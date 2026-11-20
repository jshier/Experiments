# LZ4, LZFSE, and LZVN decoders (2026-11-18)

New in `BytesCompression`: `LZ4Decoder` (raw blocks, `COMPRESSION_LZ4_RAW`; Compression's framed `bv4*` stream,
`COMPRESSION_LZ4`), `LZFSEDecoder` (`COMPRESSION_LZFSE`: `bvx2`, `bvx1`, `bvxn`, `bvx-`, `bvx$`), and
`LZVNDecoder` (raw LZVN, and LZFSE's `bvxn` blocks). All Swift; the C reference (`Sources/CLZFSE`, the lzfse
project's sources) was for tests and benchmarks only, and was removed on 2026-11-19 (the last section). Written for Apple Encrypted Archive segments and Apple
Archive `pbz4`/`pbze` blocks: whole streams of up to 16 MiB decoded into a caller's exactly sized buffer.

## API

```swift
let lz4 = LZ4Decoder()                                                  // no state, no allocation
try lz4.decompressRaw(block, decodedSize: size, into: &output)        // one raw block, exactly `size` bytes
let used = try lz4.decompressFramed(stream, into: &output)            // bv41 / bv4- … bv4$; input consumed

var lzfse = LZFSEDecoder()                                              // ~Copyable; 48 KB workspace, allocated once
let used = try lzfse.decompressAll(stream, into: &output)             // … bvx$; input consumed

let used = try LZVNDecoder().decompressAll(stream, into: &output)     // through the end-of-stream opcode
```

Typed throws, `BytesError`: `insufficientData` (input ends early: truncation at any byte), `insufficientCapacity`
(output doesn't fit; for a raw LZ4 block, also a block decoding to more than `decodedSize`), `invalidValue` (corrupt:
unknown magic, undefined LZVN opcode, distance 0 or before the output's start, a block whose data disagrees with its
header's sizes, FSE tables or bitstreams out of range). Output too short shows as `insufficientData` for raw LZ4
(it has no end marker of its own), and as fewer bytes appended for the self-delimiting formats (the caller compares
with the size it expects; an `.aea` or `pbz*` reader knows it). Matches may reach back into earlier blocks of the
same call, never before the output span's free capacity. Bytes of the free capacity past the decoded ones may be
overwritten (as `ZstdDecoder.decompressAll`); with no room past them, the decoders copy exactly near the end.

## Formats, as Compression writes them (checked on macOS 27.2)

- **`COMPRESSION_LZ4_RAW`**: one LZ4 block for the whole input, whatever its size (2.4 MB of random bytes were one
  literal run with a 9,411-byte length). Ends with a literal run, as LZ4 requires. Empty input: no bytes.
- **`COMPRESSION_LZ4`**: blocks of 64 KiB of output: `bv41`, decoded size (u32 LE), encoded size (u32 LE), then a
  raw LZ4 block (byte for byte what `COMPRESSION_LZ4_RAW` writes for the same 64 KiB); `bv4-`, size, stored bytes
  (incompressible blocks, and inputs too small to compress); `bv4$`. Matches reach into earlier blocks.
- **`COMPRESSION_LZFSE`**: `bvx-` for tiny or incompressible inputs, `bvxn` (LZVN, 12-byte header: magic, decoded
  size, payload size) for small ones (940 bytes of text; 4,700 bytes gave `bvx2`), `bvx2` otherwise (up to 40,000
  literals and 10,000 matches per block). Compression never wrote `bvx1` in any test; it's decoded (772-byte plain
  header, as `sizeof` the reference's struct) and tested by rewriting Compression's `bvx2` headers.
- Compression has no raw LZVN API. Raw LZVN is tested with the reference encoder (`lzvn_encode_buffer`) and with
  the payloads of Compression's `bvxn` blocks.

## Design

- One loop per format over raw pointers (as the LZMA and Zstandard decoders): every bound an integer comparison,
  memory touched only after the check. Two limits per buffer: the block's exact end (semantics), and the buffer's
  end less the 16-byte copy overrun (where wild copies may run); `min` of the two is the fast-path bound, so one
  comparison picks the path. Near the ends, exact copies (`memmove`, a byte loop for overlapping matches).
- `LZCopy`: literals 16 bytes at a time; matches 16 at a time at offsets of 16 or more, else libzstd's short-offset
  copy (`ZstdCopy.overlapping`: spread to 8 apart, then 8-byte steps).
- LZ4: lz4's shortcut — a sequence of at most 14 literals and an 18-byte match, far enough from both ends, is a token,
  one 16-byte literal move, an offset check, and two 16-byte match moves (30-instruction loop, no calls). Everything
  else takes the general path (255-continued lengths, careful copies).
- LZVN: opcodes classified with a few bit tests (the undefined rows 0x70–0x7F and 0xD0–0xDF with one shift of the
  mask 0x2080); a literal of 0–3 bytes is one 4-byte move the match then overwrites. The previous distance starts at
  0, which no match may use (the reference copies a match at distance 0 onto itself: we reject it).
- LZFSE: the reference's structure. Header read and checked (counts, states, frequency sums ≤ state counts, payloads
  present); value tables (L, M, D: 8-byte entries, bits | extra bits | next state base | value base) and the literal
  table (4-byte entries) built in the workspace, states no symbol has zeroed (every state stays in range by
  construction, so lookups need no checks); four interleaved literal states decoded 4 literals per refill into a
  40,000-byte buffer; then each L/M/D triple decoded with one refill (14 + 17 + 23 bits ≤ 57) and executed. Backward
  bitstreams as the Zstandard decoder's (container, bits consumed from its top); reads below a stream's start are
  allowed into the 8 bytes before it (always the header or the literal stream, as the reference reads short literal
  streams) and reported at the end as an overrun; refills that would go further throw.

## Method

`Benchmarks/CompressionBenchmarks/LZ4LZFSEBenchmarks.swift`: Silesia files and the 1.6 KB JSON response, encoded by
Compression and by the reference's LZVN encoder (cached in the corpus as `NAME-SIZE.apple-lz4raw|apple-lz4|
apple-lzfse|lzvn-ref`), each decoded whole into an exactly sized array, after checking that every decoder produces
the original. Compression through `compression_decode_buffer` with a scratch buffer allocated once; the reference
through `lzfse_decode_buffer` with its scratch state allocated once, and `lzvn_decode` (`clzfse_lzvn_decode`).
The reference is built by SwiftPM's release configuration (`-Os`, as its own Makefile) with `NDEBUG` (as its
Makefile; without it, its asserts in the decode loops cost it 18% more instructions on dickens).

Timed runs under the shared benchmark lock, while other agents built Bytes in parallel worktrees: treat MB/s as ±10%;
instruction counts don't drift (the benchmark prints them to 2 significant digits; precise counts for Bytes from a
scratch harness and `/usr/bin/time -l`, the instructions retired by 11 decodes less 1, over 10). Baseline `lz-final`
(`.benchmarkBaselines/CompressionBenchmarks/lz-final`). Apple M3 Ultra, Xcode 27.3 (Swift 6.4).

## Results

MB/s is 10^6 decoded bytes per second (median wall clock); instructions per decoded byte. Compression has no raw LZVN.

LZ4 raw (`COMPRESSION_LZ4_RAW`)

| File | Bytes MB/s | Compression MB/s | Bytes instr/B | Compression instr/B |
|---|---:|---:|---:|---:|
| dickens | 3044 | 3110 | 4.81 | 5.40 |
| mozilla | 3940 | 4656 | 2.75 | 2.81 |
| xml | 4378 | 5235 | 2.43 | 2.24 |
| x-ray | 7157 | 9877 | 1.18 | 0.98 |
| samba | 4306 | 4739 | 2.68 | 2.64 |
| JSON 1.6 KB | 1229 | 1193 | 2.80 | 2.76 |

LZ4 framed (`COMPRESSION_LZ4`)

| File | Bytes MB/s | Compression MB/s | Bytes instr/B | Compression instr/B |
|---|---:|---:|---:|---:|
| dickens | 3059 | 3110 | 4.71 | 5.40 |
| mozilla | 3940 | 4656 | 2.75 | 2.81 |
| xml | 4332 | 5155 | 2.43 | 2.24 |
| x-ray | 7427 | 9565 | 1.18 | 0.98 |
| samba | 4389 | 4719 | 2.68 | 2.64 |
| JSON 1.6 KB | 1312 | 1458 | 2.81 | 2.78 |

LZFSE (`COMPRESSION_LZFSE`)

| File | Bytes MB/s | Compression MB/s | lzfse MB/s | Bytes instr/B | Compression instr/B | lzfse instr/B |
|---|---:|---:|---:|---:|---:|---:|
| dickens | 1385 | 1534 | 1083 | 12.46 | 13.05 | 14.52 |
| mozilla | 1652 | 1707 | 1191 | 8.79 | 9.27 | 10.68 |
| xml | 3300 | 3607 | 2421 | 4.12 | 4.12 | 4.86 |
| x-ray | 1064 | 1013 | 856 | 13.92 | 14.87 | 17.11 |
| samba | 2174 | 2338 | 1543 | 6.39 | 6.71 | 7.73 |
| JSON 1.6 KB (`bvxn`) | 1064 | 915 | 895 | 5.27 | 7.32 | 6.71 |

LZVN (raw, the reference's encoding)

| File | Bytes MB/s | lzfse MB/s | Bytes instr/B | lzfse instr/B |
|---|---:|---:|---:|---:|
| dickens | 1244 | 1111 | 8.93 | 8.73 |
| mozilla | 1652 | 1463 | 5.58 | 5.60 |
| xml | 3220 | 2388 | 3.37 | 3.55 |
| x-ray | 1088 | 946 | 9.68 | 9.32 |
| samba | 2278 | 1801 | 4.26 | 4.40 |
| JSON 1.6 KB | 1093 | 1157 | 5.17 | 5.03 |

Summary: LZFSE runs as many instructions as Compression or fewer (xml equal, others −4 to −28%), at 0.90–1.16x
its speed (3–10% slower on the larger text and binary files, faster on x-ray and the small input), and 1.2–1.4x the
reference's speed. LZVN matches the reference's instruction counts (±5%) at 1.1–1.35x its speed on Silesia (0.94x
on 1.6 KB). LZ4 runs −11 to +8% of Compression's instructions except on x-ray's long literal runs (+20%), at
0.72–1.03x its speed: Compression's LZ4 decoder is the one place it's still clearly ahead (x-ray 9.9 against
7.2 GB/s, xml 5.2 against 4.4).

Precise instruction counts for Bytes (scratch harness, per decode):

| File | LZ4 raw | LZ4 framed | LZFSE | LZVN |
|---|---:|---:|---:|---:|
| dickens | 48,410,537 | 48,390,365 | 127,195,579 | 90,682,749 |
| mozilla | 140,739,519 | 140,578,234 | 449,662,284 | 285,412,008 |
| xml | 13,209,961 | 13,186,718 | 21,557,072 | 17,965,476 |
| x-ray | 10,380,590 | 10,373,493 | 117,771,299 | 81,724,526 |
| samba | 58,006,354 | 57,942,972 | 138,360,138 | 92,384,461 |

## Allocations

Zero mallocs per decode after the decoder is made: `Thresholds/CompressionBenchmarks.Allocations:{LZ4_decode_raw,
LZ4_decode_framed,LZFSE_decode,LZFSE_decode_small,LZVN_decode}.p90.json` at 0 (120 KB JSON: several LZFSE and LZ4
blocks; the 1.6 KB one: a `bvxn` block), and `benchmark thresholds check --filter 'Allocations:(LZ4|LZFSE|LZVN).*'`
passes. `LZFSEDecoder` allocates its 48 KB workspace once, in `init`; the LZ4 and LZVN decoders own nothing.

## Code generation

- `Tools/loops`: the LZ4 shortcut is a 30-instruction innermost loop with no calls; literal and match copies are
  `ldr q`/`str q` loops (`vector128`). LZFSE's literal loop is 42 instructions per 4 literals, scalar, no calls.
- `Tools/calls --callee 'retain|release|metadata|outlined|allocObject|malloc|swift_alloc'` on the four hot functions:
  none. Their calls are `memmove` and `LZCopy.exactMatch` (the careful paths near buffer ends) and the throw sites.
- Error paths: `do { } catch` around a block's decode boxed the error (`swift_allocError`) until written
  `do throws(BytesError)`.

## What worked and what didn't

Instruction counts from the benchmark (2 significant digits) unless marked precise.

| Change | Effect |
|---|---|
| LZ4 length continuation `@inline(always)` (it stayed a call with `@inline(__always)`, keeping `ip` in memory) and lz4's shortcut for short sequences, together | LZ4 −29 to −39% instructions (dickens 79 → 48 M, mozilla 215 → 141 M), −31 to −45% time |
| 32-byte steps for long wild copies (precise counts) | LZ4 x-ray −0.8%, mozilla −0.4%; LZVN −0.2 to −0.6%; LZFSE samba +1.6%. Reverted: 16-byte steps, smaller overrun |
| Chaining LZ4 shortcut sequences without the end-of-input check at the loop's top (precise) | dickens +3.3%, mozilla +2.4%: LLVM laid the loop out worse. Reverted |
| `NDEBUG` for the reference (fairness, not ours) | lzfse's LZFSE decoding 174 → 148 M instructions on dickens |

Not tried, for later: an LZ4 path for literal runs of 15 or more followed by a short match (x-ray's shape, where
Compression runs 17% fewer instructions); per-entry `63 - k` shift amounts in the FSE tables (saves a `mvn` per
symbol at most); stitching LZFSE's literal decoding into its match loop.

## Tests

(As they were while the C reference was built. Since 2026-11-19 the reference's streams come from Bytes' encoders,
checked by digest, and its decoder's results are recorded digests: the last section.)

`Tests/BytesCompressionTests/LZ4DecoderTests.swift`, `LZFSEDecoderTests.swift` (LZFSE and LZVN suites),
`LZTestSupport.swift` (reference encoders, samples, and a driver decoding between exactly sized allocations): 29
tests, all passing, also under `--sanitize=address` (exact allocations, so any access past either buffer is a heap
overflow). Round trips of Compression's LZ4 raw, LZ4 framed, and LZFSE encodings and the reference's LZFSE and LZVN
encodings: sizes 0–262,147 (0, 1, odd sizes, around 16/32/64 bytes, 4 KiB, 40,000, 64 KiB), text, random, runs,
mixed, and periods 1–16; 1 MiB, 3 MiB, and 16 MiB inputs; hand-made LZ4 blocks at every offset 1–20 and match
lengths around the copy widths (exact buffer and with room); every LZVN opcode (including both no-ops, large
literals and matches, medium and large distances) against the reference decoder; `bvx1` headers; truncation at every
byte of small streams (all throw); random corruption (never crashes; LZVN results equal the reference's wherever both
succeed); output one byte short (throws) or long; undefined opcodes, distance 0, distances before the start.

## Lessons for AGENTS.md

- **SwiftPM release builds of C targets are `-Os` without `NDEBUG`**: a vendored C reference keeps its `assert`s
  (lzfse's are in its decode loops: 18% more instructions). Add `cSettings: [.define("NDEBUG")]` to match the
  project's own build before comparing against it.
- **Benchmark instruction counts are printed to 2 significant digits**, too coarse for changes under ~2%. For precise
  counts, a scratch package depending on the dev tree and `/usr/bin/time -l` ("instructions retired") over N and 1
  iterations.
- **`do { } catch` around a typed-throws call boxes the error** (`swift_allocError` on the error path) unless written
  `do throws(E)`. Check new error paths with `Tools/calls … --callee allocError`.
- **Compression's raw LZ4 is one block for any input size**, and its framed `bv41` blocks hold that same block
  format, 64 KiB each, with matches reaching into earlier blocks. Compression's LZFSE writes `bvxn` (LZVN) for small
  inputs and never `bvx1`.
- Vendored reference sources (`Sources/CLZFSE`, while it was there) can stand in for a missing Homebrew package or
  unexported functions (the lzfse dylib doesn't export the LZVN coder in a header): tests and benchmarks only, with
  its license.

# LZVN and LZFSE encoders, and the decoders' bounds fix (2026-11-18, second pass)

New in `BytesCompression`: `LZVNEncoder` (raw LZVN, ending with the end-of-stream opcode: Apple Encrypted Archive
segments) and `LZFSEEncoder` (`COMPRESSION_LZFSE` streams: `bvx2`, with `bvxn` and `bvx-` where Compression writes
them; APFS `decmpfs` types 11 and 12, Apple Archive `pbze`). All Swift; they replace Compression in NativeAEA's writer.
Also a fix to the three decoders' fast paths, which could write past the end of a small output.

## API

```swift
var lzfse = LZFSEEncoder()                                    // ~Copyable; 512 KB table + 290 KB block buffers, once
let written = try lzfse.compressAll(input, into: &output)    // RawSpan in, OutputRawSpan out; bytes appended
LZFSEEncoder.maximumCompressedSize(forByteCount: n)          // room that always suffices

var lzvn = LZVNEncoder()                                      // ~Copyable; 512 KB table, once
let written = try lzvn.compressAll(input, into: &output)     // opcodes, then the end-of-stream opcode
LZVNEncoder.maximumCompressedSize(forByteCount: n)
```

`throws(BytesError)`: only `insufficientCapacity`, when the stream doesn't fit (exactly: a stream of the output's
size fits); the output is then unchanged, though its free capacity may have been overwritten. `LZFSEEncoder` falls
back as `compression_encode_buffer` does: under 8 bytes, a stored block; under 4,096, an LZVN block, or stored if
that doesn't shrink the input; otherwise LZFSE blocks, or stored if they don't fit and a stored block does (so
`decmpfs`'s "compress into a buffer of the chunk's size, else store the chunk" works as with Compression). Both
`Sendable`; an encoder is reused for any number of inputs.

## Design

- **The reference's parse, byte for byte.** Both encoders reproduce `lzvn_encode_buffer` and `lzfse_encode_buffer`
  exactly: the hashes (3 bytes for LZVN, 4 for LZFSE), 16,384 lines of the 4 latest positions and values, the
  candidates in the same order with the same ties, forward extension stopping where the reference's 4- or 8-byte
  steps stop (computed as a limit, so the loops can take other steps), backward extension over pending literals, the
  pending-match heuristic, LZFSE's L/M/D splitting and block limits (pushes checked as the reference checks them),
  frequency normalization, FSE tables and bitstreams, header packing. Every test and corpus input compares equal to
  the reference's output, which makes the reference the oracle. Compression's streams equal the reference's on most
  inputs; where they differ (some 64 KiB chunks of samba and mozilla, and 16 MiB of each) it's a different block
  boundary, ±0.012% in size.
- **No table clearing per input.** The reference fills its 512 KB table for every call (8 bytes per input byte at
  64 KiB; for a 1.6 KB input, most of its 183,000 instructions). Here positions are stored as `Int32` plus a bias
  that each input starts at least 2 MiB above everything stored before, so old entries are too far back to match;
  LZVN's reads them as the reference's initial entries (position 0, the input's first 4 bytes), arithmetically.
  The table is cleared when the bias passes 1 GiB, and rebased (positions lowered, clamped at 0) within an input
  that runs past `Int32.max`. The next input's bias is reserved before encoding, so an encode that throws leaves
  nothing a later input could take for its own.
- **Lines as vectors.** A line is two `SIMD4` loads; the new line a rotation and one lane insert; candidates are
  one compare of 4 values and 4 distances, narrowed (`xtn`) to a bit per lane, so lines without candidates cost no
  branch per entry.
- **One call site for the back end**, `@inline(always)`: every decision (write the pending match, the new one, or
  literals) sets the triple to write, and one call writes it, so the block state (literal start, counts, output
  position) stays in registers through the search loop. Positions inside a written match only update the table, in
  a tight loop of their own.
- **Output exactly.** LZVN opcodes are written with 16-byte literal copies where there's slack (checked with a
  conservative bound), else after an exact size check with exact copies (`matchExactly`, out of line). LZFSE blocks
  are written straight into the output when their worst case fits, else into the encoder's block buffer and copied
  after a check.

## Decoders: writes past small outputs (fixed)

The decoders' fast-path limits were pointers clamped to the buffer's start: `outputFast = min(outputEnd,
outputLimit - min(16, outputLimit - output))`. With less than 16 bytes of room it equaled `output`, so a sequence of
length 0 at `output` passed `length <= outputFast - op` and took a 16-byte wild copy; LZ4's shortcut (`outputFast -
min(48, …)`) wrote up to 46 bytes past. A raw LZ4 block decoded into 20 bytes wrote 5 past them, into 8, 8 past
(before throwing). The limits are now signed offsets from the buffers' starts (`min(outputEnd - output, (outputLimit
- output) - 16)`, the shortcut's 48 less), negative when there's no room, compared with `op - output`: in
`LZ4Decoder.decodeBlock` (input, output, and both shortcut limits), `LZFSEDecoder.executeMatches` (output), and
`LZVNDecoder.decode` (input and output; LZVN has no empty operation, so it was safe, but now by construction).
Pointers below a buffer's start aren't formed (they'd be out-of-bounds `inbounds` GEPs in LLVM's terms, and an empty
buffer's placeholder is address 1). Instruction counts unchanged (LZVN 1.6 KB: 7,934 before and after; dickens
9.13 M against 9.11 M).

`Tests/BytesCompressionTests/LZOutputBoundsTests.swift` decodes real streams (LZ4 raw and framed, LZFSE from
Compression and Bytes, LZVN) of 0–80 bytes into exactly sized, one-short, and half-sized outputs between 64-byte
guards; raw LZ4 blocks of 1 literal and a 4-byte match (the shortcut's case) into outputs of every size below their
own; 64 KiB-and-a-bit LZ4 and LZFSE streams (a small last block); and a hand-made `bvx1` block with an empty triple
decoded with no room left. Against the old decoders, 17 guard violations (16 LZ4 sizes, the LZFSE triple); none now,
also under `--sanitize=address`. The encoders follow the same rule: every fast path compares remaining room as a
count (`need <= end - position`), never a clamped pointer.

## Method

`Benchmarks/CompressionBenchmarks/LZFSEEncoderBenchmarks.swift`: two shapes per Silesia file, from where the formats
are used: the first 16 MiB (or all of it) as one stream (an `.aea` segment), and the first 1 MiB as 16 independent
64 KiB streams (a `decmpfs` resource fork); and the 1.6 KB JSON response (an LZVN block in LZFSE). Encoders: Bytes,
Compression (`compression_encode_buffer`, scratch allocated once), and the lzfse reference (`lzfse_encode_buffer`,
`lzvn_encode_buffer`, scratch allocated once; built `-Os` with `NDEBUG` as its Makefile does). Registration checks
that Bytes' streams equal the reference's and decode back. Decoders: the existing `LZ4LZFSEBenchmarks.swift` (streams
from Compression for LZFSE, from the reference for LZVN). One timed run, baseline `lzenc-final`, under the shared
benchmark lock while another agent built in a parallel worktree: treat MB/s as ±10%. Instruction counts from a
scratch harness depending on the dev tree, and a C one for the references (`/usr/bin/time -l`, N + 1 runs less 1,
over N): exact, and immune to load; they include each harness's small per-call overhead. Apple M3 Ultra, Xcode 27.3
(Swift 6.4), macOS 27.2.

## Size

Bytes' streams are the reference's byte for byte (every test input, and the corpus whole and in 64 KiB chunks), so
its ratio is the reference's; Compression's differs only where it places a block boundary differently.

| File | Shape | Input | Compression | Bytes (= lzfse) | vs Compression | Bytes LZVN (= lzfse) |
|---|---|---:|---:|---:|---:|---:|
| dickens | 16 MB | 10,192,446 | 3,864,220 | 3,864,220 | 0 | 5,001,004 |
| dickens | 64 KB × 16 | 1,048,576 | 423,773 | 423,773 | 0 | 524,164 |
| mozilla | 16 MB | 16,777,216 | 7,331,132 | 7,330,765 | −0.005% | 7,997,955 |
| mozilla | 64 KB × 16 | 1,048,576 | 670,516 | 670,494 | −0.003% | 683,604 |
| xml | 16 MB | 5,345,280 | 683,327 | 683,327 | 0 | 957,521 |
| xml | 64 KB × 16 | 1,048,576 | 176,678 | 176,678 | 0 | 220,336 |
| x-ray | 16 MB | 8,474,240 | 5,988,093 | 5,988,093 | 0 | 7,083,178 |
| x-ray | 64 KB × 16 | 1,048,576 | 732,288 | 732,288 | 0 | 853,986 |
| samba | 16 MB | 16,777,216 | 4,327,426 | 4,327,949 | +0.012% | 5,182,732 |
| samba | 64 KB × 16 | 1,048,576 | 346,093 | 346,097 | +0.001% | 388,948 |

Like Compression (and the reference), an incompressible input is written as `bvx2` even when that's larger (64 KiB
of random bytes: 66,282), unless the output is too small for it and big enough for a stored block.

## Encoding: instructions per input byte

| File | Shape | LZFSE Bytes | Compression | lzfse | LZVN Bytes | lzfse LZVN |
|---|---|---:|---:|---:|---:|---:|
| dickens | 16 MB | 95.7 | 109.1 | 110.4 | 104.0 | 110.4 |
| dickens | 64 KB × 16 | 93.2 | 108.9 | 112.2 | 101.4 | 109.7 |
| mozilla | 16 MB | 65.0 | 74.1 | 84.6 | 71.1 | 88.6 |
| mozilla | 64 KB × 16 | 57.0 | 65.5 | 83.4 | 56.5 | 81.2 |
| xml | 16 MB | 42.6 | 50.7 | 57.7 | 48.2 | 62.1 |
| xml | 64 KB × 16 | 48.7 | 59.3 | 66.6 | 52.6 | 67.3 |
| x-ray | 16 MB | 83.1 | 96.4 | 109.9 | 90.8 | 111.7 |
| x-ray | 64 KB × 16 | 80.3 | 94.4 | 109.6 | 93.4 | 114.4 |
| samba | 16 MB | 56.7 | 65.6 | 72.9 | 61.2 | 76.2 |
| samba | 64 KB × 16 | 60.0 | 70.7 | 80.0 | 62.4 | 79.0 |
| JSON 1.6 KB | | 53.2 | 138.4 | 111.0 | 53.3 | 110.9 |

LZFSE: 12–18% fewer than Compression and 13–32% fewer than the reference (62% and 52% fewer on 1.6 KB, where they
clear their 512 KB table per call). LZVN: 6–30% fewer than the reference (52% on 1.6 KB). The time is mostly branch
mispredictions, not instructions (CPU Counters, dickens at 64 KiB: 40% of cycles discarded for LZFSE, 42% for LZVN,
which is also 33% front-end bound), and the parse makes the same data-dependent decisions as the reference's, so
the time gains are smaller than the instruction gains: see below.

## Encoding: MB/s

10^6 input bytes per second, from the median wall clock (baseline `lzenc-final`).

| File | Shape | LZFSE Bytes | Compression | lzfse | Bytes vs best | LZVN Bytes | lzfse LZVN | Bytes vs lzfse |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 16 MB | 123 | 95 | 89 | 1.29x | 77 | 73 | 1.05x |
| dickens | 64 KB × 16 | 130 | 105 | 95 | 1.24x | 81 | 75 | 1.08x |
| mozilla | 16 MB | 212 | 158 | 143 | 1.34x | 161 | 122 | 1.32x |
| mozilla | 64 KB × 16 | 317 | 241 | 186 | 1.32x | 329 | 174 | 1.89x |
| xml | 16 MB | 297 | 206 | 184 | 1.44x | 214 | 144 | 1.49x |
| xml | 64 KB × 16 | 267 | 190 | 171 | 1.41x | 189 | 132 | 1.43x |
| x-ray | 16 MB | 163 | 110 | 109 | 1.48x | 107 | 81 | 1.32x |
| x-ray | 64 KB × 16 | 179 | 117 | 118 | 1.52x | 112 | 95 | 1.18x |
| samba | 16 MB | 230 | 173 | 154 | 1.33x | 164 | 121 | 1.36x |
| samba | 64 KB × 16 | 233 | 171 | 153 | 1.36x | 169 | 126 | 1.34x |
| JSON 1.6 KB | | 257 | 96 | 117 | 2.20x | 328 | 117 | 2.80x |

LZFSE is 1.24–1.52x the faster of Compression and the reference on Silesia (2.2x on 1.6 KB); LZVN 1.05–1.89x the
reference (2.8x on 1.6 KB). Dickens' LZVN is the narrowest margin (5–8%: within this run's noise; the scratch
harness, interleaved, agreed: 71–73 against 68 MB/s at 64 KiB chunks): English text keeps both parsers' branches the
least predictable.

## Decoding: MB/s (final, against the reference)

10^6 decoded bytes per second, whole files and the JSON, decoded into exactly sized buffers (`LZ4LZFSEBenchmarks`:
LZFSE streams by Compression, LZVN by the reference), after the bounds fix.

| File | LZFSE Bytes | Compression | lzfse | Bytes vs lzfse | LZVN Bytes | lzfse LZVN | Bytes vs lzfse |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 1259 | 1505 | 1078 | 1.17x | 1246 | 1136 | 1.10x |
| mozilla | 1601 | 1652 | 1220 | 1.31x | 1707 | 1552 | 1.10x |
| xml | 3394 | 3512 | 2379 | 1.43x | 3054 | 2414 | 1.27x |
| x-ray | 1095 | 1012 | 847 | 1.29x | 1118 | 1036 | 1.08x |
| samba | 2173 | 2332 | 1543 | 1.41x | 2161 | 1964 | 1.10x |
| JSON 1.6 KB | 1157 | 1009 | 820 | 1.41x | 1193 | 679 | 1.76x |

Both decoders beat the reference on every input: LZFSE 1.17–1.43x, LZVN 1.08–1.76x. (The 1.6 KB LZVN figure for the
reference is low in this run against the first pass's 1,157 MB/s: its call goes through Swift array closures in the
benchmark; the scratch harness, calling both directly, measured Bytes 9–12% ahead.) Compression's LZFSE decoder is
still 3–16% faster on dickens, mozilla, samba, and xml, slower on x-ray and the JSON; LZ4's speed is unchanged by
the fix (dickens raw 2,985 MB/s against 3,044 in the first pass), but not its instructions: see the correction in
the last section. The zero-malloc thresholds for all the LZ4, LZFSE, and LZVN
decoders and encoders pass on the final code.

## Decoding: instructions per decoded byte (final)

Streams from the reference's encoders (= Bytes'), whole file up to 16 MiB, into an exactly sized output. From the
scratch harness, which calls each decoder directly (the package benchmark, `lzenc-final`, adds its closure's overhead:
5.26 instructions a byte for Bytes' LZFSE on the 1.6 KB JSON, against 4.87 here).

| File | LZFSE Bytes | Compression | lzfse | LZVN Bytes | lzfse LZVN |
|---|---:|---:|---:|---:|---:|
| dickens | 12.45 | 13.06 | 14.51 | 8.91 | 8.75 |
| mozilla | 8.75 | 9.30 | 10.81 | 4.64 | 4.74 |
| xml | 4.01 | 4.18 | 4.87 | 3.30 | 3.54 |
| x-ray | 13.90 | 14.89 | 17.04 | 9.66 | 9.28 |
| samba | 6.57 | 6.89 | 7.94 | 4.24 | 4.40 |
| JSON 1.6 KB (`bvxn`) | 4.87 | 7.16 | 6.69 | 4.89 | 4.74 |

LZVN decoding is at instruction parity with the reference (−7 to +4%); it's faster in time (fewer mispredictions:
branches on a few bits where the reference jumps through a 256-entry table). On the 1.6 KB JSON, timed in a scratch
harness against the reference's `lzvn_decode` (3 million decodes each, 3 interleaved rounds): 1.06–1.08 s against
1.16–1.21 s, 9–12% faster; whole dickens 0.39–0.40 s against 0.41–0.43 s, x-ray 0.32 against 0.34 (both with the same
setup included).

## Allocations

Zero mallocs per encode after the encoder is made: `Thresholds/CompressionBenchmarks.Allocations:{LZFSE_encode,
LZFSE_encode_64KB,LZFSE_encode_small,LZVN_encode}.p90.json` at 0 (310 KB of JSON and 100 KB of random bytes: several LZFSE
blocks, and literal-heavy ones; the same in 64 KiB streams; the 1.6 KB JSON, an LZVN block; raw LZVN), and `benchmark
thresholds check --filter 'Allocations:(LZFSE|LZVN)_encode.*'` passes. The table and block buffers are allocated in
`init`.

## Code generation

- `Tools/calls --callee 'retain|release|metadata|outlined|allocObject|malloc|swift_alloc|allocError|SIMD.init'` on
  `LZVNEncoder.encode`, `LZFSEFrontEnd.encode`, `LZFSEBlockWriter.write`, and the three decoders' loops: none. The
  search loops call only `memmove` (exact copies near the ends), the block writer (once per block), `matchExactly`
  (LZVN near the output's end), and the throw path.
- The table update is two `ldp`/`stp` of a line and a rotation plus a lane insert per vector; candidates one `cmeq`,
  one `cmhs`/`cmhi`, an `and`, and an `xtn` to a 64-bit mask. Positions inside a written match run a 17-instruction
  loop for LZFSE, 18 for LZVN (load, hash, update; `vector128` in `Tools/loops`).
- LZFSE's match extension is 8 bytes, then 16 at a time (`cmeq.16b`, `shrn` to a nibble mask): a 15-instruction
  `vector128` loop.

## What worked and what didn't

Instructions per MiB of dickens (or x-ray) in 64 KiB chunks, from the harness, unless stated.

| Change | Effect |
|---|---|
| First version, exact parse | LZFSE 510 M, LZVN 1,069 M: 4–9x the reference |
| Lane mask: `xtn` leaves 16 bits per lane, so `lanes &= lanes - 1` visited each candidate 16 times; masked to 1 bit a lane | LZFSE 557 → 104 M, LZVN → 142 M (the bug) |
| LZFSE: one call site for the back end, `@inline(always)` (it stayed a call with `@inline(__always)`, the block state in memory), an update-only loop inside matches, the line rotation as `ext` + `ins` | 104 → 98.8 M |
| LZVN: the same, with the exact-size path out of line (`matchExactly`) | 142 → 125 M (x-ray 146 → 133) |
| LZVN: stale entries replaced with arithmetic (sign shift and masks) instead of a mask-driven select | 125 → 106 M (x-ray 133 → 98): the select compiled lane by lane through the stack, generic or not |
| 16-byte match extension after the first 8 | LZFSE −1 to −3% (dickens 98.8 → 97.8, mozilla 61.6 → 59.8, samba 64.0 → 62.9): kept. LZVN +0.5 to +1.5%: not used there |
| LZVN: long literals out of line | +2 to +5%: reverted |
| LZVN decoder: lz4-style shortcut (7 input and 37 output bytes of room, then no per-field checks) | 7.9 K → 10.2 K instructions per 1.6 KB decode, `base` spilled: reverted |
| LZVN decoder: distance and opcode length by selects | +12–18% instructions; 10% faster on dickens, 5% slower on the 1.6 KB JSON: reverted (JSON is the case that lagged) |
| `LZCopy.exact` inline for up to 16 bytes | no change on the 1.6 KB LZVN stream: reverted |
| Decoders' bounds fix (offsets, not clamped pointers) | LZFSE and LZVN unchanged; LZ4 +10–17% instructions (not noticed then: corrected 2026-11-19, last section) |

Not tried: a different parse (the reference's is kept for identical output; a faster one, say without the pending
match, would trade ratio, which the task bounds at ~1% of Compression's); branch-free candidate evaluation (all four
lanes' first 8 bytes at once), which might cut the mispredictions that dominate.

## Tests

(As written with the C reference built; the last section has what replaced its checks.)

`Tests/BytesCompressionTests/LZFSEEncoderTests.swift` (LZVN and LZFSE suites, 9 tests) and `LZOutputBoundsTests.swift`
(8): every decoder sample plus periods 17–40, sizes around 4,096 and the block limits (39,999–40,001, 50,021,
131,071/2), runs of 300,000, random-then-run, 1–16 MiB inputs, and the corpus (6 files, whole up to 16 MiB and in
64 KiB chunks up to 4 MiB): each stream equal to the reference's, decoded back by Bytes' decoder, Compression, and the
reference; block kinds (`bvx-` under 8 bytes and for 1,000 random bytes, `bvxn` at 4,095, `bvx2` at 4,096) equal to
Compression's; outputs exactly sized succeed and one byte short (and smaller) throw `insufficientCapacity`, or for
LZFSE fall back to a stored block when that fits, as the reference; an encoder reused 600 times (past the table's
clearing at 1 GiB of bias) and after failures writes what the reference does; size within 0.1% of Compression's on
the corpus. All 147 BytesCompression tests pass; under `--sanitize=address` (debug), the bounds suite, the LZVN encoder suite,
and the LZFSE encoder's output-size, block-kind, and reuse tests pass too.
Not covered: the rebase within a single input past 2 GiB (`LZMatchTable.rebase`): too large for a test here.

## Lessons for AGENTS.md

- **A narrowed comparison mask has as many bits per lane as the narrow type**: `SIMD4<UInt16>(truncatingIfNeeded:)`
  of a 32-bit mask (`xtn`) leaves 16 set bits per matching lane, so `bits &= bits - 1` visits each lane 16 times. Mask
  to one bit per lane (`& 0x0001_0001_0001_0001`) before iterating: the encoders ran 5–9x the instructions until then.
- **`SIMDMask` selects compile lane by lane through the stack** (Swift 6.4), whether via `replacing(with:where:)`, a
  generic helper, or `unsafeBitCast` of the mask then `&`/`|`: write the select arithmetically from a sign shift
  (`(a &- b) &>> 31` as all-ones lanes) and masks. −15 to −26% for the LZVN encoder.
- **Fast-path limits are signed offsets, not pointers clamped to the buffer's start.** `min(end, limit - min(16,
  limit - start))` equals `start` when there's less room than the overrun, so an empty copy at the start passes
  `length <= fast - position` and moves 16 bytes past the end. Compare `length <= fastOffset - (position - start)`
  with a possibly negative offset. Test small outputs between guard bytes with streams that reach the fast path
  (LZ4's shortcut needs 32 bytes of input after the token; an LZFSE block needs an empty triple).
- **Reuse a big hash table across inputs by biasing positions** rather than clearing it: each input's stored
  positions start above the last input's by more than the longest distance, so old entries are out of reach. The
  references clear 512 KB per call: 8 instructions per input byte at 64 KiB, most of the work on a 1.6 KB input. Reserve
  the next bias before encoding, so a throw can't leave entries that look current.
- **Funnel a hot loop's back-end calls into one call site and force it inline** (`@inline(always)`; `@inline(__always)`
  left it a call): every branch sets what to emit, one call emits it, and the back end's state stays in registers.
- **Each benchmark runs in its own process, which runs every registration again**: expensive checks there (encoding
  16 MiB with five encoders) multiply by the number of benchmarks run. Check output identity in tests; keep
  registration cheap.
- **zsh doesn't word-split unquoted variables** (already noted): `set -- $shape` in a loop left `$1` the whole string,
  and the instruction counts came out negative. Write such scripts as `#!/bin/bash` files.
- **`Tools/loops --target` finds objects anywhere under `PACKAGE/.build`**: extra scratch builds there (`--scratch-path
  .build/asan`) make its `ld -r` fail on duplicate symbols. Put other scratch builds outside the package.

## 2026-11-19: the C reference removed (and how to build it again)

After the final comparison above (Bytes' encoders write the reference's streams byte for byte and run faster; its
decoders beat the reference's on every input), the reference left the package: `Sources/CLZFSE` and its target, and
the reference rows of `LZ4LZFSEBenchmarks.swift` and `LZFSEEncoderBenchmarks.swift`. The tests keep checking
identity: `LZFSEEncoderTests` compares SHA-256 digests of Bytes' streams with digests recorded from the reference
(every sample, and the corpus whole and in 64 KiB chunks), and the LZVN decoder tests compare with the reference
decoder's recorded results (a hand-built stream of every opcode; 853 corrupt streams). LZVN streams for the decoder
tests and benchmarks now come from `LZVNEncoder`.

To compare against it again:
1. `Tools/test-data fetch c-references`, then extract `lzfse-e634ca5.tar.gz`'s `src/*.c` and `src/*.h` (all but
   `lzfse_main.c`) into `Bytes/Sources/CLZFSE`, with `src/lzfse.h` in `Sources/CLZFSE/include`.
2. Add the two files below (not upstream: the LZVN entry points `lzfse.h` doesn't export, and a one-call LZVN
   decoder).
3. In `Package.swift`: `.target(name: "CLZFSE", cSettings: [.define("NDEBUG")])` (`NDEBUG` as its Makefile sets it:
   its asserts are in the decode loops), and `"CLZFSE"` in the dependencies of `BytesCompressionTests` and
   `CompressionBenchmarks`.
4. Call it again: nothing in the tests or benchmarks does now. The removed rows called `lzfse_encode_buffer`,
   `lzvn_encode_buffer` (with `lzvn_encode_scratch_size()` bytes of work), `lzfse_decode_buffer` (with
   `lzfse_decode_scratch_size()`), and `clzfse_lzvn_decode`, one call per stream into buffers of the stream's size.
   To regenerate or check the recorded digests, `goldenDigest` (`LZTestSupport.swift`) is SHA-256 over the streams in
   order, each preceded by its length as a little-endian UInt64: `LZEncoderSamples.all` then `LZSamples.large`; the
   corpus files' first 16 MiB whole; and their first 4 MiB in 64 KiB chunks. (The corpus checks run only where the
   corpus is: `Tools/corpus fetch`, or `EXPERIMENTS_CORPUS`.)

