#!/bin/bash
# Tools/runtime-count (LLDB; no prompt once attaching is approved): counts; two --who on one symbol tallied apart; a
# crash exits 1 with the counts so far, without waiting on standard input; an unresolved breakpoint prints
# "0 (unresolved)" and exits 1; --timeout stops LLDB and the program.
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/runtime-count"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-runtime-count.XXXXXX")"
cleanup() {
    pkill -KILL -f "$work/counted-debuggable" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

cat > "$work/counted.c" <<'EOF'
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
__attribute__((noinline)) void counted(long i) { __asm__ volatile("" : : "r"(i)); }
__attribute__((noinline)) void first(long n) { for (long i = 0; i < n; i++) counted(i); }
__attribute__((noinline)) void second(long n) { for (long i = 0; i < n; i++) counted(i); }
int main(int argc, char **argv) {
    first(3);
    second(2);
    if (argc > 1 && strcmp(argv[1], "crash") == 0) { volatile int *p = 0; *p = 1; }
    if (argc > 1 && strcmp(argv[1], "sleep") == 0) sleep(60);
    return 0;
}
EOF
xcrun clang -O1 -g -o "$work/counted" "$work/counted.c" || exit 1

out="$("$tool" --who counted=lr --who counted=x0 --break first -- "$work/counted" 2> "$work/err")"
check "normal exit" "$?" 0
check "hits" "$(echo "$out" | grep '^hits' | sort | tr '\t\n' ': ')" "hits:counted:5 hits:first:1 "
check "lr tallied by caller" "$(echo "$out" | grep -c $'^who\tcounted=lr\t3\tfirst')" 1
check "lr's other caller" "$(echo "$out" | grep -c $'^who\tcounted=lr\t2\tsecond')" 1
check "x0 tallied apart: 5 hits" "$(echo "$out" | perl -ne '$n += $1 if /^who\tcounted=x0\t(\d+)/; END { print $n }')" 5

cat > "$work/threads.c" <<'EOF'
// 4 threads call target(v) 50 times each at the same moment, v = 1000 + the thread's index.
#include <pthread.h>
#include <stdatomic.h>
__attribute__((noinline)) void target(long v) { __asm__ volatile("" : : "r"(v)); }
static _Atomic int ready, go;
static void *worker(void *arg) {
    atomic_fetch_add(&ready, 1);
    while (!atomic_load(&go)) {}
    for (int i = 0; i < 50; i++) target((long)arg);
    return 0;
}
int main(void) {
    pthread_t t[4];
    for (long i = 0; i < 4; i++) pthread_create(&t[i], 0, worker, (void *)(1000 + i));
    while (atomic_load(&ready) < 4) {}
    atomic_store(&go, 1);
    for (int i = 0; i < 4; i++) pthread_join(t[i], 0);
    return 0;
}
EOF
xcrun clang -O1 -g -o "$work/threads" "$work/threads.c" || exit 1
out="$("$tool" --who target=x0 --who target=lr -- "$work/threads" 2> /dev/null)"
check "threads: exit status" "$?" 0
hits="$(echo "$out" | perl -ne 'print $1 if /^hits\ttarget\t(\d+)$/')"
check "threads: hits at most 200, nearly all" "$(( hits <= 200 && hits >= 190 ))" 1
check "threads: x0 is each thread's own value, in hex" \
    "$(echo "$out" | perl -ne 'next unless /^who\ttarget=x0\t(\d+)\t(\S+)$/; my ($c, $v) = ($1, $2); $bad++ unless $v =~ /^0x0*3e[89ab]$/ && $c <= 50; $n += $c; END { print $bad ? "wrong values" : $n }')" "$hits"
check "threads: lr is the worker" "$(echo "$out" | grep $'^who\ttarget=lr\t' | cut -f4 | sort -u)" worker

start=$SECONDS
/bin/sleep 10 | {
    "$tool" --break counted -- "$work/counted" crash > "$work/out" 2> "$work/err"
    echo $? > "$work/rc"
    echo $((SECONDS - start)) > "$work/took"
}
check "a crash exits 1" "$(cat "$work/rc")" 1
check "without waiting on standard input" "$(( $(cat "$work/took") < 8 ))" 1
check "the counts up to the crash" "$(cut -f3 "$work/out")" 5
check "and the reason" "$(grep -c 'EXC_BAD_ACCESS' "$work/err")" 1

out="$("$tool" --break counted --break no_such_function_here -- "$work/counted" 2> /dev/null)"
check "an unresolved breakpoint exits 1" "$?" 1
check "and prints its row" "$(echo "$out" | grep no_such)" "$(printf 'hits\tno_such_function_here\t0 (unresolved)')"

start=$SECONDS
"$tool" --timeout 3 --break counted -- "$work/counted" sleep > /dev/null 2>&1
check "--timeout fails" "$?" 1
sleep 1
pgrep -f "$work/counted-debuggable" > /dev/null
check "--timeout stopped the program" "$?" 1

"$tool" --who counted -- "$work/counted" > /dev/null 2>&1
check "--who without a register" "$?" 2
"$tool" --break counted --timeout x -- "$work/counted" > /dev/null 2>&1
check "--timeout x" "$?" 2
