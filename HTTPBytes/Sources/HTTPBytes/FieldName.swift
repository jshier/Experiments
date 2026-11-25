import Bytes

/// A field name HTTPBytes knows: one of about 120 common names (every name in HPACK's and QPACK's static tables, the
/// pseudo-header fields, and others in wide use), as a small index.
///
/// Comparing two known names is comparing two bytes, and a parser finds a name's index with one hash, one table
/// load, and one comparison of the bytes (``init(caseInsensitive:)``). Names it doesn't know stay bytes: a parsed
/// field's name is always available as a span, and an ``HTTPFieldStore`` keeps unknown names' bytes.
///
/// ```swift
/// if HTTPFieldName(caseInsensitive: field.name) == .contentLength { … }
/// ```
///
/// The constants are swift-http-types' `HTTPField.Name` spellings (`.contentType`, `.eTag`), plus `pseudo…` for
/// the pseudo-header fields (`.pseudoPath` is `:path`).
@frozen
public struct HTTPFieldName: Sendable, Hashable, CustomStringConvertible {
    /// The name's index in the table: 0 up to ``knownCount``.
    public let index: UInt8

    @inlinable @inline(__always)
    init(uncheckedIndex index: UInt8) { self.index = index }

    /// The known name at `index`, or `nil` past the table.
    @inlinable
    public init?(index: Int) {
        guard UInt(bitPattern: index) < UInt(Self.knownCount) else { return nil }
        self.index = UInt8(truncatingIfNeeded: index)
    }

    /// The known name spelled `name` in any case, or `nil` for a name the table doesn't have.
    ///
    /// The name's length and five of its bytes, ASCII-lowercased, hash to a slot of a perfect hash table (generated:
    /// no two known names share a slot); the slot's name is then compared with `name`'s bytes in 8-byte words, each
    /// ORed with 0x20. That folds case exactly for token characters (letters change case; digits, `-`, and the other
    /// characters the table's names use already have the bit set), so `name` must be a token, as a parsed field name
    /// is: a byte like 0x0D would compare equal to `-`.
    ///
    /// - Parameter name: The name's bytes, valid token characters (or a pseudo-header field's `:name`).
    public init?(caseInsensitive name: RawSpan) {
        guard let index = Self.lookUp(name) else { return nil }
        self.index = index
    }

    /// The name's lowercase bytes (HTTP/2's and HTTP/3's spelling).
    @inlinable
    public var lowercaseBytes: RawSpan {
        @_lifetime(immortal) get {
            let range = Self.range(index)
            // Unsafe: a span of a static table. Safe: the table is a global constant, never freed or changed, so the span
            // stays valid for the whole program (`immortal`).
            return unsafe _overrideLifetime(Self.lowercaseTable.extracting(range), borrowing: ())
        }
    }

    /// The name's canonical HTTP/1 spelling (`Content-Type`, `ETag`, `WWW-Authenticate`).
    @inlinable
    public var canonicalBytes: RawSpan {
        @_lifetime(immortal) get {
            let range = Self.range(index)
            // Unsafe and safe as for `lowercaseBytes`.
            return unsafe _overrideLifetime(Self.canonicalTable.extracting(range), borrowing: ())
        }
    }

    /// The canonical spelling, as a string.
    public var description: String {
        let bytes = canonicalBytes
        return String(decoding: (0..<bytes.byteCount).map { bytes.load(fromByteOffset: $0, as: UInt8.self) }, as: UTF8.self)
    }

    /// The name's first index in HPACK's static table (1–61, RFC 7541 Appendix A), or `nil` if it has none.
    public var hpackStaticIndex: Int? {
        let value = FieldNameTable.hpackIndexes[Int(index)]
        return value == 0 ? nil : Int(value)
    }

    /// The name's first index in QPACK's static table (0–98, RFC 9204 Appendix A), or `nil` if it has none.
    public var qpackStaticIndex: Int? {
        let value = FieldNameTable.qpackIndexes[Int(index)]
        return value == 0xFF ? nil : Int(value)
    }

    /// Whether this is a pseudo-header field (`:authority`, `:method`, `:path`, `:scheme`, `:status`, `:protocol`).
    @inlinable
    public var isPseudoHeader: Bool { index <= Self.pseudoProtocol.index }
}

extension HTTPFieldName {
    @inlinable @inline(__always)
    static func range(_ index: UInt8) -> Range<Int> {
        Int(FieldNameTable.offsets[Int(index)])..<Int(FieldNameTable.offsets[Int(index) &+ 1])
    }

    @usableFromInline
    static var lowercaseTable: RawSpan {
        @_lifetime(immortal) get { immortalSpan(FieldNameTable.lowercase) }
    }

    @usableFromInline
    static var canonicalTable: RawSpan {
        @_lifetime(immortal) get { immortalSpan(FieldNameTable.canonical) }
    }

