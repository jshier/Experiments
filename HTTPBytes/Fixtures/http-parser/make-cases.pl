#!/usr/bin/perl
# make-cases.pl TEST_C OUTPUT_FILE: nodejs/http-parser's test.c as the TSV HTTPBytes' conformance tests read
# (ConformanceCase in Tests/HTTP1Tests):
#
#   source  name  kind  verdict  input  [key=value]...
#
# source `requests` and `responses`: the `struct message` arrays, verdict accept (http-parser reads each in full), with
# `keepalive=` (should_keep_alive), `eof=` (message_complete_on_eof: the body ends with the connection), `body=HEX` (or
# `bodysize=` for the large bodies the file gives only a size for), `upgrade=HEX` (the bytes after the message an
# upgrade or CONNECT hands on), `url=HEX`, `status=`, `headers=` (num_headers), `version=MAJOR.MINOR`, `strict=0` for
# the messages under `#if !HTTP_PARSER_STRICT`, and `chunkedlength=1` for `allow_chunked_length`.
# source `simple`: the literal `test_simple`/`test_simple_type` calls in main(), verdict `reject` for an expected error
# (`error=` the HPE_ name) and `noerror` for HPE_OK (no error: complete or not).
use strict;
use warnings;

my ($input, $output) = @ARGV;
open(my $in, '<', $input) or die "make-cases: $input: $!";
my $text = do { local $/; <$in> };
open(my $out, '>', $output) or die "make-cases: $output: $!";
my $count = 0;
my %seen;

# A C string literal's contents as bytes: hexadecimal escapes are greedy (as in C), octal ones take up to three digits.
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
        my %simple = ('r' => "\r", 'n' => "\n", 't' => "\t", '\\' => '\\', '"' => '"', "'" => "'", 'a' => "\a", 'f' => "\f", 'v' => "\x0B");
        my $e = substr($rest, 0, 1);
        die "make-cases: unknown escape \\$e" unless exists $simple{$e};
        $bytes .= $simple{$e};
        $i += 2;
    }
    return $bytes;
}

# Concatenated string literals (with comments between them) as bytes, or undef if VALUE isn't string literals.
sub strings {
    my ($value) = @_;
    return undef unless $value =~ /^\s*"/;
    my $bytes = '';
    # String literals, separated by whitespace and comments (a `//` inside a literal is part of it).
    while ($value =~ /\G(?:\s+|\/\/[^\n]*|\/\*.*?\*\/)*"((?:[^"\\]|\\.)*)"/sgc) { $bytes .= unescape($1) }
    return $bytes;
}

