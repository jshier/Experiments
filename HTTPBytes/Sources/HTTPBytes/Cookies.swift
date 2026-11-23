public import Bytes

/// A cookie from a `Cookie` field: a name and a value (its surrounding double quotes, if any, removed).
@frozen
public struct HTTPCookie: ~Escapable {
    /// The name.
    public let name: RawSpan
    /// The value.
    public let value: RawSpan

    @inlinable
    @_lifetime(copy name, copy value)
    init(name: RawSpan, value: RawSpan) {
        self.name = name
        self.value = value
    }
}

/// The cookies of a `Cookie` field (RFC 6265 §4.2.1: `name=value` separated by `; `), read as user agents send them:
/// pairs split at `;`, trimmed, a pair without `=` skipped. Several `Cookie` field lines (HTTP/2 and HTTP/3 split them):
/// iterate each line.
@frozen
public struct HTTPCookies: ~Escapable {
    @usableFromInline let bytes: RawSpan
    @usableFromInline var position = 0

    /// The cookies of `value`.
    @inlinable
    @_lifetime(copy value)
    public init(_ value: RawSpan) { bytes = value }

    /// The next cookie, or `nil` at the end.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() -> HTTPCookie? {
        while position < bytes.byteCount {
            let rest = bytes.extracting(droppingFirst: position)
            let length = rest.firstByteOffset(where: { $0.matching(0x3B) }) ?? rest.byteCount
            position &+= length &+ 1
            let pair = FieldGrammar.trimmed(rest.extracting(0..<length))
            guard let equals = pair.firstByteOffset(where: { $0.matching(0x3D) }), equals > 0 else { continue }
            let name = FieldGrammar.trimmed(pair.extracting(0..<equals))
            var value = FieldGrammar.trimmed(pair.extracting(droppingFirst: equals &+ 1))
            if value.byteCount >= 2, FieldGrammar.byte(value, 0) == 0x22, FieldGrammar.byte(value, value.byteCount &- 1) == 0x22 {
                value = value.extracting(1..<value.byteCount &- 1)
            }
            return HTTPCookie(name: name, value: value)
        }
        return nil
    }

    /// The value of the first cookie named `name` (case-sensitive), or `nil`.
    @inlinable
    @_lifetime(copy value)
    public static func value(named name: RawSpan, in value: RawSpan) -> RawSpan? {
        var cookies = HTTPCookies(value)
        while let cookie = cookies.next() {
            if cookie.name.bytesEqual(name) { return cookie.value }
        }
        return nil
    }
}

/// A `Set-Cookie` field to write (RFC 6265 §4.1, with `SameSite` and `Partitioned` from RFC 6265bis): the name and value
/// checked against RFC 6265's grammar, attribute values against control characters and `;`.
///
/// ```swift
/// var cookie = HTTPSetCookie(name: sessionName, value: token)
/// cookie.maxAge = 3600; cookie.isSecure = true; cookie.isHTTPOnly = true; cookie.sameSite = .lax
/// try cookie.write(to: &writer)
/// ```
@frozen
public struct HTTPSetCookie: ~Escapable {
    /// `SameSite`'s values.
    @frozen
    public enum SameSite: Sendable, Hashable {
        /// `Strict`.
        case strict
        /// `Lax`.
        case lax
        /// `None` (needs `Secure`).
        case none
    }

    /// The name: a token.
    public var name: RawSpan
    /// The value: cookie-octets, optionally in double quotes.
    public var value: RawSpan
    /// `Expires`.
    public var expires: HTTPDate?
    /// `Max-Age`, in seconds (0 or less: expire now).
    public var maxAge: Int?
    /// `Domain`.
    public var domain: RawSpan?
    /// `Path`.
    public var path: RawSpan?
    /// `Secure`.
    public var isSecure = false
    /// `HttpOnly`.
    public var isHTTPOnly = false
    /// `SameSite`.
    public var sameSite: SameSite?
    /// `Partitioned`.
    public var isPartitioned = false

