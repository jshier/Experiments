public import Bytes

/// A request target's form (RFC 9112 §3.2).
@frozen
public enum HTTPRequestTargetForm: Sendable, Hashable {
    /// `/path?query`: most requests.
    case origin
    /// `scheme://authority/path?query`: requests to a proxy.
    case absolute
    /// `host:port`: CONNECT.
    case authority
    /// `*`: OPTIONS for the server as a whole.
    case asterisk
}

/// Why a request target was rejected (a server answers 400).
@frozen
public enum HTTPRequestTargetError: Error, Sendable, Hashable {
    /// A byte that can't be in a URI (RFC 3986 §2): space, `"`, `#`, `<`, `>`, `\`, `^`, `` ` ``, `{`, `|`, `}`, a control,
    /// or a byte above 0x7E.
    case invalidCharacter
    /// A `%` not followed by two hexadecimal digits.
    case invalidPercentEncoding
    /// The target's form doesn't match the method, or isn't one of the four (RFC 9112 §3.2).
    case invalidForm
}

/// Request-target validation (RFC 9112 §3.2, RFC 3986): one 16-byte-at-a-time pass for the characters, a scan for `%`
/// escapes, and the form's rules: origin-form for most methods, authority-form only (and always) for CONNECT, `*` only
/// for OPTIONS, absolute-form with a valid scheme.
public enum HTTPRequestTarget {
    /// The bytes RFC 3986 allows in a request target: unreserved, sub-delims, `:`, `@`, `/`, `?`, `%`, and `[`/`]` (for an
    /// IP literal). Two one-register table lookups on the nibbles, as ``HTTPCharacters/nonToken(_:)`` does; a lane
    /// matches when its byte is *not* allowed.
    @inlinable @inline(__always)
    public static func nonURIByte(_ lanes: ByteLanes) -> ByteMatches {
        let columns = SIMD16<UInt8>(0x2E, 0x3F, 0x3E, 0x3E, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x1F, 0x15, 0x1F, 0x35, 0x1F)
        let rows = SIMD16<UInt8>(0, 0, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0, 0, 0, 0, 0, 0, 0, 0)
        let column = ByteLanes(lanes.vector & SIMD16(repeating: 0x0F)).lookup(in: columns)
        let row = ByteLanes(lanes.vector &>> SIMD16(repeating: 4)).lookup(in: rows)
        return ByteMatches((column & row) .== SIMD16(repeating: 0))
    }

    /// Checks `target` for `method` (when known; otherwise its form decides), returning its form.
    @inlinable
    public static func validate(_ target: RawSpan, method: HTTPMethod?) throws(HTTPRequestTargetError) -> HTTPRequestTargetForm {
        let count = target.byteCount
        guard count > 0 else { throw .invalidForm }
        guard !target.containsByte(where: nonURIByte) else { throw .invalidCharacter }
        try checkPercentEncoding(target)
        let first = target.load(fromByteOffset: 0, as: UInt8.self)
        if method == .connect { return try authorityForm(target) }
        if first == 0x2F {
            // origin-form: an absolute path and query; brackets only belong in an authority.
            guard !target.containsByte(where: { $0.matching(0x5B) | $0.matching(0x5D) }) else { throw .invalidCharacter }
            return .origin
        }
        if count == 1, first == 0x2A {
            guard method == nil || method == .options else { throw .invalidForm }
            return .asterisk
        }
        return try absoluteForm(target)
    }

    /// Every `%` followed by two hexadecimal digits.
    @inlinable
    static func checkPercentEncoding(_ target: RawSpan) throws(HTTPRequestTargetError) {
        var position = 0
        let count = target.byteCount
        while position < count, let offset = target.extracting(droppingFirst: position).firstByteOffset(where: { $0.matching(0x25) }) {
            let percent = position &+ offset
            guard percent &+ 2 < count, target.load(fromByteOffset: percent &+ 1, as: UInt8.self).isASCIIHexDigit,
                  target.load(fromByteOffset: percent &+ 2, as: UInt8.self).isASCIIHexDigit else { throw .invalidPercentEncoding }
            position = percent &+ 3
        }
    }

    /// `host ":" port` (RFC 9112 §3.2.3): a registered name or IPv4 address, or an IP literal in brackets, then a port
    /// of digits; no path, query, or user information.
    @usableFromInline
    static func authorityForm(_ target: RawSpan) throws(HTTPRequestTargetError) -> HTTPRequestTargetForm {
        let count = target.byteCount
        // The port: digits after the last colon.
        var colon = count &- 1
        while colon >= 0, target.load(fromByteOffset: colon, as: UInt8.self) != 0x3A {
            colon &-= 1
        }
        guard colon > 0, colon < count &- 1 else { throw .invalidForm }
        for offset in (colon &+ 1)..<count where !target.load(fromByteOffset: offset, as: UInt8.self).isASCIIDigit {
            throw .invalidForm
        }
        let host = target.extracting(0..<colon)
        if host.load(fromByteOffset: 0, as: UInt8.self) == 0x5B {
            guard host.load(fromByteOffset: colon &- 1, as: UInt8.self) == 0x5D, colon > 2 else { throw .invalidForm }
            // Inside the brackets: hexadecimal digits, colons, and dots (IPv6), or IPvFuture's `v` and unreserved.
            let inside = host.extracting(1..<colon &- 1)
            guard !inside.containsByte(where: { $0.matching(0x5B) | $0.matching(0x5D) | $0.matching(0x2F) | $0.matching(0x3F) | $0.matching(0x40) | $0.matching(0x25) }) else {
                throw .invalidForm
            }
        } else {
            // reg-name: unreserved, %-escapes, sub-delims; no `/`, `?`, `@`, `[`, `]`, or another `:`.
            guard !host.containsByte(where: { $0.matching(0x2F) | $0.matching(0x3F) | $0.matching(0x40) | $0.matching(0x5B) | $0.matching(0x5D) | $0.matching(0x3A) }) else {
                throw .invalidForm
            }
        }
        return .authority
    }

    /// `scheme ":" hier-part [ "?" query ]` (RFC 3986 §3, §4.3): a scheme of a letter, then letters, digits, `+`, `-`,
    /// `.`; brackets only in the authority.
    @usableFromInline
    static func absoluteForm(_ target: RawSpan) throws(HTTPRequestTargetError) -> HTTPRequestTargetForm {
        let count = target.byteCount
        guard target.load(fromByteOffset: 0, as: UInt8.self).isASCIILetter else { throw .invalidForm }
        var position = 1
        while position < count {
            let byte = target.load(fromByteOffset: position, as: UInt8.self)
            if byte == 0x3A { break }
            guard byte.isASCIILetter || byte.isASCIIDigit || byte == 0x2B || byte == 0x2D || byte == 0x2E else { throw .invalidForm }
            position &+= 1
        }
        guard position < count else { throw .invalidForm }
        // Brackets after the authority (from the first `/`, `?` past `scheme://host`) aren't allowed.
        var start = position &+ 1
        if start &+ 1 < count, target.load(fromByteOffset: start, as: UInt8.self) == 0x2F,
           target.load(fromByteOffset: start &+ 1, as: UInt8.self) == 0x2F {
            start &+= 2
            while start < count, case let byte = target.load(fromByteOffset: start, as: UInt8.self), byte != 0x2F && byte != 0x3F {
                start &+= 1
            }
        }
        guard !target.extracting(droppingFirst: start).containsByte(where: { $0.matching(0x5B) | $0.matching(0x5D) }) else {
            throw .invalidCharacter
        }
        return .absolute
    }
}
