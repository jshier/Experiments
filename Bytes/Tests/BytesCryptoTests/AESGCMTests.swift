import Bytes
import BytesCrypto
import BytesTestSupport
import CryptoKit
import Foundation
import Testing

// AES-GCM: the test cases of McGrew and Viega's GCM specification, CryptoKit for every length up to a few
// blocks of eight, forged and truncated messages, and the hardware GHASH multiply against the bit-serial one.

@Suite struct AESGCMTests {
    func seal(_ key: [UInt8], _ nonce: [UInt8], _ plaintext: [UInt8], _ aad: [UInt8]) -> (ciphertext: [UInt8], tag: [UInt8]) {
        let aead = AESGCM(key: key.span.bytes)
        var message = plaintext
        var span = message.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        let tag = aead.seal(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes)
        return (message, tag.array)
    }

    /// The GCM specification's test cases 2, 3, 4, and 16.
    @Test func specificationVectors() {
        let zero = [UInt8](repeating: 0, count: 16)
        let case2 = seal(zero, [UInt8](repeating: 0, count: 12), zero, [])
        #expect(case2.ciphertext == hex("0388dace60b6a392f328c2b971b2fe78"))
        #expect(case2.tag == hex("ab6e47d42cec13bdf53a67b21257bddf"))

        let key = hex("feffe9928665731c6d6a8f9467308308")
        let nonce = hex("cafebabefacedbaddecaf888")
        let plaintext = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255")
        let case3 = seal(key, nonce, plaintext, [])
        #expect(case3.ciphertext == hex("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985"))
        #expect(case3.tag == hex("4d5c2af327cd64a62cf35abd2ba6fab4"))

        let aad = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        let case4 = seal(key, nonce, Array(plaintext.prefix(60)), aad)
        #expect(case4.ciphertext == hex("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091"))
        #expect(case4.tag == hex("5bc94fbc3221a5db94fae95ae7121a47"))

        let case16 = seal(key + key, nonce, Array(plaintext.prefix(60)), aad)
        #expect(case16.ciphertext == hex("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662"))
        #expect(case16.tag == hex("76fc6ece0f4e1768cddf8853bb2d551b"))
    }

