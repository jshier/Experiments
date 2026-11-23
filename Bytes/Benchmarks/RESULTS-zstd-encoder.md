# Zstandard encoding: `ZstdEncoder` against libzstd 1.5.7

2026-11-23, M3 Ultra, macOS 27.2, Xcode's Swift 6.4. Measured while other agents built and benchmarked (load average
8–13): cycles and instructions are the numbers to trust, wall times are under load.

## What it is

`ZstdEncoder` (BytesCompression, `ZstdEncoder.swift`, `ZstdEncoderBlock.swift`, `ZstdEncoderEntropy.swift`,
`ZstdMatchFinder.swift`) encodes Zstandard frames (RFC 8878) with libzstd 1.5.7's levels 1–4: its `fast` (levels 1, 2)
and `dfast` (3, 4) match finders, its block pre-splitter, and its entropy decisions, ported decision for decision.
With the same parameters a frame from `compressAll` is **libzstd's frame, byte for byte**: every Silesia file, the web
assets, 1–64 KB bodies, block boundaries, and the decoder tests' samples, at every level, with and without checksums.

```swift
var encoder = ZstdEncoder(level: 3, windowLog: ZstdEncoder.Parameters.httpWindowLog, checksum: false)
try encoder.compressAll(body, into: &output)            // one frame, content size stated
encoder.reset()                                         // or reset(contentSize:) to state it when streaming
let progress = try encoder.compress(chunk, into: &output, flush: .none)   // .flush ends a block, .finish the frame
```

- `ZstdEncoder.Parameters`: `strategy` (`.fast`, `.doubleFast`), `windowLog` (10–27), `hashLog`, `chainLog`,
  `minimumMatchLength`, `targetLength`, as `ZSTD_c_*`; `init(level:windowLog:)` takes libzstd's table for inputs over
  256 KB. For content of a known size, the window and tables shrink to it as libzstd's do (`ZSTD_adjustCParams`).
