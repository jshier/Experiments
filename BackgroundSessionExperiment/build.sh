#!/bin/bash
# Build the app, install on the booted simulator.
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
APP=build/BGExp.app
rm -rf build && mkdir -p $APP
xcrun swiftc -sdk "$SDK" -target arm64-apple-ios27.0-simulator -o $APP/BGExp App/main.swift 2>&1 | grep -v warning || true
cp App/Info.plist $APP/Info.plist
codesign -f -s - $APP
xcrun simctl install booted $APP
echo built
