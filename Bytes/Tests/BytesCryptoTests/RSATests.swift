import Bytes
import BytesCrypto
import BytesTesting
import BytesTestSupport
import Foundation
import Security
import Testing

// RSA PKCS #1 v1.5 verification: Wycheproof's vectors (every one, valid and invalid), Security on random keys and
// messages, OpenSSL's keys and signatures, the system's RSA root certificates, and the signature and certificate chain
// of the Xcode `.xip` archives in ~/Scratch, when there are any (the archive isn't checked in: 2 GB).

struct RSAVectors: Decodable {
    struct Group: Decodable {
        let keySize: Int
        let sha: String
        // Verification sets name their keys `publicKey…`; signature-generation sets `key…`.
        let publicKeyDer, publicKeyAsn, publicKeyPem: String?
        let keyDer, keyAsn, keyPem: String?
        let tests: [Vector]
    }

    struct Vector: Decodable {
        let tcId: Int
        let comment: String
        let flags: [String]
        let msg, sig: String
        let result: String
    }

    let testGroups: [Group]
}

/// The digest algorithm Wycheproof names, or nil for one RSA here doesn't support (SHA-224, SHA-3, SHA-512/256).
func rsaDigestAlgorithm(_ name: String) -> RSA.DigestAlgorithm? {
    switch name {
    case "SHA-1": .sha1
    case "SHA-256": .sha256
    case "SHA-384": .sha384
    case "SHA-512": .sha512
    default: nil
    }
}

/// Security's algorithms for PKCS #1 v1.5 over a message and over a digest.
func securityAlgorithms(_ algorithm: RSA.DigestAlgorithm) -> (message: SecKeyAlgorithm, digest: SecKeyAlgorithm) {
    switch algorithm {
    case .sha1: (.rsaSignatureMessagePKCS1v15SHA1, .rsaSignatureDigestPKCS1v15SHA1)
    case .sha256: (.rsaSignatureMessagePKCS1v15SHA256, .rsaSignatureDigestPKCS1v15SHA256)
    case .sha384: (.rsaSignatureMessagePKCS1v15SHA384, .rsaSignatureDigestPKCS1v15SHA384)
    case .sha512: (.rsaSignatureMessagePKCS1v15SHA512, .rsaSignatureDigestPKCS1v15SHA512)
    }
}

/// A digest of `message` with `algorithm`.
func rsaDigest(_ message: [UInt8], _ algorithm: RSA.DigestAlgorithm) -> [UInt8] {
    var digest = InlineArray<64, UInt8>(repeating: 0)
    algorithm.hash(message.span.bytes, into: &digest)
    return (0..<algorithm.digestByteCount).map { digest[$0] }
}

/// A Security public key from PKCS #1 RSAPublicKey DER.
func securityRSAKey(_ pkcs1: [UInt8]) -> SecKey? {
    let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
    return SecKeyCreateWithData(Data(pkcs1) as CFData, attributes, nil)
}

// MARK: - Xcode archives

/// What an Apple `.xip` (a XAR archive) carries for its signature: the compressed table of contents, its SHA-1 (the
/// heap's first 20 bytes), the RSA signature of that checksum, and the certificates from the table of contents.
struct XIPSignature {
    let name: String
    let compressedTOC: [UInt8]
    let checksum: [UInt8]
    let signature: [UInt8]
    let certificates: [[UInt8]]

