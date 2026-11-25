#!/bin/bash
# Builds the archive-coverage set into OUTPUT_DIR (default: the repository's TestData/archive-coverage, where
# `Tools/test-data fetch archive-coverage` puts it): archives Apple's tools make of one deterministic source tree
# (make-tree.py: many small files, large ones, a deep tree, long and Unicode names, every kind of link, extended
# attributes and resource forks, ACLs, modes and flags, APFS-compressed files), and a manifest of what Apple's own
# extractor makes of each, so NativeAEA's and NativeZip's tests compare their extractions without running Apple's tools.
#
#   tree-raw.aar, tree-CODEC-BLOCK.aar      `aa archive`, plain and with each codec at several block sizes
#   tree-pN-CODEC-BLOCK.aea                 `aea encrypt` of tree-raw.aar, every profile (0–5)
#   signing.pub.pem, recipient.pem, symmetric.key, password.txt
#                                           the keys those need (made here, test keys only)
#   tree-ditto.zip                          `ditto -c -k --sequesterRsrc --keepParent` (AppleDouble under __MACOSX)
#   tree-zip-y.zip                          Info-ZIP `zip -r -y` (symbolic links as links, no metadata)
#   collisions.aar, collisions-ditto.zip, collisions-zip-y.zip
#                                           names that differ only by case (made on a case-sensitive disk image)
#   source.json, collisions-source.json     manifests of the source trees as made
#   aa.json, ditto.json, zip-y.json, collisions-*.json
#                                           manifests of `aa extract`'s and `ditto -x -k`'s extractions on this
#                                           (case-insensitive) volume: the expected output
#   archives.tsv                            each archive: format, its expected manifest, profile, key, and the
#                                           reference extractor's exit status
#
# The manifests' format is manifest.py's (DiskTestSupport's `TreeManifest` reads it). Every `aa` archive and every
# `aea` payload is checked to extract to the same manifest (aa.json). The archived files and manifests are the same
# every run; the keys, and so the `aea` archives' bytes, differ.
#
# It writes and deletes only inside the repository's TestData/: OUTPUT_DIR must be there, and the work directory is
# OUTPUT_DIR/.work (removed on exit, the disk image detached first). Needs python3, and macOS's aa, aea, ditto, zip,
# openssl, and hdiutil (no sudo).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$(git -C "$here" rev-parse --show-toplevel)/Tools/lib/testdata.sh"
out="${1:-$TESTDATA_ROOT/archive-coverage}"
in_testdata "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
work="$out/.work"
in_testdata "$work"
rm -rf "$work"
mkdir "$work"
image="$work/case-sensitive.sparseimage"
mountpoint="$work/case-sensitive"

# Read-only directories stop removal of what's in them: make them writable first (`chmod -R` follows no links).
remove_tree() {
    in_testdata "$1"
    [[ -e "$1" ]] || return 0
    chmod -R u+w "$1"
    rm -rf "$1"
}

cleanup() {
    if mount | grep -qF " on $mountpoint "; then
        hdiutil detach -quiet "$mountpoint" || hdiutil detach -quiet -force "$mountpoint" || true
    fi
    remove_tree "$work"
}
trap cleanup EXIT

started=$(date +%s)
manifest() { python3 -I "$here/manifest.py" "$1" "$2" --now-after "$started"; }

# The trees.
python3 -I "$here/make-tree.py" main "$work/tree" "$work/stage"
manifest "$work/tree" "$out/source.json"
hdiutil create -quiet -size 16m -fs "Case-sensitive APFS" -volname archive-coverage -type SPARSE "$image"
mkdir "$mountpoint"
hdiutil attach -quiet -nobrowse -noverify -noautoopen -mountpoint "$mountpoint" "$image"
python3 -I "$here/make-tree.py" collisions "$mountpoint/collisions"
manifest "$mountpoint/collisions" "$out/collisions-source.json"