    /// A name's two hash words, each byte ORed with 0x20 (case folding for token characters): 8 or more bytes, the first
    /// and last 8 (overlapping below 16); 4 to 7, the first and last 4; 1 to 3, bytes 0, n/2, and n − 1 in the first
    /// word and 0 in the second. Together they cover every byte of a name up to 16, so the lookup compares them with
    /// the table's words; longer names compare their middle too. Each load is within `name` by the length test before
    /// it: the 1–3-byte ones are checked loads whose checks fold, the others unchecked (see below).
    ///
    /// From 4 bytes up, branch-free: four 4-byte loads whose offsets, and how they're paired, are selected by the length
    /// class. A branch per class mispredicted whenever consecutive names changed class (`Host`, `Accept`, `Connection`):
    /// on 401 real request heads, looking every name up cost 38 cycles a head with branches (HTTPBytes/RESULTS.md).
    @inline(__always)
    static func words(_ name: RawSpan) -> (UInt64, UInt64) {
        let count = name.byteCount
        if count >= 4 {
            let long = count >= 8
            // Unsafe: 4-byte loads at 0, at 4 (or 0), at count − 4, and at count − 8 (or count − 4). Safe: count ≥ 4, and
            // the offsets 4 and count − 8 are taken only when count ≥ 8. (Checked loads don't fold here: the offsets are
            // selected by `long`, which LLVM doesn't relate to the count. +12 instructions a name, 2026-11-23.)
            let a = UInt64(UInt32(littleEndian: unsafe name.unsafeLoadUnaligned(fromUncheckedByteOffset: 0, as: UInt32.self)))
            let b = UInt64(UInt32(littleEndian: unsafe name.unsafeLoadUnaligned(
                fromUncheckedByteOffset: long ? 4 : 0, as: UInt32.self
            )))
            let c = UInt64(UInt32(littleEndian: unsafe name.unsafeLoadUnaligned(
                fromUncheckedByteOffset: count &- 4, as: UInt32.self
            )))
            let d = UInt64(UInt32(littleEndian: unsafe name.unsafeLoadUnaligned(
                fromUncheckedByteOffset: long ? count &- 8 : count &- 4, as: UInt32.self
            )))
            let fold: UInt64 = long ? 0x2020_2020_2020_2020 : 0x2020_2020
            return ((long ? a | b &<< 32 : a) | fold, (long ? d | c &<< 32 : c) | fold)
        }
        // Single bytes at 0, count / 2, and count − 1: 1 ≤ count ≤ 3 (the caller checks count > 0).
        let b0 = UInt64(name.load(fromByteOffset: 0, as: UInt8.self))
        let b1 = UInt64(name.load(fromByteOffset: count &>> 1, as: UInt8.self))
        let b2 = UInt64(name.load(fromByteOffset: count &- 1, as: UInt8.self))
        return ((b0 | b1 &<< 8 | b2 &<< 16) | 0x20_2020, 0)
    }

    @usableFromInline
    static func lookUp(_ name: RawSpan) -> UInt8? {
        let count = name.byteCount
        guard count > 0, count <= 64 else { return nil }
        let (first, last) = words(name)
        // Rotated so the two words can't cancel when they're the same (names of exactly 8 bytes).
        let key = first ^ (last &<< 29 | last &>> 35) ^ UInt64(truncatingIfNeeded: count)
        let index = FieldNameTable.slots[Int(truncatingIfNeeded: (key &* hashMultiplier) &>> UInt64(64 &- slotBits))]
        guard Int(index) < knownCount else { return nil }
        let entry = Int(index)
        let range = range(index)
        // The length and both words in one test.
        guard (FieldNameTable.firstWords[entry] ^ first) | (FieldNameTable.lastWords[entry] ^ last)
            | UInt64(truncatingIfNeeded: range.count ^ count) == 0 else { return nil }
        // Over 16 bytes, the middle the two words didn't cover.
        if count > 16, !asciiCaseInsensitiveEqual(name.extracting(8..<count &- 8), lowercase: lowercaseTable, at: range.lowerBound &+ 8) {
            return nil
        }
        return index
    }
}

/// A string literal's bytes as a span that lives forever.
@inlinable @inline(__always)
@_lifetime(immortal)
package func immortalSpan(_ string: StaticString) -> RawSpan {
    // Unsafe: a span over a raw pointer, with its lifetime overridden. Safe: a string literal's bytes are constant data
    // in the binary, at an address that never changes and is never freed, for `utf8CodeUnitCount` bytes.
    let bytes = unsafe UnsafeRawBufferPointer(start: string.utf8Start, count: string.utf8CodeUnitCount)
    return unsafe _overrideLifetime(RawSpan(_unsafeBytes: bytes), borrowing: ())
}

/// Whether `bytes` (token characters, any case) spell the `bytes.byteCount` lowercase bytes of `table` at `offset`:
/// 8-byte words (the last overlapping), each of `bytes` ORed with 0x20, as `HTTPFieldName(caseInsensitive:)` explains.
@inline(__always)
func asciiCaseInsensitiveEqual(_ bytes: RawSpan, lowercase table: RawSpan, at offset: Int) -> Bool {
    let count = bytes.byteCount
    if count >= 8 {
        var difference: UInt64 = 0
        var position = 0
        while position < count &- 8 {
            difference |= (bytes.load(fromByteOffset: position, as: UInt64.self) | 0x2020_2020_2020_2020)
                ^ table.load(fromByteOffset: offset &+ position, as: UInt64.self)
            position &+= 8
        }
        difference |= (bytes.load(fromByteOffset: count &- 8, as: UInt64.self) | 0x2020_2020_2020_2020)
            ^ table.load(fromByteOffset: offset &+ count &- 8, as: UInt64.self)
        return difference == 0
    }
    if count >= 4 {
        let first = (bytes.load(fromByteOffset: 0, as: UInt32.self) | 0x2020_2020)
            ^ table.load(fromByteOffset: offset, as: UInt32.self)
        let last = (bytes.load(fromByteOffset: count &- 4, as: UInt32.self) | 0x2020_2020)
            ^ table.load(fromByteOffset: offset &+ count &- 4, as: UInt32.self)
        return first | last == 0
    }
    var difference: UInt8 = 0
    for position in 0..<count {
        difference |= (bytes.load(fromByteOffset: position, as: UInt8.self) | 0x20)
            ^ table.load(fromByteOffset: offset &+ position, as: UInt8.self)
    }
    return difference == 0
}
