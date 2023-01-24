package BXHPerlUtils::XMLMetadata::XCEDE2;
use base qw(BXHPerlUtils::XMLMetadata);
sub new {
  my $self =
	{
	 'failed' => 0,
	 'path' => [],
	 'indimension' => 0,
	 'indimpathsize' => undef,
	 'curdim' => undef,
	 'curdatapointslabel' => undef,
	 'foundbvaluesdatapoints' => 0,
	 'characters' => '',
	 'attstack' => [],
	};
  bless $self;
}
sub start_element {
  my ($self, $el) = @_;
  my $localname = $el->{'LocalName'};
  my $pathref = $self->{'path'};
  push @$pathref, $localname;
  # save attributes for end_element
  push @{$self->{'attstack'}}, $el->{'Attributes'};
  return if scalar(@$pathref) < 2;
  if ($localname eq 'dimension' && !$self->{'indimension'}) {
	return if $pathref->[$#$pathref-1] ne 'resource';
	return if ! grep { $_->{'LocalName'} ne 'image' } values %{$el->{'Attributes'}};
	$self->{'indimension'} = 1;
	$self->{'indimpathsize'} = scalar(@$pathref);
	my $type = $el->{'Attributes'}->{'{}label'}->{'Value'};
	my $rank = '';
	if (exists($el->{'Attributes'}->{'{}splitRank'})) {
	  $rank = '-split' . $el->{'Attributes'}->{'{}splitRank'}->{'Value'};
	}
	$self->{'dims'}->{$type} = {'type'=>$type};
	if (exists $el->{'Attributes'}->{'{}outputselect'}) {
	  $self->{'dims'}->{$type}->{'outputselect'} = $el->{'Attributes'}->{'{}outputselect'}->{'Value'};
	}
	$self->{'curdim'} = $self->{'dims'}->{$type};
  } elsif ($localname eq 'datapoints') {
	if (exists($el->{'Attributes'}->{'{}label'})) {
	  $self->{'curdatapointslabel'} = $el->{'Attributes'}->{'{}label'}->{'Value'};
	}
  }
  return;
}
sub characters {
  my ($self, $el) = @_;
  $self->{'characters'} .= $el->{'Data'};
}
sub end_element {
  my ($self, $el) = @_;
  my $localname = $el->{'LocalName'};
  my $pathref = $self->{'path'};
  my $pathsize = scalar(@$pathref);
  my $characters = $self->{'characters'};
  my $attrs = pop @{$self->{'attstack'}};
  $self->{'characters'} = '';
  if ($localname ne $pathref->[$#$pathref]) {
	die "Internal error!\n";
  }
  pop @$pathref;
  if ($localname eq 'bvalues' ||
	  (($localname eq 'param' or $localname eq 'acqParam') && exists($attrs->{'{}name'}) && $attrs->{'{}name'}->{'Value'} eq 'bvalues')) {
    if (!$self->{'foundbvaluesdatapoints'}) {
	$characters =~ s/^\s+//;
	$characters =~ s/\s+$//;
	$self->{'bvalues'} = [split(/\s+/, $characters)];
    }
  }
  if ($localname eq 'elementType') {
	$characters =~ s/^\s+//;
	$characters =~ s/\s+$//;
	$self->{'elementtype'} = $characters;
  }
  if ($localname eq 'sliceorder' ||
	  (($localname eq 'param' or $localname eq 'acqParam') && exists($attrs->{'{}name'}) && $attrs->{'{}name'}->{'Value'} eq 'sliceorder')) {
	$characters =~ s/^\s+//;
	$characters =~ s/\s+$//;
	$self->{'sliceorder'} = [split(/,/, $characters)];
  }
  return if !$self->{'indimension'};
  if ($localname eq 'dimension' && $self->{'indimpathsize'} == $pathsize) {
	$self->{'indimension'} = 0;
	$self->{'indimpathsize'} = undef;
  }
  return if scalar(@$pathref) == 0;
  $characters =~ s/^\s+//;
  $characters =~ s/\s+$//;
  if ($localname eq 'size') {
	$self->{'curdim'}->{'size'} = $characters;
  } elsif ($localname eq 'origin') {
	$self->{'curdim'}->{'origin'} = $characters;
  } elsif ($localname eq 'spacing') {
	$self->{'curdim'}->{'spacing'} = $characters;
  } elsif ($localname eq 'direction') {
	$self->{'curdim'}->{'direction'} = [ split(/\s+/, $characters) ];
  } elsif ($localname eq 'datapoints') {
	if ($characters ne '') {
	    $self->{'curdim'}->{'datapoints'}->{$self->{'curdatapointslabel'}} = [split(/\s+/, $characters)];
	}
	if ($self->{'curdatapointslabel'} eq 'bvalues') {
	    $self->{'bvalues'} = $self->{'curdim'}->{'datapoints'}->{$self->{'curdatapointslabel'}};
	    # don't let a <bvalues> or <acqParam name="bvalues"> element
	    # overwrite the above as this is the definitive one.
	    $self->{'foundbvaluesdatapoints'} = 1;
	}
	$self->{'curdatapointslabel'} = undef;
  } elsif ($localname eq 'value' && $pathref->[$#$pathref] eq 'datapoints') {
    if (defined($self->{'curdatapointslabel'})) {
	push @{$self->{'curdim'}->{'datapoints'}->{$self->{'curdatapointslabel'}}}, $characters;
    } else {
	push @{$self->{'curdim'}->{'datapoints'}->{''}}, $characters;
    }
  } elsif ($localname eq 'measurementframe' && exists($attrs->{'{}version'})) {
	push @{$self->{'curdim'}->{'measurementframeversion'}}, $characters;
  } elsif ($localname eq 'vector' && $pathref->[$#$pathref] eq 'measurementframe') {
	push @{$self->{'curdim'}->{'measurementframe'}}, [ split(/\s+/, $characters) ];
  }
}
sub end_document {
  my ($self,) = @_;
  delete $self->{'path'};
  delete $self->{'indimension'};
  delete $self->{'indimpathsize'};
  delete $self->{'curdim'};
  delete $self->{'curdatapointslabel'};
  delete $self->{'foundbvaluesdatapoints'};
  delete $self->{'characters'};
}

__PACKAGE__;
