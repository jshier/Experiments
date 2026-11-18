#!/bin/bash
# Builds NativeAEA's benchmark archive into OUTPUT_DIR (default: the repository's TestData/nativeaea-synthetic,
# where `Tools/test-data fetch nativeaea-synthetic` puts it): an Apple Archive stream laid out like Xcode's
# (make-stream.py), in a signed profile 0 container made by Apple's `aea` with Xcode's settings (LZMA, 16 MiB
# segments, SHA-256 checksums), and the signing public key to verify it with.
#
# It writes and deletes only inside the repository's TestData/: OUTPUT_DIR must be there; the work directory is
# OUTPUT_DIR/.work (removed on exit). The signature differs each time (a new key, and ECDSA is randomized); the
# archived files don't.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
out="${1:-$TESTDATA_ROOT/nativeaea-synthetic}"
in_testdata "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
work="$out/.work"
in_testdata "$work"
rm -rf "$work"
mkdir "$work"
trap 'rm -rf "$work"' EXIT

python3 -I "$here/make-stream.py" "$work/synthetic.aar"
# `aea` rejects private keys whose scalar DER shortens (a leading zero byte): make another until it's 32 bytes.
while :; do
    openssl ecparam -name prime256v1 -genkey -noout -out "$work/signing.pem"
    openssl ec -in "$work/signing.pem" -outform DER -out "$work/signing.der" 2>/dev/null
    [[ "$(xxd -s 5 -l 2 -p "$work/signing.der")" == "0420" ]] && break
done
in_testdata "$out/signing.pub.pem"
openssl ec -in "$work/signing.pem" -pubout -out "$out/signing.pub.pem" 2>/dev/null
in_testdata "$out/synthetic.aea"
rm -f "$out/synthetic.aea"
aea encrypt -profile 0 -i "$work/synthetic.aar" -o "$out/synthetic.aea" -sign-priv "$work/signing.pem" \
    -a lzma -b 16m -checksum sha256
