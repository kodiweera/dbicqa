#!/usr/bin/perl -w

use strict;

use FindBin;
use lib "$FindBin::Bin";

use BXHPerlUtils;

local $/; # slurp mode

for my $arg (@ARGV) {
  my $dataref = readxmlmetadata($arg);
  my $rasorigin = "$dataref->{rasdims}->{r}->{origin} $dataref->{rasdims}->{a}->{origin} $dataref->{rasdims}->{s}->{origin}";
  open(FH, $arg) || die "Error opening $arg for reading: $!\n";
  my $contents = <FH>;
  close FH;
  $contents =~ s%^(\s*)(<dimension)%$1<rasorigin>${rasorigin}</rasorigin>\n$1$2%sm;
  open(FH, '>', $arg) || die "Error opening $arg for writing: $!\n";
  print FH $contents;
  close FH;
}
