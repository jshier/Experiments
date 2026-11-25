#!/bin/bash
# Tools/bench-table on baselines served by a stand-in `swift` (it prints saved markdown, as `swift package benchmark
# baseline read --format markdown` does): a bad --percentile stops before anything is read, rows of two targets with
# the same benchmark name stay apart, and every unit scales (K…P, ns…Ms).
here="$(cd "$(dirname "$0")" && pwd)"
table="$here/../bench-table"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-bench-table.XXXXXX")"
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

mkdir -p "$work/bin" "$work/package"
cat > "$work/bin/swift" <<'EOF'
#!/bin/bash
# Stand-in for `swift package … benchmark baseline read NAME --format markdown`: prints $FAKE_BASELINES/NAME.md.
touch "$FAKE_BASELINES/.called"
while [[ $# -gt 0 && "$1" != read ]]; do shift; done
[[ -f "$FAKE_BASELINES/$2.md" ]] || exit 1
cat "$FAKE_BASELINES/$2.md"
EOF
chmod +x "$work/bin/swift"
export PATH="$work/bin:$PATH" FAKE_BASELINES="$work"

baseline() { # baseline NAME INSTRUCTIONS_P50 TIME_P50
    cat > "$work/$1.md" <<EOF
## Baseline '$1'

\`\`\`
Host 'test' with 1 'arm64' processors
\`\`\`
## FirstBenchmarks

### Encode

| Metric                   |        p0 |       p25 |       p50 |       p75 |       p90 |       p99 |      p100 |   Samples |
|:-------------------------|----------:|----------:|----------:|----------:|----------:|----------:|----------:|----------:|
| Instructions (K) *       |      9659 |      9667 |      $2 |      9667 |      9667 |      9672 |      9672 |      1000 |
| Time (wall clock) (μs) * |       482 |       492 |       $3 |       502 |       519 |       544 |       612 |      1000 |

## SecondBenchmarks

### Encode

| Metric                   |        p0 |       p25 |       p50 |       p75 |       p90 |       p99 |      p100 |   Samples |
|:-------------------------|----------:|----------:|----------:|----------:|----------:|----------:|----------:|----------:|
| Instructions (T) *       |         1 |         2 |         3 |         4 |         5 |         6 |         7 |        10 |
| Time (wall clock) (ks) * |         1 |         2 |         4 |         4 |         5 |         6 |         7 |        10 |

### Only here

| Metric                   |        p0 |       p25 |       p50 |       p75 |       p90 |       p99 |      p100 |   Samples |
|:-------------------------|----------:|----------:|----------:|----------:|----------:|----------:|----------:|----------:|
| Instructions (P) *       |         1 |         1 |         2 |         1 |         1 |         1 |         1 |        10 |
| Time (wall clock) (Ms) * |         1 |         1 |         3 |         1 |         1 |         1 |         1 |        10 |
EOF
}
baseline old 9667 496
baseline new 4833 248

"$table" "$work/package" --percentile p42 old new > /dev/null 2> "$work/err"
check "bad --percentile: status" "$?" 2
check "bad --percentile: nothing read" "$(test -e "$work/.called" && echo read)" ""
"$table" "$work/package" --percentile > /dev/null 2>&1
check "--percentile without a value" "$?" 2

"$table" "$work/package" old new > "$work/out" 2> "$work/err"
check "status" "$?" 0
# pick BENCHMARK METRIC: that row, |-separated.
pick() { perl -F'\t' -ane 'BEGIN { $b = shift @ARGV; $m = shift @ARGV } chomp $F[-1]; print join("|", @F) if $F[0] eq $b && $F[1] eq $m' "$1" "$2" "$work/out"; }
check "first target's row" "$(pick 'FirstBenchmarks: Encode' Instructions)" "FirstBenchmarks: Encode|Instructions|9667000|4833000|-50.0%"
check "second target's row (T)" "$(pick 'SecondBenchmarks: Encode' Instructions)" "SecondBenchmarks: Encode|Instructions|3000000000000|3000000000000|+0.0%"
check "times in μs (ks)" "$(pick 'SecondBenchmarks: Encode' 'Time (wall clock)')" "SecondBenchmarks: Encode|Time (wall clock)|4000000000|4000000000|+0.0%"
check "a name in one target keeps its name (P)" "$(pick 'Only here' Instructions)" "Only here|Instructions|2000000000000000|2000000000000000|+0.0%"
check "times in μs (Ms)" "$(pick 'Only here' 'Time (wall clock)')" "Only here|Time (wall clock)|3000000000000|3000000000000|+0.0%"
check "rows" "$(grep -c . "$work/out")" 7

"$table" "$work/package" old missing > /dev/null 2>&1
check "missing baseline" "$?" 2
