import Bytes
@testable import BytesCrypto
import BytesTesting
import BytesTestSupport
import CryptoKit
import Foundation
import Testing

// P-256 and P-384: Wycheproof's ECDSA and ECDH vectors (every one, valid, invalid, and the encodings it calls
// acceptable), differential tests against CryptoKit (keys, signatures, shared secrets), and key formats (PEM and DER
// from OpenSSL and CryptoKit, X9.63).

// CryptoKit has types of these names too: in this module, unqualified, they're BytesCrypto's.
typealias P256 = BytesCrypto.P256
typealias P384 = BytesCrypto.P384

// MARK: - Vector files

struct ECDSAVectors: Decodable {
    struct Group: Decodable {
        struct Key: Decodable { let uncompressed: String }
        let publicKey: Key
        let publicKeyDer: String
        let publicKeyPem: String
        let sha: String
        let tests: [Vector]
    }
    struct Vector: Decodable {
        let tcId: Int
        let msg, sig, result: String
        let flags: [String]
    }
    let testGroups: [Group]
}

struct ECDHVectors: Decodable {
    struct Group: Decodable {
        let curve: String
        let encoding: String
        let tests: [Vector]
    }
    struct Vector: Decodable {
        let tcId: Int
        let `public`, `private`, shared, result: String
        let flags: [String]
    }
    let testGroups: [Group]
}

/// What the vector tests need of each curve's types.
protocol TestedCurve {
    associatedtype PublicKey
    associatedtype PrivateKey
    static var byteCount: Int { get }
    static func publicKey(x963: [UInt8]) throws(BytesError) -> PublicKey
    static func publicKey(compressed: [UInt8]) throws(BytesError) -> PublicKey
    static func publicKey(der: [UInt8]) throws(BytesError) -> PublicKey
    static func publicKey(pem: String) throws(BytesError) -> PublicKey
    static func x963(_ key: PublicKey) -> [UInt8]
    static func verify(_ key: PublicKey, derSignature: [UInt8], message: [UInt8]) -> Bool
    static func verify(_ key: PublicKey, rawSignature: [UInt8], message: [UInt8]) -> Bool
    static func privateKey(raw: [UInt8]) throws(BytesError) -> PrivateKey
    static func sharedSecret(_ key: PrivateKey, _ other: PublicKey) -> [UInt8]
}

enum TestedP256: TestedCurve {
    static var byteCount: Int { 32 }
    static func publicKey(x963: [UInt8]) throws(BytesError) -> P256.PublicKey { try P256.PublicKey(x963Representation: x963.span.bytes) }
    static func publicKey(compressed: [UInt8]) throws(BytesError) -> P256.PublicKey { try P256.PublicKey(compressedRepresentation: compressed.span.bytes) }
    static func publicKey(der: [UInt8]) throws(BytesError) -> P256.PublicKey { try P256.PublicKey(derRepresentation: der.span.bytes) }
    static func publicKey(pem: String) throws(BytesError) -> P256.PublicKey { try P256.PublicKey(pemRepresentation: pem) }
    static func x963(_ key: P256.PublicKey) -> [UInt8] { key.x963Representation }
    static func verify(_ key: P256.PublicKey, derSignature: [UInt8], message: [UInt8]) -> Bool {
        guard let signature = try? P256.Signature(derRepresentation: derSignature.span.bytes) else { return false }
        return key.isValidSignature(signature, for: message.span.bytes)
    }
    static func verify(_ key: P256.PublicKey, rawSignature: [UInt8], message: [UInt8]) -> Bool {
        guard let signature = try? P256.Signature(rawRepresentation: rawSignature.span.bytes) else { return false }
        return key.isValidSignature(signature, for: message.span.bytes)
    }
    static func privateKey(raw: [UInt8]) throws(BytesError) -> P256.PrivateKey { try P256.PrivateKey(rawRepresentation: raw.span.bytes) }
    static func sharedSecret(_ key: P256.PrivateKey, _ other: P256.PublicKey) -> [UInt8] { key.sharedSecret(with: other).array }
}

