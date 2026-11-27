# Plan: error vocabulary, `Compressor`'s gaps, format detection and gzip headers, `decompressAll`'s reservation (2026-11-25)

Open items 27, 25, 24, and 15 of `Open-Items-2026-11-25.md`, in that order (27 first: 24 and 25 add API that throws,
so they're written against the final errors). Constraint from the user: Bytes' zstd stays at or ahead of libzstd 1.6.0
(`BytesCompression/Benchmarks/RESULTS-zstd-encoder.md`); nothing here may slow a codec's loop.

Baselines: `api-before` (every BytesCompression benchmark) before any change; `api-after` at the end, compared by
instructions (every row) and mallocs. HTTPBytes' content-coding rows and SocketStream's transfer driver before and after
their changes. The zstd harness (`~/Scratch/zstd-1.6.noindex/harness`) re-run on its encode and decode rows at the end.

## 27. Error vocabulary (Bytes' `BytesError`, BytesCompression's throws)

`BytesError` stays a payload-free enum: it's every codec's typed-throws error, one byte in a register, and a payload
(the surveys suggested `unsupported(feature)` and `LocatedBytesError` offsets) would make it a multi-word,
possibly-retaining value in every hot loop's error path. Two cases are added:

- **`unsupported`**: valid data using a feature this implementation doesn't have, or an operation the chosen format
  doesn't do. Replaces `invalidValue` at: zstd frames with a dictionary ID (`ZstdDecoder.swift:159,347`); zlib's preset
  dictionary (FDICT, `DeflateDecoder.swift:655`, split from the method/window/check test, which stays `invalidValue`);
  xz filter chains other than one LZMA2 filter (BCJ, delta, several filters: `XZFormat.swift:109` and `XZDecoder`'s
  copy) and the reserved check types (`XZFormat.swift:46`: the spec defines their sizes, so they're valid streams we
  can't verify); `Compressor.compress` and `Decompressor.decompress`/`transform` for a format that works on whole
  buffers only, and `Decompressor.decompress(_:into:historyCount:)` for one without history (`invalidValue` stays for
  calls before the first `reset(for:)`). Every decoder's sites are found by reading each `throw .invalidValue`, not by
  this list alone; anything that's corrupt under the format's specification stays `invalidValue`.
- **`checksumMismatch`**: a check value stored with the data doesn't match it. Replaces `mismatch` (and bzip2's
  `invalidValue`) at: gzip's CRC-32 and ISIZE trailer and header CRC-16, zlib's Adler-32 (`DeflateDecoder.swift:712,750`,
  `ParallelInflate.swift:339`), zstd's content checksum (`ZstdDecoder.swift:227,232,331`), xz's block checks
  (CRC-32, CRC-64, SHA-256) and its header, index, and footer CRCs (`XZFormat.swift`, `XZDecoder.swift`), bzip2's block
  and stream CRCs (`BZip2Decoder.swift:164,192`, `BZip2Streaming.swift:175,216`).

`mismatch` keeps: an `expect` that read another value (the readers, the macros' records), and a size or count that
disagrees with one stated by the caller or the container (`decodedSize`, zstd's frame content size, xz's index against
its blocks and its block sizes, a pledged size in `ZstdEncoder`). Not changed: BytesCrypto's AEAD tag failures stay
`mismatch` (an authentication tag isn't a checksum; out of these items' scope).

**Not added, and why:**
- `truncated`: `insufficientData` is already what every codec throws when input ends inside a stream (at `.finish`, or
  a whole buffer that stops short); a second name for the same condition would make callers match both. Its doc
  comment says so instead.
- `corrupt`: `invalidValue` is that; renaming it breaks every client for no new information.
- `LocatedBytesError` in the codecs: the offset would change every codec's throw type (`BytesError` → a two-word
  struct) on every hot path. Left as the readers' opt-in (`located(_:)`); the item is closed as "not for codecs".

Clients: NativeZip's exhaustive `BytesError.zipError(_:)` (the directory parser's errors) gains the two cases in its
`invalidRecord` arm: the parser never throws them. NativeZip's
and NativeAEA's error docs that name `mismatch` for CRCs are updated; HTTPBytes' content decoding maps both to
`malformed` (its `default:`), and `unsupported` at `reset(for:)` is already `unsupportedCoding`. Nunarchiver shows the
error's description: checked by building it.

