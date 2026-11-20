import Bytes
import BytesTestSupport
import Testing

/// ASCII character classes, tags, and numbers written as digits, against plain definitions.
@Suite struct ASCIITests {
    @Test func characterClassesAgreeWithDefinitions() {
        for value in 0...255 {
            let byte = UInt8(value)
            let scalar = Unicode.Scalar(byte)
            let isDigit = (0x30...0x39).contains(byte)
            let isLetter = (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            let isHexLetter = (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
            #expect(byte.isASCIIDigit == isDigit, "\(byte)")
            #expect(byte.asciiDigitValue == (isDigit ? byte - 0x30 : nil), "\(byte)")
            #expect(byte.isASCIILetter == isLetter, "\(byte)")
            #expect(byte.isASCIIHexDigit == (isDigit || isHexLetter), "\(byte)")
            #expect(byte.asciiHexDigitValue == (isDigit ? byte - 0x30 : isHexLetter ? (byte | 0x20) - 0x61 + 10 : nil), "\(byte)")
            #expect(byte.isASCIIWhitespace == [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains(byte), "\(byte)")
            let lower = byte < 0x80 ? UInt8(String(scalar).lowercased().utf8.first!) : byte
            let upper = byte < 0x80 ? UInt8(String(scalar).uppercased().utf8.first!) : byte
            #expect(byte.asciiLowercased == lower, "\(byte)")
            #expect(byte.asciiUppercased == upper, "\(byte)")
        }
    }

    @Test func laneClassesAgreeWithBytes() {
        for base in stride(from: 0, to: 256, by: 16) {
            var vector = SIMD16<UInt8>()
            for lane in 0..<16 { vector[lane] = UInt8(base + lane) }
            let lanes = ByteLanes(vector)
            func mask(_ test: (UInt8) -> Bool) -> UInt16 {
                (0..<16).reduce(0) { $0 | (test(vector[$1]) ? 1 << $1 : 0) }
            }
            #expect(lanes.asciiDigits.bitmask == mask(\.isASCIIDigit))
            #expect(lanes.asciiLetters.bitmask == mask(\.isASCIILetter))
            #expect(lanes.asciiWhitespace.bitmask == mask(\.isASCIIWhitespace))
            #expect(lanes.asciiControl.bitmask == mask { $0 < 0x20 || $0 == 0x7F })
            #expect(lanes.matching("+").bitmask == mask { $0 == 0x2B })
            for range in [UInt8(0)...0, 0...255, 0x30...0x39, 0x7F...0x81, 0xF0...0xFF, 0x41...0x41] {
                #expect(lanes.matching(in: range).bitmask == mask { range.contains($0) }, "\(range)")
            }
        }
    }

    @Test func tagsAreTheirBytesInOrder() throws {
        #expect(Byte4(ascii: "IHDR") == 0x49_48_44_52)
        #expect(Byte(ascii: "-") == 0x2D)
        #expect(Byte7(ascii: "$share/") == 0x24_73_68_61_72_65_2F)
        #expect(Byte4(ascii: "\u{7F}ELF") == 0x7F_45_4C_46)
        let bytes: [UInt8] = Array("qoifIHDR".utf8)
        var reader = AlignedBytesReader(bytes.span.bytes)
        try reader.expect(Byte4(ascii: "qoif"))
        #expect(try reader.read(Byte4.self) == Byte4(ascii: "IHDR"))
    }

    @Test func magicNumbersInAByteOrder() throws {
        let bytes: [UInt8] = [0x04, 0x22, 0x4D, 0x18, 0x01]
        var reader = AlignedBytesReader(bytes.span.bytes)
        #expect(throws: BytesError.mismatch) { try reader.expect(0x184D_2204 as UInt32, .bigEndian) }
        #expect(reader.remainingByteCount == 5)
        try reader.expect(0x184D_2204 as UInt32, .littleEndian)
        #expect(reader.remainingByteCount == 1)
    }

    @Test(arguments: [false, true])
    func digitsReadEveryWidth(nearTheEnd: Bool) throws {
        var generator = SplitMix64(seed: 41)
        func next() -> UInt64 { generator.next() }
        for digitCount in 1...19 {
            var power: UInt64 = 1
            for _ in 0..<digitCount { power = power &* 10 }
            for trial in 0..<200 {
                // Leading zeros sometimes; the largest value of the width sometimes.
                let value = trial == 0 ? power &- 1 : trial == 1 ? 0 : next() % (digitCount == 19 ? UInt64(Int64.max) : power)
                var text = Array(String(value).utf8)
                text = [UInt8](repeating: 0x30, count: digitCount - text.count) + text
                // Bytes after the digits (or none), and a non-digit right after, which mustn't be read.
                let bytes = text + (nearTheEnd ? [] : [0x3A] + [UInt8](repeating: 0x39, count: 20))
                var reader = AlignedBytesReader(bytes.span.bytes)
                #expect(try reader.read(UInt64.self, asciiDigits: digitCount) == value, "\(digitCount) digits: \(value)")
                #expect(reader.remainingByteCount == bytes.count - digitCount)
            }
        }
    }

    @Test(arguments: [false, true])
    func digitsRejectAnythingElse(nearTheEnd: Bool) throws {
        for digitCount in [1, 2, 7, 8, 9, 15, 16, 17, 19] {
            for badIndex in 0..<digitCount {
                for bad: UInt8 in [0x2F, 0x3A, 0x20, 0x00, 0xB0, 0xFF] {
                    var text = [UInt8](repeating: 0x35, count: digitCount)
                    text[badIndex] = bad
                    let bytes = text + (nearTheEnd ? [] : [UInt8](repeating: 0x31, count: 20))
                    var reader = AlignedBytesReader(bytes.span.bytes)
                    #expect(throws: BytesError.invalidValue) { _ = try reader.read(Int.self, asciiDigits: digitCount) }
                    #expect(reader.remainingByteCount == bytes.count, "nothing consumed")
                }
            }
        }
        let short: [UInt8] = Array("123".utf8)
        var reader = AlignedBytesReader(short.span.bytes)
        #expect(throws: BytesError.insufficientData) { _ = try reader.read(Int.self, asciiDigits: 4) }
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(Int.self, asciiDigits: 0) }
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(Int.self, asciiDigits: 20) }
        // A value its type can't hold.
        let large: [UInt8] = Array("300".utf8)
        var narrow = AlignedBytesReader(large.span.bytes)
        #expect(throws: BytesError.invalidValue) { _ = try narrow.read(UInt8.self, asciiDigits: 3) }
        #expect(narrow.remainingByteCount == 3)
    }

    @Test func digitsRoundTrip() throws {
        let bytes = try [UInt8](alignedByteCapacity: 64) { (writer) throws(BytesError) in
            try writer.write(2026, asciiDigits: 4)
            try writer.write(Byte(ascii: "-"))
            try writer.write(11, asciiDigits: 2)
            try writer.write(7, asciiDigits: 19)
        }
        #expect(String(decoding: bytes, as: UTF8.self) == "2026-11" + String(repeating: "0", count: 18) + "7")
        var reader = AlignedBytesReader(bytes.span.bytes)
        #expect(try reader.read(Int.self, asciiDigits: 4) == 2026)
        try reader.expect(Byte(ascii: "-"))
        #expect(try reader.read(Int.self, asciiDigits: 2) == 11)
        #expect(try reader.read(Int.self, asciiDigits: 19) == 7)
        _ = try [UInt8](alignedByteCapacity: 8) { (writer) throws(BytesError) in
            #expect(throws: BytesError.invalidValue) { try writer.write(100, asciiDigits: 2) }
            #expect(throws: BytesError.invalidValue) { try writer.write(-1, asciiDigits: 2) }
        }
    }
}