`Sources/CLZFSE/include/lzvn.h`:

```c
#ifndef CLZFSE_LZVN_H
#define CLZFSE_LZVN_H
#include <stddef.h>
size_t lzvn_encode_scratch_size(void);
size_t lzvn_encode_buffer(void *__restrict dst, size_t dst_size, const void *__restrict src, size_t src_size,
                          void *__restrict work);
/// Decodes a raw LZVN stream into at most `dst_size` bytes: the bytes written, or 0 unless the stream ends with its
/// end-of-stream opcode exactly at `src_size`.
size_t clzfse_lzvn_decode(void *__restrict dst, size_t dst_size, const void *__restrict src, size_t src_size);
#endif
```

`Sources/CLZFSE/clzfse_lzvn_decode.c`:

```c
#include "lzvn_decode_base.h"
#include "lzvn.h"

size_t clzfse_lzvn_decode(void *__restrict dst, size_t dst_size, const void *__restrict src, size_t src_size) {
  lzvn_decoder_state state;
  memset(&state, 0, sizeof(state));
  state.src = (const unsigned char *)src;
  state.src_end = state.src + src_size;
  state.dst_begin = (unsigned char *)dst;
  state.dst = state.dst_begin;
  state.dst_end = state.dst_begin + dst_size;
  lzvn_decode(&state);
  if (!state.end_of_stream || state.src != state.src_end)
    return 0;
  return (size_t)(state.dst - state.dst_begin);
}
```

