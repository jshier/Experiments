# BytesCompression performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M1 Max, macOS 27.2, Swift 6.4 (Xcode 27.3). Baselines
are in `.benchmarkBaselines/`; compare any two with `../Tools/bench-table . --metric 'Instructions|Malloc' A B`.
Until 2026-11-23 this was the `BytesCompression` module of the Bytes package: its history is in
`../Bytes/Benchmarks/RESULTS.md` (and `../Bytes/OPTIMIZATION.md`), and the per-format records moved here with it
(`Benchmarks/RESULTS-zstd-encoder.md`, `RESULTS-bzip2.md`, `RESULTS-lz4-lzfse.md`, `RESULTS-lzbitmap.md`,
`RESULTS-lzraven.md`, `LZRAVEN-FORMAT.md`). The `CompressionBenchmarks` baselines saved in Bytes before the move are
here too (`.benchmarkBaselines/CompressionBenchmarks/`), under their old names.

## 2026-11-24, E2: masked tables, one file of word loads, docs, the public surface (fix plan D9, D10's rest, D11; baselines `fix-E2-before` → `fix-E2-after`)

M1 Max, the only agent running; the "before" baselines of three packages were saved at once, so their times ran under
each other's builds: instruction counts judge the rows. Intermediate baselines: `fix-E2-d9-deflate`, `fix-E2-d9-lz`,
`fix-E2-zstd-exp` (here), `fix-E2-d9-http` (HTTPBytes). Exact p50s below are read from the HDR histograms (0.1%).

### `MaskedTable` (D9)

Bytes' `MaskedTable<Element>` (Bytes/Benchmarks/RESULTS.md, "E2"): a power-of-two table indexed by any integer, masked
into it, in whole 64-byte lines so group fills can't be misaligned. Applied where it measured equal or better:

- **DEFLATE's match tables** (`hash3`, `hash4`, `chains`: `MaskedTable<Int16>`, filled a `SIMD32<Int16>` at a time).
  The chained parsers (levels 2–9) index `hash3[h3]`, `chains[node4]` with no hand masks and no span counts: their spans
  went through `@inline(never)` functions with their counts unknown, so every access was checked. Level 1's bucket
  table keeps its span view with the count stated: indexed through the table (`hash << 1`, `(hash << 1) | 1`), LLVM
  merged the hash's mask into the table's after the shift, and a mask stayed on every insert (+5% at level 1; three
  forms tried: the table's mask alone, the hash masked once before the loop, the doubled hash carried as the bucket).
  Unallocated tables (levels 0–1) are one entry, one 64-byte line, where `StrideTable` allocated a byte.
- **LZFSE's and LZVN's match lines**: `LZMatchTable` holds a `MaskedTable<LZMatchTable.Line>` (32-byte lines of four
  positions and four values) and is cleared with `fill`; `insert(_:at:position:value:)` takes the lines as a span, which
  each encode binds once with its count stated. The table itself passed `inout` had its base reloaded at every searched
  position (LZFSE +1.2% on dickens); bound once, the base stays in a register and the `and` that `table + hash << 5`
  needed is gone (`lsr #18; add x, base, x, lsl #5`). Byte for byte Compression's and the reference's, as before.
- **Not Zstandard's tables.** Its hash log is chosen per frame, so the mask is a run-time value the hash's
  `>> (64 − bits)` can't be proved under. Measured with the best case emulated (a masked pointer, base and mask in
  registers) before moving the tables out of the workspace: +1.2 to +5.4% on every encode row (median +3.6%; L1 dickens
  +4.2%, L3 x-ray +5.4%). They stay as `unsafe table[hash]` over the workspace.
- **Not Brotli's bucket rings** (as the plan said: a bucket is a ring, not one entry).
- `StrideTable` and `UninitializedBuffer` stay here: `MaskedTable` keeps the group-fill guarantee by allocating whole
  64-byte lines, so moving them to Bytes wasn't needed, and their clients (LZMA's model, LZBITMAP's workspace, the
  windows and staging buffers) are all codecs.

| Rows (instructions, p50) | Before | After | Change |
|---|---:|---:|---:|
| Deflate 9 dickens (9.7 MB) | 2,315,255,808 | 2,098,200,576 | −9.38% |
| Deflate 9 Main.js (3.8 MB) | 691,535,872 | 627,048,448 | −9.33% |
| Deflate 6 dickens | 1,308,622,848 | 1,220,542,464 | −6.73% |
| Deflate 6 JSON (119.0 KB) | 10,149,888 | 9,461,760 | −6.78% |
| Deflate 6 samba (20.6 MB) | 1,870,659,584 | 1,780,482,048 | −4.82% |
| Deflate 6 x-ray (8.1 MB) | 957,874,176 | 915,406,848 | −4.43% |
| Deflate 6 xml (5.1 MB) | 340,000,768 | 332,922,880 | −2.08% |
| Deflate 6 JSON (1.6 KB) | 172,160 | 166,144 | −3.49% |
| Deflate 6 small streams 50 × 4 KB | 23,887,872 | 22,790,144 | −4.60% |
| Deflate 6 small streams 1000 × 64 B | 54,788,096 | 54,427,648 | −0.66% |
| Deflate 1 dickens | 436,207,616 | 429,129,728 | −1.62% |
| Deflate 1 x-ray | 392,429,568 | 386,924,544 | −1.40% |
| Deflate 1 small streams 50 × 4 KB | 10,993,664 | 10,919,936 | −0.67% |
| Deflate 1 small streams 200 × 1 KB | 18,661,376 | 18,710,528 | +0.26% |
| Deflate 1 small streams 1000 × 64 B | 46,235,648 | 46,530,560 | +0.64% |
| LZFSE encode dickens (9.7 MB) | 977,797,120 | 940,572,672 | −3.81% |
| LZFSE encode xml (5.1 MB) | 228,458,496 | 220,987,392 | −3.27% |
| LZFSE encode samba (16.0 MB) | 950,009,856 | 923,795,456 | −2.76% |
| LZFSE encode x-ray (64 KB × 16) | 83,230,720 | 82,575,360 | −0.79% |
| LZFSE encode mozilla (64 KB × 16) | 58,753,024 | 58,884,096 | +0.22% |
| LZFSE encode random (64 KB × 16) | 68,747,264 | 69,795,840 | +1.53% |
| LZVN encode xml (5.1 MB) | 263,847,936 | 258,473,984 | −2.04% |
| LZVN encode samba (16.0 MB) | 1,048,576,000 | 1,031,798,784 | −1.60% |
| LZVN encode dickens (64 KB × 16), reference parse | 110,297,088 | 109,248,512 | −0.95% |
| LZVN encode x-ray (8.1 MB) | 1,141,899,264 | 1,133,510,656 | −0.73% |

Every DEFLATE and LZVN row, and every LZFSE row but two, ran fewer instructions. The two exceptions are register
allocation: LZFSE on random input (no matches, so every position goes round the no-candidate path) runs exactly one more
instruction per position (1,048,576 for 2^20 positions), a fifth phi copy on the loop's back edge where the old code had
four; mozilla's 64 KiB chunks +0.2%. DEFLATE level 1's small streams run entirely in the per-position slow path, where one
value is now reloaded from the stack: +300 instructions per 64-byte stream (+0.6%). Kept: the table changes are
−1 to −9% everywhere else. Times aren't comparable (the "before" run shared the machine with two other packages'
builds); the level 6 and 9 rows' wall times moved −2 to +1%, the loops being latency-bound, as before.

### One file of word loads (D9)

`WordReads.swift`: the encoders' unchecked little-endian loads from a span (`load32`, `load64`, `byte`) and from a pointer
(`load32`, `load64`), and the checksums' checked word views (`words(_:)`, `stripes(_:)`, `value(_:)`). Clients: DEFLATE
(its short-named wrappers forward to it), Brotli (which borrowed `DeflateCompressor.load64` and `byte`), LZFSE, LZVN,
XXH64, CRC-64; `LZHash` keeps only the hash. Checked by building the module before and after and comparing every
function's instruction count (objdump over the merged object): identical. Two first tries weren't, and changed:

- XXH64's rounds through a helper taking the 32-byte stripe and returning its four words: +3 instructions a stripe (the
  stripe loaded into two vector registers and its lanes moved out). The `bitCast` stays at the use; only the view moved.
- Zstandard's `ZstdMatchInput.load32`/`load64` through the shared pointer forms: one of its 16 specialized match finders
  (`fastSelect6`) came out with its registers allocated differently, 483 instructions for 482, with `@inline(__always)`
  and `@inline(always)` alike. Zstandard keeps its own two loads.

### Docs (D10's rest)

- Brotli's quality and DEFLATE's level ranges, as they run: `CompressionFormat.brotli` says 0 runs as 1;
  HTTPBytes' `HTTPContentEncoder.init` says DEFLATE's 0 stores and levels above a coding's highest run as it. The coders'
  own docs (`BrotliEncoder`, `DeflateEncoder`, the parallel encoders) already did.
- `HTTPContentEncoder.reset()` ("keeping the encoder's memory") and HTTPBytes' carry comment (902 bytes, from the formats'
  units) were already right: A3 and D10's first part fixed them.
- NativeAEA/FORMAT.md: the root header's segment size refused over 256 MiB (`aea`'s largest; why), and a `T` time's
  nanoseconds below 10⁹.
- ARCHITECTURE.md (here and NativeAEA's) checked name by name against the code after E1's renames (every code name in
  backquotes looked up in the sources): only NativeAEA's mention of `decompressXZ`, already marked as the old name, and the
  benchmark `SegmentDecoder` line, now updated (below). §4 records `MaskedTable` and the narrowed surface.

### The public surface (D11)

First the plan's precondition: **NativeAEA's benchmark `SegmentDecoder` decodes through `Decompressor`**
(`DecompressionFormat(aeaSegment:)`, `decompressAll(_:into:decodedSize:)`), not the seven decoders by name.
`Decode segment 0: synthetic: bytes` 1,189,085,184 → 1,190,133,760 instructions (+0.09%), 0 mallocs both.
`Make segment decoder: synthetic: bytes` 13,032 → 6,648 instructions and 2 → 1 mallocs: `Decompressor` makes the
whole-buffer decoder on first use, so the row now measures less of it.

Then AGENTS.md's recipe: the symbol graphs of BytesCompression, BytesCompressionAsync, and BytesReferenceCodecs; every
public name looked up in the sources of every client (NativeZipArchive, NativeAEA, Disk, HTTPBytes and its Benchmarks,
SocketStream, MQTT, BinaryParsingComparison, BytesProbe; the Nunarchiver app imports none of these modules), then in
this package's tests and benchmarks; changed; every client built (and SocketStream with its PR toolchain); what the
compiler refused put back.

| Declared public symbols | Before | After |
|---|---:|---:|
| BytesCompression | 322 | 159 |
| BytesCompressionAsync | 110 | 110 |
| BytesCompressionAsync's extensions of BytesCompression's types | 6 | 2 |
| BytesReferenceCodecs | 23 | 17 |

- **`package`**: the decoders and encoders no other package names (`BZip2Decoder`, `LZMADecoder`, `LZMA2Decoder`,
  `XZDecoder`, `ZstdDecoder`, `LZ4Decoder`, `LZFSEDecoder`, `LZVNDecoder`, `LZBitmapDecoder`, `LZRAVENDecoder`,
  `LZFSEEncoder`, `LZVNEncoder`, `LZBitmapEncoder`, `ParallelBrotliEncoder`) with their members; `CRC64`, `XXHash64`,
  `ZstdFrameHeader`, `DeflateVariant`, `GzipHeader` (and `DeflateDecoder.variant`, `historySize`, `gzipHeader`,
  `init(variant:)`); `DecompressionFormat.isStreamable`, `historySize`; `LZMAProperties`' three bit counts;
  `ZstdEncoder`'s parameters, initializers, and `memoryUsage`; the parallel codecs' `compressAllConcurrently` and
  `decompressAllConcurrently`; `Zlib.fullFlush`, `decompressMembers`, `AppleCompression.lzvnRaw`.
- **`internal`**: `DecompressionFormat.endIsFinal`, the parallel codecs' `laneCount`, `maximumChunkSize`,
  `minimumSegment`, `ZstdEncoder.includesChecksum`, `GzipHeader.extraFlags`, three unused zlib constants.
- **Kept public, and why**: `ZstdEncoder` and its `Parameters` for `Parameters.httpWindowLog` (HTTPBytes), and
  `compress(_:into:flush:)` and `reset()` because the public type's conformance to `ByteTransform` needs public
  witnesses; `Zlib.defaultLevel` and `defaultStrategy`, default arguments of public functions; `PBZError`'s cases (an
  enum's cases take its access); the DEFLATE and Brotli coders (SocketStream's stages) and the parallel DEFLATE coders
  (NativeZip, Disk); BytesCompressionAsync's engine as it was: its public, inlinable initializers (which clients call
  through typealiases: `SegmentStream(stage:…)`) reach `BlockPoolSizing`, `BlockBufferPool`'s initializers, `BlockKind`,
  `BlockContext`, and `BlockStage`, so narrowing them means `@usableFromInline` on each, for no client's benefit.
