# LZBITMAP decoding

`LZBitmapDecoder` (`Sources/BytesCompression/LZBitmapDecoder.swift`): Apple's Compression framework's
`COMPRESSION_LZBITMAP` (0x702), in Swift. Tests: `Tests/BytesCompressionTests/LZBitmapDecoderTests.swift`;
benchmarks: `Benchmarks/CompressionBenchmarks/LZBitmapBenchmarks.swift`; the reference C decoder, libzbitmap
([eafer/libzbitmap](https://github.com/eafer/libzbitmap) at 2fcb080, MIT), vendored as `Sources/CZBitmap` for
tests and benchmarks only until 2026-11-19 (removed: the last section).

## The format

Undocumented by Apple; libzbitmap's author worked it out from Compression's output. What follows is that, checked
against Compression on macOS 27 (`compression_encode_buffer` makes every stream here; `compression_decode_buffer`
is the reference for what's valid, from streams crafted field by field: `CraftedChunk` in the tests, the probes
in this file's history). Integers are little-endian.

**Stream.** `ZBM` and a byte, 0x09 as Compression writes it, then chunks, then an end chunk. Compression reads
0x08 the same way; it also accepts 0x0C and 0x0D, but rejects every compressed chunk it writes under those
(some compressed chunks it accepts and decodes as under 0x09; the rule wasn't found): some other chunk format
nothing here writes. Streams of only stored chunks decode under all four.

**Chunk header**, 6 bytes: the chunk's length (24 bits, header included) and its decompressed size (24 bits).
- Size 0 is the end chunk, and its length must be 6. Bytes after it aren't read.
- The size is at most 32,768.
- A length of size + 6 is a stored chunk: the bytes follow.
- A longer one is invalid; a shorter one is a compressed chunk (at least 32 bytes long: header and trailer).

**Compressed chunk:** a 15-byte header (length, size, then the offsets, from the chunk's start, of the period,
bitmap, and nibble areas, 24 bits each), then five areas in order:

| Area | From | Holds |
|---|---|---|
| literals | byte 15 | the bytes that aren't copies, in order |
| periods | offset 1 | each new period, 1 or 2 bytes |
| bitmaps | offset 2 | bitmaps that aren't in the table, one byte each |
| nibbles | offset 3 | one nibble per group (low nibble first), and repetition counts |
| table | the last 17 bytes | 12 bitmaps of 10 bits (8 of bitmap, 2 of period byte count), from bit 0; 2 bytes unused |

**Groups.** The output is made 8 bytes at a time. Each group's bitmap says, lane by lane from bit 0, whether
the byte is the next literal (bit set) or a copy of the byte a *period* back (clear). Copies may reach into
earlier chunks: the period is up to 65,535, and chunks are 32 KiB, so the decoder keeps the stream's output as
its history. The period starts at 8 in every chunk and stays until a group sets another.

A group's nibble chooses its bitmap:
- 0, 1, 2: the next byte of the bitmap area, then that many bytes of new period from the period area (0: keep
  the period);
- 3 to 14: table entry *n* − 3, whose 2 bits say how many period bytes follow, as above;
- 15: not a bitmap; after a group's nibble, it starts a repetition count.

**Repetitions.** When more than 8 bytes of the chunk remain before a group, the nibble after its nibble is
looked at: a 15 means the group repeats 4 + the sum of the nibbles after the 15, through the first one that
isn't 15 (`3 F F 2`: 4 + 15 + 2 = 21 groups). Each repetition reads its own bitmap and period bytes when its
nibble says to. With 8 or fewer bytes left, the next nibble isn't looked at (it may be the table's first).

**The chunk's end.** Its last group can be partial: bits past the end are ignored and take no literals.
Repetitions past the end are ignored too, reading nothing (Compression's encoder relies on this: 517 bytes of
`abcdefgh` end in a repetition of 71 groups for 64 and a bit).

### What Compression rejects (its careful loop; Bytes rejects all of these everywhere)

- Any table entry with a period byte count of 3, used or not.
- Offsets out of order or outside the chunk; a nibble area over 2,048 bytes (one nibble per group of a full
  chunk; 2,049 bytes is rejected even when the extra byte isn't read).
- Literals or periods left over at the chunk's end (bitmaps and nibbles may be left over), or running out.
- A group that isn't all literals (0xFF) with a period of 0, or one reaching before the stream's first byte,
  measured from the group's first byte (whichever lanes copy, even lanes past the chunk's end). An all-literal
  group needs no valid period: the stream's first group is one, at period 8.
- A nibble of 15 as a group's nibble; nibbles, bitmaps, or periods running out.
- A missing end chunk, or an end chunk longer than 6 bytes.

### Periods under 8

Compression's encoder never writes one (none in the corpus, nor in runs of zeros or period-3 data: those use
period 8 or 24). Compression's careful loop copies them a byte at a time, so a group can repeat its own bytes
(period 2 after `IJKLMNOP`: `OPOPOPOP`), as libzbitmap does; Bytes does the same.

### Where Compression is lax, and inconsistent

Compression's decoder has a fast loop for most of a chunk and a careful loop for its last four or so groups
(and for whole chunks ending in a partial group). Only the careful loop checks:
- In the fast loop, a period under 8, or reaching before the output's start, copies the group from the
  output's *start* instead (`IJKLMNOP` then period 3, mid-chunk: `ABCDEFGH`, the stream's first 8 bytes). In
  the careful loop, the first copies a byte at a time and the second is rejected.
- The fast loop reads bitmaps past their area.
- Its buffer API stops once the output is full: with exactly the room needed, a stream missing its end chunk
  (or more) still returns every byte. (`compression_stream` doesn't support LZBITMAP: every call fails.)

Bytes applies the careful loop's rules everywhere: what Compression rejects, Bytes rejects (no exception in
3,600 random corruptions of real streams), and the 4% of those corruptions that only Compression decodes are
these cases. Where both decode a corrupt stream differently, the tests' reference decoder in its `lax` mode
reproduces Compression.

### What libzbitmap gets wrong

On every stream Compression's encoder wrote (the corpus, the tests' sizes and contents), libzbitmap decodes the
same bytes as Compression. On crafted and corrupt streams:
- It bounds every area by the chunk's end, not the next area: a missing nibble is read from the table, a
  missing bitmap from the nibbles, a missing literal from the periods, decoding garbage instead of failing.
