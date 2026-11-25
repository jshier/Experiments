#!/bin/bash
# Tools/corpus against a corpus in a temporary directory and local file:// downloads (no network): empty or truncated
# Silesia files bring a fetch, a download whose SHA-256 isn't the pinned one changes nothing in silesia/ and leaves no
# temporary directory, a failed download exits 1, and web/ is copied from this Mac with web/SOURCE recording the macOS
# version and the files' SHA-256s (a damaged web file is copied again, a copy that fails partway leaves nothing partial).
# Interrupted fetches (TERM, QUIT) leave no temporary directory, killed ones leave one the next fetch removes, and
# half-made temporaries are swept. The default corpus is ~/Scratch/corpus.noindex.
tools="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-corpus.XXXXXX")" || exit 1
pid="" # the background fetch (a process group leader), stopped before $work goes if a check fails while it runs
trap 'if [[ -n "$pid" ]]; then kill -TERM -- "-$pid" 2> /dev/null; wait "$pid" 2> /dev/null; fi; rm -rf "$work"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

corpus="$tools/corpus"
export EXPERIMENTS_CORPUS="$work/corpus"
mkdir -p "$EXPERIMENTS_CORPUS/silesia"
for name in dickens mozilla mr nci ooffice osdb reymont samba sao webster x-ray xml; do
    : > "$EXPERIMENTS_CORPUS/silesia/$name"
done
echo "not silesia" > "$work/dickens"
(cd "$work" && zip -q fake.zip dickens)

check "default location" "$(env -u EXPERIMENTS_CORPUS "$corpus" path)" "$HOME/Scratch/corpus.noindex"

EXPERIMENTS_SILESIA_URL="file://$work/fake.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "empty Silesia files and a zip that isn't Silesia: exit 1" "$?" 1
check "  noticed the empty files" "$(grep -c 'needs fetching: dickens mozilla' "$work/err" | tr -d ' ')" 1
check "  refused the zip by its SHA-256" "$(grep -c "silesia.zip's SHA-256 is" "$work/err" | tr -d ' ')" 1
check "  silesia/ unchanged" "$(stat -f %z "$EXPERIMENTS_CORPUS/silesia/dickens")" 0
check "  no temporary directory left" "$(find "$EXPERIMENTS_CORPUS" -name '.silesia.*' | wc -l | tr -d ' ')" 0

EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "a download that fails: exit 1" "$?" 1
check "  says so" "$(grep -c 'download of .* failed' "$work/err" | tr -d ' ')" 1

if [[ -d /System/Library/PrivateFrameworks/WebInspectorUI.framework/Resources ]]; then
    source_line="$(head -1 "$EXPERIMENTS_CORPUS/web/SOURCE")"
    check "web/SOURCE names this macOS" "$source_line" \
        "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) from /System/Library/PrivateFrameworks/WebInspectorUI.framework/Resources"
    check "web/SOURCE's sums match the files" \
        "$(cd "$EXPERIMENTS_CORPUS/web" && tail -n +2 SOURCE | shasum -a 256 -c --quiet > /dev/null 2>&1; echo $?)" 0
    echo damaged > "$EXPERIMENTS_CORPUS/web/Main.css"
    EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
    check "a damaged web file is copied again" \
        "$(cd "$EXPERIMENTS_CORPUS/web" && tail -n +2 SOURCE | shasum -a 256 -c --quiet > /dev/null 2>&1; echo $?)" 0
else
    echo "skip: no WebInspectorUI resources on this Mac"
fi

check "list skips temporary directories" "$("$corpus" list | grep -c '^\.' | tr -d ' ')" 0
check "bad usage: exit 2" "$("$corpus" bogus > /dev/null 2>&1; echo $?)" 2
mkdir -p "$work/nolib"
cp "$corpus" "$work/nolib/"
check "no library beside it: exit 2" "$("$work/nolib/corpus" path > /dev/null 2>&1; echo $?)" 2

