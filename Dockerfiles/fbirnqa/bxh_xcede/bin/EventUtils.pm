package EventUtils;

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin";
use File::Which;

use Data::Dumper;

use XMLUtils;

use Config;


BEGIN {
  use Exporter ();
  our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

  # if using RCS/CVS, this may be preferred
  $VERSION = sprintf "%d.%03d", q$Revision: 1.1 $ =~ /(\d+)/g;

  @ISA         = qw(Exporter);
  @EXPORT      = qw(&replace_onsetdur &read_and_merge_events &sort_events &trans_events &xcede_query_to_xpath &expand_xpath_event);
  @EXPORT_OK   = qw($opt_verbose);
}
our @EXPORT_OK;

our $opt_verbose = 0;

sub replace_onsetdur {
  # appending children is slow in XML::XPath, so avoid it when
  # possible
  my ($doc, $node, $newonset, $newdur) = @_;
  my @onsettextnodes = XMLUtils::xpathFindNodes('onset/text()', $node);
  my @durtextnodes = XMLUtils::xpathFindNodes('duration/text()', $node);
  if (@onsettextnodes > 1) {
    print STDERR "Too many onset nodes???\n";
    exit -1;
  }
  if (@durtextnodes > 1) {
    print STDERR "Too many duration nodes???\n";
    exit -1;
  }
  if (@onsettextnodes == 0) {
    my $newonsetnode = $doc->createElement('onset');
    $node->appendChild($newonsetnode);
    my $newonsettextnode = $doc->createTextNode("$newonset");
    $newonsetnode->appendChild($newonsettextnode);
    # do it in this order because it seems XML::XPath only increments
    # the global position number for each following node by a constant,
    # no matter if the appended node has children itself.  So, just
    # make sure we are appending from the top down.
  } else {
    $onsettextnodes[0]->setNodeValue("$newonset");
  }
  if (@durtextnodes == 0) {
    my $newdurnode = $doc->createElement('duration');
    $node->appendChild($newdurnode);
    my $newdurtextnode = $doc->createTextNode("$newonset");
    $newdurnode->appendChild($newdurtextnode);
    # do it in this order because it seems XML::XPath only increments
    # the global position number for each following node by a constant,
    # no matter what the content of the appended node is.  So, just
    # make sure we are appending from the top down.
  } else {
    $durtextnodes[0]->setNodeValue("$newdur");
  }
}

sub read_and_merge_events {
  my @xmlfiles = @_;
  my $mergedoc = XMLUtils::createDocument('events');
  my ($mergeeventselem, ) =
    XMLUtils::xpathFindNodes('events', $mergedoc);
  for my $xmlfile (@xmlfiles) {
    # find all <event> elements
    my $doc = XMLUtils::readXMLFile($xmlfile);
    # first find <events> elements
    my @eventselems = ();
    my @queue = ();
    for (my $child = $doc->getFirstChild();
	 defined($child);
	 $child = $child->getNextSibling()) {
      push @queue, $child;
    }
    while (@queue > 0) {
      my $node = shift @queue;
      if ($node->getNodeTypeStr() eq 'ELEMENT') {
	if ($node->getNodeName() eq 'events') {
	  push @eventselems, $node;
	} else {
	  for (my $child = $node->getFirstChild();
	       defined($child);
	       $child = $child->getNextSibling()) {
	    push @queue, $child;
	  }
	}
      }
    }
    # now find each child <event> element
    my @eventelems;
    for my $eventselem (@eventselems) {
      for (my $child = $eventselem->getFirstChild();
	   defined($child);
	   $child = $child->getNextSibling()) {
	if ($child->getNodeTypeStr() eq 'ELEMENT' &&
	    $child->getNodeName() eq 'event') {
	  push @eventelems, $child;
	}
      }
    }
    # for each <event> element, add them to mergedoc
    for my $eventelem (@eventelems) {
      XMLUtils::clone_and_append_child($mergedoc, $mergeeventselem, $eventelem);
    }
#    $doc->dispose();
  }

  return ($mergedoc, $mergeeventselem);
}

#####################
# sort event document
sub sort_events {
  my ($doc_in, $eventselem_in) = @_;
  my @sortedeventlist = ();
  for (my $child = $eventselem_in->getFirstChild();
       defined($child);
       $child = $child->getNextSibling()) {
    my $onset = XMLUtils::xpathFindValue('onset', $child);
    my $dur = XMLUtils::xpathFindValue('duration', $child);
    next if !defined($onset);
    if ($onset =~ /^\s*$/) {
      next;
    }
    if (!defined($dur) || $dur =~ /^\s*$/) {
      $dur = 0;
    }
    push @sortedeventlist, [$onset, $dur, $child];
  }
  @sortedeventlist = sort {
    ($a->[0] <=> $b->[0]) || ($a->[1] <=> $b->[1])
  } @sortedeventlist;
  my $sortdoc = XMLUtils::createDocument('events');
  my ($sorteventselem, ) =
    XMLUtils::xpathFindNodes('events', $sortdoc);
  for my $event (@sortedeventlist) {
    $event->[2] = XMLUtils::clone_and_append_child($sortdoc, $sorteventselem, $event->[2]);
  }
  return ($sortdoc, $sorteventselem, @sortedeventlist);
}