- `DecompressionFormat.zstd(maximumWindowSize:)`'s default is now written `1 << 27`: a public case's default can't name
  the package `ZstdDecoder.defaultMaximumWindowSize`. Test `formatsDefaultWindowIsTheDecoders` checks they agree.

Instructions: of the 294 rows in `fix-E2-after`, the D9 rows above moved; every other row is within ±0.3% but six
coder-construction rows under 20 K instructions (±0.4 to ±2.5% both ways, `Reused coder, 64 B stream: LZVNEncoder`
−2.5%, `DeflateDecoder` +1.7%: rows that small vary that much between processes). Zstandard's 66 encode rows, Brotli's,
XXH64's, and CRC-64's are within ±0.3%. HTTPBytes' HPACK and QPACK rows: 27 of 28 equal, one +0.05%.

### Tests

- Breaks, each once: `MaskedTable`'s mask halved, `MaskedTableTests` 44 issues; DEFLATE's chain write at `current + 1`,
  `DeflateEncoderTests` 2 issues; LZ lines written at `hash ^ 1`, LZVN's and LZFSE's encoder suites and their parity
  suites (3,110 and 3,376 issues); `WordReads.load64` and `value(_:)` big-endian, XXHash64Tests (884), BrotliEncoderTests
  (189), the LZMA/xz suite (1,004, through CRC-64), DecompressorTests (2); HTTPBytes' ring read at `number + 1`, HPACK and
  QPACK example and round-trip suites (17, 83, 11).
- Default sets, all passing: BytesCompression 372 tests in 66 suites; Bytes (390 in six bundles, `MaskedTableTests`
  new); NativeZipArchive 65; NativeAEA 81; Disk 72; HTTPBytes (268 in six bundles, the four known issues as before);
  MQTT 20; SocketStream through `Tools/toolchain SocketStream test`; Nunarchiver's 35 in 5 suites (`./build.sh` build
  and test, exit 0, signed ad hoc: AGENTS.md's flags, no team certificate here).
- Bulk, release: DeflateEncoderBulkTests, LZBitmapEncoderBulkTests, LZCompressionParityBulkTests, LZEncoderBulkTests,
  ParallelDeflateBulkTests, PipelineBulkTests, ZstdEncoderBulkTests (26 tests in 7 suites); HTTPBytes' HPACK and QPACK bulk
  suites (10 tests in 7 suites).
- Zero-allocation gates (`thresholds check --filter 'Allocations:(Inflate|Brotli|Zstd|LZ|BZip2|Decompressor|Pipeline|Deflate|LZBITMAP|LZFSE|LZVN|LZMA).*'`):
  equal to the thresholds. HTTPBytes' `Allocations:` rows (it keeps no thresholds files): 0 mallocs.
- No warnings: `swift build --build-tests` in Bytes, BytesCompression, NativeZipArchive, NativeAEA, Disk, HTTPBytes and
  its Benchmarks (but the C references' own, in `TestData/`), MQTT, BinaryParsingComparison, BytesProbe; SocketStream
  with its PR toolchain (but its manifest's `-dyld_env` warning, as before).

## 2026-11-24, E1: making decoders, one spelling for whole buffers, LZMA's exact limit, `limitExceeded` (fix plan C4's decoders, D2, D4, D3; baselines `fix-E1-before` → `fix-E1-after`)

M1 Max; the machine also ran test suites during some runs: instruction counts judge the rows.
`Writeups/BytesCompression-Fix-Plan-2026-11-23.md` C4 (the decoders Phase C left, and the LZFSE and Zstandard encoders),
D2, D4, and D3 (review §2.4, §3.6, §3.8, §3.7).

### Making decoders (C4)

Where the instructions went was found with a probe package that makes one coder in a loop, under `Tools/profile`
(inlined frames attributed), before changing anything; zeroing was only part of it.

- **bzip2** (516 K): zeroing its 7.8 MB workspace. Now uninitialized but the 320-byte move-to-front list. Every region is
  written by a block before that block reads it (the proof per region is on `BZip2Workspace`): `tt`'s rows by the
  link pass (each byte's rows are its runs' targets), `back`, the runs and then the block's bytes, the segment walk's
  pages and records, the Huffman tables (every entry the decode reads), selectors, counts, starts, and lengths. The list
  stays zeroed because 16-byte loads of it reach past the symbols a block's header wrote (never selected: indices are
  below the symbol count). One read did reach unwritten memory with its value unused: the segment copy loaded the next
  page's link after a segment's last piece (a page that may not be full, so never linked); it now loads it only while
  the segment goes on.
- **Brotli** (124 K): 79% was computing the 704-entry insert-and-copy table per decoder. It's a literal now
  (`brotliCommandTable`, BrotliTableData.swift, generated from `Brotli`'s length tables; `makeCommandTable()` is kept as
  its derivation and `ConstantTableTests` checks the literal against it), copied into each decoder: the fast loop reading
  the global itself ran 1.1–1.7% more instructions on every decode row (dickens q5 286 M → 291 M), so the decoder keeps
  its copy. The window (512 KB) and the table arena (256 KB) are uninitialized: each is read only where written (the
  arena's tables are built whole before a symbol is decoded with them). The literal context map (16 KB) stays zeroed: as
  an `UninitializedBuffer` (written for the meta-block's block types before a literal is read) it saved its fill, but
  the q11 decode rows ran 0.4% more instructions (Main.css 4,669 K → 4,686 K; back to 4,669 K zeroed), mechanism not
  chased.
- **DEFLATE** (50 K): building the fixed code's two tables was over 90%. They're built once per variant (DEFLATE and
  Deflate64 differ in length code 285 and distance codes 30–31), in a lazy `static let`, and copied in (12 KB). The
  window (160 KB) and the tables (24 KB) are uninitialized: a decode reads only entries `HuffmanTable.build` wrote (all
  of a code's root and subtables), and the window only where this stream wrote it.
- **Zstandard** (23 K): zeroing 156 KB and building the predefined tables. The constants (predefined tables, codes)
  are built once and copied in (2.5 KB); the literal buffer (128 KB), Huffman table, and sequence tables are
  uninitialized (each built whole before use: the weights fill a Huffman table's `1 << width` entries,
  `buildSequenceTable` all `1 << log`); the scratch (2 KB) is zeroed.
- **LZRAVEN** (62 K): filling the initial model a `UInt16` at a time. The uniform distributions are one 32-byte store
  each (`stp`, a stepping pointer), `isMatch` 8 entries a store; the states and the working model aren't initialized
  (`reset()` copies the model in at every buffer's start; each block's `start()` writes all eight states).
- **LZBITMAP** (17 K): computing the 256 bitmaps' shuffles (42%) and zeroing the workspace (33%). The shuffles are
  computed once (a lazy `static let`) and copied in (4 KB); the rest is uninitialized (each chunk writes what it reads).
- **LZFSE decoder** (7 K): the 40 KB literal buffer uninitialized (written by a block's literal decode before its
  matches read it); the tables stay zeroed.
- **LZFSE encoder** (61 K): its 280 KB workspace uninitialized (a block writes its literals, triples, counts, frequencies,
  encoding entries, and block buffer before reading them). Its 512 KB match table must start at zero (an entry of 0 is
  out of reach), so it stays zeroed, and so does the **LZVN encoder**'s, its only allocation: unchanged.
- **Zstandard encoder** (127 K): the hash and chain tables (768 KB at level 3) must start at zero; the block's own
  regions (sequences and their codes, literals, staging: 608 KB) are written before they're read and are uninitialized.
- **Not done: lazy windows.** Allocating DEFLATE's and Brotli's windows on the first streaming call saved 1–2 K
  instructions a decoder, but made one more malloc for streaming users (an empty placeholder, then the window: HTTPBytes'
  per-body decoders 4 → 5 mallocs); uninitialized memory costs nothing until touched, so the windows are allocated
  eagerly again.

| `New coder per 64 B stream` (instructions, 3 significant digits) | Before | After | Change | Reused coder |
|---|---:|---:|---:|---:|
| BZip2Decoder | 516,000 | 18,000 | −96.5% | 16,000 |
| BrotliDecoder | 124,000 | 44,000 | −64.5% | 26,000 |
| DeflateDecoder | 50,000 | 11,000 | −78.0% | 4,081 |
| ZstdDecoder | 23,000 | 5,599 | −75.7% | 2,271 |
| LZRAVENDecoder | 62,000 | 13,000 | −79.0% | 5,439 |
| LZBitmapDecoder | 17,000 | 5,031 | −70.4% | 1,753 |
| LZFSEDecoder | 7,135 | 4,795 | −32.8% | 1,735 |
| LZFSEEncoder | 61,000 | 43,000 | −29.5% | 5,647 |
| ZstdEncoder level 3 | 127,000 | 88,000 | −30.7% | 21,000 |
| LZVNEncoder (its one table must start at zero) | 41,000 | 41,000 | 0 | 5,611 |

Output is unchanged: the default set and the touched codecs' bulk suites (below) pass with
`MallocPreScribble=1 MallocScribble=1`; a probe confirmed that pair fills fresh 64-byte-aligned allocations of 64 B to 8 MB
with 0xAA (`MallocPreScribble=1` alone left them zero). Breaks, each once: a changed command-table entry fails
`ConstantTableTests` and the Brotli decoder suite (6 issues between them); DEFLATE's fixed tables not copied, 281
issues; Zstandard's constants not copied, 167 issues (under scribbling). The zero-allocation gates
(`Allocations:(Inflate|Brotli|Zstd|LZ|BZip2|Decompressor|Pipeline|Deflate).*`) are still at zero.

### One spelling for whole buffers (D2)

- `decompressAll(_:into:decodedSize:)` everywhere: bzip2's, LZBITMAP's, and LZRAVEN's `(_:decodedSize:into:)`, and
  LZ4's `decompressRaw(_:decodedSize:into:)` (now `(_:into:decodedSize:)`), as `Decompressor`'s was.
- `LZBitmapEncoder.compress(_:into:)`, the one whole-buffer `compress`, is `compressAll(_:into:)`.
- Whole-buffer encoders all return nothing: LZFSE's and LZVN's `compressAll` returned the bytes appended, which the
  output span's count says; seven of the ten (Brotli, DEFLATE, Zstandard, both parallel encoders, `Compressor`, LZBITMAP)
  returned nothing.
- `LZMA2Decoder`'s four entries, `decompressXZ`, `decompressLZMA`, `decompressLZMA2`, `decompressLZMAFile`, are
  `decompressAll(_:into:)` (`.xz` files: the one another package uses), and `package`
  `decompressAll(_:properties:into:decodedSize:maximumSize:)` (raw LZMA: `Decompressor`, the benchmarks) and
  `decompressAll(_:dictionarySize:into:)` (raw LZMA2: the tests). The `.lzma` file reader (a 13-byte header, then raw
  LZMA) had only tests as clients; it's theirs now (LZMADecoderTests).
- `Decompressor.decompressAll(_:maximumSize:decodedSize:)`: a whole stream into a new array, reserved once
  (`decodedSize`, or `maximumSize` without it) and decoded into in place through `append(addingCapacity:)`: nothing
  zeroed or copied. NativeAEA's XIP reads its TOC and `Metadata` with it, where it zero-filled an array and checked the
  size again itself. Test `wholeIntoNewArrays` (every format, at its size and up to a maximum, a maximum a byte short, a
  size above the maximum); with the size-above-maximum check removed, 18 issues.
- Callers moved: the benchmarks, tests, NativeAEA's `SegmentDecoder`, XIP; docs (ARCHITECTURE.md, LZRAVEN-FORMAT.md,
  NativeAEA's ARCHITECTURE.md, Bytes' OPTIMIZATION.md).

### LZMA's exact limit (D4)

`.lzma(properties, uncompressedSize:, maximumSize:)` (was `sizeHint:`, which only capped the window): the most a
stream ending with its marker may decode to. `LZMADecoder` stops its loops at the maximum and, there, decodes only the end
marker; the whole-buffer path limits its output the same way; a match that would cross it, or any symbol at it but the
marker, throws `BytesError.limitExceeded`, and nothing past the maximum is written (what was decoded since the last
delivery isn't delivered: the call throws). `DecompressionFormat.zipLZMA` passes a ZIP entry's size as the maximum, and
NativeZip's own counting is gone (NativeZipArchive/Benchmarks/RESULTS.md). The window is the maximum's size (it was the
hint plus 64 KiB and two longest matches). Tests `lzmaMaximumSizeStopsAtTheFirstBytePast` (streamed and whole, maximums
from 0 to the size less one, and the size), the LZMA streaming suite's size-hint test; with the maximum ignored, 22
issues.

### `limitExceeded` (D3)

`BytesError.limitExceeded` (Bytes) for limits the caller set: Zstandard's `maximumWindowSize` (and the package
`ZstdDecoder.decompress(_:maximumSize:)`), LZMA's and xz's `maximumDictionarySize` and a window a known size capped
(`LZMAWindow.makeRoom`), LZMA's `maximumSize`, and the array one-shot's `maximumSize`. `insufficientCapacity` stays the
output's room. The parallel inflate budget isn't a limit: its last throw is the in-place decode's
`insufficientCapacity`, the output's room, as the sequential decoder's (unchanged). HTTPBytes maps the case to `tooLarge`
instead of reading `freeCapacity` (HTTPBytes/RESULTS.md); NativeZip's `zipError` switch (the one exhaustive switch over
`BytesError` in the repository) takes it; `ZipError` and `AEAError` keep it as a decoding error. Tests that expected
`insufficientCapacity` from these limits (the Zstandard window in `DecompressorTests` and `ZstdDecoderTests`, xz's
dictionary limit and size hint) now expect `limitExceeded`.

### Instructions elsewhere

Of the 272 other instruction rows saved (every decode row of the formats touched, the LZFSE, LZVN, and Zstandard encode
rows, LZMA's small streams, `Decompressor`, the TLS + inflate and Brotli pipelines), 269 are within ±0.3% (Brotli's
decode rows equal, after the two Brotli changes above were found by them). The three that aren't are under 120 K
instructions, where processes differ by that much: `Pipeline TLS + brotli receive JSON (1.6 KB)` 58 K → 59 K, `Zstd
encode L3 body xml 4 KB` 117 K → 118 K, `LZ4 raw decode JSON (1.6 KB)` −0.7%; and the reused-coder rows under 6 K move
±0.5–4% both ways (`LZMA2Decoder` −4.1% with its code unchanged). Mallocs: equal everywhere. NativeZip's rows equal;
HTTPBytes' decoders made per body: gzip −0.8 to −0.9%, `br` −4.3%.

### Tests

- Default set: 371 tests in 66 suites pass; Bytes, Disk, MQTT, NativeZipArchive, NativeAEA, HTTPBytes, SocketStream
  (`Tools/toolchain SocketStream test`), Nunarchiver's tests (35 in 5 suites, after removing stale `Bytes`,
  `BytesCrypto`, `BytesFoundation`, `BytesTestSupport`, and `DiskTestSupport` modules from its derived data: AGENTS.md's
  lesson) pass; every package builds its tests without warnings (but SocketStream's manifest's `-dyld_env` linker-flag
  warning, as before).
- Bulk, release (`BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing`), with `MallocPreScribble=1
  MallocScribble=1`: BrotliDecoder, BZip2, BZip2Streaming, Deflate64, DeflateDecoder, GzipMembers, LZBitmapDecoder,
  LZBitmapEncoder, LZCompressionParity, LZEncoder, LZMA, LZMAStreaming, LZRAVEN, ParallelInflate, ParallelInflateSegment,
  Pipeline, StreamEnd, StreamingUnit, Zstd, ZstdEncoder: 64 tests in 20 suites pass (and 56 in 17 after the construction
  changes alone).

## 2026-11-24, later: `PBZ.header`, HTTP's decoding knowledge, one DEFLATE decoder, shared in-order delivery, the carry region (fix plan D1, D5, D6, D8, D10's parts; baselines `fix-D-before` → `fix-D1-after`, and `fix-D6-old-N`/`fix-D6-new-N`)

M1 Max, shared with another agent's builds: instruction counts judge the rows.
`Writeups/BytesCompression-Fix-Plan-2026-11-23.md` Phase D items D1, D5, D6, D8, and D10's parts in these files (review
§3.3, §3.9, §3.10, §3.12, §4).