index="$out/archives.tsv"
in_testdata "$index"
printf 'archive\tformat\tmanifest\tprofile\tkey\treference status\n' > "$index"

# Extracts ARCHIVE with the reference tool into a directory of its own, writes the manifest, removes the extraction.
# Sets `status` to the tool's exit status (archives of colliding names make the tools report errors; their output still
# counts). Called directly, not in `$(…)`, so `set -e` covers the manifest.
reference() {
    local format="$1" archive="$2" manifest_file="$3" directory="$work/reference" rc=0
    remove_tree "$directory"
    mkdir "$directory"
    case "$format" in
        # One thread and one writer: with several, which of two colliding names wins varies run to run.
        aar) aa extract -t 1 -wt 1 -i "$archive" -d "$directory" 2> "$work/reference.log" || rc=$? ;;
        zip) ditto -x -k "$archive" "$directory" 2> "$work/reference.log" || rc=$? ;;
    esac
    in_testdata "$manifest_file"
    manifest "$directory" "$manifest_file"
    remove_tree "$directory"
    status="$rc"
}

# Apple Archives: plain, then each codec, extracted by `aa` to the same tree.
in_testdata "$out/tree-raw.aar"
aa archive -a raw -d "$work/tree" -o "$out/tree-raw.aar"
reference aar "$out/tree-raw.aar" "$out/aa.json"
printf 'tree-raw.aar\taar\taa.json\t\t\t%s\n' "$status" >> "$index"
for spec in lzfse:1m lzma:256k lz4:64k zlib:4m lzbitmap:16k lzraven:1m; do
    codec=${spec%%:*} block=${spec#*:}
    name="tree-$codec-$block.aar"
    in_testdata "$out/$name"
    aa archive -a "$codec" -b "$block" -d "$work/tree" -o "$out/$name"
    reference aar "$out/$name" "$work/check.json"
    cmp -s "$work/check.json" "$out/aa.json" || { echo "error: $name extracts differently from tree-raw.aar" >&2; exit 1; }
    printf '%s\taar\taa.json\t\t\t%s\n' "$name" "$status" >> "$index"
done

# Keys. `aea` rejects private keys whose scalar DER shortens (a leading zero byte): make another until it's 32 bytes.
p256_key() {
    while :; do
        openssl ecparam -name prime256v1 -genkey -noout -out "$1"
        openssl ec -in "$1" -outform DER -out "$work/key.der" 2>/dev/null
        [[ "$(xxd -s 5 -l 2 -p "$work/key.der")" == "0420" ]] && break
    done
}
p256_key "$work/signing.pem"
in_testdata "$out/signing.pub.pem"
openssl ec -in "$work/signing.pem" -pubout -out "$out/signing.pub.pem" 2>/dev/null
in_testdata "$out/recipient.pem"
p256_key "$out/recipient.pem"
openssl ec -in "$out/recipient.pem" -pubout -out "$work/recipient.pub.pem" 2>/dev/null
in_testdata "$out/symmetric.key"
symmetric=$(openssl rand -hex 32)
echo "hex:$symmetric" > "$out/symmetric.key"
in_testdata "$out/password.txt"
password="archive-coverage test password, not a secret"
printf '%s' "$password" > "$out/password.txt"

# Apple Encrypted Archives: every profile, each with another codec and segment size. Each payload decrypts back to
# tree-raw.aar exactly, so aa.json is its expected tree.
for spec in 0:lzma:1m 1:lzfse:64k 2:lz4:1m 3:zlib:256k 4:lzbitmap:1m 5:none:4m; do
    IFS=: read -r profile codec block <<< "$spec"
    name="tree-p$profile-$codec-$block.aea"
    encrypt=() decrypt=() key=""
    case "$profile" in
        0) encrypt=(-sign-priv "$work/signing.pem"); decrypt=(-sign-pub "$out/signing.pub.pem"); key=signing.pub.pem ;;
        1) encrypt=(-key-value "hex:$symmetric"); decrypt=("${encrypt[@]}"); key=symmetric.key ;;
        2) encrypt=(-key-value "hex:$symmetric" -sign-priv "$work/signing.pem")
           decrypt=(-key-value "hex:$symmetric" -sign-pub "$out/signing.pub.pem"); key=symmetric.key ;;
        3) encrypt=(-recipient-pub "$work/recipient.pub.pem"); decrypt=(-recipient-priv "$out/recipient.pem"); key=recipient.pem ;;
        4) encrypt=(-recipient-pub "$work/recipient.pub.pem" -sign-priv "$work/signing.pem")
           decrypt=(-recipient-priv "$out/recipient.pem" -sign-pub "$out/signing.pub.pem"); key=recipient.pem ;;
        5) encrypt=(-password-value "$password"); decrypt=("${encrypt[@]}"); key=password.txt ;;
    esac
    in_testdata "$out/$name"
    rm -f "$out/$name"
    aea encrypt -profile "$profile" -i "$out/tree-raw.aar" -o "$out/$name" -a "$codec" -b "$block" -checksum sha256 "${encrypt[@]}"
    rm -f "$work/payload.aar"
    aea decrypt -i "$out/$name" -o "$work/payload.aar" "${decrypt[@]}"
    cmp -s "$work/payload.aar" "$out/tree-raw.aar" || { echo "error: $name doesn't decrypt to tree-raw.aar" >&2; exit 1; }
    printf '%s\taea\taa.json\t%s\t%s\t0\n' "$name" "$profile" "$key" >> "$index"
