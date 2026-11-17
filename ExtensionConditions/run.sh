#!/bin/bash
# Checks what a build can know about being for an app extension, at the compiler and in Xcode:
#   ./run.sh               compiler checks, build settings, a Release build's commands and binaries,
#                          and the negative builds that must fail (or warn)
#   ./run.sh --simulator   also runs the app on an iOS simulator and prints the conditions it reports
# Builds go to .build/DerivedData; logs to a temporary directory (kept with --keep).
set -u
cd "$(dirname "$0")" || exit 2

simulator=0 keep=0
for arg in "$@"; do
    case $arg in
        --simulator) simulator=1 ;;
        --keep) keep=1 ;;
        -h|--help) sed -n '2,6p' "$0" | cut -c3-; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

command -v jq > /dev/null || { echo "needs jq" >&2; exit 2; }
OUT=$(mktemp -d) || exit 2
if [ $keep = 1 ]; then echo "logs: $OUT" >&2; else trap 'rm -rf "$OUT"' EXIT; fi
PROJECT=ExtensionConditions.xcodeproj
DERIVED="$PWD/.build/DerivedData"
SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
passed=0 failed=0

check() { # DESCRIPTION COMMAND...: runs COMMAND, records PASS or FAIL
    local description=$1; shift
    if "$@"; then echo "PASS  $description"; passed=$((passed + 1))
    else echo "FAIL  $description"; failed=$((failed + 1)); fi
}
section() { printf '\n== %s\n' "$1"; }
contains() { grep -q -F -- "$2" "$1"; }      # FILE TEXT
lacks() { ! grep -q -F -- "$2" "$1"; }       # FILE TEXT
same() { [ "$1" = "$2" ]; }

xcbuild() { # LOG SCHEME CONFIGURATION [SETTING=VALUE...]: a clean arm64 simulator build
    local log=$1 scheme=$2 configuration=$3; shift 3
    xcodebuild clean build -project "$PROJECT" -scheme "$scheme" -configuration "$configuration" \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
        ARCHS=arm64 CODE_SIGNING_ALLOWED=NO "$@" > "$log" 2>&1
}

# ---------------------------------------------------------------------------------------------------------
section "Compiler: what -application-extension changes"

TRIPLE=arm64-apple-ios26.0-simulator
: > "$OUT/empty.c"
xcrun clang -target $TRIPLE -isysroot "$SDK_PATH" -dM -E "$OUT/empty.c" | sort > "$OUT/clang-app.txt"
xcrun clang -target $TRIPLE -isysroot "$SDK_PATH" -fapplication-extension -dM -E "$OUT/empty.c" \
    | sort > "$OUT/clang-appex.txt"
echo "clang predefines $(wc -l < "$OUT/clang-app.txt" | tr -d ' ') macros"
check "clang: -fapplication-extension defines no macro (predefines identical)" \
    cmp -s "$OUT/clang-app.txt" "$OUT/clang-appex.txt"

cat > "$OUT/conditions.swift" <<'EOF'
#if targetEnvironment(applicationExtension)
#error("targetEnvironment(applicationExtension) is true")
#endif
#if targetEnvironment(notARealEnvironment)
#error("targetEnvironment(notARealEnvironment) is true")
#endif
EOF
xcrun swiftc -target $TRIPLE -sdk "$SDK_PATH" -application-extension -typecheck "$OUT/conditions.swift" \
    > "$OUT/swift-conditions.txt" 2>&1
swift_status=$?
check "swift: targetEnvironment(applicationExtension) is false under -application-extension" same $swift_status 0
check "swift: ...and unknown targetEnvironment values get no diagnostic" \
    same "$(wc -c < "$OUT/swift-conditions.txt" | tr -d ' ')" 0

frontend_args() { # extra driver flags: the frontend job's arguments, one per line
    xcrun swiftc -target $TRIPLE -sdk "$SDK_PATH" "$@" -typecheck "$OUT/conditions.swift" -### 2>&1 \
        | head -1 | tr ' ' '\n' | grep -v -F "$OUT"
}
frontend_args > "$OUT/frontend-app.txt"
frontend_args -application-extension > "$OUT/frontend-appex.txt"
echo "frontend arguments added by -application-extension: $(diff "$OUT/frontend-app.txt" \
    "$OUT/frontend-appex.txt" | grep '^>' | cut -c3- | tr '\n' ' ')"
check "swift driver: the only frontend difference is -application-extension (same -target)" \
    same "$(diff "$OUT/frontend-app.txt" "$OUT/frontend-appex.txt" | grep -c '^[<>]')" 1