**D1: `PBZ.header(_:)`.** A stream's compression and block size from its first bytes, `nil` when they don't start a
`pbz` stream (no magic, fewer than 4 bytes, an unknown letter), `PBZError.headerCutShort` when they start one but end
within its 12 bytes (`PBZ.blockSize` threw `.header` for that), `.header` for a block size of 0 or over 256 MiB.
NativeAEA's three readers (the first AEA segment, an `.aar`, a `.xip`'s content) each detected, checked the length, and
read the size; now each calls it. `PBZ.blockSize(_:)` is gone (`header` is its one caller's form); `compression(_:)`,
`blockSizes(_:index:blockSize:available:)`, and `blockHeaderSize` are `package` (BytesCompressionAsync's inlinable
producers and the tests use them; no other package, BytesProbe, or the app does). Test `readsPBZFraming` (every cut
length from 4 to 11 bytes, 3 bytes of magic, an unknown letter, block sizes 0, 256 MiB, and one over).

**D5: HTTP's decoding knowledge here, and one DEFLATE decoder.**
- `DeflateFormat(zlibOrRaw:)`: zlib or raw DEFLATE by the first two bytes (method 8, a window of at most 32 KiB, a
  multiple of 31; `nil` for fewer than two), HTTPBytes' sniff moved here. The decoder's own zlib header check uses the
  same predicate (`ZlibHeader.isDeflate`). Test `zlibOrRawDecidesByTheHeader`: our zlib streams at every level and zlib's
  at every window are zlib, our raw streams at every level are raw (their first block's bits can't make method 8), and
  each rule's edge.
- HTTPBytes asks `DecompressionFormat.allowsConcatenation` whether an end may be followed by more, instead of its own
  list, and maps its codings to formats in one property (HTTPBytes/RESULTS.md).
- `DeflateDecoder.reset(format:)` (`package`; `invalidValue` for zlib or gzip on a Deflate64 decoder): `Decompressor`
  keeps one DEFLATE decoder for raw, zlib, and gzip, and one Deflate64, instead of four. Memory, measured with
  `malloc_zone_statistics` in a probe run alone: a `Decompressor` that has decoded all three containers holds
  189,120 bytes; the three decoders it kept before held 584,384 (−386 KiB, 184 KiB each: a 160 KiB window and 24 KiB of
  tables). Tests `oneDeflateDecoderTakesEveryContainer` (a gzip stream left a third decoded, then zlib whole, raw, gzip,
  two gzip members, and zlib in pieces, twice; the decoder's own resets, Deflate64's refusals), which failed with the
  reset not changing the container (34 issues), and the existing `Decompressor` suites, which reset between containers.
- Instructions: the 96 inflate rows `fix-B-bc-after` (phase B's last baseline, the main tree) and `fix-D1-after` share: 94
  unchanged, one −0.1%, one +0.3%; against `fix-D-before` (this tree, before D): all within ±0.4% but the parallel
  inflate rows of 256 KB (−1%; the old code read the same as the new in the interleaved runs below, 2,650 K sync, so
  `fix-D-before` ran under load) and a 39 K-instruction TLS + inflate row (−2.6%: rows under 100 K vary that much
  between processes). The format became a stored `var` in `InflateStream` (it was a `let`): no row moved. `Allocations:Decompressor_every_format`
  (raw, zlib, gzip, xz, LZMA, LZFSE, LZVN, LZBITMAP through one `Decompressor`) stays at 0 mallocs.

**D6: shared in-order delivery, one stop flag, and the decoder's task-group form.**
- `Mutex.deliverInOrder(claim:copy:record:)` (`ParallelScheduler.swift`): the loop `ChunkScheduler.deliverReady` and
  `InflateDelivery.deliverReady` each had (claim the next piece under the lock while no worker is copying, copy outside
  it, record under it), once; each keeps only its own rule for "ready" and what it records.
- One stop flag, `StopFlag`, per call: `ChunkScheduler`'s own `stopped` atomic (cleared at each call's start) is gone;
  a `ChunkBatch` makes one and hands it to its workers, the synchronous `compressAll` passes none, and the decoder's async
  forms pass theirs as before. `ParallelBlockDecoder`'s stop stays its own: a failure value under its lock that also
  stops an upstream and wakes the consumer, not a flag the workers poll.
- `ParallelDeflateDecoder.decompressAllConcurrently(_:into:)` (BytesCompressionAsync), as both encoders have: the
  segment workers are child tasks of a task group, and the call's sequential parts (the plan, the join and its
  repairs, a sequential decode, gzip's later members) run in a child task of their own, never on the caller's
  executor. The synchronous call is now the same steps (`plan`, `segmentBatch`/`InflateScheduler.work`,
  `joinSegments`, `decompressSequentially`, `decompressMembers`, `package`), with its workers on `concurrentPerform`;
  the call's shared state (`InflateScheduler`: the segment counter, the budget, the delivery) is made once with the
  decoder, so the synchronous call still allocates nothing. Tests: `concurrentFormMatchesTheSynchronousOne` (parallel,
  sequential, gzip members after a parallel first one, repaired segments, a bad CRC, an output a byte short: the same
  output or error, and the same segment count, both ways), `asyncFormMatches` (both async forms), and the cancellation
  suite with the new form (cancelled before the call, and while it runs); the parallel codecs' bulk suites (corpus at
  every lane count, 3 MB through both async forms) in release.