enum TestedP384: TestedCurve {
    static var byteCount: Int { 48 }
    static func publicKey(x963: [UInt8]) throws(BytesError) -> P384.PublicKey { try P384.PublicKey(x963Representation: x963.span.bytes) }
    static func publicKey(compressed: [UInt8]) throws(BytesError) -> P384.PublicKey { try P384.PublicKey(compressedRepresentation: compressed.span.bytes) }
    static func publicKey(der: [UInt8]) throws(BytesError) -> P384.PublicKey { try P384.PublicKey(derRepresentation: der.span.bytes) }
    static func publicKey(pem: String) throws(BytesError) -> P384.PublicKey { try P384.PublicKey(pemRepresentation: pem) }
    static func x963(_ key: P384.PublicKey) -> [UInt8] { key.x963Representation }
    static func verify(_ key: P384.PublicKey, derSignature: [UInt8], message: [UInt8]) -> Bool {
        guard let signature = try? P384.Signature(derRepresentation: derSignature.span.bytes) else { return false }
        return key.isValidSignature(signature, for: message.span.bytes)
    }
    static func verify(_ key: P384.PublicKey, rawSignature: [UInt8], message: [UInt8]) -> Bool {
        guard let signature = try? P384.Signature(rawRepresentation: rawSignature.span.bytes) else { return false }
        return key.isValidSignature(signature, for: message.span.bytes)
    }
    static func privateKey(raw: [UInt8]) throws(BytesError) -> P384.PrivateKey { try P384.PrivateKey(rawRepresentation: raw.span.bytes) }
    static func sharedSecret(_ key: P384.PrivateKey, _ other: P384.PublicKey) -> [UInt8] { key.sharedSecret(with: other).array }
}

// `#expect` can't take spans as arguments of the call it checks: these take arrays.
extension P256.PublicKey {
    func verifies(_ signature: P256.Signature, _ message: [UInt8]) -> Bool { isValidSignature(signature, for: message.span.bytes) }
    func verifies(_ signature: P256.Signature, digest: [UInt8]) -> Bool { isValidSignature(signature, digest: digest.span.bytes) }
}
extension P384.PublicKey {
    func verifies(_ signature: P384.Signature, _ message: [UInt8]) -> Bool { isValidSignature(signature, for: message.span.bytes) }
    func verifies(_ signature: P384.Signature, digest: [UInt8]) -> Bool { isValidSignature(signature, digest: digest.span.bytes) }
}

/// A big-endian integer's bytes (Wycheproof's private keys may have a sign byte or be short) as exactly `count`.
func fixedWidth(_ bytes: [UInt8], _ count: Int) -> [UInt8] {
    let significant = Array(bytes.drop { $0 == 0 })
    return [UInt8](repeating: 0, count: max(0, count - significant.count)) + significant
}

/// The ECDSA vector files, each with its curve and signature form.
enum ECDSAFile: String, CaseIterable, Sendable {
    case p256 = "ecdsa_secp256r1_sha256_test.json"
    case p256P1363 = "ecdsa_secp256r1_sha256_p1363_test.json"
    case p384 = "ecdsa_secp384r1_sha384_test.json"
    case p384P1363 = "ecdsa_secp384r1_sha384_p1363_test.json"

    static let files = wycheproofFiles(allCases.map(\.rawValue), as: ECDSAVectors.self)
    /// One vector of each class in the fast run: each costs a debug-built scalar multiplication or two.
    static let splits = files.compactMapValues { file in
        try? VectorSplit(classes: file.get().testGroups.map { $0.tests.map { vectorClass($0.result, $0.flags) } }, perClass: 1)
    }

