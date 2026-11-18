import Bytes
@testable import BytesCrypto
import CommonCrypto
import CryptoKit
import Foundation
import Testing

// SHA-1, SHA-256, HMAC, HKDF, PBKDF2, and AES: published test vectors, then differential tests against CryptoKit
// and CommonCrypto over many lengths and split points. The hardware and portable block functions are also
// compared with each other directly, so a `Portable` build isn't the only check of the portable code.

// CryptoKit has types of these names too: in this module, unqualified, they're BytesCrypto's.
typealias HashFunction = BytesCrypto.HashFunction
typealias SHA256 = BytesCrypto.SHA256
typealias HMAC<H: BytesCrypto.HashFunction> = BytesCrypto.HMAC<H>
typealias HKDF<H: BytesCrypto.HashFunction> = BytesCrypto.HKDF<H>

func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

extension InlineArray where Element == UInt8 {
    var array: [UInt8] { (0..<count).map { self[$0] } }
}

/// `bytes` hashed in pieces split at `splits`.
func hashed<H: HashFunction>(_ type: H.Type, _ bytes: [UInt8], splits: [Int]) -> [UInt8] {
    var hash = H()
    var start = 0
    for split in splits + [bytes.count] where split >= start && split <= bytes.count {
        hash.update(bytes.span.bytes.extracting(start..<split))
        start = split
    }
    var digest = [UInt8](repeating: 0, count: H.digestByteCount)
    var span = digest.mutableSpan
    var raw = MutableRawSpan(mutating: &span)
    hash.finalize(into: &raw)
    return digest
}

@Suite struct HashTests {
    @Test func publishedVectors() {
        let abc = Array("abc".utf8)
        #expect(SHA1.hash(abc.span.bytes).array == hex("a9993e364706816aba3e25717850c26c9cd0d89d"))
        #expect(SHA1.hash([UInt8]().span.bytes).array == hex("da39a3ee5e6b4b0d3255bfef95601890afd80709"))
        #expect(SHA256.hash(abc.span.bytes).array == hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        let million = [UInt8](repeating: 0x61, count: 1_000_000)
        #expect(SHA1.hash(million.span.bytes).array == hex("34aa973cd4c4daa4f61eeb2bdbad27316534016f"))
        #expect(SHA256.hash(million.span.bytes).array == hex("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"))
    }

    @Test(arguments: [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 129, 1000, 4097])
    func matchesCryptoKit(length: Int) {
        var rng = SplitMix64(state: UInt64(length))
        let bytes = randomBytes(length, using: &rng)
        let sha1 = Array(Insecure.SHA1.hash(data: bytes))
        let sha256 = Array(CryptoKit.SHA256.hash(data: bytes))
        let sha384 = Array(CryptoKit.SHA384.hash(data: bytes))
        let sha512 = Array(CryptoKit.SHA512.hash(data: bytes))
        for splits in [[], [1], [63], [64, 65], [127, 128], [length / 3, 2 * length / 3]] {
            #expect(hashed(SHA1.self, bytes, splits: splits) == sha1, "SHA-1, \(length) bytes, split at \(splits)")
            #expect(hashed(SHA256.self, bytes, splits: splits) == sha256, "SHA-256, \(length) bytes, split at \(splits)")
            #expect(hashed(BytesCrypto.SHA384.self, bytes, splits: splits) == sha384, "SHA-384, \(length) bytes, split at \(splits)")
            #expect(hashed(BytesCrypto.SHA512.self, bytes, splits: splits) == sha512, "SHA-512, \(length) bytes, split at \(splits)")
        }
    }

    @Test func portableBlockFunctionsMatch() {
        var rng = SplitMix64(state: 9)
        let blocks = randomBytes(64 * 33, using: &rng)
        var hardware1 = SHA1().state, portable1 = SHA1().state
        SHA1.compress(&hardware1, blocks: blocks.span.bytes)
        SHA1.compressPortably(&portable1, blocks: blocks.span.bytes)
        #expect(hardware1 == portable1)
        var hardware256 = SHA256().state, portable256 = SHA256().state
        SHA256.compress(&hardware256, blocks: blocks.span.bytes)
        SHA256.compressPortably(&portable256, blocks: blocks.span.bytes)
        #expect(hardware256 == portable256)
    }
}

