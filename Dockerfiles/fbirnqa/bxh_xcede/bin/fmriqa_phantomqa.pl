#!/usr/bin/env perl

# This is a wrapper for the fmriqa_phantomqa program,
# based on Matlab script provided to the fBIRN by Gary Glover.
# This script runs the program and generates plots based
# on the output.
#
# Author: Syam Gadde (gadde@biac.duke.edu)

my $Id = '$Id: fmriqa_phantomqa.pl,v 1.63 2009-02-17 14:24:52 gadde Exp $ ';

use strict;

use FindBin;
use lib "$FindBin::Bin";

use File::Spec;
use Config;

use File::Which;

my ($progvol, $progdirs, $progfile) = File::Spec->splitpath($0);
my @baseprogdirs = File::Spec->splitdir($progdirs);
if ($baseprogdirs[$#baseprogdirs] eq '') {
  pop @baseprogdirs;
}
pop @baseprogdirs;
$ENV{'MAGICK_HOME'} = File::Spec->catpath($progvol, File::Spec->catdir(@baseprogdirs), '');
$ENV{'FONTCONFIG_PATH'} = File::Spec->catpath($progvol, File::Spec->catdir(@baseprogdirs, 'etc', 'fonts'), '');

use fmriqa_utils;
use BXHPerlUtils;

our $version = 'BXH/XCEDE utilities (1.11.14)';

if ($^O eq 'darwin') {
  $ENV{'DYLD_LIBRARY_PATH'} = "$FindBin::Bin/../lib";
}

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
  fmriqa_phantomqa.pl [--timeselect timepoints] [--zselect slice] \
                      [--roisize size] \
                      [--overwrite] [--verbose] [--summaryonly] \
                      xmlfile [outputdir]

Given 4-D input BXH- or XCEDE-wrapped image data, this program produces
an HTML page with various QA plots, images, and measures that were
designed to be used with BIRN calibration phantom fMRI images.
The index.html file (which should be readable by most Web browsers) and
all other files will be put in outputdir, if specified, or otherwise will
be placed in the same directory as the input file.  Various summary
measures will be printed to standard output.  --summaryonly will only
print the summary measures, and will not save any files.
EOM

my $opt_timeselect = undef;
my $opt_zselect = undef;
my $opt_roisize = undef;
my $opt_overwrite = 0;
my $opt_verbose = 0;
my $opt_comment = undef;
my $opt_summaryonly = 0;

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
  ($arg =~ /^--zselect$/) && do {
    $opt_zselect = shift @oldARGV;
    next;
  };
  ($arg =~ /^--roisize$/) && do {
    $opt_roisize = shift @oldARGV;
    next;
  };
  ($arg =~ /^--overwrite/) && do {
    $opt_overwrite++;
    next;
  };
  ($arg =~ /^--verbose/) && do {
    $opt_verbose++;
    next;
  };
  ($arg =~ /^--summaryonly/) && do {
    $opt_summaryonly++;
    next;
  };
  ($arg =~ /^--version/) && do {
    print "Version: " . ${version} . "\n";
    exit 0;
  };
  ($arg =~ /^--comment/) && do {
    $opt_comment = shift @oldARGV;
    next;
  };
  push @ARGV, $arg;
}

if (scalar(@ARGV) < 1 || scalar(@ARGV) > 2) {
  die $usage;
}

my $outputpath = undef;
if (scalar(@ARGV) == 2) {
  $outputpath = pop @ARGV;
} else {
  my ($vol, $dirs, undef) = File::Spec->splitpath($ARGV[0]);
  $outputpath = File::Spec->catpath($vol, $dirs, '');
}
my ($outputvol, $outputdirs, undef) = File::Spec->splitpath($outputpath, 1);

my $inputpath = shift;
if (! -f $inputpath) {
  die "Error: input file '$inputpath' does not exist\n";
}

my ($inputvol, $inputdirs, $inputfile) = File::Spec->splitpath($inputpath);
my $inputbase = $inputfile;
$inputbase =~ s/\.[^\.]*$//;
my $outputbase = File::Spec->catpath($outputvol, $outputdirs, $inputbase);

if (!$opt_summaryonly && -e $outputpath && !$opt_overwrite) {
  die "Output directory $outputpath exists, aborting...";
}
if (! -e $outputpath) {
  mkdir $outputpath, 0777 || die "Error making directory $outputpath";
}

# find all needed executables
my $proggnuplot;
my $progmontage;
my $progconvert;
my $progvolmeasures;
my $progminmax;
my $progbxh2ppm;
my $progphantomqa;
my $progbxh2analyze;
my $proganalyze2bxh;
my $progghostiness;
my $progcount;
my $prog3dcalc;
my $prog3dvolreg;
my $prog3dFWHMx;
my $prog3dDetrend;
my $prog3dTstat;
my $prog3dAutomask;
my %exechashrequired =
  (
   'montage' => \$progmontage,
   'convert' => \$progconvert,
   'fmriqa_volmeasures' => \$progvolmeasures,
   'fmriqa_minmax' => \$progminmax,
   'bxh2ppm' => \$progbxh2ppm,
   'fmriqa_phantomqa' => \$progphantomqa,
   'bxh2analyze' => \$progbxh2analyze,
   'analyze2bxh' => \$proganalyze2bxh,
   'fmriqa_ghostiness' => \$progghostiness,
   'fmriqa_count' => \$progcount,
  );
my %exechashoptional =
  (
   '3dcalc' => \$prog3dcalc,
   '3dvolreg' => \$prog3dvolreg,
   '3dFWHMx' => \$prog3dFWHMx,
   '3dDetrend' => \$prog3dDetrend,
   '3dTstat' => \$prog3dTstat,
   '3dAutomask' => \$prog3dAutomask,
  );
if ($Config{'osname'} eq 'MSWin32') {
  $exechashrequired{'pgnuplot'} = \$proggnuplot;
} else {
  $exechashrequired{'gnuplot'} = \$proggnuplot;
}
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
  if (testrunexecutable($execloc) != 0) {
    $execloc = undef;
  }
  ${$exechashoptional{$execname}} = $execloc;
}

# Get amplifier gains & frequency, if available
my ($R1, $R2, $TG, $freq);
my $inputpfile = File::Spec->catpath($inputvol, $inputdirs, $inputbase . ".pfh");
if (-e $inputpfile) {
  # Read MPS R1, R2, TG, AX.
  open(PFFH, $inputpfile)
    || die "Error opening $inputpfile for reading: $!";
  sysseek(PFFH, 412, 0)
    || die "Error seeking in $inputpfile: $!";
  my $buf = '';
  sysread(PFFH, $buf, 16)
    || die "Error reading $inputpfile: $!";
  ($R1, $R2, $TG, $freq) = unpack("l4", pack("L4", unpack("N4", $buf)));
  $freq *= 0.1;
}

print STDERR " (read image metadata)\n" if ($opt_verbose);
my $filemetadata = readxmlmetadata($inputpath);
my $numtimepoints = $filemetadata->{'dims'}->{'t'}->{'size'};
my @RAStoXYZ = (-1, -1, -1);
my @XYZtoRAS = (-1, -1, -1);
for (my $dim = 0; $dim < 3; $dim++) {
  my $dimname = ('x', 'y', 'z')[$dim];
  if ($dimname eq 'z' && exists($filemetadata->{'dims'}->{'z-split2'})) {
    $dimname = 'z-split2';
  }
  my ($startlabel,undef) = split(/\s+/, $filemetadata->{'dims'}->{$dimname}->{'startlabel'});
  if ($startlabel eq 'R' || $startlabel eq 'L') {
    $RAStoXYZ[0] = $dim;
    $XYZtoRAS[$dim] = 0;
  } elsif ($startlabel eq 'A' || $startlabel eq 'P') {
    $RAStoXYZ[1] = $dim;
    $XYZtoRAS[$dim] = 1;
  } elsif ($startlabel eq 'S' || $startlabel eq 'I') {
    $RAStoXYZ[2] = $dim;
    $XYZtoRAS[$dim] = 2;
  }
}
print STDERR " XYZtoRAS = ( ", join(',', @XYZtoRAS), " )\n";
if (!defined($opt_timeselect)) {
  if ($numtimepoints % 2 == 0) {
    $opt_timeselect = '2:';
  } else {
    $opt_timeselect = '3:';
  }
}

my @xmldata = ();

