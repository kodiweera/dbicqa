package BXHPerlUtils;

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin";
use File::Which;

use XML::SAX;
use XML::SAX::PurePerl;

use BXHPerlUtils::XMLMetadata;
use BXHPerlUtils::XMLMetadata::XCEDE2;

use Config;


BEGIN {
  use Exporter ();
  our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

  # if using RCS/CVS, this may be preferred
  $VERSION = sprintf "%d.%03d", q$Revision: 1.16 $ =~ /(\d+)/g;

  @ISA         = qw(Exporter);
  @EXPORT      = qw(&findexecutable &testrunexecutable &quotecmd &run_cmd &read_avwhd &get_avw_orient &write_avwhd &get_avwhd_dims &fix_tr &read_feat_mat &mat44_string &write_feat_mat &get_feat_mat_voxelsize &fix_feat_mat &mat44_mult &mat44_add &mat44_det &affmat44_inv &flirt_apply_transform &readxmlmetadata &find_any_analyze_format &create_new_refvol);

}
our @EXPORT_OK;


sub findexecutable {
  my ($execname) = @_;
  my $retval = undef;
  my ($progvol, $progdirs, $progfile) = File::Spec->splitpath($0);
  my @progdirs = File::Spec->splitdir($progdirs);
  my $exeext = '';
  foreach my $appenddir (undef, File::Spec->catdir("..", "utils")) {
    if (defined($appenddir)) {
      $retval = File::Spec->catpath($progvol, File::Spec->catdir(@progdirs, $appenddir), "$execname");
    } else {
      $retval = File::Spec->catpath($progvol, $progdirs, "$execname");
    }
    if ($Config{'osname'} eq 'MSWin32') {
      return $retval if (-e $retval && ! -d $retval);
    } else {
      return $retval if (-x $retval);
    }
    if ($Config{'osname'} eq 'MSWin32') {
      if (defined($appenddir)) {
	$retval = File::Spec->catpath($progvol, File::Spec->catdir(@progdirs, $appenddir), "${execname}.exe");
      } else {
	$retval = File::Spec->catpath($progvol, $progdirs, "${execname}.exe");
      }
      return $retval if (-e $retval && ! -d $retval);
    }
  }
  return which($execname); # from File::Which
}

sub testrunexecutable {
  my @execandargs = @_;
  if (scalar(@execandargs) == 0 || grep { !defined($_) } @execandargs) {
    return -1;
  }
  my $childpid = undef;
  if (($childpid = fork()) == 0) {
    #child
    if ($Config{'osname'} eq 'MSWin32') {
      open(STDOUT, '>', 'nul') || die "Error redirecting standard output to 'nul'\n";
      open(STDERR, '>', 'nul') || die "Error redirecting standard output to 'nul'\n";
    } else {
      open(STDOUT, '>', '/dev/null') || die "Error redirecting standard output to /dev/null\n";
      open(STDERR, '>', '/dev/null') || die "Error redirecting standard output to /dev/null\n";
    }
    close STDIN;
    exit(system(@execandargs));
  } elsif (defined($childpid)) {
    # parent
    wait();
  }
  my $retval = $?;
  return $retval;
}

sub quotecmd {
  my @cmd = @_;
  @cmd = map {
    my $quote = undef;
    my $altquote = undef;
    if (/'/) { #'
      $quote = '"';
      $altquote = "'";
    } elsif (/"/) { #"
      $quote = "'";
      $altquote = '"';
    } elsif (/[|&\$;()<>\\]|\s/) {
      $quote = "'";
      $altquote = '"';
    }
    $_ =~ s/\!/\\\!/g;
    if (defined($quote)) {
      s/$quote/$quote$altquote$quote$altquote$quote/g;
      "$quote$_$quote";
    } elsif (length($_) == 0) {
      "''";
    } else {
      $_;
    }
  } @cmd;
  return join(" ", @cmd);
}

sub run_cmd {
  my ($fhsref, @cmd) = @_;
  for my $fh (@$fhsref) {
    print $fh "Running: ", quotecmd(@cmd), "\n";
  }
  system(@cmd);
  if ($? == -1) {
    die "ERROR: failed to execute $cmd[0]: $!\n";
  } elsif ($? & 127) {
    die
      sprintf "ERROR: child $cmd[0] exited with signal %d, %s coredump\n",
	($? & 127),  ($? & 128) ? 'with' : 'without';
  } elsif (($? >> 8) != 0) {
    die "Error running $cmd[0].\n";
  }
  return 0;
}

