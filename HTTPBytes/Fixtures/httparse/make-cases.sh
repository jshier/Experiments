#!/bin/bash
# Makes HTTPBytes' httparse differential cases in OUTPUT_DIR (default: TestData/httparse-cases): httparse's `req!`/`res!`
# tests and its request-target tests (seanmonstar/httparse at a0fa552, MIT/Apache-2.0; the httparse set) as cases.tsv,
# with what httparse expects of each (make-cases.pl says how). Needs `Tools/test-data fetch httparse` first. It writes
# only inside the repository's TestData/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
source_dir="$TESTDATA_ROOT/httparse"
[[ -f "$source_dir/lib.rs" && -f "$source_dir/uri.rs" ]] || { echo "make-cases: run Tools/test-data fetch httparse first" >&2; exit 2; }
out="${1:-$TESTDATA_ROOT/httparse-cases}"
in_testdata "$out"
in_testdata "$out/cases.tsv"
mkdir -p "$out"
perl "$here/make-cases.pl" "$source_dir/lib.rs" "$source_dir/uri.rs" "$out/cases.tsv"