my @info = ();
my @datasignal = ();
my @dataspectrum = ();
my @datarelstdmeas = ();
my @datarelstdcalc = ();
my ($mean, $snr, $sfnr);
my ($std, $percfluc, $drift, $driftfit);
my $rdc;
my $slice;
my $timepoints;
my $roisize;
my @dimensions;
my @spacing;
my @gap;
my @acqdata;
my @fullgendatabxh = ();
my $dataptr = undef;
my $datalabel = undef;
my @datacols = ();
my @datatypes = ();
my @dataunits = ();
my $cmd = "$progphantomqa";
if (defined($opt_timeselect)) {
  $cmd .= " --timeselect \"$opt_timeselect\"";
}
if (defined($opt_zselect)) {
  $cmd .= " --zselect \"$opt_zselect\"";
}
if (defined($opt_roisize)) {
  $cmd .= " --roisize \"$opt_roisize\"";
}
if ($opt_summaryonly) {
  $cmd .= " --summaryonly";
}
$cmd .= " \"$inputpath\"";
$cmd .= " \"$outputbase\"";
open(QAFH, "$cmd|") || die "Error running fmriqa_phantomqa: $!";
while (<QAFH>) {
  /^##Using ROI size (.*)/ && do {
    $roisize = $1;
    print "#roisize=$roisize";
    push @xmldata, ['roiSize', $roisize, 'integer', 'voxels'];
    next;
  };
  /^#FrameNum RawSignal\(ROI\) RawSignal\(Fit\)/ && do {
    print $_;
    push @xmldata, ['#groupcomment', 'Used to calculate signal fluctuation and drift as described in Friedman, Glover (2006), "Report on a Multicenter fMRI Quality Assurance Protocol", the following values plot mean raw signal across an RxR ROI for each volume, and a second-order polynomial fit of the same data.  These values used an ROI of ' . "${roisize}x${roisize}" . '.'];
    $datalabel = 'signal';
    @datacols = ('frameNum', 'rawSignalROI', 'rawSignalFit');
    @datatypes = ('integer', 'float', 'float');
    @dataunits = (undef, undef, undef);
    $dataptr = \@datasignal;
    next;
  };
  /^#frequency\(Hz\) spectrum\(mean_scaled\)/ && do {
    print $_;
    push @xmldata, ['#groupcomment', 'This is the frequency spectrum resulting from a Fourier analysis (of the same residual data used to calculate frequency and drift) as described in Friedman, Glover (2006), "Report on a Multicenter fMRI Quality Assurance Protocol".'];
    $datalabel = 'spectrum';
    @datacols = ('frequency', 'spectrum');
    @datatypes = ('float', 'float');
    @dataunits = ('Hz', undef);
    $dataptr = \@dataspectrum;
    next;
  };
  /^#ROIFullWidth\(pixels\) MeasuredRelativeSTD\(percent\)/ && do {
    print $_;
    push @xmldata, ['#groupcomment', 'Used in a "Weiskoff analysis" as described in Friedman, Glover (2006), "Report on a Multicenter fMRI Quality Assurance Protocol", the following values plot different ROI sizes against their coefficient of variation.'];
    $datalabel = 'relstdmeas';
    @datacols = ('roiWidth', 'relSTDMeas');
    @datatypes = ('integer', 'float');
    @dataunits = ('voxels', undef);
    $dataptr = \@datarelstdmeas;
    next;
  };
  /^#ROIFullWidth\(pixels\) CalculatedRelativeSTD\(percent\)/ && do {
    print $_;
    push @xmldata, ['#groupcomment', 'Used in a "Weiskoff analysis" as described in Friedman, Glover (2006), "Report on a Multicenter fMRI Quality Assurance Protocol", the following values plot the expected coefficient of variation for each ROI size.'];
    $datalabel = 'relstdcalc';
    @datacols = ('roiWidth', 'relSTDCalc');
    @datatypes = ('integer', 'float');
    @dataunits = ('voxels', undef);
    $dataptr = \@datarelstdcalc;
    next;
  };
  /^##\(mean, SNR, SFNR\) = \(\s*(\S+)\s+(\S+)\s+(\S+)\s*\)/ && do {
    ($mean, $snr, $sfnr) = ($1, $2, $3);
    push @xmldata, ['#comment', 'Signal summary value (\'mean\') as defined in Friedman, Glover (2006) is the mean across the ROI of the signal image (\'meanimagefile\').'];
    push @xmldata, ['mean', $mean, 'float'];
    push @xmldata, ['#comment', 'SNR summary value as defined in Friedman, Glover (2006) is the signal summary value (\'mean\') divided by the standard deviation across the ROI of the static spatial noise image (\'diffimagefile\').'];
    push @xmldata, ['SNR', $snr, 'float'];
    push @xmldata, ['#comment', 'SFNR summary value as defined in Friedman, Glover (2006) is the mean across the ROI of the signal image (\'meanimagefile\') divided by the temporal fluctuation image (\'stdimagefile\').'];
    push @xmldata, ['SFNR', $sfnr, 'float'];
    print "#mean=$mean\n";
    print "#SNR=$snr\n";
    print "#SFNR=$sfnr\n";
    next;
  };
  /^##\(std, percent fluc, drift, driftfit\) = \(\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*\)/ && do {
    ($std, $percfluc, $drift, $driftfit) = ($1, $2, $3, $4);
    push @xmldata, ['#comment', 'The following values, as described in Friedman, Glover (2006), are computed on a time-series composed of the mean intensity of each volume across the ROI.  \'std\' is a summary value calculated as the standard deviation of the residuals of a second-order polynomial fit of this time series.  \'percentFluc\', or percent fluctuation, is 100*std/msi where \'msi\' is mean signal intensity, or the mean of the above described time-series.  \'drift\' is 100*(maxroi-minroi)/msi where \'maxroi\' and \'minroi\' are the maximum and minimum values of the mean raw signal over the ROI.  \'driftfit\' is 100*(maxfit-minfit)/msi where \'maxfit\' and \'minfit\' are the maximum and minimum values of the fit.'];
    push @xmldata, ['std', $std, 'float'];
    push @xmldata, ['percentFluc', $percfluc, 'float'];
    push @xmldata, ['drift', $drift, 'float'];
    push @xmldata, ['driftfit', $driftfit, 'float'];
    print "#std=$std\n";
    print "#percentFluc=$percfluc\n";
    print "#drift=$drift\n";
    print "#driftfit=$driftfit\n";
    next;
  };
  /^##Difference image written to (\S+)/ && do {
    push @xmldata, ['#comment', 'Location of static spatial noise image (i.e. difference image) is stored in \'diffimagefile\'.'];
    push @xmldata, ['diffimagefile', $1, 'varchar'];
    $fullgendatabxh[0] = $1;
    next;
  };
  /^##Mean image written to (\S+)/ && do {
    push @xmldata, ['#comment', 'Location of "signal image" (mean across time) is stored in \'meanimagefile\'.'];
    push @xmldata, ['meanimagefile', $1, 'varchar'];
    $fullgendatabxh[1] = $1;
    next;
  };
  /^##StdDev image written to (\S+)/ && do {
    push @xmldata, ['#comment', 'Location of "temporal fluctuation noise image" (standard deviation image of voxel-by-voxel residuals of second-order polynomial fit across time) is stored in \'stdimagefile\'.'];
    push @xmldata, ['stdimagefile', $1, 'varchar'];
    $fullgendatabxh[2] = $1;
    next;
  };
  /^##SFNR image written to (\S+)/ && do {
    push @xmldata, ['#comment', 'SFNR image is signal image divided by temporal fluctuation noise image.'];
    push @xmldata, ['sfnrimagefile', $1, 'varchar'];
    $fullgendatabxh[3] = $1;
    next;
  };
  /^##rdc = (.*) pixels/ && do {
    ($rdc) = ($1);
    push @xmldata, ['#comment', 'Radius of decorrelation (RDC) as described in Friedman, Glover (2006), quote: "may be thought of as a measure of the size of ROI at which statistical independence of the voxels is lost."'];
    push @xmldata, ['rdc', $rdc, 'float', 'voxels'];
    print "#rdc=$rdc\n";
    next;
  };
  /^##Using slice (.*)/ && do {
    $slice = $1;
    push @xmldata, ['#comment', 'All slice and time point numbers are indexed starting at zero (0).'];
    push @xmldata, ['slice', $slice, 'integer'];
    print "#slice=$slice\n";
    next;
  };
  /^##Using time points (.*)/ && do {
    $timepoints = $1;
    push @xmldata, ['timepoints', $timepoints, 'varchar'];
    print "#timepoints=$timepoints\n";
    next;
  };
  /^##acquisitiondata:([^=]*) = (.*)/ && do {
    print $_;
    push @xmldata, [$1, $2, 'varchar'];
    push @acqdata, [$1, $2];
    next;
  };
  /^##orig. dimensions: (.*)/ && do {
    print $_;
    push @xmldata, ['origdimensions', $1, 'varchar'];
    @dimensions = split('x', $1);
    next;
  };
  /^##orig. spacing: (.*)/ && do {
    print $_;
    push @xmldata, ['origspacing', $1, 'varchar'];
    @spacing = split('x', $1);
    next;
  };
  /^##orig. gap: (.*)/ && do {
    print $_;
    push @xmldata, ['origgap', $1, 'varchar'];
    @gap = split('x', $1);
    next;
  };
  print $_ if (/^##/);
  /^##/ && do {
    print $_;
    push @info, $_;
    $dataptr = undef;
    next;
  };
  /^#/ && do {
    print $_;
    $dataptr = undef;
    next;
  };
  if (defined($dataptr)) {
    print $_;
    my @cols = split(/\s+/, $_);
    push @xmldata, [$datalabel, map { [$datacols[$_], $cols[$_], $datatypes[$_], $dataunits[$_]] } (0..$#datacols)];
    push @$dataptr, [@cols];
  }
}
close QAFH;

if (defined($R1) && defined($R2) && defined($TG) && defined($freq)) {
  push @xmldata, ['R1', $R1, 'float'];
  push @xmldata, ['R2', $R2, 'float'];
  push @xmldata, ['TG', $TG, 'float'];
  push @xmldata, ['freq', $freq, 'float'];
  print "#R1=$R1\n";
  print "#R2=$R2\n";
  print "#TG=$TG\n";
  print "#freq=$freq\n";
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
my @fwhmx = ();
my @fwhmy = ();
my @fwhmz = ();
my @ghost = ();
my @volreg = ();
if (!defined($prog3dcalc) ||
    !defined($prog3dvolreg) ||
    !defined($prog3dFWHMx) ||
    !defined($prog3dDetrend) ||
    !defined($prog3dTstat) ||
    !defined($prog3dAutomask)) {
  print STDOUT "Could not find one or more AFNI tools (3dcalc, 3dvolreg, 3dFWHMx, 3dDetrend,\n3dTstat, or 3dAutomask, so will not run FWHM, Ghost, or volume registration\ncalculations\n";
} else {
  my $niftiprefix = File::Spec->catpath($outputvol, $outputpath, "XX");
  my $shortfile = "${niftiprefix}shortened.nii";
  my $volregfile = "${niftiprefix}volreg.nii";
  my $volregout = "${niftiprefix}volreg.out";
  my $detrendfile = "${niftiprefix}detrend.nii";
  my $meanfile = "${niftiprefix}mean.nii";
  my $maskfile = "${niftiprefix}mask.nii";
  my $maskbxh = "${niftiprefix}mask.bxh";
  my $ghostmaskbxh = "${niftiprefix}ghostmask.bxh";
  my $ghostmaskimg = "${niftiprefix}ghostmask.img";
  my $tmpoutfile = File::Spec->catpath($outputvol, $outputpath, "fwhm.out");
  unlink "${niftiprefix}.hdr", "${niftiprefix}.img";
  unlink $shortfile, $volregfile, $detrendfile, $meanfile, $maskfile, $maskbxh, $ghostmaskbxh, $ghostmaskimg;
  unlink $tmpoutfile;
  print STDERR " (create 3-D NIFTI files)\n" if ($opt_verbose);
  system($progbxh2analyze, '--overwrite', '-b', '-s', '-v', '--niftihdr', '--nosform', $inputpath, $niftiprefix);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running bxh2analyze\n";
  }
  print STDERR " (run AFNI 3dFWHMx)\n" if ($opt_verbose);
  my $tmpfwhmdataref = [];
  system($prog3dcalc, '-a', "${niftiprefix}.hdr${afniselector}", '-expr', 'a*1', '-prefix', $shortfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dcalc\n";
  }
  system($prog3dvolreg, '-1Dfile', $volregout, '-prefix', $volregfile, $shortfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dvolreg\n";
  }
  open(SMFH, $volregout) || die "Error opening '$volregout': $!\n";
  my $volnum = 0;
  while (<SMFH>) {
    chomp;
    s/^\s+//;
    s/\s+$//;
    my ($roll, $pitch, $yaw, $dS, $dL, $dP) = split(/\s+/, $_);
    my $dX = ($dL, $dP, $dS)[$XYZtoRAS[0]];
    my $dY = ($dL, $dP, $dS)[$XYZtoRAS[1]];
    my $dZ = ($dL, $dP, $dS)[$XYZtoRAS[2]];
    push @volreg, [$volnum, $roll, $pitch, $yaw, $dX, $dY, $dZ];
    $volnum++;
  }
  close SMFH;
  system($prog3dDetrend, '-polort', '2', '-prefix', $detrendfile, $volregfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dDetrend\n";
  }
  system($prog3dTstat, '-mean', '-prefix', $meanfile, $volregfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dTstat\n";
  }
  system($prog3dAutomask, '-q', '-prefix', $maskfile, $meanfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dAutomask\n";
  }
  system($prog3dFWHMx, '-dset', $detrendfile, '-mask', $maskfile, '-out', $tmpoutfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dFWHMx\n";
  }
  open(SMFH, $tmpoutfile) || die "Error opening '$tmpoutfile': $!\n";
  push @xmldata, ['#groupcomment', 'Full-width half-maximum (FWHM) is calculated using the AFNI tool 3dFWHMx.'];
  $volnum = 0;
  while (<SMFH>) {
    chomp;
    s/^\s+//;
    s/\s+$//;
    my ($fwhmx, $fwhmy, $fwhmz) = split(/\s+/, $_);
    push @xmldata, ['FWHM', ['volnum', $volnum, 'integer'], ['FWHMX', $fwhmx, 'float', 'voxels'], ['FWHMY', $fwhmy, 'float', 'voxels'], ['FWHMZ', $fwhmz, 'float', 'voxels']];
    push @fwhmx, [$volnum, $fwhmx];
    push @fwhmy, [$volnum, $fwhmy];
    push @fwhmz, [$volnum, $fwhmz];
    $volnum++;
  }
  close SMFH;

  print STDERR " (calculate ghosting)\n" if ($opt_verbose);
  unlink $maskfile;

  system($prog3dAutomask, '-q', '-dilate', '4', '-prefix', $maskfile, $meanfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dAutomask\n";
  }
  system($proganalyze2bxh, $maskfile, $maskbxh);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running 3dAutomask\n";
  }

  my $cmd = "$progghostiness --maskfile $maskbxh $inputpath $ghostmaskbxh";
  if (defined($opt_timeselect)) {
    $cmd .= " --timeselect \"$opt_timeselect\"";
  }
  print '#volnum ghostpercentage brightghostpercentage';
  push @xmldata, ['#groupcomment', 'The ghost metrics are calculated for each volume by taking a dilated mask ("original mask") of the data, and shifting it by N/2 voxels in the appropriate axis to create a "ghost mask".  The mean intensities of those voxels in the original mask and not in the ghost mask ("meanSignal") and of voxels in the ghost mask and not in the original mask ("meanGhost") are calculated.  The mean intensity of the top 10 percent of ghost-only voxels ("meanBrightGhost") is also calculated.  "ghostPercent" is 100*meanGhost/meanSignal, "brightGhostPercent" is 100*meanBrightGhost/meanSignal.'];
  if (open(VMFH, "$cmd |")) {
    while (<VMFH>) {
      next if /^#/;
      my ($volnum, $maskmean, $ghostmean, $brightghostmean) = split(/\s+/, $_);
      my ($ghostperc, $brightghostperc) = (100*$ghostmean/$maskmean, 100.0*$brightghostmean/$maskmean);
      print join(" ", $volnum, $ghostperc, $brightghostperc), "\n";
      push @xmldata, ['ghostiness', ['volNum', $volnum, 'integer'], ['ghostPercent', $ghostperc, 'float'], ['brightGhostPercent', $brightghostperc, 'float']];

      push @ghost, [$volnum, $ghostperc, $brightghostperc];
    }
    close VMFH;
  }
  if (!@ghost) {
    print STDERR "  Not calculating ghost metrics (not EPI?)\n";
  }
  unlink "${niftiprefix}.hdr", "${niftiprefix}.img";
  unlink $shortfile, $volregfile, $volregout, $detrendfile, $meanfile, $maskfile, $maskbxh, $ghostmaskbxh, $ghostmaskimg;
  unlink $tmpoutfile;
}

