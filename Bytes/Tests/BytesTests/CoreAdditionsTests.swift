import Bytes
import BytesTestSupport
import Testing

/// Errors through the builders' closures, with payloads, to check that the exact error comes back
/// (swiftlang/swift#90291: a typed-throws closure passed to an untyped `rethrows` API threw a box as the error).
@Suite struct TypedErrorPassthroughTests {
    struct Payload: Error, Equatable {
        let code: Int
        let text: String
    }

    @Test func stringBuilderThrowsTheBodysError() {
        let expected = Payload(code: 0x1234_5678, text: "a payload long enough to need storage")
        do {
            _ = try String(utf8Capacity: 32) { writer throws(Payload) in
                try? writer.write(0x41 as Byte)
                throw expected
            }
            Issue.record("No error")
        } catch {
            #expect(error == expected)
        }
    }

    @Test func stringBuilderThrowsBytesError() {
        #expect(throws: BytesError.insufficientCapacity) {
            _ = try String(utf8Capacity: 2) { writer throws(BytesError) in
                try writer.write(0x41_42_43 as Byte3)
            }
        }
    }

    @Test func stringBuilderWithoutAnError() throws {
        let text = try String(utf8Capacity: 8) { writer throws(Payload) in
            try? writer.write(0x41_42_43 as Byte3)
        }
        #expect(text == "ABC")
    }
}

/// Sub-byte writes (the fast path for widths that divide a byte, and the general one), against a writer that sets one
/// bit at a time.
@Suite struct SubByteWriteTests {
    /// The bytes that `fields` (value, width) make in `order`, bit by bit; bits after the last are zero.
    static func reference(_ fields: [(UInt8, Int)], order: BitOrder) -> [UInt8] {
        var bits: [Bool] = []
        for (value, width) in fields {
            for index in 0..<width {
                let shift = order == .mostSignificantFirst ? width - 1 - index : index
                bits.append(value >> shift & 1 == 1)
            }
        }
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (index, bit) in bits.enumerated() where bit {
            let shift = order == .mostSignificantFirst ? 7 - index % 8 : index % 8
            bytes[index / 8] |= 1 << shift
        }
        return bytes
    }

    static func write(_ value: UInt8, width: Int, to writer: inout BytesWriter) throws(BytesError) {
        switch width {
        case 1: try writer.write(Bits<1>(truncatingIfNeeded: value))
        case 2: try writer.write(Bits<2>(truncatingIfNeeded: value))
        case 3: try writer.write(Bits<3>(truncatingIfNeeded: value))
        case 4: try writer.write(Bits<4>(truncatingIfNeeded: value))
        case 5: try writer.write(Bits<5>(truncatingIfNeeded: value))
        default: try writer.write(Bits<8>(truncatingIfNeeded: value))
        }
    }

    @Test(arguments: [BitOrder.mostSignificantFirst, .leastSignificantFirst])
    func mixedWidthsMatchBitByBit(order: BitOrder) throws {
        var random = SplitMix64(seed: 0x5EED)
        // Mostly the fast widths, sometimes widths that misalign them, so every bit offset is met.
        let widths = [1, 2, 4, 1, 2, 4, 3, 5, 8]
        for _ in 0..<300 {
            let count = Int.random(in: 0...40, using: &random)
            let fields = (0..<count).map { _ in
                let width = widths.randomElement(using: &random)!
                return (UInt8.random(in: 0...255, using: &random) & UInt8(truncatingIfNeeded: (1 << width) - 1), width)
            }
            let expected = Self.reference(fields, order: order)
            // Over bytes that start all ones: what isn't written as a value's bits must come out zero.
            var storage = [UInt8](repeating: 0xFF, count: expected.count + 2)
            var span = storage.mutableSpan
            var writer = BytesWriter(&span, bitOrder: order)
            for (value, width) in fields {
                try Self.write(value, width: width, to: &writer)
            }
            let written = writer.byteCount
            _ = consume writer
            #expect(written == expected.count)
            #expect(Array(storage[..<expected.count]) == expected, "\(fields)")
            #expect(storage[expected.count...].allSatisfy { $0 == 0xFF }, "wrote past the last byte")
        }
    }

    @Test(arguments: [1, 2, 4])
    func fullWriterThrowsAndKeepsItsState(width: Int) throws {
        for order in [BitOrder.mostSignificantFirst, .leastSignificantFirst] {
            var storage = [UInt8](repeating: 0xFF, count: 2)
            var span = storage.mutableSpan
            var writer = BytesWriter(&span, bitOrder: order)
            for index in 0..<(16 / width) {
                try Self.write(UInt8(truncatingIfNeeded: index), width: width, to: &writer)
            }
            let isFull = writer.isFull
            #expect(isFull)
            #expect(throws: BytesError.insufficientCapacity) { try Self.write(1, width: width, to: &writer) }
            let byteCount = writer.byteCount
            #expect(byteCount == 2)
            _ = consume writer
            let fields = (0..<(16 / width)).map { (UInt8(truncatingIfNeeded: $0) & UInt8((1 << width) - 1), width) }
            #expect(storage == Self.reference(fields, order: order))
        }
    }
}

