# After the safe-access refactor: findings and proposals (2026-11-23)

What the refactor (four agents converting `unsafe` code to safe APIs where it measured free, then five adversarial
reviewers) taught about the libraries, and the changes that follow from it. Each item says what evidence it rests on and
what would decide it. **Stage 3 (2026-11-23, later) did §1 and §2's first two rows**: see "Done" at the end of each, and
the stage 3 sections of BytesCompression/RESULTS.md, NativeZipArchive/Benchmarks/RESULTS.md, NativeAEA/RESULTS.md,
HTTPBytes/RESULTS.md, Disk/RESULTS.md.

## 1. A confirmed bug: a ZIP64 size past `Int.max` crashes NativeZip (fix first)

**Reproducer:** `/private/tmp/claude-501/-Users-jshier-Code-Experiments/49092c13-05a5-48e8-8c51-7436842f3ce5/scratchpad/zip64-probe`
(a scratch package; `swift build && .build/debug/Probe DIR`). It writes a stored ZIP of `x` and `._x`, where `._x`'s
central-directory size is `0xFFFFFFFF` and its ZIP64 extra field gives 2^63, then extracts it. The process ends with
SIGTRAP (exit 133): `Swift runtime failure: arithmetic overflow` at `ZipArchive+Extraction.swift:411`,
`expected.bytes += Int(clamping: entry.uncompressedSize)`. Clamping gives `Int.max`, and the next file's addition
overflows. Any archive whose directory claims such a size beside one other file crashes the extractor before it writes
anything; the size is the archive's to choose.

A second site would trap right after: `bytes.reserveCapacity(Int(entry.uncompressedSize))` in the AppleDouble merge
(`ZipArchive+Extraction.swift:478`, `._` entries, merged by default): `Int(_:)` traps above `Int.max`, and any large
claimed size reserves that much memory before a byte is read.

