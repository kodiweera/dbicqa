#!/usr/bin/env perl

use strict;

use FindBin;
use lib "$FindBin::RealDir";

use File::Spec;
use File::Temp qw/ tempfile /;

use Data::Dumper;

use XMLUtils;
use EventUtils;

our $opt_overwrite = 0;
our $opt_bypass = 0;
our $opt_verbose = 0;
our $opt_tr = 0;
our $opt_fileprefix = '';
our $opt_weightquery = undef;
our $opt_weightvaluequery = undef;
our $opt_weightmatchdefault = 1;
our $progname = "$FindBin::Script";

my $usage = <<EOM;
Usage:
  $progname [OPTIONS] outputformat xmldir outputlocation queryfiles...
  $progname [OPTIONS] outputformat xmlfile outputlocation queryfiles...
  $progname [OPTIONS] outputformat xmlfile1,xmlfile2,... outputlocation queryfiles...
Values for 'outputformat':
  fsl -
    outputlocation should be a directory.  Output is one or more .stf files
    with base name derived from the conditions specified in the queryfile(s),
    each having three columns:  onset, duration, and weight.
  par -
    outputlocation should be a file, which will have four columns: onset,
    condition index, duration, and condition name.  The conditions will be
    numbered from zero (0), in the order they are specified in the query file.


Options:
  --overwrite
        Overwrite existing output files (otherwise error and exit).
  --bypass
        Missing files or other errors will result in warning messages but
        processing on other files will continue, and the exit status will
        be 0 (success).
  --verbose
        Provide more info for debugging.
  --tr TR
        Specify the TR.  Equivalent to specifying "forcetr" in the query file.
        This is used to convert "ptsbefore" and "ptsafter" options into seconds.
  --fileprefix PREFIX
        Except for outputformat 'par', output file names will have this prefix.
        Default is no prefix.
  --weightquery STRING
        If specified (and if supported by the output type) the weight for an
        event is 1 if this query matches on the event, and 0 otherwise.
        If neither --weightquery or --weightvaluequery is specified, the
        default weight is 1 for all events unless overridden by
        --weightmatchdefault or a "queryweight" entry in a query file.
  --weightvaluequery STRING
        If specified (and if supported by the output type) the weight for an
        event is given by the value matching this query on each event, and the
        weight is zero for any event where this query does not match a value.
        If neither --weightquery or --weightvaluequery is specified, the
        default weight is 1 unless overridden by --weightmatchdefault or a
        "queryweight" entry in a query file.
  --weightmatchdefault NUMBER
        If specified (and if supported by the output type) the default weight
        for a matching event is given by this number.  If not specified,
        default is 1, but may also be overriden by a "queryweight"
        entry in a query file.
EOM

my @savedARGV = @ARGV;
@ARGV = ();
while (@savedARGV) {
  my $arg = shift @savedARGV;
  if ($arg =~ /^--help$/) {
    print STDERR $usage;
    exit -1;
  } elsif ($arg =~ /^--overwrite$/) {
    $opt_overwrite++;
    next;
  } elsif ($arg =~ /^--bypass$/) {
    $opt_bypass++;
    next;
  } elsif ($arg =~ /^--verbose$/) {
    $opt_verbose++;
    next;
  } elsif ($arg =~ /^--fileprefix$/) {
    $opt_fileprefix = shift @savedARGV;
    next;
  } elsif ($arg =~ /^--weightquery$/) {
    $opt_weightquery = shift @savedARGV;
    next;
  } elsif ($arg =~ /^--weightvaluequery$/) {
    $opt_weightvaluequery = shift @savedARGV;
    next;
  } elsif ($arg =~ /^--weightmatchdefault$/) {
    $opt_weightmatchdefault = shift @savedARGV;
    next;
  } elsif ($arg =~ /^--tr$/) {
    $opt_tr = shift @savedARGV;
    next;
  } elsif ($arg =~ /^--/) {
    print STDERR "Unrecognized option $arg";
    print STDERR $usage;
    exit -1;
  }
  push @ARGV, $arg;
}

