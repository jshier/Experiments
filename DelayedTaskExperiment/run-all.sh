#!/bin/bash
# Runs every scenario under the given mode: classic | nw | bg
# classic: default CFNetwork loader; nw: CFN_USE_NW_LOADER=1; bg scenarios are self-contained ("bg-*").
cd "$(dirname "$0")"
B=.build/debug/DelayedTaskExperiment
MODE=${1:-nw}
mkdir -p output/$MODE
SCENARIOS="delay2 delay2-nodelegate past-date delay2-wfc delay2-newrequest delay2-cancel delay2-never delay2-never-reqtimeout3 delay2-late delay2-twice delay5-reqtimeout2 delay5-restimeout3 delay5-restimeout3-wfc delay2-restimeout3-slow delay5-cancel1 delay2-suspend delay2-perreq-timeout1 wfc-ok wfc-invalid-host nowfc-invalid-host wfc-refused wfc-testnet nowfc-testnet wfc-testnet-restimeout6"
for s in ${SCENARIOS}; do
  (
    if [ "$MODE" = nw ]; then export CFN_USE_NW_LOADER=1; fi
    timeout 60 $B $s > output/$MODE/$s.txt 2>&1
  ) &
done
wait
