import Benchmark
import Bytes
import BytesCrypto
import CommonCrypto
import CryptoKit
import Foundation

// BytesCrypto's primitives against Apple's: SHA-1 and SHA-256 (CryptoKit), HMAC-SHA1 (CryptoKit), AES-128 in
// counter mode (CommonCrypto), and PBKDF2-HMAC-SHA1 with WinZip's 1,000 iterations (CommonCrypto). 1 MB per
// iteration for the bulk ones.

func registerPrimitiveBenchmarks() {
    let size = 1 << 20
    let message = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let data = Data(message)
    let key = [UInt8](repeating: 0x42, count: 16)

    Benchmark("SHA-1 1 MB: Bytes") { benchmark in
        for _ in benchmark.scaledIterations { blackHole(SHA1.hash(message.span.bytes)) }
    }
    Benchmark("SHA-1 1 MB: CryptoKit") { benchmark in
        for _ in benchmark.scaledIterations { blackHole(Insecure.SHA1.hash(data: data)) }
    }
    Benchmark("SHA-256 1 MB: Bytes") { benchmark in
        for _ in benchmark.scaledIterations { blackHole(BytesCrypto.SHA256.hash(message.span.bytes)) }
    }
    Benchmark("SHA-256 1 MB: CryptoKit") { benchmark in
        for _ in benchmark.scaledIterations { blackHole(CryptoKit.SHA256.hash(data: data)) }
    }
    Benchmark("HMAC-SHA1 1 MB: Bytes") { benchmark in
        let mac = BytesCrypto.HMAC<SHA1>(key: key.span.bytes)
        for _ in benchmark.scaledIterations {
            var copy = mac
            copy.update(message.span.bytes)
            var tag = InlineArray<20, UInt8>(repeating: 0)
            var span = tag.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            copy.finalize(into: &raw)
            blackHole(tag[0])
        }
    }
    Benchmark("HMAC-SHA1 1 MB: CryptoKit") { benchmark in
        let symmetric = SymmetricKey(data: key)
        for _ in benchmark.scaledIterations {
            blackHole(CryptoKit.HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetric))
        }
    }

    let aes = BytesCrypto.AES(key: key.span.bytes)
    var output = [UInt8](repeating: 0, count: size)
    Benchmark("AES-128-CTR 1 MB: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            var counter = BytesCrypto.AES.Counter(littleEndianFrom: 1)
            var span = output.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            aes.counterMode(message.span.bytes, into: &raw, counter: &counter)
        }
        blackHole(output[0])
    }
    Benchmark("AES-128-CTR 1 MB: CommonCrypto") { benchmark in
        let iv = [UInt8](repeating: 0, count: 16)
        for _ in benchmark.scaledIterations {
            var cryptor: CCCryptorRef?
            // CommonCrypto's pointers and lengths, each describing an array valid for the call.
            _ = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                               CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            var moved = 0
            _ = message.withUnsafeBytes { input in output.withUnsafeMutableBytes { out in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count, out.baseAddress, out.count, &moved)
            } }
            CCCryptorRelease(cryptor)
        }
        blackHole(output[0])
    }

    let password = Array("correct horse battery staple".utf8)
    let salt = [UInt8](repeating: 9, count: 16)
    Benchmark("PBKDF2-HMAC-SHA1 x1000, 34 bytes: Bytes") { benchmark in
        var derived = [UInt8](repeating: 0, count: 34)
        for _ in benchmark.scaledIterations {
            var span = derived.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            PBKDF2.deriveKey(SHA1.self, password: password.span.bytes, salt: salt.span.bytes, iterations: 1000, into: &raw)
        }
        blackHole(derived[0])
    }
    Benchmark("PBKDF2-HMAC-SHA1 x1000, 34 bytes: CommonCrypto") { benchmark in
        var derived = [UInt8](repeating: 0, count: 34)
        for _ in benchmark.scaledIterations {
            // Unsafe: CommonCrypto's pointers and lengths, each describing an array valid for the call.
            _ = password.withUnsafeBytes { p in salt.withUnsafeBytes { s in derived.withUnsafeMutableBytes { d in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), p.count,
                                            s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count,
                                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                                            d.baseAddress?.assumingMemoryBound(to: UInt8.self), d.count)
            } } }
        }
        blackHole(derived[0])
    }
}