# ---------------------------------------------------------------------------------------------------------
section "Build settings (Release, iOS simulator)"

settings() { # TARGET: settings as JSON
    xcodebuild -showBuildSettings -json -project "$PROJECT" -target "$1" -configuration Release \
        -sdk iphonesimulator 2>/dev/null | jq '.[0].buildSettings'
}
names='PRODUCT_TYPE WRAPPER_EXTENSION APPLICATION_EXTENSION_API_ONLY SWIFT_ACTIVE_COMPILATION_CONDITIONS
       SWIFT_PLATFORM_TARGET_PREFIX LLVM_TARGET_TRIPLE_VENDOR LLVM_TARGET_TRIPLE_SUFFIX'
for target in ExtensionConditions WidgetExtension SharedKit AppOnlyKit; do
    settings $target > "$OUT/settings-$target.json"
done
{
    printf 'setting'; for t in ExtensionConditions WidgetExtension SharedKit AppOnlyKit; do printf '\t%s' $t; done; echo
    for name in $names; do
        printf '%s' "$name"
        for t in ExtensionConditions WidgetExtension SharedKit AppOnlyKit; do
            printf '\t%s' "$(jq -r --arg n "$name" '.[$n] // "-" | if . == "" or (test("^ +$")) then "(empty)" else . end' \
                "$OUT/settings-$t.json" | sed 's/^ *//; s/com.apple.product-type.//')"
        done
        echo
    done
} | column -t -s $'\t'
setting() { jq -r --arg n "$2" '.[$n]' "$OUT/settings-$1.json"; } # TARGET NAME
has_condition() { setting "$1" SWIFT_ACTIVE_COMPILATION_CONDITIONS | tr ' ' '\n' | grep -q -x "$2"; }
check "the triple's parts are the same for the app and the extension" same \
    "$(for k in SWIFT_PLATFORM_TARGET_PREFIX LLVM_TARGET_TRIPLE_VENDOR LLVM_TARGET_TRIPLE_SUFFIX; do setting ExtensionConditions $k; done)" \
    "$(for k in SWIFT_PLATFORM_TARGET_PREFIX LLVM_TARGET_TRIPLE_VENDOR LLVM_TARGET_TRIPLE_SUFFIX; do setting WidgetExtension $k; done)"
check "derived APPEX_PRODUCT (from WRAPPER_EXTENSION) is set only for the extension" \
    eval 'has_condition WidgetExtension APPEX_PRODUCT && ! has_condition ExtensionConditions APPEX_PRODUCT && ! has_condition SharedKit APPEX_PRODUCT'
check "derived APP_EXTENSION_API (from APPLICATION_EXTENSION_API_ONLY) is also set for the extension-safe framework" \
    eval 'has_condition WidgetExtension APP_EXTENSION_API && has_condition SharedKit APP_EXTENSION_API && ! has_condition ExtensionConditions APP_EXTENSION_API'

# ---------------------------------------------------------------------------------------------------------
section "Release build: compile commands"

xcbuild "$OUT/release.log" ExtensionConditions Release
check "Release build succeeds" contains "$OUT/release.log" "** BUILD SUCCEEDED **"
check "no compiler warnings in the project's sources" \
    eval "! grep -E '^$PWD/.*: warning:' '$OUT/release.log'"

compile_args() { # MODULE: its swiftc arguments in the build log, one per line
    grep -m1 -E "builtin-SwiftDriver .* -module-name $1 " "$OUT/release.log" | tr ' ' '\n'
}
for module in ExtensionConditions WidgetExtension SharedKit AppOnlyKit; do
    compile_args $module > "$OUT/args-$module.txt"
    printf '%-20s -target %-34s %-24s %s\n' "$module" "$(grep -A1 -x -- -target "$OUT/args-$module.txt" | tail -1)" \
        "$(grep -x -- -application-extension "$OUT/args-$module.txt" || echo '(no -application-extension)')" \
        "$(grep -E '^-D' "$OUT/args-$module.txt" | tr '\n' ' ')"
done
target_of() { grep -A1 -x -- -target "$OUT/args-$1.txt" | tail -1; }
check "app and extension compile with the same -target" same "$(target_of ExtensionConditions)" "$(target_of WidgetExtension)"
check "the extension compiles with -application-extension, the app without" \
    eval 'grep -q -x -- -application-extension "$OUT/args-WidgetExtension.txt" && ! grep -q -x -- -application-extension "$OUT/args-ExtensionConditions.txt"'
