# bzip2 decoding (2026-11-19)

`BZip2Decoder` (`Sources/BytesCompression/BZip2Decoder.swift`): `.bz2` streams (bzip2 0.9.5 and later, Julian
Seward's format), whole stream into a whole buffer, in Swift. Written for `.xip` expansion in NativeAEA (a xip is a
XAR archive whose `Metadata` member is bzip2), and XAR heaps in general. Tests:
`Tests/BytesCompressionTests/BZip2DecoderTests.swift`; benchmarks: `Benchmarks/CompressionBenchmarks/BZip2Benchmarks.swift`;
the reference, libbzip2 1.0.8 (macOS's, `/usr/lib/libbz2.dylib`: `Sources/CBZip2`, a system-library target for tests
and benchmarks only).

## API

```swift
var decoder = BZip2Decoder()                                         // ~Copyable, Sendable; 7.8 MB workspace, once
let consumed = try decoder.decompressAll(stream, into: &output)      // through the last stream's end marker
let consumed = try decoder.decompressAll(stream, decodedSize: size, into: &output)
```

- One stream (`BZh1`–`BZh9`, blocks, the end marker with the combined CRC), then each stream that directly follows
  (`cat a.bz2 b.bz2`, pbzip2's output): decoded as one. Bytes after the last end marker (rounded up to a byte) that
  don't start with `BZh1`–`BZh9` are left alone; the return value is the input consumed.
- Every block CRC and every stream CRC is checked. bzip2's CRC is CRC-32's polynomial most significant bit first
  (CRC-32/BZIP2), not Bytes' `CRC32`: its own slicing-by-8 tables, and 64-byte `pmull` folding (the reflected
  CRC's `bytes_crc_fold` from `CBytesCRC` with non-reflected constants x^576, x^512, x^192, x^128 mod P on
  byte-reversed blocks). Its cost doesn't register: 0.2% of the time in profiles.
- Randomized blocks (bzip2 0.9.0 and 0.9.5 wrote them for repetitive data; 1.0 never does) are decoded: the
  randomization table is libbzip2's `BZ2_rNums` (checked against bzip2 1.0.8's `randtable.c`); the test builds a
  randomized stream from a 1.0 one, and libbzip2 agrees.
- Typed throws, `BytesError`: `insufficientData` (truncation at any byte), `insufficientCapacity` (the output doesn't
  fit), `mismatch` (a size other than `decodedSize`; a stream decoding past `decodedSize` is a mismatch too),
  `invalidValue` (a missing header, corrupt data, a CRC mismatch, a negative `decodedSize`). Corrupt data never reads
  or writes outside the buffers (all indices are bounded by construction: 24-bit links into a 2²⁰-entry table, byte
  counts that are the runs' own, a run count bounded by the selector count).
- Semantics follow libbzip2: code lengths 1–20, 2–6 tables, up to 18,002 selectors stored (more read and ignored, as
  1.0.8 does), RUNA/RUNB runs of at most 2²¹ symbols, the block size from the header, the origin below the block's
  length, four equal bytes always followed by a count. A block that's a power of a shorter string (`abcabc…`,
  whose BWT links make one cycle per copy) is walked as libbzip2 walks it: the origin's cycle, repeated.
- No allocation per call: `Allocations:BZip2_decode` has a zero threshold (two concatenated streams, the first of two
  blocks).

## Tests (12 in `BZip2DecoderTests`, all against libbzip2's encoder; pass in debug and release)

