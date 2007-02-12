package Image::Pngslimmer;

use 5.008004;
use strict;
use warnings;
use Compress::Zlib;
use POSIX;

require Exporter;

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Image::Pngslimmer ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
	
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
	
);

our $VERSION = '0.11';

sub checkcrc {
	my $chunk = shift;
	my ($chunklength, $subtocheck, $generatedcrc, $readcrc);
	#get length of data
	$chunklength = unpack("N", substr($chunk, 0, 4));
	$subtocheck = substr($chunk, 4, $chunklength + 4);
	$generatedcrc = crc32($subtocheck);
	$readcrc = unpack("N", substr($chunk, $chunklength + 8, 4));
	if ($generatedcrc eq $readcrc) {return 1;}
	#don't match
	return 0;
}
	

sub ispng {
	my $blob = shift;
	#check for signature
	my $pngsig = pack("C8", (137, 80, 78, 71, 13, 10, 26, 10));
	my $startpng = substr($blob, 0, 8);
	if ($startpng ne $pngsig) { 
		return 0;
	 }
 	#check for IHDR
	if (substr($blob, 12, 4) ne "IHDR") {
		return 0;
	}
	if (checkcrc(substr($blob, 8)) < 1) {return 0;}
	my $ihdr_len = unpack("N", substr($blob, 8, 4));	
	#check for IDAT - scanning CRCs as we go
	#scan through all the chunks looking for an IDAT header
	my $pnglength = length($blob);
	#start searching from end of IHDR chunk
	my $searchindex = 16 + $ihdr_len + 4 + 4;
	my $idatfound  = 0;
	while ($searchindex < ($pnglength - 4)) {
		if (checkcrc(substr($blob, $searchindex - 4)) < 1) {return 0;}
		if (substr($blob, $searchindex, 4) eq "IDAT") {
			$idatfound = 1;
			last;
		}
		my $nextindex = unpack("N", substr($blob, $searchindex - 4, 4));
		if ($nextindex == 0) {
			$searchindex += 5; #after a CRC if there is an empty chunk

		}
		else {
			$searchindex += ($nextindex + 4 + 4 + 4);
		}
	}
	if ($idatfound == 0) {
		return 0;
	}
	#check for IEND chunk
	#check CRC first
	if (checkcrc(substr($blob, $pnglength - 12)) < 1) {return 0;}
	if (substr($blob, $pnglength - 8, 4) ne "IEND") {
		return 0;
	}

	return 1;
}

sub shrinkchunk {
	my ($blobin, $blobout, $strategy, $status, $y);
	$blobin = shift;
	$strategy = shift;
	if ($strategy eq "Z_FILTERED")	{($y, $status) = deflateInit(-Level => Z_BEST_COMPRESSION, -WindowBits=> -MAX_WBITS, -Bufsize=> 0x1000, -Strategy=>Z_FILTERED);}
	else { ($y, $status) = deflateInit(-Level => Z_BEST_COMPRESSION, -WindowBits=> -MAX_WBITS, -Bufsize=> 0x1000);}
	return $blobin unless ($status == Z_OK);
	($blobout, $status) = $y->deflate($blobin);
	return $blobin unless ($status == Z_OK);
	($blobout, $status) = $y->flush();
	return $blobin unless ($status == Z_OK);
	return $blobout;
}
	
	

sub crushdatachunk {
	#TO DO: Currently only works for single IDAT chunk - FIX ME
	#look to inner stream, uncompress that, then recompress
	my ($chunkin, $datalength, $puredata, $chunkout, $crusheddata, $y, $purecrc);
	$chunkin = shift;
	$datalength = unpack("N", substr($chunkin, 0, 4));
	$puredata = substr($chunkin, 10, $datalength - 6);
	my $rawlength = length($puredata);
	$purecrc = unpack("N", substr($chunkin, $rawlength + 10, 4));
	my $x = inflateInit(-WindowBits => -MAX_WBITS)
		or return $chunkin;
	my ($output, $status);
	$output = $x->inflate($puredata);
	my $complen = $datalength - 6;
	return $chunkin unless $output;
	#check the CRCs match
	my $uncompcrc = adler32($output);
	if ($uncompcrc ne $purecrc){ return $chunkin;}
	# now crush it at the maximum level
	$crusheddata = shrinkchunk($output, Z_FILTERED);
	unless (length($crusheddata) < $rawlength) {$crusheddata = shrinkchunk($output, Z_DEFAULT_STRATEGY);}
	#should we go any further?
	my $newlength = length($crusheddata) + 6;
	return $chunkin unless (($newlength) < $rawlength);
	#now we have compressed the data, write the chunk
	$chunkout = pack("N", $newlength);
	my $rfc1950stuff = pack("C2", (0x78,0xDA)); 
	$output = "IDAT".$rfc1950stuff.$crusheddata.pack("N", $purecrc);
	my $outCRC = crc32($output);
	$chunkout = $chunkout.$output.pack("N", $outCRC);
	return $chunkout;
}

