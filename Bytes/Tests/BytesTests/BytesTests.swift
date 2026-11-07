import Bytes
import Testing

/// A deliberately naive bit-at-a-time model of the stream, to check `Bytes` against.
struct ReferenceStream {
    let bytes: [UInt8]
    let order: BitOrder

    func bit(_ index: Int) -> UInt64 {
        let byte = bytes[index / 8]
        let shift = order == .mostSignificantFirst ? 7 - index % 8 : index % 8
        return UInt64(byte >> shift & 1)
    }

    /// `count` bits from bit `start`, first bit most significant (MSB-first) or least significant (LSB-first).
    func bits(_ count: Int, from start: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count {
            switch order {
            case .mostSignificantFirst: value = value << 1 | bit(start + index)
            case .leastSignificantFirst: value |= bit(start + index) << index
            }
        }
        return value
    }

    /// `count` bytes from bit `start`, each byte the next 8 bits, as a little-endian integer.
    func bytes(_ count: Int, from start: Int) -> UInt128 {
        var value: UInt128 = 0
        for index in 0..<count {
            value |= UInt128(bits(8, from: start + 8 * index)) << (8 * index)
        }
        return value
    }
}

/// Deterministic pseudo-random bytes (SplitMix64).
func randomBytes(_ count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> [UInt8] {
    var state = seed
    return (0..<count).map { _ in
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return UInt8(truncatingIfNeeded: z ^ (z >> 31))
    }
}

// MARK: - Bits

@Suite struct BitsTests {
    @Test func literals() {
        let bit: Bit = 1
        let crumb: Crumb = 0b10
        let nibble: Nibble = "0b1010"
        let byte: Byte = 0b1111_0000
        let three: Bits<3> = "101"
        #expect(bit.rawValue == 1)
        #expect(crumb.rawValue == 2)
        #expect(nibble.rawValue == 10)
        #expect(byte.rawValue == 0xF0)
        #expect(three.rawValue == 5)
        #expect(Int(byte) == 240)
        #expect(Bool(bit))
        #expect(Bit(false) == 0)
    }

    @Test func strings() {
        // `Nibble("1010")` with a literal is literal coercion (non-optional, traps if invalid), so parse
        // runtime strings, as `LosslessStringConvertible` intends.
        func parse<T: LosslessStringConvertible>(_ string: String, as _: T.Type) -> T? { T(string) }
        #expect(parse("1010", as: Nibble.self)?.rawValue == 10)
        #expect(parse("0000_1010", as: Nibble.self)?.rawValue == 10) // Leading zeros are fine.
        #expect(parse("1111_0000", as: Byte.self)?.rawValue == 0xF0)
        #expect(parse("10000", as: Nibble.self) == nil) // Too wide.
        #expect(parse("", as: Nibble.self) == nil)
        #expect(parse("0b", as: Nibble.self) == nil)
        #expect(parse("102", as: Nibble.self) == nil)
        #expect(parse("_1", as: Nibble.self) == nil)
        #expect(Nibble("1010") == 0b1010)
        #expect(Nibble(10).description == "1010")
        #expect(Byte(5).description == "00000101")
        #expect(Bit(1).description == "1")
        for value in 0...255 {
            let byte = Byte(value)
            #expect(Byte(byte.description) == byte)
        }
    }

    @Test func conversions() {
        #expect(Nibble(exactly: 16) == nil)
        #expect(Nibble(exactly: -1) == nil)
        #expect(Nibble(exactly: 15) == .max)
        #expect(Nibble(truncatingIfNeeded: 0x1F) == 0xF)
        #expect(Nibble(rawValue: 16) == nil)
        #expect(~Nibble(0b1010) == 0b0101)
        #expect(Nibble(0b1100) & 0b1010 == 0b1000)
        #expect(Nibble(0b1100) | 0b1010 == 0b1110)
        #expect(Nibble(0b1100) ^ 0b1010 == 0b0110)
        #expect(Nibble(0b0100).isSet(at: 2))
        #expect(!Nibble(0b0100).isSet(at: 3))
        #expect(Crumb(1) < Crumb(2))
    }
}

@Suite struct SectionTests {
    /// The MQTT 5.0 specification's Variable Byte Integer examples (section 1.5.5), plus the 64-bit limits.
    static let leb128Vectors: [(UInt64, [UInt8])] = [
        (0, [0x00]), (127, [0x7F]), (128, [0x80, 0x01]), (16_383, [0xFF, 0x7F]), (16_384, [0x80, 0x80, 0x01]),
        (2_097_151, [0xFF, 0xFF, 0x7F]), (2_097_152, [0x80, 0x80, 0x80, 0x01]), (268_435_455, [0xFF, 0xFF, 0xFF, 0x7F]),
        (UInt64.max, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]),
    ]

    @Test func leb128() throws {
        for (value, encoded) in Self.leb128Vectors {
            #expect(LEB128.byteCount(of: value) == encoded.count)
            var reader = Bytes(encoded.span)
            #expect(try reader.read(LEB128.self) == value)
            let isAtEnd = reader.isAtEnd
            #expect(isAtEnd)
            let written = try [UInt8](capacity: 10) { output in
                try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in try writer.write(value, as: LEB128.self) }
            }
            #expect(written == encoded, "\(value)")
        }
        // Too long for MQTT's 4 bytes, truncated, and past 64 bits: nothing consumed.
        let five: [UInt8] = [0x80, 0x80, 0x80, 0x80, 0x01]
        var reader = Bytes(five.span)
        #expect(throws: BytesError.invalidValue) { try reader.read(LEB128.self, maxByteCount: 4) }
        #expect(try reader.read(LEB128.self) == 1 << 28)
        let truncated: [UInt8] = [0x80, 0x80]
        var short = Bytes(truncated.span)
        #expect(throws: BytesError.insufficientData) { try short.read(LEB128.self, maxByteCount: 4) }
        #expect(short.byteOffset == 0)
        let tooBig: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02]
        var big = Bytes(tooBig.span)
        #expect(throws: BytesError.invalidValue) { try big.read(LEB128.self) }
    }

    @Test func prefixedSectionsAndStrings() throws {
        // A Byte2-prefixed section of 3 bytes, a LEB128-prefixed UTF-8 string, and a Byte2-prefixed string.
        let data: [UInt8] = [0x00, 0x03, 0x0A, 0x0B, 0x0C, 0x02, 0x68, 0x69, 0x00, 0x02, 0xC3, 0xA9]
        var reader = Bytes(data.span)
        var section = try reader.read(sectionPrefixedBy: Byte2.self, .bigEndian)
        #expect(try section.read(Byte.self) == 0x0A)
        #expect(throws: BytesError.trailingData) { try section.expectEnd() }
        try section.skip(byteCount: 2)
        try section.expectEnd()
        var text = try reader.read(sectionPrefixedBy: LEB128.self, maxByteCount: 4)
        #expect(String(copying: try text.readUTF8(byteCount: 2)) == "hi")
        #expect(String(copying: try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian)) == "é")

        // Incomplete or invalid: nothing consumed, not even the length.
        let incomplete: [UInt8] = [0x00, 0x05, 0x01, 0x02]
        var partial = Bytes(incomplete.span)
        #expect(throws: BytesError.insufficientData) { try partial.read(bytesPrefixedBy: Byte2.self, .bigEndian) }
        #expect(throws: BytesError.insufficientData) { try partial.read(sectionPrefixedBy: Byte2.self, .bigEndian) }
        #expect(partial.byteOffset == 0)
        let invalid: [UInt8] = [0x00, 0x02, 0xFF, 0xFE]
        var bad = Bytes(invalid.span)
        #expect(throws: BytesError.invalidValue) { try bad.read(utf8PrefixedBy: Byte2.self, .bigEndian) }
        #expect(bad.byteOffset == 0)
        let lebIncomplete: [UInt8] = [0x05, 0x01]
        var lebPartial = Bytes(lebIncomplete.span)
        #expect(throws: BytesError.insufficientData) { try lebPartial.read(bytesPrefixedBy: LEB128.self) }
        #expect(lebPartial.byteOffset == 0)
    }

    @Test func writingSections() throws {
        let bytes = try [UInt8](capacity: 300) { output in
            try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                // Fixed prefix: backpatched in place.
                let returned = try writer.write(sectionPrefixedBy: Byte2.self, .bigEndian) { (section) throws(BytesError) in
                    try section.write(0x0A0B, as: Byte2.self, .bigEndian)
                    try section.write("hi".utf8Span, prefixedBy: Byte2.self, .bigEndian)
                    return 42
                }
                #expect(returned == 42)
                // LEB128 prefix: reserved 4 bytes, moved down to 1.
                try writer.write(sectionPrefixedBy: LEB128.self, maxByteCount: 4) { (section) throws(BytesError) in
                    try section.write(Byte4(littleEndian: 0x0403_0201))
                }
                // LEB128 prefix that needs 2 bytes.
                try writer.write(sectionPrefixedBy: LEB128.self, maxByteCount: 4) { (section) throws(BytesError) in
                    try section.write(Byte.self, count: 200) { Byte(truncatingIfNeeded: $0) }
                }
            }
        }
        #expect(Array(bytes.prefix(14)) == [0x00, 0x06, 0x0A, 0x0B, 0x00, 0x02, 0x68, 0x69, 0x04, 0x01, 0x02, 0x03, 0x04, 0xC8])
        #expect(bytes[14] == 0x01 && bytes.count == 15 + 200 && bytes[15...] == (0..<200).map { UInt8($0) }[...])

        // Too long for its prefix: invalidValue, and the cursor doesn't move.
        var buffer = [UInt8](repeating: 0, count: 300)
        var mutable = buffer.mutableSpan
        var writer = BytesWriter(&mutable)
        #expect(throws: BytesError.invalidValue) {
            try writer.write(sectionPrefixedBy: LEB128.self, maxByteCount: 1) { (section) throws(BytesError) in
                try section.write(Byte.self, count: 128) { _ in 0 }
            }
        }
        #expect(writer.byteCount == 0)
        _ = consume writer
        _ = buffer
    }
}

