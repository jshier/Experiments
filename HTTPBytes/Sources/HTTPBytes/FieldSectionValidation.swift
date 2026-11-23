public import Bytes

/// Why an HTTP/2 or HTTP/3 field section is malformed (RFC 9113 §8.1.1, §8.2, §8.3; RFC 9114 §4.1.2, §4.2, §4.3): a
/// stream error (PROTOCOL_ERROR in HTTP/2, H3_MESSAGE_ERROR in HTTP/3). Payload-free.
@frozen
public enum HTTPFieldSectionError: Error, Sendable, Hashable {
    /// A name that's empty, or has a byte in 0x00–0x20, an uppercase letter, a byte in 0x7F–0xFF, or a colon past
    /// the first byte.
    case invalidName
    /// A value with NUL, LF, or CR, or that starts or ends with a space or tab.
    case invalidValue
    /// `connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`, or `upgrade`.
    case connectionSpecificField
    /// `te` with a value other than `trailers`.
    case invalidTE
    /// A pseudo-header field after a regular field.
    case pseudoHeaderAfterRegularField
    /// A pseudo-header field that isn't defined, or isn't allowed in this section (`:status` in a request, any in
    /// trailers, `:protocol` without extended CONNECT).
    case invalidPseudoHeader
    /// A pseudo-header field that appears twice.
    case duplicatePseudoHeader
    /// A required pseudo-header field is missing, or one CONNECT forbids is present (RFC 9113 §8.3.1, §8.5; RFC 9114
    /// §4.3.1, §4.4; RFC 8441 §4, RFC 9220 §3).
    case missingPseudoHeader
    /// A pseudo-header field's value is wrong: an empty `:path` for `http` or `https`, a `:status` that isn't three
    /// digits, a `:protocol` request whose method isn't CONNECT.
    case invalidPseudoHeaderValue
}

/// Checks a field section as HTTP/2 (RFC 9113 §8.2–8.3) and HTTP/3 (RFC 9114 §4.2–4.3, the same rules) say, one field at
/// a time as the decoder yields them: for servers (requests and their trailers) and clients (responses and theirs).
/// HTTP2 calls it `HTTP2FieldValidator`, HTTP3 `HTTP3FieldValidator`.
///
/// ```swift
/// var validator = HTTP2FieldValidator(.request)
/// var malformed: HTTPFieldSectionError?
/// while let field = try decoder.next(in: block) {
///     // A malformed section still has its block decoded to the end: the decoder's table must stay in step with the
///     // encoder's, and a block left unfinished makes the decoder's next call throw.
///     if malformed != nil { continue }
///     do throws(HTTPFieldSectionError) { try validator.check(field) } catch { malformed = error; continue }
///     …
/// }
/// if let malformed { … }                    // reset the stream (PROTOCOL_ERROR, H3_MESSAGE_ERROR)
/// let request = try validator.finish()      // the pseudo-header fields seen, checked as a set
/// ```
///
/// Per field: the name's characters (skipped for a name with an ``HTTPFieldName``, which is a valid lowercase name),
/// the value's (one vector scan), connection-specific fields and `te`, and the pseudo-header fields' order, set, and
/// duplicates. At the end, the required pseudo-header fields for the section (CONNECT, and extended CONNECT: RFC 8441
/// §4, RFC 9220 §3). It allocates nothing.
@frozen
public struct HTTPFieldSectionValidator: Sendable {
    /// The kind of field section.
    @frozen
    public enum Section: Sendable, Hashable {
        /// A request's header section (HEADERS, or a push promise's request).
        case request
        /// A response's header section (including 1xx responses).
        case response
        /// Trailers: no pseudo-header fields.
        case trailers
    }

    /// What a request or response's pseudo-header fields said (the values are checked; read them from the fields).
    @frozen
    public struct PseudoHeaders: Sendable, Hashable {
        /// Bits for `:authority`, `:method`, `:path`, `:scheme`, `:status`, `:protocol` (bit = ``HTTPFieldName/index``).
        public var present: UInt8
        /// The method was CONNECT.
        public var isConnect: Bool
        /// The `:status`, for a response (else 0).
        public var status: Int

        @inlinable
        public init(present: UInt8 = 0, isConnect: Bool = false, status: Int = 0) {
            self.present = present
            self.isConnect = isConnect
            self.status = status
        }