# web/ files already there without web/SOURCE are recorded as they are, not replaced.
if [[ -f "$EXPERIMENTS_CORPUS/web/SOURCE" ]]; then
    rm "$EXPERIMENTS_CORPUS/web/SOURCE"
    echo "measured before" > "$EXPERIMENTS_CORPUS/web/Main.css"
    EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
    check "existing web/ files kept" "$(cat "$EXPERIMENTS_CORPUS/web/Main.css")" "measured before"
    check "  and recorded" \
        "$(head -1 "$EXPERIMENTS_CORPUS/web/SOURCE" | cut -d: -f1) $(grep -c '  Main.css$' "$EXPERIMENTS_CORPUS/web/SOURCE" | tr -d ' ')" \
        "macOS unknown 1"

    # A web/SOURCE cut short doesn't hide damage: every expected file needs its line.
    web_checks() {
        (cd "$EXPERIMENTS_CORPUS/web" && tail -n +2 SOURCE | shasum -a 256 -c --quiet > /dev/null 2>&1) || { echo bad; return; }
        echo "$(tail -n +2 "$EXPERIMENTS_CORPUS/web/SOURCE" | wc -l | tr -d ' ') lines"
    }
    expected=0
    for name in Main.js Main.css Main.html CodeMirror.js Three.js; do
        if [[ -f "/System/Library/PrivateFrameworks/WebInspectorUI.framework/Resources/$name" ]]; then
            expected=$((expected + 1))
        fi
    done
    head -1 "$EXPERIMENTS_CORPUS/web/SOURCE" > "$work/source"
    cp "$work/source" "$EXPERIMENTS_CORPUS/web/SOURCE"
    echo damaged > "$EXPERIMENTS_CORPUS/web/Main.css"
    EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
    check "a truncated web/SOURCE and a damaged file: copied again" "$(web_checks)" "$expected lines"
    check "  Main.css repaired" "$(grep -c damaged "$EXPERIMENTS_CORPUS/web/Main.css" | tr -d ' ')" 0

    # Two fetches at once copying web/: neither fails, and SOURCE checks.
    for round in 1 2 3; do
        rm -rf "$EXPERIMENTS_CORPUS/web"
        EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/one" &
        one=$!
        EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/two" &
        two=$!
        wait "$one"
        wait "$two"
        check "concurrent web/ copies, round $round" \
            "$(cat "$work/one" "$work/two" | grep -c "web/ couldn't be copied" | tr -d ' ') $(web_checks)" "0 $expected lines"
    done

    # A copy that fails partway (a cp that fails for Main.css, the second file): the fetch says so and leaves no partial
    # SOURCE or copy in web/.
    mkdir -p "$work/cpbin"
    cat > "$work/cpbin/cp" << 'EOF'
#!/bin/bash
case "$1" in */Main.css) exit 1 ;; esac
exec /bin/cp "$@"
EOF
    chmod +x "$work/cpbin/cp"
    rm -rf "$EXPERIMENTS_CORPUS/web"
    PATH="$work/cpbin:$PATH" EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
    check "a web copy that fails partway: says so" "$(grep -c "can't copy web/ from" "$work/err" | tr -d ' ')" 1
    check "  no partial SOURCE or copy left in web/" "$(find "$EXPERIMENTS_CORPUS/web" -name '.*' | wc -l | tr -d ' ')" 0
    EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
    check "  the next fetch copies web/" "$(web_checks)" "$expected lines"

    # Interrupted (TERM, from a cp that sends it at Main.css) mid-copy: the partial SOURCE and copy go too.
    mkdir -p "$work/cpsigbin"
    cat > "$work/cpsigbin/cp" << 'EOF'
#!/bin/bash
case "$1" in */Main.css) kill -TERM "$PPID"; exit 1 ;; esac
exec /bin/cp "$@"
EOF
    chmod +x "$work/cpsigbin/cp"
    rm -rf "$EXPERIMENTS_CORPUS/web"
    PATH="$work/cpsigbin:$PATH" EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
    check "TERM mid-copy: exit 130" "$?" 130
    check "  no partial SOURCE or copy left in web/" "$(find "$EXPERIMENTS_CORPUS/web" -name '.*' | wc -l | tr -d ' ')" 0
    EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
    check "  the next fetch copies web/" "$(web_checks)" "$expected lines"
fi

