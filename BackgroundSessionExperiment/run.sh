#!/bin/bash
# usage: run.sh scenario [extra args]; output -> output/<scenario><SUFFIX>.log
cd "$(dirname "$0")"
sc=$1; shift
out="$PWD/output/${sc}${SUFFIX}.log"
xcrun simctl terminate booted com.jshier.bgexp >/dev/null 2>&1
rm -f "$out"
xcrun simctl launch --terminate-running-process --stdout="$out" --stderr="$out" booted com.jshier.bgexp "$sc" "$@" >/dev/null
for i in $(seq 1 ${WAIT:-25}); do sleep 1; grep -qE "DONE|TIMEOUT|unknown" "$out" 2>/dev/null && break; done
sleep 0.5
echo "=== $sc"; cat "$out"
