#!/usr/bin/env perl

use strict;

use FindBin;
use lib "$FindBin::RealDir";

use File::Spec;
use File::Temp qw/ tempfile /;

use XMLUtils;
use EventUtils;

our $opt_verbose = 0;
our $opt_querylanguage = 'XCEDE';
our $opt_query = undef;
our $opt_queryfilter = undef;
our $progname = "$FindBin::Script";

my $usage = <<EOM;
Usage:
  $progname [--verbose] [--querylanguage LANG] --query QUERY [--queryfilter QUERYFILTER] xmlfile...

This program will run a query and an optional query filter on the event
set comprised by merging and sorting the events in all the given input XML
files.  The onsets and durations of matching events are printed to standard
output in two columns.  LANG can be either "XCEDE" or "event" (both are
equivalent and are the default), or "XPath".
EOM

my @savedARGV = @ARGV;
@ARGV = ();
while (@savedARGV) {
  my $arg = shift @savedARGV;
  if ($arg =~ /^--help$/) {
    print STDERR $usage;
    exit -1;
  } elsif ($arg =~ /^--verbose$/) {
    $opt_verbose++;
    next;
  } elsif ($arg =~ /^--query$/) {
    $opt_query = shift @savedARGV;
    next;
  } elsif ($arg =~ /^--queryfilter$/) {
    $opt_queryfilter = shift @savedARGV;
    next;
  } elsif ($arg =~ /^--querylanguage$/) {
    $opt_querylanguage = shift @savedARGV;
    next;
  } elsif ($arg =~ /^--/) {
    print STDERR "Unrecognized option $arg";
    print STDERR $usage;
    exit -1;
  }
  push @ARGV, $arg;
}

if ($opt_verbose) {
  $EventUtils::opt_verbose = $opt_verbose;
  $XMLUtils::opt_verbose = $opt_verbose;
}

if (!defined($opt_query)) {
  die "Error: --query option required!\n$usage";
}


##############
# MAIN PROGRAM
##############

if (@ARGV < 1) {
  print STDERR "$progname: ERROR: must specify at least one XML filename.\n";
  print STDERR $usage;
  exit -1;
}

$opt_querylanguage = lc($opt_querylanguage);
if ($opt_querylanguage ne 'event' &&
    $opt_querylanguage ne 'xcede' &&
    $opt_querylanguage ne 'xpath' &&
    $opt_querylanguage ne 'xpathevent') {
  print STDERR "$progname: ERROR: --querylanguage must be 'event', 'XCEDE', 'XPath', or 'XPathEvent'!\n";
}

my @xmlfiles = @ARGV;

###################################
# Convert XCEDE queries into XPath
my $convertfunc = undef;
if ($opt_querylanguage eq 'event' ||
    $opt_querylanguage eq 'xcede') {
  $convertfunc = \&EventUtils::xcede_query_to_xpath;
} elsif ($opt_querylanguage eq 'xpathevent') {
  $convertfunc = \&EventUtils::expand_xpath_event;
}

if (defined($convertfunc)) {
  for my $query ($opt_query, $opt_queryfilter) {
    next if !defined($query);
    my $result = &$convertfunc($query);
    print STDERR "query:\n  $query\nconverted to XPath query:\n  $result\n" if ($opt_verbose);
    $query = $result;
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
if (defined($opt_queryfilter)) {
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
my @matchednodes = XMLUtils::xpathFindNodes("${queryprefix}\[${opt_query}]", $sorteventselem);
my @matchedonsetdurs =
  map { [
	 XMLUtils::xpathFindValue('onset', $_) || 0,
	 XMLUtils::xpathFindValue('duration', $_) || 0
	] } @matchednodes;
# this shouldn't be necessary, but XML::XPath appending is a little
# weird, resulting in unsorted results
@matchedonsetdurs =
  sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @matchedonsetdurs;
if (defined($opt_queryfilter)) {
  my @filternodes = XMLUtils::xpathFindNodes("${queryprefix}\[${opt_queryfilter}]", $transeventselem);
  my @filteronsetdurs =
    map { [
	   XMLUtils::xpathFindValue('onset', $_) || 0,
	   XMLUtils::xpathFindValue('duration', $_) || 0
	  ] } @filternodes;
  @filteronsetdurs =
    sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @filteronsetdurs;
  @matchedonsetdurs =
    grep {
      my $monset = $_->[0];
      grep {
	my ($fonset, $fdur) = @$_;
	($fonset <= $monset && $monset < $fonset + $fdur);
      } @filteronsetdurs;
    } @matchedonsetdurs;
}

print STDOUT join("\n", map { join("\t", @$_) } @matchedonsetdurs), "\n";

#$sortdoc->dispose();
#if (defined($transdoc)) {
#  $transdoc->dispose();
#}
