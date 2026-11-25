public import Bytes

// Distinguished Encoding Rules (X.690) for X.509: tag-length-value elements read with an `AlignedBytesReader`,
// object identifiers, and times. Strict: definite lengths in their shortest form, low tag numbers only, every
// element inside its parent. Elements are offsets into the bytes the reader reads, so parsing allocates nothing.

/// A DER identifier octet: class, constructed bit, and tag number (only the low-tag-number form, numbers 0–30, which
/// is all X.509 uses).
public struct ASN1Tag: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// The identifier octet.
    public var rawValue: UInt8

    /// A tag from its identifier octet.
    ///
    /// - Parameter rawValue: The octet.
    @inlinable
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `BOOLEAN`: one byte, `00` or `FF` in DER.
    @inlinable public static var boolean: Self { Self(rawValue: 0x01) }
    /// `INTEGER`: two's complement, big-endian, shortest form.
    @inlinable public static var integer: Self { Self(rawValue: 0x02) }
    /// `BIT STRING`: an unused-bits count, then the bits.
    @inlinable public static var bitString: Self { Self(rawValue: 0x03) }
    /// `OCTET STRING`.
    @inlinable public static var octetString: Self { Self(rawValue: 0x04) }
    /// `NULL`: no contents.
    @inlinable public static var null: Self { Self(rawValue: 0x05) }
    /// `OBJECT IDENTIFIER` (``ASN1ObjectIdentifier``).
    @inlinable public static var objectIdentifier: Self { Self(rawValue: 0x06) }
    /// `UTF8String`.
    @inlinable public static var utf8String: Self { Self(rawValue: 0x0C) }
    /// `PrintableString`: a subset of ASCII.
    @inlinable public static var printableString: Self { Self(rawValue: 0x13) }
    /// `TeletexString` (T61String), read as Latin-1.
    @inlinable public static var teletexString: Self { Self(rawValue: 0x14) }
    /// `IA5String`: ASCII.
    @inlinable public static var ia5String: Self { Self(rawValue: 0x16) }
    /// `UTCTime`: `YYMMDDHHMMSSZ` (``X509Time``).
    @inlinable public static var utcTime: Self { Self(rawValue: 0x17) }
    /// `GeneralizedTime`: `YYYYMMDDHHMMSSZ` (``X509Time``).
    @inlinable public static var generalizedTime: Self { Self(rawValue: 0x18) }
    /// `UniversalString`: UTF-32, big-endian.
    @inlinable public static var universalString: Self { Self(rawValue: 0x1C) }
    /// `BMPString`: UTF-16, big-endian, the basic multilingual plane.
    @inlinable public static var bmpString: Self { Self(rawValue: 0x1E) }
    /// `SEQUENCE` and `SEQUENCE OF` (always constructed).
    @inlinable public static var sequence: Self { Self(rawValue: 0x30) }
    /// `SET` and `SET OF` (always constructed).
    @inlinable public static var set: Self { Self(rawValue: 0x31) }

    /// A context-specific tag, `[number]`, as X.509's optional fields use.
    ///
    /// - Parameters:
    ///   - number: The tag number, 0 through 30.
    ///   - constructed: Whether the element contains elements: true for `EXPLICIT` tags.
    @inlinable
    public static func contextSpecific(_ number: UInt8, constructed: Bool) -> Self {
        Self(rawValue: 0x80 | (constructed ? 0x20 : 0) | (number & 0x1F))
    }

    /// Whether the element's contents are elements themselves.
    @inlinable public var isConstructed: Bool { rawValue & 0x20 != 0 }

    public var description: String {
        let hex = String(rawValue, radix: 16, uppercase: true)
        return "0x" + (hex.count == 1 ? "0" + hex : hex)
    }
}

/// One DER element: its tag, and where it and its contents are, as byte offsets in the span its reader reads.
public struct ASN1Element: Hashable, Sendable {
    /// The element's tag.
    public var tag: ASN1Tag
    /// The whole element: identifier, length, and contents.
    public var range: Range<Int>
    /// The contents only.
    public var contents: Range<Int>

