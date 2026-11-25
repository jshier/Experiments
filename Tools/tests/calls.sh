#!/bin/bash
# Tools/calls on small C programs with known call sites, as an object and linked: direct calls, indirect calls
# (`blr`), a tail call, a `switch`'s jump table (`br`), exit 1 when --callee matches nothing, and a note for a name
# defined in two merged objects.
here="$(cd "$(dirname "$0")" && pwd)"
calls="$here/../calls"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-calls.XXXXXX")"
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

# probe_caller: 1 call to local_helper, 2 to puts, 2 indirect calls through a pointer, a tail call to free.
cat > "$work/probe.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>

__attribute__((noinline)) int local_helper(int x) { return x * 3 + 1; }

__attribute__((noinline)) void probe_caller(int (*fp)(int), int x, void *p) {
    x = local_helper(x);
    puts("hi");
    x = fp(x);
    x = fp(x);
    if (x == 7) puts("seven");
    free(p);
}

int main(int argc, char **argv) {
    probe_caller(local_helper, argc, malloc(8));
    return 0;
}
EOF
xcrun clang -O2 -c -o "$work/probe.o" "$work/probe.c" || { echo "FAIL: couldn't compile probe.c"; exit 1; }
xcrun clang -O2 -o "$work/probe" "$work/probe.c" || { echo "FAIL: couldn't link probe"; exit 1; }
want="$(printf '_probe_caller\tcall\t2\t(indirect)\n_probe_caller\tcall\t2\t_puts\n_probe_caller\tcall\t1\t_local_helper\n_probe_caller\ttail\t1\t_free')"
check "object: every call site" "$("$calls" "$work/probe.o" '^_probe_caller$' 2> /dev/null)" "$want"
check "binary: every call site" "$("$calls" "$work/probe" '^_probe_caller$' 2> /dev/null)" "$want"
"$calls" "$work/probe.o" '^_probe_caller$' --callee 'swift_retain' > /dev/null 2>&1
check "--callee matching nothing" "$?" 1
"$calls" "$work/probe.o" '^_probe_caller$' --callee > /dev/null 2>&1
check "--callee without a value" "$?" 2

# A jump table inside a loop, as LLVM lays out a switch.
cat > "$work/switch.s" <<'EOF'
    .text
    .p2align 2
    .globl _switch_loop
_switch_loop:
    adrp x10, Ljt@PAGE
    add x10, x10, Ljt@PAGEOFF
Lsw_head:
    ldrb w12, [x9], #1
    cmp w12, #1
    b.hi Lsw_done
    adr x13, Lsw_case0
    ldrb w14, [x10, x12]
    add x13, x13, x14, lsl #2
    br x13
Lsw_case0:
    add x1, x1, #3
    b Lsw_head
Lsw_case1:
    eor x1, x1, x2
    b Lsw_head
Lsw_done:
    ldr x16, [x0]
    br x16

// A byte table entry added into x8, then x8 overwritten by a pointer load: the br is an indirect tail call.
    .globl _byte_then_pointer
_byte_then_pointer:
    ldrb w9, [x0, x1]
    add x8, x2, x9
    ldr x8, [x8]
    br x8

// An indirect tail call through a witness-table slot picked by a register offset: no jump table.
    .globl _witness_tail
_witness_tail:
    tst w0, #0xff
    mov w9, #0x48
    mov w10, #0x50
    csel x9, x10, x9, eq
    ldr x3, [x2, x9]
    mov x0, x1
    br x3

    .section __TEXT,__const
Ljt:
    .byte 0
    .byte (Lsw_case1 - Lsw_case0) >> 2
EOF
xcrun clang -c -arch arm64 -o "$work/switch.o" "$work/switch.s" || { echo "FAIL: couldn't assemble switch.s"; exit 1; }
want="$(printf '_switch_loop\tjump\t1\t(indirect)\n_switch_loop\tjump\t1\t(jump table)')"
check "jump table and indirect tail call" "$("$calls" "$work/switch.o" '^_switch_loop$' 2> /dev/null)" "$want"
check "a table entry overwritten before the br is no jump table" "$("$calls" "$work/switch.o" '^_byte_then_pointer$' 2> /dev/null)" "$(printf '_byte_then_pointer\tjump\t1\t(indirect)')"
check "a witness slot is no jump table" "$("$calls" "$work/switch.o" '^_witness_tail$' 2> /dev/null)" "$(printf '_witness_tail\tjump\t1\t(indirect)')"

