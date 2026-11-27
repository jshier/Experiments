# Base64 performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M3 Ultra, macOS 27.2, Swift 6.4.2 (Xcode 27.3),
one core. Random input; each measured iteration encodes at least 4 MB, repeating short inputs. Throughput
counts input bytes; output is 4/3 as many. Everything below is M3 Ultra unless a heading says otherwise; the
2026-11-19 section re-runs the suite on an M1 Max.

Base64 was its own package (`Base64/`) until 2026-11-19; it's now Bytes' `BytesBase64` module (`import BytesBase64`,
same API), and paths below are Bytes'. Its baselines (`.benchmarkBaselines/Base64Benchmarks/`) and thresholds
(`Thresholds/Base64Benchmarks.*`) kept their names, so every baseline below still compares. From `Bytes/`:

```sh
swift test --filter BytesBase64Tests        # RFC 4648 vectors; every length to 200 and some larger, both alphabets,
                                            # padded and not, against Foundation; whitespace; errors and offsets
../Tools/loops --target . BytesBase64 encodeBlocks --require tbl,zip --forbid mov.b,ins                   # ARM64 kernel
../Tools/loops --target . BytesBase64 'encode\(_:into:alphabet:\)' --require ld3.16b,st4.16b              # portable kernel
swift package --disable-sandbox benchmark --target Base64Benchmarks
swift package --disable-sandbox benchmark thresholds check --target Base64Benchmarks --filter 'Allocations:.*'
./bench portable --target Base64Benchmarks  # the C module's portable fallbacks (`portable-no-c`: Swift only)
```

The ARM64 kernels need Bytes' `NEONShuffle` trait (on by default) and not `Portable` (`ByteLanes.isLookupVectorized`):
NEON's `tbl`, `tbx`, `uzp`, and `zip` come through the `CBytesNEON` C module, because Swift can't express them.
Otherwise encoding and decoding use the portable kernels.

## 2026-11-27: a complemented decoding window (M1 Max; baselines `b64-old-1` → `b64-new-2`)

The decoder's window of values is kept complemented (0 for characters not in the alphabet): its first lookup is a
4-register `tbl` instead of `movi` 0xFF and a 4-register `tbx`, then one `mvn` (on the M1 Max, 4 vector slots for 5 per
16 characters). Decoding 1 KB −11.6%, 16 KB −5.6%, 1 MB −8.5%, 64 MB −8.0%; 40–95 bytes level (instructions equal).
The standard alphabets' windows are written complemented: complementing them in the initializer didn't fold and cost
8.6% at 40 bytes. Muła and Lemire's nibble-lookup decode, counted at this core's costs, would take about 62 slots per
64 characters against 53 now, so it wasn't tried. Details: `RESULTS.md`, 2026-11-27, later.

## 2026-11-19: the same suite on an M1 Max (baselines `d2-final` → `m1max`)

Every benchmark, run unchanged on a new machine and compared with the M3 Ultra's `d2-final` (2026-11-18). The M3
numbers above and below aren't touched.

