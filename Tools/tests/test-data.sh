#!/bin/bash
# Tools/test-data in a fake repository whose DOWNLOADS and GENERATED tables are local file:// sets: snapshots are
# unpacked into staging and swapped in, deleted or stray files bring a new unpack, a pin change removes the old
# snapshot's files, a generated set is made again when its input set or Tools/lib/testdata.sh changes, read-only
# generated sets are replaced without nesting, a set that can't be removed fails the fetch, failures exit 1, set names
# match exactly, two fetches racing to swap one set both succeed, and interrupted (INT, QUIT, TERM) or killed fetches
# (between a swap's renames, mid-generation, mid-download) lose no set and leave no staging the next fetch doesn't
# reclaim (owner files half made included). Generators run with TESTDATA_GENERATOR_PATH, and a new tool, liblzma,
# libzstd, or macOS build makes a set again. The check's own cleanup stops a background fetch when a check fails.
tools="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-test-data.XXXXXX")" || exit 1
work="$(cd "$work" && pwd -P)" # TestData's path is resolved (/var → /private/var): compare like with like
# Background fetches (process group leaders), stopped by the cleanup: a check that fails while one runs would otherwise
# leave it running, making TestData again inside the removed directory.
FETCHES=()
cleanup() {
    local pid
    [[ -f "$work/go" ]] || touch "$work/go" # releases any generator still waiting
    for pid in ${FETCHES[@]+"${FETCHES[@]}"}; do kill -TERM -- "-$pid" 2> /dev/null; done
    for pid in ${FETCHES[@]+"${FETCHES[@]}"}; do wait "$pid" 2> /dev/null; done
    # Disk images a check attached, if it failed before detaching them: whatever is mounted under $work, then every image
    # whose file is under $work (by its first device).
    local device point
    while IFS=$'\t' read -r device point; do
        [[ -n "$point" ]] || continue
        umount -f "$point" 2> /dev/null
    done < <(mount | perl -sne 'print "$1\t$2\n" if m{^(/dev/disk\S+) on (.+) \([^()]*\)$} && index($2, "$w/") == 0' \
        -- -w="$work" | sort -t $'\t' -k 2 -r)
    while read -r device; do
        hdiutil detach -quiet "$device" 2> /dev/null || hdiutil detach -quiet -force "$device" 2> /dev/null
    done < <(hdiutil info | perl -sne '
        if (/^image-path\s*:\s*(.+)$/) { $in = index($1, "$w/") == 0; $done = 0 }
        elsif ($in && !$done && m{^(/dev/disk\d+)\s}) { print "$1\n"; $done = 1 }' -- -w="$work")
    # Twice: what a pass can't reach the first time (below an ACL that denies listing, an ACL on a locked directory),
    # the other passes have made reachable by the second.
    local _
    for _ in 1 2; do
        # Entries whose ACL hides them (chmod -R stats each entry and skips those), by readdir: everything under $work
        # is the check's own, links included.
        perl -e '
            sub walk {
                my ($dir) = @_;
                opendir(my $handle, $dir) or return;
                for my $name (grep { $_ ne "." && $_ ne ".." } readdir $handle) {
                    my $path = "$dir/$name";
                    unless (lstat $path) { system("chmod", "-h", "-N", $path); system("chmod", "-N", $path); }
                    walk($path) if lstat($path) && -d _;
                }
            }
            walk($ARGV[0]);' "$work" 2> /dev/null
        chflags -R nouchg,nouappnd "$work" 2> /dev/null
        chmod -R -N "$work" 2> /dev/null
        chmod -R u+rwx "$work" 2> /dev/null
    done
    rm -rf "$work"
}
trap cleanup EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }
# until_there DIR PATH-PATTERN [COUNT]: waits (at most 10 s) until COUNT paths under DIR (two levels) match.
until_there() {
    local tries
    for ((tries = 0; tries < 100; tries++)); do
        [[ "$(find "$1" -maxdepth 2 -path "$2" 2> /dev/null | wc -l | tr -d ' ')" -ge "${3:-1}" ]] && return 0
        sleep 0.1
    done
    echo "FAIL: timed out waiting for $2 in $1"
    exit 1
}

repo="$work/repo"
mkdir -p "$repo/Tools/lib" "$repo/src/v1/top" "$repo/src/v2/top" "$repo/gens/gen" "$repo/gens/ro" "$repo/gens/bad" \
    "$repo/gens/wait" "$work/bin"
cp "$tools/test-data" "$repo/Tools/"
cp "$tools/lib/common.sh" "$tools/lib/testdata.sh" "$repo/Tools/lib/"
data="$repo/TestData"
# A hook after a swap's first rename (the old set renamed aside, the new one not yet in place): CHECK_SIGNAL=INT sends
# the fetch that signal there.
perl -i -pe 'print "        if [[ -n \"\${CHECK_SIGNAL:-}\" ]]; then kill -\"\$CHECK_SIGNAL\" \$\$; sleep 1; fi\n" if /^\s+if rename_path "\$staging" "\$ROOT\/\$set"/' \
    "$repo/Tools/test-data"
check "the hook is in the copy" "$(grep -c CHECK_SIGNAL "$repo/Tools/test-data" | tr -d ' ')" 1
# And one at the start of the cleanup: CHECK_SIGNAL2=QUIT sends the fetch a second signal there.
perl -0777 -i -pe 's/(\ncleanup_staging\(\) \{\n(?:.*\n)*?    local dir\n)/$1    if [[ -n "\${CHECK_SIGNAL2:-}" ]]; then kill -"\$CHECK_SIGNAL2" \$\$; fi\n/' \
    "$repo/Tools/test-data"
check "the second hook is in the copy" "$(grep -c CHECK_SIGNAL2 "$repo/Tools/test-data" | tr -d ' ')" 1

# Two revisions of an upstream snapshot: v2 removes b.txt and changes a.txt.
echo "a v1" > "$repo/src/v1/top/a.txt"
echo "b v1" > "$repo/src/v1/top/b.txt"
echo "a v2" > "$repo/src/v2/top/a.txt"
tar -czf "$repo/src/v1.tar.gz" -C "$repo/src/v1" top
tar -czf "$repo/src/v2.tar.gz" -C "$repo/src/v2" top
sum1="$(shasum -a 256 "$repo/src/v1.tar.gz" | cut -d' ' -f1)"
sum2="$(shasum -a 256 "$repo/src/v2.tar.gz" | cut -d' ' -f1)"

# gen copies dl's a.txt (as http-corpus reads qifs); ro leaves a read-only directory; bad fails.
cat > "$repo/gens/gen/make.sh" << 'EOF'
#!/bin/bash
cp "$(dirname "$0")/../../TestData/dl/a.txt" "$1/derived.txt"
EOF
cat > "$repo/gens/ro/make.sh" << 'EOF'
#!/bin/bash
# version 1
mkdir -p "$1/locked"; echo 1 > "$1/locked/file"; chmod 555 "$1/locked"
EOF
cat > "$repo/gens/bad/make.sh" << 'EOF'
#!/bin/bash
echo partial > "$1/partial"; exit 3
EOF
# wait says it started, waits for $work/go (at most 10 s), and writes which fetch made it.
cat > "$repo/gens/wait/make.sh" << EOF
#!/bin/bash
echo "\$PPID" >> "$work/started"
for ((i = 0; i < 100; i++)); do [[ -f "$work/go" ]] && break; sleep 0.1; done
echo "\$PPID" > "\$1/maker"
EOF
# versioned depends on checktool, a fake tool whose --version is $work/toolversion; on xz and zstd, whose Homebrew
# libraries are fakes under TESTDATA_HOMEBREW_DIR; and on macOS, whose sw_vers is a fake first on the fetches' PATH
# (fetchbin). It records the checktool it ran: generators run with a PATH of checktool's directory and the system's
# (TESTDATA_GENERATOR_PATH), not the fetch's, where fetchbin's own checktool comes first. fetchbin's mv logs its
# arguments (an owner file is written under another name, then renamed in).
mkdir -p "$repo/gens/versioned" "$work/toolbin" "$work/fetchbin" "$work/brew/opt/xz/lib" "$work/brew/opt/zstd/lib"
cat > "$repo/gens/versioned/make.sh" << 'EOF'
#!/bin/bash
{ checktool; command -v checktool; } > "$1/out"
EOF
printf '#!/bin/bash\ncat "%s/toolversion"\n' "$work" > "$work/toolbin/checktool"
printf '#!/bin/bash\necho "the fetch PATH%ss checktool"\n' "'" > "$work/fetchbin/checktool"
cat > "$work/fetchbin/sw_vers" << EOF
#!/bin/bash
case "\$1" in -productVersion) echo 27.0 ;; -buildVersion) cat "$work/osbuild" ;; esac
EOF
cat > "$work/fetchbin/mv" << EOF
#!/bin/bash
echo "\$*" >> "$work/mv.log"
exec /bin/mv "\$@"
EOF
echo "checktool 1.0" > "$work/toolversion"
echo 26A1 > "$work/osbuild"
echo "liblzma 1" > "$work/brew/opt/xz/lib/liblzma.dylib"
echo "libzstd 1" > "$work/brew/opt/zstd/lib/libzstd.dylib"
export TESTDATA_GENERATOR_PATH="$work/toolbin:/usr/bin:/bin:/usr/sbin:/sbin"
export TESTDATA_HOMEBREW_DIR="$work/brew"
chmod +x "$repo/gens/gen/make.sh" "$repo/gens/ro/make.sh" "$repo/gens/bad/make.sh" "$repo/gens/wait/make.sh" \
    "$repo/gens/versioned/make.sh" "$work/toolbin/checktool" "$work/fetchbin/checktool" "$work/fetchbin/sw_vers" \
    "$work/fetchbin/mv"
