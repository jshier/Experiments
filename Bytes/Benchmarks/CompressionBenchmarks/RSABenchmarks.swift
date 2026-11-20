import Benchmark
import Bytes
import BytesCrypto
import BytesTestSupport
import Foundation
import Security

// RSA PKCS #1 v1.5 verification against Security (`SecKeyVerifySignature`, corecrypto underneath): 2048- and 4096-bit
// keys (e = 65537) from `SecKeyCreateRandomKey`, a 64-byte message hashed with SHA-256 in both. One verification per
// iteration, keys made beforehand; key parsing (with its precomputation) separately, and both together, as a
// certificate chain or an archive's signature uses each key once. Allocation counts below.
//
// Security's public key is made from the PKCS #1 DER (`SecKeyCreateWithData`), as a client reading a certificate
// makes it: the key `SecKeyCopyPublicKey` returns for a generated private key verified 7x slower (150 µs at 2048 bits
// against 22, measured separately).

/// An RSA key pair from Security: the private key, and the public key made from its PKCS #1 DER. Generated once and
/// cached in the corpus directory (`rsa-BITS.der`, the private key's PKCS #1 DER): a 4096-bit key takes seconds to
/// generate, and each benchmark using it runs in a process of its own.
func securityRSAKeyPair(bits: Int) -> (privateKey: SecKey, publicKey: SecKey, pkcs1: [UInt8]) {
    let privateDER = Fixtures.cached("rsa-\(bits).der") {
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits] as CFDictionary
        return [UInt8](SecKeyCopyExternalRepresentation(SecKeyCreateRandomKey(attributes, nil)!, nil)! as Data)
    }
    let privateAttributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
    let privateKey = SecKeyCreateWithData(Data(privateDER) as CFData, privateAttributes, nil)!
    let pkcs1 = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data)
    let publicKey = SecKeyCreateWithData(Data(pkcs1) as CFData, rsaPublicKeyAttributes(), nil)!
    return (privateKey, publicKey, pkcs1)
}

/// The attributes of an RSA public key for `SecKeyCreateWithData`.
func rsaPublicKeyAttributes() -> CFDictionary {
    [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
}

/// A key pair, a message's signature, and the forms each library takes them in.
struct RSAFixture {
    let message: [UInt8]
    let data: Data
    let publicKey: SecKey
    let pkcs1: [UInt8]
    let signature: [UInt8]
    let signatureData: CFData
    let key: RSA.PublicKey
    let pkcs1Data: CFData
    let keyAttributes = rsaPublicKeyAttributes()

    init(bits: Int, message: [UInt8] = (0..<64).map { UInt8(truncatingIfNeeded: $0 &* 29) }) {
        self.message = message
        data = Data(message)
        let (privateKey, publicKey, pkcs1) = securityRSAKeyPair(bits: bits)
        let signature = [UInt8](SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, nil)! as Data)
        let key = try! RSA.PublicKey(derRepresentation: pkcs1.span.bytes)
        precondition(key.isValidSignature(signature.span.bytes, for: message.span.bytes, digestAlgorithm: .sha256))
        self.publicKey = publicKey
        self.pkcs1 = pkcs1
        self.signature = signature
        self.key = key
        signatureData = Data(signature) as CFData
        pkcs1Data = Data(pkcs1) as CFData
        precondition(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signatureData, nil))
    }
}

func registerRSABenchmarks() {
    for bits in [2048, 4096] {
        let fixture = Lazy { RSAFixture(bits: bits) }
        register("RSA verify \(bits) SHA-256: Bytes", fixture, check: { $1 }) { f in
            f.key.isValidSignature(f.signature.span.bytes, for: f.message.span.bytes, digestAlgorithm: .sha256)
        }
        register("RSA verify \(bits) SHA-256: Security", fixture, check: { $1 }) { f in
            SecKeyVerifySignature(f.publicKey, .rsaSignatureMessagePKCS1v15SHA256, f.data as CFData, f.signatureData, nil)
        }
        // Making the key: parsing, and Bytes' precomputation (−n⁻¹ mod 2⁶⁴, R^e mod n), as a certificate chain does
        // for each issuer.
        register("RSA public key \(bits) parse: Bytes", fixture) { f in
            try! RSA.PublicKey(derRepresentation: f.pkcs1.span.bytes)
        }
        register("RSA public key \(bits) parse: Security", fixture) { f in
            SecKeyCreateWithData(f.pkcs1Data, f.keyAttributes, nil)
        }
        register("RSA parse and verify \(bits) SHA-256: Bytes", fixture, check: { $1 }) { f in
            let key = try! RSA.PublicKey(derRepresentation: f.pkcs1.span.bytes)
            return key.isValidSignature(f.signature.span.bytes, for: f.message.span.bytes, digestAlgorithm: .sha256)
        }
        register("RSA parse and verify \(bits) SHA-256: Security", fixture, check: { $1 }) { f in
            let key = SecKeyCreateWithData(f.pkcs1Data, f.keyAttributes, nil)!
            return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, f.data as CFData, f.signatureData, nil)
        }
    }
}

/// Verification allocates nothing once the key is made:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:RSA.*'
func registerRSAAllocationBenchmarks() {
    let configuration = Fixtures.allocationConfiguration
    let fixture = Lazy { RSAFixture(bits: 2048, message: [UInt8](repeating: 0x61, count: 64)) }
    register("Allocations:RSA_verify_2048", configuration: configuration, fixture, check: { $1 }) { f in
        f.key.isValidSignature(f.signature.span.bytes, for: f.message.span.bytes, digestAlgorithm: .sha256)
    }
    register("Allocations:RSA_public_key_2048_parse", configuration: configuration, fixture) { f in
        try! RSA.PublicKey(derRepresentation: f.pkcs1.span.bytes)
    }
}
