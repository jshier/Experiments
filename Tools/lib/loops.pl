#!/usr/bin/perl
# Reads `objdump -dr --no-show-raw-insn` output on stdin and reports the loops of functions, found from each one's
# control-flow graph. Two ways to name the functions:
#
# - LOOPS_FUNCTIONS: a file of "mangled<TAB>demangled" lines (Tools/loops' matches, in the order to report them), with
#   LOOPS_SYMBOLS (`nm -a` output) giving each name's addresses. stdin may hold the whole file's disassembly; only the
#   blocks at those addresses are read, whatever name objdump printed for them (an alias such as `ltmp0`). A name
#   defined at several addresses (a merged object) is analyzed per copy.
# - Otherwise FUNCTION names every `ADDRESS <NAME>:` block on stdin (copies of one symbol).
#
# The analysis:
# - Basic blocks start at the entry, at every branch target, and after every branch, return, or trap. Branch targets
#   are read as numbers (objdump without --symbolize-operands). A branch with a relocation (`ARM64_RELOC_BRANCH26`
#   in an object: an external call or tail call) or to an address outside the function leaves the function; a branch
#   to its own address without one is a one-instruction loop (`b .`, `cbnz x1, .`).
# - A `br` whose register was last written by an `add` of a table entry (an `ldrb`/`ldrh`/`ldrsw`… indexed by a
#   register) is a `switch`: its successors are the table's cases, read from the file's `__const`. The table's address
#   comes from `adrp`/`add` (or their relocation's symbol and addend: in a merged object, the copy the relocation names,
#   from `otool -r`'s symbol numbers, LOOPS_RELOCS and LOOPS_SECTIONS); its length from a bounds check that every path
#   to the load passes (`cmp` of the index register, then `b.hi`/`b.hs`, no join point or write to the register before
#   the load), or from the index's width (its last write: `ldrb`, `and #mask`, `lsr`, `ubfx`: Swift's exhaustive
#   switches have no check), capped by the table's extent (up to the next symbol), or from the extent alone. A table
#   that can't be read gets the unreached blocks that nothing else unreached leads to, within its entries' reach, with
#   a warning on stderr. Any other `br` is an indirect tail call. Blocks still unreached are extra roots.
# - Natural loops: a back edge latch -> header where the header dominates the latch; the loop is the header plus every
#   block that reaches the latch without passing the header; loops sharing a header are one loop.
# - Irreducible loops: cycles no natural loop explains, entered at more than one block (a vectorizer's remainder
#   entered from two places, a retry loop). They are the strongly connected components of the whole graph, of each
#   natural loop without its header, and of each irreducible cycle without its entries, that don't lie inside a
#   natural loop whose header they hold; their entry blocks are their headers. One shape is named for its natural
#   loop instead: a cycle that is a natural loop (holding every natural loop of the cycle) plus side blocks with no
#   cycle of their own (a refill path laid out before the header, also entered from before the loop; an outer loop
#   whose preheader can be bypassed into the inner loop's header; Duff's device) is reported as `natural+side-entry`,
#   headed by that loop's header, around the natural loop, which keeps its own row: an innermost loop never grows.
# - Depth is the number of loops holding all of a loop's blocks and more; innermost loops hold no other.
#
# Environment: FORMAT (text|tsv), BODY (1: print each loop's blocks, in address order, with gaps marked), REQUIRE /
# FORBID (comma-separated mnemonics, with or without their numeric or lane suffix: `zip` matches `zip1.16b`, `bl`
# doesn't match `tbl` or `blr`; checked against the innermost loops), LOOPS_CONST (a file of
# `objdump -r -s --section=__const` output), LOOPS_SYMBOLS (`nm -p -a`: the symbol table in its order), LOOPS_RELOCS
# (`otool -r`) and LOOPS_SECTIONS (`objdump -h`), for reading jump tables; LOOPS_JOBS and LOOPS_TMP for analyzing in
# parallel. Output is the same whatever Perl's hash order (every hash is read in sorted order).
# Exit status 1 if REQUIRE/FORBID are given and some copy of a function has no innermost loop satisfying them; 2 if a
# parallel worker failed.
use strict;
use warnings;
no warnings 'portable';   # addresses above 0xffffffff in linked binaries