echo "plain file" > "$repo/src/plain.txt"
plain="plain file://$repo/src/plain.txt $(shasum -a 256 "$repo/src/plain.txt" | cut -d' ' -f1) plain.txt"
# A curl that writes part of its file, then hangs (at most 10 s): a download to interrupt.
cat > "$work/bin/curl" << 'EOF'
#!/bin/bash
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
echo "half a file" > "$out"
sleep 10
EOF
chmod +x "$work/bin/curl"

set_downloads() { # set_downloads TEXT: replaces the DOWNLOADS table (with the plain set added)
    DL="$1$plain"$'\n' GEN=$'\ngen gens/gen/make.sh dl -\nro gens/ro/make.sh - -\nbad gens/bad/make.sh - -\nwait gens/wait/make.sh - -\nversioned gens/versioned/make.sh - checktool,xz,zstd,macos\n' \
        perl -0777 -i -pe '
        s/^DOWNLOADS=".*?^"/DOWNLOADS="$ENV{DL}"/ms; s/^GENERATED=".*?^"/GENERATED="$ENV{GEN}"/ms' "$repo/Tools/test-data"
}
td() { "$repo/Tools/test-data" "$@"; }
log="$work/log"
fetch() { td fetch "$@" > /dev/null 2> "$log"; echo $?; }
said() { grep -c -- "$1" "$log" | tr -d ' '; }
# Staging directories and owner files left in TestData.
staging_left() { find "$data" -maxdepth 1 -name '.*.*.*' | wc -l | tr -d ' '; }
# listed NAME: whether NAME, or anything named after it (its owner file, its trash), is in TestData's listing (by
# readdir, so an entry whose ACL hides its attributes shows too).
listed() {
    perl -e 'opendir(my $d, $ARGV[0]) or die; print((grep { index($_, $ARGV[1]) == 0 } readdir $d) ? "yes" : "no")' \
        "$data" "$1"
}
# background_fetch LOG SET...: a fetch in a process group of its own (so a signal reaches its children too), its
# stderr in LOG, recorded for the cleanup; sets PID.
background_fetch() {
    local errors="$1"
    shift
    perl -e 'setpgrp(0, 0); exec @ARGV' "$repo/Tools/test-data" fetch "$@" > /dev/null 2> "$errors" &
    PID=$!
    FETCHES+=("$PID")
}
# reap PID: waits for a background fetch (returning its status) and drops it from FETCHES, so the cleanup never signals
# a process group whose number may have been reused.
reap() {
    local pid rc kept=()
    wait "$1" 2> /dev/null
    rc=$?
    for pid in ${FETCHES[@]+"${FETCHES[@]}"}; do [[ "$pid" == "$1" ]] || kept+=("$pid"); done
    FETCHES=(${kept[@]+"${kept[@]}"})
    return "$rc"
}
# fetch_signal SIGNAL SET...: a fetch sent SIGNAL between a swap's two renames, INT and QUIT at their defaults (a check
# run in the background starts with both ignored, and a shell can't trap a signal ignored at its start).
fetch_signal() {
    local signal="$1"
    shift
    CHECK_SIGNAL="$signal" perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; exec @ARGV' "$repo/Tools/test-data" fetch "$@" \
        > /dev/null 2> "$log"
    echo $?
}

v1=$'\n'"dl file://$repo/src/v1.tar.gz $sum1 snap-v1.unpack.tar.gz"$'\n'
v2=$'\n'"dl file://$repo/src/v2.tar.gz $sum2 snap-v2.unpack.tar.gz"$'\n'
set_downloads "$v1"

# A check that fails while a background fetch runs stops the fetch before removing its directory: this script, run again
# with CHECK_STRAY_PID_FILE, starts one, writes its PID there, and fails.
if [[ -n "${CHECK_STRAY_PID_FILE:-}" ]]; then
    background_fetch "$work/stray.log" wait
    echo "$PID" > "$CHECK_STRAY_PID_FILE"
    until_there "$work" '*/started'
    echo "FAIL: on purpose, with a fetch running"
    exit 1
fi
mkdir "$work/inner"
TMPDIR="$work/inner" CHECK_STRAY_PID_FILE="$work/stray.pid" /bin/bash "$0" > "$work/inner.log" 2>&1
check "a check failing while a fetch runs: exit 1" "$?" 1
stray="$(cat "$work/stray.pid")"
if kill -0 "$stray" 2> /dev/null; then FETCHES+=("$stray"); fi # then stopped by this check's cleanup
check "  its fetch stopped" "$(kill -0 "$stray" 2> /dev/null && echo running || echo stopped)" stopped
check "  its directory removed" "$(find "$work/inner" -mindepth 1 | wc -l | tr -d ' ')" 0

check "fetch gen (pulls in its input dl)" "$(fetch gen)" 0
check "dl unpacked" "$(cat "$data/dl/a.txt")" "a v1"
check "gen made from dl" "$(cat "$data/gen/derived.txt")" "a v1"
check "no staging left" "$(staging_left)" 0
check "fetch again: nothing done" "$(fetch gen; said Unpacking; said Generating)" "0
0
0"

rm "$data/dl/b.txt"
check "an unpacked file deleted: fetch" "$(fetch dl; said Unpacking)" "0
1"
check "the deleted file is back" "$(cat "$data/dl/b.txt")" "b v1"
echo stray > "$data/dl/stray.txt"
check "a stray file: fetch" "$(fetch dl)" 0
check "the stray file is gone" "$([[ -e $data/dl/stray.txt ]] && echo yes || echo no)" no

set_downloads "$v2"
check "pin moved: fetch gen" "$(fetch gen; said Generating)" "0
1"
check "a.txt from v2" "$(cat "$data/dl/a.txt")" "a v2"
check "b.txt (removed upstream) gone" "$([[ -e $data/dl/b.txt ]] && echo yes || echo no)" no
check "the old tarball gone" "$([[ -e $data/dl/snap-v1.unpack.tar.gz ]] && echo yes || echo no)" no
check "gen made again from the new input" "$(cat "$data/gen/derived.txt")" "a v2"

echo "# changed" >> "$repo/Tools/lib/testdata.sh"
check "lib/testdata.sh changed: gen made again" "$(fetch gen; said Generating)" "0
1"

check "ro first fetch" "$(fetch ro)" 0
perl -i -pe 's/version 1/version 2/; s/echo 1/echo 2/' "$repo/gens/ro/make.sh"
check "ro's generator changed: read-only set replaced" "$(fetch ro)" 0
check "ro holds the new output, not nested" "$(cd "$data/ro" && find . ! -name . | sort | tr '\n' ' ')" \
    "./.generator ./locked ./locked/file "
check "ro's new content" "$(cat "$data/ro/locked/file")" 2

# An old set that can't be removed: it holds a hard link to a locked (user-immutable, read-only) file outside TestData,
# which remove_tree leaves alone (it's someone else's too).
perl -i -pe 's/version 2/version 3/; s/echo 2/echo 3/' "$repo/gens/ro/make.sh"
chmod 755 "$data/ro/locked"
mkdir -p "$work/outside"
echo "outside" > "$work/outside/file"
ln "$work/outside/file" "$data/ro/locked/hardlink"
chmod 400 "$work/outside/file"
chflags uchg "$work/outside/file"
check "an old set that can't be removed: fetch fails" "$(fetch ro)" 1
check "  and says where it is" "$(said 'is left in')" 1
check "  with the new set in place, not nested" "$(cat "$data/ro/locked/file"; find "$data/ro" -name '.ro.*' | wc -l | tr -d ' ')" "3
0"
check "  the file outside keeps its flag and mode" "$(stat -f '%Sp %Sf' "$work/outside/file")" "-r-------- uchg"
chflags nouchg "$work/outside/file"
chmod -R u+rwx "$data"
rm -rf "$data"/.ro.old.*

