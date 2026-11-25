# Bytes and its libraries: API, macros, and realistic scenarios (2026-11-24)

A survey after the codec unification and the completed fix plan (`BytesCompression-Fix-Plan-2026-11-23.md`). It builds
on `Library-Survey-2026-11-23.md` (whose items are given a status, not repeated) and covers four slices: Bytes' own API,
the libraries built on it, the macros, and how realistic the tests and benchmarks are.

**Method.** Four read-only agents, each with probe packages in the session scratchpad (`survey.noindex/`), built release
with Xcode 27.3 (Swift 6.4.4). Numbers are instruction counts (static from `objdump`/`Tools/loops`, or dynamic from
`proc_pid_rusage`), allocation counts, and footprints; no cycles and no benchmark baselines (four agents built in
parallel). Fewer instructions can be slower: every performance item below needs cycles measured before it lands.
**Verified by the lead** marks claims re-checked independently; the rest are the agents' probes or readings.

## Bugs and correctness gaps (do first)

1. **Extraction onto exFAT and FAT32 fails at the first hard link.** *Verified by the lead:* an `aa archive` of a tree
   with a hard link and a symbolic link, on a 64 MB exFAT image: `nunarchiver -d …` stops with `link hard.txt:
   Operation not supported` (exit 1); the link's file and the symbolic link are never made. `aa extract` reports the same
   failure but carries on (exit 0, symlink made); `nunzip` on a zip of the tree works. The app expands next to the
   archive, and archives live on exFAT USB drives. Fix: on `linkat` failing with `ENOTSUP`/`EPERM`/`EXDEV`, copy the
   target (counted, as `unquarantinedItems` is); a symbolic link the volume refuses is counted and skipped; a volume
   matrix test (scenario 1 below).
2. **Files left unquarantined are never reported.** *Verified by the lead:* Disk counts them
   (`Extraction.swift:257`), NativeAEA copies the count (`Extraction.swift:276`), NativeZip never reads it, and the app
   never shows it. A quarantined download expanded onto exFAT, SMB, or NFS loses its quarantine silently. Carry it in one
   `ExtractionSummary` (API item 7); the app warns once, the CLIs print it.
3. **Real-archive tests skip silently.** *Verified by the lead:* `~/Scratch` holds only `compression-review-2026-11-23/`;
   the Xcode `.aea`/`.xip` examples are gone, so `FormatTests.verifiesXcodesCertificateChain` returns early, the xip test
   is skipped, and the `NATIVEAEA_ARCHIVE` benchmark rows can't run. An agent had deleted them; the user downloaded them
   again the same day (`Xcode_27.3_beta_2.aea`, `.xip`), and AGENTS.md now says to delete only what the work created.
   `~/Scratch/swift-bugs` (the compiler bug reports AGENTS.md points to) is gone too. Still to do: make the skips
   visible (`.enabled(if:)` with a comment, or a known issue).
4. **A reused `Decompressor` never gives memory back.** Probe: streaming 96 MiB of zstd raised the footprint 131 → 227
   MB, and it stayed after a reset to gzip and after dropping the decoder (freeing a large block didn't lower the
   footprint; `MADV_FREE_REUSABLE` does). Windows only grow (`Workspace.swift:55–110`); `reset` keeps every format's
   decoder. Affects NativeZip's per-slot decoders (kept across archives), HTTP connections, the app. Proposal:
   `Decompressor.releaseMemory(keeping floor: Int = 1 << 20)` (and on `ChunkedDecompressor`, `ZipDecoder`), and windows
   that give pages back at a stream's end (Bytes' `RawStorage` already does this for buffers).