sub zlibshrink {
	my ($blobin, $blobout, $pnglength, $ihdr_len, $searchindex, $chunktocopy, $chunklength, $processedchunk);
	$blobin = shift;
	#find the data chunks
	#decompress and then recompress
	#work out the CRC and write it out
	#but first check it is actually a PNG
	if (ispng($blobin) < 1) {
		return undef;
	}
	$pnglength = length($blobin);
	$ihdr_len = unpack("N", substr($blobin, 8, 4));
	$searchindex =  16 + $ihdr_len + 4 + 4;
	#copy the start of the incoming blob
	$blobout = substr($blobin, 0, 16 + $ihdr_len + 4);
	while ($searchindex < ($pnglength - 4)) {
		#Copy the chunk
		$chunklength = unpack("N", substr($blobin, $searchindex - 4, 4));
		$chunktocopy = substr($blobin, $searchindex - 4, $chunklength + 12);
		if (substr($blobin, $searchindex, 4) eq "IDAT") {
			$processedchunk = crushdatachunk($chunktocopy);
			my ($x, $y);
			$x = length($processedchunk);
			$y = length($chunktocopy);
			if (length($processedchunk) < length($chunktocopy)) {$chunktocopy = $processedchunk;}
		}
		$blobout = $blobout.$chunktocopy;
		$searchindex += $chunklength + 12;
	}
	return $blobout;
}

sub getuncompressed_data {
	my $blobin = shift;
	my $pnglength = length($blobin);
	my $searchindex = 8 + 25; #start looking at the end of the IHDR
	while ($searchindex < ($pnglength - 8)) {
		my $chunklength = unpack("N", substr($blobin, $searchindex, 4));
		if (substr($blobin, $searchindex + 4, 4) eq "IDAT") {
			#get the data
			my $puredata = substr($blobin, $searchindex + 10, $chunklength - 6); #just the rfc1951 data
			my $uncompcrc = unpack("N", substr($blobin, $searchindex + 8 + $chunklength - 4)); #adler crc for uncompressed data
			#now uncompress it
			my $x = inflateInit(-WindowBits => -MAX_WBITS)
					or return undef;
			my ($output, $status);
			($output, $status) = $x->inflate($puredata);
			return undef unless $output;
			my $calc_crc = adler32($output);
			if ($calc_crc != $uncompcrc) {
				return undef;}
			# FIX ME - what if there is more than one IDAT? #
			return $output; # done 
		}
		$searchindex += $chunklength + 12;
	}
	return undef;
}

sub linebyline {
	#analyze the data line by line
	my ($data, $ihdr)= @_;
	my %ihdr = %{$ihdr};
	my $width = $ihdr{"imagewidth"};
	my $height = $ihdr{"imageheight"};
	my $depth = $ihdr{"bitdepth"};
	my $colourtype = $ihdr{"colourtype"};
	if ($colourtype != 2) {
		return -1;
	}
	if ($depth != 8) {
		return -1;
		}
	my $count = 0;
	my $return_filtered = 1;
	while ($count < $height) {
		my $filtertype = unpack("C1", substr($data, $count * $width * 3 + $count, 1));
		if ($filtertype != 0) {$return_filtered = -1} #already filtered
		$count++;
	}
	return $return_filtered; #can be filtered?
}

