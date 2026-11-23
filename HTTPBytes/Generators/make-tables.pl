#!/usr/bin/perl
# Generates HTTPBytes' fixed tables as Swift literals (statically initialized: no lazy globals in parsing loops):
#
#   Sources/HTTPBytes/Generated/FieldNameTable.swift   well-known field names (field-names.txt): lowercase and canonical
#                                                       bytes, a perfect hash for case-insensitive lookup, static-table
#                                                       indexes, and a constant per name
#   Sources/HTTPBytes/Generated/StaticTables.swift      HPACK's and QPACK's static tables (hpack-static.tsv,
#                                                       qpack-static.tsv, extracted from RFC 7541 Appendix A and RFC 9204
#                                                       Appendix A) as (name index, value) pairs
#
# Run from anywhere: Generators/make-tables.pl. The hash's multiplier is searched deterministically (the first that
# works), so output is stable.
use strict;
use warnings;
use Math::BigInt;
use File::Basename qw(dirname);
use File::Path qw(make_path);

my $here = dirname(__FILE__);
my $out = "$here/../Sources/HTTPBytes/Generated";
make_path($out);

# Field names.
my (@canonical, %indexOf);
open(my $names, '<', "$here/field-names.txt") or die $!;
while (<$names>) {
    chomp;
    next if /^#/ || $_ eq '';
    my $lower = lc $_;
    die "duplicate field name $_" if exists $indexOf{$lower};
    $indexOf{$lower} = scalar @canonical;
    push @canonical, $_;
}
my @lower = map { lc } @canonical;
die "too many names" if @canonical > 254;

