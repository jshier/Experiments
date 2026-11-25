public import Bytes

/// An X.509 v1–v3 certificate (RFC 5280), parsed in place: every field is a view of the DER it came from, found in
/// one pass that allocates nothing. No signature is checked: ``tbsCertificate``, ``signatureAlgorithm``, and
/// ``signature`` are what a verifier needs, and the issuer's ``publicKey``.
///
/// ```swift
/// for der in try X509Certificate.decodePEM(pemText) {
///     let certificate = try X509Certificate(derEncoded: der.span.bytes)
///     print(certificate.subject.commonName ?? "?", certificate.notAfter)
///     if certificate.signatureAlgorithm == .ecdsaWithSHA384 { … verify certificate.signature over
///         certificate.tbsCertificate with the issuer's key … }
/// }
/// ```
///
/// The certificate is `~Escapable`: it borrows the DER. Keep the bytes and parse again where a certificate must be
/// stored (parsing costs about as much as copying it, a few microseconds).
///
/// Strict DER: definite lengths in their shortest form, no bytes after any element inside its parent or after the
/// certificate, booleans `00` or `FF`, integers in their shortest form, bit strings with zero padding, times in
/// RFC 5280's forms (UTC, to the second), the outer and inner signature algorithms identical, no extension twice,
/// extensions only in v3 certificates, and no field equal to its `DEFAULT` written out (a `critical` or `cA` of `FALSE`,
/// a `version` of v1; none of the system's 151 root certificates has one). The order of `SET OF` elements (relative
/// names with several attributes) isn't checked. Anything malformed throws; nothing traps.
public struct X509Certificate: ~Escapable {
    /// The certificate's DER encoding, exactly.
    public let der: RawSpan
    /// Where the fields are in ``der``.
    let layout: X509Layout

    /// Parses the DER encoding of one certificate.
    ///
    /// - Parameter der: The certificate's bytes, and nothing after them.
    /// - Throws: ``BytesError/insufficientData`` if it's cut short; ``BytesError/trailingData`` if bytes follow it;
    ///   ``BytesError/mismatch`` if an element has the wrong tag; ``BytesError/invalidValue`` for any other
    ///   violation of DER or RFC 5280's structure (see ``X509Certificate``).
    @_lifetime(copy der)
    public init(derEncoded der: RawSpan) throws(BytesError) {
        self.der = der
        layout = try X509Layout(parsing: der)
    }

    /// The certificate's version: 1, 2, or 3.
    public var version: Int { layout.version }

    /// The `TBSCertificate` element, tag and length included: the bytes the issuer signed.
    public var tbsCertificate: RawSpan {
        @_lifetime(copy self) get { der.extracting(layout.tbsCertificate) }
    }

    /// The serial number's contents: a big-endian two's-complement integer in its shortest form.
    public var serialNumber: RawSpan {
        @_lifetime(copy self) get { der.extracting(layout.serialNumber) }
    }

    /// The signature algorithm, such as ``ASN1ObjectIdentifier/ecdsaWithSHA256``.
    public var signatureAlgorithm: ASN1ObjectIdentifier { layout.identifier(layout.signatureAlgorithm, in: der) }

    /// The signature algorithm's parameters element (tag and length included), or nil when absent, as for ECDSA.
    /// RSA's PKCS #1 algorithms have a `NULL` here.
    public var signatureAlgorithmParameters: RawSpan? {
        @_lifetime(copy self) get {
            guard let range = layout.signatureParameters else { return nil }
            return der.extracting(range)
        }
    }

    /// The signature: the `signatureValue` bit string's bytes. For ECDSA, a DER `Ecdsa-Sig-Value` (a sequence of the
    /// integers r and s).
    public var signature: RawSpan {
        @_lifetime(copy self) get { der.extracting(layout.signature) }
    }

    /// The issuer's distinguished name.
    public var issuer: X509Name {
        @_lifetime(copy self) get { X509Name(der: der.extracting(layout.issuer)) }
    }

    /// The subject's distinguished name.
    public var subject: X509Name {
        @_lifetime(copy self) get { X509Name(der: der.extracting(layout.subject)) }
    }

    /// The start of the validity period.
    public var notBefore: X509Time { layout.notBefore }

    /// The end of the validity period (inclusive).
    public var notAfter: X509Time { layout.notAfter }

    /// The `SubjectPublicKeyInfo` element, tag and length included (what key pins hash).
    public var subjectPublicKeyInfo: RawSpan {
        @_lifetime(copy self) get { der.extracting(layout.subjectPublicKeyInfo) }
    }

    /// The public key's algorithm, such as ``ASN1ObjectIdentifier/ecPublicKey`` or
    /// ``ASN1ObjectIdentifier/rsaEncryption``.
    public var publicKeyAlgorithm: ASN1ObjectIdentifier { layout.identifier(layout.publicKeyAlgorithm, in: der) }

    /// The public key algorithm's parameters element (tag and length included), or nil when absent.
    public var publicKeyParameters: RawSpan? {
        @_lifetime(copy self) get {
            guard let range = layout.publicKeyParameters else { return nil }
            return der.extracting(range)
        }
    }

