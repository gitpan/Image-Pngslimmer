
use strict;
use Image::Pngslimmer();

use Test::More tests =>1;

my ($pngfile, $blob1, $blob2, $read, $lengthfat, $lengthslim, $weightloss);


sysopen($pngfile, "./t/test3.png", 0x0);
$read = (stat ($pngfile))[7];
(sysread($pngfile, $blob1, $read) == $read) or die "Could not open PNG\n";
$blob2 = Image::Pngslimmer::filter($blob1);
$lengthfat = length($blob2);
print "After filtering file is $lengthfat bytes long.\n";
$blob2 = Image::Pngslimmer::zlibshrink($blob2);
$lengthfat = length($blob1);
$lengthslim = length($blob2);
print "Length of unfiltered file was $lengthfat, length of filtered and recrushed file was $lengthslim\n";
print "Filtered file details\n";
print Image::Pngslimmer::analyze($blob2);
#save the file
open(PNGTEST, ">./t/testout.png");
print PNGTEST $blob2;
close (PNGTEST);


ok($lengthslim < $lengthfat);




close($pngfile);