/// The literal CRC-32 tables, against the definition.
@Suite struct CRC32TableTests {
    @Test func tablesMatchTheirDefinition() {
        let braids = 5 // `CRC32.braids`
        var single = [UInt32](repeating: 0, count: 256)
        for byte in 0..<256 {
            var crc = UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1
            }
            single[byte] = crc
        }
        var tables = [UInt32](repeating: 0, count: 16 * 256)
        for k in 0..<8 {
            for byte in 0..<256 {
                var crc = single[byte]
                for zeros in 1...(7 - k + 8 * (braids - 1)) {
                    crc = crc >> 8 ^ single[Int(crc & 0xFF)]
                    if zeros == 7 - k { tables[k * 256 + byte] = crc }
                }
                if k == 7 { tables[k * 256 + byte] = single[byte] }
                tables[(8 + k) * 256 + byte] = crc
            }
        }
        #expect(CRC32.tables.count == 16 * 256)
        #expect(CRC32.tables == tables)
        #expect(CRC32.tableChecksum([UInt8]("123456789".utf8).span.bytes) == 0xCBF4_3926)
    }
}

/// Hexadecimal text, both ways.
@Suite struct HexadecimalTests {
    static func reference(_ bytes: [UInt8], uppercase: Bool) -> String {
        let digits = Array((uppercase ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }

    @Test func roundTripsEveryLength() throws {
        var random = SplitMix64(seed: 16)
        for count in 0...70 {
            let bytes = random.bytes(count)
            for uppercase in [false, true] {
                let text = String(hexadecimal: bytes.span.bytes, uppercase: uppercase)
                #expect(text == Self.reference(bytes, uppercase: uppercase))
                #expect(try [UInt8](hexadecimal: text) == bytes)
                #expect(try [UInt8](hexadecimal: Array(text.utf8).span.bytes) == bytes)
            }
            // Mixed case decodes too.
            let mixed = String(hexadecimal: bytes.span.bytes).enumerated().map { $0.offset % 3 == 0 ? $0.element.uppercased() : String($0.element) }.joined()
            #expect(try [UInt8](hexadecimal: mixed[...]) == bytes)
        }
        #expect(String(hexadecimal: ([0x00, 0xFF, 0x7F, 0xA5] as [UInt8]).span.bytes) == "00ff7fa5")
    }

    @Test func everyByteThatIsntADigitIsRejectedAnywhere() {
        let valid = Array("0123456789abcdefABCDEF".utf8)
        for count in [2, 8, 16, 18, 32, 34] {
            var text = [UInt8](repeating: 0x61, count: count)
            for position in [0, count / 2, count - 1] {
                for byte in 0...255 where !valid.contains(UInt8(byte)) {
                    text[position] = UInt8(byte)
                    #expect(throws: BytesError.invalidValue) { _ = try [UInt8](hexadecimal: text.span.bytes) }
                }
                text[position] = 0x61
            }
            #expect((try? [UInt8](hexadecimal: text.span.bytes)) == [UInt8](repeating: 0xAA, count: count / 2))
        }
        #expect(throws: BytesError.invalidValue) { _ = try [UInt8](hexadecimal: "abc") }
    }

    @Test func writerChecksCapacityAndAlignment() throws {
        var storage = [UInt8](repeating: 0, count: 5)
        var span = storage.mutableSpan
        var writer = AlignedBytesWriter(&span)
        try writer.write(0x2A as Byte)
        #expect(throws: BytesError.insufficientCapacity) { try writer.write(hexadecimal: ([1, 2, 3] as [UInt8]).span.bytes) }
        try writer.write(hexadecimal: ([0xBE, 0xEF] as [UInt8]).span.bytes, uppercase: true)
        let byteCount = writer.byteCount
        #expect(byteCount == 5)
        _ = consume writer
        #expect(storage == Array("*BEEF".utf8))
    }
}

/// Octal digits, and decimal digits up to a limit, including fields that end exactly where the data does.
@Suite struct RadixDigitTests {
    @Test func octalFieldsOfEveryWidth() throws {
        var random = SplitMix64(seed: 8)
        for count in 1...21 {
            for _ in 0..<20 {
                let digits = (0..<count).map { _ in UInt8.random(in: 0x30...0x37, using: &random) }
                let expected = digits.reduce(UInt64(0)) { $0 << 3 | UInt64($1 - 0x30) }
                // Ending at the data's end, then followed by more bytes.
                for trailing in [0, 1, 7, 8] {
                    let data = digits + [UInt8](repeating: 0x20, count: trailing)
                    var reader = BytesReader(data.span)
                    #expect(try reader.read(UInt64.self, asciiOctalDigits: count) == expected, "\(count) + \(trailing)")
                    let remainingByteCount = reader.remainingByteCount
                    #expect(remainingByteCount == trailing)
                }
                // Starting mid-byte (the bit cursor's slow path).
                let shifted = BitWriterHelper.shiftedByNibble(digits)
                var reader = BytesReader(shifted.span)
                _ = try reader.read(Nibble.self)
                #expect(try reader.read(UInt64.self, asciiOctalDigits: count) == expected)
            }
        }
    }

    @Test func octalRejectsNonDigitsAndConsumesNothing() throws {
        for count in [1, 3, 8, 11, 16, 20] {
            for position in 0..<count {
                for bad: UInt8 in [0x38, 0x39, 0x2F, 0x20, 0x00, 0xB0] {
                    for trailing in [0, 8] {
                        var data = [UInt8](repeating: 0x37, count: count + trailing)
                        data[position] = bad
                        var reader = BytesReader(data.span)
                        #expect(throws: BytesError.invalidValue) { _ = try reader.read(UInt64.self, asciiOctalDigits: count) }
                        let remainingByteCount = reader.remainingByteCount
                        #expect(remainingByteCount == count + trailing)
                    }
                }
            }
        }
        let data = Array("777".utf8)
        var reader = BytesReader(data.span)
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(UInt8.self, asciiOctalDigits: 3) } // 511
        #expect(try reader.read(UInt16.self, asciiOctalDigits: 3) == 511)
        var short = BytesReader(data.span)
        #expect(throws: BytesError.insufficientData) { _ = try short.read(Int.self, asciiOctalDigits: 4) }
        #expect(throws: BytesError.invalidValue) { _ = try short.read(Int.self, asciiOctalDigits: 22) }
        let tar = Array("00000001750\0".utf8)
        var header = BytesReader(tar.span)
        #expect(try header.read(Int.self, asciiOctalDigits: 11) == 0o1750)
    }

    @Test func decimalDigitsUpToALimit() throws {
        func read(_ text: String, upTo limit: Int) throws(BytesError) -> (Int, Int) {
            let data = Array(text.utf8)
            var reader = BytesReader(data.span)
            let value = try reader.read(Int.self, asciiDigitsUpTo: limit)
            return (value, reader.remainingByteCount)
        }
        #expect(try read("1024\r\n", upTo: 10) == (1024, 2))
        #expect(try read("1024", upTo: 10) == (1024, 0)) // Ends at the data's end, short of 8 bytes.
        #expect(try read("12345678", upTo: 8) == (12_345_678, 0)) // Exactly 8 bytes, all digits.
        #expect(try read("123456789", upTo: 8) == (12_345_678, 1)) // The limit stops it.
        #expect(try read("1234567890123x", upTo: 19) == (1_234_567_890_123, 1))
        #expect(try read("7a", upTo: 1) == (7, 1))
        #expect(try read("98765432 tail", upTo: 3) == (987, 10))
        #expect(throws: BytesError.invalidValue) { _ = try read("x123456789", upTo: 5) }
        #expect(throws: BytesError.invalidValue) { _ = try read("x", upTo: 5) }
        #expect(throws: BytesError.insufficientData) { _ = try read("", upTo: 5) }
        #expect(throws: BytesError.invalidValue) { _ = try read("1", upTo: 0) }
        #expect(throws: BytesError.invalidValue) { _ = try read("1", upTo: 20) }
        // Every length and limit, with and without bytes after, against the obvious loop.
        for length in 0...12 {
            let digits = String((0..<length).map { Character(String($0 % 10 + 1 == 10 ? 0 : $0 % 10 + 1)) })
            for limit in 1...12 {
                for tail in ["", " ", "        "] {
                    let taken = min(length, limit)
                    if taken == 0 {
                        #expect(throws: BytesError.self) { _ = try read(digits + tail, upTo: limit) }
                        continue
                    }
                    let expected = Int(digits.prefix(taken))!
                    #expect(try read(digits + tail, upTo: limit) == (expected, length - taken + tail.utf8.count), "\(digits)|\(tail) \(limit)")
                }
            }
        }
        // Overflowing the type consumes nothing.
        let data = Array("300".utf8)
        var reader = BytesReader(data.span)
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(UInt8.self, asciiDigitsUpTo: 3) }
        let remainingByteCount = reader.remainingByteCount
        #expect(remainingByteCount == 3)
    }
}

