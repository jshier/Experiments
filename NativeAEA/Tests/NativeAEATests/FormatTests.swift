import Bytes
import BytesCrypto
import BytesTestSupport
import Foundation
@testable import NativeAEA
// Security only checks BytesCrypto's verdict on a chain.
import Security
import System
import Testing

/// The container: prologue, signature, MACs, checksums, segment compressions; checked against archives Apple's
/// `aea` writes.
@Suite(.diskLifetimes) struct FormatTests {
    /// A small archive of a stream this suite writes, in the given container settings.
    private func archive(
        compression: String = "lzma", blockSize: String = "64k", checksum: String = "sha256",
        withCertificateChain: Bool = false
    ) throws -> (TemporaryDirectory, SigningKeys, URL, ArchiveStreamWriter) {
        let directory = try TemporaryDirectory()
        let keys = try SharedFixtures.keys.get()
        var writer = ArchiveStreamWriter()
        writer.directory("")
        writer.directory("folder")
        writer.file("folder/small.txt", Array("hello".utf8))
        writer.file("folder/text.txt", testBytes(300_000, seed: 1, compressible: true))
        writer.file("folder/random.bin", testBytes(200_000, seed: 2, compressible: false))
        writer.link("folder/link", to: "small.txt")
        let stream = directory.path("stream.aar")
        try writer.write(to: stream)
        let url = try makeAEA(stream, keys: keys, in: directory, compression: compression, blockSize: blockSize, checksum: checksum, withCertificateChain: withCertificateChain)
        return (directory, keys, url, writer)
    }

