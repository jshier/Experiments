import Bytes
@testable import BytesCrypto
import BytesTestSupport
import CryptoKit
import Testing

// HKDF's expander (one keyed HMAC for many outputs) against RFC 5869, `HKDF.expand`, CryptoKit, and Wycheproof; and
// TLS 1.3's HKDF-Expand-Label at its largest label and context, and its traffic keys, which share an expander.

/// `expander`'s output for `info`, `count` bytes.
func expanded<H: BytesCrypto.HashFunction>(_ expander: BytesCrypto.HKDF<H>.Expander, info: [UInt8], count: Int) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: count)
    var span = output.mutableSpan
    var raw = MutableRawSpan(mutating: &span)
    expander.expand(info: info.span.bytes, into: &raw)
    return output
}

@Suite struct HKDFExpanderTests {
    /// RFC 5869's test case 1.
    @Test func rfc5869() {
        let ikm = [UInt8](repeating: 0x0B, count: 22), salt = hex("000102030405060708090a0b0c"), info = hex("f0f1f2f3f4f5f6f7f8f9")
        let okm = hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        let prk = hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
        let extracting = HKDF<SHA256>.Expander(salt: salt.span.bytes, inputKeyMaterial: ikm.span.bytes)
        #expect(expanded(extracting, info: info, count: 42) == okm)
        let fromKey = HKDF<SHA256>.Expander(pseudorandomKey: prk.span.bytes)
        #expect(expanded(fromKey, info: info, count: 42) == okm)
    }

    /// One expander, many outputs: each the same as a fresh `HKDF.expand` and as CryptoKit's.
    func checkReuse<H: BytesCrypto.HashFunction, C: CryptoKit.HashFunction>(_ hash: H.Type, _ reference: C.Type) {
        var rng = SplitMix64(seed: UInt64(H.digestByteCount))
        let ikm = rng.bytes(40), salt = rng.bytes(H.digestByteCount)
        let expander = HKDF<H>.Expander(salt: salt.span.bytes, inputKeyMaterial: ikm.span.bytes)
        var prk = [UInt8](repeating: 0, count: H.digestByteCount)
        var prkSpan = prk.mutableSpan
        var prkRaw = MutableRawSpan(mutating: &prkSpan)
        HKDF<H>.extract(salt: salt.span.bytes, inputKeyMaterial: ikm.span.bytes, into: &prkRaw)
        for (index, count) in [0, 1, 12, 16, 32, 33, 48, 64, 65, 100, 255 * H.digestByteCount].enumerated() {
            let info = rng.bytes(index * 7)
            let output = expanded(expander, info: info, count: count)
            var fresh = [UInt8](repeating: 0, count: count)
            var freshSpan = fresh.mutableSpan
            var freshRaw = MutableRawSpan(mutating: &freshSpan)
            HKDF<H>.expand(pseudorandomKey: prk.span.bytes, info: info.span.bytes, into: &freshRaw)
            #expect(output == fresh, "\(H.self), \(count) bytes")
            guard count > 0 else { continue }
            let key = CryptoKit.HKDF<C>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: count)
            #expect(output == key.withUnsafeBytes { Array($0) }, "\(H.self), \(count) bytes, against CryptoKit")
        }
    }

    @Test func reuseMatchesFreshExpansion() {
        checkReuse(SHA256.self, CryptoKit.SHA256.self)
        checkReuse(BytesCrypto.SHA384.self, CryptoKit.SHA384.self)
        checkReuse(BytesCrypto.SHA512.self, CryptoKit.SHA512.self)
    }

    /// Wycheproof's HKDF vectors through one expander per vector.
    func checkWycheproof<H: BytesCrypto.HashFunction>(_ hash: H.Type, _ file: String) throws {
        let vectors = try wycheproof(file, as: HKDFVectors.self)
        var tested = 0
        for group in vectors.testGroups {
            for vector in group.tests where vector.size <= 255 * H.digestByteCount {
                let expander = HKDF<H>.Expander(salt: hex(vector.salt).span.bytes, inputKeyMaterial: hex(vector.ikm).span.bytes)
                let okm = expanded(expander, info: hex(vector.info), count: vector.size)
                #expect((okm == hex(vector.okm)) == (vector.result == "valid"), "\(file) #\(vector.tcId)")
                tested += 1
            }
        }
        #expect(tested > 50)
    }

    @Test func wycheproofSHA256() throws { try checkWycheproof(SHA256.self, "hkdf_sha256_test.json") }
    @Test func wycheproofSHA384() throws { try checkWycheproof(BytesCrypto.SHA384.self, "hkdf_sha384_test.json") }
}

