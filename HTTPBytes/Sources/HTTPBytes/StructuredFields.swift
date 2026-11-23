public import Bytes

// Structured Field Values (RFC 9651): Lists, Dictionaries, and Items, parsed as views of the field value's bytes.
//
// Nothing is copied or allocated while parsing. A parser walks the bytes once, validating everything as it goes
// (RFC 9651 §4.2: a field that fails anywhere fails whole), and hands out members as views: numbers and Booleans as
// values, strings, tokens, byte sequences, and display strings as spans of the field value, decoded on demand into
// the caller's memory. Parameters and inner lists are views too, walked again (without checks: they were validated)
// when asked for their contents.
//
// ```swift
// var list = HTTPStructuredList(fieldValue)
// while let member = try list.next() {
//     switch member {
//     case .item(let item): …
//     case .innerList(var list): while let item = list.next() { … }
//     }
// }
// ```

/// Why a Structured Field value couldn't be parsed or serialized.
@frozen
public enum HTTPStructuredFieldError: Error, Sendable, Hashable {
    /// A value that should be an item doesn't start with a byte any bare item starts with, or is missing (RFC 9651
    /// §4.2.3.1).
    case invalidBareItem
    /// An Integer (or Date) with no digits or more than 15, or a misplaced sign (§4.2.4).
    case invalidInteger
    /// A Decimal with more than 12 integer digits, or no fractional digits or more than 3 (§4.2.4).
    case invalidDecimal
    /// A String with a byte outside printable ASCII, an escape other than `\"` and `\\`, or no closing quote (§4.2.5).
    case invalidString
    /// A token with a byte that isn't a token character (§4.2.6); in serializing, an empty one or one starting with a
    /// byte that isn't a letter or `*`.
    case invalidToken
    /// A Byte Sequence with a byte that isn't Base64, misplaced padding, no closing colon, or a length no Base64 text
    /// has (§4.2.7).
    case invalidByteSequence
    /// A Boolean other than `?0` and `?1` (§4.2.8).
    case invalidBoolean
    /// A Date that's a Decimal (§4.2.9).
    case invalidDate
    /// A Display String without its quote, with a byte outside printable ASCII, a `%` not followed by two lowercase
    /// hexadecimal digits, or bytes that aren't UTF-8 (§4.2.10).
    case invalidDisplayString
    /// A key that's empty, or starts with a byte other than a lowercase letter or `*`, or (in serializing) has a byte
    /// other than lowercase letters, digits, `_`, `-`, `.`, and `*` (§4.2.3.3).
    case invalidKey
    /// An inner list not closed by `)`, or with items not separated by spaces (§4.2.1.2).
    case invalidInnerList
    /// List or Dictionary members not separated by a comma (§4.2.1, §4.2.2).
    case missingSeparator
    /// A comma with no member after it, or an empty field line among several (which joined with commas would leave
    /// one).
    case missingMember
    /// Bytes after an Item (§4.2: anything but spaces).
    case trailingBytes
    /// In serializing: an Integer or Date outside ±999,999,999,999,999 (§4.1.4, §4.1.10).
    case valueOutOfRange
    /// In serializing: the writer ran out of room. What was written of the value is rewound.
    case insufficientCapacity
}

// MARK: - Bare items

/// A bare item (RFC 9651 §3.3): a value without its parameters.
///
/// Parsed, its strings, tokens, byte sequences, and display strings are views of the field value's bytes as received;
/// to serialize one, make it from a value (``HTTPStructuredString/init(_:)``, ``HTTPStructuredByteSequence/init(_:)``,
/// ``HTTPStructuredDisplayString/init(_:)``, a token's bytes) and pass it to ``HTTPStructuredFieldEncoder``.
@frozen
public enum HTTPStructuredBareItem: ~Escapable {
    /// An Integer: −999,999,999,999,999 through 999,999,999,999,999.
    case integer(Int64)
    /// A Decimal, in thousandths.
    case decimal(HTTPStructuredDecimal)
    /// A String: printable ASCII.
    case string(HTTPStructuredString)
    /// A Token's bytes: a letter or `*`, then token characters, `:`, and `/`.
    case token(RawSpan)
    /// A Byte Sequence.
    case byteSequence(HTTPStructuredByteSequence)
    /// A Boolean.
    case boolean(Bool)
    /// A Date: seconds since 1970-01-01T00:00:00Z, in the Integer range.
    case date(Int64)
    /// A Display String: Unicode text.
    case displayString(HTTPStructuredDisplayString)
}