# Run volmeasures to get center-of-mass
my @cmass = ();
print STDERR " (calculate center of mass)\n" if ($opt_verbose);
$cmd = "$progvolmeasures $inputpath";
if (defined($opt_timeselect)) {
  $cmd .= " --timeselect \"$opt_timeselect\"";
}
open(VMFH, "$cmd |")
  || die "Error running fmriqa_volmeasures: $!";
push @xmldata, ['#groupcomment', 'The Center of Mass metrics are a simple mean intensity of each volume, with each voxel\'s value weighted by its index in the X, Y, or Z direction.'];
my $volnum = 0;
while (<VMFH>) {
  print $_;
  next if /^#/;
  my ($volnum, $volmean, $cmassx, $cmassy, $cmassz, $volstddev, $volmin, $volmax, $axistick) = split(/\s+/, $_);
  push @xmldata, ['cmass', ['volnum', $volnum, 'integer'], ['cmassx', $cmassx, 'float'], ['cmassy', $cmassy, 'float'], ['cmassz', $cmassz, 'float']];
  push @{$cmass[$volnum]}, $volnum, $cmassx, $cmassy, $cmassz;
  $volnum++;
}
close VMFH;

my $meanfwhmx = calcmean(map { $_->[1] != -1 ? ($_->[1]) : () } @fwhmx);
my $meanfwhmy = calcmean(map { $_->[1] != -1 ? ($_->[1]) : () } @fwhmy);
my $meanfwhmz = calcmean(map { $_->[1] != -1 ? ($_->[1]) : () } @fwhmz);
my $meanghost = calcmean(map { $_->[1] } @ghost);
my $meanbrightghost = calcmean(map { $_->[2] } @ghost);

