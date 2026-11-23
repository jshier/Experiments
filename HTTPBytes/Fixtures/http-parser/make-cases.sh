#!/bin/bash
# Makes HTTPBytes' http-parser differential cases in OUTPUT_DIR (default: TestData/http-parser-cases): nodejs/http-parser's
# test.c (at ec8b5ee, MIT; the http-parser set), its request and response messages and its `test_simple` lines, as
# cases.tsv with what http-parser expects of each (make-cases.pl says how). Needs `Tools/test-data fetch http-parser`
# first. It writes only inside the repository's TestData/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
test_c="$TESTDATA_ROOT/http-parser/test.c"
[[ -f "$test_c" ]] || { echo "make-cases: run Tools/test-data fetch http-parser first" >&2; exit 2; }
out="${1:-$TESTDATA_ROOT/http-parser-cases}"
in_testdata "$out"
in_testdata "$out/cases.tsv"
mkdir -p "$out"
perl "$here/make-cases.pl" "$test_c" "$out/cases.tsv"
