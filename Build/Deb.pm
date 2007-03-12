
package Build::Deb;

use strict;
use Digest::MD5;

my $have_zlib;
eval {
  require Compress::Zlib;
  $have_zlib = 1;
};

sub parse {
  my ($bconf, $fn) = @_;
  my $ret;
  my @control;
  if (ref($fn) eq 'ARRAY') {
    @control = @$fn;
  } else {
    local *F;
    if (!open(F, '<', $fn)) {
      $ret->{'error'} = "$fn: $!";
      return $ret;
    }
    @control = <F>;
    close F;
    chomp @control;
  }
  splice(@control, 0, 3) if @control > 3 && $control[0] =~ /^-----BEGIN/;
  my $name;
  my $version;
  my @deps;
  while (@control) {
    my $c = shift @control;
    last if $c eq '';   # new paragraph
    my ($tag, $data) = split(':', $c, 2);
    next unless defined $data;
    $tag = uc($tag);
    while (@control && $control[0] =~ /^\s/) {
      $data .= "\n".substr(shift @control, 1);
    }
    $data =~ s/^\s+//s;
    $data =~ s/\s+$//s;
    if ($tag eq 'VERSION') {
      $version = $data;
      $version =~ s/-[^-]+$//;
    } elsif ($tag eq 'SOURCE') {
      $name = $data;
    } elsif ($tag eq 'BUILD-DEPENDS') {
      my @d = split(/,\s*/, $data);
      s/\s.*// for @d;
      push @deps, @d;
    } elsif ($tag eq 'BUILD-CONFLICTS' || $tag eq 'BUILD-IGNORE') {
      my @d = split(/,\s*/, $data);
      s/\s.*// for @d;
      push @deps, map {"-$_"} @d;
    }
  }
  $ret->{'name'} = $name;
  $ret->{'version'} = $version;
  $ret->{'deps'} = \@deps;
  return $ret;
}

sub ungzip {
  my $data = shift;
  local (*TMP, *TMP2);
  open(TMP, "+>", undef) or die("could not open tmpfile\n");
  syswrite TMP, $data;
  sysseek(TMP, 0, 0);
  my $pid = open(TMP2, "-|");
  die("fork: $!\n") unless defined $pid;
  if (!$pid) {
    open(STDIN, "<&TMP");
    exec 'gunzip';
    die("gunzip: $!\n");
  }
  close(TMP);
  $data = '';
  1 while sysread(TMP2, $data, 1024, length($data)) > 0;
  close(TMP2) || die("gunzip error");
  return $data;
}

sub debq {
  my ($fn) = @_;

  local *DEBF;
  if (ref($fn) eq 'GLOB') {
      *DEBF = *$fn;
  } elsif (!open(DEBF, '<', $fn)) {
    warn("$fn: $!\n");
    return ();
  }
  my $data = '';
  sysread(DEBF, $data, 4096);
  if (length($data) < 8+60) {
    warn("$fn: not a debian package\n");
    close DEBF unless ref $fn;
    return ();
  }
  if (substr($data, 0, 8+16) ne "!<arch>\ndebian-binary   ") {
    close DEBF unless ref $fn;
    return ();
  }
  my $len = substr($data, 8+48, 10);
  $len += $len & 1;
  if (length($data) < 8+60+$len+60) {
    my $r = 8+60+$len+60 - length($data);
    $r -= length($data);
    if ((sysread(DEBF, $data, $r < 4096 ? 4096 : $r, length($data)) || 0) < $r) {
      warn("$fn: unexpected EOF\n");
      close DEBF unless ref $fn;
      return ();
    }
  }
  $data = substr($data, 8 + 60 + $len);
  if (substr($data, 0, 16) ne 'control.tar.gz  ') {
    warn("$fn: control.tar.gz is not second ar entry\n");
    close DEBF unless ref $fn;
    return ();
  }
  $len = substr($data, 48, 10);
  if (length($data) < 60+$len) {
    my $r = 60+$len - length($data);
    if ((sysread(DEBF, $data, $r, length($data)) || 0) < $r) {
      warn("$fn: unexpected EOF\n");
      close DEBF unless ref $fn;
      return ();
    }
  }
  close DEBF unless ref($fn);
  $data = substr($data, 60, $len);
  my $controlmd5 = Digest::MD5::md5_hex($data);	# our header signature
  if ($have_zlib) {
    $data = Compress::Zlib::memGunzip($data);
  } else {
    $data = ungzip($data);
  }
  if (!$data) {
    warn("$fn: corrupt control.tar.gz file\n");
    return ();
  }
  my $control;
  while (length($data) >= 512) {
    my $n = substr($data, 0, 100);
    $n =~ s/\0.*//s;
    my $len = oct('00'.substr($data, 124,12));
    my $blen = ($len + 1023) & ~511;
    if (length($data) < $blen) {
      warn("$fn: corrupt control.tar.gz file\n");
      return ();
    }
    if ($n eq './control') {
      $control = substr($data, 512, $len);
      last;
    }
    $data = substr($data, $blen);
  }
  my %res;
  my @control = split("\n", $control);
  while (@control) {
    my $c = shift @control;
    last if $c eq '';   # new paragraph
    my ($tag, $data) = split(':', $c, 2);
    next unless defined $data;
    $tag = uc($tag);
    while (@control && $control[0] =~ /^\s/) {
      $data .= "\n".substr(shift @control, 1);
    }
    $data =~ s/^\s+//s;
    $data =~ s/\s+$//s;
    $res{$tag} = $data;
  }
  $res{'CONTROL_MD5'} = $controlmd5;
  return %res;
}

