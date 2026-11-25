# BytesCompression fix plan (2026-11-23)

Fixes every finding of `BytesCompression-Review-2026-11-23.md` (§ numbers below are that review's), in its order:
bugs that truncate, amplify, trap, or hang; then memory and CPU exposures; then performance; then API and docs, with
the public-surface narrowing last. Reproducers are in `~/Scratch/compression-review-2026-11-23/`.

This version folds in an adversarial review of the first draft (its amendments are marked **[R]**: what changed and
why). The review read the code each item changes and probed what reading didn't settle.

## Status (2026-11-24)

- **Phase A: done.** A1, A2 (BytesCompression and NativeZip RESULTS.md), A3 with B9 (BytesCompression RESULTS.md,
  "Honest units"), A4 with D7's hooks and B8's failure order (NativeAEA and BytesCompression RESULTS.md).
- **Phase B: done.** B1–B3 and the AEA timestamps (NativeAEA RESULTS.md, "later"; the budget's default became 64 MiB a
  core, at least 1 GiB, after measuring 1 GiB and 2 GiB), B4, B5, B7, B8's Zstandard one-shot (BytesCompression), B6
  (Bytes), B8's HTTP items (HTTPBytes).
- **Phase C: done** (BytesCompression RESULTS.md, "Small inputs and making coders"; C4 covered the encoders, LZMA, and
  the parallel codecs' buffers; the decoders' construction is left to E1). C5: profiled, no change (Google's quality 0–1 is
  a different one-pass encoder).
- **Phase D: D1, D5, D6, D8, and D10's parts done** (BytesCompression RESULTS.md, "later"). Left: D2, D3, D4, D9,
  D10's rest, D11, in two agents run one after the other (E1: C4's decoders, D2, D4, D3; E2: D9, D11).
- **E1: done** (BytesCompression RESULTS.md, "E1"; NativeZip's, HTTPBytes', and Bytes' RESULTS.md for D4 and D3): C4's
  decoders and the LZFSE and Zstandard encoders (the LZVN encoder's only table must start at zero: unchanged); D2 (the
  encoders' whole-buffer calls return nothing, as most did; `LZMA2Decoder`'s `.lzma` file entry went to the tests);
  D4; D3, whose `BytesError` case was added at D4's start (D4's decoder throws it). Left: D9, D10's rest, D11 (E2).
- **E2: done** (BytesCompression RESULTS.md, "E2"; Bytes' and HTTPBytes' RESULTS.md for D9). D9: Bytes' `MaskedTable`,
  kept on DEFLATE's match tables, LZFSE's and LZVN's match lines, and HTTPBytes' dynamic-table ring, where it measured
  equal or better; Zstandard's tables (+1.2 to +5.4%) and HTTPBytes' encoder index (+0.2 to +0.8%) stay on pointers, so
  the four HPACK/QPACK coders stay `@unchecked Sendable`; `StrideTable` stays in BytesCompression (its only clients);
  the encoders' and checksums' word loads in one file (`WordReads.swift`), identical code. D10's rest: the level and
  quality ranges, FORMAT.md's segment cap and nanoseconds, ARCHITECTURE.md; `HTTPContentEncoder.reset()`'s doc and the
  carry comment were already right. D11: NativeAEA's benchmark `SegmentDecoder` on `Decompressor` (rows flat), then
  BytesCompression's declared public symbols 322 → 159, BytesReferenceCodecs' 23 → 17, the async entry points' 6 → 2;
  BytesCompressionAsync's engine kept (its inlinable public code reaches it). The plan is complete.
- **After E2:** reviewing `MaskedTable` found `fill(_:groupedAs:)` accepting a group with a padding lane (`SIMD3<Int32>`:
  16 bytes, three lanes, the fourth stored as 0 over every fourth entry); it now traps (Bytes' RESULTS.md, E2).
  Final gates: every package's default set (Bytes 391, BytesCompression 372, NativeAEA 81, Disk 72, NativeZip 65,
  HTTPBytes 268 with its 4 known issues, MQTT 20, BinaryParsingComparison 17, SocketStream 6), the bulk sets
  (BytesCompression 70, NativeAEA 3, HTTPBytes 15), HTTPBytes' benchmarks and BytesProbe built, Nunarchiver built and
  its 35 tests passed; no warnings; every baseline slimmed.