before="$(cat "$data/gen/derived.txt")"
check "a failing generator: exit 1" "$(fetch bad)" 1
check "  no bad set, no staging left" "$([[ -e $data/bad ]] && echo yes || echo no) $(staging_left)" "no 0"

bad=$'\n'"dl file://$repo/src/v1.tar.gz 0000000000000000000000000000000000000000000000000000000000000000 snap-x.unpack.tar.gz"$'\n'
set_downloads "$bad"
check "a download with the wrong SHA-256: exit 1" "$(fetch gen)" 1
check "  the generated set isn't made from the old input" "$(said 'not generating gen')" 1
check "  gen unchanged" "$(cat "$data/gen/derived.txt")" "$before"
set_downloads "$v1"

mkdir -p "$work/nolib"
cp "$repo/Tools/test-data" "$work/nolib/"
check "no library beside it: exit 2" "$("$work/nolib/test-data" path > /dev/null 2>&1; echo $?)" 2
# A repository removed while its fetch runs (a fake curl removes it): the fetch fails instead of making its path again.
mkdir -p "$work/gone/repo/Tools/lib" "$work/gonebin"
cp "$repo/Tools/test-data" "$work/gone/repo/Tools/"
cp "$repo/Tools/lib/common.sh" "$repo/Tools/lib/testdata.sh" "$work/gone/repo/Tools/lib/"
printf '#!/bin/bash\n/bin/rm -rf "%s"\nexit 22\n' "$work/gone/repo" > "$work/gonebin/curl"
chmod +x "$work/gonebin/curl"
check "a repository removed while its fetch runs: exit 2" \
    "$(PATH="$work/gonebin:$PATH" "$work/gone/repo/Tools/test-data" fetch plain > /dev/null 2>&1; echo $?)" 2
check "  and not made again" "$([[ -e $work/gone/repo ]] && echo made || echo gone)" gone
check "path 'd.' (a regex) is unknown" "$(td path 'd.' > /dev/null 2>&1; echo $?)" 2
check "fetch '.*' is unknown" "$(fetch '.*')" 2
check "path dl" "$(td path dl)" "$data/dl"
check "bad usage prints nothing on stdout" "$(td bogus 2> /dev/null; echo $?)" 2

# Two fetches racing: both start generating `wait` (no stamp yet), both wait until each has started, then both swap
# their set in at once. Both succeed, the set is one fetch's whole output, nothing nests, no staging is left.
fetch wait > /dev/null # a set already there, so both swaps move one aside
rm -f "$work/go" "$work/started"
echo "# race" >> "$repo/gens/wait/make.sh"
background_fetch "$work/one" wait
first=$PID
background_fetch "$work/two" wait
second=$PID
until_there "$work" '*/started'
until_there "$data" '*/.wait.generate.??????' 2
check "race: both fetches generating at once" \
    "$(find "$data" -maxdepth 1 -type d -name '.wait.generate.??????' | wc -l | tr -d ' ')" 2
touch "$work/go"
reap "$first"
one=$?
reap "$second"
two=$?
[[ "$one $two" == "0 0" ]] || cat "$work/one" "$work/two"
check "race: both fetches exit 0" "$one $two" "0 0"
check "race: the set is one fetch's output" "$(grep -cxE "$first|$second" "$data/wait/maker" | tr -d ' ')" 1
check "race: nothing nested in the set" "$(find "$data/wait" -name '.wait.*' | wc -l | tr -d ' ')" 0
check "race: no staging left" "$(staging_left)" 0

# An interrupt (INT) between a swap's two renames: the old set is renamed back, nothing is left.
check "dl back to v1" "$(fetch dl)" 0
rm "$data/dl/b.txt"
for signal in INT QUIT; do
    status=130
    [[ "$signal" == QUIT ]] && status=131
    check "$signal mid-swap: exit $status" "$(fetch_signal "$signal" dl)" "$status"
    check "  dl is still there, tarball and all" "$(cat "$data/dl/a.txt"; find "$data/dl" -name '*.unpack.tar.gz' | wc -l | tr -d ' ')" "a v1
1"
    check "  said it restored dl" "$(said 'restored dl')" 1
    check "  no staging left" "$(staging_left)" 0
done
# A second signal (QUIT) while the first one's cleanup runs doesn't cut it short.
check "INT mid-swap, then QUIT in the cleanup: exit 130" "$(CHECK_SIGNAL2=QUIT fetch_signal INT dl)" 130
check "  dl is still there" "$(cat "$data/dl/a.txt")" "a v1"
check "  no staging left" "$(staging_left)" 0

# Killed outright (KILL) at the same point: dl's only copy is in .dl.old.XXXXXX. list shows it; the next fetch puts it
# back (no download) before anything else.
check "KILL mid-swap" "$(CHECK_SIGNAL=KILL fetch dl)" 137
check "  dl's place is empty" "$([[ -e $data/dl ]] && echo yes || echo no)" no
check "  list reports the leftovers" "$(td list | grep -c $'^(staging)\t.*left over' | tr -d ' ')" 2
check "  the next fetch" "$(fetch dl)" 0
check "  restored dl rather than downloading it" "$(said 'restored dl') $(said Downloading)" "1 0"
check "  dl whole again" "$(cat "$data/dl/a.txt" "$data/dl/b.txt")" "a v1
b v1"
check "  no staging left" "$(staging_left)" 0

# Killed outright mid-generation: the next fetch reclaims the staging and generates.
rm -f "$work/go" "$work/started"
echo "# killed" >> "$repo/gens/wait/make.sh"
background_fetch "$work/background.log" wait
until_there "$work" '*/started'
kill -KILL -- "-$PID"
reap "$PID"
check "KILL mid-generation leaves staging" "$(staging_left)" 2
check "  list reports it" "$(td list | grep -c $'^(staging)\t.wait.generate.*left over' | tr -d ' ')" 1
touch "$work/go"
check "  the next fetch" "$(fetch wait)" 0
check "  reclaimed it" "$(said 'removed .wait.generate')" 1
check "  no staging left" "$(staging_left)" 0

# A live fetch's staging survives another fetch's sweep, even when the two run in different time zones and locales
# (start times are compared in C and UTC).
rm -f "$work/go" "$work/started"
echo "# owner" >> "$repo/gens/wait/make.sh"
TZ=UTC LC_ALL=fr_FR.UTF-8 background_fetch "$work/a.log" wait
a=$PID
until_there "$work" '*/started'
check "another fetch while one generates (TZ=UTC, LC_ALL=fr_FR)" "$(fetch plain)" 0
check "  the generating fetch's staging survives" \
    "$(find "$data" -maxdepth 1 -type d -name '.wait.generate.??????' | wc -l | tr -d ' ') $(said 'removed .wait')" "1 0"
touch "$work/go"
reap "$a"
check "  and the generating fetch finishes" "$? $(cat "$data/wait/maker")" "0 $a"
check "  no staging left" "$(staging_left)" 0

# Staging with no owner file is kept while younger than a minute (its maker may be about to write one), reclaimed after.
mkdir "$data/.ghost.generate.AbC123"
check "a new ownerless staging directory: fetch" "$(fetch plain)" 0
check "  kept" "$([[ -d $data/.ghost.generate.AbC123 ]] && echo yes || echo no)" yes
touch -t 202001010000 "$data/.ghost.generate.AbC123"
check "the same, a minute old: fetch" "$(fetch plain)" 0
check "  reclaimed" "$([[ -d $data/.ghost.generate.AbC123 ]] && echo yes || echo no) $(said 'removed .ghost')" "no 1"

# Owner files half made (a fetch killed between writing and renaming one): kept while younger than a minute, removed
# after.
: > "$data/.half.generate.AbC123.owner.111"
: > "$data/.half.generate.AbC123.owner.222"
touch -t 202001010000 "$data/.half.generate.AbC123.owner.222"
check "half-made owner files: fetch" "$(fetch plain)" 0
check "  the new one kept, the minute-old one removed" \
    "$([[ -f $data/.half.generate.AbC123.owner.111 ]] && echo yes || echo no) $([[ -f $data/.half.generate.AbC123.owner.222 ]] && echo yes || echo no)" \
    "yes no"
rm -f "$data/.half.generate.AbC123.owner.111"

# The generator runs with TESTDATA_GENERATOR_PATH, and the tools' versions are part of the hash: a new checktool,
# liblzma, libzstd, or macOS build makes the set again; another PATH for the fetch doesn't.
versioned() { PATH="$work/fetchbin:$PATH" fetch versioned; said Generating; }
check "versioned: first fetch, another checktool first on the fetch's PATH" "$(versioned)" "0
1"
check "  ran the checktool on TESTDATA_GENERATOR_PATH" "$(cat "$data/versioned/out")" "checktool 1.0
$work/toolbin/checktool"
check "  wrote its owner file under another name, then renamed it in" \
    "$(grep -cE '/\.versioned\.generate\.[A-Za-z0-9]{6}\.owner\.[0-9]+ .*/\.versioned\.generate\.[A-Za-z0-9]{6}\.owner$' "$work/mv.log" | tr -d ' ')" 1