| | M3 Ultra | M1 Max |
|---|---|---|
| Cores | 24 P + 8 E | 8 P + 2 E |
| P-core clock (max) | ~4.05 GHz | ~3.23 GHz (the M3's is 1.25x) |
| Memory | 256 GB LPDDR5-6400, 819 GB/s | 64 GB LPDDR5-6400, 400 GB/s |
| ISA | NEON, AES, PMULL, SHA-3 set, CRC32, DotProd, … | the same, without I8MM and BF16 |
| OS, toolchain | macOS 27.2, Swift 6.4.4 (Xcode 27.3) | macOS 27.2.1, Swift 6.4.4 (Xcode 27.3, same compiler) |

- **Method:** `swift package --disable-sandbox benchmark baseline update m1max --no-progress`, one package at a
  time, nothing else benchmarking. The M1 Max had `corespotlightd` using about one core during the Bytes runs
  (indexing new files; it couldn't be stopped); single-thread medians weren't noticeably affected there. The M3 baseline was taken at a slightly different commit, so **Instructions** is the
  same-code check, below.
- **Reading the tables:** "GB/s" is bytes per iteration over the median time, with bytes per iteration =
  `count × max(1, 4 MiB / count)` (`Fixture`): input bytes for encoding, decoded bytes for decoding. Times are
  `Time (wall clock)` medians, which are rounded to two digits from 10 ms (the Foundation and scalar rows at
  40 B, and 64 MB): ±5% there. The ratio is **M1 Max time / M3 Ultra time**, so above 1 is slower, and 1.25 is
  the clock ratio alone. The framework's `Throughput` rows (iterations per second) carry the same
  information: Bytes encoding at 1 MB is −17.9% there, 1.22x in time.

### Headline

**Geometric mean of M1 Max time / M3 Ultra time over all 81 timed benchmarks: 1.27** (n = 81: 9 sizes × 4
encoders + 5 decoders; the 18 `Allocations:*` benchmarks have no time). By group:

| Group | Geomean | n | Range |
|---|---|---|---|
| Encode (all) | 1.25 | 36 | 1.02–1.46 |
| Decode (all) | 1.28 | 45 | 1.11–1.50 |
| Bytes kernels (encode and decode into a buffer) | 1.26 | 18 | 1.12–1.45 |
| …at 16 KB and larger | 1.20 | 6 | |
| …at 95 B and smaller | 1.32 | 8 | |
| `encodedString`, `decodedBytes` (allocate) | 1.34 | 18 | 1.11–1.48 |
| Foundation | 1.35 | 18 | 1.18–1.50 |
| Decode, portable groups (Bytes, no NEON lookups) | 1.23 | 9 | 1.12–1.31 |
| Scalar table | 1.15 | 18 | 1.02–1.25 |

### Same code on both machines?

80 of the 81 benchmarks' instruction counts per iteration are within 2% of the M3's; 76 are identical in the
digits recorded (two significant). The five that differ:

| Benchmark | M3 | M1 Max | Change |
|---|---|---|---|
| Decode 47 B, portable groups | 110 M | 111 M | +0.9% |
| Decode 64 B, portable groups | 45 M | 46 M | +2.2% |
| Decode 64 MB, Foundation | 738 M | 739 M | +0.1% |
| Decode 64 MB, scalar table | 2,528 M | 2,529 M | +0.0% |
| Encode 16 KB, `encodedString` | 4,862 K | 4,882 K | +0.4% |

The one above 2% is 45 M against 46 M, two digits: within rounding of the recorded values. So the time ratios
are hardware ratios, to within what two digits resolve.

### Encoding (GB/s of input: M3 Ultra → M1 Max, ratio)

| Input | Bytes encoder | Instructions | `encodedString` | Foundation | Scalar table |
|---|---|---|---|---|---|
| 40 B | **4.10 → 3.08 (1.33x)** | 29.0 M | 0.73 → 0.53 (1.37x) | 0.38 → 0.32 (1.18x) | 0.85 → 0.76 (1.11x) |
| 47 B | **4.58 → 3.63 (1.26x)** | 24.0 M | 0.74 → 0.58 (1.29x) | 0.51 → 0.38 (1.34x) | 0.85 → 0.77 (1.11x) |
| 64 B | **5.04 → 4.05 (1.24x)** | 21.0 M | 0.96 → 0.67 (1.43x) | 0.64 → 0.48 (1.33x) | 0.86 → 0.77 (1.13x) |
| 95 B | **8.74 → 6.04 (1.45x)** | 14.0 M | 1.42 → 0.97 (1.46x) | 0.93 → 0.66 (1.41x) | 0.81 → 0.77 (1.05x) |
| 1000 B | **17.3 → 15.2 (1.14x)** | 3.9 M | 7.91 → 5.89 (1.34x) | 2.46 → 1.88 (1.31x) | 0.79 → 0.77 (1.02x) |
| 1 KB | **19.1 → 15.0 (1.27x)** | 3.9 M | 8.08 → 6.03 (1.34x) | 2.54 → 1.89 (1.34x) | 0.88 → 0.77 (1.14x) |
| 16 KB | **20.9 → 17.5 (1.19x)** | 2.9 M | 15.2 → 12.3 (1.24x) | 3.02 → 2.36 (1.28x) | 0.79 → 0.77 (1.02x) |
| 1 MB | **21.5 → 17.6 (1.22x)** | 2.8 M | 17.0 → 13.1 (1.30x) | 3.17 → 2.36 (1.34x) | 0.85 → 0.77 (1.10x) |
| 64 MB | **20.7 → 17.2 (1.20x)** | 45.0 M | 15.7 → 12.3 (1.28x) | 3.36 → 2.31 (1.45x) | 0.88 → 0.77 (1.14x) |

### Decoding (GB/s of decoded bytes)

| Input | Bytes decoder | Instructions | `decodedBytes` | Portable groups | Foundation | Scalar table |
|---|---|---|---|---|---|---|
| 40 B | **3.22 → 2.34 (1.37x)** | 36.0 M | 0.70 → 0.48 (1.46x) | 0.76 → 0.64 (1.19x) | 0.47 → 0.32 (1.47x) | 0.25 → 0.20 (1.24x) |
| 47 B | **4.28 → 3.22 (1.33x)** | 26.0 M | 0.83 → 0.58 (1.43x) | 0.80 → 0.64 (1.25x) | 0.50 → 0.35 (1.43x) | 0.25 → 0.20 (1.24x) |
| 64 B | **4.06 → 3.31 (1.23x)** | 23.0 M | 1.05 → 0.75 (1.40x) | 1.93 → 1.47 (1.31x) | 0.70 → 0.47 (1.50x) | 0.23 → 0.20 (1.17x) |
| 95 B | **6.58 → 4.85 (1.36x)** | 16.0 M | 1.66 → 1.12 (1.48x) | 1.38 → 1.08 (1.28x) | 0.87 → 0.63 (1.39x) | 0.23 → 0.20 (1.17x) |
| 1000 B | **12.1 → 9.53 (1.27x)** | 5.4 M | 7.68 → 5.59 (1.37x) | 3.57 → 2.90 (1.23x) | 2.29 → 1.78 (1.29x) | 0.25 → 0.21 (1.18x) |
| 1 KB | **11.7 → 9.36 (1.25x)** | 5.5 M | 7.65 → 5.59 (1.37x) | 3.97 → 3.15 (1.26x) | 2.28 → 1.81 (1.26x) | 0.26 → 0.21 (1.25x) |
| 16 KB | **11.6 → 10.4 (1.12x)** | 4.4 M | 11.0 → 9.87 (1.11x) | 3.78 → 3.37 (1.12x) | 3.01 → 2.29 (1.31x) | 0.26 → 0.21 (1.25x) |
| 1 MB | **12.9 → 10.4 (1.24x)** | 4.3 M | 12.4 → 10.4 (1.19x) | 4.25 → 3.39 (1.25x) | 3.02 → 2.27 (1.33x) | 0.25 → 0.21 (1.18x) |
| 64 MB | **12.8 → 10.4 (1.23x)** | 69.0 M | 12.9 → 10.3 (1.24x) | 3.95 → 3.36 (1.18x) | 3.05 → 2.31 (1.32x) | 0.26 → 0.20 (1.25x) |

The Instructions column is per iteration (about 4 MB of work), the same on both machines.

### The Bytes codec against its references

From the same rows (reference time / Bytes kernel time, M3 → M1 Max; the Bytes kernel is the buffer-to-buffer
`BytesReader → BytesWriter` benchmark):

| Reference | Inputs ≥ 1000 B | 95 B and smaller |
|---|---|---|
| Foundation, encode | 6.2–7.5x → 7.4–8.1x | 7.9–10.8x → 8.4–9.5x |
| Foundation, decode | 3.9–5.3x → 4.5–5.4x | 5.8–8.6x → 7.1–9.2x |
| Scalar table, encode | 21.7–26.5x → 19.4–22.8x | 4.8–10.9x → 4.0–7.9x |
| Scalar table, decode | 44.3–52.3x → 44.6–50.8x | 13.0–28.3x → 11.7–24.3x |
| Portable groups, decode | 3.0–3.4x → 3.0–3.3x | 2.1–5.4x → 2.2–5.0x |
| `encodedString` (allocates the `String`) | 1.3–2.4x → 1.3–2.6x | 5.3–6.2x → 5.8–6.3x |
| `decodedBytes` (allocates the array) | 1.0–1.6x → 1.0–1.7x | 3.9–5.1x → 4.3–5.5x |

- **The Bytes kernel is the fastest on the M1 Max at every size and direction.** On the M3 it is too, except
  `decodedBytes` at 64 MB (5,222 against 5,251 µs: a tie). The order of the others differs between the machines
  in 4 of the 18 size and direction combinations, always neighbours swapping: portable groups and `decodedBytes`
  (47 B decode), scalar table and `encodedString` (64 B encode), Foundation and scalar table (95 B encode), and
  the 64 MB tie.
- **Foundation's gap to the kernel is a little wider on the M1 Max** (encode at 1 MB 6.8x → 7.5x, decode 4.3x →
  4.6x); the scalar encoder's is narrower (25.3x → 22.8x at 1 MB), the scalar decoder's level (52.3x → 49.8x).
- **"93% of the best C kernel" and "99% of C of the same design" are not in this data.** The C kernels were
  measured in standalone drivers, not the benchmark suite, and I didn't build or run them (no builds while other
  timing experiments run). So the claim is neither confirmed nor refuted on the M1 Max. What the suite does
  show: the Swift kernel runs 17.6 GB/s encoding and 10.4 GB/s decoding at 1 MB there, and the C numbers would
  have to scale by the same 1.22–1.24 for the percentages to hold.

