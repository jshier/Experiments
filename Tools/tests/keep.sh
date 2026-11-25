#!/bin/bash
# --keep in the recording tools (allocations, counters, profile, tasks, sample-top): anything that isn't a new path or an
# earlier .trace recording is refused with exit 2 and left as it was, and nothing is removed when another argument is
# bad. Nothing is recorded: every case stops before xctrace runs.
set -u
tools="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-keep.XXXXXX")"
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

printf 'int main(void) { return 0; }\n' > "$work/noop.c"
xcrun clang -o "$work/noop" "$work/noop.c" || exit 1
mkdir -p "$work/results/sub"
echo precious > "$work/results/precious.txt"
echo precious > "$work/results/sub/more.txt"
mkdir -p "$work/results.trace"
echo precious > "$work/results.trace/notes.txt"
echo precious > "$work/file.trace"
echo precious > "$work/report.txt"
precious5="preciouspreciouspreciouspreciousprecious"
intact() { [[ "$(cat "$work/results/precious.txt" "$work/results/sub/more.txt" "$work/results.trace/notes.txt" "$work/file.trace" "$work/report.txt" 2>/dev/null | tr -d '\n')" == "$precious5" ]] && echo yes || echo no; }

for tool in counters profile tasks allocations; do
    for keep in "$work/results" "$work/results.trace" "$work/file.trace" "$work/report.txt"; do
        "$tools/$tool" --keep "$keep" -- "$work/noop" > /dev/null 2>&1
        rc=$?
        check "$tool --keep ${keep##*/} refused" "$rc" 2
        check "$tool --keep ${keep##*/} left everything" "$(intact)" yes
    done
    "$tools/$tool" --keep "$work/results" -- /nonexistent/program > /dev/null 2>&1
    check "$tool with a missing program" "$?" 2
    check "$tool with a missing program left everything" "$(intact)" yes
    "$tools/$tool" --keep > /dev/null 2>&1
    check "$tool --keep without a value" "$?" 2
done
"$tools/allocations" --history --keep "$work/report.txt" -- "$work/noop" > /dev/null 2>&1
check "allocations --history --keep on an existing file refused" "$?" 2
"$tools/allocations" --history --keep "$work/results" -- "$work/noop" > /dev/null 2>&1
check "allocations --history --keep on a directory refused" "$?" 2
"$tools/sample-top" --keep "$work/report.txt" -- "$work/noop" > /dev/null 2>&1
check "sample-top --keep on an existing file refused" "$?" 2
check "and everything is left" "$(intact)" yes
