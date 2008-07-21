package Image::Pngslimmer;

use 5.008004;
use strict;
use warnings;
use Compress::Zlib;
use Compress::Raw::Zlib;
use POSIX();

require Exporter;

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Image::Pngslimmer ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw() ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
	
);

our $VERSION = '0.24';

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
	my ($blobin, $bitblob, $blobout, $strategy, $status, $y, $level);
	$blobin = shift;
	$strategy = shift;
	$level = shift;
	unless (defined($level)){$level = Z_BEST_COMPRESSION;}
	if ($strategy eq "Z_FILTERED")	{($y, $status)=  new Compress::Raw::Zlib::Deflate(-Level => $level, -WindowBits=> -&MAX_WBITS(), -Bufsize=> 0x1000, -Strategy=>Z_FILTERED, -AppendOutput => 1);}
	else { ($y, $status) = new Compress::Raw::Zlib::Deflate(-Level => $level, -WindowBits=> -&MAX_WBITS(), -Bufsize=> 0x1000, -AppendOutput => 1);}
	unless ($status == Z_OK){ return $blobin;}
	$status = $y->deflate($blobin, $bitblob);
	unless ($status == Z_OK){ return $blobin;}
	$status = $y->flush($bitblob);
	$blobout = $blobout.$bitblob;
	unless ($status == Z_OK){ return $blobin;}
	return $blobout;
}

sub getuncompressed_data {
	my ($output, $puredata, @idats, $x, $status, $outputlump, $calc_crc, $uncompcrc);
	my $blobin = shift;
	my $pnglength = length($blobin);
	my $searchindex = 8 + 25; #start looking at the end of the IHDR
	while ($searchindex < ($pnglength - 8)) {
		my $chunklength = unpack("N", substr($blobin, $searchindex, 4));
		if (substr($blobin, $searchindex + 4, 4) eq "IDAT") {
			push (@idats, $searchindex);
		}
		$searchindex += $chunklength + 12;
	}
	my $numberofidats = @idats;
	if ($numberofidats == 0) {return undef;}
	my $chunknumber = 0;
	while($chunknumber < $numberofidats) {
		my $chunklength = unpack("N", substr($blobin, $idats[$chunknumber], 4));
		if ($chunknumber == 0) {
			if ($numberofidats == 1)
			{
				$output = substr($blobin, $idats[0] + 10, $chunklength - 2);
				last;
			}
			else
			{
				$output = substr($blobin, $idats[0] + 10, $chunklength - 2); 
			}
		}
		else {
			if (($numberofidats - 1) == $chunknumber)
			{
				$puredata = substr($blobin, $idats[$chunknumber] + 8, $chunklength); 
				$output = $output.$puredata;	
				last;
			}
			else
			{
				$puredata = substr($blobin, $idats[$chunknumber] + 8, $chunklength); 
				$output = $output.$puredata;
			}
		}
		$chunknumber++;
	}
	#have the output chunk now uncompress it
	$x = new Compress::Raw::Zlib::Inflate(-WindowBits => -&MAX_WBITS(), -ADLER32=>1, -AppendOutput=>1)
		or return undef;
	my $outlength = length($output);
	$uncompcrc = unpack("N", substr($output, $outlength - 4));
	$status = $x->inflate(substr($output, 0, $outlength - 4), $outputlump);
	unless (defined($outputlump)){ return undef;}
	$calc_crc = $x->adler32();
	if ($calc_crc != $uncompcrc) {
		return undef;}
	return $outputlump; # done
}

