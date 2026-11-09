# Bytes API proposals from BinaryParsingComparison

Gathered while updating BinaryParsingComparison's Bytes ports (QOI, LZ4, zip central directory) to the
current Bytes API (2026-11-09). Most valuable first.

**How they were checked.** Each was prototyped with Bytes' *public* API as an internal extension in
`Sources/Workloads/Prototypes.swift` (kept for reference at
`prototypes/BinaryParsingComparison/Prototypes.swift`),
used in a copy of one decoder (`…Proto…`), checked for identical output by a test, and compared by
benchmark instruction counts (package-benchmark, medians; wall-clock times were taken on a loaded machine
and are only indicative) plus `Tools/loops`/`Tools/calls`. All prototypes were removed afterwards: the two
that win big (1 and 2) change the *algorithm* of the Bytes port, and this package compares the libraries
on the same algorithm, so adopting them here needs the `ParserSpan` port changed the same way (a decision
for the user). Neither is kept as an internal helper for that reason, not for cost.

Line numbers are for the files as left by this run.

---

## 1. Copying literals from a reader with overrun (LZ4's "wildcopy")

**Motivation.** `Sources/Workloads/LZ4.swift:64`:

```swift
try writer.write(reader.read(byteCount: literalCount))
```

Every LZ4 sequence copies its literals (usually 0–15 bytes) with an exact copy: `write(_: RawSpan)` is two
overlapping loads and stores up to 32 bytes, with a branch on the length. LZ4's reference decoder (and
libdeflate/zstd for literal runs) instead copies a fixed 16 bytes when both input and output have room,
then advances by the real count. Bytes already has the output half (`copy(fromDistance:count:allowingOverrun:)`
for matches, `write(_:byteCount:allowingOverrun:)` for ≤ 8 bytes) but no way to take a fixed-size chunk
from a reader and write a variable prefix of it.

**Proposed API.**

```swift
extension BytesWriter {
    /// Copies the reader's next `byteCount` bytes, advancing both cursors by `byteCount`. With
    /// `allowingOverrun`, and at least 16 (or 32) bytes left in the reader and `copyOverrun` bytes of room
    /// past the copy in the writer, a copy of up to 16 (32) bytes is one (two) fixed 16-byte loads and
    /// stores that may overwrite bytes after the copy with arbitrary values; otherwise exact.
    /// Throws `.insufficientData` / `.insufficientCapacity` without moving either cursor.
    @inlinable @inline(always)
    @_lifetime(self: copy self) @_lifetime(reader: copy reader)
    mutating func write(from reader: inout BytesReader, byteCount: Int, allowingOverrun: Bool) throws(BytesError)
}
```

**After.**

```swift
try writer.write(from: &reader, byteCount: literalCount, allowingOverrun: true)
```

**Evidence.** The prototype (public API only: `peekLoad(SIMD2<UInt64>.self)`, then one or two
`write(_:byteCount:allowingOverrun:)` and `skip`) on the Bytes LZ4 port:

| Input | Instructions, exact copy | With the prototype | Change |
|---|---|---|---|
| `swift-help.lz4` (10.6 MB out) | 65 M | 51 M | −22% (time 4.8 → 3.0 ms, loaded machine) |
| `tricolor.qoi.lz4` (22 KB out) | 215 K | 172 K | −20% (10 → 7.9 µs) |

Mallocs unchanged (2). A real implementation inside Bytes would be one 16-byte move (`_move(SIMD16…)`)
instead of two 8-byte stores, so better still. The block decoder's loops stay `vector128` (the match copy);
the literal path gains lane moves from `SIMD2` extraction in the prototype, which the internal version
wouldn't have.

---

## 2. Writing a run of one repeated element (run-length fills)

**Motivation.** `Sources/Workloads/QOI.swift:61–65` and `:91–93`: a QOI_OP_RUN of `n` pixels is handled one
pixel per loop iteration (`run` counter, `guard run == 0 else { store(previous) … continue }`), as in the
published example. `tricolor.qoi` is 98.5% runs, so this is the whole decode: 17 instructions per run pixel
in the Bytes build. Run-length output is everywhere (QOI, PackBits/TIFF, BMP RLE, PCX, DEFLATE distance-1
matches): `copy(fromDistance: 1, …)` covers single bytes (`memset`) but periods of 2–7 bytes fall into
the byte-at-a-time path of `_copyBack`.

**Proposed API.**