#interpolate -1's in the FWHM output
for my $arrayref (\@fwhmx, \@fwhmy, \@fwhmz) {
  for (my $ind = 0; $ind < scalar(@$arrayref); $ind++) {
    if ($arrayref->[$ind]->[1] == -1) {
      if ($ind == 0) {
	my $validind;
	for ($validind = $ind+1; $validind < scalar(@$arrayref); $validind++) {
	  last if $arrayref->[$validind]->[1] != -1;
	}
	next if $validind == scalar(@$arrayref);
	for (my $newind = $ind; $newind < $validind; $newind++) {
	  $arrayref->[$ind]->[1] = $arrayref->[$validind]->[1];
	}
      } elsif ($ind == $#$arrayref) {
        $arrayref->[$ind]->[1] = $arrayref->[$#$arrayref-1]->[1];
      } else {
	my $prevval = $arrayref->[$ind-1]->[1];
	next if $prevval == -1;
	my $nextval = $prevval;
	my $numinterpsteps = 1;
	for (my $newind = $ind+1; $newind < scalar(@$arrayref); $newind++) {
	  if ($arrayref->[$newind]->[1] == -1) {
	    $numinterpsteps++;
          } else {
	    $nextval = $arrayref->[$newind]->[1];
	    last;
          }
        }
	$arrayref->[$ind]->[1] = $prevval + (($nextval - $prevval) / ($numinterpsteps + 1));
      }
    }
  }
}

my $minfwhmx = calcmin(map { $_->[1] } @fwhmx);
my $minfwhmy = calcmin(map { $_->[1] } @fwhmy);
my $minfwhmz = calcmin(map { $_->[1] } @fwhmz);
my $maxfwhmx = calcmax(map { $_->[1] } @fwhmx);
my $maxfwhmy = calcmax(map { $_->[1] } @fwhmy);
my $maxfwhmz = calcmax(map { $_->[1] } @fwhmz);

my $mincmassx = calcmin(map { $_->[1] } @cmass);
my $mincmassy = calcmin(map { $_->[2] } @cmass);
my $mincmassz = calcmin(map { $_->[3] } @cmass);
my $maxcmassx = calcmax(map { $_->[1] } @cmass);
my $maxcmassy = calcmax(map { $_->[2] } @cmass);
my $maxcmassz = calcmax(map { $_->[3] } @cmass);
my $meancmassx = calcmean(map { $_->[1] } @cmass);
my $meancmassy = calcmean(map { $_->[2] } @cmass);
my $meancmassz = calcmean(map { $_->[3] } @cmass);
my $dispcmassx = $maxcmassx - $mincmassx;
my $dispcmassy = $maxcmassy - $mincmassy;
my $dispcmassz = $maxcmassz - $mincmassz;
my $driftcmassx = $cmass[$#cmass]->[1] - $cmass[0]->[1];
my $driftcmassy = $cmass[$#cmass]->[2] - $cmass[0]->[2];
my $driftcmassz = $cmass[$#cmass]->[3] - $cmass[0]->[3];
if (@volreg) {
  # shift volreg measures to be coincident with first center of mass value
  map {
    $_->[4] = $cmass[0]->[1] - $_->[4];
    $_->[5] = $cmass[0]->[2] - $_->[5];
    $_->[6] = $cmass[0]->[3] - $_->[6];
  } @volreg;
}

# round some stats to a few decimal places
for my $stat ($mincmassx, $mincmassy, $mincmassz,
	      $maxcmassx, $maxcmassy, $maxcmassz,
	      $meancmassx, $meancmassy, $meancmassz,
	      $dispcmassx, $dispcmassy, $dispcmassz,
	      $driftcmassx, $driftcmassy, $driftcmassz,
	      $minfwhmx, $minfwhmy, $minfwhmz,
	      $maxfwhmx, $maxfwhmy, $maxfwhmz,
	      $meanfwhmx, $meanfwhmy, $meanfwhmz,
	      $meanghost, $meanbrightghost) {
  if (defined($stat)) {
    $stat = sprintf("%.3f", $stat);
  }
}


push @xmldata, ['#comment', 'The Center of Mass metrics are a simple mean intensity of each volume, with each voxel\'s value weighted by its index in the X, Y, or Z direction.  The following metrics are summaries of the per-volume metrics. "disp" or displacement refers to the difference between the maximum and minimum values, and "drift" is the difference between the values for the last and first volumes.'];
push @xmldata, ['minCMassX', $mincmassx, 'float'];
push @xmldata, ['minCMassY', $mincmassy, 'float'];
push @xmldata, ['minCMassZ', $mincmassz, 'float'];
print "#mincmassx=$mincmassx\n";
print "#mincmassy=$mincmassy\n";
print "#mincmassz=$mincmassz\n";
push @xmldata, ['maxCMassX', $maxcmassx, 'float'];
push @xmldata, ['maxCMassY', $maxcmassy, 'float'];
push @xmldata, ['maxCMassZ', $maxcmassz, 'float'];
print "#maxcmassx=$maxcmassx\n";
print "#maxcmassy=$maxcmassy\n";
print "#maxcmassz=$maxcmassz\n";
push @xmldata, ['meanCMassX', $meancmassx, 'float'];
push @xmldata, ['meanCMassY', $meancmassy, 'float'];
push @xmldata, ['meanCMassZ', $meancmassz, 'float'];
print "#meancmassx=$meancmassx\n";
print "#meancmassy=$meancmassy\n";
print "#meancmassz=$meancmassz\n";
push @xmldata, ['dispCMassX', $dispcmassx, 'float'];
push @xmldata, ['dispCMassY', $dispcmassy, 'float'];
push @xmldata, ['dispCMassZ', $dispcmassz, 'float'];
print "#dispcmassx=$dispcmassx\n";
print "#dispcmassy=$dispcmassy\n";
print "#dispcmassz=$dispcmassz\n";
push @xmldata, ['driftCMassX', $driftcmassx, 'float'];
push @xmldata, ['driftCMassY', $driftcmassy, 'float'];
push @xmldata, ['driftCMassZ', $driftcmassz, 'float'];
print "#driftcmassx=$driftcmassx\n";
print "#driftcmassy=$driftcmassy\n";
print "#driftcmassz=$driftcmassz\n";

if (@fwhmx) {
  push @xmldata, ['#comment', 'Full-width half-maximum (FWHM) is calculated using the AFNI tool 3dFWHMx.'];
  push @xmldata, ['minFWHMX', $minfwhmx, 'float'];
  push @xmldata, ['minFWHMY', $minfwhmy, 'float'];
  push @xmldata, ['minFWHMZ', $minfwhmz, 'float'];
  print "#minfwhmx=$minfwhmx\n";
  print "#minfwhmy=$minfwhmy\n";
  print "#minfwhmz=$minfwhmz\n";
  push @xmldata, ['maxFWHMX', $maxfwhmx, 'float'];
  push @xmldata, ['maxFWHMY', $maxfwhmy, 'float'];
  push @xmldata, ['maxFWHMZ', $maxfwhmz, 'float'];
  print "#maxfwhmx=$maxfwhmx\n";
  print "#maxfwhmy=$maxfwhmy\n";
  print "#maxfwhmz=$maxfwhmz\n";
  push @xmldata, ['meanFWHMX', $meanfwhmx, 'float'];
  push @xmldata, ['meanFWHMY', $meanfwhmy, 'float'];
  push @xmldata, ['meanFWHMZ', $meanfwhmz, 'float'];
  print "#meanfwhmx=$meanfwhmx\n";
  print "#meanfwhmy=$meanfwhmy\n";
  print "#meanfwhmz=$meanfwhmz\n";
}

if (defined($meanghost)) {
  push @xmldata, ['#comment', 'See description of ghost metrics elsewhere in this document.'];
  push @xmldata, ['meanGhost', $meanghost, 'float'];
  print "#meanghost=$meanghost\n";
}
if (defined($meanbrightghost)) {
  push @xmldata, ['#comment', 'See description of ghost metrics elsewhere in this document.'];
  push @xmldata, ['meanBrightGhost', $meanbrightghost, 'float'];
  print "#meanbrightghost=$meanbrightghost\n";
}

### write out summary data in XCEDE format
my $outputxml = File::Spec->catpath($outputvol, $outputdirs, "summaryQA.xml");
open(XMLFH, ">$outputxml")
  || die "Cannot open outputfile $outputxml: $!";
my $curtime = time();
my @localtime = localtime();
my @gmtime = gmtime();
print XMLFH <<EOM;
<?xml version="1.0" encoding="UTF-8" ?>
<XCEDE xmlns="http://www.xcede.org/xcede-2"
  xmlns:fbirn="http://www.xcede.org/extensions/fbirn"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  version="2.0">
  <analysis ID="${$}_${curtime}">
    <provenance>
      <processStep>
        <program>fmriqa_phantomqa.pl</program>
        <programArguments>$0 @ARGV</programArguments>
        <timeStamp></timeStamp>
        <user>$ENV{USER}</user>
        <hostName>$Config{myhostname}\.$Config{mydomain}</hostName>
        <platform>$Config{osname}</platform>
        <cvs>$Id</cvs>
        <package>$version</package>
      </processStep>
    </provenance>
    <measurementGroup>
      <entity xsi:type="fbirn:labeledEntity_t" description="fBIRN QA summary statistics">
        <label nomenclature="fbirnQA" termID="summarystats"/>
      </entity>
EOM
# do all simple values first
for my $entry (@xmldata) {
  my ($name, @fields) = @$entry;
  next if ($name eq '#groupcomment'); # skip this for now
  next if (ref($fields[0])); # skip this for now
  my ($value, $type, $units) = @fields;
  if (defined($type)) {
    $type = " type=\"${type}\"";
  } else {
    $type = "";
  }
  if (defined($units)) {
    $units = " units=\"${units}\"";
  } else {
    $units = "";
  }
  if ($name eq '#comment') {
    print XMLFH "      <!-- ${value} -->\n";
  } else {
    print XMLFH "      <observation name=\"${name}\"${type}${units}>${value}</observation>\n";
  }
}
print XMLFH <<EOM;
    </measurementGroup>
EOM
my @groupcomments = ();
for my $entry (@xmldata) {
  my ($name, @fields) = @$entry;
  if ($name eq '#groupcomment') {
    push @groupcomments, $fields[0];
    next;
  }
  next if (!ref($fields[0])); # already did this so skip it
  for my $groupcomment (@groupcomments) {
    print XMLFH "    <!-- $groupcomment -->\n";
  }
  print XMLFH <<EOM;
    <measurementGroup>
      <entity xsi:type="fbirn:labeledEntity_t">
        <label nomenclature="fbirnQA" termID="${name}"/>
      </entity>
EOM
  @groupcomments = ();
  for my $fieldref (@fields) {
    my ($fieldname, $value, $type, $units) = @$fieldref;
    if (defined($type)) {
      $type = " type=\"$type\"";
    } else {
      $type = '';
    }
    if (defined($units)) {
      $units = " units=\"$units\"";
    } else {
      $units = '';
    }
    print XMLFH "      <observation name=\"${fieldname}\"${type}${units}>${value}</observation>\n";
  }
  print XMLFH "    </measurementGroup>\n";
}
print XMLFH <<EOM;
  </analysis>
</XCEDE>
EOM
close XMLFH;

### the rest is executed only if --summaryonly was not specified

if (!$opt_summaryonly) {
  my $outputhtml = File::Spec->catpath($outputvol, $outputdirs, "index.html");
  my $imgsignal = "qa_signal.png";
  my $imgspectrum = "qa_spectrum.png";
  my $imgrelstd = "qa_relstd.png";
  my $imgfwhmx = "qa_fwhmx.png";
  my $imgfwhmy = "qa_fwhmy.png";
  my $imgfwhmz = "qa_fwhmz.png";
  my $imgcmassx = "qa_cmassx.png";
  my $imgcmassy = "qa_cmassy.png";
  my $imgcmassz = "qa_cmassz.png";
  my $imgghost = "qa_ghost.png";
  my $fullimgsignal = File::Spec->catpath($outputvol, $outputdirs, $imgsignal);
  my $fullimgspectrum = File::Spec->catpath($outputvol, $outputdirs, $imgspectrum);
  my $fullimgrelstd = File::Spec->catpath($outputvol, $outputdirs, $imgrelstd);
  my $fullfwhmx = File::Spec->catpath($outputvol, $outputdirs, $imgfwhmx);
  my $fullfwhmy = File::Spec->catpath($outputvol, $outputdirs, $imgfwhmy);
  my $fullfwhmz = File::Spec->catpath($outputvol, $outputdirs, $imgfwhmz);
  my $fullcmassx = File::Spec->catpath($outputvol, $outputdirs, $imgcmassx);
  my $fullcmassy = File::Spec->catpath($outputvol, $outputdirs, $imgcmassy);
  my $fullcmassz = File::Spec->catpath($outputvol, $outputdirs, $imgcmassz);
  my $fullghost = File::Spec->catpath($outputvol, $outputdirs, $imgghost);
  my $plotsignal = File::Spec->catpath($outputvol, $outputdirs, "tmpplotsignal$$");
  my $plotspectrum = File::Spec->catpath($outputvol, $outputdirs, "tmpplotspectrum$$");
  my $plotrelstd = File::Spec->catpath($outputvol, $outputdirs, "tmpplotrelstd$$");
  my $plotfwhmx = File::Spec->catpath($outputvol, $outputdirs, "tmpplotfwhmx$$");
  my $plotfwhmy = File::Spec->catpath($outputvol, $outputdirs, "tmpplotfwhmy$$");
  my $plotfwhmz = File::Spec->catpath($outputvol, $outputdirs, "tmpplotfwhmz$$");
  my $plotcmass = File::Spec->catpath($outputvol, $outputdirs, "tmpplotcmass$$");
  my $plotvolreg = File::Spec->catpath($outputvol, $outputdirs, "tmpplotvolreg$$");
  my $plotghost = File::Spec->catpath($outputvol, $outputdirs, "tmpplotghost$$");
  my $plotcmdsfile = File::Spec->catpath($outputvol, $outputdirs, "tmpplotcmds$$");

  my $yrangemin = undef;
  my $yrangemax = undef;

  # Plot signal strength
  open(TMPFH, ">$plotsignal")
    || die "Cannot open temporary outputfile $plotsignal: $!";
  print TMPFH
    join("\n", map { join(" ", @$_) } @datasignal);
  close TMPFH;
  open(GNUPLOT, ">$plotcmdsfile");
  print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullimgsignal}.pbm'
set xlabel "Frame number"
set ylabel "Raw signal (ROI)"
set title "$inputfile  [percent fluct (trend removed), drift, driftfit] = [$percfluc, $drift, $driftfit]"
EOM
  print GNUPLOT <<EOM;
plot '$plotsignal' using 1:2 title "observed" with lines, '$plotsignal' using 1:3 title "fit" with lines lt 3
EOM
  close GNUPLOT;
  system($proggnuplot, $plotcmdsfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $proggnuplot\n";
  }
  unlink $plotcmdsfile;
  unlink $plotsignal;
  system($progconvert, "${fullimgsignal}.pbm", $fullimgsignal);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $progconvert\n";
  }
  unlink "${fullimgsignal}.pbm";


  # Plot frequency spectrum
  open(TMPFH, ">$plotspectrum")
    || die "Cannot open temporary outputfile $plotspectrum: $!";
  print TMPFH
    join("\n", map { join(" ", @$_) } @dataspectrum);
  close TMPFH;
  open(GNUPLOT, ">$plotcmdsfile");
  print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullimgspectrum}.pbm'
set xlabel "Frequency (Hz)"
set ylabel "Magnitude spectrum (mean scaled)"
set title "[mean, SNR, SFNR] = [$mean  $snr  $sfnr]"
EOM
  print GNUPLOT <<EOM;
plot [] [0:8] '$plotspectrum' using 1:2 title "" with lines
EOM
  close GNUPLOT;
  system($proggnuplot, $plotcmdsfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $proggnuplot\n";
  }
  unlink $plotcmdsfile;
  unlink $plotspectrum;
  system($progconvert, "${fullimgspectrum}.pbm", $fullimgspectrum);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $progconvert\n";
  }
  unlink "${fullimgspectrum}.pbm";

  # Plot Relative STD
  open(TMPFH, ">$plotrelstd")
    || die "Cannot open temporary outputfile $plotrelstd: $!";
  my %datarelstd = ();
  map { $datarelstd{$_->[0]}->[0] = $_->[1] } @datarelstdcalc;
  map { $datarelstd{$_->[0]}->[1] = $_->[1] } @datarelstdmeas;
  my @relstdkeys = sort { $a <=> $b } keys %datarelstd;
  print TMPFH
    join("\n", map { join(" ", @$_) } map { [$_, @{$datarelstd{$_}}] } @relstdkeys);
  close TMPFH;
  open(GNUPLOT, ">$plotcmdsfile");
  print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullimgrelstd}.pbm'
