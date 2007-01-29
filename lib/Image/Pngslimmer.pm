package Image::Pngslimmer;

use 5.008004;
use strict;
use warnings;
use String::CRC32();
use Compress::Zlib;

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

our $VERSION = '0.05';

sub checkcrc {
	my $chunk = shift;
	my ($chunklength, $subtocheck, $generatedcrc, $readcrc);
	#get length of data
	$chunklength = unpack("N", substr($chunk, 0, 4));
	$subtocheck = substr($chunk, 4, $chunklength + 4);
	$generatedcrc = String::CRC32::crc32($subtocheck);
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

sub crushdatachunk {
	#TO DO: Currently only works for single IDAT chunk - FIX ME
	#look to inner stream, uncompress that, then recompress
	my ($chunkin, $datalength, $puredata, $chunkout, $crusheddata, $y, $purecrc);
	$chunkin = shift;
	$datalength = unpack("N", substr($chunkin, 0, 4));
	$puredata = substr($chunkin, 10, $datalength - 6);
	my $purelen = length($puredata);
	$purecrc = unpack("N", substr($chunkin, $purelen + 10, 4));
	my $rawlength = length($puredata);
	my $x = inflateInit(-WindowBits => -MAX_WBITS)
		or return $chunkin;
	my ($output, $status);
	$output = $x->inflate($puredata);
	$status = length($output);
	my $complen = $datalength - 6;
	return $chunkin unless $output;
	#check the CRCs match
	my $uncompcrc = adler32($output);
	if ($uncompcrc ne $purecrc){ return $chunkin;}
	# now crush it at the maximum level
	($y, $status) = deflateInit(-Level => Z_BEST_COMPRESSION, -WindowBits => -MAX_WBITS, -Strategy => Z_FILTERED);
	return $chunkin unless $y;
	($crusheddata, $status) = $y->deflate($output);
	return $chunkin unless ($status == Z_OK);
	($crusheddata, $status) = $y->flush();
	return $chunkin unless $crusheddata;
	#should we go any further?
	my $newlength = length($crusheddata) + 6;
	return $chunkin unless (($newlength) < $rawlength);
	#now we have compressed the data, write the chunk
	$chunkout = pack("N", $newlength);
	my $rfc1950stuff = pack("C2", (0x48,0x0D)); 
	$output = "IDAT".$rfc1950stuff.$crusheddata.pack("N", $purecrc);
	my $outCRC = String::CRC32::crc32($output);
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

=head1 TODO

To make Pngslimmer really useful it needs to construct grayscale PNGs from coloured PNGs
and paletize true colour PNGs. I am working on it!

zlibshrink - introduced in version 0.05 - needs to be made to work with PNGs with more than one
IDAT chunk

=head1 AUTHOR

	Adrian McMenamin <adrian AT newgolddream DOT info>

=head1 SEE ALSO

	Image::Magick


=cut

