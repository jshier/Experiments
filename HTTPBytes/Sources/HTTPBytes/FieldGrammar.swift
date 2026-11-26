public import Bytes

// RFC 9110 §5.6's field-value grammar, shared by the value parsers: tokens, quoted strings, parameters, comma lists, and
// weights. Everything is a view of the value's bytes: nothing is copied or allocated; a quoted string's escapes are
// removed only when its text is written out or compared.

/// Byte classes of the field-value grammar, scalar (values are short): one bit test of a 64-bit word each.
@usableFromInline
enum FieldGrammar {
    /// `tchar` (RFC 9110 §5.6.2).
    @inlinable @inline(__always)
    static func isToken(_ byte: UInt8) -> Bool {
        let word: UInt64 = byte < 64 ? 0x03FF_6CFA_0000_0000 : 0x57FF_FFFF_C7FF_FFFE
        return byte < 128 && (word &>> UInt64(byte & 63)) & 1 != 0
    }

    /// `qdtext` (RFC 9110 §5.6.4): tab, space, visible characters but `"` and `\`, and obs-text.
    @inlinable @inline(__always)
    static func isQuotedText(_ byte: UInt8) -> Bool {
        let word: UInt64 = byte < 64 ? 0xFFFF_FFFB_0000_0200 : 0x7FFF_FFFF_EFFF_FFFF
        return byte >= 128 || (word &>> UInt64(byte & 63)) & 1 != 0
    }

    /// What may follow a backslash in a quoted string: tab, space, a visible character, or obs-text.
    @inlinable @inline(__always)
    static func isEscapable(_ byte: UInt8) -> Bool { byte == 0x09 || byte >= 0x20 && byte != 0x7F }

    @inlinable @inline(__always)
    static func isWhitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    @inlinable @inline(__always)
    static func byte(_ bytes: RawSpan, _ offset: Int) -> UInt8 { bytes.load(fromByteOffset: offset, as: UInt8.self) }

    /// The offset after spaces and tabs from `start`.
    @inlinable
    static func whitespaceEnd(_ bytes: RawSpan, from start: Int) -> Int {
        var position = start
        while position < bytes.byteCount, isWhitespace(byte(bytes, position)) {
            position &+= 1
        }
        return position
    }

    /// The offset of the first byte at or after `start` that isn't a token character: 16-byte nibble-class lookups
    /// (``HTTPCharacters/nonToken(_:)``), short tails in one overlapping block.
    @inlinable
    static func tokenEnd(_ bytes: RawSpan, from start: Int) -> Int {
        guard start < bytes.byteCount else { return start }
        let rest = bytes.extracting(droppingFirst: start)
        return start &+ (rest.firstByteOffset(where: HTTPCharacters.nonToken) ?? rest.byteCount)
    }

    /// Lanes that end a run of quoted-string text: `"`, `\`, a control other than tab, or DEL.
    @inlinable @inline(__always)
    static func quotedTextStop(_ lanes: ByteLanes) -> ByteMatches {
        let vector = lanes.vector
        return ByteMatches(((vector .< SIMD16(repeating: 0x20)) .& (vector .!= SIMD16(repeating: 0x09)))
            .| (vector .== SIMD16(repeating: 0x7F)) .| (vector .== SIMD16(repeating: 0x22)) .| (vector .== SIMD16(repeating: 0x5C)))
    }

    /// The quoted string whose opening quote is at `start`: the offset after its closing quote, and whether it has
    /// escapes. Runs of text are skipped 16 bytes at a time to the next quote, backslash, or byte that can't be there.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidQuotedString`` if it isn't closed or holds a byte it can't.
    @inlinable
    static func quotedStringEnd(_ bytes: RawSpan, from start: Int) throws(HTTPFieldValueError) -> (end: Int, escapes: Bool) {
        var position = start &+ 1
        var escapes = false
        while position < bytes.byteCount {
            let rest = bytes.extracting(droppingFirst: position)
            guard let found = rest.firstByteOffset(where: quotedTextStop) else { break }
            position &+= found
            let character = byte(bytes, position)
            if character == 0x22 { return (position &+ 1, escapes) }
            guard character == 0x5C, position &+ 1 < bytes.byteCount, isEscapable(byte(bytes, position &+ 1)) else { throw .invalidQuotedString }
            escapes = true
            position &+= 2
        }
        throw .invalidQuotedString
    }

