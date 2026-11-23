#!/bin/bash
# Makes HTTPBytes' llhttp differential cases in OUTPUT_DIR (default: TestData/llhttp-cases): llhttp's markdown test suite
# (the llhttp-tests set) as cases.tsv, with what llhttp decided for each (make-cases.pl says how). Needs
# `Tools/test-data fetch llhttp-tests` first. It writes only inside the repository's TestData/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
tests="$TESTDATA_ROOT/llhttp-tests/test"
[[ -d "$tests/request" ]] || { echo "make-cases: run Tools/test-data fetch llhttp-tests first" >&2; exit 2; }
out="${1:-$TESTDATA_ROOT/llhttp-cases}"
in_testdata "$out"
in_testdata "$out/cases.tsv"
mkdir -p "$out"
perl "$here/make-cases.pl" "$tests" "$out/cases.tsv"