    @Test func readsTheContainer() async throws {
        let (directory, keys, url, writer) = try archive()
        defer { directory.remove() }
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { archive.close() }
        #expect(archive.prologue.profile == .signed)
        #expect(archive.rootHeader.rawSize == writer.bytes.count)
        #expect(archive.rootHeader.segmentSize == 65_536)
        #expect(archive.rootHeader.compression == .lzma)
        #expect(archive.rootHeader.checksum == .sha256)
        #expect(archive.segments.map(\.rawSize).reduce(0, +) == writer.bytes.count)
        #expect(archive.segments.count == (writer.bytes.count + 65_535) / 65_536)
        // The identifier is what `aea id` prints.
        let id = String(decoding: try ExternalTool.output("/usr/bin/aea", ["id", "-i", url.path]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = archive.identifier
        #expect(String(hexadecimal: identifier.span.bytes) == id)
    }

    @Test(arguments: ["lzma", "lzfse", "lzbitmap", "lzraven", "lz4", "zlib", "copy"])
    func decodesEverySegmentCompression(_ compression: String) async throws {
        let (directory, keys, url, writer) = try archive(compression: compression)
        defer { directory.remove() }
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { archive.close() }
        var paths: [String] = []
        let statistics = try await archive.forEachEntry { paths.append($0.path) }
        #expect(paths == ["", "folder", "folder/small.txt", "folder/text.txt", "folder/random.bin", "folder/link"])
        #expect(statistics.fileBytes == 5 + 300_000 + 200_000)
        _ = writer
    }

    @Test(arguments: ["none", "murmur64", "sha256"])
    func verifiesEveryChecksum(_ checksum: String) async throws {
        let (directory, keys, url, _) = try archive(checksum: checksum)
        defer { directory.remove() }
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { archive.close() }
        #expect(archive.rootHeader.checksum.byteCount == ["none": 0, "murmur64": 8, "sha256": 32][checksum])
        try await archive.forEachEntry { _ in }
    }

    @Test(arguments: ["lzma", "lz4"], ["1k", "4m"])
    func readsOtherSegmentSizes(_ compression: String, _ blockSize: String) async throws {
        let (directory, keys, url, _) = try archive(compression: compression, blockSize: blockSize)
        defer { directory.remove() }
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { archive.close() }
        // `aea` makes segments at least 16 KiB.
        #expect(archive.rootHeader.segmentSize == (blockSize == "1k" ? 16_384 : 4 << 20))
        let statistics = try await archive.forEachEntry { _ in }
        #expect(statistics.files == 3)
    }

    @Test func readsTheCertificateChain() async throws {
        let (directory, keys, url, _) = try archive(withCertificateChain: true)
        defer { directory.remove() }
        // Self-signed: not trusted, but usable when asked.
        #expect(throws: AEAError.self) { _ = try AEAArchive(url: url) }
        let archive = try AEAArchive(url: url, signingKey: .untrustedCertificateChain)
        defer { archive.close() }
        #expect(archive.signer?.subject == "NativeAEA tests")
        #expect(archive.signer?.isTrusted == false)
        #expect(archive.prologue.authDataEntries?.first?.key == AEASignature.certificateChainKey)

        // Trusted when its root is given.
        let pem = try String(contentsOf: keys.certificate, encoding: .utf8)
        let root = try X509Certificate.decodePEM(pem)
        let trusted = try AEAArchive(url: url, signingKey: .certificateChainTrusting(root))
        defer { trusted.close() }
        #expect(trusted.signer?.isTrusted == true)
        #expect(trusted.signer?.publicKey == archive.signer?.publicKey)
    }

    /// RFC 5280's rules on chains openssl makes: a valid root, intermediate, and leaf; then one violation each.
    @Test func enforcesTheChainRules() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        func run(_ arguments: [String]) throws { try ExternalTool.run("/usr/bin/openssl", arguments) }
        func key(_ name: String, curve: String = "prime256v1") throws -> String {
            let path = directory.path("\(name).key").path
            try run(["ecparam", "-name", curve, "-genkey", "-noout", "-out", path])
            return path
        }
        var serial = 1
        /// A certificate for `name`, signed by `issuer` (self-signed if nil), with these extensions.
        func certificate(_ name: String, key: String, issuer: (cert: String, key: String)?, extensions: String) throws -> [UInt8] {
            let config = directory.path("\(name).cnf")
            try Data("[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = \(name)\n[ext]\n\(extensions)\n".utf8).write(to: config)
            let output = directory.path("\(name).pem").path
            if let issuer {
                let request = directory.path("\(name).csr").path
                try run(["req", "-new", "-key", key, "-config", config.path, "-out", request])
                // An explicit serial: `-CAcreateserial` wrote its serial file outside the test's directory (LibreSSL
                // names it from the CA path cut at its first dot: `$TMPDIR/NativeAEATests-….srl`), one left per run.
                serial += 1
                try run(["x509", "-req", "-sha256", "-in", request, "-CA", issuer.cert, "-CAkey", issuer.key, "-set_serial", "\(serial)", "-days", "30",
                         "-extfile", config.path, "-extensions", "ext", "-out", output])
            } else {
                try run(["req", "-x509", "-sha256", "-new", "-key", key, "-config", config.path, "-extensions", "ext", "-days", "30", "-out", output])
            }
            return try #require(X509Certificate.decodePEM(String(contentsOfFile: output, encoding: .utf8)).first)
        }
        let rootKey = try key("root", curve: "secp384r1"), intermediateKey = try key("intermediate"), leafKey = try key("leaf")
        let caExtensions = "basicConstraints = critical, CA:TRUE\nkeyUsage = critical, keyCertSign, cRLSign"
        let root = try certificate("root", key: rootKey, issuer: nil, extensions: caExtensions)
        let rootFile = (directory.path("root.pem").path, rootKey)
        let intermediate = try certificate("intermediate", key: intermediateKey, issuer: rootFile,
                                           extensions: "basicConstraints = critical, CA:TRUE, pathlen:0\nkeyUsage = critical, keyCertSign")
        let intermediateFile = (directory.path("intermediate.pem").path, intermediateKey)
        let leaf = try certificate("leaf", key: leafKey, issuer: intermediateFile, extensions: "keyUsage = critical, digitalSignature")
        try CertificateChain.verify([leaf, intermediate, root], anchors: [root], at: Date())
        // A root that isn't given, or another root.
        #expect(throws: AEAError.self) { try CertificateChain.verify([leaf, intermediate, root], anchors: [leaf], at: Date()) }

        // A leaf that may not sign.
        let noSigning = try certificate("nosign", key: leafKey, issuer: intermediateFile, extensions: "keyUsage = critical, keyEncipherment")
        #expect(throws: AEAError.self) { try CertificateChain.verify([noSigning, intermediate, root], anchors: [root], at: Date()) }
        // An unknown critical extension.
        let unknown = try certificate("unknown", key: leafKey, issuer: intermediateFile,
                                      extensions: "keyUsage = critical, digitalSignature\n1.2.3.4 = critical, ASN1:NULL")
        #expect(throws: AEAError.self) { try CertificateChain.verify([unknown, intermediate, root], anchors: [root], at: Date()) }
        // A CA below one whose path length is 0.
        let subKey = try key("sub")
        let sub = try certificate("sub", key: subKey, issuer: intermediateFile, extensions: caExtensions)
        let subLeaf = try certificate("subleaf", key: leafKey, issuer: (directory.path("sub.pem").path, subKey),
                                      extensions: "keyUsage = critical, digitalSignature")
        #expect(throws: AEAError.self) { try CertificateChain.verify([subLeaf, sub, intermediate, root], anchors: [root], at: Date()) }
        // An issuer whose key usage doesn't allow signing certificates.
        let notCA = try certificate("notca", key: intermediateKey, issuer: rootFile,
                                    extensions: "basicConstraints = critical, CA:TRUE\nkeyUsage = critical, digitalSignature")
        let underNotCA = try certificate("undernotca", key: leafKey, issuer: (directory.path("notca.pem").path, intermediateKey),
                                         extensions: "keyUsage = critical, digitalSignature")
        #expect(throws: AEAError.self) { try CertificateChain.verify([underNotCA, notCA, root], anchors: [root], at: Date()) }
    }

    /// Xcode's chain (leaf, Apple Platform Signing ECC CA 1 - G1, Apple Root CA - G3), verified with BytesCrypto, as
    /// Security evaluates it; and with any byte of a signature or a name changed, rejected.
    @Test func verifiesXcodesCertificateChain() async throws {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Scratch/Xcode_27.3_beta_2.aea").path
        guard FileManager.default.fileExists(atPath: path) else { return } // Not on this machine.
        let prologue = try AEAArchive.prologue(at: FilePath(path))
        let entry = try #require(prologue.authDataEntries?.first { $0.key == AEASignature.certificateChainKey })
        let chain = try X509Certificate.decodePEM(entry.value.span.bytes)
        #expect(chain.count == 3)
        try CertificateChain.verify(chain, anchors: nil, at: Date())

        // Security's evaluation of the same chain agrees.
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        #expect(SecTrustEvaluateWithError(try #require(trust), nil))

        // Damage: the intermediate's signature (its last bytes), the leaf's issuer name, and the root's key.
        for (index, offset) in [(1, chain[1].count - 5), (0, 60), (2, chain[2].count - 120)] {
            var damaged = chain
            damaged[index][offset] ^= 0x01
            #expect(throws: AEAError.self, "certificate \(index), byte \(offset)") { try CertificateChain.verify(damaged, anchors: nil, at: Date()) }
        }
        // Without its root, or at a date outside the validity.
        #expect(throws: AEAError.self) { try CertificateChain.verify(Array(chain.prefix(2)), anchors: nil, at: Date()) }
        #expect(throws: AEAError.self) { try CertificateChain.verify(chain, anchors: nil, at: Date(timeIntervalSince1970: 0)) }
    }

    @Test func rejectsAnotherKey() async throws {
        let (directory, _, url, _) = try archive()
        defer { directory.remove() }
        let other = try SigningKeys(in: directory)
        #expect(throws: AEAError.invalidSignature) { _ = try AEAArchive(url: url, signingKey: other.signingKey) }
    }

    /// Flips one byte of the file at `offset` (negative: from the end).
    private func corrupt(_ url: URL, at offset: Int) throws -> URL {
        var bytes = try Data(contentsOf: url)
        let index = offset >= 0 ? offset : bytes.count + offset
        bytes[index] ^= 0x40
        let copy = url.deletingLastPathComponent().appending(path: "corrupt-\(offset).aea")
        try bytes.write(to: copy)
        return copy
    }

    @Test func detectsTampering() async throws {
        let (directory, keys, url, _) = try archive()
        defer { directory.remove() }
        let key = try keys.signingKey
        let archive = try AEAArchive(url: url, signingKey: key)
        defer { archive.close() }
        let prologue = archive.prologue.byteCount

        // In the signed prologue (the root header): the signature fails.
        #expect(throws: AEAError.invalidSignature) { _ = try AEAArchive(url: try corrupt(url, at: prologue - 40), signingKey: key) }
        // In the first cluster header: its MAC fails.
        #expect(throws: AEAError.authenticationFailed("cluster 0 header")) {
            _ = try AEAArchive(url: try corrupt(url, at: prologue + 3), signingKey: key)
        }
        // In a segment: its MAC fails when it's read.
        let segment = archive.segments[2]
        let tampered = try AEAArchive(url: try corrupt(url, at: segment.fileOffset + 10), signingKey: key)
        defer { tampered.close() }
        await #expect(throws: AEAError.authenticationFailed("segment 2")) { try await tampered.forEachEntry { _ in } }
        // Without MACs, the checksum (or the decoder) catches it.
        var options = AEAReadOptions()
        options.verifyMACs = false
        await #expect(throws: AEAError.self) { try await tampered.forEachEntry(options: options) { _ in } }
    }

