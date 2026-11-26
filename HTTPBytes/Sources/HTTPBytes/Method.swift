public import Bytes

/// A request method (RFC 9110 §9): a token of 1 to 16 bytes, kept inline in two words.
///
/// Comparing two methods is comparing two pairs of words, and the standard methods are constants (`.get`, `.post`),
/// so `method == .get` is two compares and no table. A method longer than 16 bytes (no registered one is: the
/// longest, `UPDATEREDIRECTREF`, has 17 and is WebDAV's) can't be one of these; parsers still hand it out as bytes.
///
/// Methods are case-sensitive (RFC 9110 §9.1): `get` isn't `GET`.
@frozen
public struct HTTPMethod: Sendable, Hashable, CustomStringConvertible {
    /// Bytes 0–7, the first in the low byte; zeros after the method.
    @usableFromInline let low: UInt64
    /// Bytes 8–15, the same way.
    @usableFromInline let high: UInt64

    @inlinable @inline(__always)
    init(low: UInt64, high: UInt64 = 0) {
        self.low = low
        self.high = high
    }

    /// The method spelled by `token`, or `nil` if `token` is empty, longer than 16 bytes, or not a token (RFC 9110
    /// §5.6.2: `!#$%&'*+-.^_\`|~`, digits, and letters).
    ///
    /// - Parameter token: The method's bytes.
    @inlinable
    public init?(_ token: RawSpan) {
        let count = token.byteCount
        guard count > 0, count <= 16, !token.containsByte(where: HTTPCharacters.nonToken) else { return nil }
        var words: (UInt64, UInt64) = (0, 0)
        for offset in 0..<count {
            let byte = UInt64(token.load(fromByteOffset: offset, as: UInt8.self))
            if offset < 8 {
                words.0 |= byte &<< UInt64(offset &* 8)
            } else {
                words.1 |= byte &<< UInt64((offset &- 8) &* 8)
            }
        }
        self.init(low: words.0, high: words.1)
    }

    /// The method's length in bytes.
    @inlinable
    public var byteCount: Int {
        // Tokens have no zero bytes, so the zeros after the method are the high ones.
        high == 0 ? 8 &- low.leadingZeroBitCount &>> 3 : 16 &- high.leadingZeroBitCount &>> 3
    }

    /// Calls `body` with the method's bytes.
    @inlinable
    public func withBytes<Result: ~Copyable, Failure: Error>(
        _ body: (RawSpan) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let words: InlineArray<2, UInt64> = [low.littleEndian, high.littleEndian]
        return try body(words.span.bytes.extracting(0..<byteCount))
    }

    public var description: String {
        withBytes { bytes in String(decoding: (0..<bytes.byteCount).map { bytes.load(fromByteOffset: $0, as: UInt8.self) }, as: UTF8.self) }
    }

    /// `GET`.
    @inlinable public static var get: Self { Self(low: 0x54_45_47) }
    /// `HEAD`.
    @inlinable public static var head: Self { Self(low: 0x44_41_45_48) }
    /// `POST`.
    @inlinable public static var post: Self { Self(low: 0x54_53_4F_50) }
    /// `PUT`.
    @inlinable public static var put: Self { Self(low: 0x54_55_50) }
    /// `DELETE`.
    @inlinable public static var delete: Self { Self(low: 0x45_54_45_4C_45_44) }
    /// `CONNECT`.
    @inlinable public static var connect: Self { Self(low: 0x54_43_45_4E_4E_4F_43) }
    /// `OPTIONS`.
    @inlinable public static var options: Self { Self(low: 0x53_4E_4F_49_54_50_4F) }
    /// `TRACE`.
    @inlinable public static var trace: Self { Self(low: 0x45_43_41_52_54) }
    /// `PATCH` (RFC 5789).
    @inlinable public static var patch: Self { Self(low: 0x48_43_54_41_50) }
}

/// The character classes HTTP's grammar uses, as 16-lane tests for `RawSpan.containsByte(where:)`,
/// `firstByteOffset(where:)`, and `ByteBlock.mask(_:)`.
public enum HTTPCharacters {
    /// Lanes that aren't token characters (`tchar`, RFC 9110 §5.6.2): two one-register table lookups on the low and
    /// high nibbles, ANDed (a lane is a token character when its row's bit is set in its column's entry).
    @inlinable @inline(__always)
    public static func nonToken(_ lanes: ByteLanes) -> ByteMatches {
        // Bit (row - 2) of `columns[low nibble]` is set when (row, column) is a token character; `rows[high nibble]` is
        // that bit, or 0 for rows 0, 1, and 8–15 (controls, space, DEL is excluded by its column, and non-ASCII).
        let columns = SIMD16<UInt8>(0x3A, 0x3F, 0x3E, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3E, 0x3E, 0x3D, 0x15, 0x34, 0x15, 0x3D, 0x1C)
        let rows = SIMD16<UInt8>(0, 0, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0, 0, 0, 0, 0, 0, 0, 0)
        let column = ByteLanes(lanes.vector & SIMD16(repeating: 0x0F)).lookup(in: columns)
        let row = ByteLanes(lanes.vector &>> SIMD16(repeating: 4)).lookup(in: rows)
        return ByteMatches((column & row) .== SIMD16(repeating: 0))
    }

    /// Lanes that end a field value or can't be in one (RFC 9110 §5.5): controls other than horizontal tab (CR and LF
    /// among them), and DEL. Three comparisons; no lookup.
    @inlinable @inline(__always)
    public static func fieldValueStop(_ lanes: ByteLanes) -> ByteMatches {
        let vector = lanes.vector
        let control = (vector .< SIMD16(repeating: 0x20)) .& (vector .!= SIMD16(repeating: 0x09))
        return ByteMatches(control .| (vector .== SIMD16(repeating: 0x7F)))
    }

    /// Lanes that are controls (horizontal tab included) or DEL: ``fieldValueStop`` and tabs, in two comparisons and an
    /// OR (``fieldValueStop`` takes five, to leave tabs out). A scan for a field line's end uses this and checks the
    /// byte it stops at: CR then LF ends the line, and anything else (a tab in the value, rarely) is looked at byte by
    /// byte. On 64-byte blocks, 12 vector operations instead of 20.
    @inlinable @inline(__always)
    public static func controlOrDelete(_ lanes: ByteLanes) -> ByteMatches {
        let vector = lanes.vector
        return ByteMatches((vector .< SIMD16(repeating: 0x20)) .| (vector .== SIMD16(repeating: 0x7F)))
    }

    /// Lanes that end a request target or can't be in one: controls, space, DEL, and bytes above 0x7F (a URI is ASCII,
    /// RFC 3986 §2; raw UTF-8 must be percent-encoded). Two comparisons. The target's own grammar (RFC 9112 §3.2) is
    /// checked separately where it matters.
    @inlinable @inline(__always)
    public static func targetStop(_ lanes: ByteLanes) -> ByteMatches {
        let vector = lanes.vector
        return ByteMatches((vector .<= SIMD16(repeating: 0x20)) .| (vector .>= SIMD16(repeating: 0x7F)))
    }
}
