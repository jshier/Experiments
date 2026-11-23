public import Bytes

/// Percent-encoding (RFC 3986 §2.1): `%` and two hexadecimal digits for a byte.
public enum HTTPPercentEncoding {
    /// The value of a hexadecimal digit, or 0xFF.
    @inlinable @inline(__always)
    static func hexValue(_ byte: UInt8) -> UInt8 {
        if byte &- 0x30 < 10 { return byte &- 0x30 }
        let folded = byte | 0x20
        return folded &- 0x61 < 6 ? folded &- 0x57 : 0xFF
    }

    /// Writes `bytes` with each `%XX` decoded: the runs between escapes copied whole, the escapes found with 16-byte
    /// vector scans. (`+` is left alone: it's a space only in form data.)
    ///
    /// - Throws: ``HTTPFieldValueError/invalidPercentEncoding`` for a `%` not followed by two hexadecimal digits;
    ///   ``HTTPFieldValueError/outputTooSmall``.
    @inlinable
    public static func decode(_ bytes: RawSpan, to writer: inout AlignedBytesWriter) throws(HTTPFieldValueError) {
        var position = 0
        let count = bytes.byteCount
        while position < count {
            let rest = bytes.extracting(droppingFirst: position)
            guard let found = rest.firstByteOffset(where: { $0.matching(0x25) }) else {
                try FieldGrammar.write(rest, to: &writer)
                return
            }
            if found > 0 { try FieldGrammar.write(rest.extracting(0..<found), to: &writer) }
            position &+= found
            guard position &+ 2 < count else { throw .invalidPercentEncoding }
            let high = hexValue(FieldGrammar.byte(bytes, position &+ 1)), low = hexValue(FieldGrammar.byte(bytes, position &+ 2))
            guard high < 16, low < 16 else { throw .invalidPercentEncoding }
            try FieldGrammar.write(high &<< 4 | low, to: &writer)
            position &+= 3
        }
    }

    /// How many bytes ``decode(_:to:)`` writes for `bytes`.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidPercentEncoding``.
    @inlinable
    public static func decodedByteCount(_ bytes: RawSpan) throws(HTTPFieldValueError) -> Int {
        var position = 0, escapes = 0
        while position < bytes.byteCount {
            guard let found = bytes.extracting(droppingFirst: position).firstByteOffset(where: { $0.matching(0x25) }) else { break }
            position &+= found
            guard position &+ 2 < bytes.byteCount, hexValue(FieldGrammar.byte(bytes, position &+ 1)) < 16,
                  hexValue(FieldGrammar.byte(bytes, position &+ 2)) < 16 else { throw .invalidPercentEncoding }
            escapes &+= 1
            position &+= 3
        }
        return bytes.byteCount &- 2 &* escapes
    }
}

/// A request target's parts (RFC 9112 §3.2, RFC 3986 §3), split by its form without decoding or validating anything
/// (``HTTPRequestTarget/validate(_:method:)`` checks a target, and for every target it accepts, gives the same form):
/// `/path?query`, `scheme:[//authority]path?query`, `host:port` (CONNECT), or `*`.
@frozen
public struct HTTPTargetComponents: ~Escapable {
    /// The form.
    public let form: HTTPRequestTargetForm
    /// The scheme (absolute-form).
    public let scheme: RawSpan?
    /// The authority (authority-form, and absolute-form with `//`; for a `Host`-like parse, ``HTTPHost/init(parsing:)``).
    public let authority: RawSpan?
    /// The path: `/…` (origin-form), `/…` or empty (absolute-form), empty (authority-form), `*` (asterisk-form).
    public let path: RawSpan
    /// The query after `?`, if there's a `?`.
    public let query: RawSpan?