- Instructions: the old code can't run beside the new in one process (the change is the scheduler both encoders and
  the decoder share), so old and new were built side by side (the D6 files reverted in an APFS copy of the package)
  and run alternately, old, new, old, new, all 37 `Parallel` rows each time (`fix-D6-old-1`, `fix-D6-new-1`,
  `fix-D6-old-2`, `fix-D6-new-2`). Every row whose count is deterministic is the same in all four runs (the inflate
  rows, the 256 KB and Main.js rows, dickens' Brotli and level-1 rows); the samba rows, whose counts include the
  workers' spin-waits for a slot (`sched_yield` loops), spread as much between the two old runs as between old and new
  (DEFLATE level 6 on 10 lanes: old 2,021 M and 1,950 M, new 1,931 M and 1,991 M). Flat. (`fix-D-before` →
  `fix-D1-after` had shown −4 to −8% on those samba rows and +13.5% on one async row: `fix-D-before` ran while
  HTTPBytes' benchmarks were building, and a second after-run alone gave −0.7% for the async row. Compare spin-waiting
  rows only interleaved, on an otherwise idle machine.)

**D8: the carry region is the client's.** `BlockBufferPool` had Apple Archive's 64 KiB header limit built in
(`static carryCapacity`); now it's an instance property set by the pool's initializer, `sizing`/`sized`
(`carryCapacity:`, recorded in `BlockPoolSizing`), and every `ParallelBlockDecoder` initializer (default 0). Staging
pools have none. NativeAEA passes 64 KiB to every source a walker reads (NativeAEA/RESULTS.md). Test
`carryRegionIsTheClients` (strides with and without, a carry of the region's size landing before the next block, an
engine's pool and its staging).

**D10 (these files).** ARCHITECTURE.md: §1's HTTP row as the mapping now is (one property, deflate decided by its
bytes, concatenation the format's, one shared DEFLATE decoder); the diagram's BytesCompressionAsync box lists
`ParallelCodecs.swift`, and the synchronous box the parallel codecs; §3's pool bullet the carry parameter; §5 the
parallel codecs' schedulers (`ChunkScheduler`, `InflateScheduler`), what they share, and why they aren't the block
engine. The stage-2 note below that HTTPBytes keeps its Zstandard decoder now says it was done in stage 3. NativeZip's
`ZipDecoder.chunkSize` (unused, a lazy `static let`) is gone.

## 2026-11-24: Small inputs and making coders (fix plan C0–C5; baselines `fix-C-before` → `fix-C-after`)

M1 Max, shared with another agent's builds: instruction counts judge the rows, and cycles come from a driver reading
`proc_pid_rusage` around each case (the minimum of 12 runs, old and new builds alternated).
`Writeups/BytesCompression-Fix-Plan-2026-11-23.md` Phase C, the review's §2.1–2.5.

### New rows (C0)

- `Deflate 1|6 small streams N × 64 B|1 KB|4 KB dickens: Bytes`, and `: libdeflate` beside them: pieces of dickens
  through one reused encoder (1,000, 200, and 50 pieces an iteration).
- `LZBITMAP encode small streams N × 1|4|16 KB dickens: Bytes` and `: Compression`: each piece with 64 KiB of room, as
  `aa` gives every APFS chunk; setup checks Bytes' streams are Compression's, byte for byte.
- `New coder per 64 B stream: CODER` and `Reused coder, 64 B stream: CODER` for every coder (8 encoders, 10 decoders): a
  coder made, used for one 64-byte stream, and destroyed per iteration, against one kept; the difference is what a client
  that makes a coder per stream pays (lazily made state is made on the first stream, so the rows include it).
- HTTPBytes/Benchmarks: `Body 1.6 KB JSON, encoded gzip (level 6), per message: HTTPBytes content encoder, reused`.

### Stride-typed tables (C1)

`StrideTable<Group: SIMD>` (StrideTable.swift): a table of `Group.Scalar` entries in whole groups, allocated by the
table at a 64-byte boundary, so every group is aligned for its type by construction and a fill can't start misaligned or
end inside a group (the user's note: tables typed by their stride). `fill(_:)` and `fill(_:groups:)` store a group at a
time; `clear()` and `clear(groups:)` are a typed zero fill, which LLVM makes one `memset`. It replaces `LZMAWorkspace`'s
hand-written copy of the pattern and `DeflateCompressor.clear`'s run-time alignment check (`UniqueArray<Int16>` promises 2
bytes; a `SIMD8<Int16>` store needs 16).

- **LZMA's workspace, ported first**, with its codegen checked identical: `LZMAWorkspace.reset` was the same 4-instruction
  `vector128` loop (`str q0, [x1, x9]`, `add #16`, `cmp`, `b.lt`; 1,004 stores for lc 3) and an 11-instruction body,
  before and after. Then one change to the shared fill: a pointer that steps instead of an offset, so the stores
  post-index (`str q0, [x9], #16`): 3 instructions a group, the same 1,004 stores. "LZMA small streams" −0.1 to −0.2%
  (−1.0 K instructions a stream, one per group). A new or grown model is filled the same way (it was filled a `UInt16`
  at a time: 8,032 `strh` loop iterations for lc 3).
- **DEFLATE's tables** are `StrideTable<SIMD32<Int16>>`: 64 bytes a group, cleared with two `stp` a group, 4
  instructions per 64 bytes (6 with an offset: `stp` has no register-offset form; 12 before, 16 bytes a store).
- **LZBITMAP's hash table** is the first 8,193 groups of a `StrideTable<SIMD32<UInt16>>` that holds the encoder's whole
  workspace (below).

Storage that's written before it's read (windows, staged output, DEFLATE's sequences, Brotli's commands) is a second,
smaller type in the same file, `UninitializedBuffer<Element>`: exact counts, no fills.

### DEFLATE's reset (C2)

`reset()` clears only the heads its level reads: none at level 0 (which only stores), the 2-entry buckets at level 1, and
both head tables at 2–9; 64 bytes a store. Level 0 allocates no tables, level 1 no 3-byte heads or chains. `Compressor`
moved to another level of the same container keeps its encoder (`DeflateEncoder.reset(level:)`, internal), allocating a
table when a level first needs it. Output is unchanged: a harness encoding 1,370 cases (every level, raw and gzip, one
shot through fresh and reused encoders, streamed with flushes, both parallel encoders, Brotli at five qualities) gave
identical bytes from the old and new builds, and again with `MallocPreScribble` (fresh memory filled with 0xAA).

**The 3-byte heads matter only for inputs under 512 bytes**: those parse with a minimum match of 3, the only matches the
3-byte heads find; longer inputs' minimum (from their literal count) is 4 or more. Left uncleared at levels 2–9, every
existing test passed; `DeflateLevelChangeTests` (a stream at one level, then one at another, against a fresh encoder: 5 ×
5 levels on 4 KB and 400 bytes, all 100 pairs on 64 KB in bulk) traps with the clear removed (index out of bounds, from a
stale head's distance).

### LZBITMAP's table (C3)

Positions are stored less 8 (`LZBitmapEncoding.positionBias`): Compression starts every bucket at position 8, which is
now 0, so the clear is a `memset` (the review: 12.3 K against 18.5 K cycles for the 512 KB table). A group takes its
position less the bias once, as a 16-bit value stepped with the position (`entry`), inserts each lane at `entry + k`, and
takes its candidates' base from it, so the bias cancels in every period. Byte for byte Compression's on every corpus file
and capacity (`LZBitmapEncoderTests`, `LZBitmapEncoderBulkTests`); with the bias set to 0 but the zero clear kept, the
parity tests fail (102 issues).

What it took to keep the loop's instructions:
- **The table as an allocation of its own cost 1.8% on large inputs** (one more pointer live in the group loop, and
  spills): it was the workspace's base before. It's back at offset 0 of one allocation (a `StrideTable` of the table's
  group type, the other regions after it as raw memory). Without that, even with no bias, the rows read +1.7 to +3.6%.
- **Adding the bias per insert made LLVM keep eight loop invariants**: loop strength reduction rewrote `position − 8 + k`
  as `(start − 8 + k) + i` for each k, and they spilled (+8 loads a group). `Builtin.freeze_Int64` didn't stop it
  (InstCombine drops a freeze of a value that can't be poison); `entry | k` did, but cost an `and` per insert. The stepped
  16-bit entry gives one `add #8` a group in place of the position's `add`, and immediates after it.
- **What's left**: `bfi` is destructive, so the lane-0 insert copies the stepped entry first (`mov`, +1 instruction a group
  that repeats at its period; a register move the cores eliminate at rename). The group loop (`Tools/loops … compressedChunk`)
  is 437 instructions against 438 in the main path, 70 against 69 in the copy path. (Correction, 2026-11-24: those two
  "loops" were the old `Tools/loops`' address ranges; with natural loops it is one innermost loop of 477 instructions,
  both paths sharing its header. The before/after comparison of the paths stands.)

| Rows (instructions, p50 from HDR histograms) | Before | After | Change | Cycles change |
|---|---:|---:|---:|---:|
| 100 × 1 KB dickens | 8,847,360 | 7,213,056 | −18.5% | −25.5% |
| 50 × 4 KB | 9,338,880 | 8,527,872 | −8.7% | −15.8% |
| 16 × 16 KB | 9,224,192 | 8,970,240 | −2.8% | −4.0% |
| dickens 64 KB × 16 (APFS chunks) | 34,275,328 | 34,045,952 | −0.7% | −1.3% |
| xml 64 KB × 16 | 23,085,056 | 22,904,832 | −0.8% | −1.7% |
| x-ray 8.1 MB, one stream | 275,775,488 | 275,775,488 | 0.0% | +0.2% |
| dickens 9.7 MB | 325,058,560 | 325,320,704 | +0.08% | −0.1% |
| samba 16 MB | 402,391,040 | 403,439,616 | +0.26% | −0.1% |
| xml 5.1 MB | 108,724,224 | 109,182,976 | +0.42% | −0.1% |

Every 64 KiB chunk (Disk's and `aa`'s case) is faster; single streams of megabytes pay up to 0.4% in instructions (as
much as their share of groups copied at the current period) and no cycles (−0.3 to +0.2%, the move eliminated).

### Making coders (C4)

Allocations made uninitialized, filled where they're read before they're written (now a group at a time), and left
untouched where they're written first: making a coder had zeroed megabytes it might never reach (Brotli's 4 MB window
with a one-shot encoder, which never uses it) and filled 128 K `Int16`s one at a time. Pages a stream never reaches are
now never touched.

- DEFLATE: tables filled a group at a time; sequences (400 KB), staging (616 KB), and the streaming window (288 KB)
  uninitialized. The parallel encoders' slots and window too.
- Brotli: window (4.25 MB), staging (544 KB), and commands (1 MB) uninitialized; the bucket counts, which qualities 1
  and 2 (one entry a bucket) never read, not allocated there. The buckets stay zeroed (0 is empty).
- LZBITMAP: the workspace uninitialized but its constants and scratch (the key choices' unwritten bytes are zeros the
  loop reads); the table is cleared at each call anyway.
- LZMA, LZMA2, xz: the probability model filled a group at a time.

| `New coder per 64 B stream` (instructions) | Before | After | Change | Reused coder |
|---|---:|---:|---:|---:|
| BrotliEncoder quality 1 | 816,128 | 75,072 | −90.8% | 32,352 |
| BrotliEncoder quality 5 | 873,472 | 167,168 | −80.9% | 68,160 |
| DeflateEncoder level 1 | 197,248 | 81,472 | −58.7% | 46,752 |
| DeflateEncoder level 6 | 209,536 | 102,848 | −50.9% | 56,160 |
| LZBitmapEncoder | 104,640 | 53,376 | −49.0% | 34,880 |
| LZMA2Decoder (.xz whole) | 74,880 | 12,848 | −82.8% | 2,988 |
| XZDecoder (streamed) | 76,608 | 11,088 | −85.5% | 3,810 |
| LZMADecoder (raw, streamed) | 73,856 | 35,776 | −51.6% | 29,760 |

Unchanged, and why: `LZFSEEncoder` (61 K) and `LZVNEncoder` (41 K) share a 512 KB match table that must start at zero
(an entry of 0 is out of reach) and LZFSE's literal slack must be defined (wild copies read it); `ZstdEncoder` (127 K) is
mostly hash and chain tables that start at zero (768 KB of its 1.4 MB at level 3), and its literals' slack is read too.
The decoders the other agent is changing (`BZip2Decoder` 516 K: 7.8 MB, its links must be below 2²⁰ before a block
writes them; `BrotliDecoder` 124 K; `DeflateDecoder` 50 K) and `ZstdDecoder` (23 K), `LZRAVENDecoder` (62 K) were left;
the rows measure them for whoever does.

### DEFLATE on small inputs (C2 and C4 together)

| Rows (instructions per stream) | Before | After | libdeflate | Cycles before → after |
|---|---:|---:|---:|---:|
| level 1, 64 B | 74,973 | 46,236 (−38.3%) | 42,369 | 23,517 → 16,867 (−28.3%) |
| level 1, 1 KB | 122,061 | 93,307 (−23.6%) | 87,572 | −18.2% |
| level 1, 4 KB | 248,709 | 219,873 (−11.6%) | 207,094 | −7.8% |
| level 6, 64 B | 79,364 | 54,788 (−31.0%) | 58,786 | 24,448 → 21,582 (−11.7%) |
| level 6, 1 KB | 180,552 | 156,058 (−13.6%) | 141,804 | −5.7% |
| level 6, 4 KB | 502,333 | 477,757 (−4.9%) | 383,386 | −1.8% |

Level 6 at 64 bytes now runs fewer instructions than libdeflate. Other rows: `Deflate 1 JSON (1.6 KB)` −23.3%, `Deflate
6 JSON (1.6 KB)` and gzip −12.5%, `Pipeline deflate 1 + TLS send JSON (1.6 KB)` −21.5%, the 119 KB JSON rows −1.0%;
every large row equal to the histograms' resolution (`Deflate 1 dickens` 436,207,616 both).
HTTPBytes' new row, a 1.6 KB gzip body per message: 207 K → 183 K instructions (−11.6%), still no allocations.

### Brotli quality 1 on small inputs (C5): profiled, not changed

Quality 1 on the 1.6 KB JSON is 150 K instructions against Google's 69 K (quality 5 is at parity). Time Profiler
(`Tools/profile`, inlined frames attributed): 28% building Huffman codes (`sortSymbols` 9%, `assignCanonicalCodewords`
7.5%, `reversed` 4.9%, the rest of `HuffmanCodeBuilder` 7%), 18% unaligned loads in the match finder's parse, 6%
`storeComplex`, 4% `writeCommands`, 7% inlined bounds checks (`_checkIndex` on spans and `InlineArray`s), 5% range
iteration. The code builder is libdeflate's, and costs in proportion to the alphabet (704 command symbols), not to the
symbols a 1.6 KB block uses. Google's qualities 0 and 1 are a different encoder (`compress_fragment.c`: one pass, a
fixed command code layout, `BuildAndStoreHuffmanTreeFast`), so closing the gap is a port of that path, not a tweak of
this one; nothing was changed without a measured gain to show.

### Tests

- New: `StrideTableTests` (alignment for 16- and 64-byte groups, fills of some groups, clears, growth, empty tables,
  `UninitializedBuffer`), `DeflateLevelChangeTests` (fast) and `DeflateEncoderBulkTests.levelChangesEncodeAsAFreshEncoder`.
- The default set (363 tests in 65 suites) passes; the encoder suites also with `MallocPreScribble=1 MallocScribble=1`.
- Bulk, release (`BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing`): `LZBitmapEncoderBulkTests` (the corpus as
  64 KiB chunks and whole, capacities), `DeflateEncoderBulkTests`, `LZCompressionParityBulkTests`, `LZEncoderBulkTests`,
  `LZMABulkTests`, `LZMAStreamingBulkTests`, `ParallelDeflateBulkTests`, `PipelineBulkTests`: 28 tests in 8 suites pass.
- The zero-allocation gates (`thresholds check --filter 'Allocations:(Deflate|Brotli|LZBITMAP|LZFSE|LZVN|Zstd|Decompressor|LZMA|Pipeline).*'`)
  are still at zero.
- Disk's suite (72 tests) passes; Disk's compressed-extraction rows moved within their noise (kernel time in the
  instruction counts: the codec-free "plain" rows moved −1.7% and −2.6%).

## 2026-11-24: Honest units, and headers read a part at a time (fix plan A3 and B9; baselines `a3-before` → `a3-after`)

M1 Max, shared with another agent's builds: instruction counts, not times, judge the rows.
`Writeups/BytesCompression-Fix-Plan-2026-11-23.md` items A3 and B9, the review's §1.3 and §3.1.

### What was wrong

`ByteTransform.maximumUnitByteCount` is the most unconsumed input a call may need before it can make progress; `Pipeline`
sizes its buffer by it and traps when a stage holds more. bzip2 and Brotli declared 1 (the default) and held a block's
tables or a meta-block's header back until all of it had arrived, reading it again from its start on every call:
- a `Pipeline` with 256-byte buffers trapped on a valid 49 KB bzip2 stream, and on Brotli's `-q 11` output of mozilla,
  x-ray, dickens, and samba with 1 or 2 KB ones (x-ray's first 2 MB held 4,852 bytes back here; the whole file, 7,780);
- a corrupt bzip2 stream's code lengths could step `+1 −1` without end, so what it held had no bound at all;
- input arriving a little at a time cost the square of a header's size: a crafted 189 KB Brotli header in 97-byte steps
  took 2.69 s, a byte at a time about 97 times that.

DEFLATE declared 1 too, holding up to a dynamic block's header (its docs said 512 bytes).

### The fix: each header in parts, each part whole

**bzip2** (`BZip2Stream.readTableHeader`, `readTableBody`, a `.tables` streaming stage with `BZip2TableProgress`): the
block's header and symbol map through the selector count are one part (395 bits at most, read again from the block's
magic as before); then the selectors 256 at a time; then each table's code lengths, its decoding tables built when they're
read. A part that runs past the input's end is left for the next call; the parts before it stay read (selectors, lengths,
and built tables are in the workspace already). A code length now takes at most 20 steps of ±1 from the last
(`maximumLengthSteps`: lengths are 1 through 20, so 19 reach any; libbzip2 writes the fewest): the 21st is
`invalidValue`. That bounds the largest part, one table's lengths, at 5 + 258 × 41 = 10,583 bits, so
`BZip2Decoder.maximumUnitByteCount` is 1,324 bytes (the part from any bit of its first byte). The whole-buffer decoder runs
the same two functions (an incomplete body is `insufficientData`), so both paths refuse the same streams.