/// The NEON shuffle paths (3-, 5-, 6-, 7-byte runs) against single reads and writes, at every length from
/// 0 to 70 values, so whole steps, partial steps, and the "64 bytes must remain" cutoff are all covered.
@Suite struct ShuffleTests {
    @Test func runsMatchSingleValues() throws {
        try check(Byte3.self); try check(Byte5.self); try check(Byte6.self); try check(Byte7.self)
    }

    func check<T: ByteGroup>(_: T.Type) throws {
        let mask = T.Integer.max >> (T.Integer.bitWidth - 8 * T.byteCount)
        for order in [ByteOrder.littleEndian, .bigEndian] {
            for count in 0...70 {
                let values = (0..<count).map { T.Integer(truncatingIfNeeded: UInt64($0 + 1) &* 0x9E37_79B9_7F4A_7C15) & mask }
                // Writing: bulk (shuffled) against one at a time.
                let bulk = try [UInt8](capacity: count * T.byteCount) { output in
                    try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                        try writer.write(values.span, as: T.self, order)
                    }
                }
                let single = try [UInt8](capacity: count * T.byteCount) { output in
                    try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                        for value in values { try writer.write(value, as: T.self, order) }
                    }
                }
                #expect(bulk == single, "write \(T.self) \(order) × \(count)")

                // Reading: bulk into an array (shuffled), forEach (shuffled), and one at a time.
                var bulkReader = Bytes(single.span)
                let read = try [T.Integer](capacity: count) { try bulkReader.read(T.self, order, into: &$0) }
                #expect(read == values, "read(into:) \(T.self) \(order) × \(count)")
                var each: [T.Integer] = []
                var eachReader = Bytes(single.span)
                eachReader.forEach(T.self) { each.append($0.integer(order)) }
                #expect(each == values, "forEach \(T.self) \(order) × \(count)")
                #expect(bulkReader.isAtEnd == true && eachReader.byteOffset == single.count)
            }
        }
    }
}

/// Regressions for the review's findings.
@Suite struct EdgeCaseTests {
    @Test func emptySpansWithoutMemory() throws {
        // Empty spans and outputs with no memory behind them used to be force-unwrapped.
        var buffer = [UInt8](repeating: 0, count: 4)
        var mutable = buffer.mutableSpan
        var writer = BytesWriter(&mutable)
        try writer.write(RawSpan())
        #expect(writer.byteCount == 0)
        _ = consume writer
        _ = buffer

        let data: [UInt8] = [1, 2, 3, 4]
        var reader = Bytes(data.span)
        var empty = OutputSpan<UInt32>()
        try reader.read(Byte4.self, .bigEndian, into: &empty)
        var emptyAddresses = OutputSpan<RawBytes<4>>()
        try reader.read(RawBytes<4>.self, into: &emptyAddresses)
        #expect(reader.byteOffset == 0)
    }

    @Test func emptyViewIsNeverMisaligned() throws {
        let words: [UInt32] = [1, 2]
        var reader = Bytes(words.span.bytes)
        try reader.skip(byteCount: 1)
        #expect(try reader.read(UInt32.self, count: 0).isEmpty)
    }

    @Test func bitIterationRealigns() throws {
        // Starting 1 bit in, 3-bit values reach a byte boundary after 5 values (1 + 15 = 16 bits) and
        // continue on the block path; results must match single reads.
        let data = randomBytes(64)
        var reader = Bytes(data.span)
        try reader.skip(bitCount: 1)
        var values: [Bits<3>] = []
        reader.forEach(Bits<3>.self) { values.append($0) }
        var scalar = Bytes(data.span)
        try scalar.skip(bitCount: 1)
        var expected: [Bits<3>] = []
        while scalar.remainingBitCount >= 3 { expected.append(try scalar.read(Bits<3>.self)) }
        #expect(values == expected)
    }
}

