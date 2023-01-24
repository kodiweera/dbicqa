#!/usr/bin/env perl

# This script implements the high/low flip angle QA analysis, as developed by
# Doug Greve (MGH).
#
# Author: Syam Gadde (gadde@biac.duke.edu)

my $Id = '$Id: fmriqa_hilo.pl,v 1.2 2009-02-24 14:42:59 gadde Exp $ ';

use strict;

use FindBin;
use lib "$FindBin::Bin";

use Cwd;

use File::Spec;
use Config;

use File::Which;

use fmriqa_utils;
use BXHPerlUtils;

our $version = 'BXH/XCEDE utilities (1.11.14)';

BEGIN {
  #increase datasize resource limit to 2GB, if BSD::Resource is installed
  if (eval { require BSD::Resource }) {
    import BSD::Resource;
    my $r = get_rlimits();
    my $lim = 2 * 1024 * 1024 * 1024; # 2GB
    my ($soft, $hard) = getrlimit($r->{'RLIMIT_DATA'});
    if (($soft != RLIM_INFINITY() && $soft < $lim) ||
	($hard != RLIM_INFINITY() && $hard < $lim)) {
      print STDERR "Increasing datasize resource limits to 2GB\n";
      $soft = $lim if ($soft != RLIM_INFINITY() && $soft < $lim);
      $hard = $lim if ($hard != RLIM_INFINITY() && $hard < $lim);
    }
    setrlimit($r->{'RLIMIT_DATA'}, $soft, $hard);
  }
}

my $usage = <<EOM;
Usage:
  fmriqa_hilo.pl [--timeselect timepoints] [--verbose] \
                 [--tmpdir dir] \
                 highxmlfile lowxmlfile

Given 4-D input BXH- or XCEDE-wrapped image data of high and low flip angle
agar phantom scans, this program writes to standard output the following
measures based on the voxels in the core (mask eroded by 5 voxels) of the
phantom: ThermalFSNR, InstabilityFSNR, MeanHigh, MeanLow, VarHigh, VarLow,
ThermalVar, (MeanHigh/MeanLow), (MeanHigh/MeanLow)^2, NumVoxels.
EOM

my $opt_timeselect = undef;
my $opt_verbose = 0;
my $opt_tmpdir = getcwd;

my @oldARGV = @ARGV;
@ARGV = ();
while (scalar(@oldARGV)) {
  my $arg = shift @oldARGV;
  ($arg =~ /^--help$/) && do {
    print STDERR $usage;
    exit -1;
  };
  ($arg =~ /^--timeselect$/) && do {
    $opt_timeselect = shift @oldARGV;
    next;
  };
  ($arg =~ /^--tmpdir$/) && do {
    $opt_tmpdir = shift @oldARGV;
    next;
  };
  ($arg =~ /^--verbose/) && do {
    $opt_verbose++;
    next;
  };
  ($arg =~ /^--version/) && do {
    print "Version: " . ${version} . "\n";
    exit 0;
  };
  push @ARGV, $arg;
}

if (scalar(@ARGV) != 2) {
  die $usage;
}

my $highpath = shift;
my $lowpath = shift;
my ($tmpvol, $tmpdirs, $tmpfile) = File::Spec->splitpath($opt_tmpdir, 1);

# find all needed executables
my $progcount;
my $progbxh2analyze;
my $proganalyze2bxh;
my $prog3dcalc;
my $prog3dDetrend;
my $prog3dTstat;
my $prog3dAutomask;
my $prog3dROIstats;
my %exechashrequired =
  (
   'fmriqa_count' => \$progcount,
   'bxh2analyze' => \$progbxh2analyze,
   'analyze2bxh' => \$proganalyze2bxh,
   '3dcalc' => \$prog3dcalc,
   '3dAutomask' => \$prog3dAutomask,
   '3dTstat' => \$prog3dTstat,
   '3dDetrend' => \$prog3dDetrend,
   '3dROIstats' => \$prog3dROIstats,
  );
my %exechashoptional =
  (
  );
foreach my $execname (keys %exechashrequired) {
  my $execloc = findexecutable($execname);
  if (!defined($execloc)) {
    print STDERR "Can't find required executable \"$execname\"!\n";
    exit -1;
  }
  ${$exechashrequired{$execname}} = $execloc;
}
foreach my $execname (keys %exechashoptional) {
  my $execloc = findexecutable($execname);
  ${$exechashoptional{$execname}} = $execloc;
}

my $afniselector = '';
if ($opt_timeselect) {
  my @ranges = split(/,/, $opt_timeselect);
  my @points = map {
    if (/^(\d+):(\d+)$/) {
      "${1}..${2}"
    } elsif (/^(\d+):$/) {
      "${1}..\$"
    } elsif (/^:(\d+)$/) {
      "0..${1}\$"
    } else {
      "$_"
    }
  } @ranges;
  $afniselector = '[' . join(',', @points) . ']';
}