set xlabel "ROI full width, pixels"
set ylabel "Relative std, %"
set title "rdc = $rdc pixels"
set logscale
EOM
  print GNUPLOT <<EOM;
plot [$relstdkeys[0]:$relstdkeys[$#relstdkeys]] [*:*] '$plotrelstd' using 1:2 title "calc." with lines, '$plotrelstd' using 1:3 title "meas." with linespoints lt 3
EOM
  close GNUPLOT;
  system($proggnuplot, $plotcmdsfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $proggnuplot\n";
  }
  unlink $plotcmdsfile;
  unlink $plotrelstd;
  system($progconvert, "${fullimgrelstd}.pbm", $fullimgrelstd);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $progconvert\n";
  }
  unlink "${fullimgrelstd}.pbm";

  if (@fwhmx) {
  # Plot FWHM-x
    open(TMPFH, ">$plotfwhmx")
      || die "Cannot open temporary outputfile $plotfwhmx: $!";
    print TMPFH
      join("\n", map { join(" ", @$_) } @fwhmx);
    close TMPFH;
    open(GNUPLOT, ">$plotcmdsfile");
    print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullfwhmx}.pbm'
set xlabel "Timepoint"
set ylabel "Smoothness(FWHM) in mm"
set title "Smoothness(FWHM) in mm - X: [min mean max] = [${minfwhmx} ${meanfwhmx} ${maxfwhmx}]"
EOM
    $yrangemin = $meanfwhmx - 2.5;
    $yrangemax = $meanfwhmx + 2.5;
    print GNUPLOT <<EOM;
plot [] [$yrangemin:$yrangemax] '$plotfwhmx' using 1:2 title "" with lines
EOM
    close GNUPLOT;
    system($proggnuplot, $plotcmdsfile);
    if ($? == -1 || $? & 127 || $? >> 8) {
      die "Error running $proggnuplot\n";
    }
    unlink $plotcmdsfile;
    unlink $plotfwhmx;
    system($progconvert, "${fullfwhmx}.pbm", $fullfwhmx);
    if ($? == -1 || $? & 127 || $? >> 8) {
      die "Error running $progconvert\n";
    }
    unlink "${fullfwhmx}.pbm";
  }

  if (@fwhmy) {
  # Plot FWHM-y
    open(TMPFH, ">$plotfwhmy")
      || die "Cannot open temporary outputfile $plotfwhmy: $!";
    print TMPFH
      join("\n", map { join(" ", @$_) } @fwhmy);
    close TMPFH;
    open(GNUPLOT, ">$plotcmdsfile");
    print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullfwhmy}.pbm'
