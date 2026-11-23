#!/bin/bash
# Makes HTTPBytes' top-1k corpus in OUTPUT_DIR (default: the repository's TestData/http-top1k, where
# `Tools/test-data fetch http-top1k` puts it) from cursed-http's tests/top1k: the requests headless Chromium sent while
# loading the Tranco top 1,000 sites, and the response heads it got (values scrubbed shape-preservingly by cursed-http):
#
#   requests.http1    the 3,533 requests' heads, concatenated (the 629 bodies left out)
#   responses.http1   the 2,054 response heads, concatenated
#
# Needs `Tools/test-data fetch cursed-http` first. It writes only inside the repository's TestData/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
top1k="$TESTDATA_ROOT/cursed-http/tests/top1k"
[[ -f "$top1k/requests.dat.gz" ]] || { echo "make-top1k: run Tools/test-data fetch cursed-http first" >&2; exit 2; }
out="${1:-$TESTDATA_ROOT/http-top1k}"
for file in "$out" "$out/requests.http1" "$out/responses.http1"; do
    in_testdata "$file"
done
mkdir -p "$out"
perl "$here/make-top1k.pl" "$top1k" "$out"