- It accepts leftover literals and periods, and a compressed chunk longer than its stored form.
- It rejects a period of 0 in an all-literal group, which Compression accepts.
- Its repetitions keep reading bitmaps and periods past the chunk's end, so it rejects a stream that gives
  only the ones used (which Compression accepts) and accepts one that gives them all (which Compression
  rejects).
- It rejects repetition counts over 65,535 (Compression's are bounded by the 2,048-byte nibble area anyway).
- It doesn't know the 0x08, 0x0C, and 0x0D magics.

## The decoder

API, in `BytesCompression`:

```swift
var decoder = LZBitmapDecoder()                                  // allocates its tables (~37 KB), once
let size = try LZBitmapDecoder.decompressedSize(of: compressed)  // from the chunk headers alone
let consumed = try decoder.decompressAll(compressed, decodedSize: size, into: &output)
```

- `decompressAll(_:decodedSize:into:)` decodes one stream, magic through end chunk, into an `OutputRawSpan`'s free
  capacity, returning the input bytes used (bytes after the end chunk are left alone). Typed throws, `BytesError`:
  `insufficientData` for a truncated stream, `insufficientCapacity` if the output doesn't fit (or is smaller than
  `decodedSize`), `mismatch` for a size other than `decodedSize`, `invalidValue` for corrupt data. (Named
  `decompress(_:into:expectedSize:)`, with `invalidValue` for a wrong size, until 2026-11-19, when the six LZ decoders'
  whole-buffer calls were made alike: `decompressAll`, the stated size before `into:`, the input consumed returned.)
- The output is the history: copies reach back into earlier chunks of the same call, never before the stream's
  first byte (bytes already in the span are out of reach).
- `~Copyable`, `Sendable`; no allocation per call.

How it decodes a compressed chunk:
1. Unpack the nibble area one nibble per byte (a vectorized loop: `ld1`, `and`/`ushr`, `st2`), then a 15.
2. Spell out each group's nibble (`expandCodes`): 16 nibbles without a 15 are 15 groups without repetitions,
   copied at once (an add and a high-bit test); around a 15, a nibble at a time.