sub comp_width {
	my ($ihdr, %ihdr);
	$ihdr = shift;
	%ihdr = %{$ihdr};
	my $lines = $ihdr{"imageheight"};
	my $pixels = $ihdr{"imagewidth"};
	my $comp_width = 3;
	my $ctype = $ihdr{"colourtype"};
	my $bdepth = $ihdr{"bitdepth"};
	if ($ctype == 2) { #truecolour with no alpha
		if ($bdepth == 8) {$comp_width = 3;}
		else {$comp_width = 6;}
	}
	elsif (($ctype == 0)&&($bdepth == 16)) {$comp_width = 2;} #16bit grayscale
	elsif ($ctype == 4) { #grayscale with alpha
		if ($bdepth == 8) {$comp_width = 2;}
		else {$comp_width = 3;}
	}
	elsif ($ctype == 6) { #truecolour with alpha
		if ($bdepth == 8) {$comp_width = 4;}
		else {$comp_width = 7;}
	}

	return $comp_width;
}

sub filter_sub {
	#filter data schunk using Sub type
	#http://www.w3.org/TR/PNG/#9Filters
	#Filt(x) = Orig(x) - Orig(a)
	#x is byte to be filtered, a is byte to left
	my($origbyte, $leftbyte, $newbyte, $ihdr, $unfiltereddata, $filtereddata);
	$unfiltereddata = shift;
	$ihdr = shift;
	my %ihdr = %{$ihdr};
	my $count = 0;
	my $count_width = 0;
	$newbyte = 0;
	my $comp_width=comp_width(\%ihdr);
	my $totalwidth = $ihdr{"imagewidth"} * $comp_width;
	$filtereddata = "";
	my $lines = $ihdr{"imageheight"};
	while ($count < $lines) {
		#start - add filtertype byte
		$filtereddata = $filtereddata."\1";
		while ($count_width < $totalwidth ) {
			$origbyte = unpack("C", substr($unfiltereddata, 1 + ($count * $totalwidth)  + $count_width + $count, 1));
			if ($count_width < $comp_width) {
				$leftbyte = 0;
			}
			else{	
				$leftbyte =  unpack("C", substr($unfiltereddata, 1 + $count + ($count * $totalwidth)  + $count_width - $comp_width, 1));
			}
			$newbyte = ($origbyte - $leftbyte)%256;
			$filtereddata = $filtereddata.pack("C", $newbyte);
			$count_width++;
		}
		$count_width = 0;
		$count++;
	}
	return $filtereddata;
}


sub filter_up {
	#filter data schunk using Up type
	my($origbyte, $upbyte, $newbyte, $ihdr, $unfiltereddata, $filtereddata);
	$unfiltereddata = shift;
	$ihdr = shift;
	my %ihdr = %{$ihdr};
	my $comp_width = comp_width(\%ihdr);
	my $count = 0;
	my $count_width = 0;
	$newbyte = 0;
	my $totalwidth = $ihdr{"imagewidth"} * $comp_width;
	$filtereddata = "";
	my $lines = $ihdr{"imageheight"};
	while ($count < $lines) {
		#start - add filtertype byte
		$filtereddata = $filtereddata."\2";
		while ($count_width < $totalwidth ) {
			$origbyte = unpack("C", substr($unfiltereddata, 1 + ($count * $totalwidth)  + $count_width + $count, 1));
			if ($count == 0) {
				$upbyte = 0;
			}
			else{	
				$upbyte =  unpack("C", substr($unfiltereddata, $count + (($count - 1) * $totalwidth)  + $count_width, 1));
			}
			$newbyte = ($origbyte - $upbyte)%256;
			$filtereddata = $filtereddata.pack("C", $newbyte);
			$count_width++;
		}
		$count_width = 0;
		$count++;
	}
	return $filtereddata;
}

sub filter_ave {
	#filter data schunk using Ave type
	my($origbyte, $avebyte, $newbyte, $ihdr, $unfiltereddata, $filtereddata, $top_predictor, $left_predictor);
	$unfiltereddata = shift;
	$ihdr = shift;
	my %ihdr = %{$ihdr};
	my $comp_width = comp_width(\%ihdr);
	my $count = 0;
	my $count_width = 0;
	$newbyte = 0;
	my $totalwidth = $ihdr{"imagewidth"} * $comp_width;
	$filtereddata = "";
	my $lines = $ihdr{"imageheight"};
	while ($count < $lines) {
		#start - add filtertype byte
		$filtereddata = $filtereddata."\3";
		while ($count_width < $totalwidth ) {
			$origbyte = unpack("C", substr($unfiltereddata, 1 + ($count * $totalwidth)  + $count_width + $count, 1));
			if ($count > 0) {
				$top_predictor = unpack("C", substr($unfiltereddata, $count + (($count - 1) * $totalwidth)  + $count_width, 1));
			}
			else {$top_predictor = 0;}
			if ($count_width >= $comp_width) {
				$left_predictor =  unpack("C", substr($unfiltereddata, 1 + $count + ($count * $totalwidth)  + $count_width - $comp_width, 1));
			}
			else {
				$left_predictor = 0;
			}
			$avebyte =  ($top_predictor + $left_predictor)/2;
			$avebyte = floor($avebyte);
			$newbyte = ($origbyte - $avebyte)%256;
			$filtereddata = $filtereddata.pack("C", $newbyte);
			$count_width++;
		}
		$count_width = 0;
		$count++;
	}
	return $filtereddata;
}
			