**A deliberate difference from libbzip2**, which accepts any number of steps: a real stream with 12 `+1 −1` pairs added to
its first code length decodes there, to the same bytes (the CRCs cover the data, not the bits), and is `invalidValue`
here (`StreamingUnitTests.libbzip2TakesStepsTheBoundRefuses`). No encoder writes such pairs.

**Brotli** (`BrotliStream.readCompressedHeader`): a compressed meta-block's header is read a part at a time (`HeaderPart`):
each category's block types (its count, block-type and block-count codes, and first count), the distance parameters with
the context modes and the literal map's code, every context map entry one at a time, each map's move-to-front bit, and
every literal, command, and distance tree. The stream keeps the part it's at, the tree counts, and the map's code and next
entry; a part that runs past the end drops the tables it built (`BrotliPrefixCodes.mark` / `removeAll(after:)`) and is read
again on the next call. The largest part is a command tree's prefix code: 2 + 18 × 4 + 5 × 704 = 3,594 bits (a complex
code's HSKIP and code-length code, then at most 5 bits a symbol: a repeat code's 7 or 8 bits cover at least 3), so
`BrotliDecoder.maximumUnitByteCount` is 451 bytes. A crafted header with 256 block types and trees of every kind, full
context maps, and every symbol's length in 5 bits (each command code 2 bits short of the worst case; 189 KB in all) held
back 449. Resumable parsing was not invasive: the header's
code was already a sequence of reads into the stream's own state; it became a loop over parts with a commit after each.

**DEFLATE** declares 289 bytes: a dynamic block's header (3 + 14 + 19 × 3 + 318 × 7 = 2,300 bits, read whole as before).
gzip's names, comments, and extra field are taken as they arrive; Zstandard keeps partial units itself (1); LZMA 20; xz
65,542.

**Per format:** `DecompressionFormat.maximumUnitByteCount` (`Int?`, `nil` for the whole-buffer formats), and
`Decompressor.maximumUnitByteCount` the largest of them (xz's). `ChunkedDecompressor.stagingCapacity` became
`stagingCapacity(for:)`: twice the format's unit and at least 256 KB, which is every format's (`start` grows the buffer
for a format that needs more; none does now). NativeZip's `StagedInputTests` takes the size from it. HTTPBytes' carry
buffer was 132 KiB "for Zstandard's largest block" (Zstandard holds back nothing); it's now twice the largest unit of its
codings, Brotli's: 902 bytes.

### Measured

The most input held back fed a byte at a time (`StreamingUnitBulkTests`: each Silesia file's first 2 MB; zlib at 9,
Brotli at 11, zstd at 3, bzip2 at 9, xz at 6), against each unit:

| Format (unit) | dickens | mozilla | x-ray | samba | xml | ooffice |
|---|---:|---:|---:|---:|---:|---:|
| DEFLATE (289) | 81 | 124 | 87 | 91 | 78 | 125 |
| Brotli (451) | 102 | 151 | 79 | 105 | 119 | 151 |
| Zstandard (1) | 0 | 0 | 0 | 0 | 0 | 0 |
| bzip2 (1,324) | 81 | 99 | 97 | 82 | 75 | 97 |
| xz (65,542) | 61,445 | 61,444 | 61,445 | 61,446 | 61,447 | 61,445 |

Input in small steps (release; "before" is the new code with each header restarted from its start on every call, as the
old code did):

| Stream, step | held back before | held back after | time before | time after |
|---|---:|---:|---:|---:|
| x-ray `.br` (`-q 11`), first 2 MB, 1 byte | 4,852 | 81 | 0.64 s | 0.16 s |
| x-ray `.br`, first 2 MB, 64 KiB | 3 | 3 | 27 ms | 24 ms |
| crafted Brotli header, 189 KB, 97 bytes | 189,148 | 449 | 2.69 s | 6.9 ms |
| crafted Brotli header, 1 byte | | 449 | (not run: about 4 min) | 0.38 s |
| bzip2's largest tables (32,767 selectors, 6 × 258 lengths of 20 steps; 32.5 KB), 97 bytes | 32,442 | 1,314 | 14.9 ms | 0.5 ms |
| the same, 1 byte | | 1,323 | | 32 ms |

Decode rows (exact p50s read from the unslimmed baselines' histograms: `bench-table`'s 3 digits turn a 100-instruction
change on a 1.6 KB row into +1.5% or +1.8%): every decode row on a whole file or 119 KB within ±0.15% (minimums within
±0.04%); encode rows (untouched) within ±0.2% but three parallel samba rows (−1.0 to +0.4%, their usual spread); mallocs
0 on every `Allocations:` row, before and after. The small streams pay the parts' bookkeeping (a store of the part and
position per part, a commit per map entry), a few hundred instructions a stream:

