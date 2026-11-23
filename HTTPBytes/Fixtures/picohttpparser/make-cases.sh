#!/bin/bash
# Makes HTTPBytes' picohttpparser differential cases in OUTPUT_DIR (default: TestData/picohttpparser-cases): h2o's
# picohttpparser test.c (at dd573d8, MIT; the picohttpparser set), its request, response, header-block, and chunked
# tests, as cases.tsv with what picohttpparser expects of each (make-cases.pl says how). Needs
# `Tools/test-data fetch picohttpparser` first. It writes only inside the repository's TestData/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
test_c="$TESTDATA_ROOT/picohttpparser/test.c"
[[ -f "$test_c" ]] || { echo "make-cases: run Tools/test-data fetch picohttpparser first" >&2; exit 2; }
out="${1:-$TESTDATA_ROOT/picohttpparser-cases}"
in_testdata "$out"
in_testdata "$out/cases.tsv"
mkdir -p "$out"
perl "$here/make-cases.pl" "$test_c" "$out/cases.tsv"