    /// An element at the given offsets.
    ///
    /// - Parameters:
    ///   - tag: The tag.
    ///   - range: The whole element.
    ///   - contents: The contents, a suffix of `range`.
    @inlinable
    public init(tag: ASN1Tag, range: Range<Int>, contents: Range<Int>) {
        self.tag = tag
        self.range = range
        self.contents = contents
    }
}

public extension GenericBytesReader where Mode == ByteAligned {
    /// Reads one DER element's identifier and length and skips its contents, returning where they are.
    ///
    /// ```swift
    /// var reader = AlignedBytesReader(der)
    /// let certificate = try reader.readASN1Element(.sequence)
    /// var fields = try AlignedBytesReader(der.extracting(..<certificate.contents.upperBound),
    ///                                     atByteOffset: certificate.contents.lowerBound)
    /// ```
    ///
    /// The span a reader reads bounds the element: to read the children of a constructed element, read a span that
    /// ends where the element does, from its contents' start, so offsets stay those of the whole input.
    ///
    /// - Returns: The element's tag and offsets in ``span``.
    /// - Throws: ``BytesError/insufficientData`` if the element runs past the end; ``BytesError/invalidValue`` for
    ///   anything DER forbids: a high tag number, an indefinite length, a length not in its shortest form, or one of
    ///   more than four bytes. Nothing is consumed then.
    @inlinable
    @_lifetime(self: copy self)
    mutating func readASN1Element() throws(BytesError) -> ASN1Element {
        let element = try ASN1Element.parseHeader(span, at: byteOffset)
        try seek(toByteOffset: element.range.upperBound)
        return element
    }

    /// Reads one DER element, which must have tag `tag`.
    ///
    /// - Parameter tag: The expected tag.
    /// - Returns: The element.
    /// - Throws: ``BytesError/mismatch`` if the next element has another tag (nothing is consumed), or what
    ///   ``readASN1Element()`` throws.
    @inlinable
    @_lifetime(self: copy self)
    mutating func readASN1Element(_ tag: ASN1Tag) throws(BytesError) -> ASN1Element {
        let element = try ASN1Element.parseHeader(span, at: byteOffset)
        guard element.tag == tag else { throw .mismatch }
        try seek(toByteOffset: element.range.upperBound)
        return element
    }

    /// The next element's tag, or nil at the end.
    @inlinable
    var nextASN1Tag: ASN1Tag? {
        isAtEnd ? nil : ASN1Tag(rawValue: span.byteOffsetLoad(byteOffset))
    }
}

extension RawSpan {
    /// The byte at `offset`, bounds-checked.
    @inlinable @inline(__always)
    func byteOffsetLoad(_ offset: Int) -> UInt8 {
        // One unsigned compare; the load's own check folds into it (the same machine code as an unchecked load after
        // it, where `Span<UInt8>(viewing:)[offset]` cost X.509 parsing 0.4% more instructions).
        precondition(UInt(bitPattern: offset) < UInt(bitPattern: byteCount), "Offset out of range")
        return load(fromByteOffset: offset, as: UInt8.self)
    }
}

