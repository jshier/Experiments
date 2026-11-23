public import Bytes

/// A list of tokens: `Vary` (field names, or `*`), `Connection` (options and field names), `Trailer`, `Allow`,
/// `Accept-Ranges`, `Content-Language`'s tags, `Cache-Control`'s `no-cache` field lists.
///
/// ```swift
/// var vary = HTTPTokenList(value)
/// if vary.isAny { … } else { while let name = try vary.next() { … HTTPFieldName(caseInsensitive: name) … } }
/// ```
@frozen
public struct HTTPTokenList: ~Escapable {
    @usableFromInline var elements: HTTPListElements
    /// Whether the value is `*` (`Vary: *`: anything about the request may vary the response).
    public let isAny: Bool

    /// The tokens of `value`.
    @inlinable
    @_lifetime(copy value)
    public init(_ value: RawSpan) {
        let trimmed = FieldGrammar.trimmed(value)
        isAny = trimmed.byteCount == 1 && FieldGrammar.byte(trimmed, 0) == 0x2A
        elements = HTTPListElements(value)
    }

    /// The next token, or `nil` at the end.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidToken`` for an element that isn't a token (`*` alone is one).
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPFieldValueError) -> RawSpan? {
        guard let element = try elements.next() else { return nil }
        guard FieldGrammar.isToken(element) else { throw .invalidToken }
        return element
    }

    /// Whether the list has `token` (ignoring case); a malformed list has nothing, wherever the malformed element is.
    @inlinable
    public static func contains(_ value: RawSpan, _ token: StaticString) -> Bool {
        var list = HTTPTokenList(value)
        var found = false
        do throws(HTTPFieldValueError) {
            while let element = try list.next() {
                if HTTPToken.equalsIgnoringCase(element, immortalSpan(token)) { found = true }
            }
        } catch {
            return false
        }
        return found
    }
}

/// An `Upgrade` protocol (RFC 9110 §7.8): a name and an optional version (`websocket`, `HTTP/2.0`).
@frozen
public struct HTTPUpgradeProtocol: ~Escapable {
    /// The protocol's name.
    public let name: RawSpan
    /// Its version, if given.
    public let version: RawSpan?

    @inlinable
    @_lifetime(copy name, copy version)
    init(name: RawSpan, version: RawSpan?) {
        self.name = name
        self.version = version
    }
}

/// The protocols of an `Upgrade` field, in the client's order of preference.
@frozen
public struct HTTPUpgradeList: ~Escapable {
    @usableFromInline var elements: HTTPListElements

    /// The protocols of `value`.
    @inlinable
    @_lifetime(copy value)
    public init(_ value: RawSpan) { elements = HTTPListElements(value) }

    /// The next protocol, or `nil` at the end.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidToken`` for an element that isn't `token["/"token]`.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPFieldValueError) -> HTTPUpgradeProtocol? {
        guard let element = try elements.next() else { return nil }
        let nameEnd = FieldGrammar.tokenEnd(element, from: 0)
        guard nameEnd > 0 else { throw .invalidToken }
        if nameEnd == element.byteCount { return HTTPUpgradeProtocol(name: element, version: nil) }
        guard FieldGrammar.byte(element, nameEnd) == 0x2F, FieldGrammar.tokenEnd(element, from: nameEnd &+ 1) == element.byteCount,
              nameEnd &+ 1 < element.byteCount else { throw .invalidToken }
        return HTTPUpgradeProtocol(name: element.extracting(0..<nameEnd), version: element.extracting(droppingFirst: nameEnd &+ 1))
    }
}

// MARK: - Host

/// A `Host` field, or a URI's authority without user information (RFC 9110 §7.2, RFC 3986 §3.2.2): a host and an
/// optional port.
///
/// The host's kind follows RFC 3986's grammar: four decimal octets without leading zeros are an IPv4 address, anything
/// else of unreserved characters, sub-delims, and percent escapes a registered name (which may be empty); `[…]` holds an
/// IPv6 address (zone identifiers are refused: RFC 9844 removed RFC 6874's URI form) or an IPvFuture literal.
@frozen
public struct HTTPHost: ~Escapable {
    /// The kinds of host.
    @frozen
    public enum Kind: Sendable, Hashable {
        /// A registered name: usually a DNS name, possibly empty.
        case registeredName
        /// An IPv4 address.
        case ipv4
        /// An IPv6 address (``HTTPHost/host`` without its brackets).
        case ipv6
        /// An IPvFuture literal (``HTTPHost/host`` without its brackets).
        case ipFuture
    }