## Rules for every phase

- **Before the first edit of a phase**, save "before" baselines of every row the phase can move (unique names:
  `fix-A-before`, …), and queue them all before editing (package-benchmark builds the tree on disk when it starts).
- **Each fix lands with a regression test** built from its reproducer (fast form in the default set; corpus sweeps,
  large inputs, and byte-at-a-time sweeps of formats that re-read headers in a `.bulk` suite: they're quadratic in
  debug builds). Break the fix once to see the test fail (AGENTS.md), and say so in RESULTS.md. **[R]** A test must be
  able to fail on the code before the fix: one that passes on today's code (the first draft's B5 test did) proves
  nothing. Hang tests use generous time limits: they catch hangs, they don't measure speed.
- **Gates per fix:** `swift build --build-tests` with no warnings in the package and every client that builds against
  it; the touched suites (`--filter 'Suite/'`), then the clients' suites that use the API; the reproducer re-run by
  hand against the release CLI (`nunzip`, `nunarchiver`), with `gtimeout` and, for memory, `/usr/bin/time -l`
  (resident memory, not reservations).
- **Gates per phase:** the full default test set of every touched package, the bulk set where codecs changed
  (`BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter …Bulk`), Nunarchiver's `build.sh` build and
  tests when a public API it uses changed, "after" baselines compared by instructions (`Tools/bench-table`), hot loops
  rechecked with `Tools/loops`/`Tools/calls` where touched, `Tools/slim-baselines`, RESULTS.md and AGENTS.md updated.
- No change in instruction counts beyond noise on rows a fix shouldn't touch; any loss a fix costs is measured and
  stated.

## Phase A: truncation, amplification, traps, hangs (§1.1–1.5, with §3.1 and §3.2 as the vehicles)

Baselines `fix-A-before` saved (NativeZipArchive and NativeAEA whole; BytesCompression's bzip2, Decompressor, LZMA
small streams, xz, and gzip rows).

**A1. ZIP's size check per chunk (§1.2). Done.** Both `contents` forms (the decoder's own loop for `ZipError` bodies,
and `readContents`) check `written <= entry.uncompressedSize` before `body` sees a chunk. **[R]** The stored path
isn't equal by construction, as the draft said ("assert it" would have trapped on crafted input): the payload is the
compressed size, which nothing ties to the recorded one, so a stored entry is refused before `body` when the two
differ. Tests `contentsStopAtTheRecordedSize` (8 MiB of zeros recording 2 MiB: the body sees at most 2 MiB, in both
forms; with the check disabled it saw 8 MiB) and `storedEntryLargerThanItsSizeIsRefused`. `nunzip -p bomb2.zip` now
writes about 1.1 MB, not 1 GiB. Extraction already checked per chunk (`ZipContentSource`).

**A2. A stream's end with input in pieces (§1.1, and the same flaw in bzip2's `transform`).** **[R]** What the
decoders actually do: gzip, zstd, and xz report `.finished` only with all their input consumed (a following byte is
read as the next stream's start, or thrown as `invalidValue`); only bzip2 reports `.finished` with bytes left, either
four or more that aren't a `BZh` header (its real end) or fewer than four (it can't tell yet). So the draft's
per-format lookaheads don't exist; the rule is:
- A `.finished` is final when the input has ended, or (bzip2) when at least four bytes are left after it. Otherwise,
  for formats that concatenate (`DecompressionFormat.allowsConcatenation`: gzip, zstd, xz, bzip2), it's tentative:
  more input continues the decoder into the next stream.
- `ChunkedDecompressor` tracks `inputEnded` (borrowed: always; staged: once `fillInput` returns 0) and returns
  `.needsInput` with the chunk open at a tentative end. After the input has ended it never returns `.needsInput`: it
  finishes or throws `insufficientData`. The caller's loop is "on `.needsInput`, `fillInput`, call again" (ZipDecoder's
  `refillInput` loses its `guard fill > 0 else throw`; the doc example changes).
- **[R]** `fillInput` returning 0 also happens when the staging buffer is full (the decoder holds a whole unit larger
  than it): an empty free span is "unit larger than staging", thrown, not "input ended".
