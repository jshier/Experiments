import Bytes
import BytesTestSupport
import Testing

/// 64-byte blocks' masks against byte-at-a-time answers: every bit position, varied bytes around each match (so a
/// gather that read a lane's low bits would show), and the padded last block of every length.
@Suite struct ByteBlockTests {
    /// The mask's bit i is byte i's test, for random blocks and two tests (a byte, and the bytes below 0x20).
    @Test func maskHasEveryByteInItsBit() {
        var generator = SplitMix64(seed: 7)
        for trial in 0..<2_000 {
            // Mostly varied bytes; every 7th trial all one byte, so whole lanes match.
            let bytes = (0..<64).map { _ in trial % 7 == 0 ? 0x3A : UInt8(truncatingIfNeeded: generator.next()) }
            let block = bytes.span.bytes.byteBlock(at: 0)
            let colons = block.mask { $0.matching(0x3A) }
            let controls = block.mask { lanes in
                ByteMatches(highBits: SIMD16(repeating: 0).replacing(with: 0xFF, where: lanes.vector .< SIMD16(repeating: 0x20)))
            }
            var expectedColons: UInt64 = 0, expectedControls: UInt64 = 0
            for (index, byte) in bytes.enumerated() {
                if byte == 0x3A { expectedColons |= 1 << UInt64(index) }
                if byte < 0x20 { expectedControls |= 1 << UInt64(index) }
            }
            #expect(colons == expectedColons)
            #expect(controls == expectedControls)
        }
    }

    /// Each single bit, in a block of non-matching bytes whose low bits vary.
    @Test func everyBitPosition() {
        for position in 0..<64 {
            var bytes = (0..<64).map { UInt8(0x30 + $0 % 0x40) }
            bytes[position] = 0x0A
            #expect(bytes.span.bytes.byteBlock(at: 0).mask { $0.matching(0x0A) } == 1 << UInt64(position))
            #expect(bytes.span.bytes.byteBlock(at: 0).mask { $0.nonASCII } == 0)
        }
    }

    /// A block made from four vectors gives the same masks as one loaded from memory.
    @Test func vectorsInOrderMatchLoadedBlocks() {
        var generator = SplitMix64(seed: 11)
        for _ in 0..<500 {
            let bytes = (0..<64).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            let span = bytes.span.bytes
            let made = ByteBlock(span.load(fromByteOffset: 0, as: SIMD16<UInt8>.self), span.load(fromByteOffset: 16, as: SIMD16<UInt8>.self),
                                 span.load(fromByteOffset: 32, as: SIMD16<UInt8>.self), span.load(fromByteOffset: 48, as: SIMD16<UInt8>.self))
            let loaded = span.byteBlock(at: 0)
            let byte = bytes[Int(generator.next() % 64)]
            #expect(made.mask { $0.matching(byte) } == loaded.mask { $0.matching(byte) })
            #expect(made.mask { $0.nonASCII } == loaded.mask { $0.nonASCII })
        }
    }

    /// The last, partial block of every length is the bytes, then the padding; a whole block at any offset.
    @Test func paddedLastBlocks() {
        let bytes = (0..<130).map { UInt8($0) }
        for offset in 0...130 {
            let block = bytes.span.bytes.byteBlock(at: offset, padding: 0xFF)
            let padding = block.mask { $0.matching(0xFF) }
            let available = min(64, 130 - offset)
            #expect(padding == (available == 64 ? 0 : ~0 << UInt64(available)), "offset \(offset)")
            for index in 0..<available {
                let byte = UInt8(offset + index)
                #expect(block.mask { $0.matching(byte) } == 1 << UInt64(index), "offset \(offset), byte \(index)")
            }
        }
    }
}