sub filter_paeth {	#paeth predictor type filtering
	my ($origbyte, $paethbyte_a, $paethbyte_b, $paethbyte_c, $paeth_p, $paeth_pa, $paeth_pb, $paeth_pc, $paeth_predictor, $unfiltereddata, $filtereddata, $newbyte, $ihdr);
	$unfiltereddata = shift;
	$ihdr = shift;
	my %ihdr = %{$ihdr};
	my $comp_width = comp_width(\%ihdr);
	my $count = 0;
	my $count_width = 0;
	$newbyte = 0;
	my $totalwidth = $ihdr{"imagewidth"} * $comp_width;
	$filtereddata = "";
	my $lines = $ihdr{"imageheight"};
	while ($count < $lines) {
		#start - add filtertype byte
		$filtereddata = $filtereddata."\4";
		while ($count_width < $totalwidth) {
			$origbyte = unpack("C", substr($unfiltereddata, 1 + ($count * $totalwidth)  + $count_width + $count, 1));
			if ($count > 0) {
				$paethbyte_b = unpack("C", substr($unfiltereddata, $count + (($count - 1) * $totalwidth)  + $count_width, 1));
			}
			else {$paethbyte_b = 0;}
			if ($count_width >= $comp_width) {
				$paethbyte_a =  unpack("C", substr($unfiltereddata, 1 + $count + ($count * $totalwidth)  + $count_width - $comp_width, 1));
			}
			else {
				$paethbyte_a = 0;
			}
			if (($count_width >= $comp_width)&&($count > 0)) {
				$paethbyte_c = unpack("C", substr($unfiltereddata, $count + (($count - 1) * $totalwidth)  + $count_width - $comp_width, 1));
			}
			else {
				$paethbyte_c = 0;
			}
			$paeth_p = $paethbyte_a + $paethbyte_b - $paethbyte_c;
			$paeth_pa = abs($paeth_p - $paethbyte_a);
			$paeth_pb = abs($paeth_p - $paethbyte_b);
			$paeth_pc = abs($paeth_p - $paethbyte_c);
			if (($paeth_pa <= $paeth_pb)&&($paeth_pa <= $paeth_pc)) { $paeth_predictor = $paethbyte_a; }
			elsif ($paeth_pb <= $paeth_pc) {$paeth_predictor = $paethbyte_b; }
			else {$paeth_predictor = $paethbyte_c;}
			$newbyte = ($origbyte - $paeth_predictor)%256;
			$filtereddata = $filtereddata.pack("C", $newbyte);
			$count_width++;
		}
		$count_width = 0;
		$count++;
	}
	return $filtereddata;
}
sub filterdata {
	my ($unfiltereddata, $ihdr, $filtereddata, $finalfiltered, $filtered_sub, $filtered_up, $filtered_ave, $filtered_paeth);
	$unfiltereddata = shift;
	$ihdr = shift;
	my %ihdr = %{$ihdr};
	$filtered_sub = filter_sub($unfiltereddata, \%ihdr);
	$filtered_up = filter_up($unfiltereddata, \%ihdr);
	$filtered_ave = filter_ave($unfiltereddata, \%ihdr);
	$filtered_paeth = filter_paeth($unfiltereddata, \%ihdr);
	
	#TO DO: Try other filters and pick best one
	my $pixels = $ihdr{"imagewidth"};
	my $rows = $ihdr{"imageheight"};
	my $comp_width = comp_width(\%ihdr);
	my $bytesperline = $pixels * $comp_width;
	my $countout = 0;
	my $rows_done = 0;
	my $count_sub = 0;
	my $count_up = 0;
	my $count_ave = 0;
	my $count_zero = 0;
	my $count_paeth = 0;
	while ($rows_done < $rows)
	{
		while (($countout) < $bytesperline)
		{	
			$count_sub += unpack("c", substr($filtered_sub, 1 + ($rows_done * $bytesperline) + $countout + $rows_done, 1));
			$count_up += unpack("c", substr($filtered_up, 1 + ($rows_done * $bytesperline) + $countout + $rows_done, 1));
			$count_ave += unpack("c", substr($filtered_ave, 1 + ($rows_done * $bytesperline) + $countout + $rows_done, 1));
			$count_zero += unpack("c", substr($unfiltereddata, 1 + ($rows_done * $bytesperline) + $countout + $rows_done, 1));
			$count_paeth +=unpack("c", substr($filtered_paeth, 1 + ($rows_done * $bytesperline) + $countout + $rows_done, 1));
			$countout++;
		}
		$count_paeth = abs($count_paeth);
		$count_zero = abs($count_zero);
		$count_ave = abs($count_ave);
		$count_up = abs($count_up);
		$count_sub = abs($count_sub);
		if (($count_paeth <= $count_zero)&&($count_paeth <= $count_sub)&&($count_paeth <= $count_up)&&($count_paeth <= $count_ave))
		{
			$finalfiltered = $finalfiltered.substr($filtered_paeth, $rows_done + $rows_done * $bytesperline, $bytesperline + 1);
		}
	   	elsif (($count_ave <= $count_zero)&&($count_ave <= $count_sub)&&($count_ave <= $count_up))
		{
			$finalfiltered = $finalfiltered.substr($filtered_ave, $rows_done + $rows_done * $bytesperline, $bytesperline + 1);
		}
		elsif (($count_up <= $count_zero)&&($count_up <= $count_sub)) 
		{
			$finalfiltered = $finalfiltered.substr($filtered_up, $rows_done + $rows_done  * $bytesperline, $bytesperline + 1);
		}
		elsif ($count_sub <= $count_zero) 
		{
			$finalfiltered = $finalfiltered.substr($filtered_sub, $rows_done + $rows_done * $bytesperline, $bytesperline + 1);
		}
		else
		{
			$finalfiltered = $finalfiltered.substr($unfiltereddata, $rows_done + $rows_done * $bytesperline, $bytesperline + 1);
		}
		$countout = 0;
		$count_up = 0;
		$count_sub = 0;
		$count_zero = 0;
		$count_ave = 0;
		$count_paeth = 0;
		$rows_done++;
	}
	return $finalfiltered;
	
}