sub crushdatachunk {
	#look to inner stream, uncompress that, then recompress
	my ($chunkin, $datalength, $puredata, $chunkout, $crusheddata, $y, $purecrc, $blobin);
	$chunkin = shift;
	$blobin = shift;
	my $output = getuncompressed_data($blobin);
	my $lenuncomp = length($output);
	unless (defined($output)){ return $chunkin;}
	my $rawlength = length($output);
	$purecrc = adler32($output);
	# now crush it at the maximum level
	$crusheddata = shrinkchunk($output, Z_FILTERED, Z_BEST_COMPRESSION);
	my $lencompo = length($crusheddata);
	unless (length($crusheddata) < $rawlength) {$crusheddata = shrinkchunk($output, Z_DEFAULT_STRATEGY, Z_BEST_COMPRESSION);}
	my $newlength = length($crusheddata) + 6;
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
	my $idatfound = 0;
	while ($searchindex < ($pnglength - 4)) {
		#Copy the chunk
		$chunklength = unpack("N", substr($blobin, $searchindex - 4, 4));
		$chunktocopy = substr($blobin, $searchindex - 4, $chunklength + 12);
		if (substr($blobin, $searchindex, 4) eq "IDAT") {
			if ($idatfound == 0){
				$processedchunk = crushdatachunk($chunktocopy, $blobin);
				$chunktocopy = $processedchunk;
				$idatfound = 1;
			}
			else {$chunktocopy = "";}
		}
		
		my $lenIDAT = length($chunktocopy);
		$blobout = $blobout.$chunktocopy;
		$searchindex += $chunklength + 12;
	}
	return $blobout;
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
	#how many bytes per pixel
	#FIX ME: only works for colour depth > 8
	my ($ihdr, %ihdr);
	$ihdr = shift;
	my $lines = $ihdr->{"imageheight"};
	my $pixels = $ihdr->{"imagewidth"};
	my $comp_width = 3;
	my $ctype = $ihdr->{"colourtype"};
	my $bdepth = $ihdr->{"bitdepth"};
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
	my $count = 0;
	my $count_width = 0;
	$newbyte = 0;
	my $comp_width = comp_width($ihdr);
	my $totalwidth = $ihdr->{"imagewidth"} * $comp_width;
	$filtereddata = "";
	my $lines = $ihdr->{"imageheight"};
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
	my $comp_width = comp_width($ihdr);
	my $count = 0;
	my $count_width = 0;
	$newbyte = 0;
	my $totalwidth = $ihdr->{"imagewidth"} * $comp_width;
	$filtereddata = "";
	my $lines = $ihdr->{"imageheight"};
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
	my $comp_width = comp_width($ihdr);
	my $count = 0;
	my $count_width = 0;
	$newbyte = 0;
	my $totalwidth = $ihdr->{"imagewidth"} * $comp_width;
	$filtereddata = "";
	my $lines = $ihdr->{"imageheight"};
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
			$avebyte = POSIX::floor($avebyte);
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
	my $comp_width = comp_width($ihdr);
	my $count = 0;
	my $count_width = 0;
	$newbyte = 0;
	my $totalwidth = $ihdr->{"imagewidth"} * $comp_width;
	$filtereddata = "";
	my $lines = $ihdr->{"imageheight"};
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
	$filtered_sub = filter_sub($unfiltereddata, $ihdr);
	$filtered_up = filter_up($unfiltereddata, $ihdr);
	$filtered_ave = filter_ave($unfiltereddata, $ihdr);
	$filtered_paeth = filter_paeth($unfiltereddata, $ihdr);
	
	#TO DO: Try other filters and pick best one
	my $pixels = $ihdr->{"imagewidth"};
	my $rows = $ihdr->{"imageheight"};
	my $comp_width = comp_width($ihdr);
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
	$blobin = shift;
	#basic check so we do not waste our time
	if (ispng($blobin) < 1) {
		return undef;
	}
	#read some basic info about the PNG
	my $ihdr = getihdr($blobin);
	if ($ihdr->{"colourtype"} == 3) { return $blobin } #already palettized
	if ($ihdr->{"bitdepth"} < 8) { return $blobin; } # colour depth is so low it's not worth it
	if ($ihdr->{"compression"} != 0) {return $blobin;} # non-standard compression
	if ($ihdr->{"filter"} != 0) {return $blobin; } # non-standard filtering

	if ($ihdr->{"interlace"} != 0) {
		#FIX ME: support interlacing
		return $blobin;
	}
	my $datachunk = getuncompressed_data($blobin);
	unless (defined($datachunk)) {return $blobin;}
	my $canfilter = linebyline($datachunk, $ihdr);
	my $preproclen = length($datachunk);
	if ($canfilter > 0)
	{
		$filtereddata = filterdata($datachunk, $ihdr);
	}
	else {return $blobin;}
	my $postproclen = length($filtereddata);
        #Now stick the uncompressed data into a chunk
	#and return - leaving the compression to a different process
        my $filteredcrc = adler32($filtereddata);
	$filtereddata = shrinkchunk($filtereddata, Z_FILTERED, Z_BEST_SPEED);
	my $filterlen = length($filtereddata);
	#now push the data into the PNG
        my $pnglength = length($blobin);
        my $ihdr_len = unpack("N", substr($blobin, 8, 4));
        my $searchindex =  16 + $ihdr_len + 4 + 4;
        #copy the start of the incoming blob
        my $blobout = substr($blobin, 0, 16 + $ihdr_len + 4);
	my $foundidat = 0;
        while ($searchindex < ($pnglength - 4)) {
	        #Copy the chunk
                my $chunklength = unpack("N", substr($blobin, $searchindex - 4, 4));
                my $chunktocopy = substr($blobin, $searchindex - 4, $chunklength + 12);
                if (substr($blobin, $searchindex, 4) eq "IDAT") {
			if ($foundidat == 0) { #ignore any additional IDAT chunks
				my $rfc1950stuff = pack("C2", (0x78, 0x5E));
				my $output = "IDAT".$rfc1950stuff.$filtereddata.pack("N", $filteredcrc);
				my $newlength = $filterlen + 6;
				my $outCRC = crc32($output);
				my $processedchunk = pack("N", $newlength).$output.pack("N", $outCRC);
				$chunktocopy = $processedchunk;
				$foundidat = 1;
			}
			else {$chunktocopy = "";}
                }
                $blobout = $blobout.$chunktocopy;
                $searchindex += $chunklength + 12;
	}
        return $blobout;
}

