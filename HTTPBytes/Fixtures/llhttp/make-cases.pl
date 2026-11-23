#!/usr/bin/perl
# make-cases.pl LLHTTP_TEST_DIR OUTPUT_FILE: llhttp's markdown tests (test/request/*.md, test/response/*.md) as one TSV
# line per case, for HTTPBytes' differential tests. Input bytes are made as llhttp's md-test.ts makes them: the block's
# trailing newline dropped, backslash-newline joined, newlines as CR LF, then \r \n \t \f \xHH and octal escapes. Cases
# whose input uses `${…}` (JavaScript) are skipped.
#
# Columns: file, title, type (llhttp's meta type: request, response, request-lenient-…), input (hex), and from the log of
# the first message: the offset of "headers complete" (or -1), the offset and reason of the first error (or -1 and ""),
# and whether the log reached "message complete" before an error (1 or 0).
use strict;
use warnings;

my ($dir, $output) = @ARGV;
open(my $out, '>', $output) or die "make-cases: $output: $!";
my $count = 0;
for my $kind ('request', 'response') {
    for my $path (sort glob("$dir/$kind/*.md")) {
        my ($file) = $path =~ m{([^/]+/[^/]+)\.md$};
        open(my $in, '<', $path) or die "make-cases: $path: $!";
        local $/;
        my $text = <$in>;
        # Each case: a meta comment, an ```http block, then a ```log block; its title is the nearest heading before it
        # (## or ###).
        # (Prose may sit between the two blocks: the http block ends at its own closing fence.)
        while ($text =~ /<!--\s*meta=(\{.*?\})\s*-->\s*```http\n(.*?)^```\s*$(?:(?!```).)*?```log\n(.*?)```/smg) {
            my ($meta, $input, $log) = ($1, $2, $3);
            my $before = substr($text, 0, $-[0]);
            my ($title) = $before =~ /.*^#{2,3}\s+([^\n]*)/ms;
            $title //= '';
            my ($type) = $meta =~ /"type"\s*:\s*"([^"]+)"/;
            next unless defined $type;
            next if $input =~ /\$\{/;
            $input =~ s/\n$//;
            $input =~ s/\\(\r\n|\r|\n)//g;
            $input =~ s/\r\n|\r|\n/\r\n/g;
            $input =~ s/\\r/\r/g;
            $input =~ s/\\n/\n/g;
            $input =~ s/\\t/\t/g;
            $input =~ s/\\f/\f/g;
            $input =~ s/\\x([0-9a-fA-F]+)/chr(hex($1))/ge;
            $input =~ s/\\([0-7]{1,3})/chr(oct($1))/ge;
            my ($headers, $errorOffset, $reason, $complete) = (-1, -1, '', 0);
            for my $line (split /\n/, $log) {
                if ($line =~ /^off=(\d+) error code=\d+ reason="(.*)"/) { ($errorOffset, $reason) = ($1, $2); last }
                if ($line =~ /^off=(\d+) headers complete/ && $headers < 0) { $headers = $1 }
                if ($line =~ /^off=\d+ message complete/) { $complete = 1; last }
            }
            $title =~ s/\t/ /g;
            $reason =~ s/\t/ /g;
            print $out join("\t", $file, $title, $type, unpack('H*', $input), $headers, $errorOffset, $reason, $complete), "\n";
            $count++;
        }
    }
}
close $out;
print STDERR "make-cases: $count cases\n";
