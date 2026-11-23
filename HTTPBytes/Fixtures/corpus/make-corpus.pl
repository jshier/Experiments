#!/usr/bin/perl
# make-corpus.pl QIFS_DIR OUTPUT_DIR: see make-corpus.sh (which checks OUTPUT_DIR is inside TestData/).
use strict;
use warnings;

my ($qifs, $out) = @ARGV;
my %reasons = (200 => 'OK', 204 => 'No Content', 206 => 'Partial Content', 301 => 'Moved Permanently',
    302 => 'Found', 304 => 'Not Modified', 400 => 'Bad Request', 404 => 'Not Found', 500 => 'Internal Server Error');

# Field sets of a QIF file: lists of [name, value], separated by blank lines; `#` lines are comments.
sub field_sets {
    my ($path) = @_;
    open(my $in, '<', $path) or die "make-corpus: $path: $!";
    my (@sets, @current);
    while (my $line = <$in>) {
        chomp $line;
        next if $line =~ /^#/;
        if ($line eq '') { push @sets, [@current] if @current; @current = (); next }
        my ($name, $value) = split /\t/, $line, 2;
        push @current, [$name, $value // ''];
    }
    push @sets, [@current] if @current;
    return @sets;
}

sub pseudo { my ($set, $name) = @_; for (@$set) { return $_->[1] if $_->[0] eq $name } return undef }

sub qif {
    my ($set) = @_;
    my @fields = ((grep { $_->[0] =~ /^:/ } @$set), (grep { $_->[0] !~ /^:/ } @$set));
    return join('', map { "$_->[0]\t$_->[1]\n" } @fields) . "\n";
}

# An HTTP/1 head: the start line, then fields; cookie crumbs joined into one field where the first was.
sub head {
    my ($start, $set, $host) = @_;
    my @lines = ($start);
    push @lines, "host: $host" if defined $host;
    my $cookie = join('; ', map { $_->[1] } grep { $_->[0] eq 'cookie' } @$set);
    my $cookieWritten = 0;
    for my $field (@$set) {
        my ($name, $value) = @$field;
        next if $name =~ /^:/;
        if ($name eq 'cookie') { next if $cookieWritten++; $value = $cookie }
        push @lines, "$name: $value";
    }
    return join("\r\n", @lines) . "\r\n\r\n";
}

my ($requests, $responses, $requestQIF, $responseQIF) = ('', '', '', '');
my ($requestCount, $responseCount) = (0, 0);
for my $file ('fb-req.qif', 'netbsd.qif', 'fb-resp.qif') {
    for my $set (field_sets("$qifs/$file")) {
        # fb-resp.qif names the status `status` (most sets) or `:status`: make it the pseudo-field.
        for (@$set) { $_->[0] = ':status' if $_->[0] eq 'status' && $file eq 'fb-resp.qif' }
        if (defined(my $status = pseudo($set, ':status'))) {
            $responses .= head("HTTP/1.1 $status " . ($reasons{$status} // 'Unknown'), $set, undef);
            $responseQIF .= qif($set);
            $responseCount++;
        } elsif (defined(my $method = pseudo($set, ':method'))) {
            my $path = pseudo($set, ':path') // '/';
            $requests .= head("$method $path HTTP/1.1", $set, pseudo($set, ':authority'));
            $requestQIF .= qif($set);
            $requestCount++;
        }
    }
}

for (['requests.http1', $requests], ['responses.http1', $responses], ['requests.qif', $requestQIF],
     ['responses.qif', $responseQIF]) {
    open(my $o, '>:raw', "$out/$_->[0]") or die "make-corpus: $out/$_->[0]: $!";
    print $o $_->[1];
    close $o;
}
printf STDERR "make-corpus: %d requests (%d bytes), %d responses (%d bytes)\n",
    $requestCount, length($requests), $responseCount, length($responses);
