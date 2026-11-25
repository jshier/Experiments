#!/bin/bash
# Tools/disk-space: one line of figures, for the Data volume by default (and for `/`, the read-only system volume, with
# a note); --check exits 1 when "available" is short or the volume is read-only; on a non-APFS volume (an exFAT disk
# image, attached here and detached after) "available" is the free space, not 0; the same image attached read-only is
# reported so and fails --check; bad values, a missing value, and a second PATH exit 2.
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/disk-space"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-disk-space.XXXXXX")"
attached=
cleanup() {
    if [[ -n "$attached" ]]; then
        hdiutil detach -quiet "$work/mnt" || hdiutil detach -force -quiet "$work/mnt"
    fi
    rm -rf "$work"
}
trap cleanup EXIT
export EXPERIMENTS_TOOLS_CACHE="$work/cache"
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }
figures='\ttotal [\d.]+ GB\tfree now [\d.]+ GB\tavailable [\d.]+ GB\topportunistic [\d.]+ GB\tread-only (yes|no)'

out="$("$tool")"
check "exit status" "$?" 0
check "the Data volume by default, writable, six fields" "$(echo "$out" | FIGURES="$figures" perl -ne 'print "ok" if /^\/System\/Volumes\/Data$ENV{FIGURES}$/ && $1 eq "no"')" ok
system_paths=(/ /. // /System/..)
[[ -d "/Volumes/Macintosh HD" ]] && system_paths+=("/Volumes/Macintosh HD")
for p in "${system_paths[@]}"; do
    out="$("$tool" "$p" 2> "$work/err")"
    check "'$p' (the system volume) is measured as the Data volume" "$(echo "$out" | cut -f1)" /System/Volumes/Data
    check "and says so" "$(grep -c 'read-only system volume' "$work/err")" 1
done
# Paths nothing can be written to: --check must say no. Another path on the sealed system volume is read-only; a path
# on a volume that isn't mounted, directly or through a dangling link into /Volumes, is refused.
"$tool" --check 0.001 /usr/bin/check-disk-space-new > /dev/null 2>&1
check "a path on the system volume: --check fails" "$?" 1
check "a path on the system volume: read-only" "$("$tool" /usr/bin/check-disk-space-new 2> /dev/null | cut -f6)" "read-only yes"
"$tool" --check 0.001 /Volumes/CheckDiskSpaceNoSuchDisk/TestData > /dev/null 2> "$work/err"
check "a path under an unmounted volume: refused" "$?/$(grep -c "isn't mounted" "$work/err")" "2/1"
ln -s /Volumes/CheckDiskSpaceNoSuchDisk/TestData "$work/dangling"
"$tool" --check 0.001 "$work/dangling/sub" > /dev/null 2> "$work/err"
check "a dangling link into an unmounted volume: refused" "$?/$(grep -c "isn't mounted" "$work/err")" "2/1"
"$tool" --check 0.001 /System/Volumes/Data/Volumes/CheckDiskSpaceNoSuchDisk > /dev/null 2> "$work/err"
check "an unmounted volume spelled through /System/Volumes/Data/Volumes: refused" "$?/$(grep -c "isn't mounted" "$work/err")" "2/1"
ln -s /System/Volumes/Data/Volumes/CheckDiskSpaceNoSuchDisk "$work/dangling-data"
"$tool" --check 0.001 "$work/dangling-data" > /dev/null 2> "$work/err"
check "a dangling link to that spelling: refused" "$?/$(grep -c "isn't mounted" "$work/err")" "2/1"
"$tool" /Volumes > /dev/null 2> "$work/err"
check "/Volumes itself is measured, not refused" "$?/$(grep -c "isn't mounted" "$work/err")" "0/0"
# A new path at the top of the sealed system volume (a typo for ~/Scratch): not the Data volume, read-only, --check fails.
out="$("$tool" /check-disk-space-no-such-top/x 2> /dev/null)"
check "a new top-level path: on the system volume, read-only" "$(echo "$out" | cut -f6)" "read-only yes"
"$tool" --check 0.001 /check-disk-space-no-such-top/x > /dev/null 2>&1
check "a new top-level path: --check fails" "$?" 1
out="$("$tool" "$work/not/yet/made" 2> "$work/err")"
check "a path that doesn't exist yet: its nearest existing ancestor" "$(echo "$out" | cut -f1)" "$work"
check "and says so" "$(grep -c 'nearest existing ancestor' "$work/err")" 1
"$tool" --check 0.5 > /dev/null
check "--check 0.5" "$?" 0
"$tool" --check 999999999 > /dev/null 2>&1
check "--check beyond the disk" "$?" 1

# (exFAT labels are at most 11 characters: a longer one fails as "Operation not permitted".)
# 300 MB, sparse (it takes only what's written), so the figures show at 0.1 GB resolution.
hdiutil create -quiet -size 300m -type SPARSE -fs ExFAT -volname CHECKDISK "$work/exfat" 2> /dev/null ||
    { echo "FAIL: hdiutil create"; exit 1; }
mkdir "$work/mnt"
hdiutil attach -quiet -nobrowse -mountpoint "$work/mnt" "$work/exfat.sparseimage" || { echo "FAIL: hdiutil attach"; exit 1; }
attached=1
out="$("$tool" "$work/mnt")"
check "exFAT: available is the free space" "$(echo "$out" | perl -ne 'print /free now ([\d.]+) GB\tavailable ([\d.]+) GB\topportunistic [\d.]+ GB\tread-only no$/ && $1 == $2 && $1 > 0 ? "yes" : "no: $_"')" yes
"$tool" --check 0.01 "$work/mnt" > /dev/null
check "exFAT: --check 0.01" "$?" 0
hdiutil detach -quiet "$work/mnt"
check "detached" "$?" 0
attached=

hdiutil attach -quiet -readonly -nobrowse -mountpoint "$work/mnt" "$work/exfat.sparseimage" ||
    { echo "FAIL: hdiutil attach -readonly"; exit 1; }
attached=1
out="$("$tool" "$work/mnt")"
check "read-only: reported" "$(echo "$out" | cut -f6)" "read-only yes"
"$tool" --check 0.01 "$work/mnt" > /dev/null 2> "$work/err"
check "read-only: --check fails" "$?" 1
check "read-only: and says why" "$(grep -c 'read-only volume' "$work/err")" 1
hdiutil detach -quiet "$work/mnt"
check "detached again" "$?" 0
attached=

for args in "--check" "--check abc /" "--check -1 /" "/ /tmp" "--frobnicate"; do
    # shellcheck disable=SC2086 # Split on purpose: each string is several arguments.
    "$tool" $args > /dev/null 2>&1
    check "$args exits 2" "$?" 2
done
