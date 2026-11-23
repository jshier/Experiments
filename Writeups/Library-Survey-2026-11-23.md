# Library survey: API, performance, `unsafe`, and Swift features (2026-11-23)

Seven read-only surveys of the repository's libraries, merged. Packages covered: Bytes (`Bytes`, `BytesAsync`, `BytesBase64`,
`BytesFoundation`, `BytesMacros`, `CBytesNEON`), BytesCompression, BytesCrypto, HTTPBytes, MQTT, SocketStream,
NativeZipArchive, NativeAEA, Disk, and the Nunarchiver app. Package roles are in the "Repository" table of `AGENTS.md`.

## Method and how to read this

- **Seven surveys, no benchmarks.** Each agent read sources and the RESULTS files, wrote throwaway probe packages (typecheck,
  `-O -S`, `Tools/loops`, `Tools/calls`, `objdump`; no repository edits, no builds in the repository), and counted
  instructions. Instruction counts are exact; cycles were not measured. AGENTS.md's rule applies: fewer instructions can be
  slower, so every performance claim without a cycle number needs a benchmark.
- **Toolchains:** Xcode 27.3, Swift 6.4.4 (the default); the PR toolchain `pr-91981` (Swift 6.5-dev, build 2511), SocketStream's.
- **Tags.** **verified**: checked by a probe or by reading the code (the entry says which). **recorded**: taken from a RESULTS
  file or OPTIMIZATION.md (its number was measured earlier). **needs measuring**: reasoning or a static count, no timing yet.
  "verified on 6.4.4" marks what the lead compiled with Xcode's Swift 6.4.4 after the surveys.