if (defined($opt_weightquery) && defined($opt_weightvaluequery)) {
  die "ERROR: you cannot specify both --weightquery and --weightvaluequery!";
}

if ($opt_verbose) {
  $EventUtils::opt_verbose = $opt_verbose;
  $XMLUtils::opt_verbose = $opt_verbose;
}


##############
# MAIN PROGRAM
##############

if (@ARGV < 4) {
  print STDERR "$progname: ERROR: wrong number of arguments.\n";
  print STDERR $usage;
  exit -1;
}

my $outputformat = shift @ARGV;
my $xmldir = shift @ARGV;
my @xmlfiles = ();
my $outputloc = shift @ARGV;
my @queryfiles = @ARGV;
@ARGV = ();

if ($outputformat ne 'fsl' && $outputformat ne 'par' && $outputformat ne 'xcede') {
  print STDERR "$progname: ERROR: Unrecognized output format '$outputformat'\n";
  exit -1;
}

if (-d $xmldir) {
  # find all XML events files
  my $xmlglob = File::Spec->catfile($xmldir, '*.xml');
  @xmlfiles = glob $xmlglob;

  if (@xmlfiles == 0) {
    if ($opt_bypass) {
      print STDERR "$progname: WARNING: No files matched '$xmlglob'.\n";
      exit 0;
    } else {
      print STDERR "$progname: ERROR: No files matched '$xmlglob'.\n";
      exit -1;
    }
  }
} else {
  @xmlfiles = split(/,/, $xmldir);
}
for my $xmlfile (@xmlfiles) {
  if (! -f $xmlfile) {
    if ($opt_bypass) {
      print STDERR "$progname: WARNING: $xmlfile does not exist (or is not a file).\n";
      exit 0;
    } else {
      print STDERR "$progname: ERROR: $xmlfile does not exist (or is not a file).\n";
      exit -1;
    }
  }
}

if ($outputformat ne 'par' && ! -d $outputloc) {
  print STDERR "$progname: ERROR: specified output directory ($outputloc) must exist for output format '$outputformat'\n";
  exit -1;
}