check "SharedKit is compiled once (one compile command for both clients)" \
    same "$(grep -c -E 'builtin-SwiftDriver .* -module-name SharedKit ' "$OUT/release.log")" 1

# ---------------------------------------------------------------------------------------------------------
section "Release build: what each binary contains"

PRODUCTS="$DERIVED/Build/Products/Release-iphonesimulator"
APP_BIN="$PRODUCTS/ExtensionConditions.app/ExtensionConditions"
APPEX_BIN="$PRODUCTS/ExtensionConditions.app/PlugIns/WidgetExtension.appex/WidgetExtension"
KIT_BIN="$PRODUCTS/ExtensionConditions.app/Frameworks/SharedKit.framework/SharedKit"
ONLY_BIN="$PRODUCTS/ExtensionConditions.app/Frameworks/AppOnlyKit.framework/AppOnlyKit"
for name in APP_BIN APPEX_BIN KIT_BIN ONLY_BIN; do
    eval "file=\$$name"
    strings -a "$file" | grep '^MARK ' | sort > "$OUT/markers-$name.txt"
    printf '%s (%s):\n' "${file#"$PRODUCTS"/}" "$name"; sed 's/^/    /' "$OUT/markers-$name.txt"
done
check "shared source file, app: no extension conditions" \
    eval 'contains "$OUT/markers-APP_BIN.txt" "MARK SharedSource compiled" && lacks "$OUT/markers-APP_BIN.txt" "MARK SharedSource APP"'
check "shared source file, extension: both extension conditions" \
    eval 'contains "$OUT/markers-APPEX_BIN.txt" "MARK SharedSource APPEX_PRODUCT" && contains "$OUT/markers-APPEX_BIN.txt" "MARK SharedSource APP_EXTENSION_API"'
check "no binary has the targetEnvironment(applicationExtension) branch" \
    eval '! cat "$OUT"/markers-*.txt | grep -q targetEnvironment'
check "SharedKit was compiled with its own conditions (APP_EXTENSION_API, not APPEX_PRODUCT)" \
    eval 'contains "$OUT/markers-KIT_BIN.txt" "MARK SharedKit APP_EXTENSION_API" && lacks "$OUT/markers-KIT_BIN.txt" "MARK SharedKit APPEX_PRODUCT"'
check "@inlinable SharedKit code inlined into the extension carries SharedKit's branch, not the extension's" \
    eval 'contains "$OUT/markers-APPEX_BIN.txt" "MARK SharedKit inlinable APP_EXTENSION_API" && lacks "$OUT/markers-APPEX_BIN.txt" "MARK SharedKit inlinable APPEX_PRODUCT"'
check "...and inlined into the app it carries the same branch (APP_EXTENSION_API in an app)" \
    contains "$OUT/markers-APP_BIN.txt" "MARK SharedKit inlinable APP_EXTENSION_API"

