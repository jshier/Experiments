#!/usr/bin/perl
# make-cases.pl TEST_C OUTPUT_FILE: h2o/picohttpparser's test.c as the TSV HTTPBytes' conformance tests read
# (ConformanceCase in Tests/HTTP1Tests):
#
#   source  name  kind  verdict  input  [decoded=HEX]
#
# source request, response, headers: the PARSE(…) lines of test_request, test_response, and test_headers (whose input is
# a header block alone: kind `headers`), verdict from the expected result (0 accept, -1 reject, -2 partial).
# source chunked: the chunked-decoder tests, kind `chunked` (a chunked body), with `decoded=` the expected data. Cases
# run with consume_trailer 0 stop after the last chunk's line without reading a trailer section, so one that expects no
# trailer bytes left over gets the empty line that ends it; consume_trailer 1 cases are as written (-2: partial).
# test_chunked_failure: reject for -1, partial for -2.
use strict;
use warnings;

my ($input, $output) = @ARGV;
open(my $in, '<', $input) or die "make-cases: $input: $!";
my $text = do { local $/; <$in> };
open(my $out, '>', $output) or die "make-cases: $output: $!";
my $count = 0;
my %seen;

sub unescape {
    my ($literal) = @_;
    my $bytes = '';
    my $i = 0;
    while ($i < length $literal) {
        my $c = substr($literal, $i, 1);
        if ($c ne '\\') { $bytes .= $c; $i++; next }
        my $rest = substr($literal, $i + 1);
        if ($rest =~ /^x([0-9a-fA-F]+)/) { $bytes .= chr(hex($1) & 0xFF); $i += 2 + length $1; next }
        if ($rest =~ /^([0-7]{1,3})/) { $bytes .= chr(oct($1) & 0xFF); $i += 1 + length $1; next }
        my %simple = ('r' => "\r", 'n' => "\n", 't' => "\t", '\\' => '\\', '"' => '"', "'" => "'");
        my $e = substr($rest, 0, 1);
        die "make-cases: unknown escape \\$e" unless exists $simple{$e};
        $bytes .= $simple{$e};
        $i += 2;
    }
    return $bytes;
}

sub strings { my $bytes = ''; $bytes .= unescape($1) while $_[0] =~ /"((?:[^"\\]|\\.)*)"/sg; return $bytes }

# Bytes as a name: printable ASCII as is, the rest as \\xHH.
sub printable { join('', map { /[ -~]/ ? $_ : sprintf('\\x%02X', ord) } split //, $_[0]) }

sub emit {
    my ($source, $name, $kind, $verdict, $bytes, @extras) = @_;
    $name =~ s/[\t\n\r]/ /g;
    # Names repeat (the same comment for several lines): number the later ones.
    $name .= " (" . $seen{"$source: $name"} . ")" if $seen{"$source: $name"}++;
    print $out join("\t", $source, $name, $kind, $verdict, unpack('H*', $bytes), @extras), "\n";
    $count++;
}

my %verdicts = (0 => 'accept', -1 => 'reject', -2 => 'partial');
for my $function ('request', 'response', 'headers') {
    $text =~ /static void test_$function\(void\)\n\{(.*?)\n\}\n/s or die "make-cases: no test_$function";
    my $body = $1;
    while ($body =~ /\bPARSE\(\s*((?:"(?:[^"\\]|\\.)*"\s*)+),\s*(.*?),\s*(-?\d+),\s*"((?:[^"\\]|\\.)*)"\);/sg) {
        my ($literals, $expected, $comment) = ($1, $3, $4);
        emit($function, $comment, $function, $verdicts{$expected}, strings($literals));
    }
}

# chunked_test_runners[i](__LINE__, CONSUME_TRAILER, "ENCODED", "DECODED", EXPECTED); EXPECTED may be `sizeof("…") - 1`.
while ($text =~ /chunked_test_runners\[i\]\(__LINE__,\s*(\d),\s*((?:"(?:[^"\\]|\\.)*"\s*)+),\s*((?:"(?:[^"\\]|\\.)*"\s*)+),\s*(.*?)\);/sg) {
    # Copy the captures first: strings() matches again, which resets them.
    my ($consume, $encodedLiterals, $decodedLiterals, $expected) = ($1, $2, $3, $4);
    my ($encoded, $decoded) = (strings($encodedLiterals), strings($decodedLiterals));
    my $leftover = $expected;
    if ($expected =~ /sizeof\(((?:"(?:[^"\\]|\\.)*"\s*)+)\)\s*-\s*1/) { my $literal = $1; $leftover = length(strings($literal)) }
    my $verdict = 'accept';
    if ($consume == 0) { $encoded .= "\r\n" if $leftover == 0 }
    else { $verdict = $leftover == -2 ? 'partial' : 'accept' }
    emit('chunked', "consume_trailer=$consume " . printable($encoded),
         'chunked', $verdict, $encoded, 'decoded=' . unpack('H*', $decoded));
}
while ($text =~ /test_chunked_failure\(__LINE__,\s*((?:"(?:[^"\\]|\\.)*"\s*)+),\s*(-?\d+)\);/sg) {
    my ($literals, $expected) = ($1, $2);
    my $encoded = strings($literals);
    emit('chunked', 'failure ' . printable($encoded), 'chunked', $verdicts{$expected}, $encoded);
}
close $out;
print STDERR "make-cases: $count cases\n";