    /// `bytes` without leading and trailing spaces and tabs.
    @inlinable
    @_lifetime(copy bytes)
    static func trimmed(_ bytes: RawSpan) -> RawSpan {
        var start = 0, end = bytes.byteCount
        while start < end, isWhitespace(byte(bytes, start)) {
            start &+= 1
        }
        while end > start, isWhitespace(byte(bytes, end &- 1)) {
            end &-= 1
        }
        return bytes.extracting(start..<end)
    }

    /// Whether `bytes` are all token characters, and at least one.
    @inlinable
    static func isToken(_ bytes: RawSpan) -> Bool {
        bytes.byteCount > 0 && tokenEnd(bytes, from: 0) == bytes.byteCount
    }
}

// MARK: - Quoted strings

/// A quoted string's text (RFC 9110 §5.6.4), as it appears between the quotes: backslash escapes are removed when the
/// text is written or compared, not when it's parsed.
@frozen
public struct HTTPQuotedString: ~Escapable {
    /// The bytes between the quotes, escapes included.
    public let escaped: RawSpan
    /// Whether any byte is escaped (if not, ``escaped`` is the text).
    public let hasEscapes: Bool

    @inlinable
    @_lifetime(copy escaped)
    init(escaped: RawSpan, hasEscapes: Bool) {
        self.escaped = escaped
        self.hasEscapes = hasEscapes
    }

    /// The text's length, escapes removed.
    @inlinable
    public var byteCount: Int {
        guard hasEscapes else { return escaped.byteCount }
        var count = 0, position = 0
        while position < escaped.byteCount {
            position &+= FieldGrammar.byte(escaped, position) == 0x5C ? 2 : 1
            count &+= 1
        }
        return count
    }

    /// Writes the text, escapes removed.
    @inlinable
    public func write(to writer: inout AlignedBytesWriter) throws(BytesError) {
        guard hasEscapes else { return try writer.write(escaped) }
        var position = 0
        while position < escaped.byteCount {
            if FieldGrammar.byte(escaped, position) == 0x5C { position &+= 1 }
            try writer.write(FieldGrammar.byte(escaped, position))
            position &+= 1
        }
    }

    /// Whether the text, escapes removed, is `text`; with `ignoringCase`, ASCII letters compared without case.
    @inlinable
    public func equals(_ text: RawSpan, ignoringCase: Bool = false) -> Bool {
        Self.equal(escaped, hasEscapes, text, false, ignoringCase: ignoringCase)
    }

    /// Whether the two strings' texts, escapes removed, are the same.
    @inlinable
    public func equals(_ other: borrowing HTTPQuotedString, ignoringCase: Bool = false) -> Bool {
        Self.equal(escaped, hasEscapes, other.escaped, other.hasEscapes, ignoringCase: ignoringCase)
    }

    /// Compares two texts, each with backslash escapes or not, a byte of text at a time.
    @inlinable
    static func equal(_ a: RawSpan, _ aEscapes: Bool, _ b: RawSpan, _ bEscapes: Bool, ignoringCase: Bool) -> Bool {
        if !aEscapes, !bEscapes, !ignoringCase { return a.bytesEqual(b) }
        var i = 0, j = 0
        while i < a.byteCount, j < b.byteCount {
            if aEscapes, FieldGrammar.byte(a, i) == 0x5C { i &+= 1 }
            if bEscapes, FieldGrammar.byte(b, j) == 0x5C { j &+= 1 }
            var x = FieldGrammar.byte(a, i), y = FieldGrammar.byte(b, j)
            if ignoringCase {
                if x &- 0x41 < 26 { x |= 0x20 }
                if y &- 0x41 < 26 { y |= 0x20 }
            }
            guard x == y else { return false }
            i &+= 1
            j &+= 1
        }
        return i == a.byteCount && j == b.byteCount
    }
}

// MARK: - Parameters

/// A parameter's value: a token or a quoted string (RFC 9110 §5.6.6).
@frozen
public enum HTTPParameterValue: ~Escapable {
    /// A token.
    case token(RawSpan)
    /// A quoted string.
    case quoted(HTTPQuotedString)

