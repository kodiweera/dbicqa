# Attempt to load an XML module, trying several alternatives.
# Also add some functions to these modules so the functions we use all
# behave similarly.

package XMLUtils;

use strict;
no strict 'subs';
use warnings;

use FindBin;
use lib "$FindBin::Bin";
use File::Which;

use Config;

BEGIN {
  use Exporter ();
  our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

  @ISA         = qw(Exporter);
  @EXPORT      = qw(&readXMLFile &createDocument &xpathFindNodes &xpathFindValue &clone_and_append_child);
  @EXPORT_OK   = qw($opt_verbose);
}
our @EXPORT_OK;

our $opt_verbose = 0;

# file globals
my $xpathparser = undef;
my $domparsername = undef;
my $sub_readxmlfile = undef;
my $sub_createdocument = undef;
my $sub_xpathfindnodes = undef;
my $sub_xpathfindvalue = undef;

sub readXMLFile {
  $sub_readxmlfile->(@_);
}
sub createDocument {
  $sub_createdocument->(@_);
}
sub xpathFindNodes {
  $sub_xpathfindnodes->(@_);
}
sub xpathFindValue {
  $sub_xpathfindvalue->(@_);
}

# these evals need to be in quotes, not curly braces, otherwise they will
# be run at compile time, and will cause the program to break if the module
# is not installed or doesn't work.
eval "use XML::LibXML";
if (!$@) {
  $domparsername = 'XML::LibXML';
} else {
  # no XML::LibXML, so try something else
  eval "use XML::XPath";
  if (!$@) {
    $domparsername = 'XML::XPath';
  } else {
    eval "use XML::DOM::Lite";
    if ($@) {
      print STDERR "Can't find XML::LibXML, XML::XPath, or XML::DOM::Lite\n";
      exit -1;
    }
    $domparsername = 'XML::DOM::Lite';
  }
}
print STDERR "Using module '$domparsername':\n" if ($opt_verbose);
if ($domparsername eq 'XML::XPath') {
  import XML::XPath;
  import XML::XPath::XMLParser;
  import XML::XPath::Node;
  import XML::XPath::Node qw/ :node_keys /;

  $sub_readxmlfile = sub {
    my ($filename,) = @_;
    my $parser = new XML::XPath::XMLParser;
    return $parser->parsefile($filename);
  };
  $sub_createdocument = sub {
    my ($rootname, ) = @_;
    my $doc = new XML::XPath::Node::Element;
    my $root = $doc->createElement($rootname);
    $doc->appendChild($root);
    return $doc;
  };
  $xpathparser = XML::XPath->new();
  $sub_xpathfindnodes = sub{
    my ($expr, $context) = @_;
    return $xpathparser->findnodes($expr, $context);
  };
  $sub_xpathfindvalue = sub{
    my ($expr, $context) = @_;
    my $retval = $context->findvalue($expr, $context);
    return undef if !defined($retval);
    return $retval->value();
  };

  package XML::XPath::NodeImpl;
  # XML::XPath::XMLParser uses the following structure for
  # XML nodes:
  #
  #  [
  #    node_parent,
  #    node_pos,
  #    ...type-specific data...
  #  ]
  #
  # Positions of various fields are imported through the :node_keys
  # import tag.
  import XML::XPath::Node;
  import XML::XPath::Node qw/ :node_keys /;
  our %elemstrs =
    (
     UNKNOWN_NODE(), 'UNKNOWN',
     ELEMENT_NODE(), 'ELEMENT',
     ATTRIBUTE_NODE(), 'ATTRIBUTE',
     TEXT_NODE(), 'TEXT',
     PROCESSING_INSTRUCTION_NODE(), 'PI',
     COMMENT_NODE(), 'COMMENT',
     NAMESPACE_NODE(), 'NAMESPACE_DECL',
    );
  sub getNodeTypeStr {
    my ($self, ) = @_;
    return $elemstrs{$self->getNodeType()};
  };
  sub cloneNode {
    my ($self, $deep) = @_;
    my $clone = bless([@$self], ref($self));
    $clone->[node_parent()] = undef;
    if ($self->getNodeType() == ELEMENT_NODE()) {
      if ($deep) {
	my $children = $clone->[node_children()];
	my $attribs = $clone->[node_attribs()];
	my $namespaces = $clone->[node_namespaces()];
	if (defined($children)) {
	  $clone->[node_children()] =
	    [
	     map {
	       $_->cloneNode(deep=>$deep);
	     } @$children
	    ];
	}
	if (defined($attribs)) {
	  $clone->[node_attribs()] =
	    [
	     map {
	       $_->cloneNode(deep=>$deep);
	     } @$attribs
	    ];
	}
	if (defined($namespaces)) {
	  $clone->[node_namespaces()] =
	    [
	     map {
	       $_->cloneNode(deep=>$deep);
	     } @$namespaces
	    ];
	}
      } else {
	$clone->[node_children()] = [];
	$clone->[node_attribs()] = [];
	$clone->[node_namespaces()] = [];
      }
    }
    return $clone;
  }
  sub getNodeName {
    my ($self,) = @_;
    return $self->getName();
  }
  sub importNode {
    my ($self, $node, $deep) = @_;
    return $node->cloneNode($deep);
  }
  sub createElement {
    my ($self, $tagname) = @_;
    return new XML::XPath::Node::Element($tagname);
  }
  sub createTextNode {
    my ($self, $content) = @_;
    return new XML::XPath::Node::Text($content);
  }
  sub getOwnerDocument {
    my ($self, ) = @_;
    my $parent = $self->getParentNode();
    if (defined($parent)) {
      return $parent->getOwnerDocument();
    } else {
      $self;
    }
  }
  sub setOwnerDocument {
    # no-op
  }
} elsif ($domparsername eq 'XML::LibXML') {
  import XML::LibXML;
  $sub_readxmlfile = sub {
    my ($filename,) = @_;
    my $parser = XML::LibXML->new();
    return $parser->parse_file($filename);
  };
  $sub_createdocument = sub {
    my ($rootname, ) = @_;
    my $doc = XML::LibXML::Document->createDocument();
    my $root = $doc->createElement($rootname);
    $doc->setDocumentElement($root);
    return $doc;
  };
  $xpathparser = undef;
  $sub_xpathfindnodes = sub {
    my ($expr, $context) = @_;
    return $context->findnodes($expr);
  };
  $sub_xpathfindvalue = sub {
    my ($expr, $context) = @_;
    return $context->findvalue($expr);
  };

  package XML::LibXML::Node;
  our %elemstrs =
    (
     0 => 'UNKNOWN',
     1 => 'ELEMENT',
     2 => 'ATTRIBUTE',
     3 => 'TEXT',
     4 => 'CDATA_SECTION',
     5 => 'ENTITY_REF',
     6 => 'ENTITY',
     7 => 'PI',
     8 => 'COMMENT',
     9 => 'DOCUMENT',
     10 => 'DOCUMENT_TYPE',
     11 => 'DOCUMENT_FRAG',
     12 => 'NOTATION',
     13 => 'HTML_DOCUMENT',
     14 => 'DTD',
     15 => 'ELEMENT_DECL',
     16 => 'ATTRIBUTE_DECL',
     17 => 'ENTITY_DECL',
     18 => 'NAMESPACE_DECL',
     19 => 'XINCLUDE_START',
     20 => 'XINCLUDE_END',
     21 => 'DOCB_DOCUMENT',
    );
  sub getNodeTypeStr {
    my ($self, ) = @_;
    return $elemstrs{$self->nodeType()};
  }
  sub getNodeName {
    my ($self, ) = @_;
    return $self->nodeName();
  }
  sub setNodeValue {
    my ($self, $value) = @_;
    return $self->setData($value);
  }
} elsif ($domparsername eq 'XML::DOM::Lite') {
  import XML::DOM::Lite;
  $sub_readxmlfile = sub {
    my ($filename,) = @_;
    my $parser = XML::DOM::Lite::Parser->new();
    return $parser->parseFile($filename);
  };
  $sub_createdocument = sub {
    my ($rootname, ) = @_;
    my $parser = XML::DOM::Lite::Parser->new();
    my $doc = $parser->parse(<<EOM);
<?xml version="1.0"?>
<$rootname>
</$rootname>
EOM
    return $doc;
  };
  $xpathparser = undef;
  $sub_xpathfindnodes = sub {
    my ($expr, $context) = @_;
    my $retval = XML::DOM::Lite::XPath->evaluate($expr, $context);
    if (ref($retval) ne 'ARRAY') {
      return ();
    } else {
      return @$retval;
    }
  };
  $sub_xpathfindvalue = sub {
    my ($expr, $context) = @_;
    return XML::DOM::Lite::XPath->evaluate('string(' . $expr . ')', $context);
  };
  package XML::DOM::Lite::Node;
  sub getFirstChild {
    my ($self, ) = @_;
    return $self->firstChild();
  }
  sub getNextSibling {
    my ($self, ) = @_;
    return $self->nextSibling();
  }
  our %elemstrs =
    (
     0 => 'UNKNOWN',
     1 => 'ELEMENT',
     2 => 'ATTRIBUTE',
     3 => 'TEXT',
     4 => 'CDATA_SECTION',
     5 => 'ENTITY_REF',
     6 => 'ENTITY',
     7 => 'PI',
     8 => 'COMMENT',
     9 => 'DOCUMENT',
     10 => 'DOCUMENT_TYPE',
     11 => 'DOCUMENT_FRAG',
     12 => 'NOTATION',
    );
  sub getNodeTypeStr {
    my ($self, ) = @_;
    return $elemstrs{$self->nodeType()};
  }
  sub getNodeName {
    my ($self, ) = @_;
    return $self->nodeName();
  }
  sub importNode {
    my ($self, $node, $deep) = @_;
    my $retval = $node->cloneNode($deep);
    return $retval;
  }
}

sub clone_and_append_child {
  my ($doc, $parent_in, $child_in) = @_;
  my $newchild = $doc->importNode($child_in, 1);
  $parent_in->appendChild($newchild);
  return $newchild;
}


1;