@Suite struct ConvenienceTests {
    @Test func singleBits() {
        var flags: Byte = 0b1010_0000
        #expect(flags[bit: 7] && !flags[bit: 6] && flags[bit: 5])
        flags[bit: 0] = true
        #expect(flags == 0b1010_0001)
        flags[bit: 7] = false
        #expect(flags == 0b0010_0001)
        flags.toggleBit(at: 1)
        #expect(flags == 0b0010_0011)
        #expect(flags.nonzeroBitCount == 3)
        var nibble: Nibble = 0
        nibble[bit: 3] = true
        #expect(nibble == 0b1000)
        #expect(Bit(true).isSet && !Bit(false).isSet)
    }

    @Test func halves() {
        var byte: Byte = 0b1010_0101
        #expect(byte.highHalf == 0b1010 && byte.lowHalf == 0b0101)
        byte.lowHalf = 0b1111
        #expect(byte == 0b1010_1111)
        byte.highHalf = 0b0001
        #expect(byte == 0b0001_1111)
        #expect(Byte(highHalf: 0b1100, lowHalf: 0b0011) == 0b1100_0011)
        var nibble: Nibble = 0b1001
        #expect(nibble.highHalf == 0b10 && nibble.lowHalf == 0b01)
        nibble.highHalf = 0b11
        #expect(nibble == 0b1101)
        #expect(Nibble(highHalf: 0b01, lowHalf: 0b10) == 0b0110)
        var crumb: Crumb = 0b10
        #expect(crumb.highHalf == 1 && crumb.lowHalf == 0)
        crumb.lowHalf = 1
        #expect(crumb == 0b11 && Crumb(highHalf: 0, lowHalf: 1) == 0b01)

        var word: Byte4 = [0x01, 0x02, 0x03, 0x04]
        #expect(word.lowHalf == [0x01, 0x02] && word.highHalf == [0x03, 0x04])
        word.highHalf = [0xAA, 0xBB]
        #expect(word == [0x01, 0x02, 0xAA, 0xBB])
        word[0] = 0xFF
        #expect(word == [0xFF, 0x02, 0xAA, 0xBB])
        #expect(Byte4(lowHalf: [1, 2], highHalf: [3, 4]) == [1, 2, 3, 4])
        var six: Byte6 = [1, 2, 3, 4, 5, 6]
        #expect(six.lowHalf == [1, 2, 3] && six.highHalf == [4, 5, 6])
        six.lowHalf = [9, 9, 9]
        #expect(six == [9, 9, 9, 4, 5, 6])
        let sixteen = Byte16(lowHalf: Byte8(littleEndian: 0x0706_0504_0302_0100), highHalf: Byte8(littleEndian: 0x0F0E_0D0C_0B0A_0908))
        #expect((0..<16).allSatisfy { sixteen[$0] == UInt8($0) })
        #expect(sixteen.highHalf.lowHalf.lowHalf.lowHalf == Byte(8))
        #expect(Byte2(lowHalf: 0x34, highHalf: 0x12).littleEndian == 0x1234)
    }

    @Test func shiftsAndWidths() {
        let nibble: Nibble = 0b1011
        #expect(nibble << 1 == 0b0110 && nibble >> 2 == 0b0010)
        var mask: Nibble = 0b1100
        mask &= 0b1010
        #expect(mask == 0b1000)
        mask |= 0b0001
        mask ^= 0b1111
        #expect(mask == 0b0110)
        #expect(Byte(Nibble(0b1010)) == 0b0000_1010)
        #expect(Nibble(truncatingIfNeeded: Byte(0b1111_0101)) == 0b0101)
    }

    enum QualityOfService: UInt8 { case atMostOnce, atLeastOnce, exactlyOnce }
    enum Kind: UInt16 { case small = 1, large = 0x1234 }

    @Test func rawValueTypes() throws {
        let bytes = try [UInt8](capacity: 8) { output in
            try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                try writer.write(QualityOfService.exactlyOnce, as: Crumb.self)
                try writer.write(Bits<6>(0))
                try writer.write(Kind.large, as: Byte2.self, .bigEndian)
                try writer.write(Crumb(3)) // Not a valid QualityOfService.
            }
        }
        #expect(bytes == [0b1000_0000, 0x12, 0x34, 0b1100_0000])
        var reader = Bytes(bytes.span)
        #expect(try reader.read(QualityOfService.self, as: Crumb.self) == .exactlyOnce)
        try reader.skip(bitCount: 6)
        #expect(try reader.read(Kind.self, as: Byte2.self, .bigEndian) == .large)
        #expect(throws: BytesError.invalidValue) { try reader.read(QualityOfService.self, as: Crumb.self) }
        #expect(reader.byteOffset == 3 && reader.bitOffset == 0) // Nothing consumed.
        var little = Bytes(bytes.span)
        try little.skip(byteCount: 1)
        #expect(throws: BytesError.invalidValue) { try little.read(Kind.self, as: Byte2.self, .littleEndian) }
    }
}

// MARK: - The usage guide's example (Bytes.docc/WritingParsers.md), verbatim

enum Unit: UInt8 { case celsius, fahrenheit, kelvin }

struct SensorID: ByteRepresentable, Equatable {
    var rawBytes: InlineArray<6, UInt8>
    init(rawBytes: InlineArray<6, UInt8>) { self.rawBytes = rawBytes }
    static func == (lhs: Self, rhs: Self) -> Bool { (0..<6).allSatisfy { lhs.rawBytes[$0] == rhs.rawBytes[$0] } }
}

struct Reading {
    var version: Nibble
    var unit: Unit
    var timestamp: UInt64?
    var samples: [Int32]
    var sensor: SensorID
}

enum ReadingError: Error { case truncated, malformed }