sub discard_noncritical {
	my ($blob, $cleanblob, $searchindex, $pnglength, $chunktext, $nextindex);
	$blob = shift;
	if (ispng($blob) < 1) { return $blob; } #not a PNG so just return the blob unaltered
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

sub ispalettized {
	my ($blobin, $ihdr, %ihdr);
	$blobin = shift;
	$ihdr = getihdr($blobin);
	%ihdr = %{$ihdr};
	return 0 unless $ihdr{"colourtype"} == 3;
	return 1;
}

sub unfiltersub {
	my ($chunkin, $lines_done, $linelength, $lineout, $comp_width, $addition);
	($chunkin, $lines_done, $linelength, $comp_width) = @_;
	my $pointis = 1;
	while ($pointis < $linelength)
	{
		my $reconbyte = unpack("C", substr($chunkin, $lines_done * $linelength + $pointis, 1));
		if ($pointis > $comp_width) {
			$addition = unpack("C", substr($lineout, $pointis - $comp_width - 1, 1));
		}
		else {$addition = 0;}
		$reconbyte = ($reconbyte + $addition)%256;
		$lineout = $lineout.pack("C", $reconbyte);
		$pointis++;
	}
	$lineout = "\0".$lineout;
	return $lineout;
}

sub unfilterup {
	my ($chunkin, $chunkout, $lines_done, $linelength, $lineout,  $addition);
	($chunkin, $chunkout, $lines_done, $linelength) = @_;
	my $pointis = 1;
	while ($pointis < $linelength)
	{
		my $reconbyte = unpack("C", substr($chunkin, $lines_done * $linelength + $pointis, 1));
		if ($lines_done > 0) {
			$addition = unpack("C", substr($chunkout, ($lines_done - 1) * $linelength + $pointis, 1));
		}
		else {$addition = 0;}
		$reconbyte = ($reconbyte + $addition)%256;
		$lineout = $lineout.pack("C", $reconbyte);
		$pointis++;
	}
	$lineout = "\0".$lineout;
	return $lineout;
}
	
sub unfilterave {
	my ($chunkin, $chunkout, $lines_done, $linelength, $lineout, $compwidth, $addition, $addition_up, $addition_left);
	($chunkin, $chunkout, $lines_done, $linelength, $compwidth) = @_;
	my $pointis = 1;
	while ($pointis < $linelength)
	{
		my $reconbyte = unpack("C", substr($chunkin, $lines_done * $linelength + $pointis, 1));
		if ($lines_done > 0) {
			$addition_up = unpack("C", substr($chunkout, ($lines_done - 1) * $linelength + $pointis, 1));
		}
		else {$addition_up = 0;}
		if ($pointis > $compwidth) {
			$addition_left = unpack("C", substr($lineout, $pointis - $compwidth - 1, 1));
		}
		else {$addition_left = 0;}
		$addition = POSIX::floor(($addition_up + $addition_left)/2);
		$reconbyte = ($reconbyte + $addition)%256;
		$lineout = $lineout.pack("C", $reconbyte);
		$pointis++;
	}
	$lineout = "\0".$lineout;
	return $lineout;
}

sub unfilterpaeth {
	my ($chunkin, $chunkout, $lines_done, $linelength, $lineout, $compwidth, $addition, $addition_up, $addition_left, $addition_uleft);
	($chunkin, $chunkout, $lines_done, $linelength, $compwidth) = @_;
	my $pointis = 1;
	while ($pointis < $linelength)
	{
		my $reconbyte = unpack("C", substr($chunkin, $lines_done * $linelength + $pointis, 1));
		if ($lines_done > 0) {
			$addition_up = unpack("C", substr($chunkout, ($lines_done - 1) * $linelength + $pointis, 1));
			if ($pointis > $compwidth) {
				$addition_uleft = unpack("C", substr($chunkout, ($lines_done - 1) * $linelength + $pointis - $compwidth, 1));
			}
			else {
				$addition_uleft = 0;
			}
		}
		else {
			$addition_up = 0;
			$addition_uleft = 0;
		}
		if ($pointis > $compwidth) {
			$addition_left = unpack("C", substr($lineout, $pointis - $compwidth - 1, 1));
		}
		else {$addition_left = 0;}
		my $paeth_p = $addition_up + $addition_left - $addition_uleft;
		my $paeth_a = abs($paeth_p - $addition_left);
		my $paeth_b = abs($paeth_p - $addition_up);
		my $paeth_c = abs($paeth_p - $addition_uleft);
		if (($paeth_a <= $paeth_b) && ($paeth_a <= $paeth_c)) { $addition = $addition_left;}
		elsif ($paeth_b <= $paeth_c) {$addition = $addition_up;}
		else {$addition = $addition_uleft;}
		my $recbyte = ($reconbyte + $addition)%256;
		$lineout = $lineout.pack("C", $recbyte);
		$pointis++;
	}
	$lineout = "\0".$lineout;
	return $lineout;
}

sub unfilter {
	my  ($blobin, $chunkin, $chunkout, $ihdr, %ihdr, $imageheight, $imagewidth);
	$chunkin = shift;
	$ihdr = shift;
	$imageheight = $ihdr->{"imageheight"};
	$imagewidth = $ihdr->{"imagewidth"};
	#get each line
	my $lines_done = 0;
	my $pixels_done = 0;
	my $comp_width = comp_width($ihdr);
	my $linelength = $comp_width * $imagewidth + 1;
	while ($lines_done < $imageheight)
	{
		my $filtertype = unpack("C", substr($chunkin, $lines_done * $linelength, 1));
		if ($filtertype == 0) {
			#line not filtered at all
			$chunkout = $chunkout.substr($chunkin,  $lines_done * $linelength, $linelength);
		}
		elsif ($filtertype == 4) {
			$chunkout = $chunkout.unfilterpaeth($chunkin, $chunkout, $lines_done, $linelength, $comp_width);
		}
		elsif ($filtertype == 1) {
			$chunkout = $chunkout.unfiltersub($chunkin, $lines_done, $linelength, $comp_width);
		}
		elsif ($filtertype == 2) {
			$chunkout = $chunkout.unfilterup($chunkin, $chunkout, $lines_done, $linelength);
		}
		else {
			$chunkout = $chunkout.unfilterave($chunkin, $chunkout, $lines_done, $linelength, $comp_width);
		}
		$lines_done++;
	}
	return $chunkout;
}

sub countcolours {
	my ($chunk, $limit, %colourlist, %ihdr, $ihdr, $totallines, $width, $cdepth, $x, $colourfound);
	($chunk, $ihdr) = @_;
	$totallines = $ihdr->{"imageheight"};
	$width = $ihdr->{"imagewidth"};
	$cdepth = comp_width($ihdr);
	my $linesdone = 0;
	my $linelength = $width * $cdepth + 1;
	my $coloursfound = 0;
	while ($linesdone < $totallines)
	{
		my $pixelpoint = 0;
		while ($pixelpoint < $width)
		{
			#FIX ME - needs to work with alpha too
			$colourfound = substr($chunk, ($pixelpoint * $cdepth) + ($linesdone * $linelength) + 1, $cdepth);
			my $colour = 0;
			for ($x = 0; $x < $cdepth; $x++)
			{
				$colour = $colour<<8|ord(substr($colourfound, $x, 1));
			}
			if (defined($colourlist{$colour})) { $colourlist{$colour}++;}
			else {
				$colourlist{$colour} = 1;
				$coloursfound++;
			}
			$pixelpoint++;
		}
		$linesdone++;
	}
	
	return ($coloursfound, \%colourlist);
}
		
sub reportcolours {
	my ($colour_limit, $blobin, $filtereddata, %ihdr, $ihdr, $blobout, $ihdr_chunk, $pal_chunk, $x, %palindex, $palindex, $colourfound);
	my ($colourlist, %colourlist, $colours);
	$blobin = shift;
	#is it a PNG
	unless( ispng($blobin) > 0)
	{
		print "Supplied image is not a PNG\n";
		return -1;
	}
	#is it already palettized?
	unless (ispalettized($blobin) < 1)
	{
		print "Supplied image is indexed.\n";
		return -1;
	}
	$filtereddata = getuncompressed_data($blobin);
	%ihdr = %{getihdr($blobin)};
	my $unfiltereddata = unfilter($filtereddata, \%ihdr);
	($colours, $colourlist) = countcolours($unfiltereddata, \%ihdr);
	%colourlist = %{$colourlist};
	my @inputlist = keys(%colourlist);
	return \%colourlist;
}
		
sub indexcolours {
	# take PNG and count colours
	my ($colour_limit, $blobin, $filtereddata, %ihdr, $ihdr, $blobout, $ihdr_chunk, $pal_chunk, $x, %palindex, $palindex, $colourfound);
	my ($colourlist, %colourlist, $colours);
	$blobin = shift;
	#is it a PNG
	return $blobin unless ispng($blobin) > 0;
	#is it already palettized?
	return $blobin unless ispalettized($blobin) < 1;
	$colour_limit = shift; 
	#0 means no limit
	$colour_limit = 0 unless $colour_limit;
	$filtereddata = getuncompressed_data($blobin);
	$ihdr = getihdr($blobin);
	my $unfiltereddata = unfilter($filtereddata, $ihdr);
	($colours, $colourlist) = countcolours($unfiltereddata, $ihdr);
	if ($colours < 1) {return $blobin;}
	#to write out an indexed version $colours has to be less than 256
	if ($colours < 256) {
		#have to rewrite the whole thing now
		#start with the PNG header
		$blobout = pack("C8", (137, 80, 78, 71, 13, 10, 26, 10));
		#now the IHDR
		$blobout = $blobout.pack("N", 0x0D);
		$ihdr_chunk = "IHDR";
		$ihdr_chunk = $ihdr_chunk.pack("N2", ($ihdr->{"imagewidth"}, $ihdr->{"imageheight"}));
		#FIX ME: Support index of less than 8 bits
		$ihdr_chunk = $ihdr_chunk.pack("C2", (8, 3)); #8 bit indexed colour
		$ihdr_chunk = $ihdr_chunk.pack("C3", ($ihdr->{"compression"}, $ihdr->{"filter"}, $ihdr->{"interlace"}));
		my $ihdrcrc = crc32($ihdr_chunk);
		$blobout = $blobout.$ihdr_chunk.pack("N", $ihdrcrc);
		#now any chunk before the IDAT
        	my $searchindex =  16 + 13 + 4 + 4;
		my $pnglength = length($blobin);
		my $foundidat = 0;
        	while ($searchindex < ($pnglength - 4)) {
	        #Copy the chunk
	                my $chunklength = unpack("N", substr($blobin, $searchindex - 4, 4));
        	        my $chunktocopy = substr($blobin, $searchindex - 4, $chunklength + 12);
                	if (substr($blobin, $searchindex, 4) eq "IDAT") {
				if ($foundidat == 0) { #ignore any additional IDAT chunks
					#now the palette chunk
					$pal_chunk = "";
					my %colourlist = %{$colourlist};
					my $palcount = 0;
					foreach $x (keys %colourlist)
					{	
						$pal_chunk = $pal_chunk.pack("C3", ($x>>16, ($x & 0xFF00)>>8, $x & 0xFF));
						#use a second hash to record where the colour is in the palette
						$palindex{$x} = $palcount;
						$palcount++;
					}
					my $pal_crc = crc32("PLTE".$pal_chunk);
					my $len_pal = length($pal_chunk);
					$blobout = $blobout.pack("N", $len_pal)."PLTE".$pal_chunk.pack("N", $pal_crc);
					#now process the IDAT
					my $dataout;
					my $linesdone = 0;
					my $totallines = $ihdr->{"imageheight"};
					my $width = $ihdr->{"imagewidth"};
					my $cdepth = comp_width($ihdr);
					my $linelength = $width * $cdepth + 1;
					while ($linesdone < $totallines)
					{
						$dataout = $dataout."\0";
						my $pixelpoint = 0;
						while ($pixelpoint < $width)
						{
							#FIX ME - needs to work with alpha too
							$colourfound = substr($unfiltereddata, ($pixelpoint * $cdepth) + ($linesdone * $linelength) + 1, $cdepth);
							my $colour = 0;
							for ($x = 0; $x < $cdepth; $x++)
							{
								$colour = $colour<<8|ord(substr($colourfound, $x, 1));
							}
							$dataout = $dataout.pack("C", $palindex{$colour});
							$pixelpoint++;
						}
						$linesdone++;
					}
					#now to deflate $dataout to get proper stream
					
					my $rfc1950stuff = pack("C2", (0x78, 0x5E));
					my $rfc1951stuff = shrinkchunk($dataout, Z_DEFAULT_STRATEGY, Z_BEST_SPEED);
					my $output = "IDAT".$rfc1950stuff.$rfc1951stuff.pack("N", adler32($dataout));
					my $newlength = length($output) - 4;
					my $outCRC = crc32($output);
					my $processedchunk = pack("N", $newlength).$output.pack("N", $outCRC);
					$chunktocopy = $processedchunk;
					$foundidat = 1;
				}
				else {$chunktocopy = "";}
	                }
        	        $blobout = $blobout.$chunktocopy;
                	$searchindex += $chunklength + 12;
		}
	}
	else {return $blobin;}
	return $blobout;
	
}

sub convert_toxyz {
	#convert 24 bit number to cartesian point
	my $inpoint = shift;
	return ($inpoint>>16, ($inpoint & 0xFF00)>>8, $inpoint & 0xFF);
}

sub convert_tocolour {
	#convert cartesian to RGB colour
	my ($x, $y, $z) = @_;
	return (($x << 16)|($y << 8)|($z));
}

sub getcolour_ave {
	my ($red, $green, $blue, @coloursin, $numb, $x, @cartesians);
	#@coloursin = @_;
	my $coloursin = shift;
	$numb = scalar(@$coloursin);
	if ($numb == 0) { return (0,0,0); };
	for ($x = 0; $x < $numb; $x++)
	{
		my @cartesians = convert_toxyz($coloursin->[$x]);
		$red += $cartesians[0];
		$green += $cartesians[1];
		$blue += $cartesians[2];
	}
	$red = ($red/$numb);
	$green = ($green/$numb);
	$blue = ($blue/$numb);
	return ($red, $green, $blue);
}

sub getaxis_details {
	#return a reference to the longestaxis and its length
	my ($boundingbox, @boundingbox, $longestaxis, $length, $i, @details);
	$boundingbox = shift;
	return (0,0) unless defined ($boundingbox->[5]);
	$longestaxis = 0;
	my @lengths;
	$lengths[0] = $boundingbox->[3] - $boundingbox->[0];
	$lengths[1] = $boundingbox->[4] - $boundingbox->[1];
	$lengths[2] = $boundingbox->[5] - $boundingbox->[2];
	for ($i = 1; $i < 3; $i++)
	{
		if ($lengths[$i] > $lengths[$longestaxis]) { $longestaxis = $i;}
	}
	my $longestaxis_cor = 2 - $longestaxis;
	return ($longestaxis_cor, $lengths[$longestaxis]);
}

sub getbiggestbox {
	#return the index to the biggest box
	my ($boxesin, $i, $n);
	$boxesin = shift;
	$n = shift; 
	my $z = 0;
	my $counter = 0;
	my $biggest = 0;
	for ($i = 0; $i < $n; $i++)
	{
		#length is 4th item per box
		$counter = $i * 4 + 3;
		if ($boxesin->[$counter] > $z)
		{
			$z = $boxesin->[$counter];
			$biggest = $i;
		}
	}
	return $biggest;
}

sub sortonaxes {
	my ($boundingref, $coloursref, $longestaxis, $lengthofaxis) = @_;
	my (@colours, $x, %distances, $colshift, @outputlist, @newcolours);
	@newcolours = @$coloursref;
	#FIXME: This only works for 24 bit colour
	if ($longestaxis == 2)
	{
		#can just sort on the whole number if red
		@newcolours = sort {$a <=> $b} @newcolours;
		return \@newcolours;
	}
	$colshift = 0xFFFFFF >> (16 - ($longestaxis * 8));
	foreach $x (@newcolours)
	{
		$distances{$x} = $x & $colshift;
	}
	@outputlist = sort {$distances{$a} <=> $distances{$b}} keys %distances;
	return \@outputlist;
}

sub getRGBbox {
	my $points = shift;
	my (@reds, @greens, @blues, $numb, $x);
	$numb = @$points;
	for ($x = 0; $x < $numb; $x += 3)
	{
		push @reds, $points->[$x];
		push @greens, $points->[$x + 1];
		push @blues, $points->[$x + 2];
	}
	@reds = sort {$a <=> $b} @reds;
	@greens = sort {$a <=> $b} @greens;
	@blues = sort {$a <=> $b} @blues;
	my $boundref = [shift @reds, shift @greens, shift @blues, pop @reds, pop @greens, pop @blues];
	return $boundref;
}

sub generate_box {
	#convert colours to cartesian points
	#and then return the bounding box
	my (@colourpoints, $x);
	foreach $x (@_)
	{
		push @colourpoints, convert_toxyz($x);
	}
	if (scalar(@colourpoints) == 3) { return \@colourpoints;}
	my $boundref = getRGBbox(\@colourpoints);
	return $boundref;
}	

sub getpalette {
	my ($x, @onebox,  @colours, @palette, %lookup, $lookup, $boxes, $z, $colours);
	my @boxes = @_;
	#eachbox has four references
	my $colnumbers = scalar(@boxes)/4;
	for ($x = 0; $x < $colnumbers; $x++)
	{
		$colours = $boxes[$x * 4 + 1];
		@colours = @$colours;
		push @palette, getcolour_ave(\@colours);
		foreach $z (@colours)
		{
			$lookup{$z} = $x;
		}
	}
	return (\@palette, \%lookup);
}

sub closestmatch_inRGB {
	my ($distance, $index, $colourin, $ciR, $ciG, $ciB, $pR, $pG, $pB, $palref, $maxindex, $cdepth, $x, $q);
	($palref, $colourin, $cdepth) = @_;
	my @pallist = @$palref;
	$index = 0;
	$distance = 0xFFFFFFFF; #big distance to start
	$maxindex = scalar(@pallist)/3; # assuming three colours
	($ciR, $ciG, $ciB) = convert_toxyz($colourin);
	for ($x = 0; $x < $maxindex; $x++)
	{
		$q = $x * 3;
		$pR = $pallist[$q] - $ciR;
		$pG = $pallist[$q + 1] - $ciG;
		$pB = $pallist[$q + 2] - $ciB;
		my $newdistance =  $pR * $pR + $pG * $pG + $pB * $pB;
		if ($newdistance < $distance) {
			$distance = $newdistance;
			$index = $x;
			if ($distance <=9) {return $index;} #probably a good enough match!
		}
	}
	return $index; #should be the closest palette entry
}
		
sub index_mediancut {
	my ($colour_numbers, $colourlist, %colourlist, @colourkeys, @boundingbox, @colourpoints, $colourspaces, $colcount, @boxes);
	my ($boxtocut, @biggestbox, $median, @newbox, $biggestbox);
	my (@palette, %lookup, $lookup, $palref, $lookupref, @axisstuff, $sortedcolours, $boxout);
	($colourlist, $colourspaces) = @_;
	if (!defined($colourspaces)||($colourspaces == 0)) {$colourspaces = 256;}
	$colcount = 0;
	%colourlist = %{$colourlist};
	@colourkeys = keys(%colourlist);
	#can now define the colour space
	# boxes data is 
	# reftoboundingboxarray, reftocoloursarray, longest_axis, length_of_longest_axis
	my $refbigbox = generate_box(@colourkeys);
	push @boxes, $refbigbox;
	push @boxes, \@colourkeys;
	push @boxes, getaxis_details($refbigbox);
	$boxtocut = 0;
	do {
		#find the biggest box
		$boxtocut = getbiggestbox(\@boxes, $colcount) unless $colcount == 0;
		@biggestbox = splice(@boxes, $boxtocut * 4, 4);
		#now sort on the axis
		$sortedcolours = sortonaxes(@biggestbox);
		my @sortedcolours = @$sortedcolours;
		$median = POSIX::floor(scalar(@sortedcolours)/2);
		#cut the colours in half
		my @lowercolours = splice(@sortedcolours, 0, $median);
		#generate two boxes
		my $refboxa = generate_box(@lowercolours);
		push @boxes, $refboxa;
		push @boxes, \@lowercolours;
		push @boxes, getaxis_details($refboxa);
		my $refboxb = generate_box(@sortedcolours);
		push @boxes, $refboxb;
		push @boxes, \@sortedcolours;
		push @boxes, getaxis_details($refboxb);
		$colcount = scalar(@boxes) /4;
	} until ($colourspaces == $colcount);
	return getpalette(@boxes);
}

sub dither {
	#implement Floyd - Steinberg error diffusion dither
	my ($colour, $unfiltereddata, $cdepth, $linesdone, $pixelpoint, $totallines, $pallookref, $paloutref, $pal_chunk, $width) = @_;
	my $linelength = $width * $cdepth + 1;
	#FIX ME not just 24 bit depth
	my %colourlookup = %$pallookref;
	my ($rcomp, $gcomp, $bcomp) = convert_toxyz($colour);
 	my $palnumber = $colourlookup{$colour};
	if (!$palnumber) {
		$palnumber = closestmatch_inRGB($paloutref, $colour, $cdepth);
	}
	my ($rp, $rg, $rb) = unpack("C3", substr($pal_chunk, $palnumber * 3, 3));
	#calculate the errors
	my @colerror = ();
	$colerror[0] = $rcomp - $rp;
	$colerror[1] = $gcomp - $rg;
	$colerror[2] = $bcomp - $rb;
	#now diffuse the errors
	my ($unpacked, $max_value);
	if ($cdepth == 6) {$max_value = 0xFFFF;}
	else {$max_value = 0xFF;}
	my $currentoffset_w = $pixelpoint * $cdepth;
	my $currentoffset_h = $linesdone * $linelength;
	my $nextoffset_h = ($linesdone + 1) * $linelength;
	for (my $ll = 0; $ll < $cdepth; $ll++)
	{
		if (($pixelpoint + 1) < $width) { 
			$unpacked = unpack("C", substr($unfiltereddata, $currentoffset_w + $currentoffset_h + 1 + $cdepth + $ll, 1));
			$unpacked += ($colerror[$ll] * 7)/16;
			if ($unpacked > $max_value) { $unpacked = $max_value; }
			elsif ($unpacked < 0) { $unpacked = 0; }
			substr($unfiltereddata, $currentoffset_w + $currentoffset_h + 1 + $cdepth + $ll, 1) = pack("C", $unpacked);
			if (($linesdone + 1) < $totallines)
			{
				$unpacked = unpack("C", substr($unfiltereddata, $currentoffset_w + (($linesdone + 1) * $linelength) + 1 + $cdepth + $ll, 1));
				$unpacked += $colerror[$ll]/16;
				if ($unpacked > $max_value) { $unpacked = $max_value; }
				elsif ($unpacked < 0) { $unpacked = 0; }
				substr($unfiltereddata, $currentoffset_w + $nextoffset_h + 1 + $cdepth + $ll, 1) = pack("C", $unpacked);
			}
		}
		if (($linesdone + 1) < $totallines)
		{
			$unpacked = unpack("C", substr($unfiltereddata, $currentoffset_w + $nextoffset_h + 1 + $ll, 1));
			$unpacked += ($colerror[$ll] * 5)/16;
			if ($unpacked > $max_value) { $unpacked = $max_value; }
			elsif ($unpacked < 0) { $unpacked = 0; }
			substr($unfiltereddata, $currentoffset_w + $nextoffset_h + 1 + $ll, 1) = pack("C", $unpacked);
			if ($pixelpoint > 0) { 
				$unpacked = unpack("C", substr($unfiltereddata, $currentoffset_w + $nextoffset_h + 1 - $cdepth + $ll, 1));
				$unpacked += ($colerror[$ll] * 3)/16;
				if ($unpacked > $max_value) { $unpacked = $max_value; }
				elsif ($unpacked < 0) { $unpacked = 0; }
				substr($unfiltereddata, $currentoffset_w + $nextoffset_h + 1 - $cdepth + $ll, 1) = pack("C", $unpacked);
			}
		}
	}

	return ($palnumber, $unfiltereddata);
}

sub palettize {
	# take PNG and count colours
	my ($colour_limit, $blobin, $filtereddata, %ihdr, $ihdr, $blobout, $ihdr_chunk, $pal_chunk, $x, %palindex, $palindex, $colourfound);
	my ($colourlist, %colourlist, $colours, $paloutref, $pallookref, $palnumb);
	$blobin = shift;
	#is it a PNG
	return $blobin unless ispng($blobin) > 0;
	#is it already palettized?
	return $blobin unless ispalettized($blobin) < 1;
	$colour_limit = shift; 
	#0 means no limit
	$colour_limit = 0 unless $colour_limit;
	my $dither = shift;
	$dither = 0 unless $dither;
	$filtereddata = getuncompressed_data($blobin);
	$ihdr = getihdr($blobin);
	my $unfiltereddata = unfilter($filtereddata, $ihdr);
	($colours, $colourlist) = countcolours($unfiltereddata, $ihdr);
	if ($colours < 1) {return $blobin;}
	if (($colours < 256)&&(($colours < $colour_limit)||($colour_limit == 0))) {return indexcolours($blobin);}
	if ($colour_limit > 256) {return undef;}
	($paloutref, $pallookref) =  index_mediancut($colourlist, $colour_limit);
	#have to rewrite the whole thing now
	#start with the PNG header
	$blobout = pack("C8", (137, 80, 78, 71, 13, 10, 26, 10));
	#now the IHDR
	$blobout = $blobout.pack("N", 0x0D);
	$ihdr_chunk = "IHDR";
	$ihdr_chunk = $ihdr_chunk.pack("N2", ($ihdr->{"imagewidth"}, $ihdr->{"imageheight"}));
	#FIX ME: Support index of less than 8 bits
	$ihdr_chunk = $ihdr_chunk.pack("C2", (8, 3)); #8 bit indexed colour
	$ihdr_chunk = $ihdr_chunk.pack("C3", ($ihdr->{"compression"}, $ihdr->{"filter"}, $ihdr->{"interlace"}));
	my $ihdrcrc = crc32($ihdr_chunk);
	$blobout = $blobout.$ihdr_chunk.pack("N", $ihdrcrc);
	#now any chunk before the IDAT
       	my $searchindex =  16 + 13 + 4 + 4;
	my $pnglength = length($blobin);
	my $foundidat = 0;
       	while ($searchindex < ($pnglength - 4)) {
       		#Copy the chunk
	        my $chunklength = unpack("N", substr($blobin, $searchindex - 4, 4));
                my $chunktocopy = substr($blobin, $searchindex - 4, $chunklength + 12);
               	if (substr($blobin, $searchindex, 4) eq "IDAT") {
			if ($foundidat == 0) { #ignore any additional IDAT chunks
				#now the palette chunk
				$pal_chunk = "";
				my @colourlist = @$paloutref;
				my $palcount = 0;
				foreach $x (@colourlist)
				{
					$pal_chunk = $pal_chunk.pack("C", $x);					
				}
				my $pal_crc = crc32("PLTE".$pal_chunk);
				my $len_pal = length($pal_chunk);
				$blobout = $blobout.pack("N", $len_pal)."PLTE".$pal_chunk.pack("N", $pal_crc);
				#now process the IDAT
				my $dataout;
				my $linesdone = 0;
				my $totallines = $ihdr->{"imageheight"};
				my $width = $ihdr->{"imagewidth"};
				my $cdepth = comp_width($ihdr);
				my $linelength = $width * $cdepth + 1;
				my %colourlookup = %{$pallookref};
				my ($colour, $palnumber);
				while ($linesdone < $totallines)
				{
					$dataout = $dataout."\0";
					my $pixelpoint = 0;
					my $linemarker = $linesdone * $linelength + 1;
					while ($pixelpoint < $width)
					{
						#FIX ME - needs to work with alpha too
						$colourfound = substr($unfiltereddata, ($pixelpoint * $cdepth) + $linemarker, $cdepth);
						$colour = 0;
						for ($x = 0; $x < $cdepth; $x++)
						{
							$colour = ($colour<<8|ord(substr($colourfound, $x, 1)));		
						}
						if ($dither == 1)
						{
							#add the new match to the palette if required
							if (!$colourlookup{$colour}) {
								($palnumb, $unfiltereddata) = dither($colour, $unfiltereddata, $cdepth, $linesdone, $pixelpoint, $totallines, \%colourlookup, $paloutref, $pal_chunk, $width);
								$colourlookup{$colour} = $palnumb;
							}
							else {
								#process the error but leave the palette alone
								($palnumb, $unfiltereddata) = dither($colour, $unfiltereddata, $cdepth, $linesdone, $pixelpoint, $totallines, \%colourlookup, $paloutref, $pal_chunk, $width);
							}
						}
						$dataout = $dataout.pack("C", $colourlookup{$colour});
						$pixelpoint++;
					}	
					$linesdone++;
				}
				#now to deflate $dataout to get proper stream
				my $rfc1950stuff = pack("C2", (0x78, 0x5E));
				my $rfc1951stuff = shrinkchunk($dataout, Z_DEFAULT_STRATEGY, Z_BEST_SPEED);
				my $output = "IDAT".$rfc1950stuff.$rfc1951stuff.pack("N", adler32($dataout));
				my $newlength = length($output) - 4;
				my $outCRC = crc32($output);
				my $processedchunk = pack("N", $newlength).$output.pack("N", $outCRC);
				$chunktocopy = $processedchunk;
				$foundidat = 1;
			}
			else {$chunktocopy = "";}
		}
        	$blobout = $blobout.$chunktocopy;
               	$searchindex += $chunklength + 12;
	}
	return $blobout;
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

	$ping = ispng($blob)				#is this a PNG? $ping == 1 if it is
	$newblob = discard_noncritical($blob)  		#discard non critcal chunks and return a new PNG
	my @chunklist = analyze($blob) 			#get the chunklist as an array
	$newblob = zlibshrink($blob)			#attempt to better compress the PNG
	$newblob = filter($blob)			#apply adaptive filtering and then compress
	$newblob = indexcolours($blob)			#attempt to replace RGB IDAT with palette (losslessly)
	$newblob = palettize($blob[, $colourlimit
					[, $dither]])	#replace RGB IDAT with colour index palette (usually lossy)
	\%colourhash = reportcolours($blob)		#return details of the colours in the PNG
	

=head1 DESCRIPTION

Image::Pngslimmer aims to cut down the size of PNGs. Users pass a PNG to various functions 
and a slimmer version is returned. Image::Pngslimmer was designed for use where PNGs are being
generated on the fly and where size matters more than speed- eg for J2ME use or any similiar 
low speed or high latency environment. There are other options - probably better ones - for 
handling static PNGs, though you may still find the fuctions useful.

Filtering and recompressing an image is not fast - for example on a 4300 BogoMIPS box with 1G
of memory the author processes PNGs at about 30KB per second.

=head2 Functions

Call Image::Pngslimmer::discard_noncritical($blob) on a stream of bytes (eg as created by Perl Magick's
Image::Magick package) to remove sections of the PNG that are not essential for display.

Do not expect this to result in a big saving - the author suggests maybe 200 bytes is typical
- but in an environment such as the backend of J2ME applications that may still be a 
worthwhile reduction.

Image::Pngslimmer::discard_noncritical($blob) will call ispng($blob) before attempting to manipulate the
supplied stream of bytes - hopefully, therefore, avoiding the accidental mangling of 
JPEGs or other files. ispng checks for PNG definition conformity -
it looks for a correct signature, an image header (IHDR) chunk in the right place, looks
for (but does not check in any way) an image data (IDAT) chunk and checks there is an
end (IEND) chunk in the right place. From version 0.03 onwards ispng also checks CRC
values.

Image::Pngslimmer::analyze($blob) is supplied for completeness and to aid debugging. It is not called by 
discard_noncritical but may be used to show 'before-and-after' to demonstrate the savings
delivered by discard_noncritical.

Image::Pngslimmer::zlibshrink($blob) will attempt to better compress the supplied PNG and will achieve good results
with poorly compressed PNGs.

Image::Pngsimmer::filter($blob) will attempt to apply adaptive filtering to the PNG - filtering should deliver 
better compression results (though the results can be mixed).  Please note that filter() will 
compress the image with Z_BEST_SPEED and so the blob returned from the function may even be larger
than the blob passed in. You must call zlibshrink if you want to recompress the blob at maximum level.
All PNG compression and filtering is lossless.

Image::Pngslimmer::indexcolours($blob) will attempt to replace an RGB image with a colourmapped image. NB This is not the
same as quantization - this process is lossless, but also only works if there are less than 256
colours in the image.

Image::Pngslimmer::palettize($blob[, $colourlimit[, $dither]]) will replace a 24 bit RGB image with a colourmapped 
(256 or less colours) image. If the original image has less than $colourlimit colours it will do this by calling 
indexcolours and so losslessly process the image. More generally it will process the image using the lossy median 
cut algorithm. Currently this only works for 24 bit images. Again this process is slow - the author can
process images at about 30 - 50KB per second - meaning it can be used for J2ME in "real time" but is
likely to be too slow for many other dynamic uses. Setting $colourlimit between 1 and 255 allows control over
the size of the generated palette (the default is 0 which generates a 256 colour palette). Setting $dither to
1 will turn on the EXTREMELY SLOW (a 150k image takes over three hours on the author's machine) dithering. It is
not recommended.

$hashref  = Image::Pngslimmer::reportcolours($blob) will return a reference to a hash with a frequency table
of the colours in the image.

=head1 LICENCE AND COPYRIGHT

This is free software and is licenced under the same terms as Perl itself ie Artistic and GPL

It is copyright (c) Adrian McMenamin, 2006, 2007, 2008

=head1 REQUIREMENTS

	POSIX
	Compress::Zlib
	Compress::Raw::Zlib

=head1 TODO

To make Pngslimmer really useful it needs to handle a broader range of bit map depths etc. The
work goes on. At the moment it really only works well with 24 bit images (though discard_noncritical
will work with all PNGs).


=head1 AUTHOR

	Adrian McMenamin <adrian AT newgolddream DOT info>

=head1 SEE ALSO

	Image::Magick


=cut

