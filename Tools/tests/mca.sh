#!/bin/bash
# Tools/mca on hand-written ARM64 loops: llvm-mca gets every block of the loop (a cold call laid out after the return
# included), its warnings reach stderr, calls in the loop are warned about, --loop is validated, and several
# matching functions are named. Skipped (passing) without Homebrew's LLVM.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../lib/common.sh" || exit 2
set +e
mca="$here/../mca"
llvm_bin > /dev/null || { echo "skipped: no Homebrew LLVM (brew install llvm)"; exit 0; }
work="$(mktemp -d "${TMPDIR:-/tmp}/check-mca.XXXXXX")"
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

cat > "$work/cases.s" <<'EOF'
    .text
    .p2align 2
// One loop of 7 instructions in two pieces: the call is laid out after the return.
    .globl _cold_call2
_cold_call2:
    mov x1, #0
Lcc_head:
    ldr x2, [x0], #8
    cbz x2, Lcc_cold
Lcc_cont:
    add x1, x1, x2
    subs x3, x3, #1
    b.ne Lcc_head
    mov x0, x1
    ret
Lcc_cold:
    bl _external_helper
    b Lcc_cont

// A table loop with no calls.
    .globl _table_loop
_table_loop:
    mov x3, #0
Ltl_head:
    adrp x8, _table@PAGE
    ldr q1, [x8, _table@PAGEOFF]
    ldr q0, [x0], #16
    tbl v2.16b, {v1.16b}, v0.16b
    str q2, [x1], #16
    subs x2, x2, #1
    b.ne Ltl_head
    ret

    .section __TEXT,__const
    .p2align 4
_table:
    .quad 0x0706050403020100, 0x0f0e0d0c0b0a0908
EOF
xcrun clang -c -arch arm64 -o "$work/cases.o" "$work/cases.s" || { echo "FAIL: couldn't assemble the cases"; exit 1; }

"$mca" "$work/cases.o" '^_cold_call2$' --full > "$work/full" 2> "$work/full.err"
check "cold call: every block reaches llvm-mca (7 x 500)" "$(perl -ne 'print $1 if /^Instructions:\s+(\d+)/' "$work/full")" 3500
"$mca" "$work/cases.o" '^_cold_call2$' > "$work/out" 2> "$work/err"
check "cold call: status" "$?" 0
grep -q 'in 2 pieces' "$work/out"
check "cold call: two pieces named" "$?" 0
grep -q 'warning: the loop holds 1 bl' "$work/err"
check "cold call: the call is warned about" "$?" 0
grep -q 'found a call in the input assembly sequence' "$work/err"
check "cold call: llvm-mca's warning forwarded" "$?" 0

"$mca" "$work/cases.o" '^_table_loop$' > "$work/out" 2> "$work/err"
check "table loop: status" "$?" 0
check "table loop: no warnings" "$(grep -c warning "$work/err")" 0
"$mca" "$work/cases.o" '^_table_loop$' --bottleneck > "$work/out" 2> /dev/null
grep -q '^  bottleneck analysis:' "$work/out"
check "--bottleneck adds the analysis" "$?" 0

"$mca" "$work/cases.o" '_(cold_call2|table_loop)$' > /dev/null 2> "$work/err"
grep -q 'warning: 2 functions match' "$work/err"
check "several matches warned about" "$?" 0

# Loops past 32 KiB and 1 MiB: their branch targets, printed as absolute addresses, are out of llvm-mca's reach
# unless rewritten.
for pad in 0x9000 0x110000; do
    printf '    .text\n    .p2align 2\n    .globl _pad\n_pad:\n    ret\n    .space %s\n    .globl _loop\n_loop:\n    adr x9, _loop\n    ldr x2, [x0], #8\n    tbz x2, #3, Lskip\n    eor x1, x1, x2\nLskip:\n    subs x3, x3, #1\n    b.ne _loop\n    ret\n' "$pad" > "$work/far.s"
    xcrun clang -c -arch arm64 -o "$work/far.o" "$work/far.s" || { echo "FAIL: couldn't assemble far.s"; exit 1; }
    "$mca" "$work/far.o" '^_loop$' > "$work/out" 2> "$work/err"
    check "loop past $pad: status" "$?" 0
    check "loop past $pad: a throughput" "$(grep -c 'Block RThroughput' "$work/out")" 1
done

# A linked binary: addresses above 0x100000000, a call through a stub.
cat > "$work/linked.c" <<'EOF'
#include <stdio.h>
__attribute__((noinline)) long sum_print(const long *p, long n) {
    long s = 0;
    for (long i = 0; i < n; i++) {
        s += p[i];
        if (__builtin_expect(p[i] == 42, 0)) puts("forty-two");
    }
    return s;
}
int main(int argc, char **argv) { long a[4] = { argc, 2, 3, 4 }; return (int)sum_print(a, argc); }
EOF
xcrun clang -O2 -o "$work/linked" "$work/linked.c" || { echo "FAIL: couldn't link linked.c"; exit 1; }
"$mca" "$work/linked" '^_sum_print$' > "$work/out" 2> "$work/err"
check "linked: status" "$?" 0
check "linked: a throughput" "$(grep -c 'Block RThroughput' "$work/out")" 1
check "linked: no Perl warnings" "$(grep -c 'non-portable' "$work/err")" 0

