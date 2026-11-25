public import Bytes

// The public face of P-256 and P-384: keys, ECDSA signatures and verification, and ECDH, as concrete types over the
// generic cores in ECKeys.swift (each a specialization of the same code). CryptoKit has types named `P256` and
// `P384` too: qualify (`BytesCrypto.P256`) in files importing both.

/// NIST P-256 (secp256r1): ECDSA with SHA-256, and ECDH.
///
/// ```swift
/// let key = try P256.PublicKey(x963Representation: point)           // 65 bytes: 04 ‖ x ‖ y
/// let signature = try P256.Signature(derRepresentation: der)
/// guard key.isValidSignature(signature, for: message) else { … }
///
/// let privateKey = try P256.PrivateKey(pemRepresentation: pem)        // SEC 1 or PKCS #8
/// let secret = privateKey.sharedSecret(with: peerKey)                 // InlineArray<32, UInt8>: x of d·Q
/// ```
///
/// Verification and key agreement allocate nothing. Key agreement is constant-time in the private key;
/// verification, which handles only public values, isn't.
///
/// One key type serves both ECDSA and ECDH, where CryptoKit has `P256.Signing` and `P256.KeyAgreement`: formats such as
/// Apple Encrypted Archives use one key for both, and the representations are the same. Keys and signatures convert
/// to and from CryptoKit's through their raw, X9.63, DER, or PEM forms. Signing isn't implemented: only verification.
/// Public keys and signatures are `Equatable`; private keys aren't (compare secrets in constant time, if at all).
public enum P256 {
    /// A public key: a point on the curve, checked when made.
    public struct PublicKey: Sendable, Equatable {
        let core: ECPublicKeyCore<P256Curve>

        init(core: ECPublicKeyCore<P256Curve>) {
            self.core = core
        }

        /// A key from X9.63's uncompressed form, 04 ‖ x ‖ y (65 bytes).
        ///
        /// - Parameter x963Representation: The encoded point.
        /// - Throws: ``BytesError/invalidValue`` for another length or form, a coordinate of p or more, or a
        ///   point not on the curve.
        public init(x963Representation: RawSpan) throws(BytesError) {
            guard x963Representation.byteCount == 65 else { throw .invalidValue }
            core = try ECPublicKeyCore(point: AffinePoint(x963: x963Representation))
        }

        /// A key from the compressed form, 02 or 03 (y's parity) ‖ x (33 bytes).
        ///
        /// - Parameter compressedRepresentation: The encoded point.
        /// - Throws: ``BytesError/invalidValue`` for another length or form, or an x with no point.
        public init(compressedRepresentation: RawSpan) throws(BytesError) {
            guard compressedRepresentation.byteCount == 33 else { throw .invalidValue }
            core = try ECPublicKeyCore(point: AffinePoint(x963: compressedRepresentation))
        }

        /// A key from a DER SubjectPublicKeyInfo naming P-256 (either point form).
        ///
        /// - Parameter derRepresentation: The DER.
        /// - Throws: ``BytesError`` for malformed DER, another algorithm or curve, or an invalid point.
        public init(derRepresentation: RawSpan) throws(BytesError) {
            core = try ECPublicKeyCore(subjectPublicKeyInfo: derRepresentation)
        }

        /// A key from PEM: a "PUBLIC KEY" block (SubjectPublicKeyInfo).
        ///
        /// - Parameter pemRepresentation: The PEM text.
        /// - Throws: ``BytesError`` for a missing block, bad Base64, or what ``init(derRepresentation:)`` throws.
        public init(pemRepresentation: String) throws(BytesError) {
            core = try ECPublicKeyCore(pem: pemRepresentation)
        }

        /// 04 ‖ x ‖ y: 65 bytes.
        public var x963Representation: [UInt8] { core.x963 }

        /// 02 or 03 ‖ x: 33 bytes.
        public var compressedRepresentation: [UInt8] { core.compressed }