    /// The host's kind.
    public let kind: Kind
    /// The host: a name, an address, or an IP literal without its brackets.
    public let host: RawSpan
    /// The port, if there's one (an empty port, `host:`, is none).
    public let port: Int?

    /// Parses `uri-host [ ":" port ]`.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidHost``.
    @inlinable
    @_lifetime(copy value)
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        let value = FieldGrammar.trimmed(value)
        let count = value.byteCount
        var hostEnd: Int
        if count > 0, FieldGrammar.byte(value, 0) == 0x5B {
            // An IP literal: up to `]`.
            var close = 1
            while close < count, FieldGrammar.byte(value, close) != 0x5D { close &+= 1 }
            guard close < count else { throw .invalidHost }
            let literal = value.extracting(1..<close)
            if literal.byteCount > 0, FieldGrammar.byte(literal, 0) | 0x20 == 0x76 {
                guard Self.isIPFuture(literal) else { throw .invalidHost }
                kind = .ipFuture
            } else {
                guard Self.isIPv6(literal) else { throw .invalidHost }
                kind = .ipv6
            }
            host = literal
            hostEnd = close &+ 1
        } else {
            hostEnd = 0
            while hostEnd < count, FieldGrammar.byte(value, hostEnd) != 0x3A { hostEnd &+= 1 }
            let name = value.extracting(0..<hostEnd)
            guard Self.isRegisteredName(name) else { throw .invalidHost }
            // An IPv4 address starts with a digit; most names don't, and skip the test.
            let digitFirst = hostEnd > 0 && FieldGrammar.byte(name, 0) &- 0x30 < 10
            kind = digitFirst && Self.isIPv4(name) ? .ipv4 : .registeredName
            host = name
        }
        guard hostEnd < count else { port = nil; return }
        guard FieldGrammar.byte(value, hostEnd) == 0x3A else { throw .invalidHost }
        if hostEnd &+ 1 == count { port = nil; return }
        guard let (number, end) = FieldGrammar.saturatingNumber(value, from: hostEnd &+ 1), end == count, number <= 65_535 else {
            throw .invalidHost
        }
        port = number
    }

    @inlinable
    static func isHexDigit(_ byte: UInt8) -> Bool { byte &- 0x30 < 10 || (byte | 0x20) &- 0x61 < 6 }

    /// `*( unreserved / pct-encoded / sub-delims )`: one 16-byte pass for the characters (a request target's, less
    /// `:`, `@`, `/`, `?`, `[`, `]`), then the escapes' digits only if there's a `%`.
    @inlinable
    static func isRegisteredName(_ name: RawSpan) -> Bool {
        guard !name.containsByte(where: { lanes in
            HTTPRequestTarget.nonURIByte(lanes) | lanes.matching(0x3A) | lanes.matching(0x40) | lanes.matching(0x2F)
                | lanes.matching(0x3F) | lanes.matching(0x5B) | lanes.matching(0x5D)
        }) else { return false }
        guard name.containsByte(where: { $0.matching(0x25) }) else { return true }
        var position = 0
        while position < name.byteCount {
            let byte = FieldGrammar.byte(name, position)
            if byte == 0x25 {
                guard position &+ 2 < name.byteCount, isHexDigit(FieldGrammar.byte(name, position &+ 1)),
                      isHexDigit(FieldGrammar.byte(name, position &+ 2)) else { return false }
                position &+= 3
                continue
            }
            guard isUnreservedOrSubDelimiter(byte) else { return false }
            position &+= 1
        }
        return true
    }

    /// RFC 3986's unreserved characters and sub-delims.
    @inlinable
    static func isUnreservedOrSubDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E: true
        case 0x21, 0x24, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x3B, 0x3D: true
        default: false
        }
    }

    /// Four dec-octets (0–255, no leading zeros) joined by dots.
    @inlinable
    static func isIPv4(_ text: RawSpan) -> Bool {
        var position = 0
        for octet in 0..<4 {
            if octet > 0 {
                guard position < text.byteCount, FieldGrammar.byte(text, position) == 0x2E else { return false }
                position &+= 1
            }
            let start = position
            var value = 0
            while position < text.byteCount, position &- start < 3, case let digit = FieldGrammar.byte(text, position) &- 0x30, digit < 10 {
                value = value &* 10 &+ Int(digit)
                position &+= 1
            }
            let length = position &- start
            guard length > 0, value <= 255, length == 1 || FieldGrammar.byte(text, start) != 0x30 else { return false }
        }
        return position == text.byteCount
    }

    /// An IPv6 address (RFC 3986 §3.2.2): up to eight groups of 1–4 hexadecimal digits, at most one `::`, the last 32
    /// bits optionally an IPv4 address.
    @inlinable
    static func isIPv6(_ text: RawSpan) -> Bool {
        let count = text.byteCount
        guard count >= 2 else { return false }
        var groups = 0, position = 0
        var compressed = false
        if FieldGrammar.byte(text, 0) == 0x3A {
            guard FieldGrammar.byte(text, 1) == 0x3A else { return false }
            compressed = true
            position = 2
            if position == count { return true }
        }
        while position < count {
            // A group, or the trailing IPv4 address.
            let start = position
            while position < count, position &- start < 5, isHexDigit(FieldGrammar.byte(text, position)) { position &+= 1 }
            if position < count, FieldGrammar.byte(text, position) == 0x2E {
                guard groups <= (compressed ? 5 : 6), isIPv4(text.extracting(droppingFirst: start)) else { return false }
                return compressed || groups == 6
            }
            let length = position &- start
            guard length >= 1, length <= 4 else { return false }
            groups &+= 1
            guard groups <= 8 else { return false }
            if position == count { break }
            guard FieldGrammar.byte(text, position) == 0x3A, position &+ 1 < count else { return false }
            position &+= 1
            if FieldGrammar.byte(text, position) == 0x3A {
                guard !compressed else { return false }
                compressed = true
                position &+= 1
                if position == count { break }
            }
        }
        return compressed ? groups <= 7 : groups == 8
    }

    /// `"v" 1*HEXDIG "." 1*( unreserved / sub-delims / ":" )`.
    @inlinable
    static func isIPFuture(_ text: RawSpan) -> Bool {
        var position = 1
        while position < text.byteCount, isHexDigit(FieldGrammar.byte(text, position)) { position &+= 1 }
        guard position > 1, position < text.byteCount, FieldGrammar.byte(text, position) == 0x2E else { return false }
        position &+= 1
        guard position < text.byteCount else { return false }
        while position < text.byteCount {
            let byte = FieldGrammar.byte(text, position)
            guard byte == 0x3A || isUnreservedOrSubDelimiter(byte) else { return false }
            position &+= 1
        }
        return true
    }
}

// MARK: - Forwarded

/// The elements of a `Forwarded` field (RFC 7239): one per proxy, nearest the client first, each a set of `name=value`
/// pairs (`for`, `by`, `host`, `proto`).
///
/// ```swift
/// var hops = HTTPForwardedElements(value)
/// while var pairs = try hops.next() { while let pair = try pairs.next() { if pair.isNamed("for") { … } } }
/// ```
@frozen
public struct HTTPForwardedElements: ~Escapable {
    @usableFromInline var elements: HTTPListElements

    /// The elements of `value`.
    @inlinable
    @_lifetime(copy value)
    public init(_ value: RawSpan) { elements = HTTPListElements(value) }

    /// The next element's pairs, or `nil` at the end.
    ///
    /// - Throws: A quoted string's error (the pairs themselves are checked as they're read).
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPFieldValueError) -> HTTPParameters? {
        guard let element = try elements.next() else { return nil }
        return HTTPParameters(pairs: element)
    }
}