    /// The curve of an elliptic-curve key (``ASN1ObjectIdentifier/prime256v1``, ``ASN1ObjectIdentifier/secp384r1``,
    /// …): the parameters when they're an object identifier, otherwise nil.
    public var namedCurve: ASN1ObjectIdentifier? {
        guard let range = layout.namedCurve else { return nil }
        return layout.identifier(range, in: der)
    }

    /// The public key: the `subjectPublicKey` bit string's bytes. For an elliptic-curve key, the X9.63 point (`04`,
    /// then x and y); for RSA, a DER `RSAPublicKey`.
    public var publicKey: RawSpan {
        @_lifetime(copy self) get { der.extracting(layout.publicKey) }
    }

    /// The basic constraints extension, or nil if there's none.
    public var basicConstraints: X509BasicConstraints? { layout.basicConstraints }

    /// The key usage extension's bits, or nil if there's none.
    public var keyUsage: X509KeyUsage? { layout.keyUsage }

    /// The extended key usage extension's purposes, or nil if there's none.
    public var extendedKeyUsage: X509ObjectIdentifiers? {
        @_lifetime(copy self) get {
            guard let range = layout.extendedKeyUsage else { return nil }
            return X509ObjectIdentifiers(der, range)
        }
    }

    /// Every extension, in order: iterate with `next()`.
    ///
    /// ```swift
    /// var extensions = certificate.extensions
    /// while let item = extensions.next() { print(item.identifier, item.isCritical, item.value.byteCount) }
    /// ```
    public var extensions: X509Extensions {
        @_lifetime(copy self) get { X509Extensions(der, layout.extensions ?? 0..<0) }
    }

    /// The extension with identifier `identifier`, or nil.
    ///
    /// - Parameter identifier: The extension's identifier, such as ``ASN1ObjectIdentifier/subjectKeyIdentifier``.
    /// - Returns: The extension.
    @_lifetime(copy self)
    public func `extension`(_ identifier: ASN1ObjectIdentifier) -> X509Extension? {
        var all = extensions
        while let item = all.next() {
            if identifier.matches(item.identifierContents) { return item }
        }
        return nil
    }

    /// Whether the issuer and subject names are the same bytes (a root, or a self-issued intermediate).
    public var isSelfIssued: Bool { layout.issuer.count == layout.subject.count && issuer.der.equals(subject.der) }
}

extension RawSpan {
    /// Whether two spans hold the same bytes.
    func equals(_ other: RawSpan) -> Bool {
        guard byteCount == other.byteCount else { return false }
        for index in 0..<byteCount where byteOffsetLoad(index) != other.byteOffsetLoad(index) {
            return false
        }
        return true
    }
}

/// The basic constraints extension (RFC 5280, 4.2.1.9).
public struct X509BasicConstraints: Hashable, Sendable {
    /// Whether the subject is a certificate authority.
    public var isCertificateAuthority: Bool
    /// The most intermediate certificates that may follow this one in a path, or nil for no limit.
    public var pathLengthConstraint: Int?

    /// Constraints with the given values.
    ///
    /// - Parameters:
    ///   - isCertificateAuthority: Whether the subject is a CA.
    ///   - pathLengthConstraint: The path length limit, or nil.
    public init(isCertificateAuthority: Bool, pathLengthConstraint: Int?) {
        self.isCertificateAuthority = isCertificateAuthority
        self.pathLengthConstraint = pathLengthConstraint
    }
}

/// The key usage extension's bits (RFC 5280, 4.2.1.3).
public struct X509KeyUsage: OptionSet, Hashable, Sendable {
    /// The usages as bits.
    public var rawValue: UInt16

    /// Usages from bits: bit n is the bit string's bit n (`digitalSignature` is bit 0).
    ///
    /// - Parameter rawValue: The bits.
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Verifying signatures other than on certificates and CRLs: what a signing leaf needs.
    public static var digitalSignature: Self { Self(rawValue: 1 << 0) }
    /// Verifying signatures that commit to content (also called contentCommitment).
    public static var nonRepudiation: Self { Self(rawValue: 1 << 1) }
    /// Encrypting keys (RSA key transport).
    public static var keyEncipherment: Self { Self(rawValue: 1 << 2) }
    /// Encrypting data directly with the public key.
    public static var dataEncipherment: Self { Self(rawValue: 1 << 3) }
    /// Key agreement (ECDH).
    public static var keyAgreement: Self { Self(rawValue: 1 << 4) }
    /// Verifying signatures on certificates: what an issuer needs.
    public static var keyCertSign: Self { Self(rawValue: 1 << 5) }
    /// Verifying signatures on certificate revocation lists.
    public static var cRLSign: Self { Self(rawValue: 1 << 6) }
    /// With ``keyAgreement``: only to encrypt during key agreement.
    public static var encipherOnly: Self { Self(rawValue: 1 << 7) }
    /// With ``keyAgreement``: only to decrypt during key agreement.
    public static var decipherOnly: Self { Self(rawValue: 1 << 8) }
}

/// One certificate extension: its identifier, whether it's critical, and its value (the `extnValue` octet string's
/// contents, the extension's own DER).
public struct X509Extension: ~Escapable {
    /// The identifier's DER contents.
    public let identifierContents: RawSpan
    /// Whether a verifier that doesn't recognize the extension must reject the certificate.
    public let isCritical: Bool
    /// The value: the octet string's contents.
    public let value: RawSpan

