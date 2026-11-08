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