/// A Decimal (RFC 9651 §3.3.2): at most 12 integer digits and 3 fractional ones, kept exactly as thousandths.
@frozen
public struct HTTPStructuredDecimal: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The value times 1,000: −999,999,999,999,999 through 999,999,999,999,999.
    public let thousandths: Int64

    /// The largest magnitude of ``thousandths``.
    @inlinable static var limit: Int64 { 999_999_999_999_999 }

    @inlinable @inline(__always)
    init(uncheckedThousandths: Int64) {
        thousandths = uncheckedThousandths
    }

    /// The decimal of `thousandths` thousandths, or `nil` if it has more than 12 integer digits.
    @inlinable
    public init?(thousandths: Int64) {
        guard thousandths >= -Self.limit, thousandths <= Self.limit else { return nil }
        self.thousandths = thousandths
    }

    /// `value` rounded to thousandths, ties to even, or `nil` if the result has more than 12 integer digits (or
    /// `value` isn't finite), as RFC 9651 §4.1.5 serializes decimals.
    ///
    /// `value` is read as the decimal it was written as: when it's the closest `Double` to a tie (0.5015, whose binary
    /// value is a little below the tie), it rounds as the tie (to 0.502), as it would from its digits.
    @inlinable
    public init?(rounding value: Double) {
        guard value.isFinite, value.magnitude < 1e13 else { return nil }
        let magnitude = value.magnitude
        // The nearest thousandth by the binary value, then the ties on either side: `Double(m) / 2000` is the closest
        // `Double` to m / 2,000 (both operands are exact and IEEE division rounds once), so `magnitude` equals it
        // exactly when it reads as that tie.
        var nearest = Int64((magnitude * 1000).rounded())
        let above = Double(2 &* nearest &+ 1) / 2000, below = Double(2 &* nearest &- 1) / 2000
        if magnitude == above {
            nearest = nearest & 1 == 0 ? nearest : nearest &+ 1
        } else if magnitude > above {
            nearest &+= 1
        } else if magnitude == below {
            nearest = nearest & 1 == 0 ? nearest : nearest &- 1
        } else if magnitude < below {
            nearest &-= 1
        }
        guard nearest <= Self.limit else { return nil }
        thousandths = value < 0 ? -nearest : nearest
    }

    /// The closest `Double`.
    @inlinable
    public var doubleValue: Double {
        // Both are exact (below 2⁵³), and the division rounds once.
        Double(thousandths) / 1000
    }

    @inlinable
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.thousandths < rhs.thousandths }

    /// The canonical form: `1.5`, `-0.25`, `10.0`.
    public var description: String {
        let magnitude = thousandths.magnitude
        var fraction = String(magnitude % 1000)
        fraction = String(repeating: "0", count: 3 - fraction.count) + fraction
        while fraction.count > 1, fraction.hasSuffix("0") { fraction.removeLast() }
        return (thousandths < 0 ? "-" : "") + String(magnitude / 1000) + "." + fraction
    }
}

/// A String (RFC 9651 §3.3.3): printable ASCII, 0x20 through 0x7E.
///
/// Parsed, it's the bytes between the quotes as received: escaped (`\"` and `\\`) if ``isEscaped``. Made from a
/// value, its bytes as they are.
@frozen
public struct HTTPStructuredString: ~Escapable {
    /// The string's bytes, with escapes if ``isEscaped``.
    public let bytes: RawSpan
    /// Whether ``bytes`` holds escapes: a `\` before each `"` and `\`.
    public let isEscaped: Bool

    @inlinable @inline(__always)
    @_lifetime(copy bytes)
    init(uncheckedBytes bytes: RawSpan, isEscaped: Bool) {
        self.bytes = bytes
        self.isEscaped = isEscaped
    }

    /// A string of `bytes`, or `nil` if one isn't printable ASCII (0x20 through 0x7E).
    @inlinable
    @_lifetime(copy bytes)
    public init?(_ bytes: RawSpan) {
        guard !bytes.containsByte(where: StructuredFieldScan.nonPrintable) else { return nil }
        self.bytes = bytes
        self.isEscaped = false
    }