| Row (instructions, p50; minimum) | before | after | |
|---|---:|---:|---:|
| Brotli decode q11 JSON (1.6 KB): whole | 67,328; 67,381 | 67,584; 67,517 | +0.38%; +0.20% |
| Brotli decode q11 JSON (1.6 KB): streaming 64 KB | 67,712; 67,741 | 68,032; 68,025 | +0.47%; +0.42% |
| Brotli decode q5 JSON (1.6 KB): whole / streaming | 55,040 / 55,424 | 55,136 / 55,520 | +0.17% / +0.17% |
| BZip2 decode -9 JSON (1.6 KB): whole / streaming | 84,224 / 86,208 | 84,416 / 86,272 | +0.23% / +0.07% |
| BZip2 decode -9 mozilla (48.8 MB): whole / streaming | 3,101.7 / 3,110.1 M | 3,105.9 / 3,112.2 M | +0.14% / +0.07% |
| Brotli decode q11 x-ray (8.1 MB): whole / streaming | 456.4 / 471.1 M | 456.4 / 471.1 M | 0.0% / 0.0% |

### Tests

`StreamingUnitTests` (fast): the declared units; every streaming format fed a byte at a time holds back less than its
unit; `Pipeline`s with 256-byte buffers decode a 180 KB block of bzip2, a `-q 11` Brotli stream, and the crafted header;
the crafted header decodes the same in Google's decoder and this one; 20 steps per length read, 21 refused (whole and a
byte at a time); a stream stepping `+1 −1` for 100 KB throws `invalidValue` whole, a byte at a time, and through a
`Pipeline` (which it trapped); the libbzip2 difference above; bzip2's largest tables in 97-byte steps.
`StreamingUnitBulkTests`: the corpus table above, the corpus through 256-byte `Pipeline`s (Brotli, bzip2, DEFLATE), and the
largest headers a byte at a time within 20 s each (0.4 s together). HTTPBytes: `ContentCodingPieceTests.aByteAtATime`
(pieces of one byte, each passed once, through the 902-byte carry, for gzip, br, deflate, zstd, and gzip + br).

Each fix broken once: Brotli's parts restarted from the header's start every call (the old behavior) failed
`craftedBrotliHeaderDecodes` (held 189 KB; 58 s in debug against 0.6 s) and trapped `smallPipelineBuffersDecode`; bzip2's
tables restarted the same way failed `largestBZip2TablesInSteps`; the step bound removed failed
`codeLengthStepsAreBounded` and `endlessCodeLengthStepsThrow` (its `Pipeline` trapped).

## 2026-11-24 (fix plan, phases A and B): where a stream ends, parallel inflate's budget, Zstandard's window and one-shot, Compressor's parameters

The fixes for `Writeups/BytesCompression-Review-2026-11-23.md`, in the order of
`Writeups/BytesCompression-Fix-Plan-2026-11-23.md` (reproducers in `~/Scratch/compression-review-2026-11-23/`). Each
fix's test was run against the code with the fix disabled and failed, as noted.

**A stream's end with input still to come (plan A2, review §1.1).** For the formats that concatenate (gzip members,
Zstandard frames, xz and bzip2 streams), a stream's end isn't the data's end while more input may follow. gzip,
Zstandard, and xz report `.finished` only with all their input consumed; bzip2 also with 1–3 bytes left (too few to
tell whether `BZh` follows), and with four or more that aren't a header (its real end). Two places took such an end as
final:
- `ChunkedDecompressor` with staged input: a piece ending exactly at a stream's end ended the data. Half of two
  streams came out, `finished`, no error; a ZipCrypto zstd entry whose first frame filled the 256 KB staging buffer
  exactly was refused as a size mismatch (frames a byte shorter or longer decoded). Now it tracks whether the input
  has ended (`fillInput` adding nothing, or `endInput()`); at a tentative end it returns `.needsInput` with the chunk
  open and continues the decoder into what's added, and once the input has ended it finishes or throws
  `insufficientData`, never asking again. `fillInput` throws `insufficientCapacity` when the staged bytes fill the
  buffer (0 there would have read as the input's end). The rule is one function,
  `DecompressionFormat.endIsFinal(unconsumed:inputEnded:)`, with `allowsConcatenation`.
- `BZip2Decoder.transform` (every `Pipeline` with bzip2 in it): 1–3 bytes left after an end were reported as the end
  (two streams cut 1–3 bytes past the first: 400,001 of 666,670 bytes, `finished`). Now `.needsInput` unless flushing.

Tests: `StreamEndTests` (each concatenating format, staged and through `transform`, cut exactly at the first stream's
end and 1–4 bytes past it; one stream; cut short; trailing bytes, which bzip2 leaves and the others refuse, pinned) and
`StreamEndBulkTests` (every cut point of three streams per format); NativeZip's `StagedInputTests` (two zstd frames in a
ZipCrypto entry, the first `stagingCapacity` − 1, exactly, + 1 bytes). With `endIsFinal` always true: 15 cases failed,
and the ZIP test failed at exactly the staging size with the review's error.