sub get_avw_orient {
  my ($avwfile, $progavworient) = @_;
  local $/;
  open(FH, "$progavworient $avwfile |")
    || die "Error running avworient: $!\n";
  my $orient = <FH>;
  close(FH);
  $orient =~ s/^\s+//;
  $orient =~ s/\s+$//;
  return $orient;
}

sub read_avwhd {
  my ($avwfile, $progavwhd) = @_;
  $ENV{'FSLOUTPUTTYPE'} = 'NIFTI'; # it doesn't matter what this is
  local $/; # file slurp mode
  open(FH, "$progavwhd -x $avwfile |")
    || die "Error running avwhd: $!\n";
  my $hdrtxt = <FH>;
  close(FH);
  return $hdrtxt;
}

sub write_avwhd {
  my ($avwfile, $hdrtxt, $progavwcreatehd, $fsloutputtype) = @_;
  unlink($avwfile);
  $ENV{'FSLOUTPUTTYPE'} = $fsloutputtype;
  open(FH, "| $progavwcreatehd - $avwfile")
    || die "Error running avwcreatehd: $!\n";
  syswrite(FH, $hdrtxt);
  close(FH);
}

# return x/y/z/t dimsizes and spacing in mm/mm/mm/ms
sub get_avwhd_dims {
  my ($avwfile, $progavwhd) = @_;
  my $hdrtxt = read_avwhd($avwfile, $progavwhd);
  my ($xsize,) = ($hdrtxt =~ /  nx = '(.*)'/);
  my ($ysize,) = ($hdrtxt =~ /  ny = '(.*)'/);
  my ($zsize,) = ($hdrtxt =~ /  nz = '(.*)'/);
  my ($tsize,) = ($hdrtxt =~ /  nt = '(.*)'/);
  my ($xspacing,) = ($hdrtxt =~ /  dx = '(.*)'/);
  my ($yspacing,) = ($hdrtxt =~ /  dy = '(.*)'/);
  my ($zspacing,) = ($hdrtxt =~ /  dz = '(.*)'/);
  my ($tspacing,) = ($hdrtxt =~ /  dt = '(.*)'/);
  my ($xyz_units,) = ($hdrtxt =~ /  xyz_units = '(.*)'/);
  my ($time_units,) = ($hdrtxt =~ /  time_units = '(.*)'/);
  my ($sto_xyz_matrix,) = ($hdrtxt =~ /  sto_xyz_matrix = '(.*)'/);
  map { defined($_) && ($_ eq '') && ($_ = undef) } ($xspacing, $yspacing, $zspacing, $tspacing, $xsize, $ysize, $zsize, $tsize, $xyz_units, $time_units, $sto_xyz_matrix);
  my ($Xr, $Yr, $Zr, $Or, $Xa, $Ya, $Za, $Oa, $Xs, $Ys, $Zs, $Os);
  if (defined($sto_xyz_matrix) && $sto_xyz_matrix ne '') {
    ($Xr, $Yr, $Zr, $Or,
     $Xa, $Ya, $Za, $Oa,
     $Xs, $Ys, $Zs, $Os,
     undef, undef, undef, undef) = split(/\s+/, $sto_xyz_matrix);
  }
  if (defined($xyz_units)) {
    my $factor = 1.0;
    if ($xyz_units == 2) { # NIFTI_UNITS_MM
      # what we wanted
    } elsif ($xyz_units == 1) { # NIFTI_UNITS_M
      $factor = 1000;
    } elsif ($xyz_units == 2) { # NIFTI_UNITS_MICRON
      $factor = 0.001;
    }
    $xspacing *= $factor;
    $yspacing *= $factor;
    $zspacing *= $factor;
  }
  if (defined($tspacing) && defined($time_units)) {
    my $factor = 1.0;
    if ($time_units == 16) { # NIFTI_UNITS_MSEC
      # what we wanted
    } elsif ($time_units == 8) { # NIFTI_UNITS_SEC
      $factor = 1000;
    } elsif ($time_units == 24) { # NIFTI_UNITS_USEC
      $factor = 0.0001;
    }
    $tspacing *= $factor;
  }
  if (defined($xspacing) && defined($yspacing) && defined($zspacing)) {
    my $msg = undef;
    if (defined($tspacing)) {
      $msg = "voxel spacing is (${xspacing}mm, ${yspacing}mm, ${zspacing}mm, ${tspacing}ms)\n";
    } else {
      $msg = "voxel spacing is (${xspacing}mm, ${yspacing}mm, ${zspacing}mm)\n";
    }
  }
  return ($xsize, $ysize, $zsize, $tsize, $xspacing, $yspacing, $zspacing, $tspacing, $Or, $Oa, $Os, 0);
}

