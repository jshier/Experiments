import Bytes
import Testing

/// APIs adopted from swift-binary-parsing's design: `atomically`, overflow-checked integer reads, and sign
/// extension for odd widths.
@Suite struct AdoptedAPITests {
    @Test func atomicallyCommitsOnlyOnSuccess() throws {
        let data: [UInt8] = [0x01, 0x00, 0x03, 0xAA, 0xBB] // type, then 3 bytes promised but only 2 present
        var reader = Bytes(data.span)
        do {
            _ = try reader.atomically { (reader) throws(BytesError) in
                _ = try reader.read(Byte.self)
                return try reader.read(bytesPrefixedBy: Byte2.self, .bigEndian).byteCount
            }
            Issue.record("expected insufficient data")
        } catch {
            #expect(error == .insufficientData)
        }
        let unmoved = reader.byteOffset
        #expect(unmoved == 0)

        let count = try reader.atomically { (reader) throws(BytesError) in
            _ = try reader.read(Byte.self)
            return try reader.read(Byte2.self, .bigEndian)
        }
        let moved = reader.byteOffset
        #expect(count == 3 && moved == 3)
    }

    @Test func checkedIntegerReads() throws {
        let data: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x02]
        var reader = Bytes(data.span)
        // 2^63 doesn't fit in an Int: throws, consuming nothing.
        do { _ = try reader.read(Int.self, as: Byte8.self, .littleEndian); Issue.record("expected a throw") } catch {
            #expect(error == .invalidValue)
        }
        let offset = reader.byteOffset
        #expect(offset == 0)
        #expect(try reader.read(UInt64.self, as: Byte8.self, .littleEndian) == 1 << 63)
        #expect(try reader.read(Int.self, as: Byte2.self, .bigEndian) == 0x0102)
        var narrow = Bytes([0x01, 0x00].span)
        do { _ = try narrow.read(UInt8.self, as: Byte2.self, .bigEndian); Issue.record("expected a throw") } catch {
            #expect(error == .invalidValue)
        }
    }

    @Test func signExtension() {
        let minusTwo: Byte3 = 0xFF_FF_FE
        #expect(minusTwo.signedInteger(.bigEndian, as: Int32.self) == -2)
        #expect(minusTwo.signedInteger(.bigEndian) == -2) // Int by default
        #expect(minusTwo.signedInteger(.littleEndian, as: Int32.self) == -65_537) // 0xFEFFFF, 24-bit
        let positive: Byte3 = 0x7F_FF_FF
        #expect(positive.signedInteger(.bigEndian, as: Int32.self) == 0x7F_FFFF)
        let wide: Byte16 = 0xFF_FF_FF_FF_FF_FF_FF_FF_FF_FF_FF_FF_FF_FF_FF_FF
        #expect(wide.signedInteger(.bigEndian, as: Int128.self) == -1)
        let odd: Byte5 = 0x80_00_00_00_00
        #expect(odd.signedInteger(.bigEndian) == -(1 << 39))
    }
}
