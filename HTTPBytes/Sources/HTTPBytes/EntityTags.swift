public import Bytes

/// An entity tag (RFC 9110 §8.8.3): `"opaque"`, or `W/"opaque"` for a weak one. Not a quoted string: there are no
/// escapes (a backslash is an ordinary character), and `W/` is case-sensitive.
@frozen
public struct HTTPEntityTag: ~Escapable {
    /// Whether it's weak (`W/`).
    public let isWeak: Bool
    /// The characters between the quotes.
    public let opaque: RawSpan

    /// An entity tag of `opaque` (the characters between the quotes).
    @inlinable
    @_lifetime(copy opaque)
    public init(opaque: RawSpan, isWeak: Bool = false) {
        self.opaque = opaque
        self.isWeak = isWeak
    }

    /// Parses an entity tag (an `ETag` field's value).
    ///
    /// - Throws: ``HTTPFieldValueError/invalidEntityTag``.
    @inlinable
    @_lifetime(copy value)
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        let value = FieldGrammar.trimmed(value)
        guard let (isWeak, start, end) = Self.scan(value, from: 0), end == value.byteCount else { throw .invalidEntityTag }
        self.isWeak = isWeak
        opaque = value.extracting(start..<end &- 1)
    }

    /// The entity tag at `start`: whether it's weak, where its opaque characters start, and the offset after its closing
    /// quote; `nil` if there isn't one.
    @inlinable
    static func scan(_ bytes: RawSpan, from start: Int) -> (isWeak: Bool, opaqueStart: Int, end: Int)? {
        let count = bytes.byteCount
        var position = start
        var isWeak = false
        if position &+ 1 < count, FieldGrammar.byte(bytes, position) == 0x57, FieldGrammar.byte(bytes, position &+ 1) == 0x2F {
            isWeak = true
            position &+= 2
        }
        guard position < count, FieldGrammar.byte(bytes, position) == 0x22 else { return nil }
        position &+= 1
        let opaqueStart = position
        // etagc is 0x21, 0x23–0x7E, and obs-text: the first byte that isn't, found 16 at a time, must be the closing quote.
        guard position < count, let found = bytes.extracting(droppingFirst: position).firstByteOffset(where: { lanes in
            let vector = lanes.vector
            return HTTPCharacters.matches((vector .<= SIMD16(repeating: 0x20)) .| (vector .== SIMD16(repeating: 0x7F))
                .| (vector .== SIMD16(repeating: 0x22)))
        }) else { return nil }
        position &+= found
        guard FieldGrammar.byte(bytes, position) == 0x22 else { return nil }
        return (isWeak, opaqueStart, position &+ 1)
    }

    /// Strong comparison (RFC 9110 §8.8.3.2): neither is weak, and the opaque characters are the same.
    @inlinable
    public func strongMatches(_ other: borrowing HTTPEntityTag) -> Bool {
        !isWeak && !other.isWeak && opaque.bytesEqual(other.opaque)
    }

    /// Weak comparison: the opaque characters are the same, weak or not.
    @inlinable
    public func weakMatches(_ other: borrowing HTTPEntityTag) -> Bool { opaque.bytesEqual(other.opaque) }

    /// Writes the entity tag (`W/"…"` or `"…"`), its opaque characters checked first (a quote, a control, or a space in
    /// them would end the field's value early or inject another field).
    ///
    /// - Throws: ``HTTPFieldValueError/invalidEntityTag`` for a character that isn't etagc (RFC 9110 §8.8.3);
    ///   ``HTTPFieldValueError/outputTooSmall``.
    @inlinable
    public func write(to writer: inout AlignedBytesWriter) throws(HTTPFieldValueError) {
        guard !opaque.containsByte(where: { lanes in
            let vector = lanes.vector
            return HTTPCharacters.matches((vector .<= SIMD16(repeating: 0x20)) .| (vector .== SIMD16(repeating: 0x7F))
                .| (vector .== SIMD16(repeating: 0x22)))
        }) else { throw .invalidEntityTag }
        do throws(BytesError) {
            if isWeak { try writer.write(0x2F57 as UInt16, as: Byte2.self, .littleEndian) }
            try writer.write(0x22 as UInt8)
            try writer.write(opaque)
            try writer.write(0x22 as UInt8)
        } catch {
            throw .outputTooSmall
        }
    }
}