extension ASN1Element {
    /// The element whose identifier is at `start` in `bytes`; it must end within `bytes`.
    @inlinable
    static func parseHeader(_ bytes: RawSpan, at start: Int) throws(BytesError) -> ASN1Element {
        let count = bytes.byteCount
        guard start >= 0, count &- start >= 2 else { throw .insufficientData }
        let identifier = bytes.byteOffsetLoad(start)
        // The high-tag-number form (tag numbers above 30) isn't used by X.509.
        guard identifier & 0x1F != 0x1F else { throw .invalidValue }
        let first = bytes.byteOffsetLoad(start &+ 1)
        var length: Int
        var contentStart = start &+ 2
        if first < 0x80 {
            length = Int(first)
        } else {
            // 0x80 is the indefinite form, BER only; more than four length bytes would be 4 GiB.
            let lengthByteCount = Int(first & 0x7F)
            guard lengthByteCount >= 1, lengthByteCount <= 4 else { throw .invalidValue }
            guard count &- contentStart >= lengthByteCount else { throw .insufficientData }
            length = 0
            for index in 0..<lengthByteCount {
                length = length &<< 8 | Int(bytes.byteOffsetLoad(contentStart &+ index))
            }
            contentStart &+= lengthByteCount
            // Shortest form: no leading zero byte, and the long form only from 128.
            guard length >= 0x80, length >> (8 &* (lengthByteCount &- 1)) != 0 else { throw .invalidValue }
        }
        guard length <= count &- contentStart else { throw .insufficientData }
        let end = contentStart &+ length
        return ASN1Element(tag: ASN1Tag(rawValue: identifier), range: start..<end, contents: contentStart..<end)
    }
}

// MARK: - Object identifiers

/// An ASN.1 object identifier, held as its DER contents (up to 63 bytes, inline): `1.2.840.10045.4.3.2` is
/// `2A 86 48 CE 3D 04 03 02`.
///
/// ```swift
/// if certificate.signatureAlgorithm == .ecdsaWithSHA256 { … }
/// let oid = try ASN1ObjectIdentifier("1.2.840.113635.100.6.2.6")
/// print(oid)                                   // "1.2.840.113635.100.6.2.6"
/// ```
public struct ASN1ObjectIdentifier: Hashable, Sendable, CustomStringConvertible {
    /// The longest contents held: 63 bytes, nine 7-bit groups per 64-bit arc for seven arcs.
    public static var maximumByteCount: Int { 63 }

    @usableFromInline var storage: InlineArray<63, UInt8>
    @usableFromInline var count: UInt8

    /// An identifier from its DER contents (no tag or length).
    ///
    /// - Parameter contents: The base-128 arcs.
    /// - Throws: ``BytesError/invalidValue`` if `contents` is empty, longer than ``maximumByteCount``, ends inside an
    ///   arc, or has an arc with a leading `0x80` byte (not in its shortest form).
    @inlinable
    public init(contents: RawSpan) throws(BytesError) {
        try Self.validate(contents)
        storage = InlineArray(repeating: 0)
        count = UInt8(contents.byteCount)
        for index in 0..<contents.byteCount {
            storage[index] = contents.byteOffsetLoad(index)
        }
    }

    /// An identifier from contents that were checked when parsed (a certificate's): invalid ones are a bug here.
    init(validated contents: RawSpan) {
        do throws(BytesError) {
            try self.init(contents: contents)
        } catch {
            preconditionFailure("An object identifier checked when parsed is invalid: \(error)")
        }
    }

    /// Checks DER's rules for an identifier's contents without copying them.
    @inlinable
    static func validate(_ contents: RawSpan) throws(BytesError) {
        let count = contents.byteCount
        guard count >= 1, count <= maximumByteCount else { throw .invalidValue }
        var arcStart = true
        for index in 0..<count {
            let byte = contents.byteOffsetLoad(index)
            if arcStart && byte == 0x80 { throw .invalidValue }
            arcStart = byte & 0x80 == 0
        }
        guard arcStart else { throw .invalidValue } // The last byte continued an arc.
    }

    /// An identifier from known-good contents (the constants below).
    @inlinable @inline(__always)
    init<let n: Int>(known bytes: InlineArray<n, UInt8>) {
        storage = InlineArray(repeating: 0)
        count = UInt8(n)
        for index in 0..<n {
            storage[index] = bytes[index]
        }
    }