check "versioned: same tools, fetched with another PATH" "$(PATH="$work/fetchbin:/usr/bin:/bin" fetch versioned; said Generating)" "0
0"
echo "checktool 2.0" > "$work/toolversion"
check "versioned: a new checktool --version" "$(versioned)" "0
1"
echo "liblzma 2" > "$work/brew/opt/xz/lib/liblzma.dylib"
check "versioned: a new liblzma" "$(versioned)" "0
1"
echo "libzstd 2" > "$work/brew/opt/zstd/lib/libzstd.dylib"
check "versioned: a new libzstd" "$(versioned)" "0
1"
echo 26A2 > "$work/osbuild"
check "versioned: a new macOS build of the same version" "$(versioned)" "0
1"
# Without TESTDATA_GENERATOR_PATH, generators run with Homebrew's bin (here TESTDATA_HOMEBREW_DIR's) then the system's.
mkdir -p "$work/brew/bin"
cp "$work/toolbin/checktool" "$work/brew/bin/checktool"
check "versioned: TESTDATA_GENERATOR_PATH unset" "$(unset TESTDATA_GENERATOR_PATH; versioned)" "0
1"
check "  ran Homebrew's checktool" "$(cat "$data/versioned/out")" "checktool 2.0
$work/brew/bin/checktool"

# Another fetch removes a leftover while this one's sweep looks at it (a fake stat removes what it's asked about): the
# sweep goes on.
mkdir -p "$work/statbin" "$data/.vanish.download.AbC123"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.vanish.download.AbC123.owner"
: > "$data/.vanish.generate.AbC123.owner.333"
cat > "$work/statbin/stat" << 'EOF'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in */.vanish.*) /bin/rm -rf "$arg" ;; esac
done
exec /usr/bin/stat "$@"
EOF
chmod +x "$work/statbin/stat"
check "a leftover removed during the sweep: fetch" "$(PATH="$work/statbin:$PATH" fetch plain)" 0
check "  no error, no claim to have removed it" "$(said 'syntax error') $(said 'No such file') $(said 'removed .vanish')" "0 0 0"
check "  no staging left" "$(staging_left)" 0

# Another fetch fills a leftover old set's place just before this one renames it back (a fake perl does it first, as
# $work/race says: renames the old set back, or swaps a newer one in): no error, and the old directory goes.
mkdir -p "$work/perlbin"
cat > "$work/perlbin/perl" << EOF
#!/bin/bash
if [[ "\$*" == *"rename("* && "\$*" == *"/.plain.old.AbC123/plain "* && -f "$work/race" ]]; then
    case "\$(cat "$work/race")" in
        rename) /usr/bin/perl -e 'rename(\$ARGV[0], \$ARGV[1])' "$data/.plain.old.AbC123/plain" "$data/plain" ;;
        newer) mkdir "$data/plain"; echo "plain file" > "$data/plain/plain.txt" ;;
    esac
    /bin/rm -f "$work/race"
fi
exec /usr/bin/perl "\$@"
EOF
chmod +x "$work/perlbin/perl"
for race in rename newer; do
    rm -rf "$data/plain"
    mkdir -p "$data/.plain.old.AbC123/plain"
    echo "plain file" > "$data/.plain.old.AbC123/plain/plain.txt"
    echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.plain.old.AbC123.owner"
    echo "$race" > "$work/race"
    check "an old set's place filled by another fetch first ($race): fetch" "$(PATH="$work/perlbin:$PATH" fetch plain)" 0
    check "  raced, no error" "$([[ -e $work/race ]] || echo raced) $(said error)" "raced 0"
    check "  plain in place, no staging left" "$(cat "$data/plain/plain.txt") $(staging_left)" "plain file 0"
done

# At an old set's place, a dangling link, a link to a full directory, or a directory holding only hidden files (Finder's
# .DS_Store) isn't the set: the sweep keeps the old copy and says so (the fetch then refuses a link, and downloads into
# the directory); once that's gone, the next fetch restores the old copy.
mkdir -p "$work/elsewhere"
echo "someone else's" > "$work/elsewhere/file"
for place in dangling-link link-to-directory hidden-files; do
    rm -rf "$data/plain"
    mkdir -p "$data/.plain.old.AbC123/plain"
    echo "plain file" > "$data/.plain.old.AbC123/plain/plain.txt"
    echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.plain.old.AbC123.owner"
    status=2
    case "$place" in
        dangling-link) ln -s "$work/nowhere" "$data/plain" ;;
        link-to-directory) ln -s "$work/elsewhere" "$data/plain" ;;
        hidden-files) mkdir "$data/plain"; : > "$data/plain/.DS_Store"; status=0 ;;
    esac
    check "$place at an old set's place: fetch" "$(fetch plain)" "$status"
    check "  the old copy kept, and said so" \
        "$(cat "$data/.plain.old.AbC123/plain/plain.txt") $(said "isn't a set's directory")" "plain file 1"
    if [[ -L "$data/plain" ]]; then rm "$data/plain"; else rm -rf "$data/plain"; fi
    check "  that removed: the next fetch" "$(fetch plain)" 0
    check "  restored the old copy" "$(said 'restored plain') $(cat "$data/plain/plain.txt") $(staging_left)" "1 plain file 0"
done
check "  the linked directory untouched" "$(cat "$work/elsewhere/file")" "someone else's"

# Nor is an empty directory (what a concurrent fetch_set leaves before its download lands): the old copy replaces it,
# so the fetch needs no download (a curl that fails shows whether it tried).
rm -rf "$data/plain"
mkdir -p "$data/.plain.old.AbC123/plain" "$data/plain" "$work/failbin"
echo "plain file" > "$data/.plain.old.AbC123/plain/plain.txt"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.plain.old.AbC123.owner"
printf '#!/bin/bash\nexit 22\n' > "$work/failbin/curl"
chmod +x "$work/failbin/curl"
check "an empty directory at an old set's place, downloads failing: fetch" "$(PATH="$work/failbin:$PATH" fetch plain)" 0
check "  restored the old copy" "$(said 'restored plain') $(cat "$data/plain/plain.txt") $(staging_left)" "1 plain file 0"

# An old directory holding nothing (a fetch killed before its first rename) is removed even when the set isn't in place.
rm -rf "$data/plain"
mkdir -p "$data/.plain.old.AbC123"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.plain.old.AbC123.owner"
check "an empty old directory, the set missing, downloads failing: fetch fails" "$(PATH="$work/failbin:$PATH" fetch plain)" 1
check "  the old directory removed, no 'only copy' error" "$(staging_left) $(said 'only copy')" "0 0"
check "  the next fetch downloads plain" "$(fetch plain; cat "$data/plain/plain.txt")" "0
plain file"

# TestData a symbolic link: the fetch refuses it before its sweep removes anything there.
mv "$data" "$work/linked"
ln -s "$work/linked" "$data"
: > "$work/linked/.link.generate.AbC123.owner.444"
touch -t 202001010000 "$work/linked/.link.generate.AbC123.owner.444"
check "TestData a symbolic link: the fetch refuses it" "$(fetch plain)" 2
check "  and removed nothing there" "$([[ -f $work/linked/.link.generate.AbC123.owner.444 ]] && echo kept)" kept
rm "$data"
mv "$work/linked" "$data"
rm -f "$data/.link.generate.AbC123.owner.444"

# TERM while removing a renamed-aside staging directory (a fake rm sends it at the trash): the cleanup removes the trash.
mkdir -p "$work/trashrmbin"
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
rm -f "$data/plain/plain.txt"
touch "$work/trash-signal"
check "TERM while removing a trash: exit 130" "$(PATH="$work/trashrmbin:$PATH" fetch plain)" 130
check "  the signal was sent, nothing left" "$([[ -e $work/trash-signal ]] && echo unsent) $(staging_left)" " 0"

# TERM right after the rename aside (a fake perl does the rename, then sends it): the cleanup still knows the trash.
mkdir -p "$work/renameperlbin"
cat > "$work/renameperlbin/perl" << EOF
#!/bin/bash
if [[ "\$*" == *"rename("* && "\${@: -1}" == *".trash."* && -f "$work/rename-signal" ]]; then
    /bin/rm -f "$work/rename-signal"
    /usr/bin/perl "\$@" || exit \$?
    kill -TERM "\$PPID"
    exit 0