3. The vector pass (`resolveGroups`), 16 groups at a time: each group's bitmap (`tbl` of the table by nibble,
   or of the bitmap area at the running count of bitmap-area nibbles, from a prefix sum of four `tbl` shifts
   and adds) and its period (the period area's bytes at the running sum of period bytes, with the last period's
   byte count carried forward the same way; `tbl` on 48 bytes). A block of 16 is flagged unless every period is
   8 through the bytes written before its group (signs of three 16-bit differences, `umaxv`). The period and
   bitmap areas are copied into the workspace first (after the chunk's first period, 8), so the pass's loads
   never leave it whatever the data says.
4. The groups (`emitGroups`): an unflagged block of 16 with room in the literals and output is 15 instructions
   a group (two loads of resolved fields, the literal and history loads, a `tbl` of the two, the store, the
   literal count from the shuffle table's 9th byte), no checks. Other groups are checked one at a time and go
   through `careful` (a byte at a time) for partial groups, periods under 8, out-of-range periods, and literals
   running out.
5. The chunk's end checks that literals and periods were used exactly and bitmaps not overrun.

Without NEON's `tbl` (the `Portable` and Swift-only builds), the chunk decodes a group at a time
(`decodeGroups`): the same rules, 31 instructions a group, with runs of groups whose cursors can't leave the
chunk checking only the period.

A block of 16 groups that are all copies (bitmap 0) at one period is flagged apart: 128 bytes copied 16 at a
time (8 when the period is under 16), no shuffles. Runs of copies are what LZBITMAP makes of long matches
(xml: 75% of groups are copies, 44% in repetitions).

## Lessons for AGENTS.md

- **Probe an undocumented decoder with crafted streams, and expect two rule sets.** Compression's LZBITMAP
  decoder has a fast loop and a careful loop for a chunk's last few groups, and they disagree on corrupt input
  (periods under 8 or out of range, bitmap overruns): a probe placed at the chunk's end sees the careful rules,
  one mid-chunk the lax ones. Pad crafted cases on both sides before concluding a rule, and fuzz real streams
  against the reference (with a plain reference decoder that has a mode for the reference's laxness).
- **Compression's buffer API stops once the output is full** and returns that count, so it "decodes" streams
  missing their end, given exactly the room; 0 is its only failure. `compression_stream` doesn't support
  LZBITMAP at all (every call fails).
- **`replacing(with:where:)` / `replace(with:where:)` with a comparison's mask compiled a lane at a time** on
  `SIMD16<UInt8>` here (about 200 instructions a vector: `dup`, `cmgt`, `bsl`, `mov.b` per lane), though it is
  one `bsl` elsewhere. Build masks arithmetically (`0 &- (x &>> 7)`, `0 &- ((x &- 1) &>> 7)` for zero lanes) or
  take a comparison's mask as lanes with `unsafeBitCast(mask, to: SIMD8<UInt16>.self)` (one `cmhi`).
- **SIMD reductions are unreliable:** `SIMD16<UInt8>.max()` was an out-of-line call; `SIMD8<UInt16>.max()` was
  one `umaxv` in one version of a loop and 17 lane moves in the next; comparing lanes with a splat of lane 0
  (`SIMD8(repeating: v[0])`) turned the arithmetic feeding it into lane moves. A `tbl` with index 0 splats lane 0
  in the vector domain; `ByteMatches(...).any` on bytes stays two instructions.
- **Prefix sums and fill-forward across 16 lanes are four `tbl` shifts each** (constant `iota - k` indices,
  0xFF lanes giving 0): with them a format's sequential cursors (LZBITMAP's bitmap and period areas, consumed
  by some groups and not others) resolve 16 groups at a time, leaving a per-group loop of loads, one `tbl`, and
  a store: 31 instructions a group with the cursors in the loop, 15 without.
- **A ternary between a loaded byte and a constant (`c ? p[0] : k`) compiled to a branch**, mispredicted on text
  (a coin toss which side): load unconditionally and select with a mask.
- **Variadic `min(a, b, c, d)` builds an array** (`swift_initStackObject`, `swift_release` in `Tools/calls`):
  nest two-argument `min`s.
- **An inner loop over a run's repetitions spilled the values held across it**; one iteration per group, with
  the repetition count as loop state, kept everything in registers (and no `inout` to an out-of-line helper:
  return values).

## Benchmarks (2026-11-18)

`swift package --disable-sandbox benchmark --filter '.*LZBITMAP.*'` (CompressionBenchmarks), M3-class Mac,
macOS 27, Xcode's Swift 6.4, each run under the shared benchmark lock while other agents built in parallel
worktrees: compare within a row (one run). MB/s is bytes out per µs of median wall time; instructions per byte
from package-benchmark's count (printed to two significant digits for the large streams, so ±0.05 there).
Streams are Compression's encodings of the first 16 MiB of each Silesia file (dickens, x-ray, and xml are
smaller: the whole file), and of its first 1 MiB as 16 independent 64 KiB streams (an APFS-compressed file's
chunks), decoded into a buffer of exactly the size with `expectedSize`.

Final version (`lzb-v5`, a run not kept as a baseline; `lzbdec-final` has the same instruction counts):

| Input | Bytes MB/s | Compression MB/s | libzbitmap MB/s | Bytes instr/B | Compression instr/B | libzbitmap instr/B |
|---|---:|---:|---:|---:|---:|---:|
| dickens (9.7 MB) | **5,851** | 5,710 | 364 | 3.14 | 3.24 | 35.0 |
| mozilla (16 MB) | 4,387 | **4,727** | 381 | 3.16 | 2.92 | 31.4 |
| samba (16 MB) | **5,333** | 5,172 | 399 | 3.16 | 2.98 | 31.9 |
| x-ray (8.1 MB) | 4,944 | **5,277** | 424 | 3.42 | 3.30 | 32.8 |
| xml (5.1 MB) | 5,848 | **5,972** | 411 | 3.18 | 2.99 | 31.1 |
| dickens (64 KB × 16) | **5,958** | 5,490 | 355 | 3.16 | 3.28 | 35.3 |
| mozilla (64 KB × 16) | 5,578 | **8,128** | 553 | 2.70 | 1.99 | 24.8 |
| samba (64 KB × 16) | 5,405 | 5,490 | 419 | 3.21 | 2.95 | 32.4 |
| x-ray (64 KB × 16) | 4,640 | **5,377** | 439 | 3.54 | 3.35 | 31.5 |
| xml (64 KB × 16) | 5,377 | **6,205** | 430 | 3.17 | 2.94 | 31.5 |

Allocations: 0 mallocs per decode in every benchmark (`Allocations:LZBITMAP_decode_one`, the generated JSON
fixture of 1,216 records as one stream; `Allocations:LZBITMAP_decode_64KB`, the same as 64 KiB streams; thresholds of 0 in `Thresholds/`). The decoder
allocates its ~37 KB workspace once, at `init()`.

How it got there (Bytes' instructions per byte; each a separate locked run, Compression's column moving 5–15%
between them with the machine's load):

| Version | dickens | mozilla | samba | x-ray | xml | dickens 64 KB | mozilla 64 KB |
|---|---:|---:|---:|---:|---:|---:|---:|
| v1: a group at a time, one branch of checks, a loop over each nibble's repetitions | 8.14 | 7.27 | 7.39 | 7.55 | 7.11 | 8.09 | 5.34 |
| v2: branchless bitmap pick, no spills (one group per iteration), runs whose cursors can't leave the chunk, nibbles spelled out per group 16 at a time | 4.22 | 4.95 | 5.07 | 5.78 | 5.80 | 4.24 | 4.61 |
| v3: the vector pass (bitmaps and periods 16 groups at a time), 15-instruction group loop | 4.12 | 4.11 | 4.35 | 5.66 | 5.05 | 3.55 | 3.72 |
| v4: period check in real 16-bit comparisons (v3's 15-bit form flagged every block with a period over 32 K: most of dickens); all-copy blocks | 3.24 | 3.93 | 3.87 | 4.84 | 4.49 | 3.31 | 3.65 |
| v5: nibble expansion copies up to the first repetition mark (v4 went a nibble at a time for the 15 before each; x-ray has one every 26 groups), 16-byte fills for counts | 3.14 | 3.16 | 3.16 | 3.42 | 3.18 | 3.16 | 2.70 |

Codegen (`Tools/loops`, `Tools/calls` on the release build): the unchecked group loop is 15 instructions
(`vector128`: `ldr q` of the shuffle, `tbl.16b`, an 8-byte store), the vector pass 104–116 per 16 groups, the
nibble unpacking `st2.16b`; no retain, release, generic, or allocation calls in any of them (only
`swift_willThrowTypedImpl` on throws, `memmove` copying the period and bitmap areas, and the out-of-line
`careful` and `readCount`). Without `tbl` (Portable, Swift-only builds) the group-at-a-time path is used; its
tests pass (Swift-only build) but it wasn't benchmarked.

### What's left

- mozilla's 64 KB streams (1.36× Compression's instructions) and x-ray (7–16% slower): Compression's
  instructions per byte are lower where long matches dominate. Bytes copies 128 bytes at once only for a
  block of 16 copies aligned to its 16-group blocks with one period; runs that straddle blocks, or copies at a
  period mixed with occasional literals, go through the group loop. A copy path keyed on runs rather than
  blocks is the next thing to try.
- The 0x0C/0x0D magic variants' compressed chunks: unknown format (rejected). (Found since: 0x0C is
  Compression's level-0 LZBITMAP encoder's, below.)

## The encoder (2026-11-18)

`LZBitmapEncoder` (`Sources/BytesCompression/LZBitmapEncoder.swift`) writes what Compression's encoder writes for
`COMPRESSION_LZBITMAP`, byte for byte, and fails where it fails. Tests:
`Tests/BytesCompressionTests/LZBitmapEncoderTests.swift`; benchmarks:
`Benchmarks/CompressionBenchmarks/LZBitmapEncoderBenchmarks.swift` (registered from `LZBitmapBenchmarks.swift`).

```swift
var encoder = LZBitmapEncoder()                         // allocates its tables (~560 KB), once
try encoder.compress(input, into: &output)              // one stream; output's free capacity is Compression's dst_size
LZBitmapEncoder.maximumCompressedSize(forByteCount: n)  // a capacity that always fits (stored chunks + 31)
```

- `compress(_:into:)` appends one stream (magic through end chunk). Typed throws, `BytesError`:
  `insufficientCapacity` exactly where `compression_encode_buffer` with that capacity returns 0 (nothing is
  appended), `invalidValue` for 4 GiB of input or more. Capacities over 2^32 − 1 are clamped, as Compression does.
- `~Copyable`, `Sendable`; no allocation per call (`Allocations:LZBITMAP_encode_one` and `_64KB`, thresholds 0).
- Each call is a new stream: the hash table is reset (to 8s, as Compression resets it), 512 KiB of stores.

### Method: reading libcompression's encoder

`libcompression.dylib` from macOS 27.2.1 (26B131), extracted from the dyld shared cache (the LZRAVEN work's copy).
`compression_encode_buffer` sends algorithms 0x700–0x702 to `_lzbitmap_encode_buffer` → `_lzbitmap_encode(dst,
dst_size, src, src_size, state, level = algorithm & 0xF)`, and 0x600–0x602 to a separate `_lzbitmap_fast_encode`
(not read). `COMPRESSION_LZBITMAP` is level 2. `_lzbitmap_init_encode_state` takes a 3-entry table at 0x2cc7d1720:
levels 0, 1, 2 write magic bytes 0x0C, 0x09, 0x09; level 0 uses 16 KiB chunks and a 15-bit hash, levels 1 and 2
32 KiB chunks and an 18-bit hash, and only level 2 keeps two positions per bucket. (So 0x0C, the variant the
decoder rejects compressed chunks under, is level 0's: its nibbles have no run-length coding, `magic & 4`.)
Binary Ninja's pseudo-C of `_lzbitmap_process_block` (1,916 instructions, three copies of the group loop, one per
level) gave the structure; `objdump` of the level-2 loop gave the exact order of the hash table's loads and stores,
the candidate lane order, and the tie rules, which the pseudo-C blurred. The transcription was C first (a plain
scalar reference, in the session's scratch directory), compared with `compression_encode_buffer` on the corpus:
identical on its first run, 7,449 cases (every Silesia and web file whole up to 16 MiB and as 64 KiB chunks at
64 KiB of capacity, prefixes of 0–1,999 bytes, random sizes and capacities, a capacity sweep, zeros, random bytes,
periods 3 and 8, repeats past 65,535). Then Swift, checked against Compression the same way (2,225 cases with the
corpus and generated files, identical in the default and Swift-only builds) and by the tests.

### The algorithm (level 2)

- **Stream:** `ZBM\x09`; 32 KiB chunks; an end chunk. Every check is against the destination's end less 31
  bytes (`limit`); a chunk that fails one is stored if *that* fits, else the call fails. Destinations under 35
  bytes fail.
- **Stored chunks:** under 145 bytes; when a compressed chunk isn't smaller than size + 6; when a check fails.
- **Hash table:** 2^18 + 8 `UInt16` positions (the low 16 bits of the absolute position), all 8 at the call's
  start, kept across chunks. A bucket is read as 32 bits at its index: the newer position low, the older high —
  which is the next bucket's newer. Inserting moves the newer up: `store32(h, pos | load32(h) << 16)`. The hash
  is `(load32le(p) × 0x9E3779B1) >> 14`.
- **Groups, in blocks of 16 (128 bytes)** while the block ends before the chunk's end and 16 bytes before the
  input's: the chunk's period starts at 8. The stream's first group is 8 literals (its positions aren't
  inserted).
  - **Copy:** if the group's 8 bytes equal those a period back: code 0, and the 8 positions are inserted in the
    order 1, 2, 3, 5, 6, 7, 4, 0.
  - **Otherwise:** the 8 buckets are read (before any insertion), then the positions inserted in the same order.
    The 16 candidates are each bucket's newer and older entries, as periods `(position + k − entry) mod 2^16`,
    in the lane order of positions 0, 4, 2, 3, 1, 5, 6, 7 (newer), then the same for older. Each candidate's
    cost is `4 × (literals in this group + period bytes) + literals in the next group` (16 bytes compared;
    a period under 8 counts as 8 and 8 literals; period bytes 1 under 256, else 2). The current period costs
    `4 × literals + next literals`, with no period bytes. The cheapest candidate, the first of equals, replaces
    the current period only if strictly cheaper.
  - **Except** when some candidate matches both groups exactly (16 equal bytes): then Compression's scalar loop
    decides, and after it picks such a candidate, later candidates are compared at their cost less 4. (Both
    agree when no candidate matches both groups; this one rule changes the choice. Searches that take this loop:
    1% of dickens's, 5% of mozilla's, 11% of samba's, 26% of xml's.)
  - The block's literals are checked against `limit` before each block (`chunk + 143 + literals`).
- **The tail:** the groups from the last block to the chunk's size rounded up to 64 bytes: each byte a literal
  if it differs from the byte at the last period, bytes past the input's end skipped (so a chunk's last groups
  are copies with empty bitmaps, and partial groups have bits only for real bytes).
- **The table:** codes `bitmap | period bytes << 8` (768) counted; the used ones moved to the front in code
  order, then a quickselect (median of three, largest first, Hoare partitions) until the first 12 are the 12
  most used, in the order the partitioning leaves them: that is the table's order (nibbles 3–14). Codes not in
  the table get nibbles 0–2 (their period byte counts) and a byte in the bitmap area.
- **Nibbles:** run-length coded (a nibble repeated 4 or more times: the nibble, 15, then counts of up to 15, the
  last under 15), scanned 16 at a time with a run counted only if it starts in the first 14 of the 16; then packed
  low first.

### The Swift encoder

A group without a copy is about 225 instructions (Compression's: about 390):
- the 8 hashes in two vectors (a `tbl` building the 4-byte words, `mul`, shift and mask to byte offsets);
- the 8 buckets as lane loads into two vectors; the 16 candidate periods by 16-bit lanewise subtraction (the
  32-bit buckets read as 16-bit pairs give newer and older at once), `uzp` into newer and older;
- the 16 comparisons (`cmeq.16b`) reduced by a tree of 14 `addp.16b`: lanes 2k and 2k + 1 hold candidate k's
  equal counts in this group and the next. (Compression reduces each comparison with three `uaddlp`s.)
- costs, the short-period and period-byte masks, and the zero-pair test in bytes; the choice as the minimum of
  32-bit keys `cost << 24 | (k + 1) << 16 | period` (4 three-register `tbl`s place the bytes), compared with the
  current period's cost in scalars;
- the bitmap of the chosen period (`cmeq.8b`, lane bits, `addv`), the literals packed by one `tbl` with a
  per-bitmap index vector.

What mattered, in order (each checked byte-identical on the corpus):

| Version | x-ray whole, Bytes / Compression | x-ray 64 KB chunks |
|---|---:|---:|
| v1: a straightforward vector port | 0.86× | 0.75× |
| v2: the table reset with 64-byte stores (`initializeMemory(as:repeating:count:)` stored one entry at a time: 16 instructions per input byte at 64 KiB); masks narrowed in bytes, lane offsets loaded rather than constant, keys by `tbl` (LLVM had built each with lane moves) | 0.94× | 1.12× |
| v3: the current period in the minimum (index 0, wins ties), so no select between it and the candidate: LLVM had made that select a branch, mispredicted on mixed data (x-ray: 26% of cycles discarded, then 1.8%) | 1.08× | 1.17× |
| v4: the current period's cost as one weighted `addv`, compared in scalars with a key holding the candidate's period: a shorter chain from one group's period to the next group's | 1.13× | 1.13× |
| v5: candidate periods from vector lanes, not an array in memory (their loads waited on unaligned 16-byte stores) | 1.14× | 1.22× |

(Driver timings, Compression run alongside in the same process, while other agents built: compare within a row.)

What didn't help: candidate periods computed in scalars from scalar bucket loads (fewer lane moves, same
speed); dropping the hash table insertions entirely (an experiment, wrong output) gained only 6%: the inserts
aren't the bottleneck. CPU counters on x-ray: 1.8% of cycles discarded, 59% "processing" (89% of that
"executing"); the remaining limit is the chain from one group's period through the next group's comparison at
that period (a 16-byte load, compare, sum, move to a scalar, compare) and the copy test's branch, which
mispredicts on mixed data (mozilla 15%, xml 28% of cycles discarded): Compression's branch, kept because a
branchless copy path would search every copy group (63% of xml's groups).

### Benchmarks (2026-11-18)

`swift package --disable-sandbox benchmark --filter '.*LZBITMAP encode.*'` (baseline `lzbenc-v1`) and
`'.*LZBITMAP decode.*'` (`lzbdec-final`), M3-class Mac, macOS 27, Xcode's Swift 6.4, each run under the shared
benchmark lock while another agent built in a parallel worktree: compare within a row. MB/s is input bytes (encode)
or output bytes (decode) per µs of median wall time; instructions per byte from package-benchmark's count (two
significant digits for the large inputs). Compression is called with a scratch buffer allocated once. The 64 KB
rows encode each 64 KiB piece with 64 KiB of room, as APFS compression does: pieces that don't fit fail (in both,
identically) after the work. libzbitmap's encoder only runs on the 64 KB shape: it searches a byte at a time
(0.5–4 MB/s) and allocates its state per call.