    /// Splits `target`, the target of a request with `method` (authority-form is CONNECT's, and only CONNECT's, as
    /// ``HTTPRequestTarget/validate(_:method:)`` decides).
    @inlinable
    @_lifetime(copy target)
    public init(_ target: RawSpan, method: HTTPMethod? = nil) {
        let count = target.byteCount
        // A fragment doesn't belong in a request target; its start ends the rest regardless.
        let end = target.firstByteOffset(where: { $0.matching(0x23) }) ?? count
        let target = target.extracting(0..<end)
        if method == .connect {
            form = .authority
            scheme = nil
            authority = target
            path = target.extracting(end..<end)
            query = nil
            return
        }
        if end > 0, FieldGrammar.byte(target, 0) == 0x2F {
            form = .origin
            scheme = nil
            authority = nil
            (path, query) = Self.pathAndQuery(target)
            return
        }
        if end == 1, FieldGrammar.byte(target, 0) == 0x2A {
            form = .asterisk
            scheme = nil
            authority = nil
            path = target
            query = nil
            return
        }
        // absolute-form: `scheme ":"`, then `//authority` if it's there, then the path and query.
        form = .absolute
        var colon = 0
        while colon < end, FieldGrammar.byte(target, colon) != 0x3A { colon &+= 1 }
        scheme = target.extracting(0..<colon)
        let rest = colon < end ? colon &+ 1 : end
        if rest &+ 1 < end, FieldGrammar.byte(target, rest) == 0x2F, FieldGrammar.byte(target, rest &+ 1) == 0x2F {
            let authorityStart = rest &+ 2
            var authorityEnd = authorityStart
            while authorityEnd < end, case let byte = FieldGrammar.byte(target, authorityEnd), byte != 0x2F, byte != 0x3F { authorityEnd &+= 1 }
            authority = target.extracting(authorityStart..<authorityEnd)
            (path, query) = Self.pathAndQuery(target.extracting(droppingFirst: authorityEnd))
        } else {
            authority = nil
            (path, query) = Self.pathAndQuery(target.extracting(droppingFirst: rest))
        }
    }

    @inlinable
    @_lifetime(copy bytes)
    static func pathAndQuery(_ bytes: RawSpan) -> (RawSpan, RawSpan?) {
        guard let mark = bytes.firstByteOffset(where: { $0.matching(0x3F) }) else { return (bytes, nil) }
        return (bytes.extracting(0..<mark), bytes.extracting(droppingFirst: mark &+ 1))
    }

    /// The path's segments: what's between its `/`s (`/a//b/` is `a`, empty, `b`, empty), still percent-encoded.
    @inlinable
    public var pathSegments: HTTPPathSegments {
        @_lifetime(copy self)
        get { HTTPPathSegments(form == .origin || form == .absolute ? path : path.extracting(0..<0)) }
    }

    /// The query's `name=value` items, split at `&` and the first `=`, still encoded (no `+` decoding: that's form
    /// data's).
    @inlinable
    public var queryItems: HTTPQueryItems {
        @_lifetime(copy self)
        get {
            if let query { return HTTPQueryItems(query) }
            return HTTPQueryItems(path.extracting(0..<0))
        }
    }
}

/// A path's segments.
@frozen
public struct HTTPPathSegments: ~Escapable {
    @usableFromInline let bytes: RawSpan
    @usableFromInline var position: Int

    @inlinable
    @_lifetime(copy path)
    init(_ path: RawSpan) {
        bytes = path
        // The first `/` opens the first segment; an empty path has none.
        position = path.byteCount > 0 && FieldGrammar.byte(path, 0) == 0x2F ? 1 : (path.byteCount == 0 ? 1 : 0)
    }

    /// The next segment, or `nil` at the end.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() -> RawSpan? {
        guard position <= bytes.byteCount, bytes.byteCount > 0 else { return nil }
        let rest = bytes.extracting(droppingFirst: position)
        let length = rest.firstByteOffset(where: { $0.matching(0x2F) }) ?? rest.byteCount
        let segment = rest.extracting(0..<length)
        position &+= length &+ 1
        return segment
    }
}

/// A query item: a name and, if there's an `=`, a value.
@frozen
public struct HTTPQueryItem: ~Escapable {
    /// The name, still encoded.
    public let name: RawSpan
    /// The value, still encoded; `nil` without an `=`.
    public let value: RawSpan?

    @inlinable
    @_lifetime(copy name, copy value)
    init(name: RawSpan, value: RawSpan?) {
        self.name = name
        self.value = value
    }
}

/// A query's items, split at `&` (empty ones skipped).
@frozen
public struct HTTPQueryItems: ~Escapable {
    @usableFromInline let bytes: RawSpan
    @usableFromInline var position = 0

    @inlinable
    @_lifetime(copy query)
    init(_ query: RawSpan) { bytes = query }