    /// Reads the start of a XAR archive: a big-endian header (`xar!`, header size, version, the table of contents'
    /// compressed and uncompressed sizes, the checksum algorithm), the zlib-compressed table of contents, then the
    /// heap, whose first bytes the table of contents' `<checksum>` and `<signature>` elements locate.
    init?(path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let headerData = try? handle.read(upToCount: 28), headerData.count == 28 else { return nil }
        let header = [UInt8](headerData)
        func bigEndian(_ range: Range<Int>) -> Int { header[range].reduce(0) { $0 << 8 | Int($1) } }
        guard header.prefix(4) == [0x78, 0x61, 0x72, 0x21] else { return nil } // "xar!"
        let headerSize = bigEndian(4..<6), compressedSize = bigEndian(8..<16), checksumAlgorithm = bigEndian(24..<28)
        guard checksumAlgorithm == 1, compressedSize < 1 << 24 else { return nil } // 1: SHA-1.
        try? handle.seek(toOffset: UInt64(headerSize))
        guard let toc = try? handle.read(upToCount: compressedSize), toc.count == compressedSize,
              let heap = try? handle.read(upToCount: 4096), heap.count == 4096 else { return nil }
        // zlib: a 2-byte header, raw DEFLATE (what Foundation's `.zlib` decodes), and an Adler-32.
        guard let xmlData = try? (Data(toc.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data else { return nil }
        let xml = String(decoding: xmlData, as: UTF8.self)
        func element(_ name: String, in text: Substring) -> Substring? {
            guard let start = text.range(of: "<\(name)"), let open = text[start.upperBound...].firstIndex(of: ">"),
                  let end = text[open...].range(of: "</\(name)>") else { return nil }
            return text[text.index(after: open)..<end.lowerBound]
        }
        func integer(_ name: String, in text: Substring) -> Int? { element(name, in: text).flatMap { Int($0) } }
        guard let checksumElement = element("checksum", in: xml[...]), let signatureElement = element("signature", in: xml[...]),
              let checksumOffset = integer("offset", in: checksumElement), let checksumSize = integer("size", in: checksumElement),
              let signatureOffset = integer("offset", in: signatureElement), let signatureSize = integer("size", in: signatureElement),
              checksumOffset + checksumSize <= heap.count, signatureOffset + signatureSize <= heap.count else { return nil }
        var certificates: [[UInt8]] = []
        var rest = signatureElement
        while let base64 = element("X509Certificate", in: rest) {
            guard let der = Data(base64Encoded: String(base64), options: .ignoreUnknownCharacters) else { return nil }
            certificates.append([UInt8](der))
            rest = rest[base64.endIndex...].dropFirst("</X509Certificate>".count)
        }
        let heapBytes = [UInt8](heap)
        name = (path as NSString).lastPathComponent
        compressedTOC = [UInt8](toc)
        checksum = Array(heapBytes[checksumOffset..<checksumOffset + checksumSize])
        signature = Array(heapBytes[signatureOffset..<signatureOffset + signatureSize])
        self.certificates = certificates
    }
}

/// The signatures of every `.xip` in ~/Scratch (Xcode's): empty when there are none, and the test that needs them
/// is skipped.
let xipSignatures: [XIPSignature] = {
    let downloads = NSString(string: "~/Scratch").expandingTildeInPath
    let names = (try? FileManager.default.contentsOfDirectory(atPath: downloads)) ?? []
    return names.filter { $0.hasSuffix(".xip") }.sorted().compactMap { XIPSignature(path: "\(downloads)/\($0)") }
}()

/// The system's root certificates, DER.
let systemRoots: [[UInt8]] = systemRootsPEM.flatMap { try? X509Certificate.decodePEM($0) } ?? []

/// One system root of each kind (signature algorithm, and the key's curve and size): what the fast tests check of
/// them; the bulk tests check every root.
let systemRootSample: [[UInt8]] = {
    var kinds = Set<String>()
    return systemRoots.filter { der in
        let kind: String
        do {
            let certificate = try X509Certificate(derEncoded: der.span.bytes)
            kind = "\(certificate.signatureAlgorithm) \(certificate.namedCurve?.description ?? "-") \(certificate.publicKey.byteCount)"
        } catch {
            return true // Every root parses (the tests check that); keep one that doesn't.
        }
        return kinds.insert(kind).inserted
    }
}()

/// The DER of the system root certificate with common name `name`.
func systemRoot(named name: String) -> [UInt8]? {
    systemRoots.first { der in (try? X509Certificate(derEncoded: der.span.bytes))?.subject.commonName == name }
}

/// Array forms of the API, for `#expect` (which doesn't take spans).
extension RSA.PublicKey {
    init(der: [UInt8]) throws(BytesError) {
        try self.init(derRepresentation: der.span.bytes)
    }

    func verifies(_ signature: [UInt8], message: [UInt8], _ algorithm: RSA.DigestAlgorithm) -> Bool {
        isValidSignature(signature.span.bytes, for: message.span.bytes, digestAlgorithm: algorithm)
    }

    func verifies(_ signature: [UInt8], digest: [UInt8], _ algorithm: RSA.DigestAlgorithm) -> Bool {
        isValidSignature(signature.span.bytes, digest: digest.span.bytes, digestAlgorithm: algorithm)
    }
}

/// The RSA vector files: Wycheproof's verification sets and signature-generation sets.
enum RSAFile: String, CaseIterable, Sendable {
    case s2048sha256 = "rsa_signature_2048_sha256_test.json", s2048sha384 = "rsa_signature_2048_sha384_test.json"
    case s2048sha512 = "rsa_signature_2048_sha512_test.json", s3072sha256 = "rsa_signature_3072_sha256_test.json"
    case s3072sha384 = "rsa_signature_3072_sha384_test.json", s3072sha512 = "rsa_signature_3072_sha512_test.json"
    case s4096sha256 = "rsa_signature_4096_sha256_test.json", s4096sha384 = "rsa_signature_4096_sha384_test.json"
    case s4096sha512 = "rsa_signature_4096_sha512_test.json"
    case g1024 = "rsa_pkcs1_1024_sig_gen_test.json", g1536 = "rsa_pkcs1_1536_sig_gen_test.json"
    case g2048 = "rsa_pkcs1_2048_sig_gen_test.json", g3072 = "rsa_pkcs1_3072_sig_gen_test.json"
    case g4096 = "rsa_pkcs1_4096_sig_gen_test.json"

    static let files = wycheproofFiles(allCases.map(\.rawValue), as: RSAVectors.self)
    /// One vector of each class in the fast run, as for the curves; groups of a digest RSA here doesn't support have
    /// none to check.
    static let splits = files.compactMapValues { file in
        try? VectorSplit(classes: file.get().testGroups.map { group in
            rsaDigestAlgorithm(group.sha) == nil ? [] : group.tests.map { vectorClass($0.result, $0.flags) }
        }, perClass: 1)
    }

    var vectors: RSAVectors { get throws { try #require(Self.files[rawValue]).get() } }
    var split: VectorSplit { get throws { _ = try vectors; return try #require(Self.splits[rawValue]) } }

    /// Each group's key: its modulus size, and the same key from DER, PKCS #1, and PEM, written back.
    func checkKeys() throws {
        for group in try vectors.testGroups where rsaDigestAlgorithm(group.sha) != nil {
            let der = try hex(#require(group.publicKeyDer ?? group.keyDer))
            let key = try RSA.PublicKey(derRepresentation: der.span.bytes)
            #expect(key.modulusBitCount == group.keySize, "\(rawValue)")
            let pkcs1 = try hex(#require(group.publicKeyAsn ?? group.keyAsn))
            #expect(try RSA.PublicKey(der: pkcs1) == key)
            #expect(try RSA.PublicKey(pemRepresentation: #require(group.publicKeyPem ?? group.keyPem)) == key)
            #expect(key.derRepresentation == der)
            #expect(key.pkcs1DERRepresentation == pkcs1)
        }
    }

    /// The vectors at `positions`: valid ones verify, invalid ones don't. Of the "acceptable" ones, signatures with
    /// 1024-bit keys, SHA-1, and e = 3 verify; DigestInfo without its NULL doesn't (the encoding is compared exactly).
    /// The digest form agrees with the message form.
    func check(_ positions: [VectorPosition]) throws {
        let vectors = try vectors
        var keys: [Int: RSA.PublicKey] = [:]
        for position in positions {
            let group = vectors.testGroups[position.group], vector = group.tests[position.test]
            let algorithm = try #require(rsaDigestAlgorithm(group.sha))
            let key = try keys[position.group] ?? RSA.PublicKey(der: hex(#require(group.publicKeyDer ?? group.keyDer)))
            keys[position.group] = key
            let message = hex(vector.msg), signature = hex(vector.sig)
            let verified = key.verifies(signature, message: message, algorithm)
            let expected: Bool = switch vector.result {
            case "valid": true
            case "invalid": false
            default: !vector.flags.contains("MissingNull")
            }
            #expect(verified == expected, "\(rawValue) #\(vector.tcId) \(vector.comment) \(vector.flags) \(vector.result)")
            let digest = rsaDigest(message, algorithm)
            #expect(key.verifies(signature, digest: digest, algorithm) == verified)
        }
    }
}

@Suite struct RSATests {
    // MARK: Wycheproof

    /// Every set is whole: 2,464 vectors, of which the 24 skipped are the signature-generation sets' SHA-224 groups.
    @Test func wycheproofCounts() throws {
        var counts: [String: Int] = [:]
        var skipped = 0
        for file in RSAFile.allCases {
            for group in try file.vectors.testGroups {
                if rsaDigestAlgorithm(group.sha) == nil {
                    skipped += group.tests.count
                } else {
                    for vector in group.tests {
                        counts[vector.result, default: 0] += 1
                    }
                }
            }
        }
        #expect(counts == ["valid": 140, "invalid": 2253, "acceptable": 71], "\(counts)")
        #expect(skipped == 24)
    }

    /// Every group's key, and one vector of every class (`VectorSplit`) of every set; `RSABulkTests` checks the others.
    @Test(arguments: RSAFile.allCases)
    func wycheproof(_ file: RSAFile) throws {
        try file.checkKeys()
        try file.check(file.split.fast)
    }

    // MARK: Security

    /// Random keys from Security, of every size class the arithmetic has: signatures it makes over random messages
    /// (and digests) verify with every hash; modified signatures, messages, and hashes don't, and Security agrees on
    /// each; random signatures fail in both. One round of messages here, with the edge signatures; seven more in
    /// `RSABulkTests`.
    @Test(arguments: [1024, 1536, 2048, 3072, 4096])
    func security(bits: Int) throws { try Self.security(bits: bits, rounds: 0..<1, edges: true) }

    static func security(bits: Int, rounds: Range<Int>, edges: Bool) throws {
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits] as CFDictionary
        var error: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(attributes, &error), "\(String(describing: error))")
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try [UInt8](#require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?))
        let key = try RSA.PublicKey(derRepresentation: pkcs1.span.bytes)
        #expect(key.modulusBitCount == bits)
        #expect(key.publicExponent == 65537)
        #expect(key.pkcs1DERRepresentation == pkcs1)
        #expect(try RSA.PublicKey(der: key.derRepresentation) == key)
        #expect(try RSA.PublicKey(pemRepresentation: key.pemRepresentation) == key)
        var generator = SplitMix64(seed: UInt64(bits) &+ UInt64(rounds.lowerBound) << 32)
        for round in rounds {
            let message = (0..<Int.random(in: 0...300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            for algorithm in RSA.DigestAlgorithm.allCases {
                let (messageAlgorithm, digestAlgorithm) = securityAlgorithms(algorithm)
                let signature = try [UInt8](#require(SecKeyCreateSignature(privateKey, messageAlgorithm, Data(message) as CFData, nil) as Data?))
                #expect(key.verifies(signature, message: message, algorithm))
                let digest = rsaDigest(message, algorithm)
                let digestSignature = try [UInt8](#require(SecKeyCreateSignature(privateKey, digestAlgorithm, Data(digest) as CFData, nil) as Data?))
                #expect(digestSignature == signature) // Deterministic.
                #expect(key.verifies(signature, digest: digest, algorithm))
                // Another hash, a flipped bit in the signature or the message: rejected by both.
                let other = RSA.DigestAlgorithm.allCases[(RSA.DigestAlgorithm.allCases.firstIndex(of: algorithm)! + 1) % 4]
                #expect(!key.verifies(signature, message: message, other))
                var flipped = signature
                flipped[(round * 37) % flipped.count] ^= UInt8(1) << (round % 8)
                let bytesAccepts = key.verifies(flipped, message: message, algorithm)
                let securityAccepts = SecKeyVerifySignature(publicKey, messageAlgorithm, Data(message) as CFData, Data(flipped) as CFData, nil)
                #expect(!bytesAccepts && !securityAccepts)
                var changed = message + [0]
                changed[0] ^= 0x80
                #expect(!key.verifies(signature, message: changed, algorithm))
                // Lengths: one byte short or long.
                #expect(!key.verifies(signature.dropLast(), message: message, algorithm))
                #expect(!key.verifies([0] + signature, message: message, algorithm))
                #expect(!key.verifies(signature, digest: digest.dropLast(), algorithm))
            }
            // A random value below n as the signature: nothing verifies it.
            var random = (0..<key.modulusByteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
            random[0] = 0
            #expect(!key.verifies(random, message: [UInt8](), .sha256))
        }
        guard edges else { return }
        // Signatures at the edges: 0, 1, n − 1, n, and above n (all ones).
        let n = key.modulusBytes
        var nMinusOne = n
        nMinusOne[nMinusOne.count - 1] -= 1 // n is odd.
        let zero = [UInt8](repeating: 0, count: n.count)
        var one = zero
        one[one.count - 1] = 1
        let ones = [UInt8](repeating: 0xFF, count: n.count)
        let digest = rsaDigest([], .sha256)
        for edge in [zero, one, nMinusOne, n, ones] {
            #expect(!key.verifies(edge, digest: digest, .sha256))
            let securityAccepts = SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15SHA256, Data(digest) as CFData, Data(edge) as CFData, nil)
            #expect(!securityAccepts)
        }
    }

    // MARK: OpenSSL

    /// `openssl genrsa` keys, including sizes that aren't a whole number of limbs or bytes and e = 3: its PEM in both
    /// forms ("PUBLIC KEY", "RSA PUBLIC KEY"), and its signatures with each hash.
    @Test(.enabled(if: opensslPath != nil), arguments: [(1100, false), (2048, false), (2056, true), (3000, false), (4096, true)])
    func openssl(bits: Int, exponentThree: Bool) throws {
        let openssl = opensslPath!
        let directory = try TemporaryDirectory(prefix: "bytes-rsa")
        defer { directory.remove() }
        let scratch = directory.url
        let keyPath = scratch.appendingPathComponent("key.pem").path
        _ = try ExternalTool.output(openssl, ["genrsa"] + (exponentThree ? ["-3"] : []) + ["-out", keyPath, "\(bits)"])
        let spki = try String(decoding: ExternalTool.output(openssl, ["rsa", "-in", keyPath, "-pubout"]), as: UTF8.self)
        let pkcs1 = try String(decoding: ExternalTool.output(openssl, ["rsa", "-in", keyPath, "-RSAPublicKey_out"]), as: UTF8.self)
        #expect(spki.hasPrefix("-----BEGIN PUBLIC KEY-----"))
        #expect(pkcs1.hasPrefix("-----BEGIN RSA PUBLIC KEY-----"))
        let key = try RSA.PublicKey(pemRepresentation: spki)
        #expect(try RSA.PublicKey(pemRepresentation: pkcs1) == key)
        #expect(key.modulusBitCount == bits)
        #expect(key.publicExponent == (exponentThree ? 3 : 65537))
        #expect(key.pemRepresentation == spki)
        let messagePath = scratch.appendingPathComponent("message").path
        let message = [UInt8]("A message signed with openssl dgst, \(bits) bits".utf8)
        try Data(message).write(to: URL(fileURLWithPath: messagePath))
        for (algorithm, name) in [(RSA.DigestAlgorithm.sha1, "-sha1"), (.sha256, "-sha256"), (.sha384, "-sha384"), (.sha512, "-sha512")] {
            let signature = try ExternalTool.output(openssl, ["dgst", name, "-sign", keyPath, messagePath])
            #expect(signature.count == key.modulusByteCount)
            #expect(key.verifies(signature, message: message, algorithm), "\(name)")
            #expect(!key.verifies(signature, message: message.dropLast(), algorithm))
        }
    }

    // MARK: Certificates

    /// One system root certificate of each kind (`systemRootSample`): its self-signature verifies natively exactly
    /// when Security says it does, RSA and ECDSA alike; P-521 isn't implemented, and its roots don't verify.
    /// `RSABulkTests` checks every root.
    @Test(.enabled(if: !systemRoots.isEmpty)) func systemRootCertificates() throws {
        let (rsaVerified, ecdsaVerified, _, sizes) = try Self.checkRoots(systemRootSample)
        #expect(rsaVerified >= 4, "\(rsaVerified) RSA roots")
        #expect(ecdsaVerified >= 2, "\(ecdsaVerified) ECDSA roots")
        #expect(sizes.isSuperset(of: [2048, 4096]), "\(sizes)")
    }

    /// Checks each root's self-signature, natively against Security: the RSA and ECDSA roots verified, the RSA key
    /// sizes, and the P-521 roots (not verified).
    static func checkRoots(_ roots: [[UInt8]]) throws -> (rsa: Int, ecdsa: Int, unsupported: Int, sizes: Set<Int>) {
        var rsaVerified = 0, ecdsaVerified = 0, unsupported = 0
        var sizes: Set<Int> = []
        for der in roots {
            let certificate = try X509Certificate(derEncoded: der.span.bytes)
            guard certificate.isSelfIssued, let security = verifies(certificate, issuedBy: certificate) else { continue }
            let native = certificate.isSigned(by: certificate)
            if certificate.namedCurve == .secp521r1 {
                #expect(!native)
                unsupported += 1
                continue
            }
            #expect(native == security, "\(certificate.subject.commonName ?? "?")")
            guard native else { continue }
            if RSA.DigestAlgorithm(signatureAlgorithm: certificate.signatureAlgorithm) != nil {
                rsaVerified += 1
                try sizes.insert(RSA.PublicKey(certificate: certificate).modulusBitCount)
            } else {
                ecdsaVerified += 1
            }
        }
        return (rsaVerified, ecdsaVerified, unsupported, sizes)
    }

    /// Certificates whose issuer's key doesn't fit their algorithm, or whose signature has been changed.
    @Test(.enabled(if: !systemRoots.isEmpty)) func mismatchedCertificates() throws {
        let rsaRoot = try #require(systemRoot(named: "Apple Root CA"))
        let ecRoot = try #require(systemRoot(named: "Apple Root CA - G3"))
        let rsa = try X509Certificate(derEncoded: rsaRoot.span.bytes)
        let ec = try X509Certificate(derEncoded: ecRoot.span.bytes)
        // (Results bound first: `#expect` doesn't take `~Escapable` values.)
        let verdicts = [rsa.isSigned(by: rsa), ec.isSigned(by: ec), rsa.isSigned(by: ec), ec.isSigned(by: rsa)]
        #expect(verdicts == [true, true, false, false])
        // The signature's last byte flipped: still parses, no longer verifies.
        var changed = rsaRoot
        changed[changed.count - 1] ^= 1
        let tampered = try X509Certificate(derEncoded: changed.span.bytes)
        let tamperedVerifies = tampered.isSigned(by: rsa)
        #expect(!tamperedVerifies)
        let ecKeyAsRSA: BytesError?
        do { _ = try RSA.PublicKey(certificate: ec); ecKeyAsRSA = nil } catch { ecKeyAsRSA = error }
        #expect(ecKeyAsRSA == .invalidValue)
    }

    /// The `.xip` archives in ~/Scratch (Xcode's): the table of contents' SHA-1 is the stored checksum, the leaf's
    /// RSA key signed it (PKCS #1 v1.5, SHA-1's DigestInfo), and the chain leads leaf ("Software Update") →
    /// "Apple Software Update Certification Authority" → "Apple Root CA", the system's root, every link
    /// sha256WithRSAEncryption and verified natively. Skipped when there's no archive.
    @Test(.enabled(if: !xipSignatures.isEmpty)) func xcodeArchives() throws {
        let appleRootCA = try #require(systemRoot(named: "Apple Root CA"))
        for archive in xipSignatures {
            let checksum = SHA1.hash(archive.compressedTOC.span.bytes)
            #expect((0..<20).map { checksum[$0] } == archive.checksum, "\(archive.name)")
            #expect(archive.signature.count == 256)
            try #require(archive.certificates.count >= 2, "\(archive.name)")
            let leafDER = archive.certificates[0], intermediateDER = archive.certificates[1]
            let leaf = try X509Certificate(derEncoded: leafDER.span.bytes)
            let intermediate = try X509Certificate(derEncoded: intermediateDER.span.bytes)
            let root = try X509Certificate(derEncoded: appleRootCA.span.bytes)
            if archive.certificates.count > 2 { #expect(archive.certificates[2] == appleRootCA) }
            #expect(leaf.subject.commonName == "Software Update")
            #expect(intermediate.subject.commonName == "Apple Software Update Certification Authority")
            #expect(leaf.signatureAlgorithm == .sha256WithRSAEncryption)
            #expect(intermediate.signatureAlgorithm == .sha256WithRSAEncryption)
            let leafIssuedByIntermediate = leaf.issuer.der.equals(intermediate.subject.der)
            let intermediateIssuedByRoot = intermediate.issuer.der.equals(root.subject.der)
            #expect(leafIssuedByIntermediate)
            #expect(intermediateIssuedByRoot)
            #expect(intermediate.basicConstraints?.isCertificateAuthority == true)
            let links = [leaf.isSigned(by: intermediate), intermediate.isSigned(by: root), root.isSigned(by: root), leaf.isSigned(by: root)]
            #expect(links == [true, true, true, false], "\(archive.name)")
            #expect(verifies(leaf, issuedBy: intermediate) == true)
            #expect(verifies(intermediate, issuedBy: root) == true)
            // The archive's signature: over the checksum, as a SHA-1 digest.
            let key = try RSA.PublicKey(certificate: leaf)
            #expect(key.modulusBitCount == 2048)
            #expect(key.verifies(archive.signature, digest: archive.checksum, .sha1), "\(archive.name)")
            let securityKey = try #require(securityRSAKey([UInt8](copying: leaf.publicKey)))
            #expect(SecKeyVerifySignature(securityKey, .rsaSignatureDigestPKCS1v15SHA1, Data(archive.checksum) as CFData,
                                          Data(archive.signature) as CFData, nil))
            var changed = archive.checksum
            changed[19] ^= 1
            #expect(!key.verifies(archive.signature, digest: changed, .sha1))
            #expect(!key.verifies(archive.signature, digest: archive.checksum, .sha256))
        }
        print("Verified the signatures and chains of \(xipSignatures.map(\.name))")
    }

    // MARK: Keys

    /// Keys outside the supported ranges, and malformed or mislabeled DER.
    @Test func rejectedKeys() throws {
        func tlv(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
            let length: [UInt8] = if contents.count < 0x80 { [UInt8(contents.count)] }
            else if contents.count < 0x100 { [0x81, UInt8(contents.count)] }
            else { [0x82, UInt8(contents.count >> 8), UInt8(contents.count & 0xFF)] }
            return [tag] + length + contents
        }
        func integer(_ magnitude: [UInt8]) -> [UInt8] { tlv(0x02, magnitude.first! & 0x80 != 0 ? [0] + magnitude : magnitude) }
        func pkcs1(_ n: [UInt8], _ e: [UInt8]) -> [UInt8] { tlv(0x30, integer(n) + integer(e)) }
        func modulus(bits: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0xA5, count: (bits + 7) / 8)
            bytes[0] = bits % 8 == 0 ? 0xC3 : UInt8(1) << UInt8(bits % 8 - 1)
            bytes[bytes.count - 1] |= 1
            return bytes
        }
        let f4: [UInt8] = [0x01, 0x00, 0x01]
        func accepts(_ der: [UInt8]) -> Bool { (try? RSA.PublicKey(derRepresentation: der.span.bytes)) != nil }
        #expect(accepts(pkcs1(modulus(bits: 1024), f4)))
        #expect(accepts(pkcs1(modulus(bits: 4096), f4)))
        #expect(accepts(pkcs1(modulus(bits: 1025), [3])))
        #expect(accepts(pkcs1(modulus(bits: 2048), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])))
        #expect(!accepts(pkcs1(modulus(bits: 1023), f4)))
        #expect(!accepts(pkcs1(modulus(bits: 4097), f4)))
        #expect(!accepts(pkcs1(modulus(bits: 8192), f4)))
        var even = modulus(bits: 2048)
        even[even.count - 1] &= 0xFE
        #expect(!accepts(pkcs1(even, f4)))
        #expect(!accepts(pkcs1(modulus(bits: 2048), [1])))
        #expect(!accepts(pkcs1(modulus(bits: 2048), [2])))
        #expect(!accepts(pkcs1(modulus(bits: 2048), [0x01, 0x00, 0x00])))
        #expect(!accepts(pkcs1(modulus(bits: 2048), [0x01, 0, 0, 0, 0, 0, 0, 0, 0x01]))) // Over 64 bits.
        // Negative and non-minimal integers, trailing bytes.
        #expect(!accepts(tlv(0x30, tlv(0x02, modulus(bits: 2048)) + integer(f4))))
        #expect(!accepts(tlv(0x30, tlv(0x02, [0, 0] + modulus(bits: 2048)) + integer(f4))))
        #expect(!accepts(pkcs1(modulus(bits: 2048), f4) + [0]))
        #expect(!accepts(tlv(0x30, integer(modulus(bits: 2048)) + integer(f4) + integer([1]))))
        // SubjectPublicKeyInfo: rsaEncryption with NULL; not without it, nor another algorithm.
        let rsaEncryption = tlv(0x06, [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        let key = pkcs1(modulus(bits: 2048), f4)
        func spki(_ algorithm: [UInt8]) -> [UInt8] { tlv(0x30, tlv(0x30, algorithm) + tlv(0x03, [0] + key)) }
        #expect(accepts(spki(rsaEncryption + [0x05, 0x00])))
        #expect(!accepts(spki(rsaEncryption)))
        #expect(!accepts(spki(rsaEncryption + [0x05, 0x01, 0x00])))
        #expect(!accepts(spki(tlv(0x06, [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A]) + [0x05, 0x00])))
        // The arithmetic's limb counts: 1024 → 16, 1025 → 24, 2048 → 32, 2049 → 48, 3072 → 48, 3073 → 64.
        for (bits, limbs) in [(1024, 16), (1025, 24), (1536, 24), (1537, 32), (2048, 32), (2049, 48), (3072, 48), (3073, 64), (4096, 64)] {
            #expect(try RSA.PublicKey(der: pkcs1(modulus(bits: bits), f4)).limbCount == limbs)
        }
        #expect(throws: BytesError.insufficientData) { _ = try RSA.PublicKey(pemRepresentation: "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n") }
    }

    /// −n⁻¹ mod 2⁶⁴ by Newton's iteration. (R^e mod n, the other precomputed constant, takes part in every
    /// verification above.)
    @Test func negativeInverse() {
        var generator = SplitMix64(seed: 7)
        for _ in 0..<1000 {
            let n = generator.next() | 1
            #expect(n &* RSALimbs.negativeInverse(n) == UInt64.max)
        }
    }
}

/// What `RSATests` leaves out: the other Wycheproof vectors (in shards), seven more rounds of Security's signatures
/// per key size, and every system root.
@Suite(.bulk) struct RSABulkTests {
    static let shards = 4

    @Test(arguments: RSAFile.allCases, 0..<shards)
    func wycheproof(_ file: RSAFile, shard: Int) throws {
        try file.check(VectorSplit.shard(file.split.bulk, shard, of: Self.shards))
    }

    @Test(arguments: [1024, 1536, 2048, 3072, 4096])
    func security(bits: Int) throws { try RSATests.security(bits: bits, rounds: 1..<8, edges: false) }

    /// Every system root certificate signed with RSA: its self-signature verifies natively exactly when Security
    /// says it does (and ECDSA roots on P-256 and P-384 the same, through the same API; P-521 isn't implemented, and
    /// its roots don't verify).
    @Test(.enabled(if: !systemRoots.isEmpty)) func systemRootCertificates() throws {
        let (rsaVerified, ecdsaVerified, unsupported, sizes) = try RSATests.checkRoots(systemRoots)
        #expect(rsaVerified > 80, "\(rsaVerified) RSA roots")
        #expect(ecdsaVerified > 10, "\(ecdsaVerified) ECDSA roots")
        #expect(sizes.isSuperset(of: [2048, 4096]), "\(sizes)")
        print("System roots: \(rsaVerified) RSA (\(sizes.sorted()) bits), \(ecdsaVerified) ECDSA verified; \(unsupported) on P-521")
    }
}