- **Priority:** H worth doing soon, M when touching the area, L nice to have. (The inputs' P1/P2/P3 map to H/M/L.)
- **Source IDs** (each entry ends with one): **BC** bytes-core, **CD** codecs (BytesCompression and BytesCrypto), **PR** protocols
  (HTTPBytes, MQTT, SocketStream), **AR** archives (Disk, NativeZip, NativeAEA, Nunarchiver), **EC** swift-ecosystem, **UC**
  `unsafe` in BytesCompression, **UO** `unsafe` everywhere else. `[BC A3]` is that report's item A3.
- Paths are relative to the repository root; `Bytes/Sources/...` is shortened to the file name where unambiguous.

### Where the inputs disagree, and how this document resolves it

1. **`RigidArray`.** CD says it is in Xcode's standard library; PR says `UniqueArray` is not in the 27.3 standard library.
   Lead's check (overrides both): `UniqueArray` is public in Xcode 6.4.4's SDK; the SDK has only an internal `_RigidArray`
   behind it; `RigidArray` is public in swift-collections 1.7.
2. **Safe `load` after a guard.** UC: a safe `RawSpan.load` after the code's own guard (`i &+ 32 <= count`, variable `i`)
   does not fold (36 instructions and 4 `brk` against 13). UO: with a guard on `count` and offsets that are constants or
   `count &- k`, it is byte-identical to the unchecked form (25 instructions, merged by LLVM). Both are right: the shapes differ.
3. **`UnsafeLanes` and parallel lanes.** UC files them under "needs a feature"; its own probe note says `Mutex<Lane>` works
   today at one uncontended lock per chunk (not codegen-probed). Listed under both.
4. **`Lent*` types.** BC finds `LentMutableSpan` has no user in any package and proposes deleting it (and `package` for the rest);
   UC names `LentBytes`/`LentMutableSpan` buffers as handoffs in BytesAsync; EC says the `Lent*` design stays until a language
   answer lands. Resolution: grep once more before deleting `LentMutableSpan`; narrowing the others to `package` is compatible with EC.
5. **`Iterable`.** EC suggests conforming Bytes' block and record walkers; BC and PR checked that `~Escapable` elements
   (fields, properties, subscriptions, records) cannot be `Iterable` elements (typechecked error), so only Escapable-element
   walkers qualify.
6. **`@export(implementation)`.** EC lists it as a clarity gain; BC and CD recommend no sweep (no codegen change expected).
7. **AES/AES-GCM typed block views.** UO marks them "safe now?" but warns the kernels use all 32 vector registers (spill
   risk): counted as unverified, not as safe.
8. **Lookahead on responses.** PR proposed it as "never measured on responses". Corrected below (PR P1).

---

## Summary: the 20 most valuable findings

Bugs and correctness gaps first, then API and performance by expected value.

| # | Finding | Tag | Where |
|---|---|---|---|
| 1 | **Bug: Disk closes a descriptor twice.** `Destination.init` closes `root` and throws after every stored property is set, then `deinit` closes it again; the second `close` can hit a descriptor another writer now owns. Delete the explicit close; better a `~Copyable` owning descriptor (see 18). | verified (probe `deinit.swift`; lead read the code) | `Disk/Sources/Disk/Destination.swift:135–141`, `178–181` [AR 1.1] |
| 2 | **API inconsistency (a footgun, not a bug): `…All` reuse differs by codec.** `compressAll` on a reused Deflate or Brotli encoder stops at a documented precondition ("needs a fresh or reset encoder"); `decompressAll` on a used Deflate or Brotli decoder returns 0 consumed and appends nothing, with no error. Zstd and BZip2 reset themselves. Make every `…All` reset first. | verified (code; a two-line test confirms the no-op) | `DeflateEncoder.swift:100`, `BrotliEncoder.swift:84`, `DeflateDecoder.swift:101,394`, `BrotliDecoder.swift:60` [CD A4] |
| 3 | **Gap: gzip decoding stops after the first member.** RFC 1952 allows several members (`cat a.gz b.gz`, BGZF, pigz, rotated logs); zstd, xz, bzip2 decoders take concatenations. A missing feature, rare in HTTP bodies. | verified (code) | `DeflateDecoder.swift` (`.done` after trailer) [CD A5] |
| 4 | **Bug (to verify): a failing quarantine `setxattr` fails the whole extraction** on volumes without xattr support (SMB, NFS, some exFAT); Archive Utility expands there. Treat `ENOTSUP` as "no quarantine here", note it once, report it. | needs measuring (needs a test volume) | `Disk/Sources/Disk/Metadata.swift:445–450` [AR 1.1] |
| 5 | **Bug: error mappings lose information.** NativeZip folds five `BytesError` cases, including `.cancelled`, into `.corruptData` (a cancelled parallel decode reads as corruption); the app detects a wrong AEA key by `hasSuffix("(wrong key?)")` on a message string. | verified (code) | `NativeZipArchive/.../ZipArchive.swift:691`; `Nunarchiver/.../AppleArchiveAdapter.swift:66`, `AEAArchive.swift:96`, `AEASignature.swift:100` [BC A7, AR 1.2] |
| 6 | **Disk's default width is 2 on the M1 Max** (`min(6, max(2, performanceCores / 4))`, 8 P cores). The only M1 Max data (2,000 small files: 255/138/106/81 ms at 1/2/4/8 workers) says wider is faster; the M3 Ultra's table says width 2 costs 848 ms against 499 ms at 6. Sweep 2–12 on the M1 Max, then replace the formula (or tune at run time). | recorded; needs measuring; formula verified by reading | `Disk/Sources/Disk/Progress.swift:157–164` [AR P1] |
| 7 | **`HTTPFieldStore.append` costs 2.7–3.4x the parse it follows** (125 µs against 36–65 µs for 401 heads; about 400 instructions a field in the store against about 230 to decode it): three arrays, two out-of-line `append(contentsOf:)` and two uniqueness checks per field. One raw allocation, one capacity check per field. | recorded; call counts verified; profile first | `HTTPBytes/Sources/HTTPBytes/FieldStore.swift:89–134` [PR P4] |
| 8 | **`ByteLanes.matching(_:)` as one `cmeq`** (full lanes) instead of the SWAR `(d^b)&-1&~(d^b)`: 11 against 14 instructions per `containsByte` step, 25 against 38 per 64-byte mask, 43 against 64 for three matches. Dependent chain 3 vector ops to 1. | verified (instruction counts); cycles needs measuring | `ByteScan.swift:32–37`, `ByteBlock.swift:86–91` [BC P1, A2] |
| 9 | **Scan-loop overhead in `firstByteOffset`/`containsByte`**: 15 instructions per 16 bytes (7 overhead, one bounds check that did not fold) against 9 with unchecked loads and a precomputed limit. | verified (instruction counts); cycles needs measuring | `ByteScan.swift:165–262` [BC P2] |
| 10 | **HTTP/1 request path repeats work the parser did**: `HTTP1RequestLine.knownMethod` re-parses a method the parser matched from one 32-bit word (80-instruction function, about 8% of a 1,263-instruction head); `HTTP1Framing.observe` repeats the field-name lookup (44 cycles a head on http-corpus requests, 162 on top-1k, recorded). | verified (static); needs measuring | `HTTP1/RequestParser.swift:59,118–135`, `HTTP1/Framing.swift:59`, `Method.swift:28` [PR P2, P3] |
| 11 | **Hard-link pass runs at about 2.8x effective parallelism on 6 lanes** (Xcode: 26,062 links, 2.59 s of 9.9 s, 280 µs each alone). Lanes take every n-th record, so one inode's 5.4 names contend. Group by target; sweep the pass's width on its own. | recorded; needs measuring | `Disk/.../PostPasses.swift:82–148`, `Planner.swift:58–62,374–385` [AR P2] |
| 12 | **A symmetric `Compressor`/`CompressionFormat` and limits on `Decompressor`.** Three clients rebuild the encoder switch (Disk `Decmpfs.swift:186–245`, HTTP `ContentCoding.swift:364–416`, SocketStream `Protection.swift:118–160`); HTTP bypasses `Decompressor` for zstd to apply RFC 9659's 8 MB window cap; output caps are written three times. | verified (code) | `Decompressor.swift:10,94`, `ZstdDecoder.swift:74,318` [CD A1, A2] |
| 13 | **Zstd one-shot: write blocks straight into the caller's output.** Random 1 MB at level 3 is +21% instructions and +15% time against libzstd, attributed to the second copy of every stored block (and 128.5 KB extra memory). | recorded; needs measuring | `ZstdEncoder.swift:230–275`; `RESULTS-zstd-encoder.md` [CD P1] |
| 14 | **NativeZip and NativeAEA extraction APIs differ for no reason**: URL against FilePath, untyped against typed throws, `Void` against `AEAStatistics`, `OverwritePolicy` against `Bool`, no Disk knobs against `.disk`. One shape (Disk settings, `ExtractionSummary`, typed `ZipError` with `.disk`) shrinks both app adapters. | verified (code) | `ZipArchive+Extraction.swift:130–280`, `NativeAEA/Extraction.swift:96–145` [AR 1.2] |
| 15 | **No connection layer: nothing outside HTTPBytes imports it.** Sans-IO HTTP/1 server and client connections (head, framing, body, response, keep-alive), protocol-neutral request and response heads, then HTTP/2. The only way to find API mistakes in the pieces. | verified (grep) | `HTTPBytes/PLAN.md` phase 7, `WRITEUP.md` "Open items" [PR A1, A2] |
| 16 | **`unsafe` audit: about 750 sites are safe now at no cost** (about 520 outside BytesCompression, 229 in it), another 295 in BytesCompression are likely free; about 850 need a language feature; about 285 are inherent (syscalls, C, hints). Details and the change list in "Unsafe code". | verified (probes) for the patterns; sites by reading | whole repository [UC, UO] |
| 17 | **Narrow access by usage.** Bytes: `BitBuffer`, `BitWriter`, `HuffmanTable`, `Lent*`, the async adapters, in-place pipeline stages, `RunningChecksum`, `ByteRepresentable`, `Byte9`/`Byte11`–`Byte15` have no client outside the package. BytesCompression: `LZ4Decoder`, `LZRAVENDecoder`, `LZMA2Decoder`, `LZMADecoder`, `XZDecoder`, `CRC64`, `XXHash64`. HTTPBytes: 65 of 83 public types unnamed outside tests (sequence after 15). | verified (census) | [BC A1, CD A9, PR A11] |
| 18 | **Scoped and owned resources.** `AsyncLimiter.withPermit`, a `~Copyable` `Lease` from `AsyncIndexPool` with a closable pool (Disk repeats the acquire/defer-release pair 5 times; NativeAEA releases a buffer by hand on five exits and reimplements the pool for `close()`); a `~Copyable` owning descriptor (finding 1's bug cannot be written). | verified (code) | `AsyncLimits.swift:16,104`, `Disk/Writer.swift:577–753`, `NativeAEA/BlockStream.swift:308–356` [BC A3, AR 3.2] |
| 19 | **`RawStorage` vends pointers, not spans**: 78 client sites hand-build `RawSpan`/`MutableRawSpan`/`OutputRawSpan`, each with its own safety comment (NativeAEA, NativeZip, Disk, and NativeAEA's segment pool accessor). One checked `bytes(at:count:)`, one `@unsafe mutableBytes`. | verified (count) | `RawStorage.swift:24–`, `NativeAEA/Extraction.swift:306–329`, `ZipDecoder.swift:154–495` [BC A4, UO] |
| 20 | **Documentation to fix**: `Bytes/OPTIMIZATION.md` says SE-0496 `@inline(always)` shipped in Swift 6.4; the proposal says 6.3 (documentation fix). Stale links in Disk docs (`Extraction.swift:104–105,132`); MQTT's and SocketStream's READMEs describe APIs that moved (report only: AGENTS.md leaves READMEs to the user). | verified | [EC, AR 1.3, PR A13] |

---

## Bytes core and BytesAsync

Scope: `Bytes`, `BytesAsync`, `BytesBase64`, `BytesFoundation`, `BytesMacros`, `CBytesNEON`. Source: BC, plus UO for
`unsafe` in Bytes and BytesAsync.

### API

- **Narrow access by usage** [M, verified census] (BC A1). Types named by nothing outside Bytes: `BitBuffer` (22 uses inside
  BytesCompression/BytesCrypto), `BitWriter`, `HuffmanTable`, `LentBytes`/`LentMutableBytes`, `LentMutableSpan` (no user anywhere),
  the four async adapters (`AsyncByteTransform`, `SynchronousTransform`, `ConcurrentTransform`, `OffloadedTransform`: tests and one
  benchmark), `InPlaceByteTransform`/`FusedPipeline` (`PipelineTests.swift:45` only), `RunningChecksum` (own tests only),
  `mapError`/`promoted(to:)` (one HTTP test), `ByteRepresentable` (234 lines, no client conformance), `Byte9`, `Byte11`–`Byte15`
  (tests only; `Byte10` at `CpioWalker.swift:150`, `Byte5`, `Byte7` have users). Make them `package`; delete the ones with no user
  (AGENTS.md: no stability shims). Types `then(_:)` returns must stay public. Check `Tools/calls --callee 'Bytes'` on BytesCompression
  after (`@usableFromInline package` plumbing needs a compile check per type).
- **`ByteMatches`: full-lane representation, an initializer from `SIMDMask<SIMD16<Int8>>`, and `matching(lessThan:)`/
  `matching(atLeast:)`** [M, verified code] (BC A2). Today it is high-bit-only, so it cannot be inverted and every consumer
  re-spreads the bit (`ByteBlock.swift:86–91`, `sshr`). HTTPBytes keeps a private copy of the conversion
  (`Method.swift:131–134`, used six times at `95–124`), and `matching(in:)` (`ASCII.swift:115`) does the same internally. Pairs with
  performance item P1 below.
- **Scoped and owned permits** [M, verified code] (BC A3). `AsyncLimiter.withPermit(_:)` (`nonisolated(nonsending)`, typed throws);
  `AsyncIndexPool.acquire() -> Lease` (`~Copyable`, `consuming func release()`, `deinit` releases); `close()` with an optional
  result so NativeAEA's `SegmentBufferPool` (`NativeAEA/Buffers.swift:23`) shrinks to its counters. Places: Disk `Writer.swift:577–578,
  698–699, 706–707, 727–728, 752–753` (the same `acquire(); defer { release() }` pair), manual pairs `:772/:807`,
  `Planner.swift:473/507/580`; NativeAEA `BlockStream.swift:308–356` (five exits). AGENTS.md records a leaked reference that trapped
  a semaphore. Perf neutral if `@frozen`/`@inlinable` stays: check with the `Tools/calls` recipe.
- **`RawStorage` span accessors** [M, verified count] (BC A4; also UO's N sites and AR). `bytes(at:count:) -> RawSpan`
  (`@_lifetime(borrow self)`, one `precondition`), `@unsafe mutableBytes(at:count:)`; keep `base` for syscalls. Client sites:
  NativeAEA `Extraction.swift:306–329,418` and `SegmentStream.swift:291–343`, NativeZip `ZipDecoder.swift:154–495`, Disk
  `FileWriter.swift` (11 `.base`/`.pointer` uses). Same idea one level up: a scoped accessor on NativeAEA's pool,
  `pool.withSegment(buffer, range) { span in … }`, or span parameters on the sinks (`entry`, `data`, `metadata`), moves about 55
  `unsafe RawSpan(_unsafeStart:…)` constructions into one place (UO; a span is the same two registers as pointer plus count, not
  probed in situ). Codegen of the accessor needs a probe (expected one compare).
- **Helpers clients reimplement** [M, verified] (BC A5):

  | Reimplemented | Where | Use or add |
  |---|---|---|
  | checked or unchecked "byte at offset", 8 copies | `HTTP1/HeadScanner.swift:302`, `StructuredFieldScan.swift:19`, `FieldGrammar.swift:32`, `ASN1DER.swift:144`, `DeflateCompressor.swift:519`, `ZstdMatchFinder.swift:64` | stdlib `RawSpan.subscript(unchecked:)` (`@unsafe`) and `RawSpan[byteOffset:]` |
  | byte-by-byte equality | `X509Certificate.swift:161` | `RawSpan.bytesEqual(_:)` (`ByteScan.swift:264`, 16 bytes a step) |
  | span to `[UInt8]` a byte at a time | `HTTPBytesHTTPTypes/Conversions.swift:71–78` (per name and value) | `[UInt8](copying:)` (`Buffers.swift:242`, a `memcpy`) |
  | `String(decoding: (0..<n).map { load… })` | `FieldName.swift:69`, `Method.swift:60` | add `String(copying: RawSpan)` beside `String(utf8Capacity:)` |
  | hand-rolled pattern search | `DER.swift:238–250` | `RawSpan.firstByteOffset(of: Byte11(ascii: "-----BEGIN "))`; clarity, not speed |
  | last-partial-block mask | `HeadScanner.swift:112–124,424–433` | one client: add `byteBlockMask` only if a second appears |

  Do the `String`, `bytesEqual`, and `copying:` ones first: they remove per-byte loops from allocation paths.
- **Sync and async spellings that collide** [L–M] (BC A6). Rename `RawSpan.withLentBytes` (async, `BytesAsync/Lending.swift:15`) so Disk
  can delete `withUnsafeBytesAsync` (`Writer.swift:434–445`). For `ByteBuffer.fill`/`receive` (`Buffers.swift:453`,
  `BytesAsync/Buffers.swift:22`), a non-closure `freeSpace() -> OutputRawSpan` plus `commit(_:)` removes the ambiguity and about 20
  duplicated lines; needs a prototype (a dropped span would silently discard what was written).
- **One ring implementation** [L] (BC A9, P4; EC 6.1; AR 3.5; UO). Three rings: `WaiterQueue` (`Waiting.swift:73`, `[Element?]`, `%`),
  `AsyncQueue.swift:20–60` (`%`), Disk `JobQueue.swift` (uninitialized pointer ring). One internal power-of-two `Ring` (mask, not `%`),
  or `UniqueArray<Slot?>` (UO: +1 compare). A few cycles per wait at one wait per file: probably invisible; do after the permits.
  swift-collections' `UniqueDeque`/`RigidDeque` would replace all three, but BC's verdict is that about 60 lines do not justify a dependency.
- **Macros emit `@inline(__always)`, not `@inline(always)`** [L–M, needs measuring] (BC A8). `BinaryRecordMacro.swift:80,152`,
  `BitFieldsMacro.swift:120,174` predate AGENTS.md's lesson (the hint was declined once a loop grew). Measure on ZipRecords,
  AEARecords, XAR instruction counts; large records called from many places grow code.
- **Small cleanups** [L] (BC A7). Delete the deprecated `append(_:)` alias (`BytesFoundation/Data.swift:33`) and the empty untracked
  `Experiments/Base64/` directory; `readUTF8(byteCount:)` (`Sections.swift:439`) would sort as `read(utf8ByteCount:)`; a separate
  cancellation error for BytesAsync's entry points (`BytesError.cancelled`, `BytesReader.swift:31`, is exhaustive noise for every
  reader); `skip(bitCount:)`/`peek(bitCount:)` (`BytesReader.swift:458,814`) use two signed compares where one unsigned would do.

### Performance

- **`matching(_:)` as one `cmeq`** [H, verified instruction counts] (BC P1). Table: `containsByte` step 14 to 11, `firstByteOffset` step
  16 to 13, one 64-byte `byteBlock.mask` 38 to 25, `matching(0x0A)|matching(0x3A)|matching(0x0D)` on a block 64 to 43; the documented
  reason for SWAR (scalar `.==` overloads compile lane by lane on 6.4) does not apply to comparing two vectors. Keep `nonASCII` working
  and `nibbleMask`'s varied-byte tests (`0x70`). Consumers: MQTT topic checks (`Basics.swift:487–494`), anything building `ByteBlock`
  masks. Cycles unknown (short scans are branch-bound): benchmark `ByteBlock` masks and the MQTT topic row, interleaved.
- **Scan-loop overhead** [M, verified counts] (BC P2). Unchecked loads (`unsafeLoadUnaligned(fromUncheckedByteOffset:)`,
  `offset &+= 16` against a precomputed `last`): 9 instructions per 16 bytes against 15; for 64 bytes and up, a main loop over
  `ByteBlock` (24 instructions per 64 against 6 per 16 before tuning). Short scans (under 32 bytes, the common case) will not move.
  Add a test whose input ends exactly at the span's end.
- **Typed block views instead of offset loads** [M, verified counts] (UO P2): a 64-byte loop of four `SIMD16<UInt8>` loads is 9
  instructions unchecked, 33 with safe loads at `o+16k`, 12 with a shrinking span, 8 with `Span<InlineArray<64, UInt8>>(viewing:)`
  (setup about 20 instructions, so check Adler32 and CRC at 16–64 bytes). Candidates: `Adler32` (14 sites), `Shuffle`/`GroupShuffle`,
  `Hexadecimal`, `ChaCha20Poly1305`.
- **`AsyncByteTransform.transform(_:appending:)` zero-fills every round** [L] (BC P3, `AsyncByteTransform.swift:55,75`): a memset against
  codec speed (about 3% for a 1 GB/s decoder), and no client uses the type: do the narrowing first.
- **`WaiterQueue`/`AsyncQueue` `%` per operation** [L, needs measuring] (BC P4): not measurable at one wait per file.
- **Nothing to fix in the library's own non-inlined code** (BC P5): `Tools/calls` over `Bytes.o` shows only `description` getters,
  array growth, and `RawStorage.init` calling the runtime; no `swift_once`, generic metadata, or `swift_allocObject` in a hot function.
  Codegen risks live in client specializations.

### Library and language callouts

- **Available now and unused:** `RawSpan.subscript(unchecked:)`, `RawSpan.byteOffsets(of:)` (no use found; recovers where a
  returned slice sits in its reader's span: `LocatedBytesError` offsets, zip data offsets), `extracting(first:/last:/droppingFirst:/
  droppingLast:)`, byte-ordered `load`/`storeBytes`/`append(_:as:_:)`, `UniqueArray` for the rings and `AsyncIndexPool.free`,
  `Mutex.withLockIfAvailable`. `Task.immediate` (running worker 0 in the calling task in `ParallelCodecs.swift`: changes the
  executor the file deliberately avoids; needs measuring). See "Available now".
- **`RelaxedCounters` on `UniqueArray<Atomic<Int>>`** [L, verified] (BC; EC 6.1; UO P6). `final class … : Sendable { let storage:
  UniqueArray<Atomic<Int>> }` compiles on 6.4.4 with no `@unchecked` (verified on 6.4.4), replacing the `ManagedBuffer` subclass and
  `unsafeDowncast` (`Counting.swift:83–135`). Cost: one more allocation and one more load per access (class to array to element);
  the compare is the same single unsigned one. Check the zero-malloc gate and `Tools/calls`. (swift-collections' `RigidArray` has the
  single-allocation layout.)
- **Not available (6.4.4):** `@lifetime` without the underscore; `Array(copying: Span)`.
- **Packages** (the repository's rule: no dependencies in the libraries): swift-collections (`UniqueDeque`, `TrailingArray`) not worth a
  dependency for about 60 lines; swift-async-algorithms `AsyncChannel` allocates per send (the gates are zero-malloc); swift-atomics,
  swift-system, swift-algorithms, swift-numerics: nothing maps.
- **Checked and not proposed (do not re-check):** `read(byteCount:)` folds after its own check (`BytesReader.swift:959`);
  `ByteBuffer.receive`'s plain `do/catch` shows no `swift_allocError`; `Byte2…Byte16` as one `Byte<let N>` (each width has its own
  `Integer` type; an integer generic parameter cannot select an associated type); `forEachRecord` as an iterator (`~Escapable`
  elements); `AsyncChannel` for `AsyncHandoff`; a generic `Data`-style API in BytesFoundation (Foundation has `Data.bytes/span/mutableSpan`,
  but no copy-from-`RawSpan` forms, so the two helpers stay). Documentation: only 11 public symbols lack a doc comment, all synthesized
  except `AsyncHandoff.init()`.

---

## Codecs: BytesCompression and BytesCrypto

Source: CD, plus UC for `unsafe` in BytesCompression. CD's object-file checks used `Bytes/.build/release/BytesCompression.o` from
2026-11-22 23:41 (before the Zstd encoder): they say nothing about `ZstdEncoder*` and may lag the working tree (which has uncommitted
Zstd encoder edits).

### API

- **Symmetric `Compressor`/`CompressionFormat`** [H, verified code] (CD A1). Decoders have `Decompressor`/`DecompressionFormat`
  (`Decompressor.swift:10,94`); encoders have nothing, and `compressAll` returns `Void` for Deflate/Brotli/Zstd/Parallel*
  (`DeflateEncoder.swift:99`, `BrotliEncoder.swift:83`, `ZstdEncoder.swift:230`), `Int` for LZFSE/LZVN (`LZFSEEncoder.swift:64`,
  `LZVNEncoder.swift:72`), and `LZBitmapEncoder` calls it `compress(_:into:)` (`:58`). Proposal: `enum CompressionFormat { deflate(DeflateFormat,
  level:), brotli(quality:, windowBits:), zstd(…), lzfse(parse:), lzvn(parse:), lzbitmap }`, `struct Compressor: ~Copyable,
  ResettableByteTransform` with `compressAll(_:into:) -> Int` for every format, `maximumCompressedSize(forByteCount:format:)`, streaming
  `compress` for the three streamable formats, the same state-on-first-use rule as `Decompressor` (zero mallocs after first use). Deletes
  about 100 lines of client switches and Disk's by-hand "stored when it doesn't shrink" fallback (`Decmpfs.swift:198–216`); the
  `[UInt8]` convenience gets written once. Rename `LZBitmapEncoder.compress` to `compressAll`. Low risk (one `switch`, measured free on
  the decode side).
- **Limits and parameters on `Decompressor`** [H, verified code] (CD A2). `DecompressionFormat.zstd` carries nothing, though
  `ZstdDecoder.maximumWindowSize` exists (`:74`) and a larger window throws `insufficientCapacity` (`:318`): HTTPBytes keeps its own
  `ZstdDecoder?` beside `Decompressor` (`ContentCoding.swift:68,74,92`) for RFC 9659's 8 MB cap. LZMA/xz have `maximumDictionarySize`
  but `Decompressor` makes the 256 MB default (`Decompressor.swift:187–190`). Output caps exist in three places: HTTP
  `maximumDecodedByteCount` (`ContentCoding.swift:152,173,224`), NativeZip `outputLimit` (`ZipDecoder.swift:58,411,440`), NativeAEA's
  exact `decodedSize`. `DecompressionLimits { maximumWindowSize, maximumDictionarySize, maximumOutput, maximumRatio }` (shape
  reference: swift-nio-extras `NIOHTTPDecompression.DecompressionLimit`), enforced per call (one `min` on the output capacity), with
  a distinct "limit" error (next item).
- **`…All` reuse semantics differ** [H, verified code] (CD A4): see summary 2. `Decompressor.decompressAll` papers over it with
  `reset()` per format (`:343–361`). Every `…All` resets first; drop the precondition; `Allocations:*` gates stay 0.
- **gzip: multi-member, header fields, auto-detect** [M, verified code] (CD A5). The decoder parses name/comment/extra (`gzipName`,
  `gzipComment` stages, `DeflateDecoder.swift:396`) and discards them; the encoder header has no mtime or name (`Deflate.swift:43–63`).
  Loop over members as `gzread` does; add `DeflateFormat.zlibOrGzip` (zlib's `inflateInit2(windowBits+32)`), which HTTPBytes
  implements by sniffing two bytes (`ContentCoding.swift:109–118`). The parallel decoder and `decompressAll`'s consumed count need a
  rule (take all members, return the total).
- **One input-retention contract for streaming decoders** [M, needs measuring for (a)] (CD A3). Zstd keeps a partial header, block, or
  checksum and consumes everything (`ZstdDecoder.swift:200–224`); Deflate (`:168–173`), Brotli, bzip2, LZMA (at most 20 B) and xz (at most
  65,542 B) stop short and need the tail passed again. HTTPBytes keeps a 132 KiB carry buffer for it (`ContentCoding.swift:165,257–300`).
  Prefer (b): a generic `CarryingTransform<T: ByteTransform>` (usable by `Pipeline`), costing the codecs nothing; (a) makes every
  decoder keep its partial unit and needs the "Inflate streaming 4 KB / 64 KB" rows.
- **Error vocabulary** [M] (CD A7; BC A7). One 7-case `BytesError` serves every codec: `insufficientCapacity` means "output full" and
  "window over your limit" (HTTP guesses by testing `output.freeCapacity == 0`, `ContentCoding.swift:~124–128`); `mismatch` is checksum,
  size, and stored-block complement; `invalidValue` is corruption and unsupported features (zstd dictionary, xz BCJ,
  `XZFormat.swift:199–200`). Add `limitExceeded`, `checksumMismatch`, `unsupported(feature)`, `corrupt`, `truncated`, and
  `LocatedBytesError` offsets (`stream.bitOffset`). Breaking for exhaustive switches (allowed).
- **Format detection next to the formats** [L] (CD A6): `DecompressionFormat(detecting:)` (gzip `1F 8B`, zlib CMF/FLG, zstd, xz, bzip2
  `BZh1–9`, LZ4 frame, `bvx*`/`bv41`) and `LZMAProperties(zipHeader:)`; today NativeAEA maps its byte (`SegmentCodec.swift:15–29`),
  NativeZip parses the 9-byte LZMA header (`ZipDecoder.swift:394–413`), HTTP sniffs.
- **Consistency items** [L] (CD A8): `decompressAll(_:decodedSize:into:)` on BZip2/LZBitmap/LZRAVEN against `(_:into:decodedSize:)` on
  `Decompressor`; `DeflateEncoder.maximumCompressedSize(forByteCount:format:)` ignores `format` (`:83–85`); clamp versus precondition
  for levels (`DeflateEncoder.swift:56`, `BrotliEncoder.swift:51`, `ZstdEncoder.swift:53–56`; HTTP's docs say Brotli "0–11" but 10–11
  become 9); `ParallelBrotliEncoder` has no streaming `compress`; `Decompressor` keeps three DEFLATE decoders (160 KB window plus
  tables each, `:107–109`): a `reset(format:)` would let one serve all (needs measuring); `[UInt8]` convenience for `Decompressor`/
  `Compressor`.
- **Access control by usage** [L–M] (CD A9; with the BC list in the summary). Also used only by BytesAsync (so `package`):
  `ParallelBrotliEncoder`, `ParallelDeflateDecoder`. Crypto primitives (`AESGCM`, `ChaCha20Poly1305`, `SHA384`, `SHA512`, `P384`,
  `X509*`, `TLS*`): not narrowed (the module's point).
- **DocC catalogs for BytesCompression and BytesCrypto** [M] (CD A10): none exist, so the many ``links`` are unchecked by AGENTS.md's
  check (Bytes only). A topics page and articles ("Choosing a codec", "Streaming and limits", "Reusing encoders"), and extend the
  `docc convert --analyze` command to both targets. Same gap for Disk, NativeZip, NativeAEA (AR 1.3).
- **BytesCrypto** (CD A11):
  - **AEAD protocol** [L]: `AESGCM` and `ChaCha20Poly1305` share the seal/open shape; TLS (`TLSRecord.swift:38–60`) and HPKE
    (`HPKE.swift:46–49`) each hand-write the same two-case enum. A public `AEAD` protocol plus one internal enum.
  - **X.509 chain validator** [M]: `isSigned(by:)` (`X509Certificate.swift:~790`) checks only the signature; NativeAEA rewrote names,
    validity, CA, key usage, path length, and root trust in `AEASignature.swift:142–270`. `X509Chain.validate(leaf:intermediates:
    trusting:at:purpose:)` (RFC 5280 §6 subset) and `matches(hostname:)`; shape reference: swift-certificates (`Verifier`, `RFC5280Policy`,
    `ServerIdentityPolicy`). No name constraints, no revocation. NativeAEA keeps its Apple policy.
  - **Missing primitives** [L unless a TLS client is planned]: X25519 (HPKE has only KEM 0x0010, `HPKE.swift:42`), Ed25519 (OID at
    `ASN1DER.swift:351`, so Ed25519 certificates cannot be verified), RSA-PSS (`ASN1DER.swift:349`, `RSA.swift:29`), ECDSA signing, SHA-3.
    X25519 and RSA-PSS verify are small. fiat-crypto (C, MIT) is a port reference and test-vector source.
  - **Secret hygiene** [L–M]: only scrypt wipes (`Scrypt.swift:145–148`, `memset_s`). Verified: a `~Copyable` struct's `deinit` cannot
    mutate its own stored properties on 6.4.4 ("'self' is immutable"), but a `~Copyable` struct holding a heap pointer can wipe it
    (`RawStorage` is that shape). A heap-backed `SecretBytes: ~Copyable` taken `borrowing` by the AEADs; registers and stack copies
    remain. SE-0544 (mutate or consume in `deinit`, Accepted) would let the struct do it directly.
  - **Fixed-size key serializers** [L]: `x963Representation`, `derRepresentation`, `compressedRepresentation` return `[UInt8]`
    (`NISTCurves.swift:~66–80`); `InlineArray<65, UInt8>` variants avoid an allocation per handshake, if handshakes become hot.

### Performance

- **Zstd one-shot straight into the output** [M, recorded; needs measuring]: see summary 13. Point the block writer at
  `output.withFreeCapacity` when `freeCapacity >= blockSize + header + margin`, staging only near the end. The byte-for-byte-equals-libzstd
  tests cover regressions. Compressed blocks save a copy of about 30% of the input (about 0.3% at level 3).
- **Brotli ratio** [M, recorded; high cost] (CD P2): `BrotliEncoder.swift:982` writes one block type per category, NPOSTFIX 0, NDIRECT 0,
  context mode LSB6, one literal tree. q9 output is 7% larger than Google's, q5 3–6%, q1 xml +26% (RESULTS.md "Brotli encode"); the encoder
  clamps quality to 1–9, so `br -11` precompression is unavailable. Order: literal context modeling, block splitting at q6+, then q10/q11's
  optimal parse. q9 is 1.6x faster than Google's, so there is time budget. The decoder already supports all of it.
- **Zstandard** (CD P3): decoder dictionaries first [M]: `ZstdDecoder` rejects a nonzero dictionary ID (`:16,144,315`); older window
  content is already a "dictionary" segment (`history.dictionaryStart/End`, `:342–343`); this is HTTP's `dcz` (RFC 9842; `ContentCoding.swift:21`
  lists `dcb` as unsupported) and Brotli's `dcb` prefix dictionary. Encoder levels 5+ (lazy/btlazy/btopt, row match finder) [L, large port].
- **Lazy, unzeroed streaming windows** [L–M, needs measuring] (CD P4): `BrotliDecoder.init` zero-fills 512 KB (`:37–40`), `DeflateDecoder.init`
  160 KB (`:65–68`, up to three per `Decompressor`), `DeflateEncoder` 288 KB (`:59`), none used by the `…All` forms; NativeAEA's comment
  (`SegmentCodec.swift:6–8`) says why it matters with 32 workers. Allocate on first streaming call (Zstd already does).
- **DEFLATE encoder** [L–M] (CD P5): the L1 5.5–14% gap to libdeflate (RESULTS.md 1586–1592, 2026-11-15) is probably stale: the working tree
  has the `fastEnd` fold (`DeflateCompressor.swift:575–637`). Re-run `Deflate 1` rows against libdeflate first. Levels 10–12 are documented
  (`Deflate.swift:~47`) but clamped to 9.
- **SHA-256** [L–M] (CD P6): 1 MB 400 µs against CryptoKit 337 (2,065 K against 1,955 K instructions; SHA-1 at parity). Verified in the
  object: `SHA256.compressWithInstructions` is one 126-instruction loop per block of which about 12 compare/branch instructions are the
  bounds checks on four 16-byte block loads (`SHA.swift:~370–375`); no table copy. Hoist the four bounds into one precondition and use
  unchecked loads (expect −5–10% instructions); then `Tools/cpu-probe` and `Tools/counters` for the latency chain.
- **AES counter mode and GCM with 12 blocks in flight** [M, needs a probe first] (CD P7): RESULTS "Not done" says the eight-block kernel is
  at its chain bound and about 1.5x remains; AES-GCM seal 1 MB is the one place CryptoKit wins (116 against 109 µs on M3). Probe
  `Tools/probe insn aese aesmc` for the M3's fused rate, then a 12-block CTR kernel; watch spills with `Tools/loops --forbid`.
- **Zstd Huffman weights** [L] (CD P8): the module's only `swift_beginAccess` is `ZstdHuffman.decodeWeights` (`ZstdEntropy.swift:591–646`),
  from an `@inline(__always)` nested function mutating a captured `bits`. A struct with `mutating` methods; at most 1–2% on 1 KB bodies.
- **Brotli decode of short inputs** [L–M, needs a profile] (CD P9): 1.6 KB q5 4.04 µs against Google 3.08 µs (31% behind; setup in
  `readContextMap`'s two `bzero`s, tree building, the 64 KB arena); HTTP responses are this size.
- **Feature and parallelism gaps** [L] (CD P10): no parallel Brotli/zstd/xz/bzip2 decoders (bzip2's is the only cheap one, by its 48-bit block
  magic); xz decodes only LZMA2 (no BCJ/ARM64/delta filters); no LZ4 frame format (`LZ4Decoder.swift:3–4`); no LZMA/xz, bzip2, or LZ4 encoders.
  No client asks.

### Library and language callouts

- **`Builtin.int_aarch64_*` can replace the C shim modules** [M, verified]. CD compiled `aese`, `aesmc`, `sha256h`, `sha512h`, `tbl1`/`tbl4`,
  `eor3`, `pmull64` (and the `pmull2` form), `udot` through `SIMD16<UInt8>._storage._value` and got exactly those instructions
  (Bytes already does it for CRC, `CRC32.swift:129`, and prefetch). It would replace `CBytesCrypto` (195-line header), `CBytesCRC` (67 lines),
  and the intrinsic wrappers in `CBytesNEON` (201 lines; not its `asm("" : "+w"(v))` barriers, which Builtin cannot express), and removes the
  `-Xcc -DBYTES_PORTABLE` plumbing every client repeats. Risk: `BuiltinModule` is experimental. Verify identical object code per kernel
  with `Tools/loops`/`Tools/calls` before deleting each C function; start with CBytesCrypto and CBytesCRC. A build simplification, not
  a speed change.
- **`~Copyable` secrets:** see A11 secret hygiene. `HashFunction` cannot be `~Copyable` (HMAC's pad trick copies a hash before finalizing).
- **`InlineArray`:** `==`/`Hashable` do not typecheck on 6.4.4 but do on the PR toolchain (SE-0543); keep `constantTimeEquals` for tags and
  MACs. The AGENTS.md "borrowing copy" trap was checked in `SHA256.compressWithInstructions` and Brotli's tables: no copy; no `memcpy` of a
  table in any hot function.
- **Integer generic parameters** are in use (`Residue<let limbs, M>`, `HashBuffer<let size>`, `RSALimbs.read<let n>`); a protocol requirement
  sizing an `InlineArray` is not expressible (error "cannot pass type 'T.n' as a value for generic value 'count'", both toolchains).
  Associated types that are concrete `InlineArray`s per conformer work (`HashFunction.Digest`), low value.
- **Span family:** present: `OutputSpan`, `OutputRawSpan`, `extracting`, `unsafeLoad`, `UTF8Span`, SE-0496. Absent on both toolchains: `Span.firstIndex(of:)`,
  `Span.elementsEqual`, `Span.mismatch`, `MutableSpan.sort()`; so Bytes' `commonPrefixLength`, `firstByteOffset`, and sorts stay.
  SocketStream builds with the PR toolchain, so code reachable from it keeps to `UniqueArray`.
- **SIMD:** scalar comparisons fixed in 6.5-dev; `pointwiseMin`/`pointwiseMax` are free functions; wide `Builtin.Int384` rows lost 10–16% (RESULTS-ecc.md): do not retry.
- **Packages:** swift-crypto 5 (span APIs: use the in-place `seal`/`open` as the benchmark reference; `SymmetricKey` zeroization for hygiene),
  swift-certificates/swift-asn1 (shape for the chain validator; differential oracle on the 151 system roots), swift-nio-extras (limit shape),
  libz/libzstd/libdeflate API shapes. swift-collections, swift-numerics: no concrete place.
- **Checked and not proposed:** DEFLATE decode (0.83–0.95x libdeflate's instructions, equal time within 4–6%, latency-bound); Zstd encoder's +7.5–11%
  instructions at equal cycles; the `_stdlib_isOSVersionAtLeast…` calls (only guard `_swift_willThrowTypedImpl` on throw paths); Brotli's
  `decodeCommandsFast` calls; parallel DEFLATE speculation (fixed 2026-11-20).

---

## Protocols: HTTPBytes, MQTT, SocketStream

Source: PR. HTTPBytes' Benchmarks package and RESULTS files supply the recorded numbers.

### API

- **No message or connection layer** [H for HTTP/1, M for HTTP/2] (PR A1). The pieces are individually strong (head parser, `HTTP1Framing`, `HTTPBodyDecoder`,
  `HTTP1HeadWriter`, HPACK/QPACK, frames) but a caller writes the head loop, `observe` per field, body-decoder choice, `HTTP1Error` to
  response mapping, keep-alive, pipelining, 100-continue, upgrade, and the writer; HTTP/2 and 3 have no stream table, flow control, or
  SETTINGS/PING/GOAWAY handling. Sans-IO state machines in the codecs' style (spans in, events out, no allocations): HTTP/1 server and
  client connections (about an afternoon of glue plus the llhttp/Garden suites), then `HTTP2Connection`, then HTTP/3 request streams;
  drivers belong in SocketStream or an adapter package.
- **Protocol-neutral request and response heads; complete the swift-http-types boundary** [H] (PR A2). An HTTP/1 request arrives as events,
  an HTTP/2/3 one as a store beginning with pseudo-fields (`HTTPFieldName.pseudoPath` …): a handler branches on protocol. `HTTPRequestHead`/
  `HTTPResponseHead` (`~Escapable` views for HTTP/1, owned after H2/H3 decode) and `HTTPRequest`/`HTTPResponse` conversions
  (`HTTPBytesHTTPTypes/Conversions.swift:1–79`; its doc at `:56` says "build the request or response from those yourself"). Conversion cost
  [L, needs measuring]: `HTTPFieldStore.init(_ fields:)` (`:43`) makes two `Array(...utf8)` per field, `HTTPFields.init(_ store:)` builds values
  byte by byte (`:71`); `[UInt8](copying:)` and `String(copying: UTF8Span)` are one `memcpy`. No conversion benchmark exists.
- **`HTTPFieldStore` is append-only** [M] (PR A15, `FieldStore.swift`): add `set`, `remove(name)`, `values(of:)`, typed accessors
  (`contentLength`, `contentType`), and a `~Escapable` field iterator instead of `field(at:)` (36 instructions a call, PR P12).
- **Frame writers do not compose with encoders** [M] (PR A3): `writeHeaders(_ fieldBlock:)` (`HTTP2/FrameParser.swift:287`) copies behind a 9-byte
  header, there is no CONTINUATION splitter, `writeSettings` takes an array (`:306`; H3 `Frames.swift:420`); three writer abstractions
  (`AlignedBytesWriter`, `BigEndianBytesWriter`, `OutputRawSpan`). `HTTP2FrameWriter.writeFieldBlock(_:using:stream:endStream:maxFrameSize:to:)`
  that reserves 9 bytes, encodes in place, patches the header, and splits.
- **Iterators instead of closures** [M] (PR A6). `HTTPList.forEachElement` (`FieldValues.swift:8`, byte at a time) duplicates `HTTPListElements`
  (vector scans); `HTTP3SettingsPayload.forEach` against `HTTP2SettingsPayload.setting(at:)`; MQTT `MQTTProperties.forEach` (`Properties.swift:410`),
  `MQTTSubscriptions.forEach` (`Packets.swift:595`), `MQTTTopicFilters.forEach` (`:698`); closures cannot `break`. Pull iterators in the
  `HTTPListElements.next()` shape (`@_lifetime(copy self)`); use `HTTPListElements` in `HTTP1Framing` (`Framing.swift:80,97,116`). `for in` over
  `~Escapable` elements is not possible (verified: `Iterable` requires `Escapable` `Element`); it works for settings pairs and
  `MQTTSubscribeAcknowledgement.reasonCodes`.
- **MQTT** (PR A7, A8, A9, P11):
  - Expose the properties' presence set (`Properties.swift:~262`) as `contains(_:)` plus typed accessors (`topicAlias`, `messageExpiryInterval`,
    `subscriptionIdentifier`, `responseTopic`) [M]: ceiling about 9% (358 against 392 µs/10k packets, recorded).
  - Topic filter validity and `matches(topicName:)` (pure functions over `UTF8Span`s; level offsets compiled at SUBSCRIBE; a `ByteBlock` mask of
    `/` positions) [M]; session pieces (packet identifiers, in-flight windows, topic aliases, keep-alive) belong with the connection layer [L].
  - Forwarding re-validates and re-encodes (`write(to:)` then `validate()`): a copy-the-body-slices path; encode is 513 instructions/packet
    (recorded), validation about 30 [L, needs measuring].
  - 800–1,000 instructions per PUBLISH (980 recorded; 793 without iterating properties): add CONNECT/SUBSCRIBE/ACK rows with allocation gates,
    then profile; parsing CONNECT's will and credentials on demand would shrink `MQTTPacket` from 153 bytes [L].
- **SocketStream is a transfer harness, not a connection layer** [M] (PR A12): extract `ByteBuffer` + optional pipeline + `TCPConnection` with
  `receive { (unread: RawSpan) throws -> Int }` driving any parser, and a write side on BytesAsync's `AsyncQueue`/`AsyncLimiter`; keep the harness
  as a client. A NIO adapter as a separate package: `NIOAsyncChannel` plus swift-nio main's `ByteBuffer.readableBytesSpan` lets the parsers run on
  NIO's bytes without a copy [L].
- **Errors, "need more", field types, UTF8Span** [L] (PR A4, A5, A10, A14): `HTTPPayloadError.status`, a `StaticString detail` on `HTTP2Error`/
  `HTTP3Error` written into GOAWAY (MQTT's `MQTTError` is the best of the three; `HTTP3Error.stream(code)` has no stream id); "need more" is spelled
  four ways (add MQTT-style `read(from:)` wrappers for the frame parsers, measure); `HPACKField`/`QPACKField` duplicate one core
  `HTTPDecodedField` and `HTTPFieldView` would gain a `hasValidValue` bit so `append` skips its rescan; `HTTP1RequestLine.targetText: UTF8Span`
  (ASCII proven by the parser) and `Content-Disposition` filenames.
- **Access control and documentation** [L] (PR A11, A13): 65 of 83 public HTTPBytes types are named nowhere in the benchmarks (HTTP1 15/19, HTTP2 17/22,
  HTTP3 17/20); narrow after a client exists. HTTPBytes has no README or DocC. MQTT's and SocketStream's `Package.swift` lack
  `InternalImportsByDefault`/`InferIsolatedConformances`/`ImmutableWeakCaptures` that HTTPBytes and Bytes use (MQTT's imports are already
  `public import`). Stale README text: see summary 20.

### Performance

- **`HTTPFieldStore.append`** [H, recorded; call counts verified] (PR P4): see summary 7. `appendUnchecked` (132 instructions) makes two out-of-line
  `Array.append(contentsOf:)` and two `_swift_isUniquelyReferenced_nonNull_native` calls, plus four growth paths; `append(_ field:)` (249 instructions)
  adds a 16-byte `containsByte` scan and a second `knownName` lookup (`:89–93`). One raw allocation for bytes and entries (`RawStorage`/`ByteBuffer`),
  one `reserve(forField:)` per field with the worst case, unchecked stores after, `knownNames` contiguous for the 16-lane scan, skip the rescan for fields
  carrying a validity bit. UO's alternative for tables owned by classes: `UniqueArray` (no uniqueness checks; +1–3 instructions per masked access).
  Profile the store row with `Tools/profile` first: the three calls are suspects, not a diagnosis.
- **`knownMethod` re-parse** [H, verified static] (PR P2): `HTTPMethod.init(_:)` is an 80-instruction function with a 16-instruction-a-byte scalar loop
  after a 16-byte `containsByte` test; the fast path (`RequestParser.swift:~118–135`) identifies `GET`, `PUT`, `POST`, `HEAD` from one word and discards
  it. Carry `HTTPMethod?` in `HTTP1RequestLine`; rewrite `init(_:)` as two overlapping masked 8-byte loads (about 12 instructions). Check the event enum
  does not grow as `MQTTPacket` did.
- **`HTTP1Framing.observe`** [H, needs measuring] (PR P3): out-of-line `HTTPFieldName.lookUp` per field (300–400 instructions a head if all names are
  looked up). Framing needs five names of distinct lengths (`host` 4, `expect` 6, `connection` 10, `content-length` 14, `transfer-encoding` 17): switch on
  `field.name.byteCount`, then 8-byte word compares OR `0x20`; about 85% of fields exit after one compare. Or cache `knownIndex` in the event
  (`FieldView.swift:15`). Estimated 30–40 of the 44 cycles a head.
- **Responses: lookahead.** Recorded gap (PR P1): responses 426 cycles against cursed-http 366 (top-1k 1,028 against 912), 14–17%, from mispredicts where long
  lines cross 64-byte blocks. PR proposed trying the lookahead design in a response-only scanner as unmeasured. Corrected: round 1's ring-of-masks and
  stop-mask trials (HTTPBytes/RESULTS.md) list no response columns, but round 2's skip-window trials did measure responses and found no gain. So a
  response-only scanner with a ring of masks remains an untried variant of an idea whose nearest relative did not help [L, an hour's experiment at most];
  the round-1 differential harness (old and new module, 1.6 M inputs) is the safety net.
- **Field-value parsers** [M, prototype first] (PR P6). Recorded: Content-Type 608, Cache-Control 1,100, Accept 2,180, Accept-Encoding 1,350, Host 378,
  Cookie 1,630 instructions a value. The moves from scalar loops to vector scans cut those parsers' instructions 18–76% (HTTPBytes/RESULTS.md, "round 2, dates
  and field values"), so this is not a reversal. Findings: `FieldGrammar.tokenEnd` (`FieldGrammar.swift:45`) specialized is 172 static instructions (6 `tbl`,
  6 `adrp`, 9 `ldr` for what is usually one block; about 25–40 executed), called at least three times per list element, for tokens that are mostly 2–10
  bytes (`text`, `gzip`, `br`, `max-age`, `utf-8`). One option to measure, not to adopt: a hybrid that tests the first few bytes with the scalar
  `isToken` (3 instructions a byte; break-even about 8 bytes) and falls to the vector scan beyond. Surer items: `HTTPMediaType` records the `charset`
  range while validating instead of scanning again (`MediaType.swift:30,48`); `HTTPListElements.next` (247) and `HTTPParameters.next` (251) are not inlined;
  a one-block structural mask per value up to 64 bytes (`ByteBlock`, classify `, ; = " SP TAB`, walk with ctz), shared by list, parameters, media type,
  cache control, accept lists (plausibly 2–4x on short values, unproven). A server reads only a few of these per request, so weigh against `append` and
  `observe`, which touch every field.
- **`HTTPToken.equalsIgnoringCase(StaticString)`** [L, needs measuring] (PR P7): a byte loop at every call site (`FieldValues.swift:25`); for literals of 1–16
  bytes, length check then one or two word compares OR `0x2020…`.
- **Frames, head writing, framing, and conversions have no benchmark or allocation gate** [M, verified by grep] (PR P5). `HTTP2FrameParser.next` is one
  424-instruction function with a 14-case result enum returned through memory (the MQTT README measured that cost at 26%); `unpadded` is called out of
  line from three sites (`FrameParser.swift:243`, DATA at `:157`) even when PADDED is clear; seven throw sites each call `_stdlib_isOSVersionAtLeast…` and
  `_swift_willThrowTypedImpl` (cold). Add rows and `Allocations:` gates first (small DATA frames, HEADERS, SETTINGS/PING, frames written, a 12-field
  response head), then a header-only peek plus per-type `parseData` if they show it.
- **Writing responses** [L, needs a benchmark] (PR P8): `writeField` rescans names and values even for known names from `canonicalBytes`
  (`HeadWriter.swift:~60–90`); `writeFields` rebuilds a `HTTPFieldView` per field. Benchmark first (against NIOHTTP1's encoder).
- **Padded-input API for tiny heads** [L] (PR P9): 8–11 cycles (about 20%) on heads under 64 bytes, "not built"; `ByteBuffer` could guarantee 64 bytes of
  slack; only for clients sending such heads.
- **SocketStream** [L] (PR P10). Recorded: zero allocations per packet, 120 per transfer, `swift_task_switch` 85 to 55. Left: zero-copy encode is blocked
  upstream (`PThreadTaskExecutor` leased buffers `fatalError` at the pinned `bd74d56`; main has no change); `receiveProtected` copies every byte once (1.7–3.2%
  memmove, recorded), avoidable with an in-place TLS opener returning a span of the wire buffer; swiftlang/swift#91981 (split continuations) was merged
  2026-11-18, so a snapshot that has it could replace the 3 GB PR toolchain (whether one exists was not checked).
- **Smaller:** `HTTPFieldName.lookUp` stays out of line (4 addressor calls per lookup from another module): recorded as no cycle gain, not proposed.

### Library and language callouts

- Typed throws: every `throw` in these parsers compiles to a runtime OS-version query plus `_swift_willThrowTypedImpl` (7 sites in `HTTP2FrameParser.next`,
  4 in `HTTPParameters.next`); cold, but check whether raising the manifest's `.macOS(.v27)` minor removes it (needs one rebuild) (PR L4).
- `nonisolated(nonsending)` and `@concurrent` split for the connection layer; swift-nio `NIOAsyncChannel` + `readableBytesSpan` for an adapter package;
  swift-async-algorithms cannot carry views as `AsyncSequence` elements (Escapable and Copyable); `UniqueArray`/`RigidArray` for the store versus
  Bytes' own `RawStorage` (no new dependency); swift-http-types 1.8 stays at the edge (its `HTTPFields` allocates 3,669 mallocs per 401 requests,
  recorded); static files via `HTTPRangeSet.resolve` + Disk's `MappedFile` span + `TCPConnection.write(from:)` (no `sendfile` through
  swift-platform-executors); swift-nio-http3/quic 0.1 are comparators (EC).

---

## Archives: Disk, NativeZipArchive, NativeAEA

Source: AR, plus UO for `unsafe` in these packages. The app is next.

### Bug-class and correctness items

- **Double close in `Destination.init`:** summary 1. Probe (`probe-archives/deinit.swift`) prints "closing in init" then "deinit closes 3".
- **Quarantine failure on volumes without xattrs:** summary 4 (`Metadata.swift:445–450`, `Quarantine.apply`, called per file in the writers and per
  directory and link in the passes). Needs a test on exFAT and SMB.
- **mmap against read for the archive** [M, needs verifying first] (AR 1.1). NativeZip maps the archive (`ZipArchive.swift:167–173`; payloads read in
  place, `ZipContentSource.swift`); NativeAEA reads, for a stated reason (a file truncated while mapped becomes SIGBUS for the whole process:
  RESULTS 2026-11-22). The survey could not reproduce it: two probes (`sigbus2/3.swift`, truncating a mapped 8 MiB file, same process and cross-process)
  returned stale data on macOS 27, not SIGBUS. If the hazard is real, `clonefile(2)` of the archive beside staging and mapping the clone works (probe
  `sigbus.swift`; EXDEV or non-APFS falls back to the original). ARCHITECTURE should state the decision for ZIP either way. The app opens archives
  that may still be downloading.

### API

- **One extraction API for NativeZip and NativeAEA** [M–H, verified] (AR 1.2; summary 14):

  | | NativeZip | NativeAEA |
  |---|---|---|
  | identity | `url: URL` (`ZipArchive.swift:148,167`); the app does `URL(filePath: archive.string)` (`ZipAdapter.swift:24`) | `path: FilePath`, convenience `init(url:)` |
  | errors | untyped `throws`; `ZipError` has no disk case | `throws(AEAError)` with `.disk(DiskError)` |
  | result | `Void` (`ExtractionReport` dropped, `ZipArchive+Extraction.swift:131–133`) | `AEAStatistics` (a copy of most of `ExtractionReport`) |
  | options | `ZipExtractionOptions`: not `Sendable`; own `maxConcurrency`, `progress`; `stopOnFirstError` a parameter | `AEAExtractionOptions`: `Sendable`, embeds `ExtractionSettings` as `.disk` |
  | existing items | `OverwritePolicy {always, never, ask}` | `overwrite: Bool` |
  | Disk knobs | none reachable (`fileSystemWidth` set inside `ZipExtractor`, `:290–296`) | all via `.disk` |

  Proposal: NativeZip takes `var disk = ExtractionSettings()`; both return a common `ExtractionSummary` embedding Disk's `ExtractionReport`; both map Disk's
  `ExistingItemPolicy` (Zip keeps `.ask` as an extra case or closure); `ZipArchive(path: FilePath)` primary; typed `throws(ZipError)` with `.disk` and
  `init(_ error: DiskError)` as `AEAError` has (`AEAError.swift:62–77`), which also removes `ExtractionError<any Error>` and `DiskError.unwrapped`
  (AR 3.9). The app today catches `ZipError.incorrectPassword` and `DiskError.isCancellation` across three error types. Also make `ZipExtractionOptions`
  `Sendable` (`onEvent` `@Sendable`/`sending`, `.ask` `@Sendable`) [L]. A shared destination preset in Disk
  (`ZipArchive+Extraction.swift:262–280` and `AEAExtractionOptions.destination`, `NativeAEA/Extraction.swift:96–110`, are near-identical) [L].
- **`ExtractableArchive` protocol in Disk** [L–M] (AR 1.2): conformed to by `ZipArchive`, `AEAArchive`, `AppleArchiveFile`, `XIPArchive`; move `ArchiveKind` beside
  it so NativeAEA stops naming ZIP (`ArchiveKind.swift:6–8`); the app drops its four-case dispatch. One call per archive, so `any` boxing is off the hot path.
- **Wrong-key detection by string** [M, verified] (AR 1.2): add `AEAError.incorrectKey` (`.missingKey` exists), thrown by the root header and signature MACs on
  encrypted profiles, replacing `hasSuffix("(wrong key?)")`.
- **`ExtractionProgress` publishes neither phase nor rate** [M] (AR 1.3): an `Atomic<UInt8>` phase set at pass boundaries (`ExtractionPhase` exists) and the
  app's `Throughput` sampler moved down. The row could say "Linking files" for the `.xip`'s 2.6 s hard-link phase (26% of Xcode's wall time) instead of a bar
  at 100%; the CLIs print the same rate.
- **Raw integers where the SDK has types** [L] (AR 1.3, 3.1): `EntryMetadata.mode`, `Owner`, `flags` (`Metadata.swift:8–60`; masks at `Destination.swift`) against
  the macOS 27.3 SDK's `System` (`FileMode`, `FileFlags`, `UserID`, `GroupID`, `Stat` with `symlinkNoFollowAny`/`resolveBeneath`); Disk already does `public import System`.
  `System` lacks `openat` with `O_RESOLVE_BENEATH`/`O_NOFOLLOW_ANY`, `fsetxattr`, `fsetattrlist`, `linkat`, `renameatx_np`, `mkdirat`, so `Sys` stays; confirm the `Stat` flag
  set before replacing `fstatat` sites.
- **Smaller Disk items** [L] (AR 1.3): `MappedFile.init(_ descriptor:…) throws(Errno)` while everything else throws `DiskError` (`Files.swift:59,68`); `DiskError.system`'s
  free-form operation string (the app matches on it) wants a `DiskOperation` enum; `ExtractionError<PlanFailure>` makes every client switch twice (a `DiskErrorWrapping`
  protocol); `credentialRequirement(at:)` on `AEAArchive` and `needsPassword` on `ZipArchive` for the app's per-profile switch (`AppleArchiveAdapter.swift:20–70`);
  `Destination.expand(archive:into:)` (stage, extract, `publishUnwrapped`, discard) removes about 25 app lines; an `ExtractionSettings.priority` that `Extraction.run` applies; one
  message style across packages (`ZipError` capitalized sentences, Disk/AEA lowercase).
- **Documentation** [L–M] (AR 1.3): stale links verified: `Extraction.swift:132` (``run(into:source:options:_:)`` is `settings:`), `:104–105` (``Planner/hardLink(_:to:metadata:)`` is `(_:to:tag:)`),
  `NativeAEA/Extraction.swift:~207` (``AEAExtractionOptions/progress`` is `.disk.progress`); no DocC for Disk, NativeZip, or NativeAEA; NativeZipArchive has no README or ARCHITECTURE
  (the `ClaimKey`, `replaces` tags, and `SourceState.waitUntilWritten` live only in comments).
- **Public surface by usage** [L, no action] (AR 1.3): the app uses `Destination`, `DestinationOptions`, `Quarantine`, `ExtractionProgress`, `DiskError`, `ExtractionSettings`; the rest is
  format-author API, correct by the rule. No symbol graph was generated.

### Performance

- **Width formula** [H]: summary 6 (`Progress.swift:164`; M1 Max `hw.perflevel0.physicalcpu` is 8, so width 2, writers 8). Sweep 2, 3, 4, 6, 8, 12 with Disk's `Workers:` rows (several `--filter`s in one
  invocation); then a table or a self-tuning probe (time the first 200 creations at 2, 4, 6). Possible 1.3–1.7x on small files for machines under about 16 P cores.
- **Hard-link pass** [H]: summary 11. Group records by `target` (a counting pass over arena offsets), whole groups per lane, same-parent links adjacent; sweep the pass width apart from
  `fileSystemWidth` (the `--hard-link-threads` sweep was during the writes only, NativeAEA RESULTS:653); later, start links of finished targets during the tail (needs a completion bit).
  Up to about 1.2–1.5 s of Xcode's 9.9 s; correctness risk nil.
- **Spotlight on staging** [M, needs measuring] (AR P3): staging is `.NAME.partial-XXXXXX` (`Destination.swift:213`); AGENTS.md says to use `*.noindex` for benchmark output, and a
  `corespotlightd` core was recorded. Whether a dot prefix already keeps `mds` out is unverified. Try `.partial-XXXXXX.noindex` (the leftover sweep must match); sample `mds`,
  `mdworker_shared`, `corespotlightd` and wall time, three interleaved rounds; plausible 3–10% on all-core `.xip`/`.aea` runs.
- **Attachments applied by the writer** [M] (AR P4): extended attributes are applied after all writers (`deferredPass`, `PostPasses.swift:204–240`: `openat`, `fstat`, `fsetxattr` x n,
  `fsetattrlist`, `close`, behind a barrier); letting `file(...)` take the blobs up front cuts 10 calls to 7 on macOS-made zips (2,000 merged AppleDouble files: 84 ms in the pass, recorded) and
  removes the barrier; blobs need job-owned storage while the planner appends. Also drop `deferredPass`'s `fstat` (`:233–236`) by recording `UF_COMPRESSED` in a bitmap.
- **Smaller** [L]: symbolic-link pass opens each parent twice (4 calls a link; contiguous runs keeping the last parent open save 2 of 4, about 0.1 s on Xcode, AR P5); shared atomics and a global
  `Mutex` per file (`WriterCounters` six atomics on one line, `Extraction.swift:219–240`; `SourceState.written(_:)`, `ZipContentSource.swift:262`; per-writer slots and a `fetch_or` bitmap; check with
  `Tools/counters`, AR P6); quarantine costs 13–17% of small-file time (libquarantine's process-wide `qtn_proc_*` is private API, CLIs only, risky, AR P7); ZIP queues in archive order, so a big entry
  after 20,000 small ones starts last (a window of at least 4 MiB entries first, excluding entries with a replacement claim, AR P8; splitting one DEFLATE stream across cores remains open and is Bytes'
  work); a dedicated `TaskExecutor` for the writers isolates blocking syscalls from the app's UI work (responsiveness, not throughput; measure poll jitter, AR P9).
- **Not worth re-measuring** (AR P10): directories by descriptor, `clonefile` for duplicates, `F_NOCACHE`/`F_PREALLOCATE`, DispatchIO, hard links during the writes (all measured and rejected).

### Library and language callouts

- **`~Copyable` owning descriptor** [M, verified need] (AR 3.2): raw `Int32` with hand-closed state in `Destination.root` and `staging.parent` (`:178–181`), `FileOutput.descriptor`/`unfinished`/
  `abandon` (`Writer.swift:51–61,126–137`, 8 `-1` resets), `OutputFile`/`InputFile` deinit, `Planner`, `deferredPass`. `struct OwnedDescriptor: ~Copyable { init(adopting:), borrowing rawValue,
  consuming func close(), deinit closes }`. Check `Tools/calls` (rawValue inlines) and zero-malloc gates.
- **Planner arena** [L] (AR 3.5): `arena: [UInt8]` turned into a raw pointer with `withUnsafeBytes { $0.baseAddress! }` and kept alive by `withExtendedLifetime` (`PostPasses.swift:56–60`): `UniqueArray<UInt8>` or
  a doubling `RawStorage` gives a borrow-checked address.
- **Foundation in NativeZip** [L] (AR 3.8): replaceable now: CP437 by a 128-entry table (`ZipArchive.swift:508`), `currentDirectoryPath` (`ZipArchive+Extraction.swift:245`), `activeProcessorCount`
  (`DiskDefaults`); not replaceable: NFD of non-ASCII names (`:494`; the stdlib exposes only NFC code units).
- **swift-system:** retry-on-interrupt for the hand loops (`Decmpfs.swift:332–334`, `InputFile.swift:171,185`) [L]; `IORing` is Linux-only; `FileDescriptor` is `Copyable`.
- **swift-async-algorithms, swift-subprocess, swift-collections `Deque`/`Heap`:** no place (events are rare, tools shell out only in `BytesTestSupport/Files.swift:160`, `JobQueue` is purpose-built);
  an `AsyncSequence` view of progress could live in Disk without the package [L].
- **Executors:** `withTaskExecutorPreference`/`group.addTask(executorPreference:)` (Swift 6, in 6.4.4) for the writers (above); nothing in this survey needs an unreleased toolchain.

---

## The app: Nunarchiver

Source: AR. App-level findings, collected from the sections above and the app's own sources.

- **`discard()` is a serial, synchronous, uncancellable recursive delete** [M] (AR 1.5; `Destination.swift:359–362`, `TreeRemoval.swift:34–100`), called from the async `Expander.expand` on every failure and
  cancellation (`LiveArchiveExpander.swift`): cancelling an Xcode `.xip` near its end blocks a pool thread for about the extraction time (167,000 entries at about 70 µs is about 12 s) while the row says
  "Stopping". Rename staging to a second hidden name in its parent at once (`renameatx_np`, one atomic call), report "cancelled", delete in a detached task, and sweep leftovers at next launch; parallel removal
  is secondary (measured 10–15%); an `async` discard checking cancellation between directories. This changes the "nothing left on disk" guarantee `ExpanderTests` asserts, so the sweep needs a test.
- **Format dispatch and credentials** [L–M]: `OpenedArchive.swift:29–65` and `ArchiveKind.open` re-dispatch on a four-case enum (the protocol above removes it); the credential logic stays app-level.
  `AppleArchiveAdapter.swift:66` wrong-key string match (summary 5).
- **Progress**: the `isFinishing` and throughput logic (`ArchiveExpander.swift:71–80`, `Throughput.swift`, `LiveArchiveExpander.swift`) moves down to Disk with a published phase (Archives, API).
- **Responsiveness** [L]: blocking syscalls and compression share the cooperative pool with the app's timer and TCA effects; a dedicated executor, measured by poll jitter during Xcode's expansion.
- **Error text**: three packages' `String(describing:)` styles differ (above); the app post-processes.
- **Quarantine and cancel** items from "Bug-class and correctness" (quarantine on non-APFS volumes, SIGBUS on a shrinking archive) are app-facing: the app expands onto user-chosen volumes and opens in-flight downloads.

---

## Unsafe code

Sources: UC (BytesCompression), UO (everything else). Strict memory safety is on in every library manifest; the repository has about 3,939 `unsafe` lines (EC). The two audits count differently: UC
classifies 1,148 "origin" lines (an unchecked access) and treats 1,005 further lines as propagation that follows their callers; UO classifies 1,825 lines in every other package by reading each file
against the probes ("S" means "same pattern as a probe that was free", not verified in situ). Counts are therefore approximate (UC says ±10%), and the combined row is a sum of unlike bases.

### Counts by package or module

Columns: **free** safe now at no cost; **cost** safe now but a measured cost, or a check that stays; **feature** needs a language feature to be free; **inherent** C, syscalls, hints, trust.

| Package / module | `unsafe` lines | free | cost | feature | inherent |
|---|---:|---:|---:|---:|---:|
| BytesCompression (origin lines of 2,153) | 1,148 | 229 certain + 295 likely (measure) | 256 (kept checks, +2–3 instructions an access) | 368 | about 1 (prefetch) |
| Bytes | 408 | 71 | 243 (cursor, CRC tables) | 84 | 10 |
| BytesAsync | 57 | 5 | 0 | 46 | 6 |
| BytesCrypto | 181 | 78 (AES/AES-GCM 68 unverified: spill risk) | 64 (RSA) | 31 | 8 |
| BytesFoundation, BytesTestSupport | 4 | 0 | 0 | 1 | 3 |
| HTTPBytes | 506 | about 220 | about 230 (pointer decoders) | about 50 | about 6 |
| Disk | 465 | about 80 | 0 | about 150 | about 232 (3 not memory-unsafe) |
| NativeZipArchive | 107 | about 8 | 0 | about 85 | about 12 (2 not memory-unsafe) |
| NativeAEA | 93 | about 55 | 0 | about 32 | about 6 |
| MQTT, SocketStream | 4 | 2 | 0 | 1 | 1 |
| **Outside BytesCompression (1,825)** | | **about 520** | **about 540** | **about 480** | **about 285** |
| **Combined, rough** | | **about 750 (+295 likely)** | **about 800** | **about 850** | **about 285** |

BytesCompression's patterns by line: typed-pointer subscripts 497, loads 211, stores 151, typed carves 121, bulk or wild copies 73, fills 28, span-pointer entries 26, `@unsafe` helper calls 24,
`unsafeBitCast` of a `SIMDMask` 12, allocations 5; hotness: about 1,360 lines in per-byte or per-symbol functions, 470 per-block, 320 per-call. Files with the most: `ZstdEncoderEntropy` 204,
`BZip2Decoder` 202, `LZBitmapDecoder` 163, `LZFSEEncoder` 151, `ZstdEncoderBlock` 143, `LZBitmapEncoder` 143. Also 45 `@unsafe` declarations and 13 `@unchecked Sendable` there.

Where the rest sit: most S and N lines do not need a package-wide rewrite; they move into a handful of owners (`RawStorage`, `ByteBuffer`, a segment pool, a mapped file) that keep one `unsafe` each.

### Patterns and what each probe showed (instruction counts, no cycles)

| Pattern | Result |
|---|---|
| Guarded loads from a span, variable index (UC P1) | safe `load` after `i &+ 32 <= count` does not fold: 36 instructions and 4 `brk` against 13 unchecked. Extract once then constant offsets: 15, 0 `brk`. Shrinking span (`droppingFirst: 32`): 20 against 18 per iteration (XXH64). |
| Guarded loads under a count guard, constants or `count &- k` (UO P3) | byte-identical to unchecked (25 instructions; LLVM merged the two). A guarded byte read: 6 and 6. Applies to `FieldName`, `FieldNameLowercase`, `HTTPDate`, `ASCII`. |
| Cursor field reads, offset of unknown sign (UO P1) | repo form 62 (8 fields); safe `load` after the same guard 86; stdlib predicate 76 (+23%, and a loop that no longer vectorizes); `UInt` offset 73 (+18%); slicing cursor 64 (+3%, scalar loop, no vectorization). Writer: 44 against 52 (+18%). Keep the cursor unsafe, confined. |
| Block loops (UO P2) | four `SIMD16<UInt8>` loads: unchecked 9; safe at `o+16k` 33; `rest` span with constants 12; `Span<InlineArray<64, UInt8>>(viewing:)` 8 (setup about 20 once). |
| Raw-pointer decode loop (UC P2, LZ4 shortcut; the shape of LZVN, LZFSE, LZBITMAP, LZRAVEN, Zstd execute) | pointers 29 per iteration, 0 checks; every safe form 60–63, 7–8 `brk`. About +100%: the match source `op - offset` is data-dependent and an `inout MutableRawSpan` reloads its count and base. Not free. |
| Tables behind pointers (UC P3) | constant size + one `precondition(table.count == K)`: folds (CRC-64: 27 against 27; 43 with unknown count). Dynamic size with a mask: a count precondition does not help; **table allocated at the maximum size plus `log <= MAX`**: Huffman-style 6 against 6, hash insert 7 against 7 (10 with unknown count). Data-dependent index (`tt[cur]`, `counts[symbol]`): the check stays, +2 per hop (5 to 7). |
| `InlineArray` as a class property (UC P3) | read through `.span` it copies the whole array (a 16 KB `memcpy` in the probe); passed `inout` to the kernel it equals pointers; `var table = w.t.mutableSpan` in a function over a class instance is a compile error. Huge workspaces (bzip2 7.8 MB) are impractical as `InlineArray`; `[T]` plus a hoisted `precondition(count == K)` is the form. |
| Typed regions from one allocation (UC P4) | several read-only `Span<UInt16>(viewing:)`/`Span<UInt32>(viewing:)` over one `RawSpan`: works, 12 instructions, 0 checks. One mutable typed region: identical to pointers. **Two mutable regions at once: rejected** ("overlapping accesses", `p6b_two_mutable`). |
| `SIMDMask` casts, fills (UC P5, P6) | `unsafeBitCast(a .== b, to:)` against `replacing(with: 0xFF, where:)`: identical machine code (one `cmeq`); `bitCast` fails (`SIMDMask` is not `ConvertibleToBytes`). `update(repeating:)`: 6–9 instructions, tail call to `memset`. Bit-writer store with a clamp: 13 (pointer) against 11 (`storeBytes`, local position): the safe form is no worse. |
| RSA limb products (UO P4) | pointers 52 per iteration; `Span`s extracted once 84 (+62%, 7 branches); opposite-direction index pair 59 (+13%); window per step 71 (+37%). Keep unsafe. |
| Masked tables in classes (UO P5) | `UnsafeMutablePointer` getter 7, loop 22; `UniqueArray` with a stored mask: getter 10, loop 9 (check kept); mask derived as `count - 1`: getter 10, loop 22 (check hoisted). +1–3 instructions per random access, free in loops. |
| `RelaxedCounters` (UO P6) | `UniqueArray<Atomic<Int>>` in a `Sendable` final class: no `@unchecked`; one more load and one more allocation (verified on 6.4.4). |
| Scratch buffers (UO P7) | `withUnsafeTemporaryAllocation` 23–30 instructions; `withTemporaryAllocation` + `append` 19–26; no allocation call in either; out-of-order slot writes must initialize first. |
| Concurrency and lifetime checks (UO P8) | a `concurrentPerform` closure can capture a `RawSpan`; mutating a captured `inout MutableRawSpan` warns now (an error later); a `withTaskGroup` or `async let` capturing a span is an error ("lifetime-dependent variable escapes its scope"); a class cannot hold a `RawSpan`; an async function can take a span and await while holding it; a closure-scoped async `withSpan` compiles; `@_lifetime(immortal)` from a `StaticString` or `static let` needs `_overrideLifetime`. |

### Changes that are safe now at no cost (do these first)

From UC (229 sites): `SIMDMask` casts via `replacing(with:where:)` (12); fills via `update(repeating:)` (28); cold header and entry code (XZFormat, ZstdFormat, Deflate trailer, LZMA2 header,
`decompressAll`, `startFrame`, `Workspace`) on checked `RawSpan.load` (about 170); XXHash64 and CRC64 on shrinking spans and constant-size table spans (20); `Workspace` allocations and window
`RawSpan(_unsafeBytes:)` array-backed (14). Then probe-and-measure the 295 per-block builder sites (normalize, sort, `buildTree`, `limitHeight`, `spread`, `writeDescription`) and the hash, FSE, and
Huffman tables at maximum size with `log <= MAX` preconditions, comparing whole-codec instruction counts. UC also notes `UnsafeLanes` (65 lines across ParallelScheduler/Inflate/Deflate/Brotli) as
a `Mutex<Lane>` or atomic slot per lane today (an uncontended lock per chunk, not codegen-probed).

From UO (about 520 sites), in its order:
1. Guarded loads: `FieldName*`, `ASCII`, `HTTPDate`, `SegmentCodec`, `DER` (about 28 plus ASCII's 8): free, mechanical.
2. Typed block views: `Adler32` (14), `ChaCha20Poly1305` (8), `Shuffle`/`GroupShuffle` (22), `Hexadecimal` (15); check short-input setup with `Tools/loops --forbid`. AES and AES-GCM (68 lines) only after a spill check.
3. `withTemporaryAllocation` (7 sites: `ByteBlock.swift:115`, `ByteRepresentable.swift:226`, `BytesReader.swift:1180`, `GroupShuffle.swift:286`, `HuffmanTable.swift:230`, `Disk/Metadata.swift:459`, `PostPasses.swift:297`); verify the
   stack-buffer trick for `GroupShuffle`/`BytesReader` still vectorizes.
4. HTTPBytes tables on `UniqueArray` (`DynamicFieldIndex` 55, `DynamicFieldTable` 12, `QPACKEncoder` about 60, decoder and encoder scratch about 50, `FieldNameLowercasing` 7, `StaticFieldEntries` about 10):
   +1–3 instructions an access, and five `extension X: @unchecked Sendable {}` become unnecessary; measure HPACK/QPACK benchmarks.
5. MQTT `detail: String` in place of `StaticString.withUTF8Buffer` (`Basics.swift:73,81`); `RelaxedCounters` on `UniqueArray`.
6. NativeAEA and Disk: span-taking sink APIs and scoped pool accessors (about 55 NativeAEA lines), Disk `EntryPath` (21), `Planner` hash and `memcmp` (about 16), `JobQueue` ring (14, `UniqueArray<Slot?>`),
   `PostPasses` quoting (about 10); NativeZip decoder buffers to `UniqueArray` (6) and `nunzip` `writeAll` (2, once `FileDescriptor` takes a span).

### What must stay unsafe, and why

- **The cursors' `Load`/`Store`/`_copy`/`_move`** (about 240 sites in `BytesReader`, `BytesWriter`, plus `CRC32` tables 24, `ByteRepresentable` 18 (+46% measured), `BitBuffer` 2 (+10% measured)): +18–23% on
  field parsing under every checked form; the only free form (slicing cursor) loses vectorization of single-read loops and does not fit bit offsets or `seek`. Keep confined behind the cursor's one check.
- **Hot decode and encode loops and wild copies** (BytesCompression's 368 sites; LZ4 shape +100%): needs the feature in the next section.
- **RSA limb products** (64 lines, +13–62%); **HTTPBytes' pointer-and-count HPACK/QPACK/Huffman decoders** (about 230; they hold an `inout` position of unknown sign, so the +18–23% applies).
- **Syscalls, C, and system types** (about 285): Disk's `openat`/`mkdirat`/`symlinkat` with C strings (`Destination.swift` 99, `Syscalls.swift` 20), ACL and `setattrlist`/`fsetxattr` (`Metadata.swift` about 40),
  `TreeRemoval` 22, `mmap`/`madvise` (`Files`), `RawStorage.madvise`, `nunzip`'s `fnmatch`/`glob`/`readpassphrase`, `clock_gettime`, `realpath`/`free`.
- **Optimizer facts and trust:** six `unsafe assume(...)` and `Builtins.swift`; `Builtin.int_prefetch_RawPointer` (`ZstdMatchFinder.swift:60`); `UTF8Span(unchecked:)` on text already validated (`MQTT/Basics.swift:325`);
  `withUnsafeContinuation` (an allocation-free continuation; no non-allocating checked one exists). UC advises against `Builtin.assume` to remove bounds checks: the same unsafety with less documentation.
- **Secret wiping** (`Scrypt` `memset_s`, `initializeMemory`, `deallocate`): must not be optimized away.
- **Shared mutable memory between tasks by design** (`RawStorage`, `LentBytes`, `JobQueue`, `ExtractionContext`, `LargeFile`, `MemorySource`, `SharedArena`, `MappedFile`'s `nonisolated(unsafe) let base`):
  until splitting and sharing exist (next section) or `Cell` (SE-0556) models memory other parties write.

---

## Swift features this code needs

What is missing, what it would unlock (site counts from UC and UO), and the closest proposal. Statuses from EC (2026-11-23) unless noted. "None found" means the surveys searched the forum topics listed
in UC and UO and EC's catalog, not exhaustively.

| Missing feature | Unlocks here | Closest proposal and status |
|---|---|---|
| **Split a `MutableSpan`/`MutableRawSpan`/`OutputRawSpan` into disjoint live parts, and give each to a parallel worker** | UC's typed carves (W1: 121 lines, about 71 hot; two mutable regions rejected today), `UnsafeLanes` (65 lines), UO's scrypt lanes (about 25), TLS sealing of disjoint records (5), `ParallelCodecs`, BytesAsync `UnsafeStage`/`UnsafeDecoder` (34), NativeAEA `BlockStream`/`SegmentStream` regions (about 32), Disk pieces | None. SE-0467 lists splitting as a "top priority" future direction, blocked on tuples of noncopyable/nonescapable values; `extracting` is `mutating` and deprecated to `_mutatingExtracting`, so two live parts overlap (EC p21); `MutableSpan.split(at:)` does not exist (p03). Related: "Aliased Span and Ref types" ([88529](https://forums.swift.org/t/pitch-aliased-span-and-ref-types/88529)), "`exclusive` parameter ownership modifier" ([83503](https://forums.swift.org/t/exclusive-parameter-ownership-modifier/83503)): neither adds splitting. Bytes' `LentBytes`/`LentMutableSpan`/`LentMutableBytes` stay the pattern. |
| **Read-only spans shared with child tasks for a scope** (a `~Escapable` value captured by non-escaping child tasks) | parallel codecs' shared input; `LentBytes`/`withLentBytes`; NativeZip decode and write tasks; part of UO's 46 BytesAsync lines | None dedicated. `concurrentPerform` accepts a captured `RawSpan` (compiles); `withTaskGroup` and `async let` reject it (EC p17). The Non-Escapable lifetime pitch thread ([69865](https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency/69865)) mentions the structured-concurrency gap. Async pointer access to spans, pitch 2026-11-23 ([91016](https://forums.swift.org/t/91016)), is related but does not hand a span to another task. |
| **A once-per-round bounds proof, or range-carrying (branded) indices** | UC's per-round limits: `unsafeFlush`/`unsafeCommonPrefixLength` 24, wild copies 54, loads and stores, plus propagation: about 900 lines; UC V2's 256 hot data-dependent subscripts; UO's cursor (about 245), RSA (64), HTTP pointer decoders (about 230) | None found. SE-0447 added `subscript(unchecked:)` as `@unsafe` and left this open; LLVM does not fold `UInt(i) <= count-32` guards into checked loads (UC P1). `Bits<N>` covers up to 8 bits; maximum-size tables with a masked index cover the shift and mask cases today. A proof the compiler can see, or a non-negative index type, is the single feature UC says unlocks the most. |
| **Spans stored in classes, or held across `await` beyond closure scopes** | NativeZip `ZipDecoder` 59 and `ZipContentSource` 34 (chunks handed between a decode task and a write task), Disk's `RawStorage` plumbing (about 150), NativeAEA's pool regions, HPACK/QPACK decoded-field views (17 `_overrideLifetime` lines); `var table = w.t.mutableSpan` on a class is an error | None. Parameters and a closure-scoped async `withSpan` work (UO c4); a class cannot hold a `RawSpan` (c6). `@_lifetime` is still experimental: PR [3145](https://github.com/swiftlang/swift-evolution/pull/3145), last updated 2026-04-20; the repo has 18 `_overrideLifetime` lines in 9 files. |
| **A free-capacity view of `OutputSpan`/`OutputRawSpan`** (a `MutableRawSpan` over the uninitialized tail, with a way to report bytes written) | about 40 builder wrappers in Bytes (about 30 in `BytesWriter`, 4 in `BytesReader`, `Buffers`, `Pipeline`, `ByteRepresentable`), `ByteBuffer` (26), HTTP `withFreeBytes` and `ContentCoding` (10) | None found. The stdlib has `mutableBytes` (initialized part only) and `@unsafe withUnsafeMutableBytes`; Bytes' `withFreeCapacity` is the workaround. Related: InputSpan pitch ([90942](https://forums.swift.org/t/90942), 2026-11-20, implementation swiftlang/swift#94535). |
| **Immortal spans from static data** (`StaticString` to `RawSpan`/`UTF8Span`; a `static let` table as `@_lifetime(immortal)`) | HTTPBytes `StaticFieldEntries` and `FieldName` tables (part of about 50), HPKE, `AEAKeys`' `utf8Start` loop, `BitFields`/`ByteGroup` StaticString bytes; AGENTS.md's finding that a `static let InlineArray` cannot back an immortal span | Mentioned in the SE-0456 thread ([76138](https://forums.swift.org/t/pitch-add-span-providing-properties-to-standard-library-types/76138)); "What is an immortal static String?" ([88323](https://forums.swift.org/t/what-is-an-immortal-static-string/88323)) not formalized. Today only `_overrideLifetime`. |
| **Span-based `FileDescriptor` I/O** | `nunzip` `writeAll` (2), Disk's `read`/`pread`/`pwrite`/`write` wrappers; not `openat`/xattr/ACL/`fsetattrlist`/`mmap`/`madvise`/`readdir`, which stay inherent | Pitch "Span adoption in FileDescriptor I/O" ([84323](https://forums.swift.org/t/pitch-span-adoption-in-filedescriptor-i-o/84323)); swift-system 1.9 still has pointer-only `read`/`write` (EC). |
| **Bulk update for `MutableSpan`/`MutableRawSpan`** (and `SIMDMask: ConvertibleToBytes`) | replaces Bytes' `copyBytes(from:toByteOffset:)`/`copyBytes(within:)` family; mask casts (covered by `replacing(with:where:)`) | SE-0558 Accepted, in neither toolchain ([0558](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0558-mutablespan-bulk-updates.md); implementation swiftlang/swift#92466). `MutableSpan.updateAll(copying:)` fails on both (p02). |
| **Interior mutability for memory others write** (`Cell`, `ConstCell`, `Volatile`) | `MappedFile`, `RawStorage`, shared memory, an archive truncated while read | SE-0556, review ended 2026-11-10, present in the PR toolchain behind `macOS 9999` availability. |
| **Cancellation- and priority-safe waits** | `Waiting.swift`/`WaiterQueue`, NativeZip `ZipContentSource.swift:243–278`: the hand-built `Mutex` + continuation + `withTaskCancellationHandler` pattern; `withUnsafeContinuation` stays "inherent" | SE-0528 noncopyable `Continuation` (Implemented 6.4); SE-0564 split continuations (Accepted, in main only). No allocation-free *checked* continuation found (UO). |
| **A safe prefetch** | `ZstdMatchFinder.swift:60` (`Builtin.int_prefetch_RawPointer`) | None; forum [66569](https://forums.swift.org/t/66569) (2023). Bytes could wrap it once. |
| **Associated types sized by a protocol's value** | `HashFunction.digestByteCount` as the count of `Digest`; `MontgomeryModulus.modulus` held as `InlineArray<6, UInt64>` with "first four used" | None in the inputs (verified error, both toolchains: "cannot pass type 'T.n' as a value for generic value 'count'"). Per-conformer concrete `InlineArray` associated types work. |
| **`for x in` over `~Escapable` elements** | MQTT properties and subscriptions, HTTP fields (PR A6) | `Iterable.Element` must be `Escapable` today; discussion [90530](https://forums.swift.org/t/90530); generics ergonomics [90324](https://forums.swift.org/t/90324). |
| **Mutating `self` in a `~Copyable` struct's `deinit`** | wiping secrets without a heap holder (CD A11d) | SE-0544 Accepted (EC). Verified on 6.4.4: "'self' is immutable". |
| **Typed-throws inference for unannotated closures** | every hot closure passed to a generic `throws(E)` parameter (AGENTS.md: `{ x in … }` infers `any Error`) | `FullTypedThrows` is rejected by Xcode and did not fix the case in the PR toolchain (EC p60). |
| **Span searching and comparison** (`firstIndex(of:)`, `elementsEqual`, `mismatch`, `MutableSpan.sort()`) | Bytes' own `commonPrefixLength`, `firstByteOffset`, Huffman builder sorts (justified until these exist, then benchmark) | Absent on both toolchains (CD). `Array(copying: Span)` and `Data(copying: RawSpan)` also absent: pitch [87952](https://forums.swift.org/t/87952) (BytesFoundation is a polyfill for it). |

---

## Available now

Usable with the toolchains here. **verified on 6.4.4** is the lead's own compile; **verified (probe)** is a survey probe; **interface** was read from the SDK's `.swiftinterface` only.

| Feature | Tag | Where it applies |
|---|---|---|
| `borrow` accessors, SE-0507 (return a stored property; returning a subscript's value is rejected) | verified on 6.4.4 | the AGENTS.md trap "an `InlineArray` stored property is copied at access" (FSE tables, `var table: InlineArray<256, Int16> { borrow { _table } }`); relieves some `_overrideLifetime` and "raw memory the decoder owns" workarounds. Not yet adopted anywhere. |
| `for x in span`, `Iterable`/`BorrowingIteratorProtocol` (SE-0516) | verified on 6.4.4 | Escapable-element walkers only: HTTP/2 and HTTP/3 settings as `(id, value)` pairs, MQTT `reasonCodes`; `Span`, `InlineArray`, `UniqueArray` are `Iterable`. A custom `Iterable` with `nextSpan(maxCount:)` compiles (EC p72). Not for fields, properties, subscriptions. |
| `UniqueArray<Atomic<Int>>` held by a `Sendable` final class, no `@unchecked` | verified on 6.4.4 | `RelaxedCounters`, the rings, `AsyncIndexPool.free`, HTTPBytes' masked tables (and their five `@unchecked Sendable` extensions), `JobQueue`, Disk's planner arena, NativeZip decoder buffers. `UniqueArray`/`UniqueBox` are public in the SDK; `RigidArray` is swift-collections only. |
| `withTemporaryAllocation(of:capacity:)` with a closure over `inout OutputSpan` (SE-0524) | verified on 6.4.4 | the 7 `withUnsafeTemporaryAllocation` sites listed above. |
| Safe `RawSpan.load`, `MutableRawSpan.storeBytes`, `OutputRawSpan.append(_:as:)` (SE-0525); `Span<T>(viewing: RawSpan)`, `MutableSpan(mutating: &MutableRawSpan)` | verified (probe) | cold header/entry code, guarded loads, typed block loops (counts above). Not the cursors. Conform `Byte2…Byte16` via `@unchecked ConvertibleFromBytes` so stdlib loads accept them [L]. |
| `RawSpan.subscript(unchecked:)` (`@unsafe`), `byteOffsets(of:)`, `extracting(first:/last:/droppingFirst:/droppingLast:)` | verified (probe) | the 8 `byte(_:)` helpers; recovering offsets of returned slices. |
| `Builtin.int_aarch64_*` through `SIMD16<UInt8>._storage._value` | verified (probe) | replace `CBytesCrypto`, `CBytesCRC`, and `CBytesNEON`'s intrinsic wrappers; experimental `BuiltinModule` already enabled. |
| `@inline(always)` (SE-0496, Swift 6.3) | verified | macro output (`BinaryRecordMacro`, `BitFieldsMacro`). OPTIMIZATION.md §4.2 says 6.4: documentation fix. |
| `@specialized(where …)` (SE-0460, 6.3); `@export(implementation)` (SE-0497, 6.3) | verified (probe) | `@specialized` for helpers on `GenericBytesReader<Mode>` that stay unspecialized across modules; `@export(implementation)` would replace `@inlinable`+`@usableFromInline` pairs (about 1,977 `@inlinable`, 550 `@usableFromInline` lines) but BC and CD advise no sweep. |
| `Ref`/`MutableRef` (SE-0519) | verified (probe) | cursors with `inout` state without boxes; one element instead of `UnsafeMutablePointer`. |
| `Task.immediate`; task-executor preference (`withTaskExecutorPreference`, `addTask(executorPreference:)`); `withDiscardingTaskGroup`; cancellation shields (SE-0504) | verified (probe) | `ParallelCodecs` worker 0 (changes executor: measure); a dedicated writers' executor in Disk (AR P9). |
| `do throws(E)`, typed throws | verified | already used; keep annotating closure error types. |
| `Mutex.withLockIfAvailable`, `AtomicLazyReference`; `Atomic`, `WordPair` | interface | try-lock fast paths in `AsyncLimiter.release`; none needed. |
| `System`: `Stat`, `FileMode`, `FileFlags`, `UserID`, `GroupID`, typed `Errno` (SDK 27.3) | interface | Disk's metadata types and read-only `fstat` paths. |
| `Data.bytes`/`.span`/`.mutableSpan`; CryptoKit `SHA256.update(bytes: RawSpan)`, `SymmetricKey.bytes` | verified (probe) | BytesFoundation (still the only copy-from-`RawSpan` forms); crypto benchmark references. |
| `UTF8Span` (`isKnownASCII`, `String(copying:)`) | interface | HTTP request targets and `Content-Disposition` filenames (ASCII proven by the parser). |
| SE-0499 (`~Copyable` simple protocols), SE-0503 (suppressed associated types), SE-0528 (noncopyable `Continuation`, API names unchecked) | interface | `~Copyable` leases and owners; waits. |
| Packages, as references or comparators only (the libraries take no dependencies): swift-crypto 5.1 span APIs (in-place `seal`/`open`), swift-certificates 1.21/swift-asn1 1.7 (chain validator shape and a differential oracle), swift-nio `readableBytesSpan` and `NIOAsyncChannel` (adapter package), swift-nio-extras `NIOHTTPDecompression` (limit shape), swift-async-algorithms `MultiProducerSingleConsumerAsyncChannel` (benchmark comparator: it allocates), swift-collections 1.7.6 (`RigidArray`, `UniqueDeque`, `RigidDeque`; BC and CD see no dependency worth taking), swift-http-types 1.8, swift-subprocess 1.0.2 (tools only), swift-system 1.9 (`Stat`, `StatFS`) | recorded (EC) | as listed. |

---

## Watch list

Proposals, pitches, and versions that could change the above within months (dates and links from EC unless noted).

- **Lifetime annotations** (`@lifetime` without the underscore): [PR 3145](https://github.com/swiftlang/swift-evolution/pull/3145); does not parse today. Every `Lifetimes` use is a source-breaking-risk site.
- **SE-0558** bulk span update (Accepted; swiftlang/swift#92466): retire `copyBytes` family after comparing instruction counts.
- **SE-0564** split continuations and **SE-0538** `Disconnected` (Accepted, main only); swiftlang/swift#91981 merged 2026-11-18: look for a snapshot that has it to retire SocketStream's PR toolchain (and re-check
  that `swift-platform-executors` `bd74d56` builds there; its PThread executors still `fatalError` on leased buffers).
- **SE-0556** `Cell`/`ConstCell`/`Volatile` (review ended 2026-11-10): `MappedFile`, `RawStorage`.
- **Swift 6.5 branch cut:** SE-0551 (`Span(ofOne:)`), SE-0557 (Hasher spans), SE-0543 (`InlineArray: Hashable`), SE-0538, SE-0556, SE-0564 move from the PR toolchain to Xcode; the SIMD scalar-comparison fix (33 instructions plus a call to
  5, p90) lets the `ByteLanes` splat workarounds go.
- **InputSpan/InputRawSpan** ([90942](https://forums.swift.org/t/90942), implementation swiftlang/swift#94535; swift-collections' `SpanPreview` has it behind `UnstableContainersPreview`): `ByteBuffer` drain-from-front and
  `Pipeline` input.
- **Async access to span pointers** ([91016](https://forums.swift.org/t/91016), filed today) and the `MutableSpan` split gap (SE-0467 future directions): the two places the stdlib may obsolete `Lent*`.
- **Equatable/Hashable spans** ([90475](https://forums.swift.org/t/90475)); **Data with spans** ([87952](https://forums.swift.org/t/87952)); `~Escapable` slices ([89800](https://forums.swift.org/t/89800));
  `Iterable` with `~Escapable` elements ([90530](https://forums.swift.org/t/90530)); constraint propagation of `~Copyable`/`~Escapable` ([90324](https://forums.swift.org/t/90324)).
- **SE-0544** mutate or consume in `deinit` (for `~Copyable` secrets); **SE-0529** `FilePath` in the stdlib (Disk, NativeAEA, NativeZip, Nunarchiver use `System.FilePath` in 27 files); SE-0532, SE-0515, SE-0562 (accepted noncopyable follow-ups).
- **swift-async-algorithms `AsyncStreaming`** (trait `UnstableAsyncStreaming`, `AsyncReader`/`AsyncWriter`/`DuplexChannel`, 1.1.5–1.1.7; draft SE "awaiting implementation"): the same design space as BytesAsync and SocketStream.
- **swift-http-api-proposal** (no release; [85254](https://forums.swift.org/t/85254), [85255](https://forums.swift.org/t/85255)), **swift-nio-quic/swift-nio-http3** 0.1 (unstable): comparators and transports for HTTPBytes.
- **swift-collections** (1.7.6 now; `UniqueDeque`, `RigidDeque`, `Container` preview); **swift-crypto** (5.1.2); **swift-binary-parsing** (0.0.4, pinned `.upToNextMinor`): re-check after each release.
- **`FullTypedThrows`** (experimental, nothing scheduled); direct-threaded interpreters ([90750](https://forums.swift.org/t/90750): range coders and HPACK state machines are the target shape); `Array.map` vectorization ([90500](https://forums.swift.org/t/90500)).
- **Repository-local:** the working tree's uncommitted Zstd encoder edits (CD's object-file checks may lag them); any macOS or Xcode move that changes the OS-version query on typed throws (PR L4).

---

## Suggested order of work

Each step names what to measure. Steps 1–3 can run in parallel with no shared files; after step 3, judge by instruction counts and allocation gates, and time on an idle machine afterwards (AGENTS.md "Parallel agents").

1. **Bugs and documentation (no benchmarks).**
   - Disk double close (summary 1): delete the explicit `Sys.close(root)`; a test that makes the quarantine fail during `init` and checks one close (a descriptor-count or `fcntl(F_GETFD)` check).
   - `…All` reuse (summary 2): reset first in Deflate/Brotli encoders and decoders; test: two `compressAll` and two `decompressAll` calls on one object; `Allocations:*` gates stay 0.
   - gzip multi-member (summary 3): test with two concatenated members and with `Decompressor` and HTTP's content decoder.
   - NativeZip `.cancelled` mapping and `AEAError.incorrectKey` (summary 5); verify quarantine on exFAT and SMB (summary 4); try to reproduce the SIGBUS and decide ZIP's mapping in ARCHITECTURE.
   - Fix OPTIMIZATION.md's SE-0496 version; stale Disk doc links; report (do not edit) MQTT's and SocketStream's READMEs; delete the deprecated `Data.append(_:)` alias and the empty `Base64/` directory.
2. **Cheap wins judged by instruction counts.**
   - `matching(_:)` as `cmeq` with full-lane `ByteMatches`, and the scan-loop unchecked form (summary 8, 9): `Tools/loops`, `ByteBlock` and MQTT topic benchmarks, then cycles interleaved.
   - `knownMethod` and `observe` (summary 10): per-head instructions on the http-corpus and top-1k rows, then cycles (`Tools/counters`).
   - SHA-256 bounds hoist: `Tools/loops` (about 12 branches gone), SHA-256 1 MB row.
   - `HTTPMediaType` charset range; `String(copying:)`, `bytesEqual`, `[UInt8](copying:)` replacements of per-byte loops.
   - Disk width sweep on the M1 Max (summary 6): one `Workers:` invocation, widths 2–12; then the formula.
   - `.noindex` staging name (three interleaved rounds, `mds` CPU).
3. **Safe-now `unsafe` conversions (about 750 sites; 295 more after measuring).** Per package, in UO's and UC's order above. Gate: `Tools/calls --callee 'memcpy|memmove|swift_allocObject|metadata'`, `Tools/loops` per hot function,
   instruction counts and zero-malloc thresholds, and a PR-toolchain build for anything reachable from SocketStream.
4. **Measured experiments (each with a baseline first).**
   - `HTTPFieldStore.append` (profile the store row, then one allocation): "owned fields" rows, mallocs.
   - Hybrid `FieldGrammar.tokenEnd` (a scalar test of the first few bytes, then the vector scan): the `r2-fields-*` baselines per value, against the round-2 numbers; keep only if it beats them on short tokens and does not lose on long.
   - Hard-link grouping and pass-width sweep (summary 11): Xcode `.xip` wall time and the pass's seconds.
   - Zstd direct output (summary 13): the `Zstd encode L3 random (1.0 MB): raw blocks` row (gate: +21% instructions, +15% time).
   - Attachments applied by the writer (AR P4): calls per file and the 2,000-merged-file row.
   - Maximum-size tables with `log <= MAX` in BytesCompression, per-block builders: whole-codec instruction counts.
   - AES 12-block probe, then kernel (`Tools/probe insn aese aesmc`, spills); Brotli short-input profile; lazy windows (`BrotliDecoder()`/`DeflateDecoder()` creation time and a 32-worker `Decompressor` set's RSS).
   - Response-only lookahead scanner as a short experiment (PR P1, as corrected): the response rows only, against round 2's skip-window results.
5. **API work, in dependency order.**
   - Narrow access by usage (summary 17) and the DocC checks for BytesCompression, BytesCrypto, Disk, NativeZip, NativeAEA: build every client, revert what the compiler rejects; check `Tools/calls --callee 'Bytes'`.
   - Scoped permits, `Lease`, closable pool; `RawStorage` span accessors; `OwnedDescriptor` (summary 18, 19): zero-malloc gates and `Tools/calls` for `rawValue` inlining.
   - `Compressor`/`CompressionFormat`, `DecompressionLimits`, an error vocabulary (summary 12): `Decompressor`'s measured-free `switch`; then delete the three client switches and HTTP's zstd bypass.
   - NativeZip/NativeAEA extraction unification, typed `ZipError`, `ExtractableArchive`, progress phase and throughput in Disk (summary 14): no perf change expected; the app's tests.
   - Async-safe discard in the app (rename then background delete, launch sweep).
6. **Larger work.**
   - HTTP/1 sans-IO connection and head types (summary 15), then narrow HTTPBytes' public surface by its clients; benchmarks and allocation gates for HTTP/2 and HTTP/3 frames and head writing first (PR P5); then HTTP/2.
   - X.509 chain validator; `Builtin` intrinsics replacing the C shim targets (kernel by kernel, identical object code); Brotli context modeling and block splitting; Zstd and Brotli decoder dictionaries (`dcz`, `dcb`); MQTT topic filters.
   - After each Swift release, revisit "Swift features this code needs" against the watch list, starting with split continuations and SE-0558.
