# ``Bytes``

Parse and write binary formats field by field, at bit or byte granularity, at memory speed.

## Overview

`Bytes` reads binary data from memory you already have (a `RawSpan` or `Span<UInt8>`) and writes it into
memory you provide (a `MutableRawSpan`, `OutputSpan<UInt8>`, or `OutputRawSpan`), without copying or
allocating. Fields are typed by their shape in the data, not by an integer type you have to pick and
byte-swap yourself:

```swift
var reader = BytesReader(packet.span)
try reader.expect(0x50_4B_03_04 as Byte4)                     // a signature
let version = try reader.read(Byte2.self, .littleEndian)      // UInt16
let length = try reader.read(Byte3.self, .bigEndian)          // UInt32, from 3 bytes
let type = try reader.read(Nibble.self)                       // 4 bits
let isRetained = try reader.read(Bit.self).isSet
let qos = try reader.read(QualityOfService.self, as: Crumb.self) // an enum from 2 bits
```

Writing mirrors reading:

```swift
let bytes = try [UInt8](capacity: 64) { output in
    try output.withBytesWriter { writer in
        try writer.write(0x50_4B_03_04 as Byte4)
        try writer.write(20, as: Byte2.self, .littleEndian)
        try writer.write(qos, as: Crumb.self)
    }
}
```

The cursors are `~Copyable` and `~Escapable`: they can't outlive the memory they work on, and a position
can't be duplicated by accident. Reads and writes that throw consume or write nothing (section writers
may leave bytes past the cursor).

Every operation is `@inlinable` and compiles to what you'd write by hand: a byte-aligned `Byte4` read is
one bounds check and one load, and loops over values (`forEach`, generating writes, and loops of single
reads) are vectorized.
On an M3 Ultra, power-of-two widths and `InlineArray`-backed custom types read and write at a single
core's memory bandwidth; with all cores, nearly every width reaches the CPU's memory ceiling.
`Benchmarks/RESULTS.md` has the measurements.

## Topics

### Essentials

- <doc:WritingParsers>
- ``BytesReader``
- ``BytesWriter``
- ``BytesError``

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

### Scanning and shuffling 16 bytes at once

- ``ByteLanes``
- ``ByteMatches``

### Decoders

- ``BitBuffer``
- ``HuffmanTable``
- ``CRC32``

### Order

- ``BitOrder``

### Iteration

- ``ByteGroupValues``
- ``BitsValues``