##########################
# read and parse queryfile
my @querylanguages = ();
my @querylabels = ();
my @queries = ();
my @queryfilters = ();
my @queryepochexcludes = ();
my @queryweights = ();
my @epochsecsbefores = ();
my @epochsecsafters = ();
my @epochptsbefores = ();
my @epochptsafters = ();
for my $queryfile (@queryfiles) {
  my %queryopts = ();
  open(QFH, $queryfile) || die "$progname: ERROR opening '$queryfile': $!\n";
  while (<QFH>) {
    chomp;
    my $outline = '';
    # remove comments from input line
    while (length($_) > 0) {
      # the following patterns are followed by comments with strange
      # characters to overcome the limitations of emacs' cperl-mode
      # syntax highlighting.
      s/^(\#.*)//;
      s/^([^'"]+)//  && ($outline .= $1);
      s/^('[^']*')// && ($outline .= $1);
      s/^("[^"]*")// && ($outline .= $1);
      if (/^\'[^']*\'/ || /^\"[^"]*$/) {
	die "Missing end quote character in quoted expression: $_\n";
      }
    }
    $_ = $outline;
    # remove initial and trailing whitespace from input line
    s/^\s+//;
    s/\s+$//;
    # option name is initial string of non-whitespace characters
    my $optname = undef;
    s/^(\S+)\s*// && ($optname = $1);
    next if !defined($optname);
    # option arg may be quoted arbitrarily, so "unquote" it
    my $optarg = '';
    while (length($_) > 0) {
      s/^([^'"]+)//  && ($optarg .= $1);
      s/^\'([^']*)\'// && ($optarg .= $1);
      s/^\"([^"]*)\"// && ($optarg .= $1);
      if (/^\'[^']*\'/ || /^\"[^"]*$/) {
	die "Missing end quote character in quoted expression: $_\n";
      }
    }
    push @{$queryopts{$optname}}, $optarg;
  }
  close(QFH);

  if (!exists($queryopts{'querylanguage'})) {
    print STDERR "$progname: ERROR: query file '$queryfile' missing 'querylanguage' line\n";
    exit -1;
  }
  if (!exists($queryopts{'querylabel'})) {
    print STDERR "$progname: ERROR: query file '$queryfile' missing 'querylabel' line(s)\n";
    exit -1;
  }
  if (!exists($queryopts{'query'})) {
    print STDERR "$progname: ERROR: query file '$queryfile' missing 'query' line(s)\n";
    exit -1;
  }
  if (!exists($queryopts{'queryfilter'})) {
    $queryopts{'queryfilter'} = [];
  }
  if (!exists($queryopts{'queryepochexclude'})) {
    $queryopts{'queryepochexclude'} = [];
  }
  if (!exists($queryopts{'queryweight'})) {
    $queryopts{'queryweight'} = [];
  }

  if (defined($opt_tr)) {
    $queryopts{'forcetr'} = [$opt_tr];
  }

  my $numquerylabels = @{$queryopts{'querylabel'}};
  my $numqueries = @{$queryopts{'query'}};
  my $numqueryfilters = @{$queryopts{'queryfilter'}};
  my $numqueryepochexcludes = @{$queryopts{'queryepochexclude'}};
  my $numqueryweights = @{$queryopts{'queryweight'}};

  if ($numquerylabels != $numqueries) {
    print STDERR "$progname: ERROR: Number of 'querylabel' ($numquerylabels) and 'query' ($numqueries) lines in query file '$queryfile' is not the same.\n";
    exit -1;
  }
  if ($numqueryfilters > 0 &&
      $numqueryfilters != $numqueries) {
    print STDERR "$progname: ERROR: Number of 'queryfilter' ($numqueryfilters) and 'query' ($numqueries) lines in query file '$queryfile' is not the same.\n";
    exit -1;
  }
  if ($numqueryepochexcludes > 0 &&
      $numqueryepochexcludes != $numqueries) {
    print STDERR "$progname: ERROR: Number of 'queryepochexclude' ($numqueryepochexcludes) and 'query' ($numqueries) lines in query file '$queryfile' is not the same.\n";
    exit -1;
  }
  if ($numqueryweights > 0 &&
      $numqueryweights != $numqueries) {
    print STDERR "$progname: ERROR: Number of 'queryweight' ($numqueryweights) and 'query' ($numqueries) lines in query file '$queryfile' is not the same.\n";
    exit -1;
  }

  if ($numqueryepochexcludes > 0) {
    if (!(exists($queryopts{'secsbefore'}) && exists($queryopts{'secsafter'})) &&
	!(exists($queryopts{'ptsbefore'}) && exists($queryopts{'ptsafter'}) && exists($queryopts{'forcetr'}))) {
      print STDERR "$progname: ERROR: 'secsbefore' and 'secsafter' (or 'ptsbefore', 'ptsafter', and specified TR) lines are required if using 'queryepochexclude' in query file '$queryfile'.\n";
      exit -1;
    }
  }

  if (exists($queryopts{'ptsbefore'}) && exists($queryopts{'ptsafter'})) {
    my $secsbefore = $queryopts{'ptsbefore'}->[0] * $queryopts{'forcetr'}->[0];
    my $secsafter = ($queryopts{'ptsafter'}->[0] + 1) * $queryopts{'forcetr'}->[0];
    if (!(exists($queryopts{'secsbefore'}) && exists($queryopts{'secsafter'}))) {
      $queryopts{'secsbefore'}->[0] = $secsbefore;
      $queryopts{'secsafter'}->[0] = $secsafter;
    } else {
      if ($queryopts{'secsbefore'}->[0] != $secsbefore) {
	print STDERR "$progname: ERROR: options ptsbefore and secsbefore conflict!\n($queryopts{ptsbefore}->[0] * $queryopts{forcetr}->[0] does not equal $queryopts{secsbefore}->[0])\n";
	exit -1;
      }
      if ($queryopts{'secsafter'}->[0] != $secsafter) {
	print STDERR "$progname: ERROR: options ptsafter and secsafter conflict!\n( ($queryopts{ptsafter}->[0] + 1) * $queryopts{forcetr}->[0] does not equal $queryopts{secsafter})\n";
	exit -1;
      }
    }
  }

  # make the arrays equal size (undefs if missing)
  $#{$queryopts{'querylabel'}} = $numqueries-1;
  $#{$queryopts{'queryfilter'}} = $numqueries-1;
  $#{$queryopts{'queryepochexclude'}} = $numqueries-1;
  $#{$queryopts{'queryweight'}} = $numqueries-1;
  # replicate the querylanguage for each query
  while (@{$queryopts{'querylanguage'}} < $numqueries) {
    push @{$queryopts{'querylanguage'}}, $queryopts{'querylanguage'}->[0];
  }
  # replicate the secsbefore for each query
  if ($numqueries > 0 && !exists($queryopts{'secsbefore'})) {
    $queryopts{'secsbefore'} = [undef];
  }
  while (@{$queryopts{'secsbefore'}} < $numqueries) {
    push @{$queryopts{'secsbefore'}}, $queryopts{'secsbefore'}->[0];
  }
  # replicate the secsafter for each query
  if ($numqueries > 0 && !exists($queryopts{'secsafter'})) {
    $queryopts{'secsafter'} = [undef];
  }
  while (@{$queryopts{'secsafter'}} < $numqueries) {
    push @{$queryopts{'secsafter'}}, $queryopts{'secsafter'}->[0];
  }

  # now add them to global lists
  push @querylanguages, @{$queryopts{'querylanguage'}};
  push @querylabels, @{$queryopts{'querylabel'}};
  push @queries, @{$queryopts{'query'}};
  push @queryfilters, @{$queryopts{'queryfilter'}};
  push @queryepochexcludes, @{$queryopts{'queryepochexclude'}};
  push @queryweights, @{$queryopts{'queryweight'}};
  push @epochsecsbefores, @{$queryopts{'secsbefore'}};
  push @epochsecsafters, @{$queryopts{'secsafter'}};
}

