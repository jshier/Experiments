# NativeZip performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M3 Ultra (32 cores), macOS 27.2, APFS.
Each step is saved as a named baseline in `.benchmarkBaselines/` and can be re-compared with
`../Tools/bench-table . --metric 'Time \(wall clock\)|Instructions|Malloc' <a> <b>`.

## baseline — the code before any performance work

`OutputFilter` (Compression.framework) decoding with a new 1 MB buffer + `Data` per chunk, `FileManager`
for attributes and existence checks, `mkdir` for every path component of every file, all serial.

| Benchmark | Wall | Instructions | Mallocs |
|---|---|---|---|
| Parse central directory (2,000 entries) | 287 µs | 6.1 M | 2,290 |
| Inflate + CRC 32 MB text | 33 ms | 359 M | 48 |
| Stored + CRC 32 MB random | 5.5 ms | 62 M | 41 |
| Inflate + CRC 2,000 small files | 48 ms | 470 M | 18 K |
| Extract 2,000 small files | 306 ms | 4,012 M | 129 K |
| Extract 32 MB text | 37 ms | 382 M | 146 |
| Extract 32 MB random | 8.4 ms | 84 M | 139 |

## step1 — zlib decoder, zero-allocation decoding, cheaper filesystem work, parallel workers

- `ZipDecoder`: reusable zlib `inflate` state (`inflateReset` per entry) and a single 1 MB output buffer,
  handing out `RawSpan`s. zlib inflate measured 2.3x faster than Compression's (`Backend:` benchmark: 30 ms
  vs ~13 ms for the same 32 MB payload).
- Output callback takes `RawSpan` instead of `Data`; stored entries are passed straight from the mapped archive.
- `DirectoryCache` (one `mkdir` per directory per extraction), `fchmod`/`futimens` on the open descriptor
  instead of `FileManager.setAttributes`, `FilePath.stat` only when the overwrite policy needs it.
- Files extracted by a pool of child tasks (`withThrowingDiscardingTaskGroup` + atomic work queue,
  largest first), one decoder per worker.

| Benchmark | Wall | Instructions | Mallocs |
|---|---|---|---|
| Parse central directory (2,000 entries) | 295 µs (+3%) | 6.1 M | 2,290 |
| Inflate + CRC 32 MB text | 14 ms (−58%) | 218 M (−39%) | 1 |
| Stored + CRC 32 MB random | 2.6 ms (−52%) | 31 M (−50%) | 0 |
| Inflate + CRC 2,000 small files | 15 ms (−69%) | 217 M (−54%) | 0 |
| Extract 2,000 small files (32 workers) | 333 ms (**+9%**) | 5,490 M (+37%) | 14 K (−89%) |
| Extract 2,000 small files (1 worker) | 230 ms (−25%) | 3,020 M (−25%) | 14 K (−89%) |
| Extract 32 MB text | 17 ms (−54%) | 239 M (−37%) | 44 |
| Extract 32 MB random | 5.7 ms (−32%) | 51 M (−39%) | 44 |

Finding: parallel small-file extraction used 1.75 s of CPU for 333 ms of wall time — 32 workers creating
files in the same directories contend in the kernel. Serial is faster. Next: find the right width.

### Width experiment (2,000 small files, step1 code)

| Workers | 1 | 2 | 4 | 8 | 32 |
|---|---|---|---|---|---|
| Wall | 215 ms | 152 ms | 113 ms | 106 ms | 311 ms |
| CPU | 215 ms | 263 ms | 327 ms | 490 ms | 1,637 ms |

Floor (`Floor: create + write 2,000 files`, raw `open`/`write`/`close`, no decoding, 1 thread): 167 ms,
~1 M kernel instructions per file. Claiming contiguous archive-order batches (so workers stay in
different directories) changed nothing (8 workers: 110 ms), so the contention is filesystem-wide,
not per directory; reverted.

## step2 — cap file-creation width at 8 (plus one worker per ≥ 1 MB entry beyond that)

| Benchmark | Wall | Instructions | CPU |
|---|---|---|---|
| Extract 2,000 small files | 102 ms (−69% vs step1, **−67% vs baseline**) | 3,253 M | 483 ms |
| Extract 2,000 small files (1 worker) | 250 ms (noise: ±10% run to run) | 2,991 M | 250 ms |
| Verify 2,000 small files (parallel, 32 workers) | 4.8 ms (vs 15 ms serial) | 288 M | 25 ms |