/// `If-Match` or `If-None-Match` (RFC 9110 §13.1.1–2): `*`, or a list of entity tags.
@frozen
public struct HTTPEntityTagList: ~Escapable {
    @usableFromInline let bytes: RawSpan
    @usableFromInline var position = 0
    /// Whether the field is `*` (any current representation).
    public let isAny: Bool

    /// The entity tags of `value`.
    @inlinable
    @_lifetime(copy value)
    public init(_ value: RawSpan) {
        let value = FieldGrammar.trimmed(value)
        bytes = value
        isAny = value.byteCount == 1 && FieldGrammar.byte(value, 0) == 0x2A
    }

    /// The next entity tag, or `nil` at the end (or for `*`).
    ///
    /// - Throws: ``HTTPFieldValueError/invalidEntityTag``.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPFieldValueError) -> HTTPEntityTag? {
        guard !isAny else { return nil }
        let count = bytes.byteCount
        while position < count, case let byte = FieldGrammar.byte(bytes, position), byte == 0x2C || FieldGrammar.isWhitespace(byte) {
            position &+= 1
        }
        guard position < count else { return nil }
        guard let (isWeak, start, end) = HTTPEntityTag.scan(bytes, from: position) else { throw .invalidEntityTag }
        // Then whitespace, and a comma or the end.
        var after = FieldGrammar.whitespaceEnd(bytes, from: end)
        guard after == count || FieldGrammar.byte(bytes, after) == 0x2C else { throw .invalidEntityTag }
        if after < count { after &+= 1 }
        position = after
        return HTTPEntityTag(opaque: bytes.extracting(start..<end &- 1), isWeak: isWeak)
    }

    /// Whether the list matches `tag`: `*` matches any existing representation (`tag` not `nil`); otherwise one of the
    /// tags matches by strong (`If-Match`) or weak (`If-None-Match`) comparison.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidEntityTag``.
    @inlinable
    public static func matches(_ value: RawSpan, _ tag: borrowing HTTPEntityTag?, weak: Bool) throws(HTTPFieldValueError) -> Bool {
        var list = HTTPEntityTagList(value)
        switch tag {
        case .none: return false
        case let .some(current):
            if list.isAny { return true }
            while let candidate = try list.next() {
                if weak ? candidate.weakMatches(current) : candidate.strongMatches(current) { return true }
            }
            return false
        }
    }
}

/// `If-Range` (RFC 9110 §13.1.5): an entity tag or a date that must match the current representation for a `Range` to
/// apply.
@frozen
public enum HTTPIfRange: ~Escapable {
    /// An entity tag.
    case entityTag(HTTPEntityTag)
    /// A date.
    case date(HTTPDate)

    /// Parses an `If-Range` value: an entity tag if it starts with `"` or `W/`, otherwise an HTTP-date.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidEntityTag`` or ``HTTPFieldValueError/invalidDate``.
    @inlinable
    @_lifetime(copy value)
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        let value = FieldGrammar.trimmed(value)
        if value.byteCount > 0, FieldGrammar.byte(value, 0) == 0x22 || FieldGrammar.byte(value, 0) == 0x57 && value.byteCount > 1 && FieldGrammar.byte(value, 1) == 0x2F {
            self = try .entityTag(HTTPEntityTag(parsing: value))
        } else {
            self = try .date(HTTPDate(parsing: value))
        }
    }

    /// Whether the `Range` applies: the entity tag matches `entityTag` by strong comparison (a weak one never does), or
    /// the date is exactly `lastModified`.
    @inlinable
    public func matches(entityTag: borrowing HTTPEntityTag?, lastModified: HTTPDate?) -> Bool {
        switch self {
        case let .entityTag(tag):
            switch entityTag {
            case let .some(current): tag.strongMatches(current)
            case .none: false
            }
        case let .date(date):
            date == lastModified
        }
    }
}

