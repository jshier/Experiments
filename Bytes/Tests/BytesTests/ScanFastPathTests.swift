import Bytes
import BytesTestSupport
import Testing

/// The scans' fast paths (unchecked 16-byte loads, `cmeq` matching, candidates walked as a mask, typed chunks) against
/// byte loops: every length to 200 and every position, so some input ends exactly where a load ends, with random
/// filler around each match (a mask that read a lane's low bits would show).
@Suite struct ScanFastPathTests {
    static let lengths = Array(0...200)

    /// `count` random bytes, none of them in `excluded`.
    static func filler(_ count: Int, seed: UInt64, excluding excluded: Set<UInt8>) -> [UInt8] {
        var generator = SplitMix64(seed: seed)
        return (0..<count).map { _ in
            var byte = UInt8(truncatingIfNeeded: generator.next())
            while excluded.contains(byte) {
                byte &+= 1
            }
            return byte
        }
    }

    // MARK: The 16-byte scans

    @Test(arguments: lengths)
    func scansAgreeWithByteLoops(count: Int) {
        let targets: [UInt8] = [0x0A, 0x3A]
        let plain = Self.filler(count, seed: UInt64(count) &+ 1, excluding: Set(targets))
        let test = { (lanes: ByteLanes) in lanes.matching(0x0A) | lanes.matching(0x3A) }
        // (Results in locals: `#expect` can't decompose a method call on a non-escapable span.)
        let none = plain.span.bytes.containsByte(where: test)
        #expect(!none)
        #expect(plain.span.bytes.firstByteOffset(where: test) == nil)
        // With non-ASCII bytes (the filler has them), a high-bit-only test beside `cmeq`'s full lanes.
        let nonASCII = plain.firstIndex { $0 >= 0x80 }
        #expect(plain.span.bytes.firstByteOffset { $0.nonASCII | $0.matching(0x0A) } == nonASCII)
        #expect(plain.span.bytes.containsByte { $0.nonASCII | $0.matching(0x0A) } == (nonASCII != nil))
        for position in 0..<count {
            var bytes = plain
            bytes[position] = targets[position % 2]
            let found = bytes.span.bytes.containsByte(where: test)
            #expect(found, "\(position) of \(count)")
            #expect(bytes.span.bytes.firstByteOffset(where: test) == position, "\(position) of \(count)")
            let expected = bytes.firstIndex { $0 >= 0x80 || $0 == 0x0A }
            #expect(bytes.span.bytes.firstByteOffset { $0.nonASCII | $0.matching(0x0A) } == expected, "\(position) of \(count)")
        }
    }

    @Test(arguments: lengths)
    func bytesEqualAgreesWithAByteLoop(count: Int) {
        let a = Self.filler(count, seed: UInt64(count) &+ 1_000, excluding: [])
        let copy = a.map(\.self)
        let same = a.span.bytes.bytesEqual(copy.span.bytes)
        #expect(same)
        var generator = SplitMix64(seed: UInt64(count))
        for position in 0..<count {
            var b = a
            b[position] ^= UInt8(truncatingIfNeeded: generator.next() % 255 + 1)
            let equal = a.span.bytes.bytesEqual(b.span.bytes)
            #expect(!equal, "difference at \(position) of \(count)")
        }
    }

    // MARK: Matches

    /// Each byte value, alone in each lane among varied other bytes, is found there by every form of the mask.
    @Test func everyByteInEveryLane() {
        for target in UInt8.min...UInt8.max {
            for lane in 0..<16 {
                var vector = SIMD16<UInt8>()
                for (index, byte) in Self.filler(16, seed: UInt64(target) << 8 | UInt64(lane), excluding: [target]).enumerated() {
                    vector[index] = byte
                }
                vector[lane] = target
                let matches = ByteLanes(vector).matching(target)
                #expect(matches.any)
                #expect(matches.bitmask == 1 << lane, "\(target) in lane \(lane)")
                #expect(matches.nibbleMask == 1 << (4 * lane + 3), "\(target) in lane \(lane)")
                #expect(matches.firstIndex == lane, "\(target) in lane \(lane)")
            }
        }
    }