        /// SubjectPublicKeyInfo DER, the point uncompressed: what ``init(derRepresentation:)`` reads.
        public var derRepresentation: [UInt8] { core.subjectPublicKeyInfo }

        /// A "PUBLIC KEY" PEM block of ``derRepresentation``.
        public var pemRepresentation: String {
            let der = core.subjectPublicKeyInfo
            return PEM.encode(der.span.bytes, label: "PUBLIC KEY")
        }

        /// Whether two keys are the same point.
        public static func ==(a: Self, b: Self) -> Bool { a.core.isEqual(to: b.core) }

        /// Whether `signature` is this key's ECDSA signature of `message`, hashed with SHA-256.
        ///
        /// - Parameters:
        ///   - signature: The signature.
        ///   - message: The signed message.
        /// - Returns: `true` if the signature is valid.
        public func isValidSignature(_ signature: Signature, for message: RawSpan) -> Bool {
            core.isValid(signature.core, message: message)
        }

        /// Whether `signature` is this key's ECDSA signature of a message with digest `digest` (of any hash: its
        /// leftmost 256 bits are used, as SEC 1 specifies).
        ///
        /// - Parameters:
        ///   - signature: The signature.
        ///   - digest: The message's digest.
        /// - Returns: `true` if the signature is valid.
        public func isValidSignature(_ signature: Signature, digest: RawSpan) -> Bool {
            core.isValid(signature.core, digest: digest)
        }
    }

    /// An ECDSA signature (r, s), both in [1, n − 1].
    public struct Signature: Sendable, Equatable {
        let core: ECSignatureCore<P256Curve>

        /// A signature from DER: an ECDSA-Sig-Value, SEQUENCE { INTEGER r, INTEGER s }, strictly encoded.
        ///
        /// - Parameters:
        ///   - derRepresentation: The DER.
        ///   - allowingZeroPadding: Whether zero bytes may follow the sequence: signatures stored in fixed-size
        ///     fields (Apple Encrypted Archives') are padded so. Anything else after it is rejected either way.
        /// - Throws: ``BytesError`` for malformed or non-minimal DER, or r or s out of range.
        public init(derRepresentation: RawSpan, allowingZeroPadding: Bool = false) throws(BytesError) {
            core = try ECSignatureCore(der: derRepresentation, allowingZeroPadding: allowingZeroPadding)
        }

        /// A signature from r ‖ s, 32 bytes each (IEEE P1363, CryptoKit's `rawRepresentation`).
        ///
        /// - Parameter rawRepresentation: 64 bytes.
        /// - Throws: ``BytesError/invalidValue`` for another length, or r or s out of range.
        public init(rawRepresentation: RawSpan) throws(BytesError) {
            core = try ECSignatureCore(raw: rawRepresentation)
        }

        /// r ‖ s: 64 bytes.
        public var rawRepresentation: [UInt8] { core.raw }

        /// The ECDSA-Sig-Value DER: what ``init(derRepresentation:allowingZeroPadding:)`` reads.
        public var derRepresentation: [UInt8] { core.der }

        /// Whether two signatures have the same r and s.
        public static func ==(a: Self, b: Self) -> Bool { a.core.isEqual(to: b.core) }
    }

    /// A private key d in [1, n − 1], with its public key dG.
    public struct PrivateKey: Sendable {
        let core: ECPrivateKeyCore<P256Curve>

        /// A random key from the system's secure generator.
        public init() {
            var generator = SystemRandomNumberGenerator()
            core = ECPrivateKeyCore(using: &generator)
        }

        /// A key from d, big-endian, 32 bytes (CryptoKit's `rawRepresentation`).
        ///
        /// - Parameter rawRepresentation: 32 bytes.
        /// - Throws: ``BytesError/invalidValue`` for another length, or d of 0 or n or more.
        public init(rawRepresentation: RawSpan) throws(BytesError) {
            core = try ECPrivateKeyCore(scalar: rawRepresentation)
        }

