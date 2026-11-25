# shellcheck shell=bash
# The TestData/ directory at the repository root (ignored by git), and the guard every script that writes there
# uses: Tools/test-data and the generators it runs write and delete only inside it. Source it:
#     source "$REPO/Tools/lib/testdata.sh"
# then call `in_testdata PATH` before writing or removing PATH. It doesn't change shell options.
#
# TestData itself may not be a symbolic link (a link would make wherever it points count as inside): set
# TESTDATA_ALLOW_LINK=1 to keep it on another volume through one, on purpose.

TESTDATA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/TestData"

# Prints PATH made absolute with symbolic links resolved, for a PATH that may not exist yet: its deepest existing
# ancestor resolved, then the rest. Fails on `.` or `..` in the part that doesn't exist, and on a symbolic link
# there: a dangling link (or a link to a file used as a directory) would be followed by whatever creates the path. A
# directory another process removes between the test and the `cd` (fetches sweeping one leftover) counts as one that
# doesn't exist.
testdata_resolve() {
    local path="$1" rest="" resolved
    [[ "$path" == /* ]] || path="$PWD/$path"
    while true; do
        if [[ -d "$path" ]] && resolved="$(cd "$path" 2> /dev/null && pwd -P)"; then
            echo "$resolved$rest"
            return 0
        fi
        [[ -L "$path" ]] && return 1
        case "$(basename "$path")" in .|..) return 1 ;; esac
        [[ "$path" != / ]] || return 1
        rest="/$(basename "$path")$rest"
        path="$(dirname "$path")"
    done
}

# Succeeds when PATH is inside TestData/ (not TestData itself) and isn't a symbolic link; otherwise prints why and
# exits 2. A link as the last component is refused even when it points inside: writing through it writes its
# target, and a generator's links (archive-coverage's) can point anywhere.
in_testdata() {
    local resolved root path="$1"
    # Without its trailing slashes: `-L "link/"` follows the link (lstat of "link/" resolves it), so a dangling link
    # written with a slash would pass both checks below, and `mkdir -p link/` creates its target.
    while [[ "$path" == */ && "$path" != / ]]; do path="${path%/}"; done
    if [[ -L "$TESTDATA_ROOT" && -z "${TESTDATA_ALLOW_LINK:-}" ]]; then
        echo "error: $TESTDATA_ROOT is a symbolic link (to $(readlink "$TESTDATA_ROOT")); set TESTDATA_ALLOW_LINK=1 if that's intended" >&2
        exit 2
    fi
    # TestData itself only, not its parents: a fetch still running after its repository was removed fails here rather
    # than making the repository's path again. Another process may make it at the same moment.
    if [[ ! -d "$TESTDATA_ROOT" ]] && ! mkdir "$TESTDATA_ROOT" 2> /dev/null && [[ ! -d "$TESTDATA_ROOT" ]]; then
        echo "error: can't create $TESTDATA_ROOT" >&2
        exit 2
    fi
    # An empty root would make the check below allow any absolute path (TestData unreadable, say): refuse instead.
    root="$(cd "$TESTDATA_ROOT" 2> /dev/null && pwd -P)" && [[ -n "$root" ]] ||
        { echo "error: can't enter $TESTDATA_ROOT" >&2; exit 2; }
    if [[ -L "$path" ]]; then
        echo "error: refusing '$1': it's a symbolic link (to $(readlink "$path"))" >&2
        exit 2
    fi
    resolved="$(testdata_resolve "$path")" ||
        { echo "error: refusing '$1': '.', '..', or a symbolic link in a part that doesn't exist" >&2; exit 2; }
    if [[ "$resolved" != "$root/"?* ]]; then
        echo "error: refusing to write or delete '$1' ($resolved): only paths inside $root are allowed" >&2
        exit 2
    fi
}
