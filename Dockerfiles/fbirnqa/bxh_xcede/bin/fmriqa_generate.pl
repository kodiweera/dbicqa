#!/usr/bin/env perl

# Run several QA measures on a given set of data and generate a directory
# with a web page that displays them all.

use strict;

use FindBin;
use lib "$FindBin::Bin";

use File::Copy;
use File::Spec;
use File::Temp qw/ tempfile /;
use Config;

use POSIX qw(ceil floor);

use File::Which;

use IPC::Open3;

use MIME::Base64 qw(encode_base64);

use JSON::PP;

if ($^O eq 'darwin') {
  $ENV{'DYLD_LIBRARY_PATH'} = "$FindBin::Bin/../lib";
}

my ($progvol, $progdirs, $progfile) = File::Spec->splitpath($0);
my @baseprogdirs = File::Spec->splitdir($progdirs);
if ($baseprogdirs[$#baseprogdirs] eq '') {
  pop @baseprogdirs;
}
pop @baseprogdirs;
$ENV{'MAGICK_HOME'} = File::Spec->catpath($progvol, File::Spec->catdir(@baseprogdirs), '');
$ENV{'FONTCONFIG_PATH'} = File::Spec->catpath($progvol, File::Spec->catdir(@baseprogdirs, 'etc', 'fonts'), '');

use BXHPerlUtils;
use fmriqa_utils;

if ($^O eq 'MSWin32') {
  use File::DosGlob;
  @ARGV = map {
    my @g = File::DosGlob::glob($_) if /[*?]/;
    @g ? @g : $_;
  } @ARGV;
  1;
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

sub basepath_labels {
  my @filelist = @_;

  my $basepath = ''; #default
  my @filelabels = @filelist; #default

  my ($basevol, $basedir, $basefile) = File::Spec->splitpath($filelist[0]);
  my @basedirs = File::Spec->splitdir($basedir);
  my $basepathlen = scalar(@basedirs); # number of common dir segments (-1 means volume doesn't match)
  my $maxnumdirs = 0;
  for my $arg (@filelist) {
    my ($argvol, $argdir, $argfile) = File::Spec->splitpath($arg);
    my @argdirs = File::Spec->splitdir($argdir);
    if (scalar(@argdirs) > $maxnumdirs) {
      $maxnumdirs = scalar(@argdirs);
    }
    if ($basevol ne $argvol) {
      $basepathlen = -1;
      last;
    }
    my $maxind = $#basedirs;
    $maxind = $#argdirs if ($#argdirs < $maxind);
    for ($basepathlen = 0; $basepathlen <= $maxind; $basepathlen++) {
      last if ($basedirs[$basepathlen] ne $argdirs[$basepathlen]);
    }
    last if ($basepathlen == 0);
  }
  if ($basepathlen >= 0) {
    # find smallest label that is unique for every file
    my $labelend = $basepathlen;
    while ($labelend < $maxnumdirs) {
      my @matchlabels = map {
	my ($margvol, $margdir, $margfile) = File::Spec->splitpath($_);
	my @margdirs = File::Spec->splitdir($margdir);
	my $mlabelend = $labelend;
	if ($mlabelend > $#margdirs) { $mlabelend = $#margdirs }
	File::Spec->catdir(@margdirs[$basepathlen..$labelend]);
      } @filelist;
      if (grep { my $curlabel = $_; (grep { $_ eq $curlabel } @matchlabels) > 1 } @matchlabels) {
	# found a match -- go to next dir component
	$labelend++;
	next;
      } else {
	last;
      }
    }
    $basepath = File::Spec->catpath($basevol, File::Spec->catdir(@basedirs[0..$basepathlen-1]), '');
    @filelabels = map {
      my ($argvol, $argdir, $argfile) = File::Spec->splitpath($_);
      my @argdirs = File::Spec->splitdir($argdir);
      if ($basepathlen == scalar(@argdirs)) {
	$argfile;
      } else {
	my $mlabelend = $labelend;
	push @argdirs, $argfile;
	if ($mlabelend > $#argdirs) {
	  $mlabelend = $#argdirs;
	}
	File::Spec->catdir(@argdirs[$basepathlen..$labelend]);
      }
    } @filelist;
  }
  map { s%[/\\]%_%g } @filelabels;
  return $basepath, @filelabels;
}

sub logdie {
  my $logfh = shift @_;
  print $logfh @_;
  die @_;
}

sub log_cmd {
  my $logfh = shift @_;
  my @escapedcmd = quotecmd(@_);
  print $logfh join(" ", @escapedcmd), "\n";
}

sub run_and_log_cmd {
  my $logfh = shift @_;
  log_cmd($logfh, @_);
  open(FROMNULL, '<', File::Spec->devnull());
  my $pid = open3('<&FROMNULL', '>&STDOUT', \*ERRFH, @_)
      || logdie($logfh, "Error running $_[0]: $!");
  my @errs = <ERRFH>;
  close ERRFH;
  if (scalar(@errs) > 0) {
    print $logfh "> ", join("> ", @errs);
    print STDERR join('', @errs);
    if (substr($errs[$#errs], -1, 1) ne "\n") {
      print $logfh "\n";
      print STDERR "\n";
    }
  }
  waitpid $pid, 0;
  close FROMNULL;
  return $?;
}

our $opt_verbose = 0;

sub log_stderr {
  if ($opt_verbose) {
    print STDERR @_;
  }
}

sub log_msg {
  my $logfh = shift @_;
  if ($opt_verbose) {
    print STDERR @_;
  }
  print $logfh @_;
}

sub log_msg_nostderr {
  my $logfh = shift @_;
  print $logfh @_;
}

my $logfh = undef;

sub writeXMLEventsFile {
  my ($fulleventfn, $tspacing, $tsize, $scalarstats, $arraystats) = @_;
  my $json = JSON::PP->new->allow_nonref;
  open(EFH, ">$fulleventfn")
    || logdie($logfh, "Cannot open output file '${fulleventfn}' for writing\n");
  my $header = "<?xml version=\"1.0\" ?>\n\n<events>\n";
  print EFH $header;
  my $rundur = $tspacing * $tsize;
  my $wholerunvalues = $scalarstats;
  print EFH <<EOM;
  <!-- This file stores statistics that are calculated from this run's data only -->
  <event>
    <!-- This element stores values that apply to the whole run -->
    <onset>0</onset>
    <duration>$rundur</duration>
EOM
  for my $name (sort { $a cmp $b } keys %$wholerunvalues) {
    my $value = $wholerunvalues->{$name};
    if (ref $value) {
      $value = $json->encode($value);
    }
    $value =~ s/\&/\&amp;/g;
    $value =~ s/</\&lt;/g;
    $value =~ s/>/\&gt;/g;
    print EFH "    <value name=\"$name\">${value}</value>\n";
  }
  print EFH <<EOM;
  </event>
  <!-- Each of the following events represents one volume -->
EOM
  my @volstatnames = grep { $arraystats->{$_}->{'xunits'} eq 'vols' } keys %$arraystats;
  for (my $volnum = 0; $volnum < $tsize; $volnum++) {
    my $onset = $volnum * $tspacing;
    my $duration = $tspacing;
    print EFH <<EOM;
  <event>
    <onset>$onset</onset>
    <duration>$duration</duration>
EOM
    for my $name (sort { $a cmp $b } @volstatnames) {
      my $value = $arraystats->{$name}->{'data'}->[$volnum]->[1];
      if (ref $value) {
	$value = $json->encode($value);
      }
      print EFH <<EOM;
    <value name="$name">$value</value>
EOM
    }
    print EFH <<EOM;
  </event>
EOM
  }
  print EFH <<EOM;
</events>
EOM
  close EFH;
}

#############################
# MAIN SCRIPT STARTS HERE
#############################

my $opt_overwrite = 0;
my $opt_defergroup = 0;
my $opt_grouponly = 0;
my @opt_filelabels = ();
my @opt_filemasks = ();
my $opt_deletestddev = 0;
my $opt_deletemean = 0;
my $opt_deleteslicevar = 0;
my $opt_deletesfnr = 0;
my $opt_deletemask = 0;
my $opt_timeselect = undef;
my $opt_forcetr = 0;
my $opt_standardizedetrendedmeans = 0;
my $opt_qalabel = undef;
my $opt_zthresh1 = 3;
my $opt_zthresh2 = 4;
my $opt_percthresh1 = 1;
my $opt_percthresh2 = 2;
my $opt_indexjs = 0;
my $opt_debugjs = 0;
my @opt_showhide = ();
my @opt_calc = ();

my $usage = <<EOM;
Usage:
  fmriqa_generate.pl [--overwrite] [--verbose] \
                     [--deletestddev] \
                     [--deletemean] [--deleteslicevar] [--deletesfnr] \
                     [--deletemask] [--forcetr TR] \
                     [ --zthresh1 NUM ] [ --zthresh2 NUM ] \
                     [ --percthresh1 NUM ] [ --percthresh2 NUM ] \
                     [ --qalabel LABEL ] [--standardizedetrendedmeans] \
                     [ --show NAMES ] [ --hide NAMES ] \
                     [ --nocalc NAMES ] [ --calc NAMES ] \
                     [ --timeselect STR ] \
                     [ --indexjs ] [ --indexnonjs ] [ --debugjs ]
                     [ --defergroup ] \
                     [ --grouponly ] \
                     [ --filelabel LABEL1 ] \
                     [ --filemask MASK1 ] \
                     inputfile1 \
                     [ --filelabel LABEL2 ] \
                     [ --filemask MASK2 ] \
                     inputfile2 \
                     ... \
                     outputdir

Given 4-D input BXH- or XCEDE-wrapped image data, this program produces
an HTML page with various useful QA plots, images, and measures, such as
mean intensity per volume, center of mass per volume, per-slice variation,
images of mean and standard deviation (across time), and others.
Many of the QA measures are also placed in an XML events file for use by
other programs.  The index.html file (which should be readable by most
Web browsers) and all other files will be put in outputdir.  Various
BXH- or XCEDE- wrapped images will be written during the process -- to
delete these, use the --deleteXXXX options (the JPEG versions of these
images displayed in the web page images will still remain).

--filelabel LABEL
    Normally, output files corresponding to each input file are named
    with a label derived from the input file name.  These labels are
    guaranteed to be unique within one run of this tool, and so if you
    specify all inputs on the command line, then you are safe.
    However, if you wish to run input files through the tool
    separately, then using --filelabel will explicitly override the
    automatically-created label with the given label.  You should
    specify this once for each input file.
--filemask IMAGE
    For metrics calculated on masked data, this specifies the mask to
    be used (rather than using bxh_brainmask).  You should specify this
    option once for each input file.
--indexjs
    If specified, use the Javascript-based HTML page as main report page
    (i.e. index.html).  The non-Javascript page will be written to
    index-nonjs.html.
--indexnonjs
    If specified, use the non-Javascript-based HTML page as main report
    page (i.e. index.html).  The Javascript-based page will be written to
    index-js.html.  This is currently the default.
--debugjs
    If specified, non-minified (i.e. readable) Javascript code will be
    used, if available.
--defergroup
    If specified, group statistics (i.e. those that depend on data
    from all runs) are not computed.  The group statistics can be
    calculated later by using the --grouponly option.
--grouponly
    If specified, only calculates group statistics from already
    calculated per-run statistics.  For this to work, the tool needs
    to know the labels used for output files when running the
    individual inputs.  If this tool is run with exactly the same list
    of input files under --defergroup and --grouponly, then it should
    be able to compute the same labels.  Otherwise using the
    --filelabel options in both stages is useful.
--timeselect STR
    Comma-separated list of timepoints to use (first timepoint is 0).
    Any timepoint can be a contiguous range, specified as two numbers
    separated by a colon, i.e. 'START:END'.  An empty END implies the
    last timepoint.  The default step of 1 (one) in ranges can be
    changed using 'START:STEP:END', which is equivalent to
    'START,START+STEP,START+(2*STEP),...,END'.
--forcetr TR
    This specifies the TR (in seconds) for the data (and overrides the TR
    in the image data, if any).
--zthresh1 NUM
--zthresh2 NUM
--percthresh1 NUM
--percthresh2 NUM
    A count of images that exceed a given threshold is performed for some
    metrics.  These options specify the two available thresholds for
    absolute z-score based measurements (i.e. how many standard deviations
    from the mean) and percent-based measurements (i.e. how many percent from
    the mean).  Defaults are 3 and 4 for the z-score thresholds and 1 and 2
    for the percent thresholds.
--qalabel LABEL
    This specifies a label to be used in the title of the HTML report.
    Default is to use a string derived from the input file name(s).
--filelabel LABEL
    Output files corresponding to individual inputs will be named with
    a label unique to the group of input filenames.  To explicitly
    specify these labels, use the --filelabel option.  These are
    especially useful to avoid name collision if using the
    --defergroup option to run QA separately on individual runs and
    then to use the --grouponly option to do calculation of group
    statistics.
--standardizedetrendedmeans
    If specified, metrics for detrended data are shifted so that their
    means are the same.
--show NAMES
--hide NAMES
--calc NAMES
--nocalc NAMES
    The --show and --hide options turn on or off the automatic display of
    the specified plots.  Hidden plots are still available in the HTML file,
    and require only clicking on a checkbox to display them.  The --calc and
    --nocalc options enable or disable the calculation of the data used in
    the specified plots (uncalculated data will therefore not be available
    for display).  These are used to override the default behavior, which
    is to calculate and show all data.  However, if only --calc options exist
    (and no --nocalc options), then only those specified plots are calculated.
    Likewise, if only --show options exist (and no --hide options), then only
    those specified plots are automatically displayed.
    Multiple plot names can be specified in the same option by separating them
    with commas, or can be specified in separate --show or --hide options.
    The available basic plot names are:
      volumemeans, maskedvolumemeans,
      meandiffvolumemeans, maskedtdiffvolumemeans,
      cmassx, cmassy, cmassz, maskedcmassx, maskedcmassy, maskedcmassz,
      spectrummean, spectrummax,
      slicevar, 3dToutcount, 3dFWHMx-X, 3dFWHMx-Y, 3dFWHMx-Z,
      meanstddevsfnr
    The following additional plot names are convenient shorthands for
    groups of the above plots:
      all, unmasked, masked, maskeddetrended, cmass, maskedcmass, fwhm,
      spectrum
    These names do not involve plots, but calculation can be disabled/enabled
    with nocalc/calc:
      clipped
    If conflicting options are provided for any particular plot, then the
    last relevant option is used.  Thus, you can use
      --nocalc all --calc 3dToutcount
    to disable calculation of all but the voxel outlier plots.
EOM

my @tempfiles = ();

my @origARGV = @ARGV;
my @oldARGV = @ARGV;
@ARGV = ();
while (scalar(@oldARGV)) {
  my $arg = shift @oldARGV;
  if ($arg =~ /^--$/) {
    push @ARGV, @oldARGV;
    last;
  }
  if ($arg !~ /^--/) {
    push @ARGV, $arg;
    next;
  }
  my ($opt, undef, $opteq, $optarg) = ($arg =~ /^--([^=]+)((=)?(.*))$/);
  if (defined($opteq)) {
    unshift @oldARGV, $optarg;
  }
  if (scalar(@oldARGV) > 0) {
    $optarg = $oldARGV[0]; # in case option takes argument
  }
  if ($opt eq 'help') {
    print STDERR $usage;
    exit(-1);
  } elsif ($opt eq 'overwrite' && !defined($opteq)) {
    $opt_overwrite++;
    next;
  } elsif ($opt eq 'indexjs' && !defined($opteq)) {
    $opt_indexjs = 1;
    next;
  } elsif ($opt eq 'indexnonjs' && !defined($opteq)) {
    $opt_indexjs = 0;
    next;
  } elsif ($opt eq 'debugjs' && !defined($opteq)) {
    $opt_debugjs = 1;
    next;
  } elsif ($opt eq 'defergroup' && !defined($opteq)) {
    $opt_defergroup++;
    next;
  } elsif ($opt eq 'grouponly' && !defined($opteq)) {
    $opt_grouponly++;
    next;
  } elsif ($opt eq 'filelabel' && defined($optarg)) {
    shift @oldARGV;
    push @opt_filelabels, $optarg;
    next;
  } elsif ($opt eq 'filemask' && defined($optarg)) {
    shift @oldARGV;
    push @opt_filemasks, $optarg;
    next;
  } elsif ($opt eq 'verbose' && !defined($opteq)) {
    $opt_verbose++;
    next;
  } elsif ($opt eq 'deletestddev' && !defined($opteq)) {
    $opt_deletestddev++;
    next;
  } elsif ($opt eq 'deletemean' && !defined($opteq)) {
    $opt_deletemean++;
    next;
  } elsif ($opt eq 'deleteslicevar' && !defined($opteq)) {
    $opt_deleteslicevar++;
    next;
  } elsif ($opt eq 'deletesfnr' && !defined($opteq)) {
    $opt_deletesfnr++;
    next;
  } elsif ($opt eq 'deletemask' && !defined($opteq)) {
    $opt_deletemask++;
    next;
  } elsif ($opt eq 'standardizedetrendedmeans' && !defined($opteq)) {
    $opt_standardizedetrendedmeans = 1;
    next;
  } elsif ($opt eq 'version' && !defined($opteq)) {
    print "Version: " . 'BXH/XCEDE utilities (1.11.14)' . "\n";
    exit 0;
  } elsif ($opt eq 'timeselect' && defined($optarg)) {
    shift @oldARGV;
    $opt_timeselect = $optarg;
  } elsif ($opt eq 'forcetr' && defined($optarg)) {
    shift @oldARGV;
    $opt_forcetr = $optarg;
  } elsif ($opt eq 'qalabel' && defined($optarg)) {
    shift @oldARGV;
    $opt_qalabel = $optarg;
  } elsif ($opt eq 'zthresh1' && defined($optarg)) {
    shift @oldARGV;
    $opt_zthresh1 = $optarg;
  } elsif ($opt eq 'zthresh2' && defined($optarg)) {
    shift @oldARGV;
    $opt_zthresh2 = $optarg;
  } elsif ($opt eq 'percthresh1' && defined($optarg)) {
    shift @oldARGV;
    $opt_percthresh1 = $optarg;
  } elsif ($opt eq 'percthresh2' && defined($optarg)) {
    shift @oldARGV;
    $opt_percthresh2 = $optarg;
  } elsif ($opt eq 'show' && defined($optarg)) {
    shift @oldARGV;
    push @opt_showhide, map { "+$_" } split(/,/, $optarg);
  } elsif ($opt eq 'hide' && defined($optarg)) {
    shift @oldARGV;
    push @opt_showhide, map { "-$_" } split(/,/, $optarg);
  } elsif ($opt eq 'calc' && defined($optarg)) {
    shift @oldARGV;
    push @opt_calc, map { "+$_" } split(/,/, $optarg);
  } elsif ($opt eq 'nocalc' && defined($optarg)) {
    shift @oldARGV;
    push @opt_calc, map { "-$_" } split(/,/, $optarg);
  } else {
    die "Unrecognized option '$opt' (or missing argument?)\nUse --help for options.\n";
  }
}

if (scalar(@ARGV) < 2) {
  die $usage;
}
my $outputpath = pop @ARGV;

my @missingfiles = grep { ! -f $_ } @ARGV;
if (scalar(@missingfiles)) {
  die "Error: following input files do not exist:\n" . join("\n", @missingfiles) . "\n";
}

if (-e $outputpath && !$opt_overwrite && !$opt_grouponly) {
  die "Output directory $outputpath exists, aborting...";
}

if (scalar(@opt_filelabels) > 0 && scalar(@opt_filelabels) != scalar(@ARGV)) {
  die "ERROR: the number of --filelabel options ", scalar(@opt_filelabels), " does not match the number of input files ", scalar(@ARGV);
}
if (scalar(@opt_filemasks) > 0 && scalar(@opt_filemasks) != scalar(@ARGV)) {
  die "ERROR: the number of --filemask options ", scalar(@opt_filemasks), " does not match the number of input files ", scalar(@ARGV);
}

# find all needed executables
my $proggnuplot;
my $progmontage;
my $progconvert;
my $progvolmeasures;
my $progspikiness;
my $progcount;
my $progmean;
my $progminmax;
my $progbxh2ppm;
my $progbrainmask;
my $progbxhselect;
my $progphantomqa;
my $progtdiff;
my $progbinop;
my $progbxh2analyze;
my $progtfilter;
my $prog3dToutcount;
my $prog3dFWHMx;
my $progspectrum;
my %exechash =
  (
   'montage' => \$progmontage,
   'convert' => \$progconvert,
   'fmriqa_volmeasures' => \$progvolmeasures,
   'fmriqa_spikiness' => \$progspikiness,
   'fmriqa_count' => \$progcount,
   'bxh_mean' => \$progmean,
   'fmriqa_minmax' => \$progminmax,
   'bxh2ppm' => \$progbxh2ppm,
   'bxh_brainmask' => \$progbrainmask,
   'bxhselect' => \$progbxhselect,
   'fmriqa_phantomqa' => \$progphantomqa,
   'fmriqa_tdiff' => \$progtdiff,
   'bxh_binop' => \$progbinop,
   'bxh2analyze' => \$progbxh2analyze,
   'bxh_tfilter' => \$progtfilter,
   'fmriqa_spectrum' => \$progspectrum,
  );
if ($Config{'osname'} eq 'MSWin32') {
  $exechash{'pgnuplot'} = \$proggnuplot;
} else {
  $exechash{'gnuplot'} = \$proggnuplot;
}
foreach my $execname (keys %exechash) {
  my $execloc = findexecutable($execname);
  if (!defined($execloc)) {
    print STDERR "Can't find required executable \"$execname\"!\n";
    exit -1;
  }
  ${$exechash{$execname}} = $execloc;
}
$prog3dToutcount = findexecutable('3dToutcount');
$prog3dFWHMx = findexecutable('3dFWHMx');
if (testrunexecutable($prog3dToutcount) != 0) {
  $prog3dToutcount = undef;
}
if (testrunexecutable($prog3dFWHMx) != 0) {
  $prog3dFWHMx = undef;
}

my $gnuplotimgtype = 'pbm';
if ($Config{'osname'} eq 'MSWin32') {
  $gnuplotimgtype = 'png';
}

# find JavaScript-based QA files
my $proglibdirs = File::Spec->catdir(@baseprogdirs, 'lib');
my $progjsdirs = File::Spec->catdir(@baseprogdirs, 'fmriqa', 'js');
my $jsfileindex = undef;
my $jsfilehighcharts = undef;
my $jsfilejquery = undef;
my $jsfilejquerymw = undef;
my $jsfilejquerymwlicense = undef;
my $jsfilejs = undef;
my $jsfilecss = undef;
my $jsfileexcanvas = undef;
my $jsfileexcanvasreadme = undef;
my @jsfileentries = (
   [\$jsfileindex, 'index-js.html', 'index-js.html', [$proglibdirs, $progjsdirs], [$opt_indexjs ? 'index.html' : 'index-js.html'] ],
   [\$jsfilehighcharts, 'highcharts.js', 'highcharts.src.js',
    [$proglibdirs, File::Spec->catdir(@baseprogdirs, 'fmriqa', 'js', 'Highcharts-2.2.0', 'js')], ['js', 'highcharts.js']],
   [\$jsfilejquery, 'jquery-1.7.1.min.js', 'jquery-1.7.1.js', [$proglibdirs, $progjsdirs], ['js', 'jquery-1.7.1.js']],
   [\$jsfilejquerymw, 'jquery.mousewheel.min.js', 'jquery.mousewheel.js', [$proglibdirs, $progjsdirs], ['js', 'jquery.mousewheel.js']],
   [\$jsfilejquerymwlicense, 'jquery.mousewheel.LICENSE.txt', 'jquery.mousewheel.LICENSE.txt', [$proglibdirs, $progjsdirs], ['js', 'jquery.mousewheel.LICENSE.txt']],
   [\$jsfilejs, 'biac_qa.js', 'biac_qa.src.js', [$proglibdirs, $progjsdirs], ['js', 'biac_qa.js']],
   [\$jsfilecss, 'biac_qa.css', 'biac_qa.css', [$proglibdirs, $progjsdirs], ['js', 'biac_qa.css']],
   [\$jsfileexcanvas, 'excanvas.js', 'excanvas.original.js', [$proglibdirs, $progjsdirs, File::Spec->catdir(@baseprogdirs, 'fmriqa', 'js', 'excanvas')], ['js', 'excanvas.js']],
   [\$jsfileexcanvasreadme, 'excanvas_README.txt', 'excanvas_README.txt', [$proglibdirs, $progjsdirs], ['js', 'excanvas_README.txt']],
);
for my $jsfileentry (@jsfileentries) {
  my ($varref, $filename, $debugfilename, $dirsarrayref, $outpathref) = @$jsfileentry;
  for my $dirs (@$dirsarrayref) {
    my $testpath = File::Spec->catpath($progvol, $dirs, $opt_debugjs ? $debugfilename : $filename);
    if (-f $testpath) {
      $$varref = $testpath;
      last;
    }
  }
  if (!defined($$varref)) {
    print STDERR "Can't find required file \"$filename\"!\n";
    exit -1;
  }
}

my ($outputvol, $outputdir, undef) = File::Spec->splitpath($outputpath, 1);
my $outputdirjson = undef;
{
  my @outputdirs = File::Spec->splitdir($outputdir);
  $outputdirjson = File::Spec->catdir(@outputdirs, 'json');
}
if (!$opt_grouponly) {
  my $outputpathjson = File::Spec->catpath($outputvol, $outputdirjson, ''), 0777;
  mkdir $outputpath, 0777 || die "Error making directory $outputpath";
  mkdir $outputpathjson, 0777 || die "Error making directory '${outputpathjson}'\n";
}

# Create log file
my $logfilename = "LOG.txt";
if ($opt_grouponly) {
  $logfilename = "LOG-group.txt";
}
my $logfile = File::Spec->catpath($outputvol, $outputdir, $logfilename);
my $mode = '>';
if ($opt_defergroup) {
  $mode = '>>';
}
open($logfh, $mode, $logfile) ||
  die "Error opening '$logfile' for writing: $!\n";

print $logfh "fmriqa_generate.pl version " . 'BXH/XCEDE utilities (1.11.14)' . "\n";

{
  my @escapedcmd = quotecmd($0, @origARGV);
  print $logfh "Command line (quoted for shell): ", join(' ', @escapedcmd), "\n";
  print $logfh "Command line (unquoted) BEGIN\n";
  print $logfh " ", join("\n ", ($0, @origARGV)), "\n";
  print $logfh "Command line (unquoted) END\n";
}

# figure out common basepath of files
my ($basepath, @filelabels) = basepath_labels(@ARGV);
if (scalar(@opt_filelabels) > 0) {
  @filelabels = @opt_filelabels;
} else {
  my %labelhash = ();
  map { $labelhash{$_}++ } @filelabels;
  for my $filelabel (@filelabels) {
    if (exists $labelhash{$filelabel} && $labelhash{$filelabel} > 1) {
      my $suffixnum = 0;
      while (1) {
	$suffixnum++;
	my $newlabel = "${filelabel}${suffixnum}";
	if (! exists $labelhash{$newlabel}) {
	  $labelhash{$newlabel} = 1;
	  $filelabel = $newlabel;
	  last;
	}
      }
    }
  }
}

# Read in image metadata for later use
log_msg($logfh, "# reading metadata from input files\n");
my @filemetadata = ();
for my $filenum (0..$#ARGV) {
  $filemetadata[$filenum] = readxmlmetadata($ARGV[$filenum]);
  if (!exists($filemetadata[$filenum]->{'dims'}->{'t'})) {
    logdie($logfh, "Error: file '$ARGV[$filenum]' does not have a 't' dimension!\n");
  }
}


###################################################
### Figure out which sections to calculate/show ###
###################################################
my @sections_summary =
  (
   'notes',
   'summary',
  );
my @sections_other =
  (
   'meanstddevsfnr',
  );
my @sections_unmasked =
  (
   'clipped',
   'volumemeans',
   'meandiffvolumemeans',
   'cmassx',
   'cmassy',
   'cmassz',
   'slicevar',
  );
my @sections_masked =
  (
   '3dFWHMx-X',
   '3dFWHMx-Y',
   '3dFWHMx-Z',
  );
my @sections_maskdetrendcmass =
  (
   'maskedcmassx',
   'maskedcmassy',
   'maskedcmassz',
  );
my @sections_maskdetrend =
  (
   'maskedvolumemeans',
   'maskedtdiffvolumemeans',
   '3dToutcount',
   @sections_maskdetrendcmass,
   'spectrummean',
   'spectrummax',
  );
my @sections = (@sections_summary, @sections_other, @sections_unmasked, @sections_masked, @sections_maskdetrend);
# the following are for convenience
my @sections_fwhm = ('3dFWHMx-X', '3dFWHMx-Y', '3dFWHMx-Z');
my @sections_cmass = ('cmassx', 'cmassy', 'cmassz',
		      'maskedcmassx', 'maskedcmassy', 'maskedcmassz');
# default is to calculate everything
my %calc_sections = map { ($_ => $_) } @sections;
# default is to show everything except maskedcmass
my %show_sections = map { ($_ => $_) } @sections;
delete @show_sections{@sections_maskdetrendcmass};
# now adjust based on user-specified options
my %shorthands =
  (
   'all' => [ @sections_other, @sections_unmasked, @sections_masked, @sections_maskdetrend ],
   'unmasked' => [ @sections_unmasked ],
   'masked' => [ @sections_masked ],
   'maskeddetrended' => [ @sections_maskdetrend ],
   'cmass' => [ 'cmassx', 'cmassy', 'cmassz' ],
   'maskedcmass' => [ 'maskedcmassx', 'maskedcmassy', 'maskedcmassz' ],
   'fwhm' => [ '3dFWHMx-X', '3dFWHMx-Y', '3dFWHMx-Z' ],
   'spectrum' => [ 'spectrummean', 'spectrummax' ],
  );
my $numcalc = grep { $_ =~ /^\+/ } @opt_calc;
my $numnocalc = grep { $_ =~ /^-/ } @opt_calc;
my $numshow = grep { $_ =~ /^\+/ } @opt_showhide;
my $numhide = grep { $_ =~ /^-/ } @opt_showhide;
if ($numcalc > 0 && $numnocalc == 0) {
  # only --calc options specified, so make default to not calculate anything
  unshift @opt_calc, "-all";
}
if ($numshow > 0 && $numhide == 0) {
  # only --show options specified, so make default to not display anything
  unshift @opt_showhide, "-all";
}
for my $arg (@opt_showhide) {
  my ($flag, $name) = ($arg =~ /^(.)(.*)$/);
  my @names = ($name);
  if (exists $shorthands{$name}) {
    @names = @{$shorthands{$name}};
  }
  if ($flag eq '+') {
    map { $show_sections{$_} = $_ } @names;
  } elsif ($flag eq '-') {
    map { $show_sections{$_} = undef } @names;
  }
}
for my $arg (@opt_calc) {
  my ($flag, $name) = ($arg =~ /^(.)(.*)$/);
  my @names = ($name);
  if (exists $shorthands{$name}) {
    @names = @{$shorthands{$name}};
  }
  if ($flag eq '+') {
    map { $calc_sections{$_} = $_ } @names;
  } elsif ($flag eq '-') {
    map { $calc_sections{$_} = undef } @names;
  }
}
for my $section (keys %calc_sections) {
  if (!defined($calc_sections{$section})) {
    $show_sections{$section} = undef;
  }
}
if ($calc_sections{'3dToutcount'} && !defined($prog3dToutcount)) {
  log_msg($logfh, "# Warning: cannot find program 3dToutcount, so will not generate outlier voxel data\n");
  $calc_sections{'3dToutcount'} = undef;
}
if (grep {$_} @calc_sections{@sections_fwhm} && !defined($prog3dFWHMx)) {
  log_msg($logfh, "# Warning: cannot find program 3dFWHMx, so will not generate smoothness data\n");
  $calc_sections{'3dFWHMx-X'} = undef;
  $calc_sections{'3dFWHMx-Y'} = undef;
  $calc_sections{'3dFWHMx-Z'} = undef;
}

# This will contain any important notes
my @notelist = map { [] } (0..$#ARGV);

#######################################
### Do time selection, if necessary ###
#######################################
my @timeselects = ($opt_timeselect,) x scalar(@ARGV);
if (!$opt_grouponly) {
  # adjust (or create) time selection string if number of timepoints will
  # be odd
  my @selectranges = ([0, '']);
  if ($opt_timeselect) {
    @selectranges = map {
      if ($_ eq '') {
	die "Found an empty component in timeselect string '$opt_timeselect'\n";
      } else {
	[ split(':', $_, -1) ]
      }
    } split(',', $opt_timeselect);
    for my $selectrangeref (@selectranges) {
      if (scalar(@$selectrangeref) > 2 ||
	  grep { $_ ne '' && ($_ ne int($_) || $_ <= 0) } @$selectrangeref) {
	die "Time select string '$opt_timeselect' is malformed (must contain a list of positive integers N or ranges of positive integers M:N, separated by commas)!\n";
      }
      if (scalar(@$selectrangeref) == 1) {
	$selectrangeref->[1] = $selectrangeref->[0];
      }
      if ($selectrangeref->[0] eq '') {
	$selectrangeref->[0] = 0;
      }
    }
  }
  for my $filenum (0..$#ARGV) {
    my $tsize = $filemetadata[$filenum]->{'dims'}->{'t'}->{'size'};
    my $numselected = 0;
    my @newselectranges = @selectranges;
    map {
      if ($_->[1] eq '') {
	$numselected += $tsize - $_->[0];
      } else {
	$numselected += $_->[1] + 1 - $_->[0];
      }
    } @newselectranges;
    if ($numselected % 2 != 0) {
      log_msg($logfh, "# ***WARNING***: number of selected timepoints is ODD in $ARGV[$filenum]; first" . ($opt_timeselect ? " selected" : '') . " timepoint will be ignored.\n");
      if (($newselectranges[0]->[1] eq '' && $newselectranges[0]->[0] == $tsize - 1) ||
	  ($newselectranges[0]->[1] ne '' && $newselectranges[0]->[0] == $newselectranges[0]->[1])) {
	# first range is a single timepoint so just remove it
	shift @newselectranges;
      } else {
	$newselectranges[0] = [$newselectranges[0]->[0] + 1, $newselectranges[0]->[1]];
      }
      $timeselects[$filenum] = join(',', map { join(':', @$_) } @newselectranges);
    }
  }

  # If --timeselect, create temporary files
  for my $filenum (0..$#ARGV) {
    if (defined($timeselects[$filenum])) {
      log_msg($logfh, "# Selecting timepoints for $ARGV[$filenum] using selector '$timeselects[$filenum]' ...\n");
      my $tempfile = File::Spec->catpath($outputvol, $outputdir, "temp_select_${filelabels[$filenum]}.bxh");
      my $tempniigz = File::Spec->catpath($outputvol, $outputdir, "temp_select_${filelabels[$filenum]}.nii.gz");
      unlink $tempfile;
      unlink $tempniigz;
      run_and_log_cmd($logfh, $progbxhselect, '--timeselect', $timeselects[$filenum], $ARGV[$filenum], $tempfile);
      if ($? == -1 || $? & 127 || $? >> 8) {
	logdie($logfh, "Error running $progbxhselect\n");
      }
      $ARGV[$filenum] = $tempfile;
      push @tempfiles, $tempfile;
      $tempfile =~ s/\.bxh$/.img/;
      push @tempfiles, $tempfile;
      $filemetadata[$filenum] = readxmlmetadata($ARGV[$filenum]);
      if (!exists($filemetadata[$filenum]->{'dims'}->{'t'})) {
	logdie($logfh, "Error: file '$ARGV[$filenum]' does not have a 't' dimension!\n");
      }
    }
  }
}

###############################
### Pre-calculate some data ###
###############################

my @numclippedvoxels = ();
my $vmdataref = [];
my $comdataref = [];
my $maskedvmdataref = [];
my $maskedcomdataref = [];
my $mdiffvmdataref = [];
my $maskedtdiffvmdataref = [];
my $spectrumdataref = [];
my $maskedoutliercountdataref = [];
my $maskedoutlierpercentdataref = [];
my $maskedfwhmdataref = [];
my @comunits = ();
my $spectrumxunits = undef;
my @pqa_means = undef;
my @pqa_snrs = undef;
my @pqa_sfnrs = undef;
my @methods = ();
if ($calc_sections{'meanstddevsfnr'}) {
  push @methods, 'mean', 'stddev', 'sfnr', 'mask';
}
if ($calc_sections{'slicevar'}) {
  push @methods, 'slicevar';
}
my %storedfns = ();
my %storedfullfns = ();
# actual range of raw data, for each method, for each file
my %storedmins = ();
my %storedmaxs = ();
# these store the data ranges that exclude outliers that we don't want to
# display, for each method, for each file.
my %storedscalemins = ();
my %storedscalemaxs = ();

### some summary stats
my @z1s = ();
my @maskedz1s = ();
my @z2s = ();
my @maskedz2s = ();
my @maskedtdiffp1s = ();
my @maskedtdiffp2s = ();
my @mdiffp1s = ();
my @mdiffp2s = ();
my @outp1s = ();
my @outp2s = ();
my @maskedmeanfwhmx = ();
my @maskedmeanfwhmy = ();
my @maskedmeanfwhmz = ();

### create filenames ###
for my $filenum (0..$#ARGV) {
  my $label = $filelabels[$filenum];
  my $sanitizedlabel = $label;
  $sanitizedlabel =~ s%[\\/]%_%g;
  for my $method (@methods) {
    for my $type ('bxh', 'nii.gz', 'ppm', 'png', 'jpg', 'png.json', 'jpg.json', 'raw.ppm', 'raw.png', 'raw.jpg', 'raw.png.json', 'raw.jpg.json') {
      for my $colorbar ('data', 'cbar') {
	$storedfns{$method}->{$type}->{$colorbar}->[$filenum] = "qa_${method}${colorbar}_${sanitizedlabel}.${type}";
	$storedfullfns{$method}->{$type}->{$colorbar}->[$filenum] = File::Spec->catpath($outputvol, $outputdir, $storedfns{$method}->{$type}->{$colorbar}->[$filenum]);
      }
    }
    # each method uses the same exact color bar for raw images.
    # (scaled images have per-run "range brackets" on the color bars)
    for my $type ('ppm', 'png', 'jpg', 'png.json', 'jpg.json') {
      my $rawtype = "raw.${type}";
      $storedfns{$method}->{$rawtype}->{'cbar'}->[$filenum] = "qa_${method}cbar.${rawtype}";
      $storedfullfns{$method}->{$rawtype}->{'cbar'}->[$filenum] = File::Spec->catpath($outputvol, $outputdir, $storedfns{$method}->{$rawtype}->{'cbar'}->[$filenum]);
    }
  }
}

#######################
### Init stat lists ###
#######################

# @statlist is an array of references to hashes, one for each input file:
# (
#   { # for file1
#     'imagerefs'   => { 'sfnr_data' => $path1, 'sfnr_cbar' => $path2,
#                        'sfnr_data_json' => $path3, ... },
#     'scalarstats' => { $summarystatname1 : $value1, ... },
#     'arraystats'  =>
#       {
#         $statname1 => $statstruct1,
#         $statname2 => $statstruct2,
#         ...
#       },
#   },
#   { # for file2
#     'imagerefs'   => { ... },
#     'scalarstats' => { $summarystatname1 : $value2, ... },
#     'arraystats'  =>
#       {
#         $statname1 => $statstruct3,
#         $statname2 => $statstruct4,
#         ...
#       },
#   },
# )
# 'scalars' stats are those that are calculated per-run.
# 'arrays' stats are calculated per-volume or otherwise have multiple values,
# and are represented by a stat structure.
# Each stat structure is a hash reference of the form:
#  {
#    name    => 'statname',
#    xlabel  => 'xaxislabel',
#    ylabel  => 'yaxislabel',
#    xunits  => 'xunits', # 'vols' triggers writing to XML, otherwise arbitrary
#    yunits  => 'yunits',
#    summary => $summaryhashref, # see below
#    data    => [ [ x1, y1 ], [ x2, y2 ], ... ],
#  }
# Summary hash refs have the following keys: count, mean, stddev

my @statlist = ();
for my $filenum (0..$#filelabels) {
  push @statlist, { 'imagerefs' => {}, 'scalarstats' => {}, 'arraystats' => {} };
}
my %maxvals =
(
  'int8' => 127,
  'uint8' => 256,
  'int16' => 32767,
  'uint16' => 65536,
  'int32' => 2147483647,
  'uint32' => 4294967296,
  'int64' => 9223372036854775807,
  'uint64' => 18446744073709551616,
);
# calculate per-run measures
for my $filenum (0..$#ARGV) {
  last if ($opt_grouponly);
  my $label = $filelabels[$filenum];
  log_stderr(" ${label}:");
  my $inputfile = $ARGV[$filenum];
  my $maskfile = undef;
  my $detrendinputfile = undef;
  
  if ($calc_sections{'clipped'}) {
    if (exists($maxvals{$filemetadata[$filenum]->{'elementtype'}})) {
      ### check for clipping in data and add it to notes
      log_stderr(" (clipped voxels)");
      my $elemtype = $filemetadata[$filenum]->{'elementtype'};
      my $maxval = $maxvals{$elemtype};
      my $cmd = "$progcount --granularity voxel --ge ${maxval} ${inputfile}";
      print $logfh "$cmd\n";
      my @clippedvoxels = grep { ! /^\#.*/ } split("\n", `$cmd`);
      $numclippedvoxels[$filenum] = scalar(@clippedvoxels);
      if ($numclippedvoxels[$filenum] > 0) {
	push @{$notelist[$filenum]}, "WARNING: ${inputfile} has $numclippedvoxels[$filenum] potentially-clipped voxels (with max ${elemtype} value ${maxval}).";
      }
    } else {
      $numclippedvoxels[$filenum] = 'N/A';
    }
  }

  if ($calc_sections{'meandiffvolumemeans'}) {
  # create mean volume
    my $meanvolbxh = File::Spec->catpath($outputvol, $outputdir, "qa_tempmeanvol_${label}.bxh");
    my $meanvolimg = File::Spec->catpath($outputvol, $outputdir, "qa_tempmeanvol_${label}.nii.gz");
    unlink $meanvolbxh if (-e $meanvolbxh);
    unlink $meanvolimg if (-e $meanvolimg);
    log_stderr(" (mean vol)");
    run_and_log_cmd($logfh, $progmean, '--dimension', 't', $inputfile, $meanvolbxh);
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running $progmean\n");
    }

    # create "mean diff" data
    my $meandiffbxh = File::Spec->catpath($outputvol, $outputdir, "qa_tempmeanvoldiff_${label}.bxh");
    my $meandiffimg = File::Spec->catpath($outputvol, $outputdir, "qa_tempmeanvoldiff_${label}.nii.gz");
    unlink $meandiffbxh if (-e $meandiffbxh);
    unlink $meandiffimg if (-e $meandiffimg);
    log_stderr(" (mean diff)");
    run_and_log_cmd($logfh, $progbinop, '--overwrite', '--sub', $inputfile, $meanvolbxh, $meandiffbxh);
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running $progbinop\n");
    }

    log_stderr(" (mean diff volume measures)");
    {
      log_msg_nostderr($logfh, "$progvolmeasures $meandiffbxh\n");
      open(VMFH, "$progvolmeasures $meandiffbxh |")
	|| logdie($logfh, "Error running fmriqa_volmeasures: $!");
      push @$mdiffvmdataref, [];
      my $vmmatref = $mdiffvmdataref->[$#$mdiffvmdataref];
      while (<VMFH>) {
	next if /^#/;
	  my ($volnum, $volmean, $cmassx, $cmassy, $cmassz, $volstddev, $volmin, $volmax, $axistick) = split(/\s+/, $_);
	push @{$vmmatref->[0]}, $volnum;
	push @{$vmmatref->[1]}, $volmean;
      }
      close VMFH;
    }

    unlink $meanvolbxh;
    unlink $meanvolimg;
    unlink $meandiffbxh;
    unlink $meandiffimg;
  }

  if (scalar(@opt_filemasks) > 0) {
    run_and_log_cmd($logfh, $progbxhselect, $opt_filemasks[$filenum], $storedfullfns{'mask'}->{'bxh'}->{'data'}->[$filenum]);
    $maskfile = $storedfullfns{'mask'}->{'bxh'}->{'data'}->[$filenum];
  } elsif (grep {$_} @calc_sections{@sections_masked,@sections_maskdetrend,'meanstddevsfnr'}) {
    # create brain mask
    $maskfile = $storedfullfns{'mask'}->{'bxh'}->{'data'}->[$filenum];
    log_stderr(" (create mask)");
    run_and_log_cmd($logfh, $progbrainmask, '--overwrite', '--method=localmin', $inputfile, $maskfile);
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running bxh_brainmask\n");
    }
  }

  if (grep {$_} @calc_sections{@sections_masked,@sections_maskdetrend}) {
    # create detrended data
    $detrendinputfile = File::Spec->catpath($outputvol, $outputdir, "qa_detrended_${label}.bxh");
    log_stderr(" (creating detrended)");
    my @forcetropts = ();
    if ($opt_forcetr != 0) {
      @forcetropts = ('--forcetr', $opt_forcetr);
    }
    run_and_log_cmd($logfh, $progtfilter, '--overwrite', '--filtertype', 'highpass', '--period', '60', '--keepdc', @forcetropts, $inputfile, $detrendinputfile);
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running bxh_tfilter\n");
    }
  }

  #if (grep {$_} @calc_sections{'volumemeans', 'cmassx', 'cmassy', 'cmassz'}) {
  if (1) { # we need this for other measures too, so calculate it anyway
    log_stderr(" (input volume measures)");
    {
      log_msg_nostderr($logfh, "$progvolmeasures $inputfile\n");
      open(VMFH, "$progvolmeasures $inputfile|")
	|| logdie($logfh, "Error running fmriqa_volmeasures: $!");
      push @$vmdataref, [];
      push @$comdataref, [];
      my $vmmatref = $vmdataref->[$#$vmdataref];
      my $commatref = $comdataref->[$#$comdataref];
      while (<VMFH>) {
	if (/^#VOLNUM\s+VOLMEAN\s+CMASSX\((.*)\)\s+CMASSY\((.*)\)\s+CMASSZ\((.*)\)\s+VOLSTDDEV\s+VOLMIN\s+VOLMAX\s+AXISTICK\(.*\)$/) {
	    @comunits = ($1, $2, $3);
	  }
	  next if /^#/;
	    my ($volnum, $volmean, $cmassx, $cmassy, $cmassz, $volstddev, $volmin, $volmax, $axistick) = split(/\s+/, $_);
	push @{$vmmatref->[0]}, $volnum;
	push @{$vmmatref->[1]}, $volmean;
	push @{$commatref->[0]}, $volnum;
	push @{$commatref->[1]}, $cmassx;
	push @{$commatref->[2]}, $cmassy;
	push @{$commatref->[3]}, $cmassz;
      }
      close VMFH;
    }
  }
  if (grep {$_} @calc_sections{'maskedvolumemeans', 'maskedcmassx', 'maskedcmassy', 'maskedcmassz'}) {
    log_stderr(" (masked,detrended volume measures)");
    {
      log_msg_nostderr($logfh, "$progvolmeasures --mask $maskfile $detrendinputfile\n");
      open(VMFH, "$progvolmeasures --mask $maskfile $detrendinputfile|")
	|| logdie($logfh, "Error running fmriqa_volmeasures: $!");
      push @$maskedvmdataref, [];
      push @$maskedcomdataref, [];
      my $vmmatref = $maskedvmdataref->[$#$maskedvmdataref];
      my $commatref = $maskedcomdataref->[$#$maskedcomdataref];
      while (<VMFH>) {
	if (/^#VOLNUM\s+VOLMEAN\s+CMASSX\((.*)\)\s+CMASSY\((.*)\)\s+CMASSZ\((.*)\)\s+VOLSTDDEV\s+VOLMIN\s+VOLMAX\s+AXISTICK\(.*\)$/) {
	    @comunits = ($1, $2, $3);
	  }
	  next if /^#/;
	    my ($volnum, $volmean, $cmassx, $cmassy, $cmassz, $volstddev, $volmin, $volmax, $axistick) = split(/\s+/, $_);
	push @{$vmmatref->[0]}, $volnum;
	push @{$vmmatref->[1]}, $volmean;
	push @{$commatref->[0]}, $volnum;
	push @{$commatref->[1]}, $cmassx;
	push @{$commatref->[2]}, $cmassy;
	push @{$commatref->[3]}, $cmassz;
      }
      close VMFH;
    }
  }

  if ($calc_sections{'maskedtdiffvolumemeans'}) {
    # create "velocity" data
    my $maskedtdiffinputbxh = File::Spec->catpath($outputvol, $outputdir, "qa_masked_tdiff_${label}.bxh");
    my $maskedtdiffinputimg = File::Spec->catpath($outputvol, $outputdir, "qa_masked_tdiff_${label}.img");
    log_stderr(" (calculate detrended velocity)");
    run_and_log_cmd($logfh, $progtdiff, '--overwrite', '--mask', $maskfile, $detrendinputfile, $maskedtdiffinputbxh);
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running fmriqa_tdiff\n");
    }
    log_stderr(" (masked,detrended \"velocity\" volume measures)");
    {
      log_msg_nostderr($logfh, "$progvolmeasures --mask $maskfile $maskedtdiffinputbxh\n");
      open(VMFH, "$progvolmeasures --mask $maskfile $maskedtdiffinputbxh|")
	|| logdie($logfh, "Error running fmriqa_volmeasures: $!");
      push @$maskedtdiffvmdataref, [];
      my $vmmatref = $maskedtdiffvmdataref->[$#$maskedtdiffvmdataref];
      while (<VMFH>) {
	if (/^#VOLNUM\s+VOLMEAN\s+CMASSX\((.*)\)\s+CMASSY\((.*)\)\s+CMASSZ\((.*)\)\s+VOLSTDDEV\s+VOLMIN\s+VOLMAX\s+AXISTICK\(.*\)$/) {
	    @comunits = ($1, $2, $3);
	  }
	  next if /^#/;
	    my ($volnum, $volmean, $cmassx, $cmassy, $cmassz, $volstddev) = split(/\s+/, $_);
	push @{$vmmatref->[0]}, $volnum;
	push @{$vmmatref->[1]}, $volmean;
      }
      close VMFH;
    }
    unlink $maskedtdiffinputbxh;
    unlink $maskedtdiffinputimg;
  }

  if ($calc_sections{'spectrummean'} || $calc_sections{'spectrummax'}) {
    # calculate frequency spectrum
    my $spectrumbxh = File::Spec->catpath($outputvol, $outputdir, "qa_spectrum_${label}.bxh");
    my $spectrumimg = File::Spec->catpath($outputvol, $outputdir, "qa_spectrum_${label}.nii.gz");
    unlink $spectrumbxh;
    unlink $spectrumimg;
    log_stderr(" (calculate frequency spectrum)");
    run_and_log_cmd($logfh, $progspectrum, ($opt_forcetr != 0) ? ( '--forcetr', $opt_forcetr ) : (), '--timeselect', ':', '--mask', $maskfile, $inputfile, $spectrumbxh);
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running fmriqa_spectrum\n");
    }
    log_stderr(" (spectrum volume measures)");
    {
      log_msg_nostderr($logfh, "$progvolmeasures --mask $maskfile $spectrumbxh\n");
      open(VMFH, "$progvolmeasures --mask $maskfile $spectrumbxh|")
	|| logdie($logfh, "Error running fmriqa_volmeasures: $!");
      push @$spectrumdataref, [];
      my $spectrummatref = $spectrumdataref->[$#$spectrumdataref];
      while (<VMFH>) {
	if (/^\#VOLNUM\s+VOLMEAN\s+CMASSX\(.*\)\s+CMASSY\(.*\)\s+CMASSZ\(.*\)\s+VOLSTDDEV\s+VOLMIN\s+VOLMAX\s+AXISTICK\((.*)\)$/) {
	  $spectrumxunits = $1;
	}
	next if /^\#/;
	my ($volnum, $volmean, $cmassx, $cmassy, $cmassz, $volstddev, $volmin, $volmax, $axistick) = split(/\s+/, $_);
	push @{$spectrummatref->[0]}, $volnum;
	push @{$spectrummatref->[1]}, $volmean;
	push @{$spectrummatref->[2]}, $volmax;
	push @{$spectrummatref->[3]}, $axistick;
      }
      close VMFH;
    }
    unlink $spectrumbxh;
    unlink $spectrumimg;
  }

  if ($calc_sections{'3dToutcount'}) {
    my $niftiprefix = File::Spec->catpath($outputvol, $outputdir, "XX");
    if (-e "${niftiprefix}.hdr") { unlink "${niftiprefix}.hdr"; }
    if (-e "${niftiprefix}.img") { unlink "${niftiprefix}.img"; }
    if (-e "${niftiprefix}_mask.hdr") { unlink "${niftiprefix}_mask.hdr"; }
    if (-e "${niftiprefix}_mask.img") { unlink "${niftiprefix}_mask.img"; }
    log_stderr(" (create 4-D NIFTI files)");
    run_and_log_cmd($logfh, $progbxh2analyze, '--overwrite', '-b', '-s', '-v', '--niftihdr', '--nosform', $detrendinputfile, $niftiprefix);
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running bxh2analyze\n");
    }
    run_and_log_cmd($logfh, $progbxh2analyze, '--overwrite', '-b', '-s', '-v', '--niftihdr', '--nosform', $maskfile, "${niftiprefix}_mask");
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running bxh2analyze\n");
    }
    log_stderr(" (mask voxel count)");
    log_msg_nostderr($logfh, "$progcount --gt 0 $maskfile\n");
    open(VMFH, "$progcount --gt 0 $maskfile |")
      || logdie($logfh, "Error running fmriqa_count: $!");
    my $nummaskvoxels = 0;
    while (<VMFH>) {
      next if /^#/;
      $nummaskvoxels = $_;
    }
    close VMFH;
    log_stderr(" (run AFNI 3dToutcount)");
    {
      log_msg_nostderr($logfh, "$prog3dToutcount -mask ${niftiprefix}_mask.hdr ${niftiprefix}.hdr\n");
      open(NULL, '>', File::Spec->devnull());
      my @cmd = ($prog3dToutcount, '-mask', "${niftiprefix}_mask.hdr", "${niftiprefix}.hdr");
      log_cmd($logfh, @cmd);
      my $pid = open3('>&NULL', \*VMFH, '>&NULL', @cmd)
	|| logdie($logfh, "Error running 3dToutcount: $!");
      push @$maskedoutliercountdataref, [];
      push @$maskedoutlierpercentdataref, [];
      my $outliercountref = $maskedoutliercountdataref->[$#$maskedoutliercountdataref];
      my $outlierpercentref = $maskedoutlierpercentdataref->[$#$maskedoutlierpercentdataref];
      my $volnum = 0;
      while (<VMFH>) {
	next if /^\+\+/;
	next if /^\*\*/;
	my $numoutliers = 0 + $_;
	push @{$outliercountref->[0]}, $volnum;
	push @{$outliercountref->[1]}, $numoutliers;
	push @{$outlierpercentref->[0]}, $volnum;
	push @{$outlierpercentref->[1]}, 100 * ($numoutliers / no_zero($nummaskvoxels));
	$volnum++;
      }
      close VMFH;
      waitpid $pid, 0;
      if ($? == -1 || $? & 127 || $? >> 8) {
	logdie($logfh, "Error running 3dToutcount\n");
      }
      close NULL;
    }
    unlink "${niftiprefix}.hdr";
    unlink "${niftiprefix}.img";
    unlink "${niftiprefix}_mask.hdr";
    unlink "${niftiprefix}_mask.img";
  }

  if (grep {$_} @calc_sections{@sections_fwhm}) {
    my $niftiprefix = File::Spec->catpath($outputvol, $outputdir, "XX");
    my $tmpoutfile = File::Spec->catpath($outputvol, $outputdir, "fwhm.out");
    unlink "${niftiprefix}.hdr", "${niftiprefix}.img";
    unlink $tmpoutfile;
    if (-e "${niftiprefix}mask.hdr") { unlink "${niftiprefix}_mask.hdr"; }
    if (-e "${niftiprefix}mask.img") { unlink "${niftiprefix}_mask.img"; }
    log_stderr(" (create 3-D NIFTI files)");
    run_and_log_cmd($logfh, $progbxh2analyze, '--overwrite', '-b', '-s', '-v', '--niftihdr', '--nosform', $inputfile, $niftiprefix);
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running bxh2analyze\n");
    }
    run_and_log_cmd($logfh, $progbxh2analyze, '--overwrite', '-b', '-s', '-v', '--niftihdr', '--nosform', $maskfile, "${niftiprefix}_mask");
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running bxh2analyze\n");
    }
    log_stderr(" (run AFNI 3dFWHMx)");
    my $tmpfwhmdataref = [];
    open(NULL, '>', File::Spec->devnull());
    my @cmd = ($prog3dFWHMx, '-demed', '-mask', "${niftiprefix}_mask.hdr", '-dset', "${niftiprefix}.hdr", '-out', $tmpoutfile);
    log_cmd($logfh, @cmd);
    my $pid = open3('>&NULL', '>&NULL', '>&NULL', @cmd)
      || logdie($logfh, "Error running 3dFWHMx: $!");
    waitpid $pid, 0;
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running 3dFWHMx\n");
    }
    close NULL;
    open(SMFH, $tmpoutfile) || logdie($logfh, "Error opening '$tmpoutfile': $!\n");
    my $volnum = 0;
    while (<SMFH>) {
      chomp;
      s/^\s+//;
      s/\s+$//;
      my ($fwhmx, $fwhmy, $fwhmz) = split(/\s+/, $_);
      push @{$tmpfwhmdataref->[0]}, $volnum;
      push @{$tmpfwhmdataref->[1]}, $fwhmx;
      push @{$tmpfwhmdataref->[2]}, $fwhmy;
      push @{$tmpfwhmdataref->[3]}, $fwhmz;
      $volnum++;
    }
    close SMFH;
    push @$maskedfwhmdataref, $tmpfwhmdataref;
    unlink "${niftiprefix}.hdr";
    unlink "${niftiprefix}.img";
    unlink "${niftiprefix}_mask.hdr";
    unlink "${niftiprefix}_mask.img";
    unlink $tmpoutfile;
  }

  # get rid of temporary files
  for my $bxhfile ($detrendinputfile) {
    next if !defined($bxhfile);
    my $imgfile = $bxhfile;
    $imgfile =~ s/\.bxh$/.img/;
    unlink $bxhfile if (-e $bxhfile);
    unlink $imgfile if (-e $imgfile);
  }

  if ($calc_sections{'meanstddevsfnr'}) {
    log_stderr(" (run sfnr)");
    my $prefix = File::Spec->catpath($outputvol, $outputdir, "pqa");
    my $maskbxh = $maskfile;
    my $sfnrbxh = File::Spec->catpath($outputvol, $outputdir, "qa_sfnrdata_${label}.bxh");
    my $sfnrimg = File::Spec->catpath($outputvol, $outputdir, "qa_sfnrdata_${label}.img");
    my ($oldavebxh, $oldaveimg,
	$oldnavebxh, $oldnaveimg,
	$oldsdbxh, $oldsdimg,
	$oldsfnrbxh, $oldsfnrimg) =
	  map {
	    File::Spec->catpath($outputvol, $outputdir, "pqa_${_}.bxh"),
		File::Spec->catpath($outputvol, $outputdir, "pqa_${_}.img")
		} ('ave', 'nave', 'sd', 'sfnr');
    my @cmd = ();
    push @cmd, $progphantomqa, '--timeselect', ':', '--maskfile', $maskbxh, '--nofluct', '--noroi', $inputfile, $prefix;
    if ($opt_forcetr != 0) {
      push @cmd, '--forcetr', $opt_forcetr;
    }
    my @escapedcmd = quotecmd(@cmd);
    print $logfh join(" ", @escapedcmd), "\n";
    open(PQAFH, join( ' ', map qq["$_"], @cmd ) . '|')
      || logdie($logfh, "Error running fmriqa_phantomqa\n");
    while (<PQAFH>) {
      if (/^##\(mean,\s+SNR,\s+SFNR\)\s*=\s*\(\s*(\S*)\s+(\S*)\s+(\S*)\)\s*$/) {
	($pqa_means[$filenum], $pqa_snrs[$filenum], $pqa_sfnrs[$filenum]) =
	  ($1 + 0, $2 + 0, $3 + 0);
      }
    }
    close PQAFH;
    if (-e $sfnrbxh) {
      unlink $sfnrbxh;
    }
    if (-e $sfnrimg) {
      unlink $sfnrimg;
    }
    run_and_log_cmd($logfh, $progbxhselect, '--overwrite', $oldsfnrbxh, $sfnrbxh);
    if ($? == -1 || $? & 127 || $? >> 8) {
      logdie($logfh, "Error running bxhselect: $!");
    }
    unlink $oldavebxh, $oldaveimg, $oldnavebxh, $oldnaveimg, $oldsdbxh, $oldsdimg, $oldsfnrbxh, $oldsfnrimg;
  }

  log_stderr(" (calculating mean/stddev/slicevar)");
  # first clean up some files
  for my $method (@methods) {
    my $fullbxhfn = $storedfullfns{$method}->{'bxh'}->{'data'}->[$filenum];
    my $fullimgfn = $storedfullfns{$method}->{'nii.gz'}->{'data'}->[$filenum];
    if (-e $fullimgfn && $opt_overwrite &&
	$method ne 'sfnr' && $method ne 'mask') {
      unlink($fullimgfn);
    }
    if (-e $fullbxhfn && $opt_overwrite &&
	$method ne 'sfnr' && $method ne 'mask') {
      unlink($fullbxhfn);
    }
  }
  for my $method (@methods) {
    my $fullbxhfn = $storedfullfns{$method}->{'bxh'}->{'data'}->[$filenum];

    if ($method eq 'stddev') {
      # calculated in 'mean' method below
    } elsif ($method eq 'mean') {
      run_and_log_cmd($logfh, $progmean, '--dimension', 't', '--stddev', $storedfullfns{'stddev'}->{'bxh'}->{'data'}->[$filenum], $ARGV[$filenum], $fullbxhfn);
    } elsif ($method eq 'slicevar') {
      run_and_log_cmd($logfh, $progspikiness, $ARGV[$filenum], $fullbxhfn);
    }
  }

  log_stderr(" (calculating min/max of mean/stddev/sfnr/mask/slicevar)");
  my $cmd = '';
  my $minmaxoutput = '';
  for my $method (@methods) {
    # calculate simple min and max
    $cmd = "$progminmax " . join(" ", $storedfullfns{$method}->{'bxh'}->{'data'}->[$filenum]);
    print $logfh $cmd, "\n";
    $minmaxoutput = `$cmd`;
    (($storedmins{$method}->[$filenum], $storedmaxs{$method}->[$filenum]) =
     ($minmaxoutput =~ m/^min=(.*), max=(.*)$/)) ||
       logdie($logfh, "Error parsing output of fmriqa_minmax:\n$minmaxoutput\n");
    $storedmins{$method}->[$filenum] += 0;
    $storedmaxs{$method}->[$filenum] += 0;
    $storedscalemins{$method}->[$filenum] = $storedmins{$method}->[$filenum];
    $storedscalemaxs{$method}->[$filenum] = $storedmaxs{$method}->[$filenum];

    # do our best to damp out extreme outliers when calculating the image scaling
    $cmd = "$progcount --histogram " . $storedfullfns{$method}->{'bxh'}->{'data'}->[$filenum];
    print $logfh "$cmd\n";
    my @histooutput = split("\n", `$cmd`);
    shift @histooutput;		# get rid of first comment
    my $colheaders = shift @histooutput;
    my $values = shift @histooutput;
    $colheaders =~ s/^\#\s+//;
    $colheaders =~ s/\s+$//;
    $values =~ s/^\s+//;
    $values =~ s/\s+$//;
    chomp $colheaders;
    chomp $values;
    my @intervals = map { [ $_ =~ /^(.*)<=?x<=?(.*)$/ ] } split(/\s+/, $colheaders);
    my @values = split(/\s+/, $values);
    map { $intervals[$_]->[2] = $values[$_] } (0..$#intervals);
    my @newintervals = ($intervals[0]);
    # find chunks in the histogram that are separated by more than three
    # stddev's worth of empty buckets
    for (my $i = 1; $i < scalar(@intervals); $i++) {
      if (scalar(@intervals) - $i >= 3 &&
	  $intervals[$i]->[2] == 0 &&
	  $intervals[$i+1]->[2] == 0 &&
	  $intervals[$i+2]->[2] == 0) {
	while ($i < scalar(@intervals)) {
	  $i++;
	  last if $intervals[$i]->[2] != 0;
	}
	push @newintervals, $intervals[$i];
      } else {
	$newintervals[$#newintervals]->[1] = $intervals[$i]->[1];
	$newintervals[$#newintervals]->[2] += $intervals[$i]->[2];
      }
    }
    # if any one of the newly chunked intervals comprise more than
    # 90% of the total data, then find the min and max value within
    # the bounds of that interval as the image windowing factors
    my $totalvoxels = 0;
    map { $totalvoxels += $_->[2] } @newintervals;
    my @bigone = grep { $_->[2] >= 0.90 * $totalvoxels } @newintervals;
    if (@bigone) {
      # "dilate" the range to make sure to include any voxels excluded by
      # floating-point rounding
      my $epsilon = $bigone[0]->[1] * 0.0001;
      $bigone[0]->[0] -= $epsilon;
      $bigone[0]->[1] += $epsilon;
      $cmd = "$progcount --histogram --ge $bigone[0]->[0] --le $bigone[0]->[1] " . $storedfullfns{$method}->{'bxh'}->{'data'}->[$filenum];
      print $logfh "$cmd\n";
      my @histooutput = split("\n", `$cmd`);
      shift @histooutput;	# get rid of first comment
      my $colheaders = shift @histooutput;
      $colheaders =~ s/^\#\s+//;
      $colheaders =~ s/\s+$//;
      chomp $colheaders;
      my @intervals = map { [ $_ =~ /^(.*)<=?x<=?(.*)$/ ] } split(/\s+/, $colheaders);
      if ($intervals[0]->[0] eq '-infinity') {
	$storedscalemins{$method}->[$filenum] = $storedmins{$method}->[$filenum];
      } else {
	$storedscalemins{$method}->[$filenum] = $intervals[0]->[0];
      }
      if ($intervals[$#intervals]->[1] eq 'infinity') {
	$storedscalemaxs{$method}->[$filenum] = $storedmaxs{$method}->[$filenum];
      } else {
	$storedscalemaxs{$method}->[$filenum] = $intervals[$#intervals]->[1];
      }
    }
  }
  log_stderr(" (converting raw data to jpg/png:");
  for my $method (@methods) {
    log_stderr(" $method");
    my $raw = 'raw.';
    if ($method eq 'slicevar' || $method eq 'mask') {
      $raw = '';
    }
    # image filenames
    my $fullbxhfn = $storedfullfns{$method}->{'bxh'}->{'data'}->[$filenum];
    my $fullppmfn = $storedfullfns{$method}->{$raw.'ppm'}->{'data'}->[$filenum];
    my $fullpngfn = $storedfullfns{$method}->{'png'}->{'data'}->[$filenum];
    my $pngfn = $storedfns{$method}->{'png'}->{'data'}->[$filenum];
    my $fulljpgfn = $storedfullfns{$method}->{$raw.'jpg'}->{'data'}->[$filenum];
    my $fulljpgjsonfn = $storedfullfns{$method}->{$raw.'jpg.json'}->{'data'}->[$filenum];
    my $jpgjsonfn = $storedfns{$method}->{$raw.'jpg.json'}->{'data'}->[$filenum];
    my $fullpngjsonfn = $storedfullfns{$method}->{$raw.'png.json'}->{'data'}->[$filenum];
    my $pngjsonfn = $storedfns{$method}->{$raw.'png.json'}->{'data'}->[$filenum];
    # colorbars
    my $fullcbarppmfn = $storedfullfns{$method}->{'raw.ppm'}->{'cbar'}->[$filenum];
    my $fullcbarjpgfn = $storedfullfns{$method}->{'raw.jpg'}->{'cbar'}->[$filenum];
    my $cbarjpgfn = $storedfns{$method}->{'raw.jpg'}->{'cbar'}->[$filenum];
    my $fullcbarjpgjsonfn = $storedfullfns{$method}->{'raw.jpg.json'}->{'cbar'}->[$filenum];
    my $cbarjpgjsonfn = $storedfns{$method}->{'raw.jpg.json'}->{'cbar'}->[$filenum];
    my $fullcbarpngjsonfn = $storedfullfns{$method}->{'raw.png.json'}->{'cbar'}->[$filenum];
    my $cbarpngjsonfn = $storedfns{$method}->{'raw.png.json'}->{'cbar'}->[$filenum];
    if (-e $fullppmfn && $opt_overwrite) {
      unlink($fullppmfn);
    }
    if (-e $fulljpgfn && $opt_overwrite) {
      unlink($fulljpgfn);
    }
    if (-e $fulljpgjsonfn && $opt_overwrite) {
      unlink($fulljpgjsonfn);
    }
    if (-e $fullpngjsonfn && $opt_overwrite) {
      unlink($fullpngjsonfn);
    }
    my $tilerows = 6;
    if (exists($filemetadata[$filenum]->{'dims'})) {
      my $dims = $filemetadata[$filenum]->{'dims'};
      if (exists($dims->{'z'})) {
	my $zdimref = $dims->{'z'};
	$tilerows = int(($zdimref->{'size'} + 5) / 6)
      } elsif (grep { /^z-split$/ } keys %$dims) {
	my @sortsplits = sort { $a cmp $b } grep { /^z-split$/ } keys %$dims;
	my $zdimref = $dims->{$sortsplits[$#sortsplits]};
	$tilerows = int(($zdimref->{'size'} + 5) / 6)
      }
    }
    my $minval = $storedmins{$method}->[$filenum];
    my $maxval = $storedmaxs{$method}->[$filenum];
    my $docolorbar = ($method ne 'mask' && ! -f "${fullcbarjpgfn}");
    my @colormapopts = ();
    my $colormap = 'gray';
    if ($method eq 'stddev') {
      $colormap = 'grayhot';
    } elsif ($method eq 'slicevar') {
      $colormap = 'bgr';
    }
    @colormapopts = ("--colormap=${colormap}",);
    my @colorbaropts = ();
    if ($docolorbar) {
      @colorbaropts = ("--colorbar=$fullcbarppmfn", "--barwidth=16", "--barlength=384", "--nobracket");
    }
    if ($method eq 'mean') {
      run_and_log_cmd($logfh, $progbxh2ppm, @colorbaropts, @colormapopts, "--minval=$minval", "--maxval=$maxval", $fullbxhfn, $fullppmfn);
      run_and_log_cmd($logfh, $progmontage, "-geometry", "64x64", "-tile", "6x$tilerows", $fullppmfn, $fulljpgfn);
    } elsif ($method eq 'mask') {
      run_and_log_cmd($logfh, $progbxh2ppm, "--minval=$minval", "--maxval=$maxval", $fullbxhfn, $fullppmfn);
      run_and_log_cmd($logfh, $progmontage, "-geometry", "64x64", "-tile", "6x$tilerows", $fullppmfn, $fullpngfn);
    } elsif ($method eq 'sfnr') {
      run_and_log_cmd($logfh, $progbxh2ppm, @colorbaropts, @colormapopts, "--minval=$minval", "--maxval=$maxval", $fullbxhfn, $fullppmfn);
      run_and_log_cmd($logfh, $progconvert, "-geometry", "384x384", $fullppmfn, $fulljpgfn);
    } elsif ($method eq 'stddev') {
      $minval = 0;
      $maxval = .3 * ($storedmaxs{'mean'}->[$filenum] - $storedmins{'mean'}->[$filenum]);
      run_and_log_cmd($logfh, $progbxh2ppm, @colorbaropts, @colormapopts, "--minval=$minval", "--maxval=$maxval", $fullbxhfn, $fullppmfn);
      run_and_log_cmd($logfh, $progmontage, "-geometry", "64x64", "-tile", "6x$tilerows", $fullppmfn, $fulljpgfn);
    } elsif ($method eq 'slicevar') {
      $minval = 0;
      $maxval = 30;
      run_and_log_cmd($logfh, $progbxh2ppm, "--dimorder=t,z", @colorbaropts, @colormapopts, "--minval=$minval", "--maxval=$maxval", $fullbxhfn, $fullppmfn);
      run_and_log_cmd($logfh, $progconvert, $fullcbarppmfn, $fullcbarjpgfn);
      my $slicestart = '';
      my $sliceend = '';
      my $timestart = '';
      my $timeend = '';
      my $zsize = undef;
      my $tsize = undef;
      if (exists($filemetadata[$filenum]->{'dims'})) {
	my $dims = $filemetadata[$filenum]->{'dims'};
	if (exists($dims->{'z'}) || exists($dims->{'z-split2'})) {
	  my $zdimref = undef;
	  if (exists($dims->{'z'})) {
	    $zdimref = {%{$dims->{'z'}}};
	  } elsif (exists($dims->{'z-split2'})) {
	    $zdimref = {%{$dims->{'z-split2'}}};
	  }
	  if ($zdimref->{'type'} =~ /^z-split/) {
	    if ($zdimref->{'outputselect'}) {
	      my $os = $zdimref->{'outputselect'};
	      $os =~ s/^\s+//;
	      $os =~ s/\s+$//;
	      my @oselems = split(/\s+/, $os);
	      $zdimref->{'size'} = scalar(@oselems);
	    } else {
	      my @zsplitkeys = grep { /^z-split/ } %{$filemetadata[$filenum]->{'dims'}};
	      $zdimref->{'size'} = 1;
	      for my $zsplitkey (@zsplitkeys) {
		$zdimref->{'size'} *= $filemetadata[$filenum]->{'dims'}->{$zsplitkey}->{'size'};
	      }
	    }
	  }
	  if (exists($zdimref->{'startlabel'}) &&
	      exists($zdimref->{'endlabelz'})) {
	    $slicestart = $zdimref->{'startlabel'};
	    $sliceend = $zdimref->{'endlabelz'};
	    $zsize = $zdimref->{'size'};
	  } else {
	    $slicestart = 1;
	    $sliceend = $zdimref->{'size'};
	  }
	}
	if (exists($dims->{'t'})) {
	  my $tdimref = $dims->{'t'};
	  $timestart = 1;
	  $timeend = $tdimref->{'size'};
	  $tsize = $tdimref->{'size'};
	}
	if (defined($zsize) && defined($tsize)) {
	  my @cmd = ();
	  my $zextent = $zsize * 8;
	  my $textent = $tsize * 4;
	  push @cmd, $progconvert;
	  if ($Config{'osname'} eq 'MSWin32') {
	    my $fontfile = 'c:\WINDOWS\Fonts\arial.ttf';
	    if (-e $fontfile) {
	      push @cmd, "-font", $fontfile;
	    }
	  }
	  my $bordertop = 40;
	  my $borderbottom = 12;
	  my $borderleft = 40;
	  my $borderright = 12;
	  my $bordermax = 40;
	  my $pointsize = 14;
	  push @cmd, "-fill", "black";
	  push @cmd, "-filter", "point";
	  push @cmd, "-resize", "400x800%";
	  push @cmd, "-border", "${bordermax}x${bordermax}";
	  push @cmd, "-bordercolor", "white";
	  push @cmd, "-pointsize", "$pointsize";
	  push @cmd, "-draw",
	    "gravity North " .
	      "text " . join(",",2-($textent/2),15) . " '1'";
	  for (my $t = 1; $t <= $timeend; $t++) {
	    my $tick = ($t * 4) - 2;
	    my $ticklen = 0;
	    if ($t % 10 == 0) {
	      $ticklen = 8;
	      push @cmd, "-draw",
		"gravity North " .
		  "text " . join(",",$tick - ($textent/2),15) . " '$t'";
	    } elsif ($t % 5 == 0) {
	      $ticklen = 4;
	    } elsif ($t == 1) {
	      $ticklen = 2;
	    }
	    if ($ticklen != 0) {
	      push @cmd, "-draw", "line " . join(",",$borderleft+$tick,$bordertop+$zextent,$borderleft+$tick,$bordertop+$zextent+$ticklen);
	      push @cmd, "-draw", "line " . join(",",$borderleft+$tick,$bordertop,$borderleft+$tick,$bordertop-$ticklen);
	    }
	  }
	  for (my $z = 0; $z < $zsize; $z++) {
	    my $tick = $z * 8;
	    my $ticklen = 0;
	    if ($z % 10 == 0) {
	      $ticklen = 8;
	    } elsif ($z % 5 == 0) {
	      $ticklen = 4;
	    }
	    if ($ticklen != 0) {
	      push @cmd, "-draw", "line " . join(",",$borderleft+$textent,$bordertop+$tick,$borderleft+$textent+$ticklen,$bordertop+$tick);
	      push @cmd, "-draw", "line " . join(",",$borderleft,$bordertop+$tick,$borderleft-$ticklen,$bordertop+$tick);
	    }
	  }
	  push @cmd, "-draw",
	    "gravity North " .
	      "text " . join(",",0,0) . " 'time point'";
	  push @cmd, "-rotate", "-90";
	  push @cmd, "-draw",
	    "gravity South " .
	      "text " . join(",",0,0) . " 'slice'";
	  push @cmd, "-draw",
	    "gravity SouthWest " .
	      "text " . join(",",$bordermax,15) . " '$slicestart'";
	  push @cmd, "-draw",
	    "gravity SouthEast " .
	      "text " . join(",",$bordermax,15) . " '$sliceend'";
	  push @cmd, "-rotate", "90";
	  push @cmd, "-crop", ($textent + $borderleft + $borderright) . "x" . ($zextent + $bordertop + $borderbottom) . "+0+0";
	  push @cmd, $fullppmfn, $fullpngfn;
	  run_and_log_cmd($logfh, @cmd);
	}
      }
    }
    if ($docolorbar) {
      run_and_log_cmd($logfh, $progconvert, $fullcbarppmfn, $fullcbarjpgfn);
    }
    # create JSON/base64 versions for import into javascript-based report
    if ($method ne 'mask') {
      for my $entry ( (($method eq 'slicevar') ? [$fullpngfn, $fullpngjsonfn, 1] : [$fulljpgfn, $fulljpgjsonfn, 1]), ($docolorbar ? [$fullcbarjpgfn, $fullcbarjpgjsonfn, 0] : ()) ) {
	next if (! -f $entry->[0]);
	open(OFH, '>', $entry->[1]) or die "Error opening '$entry->[1]' for writing: $!";
	open(IFH, '<', $entry->[0]) or die "Error opening '$entry->[0]' for reading: $!";
	print OFH '{ "data" : "';
	my $buf;
	while (read(IFH, $buf, 60*57)) {
	  $buf = encode_base64($buf);
	  $buf =~ s/[\r\n]*//g;
	  print OFH $buf;
	}
	close(IFH);
	print OFH "\" ";
	print OFH ", \"colormap\" : \"$colormap\"";
	if ($entry->[2]) {
	  # this is not a colorbar.
	  # these are the minimum and maximum *represented* values in the scaled
	  # image, i.e. the values in the original data that are represented by
	  # the lowest and highest colors on the colormap
	  print OFH ", \"minval\" : $minval";
	  print OFH ", \"maxval\" : $maxval";
	}
	print OFH "}";
	close(OFH);
      }
    }
    if ($method eq 'slicevar') {
      $statlist[$filenum]->{'imagerefs'}->{"${method}_data"} = $pngfn;
      $statlist[$filenum]->{'imagerefs'}->{"${method}_data_json"} = $pngjsonfn;
      $statlist[$filenum]->{'imagerefs'}->{"${method}_cbar_json"} = $cbarjpgjsonfn;
    } elsif ($method eq 'mask') {
      $statlist[$filenum]->{'imagerefs'}->{"${method}_data"} = $pngfn;
      # no colorbars, and no JSON data needed as it won't be scaled
    } else {
      $statlist[$filenum]->{'imagerefs'}->{"${method}_data_json"} = $jpgjsonfn;
      $statlist[$filenum]->{'imagerefs'}->{"${method}_cbar_json"} = $cbarjpgjsonfn;
    }
  }
  log_stderr(")");
  log_stderr("\n");

  #######################################
  # Calculate some per-run statistics ###
  #######################################
  if ($calc_sections{'volumemeans'}) {
    # number of volume means greater than $opt_zthresh1 std devs.
    # from individual means
    my ($mean, $sd) = calcmeanstddev(@{$vmdataref->[$filenum]->[1]});
    $z1s[$filenum] =
      0 + grep {
	abs(($_ - $mean) / no_zero($sd)) > $opt_zthresh1
      } @{$vmdataref->[$filenum]->[1]};
    # same for $opt_zthresh2
    $z2s[$filenum] =
      0 + grep {
	abs(($_ - $mean) / no_zero($sd)) > $opt_zthresh2
      } @{$vmdataref->[$filenum]->[1]};
  }

  if ($calc_sections{'maskedvolumemeans'}) {
    my ($mean, $sd) = calcmeanstddev(@{$maskedvmdataref->[$filenum]->[1]});
    $maskedz1s[$filenum] =
      0 + grep {
	abs(($_ - $mean) / no_zero($sd)) > $opt_zthresh1
      } @{$maskedvmdataref->[$filenum]->[1]};
    $maskedz2s[$filenum] =
      0 + grep {
	abs(($_ - $mean) / no_zero($sd)) > $opt_zthresh2
      } @{$maskedvmdataref->[$filenum]->[1]};
  }

  if ($calc_sections{'maskedtdiffvolumemeans'}) {
    # number of volumes whose running difference is greater than
    # $opt_percthresh1 or $opt_percthresh2 percent from the indiv. mean
    my $mean = calcmean(@{$maskedtdiffvmdataref->[$filenum]->[1]});
    my $maskedvmdatamean = calcmean(@{$maskedvmdataref->[$filenum]->[1]});
    $maskedtdiffp1s[$filenum] =
      0 + grep { 100 * abs($_ - $mean) / no_zero($maskedvmdatamean) > $opt_percthresh1 } @{$maskedtdiffvmdataref->[$filenum]->[1]};
    $maskedtdiffp2s[$filenum] =
      0 + grep { 100 * abs($_ - $mean) / no_zero($maskedvmdatamean) > $opt_percthresh2 } @{$maskedtdiffvmdataref->[$filenum]->[1]};
  }

  if ($calc_sections{'meandiffvolumemeans'}) {
    # number of volumes whose mean volume difference is greater than
    # $opt_percthresh1 or $opt_percthresh2 from the indiv. mean
    my $mean = calcmean(@{$mdiffvmdataref->[$filenum]->[1]});
    my $vmdatamean = calcmean(@{$vmdataref->[$filenum]->[1]});
    $mdiffp1s[$filenum] =
      0 + grep { 100 * abs($_ - $mean) / no_zero($vmdatamean) > $opt_percthresh1 } @{$mdiffvmdataref->[$filenum]->[1]};
    $mdiffp2s[$filenum] =
      0 + grep { 100 * abs($_ - $mean)  / no_zero($vmdatamean) > $opt_percthresh2 } @{$mdiffvmdataref->[$filenum]->[1]};
  }

  if ($calc_sections{'3dToutcount'}) {
    # number of volumes with greater than $opt_percthresh1 percent outlier voxels
    $outp1s[$filenum] =
      0 + grep { $_ > $opt_percthresh1 } @{$maskedoutlierpercentdataref->[$filenum]->[1]};
    # number of volumes with greater than $opt_percthresh1 percent outlier voxels
    $outp2s[$filenum] =
      0 + grep { $_ > $opt_percthresh2 } @{$maskedoutlierpercentdataref->[$filenum]->[1]};

    # mean FWHMS
    if ($calc_sections{'3dFWHMx-X'}) {
      $maskedmeanfwhmx[$filenum] =
	0 + sprintf("%0.3f", calcmean(@{$maskedfwhmdataref->[$filenum]->[1]}));
    }
    if ($calc_sections{'3dFWHMx-Y'}) {
      $maskedmeanfwhmy[$filenum] =
	0 + sprintf("%0.3f", calcmean(@{$maskedfwhmdataref->[$filenum]->[2]}));
    }
    if ($calc_sections{'3dFWHMx-Y'}) {
      $maskedmeanfwhmz[$filenum] =
	0 + sprintf("%0.3f", calcmean(@{$maskedfwhmdataref->[$filenum]->[3]}));
    }
  }

  ######################################
  # Calculate per-run XML event data ###
  ######################################
  {
    # do "per-run" statistics
    my $statref = $statlist[$filenum];
    my $scalarstats = $statref->{'scalarstats'};
    my $arraystats = $statref->{'arraystats'};
    my $filelabel = $filelabels[$filenum];
    $filelabel =~ s%[\\/]%_%g;

    my $wholerunvalues = $scalarstats;
    $wholerunvalues->{'filemetadata'} = { %{$filemetadata[$filenum]} };
    $wholerunvalues->{'cmassunits'} = [ @comunits ];
    $wholerunvalues->{'opt_percthresh1'} = $opt_percthresh1;
    $wholerunvalues->{'opt_percthresh2'} = $opt_percthresh2;
    $wholerunvalues->{'opt_zthresh1'} = $opt_zthresh1;
    $wholerunvalues->{'opt_zthresh2'} = $opt_zthresh2;
    if ($calc_sections{'notes'} && scalar(@{$notelist[$filenum]}) > 0) {
      $wholerunvalues->{"notes"} = join("\n", @{$notelist[$filenum]});
    }
    if ($calc_sections{'clipped'}) {
      $wholerunvalues->{"count_potentially_clipped"} = $numclippedvoxels[$filenum];
    }
    if ($calc_sections{'volumemeans'}) {
      $wholerunvalues->{"count_volmean_indiv_z${opt_zthresh1}"} = $z1s[$filenum];
      $wholerunvalues->{"count_volmean_indiv_z${opt_zthresh2}"} = $z2s[$filenum];
    }
    if ($calc_sections{'maskedvolumemeans'}) {
      $wholerunvalues->{"count_volmean_indiv_masked_z${opt_zthresh1}"} = $maskedz1s[$filenum];
      $wholerunvalues->{"count_volmean_indiv_masked_z${opt_zthresh2}"} = $maskedz2s[$filenum];
    }
    if ($calc_sections{'meandiffvolumemeans'}) {
      $wholerunvalues->{"count_mean_difference_indiv_${opt_percthresh1}percent"} = $mdiffp1s[$filenum];
      $wholerunvalues->{"count_mean_difference_indiv_${opt_percthresh2}percent"} = $mdiffp2s[$filenum];
    }
    if ($calc_sections{'maskedtdiffvolumemeans'}) {
      $wholerunvalues->{"count_velocity_indiv_masked_${opt_percthresh1}percent"} = $maskedtdiffp1s[$filenum];
      $wholerunvalues->{"count_velocity_indiv_masked_${opt_percthresh2}percent"} = $maskedtdiffp2s[$filenum];
    }
    if ($calc_sections{'maskedvolumemeans'}) {
      $wholerunvalues->{"count_volmean_indiv_masked_z${opt_zthresh1}"} = $maskedz1s[$filenum];
      $wholerunvalues->{"count_volmean_indiv_masked_z${opt_zthresh2}"} = $maskedz2s[$filenum];
    }
    if ($calc_sections{'meanstddevsfnr'}) {
      $wholerunvalues->{"mean_middle_slice"} = $pqa_means[$filenum];
      $wholerunvalues->{"mean_snr_middle_slice"} = $pqa_snrs[$filenum];
      $wholerunvalues->{"mean_sfnr_middle_slice"} = $pqa_sfnrs[$filenum];
    }
    if ($calc_sections{'3dToutcount'}) {
      $wholerunvalues->{"count_outliers_${opt_percthresh1}percent"} = $outp1s[$filenum];
      $wholerunvalues->{"count_outliers_${opt_percthresh2}percent"} = $outp2s[$filenum];
    }
    if ($calc_sections{'3dFWHMx-X'}) {
      $wholerunvalues->{"mean_masked_fwhmx"} = $maskedmeanfwhmx[$filenum];
    }
    if ($calc_sections{'3dFWHMx-Y'}) {
      $wholerunvalues->{"mean_masked_fwhmy"} = $maskedmeanfwhmy[$filenum];
    }
    if ($calc_sections{'3dFWHMx-Z'}) {
      $wholerunvalues->{"mean_masked_fwhmz"} = $maskedmeanfwhmz[$filenum];
    }

    for my $masked (0, 1) {
      my $sectionname = "volumemeans";
      my $dataref = $vmdataref;
      my $maskedprefix = '';
      my $maskedparen = '';
      if ($masked) {
	$sectionname = "maskedvolumemeans";
	$dataref = $maskedvmdataref;
	$maskedprefix = 'masked_';
	$maskedparen = ' (masked, detrended)';
      }
      if ($calc_sections{$sectionname}) {
	my $statname = "${maskedprefix}volmean";
	my $datacol = $dataref->[$filenum]->[1];
	my $count = scalar(@$datacol);
	my ($mean, $stddev) = calcmeanstddev(@$datacol);
	my $nozerostddev = no_zero($stddev);
	$arraystats->{$statname} =
	  {
	   'name'    => $statname,
	   'xlabel'  => 'Volume number',
	   'ylabel'  => "Mean intensity${maskedparen}",
	   'xunits'  => 'vols',
	   'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	   'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	  };
	$datacol = [ map { ($_ - $mean) / $nozerostddev } @$datacol ];
	$count = scalar(@$datacol);
	($mean, $stddev) = calcmeanstddev(@$datacol);
	$nozerostddev = no_zero($stddev);
	$arraystats->{"${statname}_z_indiv"} =
	  {
	   'name'    => "${statname}_z_indiv",
	   'xlabel'  => 'Volume number',
	   'ylabel'  => "Z-score of mean intensity${maskedparen}",
	   'xunits'  => 'vols',
	   'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	   'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	  };
      }
    }
    
    for my $entry (['x', 1], ['y', 2], ['z', 3]) {
      my ($direction, $colnum) = @$entry;
      for my $masked (0, 1) {
	my $sectionname = "cmass${direction}";
	my $dataref = $comdataref;
	my $maskedprefix = '';
	my $maskedparen = '';
	if ($masked) {
	  $sectionname = "maskedcmass${direction}";
	  $dataref = $maskedcomdataref;
	  $maskedprefix = 'masked_';
	  $maskedparen = ' (masked, detrended)';
	}
	if ($calc_sections{$sectionname}) {
	  my $statname = "${maskedprefix}cmass${direction}";
	  my $datacol = $dataref->[$filenum]->[$colnum];
	  my $count = scalar(@$datacol);
	  my ($mean, $stddev) = calcmeanstddev(@$datacol);
	  my $nozerostddev = no_zero($stddev);
	  $arraystats->{$statname} =
	    {
	     'name'    => $statname,
	     'xlabel'  => 'Volume number',
	     'ylabel'  => "Center of mass${maskedparen} in ${direction} direction",
	     'xunits'  => 'vols',
	     'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	     'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	    };
	  $datacol = [ map { abs($_ - $mean) } @$datacol ];
	  $count = scalar(@$datacol);
	  ($mean, $stddev) = calcmeanstddev(@$datacol);
	  $arraystats->{"${statname}_disp_indiv"} =
	    {
	     'name'    => "${statname}_disp_indiv",
	     'xlabel'  => 'Volume number',
	     'ylabel'  => "Center of mass${maskedparen} displacement from mean in $direction direction",
	     'xunits'  => 'vols',
	     'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	     'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	    };
	  $datacol = [ map { $_ / $nozerostddev } @$datacol ];
	  $count = scalar(@$datacol);
	  ($mean, $stddev) = calcmeanstddev(@$datacol);
	  $arraystats->{"${statname}_z_indiv"} =
	    {
	     'name'    => "${statname}_z_indiv",
	     'xlabel'  => 'Volume number',
	     'ylabel'  => "Z-score of center of mass${maskedparen} in $direction direction",
	     'xunits'  => 'vols',
	     'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	     'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	    };
	}
      }
    }
    if ($calc_sections{'maskedtdiffvolumemeans'}) {
      my $dataref = $maskedtdiffvmdataref;
      my $statname = 'masked_tdiff_volmean';
      my $datacol = $dataref->[$filenum]->[1];
      my $count = scalar(@$datacol);
      my ($mean, $stddev) = calcmeanstddev(@$datacol);
      $arraystats->{$statname} =
	{
	 'name'    => $statname,
	 'xlabel'  => 'Volume number',
	 'ylabel'  => "Running difference (masked,detrended) mean intensity",
	 'xunits'  => 'vols',
	 'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	 'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	};
    }
    if ($calc_sections{'meandiffvolumemeans'}) {
      my $dataref = $mdiffvmdataref;
      my $statname = 'mean_difference';
      my $datacol = $dataref->[$filenum]->[1];
      my $count = scalar(@$datacol);
      my ($mean, $stddev) = calcmeanstddev(@$datacol);
      $arraystats->{$statname} =
	{
	 'name'    => $statname,
	 'xlabel'  => 'Volume number',
	 'ylabel'  => "Mean volume difference mean intensity",
	 'xunits'  => 'vols',
	 'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	 'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	};
    }
    if ($calc_sections{'3dToutcount'}) {
      my $dataref = $maskedoutliercountdataref;
      my $statname = 'masked_outlier_count';
      my $datacol = $dataref->[$filenum]->[1];
      my $count = scalar(@$datacol);
      my ($mean, $stddev) = calcmeanstddev(@$datacol);
      $arraystats->{$statname} =
	{
	 'name'    => $statname,
	 'xlabel'  => 'Volume number',
	 'ylabel'  => "Outlier count from 3dToutcount",
	 'xunits'  => 'vols',
	 'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	 'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	};
    }
    if ($calc_sections{'3dToutcount'}) {
      my $dataref = $maskedoutlierpercentdataref;
      my $statname = 'masked_outlier_percent';
      my $datacol = $dataref->[$filenum]->[1];
      my $count = scalar(@$datacol);
      my ($mean, $stddev) = calcmeanstddev(@$datacol);
      $arraystats->{$statname} =
	{
	 'name'    => $statname,
	 'xlabel'  => 'Volume number',
	 'ylabel'  => "Outlier count from 3dToutcount as percentage of volume's voxels",
	 'xunits'  => 'vols',
	 'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	 'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	};
    }
    for my $entry (['x', 1], ['y', 2], ['z', 3]) {
      my ($direction, $col) = @$entry;
      if ($calc_sections{"3dFWHMx-".uc($direction)}) {
        my $dataref = $maskedfwhmdataref;
        my $statname = "masked_fwhm${direction}";
        my $datacol = $dataref->[$filenum]->[$col];
        my $count = scalar(@$datacol);
        my ($mean, $stddev) = calcmeanstddev(@$datacol);
        $arraystats->{$statname} =
  	  {
	   'name'    => $statname,
	   'xlabel'  => 'Volume number',
	   'ylabel'  => "Full-width half-max",
	   'xunits'  => 'vols',
	   'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	   'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	  };
      }
    }
    if ($calc_sections{'spectrummean'}) {
      my $dataref = $spectrumdataref;
      my $statname = 'spectrummean';
      my $datacol = $dataref->[$filenum]->[1];
      my $xcolref = $dataref->[$filenum]->[3];
      my $count = scalar(@$datacol);
      my ($mean, $stddev) = calcmeanstddev(@$datacol);
      $arraystats->{$statname} =
	{
	 'name'    => $statname,
	 'xlabel'  => 'Period (i.e. 1/freq)',
	 'ylabel'  => 'Mean of magnitude across volume',
	 'xunits'  => 'secs',
	 'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	 'data'    => [ map { [ $xcolref->[$_], $datacol->[$_] ] } (0..($count-1)) ],
	};
    }
    if ($calc_sections{'spectrummax'}) {
      my $dataref = $spectrumdataref;
      my $statname = 'spectrummax';
      my $datacol = $dataref->[$filenum]->[2];
      my $xcolref = $dataref->[$filenum]->[3];
      my $count = scalar(@$datacol);
      my ($mean, $stddev) = calcmeanstddev(@$datacol);
      $arraystats->{$statname} =
	{
	 'name'    => $statname,
	 'xlabel'  => 'Period (i.e. 1/freq)',
	 'ylabel'  => 'Maximum of magnitude across volume',
	 'xunits'  => 'secs',
	 'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	 'data'    => [ map { [ $xcolref->[$_], $datacol->[$_] ] } (0..($count-1)) ],
	};
    }
    for my $method (@methods) {
      $statlist[$filenum]->{'imagerefs'}->{"${method}_min"} = $storedmins{$method}->[$filenum];
      $statlist[$filenum]->{'imagerefs'}->{"${method}_max"} = $storedmaxs{$method}->[$filenum];
      $statlist[$filenum]->{'imagerefs'}->{"${method}_scaled_min"} = $storedscalemins{$method}->[$filenum];
      $statlist[$filenum]->{'imagerefs'}->{"${method}_scaled_max"} = $storedscalemaxs{$method}->[$filenum];
    }
  }

  my $statref = $statlist[$filenum];
  my $scalarstats = $statref->{'scalarstats'};
  my $arraystats = $statref->{'arraystats'};
  my $filelabel = $filelabels[$filenum];
  $filelabel =~ s%[\\/]%_%g;

  {
    # write out stats to JSON file
    for my $key ('scalarstats', 'imagerefs') {
      my $jsonfn = "qa_${key}_${filelabel}.json";
      my $fulljsonfn = File::Spec->catpath($outputvol, $outputdirjson, $jsonfn);
      open(JFH, ">$fulljsonfn")
	|| logdie($logfh, "Cannot open output file '${fulljsonfn}' for writing\n");
      print JFH encode_json($statref->{$key});
    }
    for my $key (keys %{$arraystats}) {
      my $jsonfn = "qa_arraystats_${key}_${filelabel}.json";
      my $fulljsonfn = File::Spec->catpath($outputvol, $outputdirjson, $jsonfn);
      open(JFH, ">$fulljsonfn")
	|| logdie($logfh, "Cannot open output file '${fulljsonfn}' for writing\n");
      print JFH encode_json($arraystats->{$key});
    }
  }

  {
    # write out some stats into XML events file
    my $eventfn = "qa_events_${filelabel}.xml";
    my $fulleventfn = File::Spec->catpath($outputvol, $outputdir, $eventfn);
    my $tspacing = $filemetadata[$filenum]->{'dims'}->{'t'}->{'spacing'} / 1000.0;
    my $tsize = $filemetadata[$filenum]->{'dims'}->{'t'}->{'size'};
    writeXMLEventsFile($fulleventfn, $tspacing, $tsize, $scalarstats, $arraystats);
  }

  {
    # add label to labelList.txt
    my $labellistfn = "labelList.txt";
    my $tmplabellistfn = "." . $labellistfn;
    my $fulllabellistfn = File::Spec->catpath($outputvol, $outputdir, $labellistfn);
    my $fulltmplabellistfn = File::Spec->catpath($outputvol, $outputdir, $tmplabellistfn);
    my @labellist = ();
    if (-f $fulllabellistfn) {
      open(SLFH, '<', $fulllabellistfn)
	|| logdie($logfh, "Cannot open output file '${fulllabellistfn}' for reading\n");
      @labellist = <SLFH>;
      close SLFH;
      map { $_ =~ s/[\r\n]*$// } @labellist;
    }
    if (! grep { $_ eq $filelabel } @labellist) {
      push @labellist, $filelabel;
      open(SLFH, '>', $fulltmplabellistfn)
	|| logdie($logfh, "Cannot open output file '${fulltmplabellistfn}' for writing\n");
      print SLFH join("\n", @labellist), "\n";
      close SLFH;
      rename $fulltmplabellistfn, $fulllabellistfn
	|| logdie($logfh, "Error renaming file '${fulltmplabellistfn}'!\n");
    }
  }
}
log_msg($logfh, "\n");

### done with calculations involving only individual run data ###
#################################################################

if (defined($opt_qalabel)) {
  # write report label to reportLabel.txt
  my $labelfn = "reportLabel.txt";
  my $fulllabelfn = File::Spec->catpath($outputvol, $outputdir, $labelfn);
  open(LFH, '>', $fulllabelfn)
    || logdie($logfh, "Cannot open output file '${fulllabelfn}' for writing\n");
  print LFH $opt_qalabel;
  close LFH;
}

######################################
### Copy JavaScript-based QA files ###
######################################
{
  my @outputdirs = File::Spec->splitdir($outputdir);
  my $jspath = File::Spec->catpath($outputvol, $outputdir, 'js');
  mkdir $jspath || die "Error making directory '$jspath': $!\n";
  for my $jsfileentry (@jsfileentries) {
    my ($varref, $filename, $debugfilename, $dirsarrayref, $outpathref) = @$jsfileentry;
    my @outsubdirs = @$outpathref;
    my $outfilename = pop @outsubdirs;
    my $newpath = File::Spec->catpath($outputvol, File::Spec->catdir(@outputdirs, @outsubdirs), $outfilename);
    copy($$varref, $newpath) || die "ERROR: Failed to copy '$filename': $!\n";
  }
}

if ($opt_defergroup) {
  log_msg($logfh, "Deferring group statistics.  Exiting.\n");
  exit 0;
}

if ($opt_grouponly) {
  log_msg($logfh, "Reading per-run statistics from JSON files...\n");
  {
    # read labels from labelList.txt
    my $labellistfn = "labelList.txt";
    my $fulllabellistfn = File::Spec->catpath($outputvol, $outputdir, $labellistfn);
    my @labellist = ();
    if (-f $fulllabellistfn) {
      open(SLFH, '<', $fulllabellistfn)
	|| logdie($logfh, "Cannot open output file '${fulllabellistfn}' for reading\n");
      @labellist = <SLFH>;
      close SLFH;
      map { $_ =~ s/[\r\n]*$// } @labellist;
    }
    if (scalar(@labellist) > 0) {
      @filelabels = @labellist;
      @ARGV = @labellist;
    }
  }
  for my $filenum (0..$#ARGV) {
    my $filelabel = $filelabels[$filenum];
    $filelabel =~ s%[\\/]%_%g;
    for my $type ('scalarstats', 'imagerefs') {
      my $jsonfn = "qa_${type}_${filelabel}.json";
      my $fulljsonfn = File::Spec->catpath($outputvol, $outputdirjson, $jsonfn);
      {
	local $\;
	open(JFH, '<', $fulljsonfn) || die "Error opening file '${fulljsonfn}' for reading: $!\n";
	my $jsondata = <JFH>;
	close JFH;
	$statlist[$filenum]->{$type} = decode_json $jsondata;
      }
    }

    my @arraystatskeys = ();
    for my $masked (0, 1) {
      my $sectionname = "volumemeans";
      my $maskedprefix = '';
      if ($masked) {
	$sectionname = "maskedvolumemeans";
	$maskedprefix = 'masked_';
      }
      if ($calc_sections{$sectionname}) {
	my $statname = "${maskedprefix}volmean";
	push @arraystatskeys, $statname;
      }
    }
    for my $entry (['x', 1], ['y', 2], ['z', 3]) {
      my ($direction, $colnum) = @$entry;
      for my $masked (0, 1) {
	my $sectionname = "cmass${direction}";
	my $maskedprefix = '';
	if ($masked) {
	  $sectionname = "maskedcmass${direction}";
	  $maskedprefix = 'masked_';
	}
	if ($calc_sections{$sectionname}) {
	  my $statname = "${maskedprefix}cmass${direction}";
	  push @arraystatskeys, $statname;
	}
      }
    }
    if ($calc_sections{'maskedtdiffvolumemeans'}) {
      my $statname = 'masked_tdiff_volmean';
      push @arraystatskeys, $statname;
    }
    if ($calc_sections{'meandiffvolumemeans'}) {
      my $statname = 'mean_difference';
      push @arraystatskeys, $statname;
    }
    if ($calc_sections{'3dToutcount'}) {
      my $statname = 'masked_outlier_count';
      push @arraystatskeys, $statname;
    }
    if ($calc_sections{'3dToutcount'}) {
      my $statname = 'masked_outlier_percent';
      push @arraystatskeys, $statname;
    }
    for my $entry (['x', 1], ['y', 2], ['z', 3]) {
      my ($direction, $col) = @$entry;
      if ($calc_sections{"3dFWHMx-".uc($direction)}) {
        my $statname = "masked_fwhm${direction}";
	push @arraystatskeys, $statname;
      }
    }
    if ($calc_sections{'spectrummean'}) {
      my $statname = 'spectrummean';
      push @arraystatskeys, $statname;
    }
    if ($calc_sections{'spectrummax'}) {
      my $statname = 'spectrummax';
      push @arraystatskeys, $statname;
    }
    for my $key (@arraystatskeys) {
      my $jsonfn = "qa_arraystats_${key}_${filelabel}.json";
      my $fulljsonfn = File::Spec->catpath($outputvol, $outputdirjson, $jsonfn);
      if (-f $fulljsonfn) {
	local $\;
	open(JFH, '<', $fulljsonfn) || die "Error opening file '${fulljsonfn}' for reading: $!\n";
	my $jsondata = <JFH>;
	close JFH;
	$statlist[$filenum]->{'arraystats'}->{$key} = decode_json $jsondata;
      }
    }

    my $statref = $statlist[$filenum];
    my $scalarstats = $statref->{'scalarstats'};
    my $arraystats = $statref->{'arraystats'};
    my $imagerefs = $statref->{'imagerefs'};
    $filemetadata[$filenum] = $scalarstats->{'filemetadata'};
    if (exists $scalarstats->{'cmassunits'}) {
      @comunits = @{$scalarstats->{'cmassunits'}};
    }
    my $percthresh1 = $scalarstats->{'opt_percthresh1'};
    my $percthresh2 = $scalarstats->{'opt_percthresh2'};
    my $zthresh1 = $scalarstats->{'opt_zthresh1'};
    my $zthresh2 = $scalarstats->{'opt_zthresh2'};
    if ($filenum != 0) {
      my $errname = undef;
      my $val1;
      my $val2;
      while (1) {
	$val1 = $percthresh1; $val2 = $opt_percthresh1;
	if ($val1 != $val2) { $errname = 'opt_percthresh1'; last; }
	$val1 = $percthresh2; $val2 = $opt_percthresh2;
	if ($val1 != $val2) { $errname = 'opt_percthresh2'; last; }
	$val1 = $zthresh1; $val2 = $opt_zthresh1;
	if ($val1 != $val2) { $errname = 'opt_zthresh1'; last; }
	$val1 = $zthresh2; $val2 = $opt_zthresh2;
	if ($val1 != $val2) { $errname = 'opt_zthresh2'; last; }
	last;
      }
      if (defined($errname)) {
	die "Error: reading previously-run QA data with different settings for ${errname} ($val1 and $val2)\n";
      }
    }
    # grab per-run summary statistics
    $notelist[$filenum] = [ split('\n', $scalarstats->{'notes'}) ];
    if ($calc_sections{'clipped'}) {
      $numclippedvoxels[$filenum] = $scalarstats->{'count_potentially_clipped'};
    }
    if ($calc_sections{'meanstddevsfnr'}) {
      $pqa_means[$filenum] = $scalarstats->{'mean_middle_slice'};
      $pqa_snrs[$filenum] = $scalarstats->{'mean_snr_middle_slice'};
      $pqa_sfnrs[$filenum] = $scalarstats->{'mean_sfnr_middle_slice'};
    }
    if ($calc_sections{'volumemeans'}) {
      $z1s[$filenum] = $scalarstats->{"count_volmean_indiv_z_${opt_zthresh1}"};
      $z2s[$filenum] = $scalarstats->{"count_volmean_indiv_z_${opt_zthresh2}"};
    }
    if ($calc_sections{'maskedvolumemeans'}) {
      $maskedz1s[$filenum] = $scalarstats->{"count_volmean_indiv_masked_z_${opt_zthresh1}"};
      $maskedz2s[$filenum] = $scalarstats->{"count_volmean_indiv_masked_z_${opt_zthresh2}"};
    }
    if ($calc_sections{'meandiffvolumemeans'}) {
      $mdiffp1s[$filenum] = $scalarstats->{"count_mean_difference_indiv_${opt_percthresh1}percent"};
      $mdiffp2s[$filenum] = $scalarstats->{"count_mean_difference_indiv_${opt_percthresh2}percent"};
    }
    if ($calc_sections{'maskedtdiffvolumemeans'}) {
      $maskedtdiffp1s[$filenum] = $scalarstats->{"count_velocity_indiv_masked_${opt_percthresh1}percent"};
      $maskedtdiffp2s[$filenum] = $scalarstats->{"count_velocity_indiv_masked_${opt_percthresh2}percent"};
    }
    if ($calc_sections{'3dToutcount'}) {
      $outp1s[$filenum] = $scalarstats->{"count_outliers_${opt_percthresh1}percentp"};
      $outp2s[$filenum] = $scalarstats->{"count_outliers_${opt_percthresh2}percent"};
    }
    if ($calc_sections{'3dFWHMx-X'}) {
      $maskedmeanfwhmx[$filenum] = $scalarstats->{"mean_masked_fwhmx"};
    }
    if ($calc_sections{'3dFWHMx-Y'}) {
      $maskedmeanfwhmy[$filenum] = $scalarstats->{"mean_masked_fwhmy"};
    }
    if ($calc_sections{'3dFWHMx-Z'}) {
      $maskedmeanfwhmz[$filenum] = $scalarstats->{"mean_masked_fwhmz"};
    }
    # grab array-based statistics
    if ($calc_sections{'volumemeans'}) {
      my $data = $arraystats->{'volmean'}->{'data'};
      $vmdataref->[$filenum] =
	[
	 [ map { $_->[0] } @$data ],
	 [ map { $_->[1] } @$data ],
	];
    }
    if ($calc_sections{'maskedvolumemeans'}) {
      my $data = $arraystats->{'masked_volmean'}->{'data'};
      $maskedvmdataref->[$filenum] =
	[
	 [ map { $_->[0] } @$data ],
	 [ map { $_->[1] } @$data ],
	];
    }
    if (grep {$_} @calc_sections{'cmassx', 'cmassy', 'cmassz'}) {
      my $indexdata = undef;
      for my $key ('cmassx', 'cmassy', 'cmassz') {
	if (exists $arraystats->{$key}) {
	  $indexdata = $arraystats->{$key}->{'data'};
	  last;
	}
      }
      $comdataref->[$filenum] =
	[
	 [ map { $_->[0] } @$indexdata ],
	 $calc_sections{'cmassx'} ? [ map { $_->[1] } @{$arraystats->{'cmassx'}->{'data'}} ] : undef,
	 $calc_sections{'cmassy'} ? [ map { $_->[1] } @{$arraystats->{'cmassy'}->{'data'}} ] : undef,
	 $calc_sections{'cmassz'} ? [ map { $_->[1] } @{$arraystats->{'cmassz'}->{'data'}} ] : undef,
	];
    }
    if (grep {$_} @calc_sections{'maskedcmassx', 'maskedcmassy', 'maskedcmassz'}) {
      my $indexdata = undef;
      for my $key ('masked_cmassx', 'masked_cmassy', 'masked_cmassz') {
	if (exists $arraystats->{$key}) {
	  $indexdata = $arraystats->{$key}->{'data'};
	  last;
	}
      }
      $maskedcomdataref->[$filenum] =
	[
	 [ map { $_->[0] } @$indexdata ],
	 $calc_sections{'maskedcmassx'} ? [ map { $_->[1] } @{$arraystats->{'masked_cmassx'}->{'data'}} ] : undef,
	 $calc_sections{'maskedcmassy'} ? [ map { $_->[1] } @{$arraystats->{'masked_cmassy'}->{'data'}} ] : undef,
	 $calc_sections{'maskedcmassz'} ? [ map { $_->[1] } @{$arraystats->{'masked_cmassz'}->{'data'}} ] : undef,
	];
    }
    if ($calc_sections{'spectrummean'} || $calc_sections{'spectrummax'}) {
      my $indexdata = undef;
      for my $key ('spectrummean', 'spectrummax') {
	if (exists $arraystats->{$key}) {
	  $indexdata = $arraystats->{$key}->{'data'};
	  last;
	}
      }
      $spectrumdataref->[$filenum] =
	[
	 [ map { $_ } (0..$#$indexdata) ],
	 $calc_sections{'spectrummean'} ? [ map { $_->[1] } @{$arraystats->{'spectrummean'}->{'data'}} ] : undef,
	 $calc_sections{'spectrummax'} ? [ map { $_->[1] } @{$arraystats->{'spectrummax'}->{'data'}} ] : undef,
	 [ map { $_->[0] } @$indexdata ],
	];
    }
    if ($calc_sections{'maskedtdiffvolumemeans'}) {
      my $data = $arraystats->{'masked_tdiff_volmean'}->{'data'};
      $maskedtdiffvmdataref->[$filenum] =
	[
	 [ map { $_->[0] } @$data ],
	 [ map { $_->[1] } @$data ],
	];
    }
    if ($calc_sections{'meandiffvolumemeans'}) {
      my $data = $arraystats->{'mean_difference'}->{'data'};
      $mdiffvmdataref->[$filenum] =
	[
	 [ map { $_->[0] } @$data ],
	 [ map { $_->[1] } @$data ],
	];
    }
    if ($calc_sections{'3dToutcount'}) {
      my $data = $arraystats->{'masked_outlier_count'}->{'data'};
      $maskedoutliercountdataref->[$filenum] =
	[
	 [ map { $_->[0] } @$data ],
	 [ map { $_->[1] } @$data ],
	];
    }
    if ($calc_sections{'3dToutcount'}) {
      my $data = $arraystats->{'masked_outlier_percent'}->{'data'};
      $maskedoutlierpercentdataref->[$filenum] =
	[
	 [ map { $_->[0] } @$data ],
	 [ map { $_->[1] } @$data ],
	];
    }
    if (grep {$_} @calc_sections{'3dFWHMx-X', '3dFWHMx-Y', '3dFWHMx-Z'}) {
      my $indexdata = undef;
      for my $key ('masked_fwhmx', 'masked_fwhmy', 'masked_fwhmz') {
	if (exists $arraystats->{$key}) {
	  $indexdata = $arraystats->{$key}->{'data'};
	  last;
	}
      }
      $maskedfwhmdataref->[$filenum] =
	[
	 [ map { $_->[0] } @$indexdata ],
	 $calc_sections{'3dFWHMx-X'} ? [ map { $_->[1] } @{$arraystats->{'masked_fwhmx'}->{'data'}} ] : undef,
	 $calc_sections{'3dFWHMx-Y'} ? [ map { $_->[1] } @{$arraystats->{'masked_fwhmy'}->{'data'}} ] : undef,
	 $calc_sections{'3dFWHMx-Z'} ? [ map { $_->[1] } @{$arraystats->{'masked_fwhmz'}->{'data'}} ] : undef,
	];
    }
    for my $method (@methods) {
      $storedmins{$method}->[$filenum] = $imagerefs->{"${method}_min"};
      $storedmaxs{$method}->[$filenum] = $imagerefs->{"${method}_max"};
      $storedscalemins{$method}->[$filenum] = $imagerefs->{"${method}_scaled_min"};
      $storedscalemaxs{$method}->[$filenum] = $imagerefs->{"${method}_scaled_max"};
    }
  }
}

# these store the range of the scaled ranges storedscalemins, storedscalemaxs, for each method.
my %totalmins = ();
my %totalmaxs = ();

# create scaled mean, stddev, sfnr images, using similar
# colormap scales for every run to facilitate comparisons
for my $filenum (0..$#ARGV) {
  for my $method (@methods) {
    if ($filenum == 0 ||
	$storedscalemins{$method}->[$filenum] < $totalmins{$method}) {
      $totalmins{$method} = $storedscalemins{$method}->[$filenum];
    }
    if ($filenum == 0 ||
	$storedscalemaxs{$method}->[$filenum] > $totalmaxs{$method}) {
      $totalmaxs{$method} = $storedscalemaxs{$method}->[$filenum];
    }
  }
}
log_stderr("Creating common-scaled images for mean/stddev/sfnr images: ");
for my $filenum (0..$#ARGV) {
  my $label = $filelabels[$filenum];
  log_stderr(" (${label})");
  for my $method (@methods) {
    if ($method eq 'mask') {
      # did this already
      next;
    }
    my $fullbxhfn = $storedfullfns{$method}->{'bxh'}->{'data'}->[$filenum];
    my $fullppmfn = $storedfullfns{$method}->{'ppm'}->{'data'}->[$filenum];
    my $fullpngfn = $storedfullfns{$method}->{'png'}->{'data'}->[$filenum];
    my $fulljpgfn = $storedfullfns{$method}->{'jpg'}->{'data'}->[$filenum];
    my $pngfn = $storedfns{$method}->{'png'}->{'data'}->[$filenum];
    my $jpgfn = $storedfns{$method}->{'jpg'}->{'data'}->[$filenum];
    my $fullcbarppmfn = $storedfullfns{$method}->{'ppm'}->{'cbar'}->[$filenum];
    my $fullcbarjpgfn = $storedfullfns{$method}->{'jpg'}->{'cbar'}->[$filenum];
    my $cbarjpgfn = $storedfns{$method}->{'jpg'}->{'cbar'}->[$filenum];
    if (-e $fullppmfn && $opt_overwrite) {
      unlink($fullppmfn);
    }
    if (-e $fulljpgfn && $opt_overwrite) {
      unlink($fulljpgfn);
    }
    if (-e $fullcbarppmfn && $opt_overwrite) {
      unlink($fullcbarppmfn);
    }
    if (-e $fullcbarjpgfn && $opt_overwrite) {
      unlink($fullcbarjpgfn);
    }
    my $tilerows = 6;
    if (exists($filemetadata[$filenum]->{'dims'})) {
      my $dims = $filemetadata[$filenum]->{'dims'};
      if (exists($dims->{'z'})) {
	my $zdimref = $dims->{'z'};
	$tilerows = int(($zdimref->{'size'} + 5) / 6)
      } elsif (grep { /^z-split$/ } keys %$dims) {
	my @sortsplits = sort { $a cmp $b } grep { /^z-split$/ } keys %$dims;
	my $zdimref = $dims->{$sortsplits[$#sortsplits]};
	$tilerows = int(($zdimref->{'size'} + 5) / 6)
      }
    }
    my $minval = $totalmins{$method};
    my $maxval = $totalmaxs{$method};
    my @colorbaropts = ("--colorbar=$fullcbarppmfn", "--barwidth=16", "--barlength=384");
    if ($method eq 'mean') {
      run_and_log_cmd($logfh, $progbxh2ppm, @colorbaropts, "--minval=$minval", "--maxval=$maxval", $fullbxhfn, $fullppmfn);
      run_and_log_cmd($logfh, $progmontage, "-geometry", "64x64", "-tile", "6x$tilerows", $fullppmfn, $fulljpgfn);
      run_and_log_cmd($logfh, $progconvert, $fullcbarppmfn, $fullcbarjpgfn);
    } elsif ($method eq 'sfnr') {
      run_and_log_cmd($logfh, $progbxh2ppm, @colorbaropts, "--minval=$minval", "--maxval=$maxval", $fullbxhfn, $fullppmfn);
      run_and_log_cmd($logfh, $progconvert, "-geometry", "384x384", $fullppmfn, $fulljpgfn);
      run_and_log_cmd($logfh, $progconvert, $fullcbarppmfn, $fullcbarjpgfn);
    } elsif ($method eq 'stddev') {
      $minval = 0;
      $maxval = .3 * ($totalmaxs{'mean'} - $totalmins{'mean'});
      run_and_log_cmd($logfh, $progbxh2ppm, @colorbaropts, "--colormap=grayhot", "--minval=$minval", "--maxval=$maxval", $fullbxhfn, $fullppmfn);
      run_and_log_cmd($logfh, $progmontage, "-geometry", "64x64", "-tile", "6x$tilerows", $fullppmfn, $fulljpgfn);
      run_and_log_cmd($logfh, $progconvert, $fullcbarppmfn, $fullcbarjpgfn);
    } elsif ($method eq 'slicevar') {
      # we did slicevar before, but we just need to create the per-run colorbars
      $minval = 0;
      $maxval = 30;
      run_and_log_cmd($logfh, $progbxh2ppm, "--dimorder=t,z", @colorbaropts, "--minval=$minval", "--maxval=$maxval", "--colormap=bgr", $fullbxhfn, $fullcbarppmfn);
      run_and_log_cmd($logfh, $progconvert, $fullcbarppmfn, $fullcbarjpgfn);
    }
    if ($method eq 'slicevar') {
      $statlist[$filenum]->{'imagerefs'}->{"${method}_cbar"} = $cbarjpgfn;
    } else {
      $statlist[$filenum]->{'imagerefs'}->{"${method}_data"} = $jpgfn;
      $statlist[$filenum]->{'imagerefs'}->{"${method}_cbar"} = $cbarjpgfn;
    }
  }
  # clean up now unnecessary files
  my @delmethods = ();
  for my $type ('bxh', 'nii.gz', 'ppm', 'raw.ppm', 'raw.jpg') {
    if ($type eq 'bxh' || $type eq 'nii.gz') {
      if ($calc_sections{'meanstddevsfnr'}) {
	push @delmethods, 'mean' if $opt_deletemean;
	push @delmethods, 'stddev' if $opt_deletestddev;
	push @delmethods, 'sfnr' if $opt_deletesfnr;
	push @delmethods, 'mask' if $opt_deletemask;
      }
      if ($calc_sections{'slicevar'}) {
	push @delmethods, 'slicevar' if $opt_deleteslicevar;
      }
    } else {
      if ($calc_sections{'meanstddevsfnr'}) {
	push @delmethods, 'mean';
	push @delmethods, 'stddev';
	push @delmethods, 'sfnr';
	push @delmethods, 'mask';
      }
      if ($calc_sections{'slicevar'}) {
	push @delmethods, 'slicevar';
      }
    }
    for my $delmethod (@delmethods) {
      unlink($storedfullfns{$delmethod}->{$type}->{'data'}->[$filenum])
	if (-e $storedfullfns{$delmethod}->{$type}->{'data'}->[$filenum]);
      unlink($storedfullfns{$delmethod}->{$type}->{'cbar'}->[$filenum])
	if (-e $storedfullfns{$delmethod}->{$type}->{'cbar'}->[$filenum]);
    }
  }
}
log_stderr("\n");


#################
### Plot data ###
#################

my $plothashref = undef;
my $vmplotref = undef;
my $cmxplotref = undef;
my $cmyplotref = undef;
my $cmzplotref = undef;
my $maskedvmplotref = undef;
my $maskedcmxplotref = undef;
my $maskedcmyplotref = undef;
my $maskedcmzplotref = undef;
my $mdiffvmplotref = undef;
my $maskedtdiffvmplotref = undef;
my $maskedoutlierpercentplotref = undef;
my $maskedfwhmxplotref = undef;
my $maskedfwhmyplotref = undef;
my $maskedfwhmzplotref = undef;
my $spectrummeanplotref = undef;
my $spectrummaxplotref = undef;

# some of these will be undefined if the data was not calculated
my $maskedvmdatamean = calcmean(map { @{$_->[1]} } @{$maskedvmdataref});
my $maskedcomxdatamean = calcmean(map { @{$_->[1]} } @{$maskedcomdataref});
my $maskedcomydatamean = calcmean(map { @{$_->[2]} } @{$maskedcomdataref});
my $maskedcomzdatamean = calcmean(map { @{$_->[3]} } @{$maskedcomdataref});
my $maskedtdiffvmdatamean = calcmean(map { @{$_->[1]} } @{$maskedtdiffvmdataref});
my $mdiffvmdatamean = calcmean(map { @{$_->[1]} } @{$mdiffvmdataref});
my $vmdatamean = calcmean(map { @{$_->[1]} } @{$vmdataref});

if ($opt_standardizedetrendedmeans) {
  map {
    my $indivmean = calcmean(@{$_->[1]});
    map { $_ = $_ - $indivmean + $maskedvmdatamean } @{$_->[1]};
  } @{$maskedvmdataref};
  map {
    my $indivmeanx = calcmean(@{$_->[1]});
    map { $_ = $_ - $indivmeanx + $maskedcomxdatamean } @{$_->[1]};
    my $indivmeany = calcmean(@{$_->[2]});
    map { $_ = $_ - $indivmeany + $maskedcomydatamean } @{$_->[2]};
    my $indivmeanz = calcmean(@{$_->[3]});
    map { $_ = $_ - $indivmeanz + $maskedcomzdatamean } @{$_->[3]};
  } @{$maskedcomdataref};
}

# plot volume means
if ($calc_sections{'volumemeans'}) {
  log_msg($logfh, "# Plotting volume means (input)...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'volmeans',
     'dataref'       => $vmdataref,
     'plotlabelsref' => \@filelabels,
     'plottitle'     => "Mean intensity per volume",
     'xlabel'        => 'Volume number',
     'ylabel'        => 'Mean intensity\\n(percent difference from mean)',
     'normmethod'    => 1,
     'yrangeref'     => [-3, 3],
     'metadataref'   => \@filemetadata,
    };
  $vmplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}

if ($calc_sections{'maskedvolumemeans'}) {
  log_msg($logfh, "# Plotting volume means (w/ mask,detrend)...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'maskedvolmeans',
     'dataref'       => $maskedvmdataref,
     'plotlabelsref' => \@filelabels,
     'plottitle'     => "Mean intensity per volume (w/mask,detrend)",
     'xlabel'        => 'Volume number',
     'ylabel'        => 'Mean intensity\\n(percent difference from mean)',
     'normmethod'    => 1,
     'yrangeref'     => [-3, 3],
     'metadataref'   => \@filemetadata,
    };
  $maskedvmplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}

if ($calc_sections{'maskedtdiffvolumemeans'}) {
  log_msg($logfh, "# Plotting running difference (w/ mask,detrend)...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'maskedtdiffvolmeans',
     'dataref'       => $maskedtdiffvmdataref,
     'plotlabelsref' => \@filelabels,
     'plottitle'     => 'Mean of running difference per volume (w/mask,detrend)',
     'xlabel'        => 'Volume number',
     'ylabel'        => 'Mean of running difference volume\\n(percent difference from normbaseline)',
     'normmethod'    => 1,
     'yrangeref'     => [-3, 3],
     'metadataref'   => \@filemetadata,
     'normbaseline'  => $maskedvmdatamean,
     'histobintype'  => "explicitpercent 1 ${maskedvmdatamean}",
     'histoxlabel'   => 'percent diff from normbaseline',
     'threshmin1'    => $maskedtdiffvmdatamean - ($opt_percthresh1 * $maskedvmdatamean / 100),
     'threshmax1'    => $maskedtdiffvmdatamean + ($opt_percthresh1 * $maskedvmdatamean / 100),
     'threshmin2'    => $maskedtdiffvmdatamean - ($opt_percthresh2 * $maskedvmdatamean / 100),
     'threshmax2'    => $maskedtdiffvmdatamean + ($opt_percthresh2 * $maskedvmdatamean / 100),
    };
  $maskedtdiffvmplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}

if ($calc_sections{'meandiffvolumemeans'}) {
  log_msg($logfh, "# Plotting mean volume difference...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'mdiffvolmeans',
     'dataref'       => $mdiffvmdataref,
     'plotlabelsref' => \@filelabels,
     'plottitle'     => 'Mean of mean volume difference',
     'xlabel'        => 'Volume number',
     'ylabel'        => 'Mean of mean volume difference\\n(percent difference from normbaseline)',
     'normmethod'    => 1,
     'yrangeref'     => [-3, 3],
     'metadataref'   => \@filemetadata,
     'normbaseline'  => $vmdatamean,
     'histobintype'  => "explicitpercent 1 ${vmdatamean}",
     'histoxlabel'   => 'percent diff from normbaseline',
     'threshmin1'    => $mdiffvmdatamean - ($opt_percthresh1 * $vmdatamean / 100),
     'threshmax1'    => $mdiffvmdatamean + ($opt_percthresh1 * $vmdatamean / 100),
     'threshmin2'    => $mdiffvmdatamean - ($opt_percthresh2 * $vmdatamean / 100),
     'threshmax2'    => $mdiffvmdatamean + ($opt_percthresh2 * $vmdatamean / 100),
    };
  $mdiffvmplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}

if (grep {$_} @calc_sections{@sections_cmass}) {
  # plot center of mass(es)
  my %units2range = ();
  map { $units2range{$_} = undef; } @comunits;
  $units2range{'voxels'} = [-1.5, 1.5];
  $units2range{'mm'} = [-5, 5];
  # template plot hash
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotlabelsref' => \@filelabels,
     'xlabel'        => 'Volume number',
     'normmethod'    => 2,
     'metadataref'   => \@filemetadata,
    };
  if ($calc_sections{'cmassx'}) {
    log_msg($logfh, "# Plotting center of mass (X) (input)...\n");
    $plothashref->{'plotname'} = 'cmassx';
    $plothashref->{'dataref'} = [ map { [ $_->[0], $_->[1] ] } @$comdataref ];
    $plothashref->{'plottitle'} = 'Center of Mass (X) by volume';
    $plothashref->{'ylabel'} = "Displacement (in $comunits[0]) from mean";
    $plothashref->{'yrangeref'} = $units2range{$comunits[0]};
    $cmxplotref = plotdata($proggnuplot, $progconvert, $plothashref);
  }
  if ($calc_sections{'maskedcmassx'}) {
    log_msg($logfh, "# Plotting center of mass (X) (w/ mask,detrend)...\n");
    $plothashref->{'plotname'} = 'maskedcmassx';
    $plothashref->{'dataref'} = [ map { [ $_->[0], $_->[1] ] } @$maskedcomdataref ];
    $plothashref->{'plottitle'} = 'Center of Mass (X) by volume';
    $plothashref->{'ylabel'} = "Displacement (in $comunits[0]) from mean";
    $plothashref->{'yrangeref'} = $units2range{$comunits[0]};
    $maskedcmxplotref = plotdata($proggnuplot, $progconvert, $plothashref);
  }
  if ($calc_sections{'cmassy'}) {
    log_msg($logfh, "# Plotting center of mass (Y) (input)...\n");
    $plothashref->{'plotname'} = 'cmassy';
    $plothashref->{'dataref'} = [ map { [ $_->[0], $_->[2] ] } @$comdataref ];
    $plothashref->{'plottitle'} = 'Center of Mass (Y) by volume';
    $plothashref->{'ylabel'} = "Displacement (in $comunits[1]) from mean";
    $plothashref->{'yrangeref'} = $units2range{$comunits[1]};
    $cmyplotref = plotdata($proggnuplot, $progconvert, $plothashref);
  }
  if ($calc_sections{'maskedcmassy'}) {
    log_msg($logfh, "# Plotting center of mass (Y) (w/ mask,detrend)...\n");
    $plothashref->{'plotname'} = 'maskedcmassy';
    $plothashref->{'dataref'} = [ map { [ $_->[0], $_->[2] ] } @$maskedcomdataref ];
    $plothashref->{'plottitle'} = 'Center of Mass (Y) by volume';
    $plothashref->{'ylabel'} = "Displacement (in $comunits[1]) from mean";
    $plothashref->{'yrangeref'} = $units2range{$comunits[1]};
    $maskedcmyplotref = plotdata($proggnuplot, $progconvert, $plothashref);
  }
  if ($calc_sections{'cmassz'}) {
    log_msg($logfh, "# Plotting center of mass (Z) (input)...\n");
    $plothashref->{'plotname'} = 'cmassz';
    $plothashref->{'dataref'} = [ map { [ $_->[0], $_->[3] ] } @$comdataref ];
    $plothashref->{'plottitle'} = 'Center of Mass (Z) by volume';
    $plothashref->{'ylabel'} = "Displacement (in $comunits[2]) from mean";
    $plothashref->{'yrangeref'} = $units2range{$comunits[2]};
    $cmzplotref = plotdata($proggnuplot, $progconvert, $plothashref);
  }
  if ($calc_sections{'maskedcmassz'}) {
    log_msg($logfh, "# Plotting center of mass (Z) (w/ mask,detrend)...\n");
    $plothashref->{'plotname'} = 'maskedcmassz';
    $plothashref->{'dataref'} = [ map { [ $_->[0], $_->[3] ] } @$maskedcomdataref ];
    $plothashref->{'plottitle'} = 'Center of Mass (Z) by volume';
    $plothashref->{'ylabel'} = "Displacement (in $comunits[2]) from mean";
    $plothashref->{'yrangeref'} = $units2range{$comunits[2]};
    $maskedcmzplotref = plotdata($proggnuplot, $progconvert, $plothashref);
  }
}

if ($calc_sections{'3dToutcount'}) {
  # plot number of outliers
    log_msg($logfh, "# Plotting outlier voxel counts (w/ mask,detrend)...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'outliercount',
     'dataref'       => $maskedoutlierpercentdataref,
     'plotlabelsref' => \@filelabels,
     'plottitle'     => "Percent of outlier voxels (AFNI 3dToutcount)",
     'xlabel'        => 'Volume number',
     'ylabel'        => 'Percent of outlier voxels',
     'normmethod'    => 0,
     'yrangeref'     => undef,
     'metadataref'   => \@filemetadata,
     'histobintype'  => "explicit 1 0",
    };
  $maskedoutlierpercentplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}

if ($calc_sections{'3dFWHMx-X'}) {
  # plot FWHM
  log_msg($logfh, "# Plotting FWHMx-X (w/ mask)...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'FWHMx-X',
     'dataref'       =>  [ map { [ $_->[0], $_->[1] ] } @$maskedfwhmdataref ],
     'plotlabelsref' => \@filelabels,
     'plottitle'     => "Full-width half maximum in X dimension (AFNI 3dFWHMx)",
     'xlabel'        => 'Volume number',
     'ylabel'        => 'Full-width half maximum',
     'normmethod'    => 0,
     'yrangeref'     => undef,
     'metadataref'   => \@filemetadata,
    };
  $maskedfwhmxplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}

if ($calc_sections{'3dFWHMx-Y'}) {
  log_msg($logfh, "# Plotting FWHMx-Y (w/ mask)...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'FWHMx-Y',
     'dataref'       =>  [ map { [ $_->[0], $_->[2] ] } @$maskedfwhmdataref ],
     'plotlabelsref' => \@filelabels,
     'plottitle'     => "Full-width half maximum in Y dimension (AFNI 3dFWHMx)",
     'xlabel'        => 'Volume number',
     'ylabel'        => 'Full-width half maximum',
     'normmethod'    => 0,
     'yrangeref'     => undef,
     'metadataref'   => \@filemetadata,
    };
  $maskedfwhmyplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}

if ($calc_sections{'3dFWHMx-Z'}) {
  log_msg($logfh, "# Plotting FWHMx-Z (w/ mask)...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'FWHMx-Z',
     'dataref'       =>  [ map { [ $_->[0], $_->[3] ] } @$maskedfwhmdataref ],
     'plotlabelsref' => \@filelabels,
     'plottitle'     => "Full-width half maximum in Z dimension (AFNI 3dFWHMx)",
     'xlabel'        => 'Volume number',
     'ylabel'        => 'Full-width half maximum',
     'normmethod'    => 0,
     'yrangeref'     => undef,
     'metadataref'   => \@filemetadata,
    };
  $maskedfwhmzplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}

# plot spectrum
if ($calc_sections{'spectrummean'}) {
  log_msg($logfh, "# Plotting spectrum (mean)...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'spectrummean',
     'dataref'       => [ map { [ $_->[3], $_->[1] ] } @$spectrumdataref ],
     'plotlabelsref' => \@filelabels,
     'plottitle'     => "Mean (over ROI) spectrum",
     'xlabel'        => "Frequency ($spectrumxunits)",
     'ylabel'        => 'Magnitude',
     'yrange'        => [0, undef],
     'normmethod'    => 0,
     'indivrange'    => 1,
     'metadataref'   => \@filemetadata,
    };
  $spectrummeanplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}
if ($calc_sections{'spectrummax'}) {
  log_msg($logfh, "# Plotting spectrum (max)...\n");
  $plothashref =
    {
     'gnuplotimgtype' => $gnuplotimgtype,
     'outputfh'      => *HTMLFH{IO},
     'outputvol'     => $outputvol,
     'outputdir'     => $outputdir,
     'plotname'      => 'spectrummax',
     'dataref'       => [ map { [ $_->[3], $_->[2] ] } @$spectrumdataref ],
     'plotlabelsref' => \@filelabels,
     'plottitle'     => "Max (over ROI) spectrum",
     'xlabel'        => "Frequency ($spectrumxunits)",
     'ylabel'        => 'Magnitude',
     'yrange'        => [0, undef],
     'normmethod'    => 0,
     'indivrange'    => 1,
     'metadataref'   => \@filemetadata,
    };
  $spectrummaxplotref = plotdata($proggnuplot, $progconvert, $plothashref);
}

### calculate some more summary stats
my @z1gs = ();
my @maskedz1gs = ();
my @z2gs = ();
my @maskedz2gs = ();
my @maskedtdiffp1gs = ();
my @maskedtdiffp2gs = ();
my @mdiffp1gs = ();
my @mdiffp2gs = ();

if ($calc_sections{'volumemeans'}) {
  # number of volume means greater than $opt_zthresh1 std devs.
  # from the grand mean
  @z1gs = map {
    0 + grep {
      abs(($_ - $vmplotref->{'datamean'}) / no_zero($vmplotref->{'datastddev'})) > $opt_zthresh1
    } @{$vmdataref->[$_]->[1]}
  } (0..$#filelabels);
  # same for $opt_zthresh2
  @z2gs = map {
    0 + grep {
      abs(($_ - $vmplotref->{'datamean'}) / no_zero($vmplotref->{'datastddev'})) > $opt_zthresh2
    } @{$vmdataref->[$_]->[1]}
  } (0..$#filelabels);
  # number of volume means greater than $opt_zthresh1 std devs.
  # from individual means
  @z1s = map {
    my $filenum = $_;
    0 + grep {
      abs(($_ - $vmplotref->{'datameansref'}->[$filenum]) / no_zero($vmplotref->{'datastddevsref'}->[$filenum])) > $opt_zthresh1
    } @{$vmdataref->[$_]->[1]}
  } (0..$#filelabels);
  # same for $opt_zthresh2
  @z2s = map {
    my $filenum = $_;
    0 + grep {
      abs(($_ - $vmplotref->{'datameansref'}->[$filenum]) / no_zero($vmplotref->{'datastddevsref'}->[$filenum])) > $opt_zthresh2
    } @{$vmdataref->[$_]->[1]}
  } (0..$#filelabels);
}

if ($calc_sections{'maskedvolumemeans'}) {
  # number of masked volume means greater than $opt_zthresh1 std devs.
  # from the grand mean
  @maskedz1gs = map {
    0 + grep {
      abs(($_ - $maskedvmplotref->{'datamean'}) / no_zero($maskedvmplotref->{'datastddev'})) > $opt_zthresh1
    } @{$maskedvmdataref->[$_]->[1]}
  } (0..$#filelabels);
  # same for $opt_zthresh2
  @maskedz2gs = map {
    0 + grep {
      abs(($_ - $maskedvmplotref->{'datamean'}) / no_zero($maskedvmplotref->{'datastddev'})) > $opt_zthresh2
    } @{$maskedvmdataref->[$_]->[1]}
  } (0..$#filelabels);
  @maskedz1s = map {
    my $filenum = $_;
    0 + grep {
      abs(($_ - $maskedvmplotref->{'datameansref'}->[$filenum]) / no_zero($maskedvmplotref->{'datastddevsref'}->[$filenum])) > $opt_zthresh1
    } @{$maskedvmdataref->[$_]->[1]}
  } (0..$#filelabels);
  @maskedz2s = map {
    my $filenum = $_;
    0 + grep {
      abs(($_ - $maskedvmplotref->{'datameansref'}->[$filenum]) / no_zero($maskedvmplotref->{'datastddevsref'}->[$filenum])) > $opt_zthresh2
    } @{$maskedvmdataref->[$_]->[1]}
  } (0..$#filelabels);
}

if ($calc_sections{'maskedtdiffvolumemeans'}) {
  # number of volumes whose running difference is greater than
  # $opt_percthresh1 or $opt_percthresh2 percent from the grand mean
  @maskedtdiffp1gs = map {
    0 + grep { 100 * abs($_ - $maskedtdiffvmplotref->{'datamean'}) / no_zero($maskedvmdatamean) > $opt_percthresh1 } @{$maskedtdiffvmdataref->[$_]->[1]}
  } (0..$#filelabels);
  @maskedtdiffp2gs = map {
    0 + grep { 100 * abs($_ - $maskedtdiffvmplotref->{'datamean'}) / no_zero($maskedvmdatamean) > $opt_percthresh2 } @{$maskedtdiffvmdataref->[$_]->[1]}
  } (0..$#filelabels);
}

if ($calc_sections{'meandiffvolumemeans'}) {
  # number of volumes whose mean volume difference is greater than
  # $opt_percthresh1 or $opt_percthresh2 from the grand mean
  @mdiffp1gs = map {
    0 + grep { 100 * abs($_ - $mdiffvmplotref->{'datamean'}) / no_zero($vmdatamean) > $opt_percthresh1 } @{$mdiffvmdataref->[$_]->[1]}
  } (0..$#filelabels);
  @mdiffp2gs = map {
    0 + grep { 100 * abs($_ - $mdiffvmplotref->{'datamean'})  / no_zero($vmdatamean) > $opt_percthresh2 } @{$mdiffvmdataref->[$_]->[1]}
  } (0..$#filelabels);
}

if ($calc_sections{'3dToutcount'}) {
  # number of volumes with greater than $opt_percthresh1 percent outlier voxels
  @outp1s = map {
    my $filenum = $_;
    0 + grep { $_ > $opt_percthresh1 } @{$maskedoutlierpercentdataref->[$_]->[1]}
  } (0..$#filelabels);
  # number of volumes with greater than $opt_percthresh1 percent outlier voxels
  @outp2s = map {
    my $filenum = $_;
    0 + grep { $_ > $opt_percthresh2 } @{$maskedoutlierpercentdataref->[$_]->[1]}
  } (0..$#filelabels);
}

# mean FWHMS
if ($calc_sections{'3dFWHMx-X'}) {
  @maskedmeanfwhmx = map {
    0 + sprintf("%0.3f", calcmean(@{$maskedfwhmdataref->[$_]->[1]}))
  } (0..$#filelabels);
}
if ($calc_sections{'3dFWHMx-Y'}) {
  @maskedmeanfwhmy = map {
    0 + sprintf("%0.3f", calcmean(@{$maskedfwhmdataref->[$_]->[2]}))
  } (0..$#filelabels);
}
if ($calc_sections{'3dFWHMx-Y'}) {
  @maskedmeanfwhmz = map {
    0 + sprintf("%0.3f", calcmean(@{$maskedfwhmdataref->[$_]->[3]}))
  } (0..$#filelabels);
}

######################################
### Calculate more XML events data ###
######################################
my @statlist_group = ();
for my $filenum (0..$#filelabels) {
  push @statlist_group, {'imagerefs' => {}, 'scalarstats' => {}, 'arraystats' => {}};
}
{
  # do "group" statistics
  for my $filenum (0..$#filelabels) {
    my $statref = $statlist_group[$filenum];
    my $scalarstats = $statref->{'scalarstats'};
    my $arraystats = $statref->{'arraystats'};
    my $filelabel = $filelabels[$filenum];
    $filelabel =~ s%[\\/]%_%g;

    my $wholerunvalues_group = $scalarstats;
    if ($calc_sections{'volumemeans'}) {
      $wholerunvalues_group->{"count_volmean_grand_z${opt_zthresh1}"} = $z1gs[$filenum];
      $wholerunvalues_group->{"count_volmean_grand_z${opt_zthresh2}"} = $z2gs[$filenum];
    }
    if ($calc_sections{'maskedvolumemeans'}) {
      $wholerunvalues_group->{"count_volmean_grand_masked_z${opt_zthresh1}"} = $maskedz1gs[$filenum];
      $wholerunvalues_group->{"count_volmean_grand_masked_z${opt_zthresh2}"} = $maskedz2gs[$filenum];
    }
    if ($calc_sections{'meandiffvolumemeans'}) {
      $wholerunvalues_group->{"count_mean_difference_group_${opt_percthresh1}percent"} = $mdiffp1gs[$filenum];
      $wholerunvalues_group->{"count_mean_difference_group_${opt_percthresh2}percent"} = $mdiffp2gs[$filenum];
      $wholerunvalues_group->{"threshmin_mean_difference_${opt_percthresh1}percent"} = $mdiffvmplotref->{'threshmin1'};
      $wholerunvalues_group->{"threshmax_mean_difference_${opt_percthresh1}percent"} = $mdiffvmplotref->{'threshmax1'};
      $wholerunvalues_group->{"threshmin_mean_difference_${opt_percthresh2}percent"} = $mdiffvmplotref->{'threshmin2'};
      $wholerunvalues_group->{"threshmax_mean_difference_${opt_percthresh2}percent"} = $mdiffvmplotref->{'threshmax2'};
    }
    if ($calc_sections{'maskedtdiffvolumemeans'}) {
      $wholerunvalues_group->{"count_velocity_grand_masked_${opt_percthresh1}percent"} = $maskedtdiffp1gs[$filenum];
      $wholerunvalues_group->{"count_velocity_grand_masked_${opt_percthresh2}percent"} = $maskedtdiffp2gs[$filenum];
      $wholerunvalues_group->{"threshmin_masked_velocity_${opt_percthresh1}percent"} = $maskedtdiffvmplotref->{'threshmin1'};
      $wholerunvalues_group->{"threshmax_masked_velocity_${opt_percthresh1}percent"} = $maskedtdiffvmplotref->{'threshmax1'};
      $wholerunvalues_group->{"threshmin_masked_velocity_${opt_percthresh2}percent"} = $maskedtdiffvmplotref->{'threshmin2'};
      $wholerunvalues_group->{"threshmax_masked_velocity_${opt_percthresh2}percent"} = $maskedtdiffvmplotref->{'threshmax2'};
    }

    for my $masked (0, 1) {
      my $sectionname = "volumemeans";
      if ($masked) {
	$sectionname = "maskedvolumemeans";
      }
      if ($calc_sections{$sectionname}) {
	my $dataref = $vmdataref;
	my $maskedprefix = '';
	my $maskedparen = '';
	my $normmean = $vmplotref->{'datamean'};
	my $normstddev = no_zero($vmplotref->{'datastddev'});
	if ($masked) {
	  $dataref = $maskedvmdataref;
	  $maskedprefix = 'masked_';
	  $maskedparen = ' (masked, detrended)';
	  $normmean = $maskedvmplotref->{'datamean'};
	  $normstddev = $maskedvmplotref->{'datastddev'};
	}
	my $statname = "${maskedprefix}volmean";
	my $datacol = [ map { ($_ - $normmean) / $normstddev } @{$dataref->[$filenum]->[1]} ];
	my $count = scalar(@$datacol);
	my ($mean, $stddev) = calcmeanstddev(@$datacol);
	my $nozerostddev = no_zero($stddev);
	$arraystats->{"${statname}_z_grand"} =
	  {
	   'name'    => "${statname}_z_grand",
	   'xlabel'  => 'Volume number',
	   'ylabel'  => "Z-score (across runs) of mean intensity${maskedparen}",
	   'xunits'  => 'vols',
	   'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	   'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	  };
      }
    }
    
    my %complotrefhash =
      (
       0 => { 'x' => $cmxplotref, 'y' => $cmyplotref, 'z' => $cmzplotref },
       1 => { 'x' => $maskedcmxplotref, 'y' => $maskedcmyplotref, 'z' => $maskedcmzplotref },
      );
    for my $entry (['x', 1], ['y', 2], ['z', 3]) {
      my ($direction, $colnum) = @$entry;
      for my $masked (0, 1) {
	my $sectionname = "cmass${direction}";
	if ($masked) {
	  $sectionname = "maskedcmass${direction}";
	}
	if ($calc_sections{$sectionname}) {
	  my $dataref = $comdataref;
	  my $maskedprefix = '';
	  my $maskedparen = '';
	  if ($masked) {
	    $dataref = $maskedcomdataref;
	    $maskedprefix = 'masked_';
	    $maskedparen = ' (masked, detrended)';
	  }
	  my $plotref = $complotrefhash{$masked}->{$direction};
	  my $normmean = $plotref->{'datamean'};
	  my $normstddev = no_zero($plotref->{'datastddev'});
	  my $statname = "${maskedprefix}cmass${direction}";
	  my $datacol = [ map { abs($_ - $normmean) } @{$dataref->[$filenum]->[$colnum]} ];
	  my $count = scalar(@$datacol);
	  my ($mean, $stddev) = calcmeanstddev(@$datacol);
	  $arraystats->{"${statname}_disp_grand"} =
	    {
	     'name'    => "${statname}_disp_grand",
	     'xlabel'  => 'Volume number',
	     'ylabel'  => "Center of mass${maskedparen} displacement from mean across runs in $direction direction",
	     'xunits'  => 'vols',
	     'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	     'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	    };
	  $datacol = [ map { $_ / $normstddev } @$datacol ];
	  $count = scalar(@$datacol);
	  ($mean, $stddev) = calcmeanstddev(@$datacol);
	  $arraystats->{"${statname}_z_grand"} =
	    {
	     'name'    => "${statname}_z_grand",
	     'xlabel'  => 'Volume number',
	     'ylabel'  => "Z-score of center of mass${maskedparen} across runs in $direction direction",
	     'xunits'  => 'vols',
	     'summary' => { 'count' => $count, 'mean' => $mean, 'stddev' => $stddev },
	     'data'    => [ map { [ $_, $datacol->[$_] ] } (0..($count-1)) ],
	    };
	}
      }
    }
  }
}


##########################
### Start writing HTML ###
##########################

if (!defined($opt_qalabel)) {
  $opt_qalabel = "QA stats for $basepath";
}

# open HTML file for writing
my $htmlfile = File::Spec->catpath($outputvol, $outputdir, $opt_indexjs ? 'index-nonjs.html' : 'index.html');
open(HTMLFH, ">$htmlfile")
  || logdie($logfh, "Error opening HTML file $htmlfile: $!");

# write CSS stuff
my $cssfile = File::Spec->catpath($outputvol, $outputdir, 'index.css');
open(CSSFH, ">$cssfile")
  || logdie($logfh, "Error opening CSS file $cssfile: $!");
print CSSFH <<EOM;
 table.bordered tr td {border: 1px solid gray;}
 table.striped {
  border-top: 2px solid #C0D0E0;
  border-left: 2px solid #C0D0E0;
  border-bottom: 4px solid #F8F8F8;
  border-right: 4px solid #F8F8F8;
 }
 table.striped .header {
  font-style: italic;
 }
 table.striped td {
  border-bottom: 1px solid #EEE;
 }
 .title {
  font-size: 1.5em;
  font-weight: bold;
  display: block;
 }
 .titlebanner {
  font-size: 1.5em;
  font-weight: bold;
  display: block;
  margin-left: 10px;
  margin-right: 10px;
  background-color: #F0F4FF;
  border-top: 3px solid #C0D0E0;
  border-left: 3px solid #C0D0E0;
  border-bottom: 3px solid #F8F8F8;
  border-right: 3px solid #F8F8F8;
 }
 body {
  font-family: sans-serif;
 }
 body>h1 {font-size: larger;}
 .colorbar {
   background-color: #dddddd;
 }
 .cbarmin {font-size: smaller; text-align: left;}
 .cbarmax {font-size: smaller; text-align: right;}
 .imgmin {font-size: smaller;}
 .imgmax {font-size: smaller;}
 .blue {
  color: #00F;
 }
 .gray {
  color: #AAA;
 }
 .darkgray {
  color: #666;
 }
 .underlined {
  text-decoration: underline;
 }
 div.body {
  max-width: 950px;
  padding: 10px;
 }
 div.navbar {
  top: 1em;
  right: 1em;
  position: fixed;
  padding: 10px;
  border: 3px solid #E0E8F0;
  background: #F0F4FF;
  height: 20em;
 }
 div.navbarclosed {
  top: 1em;
  right: 1em;
  position: fixed;
  font-size: larger;
  font-weight: bold;
  border: 3px solid #E0E8F0;
  background: #F0F4FF;
 }
 .navbarshowhidelink {
  text-decoration: none;
  text-align: center;
  font-size: smaller;
  color: #0000FF;
 }
 .navbartitle {
  text-align: center;
  font-size: larger;
  font-weight: bold;
  margin: 0px;
 }
 .navbar .select {
  background: #F8F8F8;
  border: 3px solid #E0E8F0;
  padding: 5px;
  overflow: auto;
  height: 18em;
  width: auto;
  border-collapse: collapse;
 }
 .navbar li a:visited {
  text-decoration: none;
  color: blue;
 }
 .navbar div div div.blue:hover {
  text-decoration: underline;
  color: blue;
 }
 .popupLink {
  outline: none;
 }
 .popup {
  position: absolute;
  visibility: hidden;
  background-color: #FDD;
  layer-background-color: #FDD;
  width: 200;
  border-left: 1px solid black;
  border-top: 1px solid black;
  border-bottom: 3px solid black;
  border-right: 3px solid black;
  padding: 3px;
  z-index: 10;
 }

 /* to avoid IE position:fixed bug */
 div#navbar { position: absolute; right: 1em; top: 1em; }
 div#navbarclosed { position: absolute; right: 1em; top: 1em; }
 body > div#navbar { position: fixed; }
 body > div#navbarclosed { position: fixed; }
EOM
close CSSFH;

print HTMLFH <<EOM;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0 Strict//EN">
<html>
  <head>
    <title>$opt_qalabel</title>
    <link href="index.css" type="text/css" rel="stylesheet"/>
    <script type="text/javascript"><!--
function debuglog(text) {
  var debugelem = document.getElementById('debug');
  debug.appendChild(document.createTextNode(text));
  debug.appendChild(document.createElement('br'));
  debug.appendChild(document.createTextNode('\\n'));
}
function showhide_show(id)
{
  document.getElementById(id).style.display='';
  document.getElementById('hide' + id).style.display='';
  document.getElementById('show' + id).style.display='none';
}
function showhide_hide(id)
{
  document.getElementById(id).style.display='none';
  document.getElementById('show' + id).style.display='';
  document.getElementById('hide' + id).style.display='none';
}
function showhide_cb_toggle(cbobj, id)
{
  if (cbobj.checked) {
    document.getElementById(id).style.display='';
  } else {
    document.getElementById(id).style.display='none';
  }
}
function showhide_cbid_show(cbid, id)
{
  document.getElementById(cbid).checked = true;
  document.getElementById(id).style.display='';
}
function showhide_cbid_hide(cbid, id)
{
  document.getElementById(cbid).checked = false;
  document.getElementById(id).style.display='none';
}
function stripe(id)
{
  var color1 = '#FFF';
  var color2 = '#EEE';
  var mytable = document.getElementById(id);
  var trelems = mytable.getElementsByTagName('tr');
  var numtrs = trelems.length;
  for (var trind = 0; trind < numtrs; trind++) {
    var tdelems = trelems[trind].getElementsByTagName('td');
    var numtds = tdelems.length;
    for (var tdind = 0; tdind < numtds; tdind++) {
      var tdelem = tdelems[tdind];
      if ((tdelem.getAttributeNode("class") == null ||
	   !tdelem.getAttributeNode("class").value) &&
	  !tdelem.style.backgroundColor) {
	if (trind % 2 == 1) {
	  tdelem.style.backgroundColor = color1;
	} else {
	  tdelem.style.backgroundColor = color2;
	}
      }
    }
  }
}
function getStyleObject(objectId) {
    // cross-browser function to get an objects style object given its id
    if(document.getElementById && document.getElementById(objectId)) {
	// W3C DOM
	return document.getElementById(objectId).style;
    } else if (document.all && document.all(objectId)) {
	// MSIE 4 DOM
	return document.all(objectId).style;
    } else if (document.layers && document.layers[objectId]) {
	// NN 4 DOM.. note: this wont find nested layers
	return document.layers[objectId];
    } else {
	return false;
    }
} // getStyleObject

function changeObjectVisibility(objectId, newVisibility) {
    // get a reference to the cross-browser style object and make sure the object exists
    var styleObject = getStyleObject(objectId);
    if(styleObject) {
	styleObject.visibility = newVisibility;
	return true;
    } else {
	// we couldn't find the object, so we can't change its visibility
	return false;
    }
} // changeObjectVisibility

function moveObject(objectId, newXCoordinate, newYCoordinate) {
    // get a reference to the cross-browser style object and make sure the object exists
    var styleObject = getStyleObject(objectId);
    if(styleObject) {
	styleObject.left = newXCoordinate;
	styleObject.top = newYCoordinate;
	return true;
    } else {
	// we could not find the object, so we cannot very well move it
	return false;
    }
} // moveObject

// ********************************
// application-specific functions *
// ********************************

// store variables to control where the popup will appear relative to the cursor position
// positive numbers are below and to the right of the cursor, negative numbers are above and to the left
var xOffset = 5;
var yOffset = -5;

function showPopup (targetObjectId, eventObj) {
    if(eventObj) {
	// hide any currently-visible popups
	hideCurrentPopup();
	// stop event from bubbling up any farther
	eventObj.cancelBubble = true;
	// move popup div to current cursor position 
	// (add scrollTop to account for scrolling for IE)
	var newXCoordinate = (eventObj.pageX)?eventObj.pageX + xOffset:eventObj.x + xOffset + ((document.body.scrollLeft)?document.body.scrollLeft:0);
	var newYCoordinate = (eventObj.pageY)?eventObj.pageY + yOffset:eventObj.y + yOffset + ((document.body.scrollTop)?document.body.scrollTop:0);
	moveObject(targetObjectId, newXCoordinate, newYCoordinate);
	// and make it visible
	if( changeObjectVisibility(targetObjectId, 'visible') ) {
	    // if we successfully showed the popup
	    // store its Id on a globally-accessible object
	    window.currentlyVisiblePopup = targetObjectId;
	    return true;
	} else {
	    // we could not show the popup, boo hoo!
	    return false;
	}
    } else {
	// there was no event object, so we wont be able to position anything, so give up
	return false;
    }
} // showPopup

function hideCurrentPopup() {
    // note: we have stored the currently-visible popup on the global object window.currentlyVisiblePopup
    if(window.currentlyVisiblePopup) {
	changeObjectVisibility(window.currentlyVisiblePopup, 'hidden');
	window.currentlyVisiblePopup = false;
    }
} // hideCurrentPopup



// ***********************
// hacks and workarounds *
// ***********************

// initialize hacks whenever the page loads
window.onload = initializeHacks;

// setup an event handler to hide popups for generic clicks on the document
document.onclick = hideCurrentPopup;

function initializeHacks() {
    // this ugly little hack resizes a blank div to make sure you can click
    // anywhere in the window for Mac MSIE 5
    if ((navigator.appVersion.indexOf('MSIE 5') != -1) 
	&& (navigator.platform.indexOf('Mac') != -1)
	&& getStyleObject('blankDiv')) {
	window.onresize = explorerMacResizeFix;
    }
    resizeBlankDiv();
    // this next function creates a placeholder object for older browsers
    createFakeEventObj();
}

function createFakeEventObj() {
    // create a fake event object for older browsers to avoid errors in function call
    // when we need to pass the event object to functions
    if (!window.event) {
	window.event = false;
    }
} // createFakeEventObj

function resizeBlankDiv() {
    // resize blank placeholder div so IE 5 on mac will get all clicks in window
    if ((navigator.appVersion.indexOf('MSIE 5') != -1)
	&& (navigator.platform.indexOf('Mac') != -1)
	&& getStyleObject('blankDiv')) {
	getStyleObject('blankDiv').width = document.body.clientWidth - 20;
	getStyleObject('blankDiv').height = document.body.clientHeight - 20;
    }
}

function explorerMacResizeFix () {
    location.reload(false);
}

// *** Navigation Menu functions ***
function jumpToAnchor(anchor) {
   window.location.href = String(window.location).replace(/\#.*\$/, "") + anchor;
   return false;
}
function enterNavigation(event) {
    var event = event || window.event;
    if ((event.fromElement &&
         event.fromElement != document.getElementById('navbar')) ||
        (event.target &&
         event.target != document.getElementById('navbar'))) {
        document.getElementById('navbar').style.display='';
        document.getElementById('navbarclosed').style.display='none';
    }
}
function contains(a, b)
{
    while(b && (a!=b) && (b!=null))
        b = b.parentNode;
    return a == b;
}
function exitNavigation(event) {
    var event = event || window.event;
    if ((event.fromElement &&
         event.toElement &&
         !document.getElementById('navbar').contains(event.toElement)) ||
        (event.relatedTarget &&
         !contains(document.getElementById('navbar'), event.relatedTarget))) {
        document.getElementById('navbar').style.display='none';
        document.getElementById('navbarclosed').style.display='';
    }
}
    --></script>
  </head>
  <body>
EOM

### do navigation bar
# first create a structure to represent the navigation bar, and
# what things should have links, which should be greyed out, etc.
my @navlist = ();
if (grep { scalar(@$_) > 0 } @notelist) {
  push @navlist,
    [ "Notes", $calc_sections{'notes'} ];
}
push @navlist,
  [ "Summary", $calc_sections{'summary'} ];
push @navlist,
  [ "Volume means", (grep {$_} @calc_sections{'volumemeans','maskedvolumemeans'}) ? '' : undef,
    [ "input", $calc_sections{'volumemeans'} ],
    [ "masked, detrended", $calc_sections{'maskedvolumemeans'} ] ];
push @navlist, [ "Mean volume difference", $calc_sections{'meandiffvolumemeans'} ];
push @navlist, [ "Running difference", $calc_sections{'maskedtdiffvolumemeans'} ];
push @navlist, [ "Outlier voxels", $calc_sections{'3dToutcount'} ];
{
  my @fwhmlist = ();
  push @fwhmlist, [ "X dimension", $calc_sections{'3dFWHMx-X'} ];
  push @fwhmlist, [ "Y dimension", $calc_sections{'3dFWHMx-Y'} ];
  push @fwhmlist, [ "Z dimension", $calc_sections{'3dFWHMx-Z'} ];
  push @navlist,
    [ "Smoothness (FWHM)", (grep {$_} @calc_sections{@sections_fwhm}) ? '' : undef,
      @fwhmlist ];
}
{
  my @cmassxlist = ();
  my @cmassylist = ();
  my @cmasszlist = ();
  push @cmassxlist, [ "input", $calc_sections{'cmassx'} ];
  push @cmassylist, [ "input", $calc_sections{'cmassy'} ];
  push @cmasszlist, [ "input", $calc_sections{'cmassz'} ];
  push @cmassxlist, [ "masked, detrended", $calc_sections{'maskedcmassx'} ];
  push @cmassylist, [ "masked, detrended", $calc_sections{'maskedcmassy'} ];
  push @cmasszlist, [ "masked, detrended", $calc_sections{'maskedcmassz'} ];
  my @cmasslist = ();
  push @cmasslist, [ "X dimension", (grep {$_} @calc_sections{'cmassx','maskedcmassx'}) ? '' : undef, @cmassxlist ];
  push @cmasslist, [ "Y dimension", (grep {$_} @calc_sections{'cmassx','maskedcmassx'}) ? '' : undef, @cmassylist ];
  push @cmasslist, [ "Z dimension", (grep {$_} @calc_sections{'cmassx','maskedcmassx'}) ? '' : undef, @cmasszlist ];
  push @navlist,
    [ "Center of mass", (grep {$_} @calc_sections{@sections_cmass}) ? '' : undef,
      @cmasslist ];
}
push @navlist,
    [ "Frequency Spectrum",
      '',
      [ "Mean over ROI", $calc_sections{'spectrummean'} ],
      [ "Max over ROI", $calc_sections{'spectrummax'} ],
    ];
push @navlist,
  [ "Per-slice variation", $calc_sections{'slicevar'} ? '' : undef,
    map {
      [ $filelabels[$_], $calc_sections{'slicevar'} ? "slicevar$_" : undef ]
    } (0..$#ARGV) ];
push @navlist,
  [ "Mean, StdDev, SFNR, Mask", $calc_sections{'meanstddevsfnr'} ? '' : undef,
    map {
      [ $filelabels[$_], $calc_sections{'meanstddevsfnr'} ? "meanstddevsfnr$_" : undef ]
    } (0..$#ARGV) ];
# now print out navigation bar based on structure
print HTMLFH <<EOM;
    <div class="navbarclosed" id="navbarclosed" onMouseOver="enterNavigation(event);">
       <span class="navbarshowhidelink">Navigation</span>
    </div>
    <div style="display:none;" class="navbar" id="navbar" onMouseOut="exitNavigation(event);">
      <div class="navmenu" id="navmenu">
        <span class="navbartitle">Navigation</span>
        <div class="select" onChange="if (this.options[this.selectedIndex].value) { jumpToAnchor(this.options[this.selectedIndex].value); } return false;">
EOM
my @navqueue = map { [$_, 0] } @navlist;
my $lastlevel = 0;
while (@navqueue) {
  my ($entry, $level) = @{shift @navqueue};
  my $label = $entry->[0];
  my $id = $entry->[1];
  my $output = '';
  while ($lastlevel > $level) {
    $lastlevel--;
  }
  if (scalar(@$entry) > 2) {
    $label .= ':';
  }
  $label = ('&nbsp;&nbsp;' x $level) . $label;
  if (!defined($id)) {
    $output = "<div class=\"gray\">$label</div>";
  } elsif ($id eq '') {
    $output = "<div>$label</div>";
  } else {
    $output = "<div onClick=\"jumpToAnchor('#$id')\" class=\"blue\">$label</div>";
  }
  print HTMLFH '  ' x $level, $output, "\n";
  if (scalar(@$entry) > 2) {
    unshift @navqueue, map { [$_, $level+1] } @{$entry}[2..$#$entry];
  }
  $lastlevel = $level;
}
while ($lastlevel > 0) {
  $lastlevel--;
}
print HTMLFH <<EOM;
        </div>
      </div>
    </div>
EOM

my $newlabel = $opt_qalabel;
$newlabel =~ s%(......................................./)%$1<br />%g;
print HTMLFH <<EOM;
    <div id="body" class="body">
    <span class="title"><b>QA report:</b><br /></span>
    <span class="titlebanner">$newlabel</span><br />
EOM

# display notes
if (grep { scalar(@$_) > 0 } @notelist) {
  print HTMLFH "<a name=\"notes\" />\n";
  print HTMLFH "<p>", showhide_checkbox("notes", $show_sections{'notes'}), "<font size=\"+1\"><b>Notes:</b></font></p>\n";
  print HTMLFH <<EOM;
    <div id="summary">
EOM
  map {
    my $label = $filelabels[$_];
    map {
      print HTMLFH "<div class='note'>${label}: $_</div>\n"
    } @{$notelist[$_]};
  } (0..$#notelist);
  print HTMLFH <<EOM;
    </div>
EOM
}

# display summary stats
print HTMLFH "<a name=\"summary\" />\n";
print HTMLFH "<p>", showhide_checkbox("summary", $show_sections{'summary'}), "<font size=\"+1\"><b>Summary:</b></font></p>\n";
# The 'rows1' array contains a four-level array of arrays
#  level 1: whether the data is input, masked, or masked and detrended
#  level 2: the label for the data
#  level 3: optional level for additional label
#  level 4: contains the actual data (one element for each input file)
# Each level consists of a text label (or undefined), followed by
# the children of that level, which are other levels when at levels 1-2,
# or the actual data when at level 3.
my @rows1 = ();
push @rows1, [ undef, [ undef, [ undef, @filelabels ] ] ];
if ($calc_sections{'clipped'}) {
  push @rows1,
   [
    'input',
    [ '# potentially-clipped voxels',
      [ undef, @numclippedvoxels ],
    ],
   ];
}
if (grep {$_} @calc_sections{'volumemeans','meandiffvolumemeans'}) {
  # unmasked (input) data
  my @inputrows = ();
  if ($calc_sections{'volumemeans'}) {
    push @inputrows,
      [ "# vols. with mean intensity abs. z-score > $opt_zthresh1",
	[ 'individual', @z1s ],
	[ 'rel. to grand mean', @z1gs ],
      ],
      [ "# vols. with mean intensity abs. z-score > $opt_zthresh2",
	[ 'individual', @z2s ],
	[ 'rel. to grand mean', @z2gs ],
      ];
  }
  if ($calc_sections{'meandiffvolumemeans'}) {
    push @inputrows,
      [ "# vols. with mean volume difference > ${opt_percthresh1}%",
	[ undef, @mdiffp1gs ],
      ],
      [ "# vols. with mean volume difference > ${opt_percthresh2}%",
	[ undef, @mdiffp2gs ],
      ],
  }
  push @rows1, [ 'input', @inputrows ];
}
if (grep {$_} @calc_sections{'3dFWHMx-X','3dFWHMx-Y','3dFWHMx-Z'}) {
  # masked data
  my @fwhmrows = ();
  if ($calc_sections{'3dFWHMx-X'}) {
    push @fwhmrows, [ 'X', @maskedmeanfwhmx ];
  }
  if ($calc_sections{'3dFWHMx-Y'}) {
    push @fwhmrows, [ 'Y', @maskedmeanfwhmy ];
  }
  if ($calc_sections{'3dFWHMx-Z'}) {
    push @fwhmrows, [ 'Z', @maskedmeanfwhmz ];
  }
  push @rows1, [ 'masked', [ 'mean FWHM', @fwhmrows ] ];
}
if (grep {$_} @calc_sections{'maskedvolumemeans', 'maskedtdiffvolumemeans', '3dToutcount', 'meanstddevsfnr'}) {
  # masked, detrended data
  my @maskdetrendrows = ();
  if ($calc_sections{'maskedvolumemeans'}) {
    push @maskdetrendrows,
      [ "# vols. with mean intensity abs. z-score > $opt_zthresh1",
	[ 'individual', @maskedz1s ],
	[ 'rel. to grand mean', @maskedz1gs ],
      ],
      [ "# vols. with mean intensity abs. z-score > $opt_zthresh2",
	[ 'individual', @maskedz2s ],
	[ 'rel. to grand mean', @maskedz2gs ],
      ];
  }
  if ($calc_sections{'maskedvolumemeans'}) {
    push @maskdetrendrows,
      [ "# vols. with running difference > ${opt_percthresh1}%",
	[ undef, @maskedtdiffp1gs ],
      ],
      [ "# vols. with running difference > ${opt_percthresh2}%",
	[ undef, @maskedtdiffp2gs ],
      ];
  }
  if ($calc_sections{'3dToutcount'}) {
    push @maskdetrendrows,
      [ "# vols. with > ${opt_percthresh1}% outlier voxels",
	[ undef, @outp1s ],
      ],
      [ "# vols. with > ${opt_percthresh2}% outlier voxels",
	[ undef, @outp2s ],
      ];
  }
  if ($calc_sections{'meanstddevsfnr'}) {
    push @maskdetrendrows,
      [ "mean (ROI in middle slice)",
	[ undef, @pqa_means ],
      ],
      [ "mean SNR (ROI in middle slice)",
	[ undef, @pqa_snrs ],
      ],
      [ "mean SFNR (ROI in middle slice)",
	[ undef, @pqa_sfnrs ],
      ];
  }
  push @rows1, [ 'masked, detrended', @maskdetrendrows ];
}
# write out HTML table from rows1 array
print HTMLFH <<EOM;
    <div id="summary">
     <table id='table_top_summary' class="striped">
EOM
for my $rowind1 (0..$#rows1) {
  my ($label1, @rows2) = @{$rows1[$rowind1]};
  my $numrows2 = 0;
  map { $numrows2 += scalar(@$_) - 1 } @rows2;
  for my $rowind2 (0..$#rows2) {
    my ($label2, @rows3) = @{$rows2[$rowind2]};
    my $numrows3 = scalar(@rows3);
    for my $rowind3 (0..$#rows3) {
      my ($label3, @data) = @{$rows3[$rowind3]};
      my $numdata = scalar(@data);
      my $colspan = 1;
      print HTMLFH "      <tr>";
      # do first level (column)
      if ($rowind2 == 0 && $rowind3 == 0) {
	print HTMLFH "<td";
	if ($numrows2 > 1) {
	  print HTMLFH " rowspan=$numrows2";
	}
	$colspan = 1;
	if (!defined($label2) && $numrows2 == 1) {
	  $colspan++;
	  if (!defined($label3) && $numrows3 == 1) {
	    $colspan++;
	  }
	  print HTMLFH " colspan=$colspan";
	}
	print HTMLFH ">";
	if (defined($label1)) { print HTMLFH $label1; }
	print HTMLFH "</td>";
      }
      # do second level (column)
      if ($colspan > 1) {
	$colspan--;
      } else {
	if ($rowind3 == 0) {
	  print HTMLFH "<td";
	  if ($numrows3 > 1) {
	    print HTMLFH " rowspan=$numrows3";
	  }
	  $colspan = 1;
	  if (!defined($label3) && $numrows3 == 1) {
	    $colspan++;
	    print HTMLFH " colspan=$colspan";
	  }
	  print HTMLFH ">";
	  if (defined($label2)) {
	    print HTMLFH $label2;
	  }
	  print HTMLFH "</td>";
	}
      }
      # do third level (column)
      if ($colspan > 1) {
	$colspan--; # just for consistency -- has no real effect
      } else {
	print HTMLFH "<td>";
	if (defined($label3)) {
	  print HTMLFH $label3;
	}
	print HTMLFH "</td>";
      }
      # and lastly, data
      print HTMLFH map { "<td>$_</td>" } @data;
      # finish row
      print HTMLFH "</tr>\n";
    }
  }
}
print HTMLFH <<EOM;
     </table>
    </div>
    <script type="text/javascript"><!--
stripe('table_top_summary');
--></script>
EOM

# Write out plots/images

# here is documentation for the plots/images
my %plotdocs = ();
$plotdocs{'volumemeans'} = <<EOM;
<p><b>Volume means:</b> this metric tracks the mean intensity of each volume (time point) in the data.  Increases and decreases in overall brain activity will be reflected in this plot.  RF spikes and other acquisition artifacts may be visible here (esp. if they affect an entire volume).</p>
EOM
$plotdocs{'maskedvolumemeans'} = <<EOM . $plotdocs{'volumemeans'};
<p><b>Masked, detrended volume means:</b> this is the <b><i>volume means</i></b> metric applied to masked and detrended data.</p>
EOM
$plotdocs{'meandiffvolumemeans'} = <<EOM;
<p><b>Means of mean volume difference:</b> for each volume <i>vol</i> and a mean volume <i>meanvol</i>, this metric tracks the mean intensity of (<i>vol</i> - <i>meanvol</i>).  Slow drifts in the input data will be apparent in this plot.</p>
EOM
$plotdocs{'maskedtdiffvolumemeans'} = <<EOM;
<p><b>Masked, detrended running difference ("velocity"):</b> this metric tracks the change in the mean intensity of consecutive volumes by subtracting the mean intensity of each volume from the mean intensity of its subsequent volume.</p>
EOM
$plotdocs{'3dToutcount'} = <<EOM;
<p><b>Outlier voxel percentages:</b> this metric is calculated by running the detrended data through the <a href="http://afni.nimh.nih.gov/afni/">AFNI</a> program <tt>3dToutcount</tt>.  This metric shows the percentage of "outlier" voxels in each volume.  For a definition of "outlier", see the <a href="http://afni.nimh.nih.gov/pub/dist/doc/program_help/3dToutcount.html">documentation for <tt>3dToutcount</tt></a> on the AFNI web site, or run <tt>3dToutcount</tt> without arguments.</p>
EOM
$plotdocs{'3dFWHMx-X'} = $plotdocs{'3dFWHMx-Y'} = $plotdocs{'3dFWHMx-Z'} = <<EOM;
<p><b>Full-width half-maximum (FWHM):</b> this metric shows the estimated FWHM for each volume in X, Y, or Z directions, used as a measure of the "smoothness" of the data.</p>
EOM
$plotdocs{'cmassx'} = $plotdocs{'cmassy'} = $plotdocs{'cmassz'} = <<EOM;
<p><b>Center of mass:</b> this metric is calculated as a weighted average of voxel intensities, where each voxel is weighted by its coordinate index in the X, Y, or Z direction.  Head motion in each of the three directions may be reflected as a change in this metric.</p>
EOM
$plotdocs{'maskedcmassx'} = $plotdocs{'maskedcmassy'} =
 $plotdocs{'maskedcmassz'} = <<EOM . $plotdocs{'cmassx'};
<p><b>Masked, detrended center of mass:</b> this is the <b><i>center of mass</i></b> metric applied to masked and detrended data.  Thus this metric will be insensitive to noise outside the mask.</p>
EOM
$plotdocs{'slicevar'} = <<EOM;
<p><b>Per-slice variation:</b> this image shows, for each slice at each time point in the data, a measure of "spikiness" at slice granularity that is insensitive to artifacts that affect all slices (e.g. head motion).  Higher numbers indicate a "spike".  It is computed as follows:</p>
<ol>
 <li>For each voxel remove the mean and detrend across time.</li>
 <li>Calculate the absolute value of the z-score across time for each voxel.</li>
 <li>For each slice at each time point, compute the average of this absolute z-score over all voxels in the single slice, producing a Z*T matrix <i>AAZ</i>.</li>
 <li>For each slice at each time point, calculate the absolute value of the "jackknife" z-score of <i>AAZ</i> across all slices at that time point, producing a new Z*T matrix <i>JKZ</i>, which is the per-slice variation.  (To compute a "jackknife" z-score, use all slices <i>except the current slice</i> to calculate mean and standard deviation.  The jackknife has the effect of amplifying outlier slices.)</li>
</ol>
<p><font size=-1>Douglas N. Greve, Nathan S. White, Syam Gadde, FIRST-BIRN. "Automatic Spike Detection for fMRI." Poster. Organization for Human Brain Mapping Annual Meeting, Florence IT 2006.</font></p>
EOM
$plotdocs{'mean'} = <<EOM;
<p><b>Mean:</b> this is the volume composed of the mean of each voxel across time.</p>
EOM
$plotdocs{'stddev'} = <<EOM;
<p><b>Standard deviation:</b> this is the volume composed of the standard deviation of each voxel across time.  The colorbar goes from 0 to 0.3 * the maximum intensity range of the mean volume.</p>
EOM
$plotdocs{'sfnr'} = <<EOM;
<p><b>Signal-to-Fluctuation Noise Ratio (SFNR):</b> this is a signal-to-noise (SNR) measure calculated for each brain voxel in the middle slice.  It is essentially the average across time divided by standard deviation (of detrended signal) across time.</p>
<p><font size=-1>Friedman L, Glover GH, The FBIRN Consortium.  "Reducing interscanner variability of activation in a multicenter fMRI study: Controlling for signal-to-fluctuation-noise-ratio (SFNR) differences."  Neuroimage. September 2, 2006.</font></p>
EOM
$plotdocs{'mask'} = <<EOM;
<p><b>Mask:</b> this mask is generated by creating a histogram of voxel intensities, fitting a curve to the histogram, and choosing the first local minimum of the curve as a threshhold.  The assumption of this algorithm is that the data will exhibit two "humps" in the histogram, the first being noise, and the second being actual brain signal.</p>
EOM
$plotdocs{'spectrummean'} = <<EOM;
<p><b>Spectrum mean:</b> a frequency spectrum is calculated for each voxel in the mask and this plot shows the mean power for each frequency across all voxels.</p>
EOM
$plotdocs{'spectrummax'} = <<EOM;
<p><b>Spectrum max:</b> a frequency spectrum is calculated for each voxel in the mask and this plot shows the maximum power for each frequency across all voxels.</p>
EOM

my @plotlist = ();
push @plotlist, ['volumemeans', 'Volume means (input)', $vmplotref, 0];
push @plotlist, ['maskedvolumemeans', 'Volume means (w/ mask,detrend)', $maskedvmplotref, 1];
push @plotlist, ['meandiffvolumemeans', 'Means of mean volume difference', $mdiffvmplotref, 0];
push @plotlist, ['maskedtdiffvolumemeans', 'Running difference ("velocity") volume means (w/ mask,detrend)', $maskedtdiffvmplotref, 1];
push @plotlist, ['3dToutcount', 'Outlier voxel percentages (from AFNI\'s 3dToutcount) (w/ mask,detrend)', $maskedoutlierpercentplotref, 1];
push @plotlist, ['3dFWHMx-X', 'FWHM in X dimension (from AFNI\'s 3dFWHMx) (w/ mask)', $maskedfwhmxplotref, 0];
push @plotlist, ['3dFWHMx-Y', 'FWHM in Y dimension (from AFNI\'s 3dFWHMx) (w/ mask)', $maskedfwhmyplotref, 0];
push @plotlist, ['3dFWHMx-Z', 'FWHM in Z dimension (from AFNI\'s 3dFWHMx) (w/ mask)', $maskedfwhmzplotref, 0];
push @plotlist, ['cmassx', 'Center of mass (X) (input)', $cmxplotref, 0];
push @plotlist, ['maskedcmassx', 'Center of mass (X) (w/ mask,detrend)', $maskedcmxplotref, 1];
push @plotlist, ['cmassy', 'Center of mass (Y) (input)', $cmyplotref, 0];
push @plotlist, ['maskedcmassy', 'Center of mass (Y) (w/ mask,detrend)', $maskedcmyplotref, 1];
push @plotlist, ['cmassz', 'Center of mass (Z) (input)', $cmzplotref, 0];
push @plotlist, ['maskedcmassz', 'Center of mass (Z) (w/ mask,detrend)', $maskedcmzplotref, 1];
push @plotlist, ['spectrummean', 'Frequency spectrum (mean over mask) (w/ mask,detrend)', $spectrummeanplotref, 1];
push @plotlist, ['spectrummax', 'Frequency spectrum (max over mask) (w/ mask,detrend)', $spectrummaxplotref, 1];
foreach my $plotentry (@plotlist) {
  my $plotstyle_show = '';
  my $plotstyle_hide = "style=\"display:none;\"";;
  my ($plotname, $plottitle, $plotref, $isdetrended) = @$plotentry;
  next if (!$calc_sections{$plotname});
  print HTMLFH "<a name=\"$plotname\" />\n";
  print HTMLFH "<p>", showhide_checkbox($plotname, $show_sections{$plotname}), <<EOM;
<font size="+1"><b>${plottitle}:</b></font>
<a href="#" class=popupLink onclick="return !showPopup('doc$plotname', event);"><font size="-1">(What&rsquo;s this?)</font></a></p>
<div onclick="event.cancelBubble = true;" class=popup id=doc$plotname>
  $plotdocs{$plotname}
  <a href="#" onclick="hideCurrentPopup(); return false;">Close</a>
</div>
EOM
  my $plotstyle = $show_sections{$plotname} ? $plotstyle_show : $plotstyle_hide;
  print HTMLFH <<EOM;
    <div id="$plotname" $plotstyle>
EOM
  if ($isdetrended && $opt_standardizedetrendedmeans) {
    print HTMLFH "<p>(individual means are standardized to grand mean)</p>\n";
  }
  showplots($plotref);
  print HTMLFH <<EOM;
    </div>
EOM
}

if (grep {$_} @calc_sections{'meanstddevsfnr', 'slicevar'}) {
  # standard deviation, mean, slicevar, sfnr, mask

  if ($calc_sections{'slicevar'}) {
    print HTMLFH "<a name=\"slicevar\" />\n";
    print HTMLFH <<EOM;
<div onclick="event.cancelBubble = true;" class=popup id=docslicevar>
  $plotdocs{'slicevar'}
  <a href="#" onclick="hideCurrentPopup(); return false;">Close</a>
</div>
EOM
    print HTMLFH "<p>", showhide_checkbox("slicevar", $show_sections{'slicevar'}), "<font size=\"+1\"><b>Per-slice variation:</b></font> <a href=\"#\" class=popupLink onclick=\"return !showPopup('docslicevar', event);\"><font size=\"-1\">(What&rsquo;s this?)</font></a></p>\n";
    my $plotstyle_show = '';
    my $plotstyle_hide = "style=\"display:none;\"";;
    my $plotstyle = $show_sections{'slicevar'} ? $plotstyle_show : $plotstyle_hide;
    print HTMLFH <<EOM;
    <div id="slicevar" $plotstyle>
EOM
    for my $filenum (0..$#ARGV) {
      my $spikejpgfn = $storedfns{'slicevar'}->{'png'}->{'data'}->[$filenum];
      my $spikecbarjpgfn = $storedfns{'slicevar'}->{'jpg'}->{'cbar'}->[$filenum];
      print HTMLFH <<EOM;
<hr />
<a name="slicevar$filenum" />
<p>$filelabels[$filenum]:</p>
<table>
 <tr class="colorbar">
  <td class="cbarmin">0</td>
  <td class="cbarmax">30</td>
 </tr>
 <tr class="colorbar">
  <td colspan="2">
   <img alt=\"Colorbar for per-slice variation of file $filelabels[$filenum]\" src=\"$spikecbarjpgfn\" />
  </td>
 </tr>
</table>
<table>
 <tr>
  <td>
   <span class="imgmin">image min: $storedmins{slicevar}->[$filenum],</span>
   <span class="imgmax">image max: $storedmaxs{slicevar}->[$filenum]</span>
  </td>
 </tr>
 <tr>
  <td><img alt=\"Per-slice variation of file $filelabels[$filenum]\" src=\"$spikejpgfn\" /></td>
 </tr>
</table>
EOM
    }
    print HTMLFH <<EOM;
    </div>
EOM
  }

  if ($calc_sections{'meanstddevsfnr'}) {
    print HTMLFH "<a name=\"meanstddevsfnr\" />\n";
    print HTMLFH <<EOM;
<div onclick="event.cancelBubble = true;" class=popup id=docmean>
  $plotdocs{'mean'}
  <a href="#" onclick="hideCurrentPopup(); return false;">Close</a>
</div>
<div onclick="event.cancelBubble = true;" class=popup id=docstddev>
  $plotdocs{'stddev'}
  <a href="#" onclick="hideCurrentPopup(); return false;">Close</a>
</div>
<div onclick="event.cancelBubble = true;" class=popup id=docsfnr>
  $plotdocs{'sfnr'}
  <a href="#" onclick="hideCurrentPopup(); return false;">Close</a>
</div>
<div onclick="event.cancelBubble = true;" class=popup id=docmask>
  $plotdocs{'mask'}
  <a href="#" onclick="hideCurrentPopup(); return false;">Close</a>
</div>
EOM
    print HTMLFH "<p>", showhide_checkbox("meanstddevsfnr", $show_sections{'meanstddevsfnr'}), "<font size=\"+1\"><b>Mean, Standard deviation, SFNR:</b></font></p>\n";
    my $plotstyle_show = '';
    my $plotstyle_hide = "style=\"display:none;\"";;
    my $plotstyle = $show_sections{'meanstddevsfnr'} ? $plotstyle_show : $plotstyle_hide;
    print HTMLFH <<EOM;
    <div id="meanstddevsfnr" $plotstyle>
EOM
    for my $filenum (0..$#ARGV) {
      my $meanjpgfn = $storedfns{'mean'}->{'jpg'}->{'data'}->[$filenum];
      my $stddevjpgfn = $storedfns{'stddev'}->{'jpg'}->{'data'}->[$filenum];
      my $sfnrjpgfn = $storedfns{'sfnr'}->{'jpg'}->{'data'}->[$filenum];
      my $maskjpgfn = $storedfns{'mask'}->{'png'}->{'data'}->[$filenum];
      my $meancbarjpgfn = $storedfns{'mean'}->{'jpg'}->{'cbar'}->[$filenum];
      my $stddevcbarjpgfn = $storedfns{'stddev'}->{'jpg'}->{'cbar'}->[$filenum];
      my $sfnrcbarjpgfn = $storedfns{'sfnr'}->{'jpg'}->{'cbar'}->[$filenum];
      my $cbarminstddev = 0;
      my $cbarmaxstddev = .3 * ($totalmaxs{'mean'} - $totalmins{'mean'});
      print HTMLFH <<EOM;
<hr />
<a name="meanstddevsfnr$filenum" />
<p>$filelabels[$filenum]:</p>
<table>
 <tr>
  <td colspan="3">Mean <a href="#" class=popupLink onclick="return !showPopup('docmean', event);"><font size="-1">(What&rsquo;s this?)</font></a></td>
  <td colspan="3">Standard Deviation <a href="#" class=popupLink onclick="return !showPopup('docstddev', event);"><font size="-1">(What&rsquo;s this?)</font></a></td>
 </tr>
 <tr class="colorbar">
  <td class="cbarmin">$totalmins{mean}</td>
  <td class="cbarmax">$totalmaxs{mean}</td>
  <td></td>
  <td class="cbarmin">$cbarminstddev</td>
  <td class="cbarmax">$cbarmaxstddev</td>
  <td></td>
 </tr>
 <tr class="colorbar">
  <td colspan="2">
   <img alt=\"Colorbar for mean of file $filelabels[$filenum]\" src=\"$meancbarjpgfn\" />
  </td>
  <td></td>
  <td colspan="2">
   <img alt=\"Colorbar for standard Deviation of file $filelabels[$filenum]\" src=\"$stddevcbarjpgfn\" />
  </td>
  <td></td>
 </tr>
 <tr>
  <td colspan="3">
   <span class="imgmin">image min: $storedmins{mean}->[$filenum],</span>
   <span class="imgmax">image max: $storedmaxs{mean}->[$filenum]</span>
  </td>
  <td colspan="3">
   <span class="imgmin">image min: $storedmins{stddev}->[$filenum],</span>
   <span class="imgmax">image max: $storedmaxs{stddev}->[$filenum]</span>
  </td>
 </tr>
 <tr>
  <td colspan="3"><img alt=\"Mean of file $filelabels[$filenum]\" src=\"$meanjpgfn\" /></td>
  <td colspan="3"><img alt=\"Standard Deviation of file $filelabels[$filenum]\" src=\"$stddevjpgfn\" /></td>
 </tr>

 <tr><td>&nbsp;</td></tr>

 <tr>
  <td colspan="3">SFNR (detrended) <a href="#" class=popupLink onclick="return !showPopup('docsfnr', event);"><font size="-1">(What&rsquo;s this?)</font></a></td>
  <td colspan="3">Mask <a href="#" class=popupLink onclick="return !showPopup('docmask', event);"><font size="-1">(What&rsquo;s this?)</font></a></td>
 </tr>
 <tr class="colorbar">
  <td class="cbarmin">$totalmins{sfnr}</td>
  <td class="cbarmax">$totalmaxs{sfnr}</td>
  <td></td>
  <td></td>
  <td></td>
  <td></td>
 </tr>
 <tr class="colorbar">
  <td colspan="2">
   <img alt=\"Colorbar for SFNR of file $filelabels[$filenum]\" src=\"$sfnrcbarjpgfn\" />
  </td>
  <td></td>
  <td></td>
  <td></td>
  <td></td>
 </tr>
 <tr>
  <td colspan="3">
   <span class="imgmin">image min: $storedmins{sfnr}->[$filenum],</span>
   <span class="imgmax">image max: $storedmaxs{sfnr}->[$filenum]</span>
  </td>
  <td colspan="3">
  </td>
 </tr>
 <tr>
  <td colspan="3"><img alt=\"SFNR of file $filelabels[$filenum]\" src=\"$sfnrjpgfn\" /></td>
  <td colspan="3"><img alt=\"Mask of file $filelabels[$filenum]\" src=\"$maskjpgfn\" /></td>
 </tr>
</table>
EOM
    }
    print HTMLFH <<EOM;
    </div>
EOM
  }
}

my $curtime = localtime();
print HTMLFH <<EOM;
  <hr />
  <p style="font-size: smaller;">Report generated by fmriqa_generate.pl on $curtime.</p>
  <p style="font-size: smaller;">BXH/XCEDE utilities (1.11.14)</p>
EOM
print HTMLFH <<EOM;
  </div>
EOM
print HTMLFH <<EOM;
  </body>
</html>
EOM

close HTMLFH;

###########################################
### Write out "group" JSON and XML data ###
###########################################
for my $filenum (0..$#filelabels) {
  my $statref = $statlist_group[$filenum];
  my $scalarstats = $statref->{'scalarstats'};
  my $arraystats = $statref->{'arraystats'};
  my $filelabel = $filelabels[$filenum];
  $filelabel =~ s%[\\/]%_%g;

  {
    # write out stats to JSON file
    my $jsonfn = "qa_stats_${filelabel}_group.json";
    my $fulljsonfn = File::Spec->catpath($outputvol, $outputdirjson, $jsonfn);
    open(JFH, ">$fulljsonfn")
      || logdie($logfh, "Cannot open output file '${fulljsonfn}' for writing\n");
    print JFH encode_json($statref);
    close JFH;
  }

  {
    # write out some stats into XML events file
    my $eventfn = "qa_events_${filelabel}_group.xml";
    my $fulleventfn = File::Spec->catpath($outputvol, $outputdir, $eventfn);
    my $tspacing = $filemetadata[$filenum]->{'dims'}->{'t'}->{'spacing'} / 1000.0;
    my $tsize = $filemetadata[$filenum]->{'dims'}->{'t'}->{'size'};
    writeXMLEventsFile($fulleventfn, $tspacing, $tsize, $scalarstats, $arraystats);
  }
}

unlink @tempfiles;

print STDOUT "Done!  Output is in $htmlfile\n";


# $Log: not supported by cvs2svn $
# Revision 1.155  2009/02/24 15:37:28  gadde
# Use bxh_mean instead of fmriqa_stddev and fmriqa_mean.
#
# Revision 1.154  2009/02/17 18:34:01  gadde
# Some tools now write .nii.gz.
# volmeasures now writes out stddev.
#
# Revision 1.153  2009/02/17 14:24:52  gadde
# Add stddev from volmeasures output
#
# Revision 1.152  2008/07/28 18:37:13  gadde
# Fix path resolver for win32
#
# Revision 1.151  2008/07/25 18:51:26  gadde
# Deal better with Siemens mosaic DICOM data.
# Remove some stderr messages.
#
# Revision 1.150  2008/07/17 17:41:03  gadde
# New fixed hovering popup menu for navigation.
#
# Revision 1.149  2008/07/16 19:21:43  gadde
# Allow mouse hovering to enter and exit navigation menu.
#
# Revision 1.148  2008/07/16 17:52:33  gadde
# Start with navigation menu closed by default.
#
# Revision 1.147  2008/07/16 17:33:54  gadde
# Move away from form/select/option and just use divs for navigation menu,
# so long filenames will trigger a scrollbar.
#
# Revision 1.146  2008/07/16 14:24:47  gadde
# Add --timeselect to usage template.
#
# Revision 1.145  2008/05/21 15:49:37  gadde
# Add pure-Perl XML::DOM::Lite for those who don't have other modules installed
#
# Revision 1.144  2008/04/02 20:32:45  gadde
# Log more command-lines to LOG.txt.
# Fix opt_timeselect option (would not work if only "0" is specified).
# Allow just meanstddevsfnr calculation (now computes required mask).
#
# Revision 1.143  2008/03/19 19:52:54  gadde
# Fix log messages.
#
# Revision 1.142  2008/03/19 17:57:40  gadde
# Standardize diagnostic messages with a '# ' prefix, and also write
# various output to a log file.
# Add the --timeselect option.
#
# Revision 1.141  2008/02/12 19:51:08  gadde
# Ignore unnecessary STDERR output from subsidiary tools.
#
# Revision 1.140  2008/01/28 17:00:45  gadde
# Fix infinity/-infinity from fmriqa_count.
#
# Revision 1.139  2008/01/10 18:19:19  gadde
# Update to allow for < instead of <= in the output of fmriqa_count.
#
# Revision 1.138  2007/12/11 21:50:45  gadde
# Update help message.
#
# Revision 1.137  2007/10/31 15:55:50  gadde
# Modify qalabel output.
#
# Revision 1.136  2007/08/20 19:14:43  gadde
# Javascript updates to navigation menu.
#
# Revision 1.135  2007/08/17 18:50:48  gadde
# Navigation menu changes.
# Also add mean FWHMs to XML file.
#
# Revision 1.134  2007/07/12 13:22:02  gadde
# Remove accidentally entered characters.
#
# Revision 1.133  2007/07/11 20:36:03  gadde
# Fix missing conversion to percent (* 100) in masked running difference for
# percent threshold 1.
#
# Revision 1.132  2007/06/08 16:48:36  gadde
# Use a min/max that disregards extreme outliers for image intensity scaling.
#
# Revision 1.131  2007/05/23 15:27:44  gadde
# Fix labeling/placement of masked cmassz plots
#
# Revision 1.130  2007/01/26 19:09:47  gadde
# Add -demed to 3dFWHMx call.
#
# Revision 1.129  2007/01/22 14:43:10  gadde
# Move some functions to fmriqa_utils.pm.
#
# Revision 1.128  2007/01/18 20:25:11  gadde
# Fix --version in perl scripts to show package version rather than CVS version.
#
# Revision 1.127  2007/01/11 20:13:18  gadde
# Move some functions to helper module and use 3dFWHMx instead of 3dFWHM
#
# Revision 1.126  2006/11/15 16:21:26  gadde
# Fix center of mass plot label.
#
# Revision 1.125  2006/09/28 13:38:41  gadde
# Documentation for "slicevar" was incorrectly ID'd as documentation for "mean".
#
# Revision 1.124  2006/09/22 15:23:31  gadde
# Documentation and help updates
#
# Revision 1.123  2006/09/22 13:51:53  gadde
# Add help popups for each metric.
#
# Revision 1.122  2006/07/13 16:10:55  gadde
# Win32 fixes
#
# Revision 1.121  2006/07/11 14:14:48  gadde
# Put version id into the body DIV.
#
# Revision 1.120  2006/07/10 17:56:33  gadde
# Add version info to report.
#
# Revision 1.119  2006/07/07 19:20:06  gadde
# Minor cosmetic CSS fix.
#
# Revision 1.118  2006/07/07 18:36:20  gadde
# Add striped tables and other cosmetic improvements(?)
# Fix cmassy and cmassz plots (were the same as cmassx).
#
# Revision 1.117  2006/07/06 19:48:50  gadde
# Large number of updates:
# * calcmean returns undef if given an empty list
# * javascript functions used to reduce code redundancy
# * every plot can now be calculated/not calculated, and for calculated plots
#   can be shown/hidden, based on user-specified options --calc, --nocalc,
#   --hide, --show.
# * added navigation bar to the left of HTML page
# * many CSS updates
# * code cleanup
#
# Revision 1.116  2006/07/05 13:45:02  gadde
# Check the relevant checkboxes (in case they are unchecked) when using
# the navigation links.
#
# Revision 1.115  2006/07/04 21:32:20  gadde
# Add navigation menu.
#
# Revision 1.114  2006/07/03 18:55:57  gadde
# Fix default zthresh2 and move decimal truncation of FWHM data.
#
# Revision 1.113  2006/07/03 16:32:15  gadde
# Reduce precision of FWHM to 3 decimal places.
#
# Revision 1.112  2006/06/30 19:23:38  gadde
# Parameterize z-score and percent thresholds.
#
# Revision 1.111  2006/06/30 18:45:43  gadde
# Move mean diff summary values to the "unmasked" section.
#
# Revision 1.110  2006/06/30 15:35:15  gadde
# Change "raw" to "input"
#
# Revision 1.109  2006/06/02 14:16:55  gadde
# Bring fBIRN changes into main branch
#
# Revision 1.108.2.15  2006/05/29 18:04:20  gadde
# Don't show fwhm in summary if fwhm analysis is not run.
#
# Revision 1.108.2.14  2006/05/25 18:22:38  gadde
# Fix some indexing bugs, and add some more text for standardized detrended
# means.
#
# Revision 1.108.2.13  2006/05/18 21:52:11  gadde
# Add --standardizedetrendedmeans for UCSD.
# Add FWHM summary to top.
# Put summary means back in running diff and mean volume diff plots.
#
# Revision 1.108.2.12  2006/05/18 21:00:01  gadde
# Add thresholds to XML file.
# Add FWHM support.
#
# Revision 1.108.2.11  2006/05/18 16:04:55  gadde
# Add ability to specify thresholds (for flagging volumes in tabular files).
# Fix 1% and 2% outlier calculation for running diff and mean volume diff data.
#
# Revision 1.108.2.10  2006/05/16 21:15:42  gadde
# Histogram updates, and also the beginnings of adding threshold markers
# to output text/xml tables.
#
# Revision 1.108.2.9  2006/05/15 18:54:43  gadde
# Change high-pass filter to 60 seconds.
#
# Revision 1.108.2.8  2006/05/01 22:07:04  gadde
# Add running difference and mean volume difference summary stats.
# Fix scales of individual plots of non-normalized metrics.
# Add histoxlabel option to plotdata().
#
# Revision 1.108.2.7  2006/05/01 19:10:41  gadde
# Change period for high-pass filter to 30 seconds.
#
# Revision 1.108.2.6  2006/05/01 16:37:05  gadde
# Add number of volumes with more than 1% or 2% percent outliers to events XML.
#
# Revision 1.108.2.5  2006/05/01 16:35:16  gadde
# Add histobintype and histobins parameters to plotdata().
# Update diagnostics and section labels.
# Add number of volumes with greater than 1% and 2% outlier voxels to summary.
#
# Revision 1.108.2.4  2006/04/26 15:34:17  gadde
# Updates to plotdata():
#  Added 'indivrange', 'normbaseline' and 'dontrescale' options.
#  Clarified range and normalization calculation and standardized plots
#  using different normalization methods.
#  Updated documentation.
# Changed range of some plots, and updated labels and diagnostic messages
# for clarity.
# Running difference and mean volume difference plots now scaled by
# the grand mean.
# Add 'nosummarymeans' option to showplots().
# Added --qalabel option.
#
# Revision 1.108.2.3  2006/04/18 21:06:08  gadde
# Updates for ImageMagick 6.
#
# Revision 1.108.2.2  2006/04/14 13:37:36  gadde
# Change "mask" labels.
#
# Revision 1.108.2.1  2006/04/13 21:31:50  gadde
# Creating a new branch for experimental QA.
#
# Revision 1.108  2006/04/12 17:29:14  gadde
# Win32 fixes
#
# Revision 1.107  2006/03/23 21:19:09  gadde
# Fix for gnuplot installations that don't have png support.
#
# Revision 1.106  2006/03/23 21:04:58  gadde
# Fixes for older versions of Perl.
#
# Revision 1.105  2006/03/23 20:47:51  gadde
# Don't need to use "composite" from ImageMagick anymore.
#
# Revision 1.104  2006/03/23 18:36:03  gadde
# Not using File::Path anymore.
#
# Revision 1.103  2006/03/23 18:27:28  gadde
# Fixes to be compatible with older versions of Perl.
#
# Revision 1.102  2005/11/10 15:14:48  gadde
# Fix bug that made subsequently plotted lines thicker and thicker.
#
# Revision 1.101  2005/11/03 17:30:48  gadde
# Add tick for timepoint 1 in slicevar images
#
# Revision 1.100  2005/11/03 17:01:15  gadde
# Update for ImageMagick gravity changes.  Now works with version 6.2.5-4.
#
# Revision 1.99  2005/11/03 16:24:49  gadde
# Use "xc" ImageMagick delegate rather than "null" (which doesn't work any more).
#
# Revision 1.98  2005/11/03 15:58:54  gadde
# Don't tile the SFNR image (there is only one).
#
# Revision 1.97  2005/11/02 16:08:27  gadde
# Update for new gnuplot version.
#
# Revision 1.96  2005/11/02 15:07:19  gadde
# Don't use list form of pipe open() for Win32.
#
# Revision 1.95  2005/09/20 18:37:52  gadde
# Updates to versioning, help and documentation, and dependency checking
#
# Revision 1.94  2005/09/19 16:31:53  gadde
# Documentation and help message updates.
#
# Revision 1.93  2005/06/09 16:51:19  gadde
# Montage now seems to allocate maximum potential image size with
# option -tile 6x999.  So change it to -tile 6x50.
#
# Revision 1.92  2005/06/08 21:42:39  gadde
# Add SNR and means (for ROI in middle slice) to output XML and summary.
#
# Revision 1.91  2005/06/06 19:06:53  gadde
# Add whole-run summary measures (and some comments) to the XML file.
#
# Revision 1.90  2005/03/16 21:18:43  gadde
# One more update to basepath calculation.
#
# Revision 1.89  2005/03/07 19:22:46  gadde
# Add --forcetr to help message.
#
# Revision 1.88  2005/03/07 19:13:58  gadde
# Another fix to basepath calculation (added missing parentheses).
#
# Revision 1.87  2005/03/07 18:59:29  gadde
# Another fix to basepath calculations.
# Add --forcetr option, and update option processing.
#
# Revision 1.86  2005/03/04 22:27:12  gadde
# Update basepath calculation.
#
# Revision 1.85  2005/02/28 14:40:41  gadde
# Change dashes in value names to underscores.
#
# Revision 1.84  2005/02/25 16:53:44  gadde
# Fix basepath calculation.
#
# Revision 1.83  2005/02/07 18:23:10  gadde
# Fix filelabel overwriting due to incorrect use of map()
#
# Revision 1.82  2005/02/04 21:12:38  gadde
# Replace / and \ with _ in file labels.
#
# Revision 1.81  2005/01/04 15:53:10  gadde
# Add missing end tag for <events>.
#
# Revision 1.80  2004/12/21 17:30:11  gadde
# Add individual stats to events file.  Also change some names.
#
# Revision 1.79  2004/12/21 17:13:57  gadde
# Add individual z-scores to summary.
#
# Revision 1.78  2004/12/21 16:08:03  gadde
# Cosmetic fix: don't let stddev lines get too close together.
#
# Revision 1.77  2004/12/21 15:52:24  gadde
# Add some summary statistics to top of page.
#
# Revision 1.76  2004/12/21 14:50:07  gadde
# Move basepath/label calculation to a subroutine.
#
# Revision 1.75  2004/12/21 14:32:32  gadde
# Move XML reading into a subroutine.
#
# Revision 1.74  2004/12/20 22:58:52  gadde
# Write only one XML events file.
#
# Revision 1.73  2004/12/20 22:09:03  gadde
# Further separate plotting and displaying.
#
# Revision 1.72  2004/12/20 21:53:33  gadde
# Separate calculating and graphing of plots from showing in HTML.
#
# Revision 1.71  2004/12/20 21:25:26  gadde
# Add sfnr and mask images.
#
# Revision 1.70  2004/12/20 17:35:03  gadde
# Fix raw/html field separation.
#
# Revision 1.69  2004/12/20 16:57:58  gadde
# Fix field collecting.
#
# Revision 1.68  2004/12/20 15:00:23  gadde
# Don't use HTML-annotated fields for math.
#
# Revision 1.67  2004/12/16 22:01:44  gadde
# Use file labels instead of indices to name files.
#
# Revision 1.66  2004/12/16 21:37:50  gadde
# Add "event" files to stoe the generated QA measures.
#
# Revision 1.65  2004/12/16 17:42:34  gadde
# Change terminology --  spikiness => per-slice variation
#
# Revision 1.64  2004/11/15 16:09:52  gadde
# Add dimorder option for spikiness data.
#
# Revision 1.63  2004/11/01 17:50:28  gadde
# Output plotted data points into a tab-separated text file, too.
#
# Revision 1.62  2004/09/16 16:02:57  gadde
# Go back to pgnuplot (which works as long as it's approx. version 3.7)
#
# Revision 1.61  2004/09/16 15:11:57  gadde
# pgnuplot doesn't work with command files.
#
# Revision 1.60  2004/09/16 15:05:57  gadde
# Don't use pipe to gnuplot (unreliable on Windows).
# Place temporary files in output directory rather than current directory
# (which may not be writable).
# Revert to linestyle vs. style line -- though deprecated, it works on
# gnuplot 3.7 and 4.0.
#
# Revision 1.59  2004/09/09 14:46:09  gadde
# Add --version option with CVS ID info.
#
# Revision 1.58  2004/09/08 18:46:13  gadde
# Windows gnuplot fixes.
#
# Revision 1.57  2004/09/03 19:30:25  gadde
# Some win32 specific fixes dealing with gnuplot
#
# Revision 1.56  2004/08/31 15:49:28  gadde
# windows updates
#
# Revision 1.55  2004/06/22 19:15:14  gadde
# Add more axis labeling.
#
# Revision 1.54  2004/06/02 15:31:02  gadde
# Adjust scale in case the data has negative values.
#
# Revision 1.53  2004/05/18 18:44:20  gadde
# Use more reliable text rotation.
#
# Revision 1.52  2004/05/18 18:32:19  gadde
# Spikiness has been approved
#
# Revision 1.51  2004/05/18 14:59:34  gadde
# Add axes labels to spikiness images.
# Plus minor fixes.
#
# Revision 1.50  2004/05/17 19:11:09  gadde
# Make this new spikiness optional for now
#
# Revision 1.49  2004/05/14 15:36:43  gadde
# Update diagnostic.
#
# Revision 1.48  2004/05/13 22:13:20  gadde
# Make spikiness prettier.
# Read XML to get labels for some images.
#
# Revision 1.47  2004/05/13 16:57:33  gadde
# Remove unnecessary message.
#
# Revision 1.46  2004/05/13 16:53:48  gadde
# Increase size of spikiness plots.
#
# Revision 1.45  2004/05/13 16:47:30  gadde
# add line break between image max and image min.
#
# Revision 1.44  2004/05/13 16:43:36  gadde
# Better spikiness and colorbar output.
#
# Revision 1.43  2004/05/12 21:58:06  gadde
# Need to separate option from option argument.
#
# Revision 1.42  2004/05/12 21:54:19  gadde
# Add new spikiness method.
#
# Revision 1.41  2004/05/12 20:04:48  gadde
# Fix spelling.
#
# Revision 1.40  2004/05/10 21:24:12  gadde
# Don't show spikiness data (too large).
#
# Revision 1.39  2004/05/10 19:44:47  gadde
# Fix typo.
#
# Revision 1.38  2004/05/10 19:41:52  gadde
# Don't use tempfile(), write to tempfile in current directory.
#
# Revision 1.37  2004/05/10 18:34:30  gadde
# Add jittered scatter plot for spikiness.
#
# Revision 1.36  2004/05/03 19:40:59  gadde
# Add checkboxes to selectively display QA sections.
# Also ignore comment lines (#) in fmriqa_* output.
#
# Revision 1.35  2004/04/28 22:03:27  gadde
# Whoops, add PID to temporary filenames.
#
# Revision 1.34  2004/04/28 21:45:34  gadde
# Change to AFNI despike method.
#
# Revision 1.33  2004/04/28 21:43:49  gadde
# Don't use tmpnam anymore.  All temporary files are now in current directory.
#
# Revision 1.32  2004/04/28 21:33:27  gadde
# option name change: writemap => colorbar
#
# Revision 1.31  2004/04/28 21:17:24  gadde
# Add non-normalized plotting, spikiness, cosmetic fixes, and color bars
# for mean/stddev images.
#
# Revision 1.30  2004/04/27 18:44:45  gadde
# Add spikiness.
#
# Revision 1.29  2004/04/06 15:18:02  gadde
# Be a little more careful about importing BSD::Resource.
#
# Revision 1.28  2004/04/06 15:09:56  gadde
# Should still work if BSD::Resource is not installed.
#
# Revision 1.27  2004/04/06 14:48:54  gadde
# Increase datasize limit.
#
# Revision 1.26  2004/04/05 17:53:06  gadde
# Be better about finding executables, and delete ppms.
#
# Revision 1.25  2004/04/02 21:24:16  gadde
# Add message at end.
#
# Revision 1.24  2004/04/02 15:00:28  gadde
# Make this work if run from source directory.
#
# Revision 1.23  2004/03/31 21:20:31  gadde
# Map checkboxes to correct row.
#
# Revision 1.22  2004/03/31 21:05:48  gadde
# Fix diagnostic.
#
# Revision 1.21  2004/03/31 21:00:38  gadde
# Cosmetic fixes.
#
# Revision 1.20  2004/03/31 16:29:00  gadde
# Use volmeasures instead of separate volmeans and volcmass.
#
# Revision 1.19  2004/03/31 15:43:08  gadde
# Try scaling stddev colormap to 30% of maximum of mean.
#
# Revision 1.18  2004/03/30 22:37:33  gadde
# Show individual min/maxes for mean/standard deviation.
#
# Revision 1.17  2004/03/30 20:23:33  gadde
# Add alt tags, show individual min/max for mean/stddev images.
#
# Revision 1.16  2004/03/30 20:07:20  gadde
# Update rescaling message, and add option to delete stddev/mean images.
#
# Revision 1.15  2004/03/29 16:07:00  gadde
# Use units int volcmass range, and add autoscaling for out-of-range data.
#
# Revision 1.14  2004/03/26 22:40:16  gadde
# Use more robust executable search.
#
# Revision 1.13  2004/03/26 20:47:28  gadde
# Add aggregate normalized plot.
#
# Revision 1.12  2004/03/26 13:55:53  gadde
# Add support for individual plots.
#
# Revision 1.11  2004/03/25 19:23:37  gadde
# Add ppm conversion, and various other updates
#
# Revision 1.10  2004/03/24 16:22:28  gadde
# Calculate outliers within each dataset, not over all datasets.
#
# Revision 1.9  2004/03/24 16:14:32  gadde
# Add mean line to plot, mark outliers in red, fix unlinks in stddev generation.
#
