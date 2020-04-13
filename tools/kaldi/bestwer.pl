#!/usr/bin/env perl

# Like best_wer.pl, but even better.

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);

BEGIN {
  # Fancy a sensible error if Path::Tiny is not found.
  unless (eval "use Path::Tiny; 1") {
    die "Path::Tiny is missing, install with:\n\n" .
        "sudo apt install libpath-tiny-perl\n\n"
  }
}

unless (@ARGV) {
  print STDERR "Usage: $0 {wer_file} ...\n\n"
      . "Print filename and best WER score line among all {wer_file}s.\n"
      . "Each {wer_file} is expected to be the output log of compute-wer.\n"
      . "The program is normally invoked with the shell-expanded argument\n"
      . "pointing to wer files in a decode directory: .../scoring/log/wer*\n";
  exit 1;
}

my $best_wer = 100.0;
my %best_files;  # Maps file_name => wer_line.

# Example file:
# -----8<-----
# compute-wer --text --mode=present ark:exp/online/original/decode_silw_0.0001/scoring/test_filt.txt ark,p:-
# ... Verbose log possible ...
# %WER 26.98 [ 699 / 2591, 118 ins, 106 del, 475 sub ]
# %SER 65.61 [ 227 / 346 ]
# Scored 346 sentences, 0 not present in hyp.
# -----8<-----

foreach my $file (@ARGV) {
  # count => -10 takes at most 10 tail lines of the file.
  my @lines = eval { path($file)->lines( { chomp => 1, count => -10 } ) };
  if ($@) {
    print STDERR "$0: cannot open file '$file'.\n";
    next;
  }

  my ($werl) = (grep { /^%WER\s/ } @lines);
  unless ($werl) {
    print STDERR "$0: file '$file' does not have a %WER line.\n";
    next;
  }

  my ($xx, $w) = split(' ', $werl);
  unless (looks_like_number($w)) {
    print STDERR "$0: file '$file' has a %WER line '$werl', but $w is not a number.\n";
    next;
  }

  if ($w < $best_wer) {
    %best_files = ( $file => $werl );
    $best_wer = $w;
  } elsif ($w == $best_wer) {
    $best_files{$file} = $werl;
  }
}

unless (%best_files) {
  print STDERR "$0: error: no valid files processed.\n";
  exit 1;
}

foreach my $file (keys %best_files) {
  print "$best_files{$file} in $file\n";
}
