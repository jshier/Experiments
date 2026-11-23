#!/usr/bin/perl
# make-top1k.pl TOP1K_DIR OUTPUT_DIR: see make-top1k.sh (which checks OUTPUT_DIR is inside TestData/).
use strict;
use warnings;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

my ($top1k, $out) = @ARGV;

# A `.dat.gz` file's records: a 32-bit little-endian length, then that many bytes (cursed-http's bench/dump_corpus).
sub records {
    my ($path) = @_;
    my $data;
    gunzip($path => \$data) or die "make-top1k: $path: $GunzipError";
    my @records;
    my $offset = 0;
    while ($offset < length $data) {
        my $length = unpack('V', substr($data, $offset, 4));
        push @records, substr($data, $offset + 4, $length);
        $offset += 4 + $length;
    }
    return @records;
}

# Each message's head: through the first empty line (a body, where a request has one, is left out).
sub heads {
    my ($name, @records) = @_;
    my $all = '';
    for my $record (@records) {
        my $end = index($record, "\r\n\r\n");
        die "make-top1k: a $name without an empty line" if $end < 0;
        $all .= substr($record, 0, $end + 4);
    }
    return ($all, scalar @records);
}

for (['requests', 'requests.dat.gz'], ['responses', 'responses.dat.gz']) {
    my ($name, $file) = @$_;
    my ($bytes, $count) = heads($name, records("$top1k/$file"));
    open(my $output, '>:raw', "$out/$name.http1") or die "make-top1k: $out/$name.http1: $!";
    print $output $bytes;
    close $output;
    printf STDERR "make-top1k: %d %s, %d bytes\n", $count, $name, length $bytes;
}
