import Bytes
import Testing

/// The 4-way deinterleave and 3-way interleave, `tbx` lookups, the 128-byte lookup, and the writer's
/// `position`/`rewind(to:)`.
@Suite struct LaneShuffleTests {
    func vectors(_ bytes: [UInt8]) -> [SIMD16<UInt8>] {
        stride(from: 0, to: bytes.count, by: 16).map { start in
            var vector = SIMD16<UInt8>()
            for lane in 0..<16 {
                vector[lane] = bytes[start + lane]
            }
            return vector
        }
    }

    func bytes(_ vectors: [SIMD16<UInt8>]) -> [UInt8] { vectors.flatMap { vector in (0..<16).map { vector[$0] } } }

    @Test func deinterleaveFour() {
        let input = vectors((0..<64).map { UInt8($0) })
        let (a, b, c, d) = ByteLanes.deinterleave(input[0], input[1], input[2], input[3])
        #expect(bytes([a]) == stride(from: 0, to: 64, by: 4).map { UInt8($0) })
        #expect(bytes([b]) == stride(from: 1, to: 64, by: 4).map { UInt8($0) })
        #expect(bytes([c]) == stride(from: 2, to: 64, by: 4).map { UInt8($0) })
        #expect(bytes([d]) == stride(from: 3, to: 64, by: 4).map { UInt8($0) })
        // The inverse of the 4-way interleave.
        let (w, x, y, z) = ByteLanes.interleave(a, b, c, d)
        #expect(bytes([w, x, y, z]) == (0..<64).map { UInt8($0) })
    }

    @Test func interleaveThree() {
        let input = vectors((0..<48).map { UInt8($0) })
        let (a, b, c) = ByteLanes.deinterleave(input[0], input[1], input[2])
        let (x, y, z) = ByteLanes.interleave(a, b, c)
        #expect(bytes([x, y, z]) == (0..<48).map { UInt8($0) })
        let red = SIMD16<UInt8>(repeating: 1), green = SIMD16<UInt8>(repeating: 2), blue = SIMD16<UInt8>(repeating: 3)
        let (p, q, r) = ByteLanes.interleave(red, green, blue)
        #expect(bytes([p, q, r]) == Array([[UInt8]](repeating: [1, 2, 3], count: 16).joined()))
    }

    @Test func lookupsKeepingOutOfRange() {
        let table = vectors((0..<64).map { UInt8($0) | 0x80 })
        let fallback = SIMD16<UInt8>(repeating: 0x41)
        let indices: SIMD16<UInt8> = [0, 15, 16, 47, 48, 63, 64, 100, 255, 1, 2, 3, 4, 5, 6, 7]
        let four = ByteLanes(indices).lookup(in: (table[0], table[1], table[2], table[3]), keepingOutOfRange: fallback)
        let three = ByteLanes(indices).lookup(in: (table[0], table[1], table[2]), keepingOutOfRange: fallback)
        for lane in 0..<16 {
            let index = Int(indices[lane])
            #expect(four[lane] == (index < 64 ? UInt8(index) | 0x80 : 0x41))
            #expect(three[lane] == (index < 48 ? UInt8(index) | 0x80 : 0x41))
        }
    }

    @Test func lookupsIn16Bytes() {
        let table = vectors((0..<16).map { UInt8($0) * 3 })[0]
        let fallback = SIMD16<UInt8>(repeating: 0xEE)
        let indices: SIMD16<UInt8> = [0, 1, 15, 16, 17, 255, 128, 7, 8, 9, 10, 11, 12, 13, 14, 2]
        let looked = ByteLanes(indices).lookup(in: table)
        let kept = ByteLanes(indices).lookup(in: table, keepingOutOfRange: fallback)
        for lane in 0..<16 {
            let index = Int(indices[lane])
            #expect(looked[lane] == (index < 16 ? UInt8(index * 3) : 0))
            #expect(kept[lane] == (index < 16 ? UInt8(index * 3) : 0xEE))
        }
    }

    @Test func lookupIn128Bytes() {
        let table = vectors((0..<128).map { UInt8(255 - $0) })
        let halves = ((table[0], table[1], table[2], table[3]), (table[4], table[5], table[6], table[7]))
        for start in stride(from: 0, to: 256, by: 16) {
            let indices = vectors((start..<(start + 16)).map { UInt8($0) })[0]
            let result = ByteLanes(indices).lookup(in: halves)
            for lane in 0..<16 {
                let index = start + lane
                #expect(result[lane] == (index < 128 ? UInt8(255 - index) : 0), "index \(index)")
            }
        }
    }

    @Test func writerRewind() throws {
        let bytes = try [UInt8](byteCapacity: 16) { (writer) throws(BytesError) in
            try writer.write(0xAB as Byte)
            try writer.write(Bits<3>(0b101))
            let mark = writer.position
            #expect(mark.byteOffset == 1 && mark.bitOffset == 3 && mark.bitPosition == 11)
            try writer.write(0x1234 as Byte2)
            try writer.write(Bits<7>(0x7F))
            writer.rewind(to: mark)
            #expect(writer.byteCount == 2)
            // Writes after the rewind continue the partial byte as it was at `mark`.
            try writer.write(Bits<5>(0b00011))
            try writer.write(0xCD as Byte)
        }
        #expect(bytes == [0xAB, 0b1010_0011, 0xCD])

        // Rewinding to the start keeps nothing.
        let none = try [UInt8](byteCapacity: 8) { (writer) throws(BytesError) in
            let start = writer.position
            try writer.write(0x0102_0304 as Byte4)
            writer.rewind(to: start)
        }
        #expect(none.isEmpty)
    }
}
