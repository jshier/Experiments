import Bytes
import BytesCrypto
import Disk
import Foundation
public import System

/// Where the key that signed an archive comes from.
public enum AEASigningKey: Sendable {
    /// The leaf of the certificate chain in the auth data (`com.apple.ias.signature.certificate-chain`), after
    /// verifying the chain up to Apple Root CA - G3 (Xcode's root), pinned by its SHA-256 fingerprint.
    case certificateChain
    /// The same, trusting these root certificates (DER) instead.
    case certificateChainTrusting([[UInt8]])
    /// The same leaf, without verifying the chain: the signature then proves only that the archive wasn't changed
    /// after the key in it signed it.
    case untrustedCertificateChain
    /// A given public key, X9.63-encoded (65 bytes).
    case publicKey([UInt8])

    /// Reads a public key from a PEM (`-----BEGIN PUBLIC KEY-----`) or raw X9.63 file, as `aea -sign-pub` takes.
    public static func publicKey(contentsOf url: URL) throws(AEAError) -> AEASigningKey {
        try publicKey(contentsOf: FilePath(url.path(percentEncoded: false)))
    }

    /// Reads a public key from a PEM (`-----BEGIN PUBLIC KEY-----`) or raw X9.63 file, as `aea -sign-pub` takes.
    public static func publicKey(contentsOf path: FilePath) throws(AEAError) -> AEASigningKey {
        // Read with Disk's `InputFile`, at most 64 KiB (a PEM public key is about 180 bytes).
        guard let data = try? InputFile.contents(of: path, maximumCount: AEAKeys.keyFileLimit) else {
            throw .untrustedSigningKey("can't read \(path)")
        }
        if data.count == 65 { return .publicKey(data) }
        guard let text = String(validating: data, as: UTF8.self), let key = try? P256.PublicKey(pemRepresentation: text) else {
            throw .untrustedSigningKey("\(path) isn't a P-256 public key")
        }
        return .publicKey(key.x963Representation)
    }

    /// A public key from text, for an app's key field: a PEM (`-----BEGIN PUBLIC KEY-----`, with or without its line
    /// breaks, as a one-line text field leaves a pasted one), or the X9.63 point (65 bytes) as `aea -sign-pub-value`
    /// takes it (`hex:…`, `base64:…`, or bare hex).
    public static func publicKey(text: String) throws(AEAError) -> AEASigningKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let begin = "-----BEGIN PUBLIC KEY-----", end = "-----END PUBLIC KEY-----"
        if trimmed.hasPrefix(begin), let tail = trimmed.range(of: end) {
            let body = trimmed[trimmed.index(trimmed.startIndex, offsetBy: begin.count)..<tail.lowerBound].filter { !$0.isWhitespace }
            guard let key = try? P256.PublicKey(pemRepresentation: "\(begin)\n\(body)\n\(end)\n") else {
                throw .untrustedSigningKey("not a P-256 public key")
            }
            return .publicKey(key.x963Representation)
        }
        // The same encodings as a symmetric key's.
        guard case let .symmetric(bytes)? = try? AEADecryptionKey.symmetric(text: trimmed), bytes.count == 65,
              (try? P256.PublicKey(x963Representation: bytes.span.bytes)) != nil
        else { throw .untrustedSigningKey("not a P-256 public key") }
        return .publicKey(bytes)
    }
}

/// The signer of an archive, as verified.
public struct AEASigner: Sendable {
    /// The signing public key, X9.63.
    public var publicKey: [UInt8]
    /// The leaf certificate's common name, when the key came from the certificate chain.
    public var subject: String?
    /// Whether the certificate chain was verified up to a trusted root.
    public var isTrusted: Bool
}

public enum AEASignature {
    public static let certificateChainKey = "com.apple.ias.signature.certificate-chain"