        /// Whether the section had `name` (a pseudo-header field).
        @inlinable
        public func contains(_ name: HTTPFieldName) -> Bool { name.isPseudoHeader && present & 1 &<< name.index != 0 }
    }

    /// The section being checked.
    public let section: Section
    /// Whether this endpoint sent SETTINGS_ENABLE_CONNECT_PROTOCOL = 1 (RFC 8441, RFC 9220), allowing `:protocol` in
    /// requests.
    public let allowsExtendedConnect: Bool
    @usableFromInline var pseudoHeaders = PseudoHeaders()
    @usableFromInline var sawRegularField = false
    /// Whether `:path` was empty (allowed only for schemes other than http and https, and checked at the end).
    @usableFromInline var emptyPath = false
    /// Whether `:scheme` was `http` or `https`.
    @usableFromInline var httpScheme = false

    @inlinable
    public init(_ section: Section, allowsExtendedConnect: Bool = false) {
        self.section = section
        self.allowsExtendedConnect = allowsExtendedConnect
    }

    /// Checks a field.
    @inlinable
    public mutating func check(_ field: HTTPFieldView) throws(HTTPFieldSectionError) {
        try check(name: field.name, value: field.value, knownName: field.knownName)
    }

    /// Checks a field: its name (when unknown), value, and place.
    @inlinable
    public mutating func check(name: RawSpan, value: RawSpan, knownName: HTTPFieldName?) throws(HTTPFieldSectionError) {
        try check(name: name, value: value, knownName: knownName, charactersChecked: false)
    }

    /// Checks a field, its characters unless they're known to be valid (a decoder's verdict, made once per literal).
    @inlinable @inline(__always)
    package mutating func check(name: RawSpan, value: RawSpan, knownName: HTTPFieldName?, charactersChecked: Bool) throws(HTTPFieldSectionError) {
        if !charactersChecked { try Self.checkValue(value) }
        if let knownName {
            if knownName.isPseudoHeader {
                try pseudoHeader(knownName, value)
                return
            }
            sawRegularField = true
            switch knownName {
            case .connection, .keepAlive, .proxyConnection, .transferEncoding, .upgrade:
                throw .connectionSpecificField
            case .te:
                guard HTTPToken.equalsIgnoringCase(value, "trailers") else { throw .invalidTE }
            default:
                break
            }
            return
        }
        // An unknown name: a pseudo-header field this module doesn't define, or a regular name to check.
        guard name.byteCount > 0 else { throw .invalidName }
        if name.load(fromByteOffset: 0, as: UInt8.self) == 0x3A { throw .invalidPseudoHeader }
        if !charactersChecked { try Self.checkName(name) }
        sawRegularField = true
    }

    /// Checks the section as a whole, after its last field, and returns its pseudo-header fields.
    @inlinable
    public func finish() throws(HTTPFieldSectionError) -> PseudoHeaders {
        let present = pseudoHeaders.present
        func has(_ name: HTTPFieldName) -> Bool { present & 1 &<< name.index != 0 }
        switch section {
        case .trailers:
            break
        case .response:
            guard has(.pseudoStatus) else { throw .missingPseudoHeader }
        case .request:
            guard has(.pseudoMethod) else { throw .missingPseudoHeader }
            if has(.pseudoProtocol) {
                // Extended CONNECT (RFC 8441 §4, RFC 9220 §3): CONNECT with :scheme, :path, and :authority.
                guard pseudoHeaders.isConnect else { throw .invalidPseudoHeaderValue }
                guard has(.pseudoScheme), has(.pseudoPath), has(.pseudoAuthority) else { throw .missingPseudoHeader }
            } else if pseudoHeaders.isConnect {
                // CONNECT (RFC 9113 §8.5, RFC 9114 §4.4): :authority only, no :scheme or :path.
                guard has(.pseudoAuthority), !has(.pseudoScheme), !has(.pseudoPath) else { throw .missingPseudoHeader }
            } else {
                guard has(.pseudoScheme), has(.pseudoPath) else { throw .missingPseudoHeader }
            }
            if emptyPath, httpScheme { throw .invalidPseudoHeaderValue }
        }
        return pseudoHeaders
    }