if (!$opt_overwrite) {
  my $needtowrite = 0;
  for my $querylabel (@querylabels[0..(($outputformat eq 'par') ? 0 : $#querylabels)]) {
    my $fulloutputfile = undef;
    my $outputfile = undef;
    if ($outputformat eq 'fsl') {
      $outputfile = "${querylabel}.stf";
    } elsif ($outputformat eq 'xcede') {
      $outputfile = "${querylabel}.xml";
    } elsif ($outputformat eq 'par') {
      $fulloutputfile = $outputloc;
    }
    if (!defined($fulloutputfile)) {
      $outputfile = $opt_fileprefix . $outputfile;
      $fulloutputfile = File::Spec->catfile($outputloc, $outputfile);
    }
    if (-e $fulloutputfile) {
      if (!$opt_bypass) {
	print STDERR "$progname: ERROR: output file '$fulloutputfile' exists.\n";
	print STDERR "  Delete it or run with --overwrite or --bypass\n";
	exit -1;
      }
    } else {
      $needtowrite = 1;
    }
  }
  if ($opt_bypass && $needtowrite == 0) {
    print STDOUT "Skipping directory (output files already exist).\n";
    exit 0;
  }
}


###################################
# Convert XCEDE queries into XPath

for my $querynum (0..$#queries) {
  my $convertfunc = undef;
  if (lc($querylanguages[$querynum]) eq 'event' ||
      lc($querylanguages[$querynum]) eq 'xcede') {
    $convertfunc = \&EventUtils::xcede_query_to_xpath;
  } elsif (lc($querylanguages[$querynum]) eq 'xpathevent') {
    $convertfunc = \&EventUtils::expand_xpath_event;
  } elsif (lc($querylanguages[$querynum]) eq 'xpath') {
    1;				# no-op
  } else {
    print STDERR "$progname: querylanguage must be one of event, XCEDE, XPath, or XPathEvent\n";
    exit -1
  }

  if (defined($convertfunc)) {
    for my $query ($queries[$querynum], $queryfilters[$querynum], $queryepochexcludes[$querynum]) {
      next if (!defined($query) || $query eq "");
      my $result = &$convertfunc($query);
      print STDERR "query:\n  $query\nconverted to XPath query:\n  $result\n" if ($opt_verbose);
      $query = $result;
    }
  }
  if (defined($opt_weightquery)) {
    my $result = &$convertfunc($opt_weightquery, 1, 0);
    print STDERR "query '$opt_weightquery' converted to XPath query '$result'\n" if ($opt_verbose);
    $opt_weightquery = $result;
  } elsif (defined($opt_weightvaluequery)) {
    my $result = &$convertfunc($opt_weightvaluequery, 1, 1);
    print STDERR "query '$opt_weightvaluequery' converted to XPath query '$result'\n" if ($opt_verbose);
    $opt_weightvaluequery = $result;
  }
}
if (defined($opt_weightvaluequery)) {
  $opt_weightvaluequery = 'value[' . $opt_weightvaluequery . ']';
  $opt_weightquery = $opt_weightvaluequery;
}
for my $querynum (0..$#queries) {
  for my $query ($queries[$querynum], $queryfilters[$querynum]) {
    if (!defined($query) || $query eq '') {
      $query = 'true()';
    }
  }
  for my $query ($queryepochexcludes[$querynum]) {
    if (!defined($query) || $query eq '') {
      $query = 'false()';
    }
  }
}

####################################################
# read all XML events files, merge them together, and sort them
print STDERR "Reading/merging events...\n" if ($opt_verbose);
my ($mergedoc, $mergeeventselem) =
  EventUtils::read_and_merge_events(@xmlfiles);
print STDERR "Sorting events...\n" if ($opt_verbose);
my ($sortdoc, $sorteventselem, @sortedeventlist) =
  EventUtils::sort_events($mergedoc, $mergeeventselem);

#################################################################
# If needed, make a "transition" document, which has an event for
# every time interval in the merged event list that with a unique
# set of simultaneous events (i.e. basically a timeline).
my $transdoc = undef;
my $transeventselem = undef;
###XXX
if (grep { defined($_) } (@queryfilters, @queryepochexcludes)) {
  print STDERR "Making transition event list...\n" if ($opt_verbose);
  ($transdoc, $transeventselem) =
    EventUtils::trans_events($sortdoc, @sortedeventlist);
}

############################################################
# We now have a document with all original events sorted,
# and a "transition" document marking all event transitions.
# We can now perform the queries.
print STDERR "Querying...\n" if ($opt_verbose);
my $queryprefix = "event";
for my $querynum (0..$#queries) {
  my $querylabel = $querylabels[$querynum];
  my $query = $queries[$querynum];
  my $queryfilter = undef;
  my $queryepochexclude = undef;
  $queryfilter = $queryfilters[$querynum];
  $queryepochexclude = $queryepochexcludes[$querynum];
  my $queryweight = $queryweights[$querynum];
  my @matchednodes = XMLUtils::xpathFindNodes("${queryprefix}\[${query}]", $sorteventselem);
  my @matchedonsetdurweights =
    map {
	  my $onset = XMLUtils::xpathFindValue('onset', $_) || 0;
	  my $duration = XMLUtils::xpathFindValue('duration', $_) || 0;
	  my $weight =
	    (defined($queryweight)
	     ? $queryweight
	     : (defined($opt_weightquery)
		? XMLUtils::xpathFindValue($opt_weightquery, $_)
		: $opt_weightmatchdefault));
	  if ($weight eq '') {
	      $weight = 0;
	  }
	  [
	   $onset,
	   $duration,
	   $weight,
	   $_
	  ] } @matchednodes;
  # this shouldn't be necessary, but XML::XPath appending is a little
  # weird, resulting in unsorted results
  @matchedonsetdurweights =
    sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @matchedonsetdurweights;
  if (defined($queryfilter)) {
    my @filternodes = XMLUtils::xpathFindNodes("${queryprefix}\[${queryfilter}]", $transeventselem);
    my @filteronsetdurs =
      map { [
	     XMLUtils::xpathFindValue('onset', $_) || 0,
	     XMLUtils::xpathFindValue('duration', $_) || 0,
	     $_
	    ] } @filternodes;
    @filteronsetdurs =
      sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @filteronsetdurs;
    @matchedonsetdurweights =
      grep {
	my $monset = $_->[0];
	grep {
	  my ($fonset, $fdur, undef, undef) = @$_;
	  ($fonset <= $monset && ($fdur == 0 || $monset < $fonset + $fdur));
	} @filteronsetdurs;
      } @matchedonsetdurweights;
  }
  if (defined($queryepochexclude)) {
    my $epochsecsbefore = $epochsecsbefores[$querynum];
    my $epochsecsafter = $epochsecsafters[$querynum];
    my @excludenodes = XMLUtils::xpathFindNodes("${queryprefix}\[${queryepochexclude}]", $transeventselem);
    my @excludeonsetdurs =
      map { [
	     XMLUtils::xpathFindValue('onset', $_) || 0,
	     XMLUtils::xpathFindValue('duration', $_) || 0,
	     $_
	    ] } @excludenodes;
    @excludeonsetdurs =
      sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @excludeonsetdurs;
    @matchedonsetdurweights =
      grep {
	my $monset = $_->[0];
	!scalar(grep {
	  my ($exonset, $exdur, $exweight, $exnode) = @$_;
	  (($exonset - $epochsecsafter < $monset) &&
	   ($exdur == 0 || $monset < $exonset + $exdur + $epochsecsbefore));
	} @excludeonsetdurs);
      } @matchedonsetdurweights;
  }
  if (scalar(@matchedonsetdurweights) == 0) {
    @matchedonsetdurweights = ( [ 0, 0, 0 ] );
  }

  my $fulloutputfile = undef;
  my $outputfile = undef;
  if ($outputformat eq 'fsl') {
    $outputfile = "${querylabel}.stf";
  } elsif ($outputformat eq 'xcede') {
    $outputfile = "${querylabel}.xml";
  } elsif ($outputformat eq 'par') {
    $fulloutputfile = $outputloc;
  }
  if (!defined($fulloutputfile)) {
    $outputfile = $opt_fileprefix . $outputfile;
    $fulloutputfile = File::Spec->catfile($outputloc, $outputfile);
  }
  if ($outputformat ne 'par' && $opt_bypass && -e $fulloutputfile) {
    print STDOUT "File exists, skipping $fulloutputfile.\n";
  } else {
    print STDOUT "Writing $outputfile...\n";
    my $openmode = '>';
    if ($outputformat eq 'par') {
      $openmode = '>>'; # append
    }
    open(OFH, $openmode, $fulloutputfile) ||
      die "$progname: Error opening '$fulloutputfile' for writing: $!\n";
    if ($outputformat eq 'fsl') {
      print OFH join("\n", map { join("\t", @{$_}[0,1,2]) } @matchedonsetdurweights), "\n";
    } elsif ($outputformat eq 'xcede') {
      print OFH <<EOM;
<?xml version="1.0"?>
<events>
EOM
      print OFH	join("\n", map { $_->[3]->toString() } grep { defined($_->[3]) } @matchedonsetdurweights), "\n";
      print OFH <<EOM;
</events>
EOM
    } elsif ($outputformat eq 'par') {
      print OFH join("\n", map { join("\t", $_->[0], $querynum, $_->[1], $querylabel) } @matchedonsetdurweights), "\n";
    }
    close OFH;
  }
}

#$sortdoc->dispose();
#if (defined($transdoc)) {
#  $transdoc->dispose();
#}