## 2026-11-19: the LZ4 bounds fix cost 10–17% instructions; a cheaper fix (baseline `lz4-strict`)

A documentation review against the baselines found LZ4 decoding at 10–17% more instructions in `lzenc-final` than in
`lz-final` (dickens raw 49 → 57 M; time about the same), where the encoder work had reported "instruction counts
unchanged" for the bounds fix. Measured in a copy of the package with the decoder before and after: the fix itself
(offsets from the buffers' starts, recomputed per sequence in the fast-path tests). Replaced with pointer limits
clamped at the buffer's start, as before, and strict comparisons (`<`): with less room than the 16-byte overrun the
limits are the start, and `ip` is never before it, so no copy, not even an empty one, takes the fast path; otherwise
only exact fits move to the careful path. The guard-byte tests pass, also under `--sanitize=address`, and the counts
are back to `lz-final`'s (−1.7 to +0.2%: dickens 49 M, mozilla 140 M, JSON 1.6 KB 4,522).

# Compression's own LZVN and LZFSE streams, byte for byte (2026-11-19)

Why: `xip --expand` stores files over 16 KiB as APFS `decmpfs` type 8, LZVN resource forks of independently compressed
64 KiB chunks, and 1,493 of 1,501 sampled chunks of Apple's output equal `compression_encode_buffer(…, 0x900)` (the
rest are stored, `0x06` and the bytes). `LZVNEncoder` wrote the open lzfse reference's parse, which differed from
Compression's on most inputs over a few hundred bytes (Silesia xml chunks: identical for 39/40 at 1,000 bytes, 20/40 at
4,096, 1/40 at 64 KiB). Now `LZVNEncoder` and `LZFSEEncoder` write Compression's streams by default, and fail where it
fails; the reference's parse stays available.

