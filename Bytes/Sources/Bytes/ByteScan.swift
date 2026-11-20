// MARK: - Testing 16 bytes at once

/// Sixteen bytes of a span, tested together in `RawSpan.containsByte(where:)`: build a
/// ``ByteMatches`` from ``matching(_:)-(UInt8)`` and ``nonASCII``, combined with `|` (matches any) and `&`
/// (matches all).
///
/// ```swift
/// let hasWildcard = topic.containsByte { $0.matching(UInt8(ascii: "+")) | $0.matching(UInt8(ascii: "#")) }
/// ```
///
/// Each test is two or three vector instructions on all 16 lanes (NEON, or SSE on x86), with no branches,
/// using only lanewise wrapping arithmetic and bitwise operations. With Swift 6.4, the standard library's
/// comparisons of two vectors (`a .== b`) are one instruction too, but those against a scalar
/// (`v .== 0`) compile a lane at a time, and `SIMDMask.any()` is inlined in some loops and an
/// out-of-line call in others. Swift 6.5 compiles all of them to vector instructions.
@frozen
public struct ByteLanes: Sendable {
    /// The 16 bytes, lane 0 first.
    public var vector: SIMD16<UInt8>

    /// Wraps 16 bytes for testing.
    ///
    /// - Parameter vector: The 16 bytes.
    @inlinable @inline(__always)
    public init(_ vector: SIMD16<UInt8>) { self.vector = vector }

    /// Tests which lanes equal `byte`.
    ///
    /// - Parameter byte: The byte to look for.
    /// - Returns: The lanes equal to `byte`.
    @inlinable @inline(__always)
    public func matching(_ byte: UInt8) -> ByteMatches {
        // `x &- 1 & ~x` has its high bit set exactly when `x` is 0: 1 through 0x80 lose no high bit to the
        // subtraction, and 0x81 through 0xFF have it cleared by `~x`. Lanes don't borrow from each other.
        let difference = vector ^ SIMD16(repeating: byte)
        return ByteMatches(highBits: (difference &- 1) & ~difference)
    }

    /// The lanes that aren't ASCII (0x80 and above): any lead or continuation byte of a multi-byte UTF-8
    /// sequence.
    @inlinable @inline(__always)
    public var nonASCII: ByteMatches { ByteMatches(highBits: vector) }
}

/// Which of 16 lanes matched a ``ByteLanes`` test: the high bit of each lane.
@frozen
public struct ByteMatches: Sendable {
    /// The high bit of each lane is set where it matched; the low bits are meaningless.
    public var highBits: SIMD16<UInt8>

    /// Creates matches from the high bit of each lane.
    ///
    /// - Parameter highBits: Lanes whose high bit is set where they matched; the low bits are ignored.
    @inlinable @inline(__always)
    public init(highBits: SIMD16<UInt8>) { self.highBits = highBits }

    /// No lane matches.
    @inlinable @inline(__always)
    public static var none: Self { Self(highBits: .zero) }

    /// Combines two sets of matches into the lanes that match either.
    ///
    /// - Parameters:
    ///   - lhs: One set of matches.
    ///   - rhs: The other.
    /// - Returns: The lanes that match `lhs` or `rhs`.
    @inlinable @inline(__always)
    public static func |(lhs: Self, rhs: Self) -> Self { Self(highBits: lhs.highBits | rhs.highBits) }

    /// Combines two sets of matches into the lanes that match both.
    ///
    /// - Parameters:
    ///   - lhs: One set of matches.
    ///   - rhs: The other.
    /// - Returns: The lanes that match `lhs` and `rhs`.
    @inlinable @inline(__always)
    public static func &(lhs: Self, rhs: Self) -> Self { Self(highBits: lhs.highBits & rhs.highBits) }

    /// Whether any lane matches: the two halves ORed as 64-bit words, rather than a reduction across lanes.
    @inlinable @inline(__always)
    public var any: Bool {
        let words = bitCast(highBits & 0x80, to: SIMD2<UInt64>.self)
        return words[0] | words[1] != 0
    }