    /// The next item, or `nil` at the end.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() -> HTTPQueryItem? {
        while position < bytes.byteCount, FieldGrammar.byte(bytes, position) == 0x26 { position &+= 1 }
        guard position < bytes.byteCount else { return nil }
        let rest = bytes.extracting(droppingFirst: position)
        let length = rest.firstByteOffset(where: { $0.matching(0x26) }) ?? rest.byteCount
        let item = rest.extracting(0..<length)
        position &+= length &+ 1
        guard let equals = item.firstByteOffset(where: { $0.matching(0x3D) }) else { return HTTPQueryItem(name: item, value: nil) }
        return HTTPQueryItem(name: item.extracting(0..<equals), value: item.extracting(droppingFirst: equals &+ 1))
    }
}

// MARK: - Content-Disposition

/// `Content-Disposition` (RFC 6266): `inline` or `attachment` (or another type), and parameters, `filename` and
/// `filename*` (RFC 8187: `charset'language'percent-encoded`) among them.
@frozen
public struct HTTPContentDisposition: ~Escapable {
    /// The disposition type, as written (compare without case).
    public let type: RawSpan
    @usableFromInline let parameterBytes: RawSpan

    /// Parses the value and checks its parameters' syntax.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidToken`` for a type that isn't a token, or a parameter's error.
    @inlinable
    @_lifetime(copy value)
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        let value = FieldGrammar.trimmed(value)
        let typeEnd = FieldGrammar.tokenEnd(value, from: 0)
        guard typeEnd > 0 else { throw .invalidToken }
        type = value.extracting(0..<typeEnd)
        parameterBytes = value.extracting(droppingFirst: typeEnd)
        // Every parameter well formed, and none named twice (RFC 6266 §4.1: such a field is invalid; recipients that
        // take the first and the last of two `filename`s would save different files).
        var outer = HTTPParameters(parameterBytes)
        var index = 0
        while let parameter = try outer.next() {
            var inner = HTTPParameters(parameterBytes)
            var earlier = 0
            while earlier < index, let previous = try inner.next() {
                guard !HTTPToken.equalsIgnoringCase(parameter.name, previous.name) else { throw .invalidParameter }
                earlier &+= 1
            }
            index &+= 1
        }
    }

    /// The parameters, in order.
    @inlinable
    public var parameters: HTTPParameters {
        @_lifetime(copy self)
        get { HTTPParameters(parameterBytes) }
    }

    /// Whether the type is `attachment` (a download), ignoring case.
    @inlinable
    public var isAttachment: Bool { HTTPToken.equalsIgnoringCase(type, "attachment") }

    /// Writes the file name, UTF-8: `filename*` decoded if it's there in a charset this knows (UTF-8 or ISO-8859-1, the
    /// latter converted), else `filename`'s text (RFC 6266 §4.3). Returns whether there was one. Either way the name is
    /// well-formed UTF-8 without control characters (a `filename*` that isn't falls back to `filename`); it's still the
    /// sender's: a caller saving a file must take only its last path component and check it.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidParameter`` for a `filename` that isn't such text;
    ///   ``HTTPFieldValueError/outputTooSmall``.
    @inlinable
    public func writeFileName(to writer: inout AlignedBytesWriter) throws(HTTPFieldValueError) -> Bool {
        // Checked by the initializer: the parameters don't throw.
        if let extended = try? parameters.value(of: "filename*") {
            switch extended {
            case .token(let text):
                let start = writer.position
                do throws(HTTPFieldValueError) {
                    try HTTPExtendedValue.decode(text, to: &writer)
                    return true
                } catch {
                    if error == .outputTooSmall { throw error }
                    // Not one this decodes: `filename` instead.
                    writer.rewind(to: start)
                }
            case .quoted:
                break
            }
        }
        guard let plain = try? parameters.value(of: "filename") else { return false }
        // The same rule for the plain name's text: UTF-8 without controls (a quoted string may hold tabs and obs-text).
        var check = FileNameTextCheck()
        let (text, escaped): (RawSpan, Bool) = switch plain {
        case .token(let token): (token, false)
        case .quoted(let string): (string.escaped, string.hasEscapes)
        }
        var position = 0
        while position < text.byteCount {
            if escaped, FieldGrammar.byte(text, position) == 0x5C { position &+= 1 }
            guard check.accept(FieldGrammar.byte(text, position)) else { throw .invalidParameter }
            position &+= 1
        }
        guard check.isComplete else { throw .invalidParameter }
        do throws(BytesError) { try plain.write(to: &writer) } catch { throw .outputTooSmall }
        return true
    }
}