- Literals raw, RLE, or Huffman (1 or 4 streams, a new tree or the previous block's); sequence tables predefined,
  RLE, or FSE-described (zstd's normalization with "less than one" cells and its spread), chosen as libzstd chooses;
  repeat offsets updated as the decoder updates them; raw blocks when compression doesn't gain libzstd's minimum, RLE
  blocks for runs (not as a frame's first block, as libzstd).
- Single-segment frames only when the content size is known and fits in the configured window, so no frame needs a
  larger window than `windowLog`: a 9 MiB body with the HTTP window states a 512 KB window (tested with decoders limited
  to 512 KB).
- `ByteTransform` and `ResettableByteTransform`. A frame whose first call is `.finish` (a whole body at once), or one
  after `reset(contentSize:)`, is the one-shot frame: tested identical, through the streaming window's slides.
- Reusable: `reset()` keeps everything; the tables aren't cleared, their indices keep growing from frame to frame (an
  entry below the frame's start is ignored) and are moved down near 3.5 GB as libzstd's (`ZSTD_reduceIndex`;
  tested by starting a frame just below the limit: the frame is unchanged).
- Allocations: the tables at creation; the streaming window as streams need it, up to the window plus a block. Gates at
  0 mallocs: `Allocations:Zstd_encode_L1`, `_L3`, `_L1_streaming`, `_L3_streaming` (`Thresholds/`).

### The HTTP window

RFC 9659 caps `zstd` content coding's window at 8 MB. `Parameters.httpWindowLog` is **19** (512 KB): bodies up to 512 KB
lose nothing (their frames are single segments sized to them), streaming memory at level 3 is 2.1 MB instead of 3.7 MB,
and on larger files level 3 loses 0–1.7% except samba's tar (+4.0%). Window log 20 is the alternative when large bodies
dominate (+0.0–0.6%, samba +1.6%; 2.6 MB streaming).

| Level 3, frame bytes | w17 | w18 | **w19** | w20 | w21 (level 3's) | w23 |
|---|---:|---:|---:|---:|---:|---:|
| dickens (9.7 MB) | 4,031,345 | 3,771,584 | 3,699,102 | 3,673,138 | 3,663,504 | 3,658,420 |
| mozilla (48.8 MB) | 19,164,994 | 18,654,908 | 18,399,681 | 18,290,358 | 18,227,296 | 18,217,164 |
| xml (5.1 MB) | 753,048 | 685,672 | 646,234 | 635,444 | 635,299 | 636,150 |
| x-ray (8.1 MB) | 6,352,877 | 6,096,150 | 6,084,863 | 6,085,154 | 6,085,208 | 6,085,208 |
| samba (20.6 MB) | 5,540,207 | 5,247,197 | 5,150,920 | 5,035,802 | 4,955,117 | 4,923,789 |
| webster (39.5 MB) | 13,211,241 | 12,469,724 | 12,227,322 | 12,120,710 | 12,096,850 | 12,055,702 |
| Main.js (3.8 MB) | 862,076 | 817,254 | 800,142 | 792,875 | 787,883 | 786,220 |
| Main.css (376 KB) | 70,225 | 66,370 | 65,941 | 65,941 | 65,941 | 65,941 |

### Memory (bytes)

`memoryUsage`: tables, sequence store, literals, and a staging buffer at creation; streaming adds the window and a block.
libzstd's are `ZSTD_estimateCCtxSize_usingCParams` and `ZSTD_estimateCStreamSize_usingCParams` with the same parameters.

| Level, window | Bytes: tables | Bytes: streaming | libzstd CCtx | libzstd CStream |
|---|---:|---:|---:|---:|
| 1, w19 (level 1's) | 734,656 | 1,390,016 | 582,680 | 1,369,625 |
| 2, w19 | 931,264 | 1,586,624 | 779,288 | 1,566,233 |
| 2, w20 (level 2's) | 931,264 | 2,110,912 | 779,288 | 2,090,521 |
| 3, w19 (HTTP) | 1,455,552 | 2,110,912 | 1,303,576 | 2,090,521 |
| 3, w20 | 1,455,552 | 2,635,200 | 1,303,576 | 2,614,809 |
| 3, w21 (level 3's) | 1,455,552 | 3,683,776 | 1,303,576 | 3,663,385 |
| 4, w19 | 2,766,272 | 3,421,632 | 2,614,296 | 3,401,241 |
| 4, w21 (level 4's) | 2,766,272 | 4,994,496 | 2,614,296 | 4,974,105 |

The one-shot difference is the staging buffer (a block, 128.5 KB): libzstd writes blocks straight into the caller's
buffer. Of level 3's 1.46 MB, 768 KB are the two hash tables and 352 KB a block's sequences and their codes.

## Method

- **Ratio and identity:** `ZstdEncoderTests.matchesLibzstd` (every sample at 11 parameter sets, checksum on and off)
  and `ZstdEncoderBulkTests.matchesLibzstdOnTheCorpus` (all 12 Silesia files and 5 web files at levels 1–4 and level 3
  with the HTTP window) compare our frame with `ZSTD_compress2`'s, libzstd given `ZSTD_c_strategy`, `windowLog`,
  `hashLog`, `chainLog`, `searchLog` (1), `minMatch`, `targetLength` (and the checksum flag) one by one, so the
  comparison doesn't depend on libzstd's tables for small inputs. libzstd still shrinks the window and tables to a
  known content size; so does `ZstdEncoder`. `ZSTD_versionNumber()` is 10507.
- **Cycles and instructions:** a scratch harness (a package depending on this one and on libzstd) runs each encoder
  on each input in 5 interleaved rounds, each round as many calls as make about 60 MB (at least 3), and reports the
  least cycles and instructions per input byte of each (`proc_pid_rusage`, `ri_cycles` and `ri_instructions`), with
  both contexts reused across calls. Cycles don't move with the clock; under load they rise a little for both.
- **package-benchmark:** `CompressionBenchmarks`' `Zstd encode …` rows, baseline `r2-zstd-encode` (each setup checks
  that the frame equals libzstd's): the same comparison in the suite, instructions and wall time (under load).

## Results

### Corpus files, one call (cycles and instructions per input byte; frames identical, so ratios are libzstd's)

| Input | Level | Frame bytes | Cycles/B Bytes | libzstd | Δ | Instr/B Bytes | libzstd | Δ |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 1 | 4,261,734 | 7.990 | 7.581 | +5.4% | 34.83 | 31.29 | +11.3% |
| dickens | 2 | 3,864,999 | 12.430 | 12.267 | +1.3% | 34.99 | 32.08 | +9.1% |
| dickens | 3 | 3,663,504 | 14.173 | 13.754 | +3.0% | 37.23 | 34.11 | +9.2% |
| dickens | 4 | 3,584,538 | 13.953 | 13.555 | +2.9% | 35.48 | 32.53 | +9.1% |
| dickens | 3, w19 | 3,699,102 | 14.265 | 13.839 | +3.1% | 38.09 | 34.94 | +9.0% |
| mozilla | 1 | 19,968,503 | 5.679 | 5.458 | +4.0% | 25.14 | 22.83 | +10.1% |
| mozilla | 2 | 18,929,451 | 6.576 | 6.443 | +2.1% | 24.68 | 22.74 | +8.5% |
| mozilla | 3 | 18,227,296 | 8.409 | 8.253 | +1.9% | 30.77 | 28.57 | +7.7% |
| mozilla | 4 | 18,043,148 | 8.880 | 8.696 | +2.1% | 30.35 | 28.17 | +7.7% |
| mozilla | 3, w19 | 18,399,681 | 8.375 | 8.243 | +1.6% | 31.06 | 28.87 | +7.6% |
| xml | 1 | 693,317 | 3.618 | 3.547 | +2.0% | 12.72 | 11.49 | +10.7% |
| xml | 3 | 635,299 | 4.479 | 4.416 | +1.4% | 13.55 | 12.60 | +7.6% |
| xml | 3, w19 | 646,234 | 4.537 | 4.470 | +1.5% | 13.77 | 12.80 | +7.6% |
| x-ray | 1 | 6,772,118 | 4.414 | 4.500 | −1.9% | 15.44 | 17.92 | −13.8% |
| x-ray | 3 | 6,085,208 | 15.624 | 15.178 | +2.9% | 60.55 | 55.70 | +8.7% |
| x-ray | 4 | 5,709,895 | 18.155 | 17.662 | +2.8% | 59.75 | 54.79 | +9.0% |
| samba | 1 | 5,487,600 | 4.947 | 4.828 | +2.5% | 18.41 | 16.78 | +9.7% |
| samba | 3 | 4,955,117 | 6.846 | 6.692 | +2.3% | 20.33 | 18.91 | +7.5% |
| samba | 3, w19 | 5,150,920 | 7.020 | 6.881 | +2.0% | 21.36 | 19.87 | +7.5% |
| Main.js | 1 | 877,255 | 6.329 | 6.232 | +1.6% | 21.03 | 18.98 | +10.8% |
| Main.js | 2 | 845,395 | 7.097 | 7.064 | +0.5% | 21.52 | 19.71 | +9.2% |
| Main.js | 3 | 787,883 | 7.639 | 7.458 | +2.4% | 21.73 | 20.02 | +8.6% |
| Main.js | 4 | 785,639 | 7.548 | 7.378 | +2.3% | 21.48 | 19.80 | +8.5% |
| Main.css | 1 | 70,426 | 5.380 | 5.350 | +0.6% | 17.67 | 15.96 | +10.7% |
| Main.css | 3 | 65,941 | 6.130 | 5.949 | +3.1% | 18.69 | 17.12 | +9.2% |

### HTTP bodies, one call (the first 1–64 KB of each file; level 3 with the HTTP window)

| Body | Level | Frame bytes | Cycles/B Bytes | libzstd | Δ | Instr Δ |
|---|---|---:|---:|---:|---:|---:|
| dickens 1 KB | 1 | 585 | 12.04 | 13.69 | −12.1% | −12.2% |
| dickens 1 KB | 3 | 571 | 14.86 | 16.21 | −8.3% | −3.2% |
| xml 1 KB | 1 | 392 | 10.58 | 12.22 | −13.4% | −14.0% |
| Main.js 1 KB | 3 | 404 | 11.94 | 13.41 | −11.0% | −8.6% |
| Main.html (2.7 KB) | 1 | 1,428 | 8.03 | 8.13 | −1.3% | +1.3% |
| Main.html (2.7 KB) | 3 | 1,373 | 10.20 | 10.37 | −1.6% | +5.9% |
| dickens 4 KB | 1 | 2,234 | 7.40 | 7.62 | −3.0% | +1.5% |
| dickens 4 KB | 3 | 2,115 | 9.99 | 9.96 | +0.4% | +6.9% |
| Main.js 4 KB | 3 | 1,731 | 7.95 | 8.07 | −1.5% | +6.5% |
| Main.css 4 KB | 3 | 1,735 | 7.89 | 7.93 | −0.5% | +6.5% |
| dickens 16 KB | 1 | 7,994 | 5.81 | 6.09 | −4.5% | +2.9% |
| dickens 16 KB | 3 | 7,485 | 9.46 | 9.46 | −0.0% | +8.0% |
| Main.js 16 KB | 3 | 4,593 | 5.57 | 5.63 | −1.0% | +8.0% |
| xml 16 KB | 3 | 2,125 | 2.86 | 2.94 | −2.7% | +7.7% |
| dickens 64 KB | 1 | 29,218 | 6.55 | 6.60 | −0.9% | +3.9% |
| dickens 64 KB | 3 | 27,039 | 12.51 | 12.16 | +2.9% | +8.8% |
| Main.js 64 KB | 1 | 20,030 | 5.07 | 5.15 | −1.5% | +4.6% |
| Main.js 64 KB | 3 | 18,467 | 7.33 | 7.27 | +0.8% | +8.9% |
| Main.css 64 KB | 3 | 12,386 | 4.99 | 5.15 | −3.1% | +9.1% |
| xml 64 KB | 3 | 6,103 | 2.01 | 2.02 | −0.3% | +9.1% |

Below about 2 KB the per-frame work dominates, and ours is 8–14% cheaper (libzstd re-checks and resets its context's
parameters on every `ZSTD_compress2`).

### Streamed in 64 KB pieces, size unknown (level 3, HTTP window; libzstd `ZSTD_compressStream2`, `ZSTD_e_continue`)

| Input | Bytes frame | libzstd frame | Cycles/B Bytes | libzstd | Δ |
|---|---:|---:|---:|---:|---:|
| dickens | 3,699,098 | 3,708,272 | 14.68 | 15.33 | −4.3% |
| mozilla | 18,399,677 | 18,569,338 | 9.46 | 10.50 | −9.9% |
| xml | 646,230 | 646,119 | 4.86 | 5.10 | −4.6% |
| x-ray | 6,084,859 | 6,084,241 | 15.91 | 17.52 | −9.2% |
| samba | 5,150,916 | 5,176,547 | 7.65 | 8.14 | −6.0% |
| Main.js | 800,138 | 806,008 | 8.03 | 8.41 | −4.5% |

Streamed frames aren't libzstd's: its circular input buffer turns the window's older part into an external dictionary,
searched by the `_extDict` match finders; ours slides a flat window (the window plus a block, one move of the window per
block once it's full), so its frames are within 0.1% of the one-shot frame and 0–0.9% smaller than libzstd's streamed
ones. Bodies sent at once with `.finish` (or after `reset(contentSize:)`) are the one-shot frame, as libzstd's are.

### In the suite (baseline `r2-zstd-encode`, p50; wall times under load)

| Benchmark | Bytes instructions | libzstd | Bytes µs | libzstd µs |
|---|---:|---:|---:|---:|
| L1 dickens (9.7 MB) | 355 M | 319 M | 25,000 | 24,000 |
| L3 dickens | 380 M | 348 M | 45,000 | 44,000 |
| L1 mozilla (48.8 MB) | 1,288 M | 1,169 M | 91,000 | 87,000 |
| L3 mozilla | 1,576 M | 1,464 M | 134,000 | 133,000 |
| L1 x-ray (8.1 MB) | 131 M | 152 M | 12,000 | 12,000 |
| L1 xml (5.1 MB) | 68 M | 61 M | 6,017 | 5,886 |
| L1 Main.js (3.8 MB) | 83 M | 75 M | 8,020 | 7,614 |
| L3 Main.js | 86 M | 79 M | 10,000 | 9,150 |
| L1 body Main.js 1 KB | 46,000 | 53,000 | 4.04 | 4.59 |
| L1 body Main.js 64 KB | 1,611,000 | 1,541,000 | 101 | 109 |
| L1 body dickens 64 KB | 2,253,000 | 2,169,000 | 144 | 134 |
| L3 w19 Main.js, streaming 64 KB | 91 M | 94 M | 10,000 | 10,000 |
| L3 random (1.0 MB): raw blocks | 1,961,000 | 1,622,000 | 140 | 122 |

The random row is the one where Bytes is clearly behind in the suite (+21% instructions, +15% time): every block is
stored raw, copied into the staging buffer and then out (libzstd copies once, into the destination). Not measured
apart; see "Not done".

### Targets

- Ratio within 2% of libzstd: **identical frames** at levels 1–4 (0.0%).
- Cycles within 15% at levels 1 and 3: **−14% to +5.4%** on every row (one call); parity within ±3% on most.
- 0 mallocs after setup: the four gates pass.
- Instructions remain **+7.5 to +11%** on large inputs (x-ray level 1: −14%): see "The gap that's left".

## How it got there (harness; cycles per byte, load 10–13)

| Step | Change | Effect |
|---|---|---|
| 1 | The port, libzstd's loops and decisions | Frames identical. Cycles +8 to +30% at level 1, +4 to +21% at level 3; 64 KB bodies +18 to +31% |
| 2 | Sequence-code histograms with four interleaved tables above 1,500 codes (`HIST_countFast_wksp`), not one: a run of one code made each increment wait for the last | Histograms 8.4% → under 3% of dickens' level 3 profile; dickens L3 15.55 → 14.49 c/B (+10.4% → +3.6%) |
| 3 | libzstd's prefetches (`ip1+64`, `ip1+128` when the step grows; `ip+256` each dfast position, its aarch64 build): `Builtin.int_prefetch_RawPointer` emits `prfm` | mozilla L1 +19.9% → +12.1%, dickens L1 +15.3% → +12.8% |
| 4 | Huffman codes stored top-aligned (`value << (64 − length) \| length`), added with one shift and one OR (the shift is the entry itself), groups of 5–9 codes per flush by table log, alternate groups in a second container (`HUF_CStream_t`); was a 32-bit entry, mask, shift, and OR per code, 4 per flush | x-ray L1 5.95 → 4.43 c/B (+31% → −2%); dickens L1 +12.8% → +5.1% |
| 5 | Candidate validity checked after the comparison, as a conditional compare: `unlikely(load(candidate) == load(here)) && valid`, the candidate address chosen by a select. LLVM had hoisted `valid` into a branch before the loads (to skip them), and validity is unpredictable when many table entries are outside the window: small adjusted windows, the HTTP window on large files | dickens 64 KB L1 +30.8% → −0.9%, Main.js 64 KB L1 +24.0% → −1.5%, dickens 64 KB L2 +18.6% → +1.2%, mozilla L3 w19 +17.8% → +1.6% |
| 6 | dfast's sequence store left in its `inout` parameter (it's touched per match; as a local its 6 fields took registers) | One of the two hash constants no longer rematerialized per position; loop 61 → 49 instructions with step 5 (libzstd's: 45) |

Tried and not kept:

- **Folding validity into the comparison** (`(a ^ b) | invalid == 0`): LLVM split it back into a branch on `invalid`
  ahead of the loads. Only the ordering with `unlikely` on the comparison held (step 5).
- **Treating rematerialized constants as register pressure:** freeing registers (step 6) removed one of the two
  `mov`/`movk` sequences; the other stays (LLVM's cost model rematerializes rather than keep it), 3 instructions a
  position that run in parallel with the loads.

## The gap that's left

Instructions are 7.5–11% above libzstd's on large inputs at the same cycles (±3%). The dfast search loop is 49
instructions against libzstd's 45: a rematerialized 5-byte-hash prime (3) and two shift amounts reloaded from the
stack per position (libzstd reloads one). The match-length tails are 3 compare-and-select steps where clang uses
branches. The entropy stages are at parity or below (x-ray level 1, nearly all literals: −14% instructions).

## Not done

- **Levels 5 and up** (greedy, lazy, lazy2, the binary-tree and optimal parsers). libzstd 1.5.7 uses its row match
  finder (SIMD tag rows) for greedy and lazy with windows over 16 KB, so matching its frames means porting that; the
  cost-based table selection and repeat modes the lazy levels use are already in the block encoder
  (`selectMode`'s second branch: `ZSTD_selectEncodingType` for `strategy >= ZSTD_lazy`), untested by frames.
- Dictionaries, long-distance matching, multithreading, `targetCBlockSize`, negative levels (the fast strategy with a
  target length runs, with literal compression off as libzstd does, but `init(level:)` stops at 1).
- Writing blocks straight into the caller's buffer in `compressAll`: would save a copy of every block (all of the input
  for incompressible data, the likely cause of the random row's gap) and 128 KB of memory.

## Tests

`ZstdEncoderTests` (fast set, 9 tests, 4 s in debug): every sample (empty, 1, 6, 7 bytes, 1,000 and 300,000 random
bytes, runs of zeros at and past 128 KB, text at 128 KB ± 1 and 256 KB, random then zeros, the decoder tests' samples)
at 11 parameter sets (levels 1–4, every hash length, small windows and tables, a target length, window 10, the HTTP
window) with and without checksums: libzstd's frame byte for byte, decoded by libzstd and by `ZstdDecoder` one call and
streamed; streaming (1-byte to 70,000-byte pieces, 7-byte to 64 KB output buffers, flushed or not) decodes, within 1% of
the one-shot frame; whole bodies at once and pledged sizes give the one-shot frame through window slides; 400 small
flushes; empty frames; a wrong pledged size throws; the 9 MiB window test; index correction near 3.5 GB; memory.
`ZstdEncoderBulkTests` (3 tests, release): the corpus at every level (byte for byte, and streamed with its size
pledged), every size 0–300 and ±40 around 32, 64, 96, and 128 KB at every level against libzstd, and random pieces,
flushes, and output room at every parameter set. All of BytesCompressionTests pass (289 tests).