# A download interrupted (TERM, QUIT) leaves no temporary directory; one killed (KILL) leaves one that list reports and
# the next fetch removes. The fake curl writes part of its file and waits (at most 10 s), and leaves on QUIT without a
# core dump (a crash report); the fake mv logs its arguments (the owner file is written under another name, then
# renamed in).
mkdir -p "$work/bin"
cat > "$work/bin/curl" << 'EOF'
#!/usr/bin/perl
$SIG{QUIT} = sub { exit 1 };
my $out;
for my $i (0 .. $#ARGV - 1) { $out = $ARGV[$i + 1] if $ARGV[$i] eq "-o" }
open(my $file, ">", $out) or die "can't write $out: $!\n";
print $file "\0" x 100000;
close($file);
sleep 10;
EOF
cat > "$work/bin/mv" << EOF
#!/bin/bash
echo "\$*" >> "$work/mv.log"
exec /bin/mv "\$@"
EOF
# The fake rm, once $work/rm-signal exists, sends INT to its process group (the fetch's) before removing a temporary
# directory: a second signal while the first one's cleanup runs.
cat > "$work/bin/rm" << EOF
#!/bin/bash
if [[ -f "$work/rm-signal" && "\$*" == *"/.silesia."* ]]; then
    /bin/rm -f "$work/rm-signal"
    kill -INT 0
fi
exec /bin/rm "\$@"
EOF
chmod +x "$work/bin/curl" "$work/bin/mv" "$work/bin/rm"
# fetch_in_group: a fetch with the fake tools, in a process group of its own, INT and QUIT at their defaults (a check
# run in the background starts with both ignored); sets pid.
fetch_in_group() {
    PATH="$work/bin:$PATH" perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' "$corpus" fetch \
        > /dev/null 2>&1 &
    pid=$!
}
# reap: waits for the background fetch, then forgets it, so the cleanup never signals a reused process group.
reap() {
    wait "$pid" 2> /dev/null
    pid=""
}
temporaries() { find "$EXPERIMENTS_CORPUS" -maxdepth 1 -name '.silesia.*' | wc -l | tr -d ' '; }
until_downloading() { # waits (at most 10 s) for the fake curl's file
    local tries
    for ((tries = 0; tries < 100; tries++)); do
        [[ -n "$(find "$EXPERIMENTS_CORPUS" -path '*/.silesia.*/silesia.zip' 2> /dev/null)" ]] && return 0
        sleep 0.1
    done
    echo "FAIL: the download never started"
    exit 1
}
# A live fetch's temporary directory survives another fetch's sweep, even across time zones and locales.
TZ=UTC LC_ALL=fr_FR.UTF-8 fetch_in_group
until_downloading
EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "another fetch mid-download (TZ=UTC, LC_ALL=fr_FR): the download's directory survives" \
    "$(temporaries) $(grep -c 'removed .silesia' "$work/err" | tr -d ' ')" "1 0"
check "  its owner file was written under another name, then renamed in" \
    "$(grep -cE '/\.silesia\.[A-Za-z0-9]{6}/owner\.partial .*/\.silesia\.[A-Za-z0-9]{6}/owner$' "$work/mv.log" | tr -d ' ')" 1
kill -TERM -- "-$pid"
reap
check "  and goes when that fetch is stopped" "$(temporaries)" 0

# A temporary directory with no owner file is kept while younger than a minute, removed after.
mkdir "$EXPERIMENTS_CORPUS/.silesia.AbC123"
EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "a new ownerless temporary directory is kept" "$(temporaries)" 1
touch -t 202001010000 "$EXPERIMENTS_CORPUS/.silesia.AbC123"
EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "  and removed once a minute old" "$(temporaries) $(grep -c 'removed .silesia.AbC123' "$work/err" | tr -d ' ')" "0 1"

# web/'s half-copied files (a fetch killed mid-copy): kept while younger than a minute, removed after.
mkdir -p "$EXPERIMENTS_CORPUS/web"
: > "$EXPERIMENTS_CORPUS/web/.Main.js.AbC123"
: > "$EXPERIMENTS_CORPUS/web/.Main.js.XyZ789"
touch -t 202001010000 "$EXPERIMENTS_CORPUS/web/.Main.js.XyZ789"
EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "half-copied web files: the new one kept, the minute-old one removed" \
    "$([[ -f $EXPERIMENTS_CORPUS/web/.Main.js.AbC123 ]] && echo yes || echo no) $([[ -f $EXPERIMENTS_CORPUS/web/.Main.js.XyZ789 ]] && echo yes || echo no)" \
    "yes no"
rm -f "$EXPERIMENTS_CORPUS/web/.Main.js.AbC123"

# Another fetch removes a leftover while this one's sweep looks at it (a fake stat removes what it's asked about): the
# sweep goes on, and doesn't claim to have removed it.
mkdir -p "$work/statbin" "$EXPERIMENTS_CORPUS/.silesia.vanish"
echo "99998 Mon Jan  1 00:00:00 2024" > "$EXPERIMENTS_CORPUS/.silesia.vanish/owner"
: > "$EXPERIMENTS_CORPUS/web/.Main.js.vanish"
cat > "$work/statbin/stat" << 'EOF'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in *.vanish) /bin/rm -rf "$arg" ;; esac
done
exec /usr/bin/stat "$@"
EOF
chmod +x "$work/statbin/stat"
PATH="$work/statbin:$PATH" EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "leftovers removed during the sweep: no error, no claim" \
    "$(grep -c 'syntax error\|No such file\|removed .silesia.vanish' "$work/err" | tr -d ' ')" 0

