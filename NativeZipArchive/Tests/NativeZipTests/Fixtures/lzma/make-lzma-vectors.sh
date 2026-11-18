#!/bin/bash
# Makes the LZMA (zip method 14) test vectors for LZMADecoderTests in OUTPUT_DIR (default: the repository's
# TestData/nativezip-lzma, where `Tools/test-data fetch nativezip-lzma` puts them): `NAME.lzma` payloads and
# `vectors.tsv`, which names the generator, size, and seed LZMADecoderTests uses to rebuild each input.
# Needs python3 and Homebrew's xz (for liblzma, called through ctypes: see make-lzma-vectors.py).
#
#   make-lzma-vectors.sh [OUTPUT_DIR]                                 # the vectors
#   make-lzma-vectors.sh --payload IN OUT [--dict SIZE] [--marker]   # one payload, for measuring
#
# It writes only inside the repository's TestData/: OUTPUT_DIR and a payload's OUT must be there.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
command -v brew >/dev/null || { echo "make-lzma-vectors: needs Homebrew's xz" >&2; exit 2; }
liblzma="$(brew --prefix xz)/lib/liblzma.dylib"
[[ -f "$liblzma" ]] || { echo "make-lzma-vectors: $liblzma not found (brew install xz)" >&2; exit 2; }

if [[ "${1:-}" == "--payload" ]]; then
    [[ $# -ge 3 ]] || { echo "make-lzma-vectors: --payload IN OUT" >&2; exit 2; }
    in_testdata "$3"
    exec python3 -I "$here/make-lzma-vectors.py" "$liblzma" "$@"
fi
out="${1:-$TESTDATA_ROOT/nativezip-lzma}"
in_testdata "$out"
mkdir -p "$out"
python3 -I "$here/make-lzma-vectors.py" "$liblzma" "$out"