Encoding (Bytes' output is Compression's, checked byte for byte before each run):

| Input | Bytes MB/s | Compression MB/s | libzbitmap MB/s | Bytes instr/B | Compression instr/B | libzbitmap instr/B |
|---|---:|---:|---:|---:|---:|---:|
| dickens (9.7 MB) | **408** | 351 | | 31.9 | 49.0 | |
| mozilla (16 MB) | **419** | 381 | | 26.8 | 39.8 | |
| samba (16 MB) | **466** | 419 | | 24.0 | 34.6 | |
| x-ray (8.1 MB) | **404** | 353 | | 32.6 | 50.2 | |
| xml (5.1 MB) | **534** | 486 | | 20.4 | 27.7 | |
| dickens (64 KB × 16) | **416** | 364 | 0.49 | 32.4 | 50.5 | 19,100 |
| mozilla (64 KB × 16) | **427** | 388 | 3.5 | 27.7 | 42.0 | 3,690 |
| samba (64 KB × 16) | **435** | 389 | 1.9 | 26.7 | 39.1 | 5,790 |
| x-ray (64 KB × 16) | **404** | 351 | 3.4 | 33.4 | 51.5 | 4,440 |
| xml (64 KB × 16) | **579** | 493 | 3.1 | 21.9 | 31.5 | 3,980 |