### Allocations

- All 18 `Allocations:Encode_*` and `Allocations:Decode_*` benchmarks count 0 mallocs on both machines (the
  zero thresholds in `Thresholds/` hold).
- Of the 81 timed benchmarks, 45 count 0 on both (every Bytes kernel, the portable groups, the scalar table); 36
  count the same nonzero number on both: `encodedString` and `decodedBytes` allocate one buffer per call, Foundation
  two (at 1 MB, 4 and 8 mallocs per iteration of 4 calls; at 40 B, 105,000 and 210,000).

### Observations

Measured:

- **The vector kernels at large sizes run at 1.12–1.24x the M3's time**, below the clock ratio. Encoding at 16 KB,
  1 MB, 64 MB: 1.19, 1.22, 1.20; decoding: 1.12, 1.24, 1.23. With equal instruction counts, that is as much or
  a little more work per clock than the M3 Ultra, if both ran at their maximum clocks (not measured). Encoding
  at 1 MB, 17.6 GB/s of input, moves 41 GB/s of input and output together, a tenth of the M1 Max's 400 GB/s,
  and 64 MB runs at 17.2 GB/s, so memory isn't what limits it.
- **Short inputs lose more than the clock**: the kernels at 95 B and smaller are 1.32x (geomean, 1.23–1.45 per
  row), the allocating paths 1.41x, Foundation 1.38x, with the same instructions per iteration. The 95 B encode
  row, 1.45x, is the largest kernel ratio.
- **The scalar table encoder barely moved**: 1.02–1.14x, and 0.77 GB/s at every size on the M1 Max (0.79–0.88 on
  the M3, an 11% spread between sizes with identical instruction counts). The scalar decoder scaled as the clock
  did: 1.17–1.25x.
- **Decode at 16 KB is the smallest ratio**: kernel 1.12x, `decodedBytes` 1.11x, portable groups 1.12x, against 1.24x,
  1.19x, 1.25x at 1 MB. The M1 Max decodes 10.4 GB/s at 16 KB and 1 MB alike; the M3's d2-final is 11.6 GB/s at
  16 KB and 12.9 at 1 MB (the 2026-11-10 table below has 13.0 and 12.5).

Interpretation, not investigated:

- The scalar encoder's flat ratio is unexplained. No counters (`Tools/counters`) were run on either machine.
- The M3's lower 16 KB decode in `d2-final` than in the 2026-11-10 baseline may be noise in that run rather than
  a property of the chip.
- Why short inputs lose more than the clock is not known: allocation, per-call overhead, or clock behavior on short
  bursts are all candidates and none is measured. The allocation-free kernel (1.32x at short sizes) and the
  allocating paths (1.41x) lose similarly, which doesn't point to malloc alone.