    /// The string's bytes when they need no unescaping, or `nil`.
    @inlinable
    public var unescapedBytes: RawSpan? {
        @_lifetime(copy self)
        get { isEscaped ? nil : bytes }
    }

    /// The number of bytes in the string, unescaped.
    @inlinable
    public var byteCount: Int {
        guard isEscaped else { return bytes.byteCount }
        // Each escape is a backslash and the byte it escapes: count the escapes, skipping their second bytes.
        var count = bytes.byteCount
        var position = 0
        while position < bytes.byteCount,
              let found = bytes.extracting(droppingFirst: position).firstByteOffset(where: { $0.matching(0x5C) }) {
            count &-= 1
            position &+= found &+ 2
        }
        return count
    }

    /// Writes the string's bytes, unescaped.
    ///
    /// - Throws: `BytesError.insufficientCapacity` if `writer` doesn't have room for ``byteCount`` bytes; nothing is
    ///   written then.
    @inlinable
    public func write(to writer: inout AlignedBytesWriter) throws(BytesError) {
        guard isEscaped else { return try writer.write(bytes) }
        guard writer.remainingByteCount >= byteCount else { throw .insufficientCapacity }
        var position = 0
        let count = bytes.byteCount
        while position < count {
            let rest = bytes.extracting(droppingFirst: position)
            guard let found = rest.firstByteOffset(where: { $0.matching(0x5C) }) else {
                try writer.write(rest)
                return
            }
            // A backslash is always followed by the byte it escapes (checked when parsed).
            try writer.write(rest.extracting(0..<found))
            try writer.write(rest.extracting(found &+ 1..<found &+ 2))
            position &+= found &+ 2
        }
    }

    /// Whether the string, unescaped, is `other`'s bytes.
    @inlinable
    public func isEqual(to other: RawSpan) -> Bool {
        guard isEscaped else { return bytes.bytesEqual(other) }
        var position = 0, otherPosition = 0
        let count = bytes.byteCount, otherCount = other.byteCount
        while position < count {
            var byte = bytes.load(fromByteOffset: position, as: UInt8.self)
            if byte == 0x5C {
                position &+= 1
                byte = bytes.load(fromByteOffset: position, as: UInt8.self)
            }
            guard otherPosition < otherCount, other.load(fromByteOffset: otherPosition, as: UInt8.self) == byte else { return false }
            position &+= 1
            otherPosition &+= 1
        }
        return otherPosition == otherCount
    }
}

/// A Byte Sequence (RFC 9651 §3.3.5).
///
/// Parsed, it's the Base64 text between the colons, without its padding (``isBase64``); made from a value, the bytes
/// themselves.
@frozen
public struct HTTPStructuredByteSequence: ~Escapable {
    /// The Base64 characters (without `=` padding) if ``isBase64``, otherwise the bytes.
    public let bytes: RawSpan
    /// Whether ``bytes`` is Base64 text.
    public let isBase64: Bool

    @inlinable @inline(__always)
    @_lifetime(copy base64)
    init(uncheckedBase64 base64: RawSpan) {
        bytes = base64
        isBase64 = true
    }

    /// A byte sequence of `bytes`.
    @inlinable
    @_lifetime(copy bytes)
    public init(_ bytes: RawSpan) {
        self.bytes = bytes
        isBase64 = false
    }

    /// The number of bytes in the sequence, decoded.
    @inlinable
    public var byteCount: Int {
        guard isBase64 else { return bytes.byteCount }
        // 3 bytes for every 4 characters, then 1 or 2 for a last group of 2 or 3 (a group of 1 fails to parse).
        let count = bytes.byteCount
        return count / 4 &* 3 &+ Swift.max(count % 4 &- 1, 0)
    }