**Fix:** bound sizes where the directory is parsed, as NativeAEA's root header does (`< 1 << 62`, else
`.invalidRecord`), so nothing downstream sees an impossible value. Also sum expected bytes with saturation, and reserve
at most a small cap for AppleDouble (they're kilobytes; read the rest as it comes). Turn the probe into a regression
test.

**And a sweep, since this is the second such trap today** (the first was cpio's `mode_t(mode)`): every size, count,
and offset read from input should be bounded where it's parsed, and conversions of input values should be
`exactly:` (rejecting) or `truncatingIfNeeded:` (where the bits are all that matter), never a bare `Int(x)` or
`UInt16(x)`. A grep finds candidate conversions in NativeZip (34), BytesCompression (152), HTTPBytes (88), BytesCrypto
(19), NativeAEA (15), MQTT (7); most are widening or already guarded, as NativeAEA's root header is. Read each with the
question "can the input reach this with an out-of-range value?".

**Done (stage 3).** NativeZip refuses any size or offset of 2^62 or more where the central directory (and the ZIP64 end
record) is parsed (`.invalidRecord(.invalidValue, "central directory entry N")`), sums totals with saturation, and reserves
at most 64 KiB for an AppleDouble entry; Disk's `ExtractionProgress.addExpected` saturates. `HostileSizeTests` (4 tests,
archives built in the test: the probe's, each ZIP64 field at 2^62 and 2^62 − 1, an offset near 2^64 after leading bytes,
four entries of 2^62 − 1 added twice to one extractor) failed before (two by trapping) and pass. Parsing cost: +0.4%.

The sweep (every package named above; NativeZip read here, the others by three read-only review agents, each finding then
confirmed with a crafted input before it was fixed). Reachable traps, all fixed with a test that failed first:

| Where | Input | Fix |
|---|---|---|
| NativeZip `ZipExtractor.add`: `expected.bytes += Int(clamping: size)` | a ZIP64 size of 2^63 (or four of 2^62 − 1) | sizes `< 2^62` at parse; saturating sums |
| NativeZip `readCentralDirectoryEntry`: `localHeaderOffset + leading` | a ZIP64 offset of 2^64 − 1 in an archive with leading data | the same bound, before the addition |
| Disk `ExtractionProgress.addExpected`: checked `+` | two archives each claiming `Int.max` in total | saturating |
| NativeAEA `AppleArchive.parseFields`: `entry.blobByteCount += count` (and the walker's `position + blobByteCount`) | three `XATC` blobs of 2^62 − 1 in one `.aar` header (no authentication) | total kept below 2^62, `.invalidArchive("blob sizes")` |
| BytesCompression `ZstdDecoder.decompress(_:maximumSize:)`: an array of the header's content size (default limit `.max`) | a 14-byte frame claiming 2^62 bytes (abort in `malloc`) | sizes beyond 32,768× the input refused as `invalidValue` |

No reachable trap in MQTT (LEB128 at most 4 bytes, identifiers below 64 before shifts), BytesCrypto (DER lengths at most 4
bytes, sizes checked exactly), HTTPBytes (prefix integers and QUIC varints stop at their widths; QPACK's arithmetic checked
before dividing, wrapping then range-checked), or BytesCompression's decoders (sizes bounded where read; wrapping arithmetic
with checks before use). Reachable but not traps, recorded for later (each package's RESULTS.md has the inputs):
memory — `ParallelDeflateDecoder`'s segment buffers grow without the output's limit; streaming Zstandard reserves its window
zeroed; an AEA root header's segment size up to 2^31 − 1 sizes the buffer pools (needs the archive's key); `XAT`/`ACL`
blobs held whole; CPU — XAR's TOC path rebuilt per element, X.509's duplicate-extension check (quadratic past 16
extensions, before any signature check), `HTTPRangeSet.resolve` re-parsing per range; other — HPACK's recursion per
oversized literal after the list limit, HTTP/2 and HTTP/3 `:status 000`, AEA timestamps' nanoseconds unchecked.
Theoretical only: `Int32` entry indexes in NativeZip (2^31 entries, a 98 GB directory), `UInt32(cluster)` in NativeAEA,
Disk's `acl_init(Int32(count))`.

## 2. Performance

| Proposal | Evidence | Expected effect | Decided by |
|---|---|---|---|
| **Vector fill for LZMA's probability reset** (`LZMACore.resetState`) | `Tools/loops`: one `strh` per probability, about 8,000 for `lc=3` (about 32,000 instructions) every time a stream starts | Every LZMA and xz entry of a ZIP, and every LZMA2 state reset; for 20,000 small LZMA entries, about 640 M instructions. A `SIMD8<UInt16>` fill as `DeflateCompressor.clear` now does, about 30x fewer | NativeZip's LZMA/xz small-file rows, instructions |
| **The same for HTTPBytes' index buckets** (`DynamicFieldIndex` fills of -1 at `init`/`reset`) and `StaticFieldEntries` | Same pattern (non-zero `update(repeating:)`/`initialize(repeating:)`); zero fills become `memset`, non-zero ones don't | Per connection or table reset: small | HPACK/QPACK rows with a reset per message |
| **Done (stage 3):** LZMA's fill, by groups | `LZMAWorkspace` sized and reset in 16-byte groups (`SIMD8<UInt16>`), aligned by its own allocation, no check: `Tools/loops` one `str q` per group, 1,004 stores for lc 3 | −28 K instructions per stream: 1,000 × 4 KB LZMA/xz streams −4.1 to −4.3%, NativeZip's 2,000 small LZMA/xz entries −4.0% | as proposed |
| **Done (stage 3):** HTTPBytes' fills: nothing to do | -1 in `Int` and `0xFF` in `UInt8` are byte splats: LLVM already calls `memset` (`Tools/calls`), no fill loop | none | — |
| **Disk's compression path without exclusivity checks** | `Tools/calls`: `swift_beginAccess` in `writeCompressedPiece` (52 sites), `writeBatches` (39), `ChunkEncoders.encode` (13), `WriterCore.prepare` (13): class-held mutable state | Minor against compression work (about 20 instructions per check); `ChunkEncoders` as a `~Copyable` struct the writer owns | Disk's compressed rows, instructions |
| **Byte-pattern searches in place of byte loops** | PEM: `Byte11`/`Byte9`/`Byte5` patterns with `firstByteOffset(of:from:)` instead of a `StaticString` byte loop, −20 to −45% | Wherever text is searched for a fixed marker a byte at a time; candidates need finding (none confirmed yet) | Per site, instructions |

## 3. API: put the remaining `unsafe` in a few audited owners

The survey said most remaining `unsafe` would move into a handful of owners rather than disappear. The refactor
measured why the general safe types don't fit the hot paths; small purpose-built types would.

- **`MaskedTable<Element>` in Bytes**: power-of-two storage with its mask, indexed `table[hash]` (masked, unchecked
  inside, one audited `unsafe`). `UniqueArray` cost HTTPBytes' HPACK/QPACK coders +2–9% (a `cbz count` on every random
  access, or `cmp`+`b.hs` when the mask is stored narrower), so those tables stayed on pointers and their four coders
  stayed `@unchecked Sendable`. A masked table would make their indexing safe at the call sites, with no check left to
  pay. Clients: HTTPBytes' dynamic table, index, static entries, and QPACK history; BytesCompression's match-finder hash
  tables. Decided by HPACK/QPACK and compression rows staying flat.