@Suite struct TLSExpandLabelTests {
    /// The longest label, 249 bytes (255 with `"tls13 "`).
    static let longestLabel: StaticString = """
        abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmno
        """

    /// HKDF-Expand-Label with the longest label and context (an HkdfLabel of 514 bytes, which trapped in a
    /// 320-byte buffer), against the HkdfLabel built by hand and `HKDF.expand`.
    @Test(arguments: [TLSCipherSuite.aes128GCMSHA256, .aes256GCMSHA384])
    func longestLabelAndContext(suite: TLSCipherSuite) {
        #expect(Self.longestLabel.utf8CodeUnitCount == 249)
        var rng = SplitMix64(seed: 249)
        let secretBytes = rng.bytes(suite.hashByteCount)
        let context = rng.bytes(255)
        let secret = TLSSecret(secretBytes.span.bytes, suite: suite)
        for count in [12, 32, 100] {
            var output = [UInt8](repeating: 0, count: count)
            var span = output.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            secret.expandLabel(Self.longestLabel, context: context.span.bytes, into: &raw)

            let label = Array("tls13 ".utf8) + Array(String(describing: Self.longestLabel).utf8)
            let info = [UInt8(count >> 8), UInt8(count & 0xFF), UInt8(label.count)] + label + [UInt8(context.count)] + context
            #expect(info.count == 2 + 1 + 255 + 1 + 255)
            var expected = [UInt8](repeating: 0, count: count)
            var expectedSpan = expected.mutableSpan
            var expectedRaw = MutableRawSpan(mutating: &expectedSpan)
            switch suite {
            case .aes256GCMSHA384:
                HKDF<BytesCrypto.SHA384>.expand(pseudorandomKey: secretBytes.span.bytes, info: info.span.bytes, into: &expectedRaw)
            default:
                HKDF<SHA256>.expand(pseudorandomKey: secretBytes.span.bytes, info: info.span.bytes, into: &expectedRaw)
            }
            #expect(output == expected, "\(suite), \(count) bytes")
        }
    }

    /// Traffic keys (two labels from one expander) are the two labels expanded one at a time.
    @Test(arguments: TLSCipherSuite.allCases)
    func trafficKeysMatchTheirLabels(suite: TLSCipherSuite) {
        var rng = SplitMix64(seed: UInt64(suite.rawValue))
        let secret = TLSSecret(rng.bytes(suite.hashByteCount).span.bytes, suite: suite)
        let keys = TLSTrafficKeys(secret: secret)
        var key = [UInt8](repeating: 0, count: suite.keyByteCount)
        var keySpan = key.mutableSpan
        var keyRaw = MutableRawSpan(mutating: &keySpan)
        secret.expandLabel("key", context: RawSpan(), into: &keyRaw)
        var iv = [UInt8](repeating: 0, count: 12)
        var ivSpan = iv.mutableSpan
        var ivRaw = MutableRawSpan(mutating: &ivSpan)
        secret.expandLabel("iv", context: RawSpan(), into: &ivRaw)
        #expect(Array(keys.key.array.prefix(suite.keyByteCount)) == key)
        #expect(keys.iv.array == iv)
    }
}
