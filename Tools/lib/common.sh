# Shared helpers for the agent tools in Tools/. Source it from a tool:
#     source "$(dirname "$0")/lib/common.sh"
#
# Conventions for every tool:
# - `--help` prints usage. Results go to stdout (tab-separated where a table makes sense, so `cut`, `sort`,
#   and `column -t -s $'\t'` work); notes and progress go to stderr.
# - Exit status: 0 success, 1 a check failed (an assertion, nothing found), 2 bad usage or missing tool.
# - Xcode tools come through `xcrun`, so `TOOLCHAINS=<bundle id>` selects another toolchain for everything.
# - Text processing uses Perl (always present on macOS), never awk features that differ between versions:
#   macOS's awk and Homebrew's `awk` formula are the one-true-awk, without gawk's `strtonum`, `gensub`, or
#   `\s`. If you need gawk, use $GAWK after `need_gawk`.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPERIMENTS_DIR="$(cd "$TOOLS_DIR/.." && pwd)"

die() { echo "error: $*" >&2; exit 2; }
fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Prints the usage block at the top of the calling script (the comment lines after the shebang).
usage() { perl -ne 'next if $. == 1; last unless /^#/; s/^# ?//; print' "$0"; exit "${1:-0}"; }

# Xcode's tools, through xcrun so TOOLCHAINS applies.
xtool() { xcrun --find "$1" 2>/dev/null || die "xcrun can't find $1 (is Xcode selected? xcode-select -p)"; }
OBJDUMP="$(xtool objdump)"
OTOOL="$(xtool otool)"
NM="$(xtool nm)"
DEMANGLE="$(xtool swift-demangle)"

# Demangles Swift symbols anywhere in stdin, simplified ("static Foo.bar(_:)").
demangle() { "$DEMANGLE" --simplified; }

# Homebrew's LLVM is keg-only: not on PATH. It has what Xcode doesn't ship: llvm-mca, opt, llc, llvm-mc.
# Override with LLVM_BIN=/path/to/bin.
llvm_bin() {
    local dir
    for dir in "${LLVM_BIN:-}" "$(brew --prefix llvm 2>/dev/null || true)/bin" /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin; do
        [[ -n "$dir" && -x "$dir/llvm-mca" ]] && { echo "$dir"; return 0; }
    done
    return 1
}
need_llvm() { LLVM_BIN="$(llvm_bin)" || die "needs Homebrew's LLVM (llvm-mca, opt): brew install llvm"; }

# gawk, if a script really needs it (none of these tools do).
need_gawk() { GAWK="$(command -v gawk || true)"; [[ -n "$GAWK" ]] || die "needs gawk: brew install gawk"; }

# Mach-O file type: "object" (relocatable .o) or "binary" (executable, dylib, bundle).
file_kind() {
    local type
    type="$("$OTOOL" -h "$1" 2>/dev/null | perl -ane 'print $F[4] if $F[0] =~ /^0x/' || true)"
    case "$type" in
        1) echo object ;;
        "") die "$1 isn't a Mach-O file" ;;
        *) echo binary ;;
    esac
}

# Defined text symbols in FILE whose demangled name (or mangled name) contains PATTERN, as
# "mangled<TAB>demangled" lines. PATTERN is a Perl regex; plain words match as substrings.
find_symbols() {
    local file="$1" pattern="$2"
    "$NM" --defined-only "$file" 2>/dev/null | perl -ane 'print "$F[2]\n" if @F >= 3 && $F[1] =~ /^[Tt]$/' | sort -u > "${TMPDIR:-/tmp}/symbols.$$"
    paste "${TMPDIR:-/tmp}/symbols.$$" <(demangle < "${TMPDIR:-/tmp}/symbols.$$") |
        PATTERN="$pattern" perl -ne 'my ($m, $d) = split /\t/; print if $d =~ /$ENV{PATTERN}/ || $m =~ /$ENV{PATTERN}/'
    rm -f "${TMPDIR:-/tmp}/symbols.$$"
}

# Disassembles one symbol (mangled name) with branch targets as labels (<L0>), no raw bytes.
disassemble_symbol() {
    "$OBJDUMP" -d --no-show-raw-insn --symbolize-operands --disassemble-symbols="$2" "$1"
}