# The same local name in two objects merged with ld -r.
printf '__attribute__((noinline)) static int helper(int x) { return x * 5; }\nint first(int x) { return helper(x) + 1; }\n' > "$work/a.c"
printf '__attribute__((noinline)) static int helper(int x) { return x * 7; }\nint second(int x) { return helper(x) + 2; }\n' > "$work/b.c"
xcrun clang -O2 -c -o "$work/a.o" "$work/a.c" || exit 1
xcrun clang -O2 -c -o "$work/b.o" "$work/b.c" || exit 1
xcrun ld -r -arch arm64 -o "$work/merged.o" "$work/a.o" "$work/b.o" 2> /dev/null || { echo "FAIL: ld -r"; exit 1; }
"$calls" "$work/merged.o" '^_(first|second)$' > /dev/null 2> "$work/err"
check "unique names: no note" "$(grep -c '^note:' "$work/err")" 0
"$calls" "$work/merged.o" '^_helper$' > /dev/null 2> "$work/err"
grep -q '^note: _helper is defined 2 times' "$work/err"
check "a name defined twice: noted" "$?" 0

# A linked binary: a static helper defined in two objects (each copy counted), and an alias at a function's address
# (counted like the function).
printf 'int ext_a(int);\n__attribute__((noinline)) static int helper(int x) { return ext_a(x) * 5; }\nint first(int x) { return helper(x) + 1; }\n' > "$work/la.c"
printf 'int ext_b(int);\n__attribute__((noinline)) static int helper(int x) { return ext_b(x) * 7; }\nint second(int x) { return helper(x) + 2; }\n' > "$work/lb.c"
printf 'int first(int), second(int);\nint ext_a(int x) { return x; }\nint ext_b(int x) { return x + 1; }\nint main(int c, char **v) { return first(c) + second(c); }\n' > "$work/lmain.c"
printf '    .text\n    .p2align 2\n    .globl _alias0\n_alias0:\n    .globl _f0\n_f0:\n    stp x29, x30, [sp, #-16]!\n    bl _ext_a\n    bl _ext_b\n    ldp x29, x30, [sp], #16\n    ret\n' > "$work/alias.s"
xcrun clang -O2 -o "$work/linked2" "$work/la.c" "$work/lb.c" "$work/lmain.c" "$work/alias.s" || { echo "FAIL: couldn't link"; exit 1; }
"$calls" "$work/linked2" '^_helper$' > "$work/out" 2> "$work/err"
check "linked, a static name twice: both copies counted" "$(tr '\t\n' ' /' < "$work/out")" "_helper call 1 _ext_a/_helper call 1 _ext_b/"
check "linked, a static name twice: noted" "$(grep -c '^note: _helper is defined 2 times' "$work/err")" 1
check "linked, an alias: counted like its function" "$("$calls" "$work/linked2" '^_(alias0|f0)$' 2> /dev/null | tr '\t\n' ' /')" \
    "_alias0 call 1 _ext_a/_alias0 call 1 _ext_b/_f0 call 1 _ext_a/_f0 call 1 _ext_b/"

# Aliases, the matches listed for objdump and the whole file disassembled (CALLS_LIST_MAX=0): the same rows.
{
    printf '    .text\n    .p2align 2\n'
    for i in $(seq 0 69); do
        [[ $i == 0 || $i == 30 ]] && printf '    .globl _alias%s\n_alias%s:\n' "$i" "$i"
        printf '    .globl _f%s\n_f%s:\n    stp x29, x30, [sp, #-16]!\n    bl _ext%s\n    ldp x29, x30, [sp], #16\n    ret\n' "$i" "$i" "$i"
    done
} > "$work/many.s"
xcrun clang -c -arch arm64 -o "$work/many.o" "$work/many.s" || exit 1
"$calls" "$work/many.o" '^_(f([0-5]?[0-9]|6[01])|alias(0|30))$' > "$work/p64" 2> /dev/null
CALLS_LIST_MAX=0 "$calls" "$work/many.o" '^_(f([0-5]?[0-9]|6[01])|alias(0|30))$' > "$work/p65" 2> /dev/null
check "listed and whole: the same rows" "$(shasum < "$work/p65")" "$(shasum < "$work/p64")"
check "listed: the aliases counted" "$(grep -c -E '^_alias(0|30)	call	1	_ext(0|30)$' "$work/p64")" 2

# Callees whose names hold spaces (Objective-C methods), in an object (relocations) and linked: named whole.
cat > "$work/spaces.s" <<'EOS'
    .text
    .p2align 2
    .globl _caller