func parseReading(_ data: RawSpan) throws(ReadingError) -> Reading {
    do throws(BytesError) {
        var reader = Bytes(data)

        // A fixed-size header read as its own cursor: its length is a constant the optimizer can see,
        // so every field read inside it needs no bounds check of its own.
        var header = Bytes(try reader.read(byteCount: 5))
        try header.expect([0x53, 0x52] as Byte2)
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

func serialize(_ reading: Reading) throws(BytesError) -> [UInt8] {
    let size = 5 + (reading.timestamp == nil ? 0 : 8) + reading.samples.count * 3 + 6
    return try [UInt8](capacity: size) { (output) throws(BytesError) in
        try output.withBytesWriter { (writer) throws(BytesError) in
            try writer.write([0x53, 0x52] as Byte2)
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

@Suite struct GuideExampleTests {
    @Test(arguments: [nil, 1_700_000_000_123] as [UInt64?])
    func roundTrip(timestamp: UInt64?) throws {
        let reading = Reading(
            version: 1, unit: .kelvin, timestamp: timestamp, samples: [0, 1, -1, 8_388_607, -8_388_608, 12_345],
            sensor: SensorID(rawBytes: [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01])
        )
        let bytes = try serialize(reading)
        #expect(bytes.count == 5 + (timestamp == nil ? 0 : 8) + 18 + 6)
        // Version 0001, unit 10, timestamp flag, reserved 0.
        #expect(Array(bytes.prefix(3)) == [0x53, 0x52, 0b0001_1000 | (timestamp == nil ? 0 : 0b10)])
        let parsed = try parseReading(bytes.span.bytes)
        #expect(parsed.version == reading.version && parsed.unit == reading.unit && parsed.timestamp == reading.timestamp)
        #expect(parsed.samples == reading.samples && parsed.sensor == reading.sensor)
        // Truncated anywhere: `.truncated`. A bad unit (3): `.malformed`.
        for length in [0, 4, 7, bytes.count - 1] {
            #expect(throws: ReadingError.truncated) { try parseReading(bytes.span.bytes.extracting(first: length)) }
        }
        var badUnit = bytes
        badUnit[2] |= 0b0000_1100
        #expect(throws: ReadingError.malformed) { try parseReading(badUnit.span.bytes) }
    }
}

// MARK: - Byte groups

@Suite struct ByteGroupTests {
    @Test func literalAndByteOrder() {
        let signature: Byte4 = [0x50, 0x4B, 0x03, 0x04]
        #expect(signature.littleEndian == 0x0403_4B50)
        #expect(signature.bigEndian == 0x504B_0304)
        #expect(signature[0] == 0x50)
        #expect(signature.description == "50 4B 03 04")
        #expect(Byte4(littleEndian: 0x0403_4B50) == signature)
        #expect(Byte4(bigEndian: 0x504B_0304) == signature)

        let three: Byte3 = [0x01, 0x02, 0x03]
        #expect(three.littleEndian == 0x03_0201)
        #expect(three.bigEndian == 0x01_0203)
        #expect(Byte3(bigEndian: 0xFF01_0203) == three) // The extra high byte is discarded.
        #expect(Byte3(0x01_0203, .bigEndian) == three)
        #expect(three.integer(.bigEndian) == 0x01_0203)

        let sixteen = Byte16(littleEndian: 0x0F0E_0D0C_0B0A_0908_0706_0504_0302_0100)
        #expect(sixteen[15] == 0x0F)
        #expect(sixteen.bigEndian == 0x0001_0203_0405_0607_0809_0A0B_0C0D_0E0F)
    }

    @Test(arguments: [false, true])
    func everyWidth(aligned: Bool) throws {
        let data = randomBytes(64)
        let reference = ReferenceStream(bytes: data, order: .mostSignificantFirst)
        try check(Byte2.self, data, reference, aligned)
        try check(Byte3.self, data, reference, aligned)
        try check(Byte4.self, data, reference, aligned)
        try check(Byte5.self, data, reference, aligned)
        try check(Byte6.self, data, reference, aligned)
        try check(Byte7.self, data, reference, aligned)
        try check(Byte8.self, data, reference, aligned)
        try check(Byte9.self, data, reference, aligned)
        try check(Byte10.self, data, reference, aligned)
        try check(Byte11.self, data, reference, aligned)
        try check(Byte12.self, data, reference, aligned)
        try check(Byte13.self, data, reference, aligned)
        try check(Byte14.self, data, reference, aligned)
        try check(Byte15.self, data, reference, aligned)
        try check(Byte16.self, data, reference, aligned)
    }

    /// Reads `T` at every offset where it fits (ending exactly at the last byte, too), aligned or 3 bits in.
    func check<T: ByteGroup>(_: T.Type, _ data: [UInt8], _ reference: ReferenceStream, _ aligned: Bool) throws {
        let bitShift = aligned ? 0 : 3
        for start in 0...(data.count - T.byteCount - (aligned ? 0 : 1)) {
            var reader = Bytes(data.span)
            try reader.skip(bitCount: start * 8 + bitShift)
            let value = try reader.read(T.self)
            let expected = reference.bytes(T.byteCount, from: start * 8 + bitShift)
            #expect(UInt128(value.littleEndian) == expected, "\(T.self) at \(start)")
            #expect(reader.byteOffset == start + T.byteCount)
            #expect(reader.bitOffset == bitShift)
        }
        // One byte short: throws without consuming.
        var reader = Bytes(data.span)
        try reader.skip(byteCount: data.count - T.byteCount + 1)
        #expect(throws: BytesError.insufficientData) { try reader.read(T.self) }
        #expect(reader.byteOffset == data.count - T.byteCount + 1)
    }
}

// MARK: - Reading bits

@Suite struct BitReadingTests {
    @Test(arguments: [BitOrder.mostSignificantFirst, .leastSignificantFirst])
    func mixedFieldsMatchReference(order: BitOrder) throws {
        let data = randomBytes(257)
        let reference = ReferenceStream(bytes: data, order: order)
        var reader = Bytes(data.span, bitOrder: order)
        var position = 0
        // Cycle through the widths so each is read at many bit offsets, up to the stream's end.
        let widths = [1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 16, 17, 24, 31, 32, 33, 48, 57, 58, 63, 64, 0]
        var step = 0
        while true {
            let width = widths[step % widths.count]
            step += 1
            guard reader.remainingBitCount >= width else { break }
            let expected = reference.bits(width, from: position)
            let actual: UInt64 = switch width {
            case 1: UInt64(try reader.read(Bit.self))
            case 2: UInt64(try reader.read(Crumb.self))
            case 3: UInt64(try reader.read(Bits<3>.self))
            case 4: UInt64(try reader.read(Nibble.self))
            case 5: UInt64(try reader.read(Bits<5>.self))
            case 6: UInt64(try reader.read(Bits<6>.self))
            case 7: UInt64(try reader.read(Bits<7>.self))
            case 8: UInt64(try reader.read(Byte.self))
            default: try reader.read(bitCount: width)
            }
            #expect(actual == expected, "\(width) bits at bit \(position)")
            position += width
            #expect(reader.byteOffset == position / 8 && reader.bitOffset == position % 8)
        }
        #expect(reader.remainingBitCount == data.count * 8 - position)
        let tooMany = reader.remainingBitCount + 1
        #expect(throws: BytesError.insufficientData) { try reader.read(bitCount: tooMany) }
    }

    @Test func msbFirstExample() throws {
        // 0b1011_0010, 0b0111_1111
        let data: [UInt8] = [0xB2, 0x7F]
        var reader = Bytes(data.span)
        #expect(try reader.read(Bit.self) == 1)
        #expect(try reader.read(Bits<3>.self) == 0b011)
        #expect(try reader.read(Nibble.self) == 0b0010)
        #expect(reader.bitOffset == 0)
        #expect(try reader.read(Crumb.self) == 0b01)
        #expect(try reader.read(bitCount: 6) == 0b11_1111)
        #expect(reader.remainingBitCount == 0)
    }

    @Test func lsbFirstExample() throws {
        // DEFLATE-style: BFINAL (1 bit), then BTYPE (2 bits), read from bit 0 up.
        let data: [UInt8] = [0b0000_0011, 0xFF]
        var reader = Bytes(data.span, bitOrder: .leastSignificantFirst)
        #expect(try reader.read(Bit.self) == 1)
        #expect(try reader.read(Crumb.self) == 0b01)
        reader.alignToByte()
        #expect(try reader.read(Byte.self) == 0xFF)
    }

    @Test func unalignedByteGroupsInBothOrders() throws {
        let data: [UInt8] = [0xAB, 0xCD, 0xEF]
        var msb = Bytes(data.span)
        try msb.skip(bitCount: 4)
        #expect(try msb.read(Byte2.self) == [0xBC, 0xDE])
        var lsb = Bytes(data.span, bitOrder: .leastSignificantFirst)
        try lsb.skip(bitCount: 4)
        #expect(try lsb.read(Byte2.self) == [0xDA, 0xFC])
    }
}

// MARK: - Cursor

@Suite struct CursorTests {
    @Test func zipStyleHeader() throws {
        let header: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x08, 0x08, 0x03, 0x00, 0x41, 0x42]
        var reader = Bytes(header.span)
        try reader.expect([0x50, 0x4B, 0x03, 0x04] as Byte4)
        #expect(try reader.read(Byte2.self, .littleEndian) == 20)
        #expect(try reader.peek(Byte2.self, .littleEndian) == 0x0808)
        #expect(try reader.read(Byte2.self, .bigEndian) == 0x0808)
        #expect(try reader.read(Byte2.self, .littleEndian) == 3)
        let name = try reader.read(byteCount: 2)
        let atEnd = reader.isAtEnd // `#expect` can't inspect properties of a ~Copyable, ~Escapable value.
        #expect(name.byteCount == 2 && atEnd)
        #expect(throws: BytesError.insufficientData) { try reader.read(Byte2.self) }
    }

    @Test func expectMismatchConsumesNothing() throws {
        let data: [UInt8] = [1, 2, 3, 4]
        var reader = Bytes(data.span)
        #expect(throws: BytesError.mismatch) { try reader.expect([1, 2, 3, 5] as Byte4) }
        #expect(reader.byteOffset == 0)
        #expect(throws: BytesError.mismatch) { try reader.expect(Nibble(1)) }
        try reader.expect(Nibble(0))
        #expect(reader.bitOffset == 4)
    }

    @Test func positioning() throws {
        let data = randomBytes(10)
        var reader = Bytes(data.span)
        try reader.skip(bitCount: 3)
        #expect(reader.remainingByteCount == 9)
        #expect(reader.remainingBytes.byteCount == 9)
        try reader.skip(byteCount: 9) // 3 bits into the last byte.
        let atEnd = reader.isAtEnd
        #expect(!atEnd && reader.remainingBitCount == 5)
        #expect(throws: BytesError.insufficientData) { try reader.skip(byteCount: 1) }
        reader.alignToByte()
        let alignedAtEnd = reader.isAtEnd
        #expect(alignedAtEnd)
        try reader.seek(toByteOffset: 4)
        #expect(try reader.read(Byte.self).rawValue == data[4])
        #expect(throws: BytesError.insufficientData) { try reader.seek(toByteOffset: 11) }
    }
}

// MARK: - ByteRepresentable

/// A custom type backed by `n` raw bytes, like an IPv4 (4), MAC (6), or IPv6 (16) address.
struct RawBytes<let n: Int>: ByteRepresentable, Equatable {
    var rawBytes: InlineArray<n, UInt8>
    init(rawBytes: InlineArray<n, UInt8>) { self.rawBytes = rawBytes }
    var array: [UInt8] { (0..<n).map { rawBytes[$0] } }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.array == rhs.array }
}

@Suite struct ByteRepresentableTests {
    // Every load path: integer sizes (bitCast), odd sizes from overlapping loads, and the default.
    @Test func everySize() throws {
        let data = randomBytes(203)
        try check(RawBytes<1>.self, data); try check(RawBytes<2>.self, data); try check(RawBytes<3>.self, data)
        try check(RawBytes<4>.self, data); try check(RawBytes<5>.self, data); try check(RawBytes<6>.self, data)
        try check(RawBytes<7>.self, data); try check(RawBytes<8>.self, data); try check(RawBytes<9>.self, data)
        try check(RawBytes<12>.self, data); try check(RawBytes<15>.self, data); try check(RawBytes<16>.self, data)
        try check(RawBytes<17>.self, data); try check(RawBytes<20>.self, data)
    }

    func check<let n: Int>(_: RawBytes<n>.Type, _ data: [UInt8]) throws {
        for bitShift in [0, 3] {
            let reference = ReferenceStream(bytes: data, order: .mostSignificantFirst)
            func expected(_ index: Int) -> [UInt8] {
                (0..<n).map { UInt8(reference.bits(8, from: bitShift + 8 * (index * n + $0))) }
            }
            let count = (data.count * 8 - bitShift) / 8 / n

            // Single reads and peeks.
            var reader = Bytes(data.span)
            try reader.skip(bitCount: bitShift)
            for index in 0..<count {
                let peeked = try reader.peek(RawBytes<n>.self)
                let value = try reader.read(RawBytes<n>.self)
                #expect(value.array == expected(index) && peeked == value, "RawBytes<\(n)> #\(index) shifted \(bitShift)")
            }
            #expect(throws: BytesError.insufficientData) { try reader.read(RawBytes<n>.self) }

            // forEach.
            var iterated: [RawBytes<n>] = []
            var each = Bytes(data.span)
            try each.skip(bitCount: bitShift)
            each.forEach(RawBytes<n>.self) { iterated.append($0) }
            #expect(iterated.map(\.array) == (0..<count).map(expected), "forEach RawBytes<\(n)> shifted \(bitShift)")
            #expect(each.byteOffset == reader.byteOffset && each.bitOffset == reader.bitOffset)

            // Bulk.
            var bulk = Bytes(data.span)
            try bulk.skip(bitCount: bitShift)
            let values = try [RawBytes<n>](capacity: count) { try bulk.read(RawBytes<n>.self, into: &$0) }
            #expect(values == iterated, "bulk RawBytes<\(n)> shifted \(bitShift)")
            #expect(bulk.byteOffset == reader.byteOffset)
        }
    }
}

// MARK: - ConvertibleFromBytes

@Suite struct ConvertibleFromBytesTests {
    @Test func loads() throws {
        let data = randomBytes(64)
        var reader = Bytes(data.span)
        try reader.skip(byteCount: 1) // Unaligned for everything below.
        let float = try reader.load(Float.self)
        #expect(float.bitPattern == UInt32(data[1]) | UInt32(data[2]) << 8 | UInt32(data[3]) << 16 | UInt32(data[4]) << 24)
        let vector = try reader.load(SIMD4<UInt8>.self)
        #expect(vector == SIMD4(data[5], data[6], data[7], data[8]))
        let address = try reader.load(InlineArray<4, UInt8>.self)
        #expect((0..<4).map { address[$0] } == Array(data[9..<13]))
        #expect(try reader.peekLoad(Double.self).bitPattern == (try reader.read(Byte8.self)).littleEndian)

        // Mid-byte: each byte is the next 8 bits.
        var shifted = Bytes(data.span)
        try shifted.skip(bitCount: 4)
        let expected = try { () throws(BytesError) -> UInt32 in
            var copy = Bytes(data.span)
            try copy.skip(bitCount: 4)
            return try copy.read(Byte4.self, .littleEndian)
        }()
        #expect(try shifted.load(UInt32.self) == expected)
        #expect(throws: BytesError.insufficientData) {
            var short = Bytes(data.span)
            try short.skip(byteCount: 60)
            _ = try short.load(Double.self)
        }
    }

    @Test func zeroCopySpans() throws {
        let data = randomBytes(101)
        var reader = Bytes(data.span)
        try reader.skip(byteCount: 1)
        // Alignment 1: viewable at any offset.
        let addresses = try reader.read(InlineArray<4, UInt8>.self, count: 25)
        #expect(addresses.count == 25 && reader.byteOffset == 101)
        for index in addresses.indices {
            #expect((0..<4).map { addresses[index][$0] } == Array(data[1 + 4 * index ..< 5 + 4 * index]))
        }
        var iterated = 0
        for address in addresses { iterated += Int(address[0]) }
        #expect(iterated == (0..<25).reduce(0) { $0 + Int(data[1 + 4 * $1]) })
        #expect(throws: BytesError.insufficientData) { try reader.read(UInt8.self, count: 1) }

        // Alignment 4: viewable only where the memory is aligned; nothing consumed otherwise.
        let words: [UInt32] = (0..<16).map { $0 &* 0x0101_0101 } // An array of UInt32 is 4-byte aligned.
        var aligned = Bytes(words.span.bytes)
        let view = try aligned.read(UInt32.self, count: 16)
        #expect(Array(0..<16).map { view[$0] } == words)
        var misaligned = Bytes(words.span.bytes)
        try misaligned.skip(byteCount: 1)
        #expect(throws: BytesError.misaligned) { try misaligned.read(UInt32.self, count: 2) }
        #expect(misaligned.byteOffset == 1)
    }
}

// MARK: - Writing

/// One write and the read that must get it back.
struct RoundTrip {
    let write: (inout BytesWriter) throws(BytesError) -> Void
    let verify: (inout Bytes) throws(BytesError) -> Bool
}

/// A random but reproducible sequence of mixed writes.
func randomRoundTrips(count: Int, seed: UInt64) -> [RoundTrip] {
    var state = seed
    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    func group<T: ByteGroup>(_: T.Type, _ value: UInt64, _ order: ByteOrder) -> RoundTrip {
        let mask = T.Integer.max >> (T.Integer.bitWidth - 8 * T.byteCount)
        let integer = T.Integer(truncatingIfNeeded: UInt128(value) << 64 | UInt128(value &* 31)) & mask
        return RoundTrip { (w: inout BytesWriter) throws(BytesError) in try w.write(integer, as: T.self, order) }
            verify: { (r: inout Bytes) throws(BytesError) in try r.read(T.self, order) == integer }
    }
    func bits<let width: Int>(_: Bits<width>.Type, _ value: UInt64) -> RoundTrip {
        let bits = Bits<width>(truncatingIfNeeded: value)
        return RoundTrip { (w: inout BytesWriter) throws(BytesError) in try w.write(bits) }
            verify: { (r: inout Bytes) throws(BytesError) in try r.read(Bits<width>.self) == bits }
    }
    return (0..<count).map { _ in
        let value = next()
        let order: ByteOrder = value & 1 == 0 ? .littleEndian : .bigEndian
        switch next() % 16 {
        case 0: return bits(Bits<1>.self, value)
        case 1: return bits(Bits<3>.self, value)
        case 2: return bits(Bits<4>.self, value)
        case 3: return bits(Bits<5>.self, value)
        case 4: return bits(Bits<8>.self, value)
        case 5:
            let count = Int(value % 65)
            let masked = count == 64 ? value : value & ((1 << UInt64(count)) - 1)
            return RoundTrip { (w: inout BytesWriter) throws(BytesError) in try w.write(masked, bitCount: count) }
                verify: { (r: inout Bytes) throws(BytesError) in try r.read(bitCount: count) == masked }
        case 6: return group(Byte2.self, value, order)
        case 7: return group(Byte3.self, value, order)
        case 8: return group(Byte4.self, value, order)
        case 9: return group(Byte6.self, value, order)
        case 10: return group(Byte8.self, value, order)
        case 11: return group(Byte9.self, value, order)
        case 12: return group(Byte13.self, value, order)
        case 13: return group(Byte16.self, value, order)
        case 14:
            let address = RawBytes<6>(rawBytes: InlineArray { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
            return RoundTrip { (w: inout BytesWriter) throws(BytesError) in try w.write(address) }
                verify: { (r: inout Bytes) throws(BytesError) in try r.read(RawBytes<6>.self) == address }
        default:
            let float = Float(bitPattern: UInt32(truncatingIfNeeded: value))
            return RoundTrip { (w: inout BytesWriter) throws(BytesError) in try w.store(float) }
                verify: { (r: inout Bytes) throws(BytesError) in try r.load(Float.self).bitPattern == float.bitPattern }
        }
    }
}

@Suite struct WriterTests {
    @Test(arguments: [BitOrder.mostSignificantFirst, .leastSignificantFirst])
    func roundTripsMixedWrites(order: BitOrder) throws {
        for seed: UInt64 in 1...20 {
            let trips = randomRoundTrips(count: 200, seed: seed)
            var buffer = [UInt8](repeating: 0xEE, count: 200 * 17)
            var mutable = buffer.mutableSpan
            var writer = BytesWriter(&mutable, bitOrder: order)
            for trip in trips { try trip.write(&writer) }
            let written = writer.byteCount
            _ = consume writer
            var reader = Bytes(buffer.span.extracting(first: written), bitOrder: order)
            for (index, trip) in trips.enumerated() {
                #expect(try trip.verify(&reader), "seed \(seed), write \(index)")
            }
            #expect(reader.remainingBitCount < 8) // Only the padding of the last byte is left.
            _ = buffer // Keep `buffer` alive and unmodified until here.
        }
    }

    @Test func neverWritesPastTheCursor() throws {
        // Odd widths and partial-byte bit writes must leave the bytes after the cursor alone.
        for skip in 0..<9 {
            var buffer = [UInt8](repeating: 0xEE, count: 64)
            var mutable = buffer.mutableSpan
            var writer = BytesWriter(&mutable)
            try writer.write(UInt64(0), bitCount: skip)
            try writer.write(0x0102_03, as: Byte3.self, .bigEndian)
            try writer.write(0x0102_0304_0506_0708_090A_0B, as: Byte11.self, .bigEndian)
            try writer.write(Bits<5>(0b10101))
            let end = writer.byteCount
            _ = consume writer
            #expect(buffer[end...].allSatisfy { $0 == 0xEE }, "after skipping \(skip) bits")
        }
    }

    @Test func throwingWritesWriteNothing() throws {
        var buffer = [UInt8](repeating: 0xEE, count: 5)
        var mutable = buffer.mutableSpan
        var writer = BytesWriter(&mutable)
        try writer.write(Bits<3>(0b101))
        #expect(throws: BytesError.insufficientCapacity) { try writer.write(0, as: Byte8.self, .littleEndian) }
        #expect(throws: BytesError.insufficientCapacity) { try writer.write(0, bitCount: 38) }
        #expect(writer.byteOffset == 0 && writer.bitOffset == 3)
        try writer.write(0, bitCount: 37) // Exactly fills the 5 bytes.
        #expect(writer.remainingBitCount == 0)
        #expect(throws: BytesError.insufficientCapacity) { try writer.write(Bit(1)) }
        _ = consume writer
        #expect(buffer == [0b1010_0000, 0, 0, 0, 0])
    }

    @Test func outputSpanCommitsOnlyWhatIsWritten() throws {
        let bytes = try [UInt8](capacity: 16) { output in
            output.append(0xAA)
            try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                try writer.write([0x50, 0x4B, 0x03, 0x04] as Byte4)
                try writer.write(Nibble(0b1100)) // A partial byte counts as written.
            }
            struct Stop: Error {}
            #expect(throws: Stop.self) {
                try output.withBytesWriter { (writer: inout BytesWriter) throws(Stop) in
                    try? writer.write(Byte(0xFF))
                    throw Stop()
                }
            }
        }
        #expect(bytes == [0xAA, 0x50, 0x4B, 0x03, 0x04, 0b1100_0000])
    }

    @Test func bulkWrites() throws {
        let values: [UInt32] = (0..<101).map { $0 &* 0x0102_0305 }
        for order in [ByteOrder.littleEndian, .bigEndian] {
            for shift in [0, 3] {
                let bytes = try [UInt8](capacity: 410) { output in
                    try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                        try writer.write(UInt64(0), bitCount: shift)
                        try writer.write(values.span, as: Byte3.self, order)
                    }
                }
                var reader = Bytes(bytes.span)
                try reader.skip(bitCount: shift)
                for value in values {
                    #expect(try reader.read(Byte3.self, order) == value & 0xFF_FFFF)
                }
            }
        }
        // Bulk bits, every width, both orders, aligned and not, with tails: must match single writes.
        func checkBits<let width: Int>(_: Bits<width>.Type) throws {
            let values = randomBytes(203).map { Bits<width>(truncatingIfNeeded: $0) }
            for order in [BitOrder.mostSignificantFirst, .leastSignificantFirst] {
                for shift in [0, 3] {
                    func written(bulk: Bool) throws -> [UInt8] {
                        try [UInt8](capacity: 204) { output in // 203 values of up to 8 bits, plus 3 bits.
                            try output.withBytesWriter(bitOrder: order) { (writer: inout BytesWriter) throws(BytesError) in
                                try writer.write(UInt64(0b101), bitCount: shift)
                                if bulk {
                                    try writer.write(values.span)
                                } else {
                                    for value in values { try writer.write(value) }
                                }
                            }
                        }
                    }
                    #expect(try written(bulk: true) == written(bulk: false), "Bits<\(width)> \(order) shifted \(shift)")
                }
            }
        }
        try checkBits(Bits<1>.self); try checkBits(Bits<2>.self); try checkBits(Bits<3>.self); try checkBits(Bits<4>.self)
        try checkBits(Bits<5>.self); try checkBits(Bits<6>.self); try checkBits(Bits<7>.self); try checkBits(Bits<8>.self)

        let addresses = (0..<50).map { i in RawBytes<4>(rawBytes: InlineArray { UInt8(truncatingIfNeeded: i * 4 + $0) }) }
        let bytes = try [UInt8](capacity: 200) { output in
            try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in try writer.write(addresses.span) }
        }
        #expect(bytes == (0..<200).map { UInt8(truncatingIfNeeded: $0) })
    }
}

