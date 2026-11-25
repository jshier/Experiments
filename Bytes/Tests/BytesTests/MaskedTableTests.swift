import Bytes
import Testing

/// `MaskedTable`: indices masked into a power-of-two table, fills by group within whole 64-byte lines.
@Suite struct MaskedTableTests {
    @Test(arguments: [1, 2, 16, 1 << 10])
    func indicesWrapIntoTheTable(count: Int) {
        var table = MaskedTable<Int>(count: count, repeating: -1)
        #expect(table.count == count)
        #expect(table.mask == count - 1)
        // Every index, negative and past the end too, lands on `index & (count - 1)`.
        for index in [-3 * count - 1, -1, 0, 1, count - 1, count, count + 5, 7 * count + 3, Int.max, Int.min] {
            let entry = index & (count - 1)
            table[index] = index
            #expect(table[entry] == index)
            #expect(table.span[entry] == index)
        }
    }

    @Test func entriesAreTheirOwn() {
        var table = MaskedTable<UInt64>(count: 64, repeating: 0)
        for index in 0..<64 {
            table[index] = UInt64(index) * 3
        }
        // Writes past the end wrap: 64 + 5 is entry 5, and nothing else moves.
        table[69] = 1_000
        for index in 0..<64 {
            #expect(table[index] == (index == 5 ? 1_000 : UInt64(index) * 3))
        }
        var span = table.mutableSpan
        span[7] = 42
        _ = consume span
        #expect(table[7 + 64 * 9] == 42)
    }

    /// Group fills cover the entries exactly (a table smaller than a group fills its first, which its 64-byte line
    /// holds), for 16-, 32-, and 64-byte groups.
    @Test(arguments: [1, 4, 8, 32, 64, 1 << 12])
    func groupFills(count: Int) {
        var table = MaskedTable<Int16>(uninitializedCount: count)
        table.fill(.min, groupedAs: SIMD32<Int16>.self)
        #expect(Self.entries(table) == [Int16](repeating: .min, count: count))
        table.fill(7, groupedAs: SIMD8<Int16>.self)
        #expect(Self.entries(table) == [Int16](repeating: 7, count: count))
        table.fill(-2, groupedAs: SIMD16<Int16>.self)
        #expect(Self.entries(table) == [Int16](repeating: -2, count: count))
        table.fill(0)
        #expect(Self.entries(table) == [Int16](repeating: 0, count: count))
    }

    /// A group with a padding lane (`SIMD3<Int32>`: 16 bytes, three lanes) traps rather than storing its fourth lane
    /// (0: `SIMD3(repeating: 5)` is `[5, 5, 5, 0]` in memory) over every fourth entry.
    @Test func groupsWithAPaddingLaneTrap() async {
        await #expect(processExitsWith: .failure) {
            var table = MaskedTable<Int32>(uninitializedCount: 16)
            table.fill(5, groupedAs: SIMD3<Int32>.self)
        }
    }

    static func entries<T: BitwiseCopyable>(_ table: borrowing MaskedTable<T>) -> [T] {
        let span = table.span
        var entries: [T] = []
        for index in span.indices {
            entries.append(span[index])
        }
        return entries
    }

    /// Entries of any trivial type, and the memory aligned to a cache line.
    @Test func structEntriesAndAlignment() {
        struct Pair: BitwiseCopyable, Equatable {
            var a: SIMD4<Int32>
            var b: SIMD4<UInt32>
        }
        var table = MaskedTable<Pair>(count: 1 << 6, repeating: Pair(a: .zero, b: .zero))
        table[3] = Pair(a: SIMD4(1, 2, 3, 4), b: SIMD4(5, 6, 7, 8))
        #expect(table[3 + (1 << 6)] == Pair(a: SIMD4(1, 2, 3, 4), b: SIMD4(5, 6, 7, 8)))
        // The span's address, compared, not used to access anything.
        let address = table.span.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        #expect(address % 64 == 0)
    }
}