    /// `matching(in:)` at its edges, for every byte value: each range's lanes and no others.
    @Test func rangesAtTheirEdges() {
        let ranges: [ClosedRange<UInt8>] = [0...0, 0...0x1F, 0x20...0x7E, 0x41...0x5A, 0x7F...0xFF, 0xFF...0xFF, 0...0xFF]
        for range in ranges {
            for base in stride(from: 0, to: 256, by: 16) {
                let vector = SIMD16<UInt8>((0..<16).map { UInt8(base + $0) })
                var expected: UInt16 = 0
                for lane in 0..<16 where range.contains(UInt8(base + lane)) {
                    expected |= 1 << lane
                }
                let matches = ByteLanes(vector).matching(in: range)
                #expect(matches.bitmask == expected, "\(range) from \(base)")
                #expect(matches.any == (expected != 0))
                #expect(matches.firstIndex == (expected == 0 ? nil : expected.trailingZeroBitCount), "\(range) from \(base)")
            }
        }
    }

    /// A comparison's mask, taken as it is, gives the same lanes as the comparison.
    @Test func comparisonMasks() {
        var generator = SplitMix64(seed: 3)
        for _ in 0..<2_000 {
            let a = SIMD16<UInt8>((0..<16).map { _ in UInt8(truncatingIfNeeded: generator.next() % 8) })
            let b = SIMD16<UInt8>((0..<16).map { _ in UInt8(truncatingIfNeeded: generator.next() % 8) })
            var equal: UInt16 = 0, below: UInt16 = 0
            for lane in 0..<16 {
                if a[lane] == b[lane] { equal |= 1 << lane }
                if a[lane] < b[lane] { below |= 1 << lane }
            }
            #expect(ByteMatches(a .== b).bitmask == equal)
            #expect(ByteMatches(a .< b).bitmask == below)
            #expect(ByteMatches(a .< b).nibbleMask.nonzeroBitCount == below.nonzeroBitCount)
        }
    }

    // MARK: Blocks and chunks

    /// The last whole block of every length, with its match in its last byte, and a block made from 64 bytes.
    @Test func lastWholeBlocks() {
        for count in 64...200 {
            var bytes = Self.filler(count, seed: UInt64(count), excluding: [0x0A])
            bytes[count - 1] = 0x0A
            bytes[count - 64] = 0x0A
            let mask = bytes.span.bytes.byteBlock(at: count - 64).mask { $0.matching(0x0A) }
            #expect(mask == UInt64(1) << 63 | 1, "\(count)")
        }
        let bytes = Self.filler(64, seed: 5, excluding: [])
        var array = InlineArray<64, UInt8>(repeating: 0)
        for index in 0..<64 {
            array[index] = bytes[index]
        }
        for byte in Set(bytes) {
            #expect(ByteBlock(array).mask { $0.matching(byte) } == bytes.span.bytes.byteBlock(at: 0).mask { $0.matching(byte) })
        }
    }