    @_lifetime(copy identifierContents, copy value)
    init(identifierContents: RawSpan, isCritical: Bool, value: RawSpan) {
        self.identifierContents = identifierContents
        self.isCritical = isCritical
        self.value = value
    }

    /// The extension's identifier, such as ``ASN1ObjectIdentifier/basicConstraints``.
    public var identifier: ASN1ObjectIdentifier {
        ASN1ObjectIdentifier(validated: identifierContents)
    }
}

/// A certificate's extensions, one at a time.
public struct X509Extensions: ~Escapable {
    var elements: X509Elements

    @_lifetime(copy der)
    init(_ der: RawSpan, _ contents: Range<Int>) { elements = X509Elements(der, contents) }

    /// The next extension, or nil after the last.
    @_lifetime(copy self)
    public mutating func next() -> X509Extension? {
        // Each was parsed when the certificate was, so these reads succeed; nil otherwise, never a trap.
        guard let element = elements.next(), let parts = try? X509Layout.extensionParts(elements.der, element) else { return nil }
        return X509Extension(identifierContents: elements.der.extracting(parts.identifier), isCritical: parts.isCritical,
                             value: elements.der.extracting(parts.value))
    }
}

/// A sequence of object identifiers (the extended key usage extension's purposes), one at a time.
public struct X509ObjectIdentifiers: ~Escapable {
    var elements: X509Elements

    @_lifetime(copy der)
    init(_ der: RawSpan, _ contents: Range<Int>) { elements = X509Elements(der, contents) }

    /// The next identifier, or nil after the last.
    public mutating func next() -> ASN1ObjectIdentifier? {
        guard let element = elements.next() else { return nil }
        return try? ASN1ObjectIdentifier(contents: elements.der.extracting(element.contents))
    }

    /// Whether `identifier` is one of them.
    ///
    /// - Parameter identifier: An identifier, such as ``ASN1ObjectIdentifier/codeSigning``.
    /// - Returns: Whether it's in the sequence.
    public func contains(_ identifier: ASN1ObjectIdentifier) -> Bool {
        var copy = elements
        while let element = copy.next() {
            if identifier.matches(elements.der.extracting(element.contents)) { return true }
        }
        return false
    }
}

/// The elements in a range of DER that has already been checked, one at a time.
struct X509Elements: ~Escapable {
    let der: RawSpan
    var offset: Int
    let end: Int

    @_lifetime(copy der)
    init(_ der: RawSpan, _ contents: Range<Int>) {
        self.der = der
        offset = contents.lowerBound
        end = contents.upperBound
    }

    mutating func next() -> ASN1Element? {
        guard offset < end, let element = try? ASN1Element.parseHeader(der.extracting(0..<end), at: offset) else { return nil }
        offset = element.range.upperBound
        return element
    }
}

/// A distinguished name: a sequence of relative distinguished names, each a set of attributes.
public struct X509Name: ~Escapable {
    /// The `Name` element, tag and length included: compare these bytes to match an issuer to its certificate.
    public let der: RawSpan

    @_lifetime(copy der)
    init(der: RawSpan) { self.der = der }

    /// The attributes, in order (each relative name's in turn): iterate with `next()`.
    public var attributes: X509NameAttributes {
        @_lifetime(copy self) get { X509NameAttributes(der) }
    }

    /// The first attribute of type `type`, or nil.
    ///
    /// - Parameter type: An attribute type, such as ``ASN1ObjectIdentifier/organizationName``.
    /// - Returns: The attribute.
    @_lifetime(copy self)
    public func first(_ type: ASN1ObjectIdentifier) -> X509NameAttribute? {
        var all = attributes
        while let attribute = all.next() {
            if type.matches(attribute.typeContents) { return attribute }
        }
        return nil
    }

    /// The first common name (`CN`) as a string, or nil if there's none or it isn't a valid string of its type.
    public var commonName: String? { first(.commonName)?.string }
}

/// One attribute of a distinguished name.
public struct X509NameAttribute: ~Escapable {
    /// The attribute type's DER contents.
    public let typeContents: RawSpan
    /// The value's tag: usually a string type (``ASN1Tag/utf8String``, ``ASN1Tag/printableString``, …).
    public let valueTag: ASN1Tag
    /// The value's contents.
    public let value: RawSpan

    @_lifetime(copy typeContents, copy value)
    init(typeContents: RawSpan, valueTag: ASN1Tag, value: RawSpan) {
        self.typeContents = typeContents
        self.valueTag = valueTag
        self.value = value
    }

    /// The attribute type, such as ``ASN1ObjectIdentifier/commonName``.
    public var type: ASN1ObjectIdentifier {
        ASN1ObjectIdentifier(validated: typeContents)
    }