    /// The matching lanes, one bit each: lane i in bit i.
    ///
    /// ```swift
    /// var lanes = block.matching(0).bitmask
    /// while lanes != 0 {
    ///     check(offset + lanes.trailingZeroBitCount)
    ///     lanes &= lanes &- 1
    /// }
    /// ```
    ///
    /// Each half's high bits shifted to bit 0 of their bytes, then gathered into one byte by a multiply
    /// (byte i's bit lands in bit 56 + i): portable, about a dozen instructions, no branches.
    @inlinable @inline(__always)
    public var bitmask: UInt16 {
        let halves = bitCast(highBits, to: SIMD2<UInt64>.self)
        // Lane i is byte i of the halves on a little-endian CPU; a big-endian one swaps them back.
        let first = UInt64(littleEndian: halves[0])
        let second = UInt64(littleEndian: halves[1])
        // Parenthesized: Swift's shifts bind tighter than multiplication.
        let low = (((first &>> 7) & 0x0101_0101_0101_0101) &* 0x0102_0408_1020_4080) &>> 56
        let high = (((second &>> 7) & 0x0101_0101_0101_0101) &* 0x0102_0408_1020_4080) &>> 56
        return UInt16(truncatingIfNeeded: low | high &<< 8)
    }

    /// The matching lanes, four bits each: lane i's match in bit 4i + 3, the other bits 0.
    ///
    /// ```swift
    /// var lanes = block.matching(0).nibbleMask
    /// while lanes != 0 {
    ///     check(offset + lanes.trailingZeroBitCount / 4)
    ///     lanes &= lanes &- 1
    /// }
    /// ```
    ///
    /// Four instructions on ARM64 (`sshr` spreading each lane's high bit through the lane, then `shrn`, `fmov`,
    /// `and`: each 16-bit pair of lanes shifted right by 4 and narrowed to a byte), against ``bitmask``'s dozen:
    /// the form to use when lanes are found by counting zero bits, as ``firstIndex`` does.
    @inlinable @inline(__always)
    public var nibbleMask: UInt64 {
        #if _endian(little)
        // The narrowing takes the high half of even lanes and the low half of odd ones, so every bit of a lane
        // must say whether it matched: only its high bit does until it's spread. (Without this, an odd lane
        // whose bit 3 happened to be set, as `matching(_:)` leaves 'p' (0x70), read as a match.)
        let full = bitCast(bitCast(highBits, to: SIMD16<Int8>.self) &>> 7, to: SIMD16<UInt8>.self)
        let pairs = bitCast(full, to: SIMD8<UInt16>.self)
        let narrowed = (pairs &>> 4)._lowBytes
        return bitCast(narrowed, to: UInt64.self) & 0x8888_8888_8888_8888
        #else
        // Lane i in bit i, spread to bit 4i + 3.
        var lanes = UInt64(bitmask)
        lanes = (lanes | lanes &<< 24) & 0x0000_00FF_0000_00FF
        lanes = (lanes | lanes &<< 12) & 0x000F_000F_000F_000F
        lanes = (lanes | lanes &<< 6) & 0x0303_0303_0303_0303
        lanes = (lanes | lanes &<< 3) & 0x1111_1111_1111_1111
        return lanes &<< 3
        #endif
    }

    /// The first matching lane, or `nil` if none matches: from ``nibbleMask``, four instructions and a test.
    @inlinable @inline(__always)
    public var firstIndex: Int? {
        let lanes = nibbleMask
        return lanes == 0 ? nil : lanes.trailingZeroBitCount &>> 2
    }
}