_caller:
    stp x29, x30, [sp, #-16]!
    bl "-[Foo bar:baz:]"
    bl "-[Foo bar:baz:]"
    bl "_weird name"
    ldp x29, x30, [sp], #16
    ret
    .globl "-[Foo bar:baz:]"
"-[Foo bar:baz:]":
    ret
    .globl "_weird name"
"_weird name":
    ret
    .globl _main
_main:
    b _caller
    .subsections_via_symbols
EOS
xcrun clang -c -arch arm64 -o "$work/spaces.o" "$work/spaces.s" || exit 1
xcrun clang -arch arm64 -o "$work/spaces" "$work/spaces.s" || exit 1
want="$(printf '_caller\tcall\t2\t-[Foo bar:baz:]\n_caller\tcall\t1\t_weird name')"
check "object: a callee's name with spaces, whole" "$("$calls" "$work/spaces.o" '^_caller$' 2> /dev/null)" "$want"
check "linked: a callee's name with spaces, whole" "$("$calls" "$work/spaces" '^_caller$' 2> /dev/null)" "$want"
check "a caller's name with spaces, starting with -" "$("$calls" "$work/spaces.o" '^-\[Foo' 2>&1; echo "exit $?")" "$(printf 'no calls in the matching functions\nexit 1')"

# A call to an address with two names (an alias): the lowest name, whichever nm lists first.
printf '    .text\n    .p2align 2\n    .globl _zz_target\n_zz_target:\n    .globl _aa_alias\n_aa_alias:\n    ret\n    .globl _caller\n_caller:\n    stp x29, x30, [sp, #-16]!\n    bl _zz_target\n    ldp x29, x30, [sp], #16\n    ret\n    .globl _main\n_main:\n    b _caller\n' > "$work/alias2.s"
xcrun clang -arch arm64 -o "$work/alias2" "$work/alias2.s" || exit 1
check "linked, a call to an aliased address: the lowest name" "$("$calls" "$work/alias2" '^_caller$' 2> /dev/null)" "$(printf '_caller\tcall\t1\t_aa_alias')"

# An object's branch back to its function's start (a local label: no relocation) is a loop, no tail call.
printf '    .text\n    .p2align 2\n    .globl _selfloop\n_selfloop:\nLstart:\n    subs x0, x0, #1\n    b.eq Ldone\n    b Lstart\nLdone:\n    ret\n' > "$work/selfloop.s"
xcrun clang -c -arch arm64 -o "$work/selfloop.o" "$work/selfloop.s" || exit 1
check "object: a branch to the function's own start is no tail call" "$("$calls" "$work/selfloop.o" '^_selfloop$' 2> /dev/null; echo "exit $?")" "exit 1"

# A universal binary is read for its arm64 slice; an x86_64 file is refused; a stripped one (strip -x) warned about.
xcrun clang -O2 -arch arm64 -arch x86_64 -o "$work/fat" "$work/probe.c" || { echo "FAIL: couldn't link a universal binary"; exit 1; }
xcrun lipo -thin x86_64 -output "$work/x86" "$work/fat" || exit 1
check "universal: as the arm64 slice" "$("$calls" "$work/fat" '^_probe_caller$' 2> /dev/null)" "$("$calls" "$work/probe" '^_probe_caller$' 2> /dev/null)"
"$calls" "$work/x86" '^_probe_caller$' > /dev/null 2> "$work/err"
check "x86_64: refused" "$? $(grep -c "isn't arm64 code (x86_64)" "$work/err")" "2 1"
xcrun ar rcs "$work/probe.a" "$work/probe.o" 2> /dev/null || { echo "FAIL: ar"; exit 1; }
"$calls" "$work/probe.a" '^_probe_caller$' > /dev/null 2> "$work/err"
check "an archive: refused" "$? $(grep -c 'is a static library (an ar archive)' "$work/err")" "2 1"
printf '#include <stdio.h>\n__attribute__((noinline)) static int helper(int x) { printf("%%d\\n", x); return x * 3; }\n__attribute__((noinline)) int caller(int x) { return helper(x) + helper(x + 1); }\nint main(int argc, char **argv) { return caller(argc); }\n' > "$work/strip.c"
xcrun clang -O2 -o "$work/strip" "$work/strip.c" || exit 1
"$calls" "$work/strip" '^_caller$' > /dev/null 2> "$work/err"
check "not stripped: no warning" "$(cat "$work/err")" ""
xcrun strip -x "$work/strip" || exit 1
"$calls" "$work/strip" '^_caller$' > /dev/null 2> "$work/err"
check "stripped: warned" "$(grep -c 'function starts in .* have no symbol (stripped?)' "$work/err")" 1

# Long names: 60 of them (20,000 bytes each, past ARG_MAX together) listed for objdump would fail with E2BIG.
perl -e 'print "    .text\n    .p2align 2\n";
    for my $i (0 .. 59) {
        my $name = sprintf "_long%02d_", $i; $name .= "x" x 20000;
        print "    .globl $name\n$name:\n    stp x29, x30, [sp, #-16]!\n    bl _ext$i\n    ldp x29, x30, [sp], #16\n    ret\n";
    }' > "$work/long.s"
xcrun clang -c -arch arm64 -o "$work/long.o" "$work/long.s" || exit 1
check "60 long names: every call" "$("$calls" "$work/long.o" '^_long' --sum 2>&1 | grep -c '^(all)	call	1	_ext')" 60

# A table entry added into x9, then a call (which may change x9) before the br: an indirect jump, no jump table.
printf '    .text\n    .p2align 2\n    .globl _call_then_br\n_call_then_br:\n    ldrb w9, [x0, x1]\n    add x9, x2, x9\n    bl _other\n    br x9\n    .subsections_via_symbols\n' > "$work/callbr.s"
xcrun clang -c -arch arm64 -o "$work/callbr.o" "$work/callbr.s" || exit 1
check "a call between the table entry and the br: no jump table" "$("$calls" "$work/callbr.o" '^_call_then_br$' 2> /dev/null | cut -f2-4 | tr '\t\n' ' /')" "call 1 _other/jump 1 (indirect)/"

# arm64e: calls to other images go through __auth_stubs.
if xcrun clang -O2 -arch arm64e -o "$work/probe-e" "$work/probe.c" 2> /dev/null; then
    check "arm64e: calls through __auth_stubs named" "$("$calls" "$work/probe-e" '^_probe_caller$' --callee '_puts|_free' 2> /dev/null | cut -f2-4 | tr '\t\n' ' /')" "call 2 _puts/tail 1 _free/"
fi

# TERM to Tools/calls' own bash while its pipeline runs (a large object): stopped at once, exit 143, nothing printed,
# its processes gone.
perl -e 'print "    .text\n    .p2align 2\n";
    for my $i (0 .. 399) {
        print "    .globl _t$i\n_t$i:\n    stp x29, x30, [sp, #-16]!\n";
        print "    bl _ext", $_ % 7, "\n" for 1 .. 2000;
        print "    ldp x29, x30, [sp], #16\n    ret\n";
    }' > "$work/huge.s"
xcrun clang -c -arch arm64 -o "$work/huge.o" "$work/huge.s" || exit 1
mkdir "$work/tt"
TMPDIR="$work/tt" "$calls" "$work/huge.o" '^_t' > "$work/tt.out" 2>&1 &
tool=$!
perl -MTime::HiRes=sleep -e 'for (1 .. 400) { exit 0 if glob("$ARGV[0]/experiments-tool.*/sites"); sleep 0.05 } exit 1' "$work/tt"
check "TERM to the tool: its pipeline started" "$?" 0
tree="$(ps -A -o pid=,ppid= | perl -e 'my $root = shift; my %k; while (<STDIN>) { my ($p, $pp) = split; push @{$k{$pp}}, $p } my @t = ($root); my @all; while (@t) { my $p = shift @t; push @all, @{$k{$p} // []}; push @t, @{$k{$p} // []} } print "@all"' "$tool")"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
kill -TERM "$tool"
wait "$tool"
rc=$?
check "TERM to the tool: exit 143 within a second, nothing printed" \
    "$rc $(perl -MTime::HiRes=time -e "print time - $t0 < 1 ? 'quick' : 'slow'") $(grep -c . "$work/tt.out")" "143 quick 0"
check "TERM to the tool: its processes gone, scratch removed" \
    "$(for p in $tree; do kill -0 "$p" 2> /dev/null && echo "$p"; done | grep -c .) $(perl -e 'opendir my $d, shift or die; print scalar grep { !/^\.\.?$/ } readdir $d' "$work/tt")" "0 0"

# A large environment (800 KB) shares ARG_MAX with objdump's arguments: 60 names of 5,000 bytes are disassembled from the
# whole file instead of listed; listed anyway (CALLS_LIST_MAX), objdump's failure is said (exit 2), not "no calls".
perl -e 'print "    .text\n    .p2align 2\n";
    for my $i (0 .. 59) {
        my $name = sprintf "_mid%02d_", $i; $name .= "x" x 5000;
        print "    .globl $name\n$name:\n    stp x29, x30, [sp, #-16]!\n    bl _ext$i\n    ldp x29, x30, [sp], #16\n    ret\n";
    }' > "$work/mid.s"
xcrun clang -c -arch arm64 -o "$work/mid.o" "$work/mid.s" || exit 1
big="$(perl -e 'print "y" x 800000')"
check "a 800 KB environment: every call (the whole file disassembled)" \
    "$(BIG_ENVIRONMENT="$big" "$calls" "$work/mid.o" '^_mid' --sum 2> /dev/null | grep -c '^(all)	call	1	_ext')" 60
BIG_ENVIRONMENT="$big" CALLS_LIST_MAX=9999999 "$calls" "$work/mid.o" '^_mid' --callee _ext > "$work/out" 2> "$work/err"
check "a 800 KB environment, the names listed anyway: objdump's failure said, exit 2" \
    "$? $(grep -c "objdump couldn't disassemble" "$work/err") $(grep -c 'no calls' "$work/err")" "2 1 0"
# The room's two allowances. 40,000 environment variables of 8 bytes (each also takes its NUL and an 8-byte pointer):
# 80 names of 5,000 bytes (400 KB) don't fit beside them, and are disassembled from the whole file.
perl -e 'print "    .text\n    .p2align 2\n";
    for my $i (0 .. 79) {
        my $name = sprintf "_wide%02d_", $i; $name .= "x" x 5000;
        print "    .globl $name\n$name:\n    stp x29, x30, [sp, #-16]!\n    bl _ext$i\n    ldp x29, x30, [sp], #16\n    ret\n";
    }' > "$work/wide80.s"
xcrun clang -c -arch arm64 -o "$work/wide80.o" "$work/wide80.s" || exit 1
many_variables() { perl -e 'my @env = map { sprintf "E%05d=1", $_ } 0 .. 39999; exec "env", @env, @ARGV' -- "$@"; }
many_variables "$calls" "$work/wide80.o" '^_wide' > "$work/out" 2> "$work/err"
check "40,000 small variables: room for their pointers too (no E2BIG)" "$? $(grep -c 'E2BIG\|Argument list too long\|ended early\|couldn.t disassemble' "$work/err")" "0 0"
# One variable leaving 100 bytes beyond 60 names of 5,000 bytes: within the 32 KB kept for what's added later (the
# tool's own variables, objdump's other arguments), so the names aren't listed.
size="$(perl -e '$e = 0; $e += length("$_=$ENV{$_}") + 9 for keys %ENV; print $ARGV[0] - $e - $ARGV[1] - 100 - length("BIG_ENVIRONMENT=") - 9' "$(getconf ARG_MAX)" "$(perl -e 'print 60 * (5008 + 1)')")"
big="$(perl -e 'print "y" x shift' "$size")"
BIG_ENVIRONMENT="$big" "$calls" "$work/mid.o" '^_mid' > "$work/out" 2> "$work/err"
check "a variable leaving 100 bytes: the margin kept (no E2BIG)" "$? $(grep -c 'E2BIG\|Argument list too long\|ended early\|couldn.t disassemble' "$work/err")" "0 0"

# TERM to the tool alone while it lists the functions (200,000 Swift symbols: nm, then the demangling, about a second):
# stopped there at once (bash would act on it only once a foreground command ended), exit 143, nothing printed.
perl -e 'print "    .text\n    .p2align 2\n"; printf "    .globl _\$s4main4f%06dyyF\n_\$s4main4f%06dyyF:\n    ret\n", $_, $_ for 0 .. 199999' > "$work/symbols60k.s"
xcrun clang -c -arch arm64 -o "$work/symbols60k.o" "$work/symbols60k.s" || exit 1
mkdir "$work/ti"
TMPDIR="$work/ti" "$calls" "$work/symbols60k.o" 'f000001' > "$work/ti.out" 2>&1 &
tool=$!
perl -MTime::HiRes=sleep -e 'for (1 .. 400) { exit 0 if glob("$ARGV[0]/experiments-tool.*/functions"); sleep 0.005 } exit 1' "$work/ti"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
kill -TERM "$tool"
wait "$tool"
rc=$?
check "TERM while listing the functions: exit 143 at once, nothing printed" \
    "$rc $(perl -MTime::HiRes=time -e "print time - $t0 < 0.25 ? 'quick' : 'slow'") $(grep -c . "$work/ti.out")" "143 quick 0"