# An irreducible loop: its entries named, each address formatted.
printf '    .text\n    .p2align 2\n    .globl _irreducible\n_irreducible:\n    cbz x0, Lir_b\nLir_a:\n    add x1, x1, #1\n    subs x2, x2, #1\n    b.eq Lir_done\nLir_b:\n    eor x1, x1, x2\n    subs x3, x3, #1\n    b.ne Lir_a\nLir_done:\n    mov x0, x1\n    ret\n' > "$work/irr.s"
xcrun clang -c -arch arm64 -o "$work/irr.o" "$work/irr.s" || { echo "FAIL: couldn't assemble irr.s"; exit 1; }
"$mca" "$work/irr.o" '^_irreducible$' > "$work/out" 2> /dev/null
check "irreducible: entries formatted" "$(grep -c '(entries 0x4, 0x10)' "$work/out")" 1

# One local name in two merged objects: the copy used is named.
printf 'static long helper(const long *p, long n) { long s = 0; for (long i = 0; i < n; i++) s ^= p[i] * 3; return s; }\n__attribute__((noinline)) long first(const long *p, long n) { return helper(p, n); }\n' > "$work/a.c"
printf 'static long helper(const long *p, long n) { long s = 1; for (long i = 0; i < n; i++) s += p[i] * 7; return s; }\n__attribute__((noinline)) long second(const long *p, long n) { return helper(p, n); }\n' > "$work/b.c"
xcrun clang -O1 -fno-inline -c -o "$work/a.o" "$work/a.c" || exit 1
xcrun clang -O1 -fno-inline -c -o "$work/b.o" "$work/b.c" || exit 1
xcrun ld -r -arch arm64 -o "$work/merged.o" "$work/a.o" "$work/b.o" 2> /dev/null || { echo "FAIL: ld -r"; exit 1; }
"$mca" "$work/merged.o" '^_helper$' > /dev/null 2> "$work/err"
grep -q 'note: _helper is defined 2 times (merged objects); using the copy at 0x' "$work/err"
check "two copies: the one used is named" "$?" 0

"$mca" "$work/cases.o" '^_table_loop$' --loop abc > /dev/null 2>&1
check "--loop abc" "$?" 2
"$mca" "$work/cases.o" '^_table_loop$' --loop > /dev/null 2>&1
check "--loop without a value" "$?" 2
"$mca" "$work/cases.o" '^_table_loop$' --loop 9 > /dev/null 2>&1
check "--loop 9 (no such loop)" "$?" 1
# Tools/loops failing after it has listed the match (objdump failing with E2BIG: a 60,000-byte name listed beside a
# 1,000,000-byte environment): its status and message, not "no loops".
perl -e 'my $name = "_wide" . "x" x 60000; print "    .text\n    .p2align 2\n    .globl $name\n$name:\nLw:\n    subs x3, x3, #1\n    b.ne Lw\n    ret\n"' > "$work/wide.s"
xcrun clang -c -arch arm64 -o "$work/wide.o" "$work/wide.s" || { echo "FAIL: couldn't assemble wide.s"; exit 1; }
BIG_ENVIRONMENT="$(perl -e 'print "y" x 1000000')" LOOPS_LIST_MAX=9999999 "$mca" "$work/wide.o" '^_wide' > /dev/null 2> "$work/err"
check "Tools/loops failing after listing the match: its exit 2 and its message" \
    "$? $(grep -c 'disassembly ended early' "$work/err") $(grep -c 'no loops' "$work/err")" "2 1 0"

# Many matches (15, the first without a loop; later ones with): the first is used ("no loops in" it, exit 1, never a
# later one's loop), 10 others are named, then the rest counted, and nothing stops early (no exit 141).
{
    printf '    .text\n    .p2align 2\n    .globl _m00\n_m00:\n    ret\n'
    for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
        printf '    .globl _m%s\n_m%s:\n    mov x1, #0\nLm%s:\n    ldr x2, [x0], #8\n    eor x1, x1, x2\n    subs x3, x3, #1\n    b.ne Lm%s\n    ret\n' "$i" "$i" "$i" "$i"
    done
} > "$work/many.s"
xcrun clang -c -arch arm64 -o "$work/many.o" "$work/many.s" || exit 1
"$mca" "$work/many.o" '^_m' > "$work/out" 2> "$work/err"
check "15 matches, the first without a loop: exit 1, no loop of another" "$? $(grep -c . "$work/out")" "1 0"
check "15 matches: the first said to have no loops" "$(grep -c '^FAIL: no loops in _m00$' "$work/err")" 1
check "15 matches: 10 others named, 4 more counted" "$(grep -c '^  _m' "$work/err") $(grep -c '^  … and 4 more$' "$work/err")" "10 1"
"$mca" "$work/many.o" '^_m(0[1-9]|1)' > "$work/out" 2> /dev/null
check "14 matches with loops: the first's" "$? $(grep -c '^_m01: loop1 at' "$work/out")" "0 1"