// MARK: - Bulk operations

@Suite struct BulkTests {
    @Test(arguments: [ByteOrder.littleEndian, .bigEndian])
    func decodeRuns(order: ByteOrder) throws {
        let data = randomBytes(1_001)
        try check(Byte2.self, data, order)
        try check(Byte3.self, data, order)
        try check(Byte4.self, data, order)
        try check(Byte8.self, data, order)
        try check(Byte16.self, data, order)
    }

    func check<T: ByteGroup>(_: T.Type, _ data: [UInt8], _ order: ByteOrder) throws {
        for bitShift in [0, 5] {
            let count = (data.count - 1) / T.byteCount
            var reader = Bytes(data.span)
            try reader.skip(bitCount: bitShift)
            let values = try [T.Integer](capacity: count) { output in
                try reader.read(T.self, order, into: &output)
            }
            var scalar = Bytes(data.span)
            try scalar.skip(bitCount: bitShift)
            for value in values {
                #expect(value == (try scalar.read(T.self, order)))
            }
            #expect(reader.byteOffset == scalar.byteOffset)
        }
        // Asking for one more than fits throws without consuming.
        var short = Bytes(data.span)
        #expect(throws: BytesError.insufficientData) {
            _ = try [T.Integer](capacity: data.count / T.byteCount + 1) { try short.read(T.self, order, into: &$0) }
        }
        #expect(short.byteOffset == 0)
    }

    @Test func forEachGroupsMatchReads() throws {
        let data = randomBytes(1_000)
        for shift in [0, 5] {
            try checkForEach(Byte2.self, data, shift); try checkForEach(Byte3.self, data, shift)
            try checkForEach(Byte4.self, data, shift); try checkForEach(Byte5.self, data, shift)
            try checkForEach(Byte6.self, data, shift); try checkForEach(Byte7.self, data, shift)
            try checkForEach(Byte8.self, data, shift); try checkForEach(Byte9.self, data, shift)
            try checkForEach(Byte10.self, data, shift); try checkForEach(Byte11.self, data, shift)
            try checkForEach(Byte12.self, data, shift); try checkForEach(Byte13.self, data, shift)
            try checkForEach(Byte14.self, data, shift); try checkForEach(Byte15.self, data, shift)
            try checkForEach(Byte16.self, data, shift)
        }
    }

    func checkForEach<T: ByteGroup>(_: T.Type, _ data: [UInt8], _ bitShift: Int) throws {
        var reader = Bytes(data.span)
        try reader.skip(bitCount: bitShift)
        var values: [T] = []
        reader.forEach(T.self) { values.append($0) }
        var scalar = Bytes(data.span)
        try scalar.skip(bitCount: bitShift)
        var expected: [T] = []
        while scalar.remainingByteCount >= T.byteCount { expected.append(try scalar.read(T.self)) }
        #expect(values == expected, "\(T.self) shifted \(bitShift)")
        #expect(reader.byteOffset == scalar.byteOffset && reader.bitOffset == scalar.bitOffset)
        for value in values {
            // Big-endian, the slow way: the first byte is the most significant.
            var bigEndian: UInt128 = 0
            for index in 0..<T.byteCount { bigEndian = bigEndian << 8 | UInt128(value[index]) }
            #expect(UInt128(value.bigEndian) == bigEndian, "\(T.self).bigEndian")
            #expect(T(bigEndian: value.bigEndian) == value)
        }
    }

    @Test(arguments: [BitOrder.mostSignificantFirst, .leastSignificantFirst])
    func forEachBitsMatchReads(order: BitOrder) throws {
        let data = randomBytes(203) // Not a multiple of any block size, so the tail path runs too.
        for shift in [0, 3] {
            try checkForEach(Bits<1>.self, data, order, shift); try checkForEach(Bits<2>.self, data, order, shift)
            try checkForEach(Bits<3>.self, data, order, shift); try checkForEach(Bits<4>.self, data, order, shift)
            try checkForEach(Bits<5>.self, data, order, shift); try checkForEach(Bits<6>.self, data, order, shift)
            try checkForEach(Bits<7>.self, data, order, shift); try checkForEach(Bits<8>.self, data, order, shift)
        }
    }

    func checkForEach<let width: Int>(_: Bits<width>.Type, _ data: [UInt8], _ order: BitOrder, _ bitShift: Int) throws {
        var reader = Bytes(data.span, bitOrder: order)
        try reader.skip(bitCount: bitShift)
        var values: [Bits<width>] = []
        reader.forEach(Bits<width>.self) { values.append($0) }
        var scalar = Bytes(data.span, bitOrder: order)
        try scalar.skip(bitCount: bitShift)
        var expected: [Bits<width>] = []
        while scalar.remainingBitCount >= width { expected.append(try scalar.read(Bits<width>.self)) }
        #expect(values == expected, "Bits<\(width)> \(order) shifted \(bitShift)")
        #expect(reader.byteOffset == scalar.byteOffset && reader.bitOffset == scalar.bitOffset)
    }

    @Test func forInBytes() throws {
        let data = randomBytes(1_000)
        var reader = Bytes(data.span)
        try reader.skip(bitCount: 13) // Iteration starts at the next whole byte: offset 2.
        var bytes: [UInt8] = []
        for byte in reader { bytes.append(byte) }
        #expect(bytes == Array(data[2...]))
        #expect(reader.byteOffset == 1 && reader.bitOffset == 5) // Not consumed.
    }

    @Test func forInValues() throws {
        let data = randomBytes(1_037)
        for shift in [0, 5] {
            try checkForIn(Byte2.self, data, shift); try checkForIn(Byte3.self, data, shift)
            try checkForIn(Byte4.self, data, shift); try checkForIn(Byte7.self, data, shift)
            try checkForIn(Byte8.self, data, shift); try checkForIn(Byte12.self, data, shift)
            try checkForIn(Byte16.self, data, shift)
            for order in [BitOrder.mostSignificantFirst, .leastSignificantFirst] {
                try checkForIn(Bits<1>.self, data, order, shift); try checkForIn(Bits<3>.self, data, order, shift)
                try checkForIn(Bits<4>.self, data, order, shift); try checkForIn(Bits<6>.self, data, order, shift)
                try checkForIn(Bits<8>.self, data, order, shift)
            }
        }
    }

    func checkForIn<T: ByteGroup>(_: T.Type, _ data: [UInt8], _ bitShift: Int) throws {
        for byteOrder in [ByteOrder.littleEndian, .bigEndian] {
            var reader = Bytes(data.span)
            try reader.skip(bitCount: bitShift)
            var iterated: [T.Integer] = []
            let values = reader.values(of: T.self, byteOrder) // Swift 6.4 can't loop over the temporary.
            for value in values { iterated.append(value) }
            #expect(reader.byteOffset == bitShift / 8 && reader.bitOffset == bitShift % 8) // Not consumed.
            let underestimatedCount = values.underestimatedCount
            var expected: [T.Integer] = []
            reader.forEach(T.self) { expected.append($0.integer(byteOrder)) } // Consumes.
            #expect(iterated == expected, "\(T.self) \(byteOrder) shifted \(bitShift)")
            #expect(underestimatedCount == expected.count)
        }
    }

    func checkForIn<let width: Int>(_: Bits<width>.Type, _ data: [UInt8], _ order: BitOrder, _ bitShift: Int) throws {
        var reader = Bytes(data.span, bitOrder: order)
        try reader.skip(bitCount: bitShift)
        var iterated: [Bits<width>] = []
        let values = reader.values(of: Bits<width>.self)
        for value in values { iterated.append(value) }
        // Small, odd chunks (not multiples of 8), through the iterator directly.
        var chunked: [Bits<width>] = []
        let view = reader.values(of: Bits<width>.self)
        var iterator = view.makeBorrowingIterator()
        while true {
            let span = iterator.nextSpan(maxCount: 5)
            if span.isEmpty { break }
            for index in span.indices { chunked.append(span[index]) }
        }
        var expected: [Bits<width>] = []
        reader.forEach(Bits<width>.self) { expected.append($0) }
        #expect(iterated == expected, "Bits<\(width)> \(order) shifted \(bitShift)")
        #expect(chunked == expected, "Bits<\(width)> \(order) shifted \(bitShift), chunks of 5")
    }

    struct Stop: Error {}

    @Test func forEachStopsWhereBodyThrows() throws {
        let data = randomBytes(100)
        var groups = Bytes(data.span)
        var seen = 0
        #expect(throws: Stop.self) {
            try groups.forEach(Byte4.self) { _ throws(Stop) in
                seen += 1
                if seen == 5 { throw Stop() }
            }
        }
        #expect(groups.byteOffset == 20) // Consumed through the fifth value.

        var bits = Bytes(data.span)
        seen = 0
        #expect(throws: Stop.self) {
            try bits.forEach(Bits<3>.self) { _ throws(Stop) in
                seen += 1
                if seen == 11 { throw Stop() }
            }
        }
        #expect(bits.byteOffset == 33 / 8 && bits.bitOffset == 33 % 8) // 11 values of 3 bits.
    }

    /// Positions where `pattern` starts in `data`, scanning `range` in its order.
    func naive(_ pattern: [UInt8], in data: [UInt8], _ range: some Sequence<Int>) -> Int? {
        range.first { start in
            start + pattern.count <= data.count && (0..<pattern.count).allSatisfy { data[start + $0] == pattern[$0] }
        }
    }

    @Test func search() {
        // Plant the pattern at the start, at 16-byte block edges, and at the very end. The noise around
        // it often matches the pattern's first and last bytes, exercising the full-compare fallback.
        var data = randomBytes(300).map { $0 % 4 == 0 ? 0x50 : $0 }
        let pattern: Byte4 = [0x50, 0x4B, 0x05, 0x50]
        let bytes = (0..<4).map { pattern[$0] }
        for plant in [0, 15, 16, 31, 133, 296] {
            for index in 0..<4 { data[plant + index] = bytes[index] }
        }
        for skip in [0, 1, 17, 200, 297] {
            var reader = Bytes(data.span)
            try? reader.skip(byteCount: skip)
            #expect(reader.firstByteOffset(of: pattern) == naive(bytes, in: data, skip..<data.count), "first from \(skip)")
            #expect(reader.lastByteOffset(of: pattern) == naive(bytes, in: data, (skip..<data.count).reversed()), "last from \(skip)")
        }
        let wide: Byte16 = Byte16(littleEndian: 0x50)
        let wideBytes = (0..<16).map { wide[$0] }
        #expect(Bytes(data.span).firstByteOffset(of: wide) == naive(wideBytes, in: data, 0..<data.count))
        let short: [UInt8] = [1, 2]
        #expect(Bytes(short.span).lastByteOffset(of: pattern) == nil)
        #expect(Bytes(short.span).firstByteOffset(of: pattern) == nil)
    }
}