# Six fetches at once sweeping one orphaned temporary directory, three rounds: exactly one says it removed it, none
# errs, nothing is left (each exits 1: the test corpus's Silesia files are empty and the download fails).
for round in 1 2 3; do
    mkdir "$EXPERIMENTS_CORPUS/.silesia.Orphn$round"
    echo "99998 Mon Jan  1 00:00:00 2024" > "$EXPERIMENTS_CORPUS/.silesia.Orphn$round/owner"
    pids=()
    for n in 1 2 3 4 5 6; do
        EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/concurrent.$n" &
        pids+=($!)
    done
    statuses=""
    for one in "${pids[@]}"; do
        wait "$one"
        statuses="$statuses $?"
    done
    check "concurrent sweeps, round $round: every fetch exits 1 (Silesia can't be made whole)" "$statuses" " 1 1 1 1 1 1"
    check "  one 'removed', no other error" \
        "$(cat "$work"/concurrent.* | grep -c "removed .silesia.Orphn$round" | tr -d ' ') $(cat "$work"/concurrent.* | grep -c 'syntax error\|No such file\|ermission denied' | tr -d ' ')" \
        "1 0"
    check "  nothing left" "$(temporaries)" 0
done

# An owner file that can't be read (as if removed meanwhile) leaves no error; a `cut` that removes the owner file it's
# given (gone between owner_alive and the report) leaves no error in list either.
mkdir "$EXPERIMENTS_CORPUS/.silesia.Unread"
echo "99998 Mon Jan  1 00:00:00 2024" > "$EXPERIMENTS_CORPUS/.silesia.Unread/owner"
chmod 000 "$EXPERIMENTS_CORPUS/.silesia.Unread/owner"
EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "an owner file that can't be read: removed, no error" \
    "$(grep -c 'removed .silesia.Unread' "$work/err" | tr -d ' ') $(grep -c 'ermission denied' "$work/err" | tr -d ' ') $(temporaries)" "1 0 0"
mkdir -p "$EXPERIMENTS_CORPUS/.silesia.LiveAb" "$work/cutbin"
echo "$$ $(LC_ALL=C TZ=UTC0 ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //; s/ $//')" > "$EXPERIMENTS_CORPUS/.silesia.LiveAb/owner"
cat > "$work/cutbin/cut" << 'EOF'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in */owner) /bin/rm -f "$arg" ;; esac
done
exec /usr/bin/cut "$@"
EOF
chmod +x "$work/cutbin/cut"
PATH="$work/cutbin:$PATH" "$corpus" list > "$work/list.out" 2> "$work/list.err"
check "an owner file gone before list's report reads it: reported in use, no error" \
    "$(grep -c 'silesia.LiveAb.*in use by fetch' "$work/list.out" | tr -d ' ') $(grep -c 'No such file' "$work/list.err" | tr -d ' ')" "1 0"
rm -rf "$EXPERIMENTS_CORPUS/.silesia.LiveAb"

# TERM while removing a renamed-aside leftover (a fake rm sends it at the trash): the cleanup removes the trash.
mkdir -p "$EXPERIMENTS_CORPUS/.silesia.TrashA" "$work/trashrmbin"
echo "99998 Mon Jan  1 00:00:00 2024" > "$EXPERIMENTS_CORPUS/.silesia.TrashA/owner"
cat > "$work/trashrmbin/rm" << EOF
#!/bin/bash
if [[ "\$*" == *".trash."* && -f "$work/trash-signal" ]]; then
    /bin/rm -f "$work/trash-signal"
    kill -TERM "\$PPID"
    exit 1
fi
exec /bin/rm "\$@"
EOF
chmod +x "$work/trashrmbin/rm"
touch "$work/trash-signal"
PATH="$work/trashrmbin:$PATH" EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "TERM while removing a trash: exit 130, the signal sent, nothing left" \
    "$? $([[ -e $work/trash-signal ]] && echo unsent) $(temporaries)" "130  0"