```swift
extension BytesWriter {
    /// Writes the low `byteCount` bytes (1 through 8) of `value`, `count` times, least significant byte
    /// first. Capacity is checked once; the element is replicated into a 16-byte pattern of whole periods
    /// and stored 16 bytes at a time (exact at the end, or with overrun when `allowingOverrun`).
    @inlinable @inline(always) @_lifetime(self: copy self)
    mutating func write(repeating value: UInt64, byteCount: Int, count: Int) throws(BytesError)

    // and, for ByteGroups/ByteRepresentable: write(repeating: Byte3(...), count: n)
}
```

Optionally also make `copy(fromDistance:count:allowingOverrun:)` use the same pattern replication for
distances 2–7 (libdeflate does), which would make run-length via `copy(fromDistance: channels, …)` fast too.

**After** (`QOI.swift:91–93`; the `run` counter and its `guard` at :61–65 go away):

```swift
default: // QOI_OP_RUN: this pixel and `value` more, at once (cut off at the end of the image)
    let count = min(Int(value) &+ 1, writer.remainingByteCount / channels)
    try writer.write(repeating: UInt64(bitCast(previous, to: UInt32.self)), byteCount: channels, count: count)
    cache[hash(previous)] = previous
    continue
```

**Evidence.** Prototype (word of whole periods, 8-byte overrun stores via `write(_:byteCount:allowingOverrun:)`):

| Image | Instructions, per pixel | With `write(repeating:)` | Change |
|---|---|---|---|
| `tricolor.qoi` (98.5% runs) | 6.57 M | 2.27 M | −65% (252 → 133 µs, loaded machine) |
| `antelope.qoi` | 131 M | 106 M | −19% (8.7 → 8.0 ms) |

Identical pixels (test). It also makes the Bytes/`ParserSpan` gap on `tricolor.qoi` moot (that gap is the
per-pixel run loop's register allocation, see RESULTS.md), but only if both ports adopt it.

---

## 3. Errors with their location: `reader.located(error)` (not a closure wrapper)

**Motivation.** `BinaryParsing`'s `ParsingError` carries the byte offset of the failing read; RESULTS.md
measured that per-site location as part of `ParserSpan`'s 2x on field parsing. Bytes gets locations for
free (a throwing read consumes nothing, so `reader.byteOffset` after `catch` is the location), but every
caller that wants an error *value* with the location writes it by hand. `CentralDirectory.swift:56–89`
(`parseWithBytes`) would use it.

**Proposed API.**

```swift
public struct LocatedBytesError: Error, Hashable, Sendable {
    public var error: BytesError
    public var byteOffset: Int
}
extension BytesReader {
    /// `error` at this cursor's position: where the read that threw it started.
    @inlinable @inline(__always)
    func located(_ error: BytesError) -> LocatedBytesError
}
```

**After.**

```swift
var reader = BytesReader(span)
do throws(BytesError) {
    while !reader.isAtEnd { … }
} catch {
    throw reader.located(error)
}
```

**Evidence.** Zip directory, 2,000 entries: 301 K instructions plain, **305 K (+1.3%)** with the `catch`
form (main loop 122 instead of 120 instructions; nothing on the success path calls out). Test: corrupting
the second header's signature reports `.mismatch` at that header's offset.

**Don't** offer it as a closure (`reader.locatingErrors { reader in … }`): measured **345 K (+15%)**. The
closure literal wasn't inlined even though the wrapper was `@inline(always)`: `Tools/calls` shows the body
as `closure #1 in …parseWithBytesProtoLocated`, called with the cursor in memory, so the bit offset and bit
order are no longer known and 14 `BytesReader._unalignedBytes` slow-path calls appear in it.

Caveat to document: offsets are relative to the cursor `located` is called on; a failure inside a
sub-cursor (`readSection`) reports the parent's position (the section's start or end), not the byte within
the section.

---

## 4. `Array<UInt8>.append(byteCapacity:) { writer in … }`

