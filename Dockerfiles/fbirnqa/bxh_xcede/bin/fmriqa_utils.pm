package fmriqa_utils;

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin";
use File::Which;

use POSIX qw(DBL_EPSILON);

use Config;

BEGIN {
  use Exporter ();
  our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

  # if using RCS/CVS, this may be preferred
  $VERSION = sprintf "%d.%03d", q$Revision: 1.5 $ =~ /(\d+)/g;

  @ISA         = qw(Exporter);
  @EXPORT      = qw(&calcmin &calcmax &calcmean &calcmeanstddev &showhide &showhide_checkbox &plotdata &showplots &no_zero);

}
our @EXPORT_OK;

sub no_zero {
  if ($_[0] == 0) {
    return DBL_EPSILON;
  }
  return $_[0];
}

sub calcmean {
  return undef if (scalar(@_) == 0);
  my $mean = 0;
  for (my $ind = 0; $ind < scalar(@_); $ind++) {
    $mean += ($_[$ind] - $mean) / ($ind + 1);
  }
  return $mean;
}

sub calcmeanstddev {
  return (undef,undef) if (scalar(@_) == 0);
  my $prevMean = 0;
  my $currMean = 0;
  my $currVar = 0;
  my $prevSD2 = 0;
  my $currSD2 = 0;
  for (my $ind = 0; $ind < scalar(@_); $ind++) {
    my $x = $_[$ind];
    if ($ind == 0) {
      $currMean = $x;
      $currVar = 0;
      $currSD2 = 0;
    } else {
      $prevMean = $currMean;
      $prevSD2 = $currSD2;
      $currMean = $prevMean + (($x - $prevMean) / ($ind + 1.0));
      $currSD2 = $prevSD2 + (($x - $prevMean) * ($x - $currMean));
      $currVar = $currSD2 / $ind;
    }
  }
  return ($currMean, sqrt($currVar));
}

sub calcmin {
  return undef if (scalar(@_) == 0);
  my $min = $_[0];
  for (my $ind = 1; $ind < $#_; $ind++) {
    if ($_[$ind] < $min) {
      $min = $_[$ind];
    }
  }
  return $min;
}

sub calcmax {
  return undef if (scalar(@_) == 0);
  my $max = $_[0];
  for (my $ind = 1; $ind < $#_; $ind++) {
    if ($_[$ind] > $max) {
      $max = $_[$ind];
    }
  }
  return $max;
}

sub showhide {
  # add a show/hide data button that triggers display of element with id $id
  my ($id, $showstr, $hidestr, $show) = @_;
  my $retval;
  if ($show) {
    $retval = <<EOM;
<a href="javascript:;" id="show$id" style="display:none" onclick="showhide_show('$id');">$showstr</a>
<a href="javascript:;" id="hide$id" onclick="showhide_hide('$id');">$hidestr</a>
EOM
  } else {
    $retval = <<EOM;
<a href="javascript:;" id="show$id" onclick="showhide_show('$id');">$showstr</a>
<a href="javascript:;" id="hide$id" style="display:none" onclick="showhide_hide('$id');">$hidestr</a>
EOM
  }
  chop $retval; # get rid of newline
  return $retval;
}

sub showhide_checkbox {
  # add a show/hide data checkbox that triggers display of element with id $id
  # Mark it checked if $checked is set.
  my ($id, $checked) = @_;
  if ($checked) {
    $checked = "checked=\"checked\"";
  } else {
    $checked = '';
  }
  my $retval = <<EOM;
<input type="checkbox" $checked value="$id" id="cb_${id}" onclick="showhide_cb_toggle(this,'$id');" />
EOM
  chop $retval; # get rid of newline
  return $retval;
}


