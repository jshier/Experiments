import Benchmark
import Bytes
import BytesCrypto
import BytesTestSupport
import CryptoKit
import Foundation

// Elliptic curves against CryptoKit (corecrypto's assembly): ECDSA verification and ECDH on P-256 and P-384, and
// HPKE opening (DHKEM(P-256, HKDF-SHA256), AES-256-GCM) of a 32-byte key, as Apple's firmware archives wrap theirs.
// One operation per iteration, keys parsed beforehand. Allocation counts in single-operation benchmarks below.

let eccMessage = [UInt8]((0..<64).map { UInt8(truncatingIfNeeded: $0 &* 29) })

/// The same keys and signatures in every process and run, as for RSA: private keys are hashes of a label (each a
/// valid scalar), and what's randomized (ECDSA signatures, HPKE's ephemeral key) is made once and cached in the corpus
/// directory (`ecc-*`). Verification's work depends on the values, so random ones made the instruction counts vary.
enum ECCFixtures {
    static func p256Scalar(_ label: String) -> Data { Data(CryptoKit.SHA256.hash(data: Data("Bytes benchmarks \(label)".utf8))) }
    static func p384Scalar(_ label: String) -> Data { Data(CryptoKit.SHA384.hash(data: Data("Bytes benchmarks \(label)".utf8))) }

    /// A cached ECDSA signature (DER), made by `sign` once.
    static func signature(_ key: String, _ sign: () -> Data) -> [UInt8] {
        Fixtures.cached("ecc-\(key)-signature-v1.der") { Array(sign()) }
    }
}

/// P-256 keys from CryptoKit, parsed by Bytes: a signature to verify, a key agreement, and an HPKE-sealed key.
struct P256Fixture {
    let message = eccMessage
    let data = Data(eccMessage)
    let signature: CryptoKit.P256.Signing.ECDSASignature
    let cryptoKitKey: CryptoKit.P256.Signing.PublicKey
    let key: BytesCrypto.P256.PublicKey
    let parsed: BytesCrypto.P256.Signature
    let der: [UInt8]
    let pem: String
    let mine = try! CryptoKit.P256.KeyAgreement.PrivateKey(rawRepresentation: ECCFixtures.p256Scalar("p256 mine"))
    let theirs = try! CryptoKit.P256.KeyAgreement.PrivateKey(rawRepresentation: ECCFixtures.p256Scalar("p256 theirs")).publicKey
    let privateKey: BytesCrypto.P256.PrivateKey
    let peer: BytesCrypto.P256.PublicKey
    let suite = CryptoKit.HPKE.Ciphersuite(kem: .P256_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
    let sealed: [UInt8]
    let enc: [UInt8]
    let empty: [UInt8] = []
    let encData: Data
    let sealedData: Data

    init() {
        let message = eccMessage
        let signer = try! CryptoKit.P256.Signing.PrivateKey(rawRepresentation: ECCFixtures.p256Scalar("p256 signing"))
        signature = try! CryptoKit.P256.Signing.ECDSASignature(
            derRepresentation: ECCFixtures.signature("p256") { try! signer.signature(for: Data(message)).derRepresentation }
        )
        cryptoKitKey = signer.publicKey
        pem = cryptoKitKey.pemRepresentation
        key = try! BytesCrypto.P256.PublicKey(x963Representation: Array(cryptoKitKey.x963Representation).span.bytes)
        parsed = try! BytesCrypto.P256.Signature(derRepresentation: Array(signature.derRepresentation).span.bytes)
        precondition(key.isValidSignature(parsed, for: message.span.bytes))
        precondition(try! BytesCrypto.P256.PublicKey(pemRepresentation: pem).x963Representation == key.x963Representation)
        der = Array(signature.derRepresentation)

        privateKey = try! BytesCrypto.P256.PrivateKey(rawRepresentation: Array(mine.rawRepresentation).span.bytes)
        peer = try! BytesCrypto.P256.PublicKey(x963Representation: Array(theirs.x963Representation).span.bytes)
        let secret = privateKey.sharedSecret(with: peer)
        precondition((0..<32).map { secret[$0] } == (try! mine.sharedSecretFromKeyAgreement(with: theirs)).withUnsafeBytes { Array($0) })

        // HPKE: set up the context (decapsulate) and open one 32-byte key. The encapsulated key (65 bytes) and the
        // sealed key, cached together.
        let archiveKey = [UInt8](repeating: 0x5C, count: 32)
        let recipient = mine.publicKey, suite = suite
        let encAndSealed = Fixtures.cached("ecc-p256-hpke-v1.bin") {
            var sender = try! CryptoKit.HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: Data())
            let sealed = Array(try! sender.seal(Data(archiveKey)))
            return Array(sender.encapsulatedKey) + sealed
        }
        enc = Array(encAndSealed.prefix(65))
        sealed = Array(encAndSealed.dropFirst(65))
        encData = Data(enc)
        sealedData = Data(sealed)
        let opened = hpkeOpen(privateKey, enc, sealed, [])
        precondition((0..<32).map { opened[$0] } == archiveKey)
    }
}

