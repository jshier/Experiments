public import Bytes
public import BytesBase64

/// Credentials (`Authorization`, `Proxy-Authorization`) or one challenge (`WWW-Authenticate`, `Proxy-Authenticate`),
/// RFC 9110 §11: an authentication scheme, then a token68 (`Basic`'s and `Bearer`'s), or `name=value` parameters.
///
/// ```swift
/// let credentials = try HTTPCredentials(parsing: authorization)
/// if credentials.isScheme("Bearer"), let token = credentials.token68 { … }
/// ```
@frozen
public struct HTTPCredentials: ~Escapable {
    /// The scheme, as written (schemes compare without case).
    public let scheme: RawSpan
    /// The token68, if that's what follows the scheme.
    public let token68: RawSpan?
    @usableFromInline let parameterBytes: RawSpan

    @inlinable
    @_lifetime(copy scheme, copy token68, copy parameterBytes)
    init(scheme: RawSpan, token68: RawSpan?, parameterBytes: RawSpan) {
        self.scheme = scheme
        self.token68 = token68
        self.parameterBytes = parameterBytes
    }

    /// Parses an `Authorization` value.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidCredentials``, or a quoted string's error.
    @inlinable
    @_lifetime(copy value)
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        let value = FieldGrammar.trimmed(value)
        var position = 0
        guard let credentials = try Self.scan(value, &position, challenges: false), position == value.byteCount else {
            throw .invalidCredentials
        }
        self = credentials
    }

    /// Whether the scheme is `scheme`, ignoring case (on both sides: `"Bearer"` and `"bearer"` alike).
    @inlinable
    public func isScheme(_ scheme: StaticString) -> Bool { HTTPToken.equalsIgnoringCase(self.scheme, scheme.bytes) }

    /// The auth-params (none when there's a token68).
    @inlinable
    public var parameters: HTTPAuthParameters {
        @_lifetime(copy self)
        get { HTTPAuthParameters(parameterBytes) }
    }

    /// `Basic` credentials' `user-id:password` (RFC 7617): the token68 decoded from Base64, written out.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidCredentials`` if the scheme isn't `Basic` or the token68 isn't Base64.
    @inlinable
    public func writeBasicUserPass(to writer: inout AlignedBytesWriter) throws(HTTPFieldValueError) {
        guard isScheme("Basic"), let token68 else { throw .invalidCredentials }
        do throws(LocatedBytesError) {
            try Base64.decode(token68, into: &writer)
        } catch {
            throw .invalidCredentials
        }
    }

    /// `token68` (RFC 9110 §11.2) characters: letters, digits, `-._~+/`.
    @inlinable
    static func isToken68(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E, 0x2B, 0x2F: true
        default: false
        }
    }

    /// Credentials or a challenge from `position` (after any separators): the scheme, then a token68 or parameters. In a
    /// challenge list, parameters end before an element that starts a new challenge (a token not followed by `=`).
    @inlinable
    @_lifetime(copy bytes)
    static func scan(_ bytes: RawSpan, _ position: inout Int, challenges: Bool) throws(HTTPFieldValueError) -> HTTPCredentials? {
        let count = bytes.byteCount
        let schemeStart = position
        let schemeEnd = FieldGrammar.tokenEnd(bytes, from: schemeStart)
        guard schemeEnd > schemeStart else { throw .invalidCredentials }
        let scheme = bytes.extracting(schemeStart..<schemeEnd)
        position = schemeEnd
        guard position < count, FieldGrammar.byte(bytes, position) == 0x20 else {
            // The scheme alone.
            return HTTPCredentials(scheme: scheme, token68: nil, parameterBytes: bytes.extracting(schemeEnd..<schemeEnd))
        }
        while position < count, FieldGrammar.byte(bytes, position) == 0x20 {
            position &+= 1
        }
        if position == count || FieldGrammar.byte(bytes, position) == 0x2C {
            // The scheme, then spaces and no parameters (`Negotiate , Basic realm="x"`).
            return HTTPCredentials(scheme: scheme, token68: nil, parameterBytes: bytes.extracting(schemeEnd..<schemeEnd))
        }
        let restStart = position
        // A token68: its characters, then any `=` padding, then the end or a comma.
        var end = position
        while end < count, isToken68(FieldGrammar.byte(bytes, end)) {
            end &+= 1
        }
        if end > position {
            var padded = end
            while padded < count, FieldGrammar.byte(bytes, padded) == 0x3D {
                padded &+= 1
            }
            let after = FieldGrammar.whitespaceEnd(bytes, from: padded)
            if after == count || FieldGrammar.byte(bytes, after) == 0x2C {
                position = after
                return HTTPCredentials(scheme: scheme, token68: bytes.extracting(restStart..<padded),
                                       parameterBytes: bytes.extracting(padded..<padded))
            }
        }
        // auth-params: `name BWS "=" BWS value`, separated by commas.
        var paramsEnd = position
        while true {
            let nameEnd = FieldGrammar.tokenEnd(bytes, from: position)
            guard nameEnd > position else { throw .invalidCredentials }
            var cursor = FieldGrammar.whitespaceEnd(bytes, from: nameEnd)
            guard cursor < count, FieldGrammar.byte(bytes, cursor) == 0x3D else { throw .invalidCredentials }
            cursor = FieldGrammar.whitespaceEnd(bytes, from: cursor &+ 1)
            guard cursor < count else { throw .invalidCredentials }
            if FieldGrammar.byte(bytes, cursor) == 0x22 {
                cursor = try FieldGrammar.quotedStringEnd(bytes, from: cursor).end
            } else {
                let valueEnd = FieldGrammar.tokenEnd(bytes, from: cursor)
                guard valueEnd > cursor else { throw .invalidCredentials }
                cursor = valueEnd
            }
            paramsEnd = cursor
            cursor = FieldGrammar.whitespaceEnd(bytes, from: cursor)
            guard cursor < count else { position = cursor; break }
            guard FieldGrammar.byte(bytes, cursor) == 0x2C else { throw .invalidCredentials }
            // Past commas and whitespace: another parameter (a token, then `=`), or, in a challenge list, a new challenge.
            var next = cursor
            while next < count, case let byte = FieldGrammar.byte(bytes, next), byte == 0x2C || FieldGrammar.isWhitespace(byte) {
                next &+= 1
            }
            guard next < count else { position = next; break }
            let tokenEnd = FieldGrammar.tokenEnd(bytes, from: next)
            let afterToken = FieldGrammar.whitespaceEnd(bytes, from: tokenEnd)
            if tokenEnd > next, afterToken < count, FieldGrammar.byte(bytes, afterToken) == 0x3D,
               // `token68=` before a comma or the end is a new challenge's token68, not a parameter.
               !(challenges && tokenEnd == afterToken && Self.endsToken68(bytes, from: afterToken)) {
                position = next
                continue
            }
            guard challenges else { throw .invalidCredentials }
            position = cursor
            break
        }
        return HTTPCredentials(scheme: scheme, token68: nil, parameterBytes: bytes.extracting(restStart..<paramsEnd))
    }

    /// Whether only `=` padding, then the end or a comma, follow `start`.
    @inlinable
    static func endsToken68(_ bytes: RawSpan, from start: Int) -> Bool {
        var position = start
        while position < bytes.byteCount, FieldGrammar.byte(bytes, position) == 0x3D {
            position &+= 1
        }
        position = FieldGrammar.whitespaceEnd(bytes, from: position)
        return position == bytes.byteCount || FieldGrammar.byte(bytes, position) == 0x2C
    }
}