/// Checks text a byte at a time: well-formed UTF-8 (no overlong forms, surrogates, or code points past U+10FFFF), and no
/// C0 control, DEL, or C1 control (U+0080–U+009F). For file names: a decoded name may hold anything percent-encoded.
@usableFromInline
struct FileNameTextCheck {
    /// Continuation bytes still expected.
    @usableFromInline var needed = 0
    /// The allowed range of the next continuation byte.
    @usableFromInline var low: UInt8 = 0x80
    @usableFromInline var high: UInt8 = 0xBF
    /// The lead byte of the current sequence (to refuse C1 controls, `C2 80`–`C2 9F`).
    @usableFromInline var lead: UInt8 = 0

    @inlinable init() {}

    /// Takes the next byte; `false` if the text can't be a file name.
    @inlinable
    mutating func accept(_ byte: UInt8) -> Bool {
        if needed > 0 {
            guard byte >= low, byte <= high else { return false }
            if lead == 0xC2, byte < 0xA0 { return false }
            needed &-= 1
            (low, high) = (0x80, 0xBF)
            return true
        }
        lead = byte
        switch byte {
        case 0x00..<0x20, 0x7F: return false
        case 0x20..<0x80: return true
        case 0xC2...0xDF: needed = 1
        case 0xE0: (needed, low) = (2, 0xA0)
        case 0xE1...0xEC, 0xEE, 0xEF: needed = 2
        case 0xED: (needed, high) = (2, 0x9F)
        case 0xF0: (needed, low) = (3, 0x90)
        case 0xF1...0xF3: needed = 3
        case 0xF4: (needed, high) = (3, 0x8F)
        default: return false
        }
        return true
    }

    /// Whether the text ended on a whole character.
    @inlinable var isComplete: Bool { needed == 0 }
}

/// RFC 8187's extended parameter values: `charset "'" [ language ] "'" value-chars`.
public enum HTTPExtendedValue {
    /// Writes the value's text as UTF-8: percent escapes decoded, ISO-8859-1 converted. The text must be a file name's:
    /// well-formed UTF-8 (or ISO-8859-1) without control characters, which only escapes could have put there.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidPercentEncoding`` for a charset other than UTF-8 or ISO-8859-1, a
    ///   malformed escape, or decoded text that isn't such a name; ``HTTPFieldValueError/outputTooSmall``. The writer
    ///   may hold part of the text then.
    @inlinable
    public static func decode(_ value: RawSpan, to writer: inout AlignedBytesWriter) throws(HTTPFieldValueError) {
        guard let first = value.firstByteOffset(where: { $0.matching(0x27) }) else { throw .invalidPercentEncoding }
        let charset = value.extracting(0..<first)
        let rest = value.extracting(droppingFirst: first &+ 1)
        guard let second = rest.firstByteOffset(where: { $0.matching(0x27) }) else { throw .invalidPercentEncoding }
        let text = rest.extracting(droppingFirst: second &+ 1)
        // Lowercase literals: `equalsIgnoringCase(_:_: StaticString)` folds only the field's side.
        let isUTF8 = HTTPToken.equalsIgnoringCase(charset, "utf-8")
        guard isUTF8 || HTTPToken.equalsIgnoringCase(charset, "iso-8859-1") else { throw .invalidPercentEncoding }
        var check = FileNameTextCheck()
        var position = 0
        while position < text.byteCount {
            var byte = FieldGrammar.byte(text, position)
            if byte == 0x25 {
                guard position &+ 2 < text.byteCount, case let high = HTTPPercentEncoding.hexValue(FieldGrammar.byte(text, position &+ 1)),
                      case let low = HTTPPercentEncoding.hexValue(FieldGrammar.byte(text, position &+ 2)), high < 16, low < 16
                else { throw .invalidPercentEncoding }
                byte = high &<< 4 | low
                position &+= 2
            }
            if isUTF8 {
                guard check.accept(byte) else { throw .invalidPercentEncoding }
                try FieldGrammar.write(byte, to: &writer)
            } else if byte < 0x80 {
                // ISO-8859-1: each byte a code point, C0, DEL, and C1 controls refused, 0xA0 and above as two bytes.
                guard check.accept(byte) else { throw .invalidPercentEncoding }
                try FieldGrammar.write(byte, to: &writer)
            } else {
                guard byte >= 0xA0 else { throw .invalidPercentEncoding }
                try FieldGrammar.write(0xC0 | byte &>> 6, to: &writer)
                try FieldGrammar.write(0x80 | byte & 0x3F, to: &writer)
            }
            position &+= 1
        }
        guard check.isComplete else { throw .invalidPercentEncoding }
    }
}