Round trips of `bzip2 -1`…`-9` (libbzip2's `BZ2_bzBuffToBuffCompress`) of the shared samples plus runs of every length
around RLE1's 4 and 255 (and its 251 count), skewed and geometric bytes (codes longer than the 10-bit table), all
256 byte values, 1 MB of zeros; every size 0…600 of random bytes and text (the CRC's folding thresholds); sizes
around the block boundaries (100,000 × level − 19, one and two blocks) and around 32,768 (where the walk changes);
periodic blocks (periods 1 to 49,500, the power-of-a-string case); CRCs against a bit-at-a-time reference;
concatenated streams (including an empty one) and trailing bytes; exact and short outputs, `decodedSize` exact, ±1,
too large, negative; truncation at every byte of three small streams and every 97th of a two-block one
(`insufficientData` each time); bad headers; 4,600 random corruptions of four streams (each decode throws or returns
the original: a flip in the end's padding bits); a randomized block; reuse after an error.

## Design, as it ended

A block is decoded in five passes over the decoder's workspace:

1. **Tables** (`readTables`): the symbol map, selectors (unary, move-to-front decoded in a 64-bit register), code
   lengths, and per table a 10-bit primary lookup table (entry: length and symbol) plus canonical limits for longer
   codes. The end-of-block symbol is left out of the primary table, so one test (`entry < 512`) sends long codes,
   invalid codes, and the end of the block to the slow path.
2. **Symbols** (`decodeSymbols`): per 50-symbol group with 160 bytes of input left, a loop with no calls: the
   refill's 8 bytes loaded a symbol ahead (`refill(with:)`), the lookup, then RUNA/RUNB against indices without a
   branch (selects), and the move-to-front list's first 16 bytes kept in a register: `tbl` to pick the byte,
   `ext` and a select to move it (indices past 15 go to memory, 16 bytes at a time). Output: runs of equal bytes
   (a 4-byte length-and-byte per move-to-front index) and each byte's count. 41 instructions a symbol.
3. **Links** (`linkPadded`): from the runs, `tt[j]` = (the position whose byte sorts to `j`, the byte), written 4
   entries at a time: every byte's rows are followed by 4 unused entries, so a run's ramp is stored without
   branching on its length. (Small blocks: `link`, with `back` links too.)
4. **The walk** (`BZip2Segments.walk`): following `tt` is one dependent load per byte from 3.6 MB, ~30 cycles each
   on one chain. Blocks of 32 KB and more are cut at evenly spaced rows into ~1 KB segments (each start marked in
   `tt`, its entry saved), 24 walked at once, each lane writing to its own pages and taking the next segment when its
   current one meets a mark; then the segments are copied out in cycle order. Smaller blocks are walked from both
   ends at once (`tt` forward from the origin, `back` backward from it).
5. **Runs undone** (`expandRuns`): 16 bytes at a time where no 4 equal bytes end in the 19-byte window, a byte at
   a time otherwise; then the block's CRC over the output.

## Results

Apple M3 Ultra, macOS 27.2, Xcode 27.3's Swift. Silesia files as `bzip2 -9` writes them (cached as
`NAME-SIZE.bzip2-1.0.8-9`), and the JSON responses of the other benchmarks.

### Final: package-benchmark, baseline `bzip2-final`

`swift package --disable-sandbox benchmark baseline update bzip2-final --filter 'BZip2 decode.*'`, under the shared
bench lock (other agents' builds may have been running). p50 wall time (`Tools/bench-table` rounds it to 2–3
significant digits), MB/s of output (10⁶ bytes), instructions per output byte.

| Input | Bytes MB/s | libbz2 MB/s | Speedup | Bytes instr/B | libbz2 instr/B |
|---|---|---|---|---|---|
| dickens (10.2 MB) | 275 | 58.6 | 4.7x | 62.9 | 105.9 |
| mozilla (51.2 MB) | 202 | 61.7 | 3.3x | 67.2 | 126.3 |
| xml (5.3 MB) | 486 | 92.2 | 5.3x | 32.7 | 59.5 |
| x-ray (8.5 MB) | 160 | 49.3 | 3.2x | 75.3 | 144.1 |
| samba (21.6 MB) | 277 | 75.3 | 3.7x | 48.7 | 90.3 |
| JSON (1.6 KB) | 264 | 126 | 2.1x | 51.2 | 106.7 |
| JSON (119 KB) | 487 | 124 | 3.9x | 33.8 | 58.7 |

`Allocations:BZip2_decode`: 0 mallocs (threshold check passes).

### Iterations (harness: instructions and cycles per output byte from `proc_pid_rusage`, best of 3; machine loaded by other agents, so cycles are approximate and compared only within an A/B pair)

| Version | dickens | mozilla | xml | x-ray | samba | JSON 1.6 KB |
|---|---|---|---|---|---|---|
| libbzip2 1.0.8 | 105.9 / 67.5 | 126.3 / 64.1 | 59.4 / 43.2 | 144.1 / 81.7 | 90.2 / 48.4 | 105.8 / 28.9 |
| v1: one walk, RLE1 undone in it | 66.9 / 46.4 | 63.6 / 38.9 | 45.0 / 35.8 | 76.2 / 53.6 | 54.0 / 34.4 | 63.4 / 20.1 |
| v2: runs out of the symbols; walk from both ends; RLE1 apart | 59.0 / 37.0 | 63.1 / 33.2 | 24.6 / 22.8 | 72.8 / 38.2 | 43.2 / 26.4 | 48.4 / 12.4 |
| v3: walk in segments, 16 lanes | 68.5 / 22.0 | 72.0 / 24.0 | 34.1 / 11.1 | 82.3 / 27.0 | 51.9 / 17.7 | 48.4 / 12.5 |
| v6: list front in a register, symbols and links without branches on runs | 69.1 / 21.0 | 72.1 / 23.5 | 34.6 / 10.5 | 82.3 / 27.5 | 52.4 / 16.8 | 50.3 / 12.6 |
| v7: refill word loaded a symbol ahead; state in a struct, not a closure | 70.5 / 17.2 | 73.3 / 20.9 | 35.0 / 9.4 | 84.1 / 26.3 | 53.2 / 14.7 | 60.7 / 14.4 |
| v8: no `back` links for segmented blocks | 66.9 / 16.8 | 70.3 / 20.5 | 33.7 / 8.6 | 79.9 / 25.6 | 51.0 / 14.1 | 60.7 / 14.4 |
| v9: 24 lanes | 66.9 / 16.1 | | 33.6 / 8.0 | | | |
| v10: end of block through the slow path | 65.7 / 16.0 | | | 78.8 / 24.9 | | 59.6 / 14.2 |
| v13: the careful group out of line (no calls in the loop) | 62.7 / 15.9 | | | 75.7 / 24.5 | | 49.7 / 12.7 |
| v15: byte counts in the symbol loop | 62.7 / 14.9 | | 32.5 / 7.7 | 75.1 / 24.3 | | |
| v16 (final): padded links, 4 at a time | 62.9 / 14.4 | 67.2 / 19.5 | 32.8 / 7.7 | 75.3 / 24.3 | 48.7 / 13.2 | 51.2 / 12.5 |

Instructions / cycles per output byte (empty cells: not measured in that round).

### What worked

- **Overlapping the walk.** The inverse BWT is a chain of dependent loads; a probe of k random chains through a
  900,000-entry table: 7.6 ns a step for 1 chain, 2.0 for 8, 1.1 for 16, 0.8 for 24 and 32. Two chains (both ends:
  v2) took dickens from 46 to 37 cycles a byte; 16 segment lanes (v3) to 22, 24 lanes another 5–8%. Segments need no
  extra pass: lanes write to pages, and the order comes from the marks each segment ends on. Instructions went up
  (the lane bookkeeping), cycles down: judge this pass by cycles.
- **Loading the refill's word a symbol ahead** (v7): the refill's address depends on the bits consumed, so a load
  per symbol sat in the chain from one code's length to the next code's lookup (~15 cycles a symbol). Loaded early,
  the chain is the lookup and two shifts: dickens −15%.
- **Branch-free bookkeeping where the data decides**: RUNA/RUNB against indices with selects (v5–v6), a link's first
  4 entries without testing its length (v6: dickens −10%), then 4-wide stores into padded rows (v16: −4%).
  `discarded` in CPU Counters fell from 40% to 12% on dickens.
- **No calls in the hot loop** (v13): the careful group near the input's end in its own function, the slow decode
  inlined. Before, the loop spilled its state (and the list's register) around calls it rarely made: −4%
  instructions, JSON 1.6 KB −10%.
- **Counting bytes in the symbol loop** (v15): a separate pass over the runs cost a load-add-store chain per run;
  inside the symbol loop it overlaps the Huffman chain: dickens −6%.
- **Undoing RLE1 apart from the walk**: the walk then writes one byte per step, and the run-length pass is 2–8%.

### What didn't

- **Two symbols per refill** (decode, decode, refill): +20% instructions and cycles, twice (LLVM spilled the state).
- **The list's first 64 bytes in four registers** (a 4-register `tbl` and four selects, no branches below 64): LLVM
  kept the whole state struct in memory and turned the selects back into branches: dickens 16 → 22 cycles a byte.
- **Block-by-block list moves** (each 16-byte block one load, `ext`, select, store, so the next move's loads are
  forwarded from single stores): more instructions than 16-byte moves top down; x-ray +8%.
- **Branch-free symbols with the list in memory** (v4 variant): moving index 0 for every RUNA/RUNB put a
  store-to-load forwarding chain on every symbol: +8% cycles. Kept once the list's front was in a register.
- **Copying up to the first run in RLE1's fast path**: +4–7% instructions on text for little gain on binaries.
- **A local function capturing the state** (`func decode()` inside `decodeSymbols`): boxed (7 `swift_allocObject`
  per block, dynamic exclusivity checks), 270 instructions a byte on 1.6 KB. A struct with `@inline(__always)`
  mutating methods compiles to registers.

### What's left

- x-ray (and mozilla's binary parts) spend most of their time on move-to-front indices past 15 (59% of x-ray's
  symbols), whose branches mispredict (`discarded` 34%): ~24 cycles a byte against dickens's 14. A branch-free
  move for large indices needs the list in more registers than the struct's codegen kept (above).
- Multi-symbol Huffman entries would shorten the per-symbol chain (lookup, shift) that bounds the symbol loop.
