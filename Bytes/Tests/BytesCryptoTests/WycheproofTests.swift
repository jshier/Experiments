import Bytes
import BytesCrypto
import BytesTestSupport
import Foundation
import Testing

// Project Wycheproof's test vectors (C2SP/wycheproof, pinned in `Tools/test-data`): known answers and known attacks
// for every primitive TLS 1.3 and WinZip AES rely on. Each AEAD vector must seal to its ciphertext and tag when
// valid, and fail to open when not (modified tags, edge-case counters); each MAC and HKDF vector must reproduce its
// output. AES-GCM and ChaCha20-Poly1305 here take only 96-bit nonces, TLS's: those groups are tested.

/// A Wycheproof vector file from the repository's TestData/wycheproof (made by `Tools/test-data fetch wycheproof`).
func wycheproof<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let data = try Data(contentsOf: TestData.file(set: "wycheproof", name: name))
    return try JSONDecoder().decode(T.self, from: data)
}

/// Files decoded once and shared by every test that reads them (`get` rethrows a missing file's error).
func wycheproofFiles<T: Decodable & Sendable>(_ names: [String], as type: T.Type) -> [String: Result<T, any Error>] {
    Dictionary(uniqueKeysWithValues: names.map { name in (name, Result { try wycheproof(name, as: T.self) }) })
}

// MARK: - Splitting a file's vectors between the fast and bulk runs

/// A vector's place in its file: its group and its index in the group.
struct VectorPosition: Hashable, Sendable {
    let group: Int
    let test: Int
}

/// A file's vectors split between the fast run and the bulk run. Wycheproof's flags name the edge case each vector
/// tests, so the fast run takes `perClass` vectors from every class (a result and its flags: the first, then spread
/// evenly through the class), and the bulk run takes all the others. Every class of edge case is in the fast run;
/// together the two check every vector.
struct VectorSplit: Sendable {
    let fast: [VectorPosition]
    let bulk: [VectorPosition]

    /// `classes[group][test]` is the vector's result and flags.
    init(classes: [[String]], perClass: Int = 2) {
        var all: [VectorPosition] = []
        var members: [String: [VectorPosition]] = [:]
        for (group, tests) in classes.enumerated() {
            for (test, name) in tests.enumerated() {
                let position = VectorPosition(group: group, test: test)
                all.append(position)
                members[name, default: []].append(position)
            }
        }
        var fast = Set<VectorPosition>()
        for positions in members.values {
            let count = min(perClass, positions.count)
            for k in 0..<count { fast.insert(positions[k * positions.count / count]) }
        }
        self.fast = all.filter { fast.contains($0) }
        self.bulk = all.filter { !fast.contains($0) }
    }

    /// One of `count` interleaved shards of `positions`, so a file's vectors spread across test cases.
    static func shard(_ positions: [VectorPosition], _ shard: Int, of count: Int) -> [VectorPosition] {
        stride(from: shard, to: positions.count, by: count).map { positions[$0] }
    }
}

/// A Wycheproof class name: the result and the sorted flags.
func vectorClass(_ result: String, _ flags: [String]) -> String {
    "\(result) \(flags.sorted().joined(separator: "+"))"
}

struct AEADVectors: Decodable {
    struct Group: Decodable {
        let ivSize: Int
        let tagSize: Int
        let tests: [Vector]
    }
    struct Vector: Decodable {
        let tcId: Int
        let key, iv, aad, msg, ct, tag: String
        let result: String
    }
    let testGroups: [Group]
}

struct MACVectors: Decodable {
    struct Group: Decodable {
        let tagSize: Int
        let tests: [Vector]
    }
    struct Vector: Decodable {
        let tcId: Int
        let key, msg, tag: String
        let result: String
    }
    let testGroups: [Group]
}

struct HKDFVectors: Decodable {
    struct Group: Decodable {
        let tests: [Vector]
    }
    struct Vector: Decodable {
        let tcId: Int
        let ikm, salt, info, okm: String
        let size: Int
        let result: String
    }
    let testGroups: [Group]
}

/// Seals or opens with one of the AEADs, as the vectors need.
protocol TestedAEAD {
    init(key: RawSpan)
    func seal(_ message: inout MutableRawSpan, nonce: RawSpan, authenticating aad: RawSpan) -> InlineArray<16, UInt8>
    func open(_ message: inout MutableRawSpan, nonce: RawSpan, authenticating aad: RawSpan, tag: RawSpan) throws(BytesError)
}
extension AESGCM: TestedAEAD {}
extension ChaCha20Poly1305: TestedAEAD {}

