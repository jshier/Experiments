#!/bin/bash
# Tools/socket-ceiling: TSV with exact bytes; a low descriptor limit is raised (or refused with exit 2 when the hard
# limit is too low), never a hang; bad options exit 2.
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/socket-ceiling"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-socket-ceiling.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export EXPERIMENTS_TOOLS_CACHE="$work/cache"
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

out="$("$tool" --pairs 2 --bytes 1M --write 64K --runs 2)"
check "exit status" "$?" 0
check "header" "$(echo "$out" | head -1)" "$(printf 'pairs\tbytes\tms\tGB_per_s')"
check "rows" "$(echo "$out" | sed 1d | cut -f1,2 | tr '\n\t' ' :')" "2:2097152 2:2097152 "
check "numeric columns" "$(echo "$out" | sed 1d | perl -ne 'print "bad" unless /^\d+\t\d+\t\d+\.\d\t\d+\.\d\d$/')" ""

out="$(ulimit -Sn 16; "$tool" --unix --pairs 12 --bytes 1M | sed 1d | cut -f1,2)"
check "unix pairs past a soft limit of 16" "$out" "$(printf '12\t12582912')"
out="$(ulimit -Sn 16; "$tool" --pairs 12 --bytes 1M | sed 1d | cut -f1,2)"
check "TCP pairs past a soft limit of 16" "$out" "$(printf '12\t12582912')"
(ulimit -n 16; "$tool" --pairs 12 --bytes 1M > /dev/null 2> "$work/err")
check "a hard limit too low exits 2" "$?" 2
check "and says why" "$(grep -c 'hard limit' "$work/err")" 1
(ulimit -n 40; "$tool" --pairs 12 --bytes 1M > /dev/null 2> "$work/err")
check "a hard limit of 40 (macOS allows 25 there) and 12 pairs: exits 2" "$?" 2
check "and says why" "$(grep -c 'only 25' "$work/err")" 1
# At a hard limit of 40 (25 descriptors), with only standard input, output, and error open: 22 free numbers, so 10 TCP
# pairs (20 and a listener) and 11 socketpairs (22) fit, and one more of either doesn't.
fit() { (for ((fd = 3; fd < 64; fd++)); do eval "exec $fd>&-"; done; ulimit -n 40; "$tool" "$@" --bytes 64K 2> /dev/null | sed 1d | cut -f1); }
check "a hard limit of 40: 10 TCP pairs run" "$(fit --pairs 10)" 10
check "a hard limit of 40: 11 TCP pairs don't" "$(fit --pairs 11)" ""
check "a hard limit of 40: 11 socketpairs run (no listener)" "$(fit --unix --pairs 11)" 11
check "a hard limit of 40: 12 socketpairs don't" "$(fit --unix --pairs 12)" ""
out="$(ulimit -Sn 64; ulimit -Sn 40; "$tool" --unix --pairs 20 --bytes 1M | sed 1d | cut -f1)"
check "a soft limit of 40 is stepped over" "$out" 20
out="$(for ((fd = 20; fd < 90; fd++)); do eval "exec $fd</dev/null"; done; ulimit -Sn 16; "$tool" --pairs 12 --bytes 1M | sed 1d | cut -f1)"
check "descriptors inherited above the soft limit" "$out" 12

for args in "--runs abc" "--runs" "--write 0" "--bytes 1.5G" "--pairs 300" "--pairs 0" "--buffer x"; do
    # shellcheck disable=SC2086 # Split on purpose: each string is several arguments.
    "$tool" $args > /dev/null 2>&1
    check "$args" "$?" 2
done