    /// Empty plaintext, empty associated data, or both (the tag alone authenticates): the specification's test case 1,
    /// CryptoKit for each key length, and opening back, forged tags rejected.
    @Test(arguments: [16, 32])
    func emptyPlaintextAndAAD(keyLength: Int) throws {
        if keyLength == 16 {
            let case1 = seal([UInt8](repeating: 0, count: 16), [UInt8](repeating: 0, count: 12), [], [])
            #expect(case1.ciphertext.isEmpty)
            #expect(case1.tag == hex("58e2fccefa7e3061367f1d57a4e7455a"))
        }
        var rng = SplitMix64(seed: 0xE0 &+ UInt64(keyLength))
        let key = rng.bytes(keyLength), nonce = rng.bytes(12)
        let aead = AESGCM(key: key.span.bytes)
        for (plaintext, aad) in [([UInt8](), [UInt8]()), ([], rng.bytes(13)), (rng.bytes(17), [])] {
            let ours = seal(key, nonce, plaintext, aad)
            let theirs = try CryptoKit.AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: CryptoKit.AES.GCM.Nonce(data: nonce), authenticating: aad)
            let label = "\(plaintext.count)-byte plaintext, \(aad.count)-byte AAD"
            #expect(ours.ciphertext == Array(theirs.ciphertext), "\(label)")
            #expect(ours.tag == Array(theirs.tag), "\(label)")
            var message = ours.ciphertext
            var span = message.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            var forged = ours.tag
            forged[0] ^= 1
            #expect(throws: BytesError.mismatch, "\(label)") {
                try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: forged.span.bytes)
            }
            try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: ours.tag.span.bytes)
            #expect(message == plaintext, "\(label)")
        }
    }

    @Test(arguments: [16, 32])
    func matchesCryptoKit(keyLength: Int) throws {
        var rng = SplitMix64(seed: UInt64(keyLength))
        let key = rng.bytes(keyLength)
        for length in Array(0...300) + [511, 512, 513, 1023, 1024, 4097, 16_384 + 17] {
            let nonce = rng.bytes(12)
            let aad = rng.bytes(length % 37)
            let plaintext = rng.bytes(length)
            let ours = seal(key, nonce, plaintext, aad)
            let theirs = try CryptoKit.AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: CryptoKit.AES.GCM.Nonce(data: nonce), authenticating: aad)
            #expect(ours.ciphertext == Array(theirs.ciphertext), "\(length) bytes")
            #expect(ours.tag == Array(theirs.tag), "\(length) bytes")

            // And back.
            let aead = AESGCM(key: key.span.bytes)
            var message = ours.ciphertext
            var span = message.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: ours.tag.span.bytes)
            #expect(message == plaintext)
        }
    }

    @Test func rejectsForgeries() {
        var rng = SplitMix64(seed: 3)
        let key = rng.bytes(16), nonce = rng.bytes(12)
        let aad = rng.bytes(13), plaintext = rng.bytes(200)
        let sealed = seal(key, nonce, plaintext, aad)
        let aead = AESGCM(key: key.span.bytes)
        func open(_ ciphertext: [UInt8], _ aad: [UInt8], _ tag: [UInt8]) -> (Result<Void, BytesError>, [UInt8]) {
            var message = ciphertext
            var span = message.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            do throws(BytesError) {
                try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: tag.span.bytes)
                return (.success(()), message)
            } catch {
                return (.failure(error), message)
            }
        }
        for index in [0, 99, 199] {
            var altered = sealed.ciphertext
            altered[index] ^= 1
            let (result, message) = open(altered, aad, sealed.tag)
            #expect(throws: BytesError.mismatch) { _ = try result.get() }
            #expect(message == altered, "a forged message is left as it was, never decrypted")
        }
        var alteredAAD = aad
        alteredAAD[0] ^= 0x80
        #expect(throws: BytesError.mismatch) { _ = try open(sealed.ciphertext, alteredAAD, sealed.tag).0.get() }
        var alteredTag = sealed.tag
        alteredTag[15] ^= 1
        #expect(throws: BytesError.mismatch) { _ = try open(sealed.ciphertext, aad, alteredTag).0.get() }
        #expect(throws: BytesError.invalidValue) { _ = try open(sealed.ciphertext, aad, Array(sealed.tag.prefix(12))).0.get() }
    }

    // Both reductions exist only where GHASH uses PMULL (AESGCM.swift's condition).
    #if HardwareCrypto && arch(arm64) && !Portable
    @Test func vectorReductionMatchesTheScalarOne() {
        var rng = SplitMix64(seed: 21)
        for _ in 0..<2000 {
            let low = SIMD2(rng.next(), rng.next()), middle = SIMD2(rng.next(), rng.next()), high = SIMD2(rng.next(), rng.next())
            #expect(AESGCM.reduceInVectors(low: low, middle: middle, high: high) == AESGCM.reduce(low: low, middle: middle, high: high))
        }
    }
    #endif

    @Test func multiplicationMatchesTheBitSerialForm() {
        var rng = SplitMix64(seed: 12)
        for _ in 0..<500 {
            let x = FieldElement(low: rng.next(), high: rng.next()), y = FieldElement(low: rng.next(), high: rng.next())
            #expect(AESGCM.multiply(x, y) == FieldElement.multiplyPortably(x, y))
        }
        // The identity: 1 is the block 0x80, 0, …, 0 (the coefficient of x⁰ is the first bit).
        let one = FieldElement(low: 0, high: 1 << 63)
        let x = FieldElement(low: rng.next(), high: rng.next())
        #expect(AESGCM.multiply(x, one) == x && FieldElement.multiplyPortably(one, x) == x)
    }
}
