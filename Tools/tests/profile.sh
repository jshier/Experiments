#!/bin/bash
# Tools/profile (Instruments; no prompt once attaching is approved): the busy function leads its thread's samples; a
# recording too short to hold a sample exits 2, never 0 with nothing printed; bad --time-limit values exit 2. About
# 20 s.
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/profile"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-profile.XXXXXX")"
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
int main(int argc, char **argv) { return (int)(spin_here(argc > 1 ? atof(argv[1]) : 0.5) & 1) * 0; }
EOF
xcrun clang -O1 -g -o "$work/busy" "$work/busy.c" || exit 1

out="$("$tool" --top 1 --keep "$work/busy.trace" -- "$work/busy" 0.5 2> "$work/err")"
rc=$?
[[ $rc == 0 ]] || { echo "the tool's stderr:"; cat "$work/err"; }
check "exit status" "$rc" 0
check "the busy function leads" "$(echo "$out" | head -1 | cut -f4)" spin_here
# A recording too short for the program's own code: either no samples at all (exit 2, "no samples", nothing printed)
# or a few in dyld (shown unsymbolicated, exit 0): never a failed symbolication.
"$tool" --time-limit 1ms -- "$work/busy" 0 > "$work/out" 2> "$work/err"
rc=$?
if [[ $rc == 2 ]]; then
    check "a recording with no samples: says so, prints nothing" \
        "$(grep -c 'no samples' "$work/err")/$(wc -c < "$work/out" | tr -d ' ')" "1/0"
else
    check "a recording with samples only outside the program: exit 0, shown" \
        "$rc/$(grep -c 'own code' "$work/err")/$([[ -s "$work/out" ]] && echo printed)" "0/1/printed"
fi

# The recording read with another program's dSYM: shown unsymbolicated, with a note that names the program and says the
# dSYM may not match, and --keep still gets the recording.
printf 'int main(void) { return 0; }\n' > "$work/other.c"
xcrun clang -O1 -g -o "$work/other" "$work/other.c" || exit 1
out="$("$tool" --top 1 --trace "$work/busy.trace" --dsym "$work/other" --keep "$work/again.trace" 2> "$work/err")"
check "a mismatched dSYM: exit 0, shown" "$?/$([[ -n "$out" ]] && echo shown)" "0/shown"
check "a mismatched dSYM: the note names the program and the mismatch" "$(grep -c "other's own code.*doesn't match" "$work/err")" 1
check "a mismatched dSYM: --keep written" "$([[ -f "$work/again.trace/form.template" ]] && echo kept)" kept