    /// Whether the value (a quoted string's text, escapes removed) is `text`; with `ignoringCase`, ASCII letters
    /// compared without case (a `charset`'s value, for instance).
    @inlinable
    public func equals(_ text: RawSpan, ignoringCase: Bool = false) -> Bool {
        switch self {
        case let .token(token):
            ignoringCase ? HTTPToken.equalsIgnoringCase(token, text) : token.bytesEqual(text)
        case let .quoted(string):
            string.equals(text, ignoringCase: ignoringCase)
        }
    }

    /// Writes the value's text (a quoted string's escapes removed).
    @inlinable
    public func write(to writer: inout AlignedBytesWriter) throws(BytesError) {
        switch self {
        case let .token(token): try writer.write(token)
        case let .quoted(string): try string.write(to: &writer)
        }
    }
}

/// A parameter: `name=value`.
@frozen
public struct HTTPParameter: ~Escapable {
    /// The name, as written (names compare without case).
    public let name: RawSpan
    /// The value.
    public let value: HTTPParameterValue

    @inlinable
    @_lifetime(copy name, copy value)
    init(name: RawSpan, value: consuming HTTPParameterValue) {
        self.name = name
        self.value = value
    }

    /// Whether the name is `name`, ignoring case on both sides (parameter names are case-insensitive).
    @inlinable
    public func isNamed(_ name: StaticString) -> Bool { HTTPToken.equalsIgnoringCase(self.name, immortalSpan(name)) }
}

/// Parameters after a value: `*( OWS ";" OWS [ parameter ] )` (RFC 9110 §5.6.6), each `name=value` with no whitespace
/// around the `=`; empty parameters (`;;`) are skipped.
///
/// ```swift
/// var parameters = mediaType.parameters
/// while let parameter = try parameters.next() { if parameter.isNamed("charset") { … } }
/// ```
@frozen
public struct HTTPParameters: ~Escapable {
    @usableFromInline let bytes: RawSpan
    @usableFromInline var position = 0
    /// Whether the first parameter may come without a `;` before it (`Forwarded`'s pairs).
    @usableFromInline var firstNeedsNoSeparator: Bool
    @usableFromInline let isPairs: Bool

    /// The parameters in `bytes`, which start with optional whitespace and a `;` (or are empty).
    @inlinable
    @_lifetime(copy bytes)
    public init(_ bytes: RawSpan) {
        self.bytes = bytes
        firstNeedsNoSeparator = false
        isPairs = false
    }

    /// `name=value` pairs separated by `;`, the first without one before it (a `Forwarded` element, RFC 7239 §4).
    @inlinable
    @_lifetime(copy pairs)
    public init(pairs: RawSpan) {
        bytes = pairs
        firstNeedsNoSeparator = true
        isPairs = true
    }

    /// The same parameters from the start.
    @inlinable
    @_lifetime(copy self)
    func restarted() -> HTTPParameters { isPairs ? HTTPParameters(pairs: bytes) : HTTPParameters(bytes) }

    /// The next parameter, or `nil` at the end.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidParameter`` (or ``HTTPFieldValueError/invalidQuotedString``) for one
    ///   that isn't `name=value`.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPFieldValueError) -> HTTPParameter? {
        let count = bytes.byteCount
        while true {
            position = FieldGrammar.whitespaceEnd(bytes, from: position)
            guard position < count else { return nil }
            if firstNeedsNoSeparator, FieldGrammar.byte(bytes, position) != 0x3B {
                firstNeedsNoSeparator = false
            } else {
                firstNeedsNoSeparator = false
                guard FieldGrammar.byte(bytes, position) == 0x3B else { throw .invalidParameter }
                position = FieldGrammar.whitespaceEnd(bytes, from: position &+ 1)
                if position == count || FieldGrammar.byte(bytes, position) == 0x3B { continue }
            }
            let nameStart = position
            position = FieldGrammar.tokenEnd(bytes, from: position)
            guard position > nameStart, position < count, FieldGrammar.byte(bytes, position) == 0x3D else { throw .invalidParameter }
            let name = bytes.extracting(nameStart..<position)
            position &+= 1
            guard position < count else { throw .invalidParameter }
            if FieldGrammar.byte(bytes, position) == 0x22 {
                let (end, escapes) = try FieldGrammar.quotedStringEnd(bytes, from: position)
                let text = bytes.extracting(position &+ 1..<end &- 1)
                position = end
                return HTTPParameter(name: name, value: .quoted(HTTPQuotedString(escaped: text, hasEscapes: escapes)))
            }
            let valueStart = position
            position = FieldGrammar.tokenEnd(bytes, from: position)
            guard position > valueStart else { throw .invalidParameter }
            return HTTPParameter(name: name, value: .token(bytes.extracting(valueStart..<position)))
        }
    }

    /// The value of the first parameter named `name` (ignoring case), or `nil`.
    ///
    /// - Throws: As ``next()``, for parameters before it.
    @inlinable
    @_lifetime(copy self)
    public func value(of name: StaticString) throws(HTTPFieldValueError) -> HTTPParameterValue? {
        var parameters = restarted()
        while let parameter = try parameters.next() {
            if parameter.isNamed(name) { return parameter.value }
        }
        return nil
    }

    /// Checks every parameter's syntax.
    @inlinable
    func validate() throws(HTTPFieldValueError) {
        var parameters = restarted()
        while try parameters.next() != nil {}
    }
}