/// P-384 keys from CryptoKit, parsed by Bytes: a signature to verify, and a key agreement.
struct P384Fixture {
    let message = eccMessage
    let data = Data(eccMessage)
    let signature: CryptoKit.P384.Signing.ECDSASignature
    let cryptoKitKey: CryptoKit.P384.Signing.PublicKey
    let key: BytesCrypto.P384.PublicKey
    let parsed: BytesCrypto.P384.Signature
    let mine = try! CryptoKit.P384.KeyAgreement.PrivateKey(rawRepresentation: ECCFixtures.p384Scalar("p384 mine"))
    let theirs = try! CryptoKit.P384.KeyAgreement.PrivateKey(rawRepresentation: ECCFixtures.p384Scalar("p384 theirs")).publicKey
    let privateKey: BytesCrypto.P384.PrivateKey
    let peer: BytesCrypto.P384.PublicKey

    init() {
        let message = eccMessage
        let signer = try! CryptoKit.P384.Signing.PrivateKey(rawRepresentation: ECCFixtures.p384Scalar("p384 signing"))
        signature = try! CryptoKit.P384.Signing.ECDSASignature(
            derRepresentation: ECCFixtures.signature("p384") { try! signer.signature(for: Data(message)).derRepresentation }
        )
        cryptoKitKey = signer.publicKey
        key = try! BytesCrypto.P384.PublicKey(x963Representation: Array(cryptoKitKey.x963Representation).span.bytes)
        parsed = try! BytesCrypto.P384.Signature(derRepresentation: Array(signature.derRepresentation).span.bytes)
        precondition(key.isValidSignature(parsed, for: message.span.bytes))
        privateKey = try! BytesCrypto.P384.PrivateKey(rawRepresentation: Array(mine.rawRepresentation).span.bytes)
        peer = try! BytesCrypto.P384.PublicKey(x963Representation: Array(theirs.x963Representation).span.bytes)
    }
}

func registerECCBenchmarks() {
    // P-256.
    let p256 = Lazy { P256Fixture() }
    register("ECDSA verify P-256: Bytes", p256, check: { $1 }) { f in
        f.key.isValidSignature(f.parsed, for: f.message.span.bytes)
    }
    register("ECDSA verify P-256: CryptoKit", p256, check: { $1 }) { f in
        f.cryptoKitKey.isValidSignature(f.signature, for: f.data)
    }
    // The DER signature parsed each time too, as an archive's reader does.
    register("ECDSA verify P-256 DER: Bytes", p256, check: { $1 }) { f in
        let signature = try! BytesCrypto.P256.Signature(derRepresentation: f.der.span.bytes)
        return f.key.isValidSignature(signature, for: f.message.span.bytes)
    }
    // A key from PEM ("PUBLIC KEY", SubjectPublicKeyInfo): Base64 decoded by BytesBase64, the DER parsed, the point
    // checked on the curve.
    register("PEM P-256 public key parse: Bytes", p256) { f in
        try! BytesCrypto.P256.PublicKey(pemRepresentation: f.pem)
    }
    register("PEM P-256 public key parse: CryptoKit", p256) { f in
        try! CryptoKit.P256.Signing.PublicKey(pemRepresentation: f.pem)
    }
    register("ECDH P-256: Bytes", p256) { f in
        f.privateKey.sharedSecret(with: f.peer)
    }
    register("ECDH P-256: CryptoKit", p256) { f in
        try! f.mine.sharedSecretFromKeyAgreement(with: f.theirs)
    }
    register("HPKE open P-256 AES-256-GCM 32 B: Bytes", p256) { f in
        hpkeOpen(f.privateKey, f.enc, f.sealed, f.empty)
    }
    register("HPKE open P-256 AES-256-GCM 32 B: CryptoKit", p256) { f in
        var recipient = try! CryptoKit.HPKE.Recipient(privateKey: f.mine, ciphersuite: f.suite, info: Data(), encapsulatedKey: f.encData)
        return try! recipient.open(f.sealedData)
    }

    // P-384.
    let p384 = Lazy { P384Fixture() }
    register("ECDSA verify P-384: Bytes", p384, check: { $1 }) { f in
        f.key.isValidSignature(f.parsed, for: f.message.span.bytes)
    }
    register("ECDSA verify P-384: CryptoKit", p384, check: { $1 }) { f in
        f.cryptoKitKey.isValidSignature(f.signature, for: f.data)
    }
    register("ECDH P-384: Bytes", p384) { f in
        f.privateKey.sharedSecret(with: f.peer)
    }
    register("ECDH P-384: CryptoKit", p384) { f in
        try! f.mine.sharedSecretFromKeyAgreement(with: f.theirs)
    }
}