    /// Writes the sequence's bytes, decoded.
    ///
    /// Base64 is decoded as RFC 9651 §4.2.7 asks: missing padding and nonzero bits after the last byte are accepted.
    ///
    /// - Throws: `BytesError.insufficientCapacity` if `writer` doesn't have room for ``byteCount`` bytes; nothing is
    ///   written then.
    @inlinable
    public func write(to writer: inout AlignedBytesWriter) throws(BytesError) {
        guard isBase64 else { return try writer.write(bytes) }
        guard writer.remainingByteCount >= byteCount else { throw .insufficientCapacity }
        let count = bytes.byteCount
        let whole = count & ~3
        StructuredFieldScan.decodeBase64Groups(bytes.extracting(0..<whole), into: &writer)
        // The last 2 or 3 characters: 1 or 2 bytes, whatever their unused bits.
        let rest = count &- whole
        guard rest >= 2 else { return }
        let value0 = StructuredFieldScan.base64Value(bytes.load(fromByteOffset: whole, as: UInt8.self))
        let value1 = StructuredFieldScan.base64Value(bytes.load(fromByteOffset: whole &+ 1, as: UInt8.self))
        try writer.write(value0 &<< 2 | value1 &>> 4)
        if rest == 3 {
            let value2 = StructuredFieldScan.base64Value(bytes.load(fromByteOffset: whole &+ 2, as: UInt8.self))
            try writer.write(value1 &<< 4 | value2 &>> 2)
        }
    }
}

/// A Display String (RFC 9651 §3.3.8): Unicode text.
///
/// Parsed, it's the bytes between the quotes as received, with `%`-escapes of UTF-8 bytes if ``isPercentEncoded``
/// (validated: they decode to UTF-8). Made from a value, its UTF-8.
@frozen
public struct HTTPStructuredDisplayString: ~Escapable {
    /// The text's bytes: percent-encoded if ``isPercentEncoded``, otherwise UTF-8.
    public let bytes: RawSpan
    /// Whether ``bytes`` has `%`-escapes.
    public let isPercentEncoded: Bool

    @inlinable @inline(__always)
    @_lifetime(copy bytes)
    init(uncheckedBytes bytes: RawSpan, isPercentEncoded: Bool) {
        self.bytes = bytes
        self.isPercentEncoded = isPercentEncoded
    }

    /// A display string of `text`.
    @inlinable
    @_lifetime(copy text)
    public init(_ text: UTF8Span) {
        bytes = text.span.bytes
        isPercentEncoded = false
    }

    /// The text when it needs no decoding, or `nil`.
    @inlinable
    public var utf8: UTF8Span? {
        @_lifetime(copy self)
        get {
            guard !isPercentEncoded else { return nil }
            // Unsafe: skips validation. Safe: unescaped bytes are either a value's UTF-8 (made from a `UTF8Span`) or,
            // parsed, printable ASCII (anything else fails to parse).
            return unsafe UTF8Span(unchecked: Span(viewing: bytes), isKnownASCII: false)
        }
    }

    /// The number of bytes of UTF-8 in the text, decoded.
    @inlinable
    public var byteCount: Int {
        guard isPercentEncoded else { return bytes.byteCount }
        var count = bytes.byteCount
        var position = 0
        while position < bytes.byteCount,
              let found = bytes.extracting(droppingFirst: position).firstByteOffset(where: { $0.matching(0x25) }) {
            count &-= 2
            position &+= found &+ 3
        }
        return count
    }

    /// Writes the text's UTF-8, decoded.
    ///
    /// - Throws: `BytesError.insufficientCapacity` if `writer` doesn't have room for ``byteCount`` bytes; nothing is
    ///   written then.
    @inlinable
    public func write(to writer: inout AlignedBytesWriter) throws(BytesError) {
        guard isPercentEncoded else { return try writer.write(bytes) }
        guard writer.remainingByteCount >= byteCount else { throw .insufficientCapacity }
        var position = 0
        let count = bytes.byteCount
        while position < count {
            let rest = bytes.extracting(droppingFirst: position)
            guard let found = rest.firstByteOffset(where: { $0.matching(0x25) }) else {
                try writer.write(rest)
                return
            }
            try writer.write(rest.extracting(0..<found))
            // Two lowercase hexadecimal digits follow every `%` (checked when parsed).
            let high = StructuredFieldScan.hexValue(rest.load(fromByteOffset: found &+ 1, as: UInt8.self))
            let low = StructuredFieldScan.hexValue(rest.load(fromByteOffset: found &+ 2, as: UInt8.self))
            try writer.write(high &<< 4 | low)
            position &+= found &+ 3
        }
    }
}