fi
exec /usr/bin/perl "\$@"
EOF
chmod +x "$work/renameperlbin/perl"
rm -f "$data/plain/plain.txt"
touch "$work/rename-signal"
check "TERM right after renaming a staging directory aside: exit 130" "$(PATH="$work/renameperlbin:$PATH" fetch plain)" 130
check "  the signal was sent, nothing left" "$([[ -e $work/rename-signal ]] && echo unsent) $(staging_left)" " 0"

# A fetch's own trash, listed while that fetch removes it (a fake rm runs `list` then), is in use: its tag matches the
# fetch's PID and start time.
mkdir -p "$work/trashlistbin"
cat > "$work/trashlistbin/rm" << EOF
#!/bin/bash
if [[ "\$*" == *".trash."* && -f "$work/trash-list" ]]; then
    /bin/rm -f "$work/trash-list"
    "$repo/Tools/test-data" list > "$work/trash-list.out" 2>&1
fi
exec /bin/rm "\$@"
EOF
chmod +x "$work/trashlistbin/rm"
rm -f "$data/plain/plain.txt"
touch "$work/trash-list"
check "a fetch's trash listed while it removes it: fetch" "$(PATH="$work/trashlistbin:$PATH" fetch plain)" 0
check "  listed as being removed, not left over" \
    "$(grep -c 'trash.*being removed by fetch' "$work/trash-list.out" | tr -d ' ') $(grep -c 'trash.*left over' "$work/trash-list.out" | tr -d ' ')" \
    "1 0"

# A leftover that a plain `rm -rf` can't remove: a locked file in a directory that can't be entered, a locked directory
# that can't be written, a locked directory that can't be entered inside another, a file and a directory whose ACLs deny
# their deletion; a directory whose ACL denies listing and search above a locked one, and one denying listing above a
# read-only one; a locked file with two links, both inside; append-only files and directories; a locked file whose ACL
# denies reading and deleting it; and a symbolic link to a locked file outside, with an ACL (left as it is). The sweep
# removes it all.
cases="$data/.cases.unpack.AbC123"
mkdir -p "$cases/a/locked" "$cases/b/dir" "$cases/c/outer/inner" "$cases/d" "$cases/e/dir" "$cases/f/acl/locked" \
    "$cases/g/acl/readonly" "$cases/h/one" "$cases/h/two" "$cases/i/appended" "$cases/j" "$cases/k"