    /// An identifier from its dotted form, such as `"2.5.29.19"`.
    ///
    /// - Parameter dotted: Two or more decimal arcs separated by dots; the first 0, 1, or 2, and the second below 40
    ///   unless the first is 2.
    /// - Throws: ``BytesError/invalidValue`` if `dotted` isn't such a string or encodes to more than
    ///   ``maximumByteCount`` bytes.
    public init(_ dotted: String) throws(BytesError) {
        var arcs: [UInt64] = []
        for part in dotted.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let arc = UInt64(part) else { throw .invalidValue }
            arcs.append(arc)
        }
        guard arcs.count >= 2, arcs[0] <= 2, arcs[0] == 2 || arcs[1] < 40, arcs[1] <= UInt64.max - 80 else { throw .invalidValue }
        var bytes: [UInt8] = []
        func append(_ arc: UInt64) {
            var groups: [UInt8] = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest != 0 {
                groups.append(UInt8(rest & 0x7F) | 0x80)
                rest >>= 7
            }
            bytes.append(contentsOf: groups.reversed())
        }
        append(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) {
            append(arc)
        }
        try self.init(contents: bytes.span.bytes)
    }

    /// The DER contents.
    public var contents: RawSpan {
        @_lifetime(borrow self)
        get { storage.span.bytes.extracting(0..<Int(count)) }
    }

    /// Whether `contents` are this identifier's contents.
    ///
    /// - Parameter contents: An identifier's DER contents.
    /// - Returns: Whether they're equal.
    @inlinable
    public func matches(_ contents: RawSpan) -> Bool {
        guard contents.byteCount == Int(count) else { return false }
        for index in 0..<Int(count) where storage[index] != contents.byteOffsetLoad(index) {
            return false
        }
        return true
    }

    @inlinable
    public static func ==(a: Self, b: Self) -> Bool {
        guard a.count == b.count else { return false }
        for index in 0..<Int(a.count) where a.storage[index] != b.storage[index] {
            return false
        }
        return true
    }

    @inlinable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for index in 0..<Int(count) {
            hasher.combine(storage[index])
        }
    }

    /// The dotted decimal form, such as `"1.2.840.10045.2.1"`. Arcs of more than 128 bits (only UUID-based
    /// identifiers under `2.25` come close) print as `?`.
    public var description: String {
        var parts: [String] = []
        var value: UInt128 = 0
        var overflow = false
        var first = true
        for index in 0..<Int(count) {
            let byte = storage[index]
            if value >> 121 != 0 { overflow = true }
            value = value << 7 | UInt128(byte & 0x7F)
            guard byte & 0x80 == 0 else { continue }
            if overflow {
                parts.append(first ? "2.?" : "?")
            } else if first {
                let top: UInt128 = value < 40 ? 0 : value < 80 ? 1 : 2
                parts.append("\(top).\(value - top * 40)")
            } else {
                parts.append("\(value)")
            }
            first = false
            value = 0
            overflow = false
        }
        return parts.joined(separator: ".")
    }
}

