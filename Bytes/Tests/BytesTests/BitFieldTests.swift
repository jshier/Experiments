import Bytes
import Testing

@Suite struct BitFieldTests {
    @Test func fieldsOfBits() {
        var flags: Nibble = 0b1101
        #expect(flags[Crumb.self, at: 1] == 0b10)
        #expect(flags[Bit.self, at: 3] == 1)
        #expect(flags[Nibble.self, at: 0] == flags)
        flags[Crumb.self, at: 1] = 0b01
        #expect(flags == 0b1011)
        flags[Crumb.self, at: 2] = 0b00
        #expect(flags == 0b0011)
    }

    @Test func fieldsOfIntegers() {
        // A DOS date: 7 bits of years since 1980, 4 of month, 5 of day. 2024-07-15.
        let date: UInt16 = (2024 - 1980) << 9 | 7 << 5 | 15
        #expect(1980 + Int(date[Bits<7>.self, at: 9]) == 2024)
        #expect(Int(date[Nibble.self, at: 5]) == 7)
        #expect(Int(date[Bits<5>.self, at: 0]) == 15)

        var value: UInt32 = 0
        value[Byte.self, at: 24] = 0xAB
        value[Nibble.self, at: 4] = 0xF
        #expect(value == 0xAB00_00F0)
        value[bit: 0] = true
        value[bit: 31] = false
        #expect(value == 0x2B00_00F1)
        #expect(value[bit: 0] && !value[bit: 1])

        #expect(value[bits: 24..<32] == 0x2B)
        #expect(value[bits: 0..<32] == value)
        #expect(value[bits: 4..<4] == 0)
        value[bits: 8..<24] = 0x1234
        #expect(value == 0x2B12_34F1)

        // Signed: fields are the bit pattern, never sign-extended; an 8-bit field fits.
        var signed: Int8 = -1
        #expect(signed[Byte.self, at: 0] == 0xFF)
        #expect(signed[bits: 4..<8] == 0xF)
        signed[Byte.self, at: 0] = 0x80
        #expect(signed == Int8.min)
    }

    /// Byte groups' operators work byte by byte in memory order, for odd widths too, and stay in their width.
    @Test func byteGroupOperators() {
        let payload: Byte4 = [0x12, 0x34, 0x56, 0x78]
        let key: Byte4 = [0xFF, 0x00, 0xF0, 0x0F]
        #expect(payload ^ key == [0xED, 0x34, 0xA6, 0x77])
        #expect(payload ^ key ^ key == payload)
        #expect(payload & key == [0x12, 0x00, 0x50, 0x08])
        #expect(payload | key == [0xFF, 0x34, 0xF6, 0x7F])
        let odd: Byte3 = [0x0F, 0xF0, 0x00]
        #expect(~odd == [0xF0, 0x0F, 0xFF])
        #expect((~odd).littleEndian == 0xFF_0F_F0) // Nothing set past the third byte.
        var value = odd
        value ^= [0xFF, 0xFF, 0xFF]
        value &= [0xF0, 0x0F, 0xFF]
        value |= [0x01, 0x00, 0x00]
        #expect(value == [0xF1, 0x0F, 0xFF])
    }

    /// `forEach` with a byte order gives each group's integer, like `read(_:_:)`.
    @Test func forEachInByteOrder() {
        let data: [UInt8] = [0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0xFF]
        var reader = BytesReader(data.span)
        var values: [UInt16] = []
        reader.forEach(Byte2.self, .bigEndian) { values.append($0) }
        #expect(values == [1, 2, 3])
        let remaining = reader.remainingByteCount
        #expect(remaining == 1)
        var little = BytesReader(data.span)
        values = []
        little.forEach(Byte2.self, .littleEndian) { values.append($0) }
        #expect(values == [0x0100, 0x0200, 0x0300])
    }

    @Test func rawRepresentableFromBits() {
        enum QualityOfService: UInt8 { case atMostOnce, atLeastOnce, exactlyOnce }
        let flags: Nibble = 0b0100
        #expect(QualityOfService(rawBits: flags[Crumb.self, at: 1]) == .exactlyOnce)
        #expect(QualityOfService(rawBits: Crumb(3)) == nil)
        enum Signed: Int8 { case low = 1 }
        #expect(Signed(rawBits: Byte(0x81)) == nil) // 129 doesn't fit in `Int8`.
    }
}