done

# ZIP: `ditto` (AppleDouble for attributes, forks, and ACLs, under __MACOSX) and Info-ZIP (links as links, nothing
# else), both extracted by `ditto -x -k` (which merges AppleDouble, as Archive Utility does).
in_testdata "$out/tree-ditto.zip"
rm -f "$out/tree-ditto.zip"
(cd "$work" && ditto -c -k --sequesterRsrc --keepParent tree "$out/tree-ditto.zip")
reference zip "$out/tree-ditto.zip" "$out/ditto.json"
printf 'tree-ditto.zip\tzip\tditto.json\t\t\t%s\n' "$status" >> "$index"
in_testdata "$out/tree-zip-y.zip"
rm -f "$out/tree-zip-y.zip"
(cd "$work" && zip -q -r -y "$out/tree-zip-y.zip" tree)
reference zip "$out/tree-zip-y.zip" "$out/zip-y.json"
printf 'tree-zip-y.zip\tzip\tzip-y.json\t\t\t%s\n' "$status" >> "$index"

# Names that collide on a case-insensitive volume.
in_testdata "$out/collisions.aar"
aa archive -a raw -d "$mountpoint/collisions" -o "$out/collisions.aar"
reference aar "$out/collisions.aar" "$out/collisions-aa.json"
printf 'collisions.aar\taar\tcollisions-aa.json\t\t\t%s\n' "$status" >> "$index"
in_testdata "$out/collisions-ditto.zip"
rm -f "$out/collisions-ditto.zip"
(cd "$mountpoint" && ditto -c -k --sequesterRsrc --keepParent collisions "$out/collisions-ditto.zip")
reference zip "$out/collisions-ditto.zip" "$out/collisions-ditto.json"
printf 'collisions-ditto.zip\tzip\tcollisions-ditto.json\t\t\t%s\n' "$status" >> "$index"
in_testdata "$out/collisions-zip-y.zip"
rm -f "$out/collisions-zip-y.zip"
(cd "$mountpoint" && zip -q -r -y "$out/collisions-zip-y.zip" collisions)
reference zip "$out/collisions-zip-y.zip" "$out/collisions-zip-y.json"
printf 'collisions-zip-y.zip\tzip\tcollisions-zip-y.json\t\t\t%s\n' "$status" >> "$index"