extension String {
    /// The string's text.
    @inlinable
    public init(_ value: HTTPStructuredString) {
        self.init(utf8Capacity: value.byteCount) { writer in
            // Can't throw: the writer has exactly the room the bytes need.
            try! value.write(to: &writer)
        }
    }

    /// The display string's text.
    @inlinable
    public init(_ value: HTTPStructuredDisplayString) {
        self.init(utf8Capacity: value.byteCount) { writer in
            // Can't throw: the writer has exactly the room the bytes need.
            try! value.write(to: &writer)
        }
    }
}

// MARK: - Items, parameters, inner lists

/// An Item (RFC 9651 §3.3): a bare item and its parameters.
@frozen
public struct HTTPStructuredItem: ~Escapable {
    /// The value.
    public let bareItem: HTTPStructuredBareItem
    /// Its parameters.
    public let parameters: HTTPStructuredParameters

    @inlinable @inline(__always)
    @_lifetime(copy bareItem, copy parameters)
    init(bareItem: HTTPStructuredBareItem, parameters: HTTPStructuredParameters) {
        self.bareItem = bareItem
        self.parameters = parameters
    }

    /// Parses a field whose value is an Item (RFC 9651 §4.2 with `item` as the type): spaces, the item, spaces.
    ///
    /// An Item field's value can't span field lines: joined with commas, two lines are never one item (strings with a
    /// comma in them aside, which RFC 9651's tests let a parser reject).
    ///
    /// - Parameter fieldValue: The field's value.
    /// - Throws: ``HTTPStructuredFieldError`` for anything the grammar doesn't allow, ``HTTPStructuredFieldError/trailingBytes``
    ///   for bytes after the item.
    @inlinable
    @_lifetime(copy fieldValue)
    public init(parsing fieldValue: RawSpan) throws(HTTPStructuredFieldError) {
        var position = StructuredFieldScan.spacesEnd(fieldValue, from: 0)
        let item = try StructuredFieldScan.item(fieldValue, &position)
        guard StructuredFieldScan.spacesEnd(fieldValue, from: position) == fieldValue.byteCount else { throw .trailingBytes }
        self = item
    }
}

/// A parameter: a key and a value.
@frozen
public struct HTTPStructuredParameter: ~Escapable {
    /// The key: a lowercase letter or `*`, then lowercase letters, digits, `_`, `-`, `.`, and `*`.
    public let key: RawSpan
    /// The value (`true` when the parameter has no `=`).
    public let value: HTTPStructuredBareItem

    @inlinable @inline(__always)
    @_lifetime(copy key, copy value)
    init(key: RawSpan, value: HTTPStructuredBareItem) {
        self.key = key
        self.value = value
    }
}

/// An item's or inner list's parameters (RFC 9651 §3.1.2), in order as received: an iterator.
///
/// Keys can repeat; the last value is the parameter's (§4.2.3.2), as ``value(forKey:)`` finds it.
///
/// ```swift
/// var parameters = item.parameters
/// while let parameter = parameters.next() { … }
/// if case .decimal(let q)? = item.parameters.value(forKey: "q".utf8Span.span.bytes) { … }
/// ```
@frozen
public struct HTTPStructuredParameters: ~Escapable {
    /// The parameters' bytes, from the first `;` (validated).
    @usableFromInline let bytes: RawSpan
    /// Where the next parameter starts in `bytes`.
    @usableFromInline var position: Int

    @inlinable @inline(__always)
    @_lifetime(copy bytes)
    init(validated bytes: RawSpan) {
        self.bytes = bytes
        position = 0
    }

    /// Whether there are no parameters.
    @inlinable
    public var isEmpty: Bool { bytes.byteCount == 0 }

    /// The next parameter, or `nil` after the last.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() -> HTTPStructuredParameter? {
        guard position < bytes.byteCount else { return nil }
        var position = self.position
        do throws(HTTPStructuredFieldError) {
            let parameter = try StructuredFieldScan.parameter(bytes, &position)
            self.position = position
            return parameter
        } catch {
            preconditionFailure("parameters are validated when parsed")
        }
    }

    /// The value of the last parameter named `key`, or `nil`.
    @inlinable
    @_lifetime(copy self)
    public func value(forKey key: RawSpan) -> HTTPStructuredBareItem? {
        var parameters = self
        parameters.position = 0
        var found: HTTPStructuredBareItem? = nil
        while let parameter = parameters.next() {
            if parameter.key.bytesEqual(key) { found = parameter.value }
        }
        return found
    }
}