    /// A cookie `name=value` with no attributes.
    @inlinable
    @_lifetime(copy name, copy value)
    public init(name: RawSpan, value: RawSpan) {
        self.name = name
        self.value = value
        domain = nil
        path = nil
    }

    /// cookie-octet: 0x21, 0x23–0x2B, 0x2D–0x3A, 0x3C–0x5B, 0x5D–0x7E.
    @inlinable
    static func isCookieOctet(_ byte: UInt8) -> Bool {
        byte == 0x21 || byte >= 0x23 && byte <= 0x7E && byte != 0x2C && byte != 0x3B && byte != 0x5C
    }

    /// Writes the field's value.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidCookie`` for a name that isn't a token, a value with a byte outside
    ///   cookie-octets (or an unmatched quote), a `Domain` or `Path` with a control character, `;`, or a byte past ASCII, or `SameSite=None`
    ///   without `Secure`; ``HTTPFieldValueError/outputTooSmall``.
    @inlinable
    public func write(to writer: inout AlignedBytesWriter) throws(HTTPFieldValueError) {
        guard FieldGrammar.isToken(name) else { throw .invalidCookie }
        var octets = value
        if value.byteCount >= 2, FieldGrammar.byte(value, 0) == 0x22, FieldGrammar.byte(value, value.byteCount &- 1) == 0x22 {
            octets = value.extracting(1..<value.byteCount &- 1)
        }
        for offset in 0..<octets.byteCount where !Self.isCookieOctet(FieldGrammar.byte(octets, offset)) { throw .invalidCookie }
        if sameSite == SameSite.none, !isSecure { throw .invalidCookie }
        try FieldGrammar.write(name, to: &writer)
        try FieldGrammar.write(0x3D, to: &writer)
        try FieldGrammar.write(value, to: &writer)
        if let expires {
            try Self.attribute("; Expires=", to: &writer)
            do throws(BytesError) { try expires.write(to: &writer) } catch { throw .outputTooSmall }
        }
        if let maxAge {
            try Self.attribute("; Max-Age=", to: &writer)
            if maxAge <= 0 { try FieldGrammar.write(0x30, to: &writer) } else {
                do throws(BytesError) { try HTTPContentRange.writeNumber(maxAge, to: &writer) } catch { throw .outputTooSmall }
            }
        }
        if let domain {
            try Self.checkAttributeValue(domain)
            try Self.attribute("; Domain=", to: &writer)
            try FieldGrammar.write(domain, to: &writer)
        }
        if let path {
            try Self.checkAttributeValue(path)
            try Self.attribute("; Path=", to: &writer)
            try FieldGrammar.write(path, to: &writer)
        }
        if isSecure { try Self.attribute("; Secure", to: &writer) }
        if isHTTPOnly { try Self.attribute("; HttpOnly", to: &writer) }
        switch sameSite {
        case .strict?: try Self.attribute("; SameSite=Strict", to: &writer)
        case .lax?: try Self.attribute("; SameSite=Lax", to: &writer)
        case .none?: try Self.attribute("; SameSite=None", to: &writer)
        case nil: break
        }
        if isPartitioned { try Self.attribute("; Partitioned", to: &writer) }
    }

    @inlinable
    static func checkAttributeValue(_ value: RawSpan) throws(HTTPFieldValueError) {
        for offset in 0..<value.byteCount {
            let byte = FieldGrammar.byte(value, offset)
            // RFC 6265's path-value: any CHAR (ASCII) but controls and `;`.
            guard byte >= 0x20, byte < 0x7F, byte != 0x3B else { throw .invalidCookie }
        }
    }

    @inlinable
    static func attribute(_ text: StaticString, to writer: inout AlignedBytesWriter) throws(HTTPFieldValueError) {
        try FieldGrammar.write(immortalSpan(text), to: &writer)
    }
}