/// The outcome of evaluating a request's preconditions (RFC 9110 §13.2.2).
@frozen
public enum HTTPPreconditionResult: Sendable, Hashable {
    /// Perform the method (and, for `Range`, evaluate `If-Range`).
    case proceed
    /// 304 (Not Modified): a GET or HEAD whose cached copy is current.
    case notModified
    /// 412 (Precondition Failed).
    case preconditionFailed
}

/// A request's conditional fields, evaluated in RFC 9110 §13.2.2's order against the selected representation.
@frozen
public struct HTTPPreconditions: ~Escapable {
    /// `If-Match`'s value, if present.
    public var ifMatch: RawSpan?
    /// `If-Unmodified-Since`'s value, if present.
    public var ifUnmodifiedSince: RawSpan?
    /// `If-None-Match`'s value, if present.
    public var ifNoneMatch: RawSpan?
    /// `If-Modified-Since`'s value, if present.
    public var ifModifiedSince: RawSpan?

    /// The conditional fields a request has.
    @inlinable
    @_lifetime(copy ifMatch, copy ifUnmodifiedSince, copy ifNoneMatch, copy ifModifiedSince)
    public init(ifMatch: RawSpan? = nil, ifUnmodifiedSince: RawSpan? = nil, ifNoneMatch: RawSpan? = nil, ifModifiedSince: RawSpan? = nil) {
        self.ifMatch = ifMatch
        self.ifUnmodifiedSince = ifUnmodifiedSince
        self.ifNoneMatch = ifNoneMatch
        self.ifModifiedSince = ifModifiedSince
    }

    /// Evaluates the preconditions for `method` against the representation's entity tag and last modification (`nil`
    /// where the representation has none). `exists`, whether there's a current representation, is by default whether it
    /// has an entity tag or a date.
    ///
    /// An `If-Match` or `If-None-Match` that doesn't parse fails its condition (`If-Match`: 412; `If-None-Match`: the
    /// method proceeds); a date that doesn't parse is ignored, as RFC 9110 §13.1.3–4 require.
    @inlinable
    public func evaluate(method: HTTPMethod, entityTag: borrowing HTTPEntityTag?, lastModified: HTTPDate?, exists: Bool? = nil) -> HTTPPreconditionResult {
        let isGetOrHead = method == .get || method == .head
        // Without the caller saying, a representation with an entity tag or a date exists.
        let exists = exists ?? (entityTag != nil || lastModified != nil)
        // 1–2: If-Match, else If-Unmodified-Since.
        if let ifMatch {
            var matched = false
            var list = HTTPEntityTagList(ifMatch)
            if list.isAny { matched = exists } else {
                // The whole list is read: a malformed one fails wherever its bad element is.
                switch entityTag {
                case let .some(current):
                    do throws(HTTPFieldValueError) {
                        while let candidate = try list.next() {
                            if candidate.strongMatches(current) { matched = true }
                        }
                    } catch {
                        matched = false
                    }
                case .none: break
                }
            }
            if !matched { return .preconditionFailed }
        } else if let ifUnmodifiedSince, let date = try? HTTPDate(parsing: ifUnmodifiedSince), let lastModified, lastModified > date {
            return .preconditionFailed
        }
        // 3–4: If-None-Match, else If-Modified-Since (GET and HEAD only).
        if let ifNoneMatch {
            var matched = false
            var list = HTTPEntityTagList(ifNoneMatch)
            if list.isAny { matched = exists } else {
                switch entityTag {
                case let .some(current):
                    do throws(HTTPFieldValueError) {
                        while let candidate = try list.next() {
                            if candidate.weakMatches(current) { matched = true }
                        }
                    } catch {
                        matched = false
                    }
                case .none: break
                }
            }
            if matched { return isGetOrHead ? .notModified : .preconditionFailed }
        } else if isGetOrHead, let ifModifiedSince, let date = try? HTTPDate(parsing: ifModifiedSince), let lastModified, lastModified <= date {
            return .notModified
        }
        return .proceed
    }
}
