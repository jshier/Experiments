import Bytes
import Testing

/// `ByteLanes.lookup(in:)`, `deinterleave`, and `interleave`, against their definitions, and
/// `BytesWriter.write(_:count:filling:)`.
@Suite struct ByteLookupTests {
    /// 16 lanes from an array.
    func vector(_ bytes: some Collection<UInt8>) -> SIMD16<UInt8> {
        precondition(bytes.count == 16)
        var vector = SIMD16<UInt8>()
        for (lane, byte) in bytes.enumerated() {
            vector[lane] = byte
        }
        return vector
    }

    func array(_ vector: SIMD16<UInt8>) -> [UInt8] { (0..<16).map { vector[$0] } }

    /// Every index, 0 through 255: the table's byte below its size, 0 from there.
    @Test func lookupsMatchTheTable() {
        let table = (0..<64).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 5) }
        let vectors = (0..<4).map { vector(table[($0 * 16)..<($0 * 16 + 16)]) }
        for start in stride(from: 0, to: 256, by: 16) {
            let indices = vector((start..<(start + 16)).map(UInt8.init))
            let from48 = array(ByteLanes(indices).lookup(in: (vectors[0], vectors[1], vectors[2])))
            let from64 = array(ByteLanes(indices).lookup(in: (vectors[0], vectors[1], vectors[2], vectors[3])))
            #expect(from48 == (start..<(start + 16)).map { $0 < 48 ? table[$0] : 0 })
            #expect(from64 == (start..<(start + 16)).map { $0 < 64 ? table[$0] : 0 })
        }
    }

    /// `deinterleave` is `ld3`'s order, `interleave` is `st4`'s, and they undo themselves.
    @Test func deinterleaveAndInterleave() {
        let bytes = (0..<64).map { UInt8($0 + 100) }
        let (first, second, third) = ByteLanes.deinterleave(vector(bytes[0..<16]), vector(bytes[16..<32]), vector(bytes[32..<48]))
        #expect(array(first) == (0..<16).map { bytes[3 * $0] })
        #expect(array(second) == (0..<16).map { bytes[3 * $0 + 1] })
        #expect(array(third) == (0..<16).map { bytes[3 * $0 + 2] })

        let parts = (0..<4).map { vector(bytes[($0 * 16)..<($0 * 16 + 16)]) }
        let (a, b, c, d) = ByteLanes.interleave(parts[0], parts[1], parts[2], parts[3])
        let interleaved: [UInt8] = [a, b, c, d].flatMap(array)
        let expected: [UInt8] = (0..<64).map { (index: Int) -> UInt8 in bytes[(index % 4) * 16 + index / 4] }
        #expect(interleaved == expected)
    }

    @Test func lookupsAreVectorizedOnARM64() {
        #if arch(arm64) && NEONShuffle && !Portable
        #expect(ByteLanes.isLookupVectorized)
        #endif
    }
}

@Suite struct WriteFillingTests {
    /// Fills the next values in place, after what was written before, and moves past them.
    @Test func fillsInPlaceAndAdvances() throws {
        var output = [UInt8](repeating: 0, count: 10)
        var span = output.mutableSpan
        var writer = BytesWriter(&span)
        try writer.write(0x01 as Byte)
        let count = try writer.write(InlineArray<4, UInt8>.self, count: 2, filling: { values -> Int in
            values[0] = [2, 3, 4, 5]
            values[1] = [6, 7, 8, 9]
            return values.count
        })
        try writer.write(0x0A as Byte)
        let written = writer.byteCount
        #expect(count == 2 && written == 10)
        #expect(output == Array(1...10))
    }

    /// Without room, it throws before calling `body`, and writes nothing.
    @Test func insufficientCapacityDoesNotCallBody() throws {
        var output = [UInt8](repeating: 0, count: 7)
        var span = output.mutableSpan
        var writer = BytesWriter(&span)
        var called = false
        #expect(throws: BytesError.insufficientCapacity) {
            try writer.write(InlineArray<4, UInt8>.self, count: 2, filling: { _ in called = true })
        }
        let written = writer.byteCount
        #expect(!called && written == 0)
    }

    /// Types with alignment: aligned positions work, misaligned ones throw.
    @Test func alignment() throws {
        var output = [UInt32](repeating: 0, count: 4)
        var span = output.mutableSpan
        var writer = BytesWriter(span.mutableBytes)
        try writer.write(UInt32.self, count: 2, filling: { $0[0] = 0x0403_0201; $0[1] = 0x0807_0605 })
        try writer.write(0x09 as Byte)
        #expect(throws: BytesError.misaligned) { try writer.write(UInt32.self, count: 1, filling: { _ in }) }
    }
}