# Static tables: [name, value] by index.
sub table {
    my ($file) = @_;
    open(my $in, '<', "$here/$file") or die $!;
    my @rows;
    while (<$in>) { chomp; my ($index, $name, $value) = split /\t/, $_, 3; push @rows, [$index, $name, $value // ''] }
    return @rows;
}
my @hpack = table('hpack-static.tsv');
my @qpack = table('qpack-static.tsv');
my (%hpackFirst, %qpackFirst);
for (@hpack) { die "HPACK name $_->[1] not in field-names.txt" unless exists $indexOf{$_->[1]}; $hpackFirst{$_->[1]} //= $_->[0] }
for (@qpack) { die "QPACK name $_->[1] not in field-names.txt" unless exists $indexOf{$_->[1]}; $qpackFirst{$_->[1]} //= $_->[0] }

# The hash, on two words of the name's bytes ORed with 0x20 (ASCII case folding for token characters), which the lookup
# then compares too: names of 8 or more bytes, their first and last 8 bytes (overlapping when shorter than 16); 4 to 7,
# their first and last 4; 1 to 3, bytes 0, n/2, and n−1 in one word (the other 0). The key is the first word XOR the
# second rotated left 29 XOR the length; a slot is the top 10 bits of the key times a multiplier.
my $slotBits = 10;
my $modulus = Math::BigInt->new(2)->bpow(64);
my $mask64 = $modulus->copy->bsub(1);
sub little_endian {
    my $word = Math::BigInt->new(0);
    for my $byte (reverse @_) { $word->blsft(8)->bior($byte) }
    return $word;
}
sub words {
    my ($name) = @_;
    my @b = map { ord($_) | 0x20 } split //, $name;
    my $n = scalar @b;
    return (little_endian(@b[0 .. 7]), little_endian(@b[$n - 8 .. $n - 1])) if $n >= 8;
    return (little_endian(@b[0 .. 3]), little_endian(@b[$n - 4 .. $n - 1])) if $n >= 4;
    return (little_endian($b[0], $b[int($n / 2)], $b[$n - 1]), Math::BigInt->new(0));
}
sub key {
    my ($name) = @_;
    my ($first, $last) = words($name);
    my $rotated = $last->copy->blsft(29)->band($mask64)->bior($last->copy->brsft(35));
    return $first->copy->bxor($rotated)->bxor(Math::BigInt->new(length $name));
}
my %seenKeys;
my @keys = map { key($_) } @lower;
my @firstWords = map { my ($f, $l) = words($_); $f } @lower;
my @lastWords = map { my ($f, $l) = words($_); $l } @lower;
for my $i (0 .. $#keys) {
    my $k = $keys[$i]->bstr;
    die "names $lower[$seenKeys{$k}] and $lower[$i] have the same hash key" if exists $seenKeys{$k};
    $seenKeys{$k} = $i;
}
my ($multiplier, @slots);
my $candidate = Math::BigInt->new('0x9E3779B97F4A7C15');
TRY: for my $try (1 .. 200000) {
    my @table = (255) x (1 << $slotBits);
    for my $i (0 .. $#keys) {
        my $slot = $keys[$i]->copy->bmul($candidate)->bmod($modulus)->brsft(64 - $slotBits)->numify;
        if ($table[$slot] != 255) {
            $candidate->badd(Math::BigInt->new('0x2545F4914F6CDD1D'))->bmod($modulus);
            $candidate->bior(1);
            next TRY;
        }
        $table[$slot] = $i;
    }
    ($multiplier, @slots) = ($candidate, @table);
    last;
}
die "no multiplier found" unless defined $multiplier;
my $multiplierDigits = substr('0' x 16 . ($multiplier->as_hex =~ s/^0x//r), -16);
my $multiplierHex = '0x' . join('_', unpack('(A4)*', uc $multiplierDigits));

sub identifier {
    my ($name) = @_;
    if ($name =~ /^:(.*)/) { return 'pseudo' . ucfirst($1) }
    return 'eTag' if $name eq 'ETag'; # swift-http-types' spelling
    my @parts = split /-/, $name;
    my $first = lc shift @parts;
    my $rest = join '', map { (length($_) > 1 && $_ eq uc($_)) ? $_ : ucfirst(lc $_) } @parts;
    return $first . $rest;
}

sub bytes_literal {
    my ($indent, @values) = @_;
    my @lines;
    while (@values) { push @lines, $indent . join(', ', map { sprintf '0x%02X', $_ } splice(@values, 0, 16)) . ',' }
    return join("\n", @lines);
}
# Strings concatenated into one Swift string literal (printable ASCII without quotes or backslashes, checked).
sub string_literal {
    my @names = @_;
    for (@names) { die "name $_ can't be in a string literal" if /["\\]/ }
    return '"' . join('', @names) . '"';
}
sub numbers_literal {
    my ($indent, $per, @values) = @_;
    my @lines;
    while (@values) { push @lines, $indent . join(', ', splice(@values, 0, $per)) . ',' }
    return join("\n", @lines);
}

my (@lowerBytes, @canonicalBytes, @offsets);
for my $i (0 .. $#lower) {
    push @offsets, scalar @lowerBytes;
    push @lowerBytes, map { ord } split //, $lower[$i];
    push @canonicalBytes, map { ord } split //, $canonical[$i];
}
push @offsets, scalar @lowerBytes;
my @hpackIndexes = map { $hpackFirst{$_} // 0 } @lower;
my @qpackIndexes = map { $qpackFirst{$_} // 255 } @lower;

my $count = scalar @lower;
my $constants = join("\n", map {
    my $id = identifier($canonical[$_]);
    "    /// `$canonical[$_]`.\n    \@inlinable public static var $id: HTTPFieldName { HTTPFieldName(uncheckedIndex: $_) }"
} 0 .. $#lower);

open(my $swift, '>', "$out/FieldNameTable.swift") or die $!;
print $swift <<"EOF";
// Generated by Generators/make-tables.pl from field-names.txt, hpack-static.tsv, and qpack-static.tsv. Don't edit.

extension HTTPFieldName {
    /// How many names the table has.
    \@inlinable public static var knownCount: Int { $count }

    /// The hash's multiplier: a slot is the top $slotBits bits of the key times it (``slot(for:)``).
    \@usableFromInline static var hashMultiplier: UInt64 { $multiplierHex }

    /// The hash's slot count's bits.
    \@usableFromInline static var slotBits: Int { $slotBits }

$constants
}

/// The table's data. Literal `InlineArray`s: statically initialized (no lazy initialization when read), and masked indexes need no bounds check.
\@usableFromInline
enum FieldNameTable {
    /// Each name's lowercase bytes, one after another (`offsets` gives each one's range). A `StaticString`: its bytes
    /// are constant data in the binary, at an address that never changes, so spans of them can be immortal. (A `static
    /// let` `InlineArray` can't back such spans: reading it may produce a temporary copy.)
    \@usableFromInline static var lowercase: StaticString {
        @{[string_literal(@lower)]}
    }

    /// Each name's canonical HTTP/1 spelling, at the same offsets.
    \@usableFromInline static var canonical: StaticString {
        @{[string_literal(@canonical)]}
    }

    /// Name i's bytes are `offsets[i]..<offsets[i + 1]`.
    \@usableFromInline static let offsets: InlineArray<@{[scalar @offsets]}, UInt16> = [
@{[numbers_literal('        ', 16, @offsets)]}
    ]

    /// The hash's slots: the name's index, or 0xFF for none.
    \@usableFromInline static let slots: InlineArray<@{[scalar @slots]}, UInt8> = [
@{[bytes_literal('        ', @slots)]}
    ]

    /// Each name's first index in HPACK's static table (1–61), or 0.
    \@usableFromInline static let hpackIndexes: InlineArray<$count, UInt8> = [
@{[numbers_literal('        ', 16, @hpackIndexes)]}
    ]

    /// Each name's first index in QPACK's static table (0–98), or 0xFF.
    \@usableFromInline static let qpackIndexes: InlineArray<$count, UInt8> = [
@{[numbers_literal('        ', 16, @qpackIndexes)]}
    ]

    /// Each name's first hash word (see ``HTTPFieldName/words(_:)``), which the lookup compares with the name's.
    \@usableFromInline static let firstWords: InlineArray<$count, UInt64> = [
@{[numbers_literal('        ', 4, map { '0x' . substr('0' x 16 . ($_->as_hex =~ s/^0x//r), -16) } @firstWords)]}
    ]

    /// Each name's second hash word.
    \@usableFromInline static let lastWords: InlineArray<$count, UInt64> = [
@{[numbers_literal('        ', 4, map { '0x' . substr('0' x 16 . ($_->as_hex =~ s/^0x//r), -16) } @lastWords)]}
    ]
}
EOF
close $swift;

# Static tables: each entry's name index and value.
sub static_table {
    my ($swiftName, $doc, @rows) = @_;
    my (@names, @valueBytes, @valueOffsets);
    for (@rows) {
        push @names, $indexOf{$_->[1]};
        push @valueOffsets, scalar @valueBytes;
        push @valueBytes, map { ord } split //, $_->[2];
    }
    push @valueOffsets, scalar @valueBytes;
    my $n = scalar @rows;
    return <<"EOF";
/// $doc
\@usableFromInline
package enum $swiftName {
    /// The entry count.
    \@inlinable package static var count: Int { $n }

    /// Entry i's name, as an ``HTTPFieldName`` index.
    \@usableFromInline package static let names: InlineArray<$n, UInt8> = [
@{[numbers_literal('        ', 16, @names)]}
    ]

    /// Entry i's value is `values[valueOffsets[i]..<valueOffsets[i + 1]]`.
    \@usableFromInline package static let valueOffsets: InlineArray<@{[scalar @valueOffsets]}, UInt16> = [
@{[numbers_literal('        ', 16, @valueOffsets)]}
    ]

    /// Every entry's value bytes, one after another: a string literal, constant data that spans can borrow forever.
    \@usableFromInline package static var values: StaticString {
        @{[string_literal(map { $_->[2] } @rows)]}
    }
}
EOF
}

open($swift, '>', "$out/StaticTables.swift") or die $!;
print $swift "// Generated by Generators/make-tables.pl from hpack-static.tsv and qpack-static.tsv. Don't edit.\n\n";
print $swift static_table('HPACKStaticTable', "HPACK's static table (RFC 7541 Appendix A): entry i (from 0) is index i + 1.", @hpack);
print $swift "\n";
print $swift static_table('QPACKStaticTable', "QPACK's static table (RFC 9204 Appendix A): entry i is index i.", @qpack);
close $swift;

printf STDERR "make-tables: %d names, multiplier %s; HPACK %d entries, QPACK %d\n", $count, $multiplierHex,
    scalar @hpack, scalar @qpack;