@Suite struct WycheproofTests {
    func check<A: TestedAEAD>(_ type: A.Type, _ file: String, keySizes: Set<Int>? = nil) throws {
        let vectors = try wycheproof(file, as: AEADVectors.self)
        var tested = 0
        for group in vectors.testGroups where group.ivSize == 96 && group.tagSize == 128 {
            for vector in group.tests {
                let key = hex(vector.key)
                if let keySizes, !keySizes.contains(key.count) { continue }
                let aead = A(key: key.span.bytes)
                let nonce = hex(vector.iv), aad = hex(vector.aad), plaintext = hex(vector.msg)
                let ciphertext = hex(vector.ct), tag = hex(vector.tag)
                // Opening: the valid ones open to the message, the invalid ones throw and leave the ciphertext.
                var opened = ciphertext
                var span = opened.mutableSpan
                var raw = MutableRawSpan(mutating: &span)
                let result = Result { () throws(BytesError) in
                    try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: tag.span.bytes)
                }
                if vector.result == "invalid" {
                    #expect(throws: BytesError.self, "\(file) #\(vector.tcId)") { _ = try result.get() }
                    #expect(opened == ciphertext, "\(file) #\(vector.tcId): a rejected message is left as it was")
                } else {
                    #expect(throws: Never.self, "\(file) #\(vector.tcId)") { _ = try result.get() }
                    #expect(opened == plaintext, "\(file) #\(vector.tcId)")
                    // Sealing: the same ciphertext and tag.
                    var sealed = plaintext
                    var sealSpan = sealed.mutableSpan
                    var sealRaw = MutableRawSpan(mutating: &sealSpan)
                    let sealedTag = aead.seal(&sealRaw, nonce: nonce.span.bytes, authenticating: aad.span.bytes)
                    #expect(sealed == ciphertext && sealedTag.array == tag, "\(file) #\(vector.tcId)")
                }
                tested += 1
            }
        }
        #expect(tested > 50, "\(file): \(tested) vectors")
    }

    @Test func aesGCM() throws { try check(AESGCM.self, "aes_gcm_test.json") }

    @Test func chaCha20Poly1305() throws { try check(ChaCha20Poly1305.self, "chacha20_poly1305_test.json") }

    func checkMAC<H: BytesCrypto.HashFunction>(_ hash: H.Type, _ file: String) throws {
        let vectors = try wycheproof(file, as: MACVectors.self)
        var tested = 0
        for group in vectors.testGroups {
            for vector in group.tests {
                var mac = BytesCrypto.HMAC<H>(key: hex(vector.key).span.bytes)
                mac.update(hex(vector.msg).span.bytes)
                let full = mac.finalize()
                let matches = Array(full.prefix(group.tagSize / 8)) == hex(vector.tag)
                #expect(matches == (vector.result == "valid"), "\(file) #\(vector.tcId)")
                tested += 1
            }
        }
        #expect(tested > 50)
    }

    @Test func hmacSHA1() throws { try checkMAC(SHA1.self, "hmac_sha1_test.json") }
    @Test func hmacSHA256() throws { try checkMAC(BytesCrypto.SHA256.self, "hmac_sha256_test.json") }

    func checkHKDF<H: BytesCrypto.HashFunction>(_ hash: H.Type, _ file: String) throws {
        let vectors = try wycheproof(file, as: HKDFVectors.self)
        var tested = 0
        for group in vectors.testGroups {
            for vector in group.tests {
                // Outputs longer than 255 digests are invalid: `expand` refuses them by precondition.
                guard vector.size <= 255 * H.digestByteCount else {
                    #expect(vector.result == "invalid", "\(file) #\(vector.tcId)")
                    continue
                }
                var prk = [UInt8](repeating: 0, count: H.digestByteCount)
                var prkSpan = prk.mutableSpan
                var prkRaw = MutableRawSpan(mutating: &prkSpan)
                BytesCrypto.HKDF<H>.extract(salt: hex(vector.salt).span.bytes, inputKeyMaterial: hex(vector.ikm).span.bytes, into: &prkRaw)
                var okm = [UInt8](repeating: 0, count: vector.size)
                var okmSpan = okm.mutableSpan
                var okmRaw = MutableRawSpan(mutating: &okmSpan)
                BytesCrypto.HKDF<H>.expand(pseudorandomKey: prk.span.bytes, info: hex(vector.info).span.bytes, into: &okmRaw)
                #expect((okm == hex(vector.okm)) == (vector.result == "valid"), "\(file) #\(vector.tcId)")
                tested += 1
            }
        }
        #expect(tested > 50)
    }

    @Test func hkdfSHA256() throws { try checkHKDF(BytesCrypto.SHA256.self, "hkdf_sha256_test.json") }
    @Test func hkdfSHA384() throws { try checkHKDF(BytesCrypto.SHA384.self, "hkdf_sha384_test.json") }
}