- **Tables typed by their store stride** (your note): `DeflateCompressor`'s `Int16` tables cleared as `SIMD8<Int16>`
  groups relied on `malloc`'s 16-byte alignment, which the type doesn't promise (fixed with a run-time check). Storage
  typed as the groups (eight-entry `SIMD8<Int16>` or `InlineArray` elements, viewed as entries for lookups) makes the
  alignment the type's own, and every fill vectorizes without a check. Natural with `MaskedTable`; LZMA's
  probabilities (above) are the second client.
- **`StaticString.bytes` in Bytes** (an immortal `RawSpan` over a literal): HTTPBytes' `immortalSpan(_:)` moved down,
  for the eight raw `utf8Start`/`withUTF8Buffer` reads across five packages (HPKE's and AEA's key-derivation labels,
  HTTPBytes' field tables, MQTT's `MQTTError` equality and hashing). MQTT's attempt with a `String` detail cost +1.2%; a
  span comparison shouldn't. `ASCII` and `BitFields` index `utf8Start` because that's what folds a literal to
  constants; check the span form folds too before moving them.
- **Word reads from byte spans**: reading `Span<InlineArray<N, UInt8>>` elements with `bitCast` to an integer was free
  (XXH64 −11 to −13%), but taking `.span` of an element or indexing a local `InlineArray` takes a local's address, and
  the stack protector then costs about 10 instructions per call (Adler-32's 64-byte rows +26%). A Bytes helper that
  hands out words (`RawSpan.withWords(of: UInt64.self) { words, tail in … }`) would make the free form the only form.
- **Path buffers for C strings**: Disk's `CString.with` on `withTemporaryAllocation` was outlined into a separate
  function per result type behind a closure call (`makeHardLink` 209 → 378 instructions, `publishUnwrapped` 963 →
  1,264), so it stayed on the unsafe form. A `~Copyable` local holding an `InlineArray<1024, UInt8>` (no closure) is
  worth one probe; if the compiler outlines that too, it's a compiler issue to report.
- **Workspace regions**: BytesCompression's `CodecWorkspace` regions are typed spans over one allocation, and a borrowing
  accessor fails the lifetime checker inside `mutating` methods ("lifetime-dependent variable escapes its scope"), hence
  the new `pointer(_:as:)` helper. Region tokens handed out once per call (or the language's borrowing accessors) would
  remove it; this one waits on the language.

## 4. Keep what the review built

The reviewers wrote differential harnesses that compare new code with old: about 237,000 malformed and truncated
compression streams, 3.7 M paths through Disk's `EntryPath`, 90,000 PEM texts, QPACK blocked-stream sequences, cpio
trees at 17 slice sizes (which found the mode trap). Their inputs and checks, made into bulk tests against fixed
expectations (no old copy needed), would guard every later change to these parsers. The fuzzing that found two traps
in one day suggests the same for NativeZip's directory parser (§1) and BytesCrypto's DER.

## Order

1. NativeZip's ZIP64 size trap, with the regression test, and the input-conversion sweep (§1).
2. LZMA's vector fill (§2): small and measurable.
3. `MaskedTable` and stride-typed storage together (§3), prototyped on HTTPBytes' tables and DEFLATE's.
4. `StaticString.bytes`, then the word-read helper (§3).
5. The review harnesses as bulk tests (§4).