    /// The value as a string, for the string types X.509 names use: UTF-8, printable and IA5 (ASCII), teletex (read
    /// as Latin-1, as is the custom), BMP (UTF-16BE), and universal (UTF-32BE). Nil for other types or invalid
    /// contents.
    public var string: String? {
        switch valueTag {
        case .utf8String:
            guard let text = try? UTF8Span(validating: Span(viewing: value)) else { return nil }
            return String(copying: text)
        case .printableString, .ia5String:
            var scalars = String.UnicodeScalarView()
            for index in 0..<value.byteCount {
                let byte = value.byteOffsetLoad(index)
                guard byte < 0x80 else { return nil }
                scalars.append(Unicode.Scalar(byte))
            }
            return String(scalars)
        case .teletexString:
            var scalars = String.UnicodeScalarView()
            for index in 0..<value.byteCount {
                scalars.append(Unicode.Scalar(value.byteOffsetLoad(index)))
            }
            return String(scalars)
        case .bmpString:
            guard value.byteCount % 2 == 0 else { return nil }
            var units: [UInt16] = []
            for index in stride(from: 0, to: value.byteCount, by: 2) {
                units.append(UInt16(value.byteOffsetLoad(index)) << 8 | UInt16(value.byteOffsetLoad(index + 1)))
            }
            var scalars = String.UnicodeScalarView()
            for result in UTF16.decode(units) {
                guard let scalar = result else { return nil }
                scalars.append(scalar)
            }
            return String(scalars)
        case .universalString:
            guard value.byteCount % 4 == 0 else { return nil }
            var scalars = String.UnicodeScalarView()
            for index in stride(from: 0, to: value.byteCount, by: 4) {
                var code: UInt32 = 0
                for byte in 0..<4 {
                    code = code << 8 | UInt32(value.byteOffsetLoad(index + byte))
                }
                guard let scalar = Unicode.Scalar(code) else { return nil }
                scalars.append(scalar)
            }
            return String(scalars)
        default:
            return nil
        }
    }
}

extension UTF16 {
    /// Decodes UTF-16 code units into scalars, nil for each error.
    static func decode(_ units: [UInt16]) -> [Unicode.Scalar?] {
        var decoder = UTF16()
        var iterator = units.makeIterator()
        var result: [Unicode.Scalar?] = []
        loop: while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar): result.append(scalar)
            case .emptyInput: break loop
            case .error: result.append(nil); break loop
            }
        }
        return result
    }
}

/// A name's attributes, one at a time.
public struct X509NameAttributes: ~Escapable {
    let der: RawSpan
    /// The relative names left (offsets in `der`).
    var names: X509Elements
    /// The current relative name's attributes left.
    var attributes: X509Elements

    @_lifetime(copy der)
    init(_ der: RawSpan) {
        self.der = der
        // The name was checked when the certificate was parsed: a sequence of sets of sequences.
        let name = (try? ASN1Element.parseHeader(der, at: 0)) ?? ASN1Element(tag: .sequence, range: 0..<0, contents: 0..<0)
        names = X509Elements(der, name.contents)
        attributes = X509Elements(der, 0..<0)
    }

    /// The next attribute, or nil after the last.
    @_lifetime(copy self)
    public mutating func next() -> X509NameAttribute? {
        while true {
            if let attribute = attributes.next() {
                var pair = X509Elements(der, attribute.contents)
                guard let type = pair.next(), let value = pair.next() else { return nil }
                return X509NameAttribute(typeContents: der.extracting(type.contents), valueTag: value.tag, value: der.extracting(value.contents))
            }
            guard let set = names.next() else { return nil }
            attributes = X509Elements(der, set.contents)
        }
    }
}

// MARK: - Parsing

/// Where a certificate's fields are in its DER, and the fields decoded from it: what parsing produces.
struct X509Layout: Sendable {
    var version = 1
    var tbsCertificate = 0..<0
    var serialNumber = 0..<0
    var signatureAlgorithm = 0..<0
    var signatureParameters: Range<Int>?
    var signature = 0..<0
    var issuer = 0..<0
    var subject = 0..<0
    var notBefore = X509Time(year: 0, month: 1, day: 1, hour: 0, minute: 0, second: 0)
    var notAfter = X509Time(year: 0, month: 1, day: 1, hour: 0, minute: 0, second: 0)
    var subjectPublicKeyInfo = 0..<0
    var publicKeyAlgorithm = 0..<0
    var publicKeyParameters: Range<Int>?
    var namedCurve: Range<Int>?
    var publicKey = 0..<0
    var extensions: Range<Int>?
    var basicConstraints: X509BasicConstraints?
    var keyUsage: X509KeyUsage?
    var extendedKeyUsage: Range<Int>?

    /// The identifier whose contents are at `range` (checked when parsed).
    func identifier(_ range: Range<Int>, in der: RawSpan) -> ASN1ObjectIdentifier {
        ASN1ObjectIdentifier(validated: der.extracting(range))
    }

    /// A reader over the children of `element`: the input up to the element's end, from its contents.
    @_lifetime(copy der)
    static func children(_ der: RawSpan, _ element: ASN1Element) throws(BytesError) -> AlignedBytesReader {
        try AlignedBytesReader(der.extracting(0..<element.contents.upperBound), atByteOffset: element.contents.lowerBound)
    }

    /// The most elements nested in one another that a certificate may have (X.509 needs about 8).
    static var maximumDepth: Int { 32 }