// MARK: - Lists

/// The elements of a comma-separated list (RFC 9110 §5.6.1): each trimmed of surrounding whitespace, empty elements
/// skipped (a recipient must accept them), commas inside quoted strings kept in their element. A list field sent as
/// several field lines is the lines' elements in order: iterate each line.
///
/// Elements are found with 16-byte vector scans for the next comma or quote.
@frozen
public struct HTTPListElements: ~Escapable {
    @usableFromInline let bytes: RawSpan
    @usableFromInline var position = 0

    /// The elements of `value`.
    @inlinable
    @_lifetime(copy value)
    public init(_ value: RawSpan) { bytes = value }

    /// The next element, or `nil` at the end.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidQuotedString`` for a quoted string that isn't closed or holds a byte it
    ///   can't.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPFieldValueError) -> RawSpan? {
        let count = bytes.byteCount
        // Empty elements and the whitespace before an element.
        while position < count, case let byte = FieldGrammar.byte(bytes, position), byte == 0x2C || FieldGrammar.isWhitespace(byte) {
            position &+= 1
        }
        guard position < count else { return nil }
        let start = position
        while true {
            let rest = bytes.extracting(droppingFirst: position)
            guard let found = rest.firstByteOffset(where: { $0.matching(0x2C) | $0.matching(0x22) }) else {
                position = count
                break
            }
            position &+= found
            if FieldGrammar.byte(bytes, position) == 0x2C { break }
            position = try FieldGrammar.quotedStringEnd(bytes, from: position).end
        }
        var end = position
        while end > start, FieldGrammar.isWhitespace(FieldGrammar.byte(bytes, end &- 1)) {
            end &-= 1
        }
        if position < count { position &+= 1 }
        return bytes.extracting(start..<end)
    }
}

// MARK: - Weights

/// Weights (`q` parameters, RFC 9110 §12.4.2) in thousandths: `0` to `1` with at most three decimals.
public enum HTTPWeight {
    /// The weight `bytes` spell, in thousandths (0–1000), or `nil` if they don't spell one.
    @inlinable
    public static func thousandths(_ bytes: RawSpan) -> Int? {
        let count = bytes.byteCount
        guard count >= 1, count <= 5 else { return nil }
        let first = FieldGrammar.byte(bytes, 0)
        guard first == 0x30 || first == 0x31 else { return nil }
        guard count > 1 else { return first == 0x31 ? 1000 : 0 }
        guard FieldGrammar.byte(bytes, 1) == 0x2E else { return nil }
        var value = 0, scale = 100
        for offset in 2..<count {
            let digit = FieldGrammar.byte(bytes, offset) &- 0x30
            guard digit < 10 else { return nil }
            value &+= Int(digit) &* scale
            scale /= 10
        }
        if first == 0x31 { return value == 0 ? 1000 : nil }
        return value
    }
}

public extension HTTPToken {
    /// Whether `bytes` and `other` are the same bytes, ASCII letters compared without case.
    @inlinable
    static func equalsIgnoringCase(_ bytes: RawSpan, _ other: RawSpan) -> Bool {
        guard bytes.byteCount == other.byteCount else { return false }
        for offset in 0..<bytes.byteCount {
            var a = FieldGrammar.byte(bytes, offset), b = FieldGrammar.byte(other, offset)
            if a &- 0x41 < 26 { a |= 0x20 }
            if b &- 0x41 < 26 { b |= 0x20 }
            guard a == b else { return false }
        }
        return true
    }
}
