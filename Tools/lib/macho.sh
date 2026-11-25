# shellcheck shell=bash
# macho.sh — the input file as Tools/loops, calls, and bn read it, from its own header (lib/macho.pl): sourced after
# lib/common.sh, used after scratch_dir.
#
# macho_input: checks $file, and for a universal file replaces it with its arm64 slice (else arm64e, else any arm64e.* one, as arm64e.x1), thinned into
# $SCRATCH (copied out by the fat table's offset and size). Sets FILE_KIND (object or binary) and MACHO_TEXT (__TEXT,__text as FILEOFF:ADDRESS:SIZE, for lib/loops.pl),
# and writes $SCRATCH/starts (a linked binary's function starts) and $SCRATCH/code (the address ranges holding code).
# Refuses with exit 2: an archive (`ar`), a file that isn't Mach-O, and another architecture.
# shellcheck disable=SC2034 # MACHO_TEXT and FILE_KIND are read by the tools that source this.
macho_read() { # macho_read FILE: sets MACHO_KIND, MACHO_CPU, MACHO_ARCHS, MACHO_TEXT
    local key value
    MACHO_KIND='' MACHO_CPU='' MACHO_ARCHS='' MACHO_SLICES='' MACHO_TEXT=''
    while IFS='=' read -r key value; do
        case "$key" in
            kind) MACHO_KIND="$value" ;;
            cpu) MACHO_CPU="$value" ;;
            archs) MACHO_ARCHS="$value" ;;
            slices) MACHO_SLICES="$value" ;;
            text) MACHO_TEXT="$value" ;;
        esac
    done < <(perl "$TOOLS_DIR/lib/macho.pl" "$1" "$SCRATCH/starts" "$SCRATCH/code")
    [[ -n "$MACHO_KIND" ]] || die "can't read $1"
}
# shellcheck disable=SC2034 # FILE_KIND is read by the tools that source this.
macho_input() {
    local input="$file" slice place
    macho_read "$file"
    if [[ "$MACHO_KIND" == fat ]]; then
        case ",$MACHO_ARCHS," in
            *,arm64,*) slice=arm64 ;;
            *,arm64e,*) slice=arm64e ;;
            *,arm64e.*) slice="${MACHO_ARCHS#*arm64e.}"; slice="arm64e.${slice%%,*}" ;;
            *) die "$input is a universal file without an arm64 slice (it holds ${MACHO_ARCHS//,/, })" ;;
        esac
        # The slice copied out by its offset and size in the fat table (lipo can't name every subtype: an arm64 slice
        # whose subtype is 1, V8, can't be thinned by name).
        place="$(SLICE="$slice" perl -e 'for (split /,/, shift) { my ($name, $offset, $size) = split /\@/; if ($name eq $ENV{SLICE}) { print "$offset $size"; exit } }' "$MACHO_SLICES")"
        [[ -n "$place" ]] || die "$input's universal header doesn't place its $slice slice"
        perl -e 'my ($in, $offset, $size, $out) = @ARGV;
            open my $i, "<:raw", $in or exit 1; seek $i, $offset, 0 or exit 1; open my $o, ">:raw", $out or exit 1;
            while ($size > 0) { my $n = read $i, my $chunk, $size < (1 << 20) ? $size : 1 << 20; exit 1 unless $n; print $o $chunk; $size -= $n }
            close $o or exit 1' "$file" "${place% *}" "${place#* }" "$SCRATCH/arm64" &
        # In the background, waited for, so a signal stops a long copy at once (the tools' traps); bounded by the file's
        # end, where a read returns nothing.
        wait "$!" || die "can't read the $slice slice of $input (it ends past the end of the file)"
        file="$SCRATCH/arm64"
        macho_read "$file"
    fi
    case "$MACHO_KIND" in
        object|binary) ;;
        archive) die "$input is a static library (an ar archive): read one of its objects (ar -x), or merge them (ld -r)" ;;
        dsym) die "$input is a dSYM's debug information, not code: give the binary it describes" ;;
        truncated) die "$input is truncated: its Mach-O header or load commands end early" ;;
        *) die "$input isn't a Mach-O object or binary" ;;
    esac
    [[ "$MACHO_CPU" == arm64 || "$MACHO_CPU" == arm64e* ]] || die "$input isn't arm64 code ($MACHO_CPU)"
    FILE_KIND="$MACHO_KIND"
}