sub fix_tr {
  my ($fhsref, $avwfile, $tspacing, $progavwhd, $progavwcreatehd, $fsloutputtype) = @_;
  map { print $_ "Fixing TR in header to ${tspacing}s...\n" } @$fhsref;
  my $hdrtxt = read_avwhd($avwfile, $progavwhd);
  $hdrtxt =~ s/  dt = .*/  dt = $tspacing/g;
  $hdrtxt =~ s/  time_units = .*/  time_units = '8'/g;
  $hdrtxt =~ s/  time_units_name = .*/  time_units_name = 's'/g;
  write_avwhd($avwfile, $hdrtxt, $progavwcreatehd, $fsloutputtype);
}

sub read_feat_mat {
  my ($matfile,) = @_;
  my @mat = ();
  open(FH, $matfile) || die "Error opening '$matfile': $!\n";
  while (<FH>) {
    s/^\s+//;
    s/\s+$//;
    my @row = split(/\s+/, $_);
    if (scalar(@row) != 4) {
      die "Following line in $matfile does not have four columns:\n$_\n";
    }
    push @mat, @row;
  }
  if (scalar(@mat) != 16) {
    die "$matfile is not a 4x4 matrix??\n";
  }
  return @mat;
}

sub mat44_string {
  my @mat = @_;
  my $output = '';
  $output .= join(' ', @mat[0..3]) . "\n";
  $output .= join(' ', @mat[4..7]) . "\n";
  $output .= join(' ', @mat[8..11]) . "\n";
  $output .= join(' ', @mat[12..15]) . "\n";
  return $output;
}

sub write_feat_mat {
  my ($fhsref,$matfile,@mat) = @_;
  my $output = mat44_string(@mat);
  for my $fh (@$fhsref) {
    print $fh "Writing matrix to $matfile:\n";
    print $fh $output;
  }
  open(FH, '>', $matfile) || die "Error opening '$matfile' for writing: $!\n";
  print FH $output;
  close FH;
}

sub get_feat_mat_voxelsize {
  my ($fhsref,@mat) = @_;
  my $xspacing = sqrt($mat[0]*$mat[0] + $mat[4]*$mat[4] + $mat[8]*$mat[8]);
  my $yspacing = sqrt($mat[1]*$mat[1] + $mat[5]*$mat[5] + $mat[9]*$mat[9]);
  my $zspacing = sqrt($mat[2]*$mat[2] + $mat[6]*$mat[6] + $mat[10]*$mat[10]);
  my $msg = "voxel spacing is (${xspacing}mm, ${yspacing}mm, ${zspacing}mm)\n";
  for my $fh (@$fhsref) {
    print $fh $msg;
  }
  return ($xspacing, $yspacing, $zspacing);
}

# If using a different FOV in output ($outbase) than the original reference
# volume ($inbase), fix the last column of the matrix to compensate.
sub fix_feat_mat {
  my ($matref, $inbase, $outbase, $progavwhd) = @_;
  my @mat = @$matref;
  my ($inxsize, $inysize, $inzsize, undef,
      $inxspacing, $inyspacing, $inzspacing, undef,
      undef, undef, undef, undef) =
	get_avwhd_dims($inbase, $progavwhd);
  my ($outxsize, $outysize, $outzsize, undef,
      $outxspacing, $outyspacing, $outzspacing, undef,
      undef, undef, undef, undef) =
	get_avwhd_dims($outbase, $progavwhd);
  my $inxfov = $inxspacing * $inxsize;
  my $inyfov = $inyspacing * $inysize;
  my $inzfov = $inzspacing * $inzsize;
  my $outxfov = $outxspacing * $outxsize;
  my $outyfov = $outyspacing * $outysize;
  my $outzfov = $outzspacing * $outzsize;

  $mat[3] += ($outxfov - $inxfov) / 2.0;
  $mat[7] += ($outyfov - $inyfov) / 2.0;
  $mat[11] += ($outzfov - $inzfov) / 2.0;
  return @mat;
}