    /// Checks that every constructed element in `range` is made of whole elements, to `depth` levels.
    static func checkStructure(_ der: RawSpan, _ range: Range<Int>, depth: Int) throws(BytesError) {
        guard depth < maximumDepth else { throw .invalidValue }
        var reader = try AlignedBytesReader(der.extracting(0..<range.upperBound), atByteOffset: range.lowerBound)
        while !reader.isAtEnd {
            let element = try reader.readASN1Element()
            if element.tag.isConstructed { try checkStructure(der, element.contents, depth: depth &+ 1) }
        }
    }

    init(parsing der: RawSpan) throws(BytesError) {
        var outer = AlignedBytesReader(der)
        let certificate = try outer.readASN1Element(.sequence)
        guard outer.isAtEnd else { throw .trailingData }
        // Every constructed element is read below except algorithm parameters and name attribute values, which
        // `checkStructure` walks where they're constructed. (A walk of the whole certificate first, and a
        // duplicate check that parsed each earlier extension again, made parsing 1.7–2.3x the instructions: 14 K against 8.1 K
        // for Apple Root CA - G3, 28 K against 12 K for ACCVRAIZ1, with 9 extensions.)

        var fields = try Self.children(der, certificate)
        let tbs = try fields.readASN1Element(.sequence)
        tbsCertificate = tbs.range
        let outerAlgorithm = try fields.readASN1Element(.sequence)
        let signatureBits = try fields.readASN1Element(.bitString)
        guard fields.isAtEnd else { throw .trailingData }
        signature = try Self.bitString(der, signatureBits, allowingUnusedBits: false)
        (signatureAlgorithm, signatureParameters) = try Self.algorithm(der, outerAlgorithm)

        var reader = try Self.children(der, tbs)
        // version [0] EXPLICIT INTEGER DEFAULT v1.
        if reader.nextASN1Tag == .contextSpecific(0, constructed: true) {
            let wrapper = try reader.readASN1Element()
            var inner = try Self.children(der, wrapper)
            let value = try Self.smallInteger(der, inner.readASN1Element(.integer))
            guard inner.isAtEnd else { throw .trailingData }
            guard value >= 1, value <= 2 else { throw .invalidValue } // v1 is the default: omitted in DER.
            version = value &+ 1
        }
        let serial = try reader.readASN1Element(.integer)
        try Self.checkInteger(der, serial)
        serialNumber = serial.contents
        // The inner signature algorithm must be the outer one (RFC 5280, 4.1.1.2).
        let innerAlgorithm = try reader.readASN1Element(.sequence)
        guard der.extracting(innerAlgorithm.range).equals(der.extracting(outerAlgorithm.range)) else { throw .invalidValue }
        let issuerName = try reader.readASN1Element(.sequence)
        try Self.checkName(der, issuerName)
        issuer = issuerName.range
        let validity = try reader.readASN1Element(.sequence)
        var times = try Self.children(der, validity)
        notBefore = try Self.time(der, times.readASN1Element())
        notAfter = try Self.time(der, times.readASN1Element())
        guard times.isAtEnd else { throw .trailingData }
        let subjectName = try reader.readASN1Element(.sequence)
        try Self.checkName(der, subjectName)
        subject = subjectName.range
        let keyInfo = try reader.readASN1Element(.sequence)
        subjectPublicKeyInfo = keyInfo.range
        var keyFields = try Self.children(der, keyInfo)
        (publicKeyAlgorithm, publicKeyParameters) = try Self.algorithm(der, keyFields.readASN1Element(.sequence))
        publicKey = try Self.bitString(der, keyFields.readASN1Element(.bitString), allowingUnusedBits: false)
        guard keyFields.isAtEnd else { throw .trailingData }
        if let parameters = publicKeyParameters, der.byteOffsetLoad(parameters.lowerBound) == ASN1Tag.objectIdentifier.rawValue {
            let element = try ASN1Element.parseHeader(der, at: parameters.lowerBound)
            try ASN1ObjectIdentifier.validate(der.extracting(element.contents))
            namedCurve = element.contents
        }
        // issuerUniqueID [1] and subjectUniqueID [2] (v2 and v3), then extensions [3] (v3).
        for number: UInt8 in 1...2 where reader.nextASN1Tag == .contextSpecific(number, constructed: false) {
            guard version >= 2 else { throw .invalidValue }
            _ = try Self.bitString(der, reader.readASN1Element(), allowingUnusedBits: true)
        }
        if reader.nextASN1Tag == .contextSpecific(3, constructed: true) {
            guard version == 3 else { throw .invalidValue }
            let wrapper = try reader.readASN1Element()
            var inner = try Self.children(der, wrapper)
            let list = try inner.readASN1Element(.sequence)
            guard inner.isAtEnd else { throw .trailingData }
            guard !list.contents.isEmpty else { throw .invalidValue } // SIZE (1..MAX).
            try parseExtensions(der, list)
            extensions = list.contents
        }
        guard reader.isAtEnd else { throw .trailingData }
    }

    /// The most extensions a certificate may have: more is refused (``BytesError/invalidValue``).
    static var maximumExtensionCount: Int { 64 }