public extension RawSpan {
    /// Whether any byte passes `test`, tested 16 at a time: whole 16-byte blocks, then the last 16 bytes
    /// (overlapping the block before them), all ORed together and checked once at the end. A 32-byte
    /// string takes two tests and no branches but the loop's.
    ///
    /// Shorter spans fill one block with overlapping loads (the first and last 8 bytes, or 4, or bytes 0,
    /// `count / 2`, and `count - 1`), which repeats some bytes but leaves none out, so they take one test
    /// too.
    ///
    /// - Parameter test: Builds the matches for one block of 16 bytes, from ``ByteLanes/matching(_:)-(UInt8)`` and
    ///   ``ByteLanes/nonASCII``. It may see some bytes more than once.
    /// - Returns: `true` if `test` matched any byte; `false` for an empty span.
    @inlinable @inline(__always)
    func containsByte(where test: (ByteLanes) -> ByteMatches) -> Bool {
        // Checked loads: the offsets are in bounds by construction, and the checks fold away.
        let count = byteCount
        guard count >= 16 else {
            let block: SIMD16<UInt8>
            switch count {
            case 8...:
                block = bitCast(SIMD2(load(fromByteOffset: 0, as: UInt64.self), load(fromByteOffset: count &- 8, as: UInt64.self)),
                                to: SIMD16<UInt8>.self)
            case 4...:
                let (first, last) = (load(fromByteOffset: 0, as: UInt32.self), load(fromByteOffset: count &- 4, as: UInt32.self))
                block = bitCast(SIMD4(first, last, first, last), to: SIMD16<UInt8>.self)
            case 1...:
                let word = UInt32(load(fromByteOffset: 0, as: UInt8.self))
                    | UInt32(load(fromByteOffset: count / 2, as: UInt8.self)) &<< 8
                    | UInt32(load(fromByteOffset: count &- 1, as: UInt8.self)) &<< 16
                    | UInt32(load(fromByteOffset: 0, as: UInt8.self)) &<< 24
                block = bitCast(SIMD4(repeating: word), to: SIMD16<UInt8>.self)
            default:
                return false
            }
            return test(ByteLanes(block)).any
        }
        var found = ByteMatches.none
        var offset = 0
        while offset < count &- 16 {
            found = found | test(ByteLanes(load(fromByteOffset: offset, as: SIMD16<UInt8>.self)))
            offset += 16 // Not `&+=`: a non-wrapping add tells the optimizer `offset` stays non-negative.
        }
        found = found | test(ByteLanes(load(fromByteOffset: count &- 16, as: SIMD16<UInt8>.self)))
        return found.any
    }

    /// The offset of the first byte that matches `test`, or `nil`: a terminator, a delimiter, the first byte
    /// that isn't ASCII.
    ///
    /// ```swift
    /// let end = bytes.firstByteOffset { $0.matching(0) }   // a C string's NUL
    /// ```
    ///
    /// Scans 16 bytes per test, as ``containsByte(where:)`` does, and stops at the first block with a match.
    /// The last block overlaps the one before it, and spans shorter than 16 bytes are tested in one block of
    /// overlapping loads; bytes seen twice were already known not to match, so the first match found is the
    /// first in the span.
    ///
    /// - Parameter test: Builds the matches for one block of 16 bytes, from ``ByteLanes/matching(_:)-(UInt8)`` and
    ///   ``ByteLanes/nonASCII``. It may see some bytes more than once.
    /// - Returns: The offset of the first matching byte, or `nil` if none matches.
    @inlinable @inline(__always)
    func firstByteOffset(where test: (ByteLanes) -> ByteMatches) -> Int? {
        // Checked loads: the offsets are in bounds by construction, and the checks fold away.
        let count = byteCount
        guard count >= 16 else {
            switch count {
            case 8...:
                // Lanes 0–7 are offsets 0–7; lanes 8–15, offsets `count - 8` on.
                let block = bitCast(SIMD2(load(fromByteOffset: 0, as: UInt64.self), load(fromByteOffset: count &- 8, as: UInt64.self)),
                                    to: SIMD16<UInt8>.self)
                guard let lane = test(ByteLanes(block)).firstIndex else { return nil }
                return lane < 8 ? lane : count &- 16 &+ lane
            case 4...:
                // Lanes 0–3 are offsets 0–3; lanes 4–7, offsets `count - 4` on (8–15 repeat them).
                let (first, last) = (load(fromByteOffset: 0, as: UInt32.self), load(fromByteOffset: count &- 4, as: UInt32.self))
                guard let lane = test(ByteLanes(bitCast(SIMD4(first, last, first, last), to: SIMD16<UInt8>.self))).firstIndex else {
                    return nil
                }
                return lane < 4 ? lane : count &- 8 &+ lane
            case 1...:
                // Lanes 0, 1, 2 are offsets 0, `count / 2`, `count - 1`, in order (3 repeats offset 0).
                let middle = count / 2
                let word = UInt32(load(fromByteOffset: 0, as: UInt8.self))
                    | UInt32(load(fromByteOffset: middle, as: UInt8.self)) &<< 8
                    | UInt32(load(fromByteOffset: count &- 1, as: UInt8.self)) &<< 16
                    | UInt32(load(fromByteOffset: 0, as: UInt8.self)) &<< 24
                guard let lane = test(ByteLanes(bitCast(SIMD4(repeating: word), to: SIMD16<UInt8>.self))).firstIndex else {
                    return nil
                }
                return switch lane & 3 { case 1: middle; case 2: count &- 1; default: 0 }
            default:
                return nil
            }
        }
        var offset = 0
        while offset < count &- 16 {
            if let lane = test(ByteLanes(load(fromByteOffset: offset, as: SIMD16<UInt8>.self))).firstIndex {
                return offset &+ lane
            }
            offset += 16 // Not `&+=`: a non-wrapping add tells the optimizer `offset` stays non-negative.
        }
        guard let lane = test(ByteLanes(load(fromByteOffset: count &- 16, as: SIMD16<UInt8>.self))).firstIndex else { return nil }
        return count &- 16 &+ lane
    }

