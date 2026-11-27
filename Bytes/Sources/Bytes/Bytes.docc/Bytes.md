# ``Bytes``

Parse and write binary formats field by field, at bit or byte granularity, at memory speed.

## Overview

`Bytes` reads binary data from memory you already have (a `RawSpan` or `Span<UInt8>`) and writes it into
memory you provide (a `MutableRawSpan`, `MutableSpan<UInt8>`, `OutputSpan<UInt8>`, or `OutputRawSpan`), or
into a new array, without copying or allocating along the way. Fields are typed by their shape in the data,
not by an integer type you have to pick and byte-swap yourself, and the bits inside a byte have names:

```swift
var reader = BigEndianBytesReader(packet.span)
try reader.expect(0x504B_0304 as UInt32)                      // a signature
let version = try reader.read(UInt16.self)                    // two bytes, in the reader's byte order
let length = try reader.read(Int.self, as: Byte3.self)        // an Int, from 3 bytes
let flags = try reader.read(Byte.self)                        // a byte of flags
let isRetained = flags[PacketFlags.retained]                  // a named flag
let qos = try flags.value(of: PacketFlags.qos)                // an enum with integer raw values, from 2 bits
```

Writing mirrors reading:

```swift
let bytes = try [UInt8](byteCapacity: 64, mode: BigEndianBytes.self) { (writer) throws(BytesError) in
    try writer.write(0x504B_0304 as UInt32)
    try writer.write(20 as UInt16)
    try writer.write(Byte {
        $0[PacketFlags.retained] = true
        $0[PacketFlags.qos] = qos
    })
}
```