# Run AFNI stuff
my $tmpprefix = File::Spec->catpath($tmpvol, $tmpdirs, "XX_");
my ($meanhigh, $varhigh, $meanlow, $varlow, $voxelcounthigh, $voxelcountlow);
for my $filestatref ([$highpath, \$meanhigh, \$varhigh, \$voxelcounthigh], [$lowpath, \$meanlow, \$varlow, \$voxelcountlow]) {
  my ($inputpath, $meanref, $varref, $voxelcountref) = @$filestatref;
  for my $suffix ('', 'select', 'detrend', 'mean', 'mask', 'stddev') {
    if (-f "${tmpprefix}${suffix}.nii") {
      unlink "${tmpprefix}${suffix}.nii";
    }
    if (-f "${tmpprefix}${suffix}.bxh") {
      unlink "${tmpprefix}${suffix}.bxh";
    }
  }
  my @cmd = ();
  @cmd = ($progbxh2analyze, '--overwrite', '-b', '-s', '-v', '--nii', '--nosform', $inputpath, $tmpprefix);
  print STDERR join(' ', @cmd), "\n" if ($opt_verbose);
  system(@cmd);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running bxh2analyze\n";
  }
  @cmd = ($prog3dcalc, '-a', "${tmpprefix}.nii${afniselector}", '-expr', 'a*1', '-prefix', "${tmpprefix}select.nii");
  print STDERR join(' ', @cmd), "\n" if ($opt_verbose);
  system(@cmd);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dcalc\n";
  }
  @cmd = ($prog3dDetrend, '-polort', '2', '-prefix', "${tmpprefix}detrend.nii", "${tmpprefix}select.nii");
  print STDERR join(' ', @cmd), "\n" if ($opt_verbose);
  system(@cmd);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dDetrend\n";
  }
  @cmd = ($prog3dTstat, '-mean', '-prefix', "${tmpprefix}mean.nii", "${tmpprefix}select.nii");
  print STDERR join(' ', @cmd), "\n" if ($opt_verbose);
  system(@cmd);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dTstat\n";
  }
  @cmd = ($prog3dAutomask, '-q', '-erode', '5', '-prefix', "${tmpprefix}mask.nii", "${tmpprefix}mean.nii");
  print STDERR join(' ', @cmd), "\n" if ($opt_verbose);
  system(@cmd);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dAutomask\n";
  }
  @cmd = ($proganalyze2bxh, "${tmpprefix}mask.nii", "${tmpprefix}mask.bxh");
  print STDERR join(' ', @cmd), "\n" if ($opt_verbose);
  system(@cmd);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running analyze2bxh\n";
  }
  @cmd = ($prog3dTstat, '-stdev', '-prefix', "${tmpprefix}stddev.nii", "${tmpprefix}detrend.nii");
  print STDERR join(' ', @cmd), "\n" if ($opt_verbose);
  system(@cmd);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dTstat\n";
  }
  my @meanoutput = `${prog3dROIstats} -mask ${tmpprefix}mask.nii ${tmpprefix}mean.nii`;
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dROIstats\n";
  }
  my @stddevoutput = `${prog3dROIstats} -mask ${tmpprefix}mask.nii ${tmpprefix}stddev.nii`;
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dROIstats\n";
  }
  $$meanref = (split("\t", $meanoutput[1]))[2];
  chomp $$meanref;
  $$meanref =~ s/\s+//g;
  $$varref = (split("\t", $stddevoutput[1]))[2];
  chomp $$varref;
  $$varref =~ s/\s+//g;
  $$varref = $$varref * $$varref;
  my @count = `${progcount} --gt 0 ${tmpprefix}mask.bxh`;
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running fmriqa_count\n";
  }
  $$voxelcountref = $count[2];
  chomp $$voxelcountref;
  $$voxelcountref =~ s/\s+//g;
  for my $suffix ('', 'select', 'detrend', 'mean', 'mask', 'stddev') {
    if (-f "${tmpprefix}${suffix}.nii") {
      unlink "${tmpprefix}${suffix}.nii";
    }
    if (-f "${tmpprefix}${suffix}.bxh") {
      unlink "${tmpprefix}${suffix}.bxh";
    }
  }
}

my $M = ($meanhigh / $meanlow) * ($meanhigh / $meanlow);
my $ThermalVar = (($M * $varlow) - $varhigh) / ($M - 1);
my $InstabilityVar = $varhigh - $ThermalVar;
if ($InstabilityVar < 0) {
  $ThermalVar = $varlow;
  $InstabilityVar = $varhigh - $varlow;
}
my $ThermalFSNR = $meanhigh/sqrt($ThermalVar);
my $InstabilityFSNR = $meanhigh/sqrt($InstabilityVar);

print STDOUT "ThermalFSNR=${ThermalFSNR}\n";
print STDOUT "InstabilityFSNR=${InstabilityFSNR}\n";
print STDOUT "MeanHigh=${meanhigh}\n";
print STDOUT "MeanLow=${meanlow}\n";
print STDOUT "VarHigh=${varhigh}\n";
print STDOUT "VarLow=${varlow}\n";
print STDOUT "ThermalVar=${ThermalVar}\n";
print STDOUT "InstabilityVar=${InstabilityVar}\n";
print STDOUT "M=${M}\n";
print STDOUT "sqrt(M)=", sqrt($M), "\n";
print STDOUT "VoxelCountHigh=${voxelcounthigh}\n";
print STDOUT "VoxelCountLow=${voxelcountlow}\n";

# $Log: In-line log eliminated on transition to SVN; use svn log instead. $
# Revision 1.1  2009/01/22 15:08:04  gadde
# Add fmriqa_hilo.pl
#
