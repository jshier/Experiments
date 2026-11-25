#!/usr/bin/perl
# macho.pl — what a file is, from its own header, read once: for Tools/loops, calls, mca (through loops), and bn, in
# place of `lipo -info` and `otool -h` (about 45 ms of xcrun lookups and processes per run).
#
# usage: perl macho.pl FILE [STARTS CODE]
#
# Prints KEY=VALUE lines (values are plain words: no quoting needed, and none is evaluated by the shell):
#   kind=object|binary|fat|archive|dsym|truncated|other
#                                          (binary: any linked Mach-O, executable, dylib, bundle; fat: universal; dsym:
#                                          a dSYM's DWARF file; truncated: its header or load commands end early)
#   cpu=arm64|arm64e|x86_64|cpu-N          (a thin Mach-O's architecture)
#   archs=arm64,x86_64                     (a universal file's slices, comma-separated)
#   slices=arm64@OFFSET@SIZE,…              (the same, with where each lies in the file, decimal)
#   text=FILEOFF:ADDRESS:SIZE              (the __TEXT,__text section, decimal)
# With STARTS and CODE (file paths), also writes:
#   STARTS  a linked binary's function starts (LC_FUNCTION_STARTS), one hex address a line; empty for an object
#   CODE    the address ranges of the sections holding instructions, "FIRST END" in hex a line (END exclusive)
# Exit 0 for any readable file (kind=other when it isn't Mach-O), 2 when it can't be read.
use strict;
use warnings;
# A truncated or damaged file is reported as such below, not with Perl's warnings about short reads.
no warnings qw(portable substr uninitialized numeric);

my ($path, $starts_path, $code_path) = @ARGV;
die "usage: macho.pl FILE [STARTS CODE]\n" unless defined $path;
open my $f, '<:raw', $path or do { print STDERR "macho.pl: can't read $path: $!\n"; exit 2 };
my $read = sub { my ($offset, $length) = @_; my $buffer = ''; seek $f, $offset, 0 or return ''; read $f, $buffer, $length; $buffer };
my %cpu_name = (0x0100000c => 'arm64', 0x01000007 => 'x86_64', 0x0200000c => 'arm64_32', 12 => 'arm', 7 => 'i386');
my $cpu_of = sub {
    my ($type, $subtype) = @_;
    if ($type == 0x0100000c) {   # ARM64, named by its subtype's low byte as lipo names it
        my $low = $subtype & 0xff;
        return $low <= 1 ? 'arm64' : $low == 2 ? 'arm64e' : $low == 12 ? 'arm64e.x1' : "arm64-subtype-$low";
    }
    return $cpu_name{$type} // "cpu-$type";
};
my $write = sub { # write PATH LINES...
    my ($file, @lines) = @_;
    return unless defined $file;
    open my $out, '>', $file or die "macho.pl: $file: $!\n";
    print $out @lines;
    close $out or die "macho.pl: $file: $!\n";
};

