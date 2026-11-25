#!/bin/bash
# Tools/lib/testdata.sh's in_testdata, in a fake repository: paths inside TestData pass; `..`, links out, a link as the
# last component (even a dangling one), a dangling link in the middle, and a TestData that is itself a link (unless
# TESTDATA_ALLOW_LINK) are refused with status 2, and nothing outside is written.
tools="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-testdata.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

make_repo() { # make_repo DIR: a repository with Tools/lib/testdata.sh and an empty TestData/set
    mkdir -p "$1/Tools/lib" "$1/TestData/set"
    cp "$tools/lib/testdata.sh" "$1/Tools/lib/"
}
guard() { # guard REPO PATH: in_testdata's exit status
    (source "$1/Tools/lib/testdata.sh"; in_testdata "$2") 2> /dev/null
    echo $?
}

repo="$work/repo with space"
outside="$work/outside"
make_repo "$repo"
mkdir -p "$outside"
echo original > "$outside/victim"
data="$repo/TestData"

check "a new file inside" "$(guard "$repo" "$data/set/new file")" 0
check "a new directory's file inside" "$(guard "$repo" "$data/set/a/b/c")" 0
check "TestData itself" "$(guard "$repo" "$data")" 2
check "TestData/set/.. (TestData itself)" "$(guard "$repo" "$data/set/..")" 2
check "TestData/set/../../Tools" "$(guard "$repo" "$data/set/../../Tools")" 2
check "TestData/missing/../x" "$(guard "$repo" "$data/missing/../x")" 2
check "outside the repository" "$(guard "$repo" "$outside/x")" 2

ln -s "$outside/victim" "$data/set/leaf"
check "a link to an outside file as the last component" "$(guard "$repo" "$data/set/leaf")" 2
ln -s "$data/set/new" "$data/set/inner-leaf"
check "a link inside as the last component" "$(guard "$repo" "$data/set/inner-leaf")" 2
ln -s "$outside/made-by-dangling" "$data/set/dangling"
check "a dangling link as the last component" "$(guard "$repo" "$data/set/dangling")" 2
check "a dangling link with a trailing slash" "$(guard "$repo" "$data/set/dangling/")" 2
check "a dangling link with two trailing slashes" "$(guard "$repo" "$data/set/dangling//")" 2
check "a dangling link, then /." "$(guard "$repo" "$data/set/dangling/.")" 2
check "a link to an outside file with a trailing slash" "$(guard "$repo" "$data/set/leaf/")" 2
check "a new directory with a trailing slash" "$(guard "$repo" "$data/set/newdir/")" 0
ln -s "$outside/newdir" "$data/set/mid"
check "a dangling link in the middle" "$(guard "$repo" "$data/set/mid/sub/file")" 2
ln -s "$outside/victim" "$data/set/filelink"
check "a link to a file used as a directory" "$(guard "$repo" "$data/set/filelink/x")" 2
ln -s "$outside" "$data/set/dirlink"
check "a link to an outside directory in the middle" "$(guard "$repo" "$data/set/dirlink/x")" 2
mkdir "$data/set/real"
ln -s "$data/set/real" "$data/set/innerdir"
check "a link to a directory inside, then a name" "$(guard "$repo" "$data/set/innerdir/x")" 0
check "the outside file is untouched" "$(cat "$outside/victim")" original
check "nothing made through the dangling link" "$([[ -e $outside/made-by-dangling ]] && echo yes || echo no)" no

linked="$work/linked"
mkdir -p "$linked/Tools/lib" "$work/elsewhere"
cp "$tools/lib/testdata.sh" "$linked/Tools/lib/"
ln -s "$work/elsewhere" "$linked/TestData"
check "TestData a link: refused" "$(guard "$linked" "$work/elsewhere/x")" 2
check "TestData a link, TESTDATA_ALLOW_LINK=1: allowed" "$(TESTDATA_ALLOW_LINK=1 guard "$linked" "$work/elsewhere/x")" 0
check "TestData a link, TESTDATA_ALLOW_LINK=1: outside still refused" \
    "$(TESTDATA_ALLOW_LINK=1 guard "$linked" "$work/x")" 2
