import Bytes
import BytesBase64
import BytesCrypto
import Disk
import Foundation
public import System

/// What decrypts an encrypted archive (profiles 1–5).
public enum AEADecryptionKey: Sendable {
    /// Profiles 1 and 2: the symmetric key (32 bytes), as `aea -key` takes it.
    case symmetric([UInt8])
    /// Profiles 3 and 4: the recipient's P-256 private key, the raw 32-byte scalar.
    case recipientPrivateKey([UInt8])
    /// Profile 5: the password's bytes.
    case password([UInt8])

    /// A symmetric key from text as `aea -key-value` takes it: `hex:…`, `base64:…`, or bare hex.
    ///
    /// Base64 is strict (BytesBase64): padded, and a last character's unused bits zero, as `aea` prints keys.
    /// (Foundation's `Data(base64Encoded:)`, used before, also took nonzero unused bits.)
    public static func symmetric(text: String) throws(AEAError) -> AEADecryptionKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("base64:") {
            guard let key = try? Base64.decodedBytes(String(trimmed.dropFirst(7))) else { throw .missingKey("a base64 key") }
            return .symmetric(key)
        }
        let hex = trimmed.hasPrefix("hex:") ? String(trimmed.dropFirst(4)) : trimmed
        guard hex.utf8.count.isMultiple(of: 2) else { throw .missingKey("a hex key of whole bytes") }
        // Digits only: `UInt8(_:radix:)`, used before, also took a sign ("+f").
        guard let bytes = try? [UInt8](hexadecimal: hex) else { throw .missingKey("a hex or base64 key") }
        return .symmetric(bytes)
    }

    /// A recipient private key from a PEM file (SEC1 `EC PRIVATE KEY` or PKCS #8 `PRIVATE KEY`), as `aea
    /// -recipient-priv` takes it, or a raw 32-byte scalar.
    public static func recipientPrivateKey(contentsOf url: URL) throws(AEAError) -> AEADecryptionKey {
        try recipientPrivateKey(contentsOf: FilePath(url.path(percentEncoded: false)))
    }

    /// A recipient private key from a PEM file (SEC1 `EC PRIVATE KEY` or PKCS #8 `PRIVATE KEY`), as `aea
    /// -recipient-priv` takes it, or a raw 32-byte scalar.
    public static func recipientPrivateKey(contentsOf path: FilePath) throws(AEAError) -> AEADecryptionKey {
        // Read with Disk's `InputFile`, at most 64 KiB (a PEM private key is about 250 bytes).
        guard let data = try? InputFile.contents(of: path, maximumCount: AEAKeys.keyFileLimit) else {
            throw .missingKey("a readable key file: \(path)")
        }
        if data.count == 32 { return .recipientPrivateKey(data) }
        guard let text = String(validating: data, as: UTF8.self), let key = try? P256.PrivateKey(pemRepresentation: text) else {
            throw .missingKey("a P-256 private key in \(path)")
        }
        return .recipientPrivateKey(key.rawRepresentation)
    }
}

extension AEAKeys {
    /// The most bytes a key file (a PEM or raw key) is read for.
    static let keyFileLimit = 64 << 10
}

extension AEAKeys {
    /// The archive's main key, from what the profile takes: the prologue's key material (0), the symmetric key (1,
    /// 2), an ECDH shared secret with the prologue's ephemeral public key (3, 4), or the password (5).
    static func mainKey(_ prologue: AEAPrologue, signingPublicKey signing: [UInt8], decryptionKey: AEADecryptionKey?) throws(AEAError) -> Key32 {
        let salt = prologue.salt.span.bytes
        switch prologue.profile {
        case .signed:
            return mainKey(prologue, input: prologue.keyMaterial.span.bytes, salt: salt, signing: signing)
        case .symmetric, .symmetricSigned:
            guard case let .symmetric(key) = decryptionKey else { throw .missingKey("a symmetric key") }
            guard key.count == 32 else { throw .missingKey("a 32-byte symmetric key (this one has \(key.count))") }
            return mainKey(prologue, input: key.span.bytes, salt: salt, signing: signing)
        case .ecdhe, .ecdheSigned:
            guard case let .recipientPrivateKey(scalar) = decryptionKey else { throw .missingKey("the recipient's private key") }
            // HKDF(ECDH x-coordinate, salt, info … | ephemeral public | recipient public | signing public).
            let (secret, recipient) = try ecdh(scalar, ephemeralPublicKey: prologue.keyMaterial)
            return mainKey(prologue, input: secret.span.bytes, salt: salt, sender: prologue.keyMaterial, recipient: recipient, signing: signing)
        case .scrypt:
            guard case let .password(password) = decryptionKey else { throw .missingKey("a password") }
            // The salt extends to 64 bytes: the first half salts scrypt, the second the main key's HKDF.
            var extended = InlineArray<64, UInt8>(repeating: 0)
            var extendedSpan = extended.mutableSpan
            var extendedBytes = MutableRawSpan(mutating: &extendedSpan)
            var pseudorandom = Key32(repeating: 0)
            var prkSpan = pseudorandom.mutableSpan
            var prk = MutableRawSpan(mutating: &prkSpan)
            BytesCrypto.HKDF<BytesCrypto.SHA256>.extract(salt: RawSpan(), inputKeyMaterial: salt, into: &prk)
            BytesCrypto.HKDF<BytesCrypto.SHA256>.expand(pseudorandomKey: pseudorandom.span.bytes, info: Array("AEA_SCRYPT".utf8).span.bytes, into: &extendedBytes)
            let cost = 0x4000 << (2 * prologue.scryptStrength)
            let passwordKey = try scrypt(password, salt: extended.span.bytes.extracting(0..<32), cost: cost)
            return mainKey(prologue, input: passwordKey.span.bytes, salt: extended.span.bytes.extracting(32..<64))
        }
    }

    /// ECDH on P-256 (BytesCrypto's, constant-time in the private key): the shared x-coordinate and the recipient's
    /// public key (X9.63).
    static func ecdh(_ scalar: [UInt8], ephemeralPublicKey: [UInt8]) throws(AEAError) -> (Key32, [UInt8]) {
        guard let privateKey = try? P256.PrivateKey(rawRepresentation: scalar.span.bytes),
              let publicKey = try? P256.PublicKey(x963Representation: ephemeralPublicKey.span.bytes)
        else { throw .missingKey("a valid P-256 key pair") }
        return (privateKey.sharedSecret(with: publicKey), privateKey.publicKey.x963Representation)
    }

    /// scrypt(password, salt, N = cost, r = 8, p = 1), 32 bytes: BytesCrypto's, with one buffer of N × 1 KiB for
    /// the call (16 MiB at the strength `aea` writes, 1 GiB at the highest).
    static func scrypt(_ password: [UInt8], salt: RawSpan, cost: Int) throws(AEAError) -> Key32 {
        var key = Key32(repeating: 0)
        var keySpan = key.mutableSpan
        var keyBytes = MutableRawSpan(mutating: &keySpan)
        do {
            try Scrypt.deriveKey(password: password.span.bytes, salt: salt, cost: cost, blockSize: 8, parallelism: 1, into: &keyBytes)
        } catch {
            throw .missingKey("a password scrypt accepts (\(error))")
        }
        return key
    }
}