**Parallel inflate's segments within the output's room (plan B4, review §1.9).** Segments decode from guessed split
points into buffers of their own, which grew with whatever a segment decoded: 4 MB of flushed zeros into 16 MiB of
output reached 10 GB before the join found it too small. Now a call has a budget of decoded bytes equal to the output's
room (an atomic); a segment pays for what it decoded before each growth and grows by at most what's left. With nothing
left it stops, failed, and the join decodes its region again in place, which fits or throws `insufficientCapacity` as a
sequential decode would. A valid stream into an output of exactly its size decodes as before at every lane count (the
existing sweeps use exact capacities). Test `segmentsStayWithinTheOutputsRoom` (64 MiB of zeros, a full flush every
MiB, into 1 MiB at 2, 8, 16 lanes: the segments' buffers stay under 8 MiB; with room, it decodes); with the budget
unlimited it failed at every lane count. The budget is touched only when a segment grows (the cold path).

**Zstandard's window (plan B5, review §1.10).** A frame that doesn't state its content size takes its window from a
6-byte header, up to the decoder's limit (128 MiB by default; 8 MiB under HTTP), and streaming reserved it zero-filled:
every page resident before a byte decoded, and every ZIP worker decoding a zstd entry could hold 128 MiB.
- The window is reserved unzeroed. A frame reads only window bytes it has written (offsets are checked against its
  history), and the window was already reused across frames without zeroing.
- `DecompressionFormat.zstd(maximumWindowSize:sizeHint:)` (`ZstdDecoder.reset(sizeHint:)`) bounds every frame's window
  by the container's size, as `.xz(sizeHint:)` does; ZIP's method 93 passes the entry's size. The hint lowers the
  window that matches may use, not only the memory: the decoder wraps its window at its size, so a smaller buffer
  with the frame's full window would have let a stream decoding past its hint copy overwritten history. Matches past
  the window are refused (the careful path checks offsets against it; the fast path copies only from the contiguous
  segment being written), so a stream decoding to more than its hint decodes right or throws, never wrong bytes.
- The hint isn't part of `Decompressor`'s decoder-reuse comparison: one decoder serves every entry.
- Test `sizeHintBoundsTheWindow`: the 6-byte-header frame with one 1,000-byte block reserves under 130 KB with the hint
  and 128 MiB without; a stream with matches 20 KB back decoded with a 10 KB hint decodes right or throws.
  (`startFrame` already limited the window to a stated content size: a test of that shape would have passed before.)

**Compressor's parameters (plan B7, review §1.12).** `Compressor.reset(for:)` didn't throw; a Zstandard window out of
10–27 trapped (`ZstdEncoder.Parameters`' precondition) while every other parameter was clamped silently, and Zstandard's
level 0 ran as level 1 (libzstd's 0 is its default, 3). Now `reset(for:)` throws `invalidValue` for what no encoder
takes (negative levels and qualities; Brotli's window out of 10–24, Zstandard's out of 10–27) and leaves the format as
it was; high levels still run as each encoder's highest, which `CompressionFormat`'s documentation now says (Brotli
10–11 as 9, Zstandard above 4 as 4, DEFLATE above 9 as 9, 0 stored); level 0 is 3. `Compressor` is a
`ResettableByteTransform`, so a `Pipeline` can choose its encoder at run time as it can its decoder. HTTPBytes'
`HTTPContentEncoder(_:level:)` throws `unsupportedCoding` for a negative level; Disk's fixed formats can't fail. Tests:
`CompressorTests` (each refused parameter, the format unchanged; levels as documented, byte for byte; a `Compressor`
and a `Decompressor` as `Pipeline` stages with 4 KB buffers).

**Instructions (`move-after` → `fix-B-bc-after`, the 181 decode rows both have: every Zstandard, inflate, and parallel
inflate row).** Flat: none moved more than 1% but one parallel async row (−1.1%, within its spread between runs).

**Zstandard's one-shot (plan B8).** `ZstdDecoder.decompress(_:maximumSize:)` had no callers outside the tests and
defaulted to an unbounded size, so 1 MB of input could make a zeroed 32 GiB array from its header's claim: it's
`package` now, `maximumSize` is required, and a claim sizes the first array only up to 1 MiB (the rest grows as decoded).

## 2026-11-23 (stage 3): LZMA's model reset by groups, Zstandard's window limit in the format, false sizes refused (baselines `stage3-before` → `stage3-after`)

M1 Max, macOS 27.2, Xcode 27.3; NativeZip's and HTTPBytes' baselines of the same names ran beside these (instruction
counts, not times). New rows, added (benchmark code only) before `stage3-before`: **LZMA small streams** (1,000 pieces of
4 KB of dickens, each its own raw LZMA or xz stream at liblzma's preset 6, through `Decompressor`, whole or streamed: what
a ZIP of small LZMA or xz entries costs, a model reset per stream).

### LZMA's probability reset, a 16-byte group per store

`LZMALoop.resetState` filled the model with `update(repeating: 0x400, count:)` on a `UInt16` pointer: one `strh` per
probability, a 4-instruction loop over 8,032 of them for lc 3 (about 32 K instructions), at every stream's start and every
LZMA2 state reset. `LZMAWorkspace` is now sized and reset by its store stride: its memory is whole groups of eight
probabilities (`SIMD8<UInt16>`, 16 bytes; every model's count is a multiple of 8), allocated by the workspace itself at a
64-byte boundary, so each group is aligned by construction rather than by a run-time check (`DeflateCompressor.clear`'s
form); `reset(_:)` checks the model fits (a `precondition`, so the callers lost their `unsafe`) and stores a group at a time.
`Tools/loops`: `LZMAWorkspace.reset(_:)` is one 4-instruction `vector128` loop around `str q0, [x1, x9]` (1,004 stores for
lc 3); inlined into the xz and whole-buffer decoders, called once per stream from `LZMADecoder.reset`. The memory stays
bound to `UInt16` (what the decoder reads and adapts); the group stores are raw stores, which memory of any trivial type takes.

| Row (instructions) | before | after | |
|---|---:|---:|---:|
| LZMA small streams raw -6, 1,000 × 4 KB: whole / streamed | 668 / 679 M | 640 / 651 M | −4.2% / −4.1% |
| LZMA small streams xz -6, 1,000 × 4 KB: whole / streamed | 670 / 672 M | 642 / 643 M | −4.2% / −4.3% |
| NativeZip: Inflate + CRC 2,000 small files: LZMA / xz (4–16 KB entries) | 1,423 / 1,427 M | 1,366 / 1,370 M | −4.0% / −4.0% |
| LZMA decode, LZMA stream, Decompressor rows on whole Silesia files (one reset each) | | | 0.0 to ±0.1% |

About 28 K instructions per stream, as counted. Mallocs: every `Allocations:` row 0. (What the rest of a 4 KB stream costs,
about 640 K instructions, is its decoding: small streams code more literals, about 150 instructions a byte against 42 for a
whole file.)

### Zstandard: `.zstd(maximumWindowSize:)`, and HTTPBytes on `Decompressor`

`DecompressionFormat.zstd` takes the window limit (`case zstd(maximumWindowSize: Int = ZstdDecoder.defaultMaximumWindowSize)`):
a frame needing more is refused (`insufficientCapacity`) before anything is allocated, as `ZstdDecoder(maximumWindowSize:)`
does. Other clients' default is unchanged (128 MB); they now write `.zstd()` (ZIP's method 93 mapping, the tests; patterns
`case .zstd:` are as before). `Decompressor` keeps its Zstandard decoder while the limit stays the same and makes a new one
when it changes. HTTPBytes' content decoder dropped its own `ZstdDecoder?` and resets its `Decompressor` for
`.zstd(maximumWindowSize: 8 << 20)` (RFC 9659): ARCHITECTURE.md §5's last codec layer outside this package is gone. Its
rows: below (HTTPBytes/RESULTS.md); new test `DecompressorTests.zstdWindowLimit` (refused at 8 MB, decoded at the default, the
decoder remade when the limit changes, a negative limit `invalidValue`).

### A content size the input can't hold

`ZstdDecoder.decompress(_:maximumSize:)` (the array-returning convenience) made its array from the frame header's content
size, limited only by `maximumSize`, whose default is `.max`: a 14-byte frame claiming 2^62 bytes aborted the process in
`malloc` ("failed to allocate 4611686018427387936 bytes", confirmed by the new test with the check disabled), and a large
allocatable claim was zero-filled before a block was read. A block decodes to at most 128 KiB and takes at least 4 bytes
(an RLE block), so no stream decodes to more than 32,768 times its size: a larger claim is refused as `invalidValue` before
allocating. Test: `ZstdDecoderTests.convenienceRefusesSizesTheInputCantHold` (the false frame; a 1 MB RLE frame still
decodes). Found by the input-conversion sweep (below).

### The input-conversion sweep: BytesCompression's parsers

Every checked conversion and checked arithmetic on input-derived values in the decoders and container code was read
(a review agent, then each finding checked here). No reachable trap of the `Int(x)`/`+` kind: sizes are bounded where
they're read (XZ's varints `<= Int.max` before `Int(_:)`, pbz blocks at 256 MiB, LZMA headers' sizes, Zstandard's window
and block sizes) and the hot paths' arithmetic is wrapping with checks before use. What the sweep did find:

| Finding | Verdict |
|---|---|
| `ZstdDecoder.decompress(_:maximumSize:)`: an array of the header's content size | **fixed** (above) |
| `ParallelDeflateDecoder`: each segment's buffer doubles on `.outputFull` with no limit (the output's capacity is checked only in the join); a bomb split by sync flushes grows every segment to its whole decoded region | memory, not a trap; not fixed (only BytesProbe uses the parallel decoder): pass the output's free capacity into the segments |
| Streaming Zstandard reserves its window zeroed (`GrowableWorkspace.reserve`): a 6-byte header makes 128 MiB resident (8 MiB under HTTP's limit) | bounded by `maximumWindowSize`; not changed |
| `Decompressor`'s `decodedSize`, `sizeHint`, `uncompressedSize` from containers (NativeZip passes `entry.uncompressedSize`, now below 2^62) | checked against the output's capacity before use, or used only in `min`/wrapping arithmetic: safe at any value |

## 2026-11-23 (later): NativeZip's and NativeAEA's codec layers moved here and unified (baselines `unify-before` → `unify-after`)

Stage 2: the compression and decompression above the codecs, which NativeZip, NativeAEA, Disk, and HTTPBytes each had
their own of, is here once. The design (what's unified, the interfaces, what stayed where and why) is
[ARCHITECTURE.md](ARCHITECTURE.md). No codec changed; no algorithm changed.

### What moved, what's new, what went

| Was | Now | |
|---|---|---|
| NativeAEA `Buffers.swift` (`SegmentBufferPool`) | `BytesCompressionAsync/BlockBufferPool.swift` (`BlockBufferPool`), `git mv` | the same code, inlinable with `@usableFromInline` state (BytesAsync's pattern) |
| NativeAEA `BlockStream.swift` and `SegmentStream.swift`'s engine (`ChunkSource`, `DecodedChunk`, `ChunkCounters`, slots, decoder tasks, producers, `UpstreamReader`) | `BytesCompressionAsync/ParallelBlockDecoder.swift`, `git mv` of BlockStream.swift: `ParallelBlockDecoder<Stage>`, `OrderedBlockSource<Failure>`, `DecodedBlock`, `BlockJob`, `BlockContext`, `BlockStage`, `BlockDecodingError`, `BlockDecodingFailure`, `BlockDecodingCounters`, `UpstreamBlocks` | two engines → one: indexed blocks (atomic claims), `pbz` from a file or an upstream source (producer + queue), plain slices; one ring of slots for both (segments had a slot per segment) |
| NativeAEA `SegmentCodec` (codec per segment, size check) | `BlockContext.decompress` (engine) and `DecompressionFormat(aeaSegment:)`/`(pbzBlock:)` | `SegmentCodec.swift` → `SegmentChecks.swift` (MAC, checksum, Murmur64 stay) |
| NativeAEA `PBZ` (pbz framing), `PBZHeader`/`PBZBlockHeader` records, `AEACompression` | `PBZ.swift` (`PBZ`, `PBZError`), `AppleArchiveCompression` in `ContainerFormats.swift` | `AEARootHeader.compression` and `AppleArchiveFile.compression` are `AppleArchiveCompression` now |
| NativeZip `ZipDecoder`'s buffers, modes (whole, history, stream), and stepping | `ChunkedDecompressor.swift` (`ChunkedDecompressor`): borrowed or staged input, `.needsInput` resumes the same chunk | `ZipDecoder` keeps decryption (filling the staged input), the method mapping call, the LZMA end-marker limit, `ZipError`; −151 lines |
| NativeZip's method `switch` and LZMA header parse | `DecompressionFormat(zipMethod:uncompressedSize:)`, `LZMAProperties(zipHeader:)`, `.zipLZMA(_:uncompressedSize:hasEndMarker:)` | `ZipArchive.Method.isSupported` asks the mapping |
| Disk `ChunkEncoders`' four encoders, `ForkUnpacker`'s three decoders | `Compressor` (new, `Compressor.swift`: `CompressionFormat`), `Decompressor` | `DiskCodec.compressionFormat`/`.decompressionFormat`; `StoragePolicy`, the fork layout, raw markers stay in Disk |
| HTTPBytes `HTTPContentEncoder`'s three encoders | `Compressor` | |
| NativeAEA XIP's TOC (zlib) and Metadata (bzip2) one-shot decoders | `Decompressor` | |

Lines: NativeAEA's library 5,151 → 4,278 (−873), NativeZip 3,344 → 3,195 (−149), HTTPPayload −8, Disk +4; this
package +1,657 (the engine and pool, 1,042 with their documentation, were 1,138 lines in NativeAEA as two engines; the
rest is new: mappings 107, `PBZ` 76, `Compressor` 140, `ChunkedDecompressor` 292). Tests: `BlockDecoderTests` (10
tests: the mappings, framing, `Compressor` byte for byte against each encoder, staged against borrowed input in each
mode, the engine indexed, framed from a file and from upstream, slices, failures, cancellation, and the pool's
activation test, moved from NativeAEA).

Errors stay typed and composed: the engine's are `BlockDecodingError`; NativeAEA's `AEAError` conforms to
`BlockDecodingFailure` (`.decoding(e, block)` → `.decompressionFailed(segment:, BytesError)`, which carried a `String`
before; framing → `.invalidArchive` with the old messages; `.cancelled`). NativeZip maps `BytesError` as before.

### Instructions and mallocs before and after

M1 Max, macOS 27.2, Xcode 27.3; each run one package after another (`unify-before` before the first edit), no other
benchmark beside them (a release build of NativeZip ran beside part of the `unify-after` run: instruction counts, not
times). Single-threaded rows (decoding and encoding):

| Row | before | after |
|---|---:|---:|
| NativeZip: Inflate + CRC 32 MB text: Bytes / Deflate64 | 147 M / 148 M | 147 M / 148 M |
| NativeZip: Inflate + CRC 32 MB text: bzip2 / LZMA / xz | 1,534 / 1,412 / 1,427 M | 1,534 / 1,412 / 1,427 M |
| NativeZip: Inflate + CRC 32 MB text: ZipCrypto / AES-256 (staged input) | 241 / 181 M | 241 / 181 M |
| NativeZip: Decrypt + CRC 32 MB text: ZipCrypto, stored | 493 M, 1 malloc | 492 M, 0 mallocs |
| NativeZip: Inflate + CRC 2,000 small files: Bytes (whole mode) | 162 M | 161 M |
| NativeZip: Inflate + CRC 32 MB raster; Zstd + CRC text, raster; Stored + CRC | 116; 377, 139; 29 M | equal |
| BytesCompression: Decompressor xz -6 dickens (0 mallocs every format) | 649 M | 649 M |
| HTTPBytes: Body rows, decode (gzip whole, chunked, one stage; br) | 4.735, 4.887, 4.891, 23 M | equal |
| HTTPBytes: Body rows, encode through `Compressor` (gzip 6, br 5, zstd 3) | 138, 182, 26 M | equal (0 mallocs) |
| NativeAEA: Decode segment 0 (the benchmark's own decoder, unchanged) | 1,191 M | 1,190 M |

Every single-threaded row is equal to `bench-table`'s three digits, but two that went down: "Inflate + CRC 2,000 small
files" (−0.6% at three digits, 162 → 161 M: each small entry now goes through `ChunkedDecompressor`'s whole mode) and
the stored ZipCrypto row (−0.2%, and one malloc fewer:
the staged input is made on the first *compressed* encrypted entry now, so a stored one no longer allocates 256 KB it
never uses). Mallocs are unchanged on every other row, and every zero-malloc gate passes (HTTPBytes' three,
`Allocations:Decompressor_every_format`).

Parallel and file-system rows (whole processes, kernel included):

| Row | before | after |
|---|---:|---:|
| NativeAEA: List (decode, verify, parse) synthetic | 272 G, 31,000 mallocs | 272 G, 31,000 |
| NativeAEA: Extract synthetic: archived / lzfse / none / archived + progress | 413 / 546 / 303 / 413 G | 413 / 545 / 303 / 413 G |
| NativeAEA: Extract mallocs (archived / lzfse / none) | 452 / 457 / 347 | 434 / 442 / 368 (earlier runs: 476–486, 378) |
| NativeZip: Verify 2,000 small files (parallel) | 192 M, 137 mallocs | 191 M, 137 |
| NativeZip: Extract 32 MB text: bzip2 / LZMA / xz / Zstd / Deflate64 | 1,566 / 1,443 / 1,456 / 411 / 181 M | 1,567 / 1,444 / 1,461 / 410 / 181 M |
| NativeZip: Extract 2,000 small files (1–8 workers, progress) | 2,770–2,867 M | 2,747–2,930 M (±5%, kernel) |
| NativeZip: Extract 20,000 small files (3 forms); 8 archives of 64 MB | 23, 23, 27 G; 2,907 M | equal; 2,923 M |
| Disk: Compressed 2,000 x 1–64 KB (LZBITMAP, LZFSE, LZVN, zlib inline) through `Compressor` | 5,075 / 7,504 / 7,520 / 8,623 M | 4,987 / 7,420 / 7,462 / 8,582 M |
| Disk: Xcode-like 5,000 files LZBITMAP / LZVN; Large file 1 GB LZBITMAP | 28 / 53 G; 38 G | equal |

The extraction rows move with the kernel's work as they always have (the uncompressed "plain" control −2.9%, the 2,000
small files rows ±5% in both directions); the decoding inside them is the single-threaded rows'. NativeAEA's extraction
mallocs (task allocator slabs, writers' scratch) vary by run as before.

**Codegen.** The engine is generic over its stage and inlinable, so NativeAEA specializes it: `Tools/calls --target
NativeAEA NativeAEA 'ParallelBlockDecoder|AEASegmentStage|…' --callee 'swift_getGenericMetadata|swift_allocObject|witness'`
shows only `specialized ParallelBlockDecoder.*` functions, no generic metadata calls, no allocation in the decode loop
(`decodeTask`, `decode`, the producers: only the per-call `RawStorage` header buffer, as before), and the stage's
`decode` called as `specialized BlockStage.decode`. NativeZip's decoder calls `ChunkedDecompressor.nextChunk(into:)`
once per chunk and `start`/`borrowInput`/`stageInput` once per entry (they were calls into `Decompressor` before).

### Found

- **The upstream source of a framed engine isn't run by it**: whoever builds a `pbz` stream over another source runs
  both (NativeAEA's `AEAPayload.run()` does). The new engine test hung until it did; documented on `Input.upstream`.
- **HTTPBytes' Zstandard decoder stays its own**: `Decompressor`'s `.zstd` has no window limit, and HTTP needs RFC 9659's
  8 MB one (`ZstdDecoder(maximumWindowSize:)`). A `.zstd(maximumWindowSize:)` format would unify it (deferred: it
  changes every `.zstd` client). (Done in stage 3: `.zstd(maximumWindowSize:)`, and HTTPBytes decodes through
  `Decompressor`.)

## 2026-11-23: the move out of Bytes (baselines `move-before` → `move-after`)

Stage 1 of a larger plan (NativeZip's and NativeAEA's codec layers come here next): the `BytesCompression` module moved
to this package unchanged, so `import BytesCompression` works everywhere. No behavior and no code changed beyond what
the move needed.

### What moved (with `git mv`, so history follows)

| From (Bytes) | To (here) |
|---|---|
| `Sources/BytesCompression` | `Sources/BytesCompression` (two imports: `CBytesCRC` → `CBytesCompression`; comments naming BytesAsync's entry points) |
| `Sources/BytesAsync/ParallelCodecs.swift` | `Sources/BytesCompressionAsync/ParallelCodecs.swift`, a module of its own (adds `internal import BytesAsync`) |
| `Sources/BytesReferenceCodecs`, `CLibDeflate`, `CBrotli`, `CZstd`, `CLZMA`, `CBZip2` | `Sources/…` (nothing in Bytes used them) |
| `Tests/BytesCompressionTests` | `Tests/BytesCompressionTests` (adds `import BytesCompressionAsync` to the two parallel suites) |
| `Tests/BytesCryptoTests/PipelineTests.swift` (the tests through codecs) | `Tests/BytesCompressionTests/PipelineTests.swift`; the four codec-free tests stayed in Bytes, in a new file of the same name |
| the codec tests of `Tests/BytesAsyncTests/AsyncTests.swift`, `ConcurrentTransformTests.swift` | `Tests/BytesCompressionTests/AsyncTests.swift`, `ConcurrentTransformTests.swift` (same suite names) |
| `Benchmarks/CompressionBenchmarks` (target name kept, BytesCrypto's rows included) | `Benchmarks/CompressionBenchmarks` |
| `.benchmarkBaselines/CompressionBenchmarks`, `Thresholds/CompressionBenchmarks.*` (52) | `.benchmarkBaselines/CompressionBenchmarks`, `Thresholds/` |
| `Benchmarks/RESULTS-{zstd-encoder,bzip2,lz4-lzfse,lzbitmap,lzraven}.md`, `LZRAVEN-FORMAT.md` | `Benchmarks/` (links fixed) |
| the CompressionBenchmarks part of `Benchmarks/portable-subset.txt`; `bench` | `Benchmarks/portable-subset.txt`; `bench` (the same script) |

### The package

- Products: `BytesCompression`, `BytesCompressionAsync` (the parallel codecs' `async` entry points), `BytesReferenceCodecs`
  (test and benchmark support, used by NativeZip's tests and benchmarks, NativeAEA's and HTTPBytes' benchmarks).
- Targets: `CBytesCompression` (C: `bytes_crc_fold`, the one wrapper BytesCompression called from Bytes' `CBytesCRC`,
  copied with its name; Bytes keeps its own for CRC-32 and Adler-32), `BytesCompression`, `BytesCompressionAsync`,
  `BytesReferenceCodecs`, the five system libraries, `BytesCompressionTests`, `CompressionBenchmarks`. Settings as in
  Bytes (`commonSettings`, `strictSettings`, `portableSwiftSettings`, `BuiltinModule` for BytesCompression).
- Traits: Bytes' four (`NEONShuffle`, `HardwareCRC`, `HardwareCrypto`, `Portable`; default the first three), each passed
  on to Bytes under the same condition, so `--traits Portable` and `--disable-default-traits` build Bytes the same way.
  `./bench optimized|portable|portable-no-c` as in Bytes.

### Dependency changes

- Bytes no longer has BytesCompression, BytesReferenceCodecs, or the reference libraries; `BytesAsync` depends only on
  `Bytes`. SwiftPM forbids package cycles, so what BytesCompression used from Bytes at `package` access became public:
  `likely(_:)` and `unlikely(_:)` (Builtins.swift, `@_transparent`), and BytesAsync's `perform(on:_:)` (now
  `@inlinable public`, with `public import Dispatch` in Offloading.swift).
- Disk, NativeZipArchive, NativeAEA, HTTPBytes, HTTPBytes/Benchmarks, SocketStream, and Tools/probes/BytesProbe depend
  on `../BytesCompression` for `BytesCompression` (and `BytesReferenceCodecs`); the Nunarchiver project lists the local
  package (no product: the app links none of its own).

### Instructions before and after

`move-before` was saved in Bytes before any edit, `move-after` here; the dependents' rows in their own packages. Both
runs had other benchmark runs beside them (instruction counts, not times).

**The machine code is identical.** Every object file of `BytesCompression` (49), `Bytes` (34), `BytesCrypto` (17),
`BytesBase64`, and of the dependents measured (`Disk` 18, `NativeZip` 12, `HTTPPayload` 4) disassembles identically
before and after (`objdump -d -r` of the release objects, old ones from the committed tree). `CompressionBenchmarks`
differs only in `ParallelBenchmarks.o` (the async entry points' new module). What did change:

- `BytesAsync`: `perform(on:_:)`, now public, is reached through the GOT in `offloaded(to:)` (one load), and a few
  helper thunks moved between its object files.
- `ParallelCodecs.o` (BytesAsync → BytesCompressionAsync): 1,803 → 1,797 instructions; the same functions, with two
  closures of the per-call glue inlined into their partial applies. Once per call, outside the workers.

So the differences in the tables are measurement: HDR buckets and run-to-run variation, the same as in the unchanged
C references beside them.

CompressionBenchmarks, 926 rows (rows by kind and size; how many changed by how much, as `bench-table` prints them):

| Rows | Count | 0 | ≤0.3% | ≤1% | >1% |
|---|---:|---:|---:|---:|---:|
| Bytes, one thread, ≥100 M instructions | 134 | 113 | 20 | 1 | 0 |
| Bytes, one thread, 100 K–100 M | 224 | 214 | 7 | 2 | 1 |
| Bytes, one thread, <100 K | 52 | 48 | 2 | 2 | 0 |
| C references and system codecs, ≥100 M | 160 | 125 | 31 | 4 | 0 |
| C references and system codecs, 100 K–100 M | 211 | 198 | 7 | 4 | 2 |
| C references and system codecs, <100 K | 41 | 36 | 0 | 2 | 3 |
| Parallel and async rows (several threads) | 47 | 30 | 2 | 6 | 9 |
| `Allocations:` rows, mallocs | 56 | 56 (all 0) | | | |

The one-thread Bytes rows beyond 0.3%: Zstd encode L3 Main.js 85 → 86 M (+1.2%, the table's two digits), Inflate64
x-ray history 1 MB 120 → 121 M (+0.8%), Two passes deflate 1 + TLS JSON 1.6 KB 134 → 135 K, RSA public key 2048 parse
112 → 111 K, LZ4 raw and LZFSE decode JSON 1.6 KB −0.5%; the references move as much (LZVN decode JSON: Compression
−2.8%, HKDF-SHA256: CryptoKit −2.2%, LZRAVEN decode Main.js: Compression −1.6%). The parallel rows' synchronous forms,
whose code is identical, moved as much as the async ones (Parallel deflate 1 samba 8 lanes: sync +6.5%, task group
+5.9%, Dispatch +14.6%; Parallel Brotli q1 samba: sync +5.7%, Dispatch +3.8%): several threads' counts vary between
runs.

The dependents:

| Package | Rows | Result |
|---|---|---|
| NativeZipArchive | 13 inflate, decrypt, Zstd + CRC rows, Verify 2,000 parallel | all within 0.1% (bzip2 1,535 → 1,537 M, xz 1,427 → 1,429 M), but parallel verify −0.5%; mallocs equal (parallel verify 129 → 121) |
| NativeAEA | Decode segment 0, Make segment decoder, List | all 0.0%, but the 5 K-instruction "system" row +3.1% |
| HTTPBytes/Benchmarks | Body rows, `Allocations:Body_*` | 0.0%, but br quality 5 encode 182 → 183 M (+0.5%, `HTTPPayload`'s objects identical); 0 mallocs |
| Disk | Compressed, One file LZBITMAP, Xcode-like LZ*, Large file LZBITMAP | −1.5 to +0.7% (kernel instructions included; the uncompressed "plain" row +0.7%) |