interface=$(ls "$PRODUCTS"/SharedKit.framework/Modules/SharedKit.swiftmodule/*.swiftinterface | grep -v private | head -1)
echo "SharedKit.swiftinterface, inlinableConditions:"
perl -ne 'print "    $_" if /inlinableConditions/../^  \}/' "$interface"
check "the .swiftinterface keeps only the active #if branch of @inlinable code" \
    eval 'grep -q "MARK SharedKit inlinable APP_EXTENSION_API" "$interface" && ! grep -q "MARK SharedKit inlinable APPEX_PRODUCT" "$interface"'

xcrun nm "$APPEX_BIN" | xcrun swift-demangle > "$OUT/nm-appex.txt"
xcrun nm "$APP_BIN" | xcrun swift-demangle > "$OUT/nm-app.txt"
check "the app-only openSettings() from the shared file is in the app's binary" \
    contains "$OUT/nm-app.txt" "SharedSource.openSettings()"
check "...and not in the extension's" lacks "$OUT/nm-appex.txt" "SharedSource.openSettings()"
check "SharedKit.openSettings() (unavailable to extensions) is still compiled into SharedKit" \
    eval 'xcrun nm "$KIT_BIN" | xcrun swift-demangle | grep -q -F "SharedKit.openSettings()"'
check "the extension links SharedKit but not AppOnlyKit" \
    eval 'otool -L "$APPEX_BIN" | grep -q SharedKit.framework && ! otool -L "$APPEX_BIN" | grep -q AppOnlyKit'
check "the extension's binary has no AppOnlyKit code" lacks "$OUT/markers-APPEX_BIN.txt" "MARK AppOnlyKit"
check "SharedKit (APPLICATION_EXTENSION_API_ONLY = YES) has the Mach-O APP_EXTENSION_SAFE flag" \
    eval 'otool -hv "$KIT_BIN" | grep -q APP_EXTENSION_SAFE'

# ---------------------------------------------------------------------------------------------------------
section "Negative builds"

xcbuild "$OUT/neg-unguarded.log" ExtensionConditions Release OTHER_SWIFT_FLAGS='$(inherited) -DNEG_UNGUARDED_SHARED_SOURCE'
grep -E 'error:.*unavailable' "$OUT/neg-unguarded.log" | sed 's|^.*/||' | sort -u | head -3
# (The app embeds the widget, so it isn't compiled after this failure; that the app compiles the same
# call is shown by the Release build, whose app binary has SharedSource.openSettings().)
check "unguarded UIApplication.shared in the shared file: error, in the extension's compile" \
    eval 'grep -q -E "SharedSource.swift:.*error: .*unavailable in application extensions" "$OUT/neg-unguarded.log" &&
          grep -A3 "The following build commands failed" "$OUT/neg-unguarded.log" | grep -q "SwiftCompile .*in target .WidgetExtension."'

xcbuild "$OUT/neg-call.log" WidgetExtension Release OTHER_SWIFT_FLAGS='$(inherited) -DNEG_EXTENSION_CALLS_UNAVAILABLE'
grep -E 'error:' "$OUT/neg-call.log" | sed 's|^.*/||' | sort -u | head -2
check "the extension calling @available(iOSApplicationExtension, unavailable) SharedKit API: error" \
    eval 'grep -E "Widget.swift:.*error: .openSettings\(\). is unavailable in application extensions" "$OUT/neg-call.log" > /dev/null'

xcbuild "$OUT/neg-unannotated.log" SharedKit Release OTHER_SWIFT_FLAGS='$(inherited) -DNEG_UNANNOTATED_IN_FRAMEWORK'
grep -E 'error:' "$OUT/neg-unannotated.log" | sed 's|^.*/||' | sort -u | head -2
check "unannotated extension-unsafe API in an extension-safe framework: error" \
    eval 'grep -E "SharedKit.swift:.*error: .*unavailable in application extensions" "$OUT/neg-unannotated.log" > /dev/null'

# Older linkers warned "linking against a dylib which is not safe for use in application extensions";
# Xcode 27's ld (27106) doesn't, even linking by hand with -fapplication-extension. Record what happens.
xcbuild "$OUT/neg-unsafe-framework.log" ExtensionConditions Release SHAREDKIT_EXTENSION_SAFE=NO
check "SharedKit built without APPLICATION_EXTENSION_API_ONLY lacks the Mach-O APP_EXTENSION_SAFE flag" \
    eval '! otool -hv "$KIT_BIN" | grep -q APP_EXTENSION_SAFE'
check "...the extension still builds and links it" contains "$OUT/neg-unsafe-framework.log" "** BUILD SUCCEEDED **"
echo "linker diagnostics about extension safety: $(grep -c -i 'safe for use in application extensions' "$OUT/neg-unsafe-framework.log")"

# Leave a normal build behind.
xcbuild "$OUT/release-again.log" ExtensionConditions Release

# ---------------------------------------------------------------------------------------------------------
if [ $simulator = 1 ]; then
    section "Run the app on a simulator"
    device=$(xcrun simctl list devices available -j | jq -r '.devices | to_entries
        | map(select(.key | test("iOS-2[6-9]"))) | sort_by(.key) | reverse | .[].value[]
        | select(.name | test("iPhone")) | .udid' | head -1)
    if [ -z "$device" ]; then
        echo "no available iPhone simulator with iOS 26 or later" >&2; failed=$((failed + 1))
    else
        xcrun simctl boot "$device" 2> /dev/null
        xcrun simctl bootstatus "$device" > /dev/null
        xcrun simctl install "$device" "$PRODUCTS/ExtensionConditions.app"
        bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PRODUCTS/ExtensionConditions.app/Info.plist")
        xcrun simctl launch --terminate-running-process --console-pty "$device" "$bundle_id" > "$OUT/console.txt" 2>&1 &
        launch=$!
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do grep -q RESULT "$OUT/console.txt" && break; sleep 1; done
        kill $launch 2> /dev/null; xcrun simctl terminate "$device" "$bundle_id" 2> /dev/null
        grep RESULT "$OUT/console.txt" | tr -d '\r'
        check "the app reports isRunningInExtension: false at run time" \
            eval 'grep -q "isRunningInExtension: false" "$OUT/console.txt"'
    fi
fi

printf '\n%d passed, %d failed\n' $passed $failed
[ $failed = 0 ]