echo x > "$cases/f/acl/locked/file"
chflags uchg "$cases/f/acl/locked"
chmod +a "everyone deny list,search" "$cases/f/acl"
chflags uchg "$cases/f/acl" # locked too: its ACL can change only once its flag is cleared
echo x > "$cases/g/acl/readonly/file"
chmod 500 "$cases/g/acl/readonly"
chmod +a "everyone deny list" "$cases/g/acl"
echo x > "$cases/h/one/file"
ln "$cases/h/one/file" "$cases/h/two/file"
chflags uchg "$cases/h/one/file"
echo x > "$cases/i/appended/file"
echo x > "$cases/i/file"
chflags uappnd "$cases/i/appended" "$cases/i/file"
echo x > "$cases/j/file"
chmod +a "everyone deny read,delete" "$cases/j/file"
chflags uchg "$cases/j/file"
echo "outside" > "$work/outside/linked"
chmod +a "everyone deny delete" "$work/outside/linked"
chflags uchg "$work/outside/linked"
ln -s "$work/outside/linked" "$cases/k/link"
chflags -h uchg "$cases/k/link"
echo x > "$cases/a/locked/file"
chflags uchg "$cases/a/locked/file"
chmod 000 "$cases/a/locked"
echo x > "$cases/b/dir/file"
chmod 500 "$cases/b/dir"
chflags uchg "$cases/b/dir"
echo x > "$cases/c/outer/inner/file"
chmod 000 "$cases/c/outer/inner"
chflags uchg "$cases/c/outer/inner"
chmod 000 "$cases/c/outer"
echo x > "$cases/d/file"
chmod +a "everyone deny delete" "$cases/d/file"
chmod +a "everyone deny delete" "$cases/e/dir"
chflags uchg "$cases/e/dir" # locked too: its ACL can change only once its flag is cleared
# More: a locked file whose name holds a newline; 300 locked files (more than one batch); a link to a file outside with
# an ACL and no flags (left as it is); a file and a directory whose ACLs hide their attributes (deny readsecurity).
mkdir -p "$cases/l" "$cases/m" "$cases/n" "$cases/o/hidden-dir"
echo x > "$cases/l/new"$'\n'"line"
chflags uchg "$cases/l/new"$'\n'"line"
for ((i = 0; i < 300; i++)); do echo x > "$cases/m/$i"; done
chflags uchg "$cases"/m/*
echo "outside" > "$work/outside/acl-only"
chmod +a "everyone deny delete" "$work/outside/acl-only"
ln -s "$work/outside/acl-only" "$cases/n/link"
chflags -h uchg "$cases/n/link"
echo x > "$cases/o/hidden-file"
chmod +a "everyone deny readsecurity" "$cases/o/hidden-file" "$cases/o/hidden-dir"
# Hidden links to that file, in a locked directory so the first `rm -rf` (which unlinks without stat) leaves them for the
# walk: one whose ACL `chmod -h -N` removes, and one denying read too, where it can't (then never followed).
mkdir -p "$cases/o/locked"
ln -s "$work/outside/acl-only" "$cases/o/locked/hidden-link"
chmod -h +a "everyone deny readsecurity" "$cases/o/locked/hidden-link"
ln -s "$work/outside/acl-only" "$cases/o/locked/hidden-read-link"
chmod -h +a "everyone deny read,readsecurity" "$cases/o/locked/hidden-read-link"
# And a hidden link to a directory outside with an ACL (it opens through the link: never followed).
mkdir -p "$work/outside/acl-dir"
chmod +a "everyone deny delete" "$work/outside/acl-dir"
ln -s "$work/outside/acl-dir" "$cases/o/locked/hidden-dir-link"
chmod -h +a "everyone deny readsecurity" "$cases/o/locked/hidden-dir-link"
chflags uchg "$cases/o/locked"
# And a hidden file below a locked directory whose ACL denies listing: the walk opens the directory to reach it.
mkdir -p "$cases/p/acl"
echo x > "$cases/p/acl/hidden-file"
chmod +a "everyone deny readsecurity" "$cases/p/acl/hidden-file"
chmod +a "everyone deny list,search" "$cases/p/acl"
chflags uchg "$cases/p/acl"
# And directories that open but can't be entered (by mode, and by an ACL denying search only), holding locked entries:
# the walk enters them so find can reach what's inside.
mkdir -p "$cases/q/listable/dir" "$cases/r/listable/dir"
echo x > "$cases/q/listable/file"
echo x > "$cases/r/listable/file"
chflags uchg "$cases/q/listable/file" "$cases/q/listable/dir" "$cases/r/listable/file" "$cases/r/listable/dir"
chmod 600 "$cases/q/listable"
chmod +a "everyone deny search" "$cases/r/listable"
echo "99998 Mon Jan  1 00:00:00 2024" > "$cases.owner"
check "a leftover with locked, unenterable, and ACL-protected entries: fetch" "$(fetch plain)" 0
check "  removed, no error" "$(said 'removed .cases.unpack.AbC123') $(said error) $(listed .cases.unpack.AbC123)" "1 0 no"
ls -le "$work/outside/linked" > "$work/outside-acl"
check "  the linked file outside keeps its flag and ACL" \
    "$(stat -f %Sf "$work/outside/linked") $(grep -c 'deny delete' "$work/outside-acl" | tr -d ' ')" "uchg 1"
ls -le "$work/outside/acl-only" > "$work/outside-acl"
ls -lde "$work/outside/acl-dir" >> "$work/outside-acl"
check "  the linked file and directory outside with only an ACL keep it" \
    "$(grep -c 'deny delete' "$work/outside-acl" | tr -d ' ')" 2
chflags nouchg "$work/outside/linked"
# A leftover whose own ACL denies listing and search, and that is locked, holding a locked directory.
mkdir -p "$data/.rootacl.unpack.AbC123/locked"
echo x > "$data/.rootacl.unpack.AbC123/locked/file"
chflags uchg "$data/.rootacl.unpack.AbC123/locked"
chmod +a "everyone deny list,search" "$data/.rootacl.unpack.AbC123"
chflags uchg "$data/.rootacl.unpack.AbC123"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.rootacl.unpack.AbC123.owner"
check "a locked leftover whose own ACL denies listing: fetch" "$(fetch plain)" 0
check "  removed, no error" "$(said 'removed .rootacl.unpack.AbC123') $(said error) $(listed .rootacl.unpack.AbC123)" "1 0 no"
# A leftover whose own ACL hides its attributes (deny readsecurity: `-e` reads false): list reports it, a fetch removes it.
mkdir -p "$data/.hidden.unpack.AbC123/in"
echo x > "$data/.hidden.unpack.AbC123/in/file"
chmod +a "everyone deny readsecurity" "$data/.hidden.unpack.AbC123"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.hidden.unpack.AbC123.owner"
check "a leftover hidden by its ACL: list reports it" "$(td list | grep -c 'hidden.unpack.AbC123.*hidden by its ACL' | tr -d ' ')" 1
check "  a fetch removes it" "$(fetch plain) $(said 'removed .hidden.unpack.AbC123') $(listed .hidden.unpack.AbC123)" "0 1 no"
# A trash whose fetch is gone (a PID with another start time), hidden by its ACL: list reports it, a fetch removes it.
mkdir -p "$data/.hidden.unpack.XyZ789.trash.$$.MonJan1000000002000/in"
chmod +a "everyone deny readsecurity" "$data/.hidden.unpack.XyZ789.trash.$$.MonJan1000000002000"
check "a trash hidden by its ACL: list reports it" "$(td list | grep -c 'XyZ789.trash.*left over' | tr -d ' ')" 1
check "  a fetch removes it" "$(fetch plain) $(listed .hidden.unpack.XyZ789)" "0 no"

# Files whose ACLs hide them (deny readsecurity) and deny their deletion are left alone, and the removal fails, saying so:
# a hard link to such a file outside TestData (which keeps its ACL: it's still hidden), and a link to the file outside
# with only an ACL (which keeps it).
mkdir -p "$data/.hardhidden.unpack.AbC123" "$data/.linkhidden.unpack.AbC123"
echo "someone else's" > "$work/outside/hidden"
ln "$work/outside/hidden" "$data/.hardhidden.unpack.AbC123/hardlink"
chmod +a "everyone deny delete,readsecurity" "$work/outside/hidden"
ln -s "$work/outside/acl-only" "$data/.linkhidden.unpack.AbC123/link"
chmod -h +a "everyone deny delete,readsecurity" "$data/.linkhidden.unpack.AbC123/link"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.hardhidden.unpack.AbC123.owner"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.linkhidden.unpack.AbC123.owner"
check "hidden files that deny deletion: fetch" "$(fetch plain)" 0
check "  neither removed, both said" \
    "$(said "can't remove .*hardhidden.unpack.AbC123") $(said "can't remove .*linkhidden.unpack.AbC123")" "1 1"
ls -le "$work/outside/acl-only" > "$work/outside-acl"
check "  the hidden file outside still hidden, the linked one keeps its ACL" \
    "$(perl -e 'print((lstat $ARGV[0]) ? "visible" : "hidden")' "$work/outside/hidden") $(grep -c 'deny delete' "$work/outside-acl" | tr -d ' ')" \
    "hidden 1"
chmod -N "$work/outside/hidden"
for leftover in "$data"/.hardhidden.unpack.AbC123* "$data"/.linkhidden.unpack.AbC123*; do
    find "$leftover" -type l -exec chmod -h -N {} + 2> /dev/null
    rm -rf "$leftover"
done

# Disk images: attach_image IMAGE MOUNTPOINT [OPTION] attaches and mounts one and prints its first device;
# detach_image DEVICE detaches it (by device: by mount point it can unmount and then fail, "Resource busy").
attach_image() {
    hdiutil attach -nobrowse -noverify -noautoopen ${3:+"$3"} -mountpoint "$2" "$1" |
        perl -ne 'if (m{^(/dev/disk\d+)\s} && !$done++) { print "$1\n" }'
}
detach_image() { hdiutil detach -quiet "$1" 2> /dev/null || hdiutil detach -quiet -force "$1"; }

# A leftover holding a mounted disk image (a generator's, its fetch killed outright): it is unmounted and detached before
# the removal, which never reaches into the volume (its file is still there when the image is attached again). (Mounts
# nested in an image's volume need root: an unprivileged attach there fails, "Permission denied".)
mkdir -p "$data/.mounted.generate.AbC123/.work/volume" "$work/remount"
hdiutil create -quiet -size 16m -fs APFS -volname testdata-check -type SPARSE "$work/image"
attach_image "$work/image.sparseimage" "$data/.mounted.generate.AbC123/.work/volume" > /dev/null
echo "on the volume" > "$data/.mounted.generate.AbC123/.work/volume/file"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.mounted.generate.AbC123.owner"
# The tool's statfs: f_fsid's first word is st_dev on APFS volumes and disk images (its offset read right).
statfs_perl="$(perl -0777 -ne "print \$1 if /^STATFS_PERL='(.*?)'\$/ms" "$repo/Tools/test-data")"
check "fsid's first word is st_dev (the Data volume, an image)" \
    "$(perl -e "$statfs_perl"'print join(" ", map { (split /:/, fsid($_) // "")[0] eq (lstat $_)[0] ? "same" : "differs" } @ARGV)' "$work" "$data/.mounted.generate.AbC123/.work/volume")" \
    "same same"
# Run through another spelling of the repository's path (the Data volume's own, /System/Volumes/Data/…: `pwd -P` keeps
# it, mount lists the kernel's).
alternate="/System/Volumes/Data$(cd "$repo" && pwd -P)"
check "the repository reached through /System/Volumes/Data" "$(ls "$alternate/Tools/test-data" > /dev/null; echo $?)" 0
check "a leftover with a disk image mounted inside, through that path: fetch" \
    "$("$alternate/Tools/test-data" fetch plain > /dev/null 2> "$log"; echo $?)" 0
check "  unmounted and detached, the leftover removed" \
    "$(said 'unmounted ') $(said 'detached /dev/disk') $(said 'removed .mounted.generate.AbC123') $(listed .mounted.generate.AbC123) $(hdiutil info | grep -c "$work/image.sparseimage" | tr -d ' ')" \
    "1 1 1 no 0"
device="$(attach_image "$work/image.sparseimage" "$work/remount" -readonly)"
check "  the volume's file untouched" "$(cat "$work/remount/file" 2>&1)" "on the volume"
detach_image "$device"

# A volume inside a leftover that can't be unmounted (fake umount and hdiutil that fail, as for a mount this user may not
# undo): nothing on it is changed (rm, find, and the walk stay on the leftover's volume), no unmount or detach is claimed,
# and the leftover is reported as not removed.
mkdir -p "$data/.stuck.generate.AbC123/.work/volume" "$work/stuckbin"
device="$(attach_image "$work/image.sparseimage" "$data/.stuck.generate.AbC123/.work/volume")"
volume="$data/.stuck.generate.AbC123/.work/volume"
mkdir "$volume/readonly" "$volume/locked" "$volume/closed"
echo keep > "$volume/readonly/file"
echo keep > "$volume/locked-file"
echo keep > "$volume/acl-file"
chmod 500 "$volume/readonly"
chmod 000 "$volume/closed"
chflags uchg "$volume/locked" "$volume/locked-file"
chmod +a "everyone deny delete" "$volume/acl-file"
# The volume's own root read-only, with an ACL, and locked: find still visits a mount point (it only doesn't descend).
chmod +a "everyone deny delete_child" "$volume"
chmod 555 "$volume"
chflags uchg "$volume"
# A fake mount that lists it as a network share, not a disk (and umount recording its calls): unmounting is tried, and
# only the device checks (the walk, both find passes) and `-x` (rm and find) keep the removal off the volume.
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$work/umount-calls" > "$work/stuckbin/umount"
printf '#!/bin/sh\n[ "$1" = info ] && exec /usr/bin/hdiutil "$@"\nexit 1\n' > "$work/stuckbin/hdiutil"
cat > "$work/stuckbin/mount" << EOF
#!/bin/sh
for volume in "$data"/.stuck.generate.AbC123*/.work/volume; do
    [ -d "\$volume" ] && echo "//user@server/share on \$(cd "\$volume" && pwd -P) (smbfs, nodev, nosuid, mounted by user)"
done
exit 0
EOF
chmod +x "$work/stuckbin/umount" "$work/stuckbin/hdiutil" "$work/stuckbin/mount"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.stuck.generate.AbC123.owner"
check "a volume inside a leftover that can't be unmounted, listed as a share: fetch" \
    "$(PATH="$work/stuckbin:$PATH" fetch plain)" 0
check "  unmounting tried, no unmount or detach claimed, the leftover reported" \
    "$(grep -c 'stuck.generate.AbC123.*/.work/volume$' "$work/umount-calls" | tr -d ' ') $(said 'unmounted ') $(said 'detached ') $(said "can't remove .*stuck.generate.AbC123")" \
    "1 0 0 1"
for leftover in "$data"/.stuck.generate.AbC123*; do # under the trash name it was renamed to
    [[ "$leftover" == *.owner ]] || volume="$leftover/.work/volume"
