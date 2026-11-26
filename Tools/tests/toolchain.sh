#!/bin/bash
# Tools/toolchain in a fake repository and a fake HOME (its own registry and ~/Library/Developer/Toolchains): an
# invalid registry stops it (2); exact names beat substrings and an alias link counts once; register checks --path
# and option values before writing; a registered toolchain that isn't installed exits 2; install refuses `..` paths and
# a wrong sha256 before extracting, and records a good one; `test` builds release (both swift build calls with the
# same flags, no -enable-testing) and returns the tests' status. A fake `swift` and testing helper stand in for real builds.
tools="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-toolchain.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

repo="$work/repo"
mkdir -p "$repo/Tools/lib"
cp "$tools/toolchain" "$repo/Tools/"
cp "$tools/lib/common.sh" "$repo/Tools/lib/"
registry="$repo/Tools/toolchains.json"
printf '{\n  "toolchains": {}\n}\n' > "$registry"
export HOME="$work/home"
installed="$HOME/Library/Developer/Toolchains"
export EXPERIMENTS_SYSTEM_TOOLCHAINS="$work/system-toolchains" # not this Mac's /Library/Developer/Toolchains
mkdir -p "$installed" "$EXPERIMENTS_SYSTEM_TOOLCHAINS"

make_toolchain() { # make_toolchain DIR BUNDLE_ID [ALIAS]
    mkdir -p "$1/usr/lib/swift/macosx" "$1/usr/libexec/swift/pm"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $2" "$1/Info.plist" > /dev/null
    if [[ -n "${3:-}" ]]; then
        /usr/libexec/PlistBuddy -c 'Add :Aliases array' -c "Add :Aliases:0 string $3" "$1/Info.plist" > /dev/null
    fi
}
make_toolchain "$installed/A.xctoolchain" org.example.check-a check-a-alias
make_toolchain "$installed/B.xctoolchain" org.example.check-a.b
ln -s "$installed/A.xctoolchain" "$installed/latest-check.xctoolchain"

tc() { "$repo/Tools/toolchain" "$@"; }
status() { "$repo/Tools/toolchain" "$@" > /dev/null 2> "$work/err"; echo $?; }
toolchain_of() { tc "$1" env 2> /dev/null | perl -ne 'print $1 if /TOOLCHAIN=(\S+)/'; }

# The registry.
cp "$registry" "$work/registry.good"
printf '{\n  "toolchains": { "x": { "bundle_id": "y", } }\n}\n' > "$registry"
check "an invalid registry: list exits 2" "$(status list)" 2
check "  and says so" "$(grep -c "isn't valid JSON" "$work/err" | tr -d ' ')" 1
check "an invalid registry: env exits 2" "$(status A env)" 2
for shape in '{"toolchains":{"x":1}}' '{"toolchains":{"x":{"install":"https://example.invalid/t.tar.gz"}}}' \
    '{"toolchains":{"x":{"bundle_id":5}}}' '{"toolchains":{"x":{"install":{"url":7}}}}' '{"toolchains":[]}'; do
    echo "$shape" > "$registry"
    check "a registry of the wrong shape exits 2: $shape" "$(status list)" 2
done
cp "$work/registry.good" "$registry"
check "the good registry lists" "$(status list)" 0
make_toolchain "$EXPERIMENTS_SYSTEM_TOOLCHAINS/S.xctoolchain" org.system.check-system
check "a toolchain in the system directory resolves" "$(toolchain_of org.system.check-system)" \
    "$EXPERIMENTS_SYSTEM_TOOLCHAINS/S.xctoolchain"

# Resolving names.
check "exact bundle id beats a longer one containing it" "$(toolchain_of org.example.check-a)" "$installed/A.xctoolchain"
check "exact alias" "$(toolchain_of check-a-alias)" "$installed/A.xctoolchain"
check "exact directory name without .xctoolchain" "$(toolchain_of B)" "$installed/B.xctoolchain"
check "a substring of two toolchains (and a link to one) is ambiguous" "$(status org.example env)" 2
check "  counted once each" "$(grep -c "matches 2 toolchains" "$work/err" | tr -d ' ')" 1
check "a substring of one toolchain and its link resolves to the directory" "$(toolchain_of check-a-al)" \
    "$installed/A.xctoolchain"
check "nothing matches: exit 2" "$(status nothing-like-this env)" 2

