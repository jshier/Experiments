import Benchmark
import Bytes
import BytesCrypto
import BytesTestSupport
import CommonCrypto
import CryptoKit
import Foundation

// BytesCrypto's primitives against Apple's: SHA-1, SHA-256, and SHA-512 (CryptoKit), HMAC-SHA1 and HMAC-SHA256
// (CryptoKit), HKDF-SHA256 (CryptoKit), AES-128 and AES-256 in counter mode (CommonCrypto), and PBKDF2-HMAC-SHA1 with
// WinZip's 1,000 iterations (CommonCrypto). 1 MB per iteration for the bulk ones; 64-byte messages 16,384 times (1 MB
// too), where per-call costs show.

/// 1 MB of input, a 64-byte message, and the keys.
struct PrimitiveFixture {
    let message = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let data: Data
    let small = (0..<64).map { UInt8(truncatingIfNeeded: $0 &* 13) }
    let smallData: Data
    let key = [UInt8](repeating: 0x42, count: 16)
    let key256 = [UInt8](repeating: 0x24, count: 32)
    let aes: BytesCrypto.AES
    let aes256: BytesCrypto.AES
    let password = Array("correct horse battery staple".utf8)
    let salt = [UInt8](repeating: 9, count: 16)
    let info = Array("tls13 key".utf8)

    init() {
        data = Data(message)
        smallData = Data(small)
        let key = key, key256 = key256
        aes = BytesCrypto.AES(key: key.span.bytes)
        aes256 = BytesCrypto.AES(key: key256.span.bytes)
    }
}

/// `body`'s 32-byte result in a stack buffer.
@inline(__always)
func into32(_ body: (inout MutableRawSpan) -> Void) -> InlineArray<32, UInt8> {
    var result = InlineArray<32, UInt8>(repeating: 0)
    var span = result.mutableSpan
    var raw = MutableRawSpan(mutating: &span)
    body(&raw)
    return result
}

/// HKDF-SHA256 extract, then expand to 32 bytes: a TLS-style derivation of one key from a shared secret.
@inline(__always)
func hkdfSHA256(salt: [UInt8], secret: [UInt8], info: [UInt8]) -> InlineArray<32, UInt8> {
    let prk = into32 { BytesCrypto.HKDF<BytesCrypto.SHA256>.extract(salt: salt.span.bytes, inputKeyMaterial: secret.span.bytes, into: &$0) }
    return into32 { BytesCrypto.HKDF<BytesCrypto.SHA256>.expand(pseudorandomKey: prk.span.bytes, info: info.span.bytes, into: &$0) }
}