my $format = $ENV{FORMAT} // 'text';
my %require = map { $_ => 1 } grep { length } split /,/, ($ENV{REQUIRE} // '');
my %forbid = map { $_ => 1 } grep { length } split /,/, ($ENV{FORBID} // '');
my $checking = %require || %forbid;
# Notes and check results for stderr: in program order with stdout (flushed first), or marked in a worker's stdout.
my $in_worker = 0;
sub err { if ($in_worker) { print "\x01$_[0]" } else { STDOUT->flush; print STDERR $_[0] } }

# Symbols: every name's addresses, the text symbols' names by address, and every symbol address in order (for a
# table's extent).
my (%addresses_of, %text_at, @symbol_addresses);
if (my $file = $ENV{LOOPS_SYMBOLS}) {
    if (open my $f, '<', $file) {
        my %all;
        while (<$f>) {
            # "ADDRESS TYPE NAME" (a name may hold spaces: Objective-C methods); debugger entries (type "-") left out.
            next unless /^([0-9a-f]+) ([A-Za-z]) (.+)$/;
            my ($address, $type, $name) = (hex $1, $2, $3);
            push @{$addresses_of{$name}}, $address;
            push @{$text_at{$address}}, $name if $type =~ /^[Tt]$/;
            $all{$address} = 1;
        }
        @symbol_addresses = sort { $a <=> $b } keys %all;
        @$_ = sort { $a <=> $b } @$_ for values %addresses_of;
    }
}

# An object's references (the addresses its code refers to: `references` below) are found by a child process while this
# one reads the disassembly, so they cost no time before the workers start (0.04 s on a 2 MB object): the child writes
# them to LOOPS_TMP/references, and references() adopts them. Only when the analysis may run in parallel.
my $references_child;
my $references_parent = $$;
# A child never adopted (no function had a `br`) is stopped at exit, so it doesn't outlive the tool holding its stdout
# (a pipe's reader would see the end late). Only the process that made it: workers run END blocks too; the child itself
# leaves with _exit.
END { local $?; if ($references_child && $$ == $references_parent) { kill 'KILL', $references_child; waitpid $references_child, 0 } }
if (($ENV{LOOPS_KIND} // '') eq 'object' && $ENV{LOOPS_RELOCS} && $ENV{LOOPS_TMP} && ($ENV{LOOPS_JOBS} // 1) > 1) {
    require POSIX;
    $references_child = fork;
    if (defined $references_child && $references_child == 0) {
        my $list = references();
        open my $out, '>', "$ENV{LOOPS_TMP}/references.part" or POSIX::_exit(1);
        print $out "$_\n" for @$list;
        close $out or POSIX::_exit(1);
        rename "$ENV{LOOPS_TMP}/references.part", "$ENV{LOOPS_TMP}/references" or POSIX::_exit(1);
        POSIX::_exit(0);   # no END blocks, nothing flushed: the parent owns the output
    }
}

# The functions to report, and the addresses whose blocks to read.
my (@functions, %wanted);
if (my $file = $ENV{LOOPS_FUNCTIONS}) {
    open my $f, '<', $file or die "loops.pl: can't read $file: $!\n";
    while (<$f>) {
        chomp;
        my ($mangled, $demangled) = split /\t/, $_, 2;
        next unless defined $mangled && length $mangled;
        $demangled //= $mangled;
        my @addresses = grep { my $a = $_; grep { $_ eq $mangled } @{$text_at{$a} // []} } @{$addresses_of{$mangled} // []};
        push @functions, [$mangled, $demangled, \@addresses];
        $wanted{$_} = 1 for @addresses;
    }
}
my $batch = defined $ENV{LOOPS_FUNCTIONS};

# Blocks of the disassembly: each `ADDRESS <NAME>:` header starts one. Only wanted ones are kept in batch mode.
my (%block_at, @single, $current, $complete);
while (my $line = <STDIN>) {
    # Tools/loops ends a successful objdump's output with this line (LOOPS_END=1): without it, objdump failed (E2BIG, a
    # damaged file) and an empty or partial disassembly would read as "no loops".
    if ($line eq "<<end of the disassembly>>\n") { $complete = 1; next }
    if ($line =~ /^([0-9a-f]+) <(.+)>:$/) {
        my $start = hex $1;
        if ($batch && !$wanted{$start}) { undef $current; next }
        $current = { start => $start, insns => [] };
        # An alias listed by --disassemble-symbols prints its own (empty) header at the same address: one block.
        if ($batch) { $current = $block_at{$start} //= $current } else { push @single, $current }
        next;
    }
    next unless $current;
    # A relocation belongs to the instruction before it: "\t\t0000000000000020:  ARM64_RELOC_BRANCH26\t_helper".
    if ($line =~ /^\s+[0-9a-f]+:\s+(ARM64_RELOC_\w+)\s+(.+?)\s*$/) {   # the whole name (it may hold spaces)
        my $last = $current->{insns}[-1];
        my ($kind, $value) = ($1, $2);
        if ($last && $kind eq 'ARM64_RELOC_ADDEND') { $last->{addend} = $value =~ /^0x/ ? hex $value : $value }
        elsif ($last) { $last->{reloc} = $value; $last->{reloc_kind} = $kind }
        next;
    }
    next unless $line =~ /^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$/;
    my ($address, $mnemonic, $operands) = (hex $1, $2, $3);
    next if $mnemonic =~ /^\./;   # data in code (.long, .byte)
    $operands =~ s/\s*;.*$//;
    push @{$current->{insns}}, { address => $address, mnemonic => $mnemonic, operands => $operands };
}
if ($ENV{LOOPS_END} && !$complete) { print STDERR "error: objdump's disassembly ended early (objdump failed: see above)\n"; exit 2 }
if (!$batch) { @functions = ([undef, $ENV{FUNCTION} // '?', undef]) }

sub report { # report FUNCTIONS...: analyze each; false if a check failed
    my $all_ok = 1;
    for my $function (@_) {
        my ($mangled, $demangled, $addresses) = @$function;
        my @copies = $batch ? grep { defined } map { $block_at{$_} } @$addresses : @single;
        if (!@copies) {
            print "$demangled\n  no instructions\n" if $format eq 'text';
            $all_ok = 0 if $checking;
            next;
        }
        my $copy_number = 0;
        for my $copy (@copies) {
            $copy_number++;
            my $name = @copies > 1 ? sprintf("%s [copy %d of %d, at 0x%x]", $demangled, $copy_number, scalar @copies, $copy->{start}) : $demangled;
            my $ok = analyze($name, $copy->{insns}, $copy->{start});
            $all_ok &&= $ok;
        }
    }
    return $all_ok;
}

# Many functions: LOOPS_JOBS processes each analyze a run of them (split by instruction count) into a file in
# LOOPS_TMP: stdout, with every stderr line marked "\x01" in its place, and a last line "\x02" and 1 (every check
# passed) or 0. The parent prints the files in order, the marked lines to stderr, so the output, 2>&1 included, is one
# process's. A worker that stops without its last line (a signal, a Perl error) stops the whole run: exit 2.
my $jobs = $ENV{LOOPS_JOBS} // 1;
unless ($jobs =~ /^[1-9][0-9]{0,5}$/) { print STDERR "error: LOOPS_JOBS must be a whole number from 1 to 999999, not '$jobs'\n"; exit 2 }
my $total = 0;
$total += @{$_->{insns}} for values %block_at;
if (!$batch || $jobs < 2 || !$ENV{LOOPS_TMP} || $total < 20000) {
    exit(report(@functions) || !$checking ? 0 : 1);
}
# An object's references, adopted from the child here rather than found in every worker, when some function has a `br`
# (only tables need them). A linked binary's are left to each worker (its scan of __text runs in parallel then, where here it would
# delay every worker).
references() if ($ENV{LOOPS_KIND} // '') eq 'object' && grep { $_->{mnemonic} eq 'br' } map { @{$_->{insns}} } values %block_at;
my @chunks = ([]);
my $size = 0;
my $share = $total / $jobs;
for my $function (@functions) {
    if ($size >= $share && @chunks < $jobs) { push @chunks, []; $size = 0 }
    push @{$chunks[-1]}, $function;
    $size += @{$block_at{$_}{insns}} for grep { $block_at{$_} } @{$function->[2]};
}
my @children;
# A TERM, INT, or HUP to this process stops the workers too (a Ctrl-C reaches them anyway, through the process group).
my %number = (HUP => 1, INT => 2, TERM => 15);
for my $signal (keys %number) {
    $SIG{$signal} = sub { kill $signal, grep { defined } @children; STDOUT->flush; exit 128 + $number{$signal} };
}
# Blocked around each fork, so no signal comes between a fork and its pid being recorded.
require POSIX;
my $blocked = POSIX::SigSet->new(values %number);
my $old = POSIX::SigSet->new;
for my $c (0 .. $#chunks) {
    POSIX::sigprocmask(POSIX::SIG_BLOCK(), $blocked, $old);
    my $pid = fork // die "loops.pl: fork: $!\n";
    if ($pid == 0) {
        $SIG{$_} = 'DEFAULT' for keys %number;
        POSIX::sigprocmask(POSIX::SIG_SETMASK(), $old);
        open STDOUT, '>', "$ENV{LOOPS_TMP}/out.$c" or die "loops.pl: $ENV{LOOPS_TMP}/out.$c: $!\n";
        $in_worker = 1;
        my $ok = report(@{$chunks[$c]});
        print "\x02", ($ok ? 1 : 0), "\n";
        close STDOUT or die "loops.pl: writing $ENV{LOOPS_TMP}/out.$c: $!\n";
        exit 0;
    }
    push @children, $pid;
    POSIX::sigprocmask(POSIX::SIG_SETMASK(), $old);
}
my @status;
for my $c (0 .. $#chunks) { waitpid $children[$c], 0; $status[$c] = $?; $children[$c] = undef }   # reaped: never signalled again
my $failed = 0;
for my $c (0 .. $#chunks) {
    my $done;
    if (open my $f, '<', "$ENV{LOOPS_TMP}/out.$c") {
        while (my $line = <$f>) {
            if ($line =~ /^\x02([01])$/) { $done = $1; last }
            if ($line =~ s/^\x01//) { STDOUT->flush; print STDERR $line } else { print $line }
        }
    }
    if ($status[$c] || !defined $done) {
        STDOUT->flush;
        my $how = $status[$c] & 127 ? "signal " . ($status[$c] & 127) : "status " . ($status[$c] >> 8);
        print STDERR "loops.pl: worker ", $c + 1, " of ", scalar @chunks, " stopped ($how) before finishing its functions\n";
        exit 2;
    }
    $failed = 1 if !$done;
}
exit($failed && $checking ? 1 : 0);

sub is_conditional { $_[0] =~ /^(b\.\w+|bc\.\w+|cbz|cbnz|tbz|tbnz)$/ }
sub is_jump { $_[0] eq 'b' || is_conditional($_[0]) }
# Ends a block with no fall-through: returns, traps, indirect branches.
sub is_stop { $_[0] =~ /^(ret|retaa|retab|br|braa|brab|braaz|brabz|brk|udf|hlt|eret|eretaa|eretab)$/ }
# The register number an operand names (x9 and w9 are both 9), or undef.
sub regnum { defined $_[0] && $_[0] =~ /^\s*[xw](\d+)\s*$/ ? $1 : undef }
sub operands { my @o = split /,\s*/, $_[0]; s/^\s+|\s+$//g for @o; @o }
# The general registers an instruction writes (its destination operands); none for stores, compares, and branches.
sub writes {
    my ($m, $o) = @_;
    # A call may change every caller-saved register (x0-x18) and the link register.
    return (0 .. 18, 30) if $m =~ /^(bl|blr|blraa|blrab|blraaz|blrabz)$/;
    return () if $m =~ /^(st|cmp|cmn|tst|ccmp|ccmn|fcmp|b$|b\.|bc\.|bl|br|cb|tb|ret|prfm|dmb|dsb|isb|nop|brk|udf|hint|msr)/;
    my @o = operands($o);
    my @r = (regnum($o[0]));
    push @r, regnum($o[1]) if $m =~ /^ldn?p/;
    return grep { defined } @r;
}

# The __const sections' bytes, the relocations in them (an object's relative table entries are a SUBTRACTOR/UNSIGNED
# pair added to the stored value), read on first use. LOOPS_CONST holds `objdump -r -s --section=__const`: relocation
# blocks, then content blocks, in the same order.
my (@segments, %reloc_at, $data_loaded);
sub load_data {
    return if $data_loaded++;
    my $file = $ENV{LOOPS_CONST} or return;
    open my $f, '<', $file or return;
    my (@relocs, @bases, $block, $base, $bytes, $next);
    while (<$f>) {
        if (/^RELOCATION RECORDS FOR/) { push @relocs, []; $block = $relocs[-1]; next }
        if (/^Contents of section/) { push @segments, [$base, $bytes] if defined $base; undef $base; push @bases, undef; undef $block; next }
        if ($block && /^([0-9a-f]+)\s+(ARM64_RELOC_\w+)\s+(.+?)\s*$/) { push @$block, [hex $1, $2, $3]; next }
        next unless @bases && /^ ([0-9a-f]+) ((?:[0-9a-f]{2,8} ){0,4})/;
        my ($at, $hex) = (hex $1, $2);
        $hex =~ s/\s+//g;
        $bases[-1] //= $at;
        if (!defined $base || $at != $next) { push @segments, [$base, $bytes] if defined $base; ($base, $bytes) = ($at, '') }
        $bytes .= pack 'H*', $hex;
        $next = $at + length($hex) / 2;
    }
    push @segments, [$base, $bytes] if defined $base;
    return unless @relocs == @bases;
    for my $k (0 .. $#relocs) {
        my %sub;
        for my $r (@{$relocs[$k]}) {
            my ($offset, $kind, $symbol) = @$r;
            my $address = $bases[$k] + $offset;
            if ($kind eq 'ARM64_RELOC_SUBTRACTOR') {
                # In a merged object a section-start symbol (`ltmp1`) has a copy per merged object: the one at or below.
                my ($copy) = grep { $_ <= $address && $_ >= $bases[$k] } reverse @{$addresses_of{$symbol} // []};
                $sub{$address} = $copy;
                next;
            }
            next unless $kind eq 'ARM64_RELOC_UNSIGNED';
            $reloc_at{$address} = { plus => $symbol, minus => exists $sub{$address} ? $sub{$address} : 0 };
        }
    }
}
sub segment_end { # the end of the __const segment holding ADDRESS, or undef
    my ($address) = @_;
    for my $s (@segments) { return $s->[0] + length $s->[1] if $address >= $s->[0] && $address < $s->[0] + length $s->[1] }
    return undef;
}
sub read_entry { # read_entry ADDRESS WIDTH SIGNED FUNCTION_START: an integer from __const, relocated, or undef
    my ($address, $width, $signed, $function_start) = @_;
    load_data();
    for my $s (@segments) {
        my ($base, $bytes) = @$s;
        next unless $address >= $base && $address + $width <= $base + length $bytes;
        my $raw = substr $bytes, $address - $base, $width;
        my $format = { 1 => 'C', 2 => 'v', 4 => 'V' }->{$width};
        my $v = unpack $format, $raw;
        $v -= 1 << (8 * $width) if $signed && $v >= 1 << (8 * $width - 1);
        if (my $r = $reloc_at{$address}) {
            return undef unless defined $r->{minus};
            # The symbol added: its copy at or below this function (a section start such as `ltmp0` has several).
            my @plus = @{$addresses_of{$r->{plus}} // []};
            my ($plus) = @plus == 1 ? @plus : grep { $_ <= $function_start } reverse @plus;
            return undef unless defined $plus;
            $v += $plus - $r->{minus};
        }
        return $v;
    }
    return undef;
}
sub extent { # (bytes from ADDRESS to its extent's end, whether a symbol or a reference ends it) in its segment, or ()
    my ($address) = @_;
    load_data();
    my $end = segment_end($address);
    return () unless defined $end;
    my ($next) = grep { $_ > $address } @symbol_addresses;   # sorted: the first is the nearest
    my $limit = defined $next && $next < $end ? $next : $end;
    for my $r (@{references()}) {
        next unless $r > $address;
        $limit = $r if $r < $limit;
        last;
    }
    return ($limit - $address, $limit < $end ? 1 : 0);
}
# The addresses in __const that code refers to, sorted, found on first use: in an object, every PAGEOFF12 relocation's
# symbol and addend (`otool -r`, LOOPS_RELOCS); in a linked binary, every `adrp` into __const's pages in __TEXT,__text
# (LOOPS_TEXT, read from the file) and the `add` or load/store offsets on its register in the 8 instructions after it,
# up to an instruction that writes the register. Each is where some constant starts: the next table, a literal.
my $references;
sub references {
    return $references if $references;
    if ($references_child) {   # the child's, when it made them
        waitpid $references_child, 0;
        $references_child = undef;
        if ($? == 0 && open my $in, '<', "$ENV{LOOPS_TMP}/references") {
            chomp(my @list = <$in>);
            return $references = \@list;
        }
    }
    load_data();
    my %seen;
    my ($file, $kind) = ($ENV{LOOPS_FILE}, $ENV{LOOPS_KIND} // '');
    if ($kind eq 'object' && $ENV{LOOPS_RELOCS}) {
        # `otool -r`: per section, "address pcrel length extern type scattered symbolnum/value". Type 4 is PAGEOFF12, its
        # symbol numbered in the symbol table's order (`nm -p -a`, LOOPS_SYMBOLS: so each copy of a name a merged object
        # defines several times is told apart); type 10 is the ADDEND before it at the same address, its value the addend.
        my @by_index = symbols_by_index();
        if (open my $r, '<', $ENV{LOOPS_RELOCS}) {
            my %addend;
            while (<$r>) {
                if (/^Relocation information/) { %addend = (); next }
                next unless /^([0-9a-f]+)\s+\d+\s+\d+\s+([01])\s+(\d+)\s+0\s+(\d+)\s*$/;
                my ($at, $extern, $type, $value) = ($1, $2, $3, $4);
                if ($type == 10) { $addend{$at} = $value; next }
                next unless $type == 4 && $extern;
                my $entry = $by_index[$value];
                $seen{$entry->[0] + ($addend{$at} // 0)} = 1 if $entry && defined $entry->[0];
            }
            close $r;
        }
    } elsif
 (defined $file && @segments && ($ENV{LOOPS_TEXT} // '') =~ /^(\d+):(\d+):(\d+)$/) {
        my ($offset, $base, $size) = ($1, $2, $3);
        my ($low, $high) = (~0, 0);
        for my $s (@segments) {
            $low = $s->[0] if $s->[0] < $low;
            $high = $s->[0] + length $s->[1] if $s->[0] + length $s->[1] > $high;
        }
        my ($first_page, $last_page) = ($low & ~0xfff, ($high - 1) & ~0xfff);
        my $text = '';
        if (open my $f, '<:raw', $file) { seek $f, $offset, 0 and read $f, $text, $size }
        # An adrp's top byte is 0x90, 0xb0, 0xd0, or 0xf0 (bit 31 set, bits 28-24 10000): found by a regex, kept when it
        # is a word's last byte.
        while ($text =~ /[\x90\xb0\xd0\xf0]/g) {
            my $at = pos($text) - 4;
            next if $at & 3;
            my $w = unpack 'V', substr($text, $at, 4);
            next unless ($w & 0x9f000000) == 0x90000000;
            my $immediate = (($w >> 29) & 3) | ((($w >> 5) & 0x7ffff) << 2);
            $immediate -= 1 << 21 if $immediate & (1 << 20);
            my $page = (($base + $at) & ~0xfff) + $immediate * 4096;
            next if $page < $first_page || $page > $last_page;
            my $rd = $w & 31;
            for my $k (1 .. 8) {
                last if $at + 4 * $k + 4 > length $text;
                my $v = unpack 'V', substr($text, $at + 4 * $k, 4);
                my $rn = ($v >> 5) & 31;
                if (($v & 0xff800000) == 0x91000000 && $rn == $rd) {   # add Xd, Xn, #imm{, lsl #12}
                    $seen{$page + ((($v >> 10) & 0xfff) << ((($v >> 22) & 1) * 12))} = 1;
                } elsif (($v & 0x3b000000) == 0x39000000 && $rn == $rd) {   # ldr/str (unsigned offset), general or SIMD
                    my $scale = $v >> 30;
                    $scale = 4 if (($v >> 26) & 1) && (($v >> 23) & 1);   # a q register
                    $seen{$page + ((($v >> 10) & 0xfff) << $scale)} = 1;
                }
                last if ($v & 31) == $rd;   # the register written (or stored: either way, stop)
            }
        }
    }
    $references = [sort { $a <=> $b } grep { defined segment_end($_) } keys %seen];
    return $references;
}

# The entry count a bounds check gives the table load at index LOAD, or undef: walking back from the load along the
# only path to it (no instruction in between is a branch target, none writes the index register) to `cmp wI, #K`
# followed by `b.hi` (K + 1 entries) or `b.hs` (K).
sub bound_count {
    my ($insns, $load, $index_reg, $is_target) = @_;
    return undef if $is_target->{$load};
    for (my $j = $load - 1; $j >= 0 && $j >= $load - 64; $j--) {
        my $insn = $insns->[$j];
        my $m = $insn->{mnemonic};
        return undef if $is_target->{$j + 1} && $j + 1 < $load;   # a join point: a path that skips what's above
        if ($m =~ /^b\.(hi|hs)$/ && $j > 0 && $insns->[$j - 1]{mnemonic} eq 'cmp' && !$is_target->{$j}) {
            my @o = operands($insns->[$j - 1]{operands});
            if ((regnum($o[0]) // -1) == $index_reg && ($o[1] // '') =~ /^#(0x[0-9a-f]+|\d+)$/) {
                my $literal = $1;
                my $k = $literal =~ /^0x/ ? hex $literal : $literal;
                my $next = $m;
                my $count;
                $count = $next eq 'b.hs' ? $k : $k + 1;
                return ($count, 'check');
            }
        }
        return undef if is_stop($m) || $m eq 'b';
        # The index register's last write: its value's width bounds the index (Swift's exhaustive switches extract a
        # tag with `lsr`/`and`/`ubfx` and have no bounds check).
        if (grep { $_ == $index_reg } writes($m, $insn->{operands})) {
            my $bits = value_bits($insns, $j, $is_target, 0);
            return defined $bits && $bits <= 16 ? (1 << $bits, 'width') : undef;
        }
    }
    return undef;
}

# How many low bits the value written at index J can have set, or undef: from the instruction and, for shifts and moves,
# its source's last write on the only path to it (as bound_count walks).
sub value_bits {
    my ($insns, $j, $is_target, $depth) = @_;
    return undef if $depth > 4;
    my $insn = $insns->[$j];
    my ($m, @o) = ($insn->{mnemonic}, operands($insn->{operands}));
    my $width = ($o[0] // '') =~ /^\s*w/ ? 32 : 64;
    my $imm = sub { my $v = shift // ''; return undef unless $v =~ /^#(0x[0-9a-f]+|\d+)$/; my $n = $1; $n =~ /^0x/ ? hex $n : $n };
    return 8 if $m =~ /^(ldrb|uxtb)$/;
    return 16 if $m =~ /^(ldrh|uxth)$/;
    if ($m eq 'ubfx' && defined(my $w = $imm->($o[3]))) { return $w }
    if ($m eq 'and' && defined(my $mask = $imm->($o[2]))) {
        my $bits = 0;
        $bits++ while $bits < 64 && ($mask >> $bits) > 0;
        return $bits;
    }
    my $source = sub { # the bits of register operand K's value before J
        my $reg = regnum($o[$_[0]]);
        return $width unless defined $reg;
        for (my $k = $j - 1; $k >= 0 && $k >= $j - 64; $k--) {
            return $width if $is_target->{$k + 1};
            my $mk = $insns->[$k]{mnemonic};
            return $width if is_stop($mk) || $mk eq 'b';
            next unless grep { $_ == $reg } writes($mk, $insns->[$k]{operands});
            return value_bits($insns, $k, $is_target, $depth + 1) // $width;
        }
        return $width;
    };
    if ($m eq 'lsr' && defined(my $s = $imm->($o[2]))) { my $b = $source->(1) - $s; return $b < 0 ? 0 : $b }
    if ($m eq 'mov' && defined regnum($o[1])) { return $source->(1) }
    return undef;
}

# A jump table's `br` at index I: { targets => [addresses] } when the table could be read, else { anchor, span, why }
# for placing unreached blocks by position, or undef when the `br` is no jump table (an indirect tail call).
sub jump_table {
    my ($insns, $i, $index_at, $is_target, $function_start, $plain) = @_;
    my $register = regnum($insns->[$i]{operands});
    return undef unless defined $register;
    # The instructions before the br, back to the previous branch.
    my @window;
    for (my $j = $i - 1; $j >= 0 && $j >= $i - 12; $j--) {
        my $m = $insns->[$j]{mnemonic};
        last if is_jump($m) || is_stop($m);
        push @window, $j;
    }
    # The last write of the br register must be an `add` of a loaded table entry.
    my ($add) = grep { my @w = writes($insns->[$_]{mnemonic}, $insns->[$_]{operands}); grep { $_ == $register } @w } @window;
    return undef unless defined $add && $insns->[$add]{mnemonic} eq 'add';
    my @ao = operands($insns->[$add]{operands});
    my ($a, $b) = (regnum($ao[1]), regnum($ao[2]));
    return undef unless defined $a && defined $b;
    my $shift = ($ao[3] // '') =~ /lsl #(?:0x)?(\d+)/ ? $1 : 0;
    # Each add operand's last write before the add (in the window): one must be a table load.
    my ($load, $width, $signed, $table_reg, $index_reg, $loaded_reg);
    for my $operand ($a, $b) {
        my ($j) = grep { my $k = $_; grep { $_ == $operand } writes($insns->[$k]{mnemonic}, $insns->[$k]{operands}) }
            grep { $_ < $add } @window;
        next unless defined $j;
        my $insn = $insns->[$j];
        next unless $insn->{mnemonic} =~ /^ldr(b|h|sb|sh|sw)$/ && $insn->{operands} =~ /\[x(\d+),\s*[xw](\d+)/;
        ($table_reg, $index_reg) = ($1, $2);
        my $kind = $insn->{mnemonic} =~ s/^ldr//r;
        $width = { b => 1, sb => 1, h => 2, sh => 2, sw => 4 }->{$kind};
        $signed = $kind =~ /^s/ ? 1 : 0;
        ($load, $loaded_reg) = ($j, $operand);
        last;
    }
    return undef unless defined $load;
    my $anchor_reg = $loaded_reg == $a ? $b : $a;
    # The base the entries are added to: an `adr` anchor, or the table itself.
    my $anchor;
    for my $j (grep { $_ < $add } @window) {
        my $insn = $insns->[$j];
        my @o = operands($insn->{operands});
        next unless grep { $_ == $anchor_reg } writes($insn->{mnemonic}, $insn->{operands});
        $anchor = hex $1 if $insn->{mnemonic} eq 'adr' && ($o[1] // '') =~ /0x([0-9a-f]+)/;
        last;
    }
    my $scale = 1 << $shift;
    my $fallback = { anchor => $anchor, span => defined $anchor ? ((1 << (8 * $width)) - 1) * $scale : undef };

    # The table's address: `adrp xT` and `add xT, xT, #off`, anywhere before the load (setup is hoisted out of loops).
    my ($page, $offset, $symbol, $add_index);
    for (my $j = $load - 1; $j >= 0; $j--) {
        my $insn = $insns->[$j];
        my @o = operands($insn->{operands});
        next unless grep { $_ == $table_reg } writes($insn->{mnemonic}, $insn->{operands});
        if (!defined $offset && $insn->{mnemonic} eq 'add' && @o >= 3 && (regnum($o[1]) // -1) == $table_reg && $o[2] =~ /^#(0x[0-9a-f]+|\d+)$/) {
            my $v = $1;
            $offset = $v =~ /^0x/ ? hex $v : $v;
            $add_index = $j;
            if (($insn->{reloc_kind} // '') eq 'ARM64_RELOC_PAGEOFF12') { $symbol = $insn->{reloc}; $offset += $insn->{addend} // 0 }
            next;
        }
        if ($insn->{mnemonic} eq 'adrp' && defined $offset && ($o[1] // '') =~ /0x([0-9a-f]+)/) {
            $page = hex $1;
            $symbol //= $insn->{reloc} if ($insn->{reloc_kind} // '') eq 'ARM64_RELOC_PAGE21';
        }
        last;   # any other write to xT ends the search
    }
    return { %$fallback, why => "its address wasn't found" } unless defined $offset && defined $page;
    my @tables = defined $symbol ? map { $_ + $offset } @{$addresses_of{$symbol} // []} : ($page + $offset);
    return { %$fallback, why => "no symbol $symbol" } unless @tables;

    # In a merged object a table's local name (lJTI0_0) has a copy per object: the relocation's own symbol picks it.
    if (defined $symbol && @tables > 1 && defined(my $copy = relocated_symbol($insns->[$add_index]{address}, $symbol))) {
        @tables = ($copy + $offset);
    }
    my ($bound, $bound_kind) = bound_count($insns, $load, $index_reg, $is_target);
    $bound_kind //= 'extent';
    my $why = "its address isn't in __const";
    my @read;
    for my $table (@tables) {
        # The table's extent: to the nearest symbol or address the code refers to after it (an object's table label,
        # lJTI0_1; the next table, wherever its function is), else to its section's end.
        my ($room, $bounded) = extent($table);
        next unless defined $room;
        my $fits = int($room / $width);
        my $count = $bound // $fits;
        if (defined $bound && $bound > $fits) {
            err(sprintf("warning: the jump table at 0x%x: its bounds check says %d entries, its extent %d; reading %d\n",
                $table, $bound, $fits, $fits)) if $bound_kind eq 'check' && $bounded;
            $count = $fits;
        }
        $why = 'it has no entries before its extent ends', next unless $count > 0;
        $count = 65536 if $count > 65536;
        my $base = defined $anchor ? $anchor : $table;
        my @targets;
        for my $e (0 .. $count - 1) {
            my $v = read_entry($table + $e * $width, $width, $signed, $function_start);
            last unless defined $v;
            push @targets, $base + $v * $scale;
        }
        # A table without a bounds check (Swift's exhaustive switches: a bound from the index's width, a ceiling, as a
        # 4-bit tag over 13 cases; or none) ends before the first entry that misses the function's instructions. When
        # nothing but its section's end bounds it either, the bytes after it (other constants) read as entries too: it
        # ends at the last entry that names a block only a table reaches (a constant naming the preheader, reached from
        # the entry, is no case; a case reached otherwise too, such as a shared `ret`, before that entry still is).
        if ($bound_kind ne 'check') {
            my ($end) = grep { !defined $index_at->{$targets[$_]} } 0 .. $#targets;
            if ($bound_kind eq 'width' || !$bounded) {
                splice @targets, $end if defined $end;
            }
            if (!$bounded) {
                my ($last) = reverse grep { my $k = $index_at->{$targets[$_]}; $plain->{leader}{$k} && !$plain->{reached}{$k} } 0 .. $#targets;
                @targets = defined $last ? @targets[0 .. $last] : ();
                $why = 'nothing bounds it, and no entry names a block only a table reaches', next unless @targets;
            }
        } else {
            $why = 'its entries could not be read', next unless @targets == $count;
        }
        $why = 'it has no entries', next unless @targets;
        # A candidate (one copy of a duplicated symbol in a merged object) whose entries miss this function is wrong.
        $why = 'an entry lands outside the function', next if grep { !defined $index_at->{$_} } @targets;
        push @read, [$table, \@targets];
    }
    if (@read > 1) {
        err(sprintf("warning: %d copies of %s fit the jump table of the br at 0x%x; using the one at 0x%x\n", scalar @read,
            $symbol // 'the table', $insns->[$i]{address}, $read[0][0]));
    }
    if (@read && $ENV{LOOPS_TABLES}) {   # for checks: what each table read gave
        err(sprintf("table: br 0x%x, table 0x%x, %s, %d cases: %s\n", $insns->[$i]{address}, $read[0][0], $bound_kind // 'extent',
            scalar @{$read[0][1]}, join(',', map { sprintf "%x", $_ } @{$read[0][1]})));
    }
    return { targets => $read[0][1] } if @read;
    return { %$fallback, why => $why, table => @tables == 1 ? $tables[0] : undef };
}

# The symbol table in its order (LOOPS_SYMBOLS, `nm -p -a`): [address, name] per entry, [undef, line] for an entry without
# an address. Read once.
my @symbols_by_index;
sub symbols_by_index {
    if (!@symbols_by_index && $ENV{LOOPS_SYMBOLS} && open my $f, '<', $ENV{LOOPS_SYMBOLS}) {
        while (<$f>) { chomp; push @symbols_by_index, /^([0-9a-f]+) ([A-Za-z]) (.+)$/ ? [hex $1, $3] : [undef, $_] }
    }
    return @symbols_by_index;
}

# The address of the copy of SYMBOL that the PAGEOFF12 relocation at text address ADDRESS names, from `otool -r`'s
# symbol numbers (LOOPS_RELOCS) and the symbol table's order (LOOPS_SYMBOLS, `nm -p -a`), or undef.
my (%reloc_symbol_at, @symbol_by_index, $relocs_loaded);
sub relocated_symbol {
    my ($address, $symbol) = @_;
    if (!$relocs_loaded++) {
        my %section_base;
        if (my $file = $ENV{LOOPS_SECTIONS}) {
            if (open my $f, '<', $file) {
                while (<$f>) { $section_base{$1} = hex $2 if /^\s*\d+\s+(\S+)\s+[0-9a-f]+\s+([0-9a-f]+)/ }
            }
        }
        if (my $file = $ENV{LOOPS_RELOCS}) {
            if (open my $f, '<', $file) {
                my $base;
                while (<$f>) {
                    if (/^Relocation information \(\w+,(\w+)\)/) { $base = $section_base{$1}; next }
                    # address pcrel length extern type scattered symbolnum: type 4 is ARM64_RELOC_PAGEOFF12.
                    next unless defined $base && /^([0-9a-f]+)\s+\d+\s+\d+\s+1\s+4\s+0\s+(\d+)/;
                    $reloc_symbol_at{$base + hex $1} = $2;
                }
            }
        }
    }
    @symbol_by_index = symbols_by_index() unless @symbol_by_index;
    my $index = $reloc_symbol_at{$address} // return undef;
    my $entry = $symbol_by_index[$index] // return undef;
    return defined $entry->[0] && $entry->[1] eq $symbol ? $entry->[0] : undef;
}

# The graph without jump tables (a `br` ends its path): its block starts, and the instructions the entry reaches.
sub plain_graph {
    my ($insns, $target) = @_;
    my (%leader, %reached);
    $leader{0} = 1;
    for my $i (0 .. $#$insns) {
        my $m = $insns->[$i]{mnemonic};
        next unless is_jump($m) || is_stop($m);
        $leader{$i + 1} = 1;
        $leader{$target->[$i]} = 1 if defined $target->[$i];
    }
    my @stack = (0);
    while (@stack) {
        my $i = pop @stack;
        while (defined $i && $i <= $#$insns && !$reached{$i}++) {
            my $m = $insns->[$i]{mnemonic};
            if (is_jump($m)) {
                push @stack, $target->[$i] if defined $target->[$i];
                $i = $m eq 'b' ? undef : $i + 1;
            } elsif (is_stop($m)) {
                $i = undef;
            } else {
                $i++;
            }
        }
    }
    return { leader => \%leader, reached => \%reached };
}

# Strongly connected components of the blocks in SET (a hash), edges restricted to SET (Tarjan's, iterative).
sub components {
    my ($set, $succ) = @_;
    my ($index, %idx, %low, %on, @stack, @result) = (0);
    for my $root (sort { $a <=> $b } keys %$set) {
        next if defined $idx{$root};
        my @work = ([$root, 0]);
        $idx{$root} = $low{$root} = $index++; push @stack, $root; $on{$root} = 1;
        while (@work) {
            my $frame = $work[-1];
            my ($v, $k) = @$frame;
            my @next = grep { $set->{$_} } @{$succ->[$v]};
            if ($k < @next) {
                $frame->[1]++;
                my $w = $next[$k];
                if (!defined $idx{$w}) {
                    $idx{$w} = $low{$w} = $index++; push @stack, $w; $on{$w} = 1;
                    push @work, [$w, 0];
                } elsif ($on{$w}) {
                    $low{$v} = $idx{$w} if $idx{$w} < $low{$v};
                }
                next;
            }
            pop @work;
            if (@work) { my $parent = $work[-1][0]; $low{$parent} = $low{$v} if $low{$v} < $low{$parent} }
            if ($low{$v} == $idx{$v}) {
                my (@c, $w);
                do { $w = pop @stack; $on{$w} = 0; push @c, $w } while ($w != $v);
                push @result, \@c;
            }
        }
    }
    return @result;
}

sub analyze {
    my ($name, $insns, $function_start) = @_;
    my @insns = @$insns;
    if (!@insns) {
        print "$name\n  no instructions\n" if $format eq 'text';
        return !$checking;
    }
    my %index_at = map { $insns[$_]{address} => $_ } 0 .. $#insns;

    # Each branch's target index inside the function, or undef when it leaves the function.
    my (@target, %is_target);
    for my $i (0 .. $#insns) {
        my $insn = $insns[$i];
        next unless is_jump($insn->{mnemonic});
        next if defined $insn->{reloc};
        next unless $insn->{operands} =~ /(?:^|[\s,])0x([0-9a-f]+)(?:\s*<[^>]*>)?\s*$/;
        $target[$i] = $index_at{hex $1};
        $is_target{$target[$i]} = 1 if defined $target[$i];
    }
    # Jump tables, read where possible. A width-bounded table's cases are checked against the graph without tables:
    # its block starts, and what the entry reaches (computed only when a `br` is there).
    my %table_of;
    my $plain;
    for my $i (0 .. $#insns) {
        next unless $insns[$i]{mnemonic} eq 'br';
        $plain //= plain_graph(\@insns, \@target);
        my $t = jump_table(\@insns, $i, \%index_at, \%is_target, $function_start, $plain);
        next unless $t;
        $t->{indexes} = [map { $index_at{$_} } @{$t->{targets}}] if $t->{targets};
        $table_of{$i} = $t;
    }

    # Basic blocks.
    my %leader = (0 => 1);
    for my $i (0 .. $#insns) {
        my $m = $insns[$i]{mnemonic};
        next unless is_jump($m) || is_stop($m);
        $leader{$i + 1} = 1 if $i < $#insns;
        $leader{$target[$i]} = 1 if defined $target[$i];
        if ($table_of{$i} && $table_of{$i}{indexes}) { $leader{$_} = 1 for @{$table_of{$i}{indexes}} }
    }
    my @starts = sort { $a <=> $b } keys %leader;
    my (@blocks, @block_of);
    for my $k (0 .. $#starts) {
        my $end = $k < $#starts ? $starts[$k + 1] - 1 : $#insns;
        push @blocks, [$starts[$k], $end];
        $block_of[$_] = $k for $starts[$k] .. $end;
    }
    my $count = @blocks;

    # Successors.
    my (@succ, @guessed);
    for my $k (0 .. $count - 1) {
        my ($first, $last) = @{$blocks[$k]};
        my $m = $insns[$last]{mnemonic};
        my %s;
        if (is_jump($m)) {
            $s{$block_of[$target[$last]]} = 1 if defined $target[$last];
            $s{$k + 1} = 1 if $m ne 'b' && $k + 1 < $count;
        } elsif ($m eq 'br' && $table_of{$last}) {
            my $t = $table_of{$last};
            if ($t->{indexes}) {
                $s{$block_of[$_]} = 1 for @{$t->{indexes}};
            } else {
                push @guessed, { block => $k, anchor => $t->{anchor}, span => $t->{span} };
                err(sprintf("warning: %s: the jump table %s couldn't be read (%s); its cases are placed by position: check them with --body\n",
                    $name, defined $t->{table} ? sprintf("at 0x%x (br at 0x%x)", $t->{table}, $insns[$last]{address})
                        : sprintf("of the br at 0x%x", $insns[$last]{address}), $t->{why}));
            }
        } elsif (!is_stop($m)) {
            $s{$k + 1} = 1 if $k + 1 < $count;
        }
        $succ[$k] = [sort { $a <=> $b } keys %s];
    }

    # Blocks nothing reaches from the entry: cases of tables that couldn't be read, else extra roots. Only blocks that
    # no other unreached block leads to are taken as cases (a loop body laid out before its header is reached through
    # the header), each by the nearest anchor below it within the entries' reach; the lowest first, then whatever it
    # reaches. When none is left, the lowest unreached block is taken.
    my @handled;
    my $mark = sub {
        my @stack = @_;
        while (@stack) {
            my $x = pop @stack;
            next if $handled[$x]++;
            push @stack, @{$succ[$x]};
        }
    };
    $mark->(0);
    my @roots = (0);
    while (1) {
        my @left = grep { !$handled[$_] } 0 .. $count - 1;
        last unless @left;
        my %unreached = map { $_ => 1 } @left;
        my %led;
        for my $x (@left) { $led{$_} = 1 for grep { $_ != $x } @{$succ[$x]} }
        my ($k) = grep { !$led{$_} } @left;
        $k //= $left[0];
        my $address = $insns[$blocks[$k][0]]{address};
        my ($table) = sort { $b->{anchor} <=> $a->{anchor} }
            grep { defined $_->{anchor} && $_->{anchor} <= $address && $address <= $_->{anchor} + $_->{span} } @guessed;
        ($table) = grep { !defined $_->{anchor} } @guessed unless $table;
        if ($table) { push @{$succ[$table->{block}]}, $k } else { push @roots, $k }
        $mark->($k);
    }

    # The virtual root ($count) leads to the entry and the extra roots.
    $succ[$count] = [@roots];
    my @pred;
    for my $k (0 .. $count) { push @{$pred[$_]}, $k for @{$succ[$k]} }

    # Dominators (Cooper, Harvey, and Kennedy's iterative algorithm over reverse postorder).
    my (@order, @visited);
    {
        my @stack = ([$count, 0]);
        $visited[$count] = 1;
        while (@stack) {
            my $frame = $stack[-1];
            my ($x, $k) = @$frame;
            if ($k < @{$succ[$x]}) {
                $frame->[1]++;
                my $y = $succ[$x][$k];
                next if $visited[$y]++;
                push @stack, [$y, 0];
            } else {
                push @order, $x;
                pop @stack;
            }
        }
    }
    @order = reverse @order;
    my @rpo;
    $rpo[$order[$_]] = $_ for 0 .. $#order;
    my @idom;
    $idom[$count] = $count;
    my $intersect = sub {
        my ($x, $y) = @_;
        while ($x != $y) {
            $x = $idom[$x] while $rpo[$x] > $rpo[$y];
            $y = $idom[$y] while $rpo[$y] > $rpo[$x];
        }
        return $x;
    };
    for (my $changed = 1; $changed;) {
        $changed = 0;
        for my $k (@order[1 .. $#order]) {
            my $new;
            for my $p (@{$pred[$k]}) {
                next unless defined $idom[$p];
                $new = defined $new ? $intersect->($p, $new) : $p;
            }
            if (!defined $idom[$k] || $idom[$k] != $new) { $idom[$k] = $new; $changed = 1 }
        }
    }
    my $dominates = sub {
        my ($h, $x) = @_;
        while (1) {
            return 1 if $x == $h;
            return 0 if $x == $count;
            $x = $idom[$x];
        }
    };

    # Natural loops: a back edge latch -> header where the header dominates the latch; the body is every block that
    # reaches the latch without passing the header; loops sharing a header merged.
    my %body;
    for my $latch (0 .. $count - 1) {
        next unless $visited[$latch];
        for my $h (@{$succ[$latch]}) {
            next unless $dominates->($h, $latch);
            my %in = ($h => 1);
            my @stack = ($latch);
            while (@stack) {
                my $x = pop @stack;
                next if $in{$x}++;
                push @stack, grep { $_ != $count } @{$pred[$x]};
            }
            $body{$h}{$_} = 1 for keys %in;
        }
    }
    my %natural = map { $_ => { blocks => [sort { $a <=> $b } keys %{$body{$_}}], headers => [$_], set => { %{$body{$_}} } } } keys %body;
    my @loops = map { $natural{$_} } sort { $a <=> $b } keys %natural;

    # Cycles no natural loop explains (entered at more than one block: irreducible): the strongly connected components
    # of the whole graph, of each natural loop without its header, and of each irreducible cycle without its entries.
    # A component is explained when it lies inside a natural loop whose header it holds.
    my %seen;
    my @work = ({ map { $_ => 1 } 0 .. $count - 1 });
    for my $h (sort { $a <=> $b } keys %body) { my %s = %{$body{$h}}; delete $s{$h}; push @work, \%s if %s }
    while (@work) {
        my $set = pop @work;
        for my $c (components($set, \@succ)) {
            next unless @$c > 1 || grep { $_ == $c->[0] } @{$succ[$c->[0]]};
            my %in = map { $_ => 1 } @$c;
            next if grep { my $h = $_; $in{$h} && !grep { !$body{$h}{$_} } @$c } keys %body;
            my $key = join ',', sort { $a <=> $b } @$c;
            next if $seen{$key}++;
            my @entries = sort { $a <=> $b } grep { my $block = $_; grep { !$in{$_} } @{$pred[$block]} } @$c;
            my %inner = %in;
            delete $inner{$_} for @entries;
            push @work, \%inner if %inner;
            # One shape is named for its natural loop: the cycle is a natural loop (the host) holding every natural loop
            # of the cycle, plus side blocks that hold no cycle of their own (a refill path laid out before the header,
            # also entered from before the loop; an outer loop whose preheader can be bypassed into the host's header).
            # It is reported as a `natural+side-entry` loop headed by the host's header, around the host, which keeps
            # its own row: an innermost loop never grows. The host is the largest natural loop headed in the cycle
            # (ties to the lowest header). Two conditions an earlier version also tested always hold, as dominance
            # gives (and 9,000 random graphs confirmed): the host's body lies in the cycle, and side blocks re-enter
            # the host only at its header.
            my @hosted = sort { keys %{$body{$b}} <=> keys %{$body{$a}} || $a <=> $b }
                grep { $in{$_} } sort { $a <=> $b } keys %body;
            my $host = $hosted[0];
            my $named = defined $host && !grep { !$body{$host}{$_} } @hosted;   # every natural loop inside the host
            my @side = $named ? grep { !$body{$host}{$_} } @$c : ();
            if ($named) {
                my %side = map { $_ => 1 } @side;
                # Acyclic: no component of more than one block, and no block branching to itself.
                $named = !grep { @$_ > 1 } components(\%side, \@succ);
                $named &&= !grep { my $x = $_; grep { $_ == $x } @{$succ[$x]} } @side;
            }
            if ($named) {
                # The side blocks entered from outside the cycle (from before the loop).
                my @entered = grep { my $x = $_; grep { !$in{$_} } @{$pred[$x]} } @side;
                push @loops, { blocks => [sort { $a <=> $b } @$c], headers => [$host], set => \%in, side => \@entered };
                next;
            }
            push @loops, { blocks => [sort { $a <=> $b } @$c], headers => \@entries, set => \%in, irreducible => 1 };
        }
    }
    # Nesting by containment: depth counts the loops holding all of a loop's blocks and more.
    my $inside = sub { my ($small, $big) = @_; @{$small->{blocks}} < @{$big->{blocks}} && !grep { !$big->{set}{$_} } @{$small->{blocks}} };
    for my $loop (@loops) {
        $loop->{depth} = grep { $_ != $loop && $inside->($loop, $_) } @loops;
        $loop->{children} = grep { $_ != $loop && $inside->($_, $loop) } @loops;
        $loop->{indexes} = [map { $blocks[$_][0] .. $blocks[$_][1] } @{$loop->{blocks}}];
    }
    @loops = sort { $a->{indexes}[0] <=> $b->{indexes}[0] || @{$b->{indexes}} <=> @{$a->{indexes}}
        || $a->{headers}[0] <=> $b->{headers}[0] || ($a->{irreducible} // 0) <=> ($b->{irreducible} // 0) } @loops;

    print "$name\n" if $format eq 'text';
    print "  no loops\n" if $format eq 'text' && !@loops;
    my $satisfied = 0;
    my $number = 0;
    for my $loop (@loops) {
        $number++;
        my $innermost = !$loop->{children};
        my $irreducible = $loop->{irreducible};
        my @side = map { $insns[$blocks[$_][0]]{address} } sort { $a <=> $b } @{$loop->{side} // []};
        my $kind = $irreducible ? 'irreducible' : $loop->{side} ? 'natural+side-entry' : 'natural';
        my @indexes = @{$loop->{indexes}};
        my (%mix, $v128, $v64, $lane, $calls);
        $v128 = $v64 = $lane = $calls = 0;
        for my $insn (@insns[@indexes]) {
            my ($m, $o) = ($insn->{mnemonic}, $insn->{operands});
            $mix{$m}++;
            my $base = $m =~ s/\..*//r;
            # Vector width: Apple syntax puts the arrangement on the mnemonic (`add.16b`), LLVM's on the registers
            # (`v0.16b`); q registers in loads and stores are 128-bit.
            if ($m =~ /\.(16b|8h|4s|2d|1q)$/ || $o =~ /\bv\d+\.(16b|8h|4s|2d|1q)\b/ || ($base =~ /^(ld|st)/ && $o =~ /\bq\d+\b/)) { $v128++ }
            elsif ($m =~ /\.(8b|4h|2s|1d)$/ || $o =~ /\bv\d+\.(8b|4h|2s|1d)\b/) { $v64++ }
            # One lane to or from a general-purpose register: `mov.b v3[2], w12`, `ins`, `umov`, `smov`.
            $lane++ if $base =~ /^(mov|ins|umov|smov)$/ && $o =~ /\bv\d+(\.\w+)?\[\d+\]/ && $o =~ /\b[wx]\d+\b/;
            $calls++ if $base =~ /^(bl|blr|blraa|blrab|blraaz|blrabz)$/;
        }
        my $verdict = $v128 ? 'vector128' : $v64 ? 'vector64' : 'scalar';
        $verdict .= '+lane-moves' if $lane;
        $verdict .= '+calls' if $calls;
        my $mix = join ', ', map { "$mix{$_} $_" } sort { $mix{$b} <=> $mix{$a} || $a cmp $b } keys %mix;

        # Contiguous runs of the loop's blocks, as [first index, last index].
        my @runs;
        for my $k (@{$loop->{blocks}}) {
            my ($first, $last) = @{$blocks[$k]};
            if (@runs && $runs[-1][1] + 1 == $first) { $runs[-1][1] = $last } else { push @runs, [$first, $last] }
        }
        my $runs = join ',', map { sprintf "%x-%x", $insns[$_->[0]]{address}, $insns[$_->[1]]{address} } @runs;
        my ($from, $to) = ($insns[$indexes[0]]{address}, $insns[$indexes[-1]]{address});
        my @header_indexes = map { $blocks[$_][0] } @{$loop->{headers}};
        my @headers = map { $insns[$_]{address} } @header_indexes;
        my %is_header = map { $_ => 1 } @header_indexes;
        my %is_side = map { $blocks[$_][0] => 1 } @{$loop->{side} // []};

        if ($innermost && $checking) {
            # An op names a mnemonic, optionally without its numeric or lane suffix: `zip` matches `zip1.16b`, `tbl`
            # matches `tbl.16b`, `ld3.16b` only itself, and `bl` matches `bl` but not `tbl` or `blr`.
            my @mnemonics = map { $_->{mnemonic} } @insns[@indexes];
            my $present = sub { my $op = shift; scalar grep { /^\Q$op\E(?:$|[.\d])/ } @mnemonics };
            my $ok = !grep { !$present->($_) } keys %require;
            $ok &&= !grep { $present->($_) } keys %forbid;
            $satisfied ||= $ok;
        }

        if ($format eq 'tsv') {
            print join("\t", $name, "loop$number", sprintf("%x", $from), sprintf("%x", $to), scalar @indexes, $loop->{depth},
                $innermost ? 'innermost' : 'outer', $verdict, $mix, join(',', map { sprintf "%x", $_ } @headers), $runs,
                $kind), "\n";
            next;
        }
        printf "  loop %d  0x%x–0x%x  %d instructions  depth %d%s  %s%s\n", $number, $from, $to, scalar @indexes, $loop->{depth},
            $innermost ? ' (innermost)' : '', $verdict, $irreducible ? '  irreducible' : '';
        my $header_text = $irreducible ? 'entries ' . join(', ', map { sprintf "0x%x", $_ } @headers) : sprintf 'header 0x%x', $headers[0];
        $header_text .= '; also entered at ' . join(', ', map { sprintf "0x%x", $_ } @side) . ' (a side path back to the header)' if @side;
        if (@runs > 1) {
            printf "    %s; %d pieces: %s\n", $header_text, scalar @runs, join(', ', map {
                sprintf "0x%x–0x%x", $insns[$_->[0]]{address}, $insns[$_->[1]]{address} } @runs);
        } elsif ($irreducible || @side || $headers[0] != $from) {
            print "    $header_text\n";
        }
        print "    $mix\n";
        next unless $ENV{BODY};
        for my $r (0 .. $#runs) {
            if ($r > 0) {
                my ($gap_first, $gap_last) = ($runs[$r - 1][1] + 1, $runs[$r][0] - 1);
                printf "      … 0x%x–0x%x: %d instructions not in this loop\n", $insns[$gap_first]{address},
                    $insns[$gap_last]{address}, $gap_last - $gap_first + 1;
            }
            for my $i ($runs[$r][0] .. $runs[$r][1]) {
                my $insn = $insns[$i];
                my $operands = $insn->{operands};
                $operands .= "  ; $insn->{reloc}" if defined $insn->{reloc};
                printf "      %x: %s\t%s%s\n", $insn->{address}, $insn->{mnemonic}, $operands,
                    $is_header{$i} ? ($irreducible ? '   <- entry' : '   <- header') : $is_side{$i} ? '   <- side entry' : '';
            }
        }
    }

    if ($checking) {
        err(($satisfied ? "ok" : "FAIL") . ": $name: require [" . join(',', sort keys %require) . "] forbid ["
            . join(',', sort keys %forbid) . "] in an innermost loop\n");
    }
    return $satisfied || !$checking;
}