sub trans_events {
  my ($sortdoc, @sortedeventlist) = @_;
  print STDERR "Making transition document:\n" if ($opt_verbose);
  my $transdoc = XMLUtils::createDocument('events');
  my ($transeventselem, ) =
    XMLUtils::xpathFindNodes('events', $transdoc);
  my $epsilon = 0.0000001;	# nanosecond granularity
  while (@sortedeventlist > 1) {
    my $eventA = $sortedeventlist[0];
    my $eventB = $sortedeventlist[1];
    my ($onsetA, $durA, $nodeA) = @$eventA;
    my ($onsetB, $durB, $nodeB) = @$eventB;
    print STDERR "A: [$onsetA, $durA)\tB: [$onsetB, $durB]\n" if ($opt_verbose);
    if ($onsetA != $onsetB && $onsetA + $durA <= $onsetB) {
      print STDERR " Retiring A (no overlap)\n" if ($opt_verbose);
      # no interval overlap, so eventA is good to go
      XMLUtils::clone_and_append_child($transdoc, $transeventselem, $nodeA);
      shift @sortedeventlist;
      next;
    }
    if (abs($onsetA - $onsetB) < $epsilon && abs($durA - $durB) < $epsilon) {
      # intervals A and B are equal
      # need to merge B into A and delete B
      print STDERR " Merging B into A, deleting B\n" if ($opt_verbose);
      my $newnodeA = $nodeA->cloneNode(1);
      my @valuenodes = XMLUtils::xpathFindNodes('value', $nodeB);
      for my $valuenode (@valuenodes) {
	XMLUtils::clone_and_append_child($sortdoc, $newnodeA, $valuenode);
      }
      $sortedeventlist[0]->[2] = $newnodeA;
      # delete interval B
      $sortedeventlist[1] = $sortedeventlist[0];
      shift @sortedeventlist;
      next;
    }
    # if we get here, A and B overlap, and starting point of A
    # is no greater than starting point of B, because they are
    # sorted
    if (abs($durA) < $epsilon) {
      # Interval A [x,x], is a single point and starts at the
      # same time as interval B [x,y], by virtue of ordering
      # constraints.  Merge B into A, but keep B.
      print STDERR " Merging B into A, keeping B\n" if ($opt_verbose);
      my $newnodeA = $nodeA->cloneNode(1);
      my @valuenodes = XMLUtils::xpathFindNodes('value', $nodeB);
      for my $valuenode (@valuenodes) {
	XMLUtils::clone_and_append_child($sortdoc, $newnodeA, $valuenode);
      }
      # eventA is finished
      print STDERR " Retiring A\n" if ($opt_verbose);
      XMLUtils::clone_and_append_child($transdoc, $transeventselem, $newnodeA);
      shift @sortedeventlist;
      next;
    }
    if ($onsetA < $onsetB) {
      # Interval A [w,x) overlaps and starts before
      # interval B [y,z):
      #     |-----A-----|
      #  <--w-----y-----x-----z-->
      #           |-----B-----|
      # or
      #     |--------A--------|
      #  <--w-----y-----z-----x-->
      #           |--B--|
      # Split interval A into two fragments C [a1,b1) and D [b1,a2):
      #     |--C--|--D--|
      #  <--w-----y-----x-----z-->
      #           |-----B-----|
      # or
      #     |--C--|-----D-----|
      #  <--w-----y-----z-----x-->
      #           |--B--|
      #
      my $nodeC = $nodeA->cloneNode(1);
      my $nodeD = $nodeA->cloneNode(1);
      my $onsetC = $onsetA;
      my $durC = $onsetB - $onsetA;
      my $onsetD = $onsetB;
      my $durD = ($onsetA + $durA) - $onsetB;
      replace_onsetdur($sortdoc, $nodeC, $onsetC, $durC);
      replace_onsetdur($sortdoc, $nodeD, $onsetD, $durD);
      print STDERR " Splitting A into two intervals:\n" if ($opt_verbose);
      print STDERR "  C: [$onsetC, $durC]\tD: [$onsetD, $durD]\n" if ($opt_verbose);
      print STDERR " Retiring C\n" if ($opt_verbose);
      # nodeA now has interval C, and nodeD has interval D
      # C is guaranteed to not overlap any other intervals,
      # so we can get rid of eventA
      XMLUtils::clone_and_append_child($transdoc, $transeventselem, $nodeC);
      shift @sortedeventlist;
      # add new interval D to sorted event list
      my $putbefore = -1;
      for my $ind (0..$#sortedeventlist) {
	my ($tmponset, $tmpdur, $tmpevent) = @{$sortedeventlist[$ind]};
	if ($tmponset > $onsetD || ($tmponset == $onsetD && $tmpdur > $durD)) {
	  $putbefore = $ind;
	  last;
	}
      }
      my $neweventref = [$onsetD, $durD, $nodeD];
      if ($putbefore == -1) {
	push @sortedeventlist, $neweventref;
      } else {
	splice(@sortedeventlist, $putbefore, 0, $neweventref);
      }
      next;
    }
    if (abs($onsetA - $onsetB) < $epsilon && $durA < $durB) {
      # Interval A [x,y) starts at the same time, but
      # ends before interval B [x,z):
      #     |--A--|
      #  <--x-----y-----z-->
      #     |-----B-----|
      # Split interval B into two fragments C [x,y) and D [y,z).
      #     |--A--|
      #  <--x-----y-----z-->
      #     |--C--|--D--|
      #
      my $nodeC = $nodeB->cloneNode(1);
      my $nodeD = $nodeB->cloneNode(1);
      my $onsetC = $onsetB;
      my $durC = $durA;
      my $onsetD = $onsetB + $durA;
      my $durD = $durB - $durA;
      replace_onsetdur($sortdoc, $nodeC, $onsetC, $durC);
      replace_onsetdur($sortdoc, $nodeD, $onsetD, $durD);
      print STDERR " Splitting B into two intervals:\n" if ($opt_verbose);
      print STDERR "  C: [$onsetC, $durC]\tD: [$onsetD, $durD]\n" if ($opt_verbose);
      # nodeB now has interval C, and nodeD has interval D.
      # new intervals C and D need to be added to sorted event list.
      # interval C can just take B's old place (right after A, since
      # they share the same onset and duration)
      $eventB->[0] = $onsetC;
      $eventB->[1] = $durC;
      $eventB->[2] = $nodeC;
      # add new interval D to sorted event list
      my $putbefore = -1;
      for my $ind (0..$#sortedeventlist) {
	my ($tmponset, $tmpdur, $tmpevent) = @{$sortedeventlist[$ind]};
	if ($tmponset > $onsetD || ($tmponset == $onsetD && $tmpdur > $durD)) {
	  $putbefore = $ind;
	  last;
	}
      }
      my $neweventref = [$onsetD, $durD, $nodeD];
      if ($putbefore == -1) {
	push @sortedeventlist, $neweventref;
      } else {
	splice(@sortedeventlist, $putbefore, 0, $neweventref);
      }
      next;
    }
    print STDERR "EventUtils: Internal error: events are not sorted correctly?\n";
  }
  # there should be at most one element left in sortedeventlist
  map {
    my $node = $_->[2];
    XMLUtils::clone_and_append_child($transdoc, $transeventselem, $node);
  } @sortedeventlist;

  return ($transdoc, $transeventselem);
}

