#!/bin/bash
# Tools/remarks on a one-file program: it reports with no `-- SWIFTC_ARGS` (an empty array under bash 3.2's set -u
# used to end it silently), and two vectorized loops at one inlined location are counted, not merged.
here="$(cd "$(dirname "$0")" && pwd)"
remarks="$here/../remarks"
command -v yq > /dev/null || { echo "skipped: no yq (brew install yq)"; exit 0; }
work="$(mktemp -d "${TMPDIR:-/tmp}/check-remarks.XXXXXX")"
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

cat > "$work/TwoLoops.swift" <<'EOF'
@inline(never)
public func twoMaps(_ a: [Int32], _ b: [Int32]) -> (Int32, Int32) {
    let x = a.reduce(0, &+)
    let y = b.reduce(0, &+)
    return (x, y)
}
EOF

"$remarks" "$work/TwoLoops.swift" --function twoMaps > "$work/out" 2> "$work/err"
check "no swiftc arguments: status" "$?" 0
check "two vectorized loops counted" "$(perl -F'\t' -ane 'print $F[0] if $F[1] eq "Passed" && $F[5] eq "Vectorized"' "$work/out")" 2
"$remarks" "$work/TwoLoops.swift" --function twoMaps -- -module-name TwoLoops > "$work/out2" 2> /dev/null
check "with swiftc arguments: same remarks" "$(cut -f1,2,3,6 "$work/out2")" "$(cut -f1,2,3,6 "$work/out")"

"$remarks" "$work/TwoLoops.swift" --passes > /dev/null 2>&1
check "--passes without a value" "$?" 2
"$remarks" --target > /dev/null 2>&1
check "--target without a package" "$?" 2