Tests: each new throw site gets a test that makes it throw (a flipped checksum byte per format; a zstd frame with a
dictionary ID; a zlib header with FDICT; an xz block with a BCJ filter and one with a reserved check type; whole-buffer
formats through `compress`/`decompress`), and existing tests that expected `mismatch`/`invalidValue` there are updated —
each found by running the suites, not assumed. Break one site back to the old case to see its test fail.

## 25. `Compressor`'s gaps

- `Compressor.init(for:)` public.
- **One rule for parameters.** Today `Compressor` throws `invalidValue` for a negative level while `DeflateEncoder`,
  `BrotliEncoder`, and `ZstdEncoder.Parameters(level:)` clamp it silently (and `BrotliEncoder` clamps its window where
  `ZstdEncoder` traps). The rule becomes: levels above an encoder's highest run as its highest (documented per format,
  unchanged); a negative level or an out-of-range window is invalid everywhere: the encoders' initializers trap
  (`precondition`, as `ZstdEncoder`'s window already does: they can't throw), and `Compressor.reset(for:)` throws
  `invalidValue` (as now). Not clamping negatives: zlib's `-1` means "default", so a silent clamp to 0 (stored) or 1
  surprises. Every caller passing a level is checked (HTTPBytes passes the client's through `Compressor`: it throws,
  mapped to `unsupportedCoding` as now).
- `CompressionFormat.maximumCompressedSize(forByteCount:)`: each encoder's bound; DEFLATE's adds its container's header
  and trailer (`DeflateEncoder.maximumCompressedSize(forByteCount:format:)` ignores `format` today: fixed). Apple's
  encoders' bounds stay `package` on the encoders and are reached through the format.
- `Compressor.compressAll(_:) -> [UInt8]`: reserves the format's bound, encodes into it in place (as
  `Decompressor.decompressAll(_:maximumSize:)` does: `append(addingCapacity:)`, nothing zeroed or copied).
- `CompressionFormat.zstdForHTTP(level:)` and `DecompressionFormat.zstdForHTTP` (static members): RFC 9659's 8 MiB
  window limit on both sides (`windowLog: ZstdEncoder.Parameters.httpWindowLog`; `maximumWindowSize: 8 << 20`).
  HTTPBytes uses them in place of its own constant and `ZstdEncoder`'s.
- `Compressor.releaseMemory()`: mirrors `Decompressor.releaseMemory()` (drops every encoder, keeps `format`; the next
  `reset(for:)`/`reset()` makes it again).
- **SocketStream onto `Compressor`/`Decompressor`**, and zstd added to its algorithms (`--compression zstd`): its
  sequential sender and receiver pipelines take `Compressor`/`Decompressor` as their stages (both are
  `ResettableByteTransform`); `ParallelDeflateEncoder` stays for `--lanes` above 1. Measured with its driver before and
  after (the survey measured the swap equal: 173.28 M against 173.30 M instructions for 4 MiB) under its PR toolchain.

Tests: `init(for:)`, the bound against each encoder's worst inputs (random, every level, sizes 0–300 and around block
sizes: `compressAll` into exactly the bound must succeed), `compressAll` to an array equals the buffer form, negative
levels throw at `reset(for:)` (and the encoders' preconditions, by inspection: traps aren't testable in-process),
`releaseMemory` then `reset()` then a stream equal to a fresh encoder's, `zstdForHTTP` frames decode under the 8 MiB
limit and state no larger window.

## 24. Format detection and gzip headers