sub getihdr {
	my ($blobin, %ihdr);
	$blobin = shift;
	$ihdr{"imagewidth"} = unpack("N", substr($blobin, 16, 4));
	$ihdr{"imageheight"} = unpack("N", substr($blobin, 20, 4));
	$ihdr{"bitdepth"} = unpack("C", substr($blobin, 24, 1));
	$ihdr{"colourtype"} = unpack("C", substr($blobin, 25, 1));
        $ihdr{"compression"} = unpack("C", substr($blobin, 26, 1));
	$ihdr{"filter"} = unpack("C", substr($blobin, 27, 1));
	$ihdr{"interlace"} = unpack("C", substr($blobin, 28, 1));
	return \%ihdr;
}
	
sub filter {
 	my ($blobin, $filtereddata);
	#decompress image and examine scanlines
	$blobin = shift;
	#basic check so we do not waste our time
	if (ispng($blobin) < 1) {
		return undef;
	}
	#read some basic info about the PNG
	my $ihdr = getihdr($blobin);
	my %ihdr = %{$ihdr};
	if ($ihdr{"colourtype"} == 3) { return $blobin } #already palettized
	if ($ihdr{"bitdepth"} < 8) { return $blobin; } # colour depth is so low it's not worth it
	if ($ihdr{"compression"} != 0) {return $blobin;} # non-standard compression
	if ($ihdr{"filter"} != 0) {return $blobin; } # non-standard filtering

	if ($ihdr{"interlace"} != 0) {
		#FIX ME: support interlacing
		return $blobin;
	}
	my $datachunk = getuncompressed_data($blobin);
	return $blobin unless $datachunk;;
	my $canfilter = linebyline($datachunk, \%ihdr);
	if ($canfilter > 0)
	{
		$filtereddata = filterdata($datachunk, \%ihdr);
	
	}
	else {return $blobin;}
        #Now stick the uncompressed data into a chunk
	#and return - leaving the compression to a different process
        my $filteredcrc = adler32($filtereddata);
	$filtereddata = shrinkchunk($filtereddata, Z_FILTERED);
	my $filterlen = length($filtereddata);
	#now push the data into the PNG
        my $pnglength = length($blobin);
        my $ihdr_len = unpack("N", substr($blobin, 8, 4));
        my $searchindex =  16 + $ihdr_len + 4 + 4;
        #copy the start of the incoming blob
        my $blobout = substr($blobin, 0, 16 + $ihdr_len + 4);
        while ($searchindex < ($pnglength - 4)) {
	        #Copy the chunk
                my $chunklength = unpack("N", substr($blobin, $searchindex - 4, 4));
                my $chunktocopy = substr($blobin, $searchindex - 4, $chunklength + 12);
                if (substr($blobin, $searchindex, 4) eq "IDAT") {
			my $rfc1950stuff = pack("C2", (0x78, 0xDA));
			my $output = "IDAT".$rfc1950stuff.$filtereddata.pack("N", $filteredcrc);
			my $newlength = $filterlen + 6;
			my $outCRC = crc32($output);
			my $processedchunk = pack("N", $newlength).$output.pack("N", $outCRC);
			$chunktocopy = $processedchunk;
                }
                $blobout = $blobout.$chunktocopy;
                $searchindex += $chunklength + 12;
	}
        return $blobout;
}

	