Bytes: 0.64–0.74× Compression's instructions, 1.10–1.17× its speed (120–850× libzbitmap's).
Allocations: 0 per encode (`Allocations:LZBITMAP_encode_one`, the 1,216-record JSON fixture as one stream;
`_64KB`, as 64 KiB streams; thresholds 0, checked); Compression 0 (given scratch); libzbitmap allocates per call
(16–108 mallocs per iteration of 16 pieces). libzbitmap's streams are a different encoding: whole files, dickens 5,357,852 bytes against
Compression's 5,353,980; mozilla 7,758,480 / 7,608,589; samba 5,689,257 / 5,382,217; xml 1,077,271 / 985,487;
x-ray 5,088,902 / 5,446,651 (smaller: its search finds more on 12-bit image data).

Decoding, the final comparison with libzbitmap before it's removed (same streams, Compression's; every decoder's
output checked equal to the input before each run, and the decoder tests check Bytes, Compression, and libzbitmap
agree on Compression's streams):

| Input | Bytes MB/s | Compression MB/s | libzbitmap MB/s | Bytes instr/B | Compression instr/B | libzbitmap instr/B |
|---|---:|---:|---:|---:|---:|---:|
| dickens (9.7 MB) | 5,634 | **5,922** | 351 | 3.14 | 3.24 | 35.0 |
| mozilla (16 MB) | **5,159** | 4,765 | 419 | 3.16 | 2.92 | 31.4 |
| samba (16 MB) | 5,848 | 5,848 | 409 | 3.16 | 2.98 | 31.9 |
| x-ray (8.1 MB) | 5,017 | **5,306** | 446 | 3.42 | 3.30 | 32.8 |
| xml (5.1 MB) | 5,779 | **6,060** | 445 | 3.18 | 2.99 | 31.1 |
| dickens (64 KB × 16) | **6,279** | 5,924 | 376 | 3.15 | 3.28 | 35.3 |
| mozilla (64 KB × 16) | 5,638 | **8,738** | 596 | 2.70 | 1.99 | 24.8 |
| samba (64 KB × 16) | 6,096 | **6,242** | 440 | 3.21 | 2.95 | 32.4 |
| x-ray (64 KB × 16) | **5,115** | 4,788 | 454 | 3.54 | 3.35 | 31.5 |
| xml (64 KB × 16) | 6,061 | **6,241** | 450 | 3.17 | 2.94 | 31.5 |