enum BitWriterHelper {
    /// `bytes` after a zero nibble, so each starts mid-byte.
    static func shiftedByNibble(_ bytes: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: bytes.count + 1)
        for (index, byte) in bytes.enumerated() {
            output[index] |= byte >> 4
            output[index + 1] |= byte << 4
        }
        return output
    }
}

/// Civil UTC times: checks, and seconds since 1970 both ways.
@Suite struct UTCDateTimeTests {
    @Test func checksEveryField() throws {
        #expect(try UTCDateTime(year: 2024, month: 2, day: 29, hour: 0, minute: 0, second: 0).secondsSince1970 == 1_709_164_800)
        #expect(throws: BytesError.invalidValue) { _ = try UTCDateTime(year: 2023, month: 2, day: 29, hour: 0, minute: 0, second: 0) }
        #expect(throws: BytesError.invalidValue) { _ = try UTCDateTime(year: 1900, month: 2, day: 29, hour: 0, minute: 0, second: 0) }
        #expect(try UTCDateTime(year: 2000, month: 2, day: 29, hour: 0, minute: 0, second: 0).day == 29)
        for (month, last) in [(1, 31), (4, 30), (6, 30), (7, 31), (9, 30), (11, 30), (12, 31)] {
            _ = try UTCDateTime(year: 2026, month: month, day: last, hour: 23, minute: 59, second: 59)
            #expect(throws: BytesError.invalidValue) { _ = try UTCDateTime(year: 2026, month: month, day: last + 1, hour: 0, minute: 0, second: 0) }
        }
        for (month, day, hour, minute, second) in [(0, 1, 0, 0, 0), (13, 1, 0, 0, 0), (1, 0, 0, 0, 0), (1, 1, 24, 0, 0), (1, 1, -1, 0, 0), (1, 1, 0, 60, 0), (1, 1, 0, 0, 60), (1, 1, 0, 0, -1)] {
            #expect(throws: BytesError.invalidValue) { _ = try UTCDateTime(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second) }
        }
        #expect(throws: BytesError.invalidValue) { _ = try UTCDateTime(year: 10_000, month: 1, day: 1, hour: 0, minute: 0, second: 0) }
        #expect(throws: BytesError.invalidValue) { _ = try UTCDateTime(year: -10_000, month: 1, day: 1, hour: 0, minute: 0, second: 0) }
        // A leap second only when allowed; it counts as the next minute's first second.
        let leap = try UTCDateTime(year: 2016, month: 12, day: 31, hour: 23, minute: 59, second: 60, allowingLeapSecond: true)
        #expect(leap.secondsSince1970 == 1_483_228_800)
        #expect(throws: BytesError.invalidValue) { _ = try UTCDateTime(year: 2016, month: 12, day: 31, hour: 23, minute: 59, second: 60) }
    }

