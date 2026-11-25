#!/bin/bash
# Tools/cpu-probe: an exact instruction name selects its row alone, others match as substrings (`insn ld4`), a name
# that matches nothing exits 1 and an empty one 2, before measuring; sizes under 128 bytes, over half the memory, or
# with trailing characters exit 2 before measuring.
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/cpu-probe"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-cpu-probe.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export EXPERIMENTS_TOOLS_CACHE="$work/cache"
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

out="$("$tool" insn ld4)"
check "insn ld4 exits 0" "$?" 0
check "insn ld4 selects the ld4 row" "$(echo "$out" | sed -n '3,$p' | cut -f1)" "ld4 (64 B, no chain)"
check "an exact name selects its row alone (pmull, not pmull2)" "$("$tool" insn pmull | sed -n '3,$p' | cut -f1)" pmull
check "two exact names, two rows" "$("$tool" insn 'tbl 3 regs' 'TBX 4 REGS' v_add | sed -n '3,$p' | cut -f1 | tr '\n' '|')" "add.16b|tbl 3 regs|tbx 4 regs|"
check "insn 'TBL 4' ignores case" "$("$tool" insn 'TBL 4' | sed -n '3,$p' | cut -f1)" "tbl 4 regs"
"$tool" insn ld4 no-such-instruction > "$work/out" 2> "$work/err"
check "a name matching nothing exits 1" "$?" 1
check "before measuring" "$(wc -c < "$work/out" | tr -d ' ')" 0
check "and names it" "$(grep -c no-such-instruction "$work/err")" 1
"$tool" insn '' > "$work/out" 2> /dev/null
check "an empty name is a usage error" "$?/$(wc -c < "$work/out" | tr -d ' ')" "2/0"

for args in "latency 64" "latency abc" "latency 1x" "latency 2Mb" "latency 0x100" "latency 1e6" "latency -1M" \
    "latency 1.M" "latency +1M" "bandwidth read --bytes 64 1" "bandwidth read --bytes 1M 2x" \
    "bandwidth read --bytes 1M 0" "bandwidth sideways 1"; do
    # shellcheck disable=SC2086 # Split on purpose: each string is several arguments.
    "$tool" $args > "$work/out" 2> /dev/null
    check "$args exits 2" "$?" 2
    check "$args measures nothing" "$(wc -c < "$work/out" | tr -d ' ')" 0
done
"$tool" latency ' 1M' > "$work/out" 2> /dev/null
check "a size with a leading space exits 2" "$?/$(wc -c < "$work/out" | tr -d ' ')" "2/0"

# The memory cap, against a pretend 2 MB Mac (half: 1 MB), so a regression can't allocate much: the latency chase
# counts its order array (1/16 of the size), bandwidth the threads' buffers together. At the edge, both ways.
capped() { CPU_PROBE_MEMORY_BYTES=2097152 "$tool" "$@" > "$work/out" 2> /dev/null; echo "$?/$(grep -c . "$work/out")"; }
check "latency 1M (with its order array, over 1 MB): refused" "$(capped latency 1M)" "2/0"
check "latency 960K (1020 KB with its order array): measured" "$(capped latency 960K)" "0/3"
check "bandwidth 2 threads of 512K (1 MB): measured" "$(capped bandwidth read --bytes 512K 2)" "0/2"
check "bandwidth 3 threads of 512K: refused" "$(capped bandwidth read --bytes 512K 3)" "2/0"
"$tool" bandwidth read --bytes 2> /dev/null
check "--bytes without a value" "$?" 2
check "latency 1.5K is a size" "$("$tool" latency 1.5K | sed -n 3p | cut -f1)" 1.5K
