#!/bin/bash
# Tools/sil-trace on a one-file program: it traces with no `-- SWIFTC_ARGS` (an empty array under bash 3.2's set -u
# used to end it silently) and with them, and its last line is what reaches IRGen.
here="$(cd "$(dirname "$0")" && pwd)"
trace="$here/../sil-trace"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-sil-trace.XXXXXX")"
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

cat > "$work/Probe.swift" <<'EOF'
public final class Box {
    public var value: Int
    public init(_ value: Int) { self.value = value }
}

@inline(never)
public func makeBoxes(_ n: Int) -> [Box] { (0..<n).map { Box($0) } }
EOF

"$trace" "$work/Probe.swift" 'makeBoxes' 'alloc_ref|apply' > "$work/out" 2> "$work/err"
check "no swiftc arguments: status" "$?" 0
grep -q 'tracing makeBoxes' "$work/err"
check "no swiftc arguments: the function found" "$?" 0
check "no swiftc arguments: passes printed" "$(test -s "$work/out" && echo yes)" yes
"$trace" "$work/Probe.swift" 'makeBoxes' 'alloc_ref|apply' -- -g > "$work/out2" 2> /dev/null
check "with swiftc arguments: status" "$?" 0
check "with swiftc arguments: same final state" "$(tail -1 "$work/out2" | perl -pe 's/^.{71}//')" "$(tail -1 "$work/out" | perl -pe 's/^.{71}//')"

"$trace" "$work/Missing.swift" 'makeBoxes' 'apply' > /dev/null 2>&1
check "missing file" "$?" 2
"$trace" --target > /dev/null 2>&1
check "--target without a package" "$?" 2
