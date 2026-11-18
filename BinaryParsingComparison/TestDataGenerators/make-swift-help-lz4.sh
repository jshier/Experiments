#!/bin/bash
# Makes swift-help.lz4 in OUTPUT_DIR (default: the repository's TestData/swift-help-lz4, where
# `Tools/test-data fetch swift-help-lz4` puts it): swift-binary-parsing's ELF/swift-help (10.6 MB, downloaded at
# the pinned revision and checked by SHA-256) as an LZ4 frame, compressed with `lz4 -9` (3.8 MB). The benchmarks
# decode it, and the tests check it decodes to the same bytes as ELF/swift-help. Needs Homebrew's lz4.
#
# lz4 1.11.1 makes the file the benchmarks in RESULTS.md measured, byte for byte; another lz4 version may
# compress differently. The file still works then, but instruction counts aren't comparable with earlier runs,
# so this warns.
#
# It writes and deletes only inside the repository's TestData/: OUTPUT_DIR must be there, and the download goes
# to OUTPUT_DIR/.work (removed on exit).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"

url="https://raw.githubusercontent.com/apple/swift-binary-parsing/8f0f56a795e36eff6d532b01e8e94f640e3443dd/Sources/TestData/Data/ELF/swift-help"
source_sha256="809fedf0b5f636fee9dd0fb58135ccfa229a43fee7260a717c1e36ea6cd6fd0a"
expected_sha256="57d6d63976ba5cd9cfeffec42629f2d25efd21ee0ce84da6162ecf914bf349e8"

command -v lz4 >/dev/null || { echo "make-swift-help-lz4: needs lz4 (brew install lz4)" >&2; exit 2; }

out="${1:-$TESTDATA_ROOT/swift-help-lz4}"
in_testdata "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
work="$out/.work"
in_testdata "$work"
rm -rf "$work"
mkdir "$work"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/swift-help" "$url"
[[ "$(shasum -a 256 "$work/swift-help" | cut -d' ' -f1)" == "$source_sha256" ]] || {
    echo "make-swift-help-lz4: the download of ELF/swift-help doesn't match its SHA-256" >&2; exit 1
}

in_testdata "$out/swift-help.lz4"
rm -f "$out/swift-help.lz4"
lz4 -q -9 "$work/swift-help" "$out/swift-help.lz4"
if [[ "$(shasum -a 256 "$out/swift-help.lz4" | cut -d' ' -f1)" != "$expected_sha256" ]]; then
    echo "make-swift-help-lz4: warning: $(lz4 --version 2>&1 | head -1) compressed swift-help differently from lz4" \
        "1.11.1; benchmark results won't be comparable with RESULTS.md" >&2
fi