set xlabel "Timepoint"
set ylabel "Smoothness(FWHM) in mm"
set title "Smoothness(FWHM) in mm - Y: [min mean max] = [${minfwhmy} ${meanfwhmy} ${maxfwhmy}]"
EOM
    $yrangemin = $meanfwhmy - 2.5;
    $yrangemax = $meanfwhmy + 2.5;
    print GNUPLOT <<EOM;
plot [] [$yrangemin:$yrangemax] '$plotfwhmy' using 1:2 title "" with lines
EOM
    close GNUPLOT;
    system($proggnuplot, $plotcmdsfile);
    if ($? == -1 || $? & 127 || $? >> 8) {
      die "Error running $proggnuplot\n";
    }
    unlink $plotcmdsfile;
    unlink $plotfwhmy;
    system($progconvert, "${fullfwhmy}.pbm", $fullfwhmy);
    if ($? == -1 || $? & 127 || $? >> 8) {
      die "Error running $progconvert\n";
    }
    unlink "${fullfwhmy}.pbm";
  }

  if (@fwhmz) {
  # Plot FWHM-z
    open(TMPFH, ">$plotfwhmz")
      || die "Cannot open temporary outputfile $plotfwhmz: $!";
    print TMPFH
      join("\n", map { join(" ", @$_) } @fwhmz);
    close TMPFH;
    open(GNUPLOT, ">$plotcmdsfile");
    print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullfwhmz}.pbm'
set xlabel "Timepoint"
set ylabel "Smoothness(FWHM) in mm"
set title "Smoothness(FWHM) in mm - Z: [min mean max] = [${minfwhmz} ${meanfwhmz} ${maxfwhmz}]"
EOM
    $yrangemin = $meanfwhmz - 2.5;
    $yrangemax = $meanfwhmz + 2.5;
    print GNUPLOT <<EOM;
plot [] [$yrangemin:$yrangemax] '$plotfwhmz' using 1:2 title "" with lines
EOM
    close GNUPLOT;
    system($proggnuplot, $plotcmdsfile);
    if ($? == -1 || $? & 127 || $? >> 8) {
      die "Error running $proggnuplot\n";
    }
    unlink $plotcmdsfile;
    unlink $plotfwhmz;
    system($progconvert, "${fullfwhmz}.pbm", $fullfwhmz);
    if ($? == -1 || $? & 127 || $? >> 8) {
      die "Error running $progconvert\n";
    }
    unlink "${fullfwhmz}.pbm";
  }

  # Plot COM
  # First write out values to file
  open(TMPFH, ">$plotcmass")
    || die "Cannot open temporary outputfile $plotcmass: $!";
  print TMPFH
    join("\n", map { join(" ", @$_) } @cmass);
  close TMPFH;
  if (@volreg) {
    open(TMPFH, ">$plotvolreg")
      || die "Cannot open temporary outputfile $plotvolreg: $!";
    print TMPFH
      join("\n", map { join(" ", @$_) } @volreg);
    close TMPFH;
  }

  # Plot COM - X
  open(GNUPLOT, ">$plotcmdsfile");
  print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullcmassx}.pbm'
set xlabel "Timepoint"
set ylabel "Center of Mass in mm"
set title "Center of Mass in mm - X: [maxdisplacement drift] = [${dispcmassx} ${driftcmassx}]"
EOM
  $yrangemin = $meancmassx - 1;
  $yrangemax = $meancmassx + 1;
  if (@volreg) {
    print GNUPLOT <<EOM;
plot [] [$yrangemin:$yrangemax] '$plotcmass' using 1:2 title "cmassx" with lines, '$plotvolreg' using 1:5 title "3dvolreg" with lines lt 3
EOM
  } else {
    print GNUPLOT <<EOM;
plot [] [$yrangemin:$yrangemax] '$plotcmass' using 1:2 title "cmassx" with lines
EOM
  }
  close GNUPLOT;
  system($proggnuplot, $plotcmdsfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $proggnuplot\n";
  }
  unlink $plotcmdsfile;
  system($progconvert, "${fullcmassx}.pbm", $fullcmassx);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $progconvert\n";
  }
  unlink "${fullcmassx}.pbm";

  # Plot COM - Y
  open(GNUPLOT, ">$plotcmdsfile");
  print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullcmassy}.pbm'
set xlabel "Timepoint"
set ylabel "Center of Mass in mm"
set title "Center of Mass in mm - Y: [maxdisplacement drift] = [${dispcmassy} ${driftcmassy}]"
EOM
  $yrangemin = $meancmassy - 1;
  $yrangemax = $meancmassy + 1;
  if (@volreg) {
    print GNUPLOT <<EOM;
plot [] [$yrangemin:$yrangemax] '$plotcmass' using 1:3 title "cmassy" with lines, '$plotvolreg' using 1:6 title "3dvolreg" with lines lt 3
EOM
  } else {
    print GNUPLOT <<EOM;
plot [] [$yrangemin:$yrangemax] '$plotcmass' using 1:3 title "cmassy" with lines
EOM
  }
  close GNUPLOT;
  system($proggnuplot, $plotcmdsfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $proggnuplot\n";
  }
  unlink $plotcmdsfile;
  system($progconvert, "${fullcmassy}.pbm", $fullcmassy);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $progconvert\n";
  }
  unlink "${fullcmassy}.pbm";

  # Plot COM - Z
  open(GNUPLOT, ">$plotcmdsfile");
  print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullcmassz}.pbm'