        /// A key from X9.63's private form: 04 ‖ x ‖ y ‖ d (97 bytes), the point d's public key.
        ///
        /// - Parameter x963Representation: 97 bytes.
        /// - Throws: ``BytesError/invalidValue`` for another length, d out of range, or a point that isn't dG.
        public init(x963Representation: RawSpan) throws(BytesError) {
            core = try ECPrivateKeyCore(x963: x963Representation)
        }

        /// A key from DER: SEC 1's ECPrivateKey (`openssl ecparam -genkey`) or PKCS #8's PrivateKeyInfo. An
        /// embedded public key must be d's, and a named curve P-256.
        ///
        /// - Parameter derRepresentation: The DER.
        /// - Throws: ``BytesError`` for malformed DER, another curve, d out of range, or a mismatched public key.
        public init(derRepresentation: RawSpan) throws(BytesError) {
            core = try ECPrivateKeyCore(der: derRepresentation)
        }

        /// A key from PEM: an "EC PRIVATE KEY" block (SEC 1; an "EC PARAMETERS" block before it is skipped) or a
        /// "PRIVATE KEY" block (PKCS #8).
        ///
        /// - Parameter pemRepresentation: The PEM text.
        /// - Throws: ``BytesError`` for a missing block, bad Base64, or what ``init(derRepresentation:)`` throws.
        public init(pemRepresentation: String) throws(BytesError) {
            core = try ECPrivateKeyCore(pem: pemRepresentation)
        }

        /// The public key, dG.
        public var publicKey: PublicKey { PublicKey(core: core.publicKey) }

        /// SEC 1's ECPrivateKey DER, with the named curve and public key (as `openssl ecparam -genkey` writes it):
        /// what ``init(derRepresentation:)`` reads.
        public var derRepresentation: [UInt8] { core.sec1 }

        /// An "EC PRIVATE KEY" PEM block of ``derRepresentation``.
        public var pemRepresentation: String {
            let der = core.sec1
            return PEM.encode(der.span.bytes, label: "EC PRIVATE KEY")
        }

        /// d, big-endian: 32 bytes.
        public var rawRepresentation: [UInt8] { core.raw }

        /// ECDH (SEC 1, 3.3.1): the x coordinate of d·Q, Q being `publicKey`. Constant-time in d. Allocates
        /// nothing.
        ///
        /// - Parameter publicKey: The other party's key (validated when it was made).
        /// - Returns: The shared secret: 32 bytes, big-endian. Derive keys from it (HKDF); don't use it as one.
        public func sharedSecret(with publicKey: PublicKey) -> InlineArray<32, UInt8> {
            var secret = InlineArray<32, UInt8>(repeating: 0)
            var span = secret.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            core.sharedSecret(with: publicKey.core, into: &bytes)
            return secret
        }
    }
}

/// NIST P-384 (secp384r1): ECDSA with SHA-384 (the curve of Apple's root certificates), and ECDH. The same API as
/// ``P256``, with 48-byte coordinates and scalars.
public enum P384 {
    /// A public key: a point on the curve, checked when made.
    public struct PublicKey: Sendable, Equatable {
        let core: ECPublicKeyCore<P384Curve>

        init(core: ECPublicKeyCore<P384Curve>) {
            self.core = core
        }

        /// A key from X9.63's uncompressed form, 04 ‖ x ‖ y (97 bytes).
        ///
        /// - Parameter x963Representation: The encoded point.
        /// - Throws: ``BytesError/invalidValue`` for another length or form, or a point not on the curve.
        public init(x963Representation: RawSpan) throws(BytesError) {
            guard x963Representation.byteCount == 97 else { throw .invalidValue }
            core = try ECPublicKeyCore(point: AffinePoint(x963: x963Representation))
        }