- **[R]** `BZip2Decoder.transform(_:into:flush:)` passes a `.finished` with 1–3 bytes left on as finished (probe:
  two streams through `Decompressor(.bzip2).transform`, cut 1–3 bytes past the first: 400,001 of 666,670 bytes,
  `finished`). It reports `.needsInput` for fewer than four bytes left unless flushing with `.finish`. Every `Pipeline`
  user had this.
- Tests (fast, each concatenating format, staged and through `transform`): two streams, input cut exactly at the first
  stream's end and 1, 2, 3, 4 bytes past it; a single stream needs no `fillInput` round beyond the one returning 0;
  bzip2 with four or more trailing non-header bytes ends with them left; gzip, zstd, xz with trailing garbage throw
  (as now: the test pins it, so no one "fixes" the decoders to pass a wrong expectation). ZIP: the `zz-boundary` shape
  (ZipCrypto, two zstd frames) **[R]** with the first frame's size derived from `stagingCapacity` (A3 changes it; a
  constant 262,144 would stop testing the boundary). Bulk: every cut point of a three-stream input per format.

**A3. Honest units, bzip2's bounded tables, Brotli's real unit (§1.3, §3.1).**
- **bzip2 [R]:** one constant for both the check and the declared unit: a code length takes at most 20 delta steps
  (lengths are 1–20; the draft's "40 steps" allowed 81 bits per symbol while declaring 41, so a stream using 21–40
  steps would still trap a `Pipeline`). Selectors take at most 6 bits (`ones < groupCount ≤ 6`), not 7. The unit is
  then 105 + 272 + 3 + 15 + 32,767 × 6 + 6 × (5 + 258 × 41) + 7 = 260,502 bits, 32,563 bytes (recompute from the code
  while implementing). libbzip2 accepts endless +1/−1 pairs: a deliberate difference (no encoder writes them), in
  RESULTS.md.
- **Brotli [R]:** declares 1 and traps `Pipeline` on valid data: `brotli -q 11` output of Silesia mozilla, x-ray,
  dickens, samba through `Pipeline(Identity(), BrotliDecoder(), bufferCapacity: 1024 or 2048)` all SIGTRAP; x-ray
  fed a byte at a time held back 7,780 bytes (one meta-block header). SocketStream runs `TLSRecordOpener(…)
  .then(BrotliDecoder())` on its peer's bytes. The largest meta-block header (256 trees of each kind, full context
  maps; roughly 270 KB by estimate) is computed exactly and declared; a crafted maximum header is a test input.
- gzip needs nothing: names and comments are consumed as they arrive. Zstandard holds back nothing (it consumes
  partial blocks). DEFLATE's unit is its largest dynamic header; LZMA's 20; xz's 65,542.
