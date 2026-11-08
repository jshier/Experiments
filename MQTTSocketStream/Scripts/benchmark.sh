#!/bin/zsh
# Runs the benchmarks with the toolchain (the executable embeds its runtime path). Arguments go to
# `swift package benchmark`:
#     Scripts/benchmark.sh --filter 'MQTT 64 B.*'
set -e
cd "${0:A:h}/.."
source Scripts/env.sh
swift package --disable-sandbox benchmark "$@"