    /// SHA-256 of Apple Root CA - G3's DER (as macOS's system roots hold it), the root Xcode's chain ends at.
    static let appleRootCAG3: [UInt8] = [
        0x63, 0x34, 0x3A, 0xBF, 0xB8, 0x9A, 0x6A, 0x03, 0xEB, 0xB5, 0x7E, 0x9B, 0x3F, 0x5F, 0xA7, 0xBE,
        0x7C, 0x4F, 0x5C, 0x75, 0x6F, 0x30, 0x17, 0xB3, 0xA8, 0xC4, 0x88, 0xC3, 0x65, 0x3E, 0x91, 0x79,
    ]

    /// Checks the prologue's signature with the signer's key.
    ///
    /// The field holds a DER ECDSA signature padded with zeros to 128 bytes; on profiles 2 and 4 those 128 bytes are
    /// encrypted (AES-CTR) and followed by their MAC, with keys from the main key:
    ///
    ///     SEK = HKDF(HKDF(main key, -, "AEA_SEK", 32), -, "AEA_SEK2", 80)
    ///
    /// The signature covers the whole prologue as stored with the field (all of it) zeroed.
    ///
    /// - Parameters:
    ///   - prologue: The parsed prologue.
    ///   - bytes: The prologue's bytes as stored.
    static func verify(_ prologue: AEAPrologue, bytes: [UInt8], signer: AEASigner, mainKey: Key32) throws(AEAError) {
        guard let key = try? P256.PublicKey(x963Representation: signer.publicKey.span.bytes) else {
            throw .untrustedSigningKey("not a P-256 public key")
        }
        var field = Array(prologue.signature.prefix(128))
        if prologue.profile != .signed {
            let signatureKey = AEAKeys.deriveDataKey(AEAKeys.derive(mainKey, KeyInfo("AEA_SEK")), KeyInfo("AEA_SEK2"))
            let stored = prologue.signature
            let mac = AEAKeys.mac(signatureKey.mac, data: stored.span.bytes.extracting(0..<128))
            guard AEAKeys.equal(mac, stored.span.bytes.extracting(128..<160)) else {
                throw .incorrectKey("signature")
            }
            signatureKey.crypt(&field)
        }
        // DER, zero-padded to the field's size.
        guard let signature = try? P256.Signature(derRepresentation: field.span.bytes, allowingZeroPadding: true) else {
            throw .invalidSignature
        }
        let signed = prologue.signedBytes(bytes)
        guard key.isValidSignature(signature, for: signed.span.bytes) else { throw .invalidSignature }
    }

    /// The signer, from the given key or the auth data's certificate chain (verified or not).
    static func signer(_ prologue: AEAPrologue, _ source: AEASigningKey) throws(AEAError) -> AEASigner {
        let anchors: [[UInt8]]?
        switch source {
        case let .publicKey(key):
            return AEASigner(publicKey: key, subject: nil, isTrusted: true)
        case .certificateChain: anchors = nil
        case let .certificateChainTrusting(roots): anchors = roots
        case .untrustedCertificateChain: anchors = []
        }
        guard let entry = prologue.authDataEntries?.first(where: { $0.key == certificateChainKey }) else {
            throw .untrustedSigningKey("no certificate chain in the auth data")
        }
        guard let chain = try? X509Certificate.decodePEM(entry.value.span.bytes), let leafDER = chain.first else {
            throw .untrustedSigningKey("the certificate chain doesn't decode")
        }
        var trusted = false
        if case .untrustedCertificateChain = source {} else {
            try CertificateChain.verify(chain, anchors: anchors, at: Date())
            trusted = true
        }
        let certificate = try CertificateChain.parse(leafDER.span.bytes, "the leaf certificate")
        guard certificate.namedCurve == .prime256v1 else { throw .untrustedSigningKey("the leaf certificate's key isn't P-256") }
        let key = [UInt8](copying: certificate.publicKey)
        return AEASigner(publicKey: key, subject: certificate.subject.commonName, isTrusted: trusted)
    }
}