# Iterations scaled to the loop: 50,000 instructions in all for a loop of 250.
perl -e 'print "    .text\n    .p2align 2\n    .globl _big\n_big:\nLbig:\n"; print "    add x6, x6, #", $_ % 7 + 1, "\n" for 1 .. 248; print "    subs x3, x3, #1\n    b.ne Lbig\n    ret\n"' > "$work/big.s"
xcrun clang -c -arch arm64 -o "$work/big.o" "$work/big.s" || exit 1
"$mca" "$work/big.o" '^_big$' --full > "$work/full" 2> /dev/null
check "a loop of 250 instructions: 200 iterations" "$(perl -ne 'print $1 if /^Iterations:\s+(\d+)/' "$work/full")" 200
# And at least 50: a loop of 2,000 instructions.
perl -e 'print "    .text\n    .p2align 2\n    .globl _huge\n_huge:\nLhuge:\n"; print "    add x6, x6, #", $_ % 7 + 1, "\n" for 1 .. 1998; print "    subs x3, x3, #1\n    b.ne Lhuge\n    ret\n"' > "$work/huge.s"
xcrun clang -c -arch arm64 -o "$work/huge.o" "$work/huge.s" || exit 1
"$mca" "$work/huge.o" '^_huge$' --full > "$work/full" 2> /dev/null
check "a loop of 2,000 instructions: 50 iterations" "$(perl -ne 'print $1 if /^Iterations:\s+(\d+)/' "$work/full")" 50

# TERM to mca's own bash while Tools/loops runs for it (listing 200,000 symbols), and while llvm-mca runs (a loop of
# 20,000): stopped at once (exit 143), nothing printed, none of its processes left, its scratch removed.
term_check() { # term_check LABEL FILE PATTERN PROCESS: TERM once a process of the tool's matching PROCESS runs
    rm -rf "$work/tt"
    mkdir "$work/tt"
    # In a process group of its own, so what it started can be found after it exits (orphans keep the group).
    TMPDIR="$work/tt" perl -e 'setpgrp(0, 0); exec @ARGV' "$mca" "$2" "$3" > "$work/tt.out" 2>&1 &
    local tool=$! t0 rc
    perl -MTime::HiRes=sleep -e 'my ($group, $what) = @ARGV; for (1 .. 1000) { exit 0 if grep { /^\s*$group\s+.*$what/ } `ps -ww -A -o pgid=,command=`; sleep 0.01 } exit 1' "$tool" "$4"
    t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
    kill -TERM "$tool"
    wait "$tool"
    rc=$?
    check "TERM $1: exit 143 within a second, no throughput printed, its processes gone, scratch removed" \
        "$rc $(perl -MTime::HiRes=time -e "print time - $t0 < 1 ? 'quick' : 'slow'") $(grep -c RThroughput "$work/tt.out") $(ps -A -o pgid=,stat= | perl -ane 'BEGIN { $g = shift } $n++ if $F[0] == $g && $F[1] !~ /^Z/; END { print $n // 0 }' "$tool") $(perl -e 'opendir my $d, shift or die; print scalar grep { !/^\.\.?$/ } readdir $d' "$work/tt")" \
        "143 quick 0 0 0"
}
perl -e 'print "    .text\n    .p2align 2\n"; printf "    .globl _\$s4main4f%06dyyF\n_\$s4main4f%06dyyF:\n    ret\n", $_, $_ for 0 .. 199999' > "$work/symbols200k.s"
xcrun clang -c -arch arm64 -o "$work/symbols200k.o" "$work/symbols200k.s" || exit 1
term_check "while Tools/loops runs (demangling 200,000 names)" "$work/symbols200k.o" f000001 swift-demangle
perl -e 'print "    .text\n    .p2align 2\n    .globl _giant\n_giant:\nLgiant:\n"; print "    add x6, x6, #", $_ % 7 + 1, "\n" for 1 .. 19998; print "    subs x3, x3, #1\n    b.ne Lgiant\n    ret\n"' > "$work/giant.s"
xcrun clang -c -arch arm64 -o "$work/giant.o" "$work/giant.s" || exit 1
term_check "while llvm-mca runs" "$work/giant.o" '^_giant$' 'llvm-mca'