/// An Inner List (RFC 9651 §3.1.1): items and parameters. An iterator over its items.
///
/// ```swift
/// var list = innerList
/// while let item = list.next() { … }
/// ```
@frozen
public struct HTTPStructuredInnerList: ~Escapable {
    /// The bytes between the parentheses (validated).
    @usableFromInline let items: RawSpan
    /// Where the next item starts in `items`.
    @usableFromInline var position: Int
    /// The list's parameters.
    public let parameters: HTTPStructuredParameters

    @inlinable @inline(__always)
    @_lifetime(copy items, copy parameters)
    init(validated items: RawSpan, parameters: HTTPStructuredParameters) {
        self.items = items
        self.parameters = parameters
        position = 0
    }

    /// Whether the list has no items.
    @inlinable
    public var isEmpty: Bool { StructuredFieldScan.spacesEnd(items, from: 0) == items.byteCount }

    /// The next item, or `nil` after the last.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() -> HTTPStructuredItem? {
        var position = StructuredFieldScan.spacesEnd(items, from: self.position)
        guard position < items.byteCount else { return nil }
        do throws(HTTPStructuredFieldError) {
            let item = try StructuredFieldScan.item(items, &position)
            self.position = position
            return item
        } catch {
            preconditionFailure("inner lists are validated when parsed")
        }
    }
}

/// A List member or Dictionary value: an Item or an Inner List.
@frozen
public enum HTTPStructuredMember: ~Escapable {
    case item(HTTPStructuredItem)
    case innerList(HTTPStructuredInnerList)
}

/// A Dictionary member: a key and a value.
@frozen
public struct HTTPStructuredDictionaryMember: ~Escapable {
    /// The key: a lowercase letter or `*`, then lowercase letters, digits, `_`, `-`, `.`, and `*`.
    public let key: RawSpan
    /// The value: an item (`true` with parameters when the member has no `=`) or an inner list.
    public let value: HTTPStructuredMember

    @inlinable @inline(__always)
    @_lifetime(copy key, copy value)
    init(key: RawSpan, value: HTTPStructuredMember) {
        self.key = key
        self.value = value
    }
}

// MARK: - Lists and Dictionaries

/// Where a List or Dictionary parser is.
@usableFromInline
enum StructuredFieldListState: UInt8, Sendable {
    /// At the start of the first field line (or after its leading spaces): a member or the end.
    case start
    /// After a member: whitespace and a comma, or the end.
    case afterMember
    /// At the start of a later field line: a member must follow (joining lines puts a comma before it).
    case needsMember
    /// The end of a field line with no members.
    case endEmpty
    /// The end of a field line after a member.
    case endAfterMember
}

/// A field whose value is a List (RFC 9651 §3.1), parsed member by member: an iterator whose members are views of the
/// field value's bytes.
///
/// Each ``next()`` parses and validates one member and the separator before it; the field is valid when `next()` has
/// returned `nil` without throwing (RFC 9651 parses a field whole: act on members only once the field has ended, or
/// undo what they did if it throws).
///
/// A field sent on several lines is one value, the lines joined by commas (RFC 9651 §4.2): after `next()` returns
/// `nil`, ``appendFieldLine(_:)`` continues with the next line.
///
/// ```swift
/// var list = HTTPStructuredList(fieldValue)
/// while let member = try list.next() { … }
/// ```
@frozen
public struct HTTPStructuredList: ~Escapable {
    /// The current field line.
    @usableFromInline var bytes: RawSpan
    /// Where parsing continues in `bytes`.
    @usableFromInline var position: Int
    @usableFromInline var state: StructuredFieldListState

    /// A parser for the List in `fieldValue` (the first, or only, field line).
    @inlinable
    @_lifetime(copy fieldValue)
    public init(_ fieldValue: RawSpan) {
        bytes = fieldValue
        position = StructuredFieldScan.spacesEnd(fieldValue, from: 0)
        state = .start
    }