public extension ASN1ObjectIdentifier {
    // Signature algorithms (RFC 5758, RFC 8017, RFC 8410).
    /// `1.2.840.10045.4.3.2`, ecdsa-with-SHA256.
    @inlinable static var ecdsaWithSHA256: Self { Self(known: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]) }
    /// `1.2.840.10045.4.3.3`, ecdsa-with-SHA384.
    @inlinable static var ecdsaWithSHA384: Self { Self(known: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03]) }
    /// `1.2.840.10045.4.3.4`, ecdsa-with-SHA512.
    @inlinable static var ecdsaWithSHA512: Self { Self(known: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04]) }
    /// `1.2.840.113549.1.1.5`, sha1WithRSAEncryption.
    @inlinable static var sha1WithRSAEncryption: Self { Self(known: [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05]) }
    /// `1.2.840.113549.1.1.11`, sha256WithRSAEncryption.
    @inlinable static var sha256WithRSAEncryption: Self { Self(known: [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]) }
    /// `1.2.840.113549.1.1.12`, sha384WithRSAEncryption.
    @inlinable static var sha384WithRSAEncryption: Self { Self(known: [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C]) }
    /// `1.2.840.113549.1.1.13`, sha512WithRSAEncryption.
    @inlinable static var sha512WithRSAEncryption: Self { Self(known: [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D]) }
    /// `1.2.840.113549.1.1.10`, RSASSA-PSS.
    @inlinable static var rsassaPSS: Self { Self(known: [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A]) }
    /// `1.3.101.112`, Ed25519 (as a signature and a key algorithm).
    @inlinable static var ed25519: Self { Self(known: [0x2B, 0x65, 0x70]) }

    // Public key algorithms and curves (RFC 5480, RFC 8017).
    /// `1.2.840.10045.2.1`, id-ecPublicKey.
    @inlinable static var ecPublicKey: Self { Self(known: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]) }
    /// `1.2.840.113549.1.1.1`, rsaEncryption.
    @inlinable static var rsaEncryption: Self { Self(known: [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]) }
    /// `1.2.840.10045.3.1.7`, prime256v1 (P-256, secp256r1).
    @inlinable static var prime256v1: Self { Self(known: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]) }
    /// `1.3.132.0.34`, secp384r1 (P-384).
    @inlinable static var secp384r1: Self { Self(known: [0x2B, 0x81, 0x04, 0x00, 0x22]) }
    /// `1.3.132.0.35`, secp521r1 (P-521).
    @inlinable static var secp521r1: Self { Self(known: [0x2B, 0x81, 0x04, 0x00, 0x23]) }

    // Name attributes (X.520).
    /// `2.5.4.3`, commonName.
    @inlinable static var commonName: Self { Self(known: [0x55, 0x04, 0x03]) }
    /// `2.5.4.6`, countryName.
    @inlinable static var countryName: Self { Self(known: [0x55, 0x04, 0x06]) }
    /// `2.5.4.10`, organizationName.
    @inlinable static var organizationName: Self { Self(known: [0x55, 0x04, 0x0A]) }
    /// `2.5.4.11`, organizationalUnitName.
    @inlinable static var organizationalUnitName: Self { Self(known: [0x55, 0x04, 0x0B]) }

    // Certificate extensions (RFC 5280, 4.2).
    /// `2.5.29.14`, subjectKeyIdentifier.
    @inlinable static var subjectKeyIdentifier: Self { Self(known: [0x55, 0x1D, 0x0E]) }
    /// `2.5.29.15`, keyUsage.
    @inlinable static var keyUsage: Self { Self(known: [0x55, 0x1D, 0x0F]) }
    /// `2.5.29.17`, subjectAltName.
    @inlinable static var subjectAlternativeName: Self { Self(known: [0x55, 0x1D, 0x11]) }
    /// `2.5.29.19`, basicConstraints.
    @inlinable static var basicConstraints: Self { Self(known: [0x55, 0x1D, 0x13]) }
    /// `2.5.29.32`, certificatePolicies.
    @inlinable static var certificatePolicies: Self { Self(known: [0x55, 0x1D, 0x20]) }
    /// `2.5.29.35`, authorityKeyIdentifier.
    @inlinable static var authorityKeyIdentifier: Self { Self(known: [0x55, 0x1D, 0x23]) }
    /// `2.5.29.37`, extKeyUsage.
    @inlinable static var extendedKeyUsage: Self { Self(known: [0x55, 0x1D, 0x25]) }

    // Extended key usages (RFC 5280, 4.2.1.12).
    /// `1.3.6.1.5.5.7.3.1`, id-kp-serverAuth.
    @inlinable static var serverAuthentication: Self { Self(known: [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]) }
    /// `1.3.6.1.5.5.7.3.2`, id-kp-clientAuth.
    @inlinable static var clientAuthentication: Self { Self(known: [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]) }
    /// `1.3.6.1.5.5.7.3.3`, id-kp-codeSigning.
    @inlinable static var codeSigning: Self { Self(known: [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03]) }
    /// `1.3.6.1.5.5.7.3.4`, id-kp-emailProtection.
    @inlinable static var emailProtection: Self { Self(known: [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x04]) }
    /// `1.3.6.1.5.5.7.3.8`, id-kp-timeStamping.
    @inlinable static var timeStamping: Self { Self(known: [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x08]) }
    /// `1.3.6.1.5.5.7.3.9`, id-kp-OCSPSigning.
    @inlinable static var ocspSigning: Self { Self(known: [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x09]) }
}