set xlabel "Timepoint"
set ylabel "Center of Mass in mm"
set title "Center of Mass in mm - Z: [maxdisplacement drift] = [${dispcmassz} ${driftcmassz}]"
EOM
  $yrangemin = $meancmassz - 1;
  $yrangemax = $meancmassz + 1;
  if (@volreg) {
    print GNUPLOT <<EOM;
plot [] [$yrangemin:$yrangemax] '$plotcmass' using 1:4 title "cmassz" with lines, '$plotvolreg' using 1:7 title "3dvolreg" with lines lt 3
EOM
  } else {
    print GNUPLOT <<EOM;
plot [] [$yrangemin:$yrangemax] '$plotcmass' using 1:4 title "cmassz" with lines
EOM
  }
  close GNUPLOT;
  system($proggnuplot, $plotcmdsfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $proggnuplot\n";
  }
  unlink $plotcmdsfile;
  system($progconvert, "${fullcmassz}.pbm", $fullcmassz);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $progconvert\n";
  }
  unlink "${fullcmassz}.pbm";

  # Clean up temporary COM plot file
  unlink $plotcmass;
  unlink $plotvolreg;

  if (@ghost) {
  # Plot Ghost metric
    open(TMPFH, ">$plotghost")
      || die "Cannot open temporary outputfile $plotghost: $!";
    print TMPFH
      join("\n", map { join(" ", @$_) } @ghost);
    close TMPFH;
    open(GNUPLOT, ">$plotcmdsfile");
    print GNUPLOT <<EOM;
set terminal pbm small color
set size .9,.6
set output '${fullghost}.pbm'
set xlabel "Timepoint"
set ylabel "Ghost mean percentage"
set title "Mean of ghost voxels as % of non-ghost [masked] mean\\n(ghostmean, brightghostmean) = ($meanghost, $meanbrightghost)\\n(lower is better)"
EOM
    print GNUPLOT <<EOM;
plot '$plotghost' using 1:3 title "top 10% ghost" with lines, '$plotghost' using 1:2 title "all ghost" with lines lt 3
EOM
    close GNUPLOT;
    system($proggnuplot, $plotcmdsfile);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $proggnuplot\n";
  }
    unlink $plotcmdsfile;
    unlink $plotghost;
    system($progconvert, "${fullghost}.pbm", $fullghost);
  if ($? == -1 || $? & 127 || $? >> 8) {
    die "Error running $progconvert\n";
  }
    unlink "${fullghost}.pbm";
  }

  # create images
  my @fullgendatappm = @fullgendatabxh;
  map { s/\.bxh$/.ppm/ } @fullgendatappm;
  my @fullgencbarppm = @fullgendatabxh;
  map { s/\.bxh$/_cbar.ppm/ } @fullgencbarppm;
  my @fullgendatajpg = @fullgendatabxh;
  map { s/\.bxh$/.jpg/ } @fullgendatajpg;
  my @fullgencbarjpg = @fullgendatabxh;
  map { s/\.bxh$/_cbar.jpg/ } @fullgencbarjpg;
  my @gendatajpg =  map {
    my ($tmpvol, $tmpdirs, $tmpfile) = File::Spec->splitpath($_);
    $tmpfile
  } @fullgendatajpg;
  my @gencbarjpg =  map {
    my ($tmpvol, $tmpdirs, $tmpfile) = File::Spec->splitpath($_);
    $tmpfile
  } @fullgencbarjpg;
  my @genmins = ();
  my @genmaxs = ();
  foreach my $ind (0..$#fullgendatabxh) {
    my $cmd = '';
    my $minmaxoutput = '';
    $cmd = "$progminmax " . $fullgendatabxh[$ind];
    $minmaxoutput = `$cmd`;
    (($genmins[$#genmins+1], $genmaxs[$#genmaxs+1]) =
     ($minmaxoutput =~ m/^min=(.*), max=(.*)$/)) ||
       die "Error parsing output of fmriqa_minmax:\n$minmaxoutput\n";
  }
  my @gencbarmins = @genmins;
  my @gencbarmaxs = @genmaxs;
  # guard against outliers messing up the displayed min/max range
  foreach my $ind (0..$#fullgendatabxh) {
    my $totalvals = undef;
    my $lastgencbarmin = undef;
    my $lastgencbarmax = undef;
    my $laststddev = undef;
    while (1) {
      my $minmaxopts = '';
      if (defined($lastgencbarmin) && defined($lastgencbarmax)) {
	# make sure we get all intended values
	my $testmin = $lastgencbarmin - (0.1 * $laststddev);
	my $testmax = $lastgencbarmax + (0.1 * $laststddev);
	$minmaxopts = "--ge $testmin --le $testmax";
      }
      my @countoutput = `$progcount $minmaxopts --histogram $fullgendatabxh[$ind]`;
      $countoutput[1] =~ s/^#\s*//;
      $countoutput[2] =~ s/^\s*//;
      my @labels = split(/\s+/, $countoutput[1]);
      my @values = split(/\s+/, $countoutput[2]);
      my @histo = ();
      for my $labelind (0..$#labels) {
	my ($start, $end) = ($labels[$labelind] =~ m/^(.*)<=?x<=?(.*)/);
	if ($start eq '-infinity') {
	  if (defined($lastgencbarmin)) {
	    $start = $lastgencbarmin;
	  } else {
	    $start = $genmins[$ind];
	  }
	}
	if ($end eq 'infinity') {
	  if (defined($lastgencbarmax)) {
	    $end = $lastgencbarmax;
	  } else {
	    $end = $genmaxs[$ind];
	  }
	}
	push @histo, [ $values[$labelind], $start, $end ];
      }
      if (!defined($totalvals)) {
	$totalvals = 0;
	map { $totalvals += $_->[0] } @histo;
      }
      # gather contiguous populated (or zero) buckets into groups
      {
	my $hind = 0;
	while ($hind < scalar(@histo) - 1) {
	  my ($numvals, $start, $end) = @{$histo[$hind]};
	  my ($numvals2, $start2, $end2) = @{$histo[$hind+1]};
	  if ($numvals > 0 && $numvals2 > 0) {
	    splice @histo, $hind, 2, [$numvals+$numvals2, $start, $end2];
	  } elsif ($numvals == 0 && $numvals2 == 0) {
	    splice @histo, $hind, 2, [0, $start, $end2];
	  } else {
	    $hind++;
	  }
	}
      }
      # remove zero-size buckets on either end
      while ($histo[0]->[0] == 0) {
	shift @histo;
      }
      while ($histo[$#histo]->[0] == 0) {
	pop @histo;
      }
      next if (scalar(@histo) == 0);
      # remove any populated "edge" buckets that contain less than 5% of the
      # total number of values and which are more than 3 stddevs from the next
      # populated bucket
      my $stddev = 0;
      if (scalar(@histo) >= 3) {
	$stddev = $histo[1]->[2] - $histo[1]->[1];
      }
      while (scalar(@histo) >= 3) {
	die "Internal error in histogram computation!\n" if $histo[1]->[0] != 0;
	my $popvalsleft = $histo[0]->[0];
	my $edgeleft1 = $histo[0]->[2];
	my $edgeleft2 = $histo[2]->[2];
	my $popvalsright = $histo[$#histo]->[0];
	my $edgeright1 = $histo[$#histo-2]->[2];
	my $edgeright2 = $histo[$#histo]->[2];
	if ($popvalsleft < 0.05 * $totalvals &&
	    ($edgeleft2 - $edgeleft1) >= 3 * $stddev) {
	  shift @histo;
	  shift @histo;
	} elsif ($popvalsright < 0.05 * $totalvals &&
		 ($edgeright2 - $edgeright1) >= 3 * $stddev) {
	  pop @histo;
	  pop @histo;
	} else {
	  last;
	}
      }
      # redo the count with the new min/max to get real min and max
      # of core data
      # make sure we get all intended values
      my $testmin = $histo[0]->[1] - (0.1 * $stddev);
      my $testmax = $histo[$#histo]->[2] + (0.1 * $stddev);
      @countoutput = `$progcount --ge $testmin --le $testmax --histogram $fullgendatabxh[$ind]`;
      $countoutput[1] =~ s/^#\s*//;
      @labels = split(/\s+/, $countoutput[1]);
      ($gencbarmins[$ind],) = ($labels[0] =~ m/^(.*)<=?x<=?.*/);
      ($gencbarmaxs[$ind],) = ($labels[$#labels] =~ m/^.*<=?x<=?(.*)/);
      if ($gencbarmins[$ind] eq '-infinity') {
	$gencbarmins[$ind] = $histo[0]->[1];
      }
      if ($gencbarmaxs[$ind] eq 'infinity') {
	$gencbarmaxs[$ind] = $histo[$#histo]->[2];
      }

      # skip out if the min/max has stabilized
      if (defined($lastgencbarmin) && defined($lastgencbarmax)) {
	if ($lastgencbarmin == $gencbarmins[$ind] &&
	    $lastgencbarmax == $gencbarmaxs[$ind]) {
	  last;
	}
      }
      # otherwise, loop around again
      $lastgencbarmin = $gencbarmins[$ind];
      $lastgencbarmax = $gencbarmaxs[$ind];
      $laststddev = $stddev;
    }
  }
  foreach my $ind (0..$#fullgendatabxh) {
    unlink $fullgendatappm[$ind] if (-e $fullgendatappm[$ind]);
    unlink $fullgencbarppm[$ind] if (-e $fullgencbarppm[$ind]);
  }
  foreach my $ind (0..$#fullgendatabxh) {
    system($progbxh2ppm, "--colorbar=$fullgencbarppm[$ind]", "--barwidth=16", "--barlength=384", "--minval=$gencbarmins[$ind]", "--maxval=$gencbarmaxs[$ind]", $fullgendatabxh[$ind], $fullgendatappm[$ind]);
    if ($? == -1 || $? & 127 || $? >> 8) {
      die "Error running $progbxh2ppm\n";
    }
    system($progconvert, "-geometry", "256x256", $fullgendatappm[$ind], $fullgendatajpg[$ind]);
    if ($? == -1 || $? & 127 || $? >> 8) {
      die "Error running $progconvert\n";
    }
    system($progconvert, $fullgencbarppm[$ind], $fullgencbarjpg[$ind]);
    if ($? == -1 || $? & 127 || $? >> 8) {
      die "Error running $progconvert\n";
    }
  }
  foreach my $ind (0..$#fullgendatabxh) {
    unlink $fullgendatappm[$ind];
    unlink $fullgencbarppm[$ind];
  }

  unshift @acqdata, ['gap', join('x', @gap)];
  unshift @acqdata, ['spacing', join('x', @spacing)];
  unshift @acqdata, ['dimensions', join('x', @dimensions)];
  my $acqdatahtml = join("\n", map {
    my ($name, $value) = @$_;
    "<tr><td>$name</td><td>$value</td></tr>"
  } @acqdata);

  # create web page
  my $commenthtml = "";
  if (defined($opt_comment)) {
    $commenthtml = "<p>Comment: $opt_comment</p>";
  }
  open(HTMLFH, ">$outputhtml")
    || die "Cannot open outputfile $outputhtml: $!";
  my $fwhmhtml = '';
  if (@fwhmx) {
    $fwhmhtml = <<EOM;
    <p><img src="$imgfwhmx" /></p>
    <p><img src="$imgfwhmy" /></p>
    <p><img src="$imgfwhmz" /></p>
EOM
  }
  print HTMLFH <<EOM;
<html>
  <head>
    <title>Phantom QA results for $inputpath, slice $slice, timepoints $timepoints</title>
    <style type="text/css"><!--
      table.bordered tr td {border: 1px solid gray;}
      body {font-family: sans-serif;}
      .colorbar {background-color: #dddddd;}
      .cbarmin {font-size: smaller; text-align: left;}
      .cbarmax {font-size: smaller; text-align: right;}
      .imgmin {font-size: smaller;}
      .imgmax {font-size: smaller;}
    --></style>
  </head>
  <body>
    <h1>Phantom QA results for $inputpath, slice $slice</h1>
$commenthtml
    <p><img src="$imgsignal" /></p>
    <p><img src="$imgspectrum" /></p>
    <p><img src="$imgrelstd" /></p>
$fwhmhtml
    <p><img src="$imgcmassx" /></p>
    <p><img src="$imgcmassy" /></p>
    <p><img src="$imgcmassz" /></p>
EOM
  if (@ghost) {
    print HTMLFH <<EOM;
    <p><img src="$imgghost" /></p>
EOM
  }

  my @genlabels =
    (
     "Odd-even difference image",
     "Mean image",
     "Standard Deviation image",
     "SFNR image",
    );
  foreach my $ind (0..$#fullgendatabxh) {
    print HTMLFH <<EOM;
    <hr />
    <p><font size="+2"><b>$genlabels[$ind]</b></font></p>
    <table>
     <tr class="colorbar">
      <td class="cbarmin">$gencbarmins[$ind]</td>
      <td class="cbarmax">$gencbarmaxs[$ind]</td>
     </tr>
     <tr class="colorbar">
      <td colspan="2">
       <img alt="Colorbar for $genlabels[$ind]" src="$gencbarjpg[$ind]" />
      </td>
     </tr>
    </table>
    <table>
     <tr>
      <td>
       <span class="imgmin">image min: $genmins[$ind],</span>
       <span class="imgmax">image max: $genmaxs[$ind]</span>
      </td>
     </tr>
     <tr>
      <td><img alt="$genlabels[$ind]" src="$gendatajpg[$ind]" /></td>
     </tr>
    </table>
EOM

  }

  print HTMLFH <<EOM;
    <hr />
    <p><font size="+1"><b>Acquisition parameters</b></font></p>
    <table border="1">
$acqdatahtml
    </table>
EOM

  print HTMLFH <<EOM;
  </body>
</html>
EOM
  close HTMLFH;

}

# $Log: not supported by cvs2svn $
# Revision 1.62  2009/01/21 19:58:16  gadde
# Add drift of fit.
#
# Revision 1.61  2009/01/15 20:55:17  gadde
# New organization of data read functions to allow for reading of non-bxh data directly by most tools
#
# Revision 1.60  2008/10/20 16:33:37  gadde
# Make AFNI stuff optional.
#
# Revision 1.59  2008/10/17 16:22:24  gadde
# Fix variable name
#
# Revision 1.58  2008/10/17 00:52:42  gadde
# Remove non-ghost SNR code for release
#
# Revision 1.57  2008/10/06 18:18:36  gadde
# Add --roisize and --version options.
# Add XML output of summary measures.
#
# Revision 1.56  2008/07/15 15:50:36  gadde
# Add missing module import.
#
# Revision 1.55  2008/04/15 17:29:11  gadde
# Fix autoscaling.
# Add some diagnostic messages when convert and gnuplot fail.
#
# Revision 1.54  2007/12/19 21:57:45  gadde
# Fix for new output of fmriqa_count.
#
# Revision 1.53  2007/04/02 19:13:46  gadde
# Print out dimensions.
#
# Revision 1.52  2007/03/03 17:00:04  gadde
# Add acquisition data to output.
#
# Revision 1.51  2007/02/26 20:18:12  gadde
# Fix comment.
#
# Revision 1.50  2007/01/29 17:31:08  gadde
# Uncomment an unlink.
#
# Revision 1.49  2007/01/26 21:23:10  gadde
# Put back an unlink removed in last comment.
#
# Revision 1.48  2007/01/26 20:45:44  gadde
# Fix "interpolation" of FWHM at beginning of time series.
#
# Revision 1.47  2007/01/23 18:08:30  gadde
# Deal better with data that does not have ghosts (spirals).
#
# Revision 1.46  2007/01/22 14:41:30  gadde
# Add 3dvolreg output to center of mass plots.
#
# Revision 1.45  2007/01/18 22:14:42  gadde
# Fix min/max cbar calculations (don't lose edge cases).
#
# Revision 1.44  2007/01/18 20:25:17  gadde
# Fix --version in perl scripts to show package version rather than CVS version.
#
# Revision 1.43  2007/01/18 20:06:18  gadde
# Fix colorbar scales for images to ignore outliers.
#
# Revision 1.42  2007/01/16 19:03:36  gadde
# Switch order of plotting ghost lines.
#
# Revision 1.41  2007/01/15 20:15:05  gadde
# Fix reported dimensions.
#
# Revision 1.40  2007/01/15 20:12:22  gadde
# Add dimensions to acq params and adjust ghost calculations.
#
# Revision 1.39  2007/01/12 16:50:33  gadde
# Add optional comment.
#
# Revision 1.38  2007/01/12 16:26:18  gadde
# Change range of smoothness plots.
#
# Revision 1.37  2007/01/12 16:23:30  gadde
# Add ghost ratio.
#
# Revision 1.36  2007/01/11 21:15:41  gadde
# Add acquisition data to output.
#
# Revision 1.35  2007/01/11 20:15:10  gadde
# Add smoothness, COM plots
#
# Revision 1.34  2006/09/22 15:23:31  gadde
# Documentation and help updates
#
# Revision 1.33  2006/04/12 17:29:15  gadde
# Win32 fixes
#
# Revision 1.32  2006/03/23 21:39:44  gadde
# Make sure lib directory is found before importing modules.
#
# Revision 1.31  2006/03/23 21:19:04  gadde
# Fix for gnuplot installations that don't have png support.
#
# Revision 1.30  2006/03/23 21:04:37  gadde
# Fix for older version of Perl.
#
# Revision 1.29  2006/03/23 18:35:51  gadde
# Not using File::Path anymore.
#
# Revision 1.28  2006/03/23 18:27:24  gadde
# Fixes to be compatible with older versions of Perl.
#
# Revision 1.27  2005/09/20 18:37:52  gadde
# Updates to versioning, help and documentation, and dependency checking
#
# Revision 1.26  2005/09/19 16:31:53  gadde
# Documentation and help message updates.
#
# Revision 1.25  2005/01/10 17:59:01  gadde
# Don't cry if output directory exists and if --overwrite is specified.
#
# Revision 1.24  2004/12/30 16:23:29  gadde
# Don't provide default timeselect (use fmriqa_phantomqa's default).
#
# Revision 1.23  2004/09/20 12:38:01  gadde
# Add CVS log.
#