    /// Checks each extension, rejects duplicates, and decodes the ones this type knows.
    mutating func parseExtensions(_ der: RawSpan, _ list: ASN1Element) throws(BytesError) {
        var reader = try Self.children(der, list)
        // Every identifier so far, to refuse a second of any (RFC 5280, 4.2). At most `maximumExtensionCount`: real
        // certificates have fewer than 30, and past 16 the check re-read every earlier extension, so 16,000 of them (a
        // 192 KB certificate, parsed before its signature is checked) took 2.6 s.
        var seen = InlineArray<64, Range<Int>>(repeating: 0..<0)
        var count = 0
        while !reader.isAtEnd {
            guard count < Self.maximumExtensionCount else { throw .invalidValue }
            let element = try reader.readASN1Element(.sequence)
            let parts = try Self.extensionParts(der, element)
            let identifier = der.extracting(parts.identifier)
            for index in 0..<count {
                guard !der.extracting(seen[index]).equals(identifier) else { throw .invalidValue }
            }
            seen[count] = parts.identifier
            count &+= 1
            let value = parts.value
            if ASN1ObjectIdentifier.basicConstraints.matches(identifier) {
                basicConstraints = try Self.parseBasicConstraints(der, value)
            } else if ASN1ObjectIdentifier.keyUsage.matches(identifier) {
                keyUsage = try Self.parseKeyUsage(der, value)
            } else if ASN1ObjectIdentifier.extendedKeyUsage.matches(identifier) {
                extendedKeyUsage = try Self.parseObjectIdentifierSequence(der, value)
            }
        }
    }

    /// An extension's identifier contents, criticality, and value contents.
    static func extensionParts(_ der: RawSpan, _ element: ASN1Element) throws(BytesError) -> (identifier: Range<Int>, isCritical: Bool, value: Range<Int>) {
        var fields = try children(der, element)
        let identifier = try fields.readASN1Element(.objectIdentifier)
        try ASN1ObjectIdentifier.validate(der.extracting(identifier.contents))
        var isCritical = false
        if fields.nextASN1Tag == .boolean {
            isCritical = try boolean(der, fields.readASN1Element())
            guard isCritical else { throw .invalidValue } // FALSE is the default: omitted in DER.
        }
        let value = try fields.readASN1Element(.octetString)
        guard fields.isAtEnd else { throw .trailingData }
        return (identifier.contents, isCritical, value.contents)
    }

    /// `BasicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE, pathLenConstraint INTEGER (0..MAX) OPTIONAL }`.
    static func parseBasicConstraints(_ der: RawSpan, _ value: Range<Int>) throws(BytesError) -> X509BasicConstraints {
        var outer = try AlignedBytesReader(der.extracting(0..<value.upperBound), atByteOffset: value.lowerBound)
        let sequence = try outer.readASN1Element(.sequence)
        guard outer.isAtEnd else { throw .trailingData }
        var fields = try children(der, sequence)
        var constraints = X509BasicConstraints(isCertificateAuthority: false, pathLengthConstraint: nil)
        if fields.nextASN1Tag == .boolean {
            constraints.isCertificateAuthority = try boolean(der, fields.readASN1Element())
            guard constraints.isCertificateAuthority else { throw .invalidValue } // FALSE is the default: omitted in DER.
        }
        if fields.nextASN1Tag == .integer {
            let length = try smallInteger(der, fields.readASN1Element())
            guard length >= 0 else { throw .invalidValue }
            constraints.pathLengthConstraint = length
        }
        guard fields.isAtEnd else { throw .trailingData }
        return constraints
    }

    /// `KeyUsage ::= BIT STRING`, bits 0 through 8.
    static func parseKeyUsage(_ der: RawSpan, _ value: Range<Int>) throws(BytesError) -> X509KeyUsage {
        var outer = try AlignedBytesReader(der.extracting(0..<value.upperBound), atByteOffset: value.lowerBound)
        let element = try outer.readASN1Element(.bitString)
        guard outer.isAtEnd else { throw .trailingData }
        let bits = try bitString(der, element, allowingUnusedBits: true)
        guard bits.count <= 2 else { throw .invalidValue }
        var usage: UInt16 = 0
        for index in 0..<bits.count {
            let byte = der.byteOffsetLoad(bits.lowerBound &+ index)
            // Bit string bit 8 × index + k is the byte's bit 7 − k.
            for k in 0..<8 where byte & (0x80 >> k) != 0 {
                let bit = 8 &* index &+ k
                guard bit <= 8 else { throw .invalidValue }
                usage |= 1 << bit
            }
        }
        return X509KeyUsage(rawValue: usage)
    }

    /// A `SEQUENCE SIZE (1..MAX) OF OBJECT IDENTIFIER` (extended key usage): its contents.
    static func parseObjectIdentifierSequence(_ der: RawSpan, _ value: Range<Int>) throws(BytesError) -> Range<Int> {
        var outer = try AlignedBytesReader(der.extracting(0..<value.upperBound), atByteOffset: value.lowerBound)
        let sequence = try outer.readASN1Element(.sequence)
        guard outer.isAtEnd else { throw .trailingData }
        guard !sequence.contents.isEmpty else { throw .invalidValue }
        var fields = try children(der, sequence)
        while !fields.isAtEnd {
            let identifier = try fields.readASN1Element(.objectIdentifier)
            try ASN1ObjectIdentifier.validate(der.extracting(identifier.contents))
        }
        return sequence.contents
    }

