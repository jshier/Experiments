#!/bin/bash
# Makes HTTPBytes' h2o HTTP/1 fuzzing corpus in OUTPUT_DIR (default: TestData/h2o-http1-corpus): h2o's fuzz/http1-corpus
# (h2o/h2o at d3e43fc, MIT; from the h2o set's tarball), 1,972 request inputs its fuzzer kept, as files in corpus/, and
# llhttp's verdict on each (llhttp-verdicts.c, built here with Xcode's clang against the llhttp set's sources) in
# llhttp-verdicts.tsv. Needs `Tools/test-data fetch h2o llhttp` first. It writes only inside the repository's TestData/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
tarball="$TESTDATA_ROOT/h2o/h2o-d3e43fc.tar.gz"
llhttp="$TESTDATA_ROOT/llhttp"
[[ -f "$tarball" ]] || { echo "make-corpus: run Tools/test-data fetch h2o first" >&2; exit 2; }
[[ -f "$llhttp/src/llhttp.c" ]] || { echo "make-corpus: run Tools/test-data fetch llhttp first" >&2; exit 2; }
out="${1:-$TESTDATA_ROOT/h2o-http1-corpus}"
work="$out/.work"
for path in "$out" "$out/corpus" "$out/llhttp-verdicts.tsv" "$work" "$work/llhttp-verdicts"; do in_testdata "$path"; done
mkdir -p "$out/corpus" "$work"
# The tarball's top directory, then fuzz/http1-corpus/: three components.
tar -xzf "$tarball" -C "$out/corpus" --strip-components 3 '*/fuzz/http1-corpus/*'
xcrun clang -O2 -w -I "$llhttp/include" "$here/llhttp-verdicts.c" "$llhttp/src/llhttp.c" "$llhttp/src/api.c" "$llhttp/src/http.c" \
    -o "$work/llhttp-verdicts"
(cd "$out/corpus" && find . -type f | sort | xargs "$work/llhttp-verdicts") > "$out/llhttp-verdicts.tsv"
rm -f "$work/llhttp-verdicts"
rmdir "$work"
echo "make-corpus: $(find "$out/corpus" -type f | wc -l | tr -d ' ') files" >&2