    @inlinable
    mutating func pseudoHeader(_ name: HTTPFieldName, _ value: RawSpan) throws(HTTPFieldSectionError) {
        guard !sawRegularField else { throw .pseudoHeaderAfterRegularField }
        let bit: UInt8 = 1 &<< name.index
        guard pseudoHeaders.present & bit == 0 else { throw .duplicatePseudoHeader }
        pseudoHeaders.present |= bit
        switch section {
        case .trailers:
            throw .invalidPseudoHeader
        case .response:
            guard name == .pseudoStatus else { throw .invalidPseudoHeader }
            guard value.byteCount == 3 else { throw .invalidPseudoHeaderValue }
            let d0 = Int(value.load(fromByteOffset: 0, as: UInt8.self)) &- 0x30
            let d1 = Int(value.load(fromByteOffset: 1, as: UInt8.self)) &- 0x30
            let d2 = Int(value.load(fromByteOffset: 2, as: UInt8.self)) &- 0x30
            guard UInt(bitPattern: d0) < 10, UInt(bitPattern: d1) < 10, UInt(bitPattern: d2) < 10 else { throw .invalidPseudoHeaderValue }
            pseudoHeaders.status = d0 &* 100 &+ d1 &* 10 &+ d2
        case .request:
            switch name {
            case .pseudoStatus:
                throw .invalidPseudoHeader
            case .pseudoProtocol:
                guard allowsExtendedConnect else { throw .invalidPseudoHeader }
            case .pseudoMethod:
                guard value.byteCount > 0 else { throw .invalidPseudoHeaderValue }
                pseudoHeaders.isConnect = value.byteCount == 7 && value.bytesEqual(immortalSpan("CONNECT"))
            case .pseudoPath:
                emptyPath = value.byteCount == 0
            case .pseudoScheme:
                httpScheme = HTTPToken.equalsIgnoringCase(value, "https") || HTTPToken.equalsIgnoringCase(value, "http")
            default:
                break
            }
        }
    }

    /// A value's characters: no NUL, LF, or CR; no space or tab first or last.
    @inlinable
    static func checkValue(_ value: RawSpan) throws(HTTPFieldSectionError) {
        guard isValidValue(value) else { throw .invalidValue }
    }

    /// Whether a value's characters are valid (RFC 9113 §8.2.1, RFC 9114 §4.2): no NUL, LF, or CR; no space or tab
    /// first or last.
    @inlinable
    public static func isValidValue(_ value: RawSpan) -> Bool {
        let count = value.byteCount
        guard count > 0 else { return true }
        let first = value.load(fromByteOffset: 0, as: UInt8.self), last = value.load(fromByteOffset: count &- 1, as: UInt8.self)
        return first != 0x20 && first != 0x09 && last != 0x20 && last != 0x09 && !value.containsByte(where: invalidValueByte)
    }

    /// Whether a regular field's name is valid: not empty, no byte in 0x00–0x20, 0x41–0x5A, 0x7F–0xFF, and no colon.
    @inlinable
    public static func isValidRegularName(_ name: RawSpan) -> Bool {
        name.byteCount > 0 && !name.containsByte(where: invalidNameByte)
    }

    /// A regular field's name: no byte in 0x00–0x20, 0x41–0x5A, 0x7F–0xFF, and no colon.
    @inlinable
    static func checkName(_ name: RawSpan) throws(HTTPFieldSectionError) {
        guard !name.containsByte(where: invalidNameByte) else { throw .invalidName }
    }

    /// NUL, LF, CR.
    @inlinable @inline(__always)
    static func invalidValueByte(_ lanes: ByteLanes) -> ByteMatches {
        lanes.matching(0) | lanes.matching(0x0A) | lanes.matching(0x0D)
    }

    /// 0x00–0x20, 0x41–0x5A, 0x7F–0xFF, `:`.
    @inlinable @inline(__always)
    static func invalidNameByte(_ lanes: ByteLanes) -> ByteMatches {
        let v = lanes.vector
        let upper = v &- SIMD16(repeating: 0x41) .< SIMD16(repeating: 26)
        return HTTPCharacters.matches((v .<= SIMD16(repeating: 0x20)) .| (v .>= SIMD16(repeating: 0x7F)) .| upper
                                          .| (v .== SIMD16(repeating: 0x3A)))
    }
}