sub mat44_mult {
  my ($matl, $matr) = @_;
  my ($L11,$L12,$L13,$L14,
      $L21,$L22,$L23,$L24,
      $L31,$L32,$L33,$L34,
      $L41,$L42,$L43,$L44) = @$matl;
  my ($R11,$R12,$R13,$R14,
      $R21,$R22,$R23,$R24,
      $R31,$R32,$R33,$R34,
      $R41,$R42,$R43,$R44) = @$matr;

  return ($L11*$R11 + $L12*$R21 + $L13*$R31 + $L14*$R41,
	  $L11*$R12 + $L12*$R22 + $L13*$R32 + $L14*$R42,
	  $L11*$R13 + $L12*$R23 + $L13*$R33 + $L14*$R43,
	  $L11*$R14 + $L12*$R24 + $L13*$R34 + $L14*$R44,
	  $L21*$R11 + $L22*$R21 + $L23*$R31 + $L24*$R41,
	  $L21*$R12 + $L22*$R22 + $L23*$R32 + $L24*$R42,
	  $L21*$R13 + $L22*$R23 + $L23*$R33 + $L24*$R43,
	  $L21*$R14 + $L22*$R24 + $L23*$R34 + $L24*$R44,
	  $L31*$R11 + $L32*$R21 + $L33*$R31 + $L34*$R41,
	  $L31*$R12 + $L32*$R22 + $L33*$R32 + $L34*$R42,
	  $L31*$R13 + $L32*$R23 + $L33*$R33 + $L34*$R43,
	  $L31*$R14 + $L32*$R24 + $L33*$R34 + $L34*$R44,
	  $L41*$R11 + $L42*$R21 + $L43*$R31 + $L44*$R41,
	  $L41*$R12 + $L42*$R22 + $L43*$R32 + $L44*$R42,
	  $L41*$R13 + $L42*$R23 + $L43*$R33 + $L44*$R43,
	  $L41*$R14 + $L42*$R24 + $L43*$R34 + $L44*$R44);
}
sub mat44_add {
  my ($matl, $matr) = @_;
  return map { $matl->[$_] + $matr->[$_] } [0..$#$matl];
}
sub mat44_det {
  my ($matl,) = @_;
  my ($L11,$L12,$L13,$L14,
      $L21,$L22,$L23,$L24,
      $L31,$L32,$L33,$L34,
      $L41,$L42,$L43,$L44) = @$matl;
  return (0
	  + ($L11 * $L22 * $L33 * $L44)
	  + ($L12 * $L23 * $L34 * $L41)
	  + ($L13 * $L24 * $L31 * $L42)
	  + ($L14 * $L21 * $L32 * $L43)
	  - ($L14 * $L23 * $L32 * $L41)
	  - ($L13 * $L22 * $L31 * $L44)
	  - ($L12 * $L21 * $L34 * $L43)
	  - ($L11 * $L24 * $L33 * $L42));
}
sub affmat44_inv {
  my ($matref,) = @_;
  # since the matrix is affine, we can determine the inverse
  # of the upper-left 3x3 and derive the rest:
  # T = [M L
  #      0 1]
  # M=3x3 rotation/scaling, L=3x1 translation, 0=1x3 zero, 1=1x1 one
  # Ti = [Mi -Mi*L
  #       0   1   ]
  # M =
  # [ M11 M12 M13 ]
  # [ M21 M22 M23 ]
  # [ M31 M32 M33 ]
  # L =
  # [ L1 ]
  # [ L2 ]
  # [ L3 ]
  my ($M11,$M12,$M13,$M21,$M22,$M23,$M31,$M32,$M33) =
    @{$matref}[0,1,2,4,5,6,8,9,10];
  my ($L1,$L2,$L3) = @{$matref}[3,7,11];
  # cofactors
  my $C11 =  1 * ($M22*$M33 - $M23*$M32);
  my $C12 = -1 * ($M21*$M33 - $M23*$M31);
  my $C13 =  1 * ($M21*$M32 - $M22*$M31);
  my $C21 = -1 * ($M12*$M33 - $M13*$M32);
  my $C22 =  1 * ($M11*$M33 - $M13*$M31);
  my $C23 = -1 * ($M11*$M32 - $M12*$M31);
  my $C31 =  1 * ($M12*$M23 - $M13*$M22);
  my $C32 = -1 * ($M11*$M23 - $M13*$M21);
  my $C33 =  1 * ($M11*$M22 - $M12*$M21);
  # adjoint is the transpose of the cofactors
  my @adj =
    ($C11,$C21,$C31,$C12,$C22,$C32,$C13,$C23,$C33);
  # determinant
  my $det = $M11*$C11 + $M12*$C12 + $M13*$C13;
  # inverse = (1/det)*adj
  my ($Mi11,$Mi12,$Mi13,$Mi21,$Mi22,$Mi23,$Mi31,$Mi32,$Mi33) =
    map { $_ / $det } @adj;
  # calc -Mi*L
  my $Li1 = -1 * ($Mi11*$L1 + $Mi12*$L2 + $Mi13*$L3);
  my $Li2 = -1 * ($Mi21*$L1 + $Mi22*$L2 + $Mi23*$L3);
  my $Li3 = -1 * ($Mi31*$L1 + $Mi32*$L2 + $Mi33*$L3);

  return ($Mi11,$Mi12,$Mi13,$Li1,
	  $Mi21,$Mi22,$Mi23,$Li2,
	  $Mi31,$Mi32,$Mi33,$Li3,
	  0,0,0,1);
}

# This function is used to apply an affine transformation (given by $mat)
# using flirt.  The matrix can be specified either as a file (send a string
# pathname in $mat), or as a 16-element array (send a reference to the array
# in $mat).  $ref is a path to the reference volume used to grab bounding
# box dimensions and voxel spacing only.  If $reforig is defined, this
# indicates that $reforig should be used to grab both orientation
# information and field of view information, otherwise only $ref is used.
# If $reforig is present, this function will fix the matrix so
# that the center of the old image remains the center of the new image.
# This function assumes that the input matrix is already adjusted to account
# for FSL's flipping of data that is considered in "neurological" orientation.
# The matrix eventually used (adjusted for differing FOV's) is written to
# "${outmatbase}.mat".
# If $outputprefix is defined, it is used as a prefix for all temporary files,
# otherwise it is assumed to be '' (i.e. write into the current directory).
# If $datatype is defined, it is used as the argument to flirt's -datatype
# option.
# Output is written to "${outputbase}.nii.gz" with a BXH header
# "${outputbase}.bxh"  The function returns a reference to the (unflipped)
# fixed matrix.
sub flirt_apply_transform {
  my ($logfhs, $input, $outputbase, $reforig, $ref, $mat, $outmatbase, $tmpfileprefix, $datatype, $progflirt, $progavwhd, $progavwcreatehd, $progavwswapdim, $progavworient, $proganalyze2bxh) = @_;

  my ($obvol, $obdirs, $obfile) = File::Spec->splitpath($outputbase);
  if (!defined($tmpfileprefix)) {
    $tmpfileprefix = File::Spec->catpath($obvol, $obdirs, "tmp${$}");
  }

  my @tempfiles = ();

  if (defined($reforig) && $reforig ne $ref) {
    # we need to create a new reference volume that has the orientation
    # information from the original reference volume and the resolution
    # information from the new reference volume.
    my $msg = "Creating new refvol from template '$reforig' and resolution from '$ref'\n";
    map { print $_ $msg } @$logfhs;
    my $tmprefvolbase = "${tmpfileprefix}_tmprefvol";
    my $newreffile = create_new_refvol($tmprefvolbase, $reforig, $ref, $progavwhd, $progavwcreatehd);
    push @tempfiles, $newreffile;
    $ref = $newreffile;
  }

  my $outputbxh = "${outputbase}.bxh";
  my $outputout = "${outputbase}.nii.gz";

  my (undef, undef, undef, undef,
      undef, undef, undef, $tspacing,
      undef, undef, undef, undef) =
	get_avwhd_dims($input, $progavwhd);
  if (defined($tspacing)) {
    $tspacing /= 1000.0;		# convert to seconds
  }

  my @mat = ();
  if (ref($mat)) {
    @mat = @$mat;
  } else {
    @mat = read_feat_mat($mat);
  }
  # fix matrix translations to account for differing FOVs
  # FLIRT .mat files assume transformations keep the first voxel fixed;
  # we want the center of the volume to be fixed, so we adjust fourth
  # column by half the FOV difference.
  # If we needed to adjust the matrix for flipping, write it to a
  # separate file.
  if (defined($reforig) && $ref ne $reforig) {
    @mat = fix_feat_mat(\@mat, $reforig, $ref, $progavwhd);
  }
  my $tmpmatfile = undef;
  my $initmatfile = undef;
  if (defined($outmatbase)) {
    $initmatfile = "${outmatbase}.mat";
  } else {
    $tmpmatfile = "${tmpfileprefix}_tmpmat.mat";
    $initmatfile = $tmpmatfile;
    push @tempfiles, $tmpmatfile;
  }
  write_feat_mat($logfhs, $initmatfile, @mat);

  $ENV{'FSLOUTPUTTYPE'} = 'NIFTI_GZ';
  {
    my @cmd = ();
    push @cmd, $progflirt;
    push @cmd, '-datatype', $datatype if defined($datatype);
    push @cmd, '-ref', $ref;
    push @cmd, '-in', $input;
    push @cmd, '-out', $outputbase;
    push @cmd, '-applyxfm';
    push @cmd, '-init', $initmatfile;
    run_cmd($logfhs, @cmd);
  }
  if (defined($tspacing)) {
    fix_tr($logfhs, $outputbase, $tspacing, $progavwhd, $progavwcreatehd, 'NIFTI_GZ');
  }
  {
    unlink $outputbxh;
    my @cmd = ();
    push @cmd, $proganalyze2bxh;
    push @cmd, $outputout;
    push @cmd, $outputbxh;
    run_cmd($logfhs, @cmd);
  }

  unlink @tempfiles;

  return [@mat];
}

sub readxmlmetadata {
  my $inputfile = shift @_;
  # define XMLMetadata inline
  my $dataref = BXHPerlUtils::XMLMetadata->new();
  my $parser = XML::SAX::ParserFactory->parser(Handler=>$dataref);
  eval { $parser->parse_uri($inputfile) };
  if( $@ ) {
    die "Error parsing (non-XML?) file ${inputfile}\n"
  }
  if (!exists($dataref->{'dims'})) {
    $dataref = BXHPerlUtils::XMLMetadata::XCEDE2->new();
    $parser = XML::SAX::ParserFactory->parser(Handler=>$dataref);
    eval { $parser->parse_uri($inputfile) };
    if( $@ ) {
      die "Error parsing (non-XML?) file ${inputfile}\n"
    }
  }
  if (!exists($dataref->{'dims'})) {
    warn("Was not able to parse XML metadata out of $inputfile (may not be BXH, XCEDE or XCEDE-2)\n");
    return undef;
  }
  my ($xdimref, $ydimref, $zdimref) = map { $dataref->{'dims'}->{$_} } ('x', 'y', 'z');
  if (exists($dataref->{'dims'}->{'z-split2'})) {
    $zdimref = $dataref->{'dims'}->{'z-split2'};
  }
  if (defined($xdimref) && defined($ydimref) && defined($zdimref)) {
    my @xdir = @{$xdimref->{'direction'}};
    my @ydir = @{$ydimref->{'direction'}};
    my @zdir = @{$zdimref->{'direction'}};
    my ($Xr, $Xa, $Xs) = @xdir;
    my ($Yr, $Ya, $Ys) = @ydir;
    my ($Zr, $Za, $Zs) = @zdir;
    my ($aXr, $aXa, $aXs) = map { abs($_) } @xdir;
    my ($aYr, $aYa, $aYs) = map { abs($_) } @ydir;
    my ($aZr, $aZa, $aZs) = map { abs($_) } @zdir;
    my ($rdimref, $adimref, $sdimref);
    if ($aXr > $aYr && $aXr > $aZr) {
      # X is R/L
      $rdimref = $xdimref;
      if ($aYa > $aXa && $aYa > $aZa) {
	# Y is A/P, Z is S/I
	$adimref = $ydimref;
	$sdimref = $zdimref;
      } else {
	# Y is S/I, Z is A/P
	$sdimref = $ydimref;
	$adimref = $zdimref;
      }
    } elsif ($aYr > $aXr && $aYr > $aZr) {
      # Y is R/L
      $rdimref = $ydimref;
      if ($aXa > $aYa && $aXa > $aZa) {
	# X is A/P, Z is S/I
	$adimref = $xdimref;
	$sdimref = $zdimref;
      } else {
	# X is S/I, Z is A/P
	$sdimref = $xdimref;
	$adimref = $zdimref;
      }
    } else {
      # Z is R/L
      $rdimref = $zdimref;
      if ($aXa > $aYa && $aXa > $aZa) {
	# X is A/P, Y is S/I
	$adimref = $xdimref;
	$sdimref = $ydimref;
      } else {
	# X is S/I, Y is A/P
	$sdimref = $xdimref;
	$adimref = $ydimref;
      }
    }
    $dataref->{'rasdims'}->{'r'} = $rdimref;
    $dataref->{'rasdims'}->{'a'} = $adimref;
    $dataref->{'rasdims'}->{'s'} = $sdimref;
    my $xspacing = $xdimref->{'spacing'};
    my $yspacing = $ydimref->{'spacing'};
    my $zspacing = $zdimref->{'spacing'};
    my $xsize = $xdimref->{'size'};
    my $ysize = $ydimref->{'size'};
    my $zsize = $zdimref->{'size'};
    if ($zdimref->{'type'} =~ /^z-split/) {
      if ($zdimref->{'outputselect'}) {
	my $os = $zdimref->{'outputselect'};
	$os =~ s/^\s+//;
	$os =~ s/\s+$//;
	my @oselems = split(/\s+/, $os);
	$zsize = scalar(@oselems);
      } else {
	my @zsplitkeys = grep { /^z-split/ } %{$dataref->{'dims'}};
	$zsize = 1;
	for my $zsplitkey (@zsplitkeys) {
	  $zsize *= $dataref->{'dims'}->{$zsplitkey}->{'size'};
	}
      }
      $dataref->{'dims'}->{'z'} = $zdimref;
      $dataref->{'dims'}->{'z'}->{'size'} = $zsize;
    }
    my ($rstart, $astart, $sstart) =
      ($rdimref->{'origin'}, $adimref->{'origin'}, $sdimref->{'origin'});
    # move to corner of bounding box
    $rstart -= 0.5 * ($xspacing*$Xr + $yspacing*$Yr + $zspacing*$Zr);
    $astart -= 0.5 * ($xspacing*$Xa + $yspacing*$Ya + $zspacing*$Za);
    $sstart -= 0.5 * ($xspacing*$Xs + $yspacing*$Ys + $zspacing*$Zs);
    # find end bound in Z direction
    my ($rendz, $aendz, $sendz) = ($rstart, $astart, $sstart);
    $rendz += $zsize*$zspacing*$Zr;
    $aendz += $zsize*$zspacing*$Za;
    $sendz += $zsize*$zspacing*$Zs;
    $rdimref->{'startlabel'} = (($rstart > 0) ? 'R ' : 'L ') . sprintf("%g",abs($rstart));
    $adimref->{'startlabel'} = (($astart > 0) ? 'A ' : 'P ') . sprintf("%g",abs($astart));
    $sdimref->{'startlabel'} = (($sstart > 0) ? 'S ' : 'I ') . sprintf("%g",abs($sstart));
    $rdimref->{'endlabelz'} = (($rendz > 0) ? 'R ' : 'L ') . sprintf("%g",abs($rendz));
    $adimref->{'endlabelz'} = (($aendz > 0) ? 'A ' : 'P ') . sprintf("%g",abs($aendz));
    $sdimref->{'endlabelz'} = (($sendz > 0) ? 'S ' : 'I ') . sprintf("%g",abs($sendz));
  }
  return $dataref;
}

sub find_any_analyze_format {
  my ($basepath,$okifnotfound) = @_;
  my @datafiles = grep { -r $_ } map { "${basepath}.${_}" } ('nii', 'nii.gz', 'hdr');
  my $numdatafiles = scalar(@datafiles);
  if ($numdatafiles < 1) {
    if ($okifnotfound) {
      return undef;
    } else {
      die "Can't find ${basepath}.nii (or .nii.gz or .hdr)!\n";
    }
  }
  return $datafiles[0];
}

# create a new reference volume (just the header) from a "template" volume,
# which is used to grab most fields, and a "dimension" volume, from which
# is extracted the dimension sizes and spacing.
sub create_new_refvol {
  my ($outfilebase, $templatebase, $dimensionsbase, $progavwhd, $progavwcreatehd) = @_;
  $ENV{'FSLOUTPUTTYPE'} = 'NIFTI';
  my $outfilename = "${outfilebase}.nii";
  my $templatetxt = read_avwhd($templatebase, $progavwhd);
  my $dimensionstxt = read_avwhd($dimensionsbase, $progavwhd);
  my ($nx,) = ($dimensionstxt =~ /  nx = '(.*)'/);
  my ($ny,) = ($dimensionstxt =~ /  ny = '(.*)'/);
  my ($nz,) = ($dimensionstxt =~ /  nz = '(.*)'/);
  my ($dx,) = ($dimensionstxt =~ /  dx = '(.*)'/);
  my ($dy,) = ($dimensionstxt =~ /  dy = '(.*)'/);
  my ($dz,) = ($dimensionstxt =~ /  dz = '(.*)'/);
  # put new dimensionality and spacing values in template
  $templatetxt =~ s/  nx = .*/  nx = '$nx'/;
  $templatetxt =~ s/  ny = .*/  ny = '$ny'/;
  $templatetxt =~ s/  nz = .*/  nz = '$nz'/;
  $templatetxt =~ s/  dx = .*/  dx = '$dx'/;
  $templatetxt =~ s/  dy = .*/  dy = '$dy'/;
  $templatetxt =~ s/  dz = .*/  dz = '$dz'/;
  # fix sform (which incorporates the spacing)
  my ($sto_xyz_matrix,) = ($templatetxt =~ /  sto_xyz_matrix = '(.*)'/);
  if (defined($sto_xyz_matrix) && $sto_xyz_matrix ne '') {
    my ($Xr, $Yr, $Zr, $Or,
	$Xa, $Ya, $Za, $Oa,
	$Xs, $Ys, $Zs, $Os,
	undef, undef, undef, undef) = split(/\s+/, $sto_xyz_matrix);
    my $Xlen = sqrt($Xr*$Xr + $Xa*$Xa + $Xs*$Xs);
    my $Ylen = sqrt($Yr*$Yr + $Ya*$Ya + $Ys*$Ys);
    my $Zlen = sqrt($Zr*$Zr + $Za*$Za + $Zs*$Zs);
    map { $_ *= ($dx / $Xlen) } ($Xr, $Xa, $Xs);
    map { $_ *= ($dy / $Ylen) } ($Yr, $Ya, $Ys);
    map { $_ *= ($dz / $Zlen) } ($Zr, $Za, $Zs);
    $sto_xyz_matrix = "$Xr $Yr $Zr $Or $Xa $Ya $Za $Oa $Xs $Ys $Zs $Os 0 0 0 1";
    $templatetxt =~ s/  sto_xyz_matrix = .*/  sto_xyz_matrix = '$sto_xyz_matrix'/;
    $templatetxt =~ s/  sto_ijk_matrix = .*//;
  }
  write_avwhd($outfilename, $templatetxt, $progavwcreatehd, 'NIFTI');
  return $outfilename;
}


1;

# $Log: In-line log eliminated on transition to SVN; use svn log instead. $
# Revision 1.15  2009/04/03 00:53:33  gadde
# Use XML::SAX for a fast pure-perl XML reading solution
#
# Revision 1.14  2009/04/02 14:53:26  gadde
# Fix use of non-existent functions.
#
# Revision 1.13  2009/02/17 18:30:59  gadde
# XPath->evaluate returns ref to array when matching nodes.
#
# Revision 1.12  2008/12/08 16:55:40  gadde
# Don't forget to close a filehandle.
#
# Revision 1.11  2008/07/25 18:51:50  gadde
# Deal better with Siemens mosaic DICOM images.
#
