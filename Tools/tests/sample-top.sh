#!/bin/bash
# Tools/sample-top: a launched program is stopped once sampling ends (a 60 s program sampled for 1 s takes seconds),
# the busy function is reported, and bad options exit 2.
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/sample-top"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-sample-top.XXXXXX")"
cleanup() {
    pkill -KILL -f "$work/busy-debuggable" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

cat > "$work/busy.c" <<'EOF'
#include <stdlib.h>
#include <time.h>
__attribute__((noinline)) static unsigned long spin_here(double seconds) {
    unsigned long x = 1;
    double end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) * 1e-9 + seconds;
    while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) * 1e-9 < end)
        for (int i = 0; i < 100000; i++) x = x * 6364136223846793005ul + 1;
    return x;
}
int main(int argc, char **argv) { return (int)(spin_here(argc > 1 ? atof(argv[1]) : 1) & 1) * 0; }
EOF
xcrun clang -O1 -g -o "$work/busy" "$work/busy.c" || exit 1

start=$SECONDS
out="$("$tool" --seconds 1 --delay 0.3 --top 3 -- "$work/busy" 60 2> /dev/null)"
check "exit status" "$?" 0
check "done in seconds, not the program's 60" "$(( SECONDS - start < 15 ))" 1
check "the busy function" "$(echo "$out" | head -1 | grep -c 'spin_here')" 1
sleep 0.5
pgrep -f "$work/busy-debuggable" > /dev/null
check "the program was stopped" "$?" 1

for args in "--seconds" "--seconds 1.5" "--delay x" "--top -1" "--pid abc"; do
    # shellcheck disable=SC2086 # Split on purpose: each string is several arguments.
    "$tool" $args -- "$work/busy" > /dev/null 2>&1
    check "$args exits 2" "$?" 2
done
