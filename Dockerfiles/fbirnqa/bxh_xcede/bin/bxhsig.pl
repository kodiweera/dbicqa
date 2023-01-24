#!/usr/bin/perl -w

use strict;

use FindBin;
use lib "$FindBin::Bin";

use XML::DOM::Lite;
use Digest::MD5 qw/ md5_hex /;
use File::Spec;

my $printcanonical = 0;

if (grep { $_ =~ /^--printcanonical$/ } @ARGV) {
  @ARGV = grep { $_ !~ /^--printcanonical$/ } @ARGV;
  $printcanonical = 1;
}

my $infilename;
while ($infilename = shift) {
  my $parser = XML::DOM::Lite::Parser->new();
  my $doc = $parser->parseFile($infilename);
  my $bxh = $doc->documentElement();
  my $xpresult = XML::DOM::Lite::XPath->evaluate("*", $bxh);
  for my $node (@$xpresult) {
    if ($node->nodeName eq "history" || $node->nodeName eq "provenance") {
      $node->parentNode()->removeChild($node);
    } elsif ($node->nodeName eq "datarec") {
      my $filenamenodes = XML::DOM::Lite::XPath->evaluate("filename", $node);
      for my $filenamenode (@$filenamenodes) {
        my $content = '';
        for (my $curnode = $filenamenode->firstChild;
             defined($curnode);
             $curnode = $curnode->nextSibling) {
          if ($curnode->nodeType eq XML::DOM::Lite::Constants::TEXT_NODE) {
            $content .= $curnode->nodeValue;
          } else {
            next;
          }
        }
        my ($vol, $dirs, $file) = File::Spec->splitpath($content);
        while ($filenamenode->firstChild) {
          $filenamenode->removeChild($filenamenode->firstChild);
        }
        my $newtextnode = $doc->createTextNode($file);
        $filenamenode->appendChild($newtextnode);
      }
    }
  }
  my $canon_xml = $doc->xml;
  if ($printcanonical) {
    print $canon_xml;
    exit 0;
  }
  my $digest = md5_hex($canon_xml);
  print "$digest\t$infilename\n";
}