- `DecompressionFormat(detecting: RawSpan)` (in `ContainerFormats.swift`, beside `init(zlibOrRaw:)`): `nil` for bytes
  that don't start a stream it can recognize, or too few bytes to tell. Recognized: gzip (`1F 8B 08`), zstd (frame
  magic `28 B5 2F FD`, and skippable frames' `5x 2A 4D 18`), xz (`FD 37 7A 58 5A 00`), bzip2 (`BZh` and a block size
  digit 1–9), zlib (the RFC 1950 header test `ZlibHeader.isDeflate`, with FDICT clear), LZFSE (`bvx2`, `bvx1`, `bvx-`,
  `bvxn`, and `bvx$` an empty stream), Compression's framed LZ4 (`bv41`, `bv4-`, `bv4$`), LZBITMAP (`ZBM` + its
  variant byte), LZRAVEN (its magic). Not detectable (no magic): raw DEFLATE, Deflate64, Brotli, raw LZMA, raw LZ4,
  LZVN: `nil`. zlib's test is checked last (two bytes, a 1-in-31-ish chance on random data; documented). Formats with
  limits get their defaults (`.zstd()`, `.xz()`): the caller sets limits from context.
- **gzip headers public.** `GzipHeader` becomes public, gains `name`, `comment`, and `extraField` (`[UInt8]?`: RFC 1952
  says Latin-1 for the name, and tools write UTF-8 or raw file-system bytes, so bytes are given as they are), and:
  - `GzipHeader.init(parsing: RawSpan) throws(BytesError)` with the header's byte count: the whole header from a
    buffer's start (a single `.gz` file's first bytes), the optional fields kept, its CRC-16 checked.
  - The streaming decoder (`DeflateDecoder`, and `Decompressor` through a new `gzipHeader` property) keeps reporting
    the fixed fields and flags without the optional fields' contents (they arrive in pieces; keeping them would mean
    storage of no fixed size in the decode path). Documented: parse the start with `init(parsing:)` for them.
  - Writing: `DeflateEncoder(format: .gzip, level:, gzipHeader:)` and `ParallelDeflateEncoder`'s counterpart write the
    given header (name, comment, extra field, time, OS, text flag, optional header CRC); the default is today's 10
    bytes, byte for byte. XFL stays the level's. The bytes are built once at `init` (and XFL patched on
    `reset(level:)`), so encoding a stream allocates nothing new.
- `CompressionFormat` keeps `.deflate(.gzip, level:)` without a header (a client that names its member uses the
  encoder): noted as a departure.

Tests: detection of every recognized format from our encoders' and the reference tools' output (`TestData`), prefixes
cut at every length (`nil` until decidable, never a wrong format), random bytes and every undetectable format's
streams (which may read as zlib only when their first two bytes pass its test: counted on random input), the header
round trip (every field, with and without FHCRC, written by our encoder and parsed back, and `gzip -N` files from the
system tool parsed: name and time), the streaming decoder decoding members with every optional field split at every
byte, default headers unchanged (frames byte-identical to before).

## 15. `decompressAll(_:maximumSize:decodedSize:)` reserves the maximum when the size is unknown

