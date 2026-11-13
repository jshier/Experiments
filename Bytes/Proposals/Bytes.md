# Bytes: API proposals

Each proposal was prototyped as an extension in a scratch package that depends on Bytes
(`prototypes/Bytes/Proposals.swift`, `Proposals2.swift`) and checked against the code it replaces. The
probes are `@inline(never)` before/after function pairs, compared with a disassembly-comparison script,
`Tools/loops`, and `Tools/calls`.

**Status: §1–§9 and most of §10 are implemented in Bytes** (INDEX.md has the dates); each section ends with
the shipped form where it differs. Not implemented: integer-typed `Bits` access (§10). The proposed
signatures below are as written then. Measurements are of the prototypes; for shipped numbers see
`../Benchmarks/RESULTS.md`.

"Merged" means Swift's LLVM folded the two functions into one, because their IR was identical: the
strongest evidence of zero cost. File:line references are from 2026-11-09 and have since moved.

Most valuable first.

## 1. `[UInt8](byteCapacity:writing:)`: one closure to write a new array

**Motivation.** Writing into a new array takes two nested closures, usually with an explicit closure type:

```swift
try [UInt8](capacity: packet.encodedByteCount) { output in
    try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in try packet.write(to: &writer) }
}
```

- MQTT's tests and benchmarks (`MQTTTests.swift:9,16,448`; `MQTTBenchmarks.swift:21,29,52,59`), the tests'
  `fieldBytes { }` helper (used 23 times), and `MQTTSocketStream/.../Workload.swift:76`
- Bytes' own docs: `README.md`, `Bytes.docc/Bytes.md`, `WritingParsers.md`, and the `withBytesWriter` doc
  comment

An appending form, `output.append(addingCapacity:) { $0.withBytesWriter { … } }`, is in
`BinaryParsingComparison/Sources/Workloads/LZ4.swift:42-49`.

**Proposed:**

```swift
extension Array where Element == UInt8 {
    @inlinable @inline(always)
    init<E: Error>(byteCapacity: Int, bitOrder: BitOrder = .mostSignificantFirst,
                   writing body: (inout BytesWriter) throws(E) -> Void) throws(E)
    @inlinable @inline(always)
    mutating func append<E: Error>(byteCapacity: Int, bitOrder: BitOrder = .mostSignificantFirst,
                                   writing body: (inout BytesWriter) throws(E) -> Void) throws(E)
}
```

The new array holds exactly what `body` wrote. If `body` throws, nothing is kept.

**After:**

```swift
try [UInt8](byteCapacity: packet.encodedByteCount) { writer in try packet.write(to: &writer) }
```

**Cost.** A probe writes a `Byte2`, a `Byte4`, and a `Bit` (`encodeBefore`/`encodeAfter`):

- The writing closure is the same 194 instructions in both versions, and out of line in both.
- The proposal inlines `withBytesWriter`, removing the 52-instruction specialized
  `OutputSpan.withBytesWriter` and one call level. Statically that's 243 instructions against 291.
- Neither version allocates beyond the array.

`@inline(always)` matters. RESULTS' caveat about cursors captured in closures that aren't inlined applies
to the old form as much as the new one.

**Shipped** as proposed (`BytesWriter.swift`). Both forms now reserve capacity and append, because the
standard library's `[UInt8](capacity:initializingWith:)` allocates through an unspecialized function:
1,000 38-byte arrays −27.6% instructions. Annotating the closure's error type no longer changes the
count; do it anyway in hot code.

## 2. `read(Bool.self)` and `write(_: Bool)`: one-bit flags

**Motivation:**

- Reads: `try reader.read(Bit.self).isSet` at `README.md:16`, `Bytes.docc/Bytes.md:18`,
  `WritingParsers.md:76`, `Tests/BytesTests/BytesTests.swift:421,1392`, and
  `NativeZipArchive/Sources/NativeZip/Inflater.swift:237` (on `BitBuffer`).
- Writes: `try writer.write(Bit(flag))` at `WritingParsers.md:115-116` and `BytesTests.swift:449-450`.
- The survey found 9 reads and 9 writes in MQTT's CONNECT and PUBLISH flags. MQTT has since been rewritten
  to read and write whole flag bytes (see MQTT §2), so it no longer needs them.

**Proposed:**

```swift
extension BytesReader {
    mutating func read(_: Bool.Type) throws(BytesError) -> Bool
    func peek(_: Bool.Type) throws(BytesError) -> Bool
}
extension BytesWriter {
    mutating func write(_ flag: Bool) throws(BytesError)    // one bit
}
extension BitBuffer {
    mutating func read(_: Bool.Type) -> Bool
}
```

**After:**

```swift
let hasTimestamp = try header.read(Bool.self)
try writer.write(reading.timestamp != nil)
```