sub discard_noncritical {
	my ($blob, $cleanblob, $searchindex, $pnglength, $chunktext, $nextindex);
	$blob = shift;
	if (Image::Pngslimmer::ispng($blob) < 1) { return $blob; } #not a PNG so just return the blob unaltered
	#we know we have a png = so go straight to the IHDR chunk
	#copy signature and text + length from IHDR
	$cleanblob = substr($blob, 0, 16);
	#get length of IHDR
	my $ihdr_len = unpack("N", substr($blob, 8, 4));
	#copy IHDR data + CRC
	$cleanblob = $cleanblob.substr($blob, 16, $ihdr_len + 4);
	#move on to next text field
	$searchindex = 16 + $ihdr_len + 8;
	$pnglength = length($blob);
	while ($searchindex < ($pnglength - 4)) {
		#how big is chunk?
		$nextindex = unpack("N", substr($blob, $searchindex - 4, 4));
		#is chunk critcial?
		$chunktext = substr($blob, $searchindex, 1);
		if ((ord($chunktext) & 0x20) == 0 ) {
			#critcial chunk so copy
			#copy length (4), text (4), data, CRC (4)
			$cleanblob = $cleanblob.substr($blob, $searchindex - 4, 4 + 4 + $nextindex + 4);
		}
		#update the searchpoint - 4 + data length + CRC (4) + 4 to get to the text
		$searchindex += $nextindex + 12;
	}
	return $cleanblob;
}

sub analyze {
	my ($blob, $chunk_desc, $chunk_text, $chunk_length, $chunk_CRC, $crit_status, $pub_status, @chunk_array, $searchindex, $pnglength, $nextindex);
	my ($chunk_CRC_checked);
	$blob = shift;
	#is it a PNG?
	if (Image::Pngslimmer::ispng($blob) < 1){
		#no it's not, so return a simple array stating so
		push (@chunk_array, "Not a PNG file");
		return @chunk_array;
	}
	#ignore signature - it's not a chunk
	#so straight to IHDR
	$searchindex = 12;
	$pnglength = length($blob);
	while ($searchindex < ($pnglength - 4)) {
		#get datalength
		$chunk_length = unpack("N", substr($blob,  $searchindex - 4, 4));
		#name of chunk
		$chunk_text = substr($blob, $searchindex, 4);
		#chunk CRC
		$chunk_CRC = unpack("N", substr($blob, $searchindex + $chunk_length, 4));
		#is CRC correct?
		$chunk_CRC_checked = checkcrc(substr($blob, $searchindex - 4));
		#critcal chunk?
		$crit_status = 0;
		if ((ord($chunk_text) & 0x20) == 0) {$crit_status = 1;}
		#public or private chunk?
		$pub_status = 0;
		if ((ord(substr($blob, $searchindex + 1, 1)) & 0x20) == 0) {$pub_status = 1;}
		$nextindex = $searchindex - 4;
		$chunk_desc = $chunk_text." begins at offset $nextindex has data length $chunk_length with CRC $chunk_CRC";
		if ($chunk_CRC_checked == 1) {
			$chunk_desc = $chunk_desc." and the CRC is good -";
		}
		else {$chunk_desc = $chunk_desc." and there is an ERROR in the CRC -";}
		if ($crit_status > 0) { $chunk_desc = $chunk_desc." the chunk is critical to the display of the PNG"; }
		else { $chunk_desc = $chunk_desc." the chunk is not critical to the display of the PNG"; }
		if ($pub_status > 0) { $chunk_desc = $chunk_desc." and is public\n"; }
		else { $chunk_desc = $chunk_desc." and is private\n"; }
		push (@chunk_array, $chunk_desc);
		$searchindex += $chunk_length + 12;
	}
	return @chunk_array;
}


