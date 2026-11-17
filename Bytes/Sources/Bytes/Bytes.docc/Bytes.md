# ``Bytes``

Parse and write binary formats field by field, at bit or byte granularity, at memory speed.

## Overview

`Bytes` reads binary data from memory you already have (a `RawSpan` or `Span<UInt8>`) and writes it into
memory you provide (a `MutableRawSpan`, `MutableSpan<UInt8>`, `OutputSpan<UInt8>`, or `OutputRawSpan`), or
into a new array, without copying or allocating along the way. Fields are typed by their shape in the data,
not by an integer type you have to pick and byte-swap yourself:

```swift
var reader = BytesReader(packet.span)
try reader.expect(0x50_4B_03_04 as Byte4)                     // a signature
let version = try reader.read(Byte2.self, .littleEndian)      // UInt16
let length = try reader.read(Byte3.self, .bigEndian)          // UInt32, from 3 bytes
let type = try reader.read(Nibble.self)                       // 4 bits
let isRetained = try reader.read(Bool.self)                   // 1 bit
let qos = try reader.read(QualityOfService.self, as: Crumb.self) // an enum with integer raw values, from 2 bits
```

Writing mirrors reading:

```swift
let bytes = try [UInt8](byteCapacity: 64) { writer in
    try writer.write(0x50_4B_03_04 as Byte4)
    try writer.write(20, as: Byte2.self, .littleEndian)
    try writer.write(qos, as: Crumb.self)
}
```

The cursors are `~Copyable` and `~Escapable`: they can't outlive the memory they work on, and a position
can't be duplicated by accident. A read or write that throws consumes or writes nothing and leaves the
cursor where it was (section writers may leave bytes ahead of it).

``BytesReader`` and ``BytesWriter`` are bit-addressable: sub-byte fields can sit anywhere in the stream. For
formats whose stream is whole bytes, ``AlignedBytesReader`` and ``AlignedBytesWriter`` have the same byte-level
API without the bit state (and so compile to less); see ``BytesCursorMode``. `[UInt8](alignedByteCapacity:writing:)`
and `withAlignedBytesWriter` give the aligned writer, `[UInt8](byteCapacity:writing:)` and `withBytesWriter` the
bit-addressable one.

Every operation is `@inlinable` and compiles to what you'd write by hand: a byte-aligned `Byte4` read is
one bounds check and one load, and loops over values (`forEach`, generating writes, and loops of single
reads) are vectorized. On an M3 Ultra, power-of-two widths and `InlineArray`-backed custom types read and
write at a single core's memory bandwidth; with all cores, nearly every width reaches the CPU's memory
ceiling. `Benchmarks/RESULTS.md` has the measurements.

Beyond the types below, `Bytes` extends the standard library (DocC can't link these extension members):
`[UInt8](byteCapacity:writing:)`, `[UInt8](alignedByteCapacity:writing:)`, `append(byteCapacity:writing:)`,
`append(alignedByteCapacity:writing:)`, `[UInt8](copying:)`, `append(copying:)`, and
`withOutputRawSpan(overwritingFrom:_:)` on `Array` (the last also on `MutableSpan<UInt8>` and
`MutableRawSpan`); `String(utf8Capacity:writing:)`, which passes an ``AlignedBytesWriter``;
`withBytesWriter` and `withAlignedBytesWriter` on `OutputSpan` and `OutputRawSpan`; `append(copying:)` and
`withFreeCapacity(byteCount:_:)` on `OutputRawSpan`; `copyBytes(from:toByteOffset:)` and
`copyBytes(within:toByteOffset:)` on `MutableRawSpan` and `MutableSpan<UInt8>`; `hasPrefix`, `hasSuffix`,
`bytesEqual`, `containsByte(where:)`, `firstByteOffset(of:from:)`, `commonPrefixLength(at:and:from:maxLength:)`,
and its unchecked form `unsafeCommonPrefixLength` on `RawSpan`; `UTF8Span(validating:excluding:)`; and bit
helpers on `FixedWidthInteger`: `[bit:]`, `[bits:]`, `[Bits<N>.self, at:]`, `bits(from:upTo:)`,
`bits(from:count:)`, `keepingLowBits(_:)`, `lowBitMask(_:)`, `signedBits(_:as:)`, and `matches(_:mask:)`.

## Topics

### Essentials

- <doc:UnderstandingTheTypes>
- <doc:WritingParsers>
- ``BytesReader``
- ``BytesWriter``
- ``AlignedBytesReader``
- ``AlignedBytesWriter``
- ``BytesError``
- ``LocatedBytesError``
- ``GenericBytesReader/located(_:)``
- ``GenericBytesReader/atomically(_:)``

### Field types

- ``Bits``
- ``Bit``
- ``Crumb``
- ``Nibble``
- ``Byte``
- ``ByteGroup``
- ``Byte2``
- ``Byte3``
- ``Byte4``
- ``Byte5``
- ``Byte6``
- ``Byte7``
- ``Byte8``
- ``Byte9``
- ``Byte10``
- ``Byte11``
- ``Byte12``
- ``Byte13``
- ``Byte14``
- ``Byte15``
- ``Byte16``
- ``ByteRepresentable``

### Variable-size data

- ``LEB128``
- ``GenericBytesReader/read(sectionPrefixedBy:_:)``
- ``GenericBytesReader/read(utf8PrefixedBy:_:)``
- ``GenericBytesReader/forEachRecord(tag:length:_:_:)``
- ``GenericBytesWriter/write(sectionPrefixedBy:_:_:)``

### Scanning and shuffling 16 bytes at once

- ``ByteLanes``
- ``ByteMatches``
- ``ByteLanes/lookup(in:)-(SIMD16<UInt8>)``
- ``ByteLanes/deinterleave(_:_:_:)``
- ``ByteLanes/interleave(_:_:_:)``

### Buffers and copies

- ``ByteBuffer``

### Decoders, encoders, and checksums

- ``BitBuffer``
- ``BitWriter``
- ``HuffmanTable``
- ``CRC32``

### Order and cursor modes

- ``BitOrder``
- ``BytesCursorMode``
- ``BitAddressable``
- ``ByteAligned``
- ``GenericBytesReader``
- ``GenericBytesWriter``

### Iteration

- ``ByteGroupValues``
- ``BitsValues``
