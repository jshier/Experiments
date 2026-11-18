# The TestData/ directory at the repository root (ignored by git), and the guard every script that writes there
# uses: Tools/test-data and the generators it runs write and delete only inside it. Source it:
#     source "$REPO/Tools/lib/testdata.sh"
# then call `in_testdata PATH` before writing or removing PATH. It doesn't change shell options.

TESTDATA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/TestData"

# Prints PATH made absolute with symbolic links resolved, for a PATH that may not exist yet: its deepest existing
# ancestor resolved, then the rest. Fails on `.` or `..` in the part that doesn't exist.
testdata_resolve() {
    local path="$1" rest=""
    [[ "$path" == /* ]] || path="$PWD/$path"
    while [[ ! -d "$path" ]]; do
        case "$(basename "$path")" in .|..) return 1 ;; esac
        rest="/$(basename "$path")$rest"
        path="$(dirname "$path")"
    done
    echo "$(cd "$path" && pwd -P)$rest"
}

# Succeeds when PATH is inside TestData/ (not TestData itself); otherwise prints why and exits 2.
in_testdata() {
    local resolved root
    mkdir -p "$TESTDATA_ROOT" || { echo "error: can't create $TESTDATA_ROOT" >&2; exit 2; }
    root="$(cd "$TESTDATA_ROOT" && pwd -P)"
    resolved="$(testdata_resolve "$1")" || { echo "error: refusing '$1': '.' or '..' in a path that doesn't exist" >&2; exit 2; }
    if [[ "$resolved" != "$root/"?* ]]; then
        echo "error: refusing to write or delete '$1' ($resolved): only paths inside $root are allowed" >&2
        exit 2
    fi
}