## API

```swift
var lzvn = LZVNEncoder()                       // Compression's raw LZVN (algorithm 0x900)
var lzvn = LZVNEncoder(parse: .reference)      // the lzfse reference's `lzvn_encode_buffer`
var lzfse = LZFSEEncoder()                     // COMPRESSION_LZFSE, block boundaries included
var lzfse = LZFSEEncoder(parse: .reference)    // the reference's `lzfse_encode_buffer`
LZVNEncoder.maximumCompressedSize(forByteCount: n)  // now n + n/4 + 32 (the room checks below)
```

`LZVNEncoder.Parse` (`.compression`, `.reference`; `LZFSEEncoder.Parse` is the same type) is a stored `let`. Both
parses are their own specialized copy of the LZVN search loop (`encodeCompression`, `encodeReference`), so the choice
costs nothing per position; LZFSE takes its one difference as a parameter.

## Method

`libcompression.dylib` from macOS 27.2.1 (the LZRAVEN work's copy). `compression_encode_buffer` sends 0x900 and 0x901
straight to `_lzvn_encode_buffer` → `_lzvn_encode_partial` → `_lzvnEncode` (the search) and `_emitMatch`;
`_lzfse_encode_buffer` calls the same `_lzvn_encode_buffer` with 0x900 for inputs under 4,096 bytes (0x901 for
`COMPRESSION_LZFSE`'s 0x802 variant). Binary Ninja's pseudo-C of `_lzvnEncode` (Tools/bn) gave the structure, objdump
the details; compared line by line with `lzvn_encode_base.c` from the c-references tarball. The transcription was C
first: the reference's files with the differences below, compared with `compression_encode_buffer` (scratch harness in
the session's directory): 219,339 LZVN cases, all identical — every Silesia and web file whole (16 MiB) and as 64 KiB
chunks into 64 KiB of room and into ample room, prefixes of 0–2,000 bytes, 200 random slices per file, capacity sweeps
(every capacity from 0 to the stream's size + 40), periods 1–40, runs, random bytes, random-then-run, at sizes up to
200,000. Then Swift, checked against Compression directly by the tests.

## What Compression's LZVN does differently

Only two things, and the rest — the 16,384 lines of 4 positions and values, the candidate order and ties, the
3-byte minimum, the forward and backward extension, the pending-match rule, the previous-distance candidate (gain
`M − 1`), the 400-byte literal backlog and its 271-byte literal, the opcodes `_emitMatch` writes, the room checks — is
the reference's, instruction for instruction:

1. **The hash.** Compression: `((v & 0xFF_FFFF) &* 0x9E37_79B1) >> 18` in 32 bits (Fibonacci hashing, the product's
   top 14 bits; the shift is `32 − hash bits`, 14 for 0x900, 11 for 0x901, read from the state). The reference:
   `((v & 0xFF_FFFF) &* 4161) >> 12 & 0x3FFF`. This alone is every byte of difference: Compression's lines collide less,
   finds more matches, and writes smaller streams: −0.003 to −2.1% in 64 KiB chunks, −0.07 to −2.9% whole (sizes below).
2. **Inputs under 8 bytes fail** (`_lzvn_encode_partial` returns 0 for `src_size <= 7`, any room); the reference writes
   them as a literal and the end-of-stream opcode. Bytes keeps writing the literal (9 bytes longer than the input, so a
   caller that stores chunks that don't shrink — `decmpfs`, AEA — decides as with Compression), and documents it.

**Room (when 0x900 returns 0).** Every check is the reference's, against `dst_end = dst + dst_size − 8` (8 bytes kept for
the end-of-stream opcode): each literal piece (`x` bytes behind a 2-byte opcode while more than 15 remain, then the rest
behind a 1-byte one) is refused unless `x + 10` is less than the room before it; a match needs more than 8 bytes of room after
its literal pieces and must end before `dst_end`. So a stream needs 1 to 10 bytes more room than its size, and less than 8
bytes of room always fails. The first refused write fails the whole stream (`lzvn_encode` stops; what's left would be
one literal, which needs more room still, so `src_used != src_size`). Bytes had exact-fit semantics (a stream of the
output's size fit): it now makes Compression's checks exactly (`Emitter.matchExactly`, `literal`, `longLiteral`), and
its fast path keeps more room than they need. With exact fits, a 64 KiB chunk compressing to within 10 bytes of 64 KiB
would have been stored compressed where `xip` stores it raw.

**Limits.** Exact for inputs under 2 GiB. From 2 GiB, Compression's (and the reference's) table positions are 32-bit
and wrap negative, so table candidates past 2^31 are out of range and only the previous distance matches; Bytes rebases
its table and keeps finding matches, so the streams differ (both valid). Over 4 GiB − 1 bytes Compression fails
(`src_size` is clamped to `0xFFFFFFFF` and `src_used != src_size`); Bytes encodes. Neither is tested (too large here).

## LZFSE: Compression's whole stream too

The earlier record had Compression's LZFSE differing from the reference's only at some block boundaries (±0.012%). The
cause, from `_lzfseEncodeBase`: when no match comes, pending literals are pushed (315 at a time, or the pending match)
once more than **945** pile up (`cmp x12, #0x3b2`: 3 × 315); the reference waits for more than 2,520 (8 × 315). Blocks
fill at the same literal limit, so an earlier 315-byte push moves where the 40,000th literal falls. Everything else in
`_lzfseEncodeBase`, `_lzfsePushMatch` (it restores `n_matches` and `n_literals` in one 8-byte store), `_lzfseEncodeFinish`
matches the reference. With this and the LZVN hash for `bvxn` blocks, the C transcription equals Compression on 83,672
cases (every file whole, 64 KiB chunks, prefixes 0–5,000) and on 62,533 capacity cases (corpus slices of 4,096–74,000
bytes at capacities around the stream's and the input's sizes).

LZFSE's room checks are the reference's too, and Bytes' writer didn't make them: a whole
`lzfse_compressed_block_header_v2` (752 bytes, though the written header is 32 + up to 630) at each block's start, 16
bytes before each group of 4 literals and before each triple, 8 for the triples' padding, 4 for the end marker; where
one fails, the stream is stored if `n + 12` fits, else the call fails. `LZFSEBlockWriter.write` now records the
position of the last literal group and the last triple (one register move per group) and checks all of them after
writing; a text input of 4,096 bytes compressing to ~1,290 bytes needs about 2,560 bytes of room, and Compression
fails below (Bytes used to succeed). `LZFSEEncoder()` is now Compression's byte for byte, failures and stored fallbacks
included; `LZFSEEncoder(parse: .reference)` the reference's (same room checks).

## Tests

`Tests/BytesCompressionTests/LZCompressionParityTests.swift` (new), against `compression_encode_buffer` directly:
- LZVN `samples`: every size 0–2,000 of text, random, runs, and mixes (8,004 inputs), periods 1–40 at 17–70,000 bytes,
  23 sizes up to 70,000 of five kinds, every `LZEncoderSamples` and `LZSamples.large` input (to 16 MiB): identical
  streams (under 8 bytes: Compression fails, Bytes writes the 9-byte-longer literal), each decoded back by
  `LZVNDecoder`, each fitting in `maximumCompressedSize`.
- LZVN `corpus`: six files' first 16 MiB whole, and their first 4 MiB as 64 KiB chunks into exactly 64 KiB of room (as
  `decmpfs`) and into ample room: identical, failures included.
- LZVN `room`: 130 inputs (sizes 8–70,000, five kinds, 40 random mixes) at every capacity from 0 to the stream's size
  + 40 (or 0–24 and ±40 around it): identical results; the least room is 1–10 bytes past the stream's size.
- `referenceRoom`: the reference parse's room is monotonic and its sub-8-byte literal needs exactly `n + 19` bytes.
- LZFSE `samples`, `corpus` (whole, and 64 KiB chunks into 64 KiB), `room` (33 generated inputs and a 64 KiB slice of
  each corpus file, at capacities 0–40, around the stream's size, every 9th to 800 past it, and around the input's
  size): identical, stored fallbacks and failures included.
`LZFSEEncoderTests.swift`: the reference-digest tests now construct `parse: .reference` encoders (digests unchanged:
the reference parse writes what it wrote); the exact-fit `outputTooSmall` tests are gone (replaced by the room tests);
LZVN's `reuse` runs for both parses. The decoders' tests keep using reference streams (`lzvnReferenceEncode`,
`lzfseReferenceEncode` pass `.reference`), so the 853-stream corruption digest is unchanged. All 159 BytesCompression
tests pass; `swift build --build-tests` has no warnings.

## Performance

Sizes (LZVN, Compression's parse against the reference's): dickens 16 MB 4,892,627 / 5,001,004 (−2.2%), 64 KB × 16
516,990 / 524,164; mozilla 7,992,463 / 7,997,955, 683,587 / 683,604; xml 948,689 / 957,521, 218,809 / 220,336; x-ray
6,875,701 / 7,083,178 (−2.9%), 836,169 / 853,986; samba 5,146,170 / 5,182,732, 387,958 / 388,948.

Benchmarks: `LZFSEEncoderBenchmarks.swift` gains `LZVN encode … : Compression` (algorithm 0x900, scratch allocated
once) and `LZVN encode … : Bytes, reference parse` rows; registration checks Bytes' first piece against Compression's
for the 64 KB and JSON shapes. One interleaved A/B run on an idle machine (no other agent benchmarking; the old code
from a copy of the tree before this work): `lzvn-old-1`, `lzvn-apple-1`, `lzvn-old-2`, `lzvn-apple-2` (the old ones
copied into `.benchmarkBaselines`), under the shared lock. MB/s from the median wall clock, the two rounds averaged
(the rounds agree within ±6% but for old mozilla 16 MB, 163/146); instructions per input byte from package-benchmark's
count (`lzvn-apple-2`; old from `lzvn-old-2`).

LZVN encoding, MB/s:

| Input | before (reference parse) | Bytes (Compression's parse) | Bytes, reference parse | Compression | Bytes vs Compression |
|---|---:|---:|---:|---:|---:|
| dickens (9.7 MB) | 76 | 86 | 85 | 80 | 1.08x |
| dickens (64 KB × 16) | 81 | 87 | 87 | 81 | 1.07x |
| mozilla (16 MB) | 155 | 169 | 173 | 122 | 1.39x |
| mozilla (64 KB × 16) | 330 | 350 | 344 | 199 | 1.76x |
| samba (16 MB) | 159 | 174 | 180 | 124 | 1.40x |
| samba (64 KB × 16) | 173 | 188 | 184 | 135 | 1.39x |
| x-ray (8.1 MB) | 106 | 89 | 102 | 82 | 1.09x |
| x-ray (64 KB × 16) | 107 | 91 | 103 | 91 | 1.00x |
| xml (5.1 MB) | 206 | 223 | 232 | 151 | 1.48x |
| xml (64 KB × 16) | 184 | 210 | 205 | 148 | 1.42x |
| JSON 1.6 KB (µs per encode) | 4.8 | 4.5 | 4.7 | 13.0 | 2.9x |

LZVN encoding, instructions per input byte:

| Input | before | Bytes | Bytes, reference parse | Compression |
|---|---:|---:|---:|---:|
| dickens (9.7 MB) | 104.1 | 112.8 | 108.4 | 111.8 |
| dickens (64 KB × 16) | 101.1 | 108.7 | 104.9 | 111.6 |
| mozilla (16 MB) | 71.1 | 71.2 | 70.9 | 86.0 |
| mozilla (64 KB × 16) | 56.3 | 55.3 | 55.3 | 77.2 |
| samba (16 MB) | 61.3 | 62.5 | 61.5 | 74.0 |
| samba (64 KB × 16) | 62.9 | 62.9 | 62.0 | 77.2 |
| x-ray (8.1 MB) | 90.7 | 134.9 | 94.4 | 137.2 |
| x-ray (64 KB × 16) | 93.5 | 128.7 | 98.2 | 133.5 |
| xml (5.1 MB) | 48.3 | 49.4 | 48.6 | 59.7 |
| xml (64 KB × 16) | 52.5 | 54.4 | 53.4 | 65.8 |
| JSON 1.6 KB (per encode) | 88 K | 87 K | 87 K | 228 K |

- **Faster than before everywhere but x-ray** (dickens +7–13%, mozilla +6–9%, samba +8–9%, xml +8–14%, JSON +7%),
  though it runs −2 to +8% instructions on the same inputs: the extension change below cut mispredictions.
- **x-ray is 15–16% slower than before, from the parse itself**: Compression's hash finds far more 3-byte candidates
  in 12-bit image data. The C transcription shows the same (x-ray 64 KB × 16: 117 M instructions with the reference's
  hash, 136 M with Compression's, +17%), and it buys 2–3% smaller streams. The reference parse in the new code is at
  96% of before on x-ray and 4–13% faster on the other files.
- **Against Compression's own encoder**: 0.72–1.01x its instructions (dickens and x-ray about equal, the others
  0.72–0.84x), and 1.00–1.76x its speed; x-ray in 64 KiB chunks is the tie.
- **LZFSE** (Compression's parse now): instructions −1.7 to +0.4% against before on every row, time within the run's
  noise (old/new per round: dickens 64 KB 133/123, 139/138; mozilla 64 KB 315/340, 349/385; x-ray 16 MB 166/177,
  177/180 MB/s), still 1.2–1.6x Compression.
- Allocations: `benchmark thresholds check --filter 'Allocations:(LZFSE|LZVN)_encode.*'` passes (0 mallocs).

What the instruction counts went through (harness, 64 KiB chunks of the first 1 MiB, instructions and cycles over 20
runs; cycles from `/usr/bin/time -l`, stable to ±0.5%):

| Step | dickens instr / cycles | x-ray instr / cycles | random 1 MiB instr |
|---|---|---|---|
| before (reference parse) | 106.3 M / 53.3 M | 97.9 M / 38.0 M | 64.5 M |
| Compression's hash and room checks, first cut | 112.4 M | 129.1 M | 72.1 M (reference parse too: 12% more) |
| the backlog literal `@inline(always)` (it had become a call: the loop's state reloaded after it) | 109.7 M | 123.8 M | 65.4 M |
| that 271-byte literal as its own function, the input's last literal out of line as a static function | 113.0 M / 55.1 M | 127.3 M / 45.3 M | 62.6 M |
| extension from the 3rd byte unconditionally (no branch on whether 3 or 4 bytes agree) | 114.0 M / 47.2 M | 134.7 M / 45.4 M | 62.6 M |

Tried and dropped: backward extension 8 bytes at a time (x-ray +6% cycles), a simpler backward loop with one
precomputed bound (no change), `matchExactly` as a static function (+1% instructions). Compression's x-ray is 42.7 M
cycles against Bytes' 45.4 M in this harness (6% ahead), its dickens 51.6 M against 47.2 M, mozilla 21.6 M against
12.3 M. Codegen (`Tools/calls` on the encoders and block writer): no retain, release, metadata, allocation, or SIMD
initializer calls; the search loop calls only `memmove` (exact copies), `matchExactly`, `finalLiteral`, and the throw
path; positions inside a written match still run the 18-instruction table-update loop.

## Left undone

- Exact output from 2 GiB (Compression's 32-bit positions wrap) and the failure over 4 GiB − 1, documented instead.
- x-ray in Compression's parse: 6% more cycles than Compression; branch-free candidate evaluation (the earlier
  record's idea) wasn't tried.
- NativeAEA's `ChunkEncoders` doc comment still says LZFSE's streams are the reference's: they're Compression's now
  (not edited: NativeAEA is the parent's).

## Lessons for AGENTS.md

- **Apple's Compression encoders can be the open source with a constant changed**: LZVN 0x900 is the lzfse reference's
  `lzvn_encode` with a Fibonacci hash (`× 0x9E3779B1 >> 18`) instead of `hash3i`; `COMPRESSION_LZFSE` is the
  reference's with a literal backlog of 3 × 315 instead of 8 × 315. Diff the disassembly against the reference
  function by function (Binary Ninja's pseudo-C for structure, objdump for the constants), patch the C reference, and
  compare it with the library before writing Swift.
- **Room checks are part of an encoder's output**: Compression's LZVN refuses a literal piece unless 10 bytes stay free
  past it (plus 8 kept for the end opcode); its LZFSE wants a whole 752-byte header struct free at each block's start
  and 16 bytes before each literal group and triple, so a stream needs up to ~1,300 bytes more room than its size.
  Exact-fit semantics change which chunks get stored raw. Sweep every capacity around the stream's and the input's
  sizes against the library, failures included.
- **Don't branch on how many bytes a hash candidate already matched**: LZVN's "3 or 4 bytes agree, extend only from
  4" mispredicted; extending from the 3rd byte unconditionally (it stops at once where the 4th differs) gives the
  same result and cut dickens' cycles 13% (more instructions, fewer mispredictions: judge by cycles, `/usr/bin/time
  -l`'s "cycles elapsed" over N runs, stable to 0.5% here).
- **A helper used once after a hot loop still shapes the loop**: the final literal inlined, or as a `mutating` call,
  cost the LZVN search loop 1–3% (the emitter's state spilled); as a static function taking the emitter by value and
  returning the position, nothing. And a check added to an `@inline(__always)` helper turned it into a call (12% more
  instructions on random input): recount after touching a hot loop's helpers.
