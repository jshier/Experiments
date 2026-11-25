#!/bin/bash
# Tools/counters (Instruments; no prompt once attaching is approved): a recording read in its own mode prints a row per
# thread with exact integer cycles; one fixed-work program's cycles agree (within 10%) between a bottleneck mode and a
# count mode (bottleneck tables hold each interval at two precisions: summing both doubled them); a recording read in
# another mode exits 2 and says so. --time-limit's rules are tests/timelimit.sh's. About 30 s.
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/counters"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-counters.XXXXXX")"
cleanup() {
    pkill -KILL -f "$work/busy-debuggable" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

# Fixed work (a dependent chain of 600 M multiply-adds), so its cycles don't depend on the clock.
cat > "$work/busy.c" <<'EOF'
int main(void) {
    unsigned long x = 1;
    for (long i = 0; i < 600000000; i++) { x = x * 6364136223846793005ul + 1; __asm__ volatile("" : "+r"(x)); }
    return (int)(x & 1) * 0;
}
EOF
xcrun clang -O1 -o "$work/busy" "$work/busy.c" || exit 1

out="$("$tool" --keep "$work/run.trace" -- "$work/busy" 2> "$work/err")"
rc=$?
[[ $rc == 0 ]] || { echo "the tool's stderr:"; cat "$work/err"; }
check "bottlenecks: exit status" "$rc" 0
check "bottlenecks: a thread with integer cycles and shares" \
    "$(echo "$out" | head -1 | perl -ne 'print "ok" if /^[^\t]+\t\d+\tdelivery [\d.]+%/')" ok
bottleneck_cycles="$(echo "$out" | head -1 | cut -f2)"
counted="$("$tool" --mode simd_fp_unit_instructions -- "$work/busy" 2> "$work/err")"
rc=$?
[[ $rc == 0 ]] || { echo "the tool's stderr:"; cat "$work/err"; }
check "simd_fp_unit_instructions: exit status" "$rc" 0
count_cycles="$(echo "$counted" | head -1 | cut -f2)"
check "the same work's cycles agree across modes (bottlenecks $bottleneck_cycles, count $count_cycles)" \
    "$(perl -e 'my ($a, $b) = @ARGV; print $b > 0 && abs($a / $b - 1) < 0.1 ? "yes" : "no"' "$bottleneck_cycles" "$count_cycles")" yes

"$tool" --mode simd_fp_unit_instructions --trace "$work/run.trace" > "$work/out" 2> "$work/err"
check "read in another mode: exit 2" "$?" 2
check "read in another mode: nothing on stdout" "$(wc -c < "$work/out" | tr -d ' ')" 0
check "read in another mode: says so" "$(grep -c 'recorded in another mode' "$work/err")" 1
