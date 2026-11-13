# Bytes API proposals from Base64

From modernizing `Base64` (2026-11-09). Most valuable first. Line numbers are in
`Base64/Sources/Base64/Base64.swift` as left by that run. Measurements: a scratch driver that encodes one
input repeatedly and reads retired instructions with `proc_pid_rusage`; times are ns per call, M3 Ultra
under load from other agents (absolute numbers ~10% low, comparisons run back to back). Kernel checks are
the README's `Tools/loops` commands; they pass with every change kept here.

**Status:** 1, 3, and the `Byte16.vector`, `write(repeating:count:)`, and 128-byte lookup parts of 6 are in
Bytes. 2 is not (Base64 keeps `shiftedDown`, in both the encoder and the decoder). 4 and 5 were not
recommended (Base64's `mask(_:atLeast:)` stays). Current Base64 numbers: `Base64/Benchmarks/RESULTS.md`.

## 1. Copy spans of up to 64 bytes inline in `BytesWriter.write(_: RawSpan)`

**Motivation** (`Base64.swift:212-219`, used at `:105` and `:115`): `write(_: RawSpan)` copies 1–32 bytes
inline with overlapping loads and stores, and calls `memmove` above that. Base64's last block writes 2–64
characters (and copies 1–47 input bytes for inputs under 48), so remainders of 24 bytes or more paid for a
`memmove` call. Base64 now has a workaround:

```swift
static func writeShort(_ bytes: RawSpan, to writer: inout BytesWriter) throws(BytesError) {
    guard bytes.byteCount > 32 else { return try writer.write(bytes) }
    try writer.write(bytes.extracting(first: 32))
    try writer.write(bytes.extracting(droppingFirst: 32))
}
```

**Proposal**: one more case in the existing switch, semantics unchanged:

```swift
case 33...64:
    unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, 0, to: &_bytes, offset)
    unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, 16, to: &_bytes, offset)
    unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, count &- 32, to: &_bytes, offset)
    unsafe Self._copy(SIMD16<UInt8>.self, from: bytes, count &- 16, to: &_bytes, offset)
```

(Optionally also `write(_ value: some ConvertibleToBytes, prefix byteCount: Int)`: the first `byteCount`
bytes of a fixed-size value, for "the first n characters of this 64-byte block".)

**After**: `try writer.write(characters.span.bytes.extracting(first: n))` and
`try blockWriter.write(reader.read(byteCount: rest))`; `writeShort` goes away, and its two out-of-line calls
become one.

**Evidence** (kept in Base64 as the internal `writeShort`: a clear win):

| Input | One `write` (memmove above 32) | `writeShort` |
|---|---|---|
| 47 B (47-byte copy in, 64 characters out) | 22.2 ns | 15.5 ns |
| 95 B (47-byte remainder) | 18.9 ns | 15.3 ns |
| 1,000 B (40-byte remainder) | 63.6 ns | 59.3 ns |
| 16 B, 64 B, 1 KB (16-byte remainder) | no change | no change |

**Shipped** as proposed (`case 33...64` in `BytesWriter.write(_: RawSpan)`, now `@inline(__always)` with
longer copies out of line); `writeShort` is gone. Bytes' 24–64-byte span copies −33 to −36% instructions;
Base64 40–47 B −13% instructions, −14 to −18% time. The optional `write(_:prefix:)` was not added.

## 2. A zero-padded last block: `BytesReader.read(paddedTo:)` (and `ByteLanes.shiftDown`)

**Motivation** (`Base64.swift:100-113`, `:221-229`): block kernels end with "the last 1 to N−1 bytes as one
more block, zero-padded". Base64 did it by zeroing an `InlineArray<48, UInt8>`, putting a `BytesWriter` on
it, and copying (`memmove` for 33–47 bytes). It now uses an overlapping load when a block came before:

```swift
try reader.seek(toByteOffset: reader.byteOffset &- (48 &- rest))
let last = try reader.load(InlineArray<3, SIMD16<UInt8>>.self)
block = bitCast(shiftedDown(last, by: 48 &- rest), to: InlineArray<48, UInt8>.self)
// shiftedDown: three 48-byte `tbl`s with indices iota + count; indices past 47 give 0.
```

**Proposal**:

```swift
extension BytesReader {
    /// Reads the remaining bytes (at most n) into an n-byte block, followed by zeros, and consumes them.
    /// When the span has n bytes ending at the end, one overlapping load and n/16 `tbl`s, with no
    /// memory round trip; otherwise a copy (inline, per proposal 1). Requires byte alignment.
    mutating func read<let n: Int>(paddedTo: InlineArray<n, UInt8>.Type) throws(BytesError) -> InlineArray<n, UInt8>
}
extension ByteLanes {
    /// 48 (or 64) bytes moved down by `count` lanes across the vectors, zeros shifted in.
    static func shiftDown(_ v: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>), by count: Int) -> (…)
}
```

Bytes can check `byteOffset >= n - remaining` itself, so it would also take the fast path for a short
input in the middle of a larger buffer (Base64 only takes it after a block of its own), and it can skip the
bit-offset slow path that `load` specializes into the caller (`_unalignedRawBytes<InlineArray<3, SIMD16>>`,
dead code in `encode`).

**After**: `let block = try reader.read(paddedTo: InlineArray<48, UInt8>.self)`: 13 lines and two helpers
become one line.

**Evidence** (kept in Base64 as `shiftedDown` and the `blocks.isEmpty` branch): 64 B 373 → 357 instructions;
95 B 24.4 → 18.9 ns and 1,000 B 66.3 → 62.2 ns (before `writeShort`). Kernel checks pass (the tail is
outside the loops).

**Not implemented.** Base64 keeps `shiftedDown` for the encoder (three 48-byte `tbl`s) and has its own for
the decoder's 64-byte block, so one Bytes version would need both widths.

## 3. 4-way deinterleave and 3-way interleave (`ld4`, `st3`)

**Motivation**: a decoder needs the inverse shuffles of the encoder's: 64 characters into every 4th byte
(`ld4`), and 3 vectors of bytes into interleaved 48 (`st3`). `ByteLanes` had the 3-way deinterleave and
4-way interleave only. Prototype
(`prototypes/Base64/DecodeBlocks.swift`) writes them as `lookup(in:)` with constant
index vectors:

```swift
let every4th: SIMD16<UInt8> = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60]
let a = ByteLanes(every4th).lookup(in: text) …  ByteLanes(every4th &+ 3).lookup(in: text)
let o0 = ByteLanes([0, 16, 32, 1, 17, 33, 2, 18, 34, 3, 19, 35, 4, 20, 36, 5]).lookup(in: bytes) …
```

**Proposal**:

```swift
static func deinterleave(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>, _ c: SIMD16<UInt8>, _ d: SIMD16<UInt8>)
    -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)   // as ld4: two rounds of uzp1/uzp2
static func interleave(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>, _ c: SIMD16<UInt8>)
    -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)                  // as st3: three 48-byte lookups
```

The 4-way deinterleave in C as two rounds of `uzp1`/`uzp2` with the same empty-`asm` barrier as
`bytes_interleave4` (8 cheap permutes instead of 4 four-register `tbl`s: the swap that gained the encoder
12–15%, since it's bound by `tbl` throughput).

**Evidence**: the prototype block decoder, all with today's `lookup(in:)`: one loop of 52 instructions per
64 characters, 15 `tbl`, no lane moves (`Tools/loops … 'decodeBlocks\(' --require tbl --forbid mov.b,ins`
passes), 12.2 GB/s of text, against 5.0 GB/s for the auto-vectorized arithmetic kernel (`ld4`/`st3`, 176
instructions per 64 characters).

**Shipped** as `ByteLanes.deinterleave` (four vectors; 8 `uzp`s via `CBytesNEON`, with the empty-`asm`
barrier that keeps the loads whole) and `ByteLanes.interleave` (three vectors; 3 `tbl`s). Base64's decoder
reaches 12.8 GB/s of bytes on one core with them and an 80-byte `tbx` window (`Base64/Benchmarks/RESULTS.md`);
NEON `ld4`/`st3` in C did no better (12.9). The 4-way deinterleave needs the `NEONShuffle` trait (on by
default); without it, it falls back to a scalar loop.

## 4. Branch-free lane masks for scalar loops LLVM vectorizes

**Motivation** (`Base64.swift:262-275`): the portable kernel maps 6-bit values with
`mask(_:atLeast:)`, `0 &- ((v &+ (128 &- bound)) &>> 7)`, because comparisons in the loop get threaded
into branches and the loop stays scalar. The decoder prototype hit exactly that: its range tests written as
`c &- low < count ? 0xFF : 0` compiled to a scalar loop with over 60 branches (0.2 GB/s); with arithmetic masks
it vectorized (`ld4`/`st3`, 5.0 GB/s). Every project re-derives these, with range restrictions in comments.

**Proposal** (on `UInt8`, or `FixedWidthInteger & UnsignedInteger`), documented as never compiling to a
branch:

```swift
extension UInt8 {
    func mask(atLeast bound: UInt8) -> UInt8        // 0xFF if self >= bound (1...128), any self
    func mask(in range: ClosedRange<UInt8>) -> UInt8 // 0xFF if in range (up to 128 values), wrapping test
    func mask(equalTo value: UInt8) -> UInt8
}
// atLeast: 0 &- ((self | (self &+ (128 &- bound))) &>> 7)   (the `self |` makes it full-range)
// in:      ((d | (d &+ (128 &- count))) &>> 7) &- 1, d = self &- lowerBound
```

**After**: `value.mask(atLeast: 26)` in `character`, and Base64's `mask` goes away.

**Evidence**: prototyped the full-range `mask(atLeast:)` as an internal extension at
`Base64.swift:263`: the portable kernel's loop stayed at 79 instructions, `vector128`, and the `ld3`/`st4`
check passed (LLVM drops the extra `|` when it knows the value is below 64). Reverted: codegen-neutral,
so it's only worth it shared, in Bytes. **Not implemented**; Base64's own `mask(_:atLeast:)` remains.

## 5. A typed transform into the writer

**Motivation** (`Base64.swift:94-97`, `:184-192`): both kernels are "read `n` typed elements, write `n`
typed elements, one function of each": `read(_:count:)`, `write(_:count:filling:)`, a kernel with
`precondition(output.count == input.count)`, and an index loop.

**Proposal**:

```swift
mutating func write<In, Out: ConvertibleFromBytes & ConvertibleToBytes>(
    _: Out.Type, transforming input: Span<In>, _ transform: (In) -> Out) throws(BytesError)
```

**After**: `try writer.write(InlineArray<64, UInt8>.self, transforming: blocks) { encodeBlock($0, table: table) }`.

**Evidence**: prototyped as an internal extension and used for the block kernel: the innermost loop was
32 instructions, `vector128`, `tbl`/`zip`, no lane moves: identical to `encodeBlocks`. Reverted: Base64
keeps its kernels `@inline(never)` (compiled once, and what the README's kernel checks name), which this
shape doesn't need but doesn't give either. **Not implemented.**

## 6. Small conveniences

- **`ByteLanes`/`SIMD16` from a `Byte16`, and vectors from 16·k-byte blocks** (`Base64.swift:49-55`,
  `:199`, `:207`): `bitCast(last.littleEndian, to: SIMD16<UInt8>.self)`,
  `bitCast(block, to: InlineArray<3, SIMD16<UInt8>>.self)`. A `Byte16.vector` (or
  `ByteLanes(_: Byte16)`) and a `ByteLanes.vectors(of: InlineArray<48, UInt8>)`-style accessor. Free (they
  are bit casts); worth it because `Byte16` is the only way found to build a constant vector with two
  variable lanes without lane inserts: `SIMD16(119, …, character62, character63)` compiled to 16 `mov.b`
  inserts with Swift 6.4.2, the `Byte16` version to 12 scalar instructions, a `dup` and a `mov.d` (−17
  instructions per call; a `SIMD8<UInt16>` with one lane set was 1 instruction worse). **Shipped** as
  `Byte16.vector` and `Byte16(_: SIMD16<UInt8>)`; no vector-array accessor.
- **`BytesWriter.write(repeating: UInt8, count: Int)`** (`Base64.swift:116-120`; **shipped**): padding becomes
  `try writer.write(repeating: 0x3D, count: padding ? (3 &- rest % 3) % 3 : 0)`. The loop of single-byte
  writes it replaced cost 7 instructions per call at 64 B against the `Byte2`/`Byte` switch.
- **A 128-byte lookup** (`tbl` + `tbx`, `lookup(in: (Table64, Table64))`): the decoder maps ASCII with
  `ByteLanes(c).lookup(in: low) | ByteLanes(c &- 64).lookup(in: high)` (2 `tbl` + `orr` per 16 characters,
  correct today because out-of-range lanes give 0); `tbx` saves the `orr`. Low value. **Shipped**
  (`lookup(in: (low, high))`), but the decoder moved to an 80-byte window (64 + 16): 61 micro-ops per block
  against 69, +11%.
