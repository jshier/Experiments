#!/usr/bin/perl
# Tools/probe compare's engine: the same rows of each probe's TSV from several result directories, side by side,
# with each later directory's ratio to the first. Run it through `Tools/probe compare`.
#
# A row is identified by its leading key columns (how many per file is in %KEYS below; 1 for files not listed),
# every other column is a metric. Output: probe, row (the keys joined with " / "), metric, one value per directory,
# then later/first for each later directory ("-" where a value is missing or not a number).
use strict; use warnings;
use File::Basename qw(basename);
use Getopt::Long qw(GetOptions);

my %KEYS = (
    'machine' => 1, 'insn' => 1, 'insn-clock' => 1,
    'mem-latency' => 1, 'mem-bandwidth' => 1, 'mem-threads' => 1,
    'checksums' => 1, 'lanes' => 4, 'segments' => 3,
);
my @ORDER = qw(machine insn insn-clock mem-latency mem-bandwidth mem-threads checksums lanes segments);

my ($probe_re, $metric_re, $spread, $min_change) = ('.', '.', 0, undef);
GetOptions('probe=s' => \$probe_re, 'metric=s' => \$metric_re, 'spread' => \$spread, 'min-change=f' => \$min_change)
    or exit 2;
my @dirs = @ARGV;
if (@dirs < 2) { print STDERR "usage: Tools/probe compare [--probe RE] [--metric RE] [--spread] [--min-change PCT] DIR_A DIR_B...\n"; exit 2; }
for (@dirs) { unless (-d $_) { print STDERR "error: no directory $_\n"; exit 2; } s{/+$}{}; }
my @names = map { basename($_) } @dirs;
my %seen; my $dup = grep { $seen{$_}++ } @names;
@names = @dirs if $dup;

# Every probe file in any of the directories, in the usual order, then others alphabetically.
my %files;
for my $dir (@dirs) { for (glob("$dir/*.tsv")) { $files{basename($_, '.tsv')} = 1; } }
my @probes = ((grep { $files{$_} } @ORDER), (sort grep { my $p = $_; !grep { $_ eq $p } @ORDER } keys %files));

sub numeric { defined $_[0] && $_[0] =~ /^-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/ }

print join("\t", 'probe', 'row', 'metric', @names, map { "$names[$_]/$names[0]" } 1 .. $#names), "\n";
for my $probe (@probes) {
    next unless $probe =~ /$probe_re/;
    my $keys = $KEYS{$probe} // 1;
    my (@rows, %row_seen, @metrics, %metric_seen, @data);
    for my $i (0 .. $#dirs) {
        my $path = "$dirs[$i]/$probe.tsv";
        next unless -f $path;
        open my $fh, '<', $path or die "error: $path: $!\n";
        my $header = <$fh>;
        next unless defined $header;
        chomp $header;
        my @columns = split /\t/, $header, -1;
        while (my $line = <$fh>) {
            chomp $line;
            next if $line eq '' || $line =~ /^#/;
            my @fields = split /\t/, $line, -1;
            my $row = join(' / ', @fields[0 .. $keys - 1]);
            push @rows, $row unless $row_seen{$row}++;
            for my $c ($keys .. $#columns) {
                my $metric = $columns[$c];
                next if !$spread && $metric =~ /spread/;
                next unless $metric =~ /$metric_re/;
                push @metrics, $metric unless $metric_seen{$metric}++;
                $data[$i]{$row}{$metric} = $fields[$c];
            }
        }
        close $fh;
    }
    for my $row (@rows) {
        for my $metric (@metrics) {
            my @values = map { $data[$_]{$row}{$metric} // '-' } 0 .. $#dirs;
            next if !grep { $_ ne '-' } @values;
            my @ratios;
            my $changed = 0;
            for my $i (1 .. $#dirs) {
                if (numeric($values[0]) && numeric($values[$i]) && $values[0] != 0) {
                    my $r = $values[$i] / $values[0];
                    push @ratios, sprintf('%.2f', $r);
                    $changed = 1 if defined $min_change && abs($r - 1) * 100 >= $min_change;
                } else {
                    push @ratios, '-';
                    $changed = 1 if defined $min_change && $values[0] ne $values[$i];
                }
            }
            next if defined $min_change && !$changed;
            print join("\t", $probe, $row, $metric, @values, @ratios), "\n";
        }
    }
}