## this stuff is for converting XCEDE event queries to XPath

sub T_INVALID    { return 0; }
sub T_NUMTOKEN   { return 1; }
sub T_STRTOKEN   { return 2; }
sub T_PARAMTOKEN { return 3; }
sub T_OPENPAREN  { return 4; }
sub T_CLOSEPAREN { return 5; }
sub T_COMMA      { return 6; }
sub T_DASH       { return 7; }
sub T_AND        { return 8; }
sub T_OR         { return 9; }
sub T_INEQ_OP    { return 10; }
sub T_EQ_OP      { return 11; }

sub S_INVALID    { return 0; }
sub S_QUERY      { return 1; }
sub S_PQUERY     { return 2; }
sub S_CONDITION  { return 3; }

my %magicparams =
  (
   '$onset' => 'onset',
   'onset' => 'onset',
   '$duration' => 'duration',
   'duration' => 'duration',
   '$type' => '@type',
   'type' => '@type',
   '$units' => 'units',
   'units' => 'units',
   '$description' => 'description',
   'description' => 'description',
  );

sub NEXTTOKEN {
  my ($tokenlistref, $tokennum) = @_;
  if ($tokennum + 1 > $#$tokenlistref) {
    my $query = join(" ", map { $_->[1] } @$tokenlistref);
    print STDERR "Expecting more after:\n $query\n";
    exit -1;
  }
  $tokennum++;
  return ($tokennum, @{$tokenlistref->[$tokennum]});
}