extension InlineArray: @retroactive Equatable where Element: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { (0..<count).allSatisfy { lhs[$0] == rhs[$0] } }
}

@Suite struct KeyDerivationTests {
    @Test(arguments: [0, 1, 20, 63, 64, 65, 200])
    func hmacMatchesCryptoKit(keyLength: Int) {
        var rng = SplitMix64(state: UInt64(keyLength) &+ 100)
        let key = randomBytes(keyLength, using: &rng)
        let message = randomBytes(300, using: &rng)
        var sha1 = HMAC<SHA1>(key: key.span.bytes)
        sha1.update(message.span.bytes.extracting(0..<100))
        sha1.update(message.span.bytes.extracting(100...))
        #expect(sha1.finalize() == Array(CryptoKit.HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key))))
        var sha256 = HMAC<SHA256>(key: key.span.bytes)
        sha256.update(message.span.bytes)
        #expect(sha256.finalize() == Array(CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))))
        var sha384 = HMAC<BytesCrypto.SHA384>(key: key.span.bytes)
        sha384.update(message.span.bytes)
        #expect(sha384.finalize() == Array(CryptoKit.HMAC<CryptoKit.SHA384>.authenticationCode(for: message, using: SymmetricKey(data: key))))
    }

    /// RFC 6070's PBKDF2-HMAC-SHA1 vectors, and CommonCrypto for WinZip's sizes.
    @Test func pbkdf2() {
        func derive(_ password: [UInt8], _ salt: [UInt8], _ iterations: Int, _ count: Int) -> [UInt8] {
            var key = [UInt8](repeating: 0, count: count)
            var span = key.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            PBKDF2.deriveKey(SHA1.self, password: password.span.bytes, salt: salt.span.bytes, iterations: iterations, into: &raw)
            return key
        }
        #expect(derive(Array("password".utf8), Array("salt".utf8), 1, 20) == hex("0c60c80f961f0e71f3a9b524af6012062fe037a6"))
        #expect(derive(Array("password".utf8), Array("salt".utf8), 4096, 20) == hex("4b007901b765489abead49d926f721d065a429c1"))
        #expect(derive(Array("passwordPASSWORDpassword".utf8), Array("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8), 4096, 25)
            == hex("3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038"))

        var rng = SplitMix64(state: 7)
        for (keyBits, password) in [(128, "secret"), (192, "a longer pass phrase"), (256, "")] {
            let salt = randomBytes(keyBits / 16, using: &rng)
            let count = 2 * keyBits / 8 + 2
            var expected = [UInt8](repeating: 0, count: count)
            let utf8 = Array(password.utf8)
            // Unsafe: CommonCrypto's pointers and lengths, each describing an array valid for the call.
            let status = utf8.withUnsafeBytes { p in salt.withUnsafeBytes { s in expected.withUnsafeMutableBytes { e in
                unsafe CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), p.count,
                                            s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count,
                                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                                            e.baseAddress?.assumingMemoryBound(to: UInt8.self), e.count)
            } } }
            #expect(status == kCCSuccess)
            #expect(derive(utf8, salt, 1000, count) == expected, "\(keyBits)-bit")
        }
    }

    /// RFC 5869's first test case.
    @Test func hkdf() {
        let ikm = [UInt8](repeating: 0x0B, count: 22)
        let salt = hex("000102030405060708090a0b0c")
        let info = hex("f0f1f2f3f4f5f6f7f8f9")
        var prk = [UInt8](repeating: 0, count: 32)
        var prkSpan = prk.mutableSpan
        var prkRaw = MutableRawSpan(mutating: &prkSpan)
        HKDF<SHA256>.extract(salt: salt.span.bytes, inputKeyMaterial: ikm.span.bytes, into: &prkRaw)
        #expect(prk == hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"))
        var okm = [UInt8](repeating: 0, count: 42)
        var okmSpan = okm.mutableSpan
        var okmRaw = MutableRawSpan(mutating: &okmSpan)
        HKDF<SHA256>.expand(pseudorandomKey: prk.span.bytes, info: info.span.bytes, into: &okmRaw)
        #expect(okm == hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))
    }
}