/// Auth-params (RFC 9110 §11.2): `name = value` (whitespace allowed around `=`), separated by commas.
@frozen
public struct HTTPAuthParameters: ~Escapable {
    @usableFromInline let bytes: RawSpan
    @usableFromInline var position = 0

    @inlinable
    @_lifetime(copy bytes)
    init(_ bytes: RawSpan) { self.bytes = bytes }

    /// The next parameter, or `nil` at the end. (The credentials' parser has checked them.)
    @inlinable
    @_lifetime(copy self)
    public mutating func next() -> HTTPParameter? {
        let count = bytes.byteCount
        while position < count, case let byte = FieldGrammar.byte(bytes, position), byte == 0x2C || FieldGrammar.isWhitespace(byte) {
            position &+= 1
        }
        guard position < count else { return nil }
        let nameEnd = FieldGrammar.tokenEnd(bytes, from: position)
        let name = bytes.extracting(position..<nameEnd)
        var cursor = FieldGrammar.whitespaceEnd(bytes, from: FieldGrammar.whitespaceEnd(bytes, from: nameEnd) &+ 1)
        if FieldGrammar.byte(bytes, cursor) == 0x22 {
            // Checked by the parser: closed, valid.
            let (end, escapes) = (try? FieldGrammar.quotedStringEnd(bytes, from: cursor)) ?? (count, false)
            let text = bytes.extracting(cursor &+ 1..<Swift.max(cursor &+ 1, end &- 1))
            position = end
            return HTTPParameter(name: name, value: .quoted(HTTPQuotedString(escaped: text, hasEscapes: escapes)))
        }
        let start = cursor
        cursor = FieldGrammar.tokenEnd(bytes, from: cursor)
        position = cursor
        return HTTPParameter(name: name, value: .token(bytes.extracting(start..<cursor)))
    }

    /// The value of the first parameter named `name` (ignoring case), or `nil`.
    @inlinable
    @_lifetime(copy self)
    public func value(of name: StaticString) -> HTTPParameterValue? {
        var parameters = HTTPAuthParameters(bytes)
        while let parameter = parameters.next() {
            if parameter.isNamed(name) { return parameter.value }
        }
        return nil
    }
}

/// The challenges of a `WWW-Authenticate` or `Proxy-Authenticate` field (RFC 9110 §11.6.1): a comma-separated list
/// whose elements are a challenge's scheme or one of its parameters.
@frozen
public struct HTTPChallenges: ~Escapable {
    @usableFromInline let bytes: RawSpan
    @usableFromInline var position = 0

    /// The challenges of `value`.
    @inlinable
    @_lifetime(copy value)
    public init(_ value: RawSpan) { bytes = value }

    /// The next challenge, or `nil` at the end.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidCredentials``, or a quoted string's error.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPFieldValueError) -> HTTPCredentials? {
        while position < bytes.byteCount, case let byte = FieldGrammar.byte(bytes, position), byte == 0x2C || FieldGrammar.isWhitespace(byte) {
            position &+= 1
        }
        guard position < bytes.byteCount else { return nil }
        return try HTTPCredentials.scan(bytes, &position, challenges: true)
    }
}