- `DecompressionFormat.maximumUnitByteCount` per format; `Decompressor.maximumUnitByteCount` the maximum (Brotli's now).
  **[R]** Buffers are sized per format, not by the maximum: `ChunkedDecompressor`'s staging is sized in `start()` from
  the format (at least twice its unit; ZIP never uses Brotli, so its workers keep 256 KB), and HTTPBytes' carry from
  its coding's unit (what it grows to for `br` stated).
- Tests: fed a byte at a time, the most held back never exceeds the declared unit (fast: a small sample per format;
  bulk: the corpus and the crafted worst cases: bzip2's most selectors and longest code lengths, Brotli's largest
  header). `Pipeline` with 256-byte buffers decodes the 49 KB bzip2 stream and the Brotli corpus files, and throws
  (not traps) on the crafted corrupt bzip2 stream.

**A4. One block source; stops that can't hang (§1.4, §1.5, §3.2, and §3.11 with it [R]).**
- `ParallelBlockDecoder` takes one `BlockSource`: `.indexed(Range<Int>)`, `.pbz(compression, blockSize, file:
  Range<Int>)`, `.pbz(compression, blockSize, upstream: any OrderedBlockSource)`, `.slices(size, file: Range<Int>)`. The
  slices-from-upstream combination can't be written.
- **[R]** `BlockStage`'s requirements are reshaped once, here, with D7's finer hooks (stored bytes: read or map;
  prepare: MAC, decryption; verify raw bytes), so NativeAEA (`AEASegmentStage`, `ArchiveFileStage`) and XIP
  (XIP.swift:284) move once. The requirements a source doesn't use can't trap: each source's stage protocol asks for
  what it reads. `AEASegmentStage` keeps the full override for mapped, encrypted, stored segments.
- `stop(_:)` passes a failure upstream (`failure ?? Failure(.cancelled)`; the upstream's only consumer is this engine's
  producer), and **[R]** `stop(nil)` also wakes this engine's own waiting consumer with `.cancelled`. Checked by the
  review: `.cancelled` stays invisible to clients (`withDecoding` returns `consume`'s value, not the stored failure).
- Pool sizing moves into the engine (`BlockBufferPool.sized(…)`), replacing NativeAEA's two hand-written rules, and
  **[R]** keeping the deferred `active:` count that Payload.swift depends on (only what a `pbz` producer needs is
  handed out until the first segment says writers will hold buffers).
- Tests: the `big.aea` shape (a `pbz` stream in AEA segments, a block spanning more segments than are in flight, the
  consumer stopping early with an error, and without one) ends, every buffer released, at 1, 2, and 8 decoders.
  Specialization rechecked: `Tools/calls --target NativeAEA NativeAEA '.*' --callee 'swift_getGenericMetadata|witness'
  --sum` unchanged, NativeAEA's List and Extract rows flat.

## Phase B: memory and CPU exposures (§1.6–1.12, minor items)

**B1. Buffer budget (§1.6).** AEA segment size at most 256 MiB (**[R]** confirmed: `aea encrypt -b 512m`, `1g`, `2g`
all record 268,435,456; `aa archive -b 512m` fails). A decoded-bytes budget (default 1 GiB; an option) for every pool
the engine sizes, decoders' read scratch (block size + 64 each) and the upstream staging included. **[R]** The
liveness minimum includes the buffers writers hold (`held = disk.writers`, one per performance core), so with 256 MiB
blocks the minimum alone is several GiB: when blocks are large, the writers (and the held buffers with them) are
reduced to fit (`writers ≤ budget / blockSize − 2`), then decoders, then extra buffers. Tests: `sized` stays within
the budget for 1/64/128/256 MiB blocks; a large-block archive with a multi-block file extracts without deadlock;
`xat-big-blocks.aar` (5.1 GB) and `seg128.aea` (2.16 GB) re-measured.

**B2. Metadata blobs (§1.7).** An entry's XAT and ACL blobs together at most **[R]** 256 MiB by default (an extraction
option): the draft's 64 MiB refused what Apple's tools write (an 80,000,000-byte extended attribute round-trips through
`aa archive` and `aa extract`, and today's `nunarchiver` extracts it). Refused where the sizes are parsed, before
anything is held. **[R]** `blobs` is reserved once from the declared (now bounded) sizes instead of growing by
doubling (the 80 MB attribute peaked at 380 MB, 4.75x), and shrinks back after an entry that grew it past 1 MiB.
Tests: a crafted archive declaring a 1 GiB XAT throws at its header; an `aa`-made archive with an 80 MB attribute
extracts (bulk: it's large).

**B3. XAR's TOC scanner (§1.8).** Keep the path incrementally (append the name, truncate to the saved length at the
end tag) and report it only while it's at most 128 bytes (longer paths report `""`, which matches no case: the deepest
path the reader uses is 51 bytes). Each event then costs its own bytes plus 128. (Review: sound; the scanner's other
work is linear.) Tests: the 40,000-deep TOC in well under a second; one 1 MB element name with 100,000 children
likewise; the real Xcode TOC's events unchanged.

**B4. ParallelDeflateDecoder's segments (§1.9).** A budget of decoded bytes per call, equal to the output's capacity
(plus a minimum segment per lane). **[R]** Segments are speculative and overlap (a segment decodes on past a false
split), so they spend the budget in time order: running out marks the segment failed, and its region is decoded again
in place after the real history (the existing fallback), never thrown; only the in-place decode throws
`insufficientCapacity`, as the sequential decoder would. Segments allocated uninitialized. Tests: an output of exactly
the decoded size decodes correctly at every lane count 1–16 (bulk); `zflush.gz`'s shape into 16 MiB throws with
peak memory near the output's size, not 10 GB.

**B5. Zstandard's window (§1.10).** **[R]** The draft's design would corrupt output silently: the decoder wraps its
window at its allocated size (ZstdDecoder.swift:341–353), so a hint that shrank the memory but not the window matches
may reach would let a ZIP entry that decodes past its declared size wrap early and copy overwritten history. So:
`.zstd(maximumWindowSize:sizeHint:)` lowers the frame's usable window to the hint as well (a match reaching past it
throws), and output past the hint throws, as xz's `sizeHint` does. The hint stays out of `Decompressor.reset`'s
decoder-reuse comparison (as xz's `reset(sizeHint:)` keeps one decoder). ZIP passes the entry's size. `startFrame`
already limits the window to a declared content size; the finding is frames without one (the 6-byte header).
Reserving unzeroed is safe by the review's reading: the window is reused across frames without zeroing today, offsets
are checked against what the frame produced, and wild copies read only bytes already written. Tests: a frame with no
content size declaring a 128 MiB window, through ZIP with a 1 KB entry: resident memory stays small (measured), and
output past the size throws; a reuse test (decode 0xAA bytes, then a frame whose offset reaches past what it has
produced: it throws, never outputs 0xAA).

**B6. X.509 extensions (§1.11).** At most 64 extensions (`invalidValue` past that), kept in an
`InlineArray<64, Range<Int>>`, the rescan path removed. Tests: 65 refused; 64 distinct accepted; a duplicate at
positions 1 and 64 found.

**B7. Compressor parameters (§1.12, §3.5).** `Compressor.reset(for:)` throws `invalidValue` for an out-of-range
window log (zstd: 10–27) and negative levels. **[R]** High levels keep clamping (HTTPBytes passes users' levels:
`br` at 11 and zstd at 19 are ordinary settings; throwing would break them); the docs state what each runs as. Level
0 is libzstd's default, 3 (it runs as 1 today, by `max(level, 1)`). `Compressor` conforms to
`ResettableByteTransform` as `Decompressor` does. Clients (Disk, HTTPBytes) adapt.

**B8. Minor items.** HTTP/2 and HTTP/3 `:status` first digit 1–9. **[R]** `ZstdDecoder.decompress(_:maximumSize:)` has
no callers outside tests: `package`, growing its array as it decodes. HPACK's `literal(continuing:)` as a loop.
`HTTPRangeSet.resolve` parses once into a 256-entry stack buffer, then sorts and merges. AEA timestamps with
nanoseconds ≥ 10⁹ refused at parse. `ParallelBlockDecoder`'s failures: **[R]** the reported one is the lowest failing
block index among those failed (so the error doesn't vary with timing), named by the source's kind ("block N" for
`pbz`, "segment N" for AEA). Each with a test.

**B9. [R] Headers re-read from the start (new).** bzip2's tables and Brotli's meta-block headers are parsed again from
their start on every call that doesn't complete them: fed a byte at a time, the first 2 MB of x-ray's `.br` took
1.98 s against 0.027 s in 64 KiB steps, and a crafted ~130 KB header trickled through HTTPBytes' carry costs about
10¹⁰ byte-steps a body. The fix belongs in the decoders: resumable header parsing (the parse's position and the
tables built so far kept across calls). Retrying only when the held bytes double (the review's suggestion) was
rejected: in an interactive stream (SocketStream, MQTT over a compressed socket) the peer flushes and waits for a
reply, and a decoder holding a completed header but waiting for the doubling would deadlock. Tests: a byte-at-a-time
decode of a stream with the largest header finishes within a time limit (bulk), and instruction counts of the decode
rows stay flat.

## Phase C: performance (§2), with stride-typed storage as the base

**C0. Rows first.** Add small-input rows: DEFLATE levels 1 and 6 at 64 B, 1 KB, 4 KB with a reused encoder;
HTTPBytes' gzip encoding of a 1.6 KB body per message; LZBITMAP encoding of 1, 4, 16 KB; coder construction for each
codec. Save `fix-C-before` with them.

**C1. Stride-typed tables (the user's note; §3 follow-up).** Generalize `LZMAWorkspace`'s pattern into one internal
type: a table of `Element` stored and cleared in `SIMD` groups, aligned to its group by construction, so a fill can't
be misaligned and compiles to wide stores. Port LZMA's workspace onto it first and require identical codegen
(`Tools/loops`: one `vector128` loop of `str q0`, 1,004 stores for lc 3; instructions equal on "LZMA small streams"),
then the DEFLATE hash tables and the LZBITMAP table.

**C2. DEFLATE's reset (§2.1, §2.2).** The review's variant: hash3 cleared only for strategies that read it, cleared
64 bytes per store; hash3 not allocated at levels 0–1 (allocated on a reset to a level that needs it). Byte-for-byte
tests unchanged.

**C3. LZBITMAP's table (§2.3).** Positions stored biased by −8 so an empty bucket is 0 and the clear is a zero fill;
the bias folded into the hot loop (`Tools/loops`: no added instructions per position). Byte-for-byte parity with
Compression on every corpus file and capacity (existing tests).

**C4. Construction (§2.4).** Allocate tables uninitialized and run the (now vector) reset; zero only what's read before
it's written. Measured per codec on C0's rows.

**C5. Brotli quality 1 on small inputs (§2.5):** profile and report; change only with a measured gain.

## Phase D: API, docs, narrowing (§3.3–3.12, §4)

- D1 `PBZ.header(_:)` (three NativeAEA sites onto it); `blockSizes`, `blockHeaderSize` to `package`.
- D2 One spelling for whole-buffer calls (`decompressAll(_:into:decodedSize:)` everywhere, `LZBitmapEncoder`'s whole
  call named as such, LZMA2Decoder's entry points cut to the needed ones, encoders returning `Int` consistently) and a
  `Decompressor` one-shot into a new array (reserve, then `append(addingCapacity:)`); XIP onto it.
- D3 `BytesError.limitExceeded` (Bytes) for configured limits (zstd window, LZMA dictionary, sizes) apart from
  `insufficientCapacity`; HTTPBytes drops its `freeCapacity` test; `AEAError`/`ZipError` keep `cancelled` apart.
  **[R]** A new case breaks every exhaustive `switch` over `BytesError` in the clients: list them first (grep every
  package, the app, and BytesProbe), and do D3 after A3 (which touches HTTPBytes' check).
- D4 LZMA's exact output limit in the decoder (`.lzma(maximumSize:)`); NativeZip drops `outputLimit`/`produced`.
- D5 HTTP's knowledge in the package: DEFLATE container detection (zlib or raw) as a format, `allowsConcatenation`
  (from A2) used by HTTPBytes, `DeflateDecoder.reset(format:)` so `Decompressor` keeps two DEFLATE decoders, not four.
- D6 Shared in-order delivery for `ChunkScheduler` and `InflateDelivery`, one stop flag; a
  `decompressAllConcurrently` for `ParallelDeflateDecoder`.
- D7 (moved into A4.)
- D8 `BlockBufferPool`'s carry region as a parameter.
- D9 `MaskedTable` in Bytes, applied to DEFLATE's and Zstandard's match tables and LZFSE/LZVN's lines where it measures
  equal or better; shared encoder word-read helpers.
- D10 Docs: ARCHITECTURE.md §1, §3, §5 to the code; RESULTS.md's superseded note; Brotli's quality and DEFLATE's
  level ranges stated as they run; `HTTPContentEncoder.reset()`'s doc; dead `ZipDecoder.chunkSize`.
- D11 Narrow the public surface by usage (symbol graph, every client including BytesProbe and Nunarchiver), after
  NativeAEA's benchmark `SegmentDecoder` moves onto `Decompressor`.

Each D item gets the same gates; API changes rebuild every client and Nunarchiver.

## Execution

One phase at a time in the main tree. Within a phase, work that touches disjoint packages may run as parallel agents
(each its own packages, its own scratch directory, benchmarks judged by instructions), but BytesCompression has one
editor at a time. Disk is ~26 GB free: no worktrees with full builds beyond one at a time; remove each when merged.

## What the review confirmed as planned

B3's 128-byte path (the scanner's other work, `skip`, `unescape`, `attribute`, is linear), B6's 64-extension cap,
the AEA segment cap at 256 MiB, and `.cancelled` staying invisible after A4's upstream stop.
