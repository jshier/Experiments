import CryptoKit
import Foundation
import Security

/// Where the key that signed an archive comes from.
public enum AEASigningKey: Sendable {
    /// The leaf of the certificate chain in the auth data (`com.apple.ias.signature.certificate-chain`), after
    /// evaluating the chain as trusted against the system's roots (Xcode's chain ends at Apple Root CA - G3).
    case certificateChain
    /// The same leaf, without evaluating the chain: the signature then proves only that the archive wasn't
    /// changed after the key in it signed it.
    case untrustedCertificateChain
    /// A given public key, X9.63-encoded (65 bytes).
    case publicKey([UInt8])

    /// Reads a public key from a PEM (`-----BEGIN PUBLIC KEY-----`) or raw X9.63 file, as `aea -sign-pub` takes.
    public static func publicKey(contentsOf url: URL) throws(AEAError) -> AEASigningKey {
        guard let data = try? Data(contentsOf: url) else { throw .untrustedSigningKey("can't read \(url.path)") }
        if data.count == 65 { return .publicKey(Array(data)) }
        guard let text = String(data: data, encoding: .utf8),
              let key = try? P256.Signing.PublicKey(pemRepresentation: text)
        else { throw .untrustedSigningKey("\(url.path) isn't a P-256 public key") }
        return .publicKey(Array(key.x963Representation))
    }
}

/// The signer of an archive, as verified.
public struct AEASigner: Sendable {
    /// The signing public key, X9.63.
    public var publicKey: [UInt8]
    /// The leaf certificate's subject summary, when the key came from the certificate chain.
    public var subject: String?
    /// Whether the certificate chain was evaluated as trusted.
    public var isTrusted: Bool
}

enum AEASignature {
    static let certificateChainKey = "com.apple.ias.signature.certificate-chain"

    /// Finds the signing key, checks the prologue's signature with it, and returns it.
    ///
    /// - Parameters:
    ///   - prologue: The parsed prologue.
    ///   - bytes: The prologue's bytes as stored.
    static func verify(_ prologue: AEAPrologue, bytes: [UInt8], key source: AEASigningKey) throws(AEAError) -> AEASigner {
        let signer = try signer(prologue, source)
        guard let key = try? P256.Signing.PublicKey(x963Representation: signer.publicKey) else {
            throw .untrustedSigningKey("not a P-256 public key")
        }
        // The field holds a DER signature padded with zeros to 128 bytes: its length is in its header.
        let field = prologue.signature
        guard field.count >= 2, field[0] == 0x30, Int(field[1]) + 2 <= field.count,
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: field[0..<(Int(field[1]) + 2)])
        else { throw .invalidSignature }
        guard key.isValidSignature(signature, for: prologue.signedBytes(bytes)) else { throw .invalidSignature }
        return signer
    }

    private static func signer(_ prologue: AEAPrologue, _ source: AEASigningKey) throws(AEAError) -> AEASigner {
        switch source {
        case .publicKey(let key):
            return AEASigner(publicKey: key, subject: nil, isTrusted: true)
        case .certificateChain, .untrustedCertificateChain:
            guard let entry = prologue.authDataEntries?.first(where: { $0.key == certificateChainKey }) else {
                throw .untrustedSigningKey("no certificate chain in the auth data")
            }
            let certificates = try certificates(pem: entry.value)
            guard let leaf = certificates.first else { throw .untrustedSigningKey("empty certificate chain") }
            var trusted = false
            if case .certificateChain = source {
                var trust: SecTrust?
                guard unsafe SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
                      let trust
                else { throw .untrustedSigningKey("can't evaluate the certificate chain") }
                var error: CFError?
                guard unsafe SecTrustEvaluateWithError(trust, &error) else {
                    throw .untrustedSigningKey(error.map { CFErrorCopyDescription($0) as String } ?? "the chain isn't trusted")
                }
                trusted = true
            }
            guard let key = SecCertificateCopyKey(leaf), let external = SecKeyCopyExternalRepresentation(key, nil) as Data?,
                  external.count == 65
            else { throw .untrustedSigningKey("the leaf certificate's key isn't P-256") }
            let subject = SecCertificateCopySubjectSummary(leaf) as String?
            return AEASigner(publicKey: Array(external), subject: subject, isTrusted: trusted)
        }
    }

    /// The certificates of a PEM chain, leaf first.
    private static func certificates(pem: [UInt8]) throws(AEAError) -> [SecCertificate] {
        let text = String(decoding: pem.prefix { $0 != 0 }, as: UTF8.self)
        var certificates: [SecCertificate] = []
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        var rest = text[...]
        while let start = rest.range(of: begin), let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex) {
            let base64 = rest[start.upperBound..<stop.lowerBound]
            guard let der = Data(base64Encoded: String(base64), options: .ignoreUnknownCharacters),
                  let certificate = SecCertificateCreateWithData(nil, der as CFData)
            else { throw .untrustedSigningKey("a certificate doesn't parse") }
            certificates.append(certificate)
            rest = rest[stop.upperBound...]
        }
        return certificates
    }
}
