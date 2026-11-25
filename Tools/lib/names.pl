#!/usr/bin/perl
# names.pl — the function names Tools/loops and calls match against: `nm`'s text symbols (T, t) at addresses in
# sections holding code (not `__mh_execute_header`, at the start of __TEXT before any code), without the assembler's
# section markers (`ltmp0`, which alias a section's first function), sorted, each once. A name may hold spaces
# (Objective-C methods). Also warns, for a linked binary, when more than a quarter of its function starts have no
# symbol (stripped with `strip -x`: such a function reads as part of the one before it; an unstripped Swift binary has
# about 2% without one, outlined parts).
#
# usage: perl names.pl SYMBOLS CODE STARTS FILE-NAME CONSEQUENCE > NAMES
#   SYMBOLS  `nm` output; CODE, STARTS  lib/macho.pl's; CONSEQUENCE  the warning's end ("their code is read as …")
use strict;
use warnings;
no warnings 'portable';

my ($symbols, $code, $starts, $name, $consequence) = @ARGV;
my @ranges;
if (open my $c, '<', $code) {
    while (<$c>) { push @ranges, [hex $1, hex $2] if /^([0-9a-f]+) ([0-9a-f]+)$/ }
}
my (%named, %names);
open my $s, '<', $symbols or die "names.pl: $symbols: $!\n";
while (<$s>) {
    next unless /^([0-9a-f]+) [Tt] (.+)$/;
    my ($address, $symbol) = (hex $1, $2);
    next unless grep { $address >= $_->[0] && $address < $_->[1] } @ranges;
    $named{$address} = 1;
    $names{$symbol} = 1 unless $symbol =~ /^ltmp\d+$/;
}
print "$_\n" for sort keys %names;
if (open my $f, '<', $starts) {
    my ($n, $without) = (0, 0);
    while (<$f>) { next unless /^([0-9a-f]+)$/; $n++; $without++ unless $named{hex $1} }
    printf STDERR "warning: %d of %d function starts in %s have no symbol (stripped?): %s\n", $without, $n, $name, $consequence
        if $n && $without > $n / 4;
}
