import Bytes
import Testing
import zlib

@Suite struct AdlerTests {
    /// Deterministic bytes, varied enough that column sums differ.
    static func bytes(_ count: Int, seed: UInt64 = 1) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }

    static func zlibAdler(_ bytes: [UInt8], continuing value: UInt32 = 1) -> UInt32 {
        // unsafe: zlib reads exactly `count` bytes from the buffer, which is valid for the closure.
        bytes.withUnsafeBufferPointer { unsafe UInt32(adler32(UInt(value), $0.baseAddress, UInt32($0.count))) }
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

    /// The UDOT kernel reduces every 86 blocks of 64 bytes (5,504 bytes): sizes around one, two, and three chunks, from
    /// starts that aren't aligned, with the worst-case bytes and a value that continues from a large checksum.
    @Test(arguments: [5_439, 5_440, 5_503, 5_504, 5_505, 5_567, 11_007, 11_008, 11_009, 16_511, 16_512, 16_513])
    func adlerAroundDotProductChunks(count: Int) {
        for start in [0, 1, 7, 16, 33] {
            let data = Self.bytes(count + start, seed: UInt64(count))
            let slice = Array(data[start...])
            #expect(Adler32.checksum(data.span.bytes.extracting(start...)) == Self.zlibAdler(slice), "\(count) from \(start)")
            let ones = [UInt8](repeating: 0xFF, count: count + start)
            let onesSlice = Array(ones[start...])
            #expect(
                Adler32.checksum(ones.span.bytes.extracting(start...), continuing: 0xFFF0_FFF0 & 0xFFFE_FFFE)
                    == Self.zlibAdler(onesSlice, continuing: 0xFFF0_FFF0 & 0xFFFE_FFFE),
                "ones \(count) from \(start)"
            )
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

    /// Both checksums through `RunningChecksum`: incremental updates and combining match one pass.
    func runningChecksumAgrees<C: RunningChecksum>(_: C.Type) {
        let data = Self.bytes(10_000)
        let whole = C.checksum(data.span.bytes)
        var incremental = C()
        incremental.update(data.span.bytes.extracting(0..<3_000))
        incremental.update(data.span.bytes.extracting(3_000...))
        #expect(incremental.value == whole)
        let first = C.checksum(data.span.bytes.extracting(0..<3_000))
        let second = C.checksum(data.span.bytes.extracting(3_000...))
        #expect(C.combine(first, second, secondLength: 7_000) == whole)
        #expect(C.checksum(RawSpan()) == C.initialValue)
    }

    @Test func runningChecksums() {
        runningChecksumAgrees(CRC32.self)
        runningChecksumAgrees(Adler32.self)
    }
}