sub xcede_query_to_xpath {
  my ($queryin, $noimplicittest, $valuelevel) = @_;

  my @tokenlist = ();
  my @stack = ();

  if (!defined($noimplicittest)) {
    $noimplicittest = 0;
  }

  if (!defined($valuelevel)) {
    $valuelevel = 0;
  }

  # first convert into tokens
  while (length($queryin) > 0) {
    my $token = undef;
    my $tokentype = T_INVALID;
    $queryin =~ s/^\s+//;
    if ($queryin =~ s/^(\d+\.\d*|\d+|\.\d+)//) {
      # NUMTOKEN   ::=  DIGIT+ "." DIGIT*
      #              |  DIGIT+
      #              |  "." DIGIT+
      $token = $1;
      $tokentype = T_NUMTOKEN;
    } elsif ($queryin =~ s/^(\'[^\']*\'|\"[^\"]*\")//) {
      # STRTOKEN   ::=  "'" STRCHAR1* "'"
      #              |  '"' STRCHAR2* '"'
      # STRCHAR1   ::= any ASCII character except single quote (')
      # STRCHAR2   ::= any ASCII character except double quote (")
      $token = $1;
      $tokentype = T_STRTOKEN;
    } elsif ($queryin =~ s/^((\$|\%)?[_A-Za-z][._A-Za-z0-9]*)//) {
      # PARAMTOKEN ::=  "$" PARAMSTART PARAMCHAR*
      #              |  "%" PARAMSTART PARAMCHAR*
      #              |      PARAMSTART PARAMCHAR*
      # PARAMSTART ::=  "_" | LETTER
      # PARAMCHAR  ::=  "." | "_" | LETTER | DIGIT
      $token = $1;
      $tokentype = T_PARAMTOKEN;
    } elsif ($queryin =~ s/^(\()//) {
      $token = $1;
      $tokentype = T_OPENPAREN;
    } elsif ($queryin =~ s/^(\))//) {
      $token = $1;
      $tokentype = T_CLOSEPAREN;
    } elsif ($queryin =~ s/^(,)//) {
      $token = $1;
      $tokentype = T_COMMA;
    } elsif ($queryin =~ s/^(-)//) {
      $token = $1;
      $tokentype = T_DASH;
    } elsif ($queryin =~ s/^(\&)//) {
      $token = $1;
      $tokentype = T_AND;
    } elsif ($queryin =~ s/^(\|)//) {
      $token = $1;
      $tokentype = T_OR;
    } elsif ($queryin =~ s/^(<=|>=|<|>)//) {
      $token = $1;
      # INEQ_OP  ::=  "<=" | ">=" | "<" | ">"
      $tokentype = T_INEQ_OP;
    } elsif ($queryin =~ s/^(==|!=)//) {
      # EQ_OP    ::=  "==" | "!="
      $token = $1;
      $tokentype = T_EQ_OP;
    } else {
      print STDERR "Unrecognized syntax at:\n $queryin\n";
      exit -1;
    }
    push @tokenlist, [ $tokentype, $token ];
  }

  if (@tokenlist == 0) {
    print STDERR "input query is empty!\n";
    exit -1;
  }

  # Starting point is thus:
  #   QUERY ::= "(" QUERY ")"
  #           | QUERY "&" QUERY
  #           | QUERY "|" QUERY
  #           | CONDITION
  # XPath has the same order of operations, so we don't need to
  # worry about re-ordering anything or adding parentheses.
  # For our purposes, then, the above is equivalent to:
  #   QUERY  ::= PQUERY    "&" QUERY
  #            | PQUERY    "|" QUERY
  #            | PQUERY
  #            | CONDITION "&" QUERY
  #            | CONDITION "|" QUERY
  #            | CONDITION
  #   PQUERY ::= "(" QUERY ")"
  # The state machine below uses "goto"s for clarity!

  my $queryout = '';
  push @stack, S_QUERY;
  my $tokennum = 0;
  my $numtokens = scalar(@tokenlist);
  while (@stack && $tokennum <= $#tokenlist) {
    my ($tokentype, $token) = @{$tokenlist[$tokennum]};
    if ($tokentype == T_OPENPAREN) {
      push @stack, S_PQUERY;
      $queryout .= "(";
      $tokennum++;
      next;
    }
    # we didn't find an open parenthesis, so parse a CONDITION
    my $lvalue = undef;
    my $ltype = T_INVALID;
    my $rvalue = undef;
    if ($tokentype != T_PARAMTOKEN &&
	$tokentype != T_NUMTOKEN &&
	$tokentype != T_STRTOKEN) {
      my $querystart = join(" ", map { $_->[1] } @tokenlist[0..$tokennum-1]);
      my $queryend = join(" ", map { $_->[1] } @tokenlist[$tokennum..$#tokenlist]);
      print STDERR "param name, string, or number expected after:\n $querystart\nbut got:\n $queryend\n";
      exit -1;
    }
    $ltype = $tokentype;
    if ($tokentype == T_PARAMTOKEN) {
      if (exists($magicparams{$token})) {
	$lvalue = $magicparams{$token};
      } else {
	$token =~ s/^\%//;
	if (!$valuelevel) {
	  $lvalue .= 'value[';
	}
	$lvalue .= '@name=\'';
	$lvalue .= $token;
	$lvalue .= '\'';
	if (!$valuelevel) {
	  $lvalue .= ']';
	}
      }
    } else {
      $lvalue = $token;
    }
    if ($tokennum + 1 < $numtokens) {
      $tokennum++;
      ($tokentype, $token) = @{$tokenlist[$tokennum]};
    } else {
      $tokennum++;
      $tokentype = T_INVALID;
    }
    if ($tokentype == T_OPENPAREN) {
      my $firstclause = 1;
      if ($ltype != T_PARAMTOKEN) {
	my $querystart = join(" ", map { $_->[1] } @tokenlist[0..$tokennum]);
	print STDERR "Expected param name before paren here:\n $querystart\n";
	exit -1;
      }
      $queryout .= "(";
      ($tokennum, $tokentype, $token) = NEXTTOKEN(\@tokenlist, $tokennum);
      while ($tokentype != T_CLOSEPAREN) {
	if (!$firstclause) {
	  if ($tokentype != T_COMMA) {
	    my $querystart = join(" ", map { $_->[1] } @tokenlist[0..$tokennum-1]);
	    my $queryend = join(" ", map { $_->[1] } @tokenlist[$tokennum..$#tokenlist]);
	    print STDERR "Expected comma or right-paren after:\n $querystart\nbut got:\n $queryend\n";
	    exit -1;
	  }
	  $queryout .= " or ";
	  ($tokennum, $tokentype, $token) = NEXTTOKEN(\@tokenlist, $tokennum);
	}
	$firstclause = 0;
	if ($tokentype == T_INEQ_OP) {
	  my $op = $token;
	  ($tokennum, $tokentype, $token) = NEXTTOKEN(\@tokenlist, $tokennum);
	  if ($tokentype != T_NUMTOKEN) {
	    my $querystart = join(" ", map { $_->[1] } @tokenlist[0..$tokennum-1]);
	    my $queryend = join(" ", map { $_->[1] } @tokenlist[$tokennum..$#tokenlist]);
	    print STDERR "Expected number after:\n $querystart\nbut got:\n $queryend\n";
	    exit -1;
	  }
	  $queryout .= $lvalue;
	  $queryout .= $op;
	  $queryout .= $token;
	} elsif ($tokentype == T_NUMTOKEN) {
	  my $rangebegin = $token;
	  if ($tokennum + 1 < $numtokens &&
	      $tokenlist[$tokennum+1]->[0] == T_DASH) {
	    $tokennum++;
	    ($tokennum, $tokentype, $token) = NEXTTOKEN(\@tokenlist, $tokennum);
	    if ($tokentype != T_NUMTOKEN) {
	      my $querystart = join(" ", map { $_->[1] } @tokenlist[0..$tokennum-1]);
	      my $queryend = join(" ", map { $_->[1] } @tokenlist[$tokennum..$#tokenlist]);
	      print STDERR "Expected number after:\n $querystart\nbut got:\n $queryend\n";
	      exit -1;
	    }
	    my $rangeend = $token;
	    $queryout .= "(";
	    $queryout .= $lvalue;
	    $queryout .= ">=";
	    $queryout .= $rangebegin;
	    $queryout .= " and ";
	    $queryout .= $lvalue;
	    $queryout .= "<=";
	    $queryout .= $rangeend;
	    $queryout .= ")";
	  } else {
	    $queryout .= $lvalue;
	    $queryout .= "=";
	    $queryout .= $token;
	  }
	} else {
	  # should be a string
	  $queryout .= $lvalue;
	  $queryout .= "=";
	  $queryout .= $token;
	}
	($tokennum, $tokentype, $token) = NEXTTOKEN(\@tokenlist, $tokennum);
      }
      $tokennum++;
      $queryout .= ")";
    } elsif ($tokentype == T_INEQ_OP) {
      my $op = $token;
      ($tokennum, $tokentype, $token) = NEXTTOKEN(\@tokenlist, $tokennum);
      if ($tokentype == T_PARAMTOKEN) {
	if (exists($magicparams{$token})) {
	  $rvalue = $magicparams{$token};
	} else {
	  $token =~ s/^%//;
	  if (!$valuelevel) {
	    $rvalue .= 'value[';
	  }
	  $rvalue .= '@name=\'';
	  $rvalue .= $token;
	  $rvalue .= '\'';
	  if (!$valuelevel) {
	    $rvalue .= ']';
	  }
	}
      } elsif ($tokentype == T_NUMTOKEN) {
	$rvalue = $token;
      } else {
	my $querystart = join(" ", map { $_->[1] } @tokenlist[0..$tokennum-1]);
	my $queryend = join(" ", map { $_->[1] } @tokenlist[$tokennum..$#tokenlist]);
	print STDERR "Expected param name or number after:\n $querystart\nbut got:\n $queryend\n";
	exit -1;
      }
      $queryout .= $lvalue;
      $queryout .= $op;
      $queryout .= $rvalue;
      $tokennum++;
    } elsif ($tokentype == T_EQ_OP) {
      my $op = $token;
      if ($op eq '==') {
	$op = "=";
      }
      ($tokennum, $tokentype, $token) = NEXTTOKEN(\@tokenlist, $tokennum);
      if ($tokentype == T_PARAMTOKEN) {
	if (exists($magicparams{$token})) {
	  $rvalue = $magicparams{$token};
	} else {
	  $token =~ s/^%//;
	  if (!$valuelevel) {
	    $rvalue .= 'value[';
	  }
	  $rvalue .= '@name=\'';
	  $rvalue .= $token;
	  $rvalue .= '\'';
	  if (!$valuelevel) {
	    $rvalue .= ']';
	  }
	}
      } elsif ($tokentype == T_NUMTOKEN || $tokentype == T_STRTOKEN) {
	$rvalue = $token;
      } else {
	my $querystart = join(" ", map { $_->[1] } @tokenlist[0..$tokennum-1]);
	my $queryend = join(" ", map { $_->[1] } @tokenlist[$tokennum..$#tokenlist]);
	print STDERR "Expected param name, number, or string after:\n $querystart\nbut got:\n $queryend\n";
	exit -1;
      }
      $queryout .= $lvalue;
      $queryout .= $op;
      $queryout .= $rvalue;
      $tokennum++;
    } else {
      # simple test
      if ($noimplicittest) {
	$queryout .= $lvalue;
      } elsif (!$noimplicittest) {
	$queryout .= $lvalue;
	$queryout .= " and ";
	$queryout .= "(";
	$queryout .= $lvalue;
        $queryout .= "!=";
	$queryout .= "0";
	$queryout .= ")";
      }
    }

    my $checkstateend = 1;
    while ($checkstateend) {
      # pre-conditions:
      #  for state S_PQUERY:
      #    Next token is '&' or '|', which continues the query,
      #    or next token is ')', which ends this parenthesized query (pop!).
      #  for state S_QUERY:
      #    Next token is '&' or '|', which continues the query,
      #    or there is no following token, which ends the query (pop!).
      my $curstate = $stack[$#stack];
      if ($tokennum < $numtokens) {
	($tokentype, $token) = @{$tokenlist[$tokennum]};
      }
      if ($tokennum >= $numtokens && $curstate == S_PQUERY) {
	my $query = join(" ", map { $_->[1] } @tokenlist);
	print STDERR "End-of-query error; expected more after:\n $query\n";
	exit -1;
      }
      if (($tokennum >= $numtokens && $curstate == S_QUERY) ||
	  ($tokentype == T_CLOSEPAREN && $curstate == S_PQUERY)) {
	# we are finished with a query, so pop the stack
	if ($tokentype == T_CLOSEPAREN && $curstate == S_PQUERY) {
	  # push the close paren out
	  $queryout .= ")";
	  $tokennum++;
	}
	if (@stack == 0) {
	  die "Stack empty!\n";
	}
	pop @stack;
	if (@stack == 0) {
	  if ($tokennum >= $numtokens) { # we're done!
	    $checkstateend = 0;
	  } else {
	    die "Stack empty!\n";
	  }
	}
      } else {
	if ($tokentype == T_AND) {
	  $queryout .= " and ";
	  ($tokennum, $tokentype, $token) = NEXTTOKEN(\@tokenlist, $tokennum);
	} elsif ($tokentype == T_OR) {
	  $queryout .= " or ";
	  ($tokennum, $tokentype, $token) = NEXTTOKEN(\@tokenlist, $tokennum);
	} else {
	  my $querystart = join(" ", map { $_->[1] } @tokenlist[0..$tokennum-1]);
	  my $queryend = join(" ", map { $_->[1] } @tokenlist[$tokennum..$#tokenlist]);
	  print STDERR "Garbage found after:\n $querystart\nhere:\n $queryend\n";
	  exit -1;
	}
	$checkstateend = 0;
      }
    }
  }

  return $queryout;
}


my $cc_namestartchar_nc =
  ''
  . 'A-Z'
  . 'a-z'
  . '_'
  . '\x{C0}-\x{D6}'
  . '\x{D8}-\x{F6}'
  . '\x{F8}-\x{2FF}'
  . '\x{370}-\x{37D}'
  . '\x{37F}-\x{1FFF}'
  . '\x{200C}-\x{200D}'
  . '\x{2070}-\x{218F}'
  . '\x{2C00}-\x{2FEF}'
  . '\x{3001}-\x{D7FF}'
  . '\x{F900}-\x{FDCF}'
  . '\x{FDF0}-\x{FFFD}'
  . '\x{10000}-\x{EFFFF}';
my $cc_namechar_nc =
  $cc_namestartchar_nc
  . '-'
  . '.'
  . '0-9'
  . '\x{B7}'
  . '\x{0300}-\x{036F}'
  . '\x{203F}-\x{2040}';
my $re_ncname = qr/[${cc_namestartchar_nc}][${cc_namechar_nc}]*/o;

sub expand_xpath_event {
  my $oldxpath = shift(@_);
  my $re_xpathtoken = qr{
    (?:
      # $1: this contains all the non-variable stuff
      (
        (?!)   # impossible to match -- just so we can start using '|' before
               # the first alternative below

      # special characters
      | \( | \) | \[ | \] | \. | \.\. | \@ | , | ::

      # operators
      | and | or | mod | div
      | \/ | \/\/ | \| | \+ | - | = | != | < | <= | > | >= | \*

      # reserved names
      | comment | text | processing-instruction    # NodeType
      | ancestor-or-self | ancestor | attribute | child | descendant-or-self | descendant | following-sibling | following | namespace | parent | preceding-sibling | preceding | self    # AxisName

      # Literal
      | "[^"]*"
      | '[^']*'

      # Number
      | [0-9]+ (?: \. (?: [0-9]+ )? )?
      | \. [0-9]+

      # $2: QName (so we can grab "function" names)
      | ( (?: $re_ncname :)? $re_ncname )

      # NameTest (except for those that already matched QName)
      | (?: $re_ncname :)?      # optional prefix, with colon
        (?: \* | $re_ncname )   # wildcard or unqualified name
      )

    |
      # $3: this is variable references ($VARNAME plus our added %VARNAME)
      (
        [\$\%] (?: $re_ncname :)? $re_ncname
      )
    )
  }xo; # compile only once

  my $newxpath = '';
  my @funcstack = ();
  my $parendepth = 0;
  my $lastqname = undef;
  #print STDERR "Original xpath: $oldxpath\n";
  while ($oldxpath =~ s/\A$re_xpathtoken|\A(\s+)//o) {
    #print STDERR " eaten xpath: $oldxpath\n";
    my $popfunc = 0;
    my $gotcomma = 0;
    my $gotopenparen = 0;
    my $newtext = '';
    my $savedlastqname = $lastqname;
    $lastqname = undef;
    if (defined($3)) {
      #print STDERR " Found variable: =>$3<=\n";
      my $var = $3;
      if (exists $magicparams{$var}) {
	$newtext .= $magicparams{$var};
      } elsif ($var =~ /^[%](.*)$/) {
	my $varname = $1;
	$newtext .= "value[\@name='$varname']";
      } else {
	$newtext .= $var;
      }
    } elsif (defined($1)) {
      #print STDERR " Found non-variable: =>$1<=\n";
      my $nonvar = $1;
      if ($nonvar eq '(') {
	$gotopenparen = 1;
	$parendepth += 1;
	if (defined($savedlastqname)) {
	  #print STDERR "==== FUNCTION CALL (maybe) ====\n";
	  #print STDERR "funcstack before:\n " . Dumper(@funcstack) . "\n";
	  # assume this was a "function" call
	  # remove function name already output to newxpath or funcstack
	  my $strref = \$newxpath;
	  if (scalar(@funcstack) > 0) {
	    # $savedlastqname was saved to funcstack, not newxpath
	    my $argsref = $funcstack[$#funcstack]->[2];
	    $strref = \$argsref->[$#$argsref];
	  }
	  my $namelen = length($savedlastqname);
	  #print STDERR "Replacing string:\n $savedlastqname\nat end of:\n$$strref\nand putting it in funcstack as funcname\n";
	  my $replaced = substr($$strref, -1 * $namelen, $namelen, '');
	  if ($replaced ne $savedlastqname) {
	    print STDERR "Internal error: $replaced | $savedlastqname | $$strref\n";
	    exit -1;
	  }
	  push @funcstack, [$savedlastqname, $parendepth, []];
	  #print STDERR "funcstack after:\n " . Dumper(@funcstack) . "\n";
	}
      } elsif ($nonvar eq ',') {
	$gotcomma = 1;
      } elsif ($nonvar eq ')') {
	if (scalar(@funcstack) > 0 && $funcstack[$#funcstack]->[1] == $parendepth) {
	  $popfunc = 1;
	}
	$parendepth -= 1;
      } else {
	if (defined($2)) {
	  $lastqname = $2;
	}
      }
      #print STDERR " Found non-variable: =>$1<=\n";
      $newtext .= $nonvar;
    } else {
      #print STDERR " Found whitespace\n";
      $newtext .= $4;
    }
    if ($popfunc) {
      #print STDERR "==== POP FUNCTION ====\n";
      # see if this is a function we need to deal with
      #print STDERR "funcstack before:\n " . Dumper(@funcstack) . "\n";
      #print STDERR "newxpath before:\n " . $newxpath . "\n";
      my $funcref = pop @funcstack;
      my $funcname = $funcref->[0];
      my $argsref = $funcref->[2];
      if ($funcname eq 'matchany') {
	# Usage: matchany(EXPR, VAL1, VAL2, ...)
	# Returns true if EXPR string-wise matches any one of the VAL
	# arguments.
	#print STDERR "Args:\n " . join("\n ", @$argsref) . "\n";
	my $protect1 = "<";
	my $protect2 = ">";
	for my $p ($protect1, $protect2) {
	  while (grep { index($_, $p) != -1 } @$argsref) {
	    #print STDERR "Increasing protect '$p'...\n";
	    $p .= substr($p, length($p) - 2);
	    #print STDERR "... to '$p'\n";
	  }
	}
	# take a look at haystack args to see if we can just concat them ourselves
	my $haystack = '';
	for my $arg (@$argsref[1..$#$argsref]) {
	  # this regexp excludes leading (before decimal point) and
	  # trailing zeros (after decimal point)
	  if ($arg =~ /^\s*([+-]?)0*([0-9]*)(\.?)([0-9]*?)0*\s*$/) {
	    my $sign = $1;
	    my $int = $2;
	    my $point = $3;
	    my $fraction = $4;
	    if (length($point) > 0 && length($fraction) == 0) {
	      $point = '';
	    }
	    #print STDERR "found number: $sign$int$point$fraction\n";
	    $haystack .= "$protect1$sign$int$point$fraction$protect2";
	  } elsif ($arg =~ /^("|')(?:[^"]*+)\1$/) {
	    #print STDERR "found quoted string without double quotes: $2\n";
	    # quoted string without double quotes inside
	    $haystack .= "$protect1$2$protect2";
	  } else {
	    #print STDERR "Can't just insert into haystack: $arg\n";
	    $haystack = undef;
	    last;
	  }
	}
	# output the new transformed function
	$newtext = '';
	$newtext .= 'contains(';
	if (defined($haystack)) {
	  $newtext .= "\"$haystack\"";
	} else {
	  $newtext .= 'concat(';
	  $newtext .= join('', map { ('"', $protect1, '",string(', $_, '),"', $protect2, '",') } @{$argsref}[1..$#$argsref]);
	  $newtext .= '""';
	  $newtext .= ')';
	}
	$newtext .= ',';
	{
	  $newtext .= join('', 'concat("', $protect1, '",string(', $argsref->[0], '),"', $protect2, '")');
	}
	$newtext .= ')';
      } else {
	$newtext = '';
	$newtext .= $funcname;
	$newtext .= '(' . join(', ', @$argsref) . ') ';
      }
      #print STDERR "funcstack after:\n " . Dumper(@funcstack) . "\n";
      #print STDERR "newtext after:\n " . $newtext . "\n";
    }
    if (length($newtext) > 0) {
      #print STDERR "==== APPENDING TEXT ====\n";
      #print STDERR "newtext: ==>$newtext<==\n";
      if (scalar(@funcstack) > 0) {
	# push new text
	my $funcref = $funcstack[$#funcstack];
	my $funcdepth = $funcref->[1];
	my $argsref = $funcref->[2];
	my $atcurdepth = ($funcdepth == $parendepth);
	#print STDERR "args before:\n " . Dumper(@$argsref) . "\n";
	if ($atcurdepth && $gotcomma) {
	  if (scalar(@$argsref) != 0) {
	    # there was actually an argument here, and we got a comma, so
	    # create a new empty argument to hold future text
	    push @$argsref, '';
	  }
	  # otherwise just keep it empty in case it is an empty argument list
	} elsif ($atcurdepth && $gotopenparen) {
	  # just got the open paren, no need to encode anything
	  1;			# no-op
	} else {
	  if (scalar(@$argsref) == 0) {
	    push @$argsref, $newtext;
	  } else {
	    $argsref->[$#$argsref] .= $newtext;
	  }
	}
	#print STDERR "args after:\n " . Dumper(@$argsref) . "\n";
	# whatever was in $newtext is encoded now in the args and will get
	# output when the function call hits the closing paren
      } else {
	#print STDERR "newxpath before:\n " . $newxpath . "\n";
	$newxpath .= $newtext;
	#print STDERR "newxpath after:\n " . $newxpath . "\n";
      }
    }
  }
  if ($oldxpath ne '') {
    print STDERR "Found unparseable XPath here => $oldxpath\n";
    exit -1
  }
  #print STDERR "Returning newxpath: $newxpath\n";
  return $newxpath;
}


1;