/// Verifies a certificate chain (leaf first) with BytesCrypto, as RFC 5280's path validation does for what an archive's
/// chain carries:
/// - each certificate's issuer is the next one's subject, a CA (`cA`, `keyCertSign` if it has a key usage, its path
///   length constraint respected), and signed it (`X509Certificate.isSigned(by:)`: ECDSA on P-256 or P-384, RSA
///   PKCS #1 v1.5 with 1024–4096-bit keys);
/// - every key is of the policy's kind, every certificate is within its validity at `date`, and none has a critical
///   extension this doesn't understand;
/// - the leaf may sign (`digitalSignature`, if it has a key usage), with the policy's extended key usage if it names one;
/// - the chain ends at a trusted root: the last certificate itself, or its issuer.
///
/// With Apple's root (no `anchors` given), the leaf must also be issued by the policy's Apple CA (for `.aea`, "Apple
/// Platform Signing …", Xcode's issuer), not just anything under the root.
public enum CertificateChain {
    /// What an Apple chain must be, beyond RFC 5280's checks: its root, the CA that issues its leaves, and its keys.
    public struct Policy: Sendable {
        /// SHA-256 of the root's DER (as macOS's system roots hold it), and its name for errors.
        var root: [UInt8]
        var rootName: String
        /// The common name (a prefix of it) of the leaf's issuer, and its name for errors.
        var issuer: String
        var issuerName: String
        var keyAlgorithm: ASN1ObjectIdentifier
        /// An extended key usage the leaf must have.
        var leafUsage: ASN1ObjectIdentifier?

        /// Apple Encrypted Archives: P-256 leaves from Apple's platform signing CA, under Apple Root CA - G3.
        public static let archive = Policy(
            root: AEASignature.appleRootCAG3, rootName: "Apple Root CA - G3", issuer: "Apple Platform Signing ",
            issuerName: "Apple's platform signing CA", keyAlgorithm: .ecPublicKey, leafUsage: nil
        )
        /// `.xip`s: the RSA "Software Update" leaf (extended key usage 1.2.840.113635.100.4.1, Apple's software update
        /// signing), from Apple Software Update Certification Authority, under Apple Root CA.
        static let softwareUpdate = Policy(
            root: [
                0xB0, 0xB1, 0x73, 0x0E, 0xCB, 0xC7, 0xFF, 0x45, 0x05, 0x14, 0x2C, 0x49, 0xF1, 0x29, 0x5E, 0x6E,
                0xDA, 0x6B, 0xCA, 0xED, 0x7E, 0x2C, 0x68, 0xC5, 0xBE, 0x91, 0xB5, 0xA1, 0x10, 0x01, 0xF0, 0x24,
            ],
            rootName: "Apple Root CA", issuer: "Apple Software Update Certification Authority",
            issuerName: "Apple's software update CA", keyAlgorithm: .rsaEncryption,
            leafUsage: try? ASN1ObjectIdentifier(contents: [UInt8]([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x04, 0x01]).span.bytes)
        )
    }

    /// Extensions this validation understands, so they may be critical.
    private static let understood: [ASN1ObjectIdentifier] = [
        .basicConstraints, .keyUsage, .extendedKeyUsage, .subjectAlternativeName, .certificatePolicies,
    ]

    /// Parses a certificate, a failure naming `what`.
    @_lifetime(copy der)
    static func parse(_ der: RawSpan, _ what: @autoclosure () -> String) throws(AEAError) -> X509Certificate {
        do throws(BytesError) {
            return try X509Certificate(derEncoded: der)
        } catch {
            throw .untrustedSigningKey("\(what()) doesn't parse (\(error))")
        }
    }