@Suite struct AESTests {
    /// FIPS 197, appendix C.
    @Test func publishedVectors() {
        let plaintext = hex("00112233445566778899aabbccddeeff")
        let block = SIMD16<UInt8>((0..<16).map { plaintext[$0] })
        for (key, expected) in [
            ("000102030405060708090a0b0c0d0e0f", "69c4e0d86a7b0430d8cdb78070b4c55a"),
            ("000102030405060708090a0b0c0d0e0f1011121314151617", "dda97ca4864cdfe06eaf70a0ec0d7191"),
            ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "8ea2b7ca516745bfeafc49904b496089"),
        ] {
            let aes = AES(key: hex(key).span.bytes)
            let ciphertext = aes.encrypt(block)
            #expect((0..<16).map { ciphertext[$0] } == hex(expected), "\(key.count * 4)-bit key")
            let portable = aes.encryptPortably(block)
            #expect((0..<16).map { portable[$0] } == hex(expected), "\(key.count * 4)-bit key, portable")
        }
    }

    /// CommonCrypto's AES-ECB of each counter block, as the reference for both counter layouts.
    static func referenceKeystream(key: [UInt8], counterBlocks: [[UInt8]]) -> [UInt8] {
        let input = counterBlocks.flatMap { $0 }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        // Unsafe: CommonCrypto's pointers and lengths, each describing an array valid for the call.
        let status = key.withUnsafeBytes { k in input.withUnsafeBytes { i in output.withUnsafeMutableBytes { o in
            unsafe CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                           k.baseAddress, k.count, nil, i.baseAddress, i.count, o.baseAddress, o.count, &moved)
        } } }
        precondition(status == kCCSuccess)
        return output
    }

    @Test(arguments: [16, 24, 32])
    func counterModeInPieces(keyLength: Int) {
        var rng = SplitMix64(state: UInt64(keyLength))
        let key = randomBytes(keyLength, using: &rng)
        let message = randomBytes(1000, using: &rng)
        let aes = AES(key: key.span.bytes)
        let blockCount = (message.count + 15) / 16

        // WinZip: a 128-bit little-endian counter from 1.
        let wide = (0..<blockCount).map { index -> [UInt8] in
            (0..<16).map { byte in byte < 8 ? UInt8(truncatingIfNeeded: UInt64(index + 1) >> (8 * byte)) : 0 }
        }
        let wideStream = Self.referenceKeystream(key: key, counterBlocks: wide)
        // GCM: twelve fixed bytes, then a 32-bit big-endian counter from 2 (crossing a carry into byte 14).
        let start = randomBytes(12, using: &rng) + [0, 0, 0xFF, 0xFE]
        let narrow = (0..<blockCount).map { index -> [UInt8] in
            let value = UInt32(0xFFFE) &+ UInt32(index)
            return Array(start.prefix(12)) + [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
        let narrowStream = Self.referenceKeystream(key: key, counterBlocks: narrow)

        for splits in [[], [1], [15, 16, 17], [128, 129], [300, 777], Array(stride(from: 7, to: 1000, by: 7))] {
            for (stream, wideCounter) in [(wideStream, true), (narrowStream, false)] {
                var counter = wideCounter ? AES.Counter(littleEndianFrom: 1) : AES.Counter(bigEndianCounterIn: start.span.bytes)
                var output = [UInt8](repeating: 0, count: message.count)
                var begin = 0
                for split in splits + [message.count] where split >= begin {
                    var span = output.mutableSpan
                    var raw = MutableRawSpan(mutating: &span)
                    var piece = raw._mutatingExtracting(begin..<split)
                    aes.counterMode(message.span.bytes.extracting(begin..<split), into: &piece, counter: &counter)
                    begin = split
                }
                let expected = (0..<message.count).map { message[$0] ^ stream[$0] }
                #expect(output == expected, "\(wideCounter ? "little-endian" : "big-endian") counter, split at \(splits.prefix(5))")
            }
        }
    }
}