# A fetch's own trash, listed while that fetch removes it (a fake rm runs `list` then), is in use: its tag matches the
# fetch's PID and start time.
mkdir -p "$EXPERIMENTS_CORPUS/.silesia.ListAb" "$work/trashlistbin"
echo "99998 Mon Jan  1 00:00:00 2024" > "$EXPERIMENTS_CORPUS/.silesia.ListAb/owner"
cat > "$work/trashlistbin/rm" << EOF
#!/bin/bash
if [[ "\$*" == *".trash."* && -f "$work/trash-list" ]]; then
    /bin/rm -f "$work/trash-list"
    "$corpus" list > "$work/trash-list.out" 2>&1
fi
exec /bin/rm "\$@"
EOF
chmod +x "$work/trashlistbin/rm"
touch "$work/trash-list"
PATH="$work/trashlistbin:$PATH" EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "a fetch's trash listed while it removes it: listed as being removed, not left over" \
    "$(grep -c 'trash.*being removed by fetch' "$work/trash-list.out" | tr -d ' ') $(grep -c 'trash.*left over' "$work/trash-list.out" | tr -d ' ') $(temporaries)" \
    "1 0 0"

# A trash is in use only while the fetch named in it runs, by PID and start time: one named for this script is listed
# and kept; one with this PID but another start time (a reused PID) is listed as left over and removed.
start_tag="$$.$(LC_ALL=C TZ=UTC0 ps -o lstart= -p $$ | tr -cd 'A-Za-z0-9')"
mkdir "$EXPERIMENTS_CORPUS/.silesia.AbC123.trash.$start_tag" "$EXPERIMENTS_CORPUS/.silesia.XyZ789.trash.$$.MonJan1000000002000"
check "trashes: list shows the live one and the reused PID's" \
    "$("$corpus" list | grep -c -e "AbC123.trash.*being removed by fetch $$" -e "XyZ789.trash.*left over" | tr -d ' ')" 2
EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
check "  a fetch keeps the live one, removes the reused PID's" \
    "$([[ -d $EXPERIMENTS_CORPUS/.silesia.AbC123.trash.$start_tag ]] && echo kept) $([[ -d $EXPERIMENTS_CORPUS/.silesia.XyZ789.trash.$$.MonJan1000000002000 ]] && echo kept)" \
    "kept "
rm -rf "$EXPERIMENTS_CORPUS/.silesia.AbC123.trash.$start_tag"

# INT during a TERM's cleanup doesn't cut it short.
fetch_in_group
until_downloading
touch "$work/rm-signal"
kill -TERM -- "-$pid"
reap
check "TERM mid-download, then INT in the cleanup: no temporary directory left" "$(temporaries) $(find "$work" -maxdepth 1 -name rm-signal | wc -l | tr -d ' ')" "0 0"

for signal in TERM QUIT KILL; do
    fetch_in_group
    until_downloading
    kill "-$signal" -- "-$pid"
    reap
    if [[ "$signal" != KILL ]]; then
        check "$signal mid-download: no temporary directory left" "$(temporaries)" 0
    else
        check "KILL mid-download leaves one" "$(temporaries)" 1
        check "  list reports it" "$("$corpus" list | grep -c $'^(temporary)\t.*left over' | tr -d ' ')" 1
        EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch > /dev/null 2> "$work/err"
        check "  the next fetch removes it" "$(temporaries) $(grep -c 'removed .silesia' "$work/err" | tr -d ' ')" "0 1"
    fi
done

# A corpus whose own path has `.trash.` in it: its leftovers are still swept (trash is told by the entry's name).
mkdir -p "$work/x.trash.y/corpus/silesia" "$work/x.trash.y/corpus/.silesia.Orphan"
echo "99998 Mon Jan  1 00:00:00 2024" > "$work/x.trash.y/corpus/.silesia.Orphan/owner"
EXPERIMENTS_CORPUS="$work/x.trash.y/corpus" EXPERIMENTS_SILESIA_URL="file://$work/missing.zip" "$corpus" fetch \
    > /dev/null 2> "$work/err"
check "a corpus under a path with .trash. in it: its leftover removed" \
    "$([[ -d $work/x.trash.y/corpus/.silesia.Orphan ]] && echo kept || echo removed) $(grep -c 'removed .silesia.Orphan' "$work/err" | tr -d ' ')" \
    "removed 1"
