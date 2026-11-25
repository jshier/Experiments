@testable import BytesCompression
import Testing

/// The codecs' table storage: `StrideTable` (whole SIMD groups at a 64-byte boundary, filled and cleared a group at a
/// time) and `UninitializedBuffer` (storage written before it's read).
@Suite struct StrideTableTests {
    /// Every entry of `table` from `range`, as an array (spans can't be captured by `#expect`'s closures).
    static func entries<Group: SIMD & BitwiseCopyable>(_ table: borrowing StrideTable<Group>, _ range: Range<Int>) -> [Group.Scalar] {
        let span = table.span
        return range.map { span[$0] }
    }

    /// Every group starts aligned for its type by construction, whatever the group's width, and fills store whole groups.
    @Test func groupsAreAlignedAndFillsCoverWholeGroups() {
        let narrow = StrideTable<SIMD8<UInt16>>(minimumCount: 1_001, repeating: 0x400)
        #expect(narrow.groupCount == 126 && narrow.count == 1_008) // 1,001 entries round up to whole groups.
        #expect(UInt(bitPattern: narrow.base) % 64 == 0)
        #expect(Self.entries(narrow, 0..<1_008).allSatisfy { $0 == 0x400 })

        var wide = StrideTable<SIMD32<Int16>>(uninitializedGroups: 4)
        #expect(UInt(bitPattern: wide.base) % 64 == 0 && wide.count == 128)
        wide.fill(.min)
        wide.fill(7, groups: 1) // Only the first group's 32 entries.
        #expect(Self.entries(wide, 0..<32).allSatisfy { $0 == 7 } && Self.entries(wide, 32..<128).allSatisfy { $0 == .min })
        wide.clear(groups: 2)
        #expect(Self.entries(wide, 0..<64).allSatisfy { $0 == 0 } && Self.entries(wide, 64..<128).allSatisfy { $0 == .min })
        do {
            var entries = wide.mutableSpan
            entries[127] = 1
        }
        #expect(Self.entries(wide, 127..<128) == [1])
    }

    /// A table grows by replacement, its new groups uninitialized; an empty table holds nothing and fills nothing.
    @Test func reserveGrowsAndEmptyTablesFillNothing() {
        var table = StrideTable<SIMD8<UInt16>>(uninitializedGroups: 0)
        let empty = table.isEmpty // (#expect can't read a ~Copyable value's property.)
        #expect(empty)
        table.fill(1)
        table.clear()
        table.reserve(groups: 3)
        #expect(table.groupCount == 3 && UInt(bitPattern: table.base) % 64 == 0)
        table.fill(9)
        #expect(Self.entries(table, 0..<24).allSatisfy { $0 == 9 })
        table.reserve(groups: 2) // Never shrinks.
        #expect(table.groupCount == 3)
    }

    @Test func uninitializedBuffersHoldTheirCount() {
        var bytes = UninitializedBuffer<UInt8>(count: 1_000)
        #expect(bytes.count == 1_000 && UInt(bitPattern: bytes.base) % 64 == 0)
        do {
            var span = bytes.mutableSpan
            for index in span.indices {
                span[index] = UInt8(truncatingIfNeeded: index)
            }
        }
        let span = bytes.span
        var written = span.count == 1_000
        for index in span.indices where span[index] != UInt8(truncatingIfNeeded: index) {
            written = false
        }
        #expect(written)
        let empty = UninitializedBuffer<UInt64>(count: 0)
        let isEmpty = empty.span.isEmpty // `#expect` takes no `~Escapable` values.
        #expect(isEmpty)
    }
}

/// Constant tables written as literals or built once, against their derivations.
@Suite struct ConstantTableTests {
    /// Brotli's insert-and-copy lengths: the literal (`brotliCommandTable`) is what `makeCommandTable` computes.
    @Test func brotliCommandTableIsItsDerivation() {
        #expect(brotliCommandTable == BrotliStream.makeCommandTable())
    }

    /// LZBITMAP's shuffles: each bitmap's literal lanes take the next literal's index, the others the history's
    /// lane (8 + lane), and byte 8 the literal count.
    @Test func lzbitmapShufflesPickEachBitmapsLiterals() {
        let shuffles = LZBitmapWorkspace.shuffles
        #expect(shuffles.count == 4096)
        for bitmap in [0, 1, 0x80, 0xA5, 0xFF] {
            let row = Array(shuffles[(bitmap * 16)..<(bitmap * 16 + 9)])
            var literal: UInt8 = 0
            var expected: [UInt8] = []
            for lane in 0..<8 {
                if bitmap >> lane & 1 != 0 {
                    expected.append(literal)
                    literal += 1
                } else {
                    expected.append(UInt8(8 + lane))
                }
            }
            expected.append(literal)
            #expect(row == expected, "bitmap \(bitmap)")
        }
    }
}
