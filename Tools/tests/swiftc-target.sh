#!/bin/bash
# Tools/swiftc-target on a one-target package: the first capture succeeds (a pipe once killed `swift build` with
# SIGPIPE, status 141), a relative -o lands in the caller's directory, a new source file is compiled without --refresh,
# a cached command whose swiftc is gone is captured again, the cache is keyed by toolchain, and -h prints usage.
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/../swiftc-target"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-swiftc-target.XXXXXX")"
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

mkdir -p "$work/pkg/Sources/Alpha" "$work/caller"
cat > "$work/pkg/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "Probe", targets: [.target(name: "Alpha")])
EOF
printf '@inline(never) public func alphaSum(_ a: [Int]) -> Int { a.reduce(0, &+) }\n' > "$work/pkg/Sources/Alpha/Alpha.swift"

cd "$work/caller" || exit 1
"$tool" "$work/pkg" Alpha -- -emit-sil -o relative.sil > "$work/out" 2> "$work/err"
status=$?
[[ $status -eq 0 ]] || sed 's/^/    /' "$work/err"
check "first capture: status" "$status" 0
check "relative -o lands in the caller's directory" "$(test -s "$work/caller/relative.sil" && echo yes)" yes
check "nothing beside the package" "$(test -e "$work/relative.sil" && echo yes)" ""
keyed=0
for command_file in "$work/pkg/.build/agent-tools"/Alpha.release.*.command; do
    [[ "$(basename "$command_file")" =~ ^Alpha\.release\.[0-9a-f]{12}\.command$ ]] && keyed=$((keyed + 1))
done
check "cache keyed by toolchain" "$keyed" 1

"$tool" "$work/pkg" Alpha -- -emit-sil -o "$work/same.sil" > /dev/null 2> "$work/err"
check "unchanged: status" "$?" 0
check "unchanged: the cached command is used" "$(grep -c 'capturing' "$work/err")" 0

printf '@inline(never) public func alphaExtra() -> Int { 42 }\n' > "$work/pkg/Sources/Alpha/Extra.swift"
"$tool" "$work/pkg" Alpha -- -emit-sil -o "$work/extra.sil" > /dev/null 2> "$work/err"
check "new file: status" "$?" 0
grep -q "capturing Alpha's command: the target's files changed" "$work/err"
check "new file: captured again for it" "$?" 0
check "new file: compiled" "$(grep -c '^sil .*alphaExtra' "$work/extra.sil")" 1

# Package.swift edited after the capture (the cache dated back: mtimes are compared in whole seconds).
touch -t 202001010000 "$command_file"
"$tool" "$work/pkg" Alpha -- -emit-sil -o "$work/manifest.sil" > /dev/null 2> "$work/err"
grep -q "capturing Alpha's command: Package.swift changed" "$work/err"
check "Package.swift newer: captured again" "$?" 0

cache="$(ls "$work/pkg/.build/agent-tools/"Alpha.release.*.command)"
perl -pi -e 's{^\S+}{/nonexistent/usr/bin/swiftc}' "$cache"
"$tool" "$work/pkg" Alpha -- -emit-sil -o "$work/again.sil" > /dev/null 2> "$work/err"
check "swiftc gone: status" "$?" 0
grep -q 'its swiftc is gone' "$work/err"
check "swiftc gone: captured again" "$?" 0

"$tool" -h > "$work/help" 2>&1
check "-h: status" "$?" 0
grep -q '^usage: Tools/swiftc-target' "$work/help"
check "-h: usage printed" "$?" 0
"$tool" --bogus "$work/pkg" Alpha > /dev/null 2>&1
check "unknown option" "$?" 2
"$tool" "$work/nowhere" Alpha > /dev/null 2>&1
check "not a package" "$?" 2