The decoder is unchanged from `lzb-v5` (same instruction counts): 9.5–17× libzbitmap's speed. The idea in "What's
left" (copies keyed on runs, for mozilla's 64 KB streams) wasn't attempted this pass.

### Storage decisions

Because every stream and every failure is Compression's (the capacity checks are its, at the same points), an
APFS writer using this encoder makes Compression's decisions by construction: a 64 KiB chunk fits in 64 KiB exactly
when Compression's does, and inline (≤ 3,584 bytes) and plain (fork ≥ 93%) decisions see the same sizes. Not
rerun on Xcode here (NativeAEA isn't in this package); the corpus at 64 KiB chunks and 64 KiB of capacity, and the
capacity sweeps in the tests, are identical, failures included.

### What's left

- The chain from one group's chosen period to the next group's cost of it (a load at the period, compare, sum,
  move to a scalar) and the copy test's branch bound the group loop: IPC is about 3. Two groups could be
  evaluated speculatively (the next group's candidates don't depend on this group's choice; only its current
  period does), or the current period's comparison for the next group taken from this group's candidates' second
  halves (they compare exactly those 8 bytes) when the choice is a candidate.
- Level 0 and 1 (`COMPRESSION_LZBITMAP` is 2; 0x700 and 0x701 select them) and `_lzbitmap_fast_encode` (0x600–0x602)
  weren't transcribed; level 0's 0x0C streams are the variant the decoder rejects.

### Lessons for AGENTS.md

- **An encoder can be reproduced byte for byte from its machine code**: transcribe the disassembly's exact order
  of hash-table loads and stores (Compression reads all 8 buckets, then inserts in the order 1, 2, 3, 5, 6, 7,
  4, 0), the candidates' lane order (ties go to the lower lane), and the selection loop's quirks; a plain C
  transcription first, compared with the library on the corpus and on capacity sweeps (the failures must match
  too), then the fast version, compared with both.
- **Undocumented size rules come from the checks**: Compression's LZBITMAP encoder checks every write against the
  destination's end less 31 bytes and stores a chunk when compressing it fails a check, so whether a stream "fits"
  depends on the capacity in a way only reproducing the checks gets right.
- **`initializeMemory(as:repeating:count:)` stored one `UInt16` at a time** (a 4-instruction loop over 262,144
  entries): reset large tables with explicit 64-byte vector stores.
- **LLVM makes branches of selects that pick an index for a load** (`best = wins ? k : 16`, then `table[best]`):
  it duplicated the load into both arms and branched on `wins`, a coin toss on mixed data (26% of cycles
  discarded). Fold the choice into a reduction (the current choice as one more key with the lowest tiebreak) or
  compute the loaded value in both cases and select it.
- **Round trips through memory between vector and scalar code stall on unaligned stores**: 16-byte stores at
  offsets 2 and 18, then 2-byte loads inside them, cost more than 16 `umov`s.
- **Pairwise-add trees count matches for many comparisons at once**: 16 candidates' 16-byte `cmeq` masks reduce to
  each candidate's two 8-byte counts in 14 `addp.16b` (Swift: `SIMD32(lowHalf:highHalf:)`, `evenHalf &+ oddHalf`),
  against 3 `uaddlp` per candidate.
- **Vector reductions through `Builtin`** are one instruction each: `Builtin.int_vector_reduce_umin_Vec4xInt32`,
  `int_vector_reduce_add_Vec16xInt8`, `int_umin_Vec8xInt16` on `._storage._value` (BytesCompression enables
  `BuiltinModule`). `SIMD16<UInt8>.min()` is a call.
- **Benchmark registration runs in every benchmark process**: package-benchmark starts one per benchmark, so a
  slow reference in a fixture check (libzbitmap's encoder, 1 MB/s) cost a minute per process. Keep registration
  cheap, and slow references to small inputs.

## 2026-11-19: a 12–15% regression from code added elsewhere in the module, fixed (baselines `m3-api`, `lzb-fix`)

After the LZFSE and LZVN encoders joined BytesCompression, decoding ran 12–15% more instructions (dickens 32 → 36 M,
mozilla 53 → 61 M), with the decoder's file unchanged and Compression's counts identical in the same runs. Bisected in
a copy of the package (the encoder agent's experiment tree): removing just `LZFSEEncoder.swift` and
`LZVNEncoder.swift` restored the counts. The cause: `resolveGroups` widened period bytes with
`SIMD8<UInt16>(truncatingIfNeeded:)` and narrowed flags with `SIMD8<UInt8>(truncatingIfNeeded:)`; with the
encoders' SIMD conversions in the module, LLVM kept that generic specialization out of line, 6 calls per 16 groups.
Fix: each period's two bytes by a byte zip (lane picks of the low and high vectors, `zip1`/`zip2`), and the
any-outside test on the masks themselves (all-ones or zero lanes: no narrowing). The vector pass went from 116/104
to 112/100 instructions per 16 groups with no calls, and decoding to 0–1.9% below the earlier record
(`lzb-fix`: dickens 32 M, mozilla 53 M, samba 52 M; the 64 KB shapes −0.7 to −1.0%). Bytes' `nibbleMask` had the
same narrowing (and calls in `read(bytesTerminatedBy:)`): it now uses `_lowBytes`, a `Builtin.trunc` (`shrn`), and
the terminator scan loop is 13 instructions.

## 2026-11-19: libzbitmap removed (and how to build it again)

After the final comparison above (Bytes decodes 9.5–17x faster than libzbitmap, and all three decoders agree on
Compression's streams; libzbitmap's encoder writes other streams at 0.5–4 MB/s), `Sources/CZBitmap` and its target
left the package, with libzbitmap's rows in `LZBitmapBenchmarks.swift` and `LZBitmapEncoderBenchmarks.swift` and
its checks in `LZBitmapDecoderTests` (which compared it with Compression's results, which the tests still check).

To compare against it again: `Tools/test-data fetch c-references`; extract `libzbitmap-2fcb080.tar.gz`'s
`libzbitmap.c` and `LICENSE` into `Bytes/Sources/CZBitmap` and `libzbitmap.h` into `Sources/CZBitmap/include`; add
`.target(name: "CZBitmap", exclude: ["LICENSE"], cSettings: [.unsafeFlags(["-Wno-shorten-64-to-32"])])` to
`Package.swift` and `"CZBitmap"` to the dependencies of `BytesCompressionTests` and `CompressionBenchmarks`. Its
functions are `zbm_decompress(dst, dst_size, src, src_size, &out_len)` and `zbm_compress(…)`, 0 on success. Nothing
calls them now: the removed benchmark rows decoded each stream (and, for the 64 KB shape only, encoded each piece)
with one call into a buffer of its size.
