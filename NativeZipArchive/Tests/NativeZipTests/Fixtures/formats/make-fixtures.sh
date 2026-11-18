#!/bin/bash
# Builds the format fixtures for FormatTests into OUTPUT_DIR (default: the repository's
# TestData/nativezip-formats, where `Tools/test-data fetch nativezip-formats` puts them). Needs python3 3.14 or
# later (zstd), and macOS's zip and bsdtar (traditional and AES encryption). Run from anywhere.
#
# It writes and deletes only inside the repository's TestData/: OUTPUT_DIR must be there, and the work
# directory is OUTPUT_DIR/.work (removed on exit).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
out="${1:-$TESTDATA_ROOT/nativezip-formats}"
in_testdata "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
work="$out/.work"
in_testdata "$work"
rm -rf "$work"
mkdir "$work"
trap 'rm -rf "$work"' EXIT

python3 -I "$here/make-fixtures.py" "$out" "$work"

# Encryption: ZipCrypto from Info-ZIP's zip (no data descriptor) and bsdtar (with one), AES from bsdtar.
rm -f "$out/zipcrypto.zip"
(cd "$work" && zip -q -P secret "$out/zipcrypto.zip" sample.txt)
for encryption in traditional aes128 aes256; do
    rm -f "$out/bsdtar-$encryption.zip"
    (cd "$work" && bsdtar --format zip --options "zip:encryption=$encryption" --passphrase secret -cf "$out/bsdtar-$encryption.zip" sample.txt)
done

# A self-extractor: data before the archive, offsets not adjusted (as `cat stub archive.zip` makes).
head -c 5000 /bin/ls > "$work/stub"
(cd "$work" && zip -q plain.zip sample.txt)
cat "$work/stub" "$work/plain.zip" > "$out/prefixed.zip"
# The same, adjusted with `zip -A` (offsets count from the file's start).
cp "$out/prefixed.zip" "$out/prefixed-adjusted.zip"
zip -qA "$out/prefixed-adjusted.zip"

# Symbolic links.
mkdir -p "$work/links/dir"
printf 'target\n' > "$work/links/dir/target.txt"
ln -s dir/target.txt "$work/links/link"
rm -f "$out/symlink.zip"
(cd "$work/links" && zip -qry "$out/symlink.zip" .)