(`PacketFlags` declares each field once: `static var retained: BitFlag { BitFlag(bit: 4) }`,
`static var qos: BitField<QualityOfService> { BitField(bits: 2...3) }`. The `BytesMacros` product's
`@BitFields` and `@BinaryRecord` generate that, and the reading and writing of whole records, from a
struct's properties.) A reader with an explicit order, `AlignedBytesReader` with `read(Byte2.self,
.littleEndian)`, suits formats that mix byte orders, and ``BytesReader`` reads fields of any bit width at any
bit position (`read(Nibble.self)`, `read(Bool.self)`, `read(Crumb.self)`).

The cursors are `~Copyable` and `~Escapable`: they can't outlive the memory they work on, and a position
can't be duplicated by accident. A read or write that throws consumes or writes nothing and leaves the
cursor where it was (section writers may leave bytes ahead of it).

``BytesReader`` and ``BytesWriter`` are bit-addressable: sub-byte fields can sit anywhere in the stream. For
formats whose stream is whole bytes, ``AlignedBytesReader`` and ``AlignedBytesWriter`` have the same byte-level
API without the bit state (and so compile to less); see ``BytesCursorMode``. When one byte order serves the
whole format, ``BigEndianBytesReader``, ``LittleEndianBytesReader``, and the matching writers read and write
integers by type without an order at each call. `[UInt8](alignedByteCapacity:writing:)` and
`withAlignedBytesWriter` give the aligned writer, `[UInt8](byteCapacity:mode:writing:)` a byte-ordered one
(`mode: BigEndianBytes.self`), and `[UInt8](byteCapacity:writing:)` and `withBytesWriter` the bit-addressable
one.

Fixed structures read and write themselves as records (``BinaryParsable``, ``BinaryWritable``,
``FixedSizeBinary``), in one call with one bounds check; formats that name their byte order in their first
bytes (ELF, PCAPNG, TIFF) declare records in the cursor's order (``ByteOrderedParsable``), compiled once per
order. ``Padding`` and ``Reserved`` fields skip bytes or require them to be zero. The macros that generate
records live in the `BytesMacros` product. Lengths, widths, and terminators that come from the data are read
as the data says, and fail as data does: a negative length, a width outside 1 through 8, or a missing
terminator throws instead of trapping. Streams go through ``ByteTransform`` stages composed into a ``Pipeline``; the
`BytesAsync` product has their `async` counterparts and the parallel codecs' asynchronous entry points.
<doc:WritingParsers> builds a format both ways.

Every operation is `@inlinable` and compiles to what you'd write by hand: a byte-aligned `Byte4` read is
one bounds check and one load, and loops over values (`forEach`, generating writes, and loops of single
reads) are vectorized. On an M3 Ultra, power-of-two widths and `InlineArray`-backed custom types read and
write at a single core's memory bandwidth; with all cores, nearly every width reaches the CPU's memory
ceiling. `Benchmarks/RESULTS.md` has the measurements.

Beyond the types below, `Bytes` extends the standard library (DocC can't link these extension members):
`[UInt8](byteCapacity:writing:)`, `[UInt8](alignedByteCapacity:writing:)`, `[UInt8](byteCapacity:mode:writing:)`,
`append(byteCapacity:writing:)`, `append(alignedByteCapacity:writing:)`, `append(byteCapacity:mode:writing:)`, `[UInt8](copying:)`, `append(copying:)`, and
`withOutputRawSpan(overwritingFrom:_:)` on `Array` (the last also on `MutableSpan<UInt8>` and
`MutableRawSpan`); `[UInt8](hexadecimal:)` and `String(hexadecimal:uppercase:)` for hexadecimal text;
`String(utf8Capacity:writing:)`, which passes an ``AlignedBytesWriter``;
`withBytesWriter`, `withAlignedBytesWriter`, and `withBytesWriter(mode:_:)` on `OutputSpan` and `OutputRawSpan`;
`withLentBytes(_:)` on `RawSpan` and `MutableRawSpan`, and `withLentFreeCapacity(_:)` on `OutputRawSpan` (see ``LentBytes``); `append(copying:)` and
`withFreeCapacity(byteCount:_:)` on `OutputRawSpan`; `copyBytes(from:toByteOffset:)` and
`copyBytes(within:toByteOffset:)` on `MutableRawSpan` and `MutableSpan<UInt8>`; `hasPrefix`, `hasSuffix`,
`bytesEqual`, `containsByte(where:)`, `firstByteOffset(where:)`, `firstByteOffset(of:from:)`, `commonPrefixLength(at:and:from:maxLength:)`,
and its unchecked form `unsafeCommonPrefixLength` on `RawSpan`; `byteBlock(at:)` and `byteBlock(at:padding:)` on `RawSpan`
(see ``ByteBlock``); `chunks(of:)` on `RawSpan`, its whole fixed-size chunks as a typed view (`InlineArray<n, UInt8>`
elements, which ``ByteBlock/init(_:)`` takes for 64); `UTF8Span(validating:excluding:)`; and bit
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
- ``BigEndianBytesReader``
- ``BigEndianBytesWriter``
- ``LittleEndianBytesReader``
- ``LittleEndianBytesWriter``
- ``BytesError``
- ``LocatedBytesError``
- ``CancellableError``
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

### Named bit fields

- ``BitFlag``
- ``BitField``
- ``BitPattern``

### Records

- ``BinaryParsable``
- ``BinaryWritable``
- ``FixedSizeBinary``
- ``ByteOrderedParsable``
- ``ByteOrderedWritable``
- ``Padding``
- ``Reserved``

### Variable-size data

- ``LEB128``
- ``GenericBytesReader/read(sectionPrefixedBy:_:includingPrefix:)``
- ``GenericBytesReader/read(utf8PrefixedBy:_:)``
- ``GenericBytesReader/read(bytesTerminatedBy:)``
- ``GenericBytesReader/read(utf8TerminatedBy:)``
- ``GenericBytesReader/forEachRecord(tag:length:_:paddedTo:_:)``
- ``GenericBytesReader/read(_:byteCount:_:)``
- ``GenericBytesReader/read(_:signedByteCount:_:)``
- ``GenericBytesWriter/write(sectionPrefixedBy:_:_:)``
- ``GenericBytesWriter/write(_:terminatedBy:)-(UTF8Span,_)``
- ``GenericBytesWriter/write(_:byteCount:_:)``
- ``GenericBytesWriter/write(_:signedByteCount:_:)``

### ASCII: tags, characters, and digits

- ``ByteGroup/init(ascii:)``
- ``GenericBytesReader/expect(_:_:)``
- ``GenericBytesReader/read(_:asciiDigits:)``
- ``GenericBytesReader/read(_:asciiDigitsUpTo:)``
- ``GenericBytesReader/read(_:asciiOctalDigits:)``
- ``GenericBytesWriter/write(_:asciiDigits:)``
- ``Bits/init(ascii:)``

### Hexadecimal text

- ``GenericBytesWriter/write(hexadecimal:uppercase:)``

### Dates and times

- ``UTCDateTime``

### Scanning and shuffling 16 bytes at once

- ``ByteLanes``
- ``ByteMatches``
- ``ByteBlock``
- ``ByteLanes/matching(in:)``
- ``ByteLanes/asciiDigits``
- ``ByteLanes/lookup(in:)-(SIMD16<UInt8>)``
- ``ByteLanes/deinterleave(_:_:_:)``
- ``ByteLanes/interleave(_:_:_:)``

### Buffers and copies

- ``ByteBuffer``
- ``RawStorage``
- ``LentBytes``
- ``LentMutableSpan``
- ``LentMutableBytes``

### Decoders, encoders, and checksums

- ``BitBuffer``
- ``BitWriter``
- ``HuffmanTable``
- ``CRC32``
- ``Adler32``
- ``RunningChecksum``

### Pipelines

- ``ByteTransform``
- ``ResettableByteTransform``
- ``InPlaceByteTransform``
- ``Pipeline``
- ``FusedPipeline``
- ``TransformFlush``
- ``TransformStatus``
- ``TransformProgress``
- ``PromotedTransform``
- ``PromotedInPlaceTransform``
- ``MappedErrorTransform``

### Order and cursor modes

- ``BitOrder``
- ``BytesCursorMode``
- ``BitAddressable``
- ``ByteAligned``
- ``ByteAlignedCursorMode``
- ``ByteOrderedCursorMode``
- ``BigEndianBytes``
- ``LittleEndianBytes``
- ``GenericBytesReader``
- ``GenericBytesWriter``

### Iteration

- ``ByteGroupValues``
- ``BitsValues``
