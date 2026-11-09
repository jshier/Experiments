#!/usr/bin/perl
# Reads `objdump -d --no-show-raw-insn --symbolize-operands` output for one function on stdin and reports its
# loops: a branch to a label at or before the branch is a loop from the label to the branch.
#
# Environment: FUNCTION (name to print), FORMAT (text|tsv), BODY (1: print loop instructions),
# REQUIRE / FORBID (comma-separated mnemonics, with or without their numeric/lane suffix: `zip` matches
# `zip1.16b`, `bl` doesn't match `tbl` or `blr`; checked against the innermost loops).
# Exit status 1 if REQUIRE/FORBID are given and no innermost loop satisfies them.
use strict;
use warnings;

my (@insns, %label_at);
while (my $line = <STDIN>) {
    chomp $line;
    if ($line =~ /^<(L\d+)>:/) { $label_at{$1} = scalar @insns; next }
    next unless $line =~ /^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$/;
    my ($address, $mnemonic, $operands) = ($1, $2, $3);
    $operands =~ s/\s*;.*$//;
    push @insns, { address => $address, mnemonic => $mnemonic, operands => $operands };
}

# Loops: [start, end] index ranges.
my @loops;
for my $index (0 .. $#insns) {
    my $insn = $insns[$index];
    next unless $insn->{mnemonic} =~ /^(b|b\..+|cbz|cbnz|tbz|tbnz)$/;
    next unless $insn->{operands} =~ /<(L\d+)>/;
    my $start = $label_at{$1};
    push @loops, [$start, $index] if defined $start && $start <= $index;
}
@loops = sort { $a->[0] <=> $b->[0] || $b->[1] <=> $a->[1] } @loops;

sub contains { my ($outer, $inner) = @_; $outer != $inner && $outer->[0] <= $inner->[0] && $inner->[1] <= $outer->[1] }

my %require = map { $_ => 1 } grep { length } split /,/, ($ENV{REQUIRE} // '');
my %forbid = map { $_ => 1 } grep { length } split /,/, ($ENV{FORBID} // '');
my $checking = %require || %forbid;
my $satisfied = 0;
my $format = $ENV{FORMAT} // 'text';
my $function = $ENV{FUNCTION} // '?';

print "$function\n" if $format eq 'text';
print "  no loops\n" if $format eq 'text' && !@loops;

my $number = 0;
for my $loop (@loops) {
    my ($start, $end) = @$loop;
    my $depth = grep { contains($_, $loop) } @loops;
    my $innermost = !grep { contains($loop, $_) } @loops;
    my (%mix, $v128, $v64, $lane, $calls, $interleaved, $shuffles);
    $v128 = $v64 = $lane = $calls = $interleaved = $shuffles = 0;
    for my $insn (@insns[$start .. $end]) {
        my ($m, $o) = ($insn->{mnemonic}, $insn->{operands});
        $mix{$m}++;
        my $base = $m =~ s/\..*//r;
        # Vector width: Apple syntax puts the arrangement on the mnemonic (`add.16b`), LLVM's on the
        # registers (`v0.16b`); q registers in loads and stores are 128-bit.
        if ($m =~ /\.(16b|8h|4s|2d)$/ || $o =~ /\bv\d+\.(16b|8h|4s|2d)\b/ || ($base =~ /^(ld|st)/ && $o =~ /\bq\d+\b/)) { $v128++ }
        elsif ($m =~ /\.(8b|4h|2s|1d)$/ || $o =~ /\bv\d+\.(8b|4h|2s|1d)\b/) { $v64++ }
        # One lane to or from a general-purpose register: `mov.b v3[2], w12`, `ins`, `umov`, `smov`.
        $lane++ if $base =~ /^(mov|ins|umov|smov)$/ && $o =~ /\bv\d+(\.\w+)?\[\d+\]/ && $o =~ /\b[wx]\d+\b/;
        $calls++ if $base =~ /^(bl|blr)$/;
        $interleaved++ if $base =~ /^(ld[234]|st[234])$/;
        $shuffles++ if $base =~ /^(tbl|tbx|zip[12]|uzp[12]|trn[12]|ext)$/;
    }
    my $verdict = $v128 ? 'vector128' : $v64 ? 'vector64' : 'scalar';
    $verdict .= '+lane-moves' if $lane;
    $verdict .= '+calls' if $calls;
    my $count = $end - $start + 1;
    my $mix = join ', ', map { "$mix{$_} $_" } sort { $mix{$b} <=> $mix{$a} || $a cmp $b } keys %mix;
    my ($from, $to) = ($insns[$start]{address}, $insns[$end]{address});
    $number++;

    if ($innermost && $checking) {
        # An op names a mnemonic, optionally without its numeric or lane suffix: `zip` matches `zip1.16b`,
        # `tbl` matches `tbl.16b`, `ld3.16b` only itself, and `bl` matches `bl` but not `tbl` or `blr`.
        my @mnemonics = map { $_->{mnemonic} } @insns[$start .. $end];
        my $present = sub { my $op = shift; scalar grep { /^\Q$op\E(?:$|[.\d])/ } @mnemonics };
        my $ok = !grep { !$present->($_) } keys %require;
        $ok &&= !grep { $present->($_) } keys %forbid;
        $satisfied ||= $ok;
    }

    if ($format eq 'tsv') {
        print join("\t", $function, "loop$number", $from, $to, $count, $depth, $innermost ? 'innermost' : 'outer', $verdict, $mix), "\n";
    } else {
        printf "  loop %d  0x%s–0x%s  %d instructions  depth %d%s  %s\n    %s\n", $number, $from, $to, $count, $depth,
            $innermost ? ' (innermost)' : '', $verdict, $mix;
        if ($ENV{BODY}) { print "      $_->{address}: $_->{mnemonic}\t$_->{operands}\n" for @insns[$start .. $end] }
    }
}

if ($checking) {
    print STDERR ($satisfied ? "ok" : "FAIL"), ": $function: ",
        "require [", join(',', sort keys %require), "] forbid [", join(',', sort keys %forbid), "] in an innermost loop\n";
    exit($satisfied ? 0 : 1);
}
exit 0;
