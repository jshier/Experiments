# Writing a parser

Turn a binary format's specification into a parser and a serializer that run at memory speed.

## Overview

This guide builds both directions for a small, made-up sensor format, then lists the rules that keep
`Bytes` code fast. The format:

| Field | Size | Notes |
|---|---|---|
| Signature | 2 bytes | `0x53 0x52` ("SR") |
| Version | 4 bits | currently 1 |
| Unit | 2 bits | 0 Celsius, 1 Fahrenheit, 2 Kelvin |
| Has timestamp | 1 bit | |
| Reserved | 1 bit | 0 |
| Sample count | 2 bytes, big-endian | |
| Timestamp | 8 bytes, little-endian | only if the flag is set |
| Samples | 3 bytes each, big-endian | signed 24-bit values |
| Sensor ID | 6 bytes | an opaque identifier |

### Model the fields as types

Pick each field's type from its shape in the data:

- Sub-byte fields are ``Bits``: ``Bit``, ``Crumb`` (2 bits), ``Nibble``, ``Byte``, or any width as
  `Bits<3>`.
- Multi-byte integers are a ``ByteGroup`` (``Byte2`` through ``Byte16``) plus a `ByteOrder`. Odd widths
  such as 24-bit samples are first-class.
- Fields that are really enumerations become enums with integer raw values, read through their field type.
- Fields packed inside a multi-byte value (flags in a `Byte2`, a DOS date's day and month) are read with
  the value, then taken out of its integer as ``Bits``: `flags[bit: 0]`, `date[Bits<5>.self, at: 0]`, or
  wider ones as integers, `attributes[bits: 16..<32]`. `Unit(rawBits: field)` makes an enum of one.
- Opaque fixed-size values (addresses, identifiers, digests) become your own types conforming to
  ``ByteRepresentable``, backed by an `InlineArray` of their bytes.

```swift
import Bytes

enum Unit: UInt8 { case celsius, fahrenheit, kelvin }

struct SensorID: ByteRepresentable, Equatable {
    var rawBytes: InlineArray<6, UInt8>
    init(rawBytes: InlineArray<6, UInt8>) { self.rawBytes = rawBytes }
}

struct Reading {
    var version: Nibble
    var unit: Unit
    var timestamp: UInt64?
    var samples: [Int32]
    var sensor: SensorID
}
```

### Parse

Create a ``Bytes/Bytes`` cursor over the input and read the fields in order. A function that reads part of
a message takes the cursor `inout`; since it's `~Escapable`, say how the result's lifetime relates with
`@_lifetime` (this needs the `Lifetimes` experimental feature in your target).

```swift
enum ReadingError: Error { case truncated, malformed }

func parseReading(_ data: RawSpan) throws(ReadingError) -> Reading {
    do throws(BytesError) {
        var reader = Bytes(data)

        // A fixed-size header read as its own cursor: its length is a constant the optimizer can see,
        // so every field read inside it needs no bounds check of its own.
        var header = Bytes(try reader.read(byteCount: 5))
        try header.expect(0x53_52 as Byte2)
        let version = try header.read(Nibble.self)
        guard version == 1 else { throw .invalidValue }
        let unit = try header.read(Unit.self, as: Crumb.self)  // throws .invalidValue for 3
        let hasTimestamp = try header.read(Bit.self).isSet
        try header.expect(Bit(0))                               // reserved
        let count = Int(try header.read(Byte2.self, .bigEndian))

        let timestamp: UInt64? = if hasTimestamp { try reader.read(Byte8.self, .littleEndian) } else { nil }

        // A run of values: one bounds check, then a vectorized loop.
        var samples: [Int32] = []
        samples.reserveCapacity(count)
        var run = Bytes(try reader.read(byteCount: count * 3))
        run.forEach(Byte3.self) { sample in
            samples.append(Int32(bitPattern: sample.bigEndian << 8) >> 8) // sign-extend 24 bits
        }

        let sensor = try reader.read(SensorID.self)
        return Reading(version: version, unit: unit, timestamp: timestamp, samples: samples, sensor: sensor)
    } catch {
        throw error == .insufficientData ? .truncated : .malformed
    }
}
```

Errors are typed (``BytesError``), so mapping them to your own costs nothing, and a read that throws
consumes nothing: after `.insufficientData` a streaming caller can wait for more data and retry from the
same position.

### Serialize

Write into uninitialized storage with `withBytesWriter`, which commits exactly the bytes written. Lengths
that prefix their data are usually known before writing; compute them first.

```swift
func serialize(_ reading: Reading) throws(BytesError) -> [UInt8] {
    let size = 5 + (reading.timestamp == nil ? 0 : 8) + reading.samples.count * 3 + 6
    return try [UInt8](capacity: size) { (output) throws(BytesError) in
        try output.withBytesWriter { (writer) throws(BytesError) in
            try writer.write(0x53_52 as Byte2)
            try writer.write(reading.version)
            try writer.write(reading.unit, as: Crumb.self)
            try writer.write(Bit(reading.timestamp != nil))
            try writer.write(Bit(0))
            try writer.write(UInt16(reading.samples.count), as: Byte2.self, .bigEndian)
            if let timestamp = reading.timestamp {
                try writer.write(timestamp, as: Byte8.self, .littleEndian)
            }
            // A generating write: the closure is fused into one vectorized loop.
            try writer.write(Byte3.self, .bigEndian, count: reading.samples.count) {
                UInt32(bitPattern: reading.samples[$0])
            }
            try writer.write(reading.sensor)
        }
    }
}
```

### Variable-size parts

Many formats prefix a part with its length: a string, a list, a nested message. Read the part as a
section, a cursor of its own that every read inside is bounded to, and check it was fully consumed:

```swift
var message = try reader.read(sectionPrefixedBy: LEB128.self, maxByteCount: 4)
let topic = try message.read(utf8PrefixedBy: Byte2.self, .bigEndian) // a validated UTF8Span
let flags = try message.read(Byte.self)
try message.expectEnd()                                             // .trailingData otherwise
```

These reads are atomic too: if the section isn't all there, nothing is consumed, not even its length.
To write one, compute its size first and write the length directly, or let a section writer fill it in:

```swift
try writer.write(UInt64(size), as: LEB128.self)
try writer.write(sectionPrefixedBy: Byte2.self, .bigEndian) { (section) throws(BytesError) in
    try section.write(topic, prefixedBy: Byte2.self, .bigEndian)
}
```

The MQTT package next to this one (`../MQTT`) parses and encodes every MQTT 5.0 packet this way.

### Keep it fast

- **Keep cursors local, or pass them `inout` to inlinable code.** A cursor passed `inout` to a closure
  or function the compiler doesn't inline lives in memory: every read then loads and stores its offset,
  and loops stop vectorizing. Most parsers are a few local functions in one module, which is fine.
- **Read fixed-size records as sub-cursors** (`Bytes(try reader.read(byteCount: n))`). Their bounds checks
  fold to one per record.
- **Loop over runs with `forEach`, generating writes, or bulk reads/writes**, not field by field with
  calls the compiler can't see through. Plain loops of single reads and writes also vectorize when the
  cursor is local.
- **Bits one at a time are inherently sequential.** For runs of bit fields, use `forEach(Nibble.self)` or
  `write(Nibble.self, count:)`, which work a byte or block at a time.
- **Little-endian is free** on Apple platforms; big-endian adds a byte swap, which vectorizes.
- **`for`-`in` works** (``Bytes/Bytes`` and its `values(of:)` views are `Iterable`), but typed views decode
  into a buffer first. For hot loops over decoded values, prefer `forEach`. For bytes, or 4-byte custom
  types, iterate zero-copy spans: `for byte in reader`, or `reader.read(InlineArray<4, UInt8>.self, count:)`.
- **Measure.** `Benchmarks/BytesBenchmarks` shows how to benchmark against hand-written code and record
  bandwidth, and `Benchmarks/RESULTS.md` records what each choice in this library cost or saved.