# Builds a SwiftPM target (release) and prints the path of one object file with all its code: the target's
# object if it has one, else its objects merged with `ld -r` (relocations and local symbols intact) into
# PACKAGE/.build/agent-tools/TARGET.o. So tools that read one object (loops, calls, mca) take a whole target.
# Honors TOOLCHAINS.
target_object() {
    local package="$1" target="$2" objects=() merged log
    [[ -f "$package/Package.swift" ]] || die "$package isn't a package (no Package.swift)"
    package="$(cd "$package" && pwd)"
    log="$(mktemp "${TMPDIR:-/tmp}/build.XXXXXX")"
    note "building $target (release)…"
    (cd "$package" && swift build -c release --target "$target") > "$log" 2>&1 ||
        { grep -E 'error:' "$log" | head -20 >&2; rm -f "$log"; die "swift build --target $target failed"; }
    rm -f "$log"
    # Xcode-style build system: .build/out/Intermediates.noindex/…/Release/T-t.build (libraries) or T-p.build
    # (executables); native: .build/…/release/T.build. Failing those, the prelinked .build/out/Products/Release/T.o
    # that some builds leave for a dependency's module.
    while IFS= read -r object; do objects+=("$object"); done < <(find "$package/.build" \
        \( -path "*/Release/$target-t.build/Objects-normal/*" -o -path "*/Release/$target-p.build/Objects-normal/*" \
           -o -path "*/release/$target.build/*" \) -name '*.o' 2>/dev/null | sort)
    if [[ ${#objects[@]} -eq 0 && -f "$package/.build/out/Products/Release/$target.o" ]]; then
        objects=("$package/.build/out/Products/Release/$target.o")
    fi
    [[ ${#objects[@]} -gt 0 ]] || die "no objects for $target under $package/.build"
    if [[ ${#objects[@]} -eq 1 ]]; then echo "${objects[0]}"; return 0; fi
    merged="$package/.build/agent-tools/$target.o"
    mkdir -p "$(dirname "$merged")"
    xcrun ld -r -arch arm64 -o "$merged" "${objects[@]}" 2>/dev/null || die "couldn't merge $target's objects with ld -r"
    echo "$merged"
}

# The input of a tool that reads compiled code: `FILE` or `--target PACKAGE_DIR TARGET` at the start of the
# arguments. Sets INPUT (a file) and INPUT_ARGS (how many arguments that took: `shift "$INPUT_ARGS"`).
read_input() {
    if [[ "${1:-}" == --target ]]; then
        [[ $# -ge 3 ]] || usage 2
        INPUT="$(target_object "$2" "$3")"; INPUT_ARGS=3
    else
        [[ $# -ge 1 && -f "$1" ]] || die "no file ${1:-}"
        INPUT="$1"; INPUT_ARGS=1
    fi
}

# Prints the path of a copy of PROGRAM that tools can attach to: signed with the `get-task-allow` entitlement
# (plus any entitlements PROGRAM already had). Without it, Instruments' attaching templates (Allocations,
# Leaks…) and anything else that asks for the task port fail with "Failed to attach to target process", and
# SwiftPM release builds don't have it. Every tool that launches a program launches it through this, so
# results don't depend on how the program was built or signed.
#
# The copy is PROGRAM-debuggable, next to PROGRAM, so @executable_path rpaths and resource bundles still
# resolve. It's re-made only when PROGRAM is newer. If PROGRAM's directory isn't writable, the copy goes in
# $SCRATCH (call scratch_dir first). A program that already has the entitlement is used as is. A process
# that's already running (sample-top --pid) can't be fixed this way: relaunch it from a debuggable copy.
debuggable() {
    local program="$1" copy entitlements
    program="$(command -v "$program" 2>/dev/null || echo "$program")"
    [[ -x "$program" ]] || die "no program $program"
    has_get_task_allow "$program" && { echo "$program"; return 0; }
    copy="$program-debuggable"
    [[ -w "$(dirname "$program")" ]] || copy="${SCRATCH:?call scratch_dir before debuggable}/$(basename "$program")"
    if [[ ! -x "$copy" || "$program" -nt "$copy" ]] || ! has_get_task_allow "$copy"; then
        entitlements="$(mktemp "${TMPDIR:-/tmp}/entitlements.XXXXXX")"
        codesign -d --entitlements - --xml "$program" > "$entitlements" 2>/dev/null || true
        [[ -s "$entitlements" ]] || plutil -create xml1 "$entitlements"
        # plutil key paths split on ".", so the key's dots are escaped. Functions run in $(…) don't get set -e,
        # so every step is checked.
        plutil -insert 'com\.apple\.security\.get-task-allow' -bool YES "$entitlements" > /dev/null &&
            cp -f "$program" "$copy" &&
            codesign -s - -f --entitlements "$entitlements" "$copy" > /dev/null 2>&1 ||
            { rm -f "$entitlements"; die "couldn't sign $copy with get-task-allow"; }
        rm -f "$entitlements"
        has_get_task_allow "$copy" || die "signed $copy, but it still lacks get-task-allow"
    fi
    echo "$copy"
}
has_get_task_allow() {
    codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null | grep -qx true
}

# Runs COMMAND... with a time limit. Exit status: COMMAND's, or 124 if it was killed for running past SECONDS.
# Wrap anything that can block on a macOS authorization prompt the user may not have noticed (Instruments or
# a debugger attaching), so the tool fails with a message instead of hanging.
with_timeout() {
    local seconds="$1" pid second; shift
    "$@" & pid=$!
    for ((second = 0; second < seconds; second++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true; return 124; fi
    wait "$pid"
}
AUTH_HINT="if macOS showed an authorization prompt (Developer Tools access, or attaching to a process), the user has to approve it; ask them, then retry"

# A scratch directory that's removed on exit.
scratch_dir() {
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/experiments-tool.XXXXXX")"
    trap 'rm -rf "$SCRATCH"' EXIT
}
