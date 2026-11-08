#!/bin/zsh
# Builds and runs the tests against the toolchain's Concurrency runtime. `swift test` can't: it replaces
# DYLD_LIBRARY_PATH for its test process, which then loads the OS runtime and crashes in the I/O.
set -e
cd "${0:A:h}/.."
source Scripts/env.sh
swift build -c release --build-tests
bin="$PWD/.build/out/Products/Release/MQTTSocketStreamTests.xctest/Contents/MacOS/MQTTSocketStreamTests"
DYLD_LIBRARY_PATH="$RUNTIME:$RUNTIME/testing:$XCODE_PLATFORM/Developer/usr/lib" \
DYLD_FRAMEWORK_PATH="$XCODE_PLATFORM/Developer/Library/Frameworks" \
    "$TOOLCHAIN/usr/libexec/swift/pm/swiftpm-testing-helper" --test-bundle-path "$bin" --testing-library swift-testing
