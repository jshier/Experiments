#!/usr/bin/perl
# to-tsv.pl CASES_BIN OUTPUT_FILE: cursed-http's extract.py records (name NUL source NUL verdict NUL, a little-endian
# 32-bit length, the bytes) as the TSV HTTPBytes' conformance tests read (ConformanceCase in Tests/HTTP1Tests):
#
#   source  name  kind  verdict  input
#
# source: llhttp, garden, pico, httparse (the suite, from extract.py's source, whose llhttp ones also name llhttp's test
# type: kept as `type=…` after the columns); kind: request (extract.py gathers requests only); verdict: accept, reject,
# partial, or empty (HTTP Garden's payloads, llhttp's lenient types); input: hexadecimal.
use strict;
use warnings;

my ($input, $output) = @ARGV;
open(my $in, '<:raw', $input) or die "to-tsv: $input: $!";
my $data = do { local $/; <$in> };
open(my $out, '>', $output) or die "to-tsv: $output: $!";
my ($offset, $count) = (0, 0);
my @gardenSections = ('server', 'transducer', 'bonus', 'bonus-bonus');
my ($gardenSection, $gardenNumber) = (0, 0);
while ($offset < length $data) {
    my @strings;
    for (1 .. 3) {
        my $end = index($data, "\0", $offset);
        die "to-tsv: truncated record at $offset" if $end < 0;
        push @strings, substr($data, $offset, $end - $offset);
        $offset = $end + 1;
    }
    my $length = unpack('V', substr($data, $offset, 4));
    my $bytes = substr($data, $offset + 4, $length);
    $offset += 4 + $length;
    my ($name, $source, $verdict) = @strings;
    my $type = '';
    if ($source =~ /^llhttp-(.*)$/) { ($source, $type) = ('llhttp', $1) }
    # extract.py looks for a "### Transducer" heading that TROPHIES.md doesn't have ("## Transducer Bugs"), so it names
    # every payload "server bug N", and the numbers restart in each section: name them by the section they're in, which
    # changes wherever the number doesn't go up (Server, Transducer, Bonus, Bonus Bonus), so each name is unique.
    if ($source eq 'garden' && $name =~ /^garden\/\w+ bug (\d+): (.*)$/s) {
        my ($number, $title) = ($1, $2);
        $gardenSection++ if $number <= $gardenNumber;
        $gardenNumber = $number;
        $name = "garden/$gardenSections[$gardenSection] bug $number: $title";
    }
    s/[\t\n\r]/ /g for $name;
    print $out join("\t", $source, $name, 'request', $verdict, unpack('H*', $bytes), ($type eq '' ? () : ("type=$type"))), "\n";
    $count++;
}
close $out;
print STDERR "to-tsv: $count cases\n";