func registerPrimitiveBenchmarks() {
    let fixture = Lazy { PrimitiveFixture() }

    register("SHA-1 1 MB: Bytes", fixture) { f in SHA1.hash(f.message.span.bytes) }
    register("SHA-1 1 MB: CryptoKit", fixture) { f in Insecure.SHA1.hash(data: f.data) }
    register("SHA-256 1 MB: Bytes", fixture) { f in BytesCrypto.SHA256.hash(f.message.span.bytes) }
    register("SHA-256 1 MB: CryptoKit", fixture) { f in CryptoKit.SHA256.hash(data: f.data) }
    let sha512Matches = { (f: PrimitiveFixture, digest: InlineArray<64, UInt8>) in
        (0..<64).map { digest[$0] } == Array(CryptoKit.SHA512.hash(data: f.data))
    }
    register("SHA-512 1 MB: Bytes", fixture, check: sha512Matches) { f in
        var hash = BytesCrypto.SHA512()
        hash.update(f.message.span.bytes)
        var digest = InlineArray<64, UInt8>(repeating: 0)
        var span = digest.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        hash.finalize(into: &raw)
        return digest
    }
    register("SHA-512 1 MB: CryptoKit", fixture) { f in CryptoKit.SHA512.hash(data: f.data) }
    // 64-byte messages: a block and the padding block each.
    register("SHA-256 64 B (x16384): Bytes", fixture, check: { f, digest in
        (0..<32).map { digest[$0] } == Array(CryptoKit.SHA256.hash(data: f.smallData))
    }) { f in
        var digest = InlineArray<32, UInt8>(repeating: 0)
        for _ in 0..<16_384 {
            digest = BytesCrypto.SHA256.hash(f.small.span.bytes)
        }
        return digest
    }
    register("SHA-256 64 B (x16384): CryptoKit", fixture) { f in
        var last: CryptoKit.SHA256.Digest?
        for _ in 0..<16_384 {
            last = CryptoKit.SHA256.hash(data: f.smallData)
        }
        return last
    }
    let hmacMatches = { (message: Data) in
        { (f: PrimitiveFixture, mac: InlineArray<32, UInt8>) in
            (0..<32).map { mac[$0] } == Array(CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: message, using: SymmetricKey(data: f.key)))
        }
    }
    register("HMAC-SHA256 1 MB: Bytes", fixture, check: { hmacMatches($0.data)($0, $1) }) { f in
        into32 { BytesCrypto.HMAC<BytesCrypto.SHA256>.authenticationCode(for: f.message.span.bytes, key: f.key.span.bytes, into: &$0) }
    }
    register("HMAC-SHA256 1 MB: CryptoKit", fixture) { f in
        CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: f.data, using: SymmetricKey(data: f.key))
    }
    // The key's pads hashed per message too, as a protocol authenticating records with a fresh `HMAC` does.
    register("HMAC-SHA256 64 B (x16384): Bytes", fixture, check: { hmacMatches($0.smallData)($0, $1) }) { f in
        var mac = InlineArray<32, UInt8>(repeating: 0)
        for _ in 0..<16_384 {
            mac = into32 { BytesCrypto.HMAC<BytesCrypto.SHA256>.authenticationCode(for: f.small.span.bytes, key: f.key.span.bytes, into: &$0) }
        }
        return mac
    }
    register("HMAC-SHA256 64 B (x16384): CryptoKit", fixture) { f in
        let key = SymmetricKey(data: f.key)
        var last: CryptoKit.HMAC<CryptoKit.SHA256>.MAC?
        for _ in 0..<16_384 {
            last = CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: f.smallData, using: key)
        }
        return last
    }
    // Extract and expand to one 32-byte key, from a 32-byte secret: 1,000 per iteration.
    register("HKDF-SHA256 32 B (x1000): Bytes", fixture, check: { (f: PrimitiveFixture, key: InlineArray<32, UInt8>) in
        let reference = CryptoKit.HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: f.key256), salt: f.salt, info: f.info, outputByteCount: 32
        )
        return (0..<32).map { key[$0] } == reference.withUnsafeBytes { Array($0) }
    }) { f in
        var key = InlineArray<32, UInt8>(repeating: 0)
        for _ in 0..<1_000 {
            key = hkdfSHA256(salt: f.salt, secret: f.key256, info: f.info)
        }
        return key
    }
    register("HKDF-SHA256 32 B (x1000): CryptoKit", fixture) { f in
        let secret = SymmetricKey(data: f.key256)
        var last: SymmetricKey?
        for _ in 0..<1_000 {
            last = CryptoKit.HKDF<CryptoKit.SHA256>.deriveKey(inputKeyMaterial: secret, salt: f.salt, info: f.info, outputByteCount: 32)
        }
        return last
    }
    Benchmark("HMAC-SHA1 1 MB: Bytes") { benchmark in
        let f = fixture.value
        let mac = BytesCrypto.HMAC<SHA1>(key: f.key.span.bytes)
        for _ in benchmark.scaledIterations {
            var copy = mac
            copy.update(f.message.span.bytes)
            var tag = InlineArray<20, UInt8>(repeating: 0)
            var span = tag.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            copy.finalize(into: &raw)
            blackHole(tag[0])
        }
    } setup: { _ = fixture.value }
    Benchmark("HMAC-SHA1 1 MB: CryptoKit") { benchmark in
        let f = fixture.value
        let symmetric = SymmetricKey(data: f.key)
        for _ in benchmark.scaledIterations {
            blackHole(CryptoKit.HMAC<Insecure.SHA1>.authenticationCode(for: f.data, using: symmetric))
        }
    } setup: { _ = fixture.value }

    // Made by setup.
    var output: [UInt8] = []
    for (bits, key) in [(128, \PrimitiveFixture.key), (256, \PrimitiveFixture.key256)] {
        let aes = bits == 128 ? \PrimitiveFixture.aes : \PrimitiveFixture.aes256
        Benchmark("AES-\(bits)-CTR 1 MB: Bytes") { benchmark in
            let f = fixture.value
            let cipher = f[keyPath: aes]
            for _ in benchmark.scaledIterations {
                var counter = BytesCrypto.AES.Counter(littleEndianFrom: 1)
                var span = output.mutableSpan
                var raw = MutableRawSpan(mutating: &span)
                cipher.counterMode(f.message.span.bytes, into: &raw, counter: &counter)
            }
            blackHole(output[0])
        } setup: { output = [UInt8](repeating: 0, count: fixture.value.message.count) }
        Benchmark("AES-\(bits)-CTR 1 MB: CommonCrypto") { benchmark in
            let f = fixture.value
            let keyBytes = f[keyPath: key]
            let iv = [UInt8](repeating: 0, count: 16)
            for _ in benchmark.scaledIterations {
                var cryptor: CCCryptorRef?
                // CommonCrypto's pointers and lengths, each describing an array valid for the call.
                _ = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                            CCPadding(ccNoPadding), iv, keyBytes, keyBytes.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
                var moved = 0
                _ = f.message.withUnsafeBytes { input in output.withUnsafeMutableBytes { out in
                    CCCryptorUpdate(cryptor, input.baseAddress, input.count, out.baseAddress, out.count, &moved)
                } }
                CCCryptorRelease(cryptor)
            }
            blackHole(output[0])
        } setup: { output = [UInt8](repeating: 0, count: fixture.value.message.count) }
    }

    // Made by setup, not in the measured closure.
    var derived: [UInt8] = []
    Benchmark("PBKDF2-HMAC-SHA1 x1000, 34 bytes: Bytes") { benchmark in
        let f = fixture.value
        for _ in benchmark.scaledIterations {
            var span = derived.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            PBKDF2.deriveKey(SHA1.self, password: f.password.span.bytes, salt: f.salt.span.bytes, iterations: 1000, into: &raw)
        }
        blackHole(derived[0])
    } setup: {
        _ = fixture.value
        derived = [UInt8](repeating: 0, count: 34)
    }
    Benchmark("PBKDF2-HMAC-SHA1 x1000, 34 bytes: CommonCrypto") { benchmark in
        let f = fixture.value
        for _ in benchmark.scaledIterations {
            // Unsafe: CommonCrypto's pointers and lengths, each describing an array valid for the call.
            _ = f.password.withUnsafeBytes { p in f.salt.withUnsafeBytes { s in derived.withUnsafeMutableBytes { d in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), p.count,
                                     s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                                     d.baseAddress?.assumingMemoryBound(to: UInt8.self), d.count)
            } } }
        }
        blackHole(derived[0])
    } setup: {
        _ = fixture.value
        derived = [UInt8](repeating: 0, count: 34)
    }
}