        /// A key from the compressed form, 02 or 03 ‖ x (49 bytes).
        ///
        /// - Parameter compressedRepresentation: The encoded point.
        /// - Throws: ``BytesError/invalidValue`` for another length or form, or an x with no point.
        public init(compressedRepresentation: RawSpan) throws(BytesError) {
            guard compressedRepresentation.byteCount == 49 else { throw .invalidValue }
            core = try ECPublicKeyCore(point: AffinePoint(x963: compressedRepresentation))
        }

        /// A key from a DER SubjectPublicKeyInfo naming P-384 (either point form): a certificate's key.
        ///
        /// - Parameter derRepresentation: The DER.
        /// - Throws: ``BytesError`` for malformed DER, another algorithm or curve, or an invalid point.
        public init(derRepresentation: RawSpan) throws(BytesError) {
            core = try ECPublicKeyCore(subjectPublicKeyInfo: derRepresentation)
        }

        /// A key from PEM: a "PUBLIC KEY" block.
        ///
        /// - Parameter pemRepresentation: The PEM text.
        /// - Throws: ``BytesError`` for a missing block, bad Base64, or what ``init(derRepresentation:)`` throws.
        public init(pemRepresentation: String) throws(BytesError) {
            core = try ECPublicKeyCore(pem: pemRepresentation)
        }

        /// 04 ‖ x ‖ y: 97 bytes.
        public var x963Representation: [UInt8] { core.x963 }

        /// 02 or 03 ‖ x: 49 bytes.
        public var compressedRepresentation: [UInt8] { core.compressed }

        /// SubjectPublicKeyInfo DER, the point uncompressed: what ``init(derRepresentation:)`` reads.
        public var derRepresentation: [UInt8] { core.subjectPublicKeyInfo }

        /// A "PUBLIC KEY" PEM block of ``derRepresentation``.
        public var pemRepresentation: String {
            let der = core.subjectPublicKeyInfo
            return PEM.encode(der.span.bytes, label: "PUBLIC KEY")
        }

        /// Whether two keys are the same point.
        public static func ==(a: Self, b: Self) -> Bool { a.core.isEqual(to: b.core) }

        /// Whether `signature` is this key's ECDSA signature of `message`, hashed with SHA-384.
        ///
        /// - Parameters:
        ///   - signature: The signature.
        ///   - message: The signed message (a certificate's TBSCertificate).
        /// - Returns: `true` if the signature is valid.
        public func isValidSignature(_ signature: Signature, for message: RawSpan) -> Bool {
            core.isValid(signature.core, message: message)
        }

        /// Whether `signature` is this key's ECDSA signature of a message with digest `digest` (of any hash: its
        /// leftmost 384 bits are used; a certificate signed with ecdsa-with-SHA256 passes a SHA-256 digest).
        ///
        /// - Parameters:
        ///   - signature: The signature.
        ///   - digest: The message's digest.
        /// - Returns: `true` if the signature is valid.
        public func isValidSignature(_ signature: Signature, digest: RawSpan) -> Bool {
            core.isValid(signature.core, digest: digest)
        }
    }

    /// An ECDSA signature (r, s), both in [1, n − 1].
    public struct Signature: Sendable, Equatable {
        let core: ECSignatureCore<P384Curve>

        /// A signature from DER: an ECDSA-Sig-Value, strictly encoded (a certificate's signatureValue contents).
        ///
        /// - Parameters:
        ///   - derRepresentation: The DER.
        ///   - allowingZeroPadding: Whether zero bytes may follow the sequence.
        /// - Throws: ``BytesError`` for malformed or non-minimal DER, or r or s out of range.
        public init(derRepresentation: RawSpan, allowingZeroPadding: Bool = false) throws(BytesError) {
            core = try ECSignatureCore(der: derRepresentation, allowingZeroPadding: allowingZeroPadding)
        }

