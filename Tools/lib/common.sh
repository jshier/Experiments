# shellcheck shell=bash
# shellcheck disable=SC2034 # The variables set here (EXPERIMENTS_DIR, INPUT, AUTH_HINT, …) are for the tools that source it.
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

# (From this file's path by string operations: the `cd`/`pwd` subshells cost about 15 ms, every tool. A path with `.`
# or `..` components still goes through `cd`, which resolves them.)
_cs_path="${BASH_SOURCE[0]}"
[[ "$_cs_path" == /* ]] || _cs_path="$PWD/$_cs_path"
if [[ "$_cs_path" == */lib/common.sh && "$_cs_path" != */./* && "$_cs_path" != */../* && "$_cs_path" != *//* ]]; then
    TOOLS_DIR="${_cs_path%/lib/common.sh}"
else
    TOOLS_DIR="$(cd "${_cs_path%/*}/.." && pwd)"
fi
EXPERIMENTS_DIR="${TOOLS_DIR%/*}"
unset _cs_path
# Where Tools build their helper executables (C probes, small Objective-C helpers): in ~/Scratch, beside the
# experiments' other outputs, never in ~/Library. `.noindex` keeps Spotlight out.
TOOLS_CACHE="${EXPERIMENTS_TOOLS_CACHE:-$HOME/Scratch/tools-cache.noindex}"

# (The messages can't end the tool themselves: with stderr closed, a failed echo under `set -e` would exit 1.)
# Each message is written by a subshell, so a closed stderr or one whose pipe reader has gone (SIGPIPE) ends only the
# subshell, never the tool.
die() { (echo "error: $*" >&2) || true; exit 2; }
fail() { (echo "FAIL: $*" >&2) || true; exit 1; }
note() { (echo "$*" >&2) || true; }
have() { command -v "$1" >/dev/null 2>&1; }

# Prints the usage block at the top of the calling script (the comment lines after the shebang): on stdout for
# `--help` (status 0), on stderr for bad usage (any other status), so a piped result never holds usage text.
usage() {
    if [[ "${1:-0}" == 0 ]]; then
        perl -ne 'next if $. == 1; last unless /^#/; s/^# ?//; print' "$0"
    else
        perl -ne 'next if $. == 1; last unless /^#/; s/^# ?//; print' "$0" >&2
    fi
    exit "${1:-0}"
}

# An option's value: `need_value "$@"` in a `case` arm, before reading "$2", so a missing value is bad usage
# (exit 2) rather than bash's unbound-variable error (exit 1). `need_number NAME VALUE` also requires a
# non-negative integer; `need_decimal NAME VALUE` a non-negative decimal (seconds, sizes in GB).
need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }
# (No leading zeros: bash's arithmetic reads `010` as octal 8 and `08` as an error. At most 15 digits: bash's
# arithmetic is 64-bit and wraps silently, so 18446744073709551617 would mean 1.)
need_number() { [[ "$2" =~ ^(0|[1-9][0-9]{0,14})$ ]] || die "$1 needs a whole number (at most 15 digits), not '$2'"; }
need_decimal() { [[ "$2" =~ ^(0|[1-9][0-9]{0,14})(\.[0-9]+)?$ ]] || die "$1 needs a number (at most 15 digits), not '$2'"; }

# Xcode's tools, through xcrun so TOOLCHAINS applies: OBJDUMP, OTOOL, NM, DEMANGLE. Looked up by `need_xcode_tools`
# (called by every helper below that uses them, and before any use of the variables), not when sourced: each `xcrun
# --find` costs about 15 ms, and tools that don't read compiled code (doctor, test-data, corpus, job) don't need them
# or Xcode. The four run at once; a missing one stops the tool with the reason.
xtool() { xcrun --find "$1" 2>/dev/null || true; }
OBJDUMP='' OTOOL='' NM='' DEMANGLE=''
need_xcode_tools() {
    local _xt_name _xt_path _xt_missing=''
    if [[ -z "$OBJDUMP" || -z "$OTOOL" || -z "$NM" || -z "$DEMANGLE" ]]; then
        # One "name<TAB>path" line from each lookup, through a pipe: no files to leave behind if the tool is killed.
        while IFS=$'\t' read -r _xt_name _xt_path; do
            case "$_xt_name" in
                objdump) OBJDUMP="$_xt_path" ;;
                otool) OTOOL="$_xt_path" ;;
                nm) NM="$_xt_path" ;;
                swift-demangle) DEMANGLE="$_xt_path" ;;
            esac
        done < <(
            for _xt_name in objdump otool nm swift-demangle; do
                printf '%s\t%s\n' "$_xt_name" "$(xtool "$_xt_name")" &
            done
            wait
        )
    fi
    [[ -n "$OBJDUMP" ]] || _xt_missing+=" objdump"
    [[ -n "$OTOOL" ]] || _xt_missing+=" otool"
    [[ -n "$NM" ]] || _xt_missing+=" nm"
    [[ -n "$DEMANGLE" ]] || _xt_missing+=" swift-demangle"
    [[ -z "$_xt_missing" ]] || die "xcrun can't find${_xt_missing} (is Xcode selected? xcode-select -p)"
}

# Demangles Swift symbols anywhere in stdin, simplified ("static Foo.bar(_:)").
demangle() { need_xcode_tools; "$DEMANGLE" --simplified; }

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

# Builds a SwiftPM target (release) and prints the path of one object file with all its code: the target's
# object if it has one, else its objects merged with `ld -r` (relocations and local symbols intact) into
# PACKAGE/.build/agent-tools/TARGET.o. So tools that read one object (loops, calls, mca) take a whole target.
# Honors TOOLCHAINS. The build log goes in TARGET_LOG_DIR (default TMPDIR); the build itself keeps the caller's TMPDIR,
# where SwiftPM keeps the lock files that make two builds of one package wait for each other.
target_object() {
    local package="$1" target="$2" objects=() merged log
    [[ -f "$package/Package.swift" ]] || die "$package isn't a package (no Package.swift)"
    package="$(cd "$package" && pwd)"
    log="$(mktemp "${TARGET_LOG_DIR:-${TMPDIR:-/tmp}}/build.XXXXXX")"
    note "building $target (release)…"
    (cd "$package" && swift build -c release --target "$target") > "$log" 2>&1 ||
        { perl -ne 'print if /error:/ && ++$n <= 20' "$log" >&2; rm -f "$log"; die "swift build --target $target failed"; }
    rm -f "$log"
    # Xcode-style build system (the default): .build/out/Intermediates.noindex/…/Release/T-t.build (libraries) or
    # T-p.build (executables); the native one: .build/…/release/T.build. One or the other, never both: a package
    # built both ways has both, and merging them gives duplicate symbols (or stale code). Failing those, the
    # prelinked .build/out/Products/Release/T.o that some builds leave for a dependency's module.
    while IFS= read -r object; do objects+=("$object"); done < <(find "$package/.build" \
        \( -path "*/Release/$target-t.build/Objects-normal/*" -o -path "*/Release/$target-p.build/Objects-normal/*" \) \
        -name '*.o' 2>/dev/null | sort)
    if [[ ${#objects[@]} -eq 0 ]]; then
        while IFS= read -r object; do objects+=("$object"); done < <(find "$package/.build" \
            -path "*/release/$target.build/*" -name '*.o' 2>/dev/null | sort)
    fi
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
    need_xcode_tools
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
    local program="$1" copy entitlements signing
    program="$(command -v "$program" 2>/dev/null || echo "$program")"
    [[ -x "$program" ]] || die "no program $program"
    has_get_task_allow "$program" && { echo "$program"; return 0; }
    copy="$program-debuggable"
    [[ -w "$(dirname "$program")" ]] || copy="${SCRATCH:?call scratch_dir before debuggable}/$(basename "$program")"
    if [[ ! -x "$copy" || "$program" -nt "$copy" ]] || ! has_get_task_allow "$copy"; then
        entitlements="$(mktemp "${TMPDIR:-/tmp}/entitlements.XXXXXX")"
        # Copied and signed under a name of its own, then renamed over the copy: two tools making the same copy at
        # once each install a whole signed file (and a copy already running keeps its own inode).
        signing="$(mktemp "$copy.XXXXXX")" || { rm -f "$entitlements"; die "can't create a file beside $copy"; }
        codesign -d --entitlements - --xml "$program" > "$entitlements" 2>/dev/null || true
        [[ -s "$entitlements" ]] || plutil -create xml1 "$entitlements"
        # plutil key paths split on ".", so the key's dots are escaped. Functions run in $(…) don't get set -e,
        # so every step is checked.
        if ! plutil -insert 'com\.apple\.security\.get-task-allow' -bool YES "$entitlements" > /dev/null ||
            ! cp -f "$program" "$signing" ||
            ! chmod "$(stat -f %Lp "$program")" "$signing" ||
            ! codesign -s - -f --entitlements "$entitlements" "$signing" > /dev/null 2>&1 ||
            ! has_get_task_allow "$signing" ||
            ! mv -f "$signing" "$copy"; then
            rm -f "$entitlements" "$signing"
            die "couldn't sign $copy with get-task-allow"
        fi
        rm -f "$entitlements"
    fi
    echo "$copy"
}
# (Compared as a string, not piped to `grep -q`: under pipefail, grep exiting at its match could SIGPIPE plutil
# and turn a match into a failure.)
has_get_task_allow() {
    [[ "$(codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null)" == true ]]
}

# Runs COMMAND... (a program, not a shell function) with a time limit. Exit status: COMMAND's (127 if it can't be
# run), or 124 if it was stopped for running past SECONDS. Wrap anything that can block on a macOS authorization
# prompt the user may not have noticed (Instruments or a debugger attaching), so the tool fails with a message
# instead of hanging. Call it as a simple command in the tool's own shell, redirected to files, as
# `with_timeout 60 xctrace … > "$log" 2>&1 < /dev/null`: not in a pipeline or `$(…)`, where a signal sent to the
# tool's PID doesn't reach the subshell running it.
#
# COMMAND runs in a process group of its own, and it and everything it started are stopped (`stop_tree`) at the
# timeout and when the tool gets INT, TERM, HUP, or QUIT (Ctrl-C, Ctrl-\): a non-interactive bash runs background
# commands with SIGINT ignored, so otherwise xctrace or lldb outlived the tool while its EXIT trap deleted their
# scratch. Then the caller's own traps for those signals are restored and the signal is raised again: with no trap of
# its own (or one that exits), the tool ends with the signal's status (130, 143, 129, 131); a signal the caller set to
# be ignored stays ignored and doesn't stop COMMAND. COMMAND starts with INT and QUIT at their defaults, as a
# foreground command would (bash would otherwise start it with both ignored). COMMAND keeps the tool's standard input, and can write to the
# terminal and set its modes: in its background group SIGTTOU and SIGTTIN are ignored (lldb sets terminal modes; it
# would otherwise be stopped and time out), and a read from the terminal fails with EIO. Locals are prefixed so a
# caller's EXIT trap, run while this function is active, still sees the caller's own variables (sample-top's `pid`).
# Every `sleep` here tolerates being interrupted, so a caller under `set -e` isn't ended by Ctrl-C before the stop.
with_timeout() {
    local _wt_seconds="${1:-}" _wt_pid _wt_start _wt_tenth=0 _wt_rc=0 _wt_saved _wt_signal="" _wt_name _wt_one
    local _wt_had=" " _wt_ignored=" "
    [[ $# -ge 2 ]] || die "with_timeout needs SECONDS and a COMMAND"
    shift
    need_number "with_timeout's seconds" "$_wt_seconds"
    _wt_saved="$(trap -p INT TERM HUP QUIT)"
    # Which signals the caller traps, and which it ignores, one at a time: a trap's own text can mention another
    # signal's name, so the joined listing can't be searched.
    for _wt_name in INT TERM HUP QUIT; do
        _wt_one="$(trap -p "$_wt_name")"
        [[ -z "$_wt_one" ]] || _wt_had+="$_wt_name "
        [[ "$_wt_one" != "trap -- '' SIG$_wt_name" ]] || _wt_ignored+="$_wt_name "
    done
    for _wt_name in INT TERM HUP QUIT; do
        [[ "$_wt_ignored" == *" $_wt_name "* ]] && continue
        # shellcheck disable=SC2064 # The name is fixed now, on purpose.
        trap "_wt_signal=$_wt_name" "$_wt_name"
    done
    # INT and QUIT back to their defaults (bash starts background commands with both ignored, and a shell can't trap a
    # signal ignored at its start): COMMAND handles them as it would in the foreground.
    perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; $SIG{TTOU} = $SIG{TTIN} = "IGNORE"; setpgrp(0, 0); exec { $ARGV[0] } @ARGV;
             print STDERR "with_timeout: can\x27t run $ARGV[0]: $!\n"; exit 127' -- "$@" 0<&0 &
    _wt_pid=$!
    # (The four signals ignored in the substitution: bash gives it, and its `ps`, their defaults while they're trapped. A
    # Ctrl-\ there would leave a crash report, and a hang-up would end a plain call under `set -e` with COMMAND running;
    # the trap above records it either way.)
    _wt_start="$(trap '' INT QUIT HUP TERM; process_start "$_wt_pid")" || true
    # Tenths of a second for the first 2 s (a quick command costs no whole second), then whole seconds.
    while (( _wt_tenth < _wt_seconds * 10 )); do
        [[ -z "$_wt_signal" ]] || break
        kill -0 "$_wt_pid" 2>/dev/null || break
        if (( _wt_tenth < 20 )); then
            _wt_pause 0.1
            _wt_tenth=$(( _wt_tenth + 1 ))
        else
            _wt_pause 1
            _wt_tenth=$(( _wt_tenth + 10 ))
        fi
    done
    if [[ -n "$_wt_signal" ]] || kill -0 "$_wt_pid" 2>/dev/null; then
        stop_tree "$_wt_pid" "$_wt_start"
        wait "$_wt_pid" 2>/dev/null || true
        _wt_rc=124
    else
        wait "$_wt_pid" || _wt_rc=$?
        # A signal during that wait interrupts it: COMMAND may still be running.
        if [[ -n "$_wt_signal" ]] && kill -0 "$_wt_pid" 2>/dev/null; then
            stop_tree "$_wt_pid" "$_wt_start"
            wait "$_wt_pid" 2>/dev/null || true
        fi
    fi
    # The caller's traps back first, then defaults for the signals it had none for: no moment with neither in place.
    eval "$_wt_saved"
    for _wt_name in INT TERM HUP QUIT; do
        [[ "$_wt_had" == *" $_wt_name "* ]] || trap - "$_wt_name"
    done
    if [[ -n "$_wt_signal" ]]; then
        # Bash runs its EXIT trap when INT, TERM, or HUP ends it, but not QUIT (which also leaves a crash report): with
        # no QUIT trap of the caller's, exit with QUIT's status instead, so the caller's cleanup runs.
        if [[ "$_wt_signal" == QUIT && "$_wt_had" != *" QUIT "* ]]; then
            exit 131
        fi
        kill -s "$_wt_signal" $$
        case "$_wt_signal" in INT) return 130 ;; TERM) return 143 ;; HUP) return 129 ;; *) return 131 ;; esac
    fi
    return "$_wt_rc"
}

# with_timeout's poll interval. A foreground `sleep` killed by a terminal's Ctrl-\ (sent to the tool's whole group)
# leaves a crash report each time; one started with `&` starts with INT and QUIT ignored, and a signal the shell traps
# ends the `wait` on it at once (then the sleep is stopped). A signal the tool ignores doesn't cut the pause short.
_wt_pause() {
    local _wp_pid _wp_rc=0
    sleep "$1" &
    _wp_pid=$!
    wait "$_wp_pid" 2>/dev/null || _wp_rc=$?
    if (( _wp_rc > 128 )); then
        kill "$_wp_pid" 2>/dev/null || true
        wait "$_wp_pid" 2>/dev/null || true
    fi
}

# A process's start time (`ps -o lstart`, whitespace collapsed), or nothing when it's gone: with its PID, it names one
# process, so a PID reused by another is told apart. Always in the C locale and UTC: `ps` formats it in the caller's
# TZ and LC_TIME, so two tools in different environments would otherwise read one process's start as two.
process_start() {
    local _ps_when
    _ps_when="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null || true)"
    # shellcheck disable=SC2086 # Unquoted on purpose: word splitting collapses ps's padding.
    echo $_ps_when
}

# Stops PID (started at START, if given) and every process it started, and nothing else. Its descendants are listed
# with their start times, so a PID reused meanwhile is left alone: xctrace's program and DTServiceHub, and lldb's
# debugserver and program, run in process groups of their own and outlive their parent. xctrace gets INT first, its own
# "stop recording", which also ends the program it launched. A stopped process is continued, so it can act on the TERM.
#
# A PID that names another process now (not started at START) is left alone, its group too; a PID that's gone still
# has its group stopped (members it left behind: a PID isn't reused while its group exists).
#
# The work runs in a background subshell, which a non-interactive bash starts with INT and QUIT ignored (its helpers
# inherit that), so a second Ctrl-C can't kill a helper midway; the caller's shell only waits for it, so its own traps
# stay in place and still see the Ctrl-C (with_timeout raises it again afterwards).
stop_tree() {
    local _st_helper _st_rc
    _stop_tree_now "$@" &
    _st_helper=$!
    # A trapped signal interrupts `wait` (status over 128) while the helper goes on: wait again until it has ended.
    while true; do
        _st_rc=0
        wait "$_st_helper" 2>/dev/null || _st_rc=$?
        (( _st_rc > 128 && _st_rc != 255 )) || break
        kill -0 "$_st_helper" 2>/dev/null || break
    done
}

_stop_tree_now() {
    local _st_pid="$1" _st_start="${2:-}" _st_tree=() _st_entry _st_tenth _st_signal _st_sent _st_now
    # A hang-up or TERM sent to the whole process group (a closed terminal) mustn't end the stop halfway either.
    trap '' HUP TERM
    _st_now="$(process_start "$_st_pid")"
    [[ -n "$_st_start" ]] || _st_start="$_st_now"
    if [[ -z "$_st_now" ]]; then
        # Gone: only its group can be left (with START, stop_group signals no lone process that took the PID since).
        stop_group "$_st_pid" "$_st_start"
        return 0
    fi
    [[ "$_st_now" == "$_st_start" ]] || return 0
    while IFS= read -r _st_entry; do _st_tree+=("$_st_entry"); done < <(descendants "$_st_pid")
    if [[ "$(ps -o comm= -p "$_st_pid" 2>/dev/null || true)" == *xctrace ]]; then
        kill -INT "$_st_pid" 2>/dev/null || true
        for ((_st_tenth = 0; _st_tenth < 150; _st_tenth++)); do
            [[ "$(process_start "$_st_pid")" == "$_st_start" ]] || break
            sleep 0.1 || true
        done
    fi
    # Again, while PID is still the same process: a program started while the command was starting up is its
    # descendant only now.
    if [[ "$(process_start "$_st_pid")" == "$_st_start" ]]; then
        while IFS= read -r _st_entry; do _st_tree+=("$_st_entry"); done < <(descendants "$_st_pid")
    fi
    stop_group "$_st_pid" "$_st_start"
    for _st_signal in TERM KILL; do
        _st_sent="$(printf '%s\n' "${_st_tree[@]+"${_st_tree[@]}"}" | signal_listed "$_st_signal")" || _st_sent=unknown
        [[ $_st_signal == TERM && "$_st_sent" != 0 ]] || break
        # Up to 2 s by the clock for them to end on TERM, but no longer than they take: one process polls (a loop of
        # sleeps and `ps` runs here took 2.6–3.3 s under load), and prints how many are still there.
        _st_sent="$(printf '%s\n' "${_st_tree[@]+"${_st_tree[@]}"}" | wait_listed 2)" || _st_sent=unknown
        [[ "$_st_sent" != 0 ]] || break
    done
}

# Waits up to SECONDS (by the clock) for every "PID START-TIME" line on standard input to be gone (no process with that
# PID and start time), polling every 0.1 s; prints how many are still there (all of them when the last `ps` failed).
wait_listed() {
    perl -MTime::HiRes=time,sleep -e '
        my $deadline = time + shift;
        @ENV{"LC_ALL", "TZ"} = ("C", "UTC0");  # As process_start and descendants read start times.
        my @listed;
        while (<STDIN>) {
            chomp;
            my ($pid, $when) = split / /, $_, 2;
            push @listed, [$pid, $when] if defined $pid && defined $when;
        }
        while (1) {
            my %now;
            my @table = `ps -A -o pid=,lstart=`;
            # A failed ps (it always lists itself) knows nothing: every listed process counts as still there.
            my $known = $? == 0 && @table;
            for (@table) {
                my ($pid, @when) = split;
                $now{$pid} = "@when";
            }
            my $left = $known ? (grep { defined $now{$_->[0]} && $now{$_->[0]} eq $_->[1] } @listed) : @listed;
            if ($left == 0 || time >= $deadline) {
                print "$left\n";
                exit 0;
            }
            sleep 0.1;
        }' "$1"
}

# Prints "PID START-TIME" for every descendant of PID, from one snapshot of the process table. A failed `ps` (it
# always lists itself) is tried again for up to 1 s; then the call fails with a note, printing nothing.
descendants() {
    perl -e '
        my $root = shift;
        my (%children, %start, @table);
        @ENV{"LC_ALL", "TZ"} = ("C", "UTC0");  # As process_start reads start times.
        for my $try (1 .. 10) {
            @table = `ps -A -o pid=,ppid=,lstart=`;
            last if $? == 0 && @table;
            @table = ();
            select undef, undef, undef, 0.1;
        }
        unless (@table) {
            print STDERR "note: the process table could not be read: the descendants of $root are not listed\n";
            exit 1;
        }
        for (@table) {
            my ($pid, $parent, @when) = split;
            push @{$children{$parent}}, $pid;
            $start{$pid} = "@when";
        }
        my @todo = ($root);
        while (@todo) {
            for my $child (@{$children{shift @todo} || []}) {
                print "$child $start{$child}\n";
                push @todo, $child;
            }
        }' "$1"
}

# Sends SIGNAL to each "PID START-TIME" line on standard input whose process still has that start time (and CONT
# after anything but KILL or 0, so a stopped process acts on it); prints how many it signalled (with 0: how many are
# still there). Fails, printing nothing, when the process table can't be read.
signal_listed() {
    perl -e '
        my $signal = shift;
        my (%now, @table);
        @ENV{"LC_ALL", "TZ"} = ("C", "UTC0");  # As process_start and descendants read start times.
        # A failed ps (it always lists itself; fork can fail under load) is tried again for up to 1 s, then the call
        # fails (nothing printed), so the caller goes on to its next step rather than read "none left".
        for my $try (1 .. 10) {
            @table = `ps -A -o pid=,lstart=`;
            last if $? == 0 && @table;
            @table = ();
            select undef, undef, undef, 0.1;
        }
        exit 1 unless @table;
        for (@table) {
            my ($pid, @when) = split;
            $now{$pid} = "@when";
        }
        my $sent = 0;
        while (<STDIN>) {
            chomp;
            my ($pid, $when) = split / /, $_, 2;
            next unless defined $pid && defined $when && defined $now{$pid} && $now{$pid} eq $when;
            kill $signal, $pid;
            kill "CONT", $pid unless $signal eq "KILL" || $signal eq "0";
            $sent++;
        }
        print "$sent\n";' "$1"
}

# Stops process group PGID: TERM and CONT, then KILL whatever is left after 5 s. Before the leader has made its group,
# the leader alone. With START, nothing is signalled when PGID names a process that started at another time (a reused
# PID, so the group is that process's); when no process has the PID, its group is stopped (a PID isn't reused while a
# group with its number exists).
stop_group() {
    local _sg_pgid="$1" _sg_start="${2:-}" _sg_tenth _sg_now
    if [[ -n "$_sg_start" ]]; then
        _sg_now="$(process_start "$_sg_pgid")"
        [[ -z "$_sg_now" || "$_sg_now" == "$_sg_start" ]] || return 0
    fi
    if kill -TERM -- "-$_sg_pgid" 2>/dev/null; then
        kill -CONT -- "-$_sg_pgid" 2>/dev/null || true
    elif [[ -z "$_sg_start" || "$(process_start "$_sg_pgid")" == "$_sg_start" ]]; then
        kill -TERM "$_sg_pgid" 2>/dev/null || return 0
        kill -CONT "$_sg_pgid" 2>/dev/null || true
    else
        return 0
    fi
    for ((_sg_tenth = 0; _sg_tenth < 50; _sg_tenth++)); do
        kill -0 -- "-$_sg_pgid" 2>/dev/null || [[ -n "$_sg_start" && "$(process_start "$_sg_pgid")" == "$_sg_start" ]] ||
            return 0
        sleep 0.1 || true
    done
    kill -KILL -- "-$_sg_pgid" 2>/dev/null || true
    if [[ -n "$_sg_start" && "$(process_start "$_sg_pgid")" == "$_sg_start" ]]; then
        kill -KILL "$_sg_pgid" 2>/dev/null || true
    fi
}

# Prints the path of an executable built from SOURCE with `xcrun clang ARGS…`, in TOOLS_CACHE, named NAME plus a
# key of the source, the headers beside it, the arguments, and the compiler: two checkouts (or a source edit older
# than the binary) can't run each other's builds, and parallel first runs don't race (each compiles to its own file,
# then renames). Headers elsewhere aren't in the key: keep a tool's own headers in its source's directory.
compiled_tool() {
    local name="$1" source_file="$2" key binary building header
    shift 2
    [[ -f "$source_file" ]] || die "no source $source_file"
    key="$({
        cat "$source_file"
        for header in "$(dirname "$source_file")"/*.h; do
            [[ -f "$header" ]] && cat "$header"
        done
        printf '%s\n' "$@"
        xcrun clang --version 2>/dev/null | head -1
    } | shasum -a 256 | cut -c1-16)"
    binary="$TOOLS_CACHE/$name-$key"
    if [[ ! -x "$binary" ]]; then
        mkdir -p "$TOOLS_CACHE" || die "can't create $TOOLS_CACHE"
        # mktemp, not $$: subshells of one script share $$ (bash 3.2 has no BASHPID).
        building="$(mktemp "$binary.XXXXXX")" || die "can't create a file in $TOOLS_CACHE"
        xcrun clang "$@" -o "$building" "$source_file" >&2 || { rm -f "$building"; die "couldn't compile $source_file"; }
        # Another run may have installed the same binary meanwhile: that's as good.
        mv -f "$building" "$binary" || [[ -x "$binary" ]] || die "couldn't install $binary"
    fi
    echo "$binary"
}
AUTH_HINT="if macOS showed an authorization prompt (Developer Tools access, or attaching to a process), the user has to approve it; ask them, then retry"

# A scratch directory that's removed on exit.
scratch_dir() {
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/experiments-tool.XXXXXX")"
    trap 'rm -rf "$SCRATCH"' EXIT
}