    /// `AlgorithmIdentifier ::= SEQUENCE { algorithm OBJECT IDENTIFIER, parameters ANY OPTIONAL }`: the identifier's
    /// contents, and the parameters element if present.
    static func algorithm(_ der: RawSpan, _ element: ASN1Element) throws(BytesError) -> (Range<Int>, Range<Int>?) {
        var fields = try children(der, element)
        let identifier = try fields.readASN1Element(.objectIdentifier)
        try ASN1ObjectIdentifier.validate(der.extracting(identifier.contents))
        var parameters: Range<Int>?
        if !fields.isAtEnd {
            let element = try fields.readASN1Element()
            if element.tag.isConstructed { try checkStructure(der, element.contents, depth: 1) }
            parameters = element.range
        }
        guard fields.isAtEnd else { throw .trailingData }
        return (identifier.contents, parameters)
    }

    /// `Name ::= SEQUENCE OF SET SIZE (1..MAX) OF SEQUENCE { type OBJECT IDENTIFIER, value ANY }`.
    static func checkName(_ der: RawSpan, _ name: ASN1Element) throws(BytesError) {
        var names = try children(der, name)
        while !names.isAtEnd {
            let set = try names.readASN1Element(.set)
            guard !set.contents.isEmpty else { throw .invalidValue }
            var attributes = try children(der, set)
            while !attributes.isAtEnd {
                var pair = try children(der, attributes.readASN1Element(.sequence))
                let type = try pair.readASN1Element(.objectIdentifier)
                try ASN1ObjectIdentifier.validate(der.extracting(type.contents))
                let value = try pair.readASN1Element()
                if value.tag.isConstructed { try checkStructure(der, value.contents, depth: 1) }
                guard pair.isAtEnd else { throw .trailingData }
            }
        }
    }

    /// A `BIT STRING`'s bytes after the unused-bits count. DER: the unused bits (0–7, none in an empty string) are
    /// zero; `allowingUnusedBits` false requires a whole number of bytes.
    static func bitString(_ der: RawSpan, _ element: ASN1Element, allowingUnusedBits: Bool) throws(BytesError) -> Range<Int> {
        guard element.tag == .bitString || element.tag.rawValue & 0xE0 == 0x80 else { throw .mismatch }
        let contents = element.contents
        guard !contents.isEmpty else { throw .invalidValue }
        let unused = der.byteOffsetLoad(contents.lowerBound)
        guard unused <= 7 else { throw .invalidValue }
        if unused != 0 {
            guard allowingUnusedBits, contents.count >= 2 else { throw .invalidValue }
            let last = der.byteOffsetLoad(contents.upperBound &- 1)
            guard last & (UInt8(1) << unused &- 1) == 0 else { throw .invalidValue }
        }
        return (contents.lowerBound &+ 1)..<contents.upperBound
    }

    /// Checks an `INTEGER`'s contents: at least one byte, in the shortest form.
    static func checkInteger(_ der: RawSpan, _ element: ASN1Element) throws(BytesError) {
        let contents = element.contents
        guard !contents.isEmpty else { throw .invalidValue }
        if contents.count >= 2 {
            let first = der.byteOffsetLoad(contents.lowerBound), second = der.byteOffsetLoad(contents.lowerBound &+ 1)
            guard !(first == 0x00 && second < 0x80), !(first == 0xFF && second >= 0x80) else { throw .invalidValue }
        }
    }

    /// An `INTEGER` that fits in 62 bits.
    static func smallInteger(_ der: RawSpan, _ element: ASN1Element) throws(BytesError) -> Int {
        guard element.tag == .integer else { throw .mismatch }
        try checkInteger(der, element)
        let contents = element.contents
        guard contents.count <= 7 else { throw .invalidValue }
        var value = Int(Int8(bitPattern: der.byteOffsetLoad(contents.lowerBound)))
        for offset in contents.dropFirst() {
            value = value &<< 8 | Int(der.byteOffsetLoad(offset))
        }
        return value
    }

    /// A `BOOLEAN`: one byte, `00` or `FF`.
    static func boolean(_ der: RawSpan, _ element: ASN1Element) throws(BytesError) -> Bool {
        guard element.tag == .boolean else { throw .mismatch }
        guard element.contents.count == 1 else { throw .invalidValue }
        switch der.byteOffsetLoad(element.contents.lowerBound) {
        case 0x00: return false
        case 0xFF: return true
        default: throw .invalidValue
        }
    }

    /// A `Time ::= CHOICE { utcTime UTCTime, generalTime GeneralizedTime }`.
    static func time(_ der: RawSpan, _ element: ASN1Element) throws(BytesError) -> X509Time {
        guard element.tag == .utcTime || element.tag == .generalizedTime else { throw .mismatch }
        return try X509Time(contents: der.extracting(element.contents), tag: element.tag)
    }
}

// MARK: - PEM