    var vectors: ECDSAVectors { get throws { try #require(Self.files[rawValue]).get() } }
    var split: VectorSplit { get throws { _ = try vectors; return try #require(Self.splits[rawValue]) } }

    /// Checks each group's key in its three encodings (no signatures), and that the file is whole.
    func checkKeysAndCounts() throws {
        switch self {
        case .p256, .p256P1363: try checkKeysAndCounts(TestedP256.self)
        case .p384, .p384P1363: try checkKeysAndCounts(TestedP384.self)
        }
    }

    /// Checks the vectors at `positions`: valid ones verify, the others don't.
    func check(_ positions: [VectorPosition]) throws {
        switch self {
        case .p256, .p256P1363: try check(TestedP256.self, positions)
        case .p384, .p384P1363: try check(TestedP384.self, positions)
        }
    }

    private func checkKeysAndCounts<C: TestedCurve>(_ curve: C.Type) throws {
        let vectors = try vectors
        var counts = (valid: 0, invalid: 0)
        for group in vectors.testGroups {
            let key = try C.publicKey(x963: hex(group.publicKey.uncompressed))
            // The same key from its DER and PEM.
            #expect(try C.x963(C.publicKey(der: hex(group.publicKeyDer))) == C.x963(key), "\(rawValue)")
            #expect(try C.x963(C.publicKey(pem: group.publicKeyPem)) == C.x963(key), "\(rawValue)")
            for vector in group.tests {
                if vector.result == "valid" { counts.valid += 1 } else { counts.invalid += 1 }
            }
        }
        #expect(counts.valid > 150 && counts.invalid > 80, "\(rawValue): \(counts)")
    }

    private func check<C: TestedCurve>(_ curve: C.Type, _ positions: [VectorPosition]) throws {
        let vectors = try vectors
        let p1363 = self == .p256P1363 || self == .p384P1363
        var keys: [Int: C.PublicKey] = [:]
        for position in positions {
            let group = vectors.testGroups[position.group], vector = group.tests[position.test]
            let key = try keys[position.group] ?? C.publicKey(x963: hex(group.publicKey.uncompressed))
            keys[position.group] = key
            let signature = hex(vector.sig), message = hex(vector.msg)
            let valid = p1363 ? C.verify(key, rawSignature: signature, message: message)
                : C.verify(key, derSignature: signature, message: message)
            #expect(valid == (vector.result == "valid"), "\(rawValue) #\(vector.tcId) \(vector.flags)")
        }
    }
}

/// The ECDH vector files, each with its curve.
enum ECDHFile: String, CaseIterable, Sendable {
    case p256 = "ecdh_secp256r1_test.json"
    case p256Points = "ecdh_secp256r1_ecpoint_test.json"
    case p384 = "ecdh_secp384r1_test.json"

    static let files = wycheproofFiles(allCases.map(\.rawValue), as: ECDHVectors.self)
    /// One vector of each class in the fast run, as for ECDSA.
    static let splits = files.compactMapValues { file in
        try? VectorSplit(classes: file.get().testGroups.map { $0.tests.map { vectorClass($0.result, $0.flags) } }, perClass: 1)
    }

    var vectors: ECDHVectors { get throws { try #require(Self.files[rawValue]).get() } }
    var split: VectorSplit { get throws { _ = try vectors; return try #require(Self.splits[rawValue]) } }

    /// That the file is whole: enough valid and invalid vectors.
    func checkCounts() throws {
        let results = try vectors.testGroups.flatMap { $0.tests.map(\.result) }
        let valid = results.count { $0 == "valid" }, invalid = results.count { $0 == "invalid" }
        #expect(valid > 300 && invalid > 20, "\(rawValue): \(valid) valid, \(invalid) invalid")
    }

    /// Checks the vectors at `positions`: valid ones agree, invalid ones throw, and acceptable ones either throw or
    /// agree.
    func check(_ positions: [VectorPosition]) throws {
        switch self {
        case .p256, .p256Points: try check(TestedP256.self, positions)
        case .p384: try check(TestedP384.self, positions)
        }
    }

    private func check<C: TestedCurve>(_ curve: C.Type, _ positions: [VectorPosition]) throws {
        let vectors = try vectors
        for position in positions {
            let group = vectors.testGroups[position.group], vector = group.tests[position.test]
            let encoded = hex(vector.public)
            let privateKey = try C.privateKey(raw: fixedWidth(hex(vector.private), C.byteCount))
            let result = Result { () throws(BytesError) -> [UInt8] in
                let publicKey: C.PublicKey
                if group.encoding == "ecpoint" {
                    publicKey = encoded.count == 1 + C.byteCount ? try C.publicKey(compressed: encoded) : try C.publicKey(x963: encoded)
                } else {
                    publicKey = try C.publicKey(der: encoded)
                }
                return C.sharedSecret(privateKey, publicKey)
            }
            let label = "\(rawValue) #\(vector.tcId) \(vector.flags)"
            switch vector.result {
            case "valid":
                #expect(try result.get() == hex(vector.shared), "\(label)")
            case "invalid":
                #expect(throws: BytesError.self, "\(label)") { _ = try result.get() }
            default:
                // Acceptable: either outcome, but a secret computed must be the right one.
                if let shared = try? result.get() {
                    #expect(shared == hex(vector.shared), "\(label)")
                }
            }
        }
    }
}

/// Every class of Wycheproof's ECDSA and ECDH vectors (one of each: `VectorSplit`), every group's key, and each file's
/// counts; `ECCWycheproofBulkTests` checks the other vectors. (Debug-built curve arithmetic takes about 0.25 s for a
/// P-384 scalar multiplication: every vector is 7 minutes of CPU.)
@Suite struct ECCWycheproofTests {
    static let shards = 4

    @Test(arguments: ECDSAFile.allCases)
    func ecdsaKeysAndCounts(_ file: ECDSAFile) throws { try file.checkKeysAndCounts() }

    @Test(arguments: ECDSAFile.allCases, 0..<shards)
    func ecdsa(_ file: ECDSAFile, shard: Int) throws {
        try file.check(VectorSplit.shard(file.split.fast, shard, of: Self.shards))
    }

    @Test(arguments: ECDHFile.allCases)
    func ecdhCounts(_ file: ECDHFile) throws { try file.checkCounts() }

    @Test(arguments: ECDHFile.allCases, 0..<shards)
    func ecdh(_ file: ECDHFile, shard: Int) throws {
        try file.check(VectorSplit.shard(file.split.fast, shard, of: Self.shards))
    }
}

/// The ECDSA and ECDH vectors `ECCWycheproofTests` leaves out, in shards that spread across cores.
@Suite(.bulk) struct ECCWycheproofBulkTests {
    static let shards = 16

    @Test(arguments: ECDSAFile.allCases, 0..<shards)
    func ecdsa(_ file: ECDSAFile, shard: Int) throws {
        try file.check(VectorSplit.shard(file.split.bulk, shard, of: Self.shards))
    }

    @Test(arguments: ECDHFile.allCases, 0..<shards)
    func ecdh(_ file: ECDHFile, shard: Int) throws {
        try file.check(VectorSplit.shard(file.split.bulk, shard, of: Self.shards))
    }
}

// MARK: - Field arithmetic

@Suite struct ECCFieldTests {
    /// The moduli's constants agree with each other, and both inversions and the square agree with products, for
    /// `count` random elements (`ECCFieldBulkTests` checks 200 of each).
    static func check<F: ModularArithmetic>(_ type: F.Type, count: Int = 40) {
        // A fixed seed, so a failure reproduces: the messages name it.
        let seed: UInt64 = 0xECC0_F1E1D
        var generator = SplitMix64(seed: seed)
        var tested = 0
        while tested < count {
            let bytes = (0..<F.byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
            guard let x = F(bigEndian: bytes.span.bytes), x.zeroMask == 0 else { continue }
            let inverse = x.inverted
            #expect((x * inverse).equalMask(.one) != 0, "\(F.self) element \(tested), seed \(seed)")
            #expect(x.invertedVariableTime.equalMask(inverse) != 0, "\(F.self) element \(tested), seed \(seed)")
            #expect(x.squared.equalMask(x * x) != 0, "\(F.self) element \(tested), seed \(seed)")
            // Out of Montgomery form and back.
            var output = [UInt8](repeating: 0, count: F.byteCount)
            var span = output.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            x.write(bigEndianTo: &raw, at: 0)
            #expect(output == bytes, "\(F.self) element \(tested), seed \(seed)")
            tested += 1
        }
        #expect(F.zero.invertedVariableTime.zeroMask != 0)
        #expect(F.one.invertedVariableTime.equalMask(.one) != 0)
    }

    @Test func p256Field() { Self.check(P256Curve.Field.self) }
    @Test func p256Order() { Self.check(P256Curve.Scalar.self) }
    @Test func p384Field() { Self.check(P384Curve.Field.self) }
    @Test func p384Order() { Self.check(P384Curve.Scalar.self) }

    @Test func constants() {
        func checkModulus<M: MontgomeryModulus>(_ type: M.Type, limbs: Int) {
            #expect(M.modulus[0] &* M.negativeInverse == UInt64.max, "−m⁻¹ mod 2⁶⁴")
            var exponent = M.modulus
            exponent[0] -= 2
            for index in 0..<6 { #expect(exponent[index] == M.inversionExponent[index]) }
        }
        checkModulus(P256FieldModulus.self, limbs: 4)
        checkModulus(P256OrderModulus.self, limbs: 4)
        checkModulus(P384FieldModulus.self, limbs: 6)
        checkModulus(P384OrderModulus.self, limbs: 6)
    }
}

/// The field checks with 200 random elements of each.
@Suite(.bulk) struct ECCFieldBulkTests {
    @Test func p256Field() { ECCFieldTests.check(P256Curve.Field.self, count: 200) }
    @Test func p256Order() { ECCFieldTests.check(P256Curve.Scalar.self, count: 200) }
    @Test func p384Field() { ECCFieldTests.check(P384Curve.Field.self, count: 200) }
    @Test func p384Order() { ECCFieldTests.check(P384Curve.Scalar.self, count: 200) }
}

// MARK: - CryptoKit

/// Rounds against CryptoKit with fresh keys: the first few here, the rest (to 40 for P-256, 20 for P-384) in
/// `ECCCryptoKitBulkTests`. Rounds differ in message length (`round * 37` and `round * 53` bytes).
@Suite struct ECCCryptoKitTests {
    @Test(arguments: 0..<4) func p256AgainstCryptoKit(round: Int) throws { try Self.p256Round(round) }
    @Test(arguments: 0..<2) func p384AgainstCryptoKit(round: Int) throws { try Self.p384Round(round) }

    static func p256Round(_ round: Int) throws {
        do {
            let signer = CryptoKit.P256.Signing.PrivateKey()
            let message = [UInt8]((0..<(round * 37)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ round) })
            let signature = try signer.signature(for: Data(message))
            let key = try P256.PublicKey(x963Representation: Array(signer.publicKey.x963Representation).span.bytes)
            // Verification, from DER and raw.
            let der = try P256.Signature(derRepresentation: Array(signature.derRepresentation).span.bytes)
            let raw = try P256.Signature(rawRepresentation: Array(signature.rawRepresentation).span.bytes)
            #expect(raw.rawRepresentation == Array(signature.rawRepresentation))
            #expect(key.verifies(der, message))
            #expect(key.verifies(raw, message))
            #expect(key.verifies(der, digest: Array(CryptoKit.SHA256.hash(data: message))))
            var forged = message + [1]
            #expect(!key.verifies(der, forged))
            forged = Array(signature.rawRepresentation)
            forged[63] ^= 1
            #expect(!key.verifies(try P256.Signature(rawRepresentation: forged.span.bytes), message))
            // Compressed form and DER of the public key.
            #expect(try P256.PublicKey(compressedRepresentation: Array(signer.publicKey.compressedRepresentation).span.bytes)
                .x963Representation == key.x963Representation)
            #expect(key.compressedRepresentation == Array(signer.publicKey.compressedRepresentation))
            #expect(try P256.PublicKey(derRepresentation: Array(signer.publicKey.derRepresentation).span.bytes)
                .x963Representation == key.x963Representation)

            // Key agreement, and public keys derived from private ones.
            let mine = CryptoKit.P256.KeyAgreement.PrivateKey()
            let theirs = CryptoKit.P256.KeyAgreement.PrivateKey()
            let expected = try mine.sharedSecretFromKeyAgreement(with: theirs.publicKey).withUnsafeBytes { Array($0) }
            let privateKey = try P256.PrivateKey(rawRepresentation: Array(mine.rawRepresentation).span.bytes)
            #expect(privateKey.publicKey.x963Representation == Array(mine.publicKey.x963Representation))
            #expect(privateKey.rawRepresentation == Array(mine.rawRepresentation))
            let peer = try P256.PublicKey(x963Representation: Array(theirs.publicKey.x963Representation).span.bytes)
            #expect(privateKey.sharedSecret(with: peer).array == expected)
            // CryptoKit's PEM (PKCS #8), DER, and X9.63 private forms.
            #expect(try P256.PrivateKey(pemRepresentation: mine.pemRepresentation).rawRepresentation == privateKey.rawRepresentation)
            #expect(try P256.PrivateKey(derRepresentation: Array(mine.derRepresentation).span.bytes).rawRepresentation == privateKey.rawRepresentation)
            #expect(try P256.PrivateKey(x963Representation: Array(mine.x963Representation).span.bytes).rawRepresentation == privateKey.rawRepresentation)
            #expect(try P256.PublicKey(pemRepresentation: mine.publicKey.pemRepresentation).x963Representation == privateKey.publicKey.x963Representation)
        }
    }

    static func p384Round(_ round: Int) throws {
        do {
            let signer = CryptoKit.P384.Signing.PrivateKey()
            let message = [UInt8]((0..<(round * 53)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ round) })
            let signature = try signer.signature(for: Data(message))
            let key = try P384.PublicKey(x963Representation: Array(signer.publicKey.x963Representation).span.bytes)
            let der = try P384.Signature(derRepresentation: Array(signature.derRepresentation).span.bytes)
            #expect(key.verifies(der, message))
            #expect(!key.verifies(der, message + [0]))
            // A P-384 key verifying a SHA-256 digest (ecdsa-with-SHA256 certificates).
            let sha256Signature = try signer.signature(for: CryptoKit.SHA256.hash(data: message))
            let digest = Array(CryptoKit.SHA256.hash(data: message))
            #expect(key.verifies(try P384.Signature(rawRepresentation: Array(sha256Signature.rawRepresentation).span.bytes), digest: digest))
            #expect(try P384.PublicKey(compressedRepresentation: Array(signer.publicKey.compressedRepresentation).span.bytes)
                .x963Representation == key.x963Representation)

            let mine = CryptoKit.P384.KeyAgreement.PrivateKey()
            let theirs = CryptoKit.P384.KeyAgreement.PrivateKey()
            let expected = try mine.sharedSecretFromKeyAgreement(with: theirs.publicKey).withUnsafeBytes { Array($0) }
            let privateKey = try P384.PrivateKey(pemRepresentation: mine.pemRepresentation)
            #expect(privateKey.publicKey.x963Representation == Array(mine.publicKey.x963Representation))
            let peer = try P384.PublicKey(derRepresentation: Array(theirs.publicKey.derRepresentation).span.bytes)
            #expect(privateKey.sharedSecret(with: peer).array == expected)
        }
    }

    @Test func randomKeys() throws {
        let key = P256.PrivateKey()
        let cryptoKit = try CryptoKit.P256.KeyAgreement.PrivateKey(rawRepresentation: key.rawRepresentation)
        #expect(Array(cryptoKit.publicKey.x963Representation) == key.publicKey.x963Representation)
        let key384 = P384.PrivateKey()
        let cryptoKit384 = try CryptoKit.P384.KeyAgreement.PrivateKey(rawRepresentation: key384.rawRepresentation)
        #expect(Array(cryptoKit384.publicKey.x963Representation) == key384.publicKey.x963Representation)
    }
}

/// The CryptoKit rounds `ECCCryptoKitTests` leaves out, and the rest of the key and signature output rounds.
@Suite(.bulk) struct ECCCryptoKitBulkTests {
    @Test(arguments: 4..<40) func p256AgainstCryptoKit(round: Int) throws { try ECCCryptoKitTests.p256Round(round) }
    @Test(arguments: 2..<20) func p384AgainstCryptoKit(round: Int) throws { try ECCCryptoKitTests.p384Round(round) }
    @Test(arguments: 2..<16) func keyAndSignatureOutputs(round: Int) throws { try ECCFormatTests.keyAndSignatureOutputs() }
}

// MARK: - Formats

@Suite struct ECCFormatTests {
    /// `openssl ecparam -genkey -name prime256v1` (a throwaway key made for this test), with its parameters block.
    static let openSSLP256 = """
        -----BEGIN EC PARAMETERS-----
        BggqhkjOPQMBBw==
        -----END EC PARAMETERS-----
        -----BEGIN EC PRIVATE KEY-----
        MHcCAQEEIEpq/nlWo8yTTLXQta5XEUwkec8qNmbD3Pcmm8D86CS1oAoGCCqGSM49
        AwEHoUQDQgAEocJVx7l6y0XlW88SOW0/dCC65yE/Lqqz7qCqJ4HWzLCJQ6xNzDfN
        sG5OqbqkVzdnjS9zj5RTM9XPzQ1KFsx5WQ==
        -----END EC PRIVATE KEY-----
        """

    /// `openssl ecparam -genkey -name secp384r1 -noout`, and `openssl ec -pubout` of it.
    static let openSSLP384 = """
        -----BEGIN EC PRIVATE KEY-----
        MIGkAgEBBDA2001zghltoWBASXpriwUKY3KQxOJ1n3dBBpKtWJAa8U9hx7uCgAXU
        3axFaFeiJWigBwYFK4EEACKhZANiAARazrNaWU+kVboWybTnGoS1DJsI4jF1UWKz
        x+UTst7UoIrvLlYgS4qdNqKe7LmRjtgonmIqHBKM61f1V6PO6CNl9XB+flmvCsIx
        Pp+F+ZeTE2lCZTp9/3KszSpp2UubLoo=
        -----END EC PRIVATE KEY-----
        """
    static let openSSLP384Public = """
        -----BEGIN PUBLIC KEY-----
        MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEWs6zWllPpFW6Fsm05xqEtQybCOIxdVFi
        s8flE7Le1KCK7y5WIEuKnTainuy5kY7YKJ5iKhwSjOtX9VejzugjZfVwfn5ZrwrC
        MT6fhfmXkxNpQmU6ff9yrM0qadlLmy6K
        -----END PUBLIC KEY-----
        """

    @Test func openSSLKeys() throws {
        let key = try P256.PrivateKey(pemRepresentation: Self.openSSLP256)
        #expect(key.rawRepresentation == hex("4a6afe7956a3cc934cb5d0b5ae57114c2479cf2a3666c3dcf7269bc0fce824b5"))
        #expect(key.publicKey.x963Representation == hex(
            "04a1c255c7b97acb45e55bcf12396d3f7420bae7213f2eaab3eea0aa2781d6ccb08943ac4dcc37cdb06e4ea9baa45737678d2f738f945333d5cfcd0d4a16cc7959"))
        let key384 = try P384.PrivateKey(pemRepresentation: Self.openSSLP384)
        #expect(key384.publicKey.x963Representation == (try P384.PublicKey(pemRepresentation: Self.openSSLP384Public)).x963Representation)
        // A P-384 key isn't a P-256 one, nor the reverse.
        #expect(throws: BytesError.self) { _ = try P256.PrivateKey(pemRepresentation: Self.openSSLP384) }
        #expect(throws: BytesError.self) { _ = try P384.PublicKey(pemRepresentation: CryptoKit.P256.Signing.PrivateKey().publicKey.pemRepresentation) }
    }

    @Test func rejectedKeys() throws {
        let key = try P256.PrivateKey(pemRepresentation: Self.openSSLP256)
        var x963 = key.publicKey.x963Representation
        // Off the curve, a coordinate of p, the identity, the wrong length.
        x963[64] ^= 1
        #expect(throws: BytesError.self) { _ = try P256.PublicKey(x963Representation: x963.span.bytes) }
        let p = hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")
        #expect(throws: BytesError.self) { _ = try P256.PublicKey(x963Representation: ([4] + p + p).span.bytes) }
        #expect(throws: BytesError.self) { _ = try P256.PublicKey(x963Representation: [0].span.bytes) }
        let short = Array(key.publicKey.x963Representation.dropLast())
        #expect(throws: BytesError.self) { _ = try P256.PublicKey(x963Representation: short.span.bytes) }
        // Private keys of 0 and n, and a public key that isn't d's.
        #expect(throws: BytesError.self) { _ = try P256.PrivateKey(rawRepresentation: [UInt8](repeating: 0, count: 32).span.bytes) }
        let n = hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
        #expect(throws: BytesError.self) { _ = try P256.PrivateKey(rawRepresentation: n.span.bytes) }
        let other = P256.PrivateKey()
        #expect(throws: BytesError.self) {
            _ = try P256.PrivateKey(x963Representation: (other.publicKey.x963Representation + key.rawRepresentation).span.bytes)
        }
        // d = n − 1: −G.
        var nMinusOne = n
        nMinusOne[31] -= 1
        let last = try P256.PrivateKey(rawRepresentation: nMinusOne.span.bytes)
        let one = try P256.PrivateKey(rawRepresentation: fixedWidth([1], 32).span.bytes)
        #expect(last.publicKey.x963Representation.prefix(33) == one.publicKey.x963Representation.prefix(33))
        #expect(last.publicKey.x963Representation != one.publicKey.x963Representation)
    }

    @Test func paddedDERSignatures() throws {
        let signer = CryptoKit.P256.Signing.PrivateKey()
        let message: [UInt8] = Array("Apple Encrypted Archive".utf8)
        let der = Array(try signer.signature(for: Data(message)).derRepresentation)
        let key = try P256.PublicKey(x963Representation: Array(signer.publicKey.x963Representation).span.bytes)
        let padded = der + [UInt8](repeating: 0, count: 128 - der.count)
        #expect(throws: BytesError.self) { _ = try P256.Signature(derRepresentation: padded.span.bytes) }
        let signature = try P256.Signature(derRepresentation: padded.span.bytes, allowingZeroPadding: true)
        #expect(key.verifies(signature, message))
        var garbage = padded
        garbage[127] = 1
        #expect(throws: BytesError.self) { _ = try P256.Signature(derRepresentation: garbage.span.bytes, allowingZeroPadding: true) }
    }

    @Test func base64() throws {
        func decode(_ text: String) throws(BytesError) -> [UInt8] {
            let bytes = Array(text.utf8)
            return try PEM.decodeBase64(bytes.span.bytes)
        }
        #expect(try decode("TWFu") == Array("Man".utf8))
        #expect(try decode("TWE=\n") == Array("Ma".utf8))
        #expect(try decode("TQ==") == Array("M".utf8))
        #expect(throws: BytesError.self) { _ = try decode("TQ=a") }
        #expect(throws: BytesError.self) { _ = try decode("TQ==TQ==") }
        #expect(throws: BytesError.self) { _ = try decode("TWF") }
        // Nonzero padding bits: "TR==" and "TWF=" decode to the same bytes as "TQ==" and "TWE=" in a lax decoder.
        #expect(throws: BytesError.self) { _ = try decode("TR==") }
        #expect(throws: BytesError.self) { _ = try decode("TWF=") }
    }

    /// Keys' PEM goes through the same strict decoder as certificates': a key block after another label, and the
    /// first of its label; a mislabeled end line or a missing block fails.
    @Test func keyPEM() throws {
        let key = P256.PrivateKey()
        let base64 = Data(key.publicKey.derRepresentation).base64EncodedString()
        let text = "-----BEGIN EC PARAMETERS-----\nBggqhkjOPQMBBw==\n-----END EC PARAMETERS-----\n" +
            "-----BEGIN PUBLIC KEY-----\n\(base64)\n-----END PUBLIC KEY-----\n"
        #expect(try P256.PublicKey(pemRepresentation: text) == key.publicKey)
        #expect(throws: BytesError.invalidValue) {
            _ = try P256.PublicKey(pemRepresentation: "-----BEGIN PUBLIC KEY-----\n\(base64)\n-----END PRIVATE KEY-----\n")
        }
        #expect(throws: BytesError.insufficientData) { _ = try P256.PublicKey(pemRepresentation: "no blocks") }
    }

    /// The DER and PEM outputs are CryptoKit's and OpenSSL's encodings, and read back: two rounds of fresh keys here,
    /// 14 more in `ECCCryptoKitBulkTests`.
    @Test(arguments: 0..<2) func keyAndSignatureOutputs(round: Int) throws { try Self.keyAndSignatureOutputs() }

    static func keyAndSignatureOutputs() throws {
        do {
            let theirs = CryptoKit.P256.Signing.PrivateKey()
            let key = try P256.PrivateKey(rawRepresentation: theirs.rawRepresentation.span.bytes)
            #expect(key.publicKey.derRepresentation == Array(theirs.publicKey.derRepresentation))
            #expect(key.publicKey.pemRepresentation == theirs.publicKey.pemRepresentation + "\n")
            #expect(try P256.PublicKey(pemRepresentation: key.publicKey.pemRepresentation) == key.publicKey)
            let der = key.derRepresentation
            #expect(try P256.PrivateKey(derRepresentation: der.span.bytes).rawRepresentation == key.rawRepresentation)
            #expect(try P256.PrivateKey(pemRepresentation: key.pemRepresentation).rawRepresentation == key.rawRepresentation)

            let signature = try theirs.signature(for: Data("message".utf8))
            let mine = try P256.Signature(rawRepresentation: signature.rawRepresentation.span.bytes)
            #expect(mine.derRepresentation == Array(signature.derRepresentation))
            #expect(try P256.Signature(derRepresentation: mine.derRepresentation.span.bytes) == mine)

            let big = CryptoKit.P384.Signing.PrivateKey()
            let bigKey = try P384.PrivateKey(rawRepresentation: big.rawRepresentation.span.bytes)
            #expect(bigKey.publicKey.derRepresentation == Array(big.publicKey.derRepresentation))
            #expect(try P384.PrivateKey(pemRepresentation: bigKey.pemRepresentation).rawRepresentation == bigKey.rawRepresentation)
            let bigSignature = try big.signature(for: Data("message".utf8))
            let bigMine = try P384.Signature(rawRepresentation: bigSignature.rawRepresentation.span.bytes)
            #expect(bigMine.derRepresentation == Array(bigSignature.derRepresentation))
        }
    }
}
