#!/bin/bash
# Makes HTTPBytes' cursed-http differential cases in OUTPUT_DIR (default: TestData/cursed-http-cases): cursed-http's
# conformance/extract.py (MIT; public/cursed-http at 5e10ca8, from the cursed-http set) run over the suites it gathers,
# from their own sets: llhttp's markdown tests (llhttp-tests), HTTP Garden's TROPHIES.md (http-garden; GPL-3.0, so it's
# fetched, never checked in), picohttpparser's test.c (picohttpparser), and httparse's src/lib.rs (httparse). Its
# records become cases.tsv (to-tsv.pl says how), one request per line with the suite's verdict.
#
# Needs python3 and `Tools/test-data fetch cursed-http llhttp-tests http-garden picohttpparser httparse` first. It writes
# only inside the repository's TestData/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
extract="$TESTDATA_ROOT/cursed-http/conformance/extract.py"
llhttp="$TESTDATA_ROOT/llhttp-tests"
garden="$TESTDATA_ROOT/http-garden"
pico="$TESTDATA_ROOT/picohttpparser/test.c"
httparse="$TESTDATA_ROOT/httparse/lib.rs"
for need in "$extract:cursed-http" "$llhttp/test/request:llhttp-tests" "$garden/TROPHIES.md:http-garden" "$pico:picohttpparser" \
    "$httparse:httparse"; do
    [[ -e "${need%:*}" ]] || { echo "make-cases: run Tools/test-data fetch ${need##*:} first" >&2; exit 2; }
done
command -v python3 > /dev/null || { echo "make-cases: needs python3" >&2; exit 2; }
out="${1:-$TESTDATA_ROOT/cursed-http-cases}"
work="$out/.work"
for path in "$out" "$out/cases.tsv" "$work" "$work/cases.bin"; do in_testdata "$path"; done
mkdir -p "$work"
# `-I`: the downloaded script's directory and the user's site-packages stay off the import path (it imports only the
# standard library).
python3 -I "$extract" "$llhttp" "$garden" "$pico" "$httparse" > "$work/cases.bin"
perl "$here/to-tsv.pl" "$work/cases.bin" "$out/cases.tsv"
rm -f "$work/cases.bin"
rmdir "$work"