public extension X509Certificate {
    /// The DER encodings of the certificates in PEM text: each `-----BEGIN CERTIFICATE-----` … `-----END
    /// CERTIFICATE-----` block's Base64, decoded (RFC 7468). Text between blocks is ignored; blocks with other labels
    /// are skipped.
    ///
    /// - Parameter text: The PEM text's bytes (ASCII).
    /// - Returns: Each certificate's DER, in order (not parsed).
    /// - Throws: ``BytesError/invalidValue`` for a block whose Base64 is malformed (characters outside the alphabet
    ///   and whitespace, misplaced or missing padding, nonzero padding bits) or whose end line is missing or
    ///   mislabeled.
    static func decodePEM(_ text: RawSpan) throws(BytesError) -> [[UInt8]] {
        try PEM.decodeAll(text, label: "CERTIFICATE")
    }

    /// The DER encodings of the certificates in PEM text, as ``decodePEM(_:)-(RawSpan)``.
    ///
    /// - Parameter text: The PEM text.
    /// - Returns: Each certificate's DER, in order.
    /// - Throws: As ``decodePEM(_:)-(RawSpan)``.
    static func decodePEM(_ text: String) throws(BytesError) -> [[UInt8]] {
        try PEM.decodeAll(text, label: "CERTIFICATE")
    }
}

// MARK: - Signatures

public extension X509Certificate {
    /// Whether this certificate's signature verifies with `issuer`'s public key: RSA PKCS #1 v1.5
    /// (`sha1WithRSAEncryption`, `sha256WithRSAEncryption`, `sha384WithRSAEncryption`, `sha512WithRSAEncryption`, their
    /// parameters `NULL` or absent) with an RSA key of 1024 to 4096 bits, or ECDSA (`ecdsaWithSHA256`, `ecdsaWithSHA384`,
    /// `ecdsaWithSHA512`) with a P-256 or P-384 key.
    ///
    /// Only the signature is checked: a chain needs the names, validity, and constraints checked too, and its root
    /// trusted by identity. Leaf → intermediate → root, as Apple's `.xip` archives carry theirs:
    ///
    /// ```swift
    /// let leaf = try X509Certificate(derEncoded: leafDER.span.bytes)
    /// let intermediate = try X509Certificate(derEncoded: intermediateDER.span.bytes)
    /// let root = try X509Certificate(derEncoded: rootDER.span.bytes)     // a trusted root's exact bytes
    /// for (certificate, issuer) in [(leaf, intermediate), (intermediate, root)] {   // (schematically: they're ~Escapable)
    ///     guard constantTimeEquals(certificate.issuer.der, issuer.subject.der),
    ///           issuer.basicConstraints?.isCertificateAuthority == true,
    ///           issuer.keyUsage?.contains(.keyCertSign) ?? true,
    ///           certificate.isSigned(by: issuer) else { throw … }
    /// }
    /// let key = try RSA.PublicKey(certificate: leaf)
    /// guard key.isValidSignature(signature, digest: tocChecksum, digestAlgorithm: .sha1) else { throw … }
    /// ```
    ///
    /// - Parameter issuer: The certificate whose key should have signed this one (this one itself, for a self-signed
    ///   root).
    /// - Returns: `true` if the signature is valid; `false` for an invalid signature, an unsupported algorithm or key,
    ///   or a key that doesn't match the algorithm.
    func isSigned(by issuer: borrowing X509Certificate) -> Bool {
        let algorithm = signatureAlgorithm
        if let digestAlgorithm = RSA.DigestAlgorithm(signatureAlgorithm: algorithm) {
            // RFC 4055, 5: the parameters are NULL, and verifiers accept them absent too.
            if let parameters = signatureAlgorithmParameters {
                guard parameters.byteCount == 2, parameters.byteOffsetLoad(0) == ASN1Tag.null.rawValue,
                      parameters.byteOffsetLoad(1) == 0 else { return false }
            }
            guard let key = try? RSA.PublicKey(certificate: issuer) else { return false }
            return key.isValidSignature(signature, for: tbsCertificate, digestAlgorithm: digestAlgorithm)
        }
        let digestAlgorithm: RSA.DigestAlgorithm
        switch algorithm {
        case .ecdsaWithSHA256: digestAlgorithm = .sha256
        case .ecdsaWithSHA384: digestAlgorithm = .sha384
        case .ecdsaWithSHA512: digestAlgorithm = .sha512
        default: return false
        }
        guard issuer.publicKeyAlgorithm == .ecPublicKey else { return false }
        var digestBytes = InlineArray<64, UInt8>(repeating: 0)
        digestAlgorithm.hash(tbsCertificate, into: &digestBytes)
        let digest = digestBytes.span.bytes.extracting(first: digestAlgorithm.digestByteCount)
        switch issuer.namedCurve {
        case .prime256v1:
            guard let key = try? P256.PublicKey(x963Representation: issuer.publicKey),
                  let value = try? P256.Signature(derRepresentation: signature) else { return false }
            return key.isValidSignature(value, digest: digest)
        case .secp384r1:
            guard let key = try? P384.PublicKey(x963Representation: issuer.publicKey),
                  let value = try? P384.Signature(derRepresentation: signature) else { return false }
            return key.isValidSignature(value, digest: digest)
        default:
            return false
        }
    }
}