sub query {
  my ($handle, $withevra) = @_;

  my %res = debq($handle);
  return undef unless %res;
  my $name = $res{'PACKAGE'};
  my $src = $name;
  $src = $res{'SOURCE'} if $res{'SOURCE'};
  my @provides = split(',\s*', $res{'PROVIDES'} || '');
  push @provides, "$name = $res{'VERSION'}" unless grep {/^\Q$name\E(?: |$)/} @provides;
  my @depends = split(',\s*', $res{'DEPENDS'} || '');
  my @predepends = split(',\s*', $res{'PRE-DEPENDS'} || '');
  push @depends, @predepends;
  s/ \(([^\)]*)\)/ $1/g for @provides;
  s/ \(([^\)]*)\)/ $1/g for @depends;
  s/>>/>/g for @provides;
  s/<</</g for @provides;
  s/>>/>/g for @depends;
  s/<</</g for @depends;
  my $data = {
    name => $name,
    hdrmd5 => $res{'CONTROL_MD5'},
    provides => \@provides,
    requires => \@depends,
  };
  $data->{'source'} = $src if $src ne '';
  if ($withevra) {
    if ($res{'VERSION'} =~ /^(.*)-(.*?)$/) {
      $data->{'version'} = $1;
      $data->{'release'} = $2;
    } else {
      $data->{'version'} = $res{'VERSION'};
    }
    $data->{'arch'} = $res{'ARCHITECTURE'};
  }
  return $data;
}

sub queryhdrmd5 {
  my ($bin) = @_; 

  local *F; 
  open(F, '<', $bin) || die("$bin: $!\n");
  my $data = ''; 
  sysread(F, $data, 4096);
  if (length($data) < 8+60) {
    warn("$bin: not a debian package\n");
    close F;
    return undef; 
  }   
  if (substr($data, 0, 8+16) ne "!<arch>\ndebian-binary   ") {
    warn("$bin: not a debian package\n");
    close F;
    return undef; 
  }   
  my $len = substr($data, 8+48, 10);
  $len += $len & 1;
  if (length($data) < 8+60+$len+60) {
    my $r = 8+60+$len+60 - length($data);
    $r -= length($data);
    if ((sysread(F, $data, $r < 4096 ? 4096 : $r, length($data)) || 0) < $r) {
      warn("$bin: unexpected EOF\n");
      close F;
      return undef; 
    }   
  }   
  $data = substr($data, 8 + 60 + $len);
  if (substr($data, 0, 16) ne 'control.tar.gz  ') {
    warn("$bin: control.tar.gz is not second ar entry\n");
    close F;
    return undef; 
  }   
  $len = substr($data, 48, 10);
  if (length($data) < 60+$len) {
    my $r = 60+$len - length($data);
    if ((sysread(F, $data, $r, length($data)) || 0) < $r) {
      warn("$bin: unexpected EOF\n");
      close F;
      return undef; 
    }   
  }   
  close F;
  $data = substr($data, 60, $len);
  return Digest::MD5::md5_hex($data);
}

1;