    @Test func secondsSince1970AgainstCountedDays() throws {
        // Days counted year by year and month by month from 1970, against the closed form, both ways.
        func days(toYear year: Int) -> Int {
            year >= 1970
                ? (1970..<year).reduce(0) { $0 + (UTCDateTime.isLeapYear($1) ? 366 : 365) }
                : -(year..<1970).reduce(0) { $0 + (UTCDateTime.isLeapYear($1) ? 366 : 365) }
        }
        for year in [-9_999, -401, -400, -1, 0, 1, 1600, 1899, 1900, 1969, 1970, 1999, 2000, 2024, 2100, 2400, 9_999] {
            var day = days(toYear: year)
            for month in 1...12 {
                let time = try UTCDateTime(year: year, month: month, day: 1, hour: 13, minute: 14, second: 15)
                let expected = Int64(day) * 86_400 + 13 * 3_600 + 14 * 60 + 15
                #expect(time.secondsSince1970 == expected, "\(time)")
                #expect(try UTCDateTime(secondsSince1970: expected) == time)
                day += UTCDateTime.dayCount(inMonth: month, year: year)
            }
        }
        // Every day for a few years each side of 1970 and of a century, round trip.
        let starts: [Int64] = [-3 * 366 * 86_400, 946_684_800 - 2 * 366 * 86_400]
        for start in starts {
            var previous: UTCDateTime?
            for seconds in stride(from: start, to: start + Int64(6 * 366 * 86_400), by: 86_399) {
                let time = try UTCDateTime(secondsSince1970: seconds)
                #expect(time.secondsSince1970 == seconds)
                if let previous { #expect(previous < time) }
                previous = time
            }
        }
        #expect(throws: BytesError.invalidValue) { _ = try UTCDateTime(secondsSince1970: .max) }
        #expect(throws: BytesError.invalidValue) { _ = try UTCDateTime(secondsSince1970: .min) }
    }

    @Test func description() throws {
        #expect(try UTCDateTime(year: 2026, month: 11, day: 19, hour: 8, minute: 5, second: 9).description == "2026-11-19T08:05:09Z")
        #expect(try UTCDateTime(year: -44, month: 3, day: 15, hour: 12, minute: 0, second: 0).description == "-0044-03-15T12:00:00Z")
    }
}