5. **Brotli's encoder positions wrap past 4 GiB in one stream.** *Read by the lead:* `streamBase &+ UInt32(origin +
   position)` (`BrotliEncoder.swift:540,571,687`), rebased only in `reset()`. Matches are verified, so the likely cost is
   ratio (and an absolute 0 read as an empty slot), not corruption, but nothing tests it; a long SocketStream connection
   reaches it. zstd has `setNextIndex` and a 3.5 GB test; add the same hook and test (output decodes with Google's
   decoder, size within 1.1x of a fresh encoder). gzip's ISIZE past 2³² is untested too.

Also found: HTTPBytes' HTTP2 target depends on `BytesMacros` (`Package.swift:61–62`, "frame headers") but no HTTP2 file
imports it, so HTTPBytes builds swift-syntax for nothing (*verified by the lead*). Disk space is not tight: `df` said 98%
full (17.7 GB free now), but that leaves out purgeable space; macOS reports 274.8 GB available, as Finder does
(`Tools/disk-space`, added after this survey).

## API: performance

1. **[H] Bounds checks on 64-byte block loads don't fold in loops.** *Verified by the lead:* HTTPBytes' release
   `HeadScanner.o` (newer than its sources): `farStop`'s loop is 49 instructions per 64-byte block with 8 `cmp`, 4
   `b.lo`, 3 `b.gt`, while `ByteBlock.swift:94` says the four loads' checks fold into one. Same pattern in the `ByteScan`
   loops (`containsByte`, `firstByteOffset(where:)`, `bytesEqual`), SHA-1/256 (8 `cmp` + 9 branches in 126–132
   instructions), SHA-512, and GHASH (9 + 9 in 171). Probes: the `farStop` shape 48 → 29 with `byteBlock(at:)` keeping its
   one precondition and loading unchecked under it; a four-load kernel 35 → 10, or 8 as a `Span<InlineArray<64, UInt8>>`
   view. Proposal: the internal fix in `byteBlock(at:)` and the three scans, a public typed view (`RawSpan.blocks<let
   n>()`, moving BytesCompression's `WordReads` down into Bytes) and `ByteBlock(InlineArray<64, UInt8>)`; correct the
   comments; a test whose input ends at the span's end. Measure HTTPBytes' long-field rows, SHA and AES-GCM at 1 MB.
2. **[H–M] BytesAsync on the SDK's noncopyable `Continuation` (SE-0528).** *Verified by the lead:* the macOS 27 SDK's
   `_Concurrency` has `@frozen struct Continuation<Success: ~Copyable, Failure>: ~Copyable` and
   `nonisolated(nonsending) withContinuation(of:throwing:_:)`; BytesAsync's own types of the same names
   (`Waiting.swift:15–65`) shadow them and differ between builds (checked in debug, unchecked in release). `WaiterQueue`'s
   `[Element?]` with `%` runs a copy-on-write check under the lock. Probe: `AsyncLimiter.release` 54 → 35 instructions,
   no uniqueness check, exactly-once resumption enforced by the compiler in every build. Sites: five BytesAsync types,
   Disk's `JobQueue` and extraction, `BlockBufferPool`, `ParallelBlockDecoder`, NativeAEA's payload; NativeZip's
   `ZipContentSource.swift:293–330` still waits on `CheckedContinuation` with an `Array` (allocates per wait). Gate on the
   zero-malloc thresholds.
3. **[H] `HTTPFieldStore.append`: 534 → 274 instructions a field** (prototype: one allocation, one reserve per field;
   no growth path yet). Parsing into the store costs 5,013 instructions a head against the parse's 1,434. A
   `hasValidValue` bit from HPACK/QPACK would skip `append`'s rescan.
4. **[H] An HTTP/1 sans-IO server connection.** Nothing ties the parser, framing, store, body decoders, and head writer
   together, and nothing outside HTTPBytes imports it. A server's head path costs 5,715 instructions (four times the
   parse): the method parsed twice, every name looked up twice (`RequestParser.swift:193`, `Framing.swift`). Sketch:
   `HTTP1ServerConnection: ~Copyable` with `next(in:consumed:) -> Event` (`.head`, `.body(RawSpan)`, `.end`,
   `.needsMore`), `writeHead`/`writeBody`/`writeEnd`, `keepsAlive`; plus SocketStream's `StreamConnection` to drive it.
   Estimated about 3,700 instructions a head, no mallocs after the first request; a zero-copy identity-body path
   (`HTTP1BodyFraming.next(in:consumed:)`) and field writers taking `HTTPFieldName` (12 fields: 2,406 → 1,864) belong to
   the same project. The conformance suites could drive it directly.
5. **[M] One coder per connection, reset per message.** Making coders per 1.6 KB body costs +13% (zstd decode) to +76%
   (zstd encode, HTTP window: 95.8 K reused against 169 K new) of the body's instructions, and 12 mallocs for gzip.
   `HTTPContentEncoder.coding` is a `let` (`ContentCoding.swift:404`): add `reset(_ coding:, level:)`; `encode` also maps
   every error to `.outOfRoom` (`:436–447`).
6. **[M–L] `firstByteOffset(of:)`/`lastByteOffset(of:)` test candidate blocks a lane at a time**
   (`BytesReader.swift:1397–1401, 1427–1431`): 97–101 instructions a block with any candidate, against 9 a candidate
   walking a `nibbleMask`. Worst case only (dense candidates); do with item 1.
7. **[L–M] DOS dates through `Calendar.current`** (`ZipArchive.swift:536–558`, every entry without a `UT` field): 440
   ns against 118 ns with day arithmetic, identical on 5,000 dates; 30,000 entries 13 → 3.5 ms.

Still open from 2026-11-23 and re-measured: `ByteLanes.matching(_:)` as one `cmeq` (a two-byte `containsByte` step 19 →
12, a three-byte block mask 64 → 44); HTTP/1's repeated method and name lookups (+111 and +645 instructions a head);
swift-http-types conversions (3–5 K instructions and ~3 mallocs a field; `String(decoding:)` per span −65%).

## API: ergonomics

1. **One extraction shape for ZIP and Apple archives** (with bug 2). NativeZip takes a URL and returns `Void`; NativeAEA
   takes a `FilePath` and returns `AEAStatistics`, which repeats about 12 of Disk's report fields; three existing-item
   policies with opposite defaults; Disk's knobs only through AEA; ZIP's options aren't `Sendable`. Sketch:
   `ZipArchive(path: FilePath)`, `ZipExtractionOptions: Sendable { var disk = ExtractionSettings(); … }`, both
   `extract(into:options:) async throws(…) -> ExtractionSummary`.
2. **An archive layer between the packages and the app.** About 230 lines of the app are archive logic (credential
   mapping, three identical `extract` arms, stage/extract/publish/discard in `LiveArchiveExpander.swift:137–170`);
   `nunarchiver` refuses ZIP and writes its commands three times. Sketch: a `NativeArchives` module with `ArchiveKind`,
   `Archive.open(path, credentials)`, `protocol ExtractableArchive`, `Destination.expand(beside:quarantine:_:)`, and
   `ZipArchive.close()` (its mapping, or a private copy on exFAT, lives as long as the struct).
3. **`ByteBuffer` gaps make clients hand-roll buffers on `RawStorage`**: `append(copying:)`, `withFreeCapacity`,
   `growing(to:)`. HTTPPayload's carry and middle buffers (`ContentCoding.swift:181–341`, six `unsafe` copies),
   `ChunkedDecompressor`'s nested closures and hand regrowth (`:151–176`), SocketStream's `Protection.swift:229`.
4. **Helpers that exist or belong in Bytes but aren't used:** `String` from a `RawSpan` (7 sites); `[UInt8](copying:)` in
   HTTPBytesHTTPTypes (`Conversions.swift:71–76`, per field); `bytesEqual` in X.509 (`X509Certificate.swift:161`);
   `StaticString.bytes` as an immortal `RawSpan` (24 sites in 5 packages; HTTPBytes' package-only `immortalSpan` has 15);
   an unsigned `read(Int.self, as: Byte2.self, order)` for the 20 `Int(try reader.read(UInt16.self))` sites.
5. **Scoped resources:** a noncopyable `BlockBuffer` lease from `BlockBufferPool` (NativeAEA retains and releases by
   hand at 14 sites with `-1` sentinels); Disk's five `acquire`/`defer release` pairs as `withPermit`.
6. **SocketStream onto `Compressor`/`Decompressor`**: measured equal (4 MiB: 173.28 M against 173.30 M instructions;
   not yet under the PR toolchain). Then `Compressor.init(for:)` public, the per-codec encoder and decoder types and
   `ZstdEncoder` `package` (HTTP names `ZstdEncoder` only for `httpWindowLog`: a `CompressionFormat.zstdForHTTP(level:)`),
   and SocketStream gains zstd.
7. **Progress in Disk, not the app**: an atomic phase ("Finishing" shows none today), a rate window, `readings(every:)`
   as an `AsyncSequence`; `nunzip` has no progress at all. Cancelling deletes staging synchronously (about 12 s for
   Xcode): rename, then delete in the background, and sweep at launch.
8. **Single-file `.gz`, `.bz2`, `.xz`, `.zst`**: `DecompressionFormat(detecting:)`, a public `GzipMemberInfo` (name,
   mtime), and `ArchiveKind.compressedFile(format)` streamed through `ChunkedDecompressor` into an `OutputFile`.
9. **MQTT**: make `encodedByteCount` and `validate()` public; `write(to:maximumPacketSize:) throws(MQTTWriteError)`
   (the writer maps every broken rule to `BytesError.invalidValue`).
10. **Narrowing after the package split.** The split made `BitBuffer`, `BitWriter`, `HuffmanTable`, `MaskedTable`,
    `LentBytes`, `LentMutableBytes` legitimately public. Delete `LentMutableSpan` (no user anywhere), the async transform
    adapters and `AsyncByteTransform` (tests only); `package` for `InPlaceByteTransform`, `FusedPipeline`,
    `RunningChecksum`, `ByteRepresentable`, `Byte9`/`Byte11`–`Byte15`. 122 public Bytes-core symbols are named by no
    client.

## Macros

**What they generate costs about what hand code does** (probes, `@inline(never)` functions, `objdump`):

| Record | Hand | Macro | Note |
|---|---|---|---|
| HTTP/2 9-byte frame header | 37 (13 hot) | 37 (13 hot) | |
| ZIP end of central directory, 22 bytes | 62 | 73 | identical hot path; one more throw path |
| LZFSE v2 header word, decode / encode | 7 / 11 | 7 / 8 | the hand encoder's `UInt64(Int)` traps; the macro masks |
| gzip 10-byte header | 71 (15 hot) | 112 (22 hot) | one load, compare, and throw site per `expecting:` field |
| ZIP central-directory entry + 3 trailing parts | 131 (today) | 92 (one summed check) | the case for generated trailing spans |

**About 25 hand-written records fit today's macros unchanged**: ZIP's end of central directory, ZIP64 locator and
record, local header, general-purpose flags (7 hand masks in 4 files), WinZip AES extra field; AppleDouble's three
records; `pbz`'s headers; LZMA's zip header; the `bvx*`/`bv4*` block headers; LZFSE v2's three header words and
LZRAVEN's block word; gzip and zlib headers, `GzipFlags`, `ZstdDescriptor`; AEA's profile word; the `decmpfs` header;
HTTP/2's frame header; the TLS record header; MQTT's CONNECT, CONNACK, and subscription-option flags. The gain is less
lines than one declaration shared by reader and writer: the zstd and LZFSE encoders build their headers with their own
shifts (`ZstdEncoder.swift:423`, `LZFSEEncoder.swift:545–553`), apart from the decoders' descriptors.

**Expansions, ranked by records unlocked:**

1. **`@Magic`**: constants that store nothing, written as ASCII or bytes, one-of (`AA01`/`YAA1`), consecutive constants
   merged into one compare with one throw site (~15 records; closes most of gzip's gap).
   `@Magic(Byte4.self, ascii: "xar!")` replaces `@Field(Byte4.self, expecting: 0x7861_7221) var magic: UInt32`.
2. **Trailing `RawSpan` fields with counts from earlier fields** in a `~Escapable` record, one bounds check over the
   summed lengths (~10: ZIP central directory and local header, AppleDouble attribute entries with `@Align(4)`, cpio
   names, AEA auth data, XAR, `pbz` payloads, TLS handshakes, HTTP/2 payloads). Measured −30% instructions.
3. **Validation with the client's errors**: `in:` ranges per field and a `validate()` the generated initializer calls
   (~10: AEA's root header, `pbz`, LZFSE's 12 bounds, ZIP sizes, zlib's multiple-of-31). The real blocker is custom
   errors: AEA, `pbz`, and MQTT re-read raw values to throw their own; an error-type parameter, or a thrown
   `(field, BytesError)` the client maps.
4. **A write path into fixed storage**: `encoded: InlineArray<N, UInt8>` and `unsafe store(to:)` (~8: gzip and zlib
   header and trailer, `decmpfs`, LZFSE's block headers, zstd's frame header, HTTP/2's writer, TLS `keyUpdate`).
5. Conditional fields and widths picked by an earlier field (~6: zstd frame header, xz block header, ZIP extras, ELF,
   MQTT CONNECT/PUBLISH): loses the single bounds check; last.
6. TLV tagged unions: MQTT properties (three 27-case switches, ~110 → 30 lines), later ZIP extras and SETTINGS. Hot
   dispatch: measure (the MQTT big-switch lesson).
7. Odd `@BitFields` storage (`Byte3`, nibbles: zstd's block header, MQTT PUBLISH flags); `Padding<let N: Int>` (AEA's
   22-byte reserved field as one, not three).

Low value: varint fields (xz only, and `XZCursor.integer()` should first use Bytes' existing
`read(LEB128.self, maxByteCount: 9, requiringMinimal: true)`: *verified by the lead*), ASCII-octal (cpio), checksum ranges
(xz), per-field byte order. Not record-shaped: an `@OpenEnum` for the ~100 constants of HTTP/2 and HTTP/3 frame and
setting types, `MQTTReasonCode`, `ASN1Tag` (~200 lines). Leave by hand: HPACK/QPACK prefix integers, QUIC varints, Apple
Archive's field stream, bzip2, attribute lists, DER.

## Tests and benchmarks: realistic scenarios

**Strong today**: compression differentials and mutated Brotli/zstd streams against the references' verdicts, every
capacity, trickled input; HTTP/1 split at every point and byte at a time over cursed-http, h2o, DesyncBox, and the
conformance suites; MQTT's 100,000 mutations and every truncation; Wycheproof; Disk's injected failures and lifetime
checks.

**Gaps** (grep-confirmed): nothing is fed in TCP-segment-sized pieces (1,448 bytes) anywhere; no keep-alive or pipelined
HTTP stream with bodies in pieces, and no benchmark resumes after `needsMore` (heads parsed from exact spans, "1,000
tiny requests" is one head repeated); no mutation sweeps for HPACK, HTTP/2 frames, the field-value parsers, the ZIP
central directory, or `.aar`/`pbz`/XAR/cpio/WKMS (the parsers that see unauthenticated input); TLS's opener fed whole
buffers, and SocketStream never sets `recordLimit`, so keys never update in a transfer; MQTT never exceeds a 2-byte
remaining length (300-byte payloads), its mixed session stream is never split; no ZIP64-by-count archive and no streamed
ZIP with data descriptors; cancellation sampled (after 1, 50, 400 entries), never swept; no worst-case encoder inputs; no
BytesAsync stress; hashes only at 64 B and 1 MB; compression streaming rows in power-of-two pieces without flushes;
ZIP and Disk small files uniform, flat, without links; the app never runs a `.xip`, a read-only or full volume, or an
archive renamed mid-expansion. No benchmark makes fixtures in its measured loop or sums results.

**Proposals, ranked:**

1. **A volume matrix for extraction** (Disk, NativeAEA, NativeZip, the app): `hdiutil` images (exFAT, FAT32, HFS+,
   case-sensitive APFS, a 16 MB APFS image for `ENOSPC`), archives built in the test with hard and symbolic links,
   `decmpfs` files, xattrs, and case- and NFC/NFD-colliding names; compared item by item with `aa extract`/`ditto -x -k`.
   One exFAT case in the fast set (~3 s), the matrix in bulk (~20 s). Catches bug 1.
2. **HTTP/1 connection streams**: real heads with bodies (Content-Length and chunked, gzip/br/zstd/identity mixed) as
   one stream, delivered in 1,448-byte, 16 KB, random, and one-byte pieces, events compared with parsing each message
   whole, under a time limit; 50 messages fast, the corpus in bulk; benchmark rows for 1,448-byte and 16 KB reads. With
   API item 4, this is the connection layer's test bed.
3. **Mutation sweeps where none exist**: HPACK, HTTP/2 frames, field values seeded from corpus headers, the ZIP
   container, `.aar`/`pbz`/XAR/cpio/WKMS, TLS records in pieces, a BinaryParsingComparison differential against
   swift-binary-parsing. 10,000 mutations each fast, a million in bulk; later, llhttp's and ls-hpack's verdicts on
   mutated input recorded at generation time.
4. **Codec rows sized like traffic**: decoders streamed at 1,448 and 16,389 bytes, pipeline receive in 1,448-byte
   reads, and "1,000 JSON messages, flushed each, one stream" (permessage-deflate, compressed MQTT) for DEFLATE 1/6,
   Brotli 1/5, zstd 1/3.
5. **Real-shaped archives from the installed macOS SDK** (33,549 files, all APFS-compressed, 8,192 symlinks, 21
   levels): a `Tools/test-data` generator taking a 60–100 MB subset to `.aar`, `.aea`, and `.zip`, with a hard-link
   overlay, for bulk extraction checks and one benchmark (disk is tight: keep it small).
6. **Cancellation at every system call**: a debug-only "cancel at call N" in `SyscallFaults`, swept; check `.cancelled`,
   lifetimes, no half-written files, staging discarded. Every 10th call fast (1–2 s), every call in bulk.
7. **MQTT**: remaining-length boundaries (127/128, 16,383/16,384, 2,097,151/2,097,152, and a 268,435,455 claim refused);
   the mixed stream split at random points; a broker-mix benchmark (varied topics and payloads up to 256 KB retained,
   QoS 0/1/2 with acknowledgements interleaved, topic aliases) read in 1,448-byte pieces.
8. **TLS as a socket delivers it**: `recordLimit` and padding across 200 messages, opened in random and 1,448-byte
   pieces, alerts split across reads; a SocketStream transfer with key updates; a PUBLISH → PUBACK round trip.
9. **Long streams**: Brotli's stream-base hook and test (bug 5); gzip's ISIZE near 2³².
10. **Worst-case encoder inputs**: 1 MB of zeros, period 3, period of the window + 1, crafted hash-bucket collisions,
    as rows plus a bulk instruction bound relative to dickens.
11. **BytesAsync stress** in bulk (64 × 64 tasks, capacity 1, a million items, `close()` racing offers) under a time
    limit, and one Thread Sanitizer run (more valuable once API item 2 lands).
12. **Hash rows at remainder sizes** (1,000,003 bytes) for SHA-1/256/512, HMAC, XXH64, Adler-32; Nunarchiver flows
    (`.xip` through the live expander, exFAT and read-only images, a volume filling mid-expansion).

## Suggested order

1. Bugs 1–3 with the volume matrix (scenario 1), and the unquarantined count through one `ExtractionSummary`
   (ergonomics 1), then the archive layer (ergonomics 2).
2. Bytes' block loads (performance 1, 6) and BytesAsync on the SDK's `Continuation` (performance 2), each measured
   (HTTPBytes' long fields, SHA/AES-GCM 1 MB; the zero-malloc gates).
3. The HTTP/1 connection project: `append` first (performance 3), then the connection (4), identity bodies, writers,
   coders per connection (5), tested by scenario 2 and the mutation sweeps (3).
4. `Decompressor.releaseMemory` (bug 4) measured across a mixed ZipExtractor run; Brotli's stream base (bug 5).
5. Macros: `@Magic`, then trailing spans, then validation with client errors, then the write path; move the ~25
   records that fit today as each file is touched, measuring the gzip member path.
6. The remaining ergonomics, narrowing last (it depends on the shapes above).

## Status of the 2026-11-23 survey's items (short)

- **Bytes:** done: `RelaxedCounters` on `UniqueArray`, `MaskedTable`, PEM search, `byteBlock(at:padding:)`,
  `limitExceeded`, small cleanups. Partly: the closable pool (in BytesCompressionAsync, not BytesAsync), word reads
  (BytesCompression only), `RawStorage` spans (78 → about 10–19 hand-built sites; `pointer(_:)` documents a precondition
  it doesn't check), byte-at-offset helpers (8 private copies). Open: `cmeq` matching, scan overhead, full-lane
  `ByteMatches` (HTTPBytes' own `matches(_:)` at 14 sites), one ring, the sync/async name clash, every BytesCrypto item
  (the AEAD enum written twice, NativeAEA's own chain validator, X25519/Ed25519/PSS/signing, secret wiping, fixed-size
  key serializers, the C shims), Proposals 4/15/18/19.
- **BytesCompression:** mostly done. Open: format detection, Brotli quality 10–11 (run as 9), zstd dictionaries,
  zstd's Huffman weights, the two in-order delivery loops; unsupported features still throw `invalidValue`;
  `Compressor` throws on a bad level where `DeflateEncoder` clamps; no `Compressor.maximumCompressedSize` or array
  one-shot; `decompressAll(_:maximumSize:) -> [UInt8]` reserves the maximum when the size is unknown.
- **HTTPBytes, MQTT, SocketStream:** the bugs and P1/P9 (declined after measuring) are done; the connection layer,
  `append`, repeated lookups, conversions, and MQTT's items are open (MQTT and SocketStream sources unchanged since
  2026-11-18; their manifests lack the upcoming-feature flags the others have).
- **Disk, NativeZip, NativeAEA, the app:** every bug fixed; open: one extraction shape, the width formula (still 2 on
  the M1 Max), the hard-link pass's lanes, `acquire`/`defer release` pairs, the synchronous discard.

Agents' long-form notes and probes: the session scratchpad's `survey.noindex/` (`core.noindex`, `macros.noindex`,
`clients.noindex`, `scenarios.noindex`, each with `REPORT.md` or notes and its probe packages).