    public static func verify(_ chain: [[UInt8]], anchors: [[UInt8]]?, at date: Date, policy: Policy = .archive) throws(AEAError) {
        let now = Int64(date.timeIntervalSince1970)
        for (index, der) in chain.enumerated() {
            let certificate = try parse(der.span.bytes, "certificate \(index)")
            guard certificate.notBefore.secondsSince1970 <= now, now <= certificate.notAfter.secondsSince1970 else {
                throw .untrustedSigningKey("certificate \(index) (\(certificate.subject.commonName ?? "?")) isn't valid at \(date)")
            }
            guard certificate.publicKeyAlgorithm == policy.keyAlgorithm else {
                throw .untrustedSigningKey("certificate \(index)'s key isn't \(policy.keyAlgorithm == .ecPublicKey ? "an EC" : "an RSA") key")
            }
            var extensions = certificate.extensions
            while let item = extensions.next() {
                let identifier = item.identifier
                guard !item.isCritical || understood.contains(identifier) else {
                    throw .untrustedSigningKey("certificate \(index) has a critical extension \(identifier)")
                }
            }
            if index == 0, let usage = certificate.keyUsage, !usage.contains(.digitalSignature) {
                throw .untrustedSigningKey("the leaf certificate may not sign")
            }
            if index == 0, let usage = policy.leafUsage, certificate.extendedKeyUsage?.contains(usage) != true {
                throw .untrustedSigningKey("the leaf certificate isn't for this kind of signature")
            }
            if index == 1, anchors == nil {
                // Apple's root: only the policy's CA issues these signers.
                guard certificate.subject.commonName?.hasPrefix(policy.issuer) == true else {
                    throw .untrustedSigningKey("the signer wasn't issued by \(policy.issuerName)")
                }
            }
            if index + 1 < chain.count {
                let issuerDER = chain[index + 1]
                let issuer = try parse(issuerDER.span.bytes, "certificate \(index + 1)")
                try checkIssued(certificate, by: issuer, index: index)
            }
        }
        guard let last = chain.last else { throw .untrustedSigningKey("empty certificate chain") }
        // The root: the chain's last certificate, trusted by identity (RFC 5280 doesn't verify a trust anchor, its own
        // signature included): Apple Root CA - G3 by fingerprint, or a given root's exact bytes; or a given root that
        // issued it.
        guard let anchors else {
            let lastDigest = [UInt8](copying: SHA256.hash(last.span.bytes).span.bytes)
            guard lastDigest == policy.root else {
                throw .untrustedSigningKey("the chain doesn't end at \(policy.rootName)")
            }
            return
        }
        for anchor in anchors {
            if anchor == last { return }
            if let issued = try? issuedBy(last, anchor), issued { return }
        }
        throw .untrustedSigningKey("the chain doesn't end at a trusted root")
    }

    private static func issuedBy(_ der: [UInt8], _ issuerDER: [UInt8]) throws(BytesError) -> Bool {
        let certificate = try X509Certificate(derEncoded: der.span.bytes)
        let issuer = try X509Certificate(derEncoded: issuerDER.span.bytes)
        return (try? checkIssued(certificate, by: issuer, index: 0)) != nil
    }

    private static func checkIssued(_ certificate: borrowing X509Certificate, by issuer: borrowing X509Certificate, index: Int) throws(AEAError) {
        let issuerName = certificate.issuer.der, subjectName = issuer.subject.der
        guard issuerName.byteCount == subjectName.byteCount, constantTimeEquals(issuerName, subjectName) else {
            throw .untrustedSigningKey("certificate \(index)'s issuer isn't the next certificate")
        }
        if let usage = issuer.keyUsage, !usage.contains(.keyCertSign) {
            throw .untrustedSigningKey("certificate \(index)'s issuer may not sign certificates")
        }
        // The issuer at position index + 1 has `index` certificates below it; all but the leaf are CAs.
        if let limit = issuer.basicConstraints?.pathLengthConstraint, limit < index {
            throw .untrustedSigningKey("certificate \(index)'s issuer allows \(limit) CAs below it")
        }
        guard issuer.basicConstraints?.isCertificateAuthority == true else {
            throw .untrustedSigningKey("certificate \(index)'s issuer isn't a certificate authority")
        }
        // ECDSA (SHA-256/384/512 on P-256 or P-384) or RSA PKCS #1 v1.5 (SHA-1/256/384/512, 1024–4096 bits).
        guard certificate.isSigned(by: issuer) else {
            throw .untrustedSigningKey("certificate \(index)'s signature doesn't verify (\(certificate.signatureAlgorithm))")
        }
    }
}
