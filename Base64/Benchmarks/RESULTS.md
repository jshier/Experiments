# Base64 performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M3 Ultra, macOS 27.2, Swift 6.4.2 (Xcode 27.3),
one core. Random input; each measured iteration encodes at least 4 MB, repeating short inputs. Throughput
counts input bytes; output is 4/3 as many.

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

`Base64.decode` (`Sources/Base64/Decoding.swift`): strict RFC 4648 (only the alphabet's characters, `=`
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

64 characters to 48 bytes, 49 instructions, no lane moves (`Tools/loops --target . Base64
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
going through `[UInt8](capacity:)` (2,080 before; see Bytes' RESULTS.md).

**Tests** (`Tests/Base64Tests/DecodingTests.swift`): round trips of every length to 200 and four larger
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
