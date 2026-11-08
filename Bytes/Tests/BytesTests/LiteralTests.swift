import Bytes
import Testing

@Suite struct ByteGroupLiteralTests {
    /// Integer literals are the bytes in memory order, like array literals of the same bytes.
    @Test func integerLiteralsAreBytesInMemoryOrder() {
        let signature: Byte4 = 0x50_4B_03_04
        #expect(signature == [0x50, 0x4B, 0x03, 0x04])
        #expect(signature.bigEndian == 0x504B_0304)
        #expect(signature.littleEndian == 0x0403_4B50)
        #expect(signature.description == "50 4B 03 04")

        let name: Byte6 = 0x00_04_4D_51_54_54 // Leading zero bytes are kept: the width is fixed.
        #expect(name == [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54])
        let short: Byte2 = 0x05
        #expect(short == [0x00, 0x05])
        let odd: Byte3 = 0x12_34_56
        #expect(odd == [0x12, 0x34, 0x56])
        let wide: Byte16 = 0x00_11_22_33_44_55_66_77_88_99_AA_BB_CC_DD_EE_FF
        #expect(wide[0] == 0x00 && wide[1] == 0x11 && wide[15] == 0xFF)
        let wideOdd: Byte11 = 0x01_02_03_04_05_06_07_08_09_0A_0B
        #expect(wideOdd[0] == 0x01 && wideOdd[10] == 0x0B)
    }

    /// Every width agrees with its array literal.
    @Test func everyWidthMatchesArrayLiterals() {
        func check<T: ByteGroup>(_: T.Type) {
            let bytes = (0..<T.byteCount).map { UInt8(0xA0 &+ $0) }
            var integer: T.Integer = 0
            for byte in bytes { integer = integer << 8 | T.Integer(byte) }
            let value = T(integerLiteral: integer)
            #expect((0..<T.byteCount).allSatisfy { value[$0] == bytes[$0] }, "\(T.self)")
        }
        check(Byte2.self); check(Byte3.self); check(Byte4.self); check(Byte5.self); check(Byte6.self)
        check(Byte7.self); check(Byte8.self); check(Byte9.self); check(Byte10.self); check(Byte11.self)
        check(Byte12.self); check(Byte13.self); check(Byte14.self); check(Byte15.self); check(Byte16.self)
    }

    /// Literals work wherever a group is expected: reading, comparing, and matching.
    @Test func literalsInUse() throws {
        let data: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]
        var reader = BytesReader(data.span)
        try reader.expect(0x50_4B_03_04 as Byte4)
        let version = try reader.read(Byte2.self)
        #expect(version == 0x14_00)
        switch version {
        case 0x14_00: break
        default: Issue.record("didn't match the literal")
        }
        var output = [UInt8](repeating: 0, count: 4)
        var span = output.mutableSpan
        var writer = BytesWriter(&span)
        try writer.write(0x50_4B_03_04 as Byte4)
        _ = consume writer
        _ = consume span
        #expect(output == [0x50, 0x4B, 0x03, 0x04])
    }
}