    /// The next member, or `nil` at the end of the field line.
    ///
    /// - Throws: ``HTTPStructuredFieldError`` if the member, or what separates it from the one before, isn't valid.
    ///   The parser doesn't move: calling again throws again.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPStructuredFieldError) -> HTTPStructuredMember? {
        var position = self.position, state = self.state
        guard try StructuredFieldScan.memberFollows(bytes, &position, &state) else {
            self.position = position
            self.state = state
            return nil
        }
        let member = try StructuredFieldScan.member(bytes, &position)
        self.position = position
        self.state = .afterMember
        return member
    }

    /// Continues with another field line of the same field: the List is the lines joined with commas.
    ///
    /// - Parameter fieldLine: The next line's value.
    /// - Throws: ``HTTPStructuredFieldError/missingMember`` if the line before was empty (joined, a comma would follow
    ///   nothing). An empty `fieldLine` throws from the next ``next()``.
    /// - Precondition: ``next()`` has returned `nil`.
    @inlinable
    @_lifetime(self: copy self, copy fieldLine)
    public mutating func appendFieldLine(_ fieldLine: RawSpan) throws(HTTPStructuredFieldError) {
        try StructuredFieldScan.continueState(&state)
        bytes = fieldLine
        position = StructuredFieldScan.whitespaceEnd(fieldLine, from: 0)
    }
}

/// A field whose value is a Dictionary (RFC 9651 §3.2), parsed member by member: an iterator whose members are views
/// of the field value's bytes, in order as received.
///
/// Keys can repeat: the last value is the member's, in the place of the first (§4.2.2). ``lastValue(forKey:)`` finds
/// a key's value.
///
/// Each ``next()`` parses and validates one member; the field is valid when `next()` has returned `nil` without
/// throwing. A field sent on several lines is one value, the lines joined by commas: after `next()` returns `nil`,
/// ``appendFieldLine(_:)`` continues with the next line.
///
/// ```swift
/// var dictionary = HTTPStructuredDictionary(fieldValue)
/// while let member = try dictionary.next() { … member.key, member.value … }
/// ```
@frozen
public struct HTTPStructuredDictionary: ~Escapable {
    @usableFromInline var bytes: RawSpan
    @usableFromInline var position: Int
    @usableFromInline var state: StructuredFieldListState

    /// A parser for the Dictionary in `fieldValue` (the first, or only, field line).
    @inlinable
    @_lifetime(copy fieldValue)
    public init(_ fieldValue: RawSpan) {
        bytes = fieldValue
        position = StructuredFieldScan.spacesEnd(fieldValue, from: 0)
        state = .start
    }

    /// The next member, or `nil` at the end of the field line.
    ///
    /// - Throws: ``HTTPStructuredFieldError`` if the member, or what separates it from the one before, isn't valid.
    ///   The parser doesn't move: calling again throws again.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPStructuredFieldError) -> HTTPStructuredDictionaryMember? {
        var position = self.position, state = self.state
        guard try StructuredFieldScan.memberFollows(bytes, &position, &state) else {
            self.position = position
            self.state = state
            return nil
        }
        let member = try StructuredFieldScan.dictionaryMember(bytes, &position)
        self.position = position
        self.state = .afterMember
        return member
    }

    /// Parses the rest of the field line, and returns the value of the last member named `key`, or `nil`.
    ///
    /// - Throws: ``HTTPStructuredFieldError`` if any member left isn't valid.
    @inlinable
    @_lifetime(copy self)
    public mutating func lastValue(forKey key: RawSpan) throws(HTTPStructuredFieldError) -> HTTPStructuredMember? {
        var found: HTTPStructuredMember? = nil
        while let member = try next() {
            if member.key.bytesEqual(key) { found = member.value }
        }
        return found
    }

    /// Continues with another field line of the same field: the Dictionary is the lines joined with commas.
    ///
    /// - Parameter fieldLine: The next line's value.
    /// - Throws: ``HTTPStructuredFieldError/missingMember`` if the line before was empty. An empty `fieldLine` throws
    ///   from the next ``next()``.
    /// - Precondition: ``next()`` has returned `nil`.
    @inlinable
    @_lifetime(self: copy self, copy fieldLine)
    public mutating func appendFieldLine(_ fieldLine: RawSpan) throws(HTTPStructuredFieldError) {
        try StructuredFieldScan.continueState(&state)
        bytes = fieldLine
        position = StructuredFieldScan.whitespaceEnd(fieldLine, from: 0)
    }
}