1;
__END__


=pod

=head1 NAME

Image::Pngslimmer - slims (dynamically created) PNGs

=head1 SYNOPSIS

	$ping = ispng($blob)			#is this a PNG? $ping == 1 if it is
	$newblob = discard_noncritical($blob)  	#discard non critcal chunks and return a new PNG
	my @chunklist = analyze($blob) 		#get the chunklist as an array
	$newblob = zlibshrink($blob)		#attempt to better compress the PNG
	$newblob = filter($blob)		#apply adaptive filtering and then compress
	

=head1 DESCRIPTION

Image::Pngslimmer aims to cut down the size of PNGs. Users pass a PNG to various functions 
(though only one presently exists - Image::Pngslimmer::discard_noncritical($blob)) and a
slimmer version is returned. Image::Pngslimmer is designed for use where PNGs are being
generated on the fly and where size matters - eg for J2ME use. There are other options - 
probably better ones - for handling static PNGs.

Call discard_noncritical($blob) on a stream of bytes (eg as created by Perl Magick's
Image::Magick package) to remove sections of the PNG that are not essential for display.

Do not expect this to result in a big saving - the author suggests maybe 200 bytes is typical
- but in an environment such as the backend of J2ME applications that may still be a 
worthwhile reduction..

discard_noncritical($blob) will call ispng($blob) before attempting to manipulate the
supplied stream of bytes - hopefully, therefore, avoiding the accidental mangling of 
JPEGs or other files. ispng checks for PNG definition conformity -
it looks for a correct signature, an image header (IHDR) chunk in the right place, looks
for (but does not check in any way) an image data (IDAT) chunk and checks there is an
end (IEND) chunk in the right place. From version 0.03 onwards ispng also checks CRC
values.

analyze($blob) is supplied for completeness and to aid debugging. It is not called by 
discard_noncritical but may be used to show 'before-and-after' to demonstrate the savings
delivered by discard_noncritical.

zlibshrink($blob) will attempt to better compress the supplied PNG and will achieve good results
with smallish (ie with only one IDAT chunk) but poorly compressed PNGs.

filter($blob) will attempt to apply some adaptive filtering to the PNG - filtering should deliver
compression (though the results can be mixed). Currently this code is under development but it does
work on PNG test images and if filtering is not possible (eg the image has already been filtered),
then an unchanged image is returned. All PNG compression and filtering is lossless.

=head1 LICENCE AND COPYRIGHT

This is free software and is licenced under the same terms as Perl itself ie Artistic and GPL

It is copyright (c) Adrian McMenamin, 2006, 2007

=head1 REQUIREMENTS

	POSIX
	Compress::Zlib

=head1 TODO

To make Pngslimmer really useful it needs to construct grayscale PNGs from coloured PNGs
and paletize true colour PNGs. I am working on it!

zlibshrink - introduced in version 0.05 - needs to be made to work with PNGs with more than one
IDAT chunk

filtering - with all type implement since version 0.1 needs to work with PNGs with more than
one IDAT chunk

=head1 AUTHOR

	Adrian McMenamin <adrian AT newgolddream DOT info>

=head1 SEE ALSO

	Image::Magick


=cut