**Motivation.** `Sources/Workloads/LZ4.swift:42–50` (and the `ParserSpan` port's :109–117): appending to an
array through a writer needs two nested closures with spelled-out types and typed throws:

```swift
try output.append(addingCapacity: blockMaximum) { (span: inout OutputSpan<UInt8>) throws(BytesError) in
    try span.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
        try decodeBlock(block, into: &writer)
    }
}
```

**Proposed API.**

```swift
extension Array where Element == UInt8 {   // and ContiguousArray, Data-like RangeReplaceable types
    /// Appends up to `byteCapacity` bytes written by `body`, committing exactly what it writes.
    @inlinable @inline(always)
    mutating func append<E: Error>(byteCapacity: Int, _ body: (inout BytesWriter) throws(E) -> Void) throws(E)
}
```

**After.**

```swift
try output.append(byteCapacity: blockMaximum) { (writer) throws(BytesError) in
    try decodeBlock(block, into: &writer)
}
```

**Evidence.** Same instruction counts as the nested form (65 M / 215 K for the two LZ4 inputs, measured
together with 5); the block decoder is still one closure with the writer local and its loops unchanged
(`Tools/loops`: same 34 loops, same sizes and verdicts as the kept code's closure).

---

## 5. Masked field comparison: `matches(_:mask:)`

**Motivation.** `Sources/Workloads/LZ4.swift:25–27` validates the frame descriptor bit by bit:

```swift
guard flags[Crumb.self, at: 6] == 0b01, !flags[bit: 1], !descriptor[bit: 7],
      descriptor[Nibble.self, at: 0] == 0, sizeCode >= 4, flags[bit: 5]
```

Version bits plus reserved-must-be-zero bits are the common header check (LZ4 FLG/BD, PNG/zip flags, IP
headers); the published example does it as `rawValue & validationMask == validationValue`.

**Proposed API.**

```swift
extension Bits { func matches(_ value: Self, mask: Self) -> Bool }               // self & mask == value
extension FixedWidthInteger { func matches(_ value: Self, mask: Self) -> Bool }
extension BytesReader { mutating func expect<T: ByteGroup>(_ value: T, mask: T) throws(BytesError) } // .mismatch
```

**After.**

```swift
// Version 01, reserved bit 1 clear, independent blocks; descriptor reserved bits clear.
guard flags.matches(0b0110_0000, mask: 0b1110_0010), descriptor.matches(0, mask: 0b1000_1111), sizeCode >= 4
```

**Evidence.** Cold code; same instruction counts as the kept version (measured with 4). Value is
readability and matching the spec's tables; it's a one-liner users can write, so lower priority.

---

## 6. LZ4-style "saturated" lengths

**Motivation.** `Sources/Workloads/LZ4.swift:75–83`: a 4-bit length that, at 15, continues with bytes added
while they're 255. Same scheme in Ogg lacing values and zstd/LZ4-derived formats.

**Proposed API.**

```swift
extension BytesReader {
    /// `initial`, plus following bytes added while each is 255 when `initial == saturation`.
    /// Throws `.insufficientData` (consuming nothing) if the data ends mid-length, `.invalidValue` on overflow.
    mutating func read(lengthContinuing initial: Int, saturation: Int) throws(BytesError) -> Int
}
```

**Evidence.** The prototype is the existing `@inline(always)` helper `LZ4.length(_:_:)`, which is what the
port measures with (no change by construction). Low priority: small, and the atomic version (rewind on
`.insufficientData`) costs a saved offset.

---

## Findings for Bytes that aren't new API

- **`atomically { }` with a large body loses the cursor's registers.** Wrapping each zip entry in
  `reader.atomically { (reader) throws(BytesError) in … }` (all-or-nothing entries, as a streaming parser
  wants): **453 K vs 301 K instructions (+50%)**. The closure literal isn't inlined (`Tools/calls`: one
  call to `closure #1 in …parseWithBytesProtoAtomic`, 14 `_unalignedBytes` slow-path calls inside, outer
  loop 391 instructions). Same cause as the closure form of 3. `atomically` is `@inline(__always)`; it's
  the closure that stays out of line. Worth documenting next to the README's closure caveat, or offering a
  non-closure form (`let mark = reader.byteOffset; … catch { try reader.seek(toByteOffset: mark) }`, or a
  `checkpoint`/`restore` pair).
- **Bit-field subscripts cost nothing.** A QOI variant with the DIFF/LUMA fields taken out with shifts and
  masks (as the `ParserSpan` port does) instead of `first[Crumb.self, at: 4]`, `second.highHalf`: same
  instructions (6.574 M vs 6.574 M; 132 M vs 131 M) and the same loops.
- **`Byte3` vs three `Byte` reads** for QOI_OP_RGB: same instructions (6.566 M vs 6.574 M) and the same
  17-instruction run loop, so neither explains the `tricolor.qoi` gap to `ParserSpan` (see RESULTS.md).
