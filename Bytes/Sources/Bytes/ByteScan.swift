// MARK: - Testing 16 bytes at once

/// Sixteen bytes of a span, tested together in ``Swift/RawSpan/containsByte(where:)``: build a
/// ``ByteMatches`` from ``matching(_:)`` and ``nonASCII``, combined with `|` (matches any) and `&`
/// (matches all).
///
/// ```swift
/// let hasWildcard = topic.containsByte { $0.matching(UInt8(ascii: "+")) | $0.matching(UInt8(ascii: "#")) }
/// ```
///
/// Each test is two or three vector instructions on all 16 lanes (NEON, or SSE on x86), with no branches,
/// using only lanewise wrapping arithmetic and bitwise operations. Not the standard library's lane
/// comparisons (`.==`, `.>=`) and `SIMDMask` reductions (`any`): those vectorize with a Swift 6.5 compiler,
/// but Swift 6.4's compiles them a lane at a time and reduces through an out-of-line call.
@frozen
public struct ByteLanes: Sendable {
    public var vector: SIMD16<UInt8>

    @inlinable @inline(__always)
    public init(_ vector: SIMD16<UInt8>) { self.vector = vector }

    /// The lanes equal to `byte`.
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

    @inlinable @inline(__always)
    public init(highBits: SIMD16<UInt8>) { self.highBits = highBits }

    /// No lane matches.
    @inlinable @inline(__always)
    public static var none: Self { Self(highBits: .zero) }

    /// Lanes that match either.
    @inlinable @inline(__always)
    public static func | (lhs: Self, rhs: Self) -> Self { Self(highBits: lhs.highBits | rhs.highBits) }

    /// Lanes that match both.
    @inlinable @inline(__always)
    public static func & (lhs: Self, rhs: Self) -> Self { Self(highBits: lhs.highBits & rhs.highBits) }

    /// Whether any lane matches: the two halves ORed as 64-bit words, rather than a reduction across lanes.
    @inlinable @inline(__always)
    public var any: Bool {
        let words = bitCast(highBits & 0x80, to: SIMD2<UInt64>.self)
        return words[0] | words[1] != 0
    }
}

extension RawSpan {
    /// Whether any byte passes `test`, tested 16 at a time: whole 16-byte blocks, then the last 16 bytes
    /// (overlapping the block before them), all ORed together and checked once at the end. A 32-byte
    /// string takes two tests and no branches but the loop's.
    ///
    /// Shorter spans fill one block with overlapping loads (the first and last 8 bytes, or 4, or bytes 0,
    /// `count / 2`, and `count - 1`), which repeats some bytes but leaves none out, so they take one test
    /// too.
    @inlinable @inline(__always)
    public func containsByte(where test: (ByteLanes) -> ByteMatches) -> Bool {
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

    /// Whether `self` and `other` hold the same bytes, compared 16 at a time as
    /// ``containsByte(where:)`` scans: XOR each pair of blocks, OR the differences, and check once.
    @inlinable @inline(__always)
    public func bytesEqual(_ other: RawSpan) -> Bool {
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

extension UTF8Span {
    /// Views `bytes` as UTF-8 in which no byte matches `excluded`, checking both in one pass in the usual
    /// case, ASCII: bytes below 0x80 are each a whole, valid UTF-8 character, so text that's ASCII and has
    /// no `excluded` byte needs no other check. Anything else is validated in full, then scanned for
    /// `excluded` again.
    ///
    /// ```swift
    /// let name = UTF8Span(validating: bytes, excluding: { $0.matching(0) }) // no U+0000
    /// ```
    ///
    /// Returns `nil` if the bytes aren't valid UTF-8 or any matches `excluded`.
    @inlinable @inline(__always)
    @_lifetime(copy bytes)
    public init?(validating bytes: RawSpan, excluding excluded: (ByteLanes) -> ByteMatches) {
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