/// Decapsulates and opens `sealed` (ciphertext ‖ tag, at most 64 bytes) in a stack buffer: no allocation.
@inline(never)
func hpkeOpen(_ key: BytesCrypto.P256.PrivateKey, _ enc: [UInt8], _ sealed: [UInt8], _ empty: [UInt8]) -> InlineArray<64, UInt8> {
    var recipient = try! BytesCrypto.HPKE.Recipient(privateKey: key, aead: .aes256GCM, info: empty.span.bytes, encapsulatedKey: enc.span.bytes)
    var buffer = InlineArray<64, UInt8>(repeating: 0)
    let count = sealed.count - 16
    var span = buffer.mutableSpan
    var bytes = MutableRawSpan(mutating: &span)
    bytes.copyBytes(from: sealed.span.bytes.extracting(first: count), toByteOffset: 0)
    var message = bytes._mutatingExtracting(0..<count)
    try! recipient.open(&message, authenticating: empty.span.bytes, tag: sealed.span.bytes.extracting(droppingFirst: count))
    return buffer
}

/// Verification, ECDH, and HPKE opening allocate nothing once keys are parsed:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:(ECDSA|ECDH|HPKE).*'
struct ECCAllocationFixture {
    let message = [UInt8](repeating: 0x61, count: 64)
    let der256: [UInt8]
    let key256: BytesCrypto.P256.PublicKey
    let der384: [UInt8]
    let key384: BytesCrypto.P384.PublicKey
    let private256: BytesCrypto.P256.PrivateKey
    let peerPoint: [UInt8]
    let private384: BytesCrypto.P384.PrivateKey
    let peer384: BytesCrypto.P384.PublicKey
    let sealed: [UInt8]
    let enc: [UInt8]
    let empty: [UInt8] = []

    /// Deterministic keys and cached signatures, as for the timed fixtures above.
    init() {
        let message = message
        let signer256 = try! CryptoKit.P256.Signing.PrivateKey(rawRepresentation: ECCFixtures.p256Scalar("gate p256 signing"))
        der256 = ECCFixtures.signature("gate-p256") { try! signer256.signature(for: Data(message)).derRepresentation }
        key256 = try! BytesCrypto.P256.PublicKey(x963Representation: Array(signer256.publicKey.x963Representation).span.bytes)
        let signer384 = try! CryptoKit.P384.Signing.PrivateKey(rawRepresentation: ECCFixtures.p384Scalar("gate p384 signing"))
        der384 = ECCFixtures.signature("gate-p384") { try! signer384.signature(for: Data(message)).derRepresentation }
        key384 = try! BytesCrypto.P384.PublicKey(x963Representation: Array(signer384.publicKey.x963Representation).span.bytes)
        let private256 = try! BytesCrypto.P256.PrivateKey(rawRepresentation: Array(ECCFixtures.p256Scalar("gate p256 mine")).span.bytes)
        self.private256 = private256
        peerPoint = try! BytesCrypto.P256.PrivateKey(rawRepresentation: Array(ECCFixtures.p256Scalar("gate p256 theirs")).span.bytes).publicKey
            .x963Representation
        private384 = try! BytesCrypto.P384.PrivateKey(rawRepresentation: Array(ECCFixtures.p384Scalar("gate p384 mine")).span.bytes)
        peer384 = try! BytesCrypto.P384.PrivateKey(rawRepresentation: Array(ECCFixtures.p384Scalar("gate p384 theirs")).span.bytes).publicKey
        let encAndSealed = Fixtures.cached("ecc-gate-p256-hpke-v1.bin") {
            var sender = BytesCrypto.HPKE.Sender(recipientKey: private256.publicKey, aead: .aes256GCM, info: [UInt8]().span.bytes)
            let sealed = sender.seal([UInt8](repeating: 0x5C, count: 32).span.bytes, authenticating: [UInt8]().span.bytes)
            return sender.encapsulatedKey + sealed
        }
        enc = Array(encAndSealed.prefix(65))
        sealed = Array(encAndSealed.dropFirst(65))
    }
}

func registerECCAllocationBenchmarks() {
    let configuration = Fixtures.allocationConfiguration
    let fixture = Lazy { ECCAllocationFixture() }
    register("Allocations:ECDSA_verify_P256", configuration: configuration, fixture, check: { $1 }) { f in
        let signature = try! BytesCrypto.P256.Signature(derRepresentation: f.der256.span.bytes)
        return f.key256.isValidSignature(signature, for: f.message.span.bytes)
    }
    register("Allocations:ECDSA_verify_P384", configuration: configuration, fixture, check: { $1 }) { f in
        let signature = try! BytesCrypto.P384.Signature(derRepresentation: f.der384.span.bytes)
        return f.key384.isValidSignature(signature, for: f.message.span.bytes)
    }
    register("Allocations:ECDH_P256", configuration: configuration, fixture) { f in
        // The peer's key parsed each time, as a protocol receives it.
        let peer = try! BytesCrypto.P256.PublicKey(x963Representation: f.peerPoint.span.bytes)
        return f.private256.sharedSecret(with: peer)
    }
    register("Allocations:ECDH_P384", configuration: configuration, fixture) { f in
        f.private384.sharedSecret(with: f.peer384)
    }
    register("Allocations:HPKE_open_P256", configuration: configuration, fixture) { f in
        hpkeOpen(f.private256, f.enc, f.sealed, f.empty)
    }
}