        /// A signature from r ‖ s, 48 bytes each.
        ///
        /// - Parameter rawRepresentation: 96 bytes.
        /// - Throws: ``BytesError/invalidValue`` for another length, or r or s out of range.
        public init(rawRepresentation: RawSpan) throws(BytesError) {
            core = try ECSignatureCore(raw: rawRepresentation)
        }

        /// r ‖ s: 96 bytes.
        public var rawRepresentation: [UInt8] { core.raw }

        /// The ECDSA-Sig-Value DER: what ``init(derRepresentation:allowingZeroPadding:)`` reads.
        public var derRepresentation: [UInt8] { core.der }

        /// Whether two signatures have the same r and s.
        public static func ==(a: Self, b: Self) -> Bool { a.core.isEqual(to: b.core) }
    }

    /// A private key d in [1, n − 1], with its public key dG.
    public struct PrivateKey: Sendable {
        let core: ECPrivateKeyCore<P384Curve>

        /// A random key from the system's secure generator.
        public init() {
            var generator = SystemRandomNumberGenerator()
            core = ECPrivateKeyCore(using: &generator)
        }

        /// A key from d, big-endian, 48 bytes.
        ///
        /// - Parameter rawRepresentation: 48 bytes.
        /// - Throws: ``BytesError/invalidValue`` for another length, or d of 0 or n or more.
        public init(rawRepresentation: RawSpan) throws(BytesError) {
            core = try ECPrivateKeyCore(scalar: rawRepresentation)
        }

        /// A key from X9.63's private form: 04 ‖ x ‖ y ‖ d (145 bytes).
        ///
        /// - Parameter x963Representation: 145 bytes.
        /// - Throws: ``BytesError/invalidValue`` for another length, d out of range, or a point that isn't dG.
        public init(x963Representation: RawSpan) throws(BytesError) {
            core = try ECPrivateKeyCore(x963: x963Representation)
        }

        /// A key from DER: SEC 1's ECPrivateKey or PKCS #8's PrivateKeyInfo.
        ///
        /// - Parameter derRepresentation: The DER.
        /// - Throws: ``BytesError`` for malformed DER, another curve, d out of range, or a mismatched public key.
        public init(derRepresentation: RawSpan) throws(BytesError) {
            core = try ECPrivateKeyCore(der: derRepresentation)
        }

        /// A key from PEM: an "EC PRIVATE KEY" or a "PRIVATE KEY" block.
        ///
        /// - Parameter pemRepresentation: The PEM text.
        /// - Throws: ``BytesError`` for a missing block, bad Base64, or what ``init(derRepresentation:)`` throws.
        public init(pemRepresentation: String) throws(BytesError) {
            core = try ECPrivateKeyCore(pem: pemRepresentation)
        }

        /// The public key, dG.
        public var publicKey: PublicKey { PublicKey(core: core.publicKey) }

        /// SEC 1's ECPrivateKey DER, with the named curve and public key (as `openssl ecparam -genkey` writes it):
        /// what ``init(derRepresentation:)`` reads.
        public var derRepresentation: [UInt8] { core.sec1 }

        /// An "EC PRIVATE KEY" PEM block of ``derRepresentation``.
        public var pemRepresentation: String {
            let der = core.sec1
            return PEM.encode(der.span.bytes, label: "EC PRIVATE KEY")
        }

        /// d, big-endian: 48 bytes.
        public var rawRepresentation: [UInt8] { core.raw }

        /// ECDH: the x coordinate of d·Q. Constant-time in d. Allocates nothing.
        ///
        /// - Parameter publicKey: The other party's key.
        /// - Returns: The shared secret: 48 bytes, big-endian.
        public func sharedSecret(with publicKey: PublicKey) -> InlineArray<48, UInt8> {
            var secret = InlineArray<48, UInt8>(repeating: 0)
            var span = secret.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            core.sharedSecret(with: publicKey.core, into: &bytes)
            return secret
        }
    }
}