# register.
cp "$registry" "$work/before"
check "register --path to a non-toolchain: exit 2" "$(status register ghost --url https://example.invalid/t.tar.gz --path "$work")" 2
check "  registry unchanged" "$(cmp -s "$registry" "$work/before" && echo same)" same
check "register --url with no value: exit 2" "$(status register x --url)" 2
check "  says so" "$(cat "$work/err")" "error: --url needs a value"
check "register --sha256 that isn't hex: exit 2" "$(status register x --url file:///x --sha256 xyz)" 2
check "  registry unchanged" "$(cmp -s "$registry" "$work/before" && echo same)" same
check "register --path to a toolchain" "$(status register a --url file:///nowhere.tar.gz --path "$installed/A.xctoolchain")" 0
check "  records directory and bundle id" "$(jq -r '.toolchains.a | "\(.directory) \(.bundle_id)"' "$registry")" \
    "A.xctoolchain org.example.check-a"
check "a registered name resolves" "$(toolchain_of a)" "$installed/A.xctoolchain"
tc register ghost --url file:///nowhere.tar.gz > /dev/null 2>&1
check "registered but not installed: exit 2" "$(status ghost env)" 2

# install.
craft="$work/craft/one/two/three/src"
mkdir -p "$craft/Library/Developer/Toolchains"
make_toolchain "$craft/Library/Developer/Toolchains/New.xctoolchain" org.example.check-new
echo evil > "$craft/evil"
(cd "$craft" && tar -czf "$work/dotdot.tar.gz" Library/Developer/Toolchains/New.xctoolchain \
    "Library/Developer/Toolchains/../../../evil" 2> /dev/null)
(cd "$craft" && tar -czf "$work/good.tar.gz" Library/Developer/Toolchains/New.xctoolchain)
good_sum="$(shasum -a 256 "$work/good.tar.gz" | cut -d' ' -f1)"
tc register dotdot --url "file://$work/dotdot.tar.gz" > /dev/null 2>&1
check "install a tarball with '..' in a path: exit 2" "$(status install dotdot)" 2
check "  nothing extracted" "$([[ -e $installed/New.xctoolchain ]] && echo yes || echo no)" no
tc register wrongsum --url "file://$work/good.tar.gz" --sha256 "$(printf '0%.0s' {1..64})" > /dev/null 2>&1
check "install with a wrong sha256: exit 2" "$(status install wrongsum)" 2
check "  nothing extracted" "$([[ -e $installed/New.xctoolchain ]] && echo yes || echo no)" no
tc register new --url "file://$work/good.tar.gz" --sha256 "$good_sum" > /dev/null 2>&1
check "  registry has the sha256" "$(jq -r '.toolchains.new.install.sha256' "$registry")" "$good_sum"
check "install with the right sha256" "$(status install new)" 0
check "  recorded" "$(jq -r '.toolchains.new | "\(.directory) \(.bundle_id)"' "$registry")" \
    "New.xctoolchain org.example.check-new"

# test: a fake swift logs its arguments; the fake helper exits with HELPER_STATUS.
mkdir -p "$work/bin" "$work/pkg" "$work/products/P.xctest/Contents/MacOS"
touch "$work/pkg/Package.swift" "$work/products/P.xctest/Contents/MacOS/P"
cat > "$work/bin/swift" << EOF
#!/bin/bash
echo "\$*" >> "$work/swift.log"
[[ "\$*" == *--show-bin-path* ]] && echo "$work/products"
exit 0
EOF
cat > "$installed/A.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper" << 'EOF'
#!/bin/bash
exit "${HELPER_STATUS:-0}"
EOF
chmod +x "$work/bin/swift" "$installed/A.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
check "test (release)" "$(PATH="$work/bin:$PATH" status a test "$work/pkg")" 0
check "  both builds release, no -enable-testing" "$(cat "$work/swift.log")" "build -c release --build-tests
build -c release --show-bin-path"
rm "$work/swift.log"
check "test --debug" "$(PATH="$work/bin:$PATH" status a test --debug "$work/pkg")" 0
check "  both builds debug" "$(cat "$work/swift.log")" "build -c debug --build-tests
build -c debug --show-bin-path"
check "a failing test's status comes back" "$(HELPER_STATUS=5 PATH="$work/bin:$PATH" status a test "$work/pkg")" 5
