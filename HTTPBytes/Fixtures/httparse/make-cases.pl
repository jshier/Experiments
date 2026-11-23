#!/usr/bin/perl
# make-cases.pl LIB_RS URI_RS OUTPUT_FILE: httparse's `req!` and `res!` tests (src/lib.rs) and its request-target tests
# (tests/uri.rs) as the TSV HTTPBytes' conformance tests read (ConformanceCase in Tests/HTTP1Tests):
#
#   source  name  kind  verdict  input  [path=HEX]  [length=N]
#
# source: lib.rs or uri.rs; kind: request or response; verdict: from the macro's expected status (none: Complete, so
# accept; Ok(Status::Partial): partial; Err(…): reject, with `error=` the variant); input: the byte string (or the
# `static` it names), hexadecimal; path: the first `assert_eq!(req.path.unwrap(), "…")` in the test's closure;
# length: a `Complete(N)` that isn't the whole input.
use strict;
use warnings;

my ($lib, $uri, $output) = @ARGV;
open(my $out, '>', $output) or die "make-cases: $output: $!";
my $count = 0;

# A Rust byte string's or string's contents (between the quotes) as bytes.
sub unescape {
    my ($text) = @_;
    my $bytes = '';
    my $i = 0;
    while ($i < length $text) {
        my $c = substr($text, $i, 1);
        if ($c ne '\\') { $bytes .= $c; $i++; next }
        my $e = substr($text, $i + 1, 1);
        if ($e eq "\n") {
            # A line continuation: the newline and the next line's leading whitespace go.
            $i += 2;
            $i++ while $i < length $text && substr($text, $i, 1) =~ /\s/;
        } elsif ($e eq 'x') {
            $bytes .= chr(hex(substr($text, $i + 2, 2)));
            $i += 4;
        } elsif ($e eq 'u') {
            substr($text, $i) =~ /^\\u\{([0-9a-fA-F]+)\}/ or die "make-cases: bad \\u escape";
            my $code = hex($1);
            $i += length("\\u{$1}");
            utf8::encode(my $encoded = chr($code));
            $bytes .= $encoded;
        } else {
            my %simple = ('r' => "\r", 'n' => "\n", 't' => "\t", '\\' => '\\', '"' => '"', "'" => "'", '0' => "\0");
            die "make-cases: unknown escape \\$e" unless exists $simple{$e};
            $bytes .= $simple{$e};
            $i += 2;
        }
    }
    return $bytes;
}

sub cases {
    my ($path, $source) = @_;
    open(my $in, '<', $path) or die "make-cases: $path: $!";
    my $text = do { local $/; <$in> };
    my %statics;
    while ($text =~ /static\s+(\w+)\s*:\s*&\[u8\]\s*=\s*b"((?:[^"\\]|\\.)*)"\s*;/sg) { $statics{$1} = unescape($2) }
    # Each invocation: `req! {` or `res! {`, comments, the test's name, the buffer, an optional status, then the closure.
    while ($text =~ /\b(req|res)!\s*\{((?:\s*\/\/[^\n]*\n)*)\s*(\w+)\s*,\s*(b"(?:[^"\\]|\\.)*"|\w+)\s*,\s*(?:(Ok\([^|]*?\)|Err\([^|]*?\))\s*,\s*)?\|\s*\w+\s*\|/sg) {
        my ($macro, $name, $buffer, $status) = ($1, $3, $4, $5 // '');
        next if $name =~ /^\$/;
        my $after = substr($text, pos($text), 2000);
        my $input;
        if ($buffer =~ /^b"(.*)"$/s) { $input = unescape($1) }
        else { $input = $statics{$buffer} // die "make-cases: unknown static $buffer" }
        my ($verdict, @extras) = ('accept');
        if ($status =~ /Partial/) { $verdict = 'partial' }
        elsif ($status =~ /^Err\(\s*(?:crate::)?Error::(\w+)/) { $verdict = 'reject'; push @extras, "error=$1" }
        elsif ($status =~ /Complete\((\d+)\)/ && $1 != length $input) { push @extras, "length=$1" }
        # The first path assertion in the closure (it ends at the next invocation).
        my ($closure) = $after =~ /^(.*?)(?:\b(?:req|res)!\s*\{|\z)/s;
        if ($closure =~ /assert_eq!\(\s*req\.path\.unwrap\(\)\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)/s) {
            push @extras, 'path=' . unpack('H*', unescape($1));
        }
        print $out join("\t", $source, $name, $macro eq 'req' ? 'request' : 'response', $verdict, unpack('H*', $input), @extras), "\n";
        $count++;
    }
}

cases($lib, 'lib.rs');
cases($uri, 'uri.rs');
close $out;
print STDERR "make-cases: $count cases\n";
