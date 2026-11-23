import Bytes
import BytesTestSupport
import Testing

@Suite struct CRC32Tests {
    /// The CRC one bit at a time, straight from the definition.
    static func reference(_ bytes: [UInt8], from crc: UInt32 = 0) -> UInt32 {
        var state = ~crc
        for byte in bytes {
            state ^= UInt32(byte)
            for _ in 0..<8 {
                state = state & 1 == 1 ? state >> 1 ^ 0xEDB8_8320 : state >> 1
            }
        }
        return ~state
    }

    /// Fixed seeds, so a failure reproduces: the messages name them.
    static let dataSeed: UInt64 = 0xC4C3_2000
    static let splitSeed: UInt64 = 0xC4C3_2001

    static func random(_ count: Int) -> [UInt8] {
        var rng = SplitMix64(seed: dataSeed)
        return rng.bytes(count)
    }

    @Test func checkValues() {
        #expect(CRC32.checksum(Array("123456789".utf8).span.bytes) == 0xCBF4_3926) // The catalogue's check.
        #expect(CRC32.checksum([UInt8]().span.bytes) == 0)
        #expect(CRC32.checksum([UInt8](repeating: 0, count: 32).span.bytes) == 0x190A_55AD)
    }

    /// Every length to well past the folding threshold, at every alignment, against the reference, and
    /// the table path (other CPUs') too.
    @Test func matchesReference() {
        let data = Self.random(1_200)
        for offset in 0..<16 {
            for count in stride(from: 0, through: data.count - offset, by: offset == 0 ? 1 : 37) {
                let slice = Array(data[offset..<(offset + count)])
                let expected = Self.reference(slice)
                #expect(CRC32.checksum(slice.span.bytes) == expected, "offset \(offset), \(count) bytes, seed \(Self.dataSeed)")
                #expect(CRC32.tableChecksum(slice.span.bytes) == expected, "tables: offset \(offset), \(count) bytes, seed \(Self.dataSeed)")
            }
        }
    }

    /// Updating in pieces gives the same value as all at once, including through `init(continuing:)`.
    @Test func incremental() {
        let data = Self.random(100_000)
        let whole = CRC32.checksum(data.span.bytes)
        var rng = SplitMix64(seed: Self.splitSeed)
        for _ in 0..<50 {
            var crc = CRC32()
            var start = 0
            while start < data.count {
                let end = min(data.count, start + Int.random(in: 0...3_000, using: &rng))
                crc.update(data.span.extracting(start..<end))
                start = end
                crc = CRC32(continuing: crc.value)
            }
            #expect(crc.value == whole, "seeds \(Self.dataSeed), \(Self.splitSeed)")
        }
        #expect(whole == Self.reference(data))
    }

    /// A byte at a time through the register: every byte value from every kind of register, and a whole buffer's
    /// checksum (the register's complement).
    @Test func updateRegister() {
        var rng = SplitMix64(seed: Self.splitSeed)
        for register: UInt32 in [0, 0xFFFF_FFFF, 0x1234_5678, UInt32.random(in: 0...UInt32.max, using: &rng)] {
            for byte in UInt8.min...UInt8.max {
                // Bitwise: the reflected polynomial, one bit at a time.
                var expected = register ^ UInt32(byte)
                for _ in 0..<8 {
                    expected = expected & 1 != 0 ? expected >> 1 ^ 0xEDB8_8320 : expected >> 1
                }
                #expect(CRC32.updateRegister(register, byte: byte) == expected, "register \(register), byte \(byte)")
            }
        }
        let data = Self.random(10_000)
        var register: UInt32 = 0xFFFF_FFFF
        for byte in data {
            register = CRC32.updateRegister(register, byte: byte)
        }
        #expect(~register == CRC32.checksum(data.span.bytes))
    }

    #if arch(arm64) && HardwareCRC && !Portable
    /// The folding constants: x^(n ± 32) mod P, bit-reflected, shifted left one.
    @Test func foldingConstants() {
        func constant(_ exponent: Int) -> UInt64 {
            var remainder: UInt64 = 1
            for _ in 0..<exponent {
                remainder <<= 1
                if remainder & (1 << 32) != 0 { remainder ^= 0x1_04C1_1DB7 }
            }
            return UInt64(UInt32(remainder).bitReversed) << 1
        }
        #expect(bitCast(CRC32.fold128, to: SIMD2<UInt64>.self) == SIMD2(constant(128 + 32), constant(128 - 32)))
        #expect(bitCast(CRC32.fold1024, to: SIMD2<UInt64>.self) == SIMD2(constant(1024 + 32), constant(1024 - 32)))
    }
    #endif
}