**Cost.** Merged in both directions. Probes: a loop of flag reads (`flagsBefore`/`After`), and two flag
writes (`writeFlagBefore`/`After`).

**Shipped** as proposed, plus `Bits(rawBitsOf:)` (MQTT §4).

## 3. Rolling back: minimal LEB128 reads, and a non-throwing rewind

**Motivation.** MQTT rolls back by hand with `let start = reader.byteOffset … try! reader.seek(toByteOffset:
start)` (`Framing.swift:64,77,82`, `Packet.swift:69`, `Packets.swift:62`, `Basics.swift:333-343`). Two
things push it to do so:

- `atomically` can't return `nil` without consuming. Framing returns `nil` for "need more data".
- MQTT's variable byte integer must be minimally encoded. It's a LEB128 read, a length check, and a
  rewind. Because of that check, `Properties.swift` can't use `read(bytesPrefixedBy: LEB128.self,
  maxByteCount: 4)` and reads the length, then the bytes.

**Proposed:**

```swift
extension BytesReader {
    // Throws .invalidValue, consuming nothing, unless the value uses the fewest bytes.
    mutating func read(minimal _: LEB128.Type, maxByteCount: Int) throws(BytesError) -> UInt64
    // And a `minimal: Bool = false` parameter on read(sectionPrefixedBy: LEB128…)/read(bytesPrefixedBy: LEB128…).

