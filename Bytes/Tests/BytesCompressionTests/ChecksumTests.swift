import BytesCompression
import Testing
import zlib

@Suite struct ChecksumTests {
    /// Deterministic bytes, varied enough that column sums differ.
    static func bytes(_ count: Int, seed: UInt64 = 1) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }

    static func zlibAdler(_ bytes: [UInt8], continuing value: UInt32 = 1) -> UInt32 {
        bytes.withUnsafeBufferPointer { UInt32(adler32(UInt(value), $0.baseAddress, UInt32($0.count))) }
    }

    @Test(arguments: Array(0...70) + [127, 128, 4095, 4096, 4097, 4127, 4128, 4129, 8192, 100_000, 1 << 20])
    func adlerMatchesZlib(count: Int) {
        let data = Self.bytes(count)
        #expect(Adler32.checksum(data.span.bytes) == Self.zlibAdler(data))
    }

    @Test func adlerAllOnesStressesTheSums() {
        // 0xFF everywhere is the worst case for every intermediate sum.
        for count in [31, 32, 4096, 4128, 65_536, 1 << 20] {
            let data = [UInt8](repeating: 0xFF, count: count)
            #expect(Adler32.checksum(data.span.bytes) == Self.zlibAdler(data), "\(count)")
        }
    }

    @Test func adlerIncremental() {
        let data = Self.bytes(10_000, seed: 7)
        var adler = Adler32()
        var start = 0
        for size in [1, 31, 32, 33, 4096, 5000] where start < data.count {
            let end = min(start + size, data.count)
            adler.update(data.span.bytes.extracting(start..<end))
            start = end
        }
        adler.update(data.span.bytes.extracting(start...))
        #expect(adler.value == Self.zlibAdler(data))
    }
}
