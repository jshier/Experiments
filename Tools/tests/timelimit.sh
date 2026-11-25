#!/bin/bash
# Tools/counters, tasks, and profile (from the round 3 review): --time-limit's rules, without recording anything. The
# program doesn't exist, so a limit that's accepted fails afterwards on the program, and one that's refused names
# --time-limit: a refusal is told apart from a later failure by its message, not just the exit status. Under a second.
set -u
tools="$(cd "$(dirname "$0")/.." && pwd)"
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }
verdict() { # tool limit -> accepted|refused
    local err
    err="$("$tools/$1" --time-limit "$2" -- /nonexistent/program 2>&1 > /dev/null)"
    [[ "$err" == *time-limit* ]] && echo refused || echo accepted
}
for tool in counters tasks profile; do
    for limit in 1 1ms 10000000s 9999999999ms 166666m 2777h; do
        check "$tool --time-limit $limit is accepted" "$(verdict "$tool" "$limit")" accepted
    done
    for limit in 0 0s 08s 10000001s 166667m 2778h 9999999999 1.5s 5x; do
        check "$tool --time-limit $limit is refused" "$(verdict "$tool" "$limit")" refused
    done
done
