#!/bin/bash
# Makes HTTPBytes' message corpus in OUTPUT_DIR (default: the repository's TestData/http-corpus, where
# `Tools/test-data fetch http-corpus` puts it) from qifs' QIF files (real HTTP/3 traffic: Facebook's requests and
# responses, NetBSD's requests), so HTTP/1, HPACK, and QPACK rows measure the same messages:
#
#   requests.http1    every request as an HTTP/1.1 head (`:method :path HTTP/1.1`, `Host` from `:authority`, the
#                     other fields in their order, cookie crumbs joined with "; " as RFC 9113 §8.2.3 says), concatenated
#   responses.http1   every response as an HTTP/1.1 head (`HTTP/1.1 :status REASON`), concatenated
#   requests.qif, responses.qif   the same messages as QIF (fields as in the source, pseudo-fields first), for the
#                     HPACK and QPACK encoders
#
# Needs `Tools/test-data fetch qifs` first. It writes only inside the repository's TestData/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
qifs="$TESTDATA_ROOT/qifs/qifs"
[[ -f "$qifs/fb-req.qif" ]] || { echo "make-corpus: run Tools/test-data fetch qifs first" >&2; exit 2; }
out="${1:-$TESTDATA_ROOT/http-corpus}"
for file in "$out" "$out/requests.http1" "$out/responses.http1" "$out/requests.qif" "$out/responses.qif"; do
    in_testdata "$file"
done
mkdir -p "$out"
perl "$here/make-corpus.pl" "$qifs" "$out"