Everything else unchanged within noise.

## step3 — own `mmap` (`MappedFile`) and pipelined writes for large deflated entries

- `MappedFile` replaces `Data(contentsOf:options: .alwaysMapped)`: a `Sendable` class owning the mapping,
  exposing `bytes: RawSpan` (`@_lifetime(borrow self)`) and a stable pointer for async decode loops.
- `ZipDecoder.inflatePipelined`: two 1 MB buffers; chunk N is written in a child task
  (`withThrowingTaskGroup`) while chunk N+1 inflates. Used for deflated entries ≥ 4 MB.

| Benchmark | step2 | step3 |
|---|---|---|
| Extract 32 MB text | 17 ms | 15 ms (−12%) |
| Extract 32 MB random | 6.2 ms | 4.3 ms (−31%, from the mapping change) |

## step4 — no per-entry allocations; `sending` instead of `@unchecked Sendable`

- A local func passed as a closure boxed its captured `crc`/`written` vars on the heap: 2 mallocs per
  entry. Closure literals keep them on the stack.
- The pipelined `Chunk` is no longer `@unchecked Sendable`; it's sent to exactly one child task, with
  the single opt-out (`nonisolated(unsafe) let`) at the send site, since it points into the decoder's buffer.

| Benchmark | step3 | step4 |
|---|---|---|
| Inflate + CRC 2,000 small files | 4,001 mallocs | **1** (the harness's own) |
| Inflate + CRC 32 MB text | 3 mallocs | 1 |
| Stored + CRC 32 MB random | 3 mallocs | 1 |

Times unchanged (allocation was never the bottleneck there; now it's provably absent).

### Experiments that didn't pay off

- `openat` relative to cached directory descriptors (skip absolute-path resolution): floor 142 → 133 ms
  (−6%). Path lookup isn't where the time goes; file creation is. Not adopted.
- `@inlinable` on the public entry points (`contents(of:using:_:)`, `contents(of:_:)`, `isEncrypted`):
  removing it changed instructions by < 0.3% and wall time within noise, because each call does a whole
  entry's work. Kept (no cost), but not pushed deeper: that would expose zlib/parsing internals as
  `@usableFromInline` for no measured gain.

## Benchmark summary: baseline → step4

| Benchmark | baseline | step4 | Change |
|---|---|---|---|
| Extract 2,000 small files | 306 ms | 105 ms | −66% |
| Extract 32 MB text | 37 ms | 15 ms | −59% |
| Extract 32 MB random | 8.4 ms | 4.3 ms | −49% |
| Inflate + CRC 32 MB text | 33 ms | 14 ms | −58% |
| Inflate + CRC 2,000 small files | 48 ms / 18 K mallocs | 15 ms / 0 per entry | −69% |
| Stored + CRC 32 MB random | 5.5 ms | 2.7 ms | −50% |
| Extract 2,000 small files: mallocs | 129 K | 14 K | −89% |

## End-to-end CLI comparison (hyperfine, 5 runs, warm cache)

Same archives as the first comparison: SDK headers (3,460 files → 7.4 MB), 188 MB text (→ 30 MB),
200 MB random (stored). `nunzip` before = the pre-optimization release build.

| Job | unzip | ditto | nunzip before | nunzip now | now vs before | now vs unzip |
|---|---|---|---|---|---|---|
| Extract headers.zip | 564 ms | 771 ms | 492 ms | **150 ms** | 3.3x | 3.8x |
| Extract text.zip | 802 ms | 119 ms | 200 ms | **106 ms** | 1.9x | 7.6x |
| Extract random.zip | 763 ms | 45 ms | 69 ms | **39 ms** | 1.8x | 19.7x |
| Test headers.zip (`-t`) | 158 ms | — | 83 ms | **15 ms** | 5.4x | 10.2x |
| Test text.zip (`-t`) | 770 ms | — | 184 ms | **99 ms** | 1.9x | 7.8x |
| Test random.zip (`-t`) | 739 ms | — | 46 ms | **28 ms** | 1.6x | 26.1x |

`nunzip` is now faster than `ditto` on all three (it was 1.6x slower on the large files).

## step5: parsing with the Bytes package (`../Bytes`)

`ByteReader` replaced by `Bytes` for the central directory, EOCD/ZIP64 records, and local headers:
fixed-size headers are read as sub-cursors (one bounds check per record instead of one per field),
signatures are `Byte4` literals, and the EOCD search uses `lastByteOffset(of:)` (16-byte SIMD). The
original parser is kept in `ZipArchive+ByteReaderParsing.swift`, behind `@_spi(Benchmarking)`, so the two
run side by side; the benchmark setup checks they produce identical entries and payload ranges for every
fixture. Baselines: `pre-bytes` (fresh run of step4 code) and `bytes`.

| Benchmark (same run) | ByteReader | Bytes | Change |
|---|---|---|---|
| Parse central directory (2,000 entries, includes `String` names and `Date`s) | 279 µs, 5,861 K instr | 238 µs, 4,960 K instr | −15% |
| Locate 2,000 payloads (local headers) | 207 µs, 3,592 K instr | 202 µs, 3,396 K instr | −5% instr |

Decoding, CRC, and verification are unchanged (they don't parse). Extraction moved within its usual
run-to-run noise (±20%: the two `Floor:` benchmarks, which don't parse at all, moved −9% and −12% between
the same two runs); the ~50 µs saved per archive open is far below that. CLI regression archives behave as
before (Info-ZIP-identical trees; slip, absolute path, bad CRC, truncated, and non-zip inputs rejected).

## step6: DEFLATE decoding with Bytes (`Inflater`), against zlib

`Inflater` (Sources/NativeZip/Inflater.swift) is a DEFLATE decoder written with `Bytes`: block headers are
`Bit`/`Crumb`/`Bits<5>`/`Nibble` fields read from a `BitBuffer`, stored-block lengths are `Byte2`s with
`expect` for NLEN, Huffman tables are built by `HuffmanTable.build` with DEFLATE-specific packed entries,
and matches are `BytesWriter.copy(fromDistance:count:allowingOverrun:)`. `ZipDecoder(backend:)` picks it
(the default) or zlib, which stays for comparison (`nunzip --zlib`, `ExtractionOptions.backend`). Baseline
`bytes-inflate`.

| Benchmark (same run, p50) | Bytes | zlib |
|---|---|---|
| Inflate + CRC 32 MB text | 13 ms, 0 mallocs | 14 ms, 1 malloc |
| Inflate + CRC 2,000 small files | 14 ms, 0 mallocs | 15 ms, 1 malloc |
| Verify 2,000 small files (parallel) | 4.70 ms (a later run: 4.72) | 5.01 ms (a later run: 4.71) |
| Extract 32 MB text | 15 ms | 15 ms |
| Extract 2,000 small files | within noise (127–161 ms, both) | |

By stream shape (`swift test -c release --filter PerfProbe`): literal-heavy data ties, default-level text
and fixed-code blocks are ~4% faster, long runs (distance-1 matches) 3.5x faster, stored blocks equal.
CLI (hyperfine, Bytes vs zlib): 320 MB text 148 vs 144 ms serial, 23.1 vs 22.5 ms parallel (noise);
20,000 small files 172 vs 176 ms serial, 51.9 vs 53.2 ms parallel.

Correctness: round trips of zlib output at every level and strategy, a 20,000-case mutation differential
against zlib (same output or both reject), and malformed streams.

### How it got from 2x slower to faster

The first version was 2x slower than zlib. In order of payoff:

1. **Inlining.** `@inline(__always)` is a hint, and the inliner refused it for the match copy ("not
   profitable", cost 263 against benefit 45); the call took the writer by address, which put it in memory for
   the whole loop. Splitting the decoder into small functions with their own local `BitBuffer` and
   `BytesWriter`, and marking the hot `Bytes` APIs `@inline(always)` (SE-0496, guaranteed), kept both in
   registers. `BitBuffer.init` had to be always-inlined too, so a literal bit order folds to a constant.
2. **Register-only refill.** The slow refill (near the end) took the fields `inout`, which kept them in
   memory on the fast path too; it now takes and returns values. Shift counts use `truncatingIfNeeded`,
   removing sign checks.
3. **libdeflate's table builder**: table building was 11% of small-file time. Codes are visited in
   canonical order with the bit-reversed code incremented directly, only the first `2^length` root entries
   are written, and they're doubled with `memcpy` at each longer length. Now `HuffmanTable.build` in Bytes.
4. **Shortening the critical path.** The next symbol's entry is looked up before the current one is used;
   the root lookup happens before the refill (11 bits are always buffered) and only the subtable step after
   it; after a length code, the distance is decoded from the bits already buffered while the refill and the
   match copy proceed. `totalBits` is masked to 6 bits in the entry so ARM's `lsr` takes the raw entry.
5. **Overrun copies.** Matches copy 16 bytes at a time (8 for distances under 16) and may write up to 32
   bytes past their end, kept free by the loop condition; distance 1 is a `memset`.

Tried and reverted: 8-byte steps for all distances, unrolled byte copies, exact copies for distances
under 32, decoding literal pairs from a combined table (small files 14 → 23 ms: building it costs more than
it saves on short blocks), an adaptive literal-run loop, and gathering literals into a word store.

## step7: safe constructs (baselines `pre-safety` → `safe-final`, `bytes` → `safe-parse`)

- **Inflater tables** moved from a raw allocation to a `[UInt32]` read through `Span`s. Every lookup is
  bounds-checked; `decodeSymbols` states the tables' sizes once (`precondition`), after which the masked
  root lookups' checks fold. Instruction counts identical (small files 238 → 239 M, 32 MB text 249 → 249 M).
- **Output** reaches the inflater as a `MutableRawSpan` rather than a buffer pointer. `ZipDecoder` creates it
  from its own buffers, which stay raw allocations: the pipelined path sends chunks of them to child tasks.
- **The code-length table and the table builder** are `Bytes`' `HuffmanTable`, now safe throughout.
- **`BitBuffer`'s refill load** stays unchecked: checked, DEFLATE took 10% more instructions.
- **Zip fields with Bytes' bit-field APIs**: the DOS date and time (`date[Bits<7>.self, at: 9]` …), the Unix
  mode (`attributes[bits: 16..<32]`), the directory attribute (`[bit: 4]`), and the host OS
  (`versionMadeBy[Byte.self, at: 8]`); saturation tests compare against `UInt16.max`/`UInt32.max`. Parsing
  the central directory is 1% fewer instructions (4,907 vs 4,960 K). `ZipEntry.isEncrypted` keeps its mask:
  it's public and inlinable, and `Bytes` is imported `internal`.
- **Remaining `unsafe`** has comments saying why: `mmap`/`munmap` (`MappedFile`), zlib's and
  Compression's C APIs, `symlink`/`mkdir`/`futimens`/`fnmatch`, System's buffer-pointer `writeAll`,
  `Data`'s buffer-pointer append, and the pipelined decoder's cross-task chunks.

## step8: native CRC-32 for the Bytes backend (baseline `native-crc`)

Entry verification uses each backend's own CRC: `Bytes`' `CRC32` with the `Bytes` decoder, zlib's
`crc32_z` with zlib's, so each backend is measured whole (`ZipDecoder.crc32(_:_:backend:)`, static so it
can run inside `inflate`'s callbacks). Stored entries follow the decoder's backend too. Direct
comparisons are `CRC-32 <size>: Bytes / zlib` and `Stored + CRC 32 MB random: Bytes / zlib`.

| Benchmark (p50) | Bytes | zlib |
|---|---|---|
| CRC-32 32 MB | 532 µs (63 GB/s) | 888 µs (38 GB/s) |
| CRC-32 256 KB, in cache (×128) | 460 µs | 833 µs |
| CRC-32 1 KB (×32 K) | 665 µs | 1,279 µs |
| CRC-32 64 B (×512 K) | 3,084 µs | 6,963 µs |
| Stored + CRC 32 MB random | 2.56 ms, 29 M instructions | 2.92 ms, 31 M |
| Inflate + CRC 32 MB text | 12.9 ms | 13.6 ms |
| Inflate + CRC 2,000 small files | 13.9 ms | 14.6 ms |

CRC is about 4% of inflating time, so the decode benchmarks move by less than their noise (instructions
−1%). How `CRC32` works is in Bytes' RESULTS.md.