    @Test func blockPastTheEndTraps() async {
        await #expect(processExitsWith: .failure) {
            let bytes = [UInt8](repeating: 0, count: 100)
            _ = bytes.span.bytes.byteBlock(at: 37).mask { $0.matching(0) }
        }
    }

    /// Whole chunks of 1, 16, 64, and 128 bytes, for every length: their count and contents, the remainder left out.
    @Test func chunks() {
        func check<let n: Int>(_ type: InlineArray<n, UInt8>.Type) {
            for count in 0...(3 * n + 7) {
                let bytes = Self.filler(count, seed: UInt64(count), excluding: [])
                let chunks = bytes.span.bytes.chunks(of: type)
                #expect(chunks.count == count / n, "\(n)-byte chunks of \(count)")
                for index in chunks.indices {
                    let chunk = chunks[index]
                    for offset in 0..<n where chunk[offset] != bytes[index * n + offset] {
                        Issue.record("\(n)-byte chunk \(index) of \(count), byte \(offset)")
                    }
                }
            }
        }
        check(InlineArray<1, UInt8>.self)
        check(InlineArray<16, UInt8>.self)
        check(InlineArray<64, UInt8>.self)
        check(InlineArray<128, UInt8>.self)
    }

    // MARK: Pattern search with dense candidates

    /// Positions where `pattern` starts in `data`, scanning `range` in its order.
    static func naive(_ pattern: [UInt8], in data: [UInt8], _ range: some Sequence<Int>) -> Int? {
        range.first { start in
            start + pattern.count <= data.count && (0..<pattern.count).allSatisfy { data[start + $0] == pattern[$0] }
        }
    }

    /// Every offset a candidate (filler of the pattern's first and last byte), or a quarter of them (random `A`s and
    /// `B`s), with the pattern planted at each position near both ends, searched from several starts.
    static let searchSizes = [2, 3, 4, 5, 7, 8, 11, 16]

    @Test(arguments: searchSizes)
    func searchWithDenseCandidates(size: Int) {
        Self.withGroup(size: size) { Self.denseSearch($0) }
    }

    /// Two matches in one block of 16 offsets, at every gap that fits, and a pattern overlapping itself (all `A`s in
    /// `A`s): the first and last set lanes must be told apart, in both directions and from several starts.
    @Test(arguments: searchSizes)
    func searchWithTwoMatchesInABlock(size: Int) {
        Self.withGroup(size: size) { Self.pairedSearch($0) }
    }

    /// Calls `body` with the `ByteGroup` type of `size` bytes.
    static func withGroup(size: Int, _ body: (any ByteGroup.Type) -> Void) {
        switch size {
        case 2: body(Byte2.self)
        case 3: body(Byte3.self)
        case 4: body(Byte4.self)
        case 5: body(Byte5.self)
        case 7: body(Byte7.self)
        case 8: body(Byte8.self)
        case 11: body(Byte11.self)
        default: body(Byte16.self)
        }
    }

    /// `bytes` as a `T`.
    static func group<T: ByteGroup>(_: T.Type, _ bytes: [UInt8]) -> T {
        var value: T.Integer = 0
        for (index, byte) in bytes.enumerated() {
            value |= T.Integer(byte) << (8 * index)
        }
        return T(littleEndian: value)
    }

    /// Checks both searches against `naive` from several starts.
    static func checkSearches<T: ByteGroup>(_ group: T, _ pattern: [UInt8], in data: [UInt8], _ label: String) {
        for skip in [0, 1, 7, 15, 16, 33] where skip <= data.count {
            var reader = BytesReader(data.span)
            try? reader.skip(byteCount: skip)
            #expect(reader.firstByteOffset(of: group) == naive(pattern, in: data, skip..<data.count), "first \(label) from \(skip)")
            #expect(reader.lastByteOffset(of: group) == naive(pattern, in: data, (skip..<data.count).reversed()),
                    "last \(label) from \(skip)")
        }
    }

    static func pairedSearch<T: ByteGroup>(_: T.Type) {
        let size = T.byteCount
        let pattern = [0x41] + [UInt8](repeating: 0x43, count: size - 1)
        let planted = group(T.self, pattern)
        for count in [48, 64, 81] {
            for gap in size...max(size, 15) {
                for first in stride(from: 0, through: count - size - gap, by: 3) {
                    var data = [UInt8](repeating: 0x42, count: count)
                    data.replaceSubrange(first..<(first + size), with: pattern)
                    data.replaceSubrange((first + gap)..<(first + gap + size), with: pattern)
                    checkSearches(planted, pattern, in: data, "\(size) at \(first) and \(first + gap) in \(count)")
                }
            }
        }
        // A pattern of all `A`s in `A`s matches at every offset.
        let overlapping = [UInt8](repeating: 0x41, count: size)
        for count in [size, size + 1, 31, 64, 81] {
            checkSearches(group(T.self, overlapping), overlapping, in: [UInt8](repeating: 0x41, count: count), "\(size) overlapping in \(count)")
        }
    }

    static func denseSearch<T: ByteGroup>(_: T.Type) {
        let size = T.byteCount
        // `A`, then `C`s, then `A`: candidates wherever the filler has two `A`s `size - 1` apart, never a match unless
        // planted. (For two bytes, `AC`: `A` filler has no candidates, as a candidate needs the tail too, so it tests
        // the planted match's block alone.)
        let pattern = size == 2 ? [0x41, 0x43] : [0x41] + [UInt8](repeating: 0x43, count: size - 2) + [0x41]
        let planted = group(T.self, pattern)
        var generator = SplitMix64(seed: UInt64(size))
        for count in 0...80 {
            let fillers = [
                [UInt8](repeating: 0x41, count: count),
                (0..<count).map { _ in 0x41 + UInt8(truncatingIfNeeded: generator.next() & 1) },
            ]
            for filler in fillers {
                let candidates = [0, 1, 15, 16, 17, count - size - 1, count - size]
                let positions = Array(Set(candidates.filter { $0 >= 0 && $0 <= count - size }))
                for position in [nil] + positions.map(Optional.some) {
                    var data = filler
                    if let position {
                        data.replaceSubrange(position..<(position + size), with: pattern)
                    }
                    checkSearches(planted, pattern, in: data, "\(size) in \(count) at \(position as Int?)")
                }
            }
        }
    }
}
