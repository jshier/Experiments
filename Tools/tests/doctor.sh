#!/bin/bash
# Tools/doctor in a fake repository, on a PATH of system tools plus fakes: a yq that isn't mikefarah's, a python3 older
# than 3.14, no lz4 or xz, an invalid toolchain registry, Command Line Tools selected instead of Xcode (when they're
# installed), and no developer directory at all. Each is an error row, every run still reports, and the exit is 1.
tools="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-doctor.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

repo="$work/repo"
mkdir -p "$repo/Tools/lib" "$work/bin"
cp "$tools/doctor" "$tools/toolchain" "$repo/Tools/"
cp "$tools/lib/common.sh" "$repo/Tools/lib/"
printf '{ "toolchains": { "x": 1, } }\n' > "$repo/Tools/toolchains.json"
jq="$(command -v jq)" || { echo "FAIL: this check needs jq"; exit 1; }
ln -s "$jq" "$work/bin/jq"
printf '#!/bin/sh\necho "yq 3.4.3"\n' > "$work/bin/yq"
printf '#!/bin/sh\necho 3.12.1\n' > "$work/bin/python3"
chmod +x "$work/bin/yq" "$work/bin/python3"
minimal="$work/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# status ROWS AREA ITEM: the status column of that row
status() { perl -F'\t' -sane 'print $F[2] if $F[0] eq $area && $F[1] eq $item' -- -area="$2" -item="$3" <<< "$1"; }

out="$(PATH="$minimal" "$repo/Tools/doctor" 2> /dev/null)"
check "a broken environment exits 1" "$?" 1
check "yq that isn't mikefarah's" "$(status "$out" brew yq)" error
check "python3 3.12" "$(status "$out" generators python3)" error
check "no lz4" "$(status "$out" generators lz4)" error
check "no xz" "$(status "$out" generators xz)" error
check "aa (macOS)" "$(status "$out" generators aa)" ok
check "an invalid toolchain registry" "$(status "$out" swift "toolchain registry")" error
check "jq" "$(status "$out" brew jq)" ok

if [[ -d /Library/Developer/CommandLineTools ]]; then
    out="$(DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="$minimal" "$repo/Tools/doctor" 2> /dev/null)"
    check "Command Line Tools: exit 1" "$?" 1
    check "Command Line Tools selected" "$(status "$out" swift xcode)" error
    check "  no Instruments templates" "$(status "$out" xcode xctrace-templates)" error
else
    echo "skip: no Command Line Tools installed"
fi

out="$(DEVELOPER_DIR=/nonexistent PATH="$minimal" "$repo/Tools/doctor" 2> /dev/null)"
check "no developer directory: exit 1" "$?" 1
check "  still reports every section" "$(status "$out" generators aea)" ok
check "  xcode row" "$(status "$out" swift xcode)" error
check "  swiftc row" "$(status "$out" swift swiftc)" error
check "  objdump row" "$(status "$out" xcode objdump)" error

check "bad usage: exit 2" "$("$repo/Tools/doctor" --bogus > /dev/null 2>&1; echo $?)" 2

# An awk whose version text is long (head -1 closes the pipe early, so it gets SIGPIPE) doesn't end doctor (141 under
# pipefail): the awk row is still printed, when Homebrew is there to print it.
if command -v brew > /dev/null; then
    mkdir "$work/long-awk"
    printf '#!/usr/bin/perl\nprint "awk version 20240728\\n";\nprint "padding line for the version text\\n" for 1 .. 5000;\n' > "$work/long-awk/awk"
    chmod +x "$work/long-awk/awk"
    out="$(PATH="$work/long-awk:$PATH" "$repo/Tools/doctor" 2> /dev/null)"
    check "a long awk --version: doctor isn't ended by SIGPIPE" "$(( $? == 141 ))" 0
    check "  and prints the awk row" "$(status "$out" brew awk)" note
else
    echo "skip: no Homebrew, so no awk row"
fi
