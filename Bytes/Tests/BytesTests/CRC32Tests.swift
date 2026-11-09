// `@testable` (for the folding constants) only where Bytes is built for testing: `swift build -c release
// --build-tests` builds it without `-enable-testing`, and the import would fail.
#if DEBUG
@_spi(Benchmarking) @testable import Bytes
#else
@_spi(Benchmarking) import Bytes
#endif
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

    static func random(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
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
                #expect(CRC32.checksum(slice.span.bytes) == expected, "offset \(offset), \(count) bytes")
                #expect(CRC32.tableChecksum(slice.span.bytes) == expected, "tables: offset \(offset), \(count) bytes")
            }
        }
    }

    /// Updating in pieces gives the same value as all at once, including through `init(continuing:)`.
    @Test func incremental() {
        let data = Self.random(100_000)
        let whole = CRC32.checksum(data.span.bytes)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            var crc = CRC32()
            var start = 0
            while start < data.count {
                let end = min(data.count, start + Int.random(in: 0...3_000, using: &rng))
                crc.update(data.span.extracting(start..<end))
                start = end
                crc = CRC32(continuing: crc.value)
            }
            #expect(crc.value == whole)
        }
        #expect(whole == Self.reference(data))
    }

    #if arch(arm64) && DEBUG
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