Today it reserves `maximumSize` (64 MiB in NativeAEA's TOC call) whatever the stream decodes to. New:

1. Capacity: `decodedSize` if given; else a size the input states — zstd's first frame's content size, gzip's ISIZE
   (the last member's; exact for one member), xz's index (the last stream's uncompressed total), Compression's `bv41`
   block sizes summed — clamped to `maximumSize`; else an estimate, `max(64 KiB, 4 × input)`, clamped. A stated size is
   only a starting capacity, never trusted (input can lie: the decode's own checks still decide).
2. Decode with the one-shot decoder into that capacity (unchanged: the fastest path).
3. On `insufficientCapacity` below `maximumSize`: grow to `min(maximumSize, 4 × capacity)` and decode again from the
   start (every one-shot decoder stops at the first byte that doesn't fit, so a failed attempt costs at most its
   capacity's worth of decoding: at most a third more work in all). At `maximumSize`, `limitExceeded` as now.

Checked first, by a probe: that every whole-buffer decoder stops at the overflow (bounded work), not at its end.
Measured: new benchmark rows decoding to an array without `decodedSize` (DEFLATE, zstd with and without a content size,
bzip2, xz; 64 KiB and 8 MiB), mallocs and peak resident size against the old reservation, and the time against
decoding into a buffer of the right size.

Tests: every format at sizes around the estimate and its growth steps (exact fits, one byte over), a stated size that
lies low and one that lies high, `maximumSize` exactly the decoded size and one less, empty streams.

## Order and checks

27 → 25 (with HTTPBytes and SocketStream) → 24 → 15, each: build every package with tests (no warnings), the touched
suites, the clients' suites (NativeZip, NativeAEA, Disk, HTTPBytes, Nunarchiver's `build.sh`). At the end: the bulk
sets of BytesCompression, `api-after` against `api-before`, the zstd harness, SwiftFormat, records (RESULTS.md, LESSONS,
open items).

## Review (2026-11-25) and what changed

An adversarial review (read-only agent, the plan and the code) found 18 issues; all accepted unless noted. They
override the sections above where they differ.

1. **Item 15 could retry forever** on a stated size of 0 (BGZF's empty last member, a zstd frame stating 0 before
   another): every capacity is floored at `min(maximumSize, 64 KiB)` and grows by `max(4 × capacity, capacity + 1)`.
   Tests for both inputs.
2. **`Compressor.releaseMemory()` would trap** (`Compressor` force-unwraps encoders by `format`; `reset()` reuses an
   encoder when its `*Format` matches): it clears the encoders and their `*Format`s, and a `ready` flag (set by
   `reset(for:)`) makes coding calls throw `invalidValue` until the next reset, as `Decompressor`'s `codec` does.
3. `ZstdDecoder.swift:227` is the content-size check: it stays `mismatch`. The checksum sites are `:232` and `:331`.
4. xz's SHA-256 check is skipped, not verified (`XZFormat.swift:335`, `XZDecoder.swift:314`): it stays so, documented.
   The filter test is `XZ.blockHeader`'s alone.
5. `XZFormat.swift:109` splits: several filters or a filter ID other than LZMA2 → `unsupported`; LZMA2 with a
   properties size other than 1 → `invalidValue`.
6. **One rule:** a field, bit, or value the format's specification *reserves for future use* is `unsupported` (a newer
   writer may set it; RFC 1952 says a reserved FLG bit could mean a new field; liblzma calls reserved xz flags "options"
   errors); a value the specification rules out, or calls corrupt, is `invalidValue` (zstd's reserved block type 3: its
   spec says "corrupted"). Under it, `unsupported` also covers: gzip's reserved FLG bits, xz's reserved stream and block
   flags, reserved check types, unknown filter IDs, Brotli's large-window escape (`BrotliStream.swift:561`), LZBITMAP's
   `0x0C`/`0x0D` variants' compressed chunks, `DeflateDecoder.reset(format:)` refusing zlib/gzip for Deflate64, and
   zstd's frame header reserved bit. Each site is decided by reading the specification's words there.
7. The gzip trailer is split: CRC-32 → `checksumMismatch`, ISIZE → `mismatch` (a size), header CRC-16 →
   `checksumMismatch`.
8. **Clients name it:** NativeZip's `ZipError(decoding:)` maps `unsupported` to a new `ZipError.unsupportedData(String)`
   (nunzip's exit code 81, Info-ZIP's for unsupported), and `checksumMismatch` to its existing CRC error if it has one,
   else `decoding`; NativeAEA's `decompressionFailed` description says "unsupported" for it; HTTPBytes maps
   `unsupported` from decoding to `unsupportedCoding`, `checksumMismatch` to `malformed`.
9. **Item 15's premise, corrected:** no client reaches the unknown-size path today (NativeAEA passes `decodedSize`), and
   an untouched reservation is virtual memory, not resident. The defect that remains is that a *limit* is used as an
   *allocation size*: a generous `maximumSize` (or one past what the process can map) reserves that much or traps.
   The fix stands with that framing. Its cost, stated correctly: failed attempts decode at most about 4/3 of the decoded
   size more (a third of the final capacity), and a block-granular decoder (bzip2) fails a block late; bzip2's floor is
   its header's block size (level × 100,000 bytes). Success: same instructions where a size is known or stated; mallocs
   and peak footprint no larger than the decoded size × 4 (+ 64 KiB) otherwise.
10. Stated sizes are capped by the format's largest expansion of the input (believe a header only as far as the input
    can expand: DEFLATE 1032:1, the others' bounds in the code), and include the format's own (`.lzma`'s
    `uncompressedSize`, zstd's and xz's `sizeHint`) and LZFSE's block sizes (checked before decoding today, so summed as
    cheaply as `bv41`'s).
11. **gzip header types:** public `GzipHeader` is the full header (text flag, time, OS, name, comment, extra field,
    whether it has a header CRC; the presence flags derived from the optionals), made by
    `GzipHeader.parse(_:) -> (header, byteCount)` and taken by the encoder. The streaming decoder keeps an internal,
    trivially copyable fixed-field value (`InflateStream` stays trivial); nothing new is reported while streaming.
    `extraFlags` isn't public: the encoder writes the level's.
12. **Writing:** a gzip-only initializer, `DeflateEncoder(gzipHeader:level:)` (and `ParallelDeflateEncoder`'s). The
    header bytes are built at the start of each stream into a buffer made once (so XFL and the FHCRC follow
    `reset(level:)`), and delivered in pieces like other pending output, not through the fixed staging buffer or the
    16-byte `small`. `maximumCompressedSize` gets an instance form that counts the header.
13. The parameter rule covers `ParallelDeflateEncoder` and `ParallelBrotliEncoder` too. Negative zstd levels are libzstd's
    fast levels: `Compressor` throws `unsupported` for them (`invalidValue` for DEFLATE's and Brotli's); the encoders'
    preconditions say so in their docs.
14. Departures, stated: `ZstdEncoder` stays public (the user's instruction for this round: no access narrowing yet);
    Bytes-Survey's `ArchiveKind.compressedFile(format)` (single-file archives in NativeAEA/Nunarchiver) is not part of
    item 24 and stays open; new API without an outside caller yet is public for the same reason.
15. **Detection's `nil`:** `DecompressionFormat.detectionByteCount` (6) is published: with that many bytes, `nil` means
    unrecognized; with fewer, it may mean "wait".
16. zlib with FDICT is detected as zlib (its decoder then says `unsupported`). Skippable frames (shared with the LZ4
    frame format's) detect as zstd, documented. The standard LZ4 frame, legacy zstd, and `.lzma` files are `nil`,
    documented.
17. zlib's false-positive rate on random bytes: about 1 in 2,000 with FDICT clear, but FDICT headers are detected too
    (16), so about 1 in 1,000 (measured: 200 in 200,000): the doc says so.
18. bzip2's streaming decoder keeps the failure it first threw (today a later call rethrows `invalidValue`), as LZMA's
    does; the bounds and estimates saturate before reserving.

## Second review (the implementation), and what changed

A second read-only agent reviewed the code (probes in a copy: malloc counts, overflow at every capacity, every
format's retry). No defects; fixed:

- `GzipHeader`'s fields are `var`s, so a name with a zero byte or an extra field over 65,535 bytes set after its
  initializer wrote a corrupt stream: the encoders check the fields again at each stream's start (a precondition).
- A custom header allocated per stream (`name + [0]`, 10–20 mallocs per 10 streams): appended in pieces now.
- Stale docs saying `mismatch` for a checksum (`ParallelInflate.swift`).
- Rule 6, applied further: LZMA2's properties byte with its reserved bits 6–7 set is `unsupported` (a size code past
  40 stays `invalidValue`); a zstd window past 2^31 is `limitExceeded` (a resource limit, as a window past
  `maximumWindowSize` is; HTTP maps both to `tooLarge`), not `unsupported`.
- Tests: the stored block's NLEN error (now `invalidValue`) is pinned; the retry is exercised for every whole-buffer
  format (5 MiB of zeros), not only five.

Not taken, and why:

- **LZFSE's block sizes** (first review, 10): reading a v1 or v2 block's size means decoding its frequency tables,
  which is part of decoding, not a header read. LZFSE's clients pass `decodedSize` (AEA, `decmpfs`); without it, LZFSE
  grows as the formats that state nothing do.
- **Brotli's large-window escape stays `unsupported`**, the rule's one exception: RFC 7932 calls the pattern invalid,
  but Google's large-window extension defines it, so the data may well be valid.