## 2026-11-18: a reshuffling encoder kernel, not kept

The SSE/AVX encoders' scheme on NEON: one-register `tbl`s place each 3-byte group in its 4 output bytes as
`[b1, b0, b2, b1]`, then shifts and masks in 32-bit lanes extract the four 6-bit values in output order, so the
characters need no interleave. It cuts the shuffles' `tbl` micro-ops from 9 (three 3-register lookups) to 4,
but costs more elsewhere. `Tools/loops`, instructions in the loop per 48-byte block:

| Kernel | Instructions | Vector work |
|---|---|---|
| Deinterleave, compute, interleave (kept) | 32 | 7 `tbl` (25 micro-ops), 10 for the fields, interleave folded into 2 `st2` |
| Reshuffle, 32-bit shifts and masks | 75 | 8 `tbl` (20 micro-ops), 44 for the fields (16 `and`, 12 `orr`, 16 shifts) |
| Reshuffle, per-lane shifts on 16-bit lanes | 143 | split into 64-bit halves with `rev32`/`trn2` |
| Reshuffle by lane picks (`SIMD16(a[1], a[0], …)`) | 243 | byte loads and lane inserts |

On deinterleaved bytes each 6-bit value is one or two shifts and an `or`, shared by 16 groups; on reshuffled lanes
it's a shift and a mask per value per lane. Not benchmarked: double the vector operations of a loop that is
already vector-bound. (Lane picks across two vectors compile to `ext` when they're a contiguous run.)

## 2026-11-16: byte-aligned cursors (baselines `p4-generic` → `p4-aligned`)

The API now takes `AlignedBytesReader` and `AlignedBytesWriter` (Base64 is whole bytes), and
`String(utf8Capacity:)` gives an aligned writer.
- **Encode** through the cursors: −6.5% at 40 B, −7.7% at 47 B, −4.5% at 64 B, −6.7% at 95 B, −1.5% at 1 KB.
- **`encodedString`:** −0.9% to −1.4%.
- **Decode:** −3.7% at 47 B; `decodedBytes` −0.6% to −1.5%.
- **"Portable groups" decode**, which doesn't use the cursors in its loop: +1.6% and +2.2% at 95 and 64 B.

The benchmark names still say `BytesReader → BytesWriter`, to keep comparisons with earlier baselines. Details:
[RESULTS.md](RESULTS.md), 2026-11-16.

## Current (baseline `final`)

| Input | Bytes encoder | Allocations | `encodedString` | Foundation `base64EncodedData()` | Scalar table |
|---|---|---|---|---|---|
| 64 B | 4.4 GB/s | 0 | 0.97 GB/s | 0.66 GB/s | 0.86 GB/s |
| 1 KB | 18.1 GB/s | 0 | 8.3 GB/s | 2.6 GB/s | 0.86 GB/s |
| 16 KB | **21.4 GB/s** | 0 | 14.7 GB/s | 3.1 GB/s | 0.88 GB/s |
| 1 MB | **21.4 GB/s** | 0 | 17.0 GB/s | 3.3 GB/s | 0.86 GB/s |
| 64 MB | 20.5 GB/s | 0 | 15.2 GB/s | 3.3 GB/s | 0.87 GB/s |

- **Allocations:**
  - The encoder allocates nothing at any size: `Allocations:Encode_*` count over 10 iterations against
    static thresholds of zero (`Thresholds/`).
  - `encodedString` allocates once, the `String`.
  - Foundation allocates twice per call.
- **Against Foundation:** 6.2–6.9x from 16 KB up, 7x at 1 KB, and 6.6x at 64 B, where Foundation's allocations
  dominate.
- **Against a scalar table encoder:** 25x. That's the usual loop: one table load per character, a gather,
  so it doesn't vectorize; 0.86 GB/s, 16 instructions per input byte.
- **Per block:** 0.67 instructions per input byte, 32 per 48-byte block, at about 9 cycles per block (3.5
  instructions per cycle).
- **Memory:** at 64 MB, input and output together move 47 GB/s, well below the core's memory bandwidth, so
  it's still compute-bound.
- **Short inputs** pay per call: reading and writing the remainder block, and building the alphabet's
  table. That's about 410 instructions at 64 B (15 ns).

### The ceiling: a C kernel with `ld3` and `st4`

C with NEON intrinsics, same input, `clang -O3`:

| Kernel | Lookups per 48 bytes | Throughput |
|---|---|---|
| `vld3q`, 4 × `vqtbl4q`, `vst4q` | 4 | **23.1 GB/s** |
| 3 × `vqtbl3q`, 4 × `vqtbl4q`, 8 `zip`s (this package's design) | 7 | 21.8 GB/s |
| 3 × `vqtbl3q`, 4 × `vqtbl4q`, 4 × `vqtbl4q` to interleave | 11 | 19.5 GB/s |

- **This package is at 93% of the best C kernel**, and level with C of the same design: Swift's code for
  it is as good as C's.
- The rest is `ld3` and `st4`. They deinterleave and interleave inside the load and store units, and Swift
  has no way to emit them for explicit vectors: Swift has no intrinsics, and a C wrapper would need
  pointers.
- **The bottleneck is table lookups, not instructions.** Folding the bounds checks cut instructions 2.3x
  with no change in throughput. Then replacing 4 lookups with 8 `zip`s gained 12%.

## Decoding (2026-11-10, baseline `final2`)

`Base64.decode` (`Sources/BytesBase64/Decoding.swift`): strict RFC 4648 (only the alphabet's characters, `=`
only as padding, zero unused bits), all or nothing (errors are `LocatedBytesError`, with the offset of
the bad character; the reader doesn't move and the writer is rewound), padded or not, any alphabet.
Throughput counts decoded bytes (the text is 4/3 as long); medians, one core.

| Input | Bytes decoder | Instructions per call | `decodedBytes` | Foundation `Data(base64Encoded:)` | Portable kernel | Scalar table |
|---|---|---|---|---|---|---|
| 40 B | 3.2 GB/s | 348 | 0.70 GB/s | 0.47 GB/s | 0.83 GB/s | 0.25 GB/s |
| 64 B | 4.4 GB/s | 359 | 1.0 GB/s | 0.70 GB/s | 1.9 GB/s | 0.25 GB/s |
| 95 B | 6.6 GB/s | 363 | 1.6 GB/s | 0.94 GB/s | 1.4 GB/s | 0.25 GB/s |
| 1 KB | 11.6 GB/s | 1,339 | 7.2 GB/s | 2.4 GB/s | 3.9 GB/s | 0.24 GB/s |
| 16 KB | **13.0 GB/s** | 17,021 | 12.1 GB/s | 3.0 GB/s | 4.2 GB/s | 0.25 GB/s |
| 1 MB | **12.5 GB/s** | 1.07 M | 12.6 GB/s | 3.1 GB/s | 4.2 GB/s | 0.25 GB/s |
| 64 MB | 12.8 GB/s | 68.5 M | 12.8 GB/s | 3.1 GB/s | 4.2 GB/s | 0.27 GB/s |

- **4.2x Foundation** from 16 KB, 4.9x at 1 KB, 6.7x at 40 B (where Foundation's two allocations cost the
  most); 3x the portable kernel; 50x a scalar table (a gather per character, so it doesn't vectorize).
- **Allocations:** none into a buffer, at any size (`Allocations:Decode_*`, thresholds of 0, pass);
  `decodedBytes` one, the array.
- **17 GB/s of text** at 1 MB. Encoding runs 21.5 GB/s of input there.

### The kernel

64 characters to 48 bytes, 49 instructions, no lane moves (`Tools/loops --target Bytes BytesBase64
'^static Base64.decodeBlocks\(' --require tbx.16b,uzp1.16b,tbl.16b --forbid mov.b,ins,ld1.b` passes):

1. 4 loads, then `ByteLanes.deinterleave` (8 `uzp`s, as `ld4` would).
2. Per 16 characters: subtract the window's first character, a 64-byte `tbx` with 0xFF as fallback, a
   16-byte `tbx` for the window's last 16 characters. Characters outside the alphabet, below the window
   (they wrap), or 0x80 and up all come out 0xFF.
3. Shifts and ORs make 3 vectors of bytes; `ByteLanes.interleave` puts them in order (3 `tbl`s, as `st3`).
4. The values ORed into an accumulator, tested once after the loop: no branches in it.

It's bound by vector-pipe micro-ops (`Tools/counters`: 50% useful cycles, 43% back-end, all executing,
no memory misses). Counting a `tbl`/`tbx` as one micro-op per table register, the loop is 61, about 15.25
cycles on 4 pipes; measured, 15.2 (3.75 ns per block). So fewer table registers, not fewer instructions,
was the lever:

| Step | Kernel loop | 1 MB |
|---|---|---|
| Prototype (`Proposals/prototypes/Base64/DecodeBlocks.swift`): lookups for `ld4` and `st3`, 128-byte table with `tbl`s, `matching(0)` | 52 instructions, 15 `tbl` | 12.2 GB/s of text |
| `uzp`s instead of 4 lookups; the table `tbl` + `tbx` on 64 bytes each | 131 instructions, 3 calls | — |
| The interleave's indices as `Byte16` literals (`SIMD16` array literals compiled to `SIMD.init` calls) | 91, lane loads | — |
| An empty `asm` before the `uzp`s (LLVM had narrowed the loads to the lanes the first round uses) | 45 (69 micro-ops) | 11.5 GB/s of bytes |
| An 80-character window (`+` to `z`): 64 + 16 table bytes instead of 128 (61 micro-ops) | 49 | **12.8 GB/s** |

**The ceiling** (C with NEON intrinsics, `clang -O3`, same window, 1 MB of text):

| Kernel | Throughput (bytes) |
|---|---|
| `vld4q`, `tbx` window, `vst3q` | 12.9 GB/s |
| 8 `uzp`s, `tbx` window, 3 `tbl` (this package's design) | 12.5 GB/s |
| **This package (Swift)** | **12.8 GB/s** |

At the ceiling: unlike the encoder's `ld3`/`st4`, `ld4` and `st3` don't help here, since the loop is
bound by the vector pipes they use too. Also costed, not built: a nibble-based classification (Muła's)
is about 9 micro-ops per 16 characters with 1-register `tbl`s, the same as the window's; decoding the
characters in place and combining with shifts avoids the shuffles (17 micro-ops) but costs about 30 to
combine and compact.

### Short inputs

Per call, the tail block is most of it (`Tools/profile` at 64 B: the last block's decode 13%, the code
around it 10%, building the table 6%). What brought 64 B from 1,570 instructions per call to 359:

- The table and the shift indices as `Byte16` constants (they were `SIMD16` array literals: `SIMD.init`
  calls, about 1,000 instructions).
- A reader created at the overlap's offset instead of `seek`: `seek` wasn't inlined, and `load` kept its
  unaligned slow path, which a known bit offset of 0 folds away. (The encoder had the same pattern: fixed
  there too, below.)
- The last group, padding or not, goes through the tail block (padding lanes replaced with `A`, the value
  0; the unused bits are then the byte after the last written, checked for zero) instead of a scalar
  decode: `_decodeLastGroup` was 459 instructions of code.
- Whole-group text (all padded text) decodes its last 64 characters as they are, overlapping the last
  block, with no shift (four 64-byte `tbx`s saved).
- The standard and URL-safe windows as constants; other alphabets build theirs out of line (60
  instructions); alphabets whose two characters don't fit the window use the portable kernel.

`decodedBytes` adds the array: 1,521 instructions per call at 40 B, after Bytes' array builder stopped
going through `[UInt8](capacity:)` (2,080 before; see [RESULTS.md](RESULTS.md)).

**Tests** (`Tests/BytesBase64Tests/DecodingTests.swift`): round trips of every length to 200 and four larger
ones, both alphabets, padded and not, against Foundation; every byte value in every position of a group,
through the block kernel and the tail, for four alphabets (two built at run time, one too wide for the
window); every invalid character at every position, with its offset; padding, unused bits, capacity,
and failures leaving the reader and writer where they were; the portable path alone.

## 2026-11-10: encoder (baselines `conv-old-*` → `conv-new-*`, then `final2`)

- **The last block after a full block** reads its overlapping 48 bytes with a reader created at that
  offset instead of `seek` then `load` (as the decoder does): `seek` was an out-of-line call, and `load`
  carried its unaligned path. 64 B and 95 B −9.1% instructions, −9 to −16% time; 40 and 47 B −4.9%; 1
  KB −3.4%; 16 KB and up unchanged.
- **The alphabet's last vector** with `Byte16.vector` (the same bit cast).
- **`encodedString`** with Bytes' `String(utf8Capacity:writing:)` (the non-throwing form): level with the
  hand-written version at 64 B and 1 KB, +16 instructions per call at 40 B (968 → 984, in a driver), the
  same time. The throwing form with `try!` was 10 more.

| Input | Instructions per call (`final2`) | Throughput |
|---|---|---|
| 40 B | 294 | 4.1 GB/s |
| 64 B | 332 | 5.5 GB/s |
| 95 B | 331 | 8.3 GB/s |
| 1 KB | 972 | 18.6 GB/s |
| 16 KB, 1 MB | 11,214, 699 K | 21.6, 21.5 GB/s |

**Harness:** nothing but the work runs inside `scaledIterations` now (fixtures, including raw output
buffers, are made before the benchmarks are registered; no clock or custom metric in the loop).
Throughput is the framework's, iterations per second, times the bytes per iteration (`count ×
repetitions`, about 4 MB).

## How it got here

| Step | Baseline | 64 B | 1 KB | 1 MB | Instructions, 1 MB |
|---|---|---|---|---|---|
| Arithmetic mapping, auto-vectorized (`ld3`, compares, `st4`) | `v1` | 3.1 GB/s | 7.4 GB/s | 9.0 GB/s | 6.9 M per 4 MB |
| 48-byte blocks with `tbl` (11 per block), raw-span offsets | `tbl` | 3.0 | 14.5 | 19.1 | 5.0 M |
| Blocks as typed-span elements: bounds checks fold | `tbl-spans` | 3.1 | 14.9 | 18.9 | 2.2 M |
| Interleave with `zip`s instead of 4 lookups | `zip` | 3.2 | 16.3 | 21.7 | 2.8 M |
| The remainder as one more block; the table built with one initializer | `remainder` | 4.4 | 17.9 | 21.0 | 2.8 M |

What made the difference, and what didn't work:

- **Vectorization without a table.** The obvious loop maps each 6-bit value through a 64-byte table. Each
  lookup is a gather, and the vectorizer gives up. Computing the character instead, as the value plus an
  offset chosen by range, lets LLVM vectorize the whole loop: `ld3`, then shifts, compares and selects,
  then `st4`. Written over typed spans of 3-byte and 4-byte groups, it vectorizes with checked subscripts.
  - **The offset must not branch.** Written with `if`s or ternaries, the range tests are correlated (a
    value of at least 62 is at least 52). LLVM threaded them into branches in the package build, though not
    in a one-file test, and the loop stayed scalar. Arithmetic masks, `(v + 128 - k) >> 7`, can't become
    branches. That costs `add` + `cmlt` per test where a single `cmhi` would do: 77 instructions per 48
    bytes with Swift 6.4, 62 with 6.5, which does use `cmhi`.
- **`tbl` from Swift.** `SIMD16`'s dynamic subscript compiles a lane at a time (6.4 and 6.5).
  - Bytes' CBytesNEON C module already had a 64-byte lookup that inlines into Swift as one `tbl`. It's now
    public as `ByteLanes.lookup(in:)`, with a 48-byte one, and `isLookupVectorized` to choose a kernel.
  - With 11 lookups per block, the encoder doubled to 19 GB/s.
- **Bounds checks fold over typed spans.** Loading three `SIMD16`s at byte offsets from a `RawSpan`, and
  storing four, checked each access: 14 of 45 instructions. Reading blocks as `Span<InlineArray<48, UInt8>>`
  elements and writing `MutableSpan<InlineArray<64, UInt8>>` elements, bit-cast to and from vectors,
  leaves one check per span, before the loop. Instructions fell 2.3x and throughput didn't move: the loop
  was bound by its lookups.
- **`zip` instead of lookups to interleave.** Swift's lane initializers for zip patterns compile to single
  `zip1`/`zip2`. But two rounds of them get merged by LLVM's instruction combiner into four-vector
  shuffles, which ARM64 builds a lane at a time (1 `zip` and 14 inserts per vector).
  - `ByteLanes.interleave`, in the C module, keeps the rounds apart with an empty `asm`.
  - LLVM then turns the second round into `st2` stores.
  - +12%, to 21.7 GB/s.
- **Short inputs:** the last 0 to 47 bytes as one zero-padded block, instead of up to 15 groups through
  the portable kernel's scalar remainder. Plus the alphabet table from one initializer per vector, not an
  array literal changed lane by lane (16 inserts). 64 B went from 3.2 to 4.4 GB/s.

## Toolchains

The kernels' loops (measured with the since-removed `Scripts/check-vectorized.sh`; now `Tools/loops`) with
Swift 6.4.2 and with 6.5-dev (swiftlang/swift#91981 build 2511):

| Kernel | Swift 6.4.2 | Swift 6.5-dev |
|---|---|---|
| ARM64 blocks (`tbl`, `zip`) | 32 instructions per 48 bytes | 29 |
| Portable groups (`ld3`, `st4`) | 77 | 62 |

## 2026-11-09: `write(_: RawSpan)` inlined (baselines `bcd-old-*` → `bcd-new-*`)

Bytes now inlines `write(_: RawSpan)` (copies up to 64 bytes in line, `memmove` out of line). `encode`
called it twice per input, for the last block's bytes in and characters out. No Base64 source changed.

| Input | Instructions per call | Time (rounds 1 / 2) |
|---|---|---|
| 40 B | 356 → 309 (−13%) | −15% / −18% |
| 47 B | 351 → 305 (−13%) | −14% / −17% |
| 64 B | 376 → 365 (−3%) | −7% / −5% |
| 95 B | 377 → 364 (−3%) | −3% / −4% |
| 1000 B, 1 KB | −1% | −1 to −2% |
| 16 KB and up | unchanged | within noise |

## 2026-11-09: Bytes copies 33–64 bytes inline; `writeShort` removed (baselines `ab-old-*` → `ab-new-*`)

Bytes' `write(_: RawSpan)` now copies up to 64 bytes inline (it called `memmove` above 32), so the
`writeShort` workaround (two writes of at most 32) is gone: the last block's copy in (1–47 bytes, inputs
under 48) and its characters out (2–64) are each one `write`. The benchmarks gained 40, 47, 95, and
1000-byte inputs, whose remainders (40 or 47 bytes, 54–64 characters) take those copies; the power-of-two
sizes leave 16 bytes or none and never did. Interleaved runs of the previous commit and this one (two
rounds; round 2 below, where unchanged sizes moved under 5%):

| Input | Instructions per call | ns per call |
|---|---|---|
| 40 B | 433 → 356 (−18%) | 16.0 → 13.1 (−18%) |
| 47 B | 428 → 351 (−18%) | 15.5 → 12.7 (−18%) |
| 95 B | 415 → 377 (−9%) | 15.7 → 14.1 (−10%) |
| 1000 B | 1,029 → 991 (−4%) | 55.1 → 53.6 (−3%) |
| 64 B, 1 KB, 16 KB, 1 MB, 64 MB | unchanged (±0.8%) | within ±5% |

`encodedString` gains the same 77 instructions per call at 40–47 B (−5% of its total, which is mostly
creating the `String`). Kernel checks pass; `encode` has two out-of-line `write(_: RawSpan)` calls, where
`writeShort` made up to four. Allocation thresholds for the new sizes: 0.

## 2026-11-09: current Bytes APIs, the last block (baseline `modern`)

Swift 6.4.2, same machine, but shared with other agents' builds and benchmarks (load average 10–14).
Code that didn't change ran 5–12% below `final` with identical instruction counts (scalar table 0.86 →
0.78 GB/s, Foundation 3.30 → 3.14 at 1 MB), so compare instructions against `final`, and throughput
against `pre-modern` (this package before these changes, measured the same day).

**Re-verified by interleaving** (the old code, commit `eec4a92`, and the new, run alternately twice, no
other benchmarks running; Foundation and the scalar table unchanged within 2%, as a control):

| Input | Old (GB/s, two rounds) | New | |
|---|---|---|---|
| 64 B | 4.10, 4.09 | 4.48, 4.73 | **+9–16%** (25 M against 27 M instructions per 4 MB) |
| 1 KB | 18.1, 18.0 | 18.5, 18.5 | +2–3% |
| 1 MB | 21.0, 21.4 | 21.3, 21.6 | +1% (same instructions) |

Single runs on this machine vary by up to 10% from minute to minute (a lone `modern` re-run read 19.8 GB/s
at 1 MB), so throughput comparisons need old and new interleaved.

| Input | `final` | `pre-modern` | `modern` | Instructions per 4 MB, `final` → `modern` |
|---|---|---|---|---|
| 64 B | 4.36 GB/s | 3.88 | **4.30** (+11%) | 27 M → 25 M |
| 1 KB | 18.1 | 16.7 | 16.5 | 4.33 M → 4.18 M |
| 16 KB | 21.4 | 19.2 | 19.2 | 2.90 M → 2.89 M |
| 1 MB | 21.4 | 19.3 | 19.1 | 2.80 M (same) |
| 64 MB | 20.5 | 18.8 | 18.4 | 45 M (same) |

Zero allocations at every size (`thresholds check --filter 'Allocations:.*'` passes); the kernel checks pass
(`encodeBlocks` 32 instructions per block, the portable loop 79).

Every benchmark size leaves 16 bytes after its last 48-byte block, so the benchmarks miss the remainder
lengths these changes are about. A driver (`encode` in a loop, retired instructions from `proc_pid_rusage`,
median of 3, run back to back under the lock) covers them:

| Input (remainder) | Before: instructions, ns per call | After | Time |
|---|---|---|---|
| 16 B (16) | 349, 12.97 ns | 332, 12.33 ns | −5% |
| 47 B (47) | 480, 23.6 | 410, 15.5 | −34% |
| 64 B (16) | 397, 15.5 | 361, 13.8 | −11% |
| 95 B (47) | 528, 26.1 | 397, 15.2 | −42% |
| 1,000 B (40) | 1,110, 68.0 | 1,010, 60.4 | −11% |
| 1 KB (16) | 1,037, 62.5 | 1,001, 60.2 | −4% |
| 16 KB, 1 MB | | | within noise |

What changed (each measured alone with the driver):

- **The alphabet table's last vector** is a `Byte16` constant with bytes 14 and 15 set, then bit-cast. As
  `SIMD16(119, …, character62, character63)` it compiled to 16 lane inserts (`mov.b`) with 6.4.2, not the
  "constant plus two inserts" its comment claimed: −17 instructions per call. A `SIMD8<UInt16>` with one
  lane set was 1 instruction and a little time worse.
- **Padding** as one `Byte2` ("==") or `Byte` ("=") write instead of a loop of byte writes: −7.
- **The last block after a full block** is the last 48 bytes of input, which overlap the previous block:
  `seek` back, `load(InlineArray<3, SIMD16<UInt8>>.self)`, and three 48-byte `ByteLanes.lookup`s with
  indices `iota + (48 − rest)` move the remainder down with zeros after (`shiftedDown`). No zeroed block,
  no `BytesWriter` over it, no copy. 95 B 24.4 → 18.9 ns, 1,000 B 66 → 62 ns. Inputs under 48 bytes still
  copy into zeros.
- **Writes of 33–64 bytes as two writes** (`writeShort`): `BytesWriter.write(_: RawSpan)` copies up to 32
  bytes inline and calls `memmove` above that, which the last block's 44–64 characters (and a 33–47-byte
  input copy) hit. 47 B 22.2 → 15.5 ns, 95 B 18.9 → 15.3 ns. (Since replaced: Bytes copies up to 64
  bytes inline, and the helper is gone; see the section above.)
- Not kept: computing the remainder's character count directly instead of `encodedByteCount` (+3
  instructions: LLVM had already shared the division).
- **Release test builds** failed: the tests' `@testable import` needs `-enable-testing`, which `-c release`
  doesn't pass. The group kernel the tests call is now `package`, and the tests import normally.

Where the time goes (`Tools/counters`, `Tools/profile`, driver):

- **Vectorized at run time**: at 1 MB, 23.7 SIMD arithmetic instructions per 48-byte block (`simd_fp_unit_
  instructions`), as in the loop; at 64 B, 58 per call. 1 MB is 57% useful cycles and 36% back-end bound
  (the `tbl`s, as before); 64 B is 89% useful: short inputs are bound by instruction count, so fewer
  instructions is the lever there.
- **64 B** (361 instructions, about 50 cycles): `encode`'s own code 21% of samples, `encodeBlocks` 19%,
  `encodedByteCount` 10% (its range check and division, three times), the typed-span read and write 15%,
  `write(_: RawSpan)` 6%. A 48-byte input with no remainder is 210 instructions, each further block 32.
- **`encodedString`** at 1 KB: 2,500 instructions against 1,001 for `encode`. The `String` initializer
  validates the UTF-8 it's given (`_allASCII`, 14% of samples), plus malloc and free (about 10%). No
  public initializer skips validation without an extra copy, so it stays.

### A decoder (since built: see "Decoding" above)

The package encoded only. A decoder is straightforward with Bytes' current APIs; two prototype kernels
(outside the package, decoding a 1 MB input's text, checked against the
input and for rejecting `*`, 0x80, 0xFF, and `=` mid-text):

| Kernel | Loop | GB/s of text |
|---|---|---|
| 4-character groups to 3 bytes, arithmetic, validity ORed (no early exit): `Span<InlineArray<4, UInt8>>` → `MutableSpan<InlineArray<3, UInt8>>` | `ld4`/`st3`, 176 instructions per 64 characters | 5.0 |
| The same with `c &- low < count ? 0xFF : 0` range tests | scalar, branches | 0.2 |
| 64-character blocks with `ByteLanes.lookup(in:)`: every 4th character (4 lookups, as `ld4`), characters to values (2 lookups per 16, 0 for invalid, tested with `matching(0)`), bytes interleaved (3 lookups, as `st3`) | 52 instructions, 15 `tbl`, no lane moves | 12.2 |

Proposed, not implemented: the public API (errors for invalid characters and padding, unpadded and
URL-safe input, a tail of 1–63 characters) and its tests are more than a small addition. Bytes could make
the block kernel shorter and likely faster with a 4-way deinterleave from `uzp`s (fewer `tbl`s, which bound
the encoder) and a 3-way interleave; see the Bytes API proposals.