my $head = $read->(0, 32);
if (substr($head, 0, 8) eq "!<arch>\n") {
    print "kind=archive\n";
    $write->($_) for grep { defined } $starts_path, $code_path;
    exit 0;
}
my $magic_be = length $head >= 4 ? unpack('N', $head) : 0;
if ($magic_be == 0xcafebabe || $magic_be == 0xcafebabf) {
    # Universal: big-endian fat_arch (or fat_arch_64) entries after the count. (Java class files share 0xcafebabe; their
    # "count" is a version number, far above any real file's architectures.)
    if (length $head < 8) { print "kind=truncated\n"; $write->($_) for grep { defined } $starts_path, $code_path; exit 0 }   # no count
    my $count = unpack 'N', substr($head, 4, 4);
    if ($count >= 1 && $count <= 32) {
        my $size = $magic_be == 0xcafebabf ? 32 : 20;
        my $table = $read->(8, $count * $size);
        if (length $table < $count * $size) { print "kind=truncated\n"; $write->($_) for grep { defined } $starts_path, $code_path; exit 0 }
        my (@archs, @slices);
        for my $k (0 .. $count - 1) {
            my $entry = substr($table, $k * $size, $size);
            my ($type, $subtype) = unpack 'N2', $entry;
            my ($offset, $length) = $size == 32 ? unpack('x8 Q> Q>', $entry) : unpack('x8 N N', $entry);
            push @archs, $cpu_of->($type, $subtype);
            push @slices, "$archs[-1]\@$offset\@$length";
        }
        print "kind=fat\narchs=", join(',', @archs), "\nslices=", join(',', @slices), "\n";
        $write->($_) for grep { defined } $starts_path, $code_path;
        exit 0;
    }
}
my $magic = length $head >= 4 ? unpack('V', $head) : 0;
unless ($magic == 0xfeedfacf || $magic == 0xfeedface) {
    print "kind=other\n";
    $write->($_) for grep { defined } $starts_path, $code_path;
    exit 0;
}
my $wide = $magic == 0xfeedfacf;
if (length $head < ($magic == 0xfeedfacf ? 32 : 28) || ($magic == 0xfeedfacf ? 32 : 28) + unpack('V', substr($head, 20, 4)) > -s $f) {
    print "kind=truncated\n";   # the header, or its load commands, past the end of the file
    $write->($_) for grep { defined } $starts_path, $code_path;
    exit 0;
}
my ($type, $subtype, $filetype, $ncmds, $sizeofcmds) = unpack 'V5', substr($head, 4, 20);
print "kind=", ($filetype == 1 ? 'object' : $filetype == 10 ? 'dsym' : 'binary'), "\ncpu=", $cpu_of->($type, $subtype), "\n";
exit 0 unless $wide;   # 32-bit Mach-O: reported, never read further (the tools refuse it by its cpu)

# Load commands: segments and their sections (code ranges, __text), and the function starts.
my $commands = $read->(32, $sizeofcmds);
my (@code, $text, $text_segment, $starts);
my $at = 0;
for (1 .. $ncmds) {
    last if $at + 8 > length $commands;
    my ($cmd, $cmdsize) = unpack 'V2', substr($commands, $at, 8);
    last if $cmdsize < 8;
    if ($cmd == 0x19) {   # LC_SEGMENT_64
        my $segname = unpack 'Z16', substr($commands, $at + 8, 16);
        my ($vmaddr, $vmsize, $fileoff, $filesize, $maxprot, $initprot, $nsects) = unpack 'Q4 V3', substr($commands, $at + 24, 44);
        $text_segment = $vmaddr if $segname eq '__TEXT';
        for my $s (0 .. $nsects - 1) {
            my $section = substr($commands, $at + 72 + $s * 80, 80);
            last if length $section < 80;
            my ($sectname, $sectseg) = unpack 'Z16 Z16', $section;
            my ($addr, $size, $offset) = unpack 'Q2 V', substr($section, 32, 20);
            my $flags = unpack 'V', substr($section, 64, 4);
            # S_ATTR_PURE_INSTRUCTIONS or S_ATTR_SOME_INSTRUCTIONS.
            push @code, sprintf("%x %x\n", $addr, $addr + $size) if $flags & 0x80000400 && $size;
            $text = "$offset:$addr:$size" if $sectname eq '__text' && $sectseg eq '__TEXT';
        }
    } elsif ($cmd == 0x26) {   # LC_FUNCTION_STARTS: ULEB128 deltas from the __TEXT segment's address
        $starts = [unpack 'V2', substr($commands, $at + 8, 8)];
    }
    $at += $cmdsize;
}
print "text=$text\n" if defined $text;
if (defined $starts_path) {
    my @lines;
    if ($starts && defined $text_segment && $filetype != 1) {
        my $data = $read->(@$starts);
        my $address = $text_segment;
        my ($value, $shift) = (0, 0);
        for my $byte (unpack 'C*', $data) {
            $value |= ($byte & 0x7f) << $shift;
            $shift += 7;
            next if $byte & 0x80;
            last if $value == 0;
            $address += $value;
            push @lines, sprintf("%x\n", $address);
            ($value, $shift) = (0, 0);
        }
    }
    $write->($starts_path, @lines);
    $write->($code_path, @code) if defined $code_path;
}