    // A position from this reader; restoring one never fails, so no `try!`.
    var position: Position { get }      // (byteOffset, bitOffset)
    mutating func rewind(to position: Position)   // precondition: at or before the current position
}
```

**After:**

```swift
let length = try reader.read(minimal: LEB128.self, maxByteCount: 4)
let start = reader.position
… catch { reader.rewind(to: start); … }
```

**Cost.**

- `minimalBefore`/`minimalAfter`: 67 against 63 instructions. The prototype is `atomically` around
  `read(LEB128)` plus `LEB128.byteCount(of:)`.
- `rewind(to:)` is `seek` without the throw. Inside Bytes it's two stores and the existing
  `_assumeInvariant`.

**Shipped** with different spelling for the first half: a `requiringMinimal: Bool = false` parameter on
`read(LEB128.self, maxByteCount:)` and on the prefixed `bytes`/`section` reads, not `read(minimal:)`. The
check is one compare in the decode loop; MQTT parsing −1.6 to −2.6% instructions. `position` and
`rewind(to:)` shipped as proposed (`BytesReader.Position`), and `BytesWriter` has both too.

## 4. `BytesReader(span, atByteOffset:)` and `atBitPosition:`: start a reader at an offset

**Motivation:**

- `var reader = BytesReader(archive); try reader.seek(toByteOffset: Int(clamping: location.offset))` at
  `NativeZipArchive/Sources/NativeZip/ZipArchive.swift:75-76`, and 4 more in that file.
- `var reader = BytesReader(input, bitOrder: .leastSignificantFirst); try reader.seek(toBitPosition: p)`
  at `Inflater.swift:230-231,266-267`, followed by `BitBuffer(reader)`.

The `ByteReader` this replaced had `ByteReader(archive, at:)`.

**Proposed:**

```swift
extension BytesReader {
    init(_ span: RawSpan, atByteOffset: Int, bitOrder: BitOrder = .mostSignificantFirst) throws(BytesError)
    init(_ span: RawSpan, atBitPosition: Int, bitOrder: BitOrder = .mostSignificantFirst) throws(BytesError)
}
extension BitBuffer {
    init(_ span: RawSpan, atBitPosition: Int, bitOrder: BitOrder) throws(BytesError)
}
```

**Cost.** Merged (`atOffsetBefore`/`After`).

Consider `some BinaryInteger` offsets too, throwing `.insufficientData` when out of range. They would
remove NativeZip's five `Int(clamping:)` conversions of `UInt64` zip offsets.

**Shipped:** `BytesReader(_:atByteOffset: some BinaryInteger, bitOrder:)`, `BytesReader(_:atBitPosition:bitOrder:)`,
`BitBuffer(_:atBitPosition:bitOrder:)`, and for writers `BytesWriter(&bytes, atByteOffset:)` (not
`startingAt:`). All `@inline(__always)`: the writer's, only `@inlinable` at first, was called out of line
from NativeZip's inflater.

## 5. Signed values: group reads, bit fields, and bit counts

**Motivation:**

- `try Int32(bitPattern: field.read(Byte4.self, .littleEndian))` at `NativeZipArchive/.../ZipArchive.swift:182`
  and `BinaryParsingComparison/Sources/Workloads/CentralDirectory.swift:84,121`.
  - `read(Int32.self, as: Byte4.self, …)` rejects negative values.
  - `signedInteger(_:as:)` needs the group read first.
- `WritingParsers.md:86-90` / `BytesTests.swift:429-432` read signed 24-bit samples with
  `run.forEach(Byte3.self) { samples.append($0.signedInteger(.bigEndian, as: Int32.self)) }`.
- Bit-packed formats with signed fields have no helper. Examples: a 12-bit signed delta, FLAC residuals,
  sensor packing. Today that's `Int32(bitPattern: value &<< 16) &>> 20`.

**Proposed:**

```swift
extension BytesReader {
    mutating func readSigned<T: ByteGroup, I: FixedWidthInteger & SignedInteger>(_: T.Type, _: ByteOrder, as: I.Type) throws(BytesError) -> I
    mutating func forEach<T: ByteGroup, I: FixedWidthInteger & SignedInteger>(_: T.Type, _: ByteOrder, signedAs: I.Type, _ body: (I) -> Void)
    mutating func readSigned(bitCount: Int) throws(BytesError) -> Int64      // two's complement, 1…64 bits
}
extension FixedWidthInteger {
    func signedBits<I: FixedWidthInteger & SignedInteger>(_ range: Range<Int>, as: I.Type = Int.self) -> I
}
extension Bits {
    var signedValue: Int8 { get }    // the top bit is the sign
}
```

**After:**

```swift
let seconds = try field.readSigned(Byte4.self, .littleEndian, as: Int32.self)
let delta = word.signedBits(4..<16, as: Int32.self)
```

**Cost.** Every pair merged:

- `signedBefore`/`After`: a loop of `Byte4` reads.
- `signedBitsBefore`/`After`: one `sbfx`.
- `signedNibbleBefore`/`After`: a vectorized `forEach(Nibble.self)`, so the sign extension stays vectorized.
- `readSignedBefore`/`After`: 13-bit reads.

**Shipped:** `readSigned(_:_:as:)`, `readSigned(bitCount:)` on `BytesReader` (throws, 1…64 bits) and
`BitBuffer` (non-throwing, 1…56 bits), `signedBits(_:as:)`, and `Bits.signedValue`. Not shipped: the
`forEach(_:_:signedAs:)` overload; use `forEach(Byte3.self, .bigEndian) { $0 … }` with `signedInteger`.

## 6. `forEachRecord(tag:length:_:_:)`: tag-length-value records

**Motivation.** Zip extra fields, a 2-byte id then a 2-byte size:

- `NativeZipArchive/Sources/NativeZip/ZipArchive.swift:168-171`
- `BinaryParsingComparison/Sources/Workloads/CentralDirectory.swift:79-82,115-119`
- `Benchmarks/BytesBenchmarks/Comparators.swift:156-163,194-201` (Bytes' own benchmarks)

The same shape appears in TLS extensions, BLE advertising data, and PNG chunks (with the order reversed).

```swift
while extra.remainingByteCount >= 4 {
    let id = try extra.read(Byte2.self, .littleEndian)
    let size = try Int(extra.read(Byte2.self, .littleEndian))
    var field = try BytesReader(extra.read(byteCount: size))
    …
}
```

**Proposed:**

```swift
extension BytesReader {
    // Until the end. Each record is read atomically: one that doesn't fit throws without being consumed.
    mutating func forEachRecord<Tag: ByteGroup, Length: ByteGroup>(
        tag: Tag.Type, length: Length.Type, _ byteOrder: ByteOrder,
        _ body: (Tag.Integer, inout BytesReader) throws(BytesError) -> Void) throws(BytesError)
}
```

**After:**

```swift
try extra.forEachRecord(tag: Byte2.self, length: Byte2.self, .littleEndian) { id, field in … }
```

**Cost.** `recordsBefore`/`After`: 116 against 115 instructions. The record loops are 28 and 27
instructions, with the same mix.

**Shipped** as proposed (`Sections.swift`), with no closure inside so the cursor stays in registers
(64 against 80 instructions for the same loop). A tolerant loop that stops quietly at an incomplete
record uses `readSectionIfComplete(prefixedBy:_:)` instead.

## 7. `readRemainingBytes()`

**Motivation.** `payload = try body.read(byteCount: body.remainingByteCount)` at
`MQTT/Sources/MQTT/Packets.swift:329,500,574,626`. It can't fail on a byte-aligned reader, but it still
has to be in a `do`/`catch`.

**Proposed:** `mutating func readRemainingBytes() -> RawSpan`. It's non-throwing, with byte alignment
as a precondition.

**Cost.** Merged (`remainingBefore`/`After`).

**Shipped** as proposed.

## 8. `write(repeating:count:)`

**Motivation.**

- Base64's padding is `for _ in 0..<n { try writer.write(0x3D as Byte) }`
  (`Base64/Sources/Base64/Base64.swift:106-110`, now `:118,140`).
- Zero padding and filler appear in most formats.

**Proposed:** `mutating func write(repeating byte: Byte, count: Int) throws(BytesError)`, on top of the
generating `write(Byte.self, count:) { _ in byte }`.

**Cost.** Better than the loop it replaces:

- After: one capacity check, then `memset`.
- Before: a capacity check per byte, in a vectorized store loop (`padBefore`/`After`: 59 against 47
  instructions).

The generating write already gets the `memset` today. This is the discoverable name for it.

**Shipped** as `write(repeating: Byte, count:)`, plus `write(repeating: some ByteGroup, count:)` and
`write(repeating: UInt64, byteCount:, count:)` for run-time element widths, which store 16 bytes at a
time (QOI runs −65 to −77% instructions; see BinaryParsingComparison §2).

## 9. Low-bit masks: `keepingLowBits(_:)` and `lowBitMask(_:)`

**Motivation.** `(1 &<< n) &- 1` with a runtime `n`, often with a special case for the full width:

- Bytes' internals: `BytesWriter.swift:206`, `Sections.swift:29`, `HuffmanTable.swift:76,79,361`.
- `NativeZipArchive/Sources/NativeZip/Inflater.swift:56` (`bits & ((1 &<< UInt64(totalBits)) &- 1)`), and
  the root-table index.

The `[bits:]` subscript takes a `Range` and checks it, which is awkward in hot code with runtime bounds.

**Proposed:**

```swift
extension FixedWidthInteger {
    func keepingLowBits(_ count: Int) -> Self      // 0…bitWidth; precondition
    static func lowBitMask(_ count: Int) -> Self
}
```

**Cost.** `lowBitsBefore`/`After` are 8 instructions each:

- Before: `lsl`/`bic` with a branch for 64.
- After: `lsl`/`csinv`/`and`.

The precondition is one compare that folds when `count` is known.

**Shipped** as proposed, but without a precondition on the upper end: a count above `bitWidth` keeps every
bit (a negative count traps in debug builds only). Inside Bytes the run pattern and `LEB128.maxValue` use
them (runs of 3- and 4-byte elements −2.0 to −2.6% instructions). `bits(from:upTo:)` (NativeZip §2)
shipped alongside.

## 10. Smaller ones (not prototyped: thin wrappers, or adoption notes)

Shipped: `CRC32.checksum(_:continuing:)`, `[UInt8].append(copying:)` (with `[UInt8](copying:)`),
`RawSpan.hasPrefix(_:)` (the test half of `expect`), `String(utf8Capacity:writing:)` (with a non-throwing
overload), `Byte16.vector`, `matches(_:mask:)`. Not shipped: integer-typed `Bits` access.

- **Adoption, no new API:**
  - `read(Byte.self).rawValue` (MQTT `Properties.swift:52-82`, 9 sites) is `load(UInt8.self)`, which
    works at any bit offset.
  - `BytesReader(x.read(byteCount: n))` (`BinaryParsingComparison/.../CentralDirectory.swift:77-119`, 7
    sites) is `readSection(byteCount:)`.
  - MQTT tests' `array(_:)` helper (`MQTTTests.swift:22`) and `withUnsafeBytes { Array($0) }`
    (`MQTTBenchmarks.swift:232`) are `[UInt8](copying:)`.
  - Base64's padding loop is `write(repeating:count:)` (§8).
- **`CRC32.checksum(_:continuing:)`:** the static counterpart of `init(continuing:)` + `update` + `value`
  (`NativeZipArchive/.../ZipDecoder.swift:244-246`).
- **`[UInt8].append(copying: RawSpan)`:** next to `[UInt8](copying:)`. It removes `withUnsafeBytes` at
  `ZipArchive.swift:360-362` and `ZipDecoder.swift:225`.
- **`RawSpan.hasPrefix(_: some ByteGroup)`** (proposed as `starts(with:)`, or a non-throwing
  `reader.matches(_:)`): the test half of `expect`. MQTT built a throwaway reader for
  `peek(Byte7.self) == "$share/"` (`Basics.swift`).
- **`String(utf8Capacity:writing:)`:** keeps Base64's `String(unsafeUninitializedCapacity:)` +
  `MutableRawSpan(_unsafeBytes:)` (`Base64.swift:153-157`) in one audited place.
- **Integer-typed `Bits` access:** `value[Bits<7>.self, at: 9, as: Int.self]` and
  `BitBuffer.read(Int.self, as: Bits<5>.self)`, for the ~16 `Int(…Bits…)` and `.rawValue` hops in
  NativeZip, QOI, and LZ4.
  - Lower value: `Int(x)` is already short.
- **Considered and not recommended:** a return-type-inferred widening read
  (`let n: Int = try r.read(Byte2.self, .le)`). It overloads `read(_:_:)` on return type alone, which
  makes every existing call site ambiguous-prone. `read(Int.self, as: Byte2.self, .le)` already exists.