# 'outputfh' is where to send HTML output
# 'outputvol' and 'outputdir' are the volume and directory where the output
#   files should go
# 'plotname' is a unique name for this plot (used for filenames, etc.)
# 'dataref' is a reference to an array of file data structures.  Each file data
#   structure is a reference to an array of two data columns.  Each data column
#   is an array reference, containing data for x (column 1) or y (column 2).
# 'plotlabelsref' is a reference to an array of labels that should be used
#   in labeled individual plot lines
# 'plottitle' is the title to be used for the plots
# 'xlabel' is the label for the x-axis
# 'ylabel' is the label for the y-axis
# 'normmethod' is
#   0 for no normalization (default)
#   1 to show difference from mean, as percent of normbaseline
#   2 to show difference from mean
# 'normbaseline' can be specified explicitly, or will be the mean of input
#   data.
# 'plotstyle' is gnuplot plot style (default 'lines')
# 'yrangeref' is a reference to a two-element array representing the low and
#   high points for the y-axis, for aggregate plots.  It is also used for
#   individual plots if "indivrange" is specified.
# 'indivrange', if non-zero, means the range of the "individual" plots should
#   be scaled separately for each plot.  If not set, the individual plots will
#   look the same as on the overlay plots.
# 'dontrescale', if non-zero, suppresses the functionality of overriding the
#   range given in yrangeref if the data is out of range (a message is placed
#   in the plot if the data is rescaled).
# 'histobintype' can be 'stddev' (default), 'explicitpercent WIDTH
#   BASE' or 'explicit WIDTH ZERO', and specifies whether the bins
#   should reflect the number of standard deviations from the
#   normbaseline, or whether the bins are specified by WIDTH-sized
#   bins to the right and left of ZERO (both WIDTH and ZERO must be
#   (floating-point) numbers).  In the case of 'explicitpercent',
#   WIDTH is in units of percent from BASE.
# 'histobins' specifies a scalar reference into which a reference to the
#   histogram data will be written.
# 'histocenter', if non-zero, specifies that histogram bins should be centered
#   on the center value.  For example, rather than [-1,0), [0,1), etc. they
#   would be [-1.5,-0.5), [-0.5,0.5), [0.5,1.5).
sub plotdata {
  my $proggnuplot   = shift @_;
  my $progconvert   = shift @_;
  my $plothashref   = shift @_;
  my $gnuplotimgtype = $plothashref->{'gnuplotimgtype'} || 'pbm';
  my $outputvol     = $plothashref->{'outputvol'};
  my $outputdir     = $plothashref->{'outputdir'};
  my $plotname      = $plothashref->{'plotname'};
  my $dataref       = $plothashref->{'dataref'};
  my $plotlabelsref = $plothashref->{'plotlabelsref'};
  my $plottitle     = $plothashref->{'plottitle'};
  my $xlabel        = $plothashref->{'xlabel'};
  my $ylabel        = $plothashref->{'ylabel'};
  my $normmethod    = $plothashref->{'normmethod'};
  my $yrangeref     = $plothashref->{'yrangeref'};
  my $plotstyle     = $plothashref->{'plotstyle'};
  my $indivrange    = $plothashref->{'indivrange'};
  my $normbaseline  = $plothashref->{'normbaseline'};
  my $dontrescale   = $plothashref->{'dontrescale'};
  my $histobintype  = $plothashref->{'histobintype'};
  my $histobins     = $plothashref->{'histobins'};
  my $histoxlabel   = $plothashref->{'histoxlabel'};
  my $histocenter   = $plothashref->{'histocenter'};
  my $plotcmdsfile  = File::Spec->catpath($outputvol, $outputdir, "tmpplotcmds$$");

  my $gnuplotimgoptions = '';
  if ($gnuplotimgtype eq 'pbm') {
    $gnuplotimgoptions = 'color';
  }

  $plottitle = '' if !defined($plottitle);
  $xlabel = '' if !defined($xlabel);
  $ylabel = '' if !defined($ylabel);
  $normmethod = 0 if !defined($normmethod);
  $plotstyle = 'lines' if !defined($plotstyle);
  $indivrange = 0 if !defined($indivrange);
  $dontrescale = 0 if !defined($dontrescale);
  $histobintype = 'stddev' if !defined($histobintype);
  $histocenter = 0 if !defined($histocenter);

  if (!defined($plotname)) {
    die "'plotname' must be defined in plotdata argument hash!";
  }
  if (!defined($dataref)) {
    die "'dataref' must be defined in plotdata argument hash!";
  }
  if (!defined($plotlabelsref)) {
    die "'plotlabelsref' must be defined in plotdata argument hash!";
  }
  if ($normmethod < 0 || $normmethod > 2) {
    die "normmethod must be 0 (no normalization), 1 (mean == 1), or 2 (mean == 0)";
  }
  if ($histobintype ne 'stddev' && $histobintype !~ /^explicit(percent)?\s+((\d+)?\.?(\d+)?)\s+((\d+)?\.?(\d+)?)$/) {
    die "Only valid histobintypes for normmethod==$normmethod are 'stddev', 'explicitpercent NUM NUM', and 'explicit NUM NUM'\n";
  }

  my $numfiles = scalar(@$dataref);

  # save size of each array
  my $maxrow = -1;
  my @maxrows = ();
  for my $filenum (0..$#$dataref) {
    push @maxrows, $#{$dataref->[$filenum]->[0]};
    if ($maxrows[$#maxrows] > $maxrow) {
      $maxrow = $maxrows[$#maxrows];
    }
  }
  # calculate means, stddevs, sums, mins, maxs
  my $datasum = 0;
  my $datassd = 0;
  my $datamean = 0;
  my $datanum = 0;
  my $datamin = undef;
  my $datamax = undef;
  my $dataxmax = undef;
  my @datasums = ();
  my @datassds = ();
  my @datameans = ();
  my @datanums = ();
  my @datamins = ();
  my @datamaxs = ();
  my @dataxmaxs = ();
  for my $filenum (0..$#$dataref) {
    my $arrayref = $dataref->[$filenum]->[1];
    my $filedatamean = 0;
    my $filedatassd = 0;
    my $filedatanum = 0;
    map {
      my $prevdatamean = $datamean;
      my $prevdatassd = $datassd;
      my $prevfiledatamean = $filedatamean;
      my $prevfiledatassd = $filedatassd;
      $datanum++;
      $filedatanum++;
      $datamean = $prevdatamean + (($_ - $datamean) / ($datanum));
      $datassd = $prevdatassd + (($_ - $prevdatamean) * ($_ - $datamean));
      $filedatamean = $prevfiledatamean + (($_ - $prevfiledatamean) / ($filedatanum));
      $filedatassd = $prevfiledatassd + (($_ - $prevfiledatamean) * ($_ - $filedatamean));
    } @$arrayref;
    $datanums[$filenum] = $filedatanum;
    $datameans[$filenum] = $filedatamean;
    $datassds[$filenum] = $filedatassd;
    my $mininfile = undef;
    my $maxinfile = undef;
    my $xmaxinfile = undef;
    map {
      $xmaxinfile = $_ if !defined($xmaxinfile);
      $xmaxinfile = $_ if $_ > $xmaxinfile;
    } @{$dataref->[$filenum]->[0]}[0..$maxrows[$filenum]];
    map {
      $mininfile = $_ if !defined($mininfile);
      $mininfile = $_ if $_ < $mininfile;
      $maxinfile = $_ if !defined($maxinfile);
      $maxinfile = $_ if $_ > $maxinfile;
    } @{$dataref->[$filenum]->[1]}[0..$maxrows[$filenum]];
    $mininfile = 0 if !defined($mininfile);
    $maxinfile = 0 if !defined($maxinfile);
    $datamins[$filenum] = $mininfile;
    $datamaxs[$filenum] = $maxinfile;
    $datamin = $mininfile if !defined($datamin);
    $datamin = $mininfile if $mininfile < $datamin;
    $datamax = $maxinfile if !defined($datamax);
    $datamax = $maxinfile if $maxinfile > $datamax;
    $dataxmax = $xmaxinfile if !defined($dataxmax);
    $dataxmax = $xmaxinfile if $xmaxinfile > $dataxmax;
  }
  my $datastddev = sqrt($datassd / ($datanum - 1));
  my @datastddevs = ();
  for my $filenum (0..$#$dataref) {
    $datastddevs[$filenum] = sqrt($datassds[$filenum] / ($datanums[$filenum] - 1));
  }

  # do the plotting
  my @imagesets = ();
  # chooselist contains a list of the desired plots, and can include
  # 'all, 'allnorm', and any of the file indices
  my @chooselist = ();
  if ($normmethod == 0) {
    push @chooselist, ('all', 0..$#$dataref);
  } else {
    push @chooselist, ('allnorm', 'all', 0..$#$dataref);
  }
  for my $chosen (@chooselist) {
    my @filenumlist = ();
    my $plotimg = "qa_${plotname}_${chosen}.png";
    my $histoimg = "qa_${plotname}_${chosen}_histo.png";
    if ($chosen ne 'all' && $chosen ne 'allnorm') {
      my $filelabel = $plotlabelsref->[$chosen];
      $filelabel =~ s%[\\/]%_%g;
      $plotimg = "qa_${plotname}_${filelabel}.png";
      $histoimg = "qa_${plotname}_${filelabel}_histo.png";
    }
    if ($chosen eq 'all') {
      push @filenumlist, (0..$#$dataref);
      push @imagesets, ["all", "qa_plot_${plotname}_all", 1, $plotimg, $histoimg];
    } elsif ($chosen eq 'allnorm') {
      push @filenumlist, (0..$#$dataref);
      push @imagesets, ["allnorm", "qa_plot_${plotname}_allnorm", 1, $plotimg];
    } else {
      my $filelabel = $plotlabelsref->[$chosen];
      $filelabel =~ s%[\\/]%_%g;
      push @filenumlist, $chosen;
      push @imagesets, [$plotlabelsref->[$chosen], "qa_plot_${plotname}_${filelabel}", 0, $plotimg, $histoimg];
    }

    # For each input column, calculate normalization parameters.
    # The plotted function is percentmult * (f(x) - zero) / normbaseline
    my @zeros = ();
    my @normbaselines = ();
    my @percentmults = ();
    if ($normmethod == 0) {
      @zeros[@filenumlist] = (0) x scalar(@filenumlist);
    } else {
      if ($chosen eq 'all') {
	@zeros[@filenumlist] = ($datamean) x scalar(@filenumlist);
      } else {
	@zeros[@filenumlist] = @datameans[@filenumlist];
      }
    }
    if ($normmethod == 1) {
      if (defined($normbaseline)) {
	@normbaselines[@filenumlist] = ($normbaseline) x scalar(@filenumlist);
      } else {
	if ($chosen eq 'all') {
	  @normbaselines[@filenumlist] = ($datamean) x scalar(@filenumlist);
	} else {
	  @normbaselines[@filenumlist] = @datameans[@filenumlist];
	}
      }
    } else {
      @normbaselines[@filenumlist] = (1) x @filenumlist;
    }
    if ($normmethod == 1) {
      @percentmults[@filenumlist] = (100) x @filenumlist;
    } else {
      @percentmults[@filenumlist] = (1) x @filenumlist;
    }

    # choose a default plot range (and normalize it)
    my $defrangemin = undef;
    my $defrangemax = undef;
    if ($normmethod == 0) {
      # just choose min and max as default range
      if ($chosen eq 'allnorm') {
	# find the widest plot range from -4 to 4 times stddev from the mean
	for my $filenum (@filenumlist) {
	  my $tmprangemin = $datamins[$filenum];
	  my $tmprangemax = $datamaxs[$filenum];
	  $tmprangemin = $percentmults[$filenum] * ($tmprangemin - $zeros[$filenum]) / no_zero($normbaselines[$filenum]);
	  $tmprangemax = $percentmults[$filenum] * ($tmprangemax - $zeros[$filenum]) / no_zero($normbaselines[$filenum]);
	  if (!defined($defrangemin) || $tmprangemin < $defrangemin) {
	    $defrangemin = $tmprangemin;
	  }
	  if (!defined($defrangemax) || $tmprangemax > $defrangemax) {
	    $defrangemax = $tmprangemax;
	  }
	}
      } elsif ($chosen eq 'all') {
	$defrangemin = $datamin;
	$defrangemax = $datamax;
      } else {
	if ($indivrange) {
	  $defrangemin = $datamins[$chosen];
	  $defrangemax = $datamaxs[$chosen];
	} else {
	  $defrangemin = $datamin;
	  $defrangemax = $datamax;
	}
      }
    } elsif ($chosen eq 'allnorm') {
      # find the widest plot range from -4 to 4 times stddev from the mean
      for my $filenum (@filenumlist) {
	my $tmprangemin = $datameans[$filenum] - (4 * $datastddevs[$filenum]);
	my $tmprangemax = $datameans[$filenum] + (4 * $datastddevs[$filenum]);
	$tmprangemin = $percentmults[$filenum] * ($tmprangemin - $zeros[$filenum]) / no_zero($normbaselines[$filenum]);
	$tmprangemax = $percentmults[$filenum] * ($tmprangemax - $zeros[$filenum]) / no_zero($normbaselines[$filenum]);
	if (!defined($defrangemin) || $tmprangemin < $defrangemin) {
	  $defrangemin = $tmprangemin;
	}
	if (!defined($defrangemax) || $tmprangemax > $defrangemax) {
	  $defrangemax = $tmprangemax;
	}
      }
    } else {
      # choose a default plot range from -4 to 4 times stddev from the mean
      if ($chosen eq 'all') {
	$defrangemin = $datamean - (4 * $datastddev);
	$defrangemax = $datamean + (4 * $datastddev);;
      } else {
	if ($indivrange) {
	  $defrangemin = $datameans[$chosen] - (4 * $datastddevs[$chosen]);
	  $defrangemax = $datameans[$chosen] + (4 * $datastddevs[$chosen]);
	} else {
	  # use same range as aggregate
	  $defrangemin = $datamean - (4 * $datastddev);
	  $defrangemax = $datamax + (4 * $datastddev);;
	}
      }
      # normalize the range (all values of zero, normbaseline, percentmult
      # will be the same for all but 'allnorm' plots)
      # This is the same normalization that will be applied to the data,
      # so if $indivrange is not set, the individual graphs will have the
      # same visual scale as in the aggregate ('all') plot.
      $defrangemin = $percentmults[$filenumlist[0]] * ($defrangemin - $zeros[$filenumlist[0]]) / no_zero($normbaselines[$filenumlist[0]]);
      $defrangemax = $percentmults[$filenumlist[0]] * ($defrangemax - $zeros[$filenumlist[0]]) / no_zero($normbaselines[$filenumlist[0]]);
    }
    my $rangemin = $defrangemin;
    my $rangemax = $defrangemax;
    if (defined($yrangeref)) {
      # specified range overrides the default range for now
      if (defined($yrangeref->[0])) {
	$rangemin = $yrangeref->[0];
      }
      if (defined($yrangeref->[1])) {
	$rangemax = $yrangeref->[1];
      }
    }
    # create temporary files for normalized data
    my $outofrange = 0;
    my $rescaled = 0;
    my @plotfiles = ();
    for my $filenum (@filenumlist) {
      my $zero = $zeros[$filenum];
      my $normbaseline = $normbaselines[$filenum];
      my $percentmult = $percentmults[$filenum];
      my $matref = $dataref->[$filenum];
      $plotfiles[$filenum] = File::Spec->catpath($outputvol, $outputdir, "tmpplotfile$filenum$$");
      open(TMPFH, ">$plotfiles[$filenum]") ||
	  die "Cannot open temporary output file $plotfiles[$filenum] for writing\n";
      print TMPFH
	join("\n",
	     map {
	       my $xval = $matref->[0]->[$_];
	       my $val = $matref->[1]->[$_];
	       $val = $percentmult * ($val - $zero) / no_zero($normbaseline);
	       if ((defined($rangemin) && $val < $rangemin) ||
		   (defined($rangemax) && $val > $rangemax)) {
		 $outofrange = 1;
	       }
	       join("\t", $xval, $val);
	     } (0..$maxrows[$filenum]));
      close TMPFH;
    }
    if ($outofrange &&
	!$dontrescale &&
	($defrangemin < $rangemin || $defrangemax > $rangemax)) {
      $rescaled = 1;
      $rangemin = $defrangemin;
      $rangemax = $defrangemax;
    }
    # calculate sigmas for display
    my $epsilon = 0.000001;
    my $sigmamean;
    my $sigmastddev;
    if ($chosen eq 'all') {
      $sigmamean = $datamean;
      $sigmastddev = $datastddev;
    } elsif ($chosen eq 'allnorm') {
      # sigmas not displayed
    } else {
      $sigmamean = $datameans[$chosen];
      $sigmastddev = $datastddevs[$chosen];
    }
    my @sigmas = ();
    my @sigmaposs = ();
    my @sigmalabels = ();
    if ($chosen ne 'allnorm' && $sigmastddev != 0) {
      my $sigmastep = int((($rangemax - $rangemin) / 24) / no_zero($sigmastddev)) + 1;
      my @sigmainds = grep { abs($_) <= 4 } map { $_ * $sigmastep } (-4..4);
      @sigmas = map { ($percentmults[$filenumlist[0]] * (($_ * $sigmastddev) / no_zero($normbaselines[$filenumlist[0]]))) } @sigmainds;
      @sigmalabels = map { abs($_) . "s" } @sigmainds;
      @sigmaposs = map { ($percentmults[$filenumlist[0]] * ($sigmamean - $zeros[$filenumlist[0]]) / no_zero($normbaselines[$filenumlist[0]])) + $_ } @sigmas;
      #print "$chosen SIGMAS:\n ", join("\n ", map { "$sigmalabels[$_]: $sigmas[$_]" } (0..$#sigmas)), "\n";
      my @oldsigmas = @sigmas;
      my @oldsigmaposs = @sigmaposs;
      my @oldsigmalabels = @sigmalabels;
      @sigmas = ();
      @sigmaposs = ();
      @sigmalabels = ();
      for (my $ind = 0; $ind < scalar(@sigmainds); $ind++) {
	next if ($oldsigmaposs[$ind] < $rangemin || $oldsigmaposs[$ind] > $rangemax);
	push @sigmas, $oldsigmas[$ind];
	push @sigmaposs, $oldsigmaposs[$ind];
	push @sigmalabels, $oldsigmalabels[$ind];
      }
    }
    my $fullimgfn = File::Spec->catpath($outputvol, $outputdir, "$plotimg");
    my $ylabelext = '';
    if ($rescaled) {
      $ylabelext .= "\\n***Warning: data autoscaled***";
    }
    if ($outofrange) {
      $ylabelext .= "\\n***Warning: some data out of preset range***";
    }
    if ($normmethod == 1 || $normmethod == 2) {
      if ($chosen eq 'allnorm') {
	$ylabelext .= "\\nindividual baselines at 0";
      } else {
	my $tmp = $normbaselines[$filenumlist[0]];
	$ylabelext .= "\\nnormbaseline $tmp";
      }
    }
    open(GNUPLOT, ">$plotcmdsfile");
    print GNUPLOT <<EOM;
set terminal ${gnuplotimgtype} small ${gnuplotimgoptions}
set size .9,.6
set output '${fullimgfn}.${gnuplotimgtype}'
set xlabel "$xlabel"
set ylabel "$ylabel$ylabelext"
set title "$plottitle"
EOM
    print GNUPLOT join("\n", map { "set style line $_ lt $_ lw 1 pt $_ ps 1"} map { $_ + 1 } @filenumlist), "\n";
    if ($chosen ne 'allnorm' && scalar(@sigmas)) {
      print GNUPLOT join("\n", map { "set label \"$sigmalabels[$_]\" at $dataxmax, $sigmaposs[$_]" } (0..$#sigmas)), "\n";
    }
    if ($rangemin == $rangemax) {
      print GNUPLOT "plot [0:$dataxmax] [" . ($rangemin-$epsilon) . ':' . ($rangemax+$epsilon) . "] ";
    } else {
      print GNUPLOT "plot [0:$dataxmax] [$rangemin:$rangemax] ";
    }
    if ($chosen ne 'allnorm' && scalar(@sigmas) && $plotstyle ne 'dots') {
      print GNUPLOT join(", ", map { " $sigmaposs[$_] notitle with lines lt 0 lw 0" } (0..$#sigmas));
      print GNUPLOT ", ";
    }
    print GNUPLOT join(", ", map {my $style = $_ + 1; "'$plotfiles[$_]' using 1:2 title \"$plotlabelsref->[$_]\" with $plotstyle linestyle $style"} @filenumlist);
    print GNUPLOT "\n";
    close GNUPLOT;
    system($proggnuplot, $plotcmdsfile);
    unlink $plotcmdsfile;
    map { unlink $plotfiles[$_] } @filenumlist;
    system($progconvert, "${fullimgfn}.${gnuplotimgtype}", $fullimgfn);
    unlink "${fullimgfn}.${gnuplotimgtype}";

    # histogram
    if ($chosen ne 'allnorm') {
      # create temporary files for histograms
      my $binwidth = $sigmastddev;
      if ($sigmastddev == 0) {
	$binwidth = 0.0000000000001;
      }
      my $zeroloc = $sigmamean;
      my $ticcenter = 0;
      my $ticstep = 1;
      if ($histobintype =~ /^explicitpercent\s+((\d+)?\.?(\d+)?)\s+((\d+)?\.?(\d+)?)/) {
	$binwidth = $1 * $4 / 100.0;
	$ticstep = $1;
	if (!defined($histoxlabel)) {
	  $histoxlabel = '';
	}
      } elsif ($histobintype =~ /^explicit\s+((\d+)?\.?(\d+)?)\s+((\d+)?\.?(\d+)?)/) {
	$binwidth = $1;
	$ticstep = $1;
	$ticcenter = $4;
	$zeroloc = $4;
	if (!defined($histoxlabel)) {
	  $histoxlabel = '';
	}
      }
      if (!defined($histoxlabel)) {
	$histoxlabel = 'Std. Devs. from baseline';
      }
      my $binmin = undef;
      my $numbins = undef;
      my $binref = [];
      if (defined($histobins)) {
	${$histobins}->{$chosen} = $binref;
      }
      if ($histocenter) {
	push @$binref,
	  map { [ $zeroloc + (($_ - 0.5 ) * $binwidth),
		  $zeroloc + (($_ + 0.5 ) * $binwidth),
		  0 ] } (-5..5);
	$binmin = $zeroloc - (5.5 * $binwidth);
	$numbins = 11;
      } else {
	push @$binref,
	  map { [ $zeroloc + (($_ - 1 ) * $binwidth),
		  $zeroloc + ($_ * $binwidth),
		  0 ] } (-4..5);
	$binmin = $zeroloc - (5.0 * $binwidth);
	$numbins = 10;
      }
      for my $filenum (@filenumlist) {
	map {
	  my $binnum = int(($_ - $binmin) / $binwidth);
	  $binnum = 0 if ($binnum < 0);
	  $binnum = $numbins - 1 if ($binnum >= $numbins);
	  $binref->[$binnum]->[2]++;
	} @{$dataref->[$filenum]->[1]}[0..$maxrows[$filenum]];
      }

      my $plothistostdfile = undef;
      $plothistostdfile = File::Spec->catpath($outputvol, $outputdir, "tmp_histostdfile_${chosen}_$$");
      open(TMPFH, ">$plothistostdfile") ||
	die "Cannot open temporary output file $plothistostdfile for writing\n";
      if ($histocenter) {
	print TMPFH join("\n", map { join(" ", $_ - 5, $binref->[$_]->[2]) } (0..$numbins-1)), "\n";
      } else {
	print TMPFH join("\n", map { join(" ", $_ - 4.5, $binref->[$_]->[2]) } (0..$numbins-1)), "\n";
      }
      close TMPFH;

      my @histoxtics = ();
      if ($histocenter) {
	push @histoxtics, [-5, "<=" . ($ticcenter + $ticstep*-4.5)];
      } else {
	push @histoxtics, [-5, "<=" . ($ticcenter + $ticstep*-5)];
      }
      for my $ticind (-4..4) {
	push @histoxtics, [$ticind, ($ticcenter + $ticstep*$ticind)];
      }
      if ($histocenter) {
	push @histoxtics, [5, ">=" . ($ticcenter + $ticstep*4.5)];
      } else {
	push @histoxtics, [5, ">=" . ($ticcenter + $ticstep*5)];
      }
      my $histoxtics = join(', ', map { "\"$_->[1]\" $_->[0]" } @histoxtics);
      my $fullhistoimgfn = File::Spec->catpath($outputvol, $outputdir, "$histoimg");
      my $histoxrangemin = -5.5;
      my $histoxrangemax = 5.5;
      my $histoyrangemax = 0;
      map { $histoyrangemax = $_->[2] if ($_->[2] > $histoyrangemax); } @$binref;
      if ($histoyrangemax > 350) {
	$histoyrangemax = 350; # don't let this get too big
      } else {
	$histoyrangemax = ''; # let gnuplot autoscale
      }
      open(GNUPLOT, ">$plotcmdsfile");
      print GNUPLOT <<EOM;
set terminal ${gnuplotimgtype} small ${gnuplotimgoptions}
set size .5,.6
set output '${fullhistoimgfn}.${gnuplotimgtype}'
set xlabel "$histoxlabel"
set ylabel "Number of points"
set title "$plottitle\\n(histogram)"
set xtics ($histoxtics)
EOM
      print GNUPLOT "plot [$histoxrangemin:$histoxrangemax] [0:$histoyrangemax] '$plothistostdfile' using 1:2 notitle with histeps\n";
      close GNUPLOT;
      system($proggnuplot, $plotcmdsfile);
      unlink $plotcmdsfile;
      unlink $plothistostdfile;
      system($progconvert, "${fullhistoimgfn}.${gnuplotimgtype}", $fullhistoimgfn);
      unlink "${fullhistoimgfn}.${gnuplotimgtype}";
    }
  }

  my $retstruct =
    {
     %$plothashref,
     'numfiles'       => $numfiles,
     'maxrow'         => $maxrow,
     'maxrowsref'     => [@maxrows],
     'datasum'        => $datasum,
     'datanum'        => $datanum,
     'datamin'        => $datamin,
     'datamax'        => $datamax,
     'dataxmax'       => $dataxmax,
     'datasumsref'    => [@datasums],
     'datanumsref'    => [@datanums],
     'dataminsref'    => [@datamins],
     'datamaxsref'    => [@datamaxs],
     'dataxmaxsref'   => [@dataxmaxs],
     'datamean'       => $datamean,
     'datameansref'   => [@datameans],
     'datastddev'     => $datastddev,
     'datastddevsref' => [@datastddevs],
     'imagesetsref'   => [@imagesets],
    };
  return $retstruct;
}

sub showplots {
  my $plotstructref = shift @_;

  my $outputfh      = $plotstructref->{'outputfh'};
  my $outputvol     = $plotstructref->{'outputvol'};
  my $outputdir     = $plotstructref->{'outputdir'};
  my $plotname      = $plotstructref->{'plotname'};
  my $dataref       = $plotstructref->{'dataref'};
  my $plotlabelsref = $plotstructref->{'plotlabelsref'};
  my $plottitle     = $plotstructref->{'plottitle'};
  my $normmethod    = $plotstructref->{'normmethod'};
  my $showdata      = $plotstructref->{'showdata'};
  my $metadataref   = $plotstructref->{'metadataref'};

  my $numfiles      = $plotstructref->{'numfiles'};
  my $maxrow        = $plotstructref->{'maxrow'};
  my $datamean      = $plotstructref->{'datamean'};
  my @datameans     = @{$plotstructref->{'datameansref'}};
  my $datastddev    = $plotstructref->{'datastddev'};
  my @datastddevs   = @{$plotstructref->{'datastddevsref'}};
  my @imagesets     = @{$plotstructref->{'imagesetsref'}};

  my $nosummarymeans = $plotstructref->{'nosummarymeans'};

  my $threshmininds1 = $plotstructref->{'threshmininds1'};
  my $threshmininds2 = $plotstructref->{'threshmininds2'};
  my $threshmaxinds1 = $plotstructref->{'threshmaxinds1'};
  my $threshmaxinds2 = $plotstructref->{'threshmaxinds2'};
  my $threshmin1     = $plotstructref->{'threshmin1'};
  my $threshmin2     = $plotstructref->{'threshmin2'};
  my $threshmax1     = $plotstructref->{'threshmax1'};
  my $threshmax2     = $plotstructref->{'threshmax2'};

  $showdata = 1 if !defined($showdata);
  $nosummarymeans = 0 if !defined($nosummarymeans);

  if (defined($threshmininds1) || defined($threshmaxinds1) ||
      defined($threshmininds2) || defined($threshmaxinds2) ||
      defined($threshmin1) || defined($threshmax1) ||
      defined($threshmin2) || defined($threshmax2)) {
    # if any threshold specified, use it
  } elsif (!defined($threshmininds1) && !defined($threshmaxinds1) &&
	   !defined($threshmininds2) && !defined($threshmaxinds2) &&
	   !defined($threshmin1) && !defined($threshmax1) &&
	   !defined($threshmin2) && !defined($threshmax2)) {
    # if no thresholds specified, create defaults
    $threshmininds1 = [ map { $datameans[$_] - ( 3 * $datastddevs[$_] ) } (0..$#$dataref) ];
    $threshmaxinds1 = [ map { $datameans[$_] + ( 3 * $datastddevs[$_] ) } (0..$#$dataref) ];
    $threshmininds2 = [ map { $datameans[$_] - ( 4 * $datastddevs[$_] ) } (0..$#$dataref) ];
    $threshmaxinds2 = [ map { $datameans[$_] + ( 4 * $datastddevs[$_] ) } (0..$#$dataref) ];
    $threshmin1 = $datamean - ( 3 * $datastddev );
    $threshmax1 = $datamean + ( 3 * $datastddev );
    $threshmin2 = $datamean - ( 4 * $datastddev );
    $threshmax2 = $datamean + ( 4 * $datastddev );
  }
  my $datamin = undef;
  my $datamax = undef;
  map { map { if (!defined($datamin) || $_ < $datamin) { $datamin = $_ } } @{$_->[1]} } @$dataref;
  map { map { if (!defined($datamax) || $_ > $datamax) { $datamax = $_ } } @{$_->[1]} } @$dataref;
  $threshmininds1 = [($datamin) x scalar(@$dataref)] if !defined($threshmininds1);
  $threshmininds2 = [($datamin) x scalar(@$dataref)] if !defined($threshmininds2);
  $threshmaxinds1 = [($datamax) x scalar(@$dataref)] if !defined($threshmaxinds1);
  $threshmaxinds2 = [($datamax) x scalar(@$dataref)] if !defined($threshmaxinds2);
  $threshmin1 = $datamin if !defined($threshmin1);
  $threshmin2 = $datamin if !defined($threshmin2);
  $threshmax1 = $datamax if !defined($threshmax1);
  $threshmax2 = $datamax if !defined($threshmax2);

  # create HTML
  # create table rows
  my $datafn = "qa_data_${plotname}.txt";
  my $fulldatafn = File::Spec->catpath($outputvol, $outputdir, "$datafn");
  open(DATAFH, ">$fulldatafn") ||
    die "Cannot open output file $fulldatafn for writing\n";
  my @htmldataarray = ();
  push @htmldataarray,
    "<tr><td>VOLNUM</td><td style=\"border:2px solid gray\">" . join("</td><td style=\"border:2px solid gray\">", @$plotlabelsref) . "</td></tr>";
  if (defined($plotstructref->{'threshmin1'}) ||
      defined($plotstructref->{'threshmax1'})) {
    print DATAFH "# Overall Threshold 1: [ $threshmin1 $threshmax1 ]\n";
  }
  if (defined($plotstructref->{'threshmin2'}) ||
      defined($plotstructref->{'threshmax2'})) {
    print DATAFH "# Overall Threshold 2: [ $threshmin2 $threshmax2 ]\n";
  }
  if (defined($plotstructref->{'threshmininds1'}) ||
      defined($plotstructref->{'threshmaxinds1'})) {
    print DATAFH "# Individual Thresholds 1:\n";
    print DATAFH map { my $a = $plotlabelsref->[$_]; $a =~ s/\s/_/g; print "#\t$a\t[ $threshmininds1->[$_] $threshmaxinds1->[$_] ]\n" } (0..$#$plotlabelsref);
  }
  if (defined($plotstructref->{'threshmininds2'}) ||
      defined($plotstructref->{'threshmaxinds2'})) {
    print DATAFH "# Individual Thresholds 2:\n";
    print DATAFH map { my $a = $plotlabelsref->[$_]; $a =~ s/\s/_/g; print "#\t$a\t[ $threshmininds2->[$_] $threshmaxinds2->[$_] ]\n" } (0..$#$plotlabelsref);
  }
  print DATAFH "VOLNUM\t", join("\t", map { my $a = $_; $a =~ s/\s/_/g; $a } @$plotlabelsref), "\n";
  for my $rownum (0..$maxrow) { # skip header row
    my @htmlfields = ();
    my @textfields = ();
    push @htmlfields, "<td>$rownum</td>";
    push @textfields, $rownum;
    for my $filenum (0..$#$dataref) {
      my $dataarray = $dataref->[$filenum]->[1];
      my $textval = undef;
      my $htmlval = undef;
      if ($#$dataarray >= $rownum) {
	$textval = $dataarray->[$rownum];
	$htmlval = $dataarray->[$rownum];
	if (defined($htmlval)) {
	  if ($htmlval < $threshmin2 || $htmlval > $threshmax2) {
	    $htmlval = "<td style=\"background-color: #ee0000\">$htmlval</td>";
	  } elsif ($htmlval < $threshmin1 || $htmlval > $threshmax1) {
	    $htmlval = "<td style=\"background-color: #ff8800\">$htmlval</td>";
	  } elsif ($htmlval < $threshmininds2->[$filenum] || $htmlval > $threshmaxinds2->[$filenum]) {
	    $htmlval = "<td style=\"background-color: #ee4444\">$htmlval</td>";
	  } elsif ($htmlval < $threshmininds1->[$filenum] || $htmlval > $threshmaxinds1->[$filenum]) {
	    $htmlval = "<td style=\"background-color: #ffdd44\">$htmlval</td>";
	  } else {
	    $htmlval = "<td>$htmlval</td>";
	  }
	}
      } else {
	$textval = '';
	$htmlval = '<td></td>';
      }
      push @htmlfields, $htmlval;
      push @textfields, $textval;
    }
    push @htmldataarray,
      "<tr>" . join('', @htmlfields) . "</tr>";
    print DATAFH join("\t", @textfields), "\n";
  }
  close DATAFH;

  # create summary
  my @htmlsummaryarray = ();
  push @htmlsummaryarray, "<tr><td colspan=\"2\">$plottitle</td>";
  for my $filenum (0..$#$dataref) {
    push @htmlsummaryarray,
      "<td class=\"header\">" . $plotlabelsref->[$filenum] . "</td>";
  }
  push @htmlsummaryarray, "</tr>";
  if (!$nosummarymeans) {
    push @htmlsummaryarray, "<tr><td rowspan=\"2\">Mean:</td><td>(absolute)";
    for my $filenum (0..$#$dataref) {
      push @htmlsummaryarray,
	"<td>" . sprintf("%g", $datameans[$filenum]) . "</td>";
    }
    push @htmlsummaryarray, "</tr>";
    push @htmlsummaryarray, "<tr><td>(relative)</td>";
    for my $filenum (0..$#$dataref) {
      push @htmlsummaryarray,
	"<td>" . sprintf("%g", $datameans[$filenum] / no_zero($datamean)) . "</td>";
    }
    push @htmlsummaryarray, "</tr>";
  }
  push @htmlsummaryarray, "<tr><td rowspan=\"2\">Show:</td><td>(individual)</td>";
  for my $filenum (0..$#$dataref) {
    my $offset = 2;
    if ($normmethod == 0) { $offset = 1 };
    push @htmlsummaryarray,
      "<td>" . showhide_checkbox(@{$imagesets[$filenum+$offset]}[1..2]) . "</td>";
  }
  push @htmlsummaryarray, "</tr>";
  push @htmlsummaryarray, "<tr><td colspan=\"" . ($numfiles+1) . "\">";
  if ($normmethod == 0) {
    push @htmlsummaryarray,
      showhide_checkbox(@{$imagesets[0]}[1..2]) .
	"(overlay all) ";
  } elsif ($normmethod == 1) {
    push @htmlsummaryarray,
      showhide_checkbox(@{$imagesets[0]}[1..2]) .
	"(overlay individual plots) ";
    push @htmlsummaryarray,
      showhide_checkbox(@{$imagesets[1]}[1..2]) .
	"(overlay all relative to grand mean) ";
  } elsif($normmethod == 2) {
    push @htmlsummaryarray,
      showhide_checkbox(@{$imagesets[0]}[1..2]) .
	"(overlay individual plots) ";
    push @htmlsummaryarray,
      showhide_checkbox(@{$imagesets[1]}[1..2]) .
	"(overlay all relative to grand mean == 0) ";
  }
  push @htmlsummaryarray, "</td>";

  # put it all together
  # summary first
  my $datarows = join("\n", @htmldataarray);
  my $htmlsummary = join("\n", @htmlsummaryarray);
  my $tableid = "qa_data_${plotname}";
  my $buttons = showhide($tableid, 'Show data', 'Hide data', 0);
  print $outputfh <<EOM;
<table id="table_${plotname}_summary" class=\"striped\" width="100%">
$htmlsummary
</table>
<script><!--
stripe('table_${plotname}_summary');
--></script>
EOM
  # now graphs
  print $outputfh "<table class=\"bordered\">\n";
  for my $imageset (@imagesets) {
    my ($name, $rowid, $cbval, @imagefiles) = @$imageset;
    my $style = '';
    if (!$cbval) { $style = "style=\"display:none\""; }
    print $outputfh "<tr id=\"$rowid\" $style>\n";
    map { print $outputfh "<td><img alt=\"$plottitle - $name\" src=\"$_\" /></td>\n" } @imagefiles;
    print $outputfh "</tr>\n";
  }
  print $outputfh "</table>\n";
  # now data
  if ($showdata) {
    print $outputfh <<EOM;
<p>$buttons (<a href="$datafn">tab-separated file</a>)</p>
<table class=\"striped\" width="100%" id="$tableid" style=\"display:none; border:2px solid gray\">
$datarows
</table>
<script><!--
stripe('$tableid');
--></script>
EOM
  }
}

1;