done
ls -le "$volume/acl-file" > "$work/volume-acl"
ls -led "$volume" > "$work/root-acl"
check "  nothing on the volume changed" \
    "$(stat -f '%Sf' "$volume/locked" "$volume/locked-file" | tr '\n' ' ')$(stat -f %Lp "$volume/readonly" "$volume/closed" | tr '\n' ' ')$(grep -c 'deny delete' "$work/volume-acl" | tr -d ' ')" \
    "uchg uchg 500 0 1"
check "  nor its root" "$(stat -f '%Sf %Lp' "$volume") $(grep -c 'deny delete_child' "$work/root-acl" | tr -d ' ')" \
    "uchg 555 1"
# The same volume's mount point hidden by its ACL (unlocked: a locked entry's ACL can't change), mount listing it, and
# TestData a link to where it is (TESTDATA_ALLOW_LINK=1: the leftover's path isn't the one mount lists): the walk reads
# its file system by statfs and leaves it alone.
chflags nouchg "$volume"
chmod +a "everyone deny readsecurity" "$volume"
for leftover in "$data"/.stuck.generate.AbC123*; do
    [[ "$leftover" == *.owner ]] || echo "99998 Mon Jan  1 00:00:00 2024" > "$leftover.owner"
done
rm -f "$work/stuckbin/mount"
mv "$data" "$work/linked-data"
ln -s "$work/linked-data" "$data"
check "the same, its mount point hidden, TestData linked: fetch" \
    "$(TESTDATA_ALLOW_LINK=1 PATH="$work/stuckbin:$PATH" fetch plain)" 0
check "  no unmount or detach claimed, the leftover reported" \
    "$(said 'unmounted ') $(said 'detached ') $(said "can't remove .*stuck.generate.AbC123")" "0 0 1"
for leftover in "$data"/.stuck.generate.AbC123*; do # renamed again (the hidden mount point itself can't be globbed:
    [[ "$leftover" == *.owner ]] || volume="$leftover/.work/volume" # a glob stats it)
done
check "  the mount point still hidden" "$(perl -e 'print((lstat $ARGV[0]) ? "visible" : "hidden")' "$volume")" hidden
chmod -N "$volume"
chmod 755 "$volume"
chflags nouchg "$volume/locked" "$volume/locked-file"
chmod -N "$volume/acl-file"
detach_image "$device"
for leftover in "$data"/.stuck.generate.AbC123*; do rm -rf "$leftover"; done

# A leftover that is itself a mount point (TestData still linked): `rm -x` would empty the volume (the leftover's device
# is the volume's). It can't be unmounted: refused, the volume untouched. It can: unmounted and detached first, then
# removed, and the volume's file is still there when the image is attached again.
mkdir "$data/.mp.generate.AbC123"
device="$(attach_image "$work/image.sparseimage" "$data/.mp.generate.AbC123")"
mkdir "$data/.mp.generate.AbC123/sub"
echo "on the volume" > "$data/.mp.generate.AbC123/sub/file"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.mp.generate.AbC123.owner"
check "a leftover that is a mount point that can't be unmounted: fetch" \
    "$(TESTDATA_ALLOW_LINK=1 PATH="$work/stuckbin:$PATH" fetch plain)" 0
check "  refused, nothing claimed, the volume's file there" \
    "$(said "can't remove .*mp.generate.AbC123[^ ]*: a volume is mounted there") $(said 'unmounted ') $(said 'detached ') $(cat "$data/.mp.generate.AbC123/sub/file" 2>&1)" \
    "1 0 0 on the volume"
check "a leftover that is a mount point: fetch" "$(TESTDATA_ALLOW_LINK=1 fetch plain)" 0
check "  unmounted and detached, the leftover removed" \
    "$(said 'unmounted .*mp.generate.AbC123') $(said 'detached /dev/disk') $(said 'removed .mp.generate.AbC123') $(listed .mp.generate.AbC123) $(hdiutil info | grep -c "$work/image.sparseimage" | tr -d ' ')" \
    "1 1 1 no 0"
device="$(attach_image "$work/image.sparseimage" "$work/remount" -readonly)"
check "  the volume's file untouched" "$(cat "$work/remount/sub/file" 2>&1)" "on the volume"
detach_image "$device"
rm "$data"
mv "$work/linked-data" "$data"

# TestData on HFS+ (a link to it), where link(2) on a directory needs no privilege: a leftover holding hard links to
# directories outside TestData (one read-only with an ACL) is refused before any rm, and nothing outside changes; one
# without (a locked directory in it) is removed as anywhere else.
hdiutil create -quiet -size 16m -fs HFS+J -volname testdata-hfs -type SPARSE "$work/hfs-image"
mkdir "$work/hfs"
device="$(attach_image "$work/hfs-image.sparseimage" "$work/hfs")"
hfs_data="$work/hfs/TestData"
mkdir -p "$hfs_data/.hfslinks.generate.AbC123/in" "$hfs_data/.hfsplain.generate.AbC123/in/locked" \
    "$work/hfs/outside/shared" "$work/hfs/outside/guarded/inner"
echo "someone else's" > "$work/hfs/outside/shared/file"
echo "someone else's" > "$work/hfs/outside/guarded/inner/file"
chmod 500 "$work/hfs/outside/guarded"
chmod +a "everyone deny delete" "$work/hfs/outside/guarded"
perl -e 'link($ARGV[0], $ARGV[1]) or die "link: $!\n"' "$work/hfs/outside/shared" "$hfs_data/.hfslinks.generate.AbC123/in/shared"
perl -e 'link($ARGV[0], $ARGV[1]) or die "link: $!\n"' "$work/hfs/outside/guarded" "$hfs_data/.hfslinks.generate.AbC123/in/guarded"
chflags uchg "$hfs_data/.hfsplain.generate.AbC123/in/locked"
# And one whose link is inside a directory hidden by its ACL (which can't be checked: refused too).
mkdir -p "$hfs_data/.hfshidden.generate.AbC123/in/hidden"
perl -e 'link($ARGV[0], $ARGV[1]) or die "link: $!\n"' "$work/hfs/outside/shared" "$hfs_data/.hfshidden.generate.AbC123/in/hidden/shared"
chmod +a "everyone deny readsecurity" "$hfs_data/.hfshidden.generate.AbC123/in/hidden"
echo "99998 Mon Jan  1 00:00:00 2024" > "$hfs_data/.hfshidden.generate.AbC123.owner"
echo "99998 Mon Jan  1 00:00:00 2024" > "$hfs_data/.hfslinks.generate.AbC123.owner"
echo "99998 Mon Jan  1 00:00:00 2024" > "$hfs_data/.hfsplain.generate.AbC123.owner"
mv "$data" "$work/data-aside"
ln -s "$hfs_data" "$data"
check "TestData on HFS+, leftovers with and without directory hard links: fetch" \
    "$(TESTDATA_ALLOW_LINK=1 fetch plain)" 0
check "  the ones with links refused, the other removed" \
    "$(said "can't remove .*hfslinks.generate.AbC123[^ ]*: it is on HFS+") $(said "can't remove .*hfshidden.generate.AbC123[^ ]*: it is on HFS+") $(said 'removed .hfsplain.generate.AbC123') $(listed .hfsplain.generate.AbC123)" \
    "1 1 1 no"
ls -led "$work/hfs/outside/guarded" > "$work/guarded-acl"
check "  the directories outside untouched" \
    "$(cat "$work/hfs/outside/shared/file" "$work/hfs/outside/guarded/inner/file" | tr '\n' ' ')$(stat -f %Lp "$work/hfs/outside/guarded") $(grep -c 'deny delete' "$work/guarded-acl" | tr -d ' ')" \
    "someone else's someone else's 500 1"
rm "$data"
mv "$work/data-aside" "$data"
detach_image "$device"

# A leftover's own name held by a link hidden by its ACL (a staging name and a trash name, to a directory outside with a
# locked entry and an ACL): left alone, never followed, and no fetch fails over it.
mkdir -p "$work/target/locked"
chflags uchg "$work/target/locked"
chmod +a "everyone deny list" "$work/target"
ln -s "$work/target" "$data/.linkroot.unpack.AbC123"
ln -s "$work/target" "$data/.linkroot.unpack.XyZ789.trash.$$.MonJan1000000002000"
chmod -h +a "everyone deny readsecurity" "$data/.linkroot.unpack.AbC123" \
    "$data/.linkroot.unpack.XyZ789.trash.$$.MonJan1000000002000"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.linkroot.unpack.AbC123.owner"
check "leftover names held by hidden links: fetch" "$(fetch plain) $(said "can't remove\|refusing")" "0 0"
ls -lde "$work/target" > "$work/target-acl"
check "  the links left, their target untouched" \
    "$(listed .linkroot.unpack.AbC123) $(listed .linkroot.unpack.XyZ789) $(stat -f %Sf "$work/target/locked") $(grep -c 'deny list' "$work/target-acl" | tr -d ' ')" \
    "yes yes uchg 1"