    @Test func detectsTruncation() async throws {
        let (directory, keys, url, _) = try archive()
        defer { directory.remove() }
        var bytes = try Data(contentsOf: url)
        bytes.removeLast(100)
        let truncated = url.deletingLastPathComponent().appending(path: "truncated.aea")
        try bytes.write(to: truncated)
        #expect(throws: AEAError.truncated) { _ = try AEAArchive(url: truncated, signingKey: keys.signingKey) }
        #expect(throws: AEAError.notAnAEAFile) {
            let empty = url.deletingLastPathComponent().appending(path: "empty.aea")
            try Data().write(to: empty)
            _ = try AEAArchive(url: empty, signingKey: keys.signingKey)
        }
    }

    @Test func parsesHeaderFields() async throws {
        var writer = ArchiveStreamWriter()
        writer.file("a/b", [1, 2, 3], mode: 0o4755, diskCompression: 14, flags: 0x20)
        let bytes = writer.bytes
        let count = try AppleArchive.headerByteCount(bytes.span.bytes)
        let header = try AppleArchive.parseHeader(bytes.span.bytes.extracting(0..<count))
        #expect(header.type == .regularFile)
        #expect(header.mode == 0o4755)
        #expect(header.diskCompression == 14)
        #expect(header.flags == 0x20)
        #expect(header.data?.count == 3)
        #expect(header.path?.count == 3)
        #expect(count + 3 == bytes.count)
    }
}
