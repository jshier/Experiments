#!/bin/bash
# Tools/allocations (Instruments and LLDB attach; no prompt once approved): categories count allocations, not events,
# with Instruments' "All …" rows apart; --history reads its own process even with another of the same name running, and
# passes malloc_history's error on; --timeout stops the recorded program and nothing else.
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/allocations"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-allocations.XXXXXX")"
bystander=
cleanup() {
    [[ -n "$bystander" ]] && kill -KILL "$bystander" 2>/dev/null
    pkill -KILL -f "$work/churn-debuggable" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

cat > "$work/churn.c" <<'EOF'
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
__attribute__((noinline)) static void churn(long count) {
    for (long i = 0; i < count; i++) { void *volatile p = malloc(48); free(p); }
}
int main(int argc, char **argv) {
    if (argc > 2) sleep(atoi(argv[2]));
    churn(argc > 1 ? atol(argv[1]) : 0);
    if (argc > 3 && strcmp(argv[3], "_exit") == 0) _exit(0);
    return 0;
}
EOF
xcrun clang -O1 -g -o "$work/churn" "$work/churn.c" || exit 1

out="$("$tool" --top 5 -- "$work/churn" 3000 2> "$work/err")"
rc=$?
[[ $rc == 0 ]] || { echo "the tool's stderr:"; cat "$work/err"; }
check "recording exit status" "$rc" 0
row="$(echo "$out" | sed -n '/^== categories/,/^== callers/p' | grep $'\tMalloc 48 Bytes$')"
check "48-byte allocations counted once each (3000 and a few)" "$(echo "$row" | perl -ane 'print $F[0] >= 3000 && $F[0] < 3300 ? "yes" : "no: $F[0]"')" yes
check "with their bytes" "$(echo "$row" | perl -ane 'print $F[2] == 48 * $F[0] ? "yes" : "no"')" yes
check "no All rows among the categories" "$(echo "$out" | sed -n '/^== categories/,/^== callers/p' | grep -c $'\tAll ')" 0
check "All rows in the totals" "$(echo "$out" | sed -n '/^== totals/,/^== categories/p' | grep -c $'\tAll Heap Allocations$')" 1

"$tool" --history --top 3 -- "$work/churn" 0 > /dev/null 2>&1 # makes churn-debuggable for the bystander
"$work/churn-debuggable" 0 60 &
bystander=$!
out="$("$tool" --history --top 3 -- "$work/churn" 700 2> /dev/null)"
check "--history with a same-named process: exit status" "$?" 0
check "--history counts this run's churn" "$(echo "$out" | grep $'\tchurn$' | cut -f1)" 700

"$tool" --history -- "$work/churn" 10 0 _exit > /dev/null 2> "$work/err"
check "--history without an exit: fails" "$?" 2
check "with malloc_history's own message" "$(grep -c '^malloc_history: .*no longer appears to be running' "$work/err")" 1

"$tool" --timeout 3 -- "$work/churn" 0 50 > /dev/null 2>&1
check "--timeout fails" "$?" 1
sleep 1
check "the bystander still runs" "$(kill -0 "$bystander" 2>/dev/null && echo yes || echo no)" yes
check "the recorded program was stopped" "$(pgrep -f "$work/churn-debuggable 0 50" > /dev/null && echo running || echo stopped)" stopped