// MARK: - Times

/// A time in a certificate: X.509's `UTCTime` (`YYMMDDHHMMSSZ`, years 1950–2049) or `GeneralizedTime`
/// (`YYYYMMDDHHMMSSZ`), always UTC, to the second, as RFC 5280 (4.1.2.5) requires.
public struct X509Time: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The year, 0 through 9999.
    public var year: Int
    /// The month, 1 through 12.
    public var month: Int
    /// The day of the month, 1 through 31.
    public var day: Int
    /// The hour, 0 through 23.
    public var hour: Int
    /// The minute, 0 through 59.
    public var minute: Int
    /// The second, 0 through 59.
    public var second: Int

    /// A time from its fields, unchecked.
    ///
    /// - Parameters:
    ///   - year: The year.
    ///   - month: The month, 1 through 12.
    ///   - day: The day, from 1.
    ///   - hour: The hour.
    ///   - minute: The minute.
    ///   - second: The second.
    @inlinable
    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// Parses the contents of a `UTCTime` or `GeneralizedTime` element.
    ///
    /// - Parameters:
    ///   - contents: The element's contents: ASCII digits and a final `Z`.
    ///   - tag: ``ASN1Tag/utcTime`` or ``ASN1Tag/generalizedTime``.
    /// - Throws: ``BytesError/invalidValue`` for another tag, length, or character, a field out of range (including
    ///   a day past the month's end), fractional seconds, or a time zone other than `Z`.
    @inlinable
    public init(contents: RawSpan, tag: ASN1Tag) throws(BytesError) {
        let yearDigits: Int
        if tag == .utcTime { yearDigits = 2 } else if tag == .generalizedTime { yearDigits = 4 } else { throw .invalidValue }
        guard contents.byteCount == yearDigits &+ 11, contents.byteOffsetLoad(yearDigits &+ 10) == 0x5A else { throw .invalidValue }
        var offset = 0
        func digits(_ count: Int) throws(BytesError) -> Int {
            var value = 0
            for _ in 0..<count {
                let digit = contents.byteOffsetLoad(offset) &- 0x30
                guard digit <= 9 else { throw .invalidValue }
                value = value &* 10 &+ Int(digit)
                offset &+= 1
            }
            return value
        }
        var year = try digits(yearDigits)
        if yearDigits == 2 { year &+= year >= 50 ? 1900 : 2000 }
        let month = try digits(2), day = try digits(2), hour = try digits(2), minute = try digits(2), second = try digits(2)
        // Checked here rather than by making a `UTCDateTime` (which also checks the year's range: 16 more
        // instructions per certificate). No leap second: RFC 5280 has none.
        guard month >= 1, month <= 12, day >= 1, day <= UTCDateTime.dayCount(inMonth: month, year: year), hour <= 23,
              minute <= 59, second <= 59 else {
            throw .invalidValue
        }
        self.init(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// Seconds since 1970-01-01 00:00:00 UTC (negative before), as `Date(timeIntervalSince1970:)` takes:
    /// ``Bytes/UTCDateTime``'s computation (Howard Hinnant's, proleptic Gregorian).
    public var secondsSince1970: Int64 {
        UTCDateTime.secondsSince1970(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    public static func <(a: Self, b: Self) -> Bool {
        (a.year, a.month, a.day, a.hour, a.minute, a.second) < (b.year, b.month, b.day, b.hour, b.minute, b.second)
    }

    /// ISO 8601: `2026-11-18T09:30:00Z`.
    public var description: String {
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))Z"
    }
}
