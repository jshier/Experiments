import Bytes
import Testing

/// Prefix lengths, suffix checks, searches from an offset, lane masks, bit-field extracts, and `BitBuffer`
/// rewinds.
@Suite struct MatchingTests {
    @Test func commonPrefixLengthAgreesWithAByteLoop() {
        // Runs with differences at every distance from the start, in the 8-byte loop and the byte tail.
        var bytes = [UInt8](repeating: 0x61, count: 300)
        for difference in [0, 1, 7, 8, 9, 15, 16, 100, 149] {
            bytes[150 + difference] = 0x62
            for (start, maxLength) in [(0, 150), (4, 150), (0, 9), (3, 3), (0, 0)] {
                let length = bytes.span.bytes.commonPrefixLength(at: 150, and: 0, from: start, maxLength: maxLength)
                var expected = start
                while expected < maxLength && bytes[150 + expected] == bytes[expected] {
                    expected += 1
                }
                #expect(length == expected, "difference \(difference), start \(start), max \(maxLength)")
            }
            bytes[150 + difference] = 0x61
        }
    }

    @Test func commonPrefixLengthOfOverlappingRuns() {
        // A run of one byte against itself one back: a distance-1 match, as long as allowed.
        let bytes = [UInt8](repeating: 7, count: 40)
        #expect(bytes.span.bytes.commonPrefixLength(at: 1, and: 0, maxLength: 39) == 39)
    }

    @Test func suffixes() {
        // (Results bound first: `#expect` can't take a call on a span as its whole condition.)
        let text: [UInt8] = Array("QUJD==".utf8)
        let padded = text.span.bytes.hasSuffix(0x3D_3D as Byte2)
        let wrong = text.span.bytes.hasSuffix(0x44_3D as Byte2)
        let three = text.span.bytes.hasSuffix(0x3D_3D_3D as Byte3)
        let short = ([0x3D] as [UInt8]).span.bytes.hasSuffix(0x3D_3D as Byte2) // Shorter than the suffix.
        #expect(padded && !wrong && !three && !short)
    }

    @Test func searchFromAnOffset() {
        var bytes = [UInt8](repeating: 0x11, count: 100)
        for offset in [3, 40, 96] {
            bytes.replaceSubrange(offset..<(offset + 4), with: [0x00, 0x00, 0xFF, 0xFF])
        }
        let marker = [0x00, 0x00, 0xFF, 0xFF] as Byte4
        #expect(bytes.span.bytes.firstByteOffset(of: marker) == 3)
        #expect(bytes.span.bytes.firstByteOffset(of: marker, from: 4) == 40)
        #expect(bytes.span.bytes.firstByteOffset(of: marker, from: 41) == 96)
        #expect(bytes.span.bytes.firstByteOffset(of: marker, from: 97) == nil)
        #expect(bytes.span.bytes.firstByteOffset(of: marker, from: 100) == nil)
    }

    @Test func laneMasks() {
        var lanes = SIMD16<UInt8>(repeating: 1)
        #expect(ByteLanes(lanes).matching(0).bitmask == 0)
        #expect(ByteLanes(lanes).matching(0).firstIndex == nil)
        for lane in [0, 5, 7, 8, 15] {
            lanes[lane] = 0
        }
        let matches = ByteLanes(lanes).matching(0)
        #expect(matches.bitmask == 1 << 0 | 1 << 5 | 1 << 7 | 1 << 8 | 1 << 15)
        #expect(matches.firstIndex == 0)
        lanes[0] = 1
        #expect(ByteLanes(lanes).matching(0).firstIndex == 5)
    }

    /// The nibble mask has lane i's match in bit 4i + 3, for every single lane and for all of them.
    @Test func nibbleMasks() {
        for lane in 0..<16 {
            var lanes = SIMD16<UInt8>(repeating: 7)
            lanes[lane] = 0
            let matches = ByteLanes(lanes).matching(0)
            #expect(matches.nibbleMask == 1 << (4 * lane + 3))
            #expect(matches.firstIndex == lane)
        }
        #expect(ByteLanes(.zero).matching(0).nibbleMask == 0x8888_8888_8888_8888)
        #expect(ByteLanes(.zero).matching(0).nibbleMask.nonzeroBitCount == 16)
    }

