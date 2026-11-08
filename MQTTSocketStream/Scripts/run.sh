#!/bin/zsh
# Builds and runs mqtt-socket-stream with the given options. It finds the toolchain's Concurrency runtime
# itself (the path is embedded at link time: see Package.swift).
#     Scripts/run.sh --payload 1024 --connections 4
set -e
cd "${0:A:h}/.."
source Scripts/env.sh
swift build -c release --product mqtt-socket-stream > /dev/null
"$(swift build -c release --show-bin-path)/mqtt-socket-stream" "$@"
