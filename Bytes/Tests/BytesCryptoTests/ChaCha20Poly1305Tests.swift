import Bytes
import BytesCrypto
import BytesTestSupport
import CryptoKit
import Foundation
import Testing

func randomBytes(_ count: Int, using rng: inout SplitMix64) -> [UInt8] {
    rng.bytes(count)
}

/// Seals with Bytes, in place: ciphertext and tag.
func bytesSeal(_ plaintext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) -> (ciphertext: [UInt8], tag: [UInt8]) {
    let aead = ChaCha20Poly1305(key: key.span.bytes)
    var message = plaintext
    var span = message.mutableSpan
    var raw = MutableRawSpan(mutating: &span)
    let tag = aead.seal(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes)
    return (message, (0..<16).map { tag[$0] })
}

@Suite struct ChaCha20Poly1305Tests {
    /// Against CryptoKit's ChaChaPoly: same ciphertext and tag, for every length up to 600 and a few large.
    @Test func matchesCryptoKit() throws {
        var rng = SplitMix64(seed: 11)
        for length in Array(0...600) + [1023, 1024, 1025, 4096, 65_537, 1 << 20] {
            let key = randomBytes(32, using: &rng)
            let nonce = randomBytes(12, using: &rng)
            let aad = randomBytes(Int.random(in: 0...40, using: &rng), using: &rng)
            let plaintext = randomBytes(length, using: &rng)
            let reference = try ChaChaPoly.seal(
                Data(plaintext), using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce), authenticating: Data(aad)
            )
            let ours = bytesSeal(plaintext, key: key, nonce: nonce, aad: aad)
            #expect(ours.ciphertext == [UInt8](reference.ciphertext), "length \(length)")
            #expect(ours.tag == [UInt8](reference.tag), "length \(length)")

            // And back, rejecting a forged tag.
            let aead = ChaCha20Poly1305(key: key.span.bytes)
            var message = ours.ciphertext
            var forged = ours.tag
            forged[Int.random(in: 0..<16, using: &rng)] ^= 1
            do {
                var span = message.mutableSpan
                var raw = MutableRawSpan(mutating: &span)
                #expect(throws: BytesError.mismatch) {
                    try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: forged.span.bytes)
                }
                try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: ours.tag.span.bytes)
            }
            #expect(message == plaintext)
        }
    }

    /// Empty plaintext, empty associated data, or both (only the tag is left): CryptoKit's results, and opening back,
    /// forged tags rejected.
    @Test func emptyPlaintextAndAAD() throws {
        var rng = SplitMix64(seed: 0xE0)
        let key = randomBytes(32, using: &rng), nonce = randomBytes(12, using: &rng)
        let aead = ChaCha20Poly1305(key: key.span.bytes)
        for (plaintext, aad) in [([UInt8](), [UInt8]()), ([], randomBytes(13, using: &rng)), (randomBytes(17, using: &rng), [])] {
            let reference = try ChaChaPoly.seal(
                Data(plaintext), using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce), authenticating: Data(aad)
            )
            let ours = bytesSeal(plaintext, key: key, nonce: nonce, aad: aad)
            let label = "\(plaintext.count)-byte plaintext, \(aad.count)-byte AAD"
            #expect(ours.ciphertext == [UInt8](reference.ciphertext), "\(label)")
            #expect(ours.tag == [UInt8](reference.tag), "\(label)")
            var message = ours.ciphertext
            var span = message.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            var forged = ours.tag
            forged[15] ^= 0x80
            #expect(throws: BytesError.mismatch, "\(label)") {
                try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: forged.span.bytes)
            }
            try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: ours.tag.span.bytes)
            #expect(message == plaintext, "\(label)")
        }
    }
}
