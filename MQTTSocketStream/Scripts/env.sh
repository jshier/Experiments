# Sourced by the other scripts: the toolchain with swiftlang/swift#91981, and the paths its processes need.
# Override TOOLCHAIN or XCODE_PLATFORM if they live elsewhere.
TOOLCHAIN="${TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-PR-91981-2511.xctoolchain}"
XCODE_PLATFORM="${XCODE_PLATFORM:-/Applications/Xcode_27.3.app/Contents/Developer/Platforms/MacOSX.platform}"
export TOOLCHAINS="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TOOLCHAIN/Info.plist")"
# The I/O interfaces need the toolchain's Concurrency runtime, not the OS's.
RUNTIME="$TOOLCHAIN/usr/lib/swift/macosx"