    /// Only the lanes that match count, whatever the other lanes hold: `matching(_:)` leaves arbitrary low bits
    /// in lanes that don't match (0x70 leaves bit 3 set), which mustn't read as matches.
    @Test func nibbleMasksIgnoreLowBits() {
        for filler in UInt8.min...UInt8.max where filler != 0 {
            for lane in [0, 1, 6, 7, 14, 15] {
                var lanes = SIMD16<UInt8>(repeating: filler)
                lanes[lane] = 0
                let matches = ByteLanes(lanes).matching(0)
                #expect(matches.nibbleMask == 1 << (4 * lane + 3), "filler \(filler), lane \(lane)")
                #expect(matches.firstIndex == lane)
            }
            #expect(ByteLanes(SIMD16(repeating: filler)).matching(0).firstIndex == nil)
        }
    }

    @Test func bitFieldsByWidth() {
        let value: UInt64 = 0b1011_0110_1100
        for low in 0..<12 {
            for count in 0..<(64 - low) {
                #expect(value.bits(from: low, count: count) == value.bits(from: low, upTo: low + count))
            }
        }
    }

    @Test func bitWriterRoundTripsThroughBitBuffer() throws {
        // Codes of every width 1 through 25, then an aligned byte copy, then more codes.
        let codes: [(UInt64, Int)] = (1...25).map { width in (UInt64(width &* 0x9E37_79B9) & ((1 << UInt64(width)) - 1), width) }
        var storage = [UInt8](repeating: 0, count: 256)
        var span = storage.mutableSpan
        var writer = BitWriter(MutableRawSpan(mutating: &span))
        for (value, width) in codes {
            writer.add(value, bitCount: width)
            writer.flush()
        }
        writer.alignToByte()
        let aligned = writer.byteOffset
        writer.write(([0xAA, 0xBB, 0xCC] as [UInt8]).span.bytes)
        writer.add(0b101, bitCount: 3)
        writer.alignToByte()
        let end = writer.byteOffset
        #expect(writer.pendingBitCount == 0)
        _ = consume writer
        _ = consume span

        var bits = try BitBuffer(storage.span.bytes, atBitPosition: 0, bitOrder: .leastSignificantFirst)
        for (value, width) in codes {
            bits.refill()
            #expect(bits.read(bitCount: width) == value, "width \(width)")
        }
        #expect((bits.bitPosition + 7) / 8 == aligned)
        #expect(Array(storage[aligned..<(aligned + 3)]) == [0xAA, 0xBB, 0xCC])
        #expect(storage[aligned + 3] == 0b101 && end == aligned + 4)
    }

    @Test func bitWriterResumes() {
        // A writer stopped mid-byte, resumed from its state, writes what one writer would have.
        var one = [UInt8](repeating: 0, count: 32)
        var two = one
        do {
            var span = one.mutableSpan
            var writer = BitWriter(MutableRawSpan(mutating: &span))
            writer.add(0x5, bitCount: 3)
            writer.add(0x1FF, bitCount: 9)
            writer.alignToByte()
        }
        do {
            var span = two.mutableSpan
            var first = BitWriter(MutableRawSpan(mutating: &span))
            first.add(0x5, bitCount: 3)
            first.flush()
            let (offset, bits, count) = (first.byteOffset, first.pendingBits, first.pendingBitCount)
            _ = consume first
            var second = BitWriter(MutableRawSpan(mutating: &span), byteOffset: offset, bits: bits, bitCount: count)
            second.add(0x1FF, bitCount: 9)
            second.alignToByte()
        }
        #expect(one == two)
    }

    @Test(arguments: [BitOrder.leastSignificantFirst, .mostSignificantFirst])
    func bitBufferRewinds(order: BitOrder) throws {
        let data: [UInt8] = (0..<64).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        var bits = try BitBuffer(data.span.bytes, atBitPosition: 13, bitOrder: order)
        bits.refill()
        _ = bits.read(bitCount: 5)
        let mark = bits.position
        #expect(mark.bitPosition == 18)
        bits.refill()
        let first = bits.read(bitCount: 11)
        let second = bits.read(bitCount: 23)
        bits.rewind(to: mark)
        #expect(bits.bitPosition == 18)
        bits.refill()
        #expect(bits.read(bitCount: 11) == first)
        #expect(bits.read(bitCount: 23) == second)
        // A byte-aligned position, and the end.
        let aligned = bits.position
        _ = bits.read(bitCount: 6)
        bits.rewind(to: aligned)
        #expect(bits.bitPosition == aligned.bitPosition)
        var end = try BitBuffer(data.span.bytes, atBitPosition: 64 * 8, bitOrder: order)
        let atEnd = end.position
        end.refill()
        _ = end.read(bitCount: 3) // Zeros past the end.
        let over = end.isOverrun
        end.rewind(to: atEnd)
        let back = end.isOverrun
        #expect(over && !back)
    }
}