echo "$$ $(LC_ALL=C TZ=UTC0 ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //; s/ $//')" > "$data/.linkroot.unpack.AbC123.owner"
td list > "$work/list.out"
check "  not listed, even with a live owner" "$(grep -c linkroot "$work/list.out" | tr -d ' ')" 0
chmod -h -N "$data/.linkroot.unpack.AbC123" "$data/.linkroot.unpack.XyZ789.trash.$$.MonJan1000000002000"
rm -f "$data/.linkroot.unpack.AbC123" "$data/.linkroot.unpack.XyZ789.trash.$$.MonJan1000000002000" \
    "$data/.linkroot.unpack.AbC123.owner"
chmod -N "$work/target"
chflags nouchg "$work/target/locked"

# A directory inside a leftover whose ACL both hides it and denies listing it: unhidden (opendir's EACCES says it's a
# directory) and removed.
mkdir -p "$data/.unlisted.unpack.AbC123/in/dir"
echo x > "$data/.unlisted.unpack.AbC123/in/dir/file"
chmod +a "everyone deny list,readsecurity" "$data/.unlisted.unpack.AbC123/in/dir"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.unlisted.unpack.AbC123.owner"
check "a hidden directory that can't be listed: fetch" "$(fetch plain)" 0
check "  removed, no error" "$(said 'removed .unlisted.unpack.AbC123') $(said error) $(listed .unlisted.unpack.AbC123)" "1 0 no"
# The same as a leftover itself: a staging directory whose own ACL hides it and denies listing it.
mkdir -p "$data/.unlistedroot.unpack.AbC123/in"
echo x > "$data/.unlistedroot.unpack.AbC123/in/file"
chmod +a "everyone deny list,readsecurity" "$data/.unlistedroot.unpack.AbC123"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.unlistedroot.unpack.AbC123.owner"
check "a leftover hidden by its ACL that can't be listed: fetch" "$(fetch plain)" 0
check "  removed, no error" \
    "$(said 'removed .unlistedroot.unpack.AbC123') $(said error) $(listed .unlistedroot.unpack.AbC123)" "1 0 no"
# (A two-volume image, one volume inside a leftover and one elsewhere, is left out: it needs `diskutil apfs addVolume`
# and `diskutil mount`, which hung on a freshly added volume, so the check could hang. Probe f3-whole-disk.sh covers it.)

# TestData that can't be entered: the fetch refuses rather than allowing any path.
chmod 000 "$data"
check "TestData that can't be entered: the fetch refuses it" "$(fetch plain)" 2
check "  and says so" "$(said "can't enter")" 1
chmod 755 "$data"

# A set whose only entries are hidden but which has its marker (a generator whose output is all dotfiles) is a set: the
# old copy at its place goes.
rm -rf "$data/plain"
mkdir -p "$data/plain" "$data/.plain.old.AbC123/plain"
: > "$data/plain/.generator"
echo "plain file" > "$data/.plain.old.AbC123/plain/plain.txt"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.plain.old.AbC123.owner"
check "a set of hidden files with its marker at an old set's place: fetch" "$(fetch plain)" 0
check "  the old copy removed, no error" \
    "$([[ -d $data/.plain.old.AbC123 ]] && echo kept || echo removed) $(said "isn't a set's directory") $(staging_left)" "removed 0 0"
rm -f "$data/plain/.generator"

# A trash is in use only while the fetch named in it runs, by PID and start time: one named for this script (running)
# is listed and kept; one with this PID but another start time (a reused PID) is listed as left over and removed.
start_tag="$$.$(LC_ALL=C TZ=UTC0 ps -o lstart= -p $$ | tr -cd 'A-Za-z0-9')"
mkdir -p "$data/.plain.old.AbC123.trash.$start_tag/plain" "$data/.plain.old.XyZ789.trash.$$.MonJan1000000002000/plain"
check "trashes: list shows the live one and the reused PID's" \
    "$(td list | grep -c -e "AbC123.trash.*being removed by fetch $$" -e "XyZ789.trash.*left over" | tr -d ' ')" 2
check "  fetch" "$(fetch plain)" 0
check "  the live one kept, the reused PID's removed" \
    "$([[ -d $data/.plain.old.AbC123.trash.$start_tag ]] && echo kept) $([[ -d $data/.plain.old.XyZ789.trash.$$.MonJan1000000002000 ]] && echo kept)" \
    "kept "
rm -rf "$data/.plain.old.AbC123.trash.$start_tag"

# Paths that can't be entered or read, as if removed meanwhile: a leftover without search permission (its `cd` fails in
# in_testdata) and one whose owner file can't be read are removed without an error; a `cut` that removes the owner file
# it's given (gone between owner_alive and the report) leaves no error either.
mkdir -p "$data/.perm.download.AbC123/inner" "$data/.unread.download.AbC123" "$work/cutbin"
echo "a file" > "$data/.perm.download.AbC123/file"
chmod 000 "$data/.perm.download.AbC123/inner" "$data/.perm.download.AbC123"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.perm.download.AbC123.owner"
echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.unread.download.AbC123.owner"
chmod 000 "$data/.unread.download.AbC123.owner"
check "a leftover that can't be entered, an owner file that can't be read: fetch" "$(fetch plain)" 0
check "  both removed, no error" \
    "$(said 'removed .perm.download.AbC123') $(said 'removed .unread.download.AbC123') $(said 'error\|ermission denied') $(staging_left)" \
    "1 1 0 0"
mkdir "$data/.live.generate.AbC123"
echo "$$ $(LC_ALL=C TZ=UTC0 ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //; s/ $//')" > "$data/.live.generate.AbC123.owner"
cat > "$work/cutbin/cut" << 'EOF'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in *.owner) /bin/rm -f "$arg" ;; esac
done
exec /usr/bin/cut "$@"
EOF
chmod +x "$work/cutbin/cut"
PATH="$work/cutbin:$PATH" td list > "$work/list.out" 2> "$work/list.err"
check "an owner file gone before list's report reads it: reported in use, no error" \
    "$(grep -c 'live.generate.AbC123.*in use by fetch' "$work/list.out" | tr -d ' ') $(grep -c 'No such file' "$work/list.err" | tr -d ' ')" \
    "1 0"
rm -rf "$data/.live.generate.AbC123"

# Six fetches at once sweeping one orphaned old copy (its set's place missing, or an empty directory), four rounds: every
# fetch exits 0 without an error, exactly one says it removed the orphan, and nothing is left.
for round in 1 2 3 4; do
    rm -rf "$data/plain"
    mkdir -p "$data/.plain.old.Orphn$round/plain"
    echo "plain file" > "$data/.plain.old.Orphn$round/plain/plain.txt"
    echo "99998 Mon Jan  1 00:00:00 2024" > "$data/.plain.old.Orphn$round.owner"
    (( round % 2 == 0 )) && mkdir "$data/plain"
    pids=()
    for n in 1 2 3 4 5 6; do
        background_fetch "$work/concurrent.$n" plain
        pids+=("$PID")
    done
    statuses=""
    for pid in "${pids[@]}"; do
        reap "$pid"
        statuses="$statuses $?"
    done
    check "concurrent sweeps, round $round: every fetch exits 0" "$statuses" " 0 0 0 0 0 0"
    check "  no errors, one 'removed'" \
        "$(cat "$work"/concurrent.* | grep -c -i 'error\|refusing\|No such file' | tr -d ' ') $(cat "$work"/concurrent.* | grep -c "removed .plain.old.Orphn$round" | tr -d ' ')" \
        "0 1"
    check "  plain whole, nothing left" "$(cat "$data/plain/plain.txt") $(staging_left)" "plain file 0"
done

# Interrupted (TERM) mid-download: the partial file goes with its staging. Killed: the next fetch reclaims it.
check "fetch plain" "$(fetch plain)" 0
rm "$data/plain/plain.txt"
PATH="$work/bin:$PATH" background_fetch "$work/background.log" plain
until_there "$data" '*/.plain.download.??????/plain.txt'
kill -TERM -- "-$PID"
reap "$PID"
check "TERM mid-download: nothing partial left" "$(staging_left) $(find "$data/plain" ! -path "$data/plain" | wc -l | tr -d ' ')" "0 0"
PATH="$work/bin:$PATH" background_fetch "$work/background.log" plain
until_there "$data" '*/.plain.download.??????/plain.txt'
kill -KILL -- "-$PID"
reap "$PID"
check "KILL mid-download leaves staging" "$(staging_left)" 2
check "  the next fetch" "$(fetch plain)" 0
check "  reclaimed it and downloaded" "$(said 'removed .plain.download') $(cat "$data/plain/plain.txt")" "1 plain file"
check "  no staging left" "$(staging_left)" 0