    /// Compares two spans' bytes 16 at a time, as ``containsByte(where:)`` scans: XOR each pair of
    /// blocks, OR the differences, and check once.
    ///
    /// - Parameter other: The span to compare with.
    /// - Returns: `true` if both spans have the same length and bytes.
    @inlinable @inline(__always)
    func bytesEqual(_ other: RawSpan) -> Bool {
        let count = byteCount
        guard count == other.byteCount else { return false }
        guard count >= 16 else {
            switch count {
            // Parenthesized: `^` and `|` have the same precedence in Swift.
            case 8...:
                return (load(fromByteOffset: 0, as: UInt64.self) ^ other.load(fromByteOffset: 0, as: UInt64.self))
                    | (load(fromByteOffset: count &- 8, as: UInt64.self) ^ other.load(fromByteOffset: count &- 8, as: UInt64.self)) == 0
            case 4...:
                return (load(fromByteOffset: 0, as: UInt32.self) ^ other.load(fromByteOffset: 0, as: UInt32.self))
                    | (load(fromByteOffset: count &- 4, as: UInt32.self) ^ other.load(fromByteOffset: count &- 4, as: UInt32.self)) == 0
            default:
                var difference: UInt8 = 0
                for offset in 0..<count {
                    difference |= load(fromByteOffset: offset, as: UInt8.self) ^ other.load(fromByteOffset: offset, as: UInt8.self)
                }
                return difference == 0
            }
        }
        var difference = SIMD16<UInt8>.zero
        var offset = 0
        while offset < count &- 16 {
            difference |= load(fromByteOffset: offset, as: SIMD16<UInt8>.self) ^ other.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            offset += 16
        }
        difference |= load(fromByteOffset: count &- 16, as: SIMD16<UInt8>.self)
            ^ other.load(fromByteOffset: count &- 16, as: SIMD16<UInt8>.self)
        let words = bitCast(difference, to: SIMD2<UInt64>.self)
        return words[0] | words[1] == 0
    }
}

public extension UTF8Span {
    /// Views `bytes` as UTF-8 in which no byte matches `excluded`, or returns `nil` if the bytes aren't
    /// valid UTF-8 or any matches `excluded`.
    ///
    /// Both are checked in one pass in the usual case, ASCII: bytes below 0x80 are each a whole, valid
    /// UTF-8 character, so text that's ASCII and has no `excluded` byte needs no other check. Anything
    /// else is validated in full, then scanned for `excluded` again.
    ///
    /// ```swift
    /// let name = UTF8Span(validating: bytes, excluding: { $0.matching(0) }) // no U+0000
    /// ```
    ///
    /// - Parameters:
    ///   - bytes: The bytes to view.
    ///   - excluded: Builds the matches for one block of 16 bytes, as for `RawSpan.containsByte(where:)`;
    ///     no byte may match.
    @inlinable @inline(__always)
    @_lifetime(copy bytes)
    init?(validating bytes: RawSpan, excluding excluded: (ByteLanes) -> ByteMatches) {
        if !bytes.containsByte(where: { $0.nonASCII | excluded($0) }) {
            // Unsafe: skips the standard library's validation. Safe: every byte was just checked to be
            // below 0x80, and such bytes are valid UTF-8 in any order. No safe initializer skips the
            // validation, which is an out-of-line call; this check is inline, 16 bytes at a time.
            self = unsafe UTF8Span(unchecked: Span(viewing: bytes), isKnownASCII: true)
            return
        }
        guard let text = try? UTF8Span(validating: Span(viewing: bytes)), !bytes.containsByte(where: excluded) else {
            return nil
        }
        self = text
    }
}