# Splits an initializer's body into its top-level `.field= value` pairs.
sub fields {
    my ($body) = @_;
    my (%fields, $name, $value, $depth, $quoted);
    ($depth, $quoted, $value) = (0, 0, '');
    my $flush = sub { if (defined $name) { $value =~ s/^\s+|[\s,]+$//g; $fields{$name} = $value } };
    for (my $i = 0; $i < length $body; $i++) {
        my $c = substr($body, $i, 1);
        if ($quoted) {
            $value .= $c;
            if ($c eq '\\') { $value .= substr($body, ++$i, 1) }
            elsif ($c eq '"') { $quoted = 0 }
            next;
        }
        if ($c eq '/' && substr($body, $i, 2) eq '//') { my $end = index($body, "\n", $i); $i = $end < 0 ? length $body : $end; next }
        if ($c eq '"') { $quoted = 1; $value .= $c; next }
        if ($c eq '{') { $depth++ }
        if ($c eq '}') { $depth-- }
        if ($depth == 0 && $c eq '.' && substr($body, $i) =~ /^(\.(\w+)\s*=)/) {
            my ($field, $length) = ($2, length $1);
            if ($value =~ /(?:^|,)\s*$/) {
                $flush->();
                ($name, $value) = ($field, '');
                $i += $length - 1;
                next;
            }
        }
        $value .= $c;
    }
    $flush->();
    return %fields;
}

# The entries of `const struct message NAME[] = { … };`, each with whether it's inside `#if !HTTP_PARSER_STRICT`.
sub messages {
    my ($array) = @_;
    $text =~ /const struct message $array\[\]\s*=\s*\n(.*?)\n\};/s or die "make-cases: no $array array";
    my $body = $1;
    my @entries;
    my ($depth, $quoted, $start, $strict) = (0, 0, -1, 1);
    for (my $i = 0; $i < length $body; $i++) {
        my $c = substr($body, $i, 1);
        if ($quoted) { if ($c eq '\\') { $i++ } elsif ($c eq '"') { $quoted = 0 } next }
        if ($c eq '/' && substr($body, $i, 2) eq '//') { my $end = index($body, "\n", $i); $i = $end < 0 ? length $body : $end; next }
        if ($c eq '#' && substr($body, $i) =~ /^#if !HTTP_PARSER_STRICT/) { $strict = 0 }
        if ($c eq '#' && substr($body, $i) =~ /^#endif/) { $strict = 1 }
        if ($c eq '"') { $quoted = 1; next }
        if ($c eq '{') { $depth++; $start = $i + 1 if $depth == 2 }
        if ($c eq '}') { push @entries, [substr($body, $start, $i - $start), $strict] if $depth == 2; $depth-- }
    }
    return @entries;
}

for my $array ('requests', 'responses') {
    for my $entry (messages($array)) {
        my ($body, $strict) = @$entry;
        my %f = fields($body);
        my $raw = strings($f{raw} // '') // die "make-cases: no raw in $array";
        my $name = strings($f{name} // '""');
        $name =~ s/[\t\n\r]/ /g;
        # Names repeat (a strict and a lenient copy): number the later ones so each is a key of its own.
        $name .= " (" . $seen{"$array: $name"} . ")" if $seen{"$array: $name"}++;
        my @extras;
        push @extras, 'keepalive=' . ($f{should_keep_alive} =~ /TRUE|1/ ? 1 : 0) if defined $f{should_keep_alive};
        push @extras, 'eof=' . ($f{message_complete_on_eof} =~ /TRUE|1/ ? 1 : 0) if defined $f{message_complete_on_eof};
        if (defined $f{body_size}) { push @extras, "bodysize=$f{body_size}" }
        elsif (defined $f{body}) { my $b = strings($f{body}); push @extras, 'body=' . unpack('H*', $b) if defined $b }
        if (defined $f{upgrade}) { my $u = strings($f{upgrade}); push @extras, 'upgrade=' . unpack('H*', $u) if defined $u }
        if (defined $f{request_url}) { my $u = strings($f{request_url}); push @extras, 'url=' . unpack('H*', $u) if defined $u }
        push @extras, "status=$f{status_code}" if defined $f{status_code};
        push @extras, "headers=$f{num_headers}" if defined $f{num_headers};
        push @extras, "version=$f{http_major}.$f{http_minor}" if defined $f{http_major} && defined $f{http_minor};
        push @extras, "method=$1" if ($f{method} // '') =~ /HTTP_(\w+)/;
        push @extras, 'chunkedlength=1' if ($f{allow_chunked_length} // '') =~ /1|TRUE/;
        push @extras, 'strict=0' unless $strict;
        my $kind = ($f{type} // '') =~ /RESPONSE/ ? 'response' : 'request';
        print $out join("\t", $array, $name, $kind, 'accept', unpack('H*', $raw), @extras), "\n";
        $count++;
    }
}

# test_simple("…", HPE_X) and test_simple_type("…", HPE_X, HTTP_RESPONSE) with literal strings.
my ($main) = $text =~ /\nmain \(void\)\n\{(.*)\n\}/s or die "make-cases: no main";
my $index = 0;
while ($main =~ /\btest_simple(_type)?\(\s*((?:"(?:[^"\\]|\\.)*"\s*(?:\/\/[^\n]*\n\s*)?)+),\s*(HPE_\w+|0)\s*(?:,\s*(HTTP_\w+))?\s*\)/sg) {
    my ($literals, $error, $type) = ($2, $3, $4 // 'HTTP_REQUEST');
    my $raw = strings($literals);
    my $verdict = $error eq 'HPE_OK' || $error eq '0' ? 'noerror' : 'reject';
    my $kind = $type eq 'HTTP_RESPONSE' ? 'response' : 'request';
    $index++;
    print $out join("\t", 'simple', "#$index $error", $kind, $verdict, unpack('H*', $raw), "error=$error"), "\n";
    $count++;
}
close $out;
print STDERR "make-cases: $count cases\n";
