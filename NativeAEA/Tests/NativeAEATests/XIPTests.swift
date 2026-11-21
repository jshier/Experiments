// The test archives are made here: a cpio (odc) stream written below, in pbzx blocks (xz from libcompression, or
// stored), in a XAR written below, as Xcode's `.xip`s are, signed with a test chain or not (this macOS's `xar` no
// longer signs).
import BytesTestSupport
import Compression
import CryptoKit
import Disk
import Foundation
@testable import NativeAEA
import System
import Testing

/// A cpio "odc" stream, built entry by entry.
struct CpioBuilder {
    private(set) var bytes: [UInt8] = []
    private var nextInode = 100

    private static func octal(_ value: Int, _ width: Int) -> [UInt8] {
        let digits = String(value, radix: 8)
        return Array((String(repeating: "0", count: max(0, width - digits.count)) + digits).utf8)
    }

    private mutating func entry(_ name: String, mode: Int, inode: Int? = nil, links: Int = 1, mtime: Int, data: [UInt8] = []) {
        let inode = inode ?? { nextInode += 1; return nextInode }()
        let name = Array(name.utf8) + [0]
        bytes += Array("070707".utf8) + Self.octal(1, 6) + Self.octal(inode, 6) + Self.octal(mode, 6)
        bytes += Self.octal(501, 6) + Self.octal(20, 6) + Self.octal(links, 6) + Self.octal(0, 6)
        bytes += Self.octal(mtime, 11) + Self.octal(name.count, 6) + Self.octal(data.count, 11)
        bytes += name + data
    }

    mutating func directory(_ name: String, mode: Int = 0o755) { entry(name, mode: 0o040000 | mode, mtime: 1_700_000_000) }

    mutating func file(_ name: String, _ data: [UInt8], mode: Int = 0o644, mtime: Int = 1_700_000_123) {
        entry(name, mode: 0o100000 | mode, mtime: mtime, data: data)
    }

    /// Two names of one file (`ditto` writes each name with the contents).
    mutating func hardLinks(_ names: [String], _ data: [UInt8]) {
        nextInode += 1
        for name in names { entry(name, mode: 0o100644, inode: nextInode, links: names.count, mtime: 1_700_000_456, data: data) }
    }

    mutating func link(_ name: String, to target: String) { entry(name, mode: 0o120755, mtime: 1_700_000_000, data: Array(target.utf8)) }

    mutating func end() { entry("TRAILER!!!", mode: 0, inode: 0, links: 1, mtime: 0) }
}

/// `contents` in pbzx blocks of `blockSize`: xz from libcompression, or stored when that's no smaller (or `store`).
func pbzx(_ contents: [UInt8], blockSize: Int, store: Bool = false) -> [UInt8] {
    func be(_ value: Int) -> [UInt8] { (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    var output = Array("pbzx".utf8) + be(blockSize)
    var offset = 0
    while offset < contents.count {
        let block = Array(contents[offset..<min(offset + blockSize, contents.count)])
        var encoded = [UInt8](repeating: 0, count: block.count + 4096)
        let count = store ? 0 : compression_encode_buffer(&encoded, encoded.count, block, block.count, nil, COMPRESSION_LZMA)
        let stored = count > 0 && count < block.count ? Array(encoded[0..<count]) : block
        output += be(block.count) + be(stored.count) + stored
        offset += block.count
    }
    return output
}

/// A certificate chain shaped like Xcode's xips' (made with `/usr/bin/openssl`, LibreSSL): a test root, "Apple Software
/// Update Certification Authority", and an RSA "Software Update" leaf with Apple's software update extended key usage
/// (or without it).
struct XIPSigningChain {
    let leafKey: URL
    /// Leaf, intermediate, root (DER).
    let certificates: [[UInt8]]
    var root: [UInt8] { certificates[2] }

    init(in directory: TemporaryDirectory, name: String = "chain", leafUsage: Bool = true) throws {
        let folder = directory.path(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func file(_ name: String) -> String { folder.appending(path: name).path }
        try Data("""
        [req]
        distinguished_name = dn
        [dn]
        [ca]
        basicConstraints = critical, CA:TRUE
        keyUsage = critical, keyCertSign, cRLSign
        [leaf]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature
        \(leafUsage ? "extendedKeyUsage = critical, 1.2.840.113635.100.4.1" : "")

        """.utf8).write(to: URL(fileURLWithPath: file("ca.cnf")))
        let openssl = "/usr/bin/openssl", config = file("ca.cnf")
        try ExternalTool.run(openssl, [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", file("root.key"), "-subj", "/CN=Test Root",
            "-days", "3650", "-config", config, "-extensions", "ca", "-outform", "DER", "-out", file("root.der"),
        ])
        for (name, subject, issuer, serial, extensions) in [
            ("inter", "/CN=Apple Software Update Certification Authority", "root", "2", "ca"),
            ("leaf", "/CN=Software Update", "inter", "3", "leaf"),
        ] {
            try ExternalTool.run(openssl, [
                "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", file("\(name).key"), "-subj", subject,
                "-config", config, "-out", file("\(name).csr"),
            ])
            try ExternalTool.run(openssl, [
                "x509", "-req", "-in", file("\(name).csr"), "-CA", file("\(issuer).der"), "-CAform", "DER",
                "-CAkey", file("\(issuer).key"), "-set_serial", serial, "-days", "3650", "-extfile", config,
                "-extensions", extensions, "-outform", "DER", "-out", file("\(name).der"),
            ])
        }
        leafKey = URL(fileURLWithPath: file("leaf.key"))
        certificates = try ["leaf", "inter", "root"].map { Array(try Data(contentsOf: URL(fileURLWithPath: file("\($0).der")))) }
    }

    /// The RSA PKCS #1 v1.5 signature of a SHA-1 digest with the leaf's key, as `xar` signs a TOC checksum.
    func sign(sha1 digest: [UInt8], in directory: TemporaryDirectory) throws -> [UInt8] {
        let digestInfo: [UInt8] = [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2B, 0x0E, 0x03, 0x02, 0x1A, 0x05, 0x00, 0x04, 0x14] + digest
        let input = directory.path("digestinfo-\(UUID().uuidString)"), output = directory.path("signature-\(UUID().uuidString)")
        try Data(digestInfo).write(to: input)
        try ExternalTool.run("/usr/bin/openssl", ["pkeyutl", "-sign", "-inkey", leafKey.path, "-in", input.path, "-out", output.path])
        return Array(try Data(contentsOf: output))
    }
}

/// zlib (RFC 1950) of `bytes`: libcompression's raw DEFLATE between the header and the Adler-32.
private func zlib(_ bytes: [UInt8]) -> [UInt8] {
    var encoded = [UInt8](repeating: 0, count: bytes.count + 1024)
    let count = compression_encode_buffer(&encoded, encoded.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in bytes {
        a = (a + UInt32(byte)) % 65_521
        b = (b + a) % 65_521
    }
    let adler = b << 16 | a
    return [0x78, 0x9C] + encoded[0..<count] + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: adler >> $0) }
}

/// A `.xip` of `content` (the pbzx stream) and a small `Metadata` member, laid out as Xcode's: the TOC's SHA-1 at the
/// heap's start, then the signature (with `chain`), then the members, stored.
func makeXIP(
    _ content: [UInt8], in directory: TemporaryDirectory, name: String = "test.xip", signedBy chain: XIPSigningChain? = nil,
    creationTime: String? = nil, cpioSize: Int = 0
) throws -> URL {
    // Metadata as Xcode's: a property list, bzip2-compressed (by `/usr/bin/bzip2`).
    let plist = Array("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    	<key>FileSystemCompressionFormat</key>
    	<string>10.10</string>
    	<key>UncompressedSize</key>
    	<integer>\(cpioSize)</integer>
    	<key>Version</key>
    	<integer>1</integer>
    	<key>xbs_sortcpio</key>
    	<true/>
    </dict>
    </plist>

    """.utf8)
    let plistFile = directory.path("metadata-\(UUID().uuidString)")
    try Data(plist).write(to: plistFile)
    try ExternalTool.run("/usr/bin/bzip2", ["-k", "-f", plistFile.path])
    let metadata = Array(try Data(contentsOf: URL(fileURLWithPath: plistFile.path + ".bz2")))
    let signatureSize = chain == nil ? 0 : 256
    let made = creationTime ?? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: Date())
    }()
    var members = ""
    var offset = 20 + signatureSize
    for (id, member, bytes, decoded, encoding) in [
        (1, "Content", content, content, "application/octet-stream"), (2, "Metadata", metadata, plist, "application/x-bzip2"),
    ] {
        members += """
        <file id="\(id)"><data><length>\(bytes.count)</length><offset>\(offset)</offset><size>\(decoded.count)</size>\
        <encoding style="\(encoding)"/><archived-checksum style="sha1">\(hex(Insecure.SHA1.hash(data: bytes)))</archived-checksum>\
        <extracted-checksum style="sha1">\(hex(Insecure.SHA1.hash(data: decoded)))</extracted-checksum></data><name>\(member)</name><type>file</type></file>
        """
        offset += bytes.count
    }
    let certificates = chain.map { chain in
        chain.certificates.map { "<X509Certificate>\(Data($0).base64EncodedString(options: .lineLength64Characters))</X509Certificate>" }.joined()
    }
    let signature = certificates.map {
        """
        <signature style="RSA"><offset>20</offset><size>256</size><KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#">\
        <X509Data>\($0)</X509Data></KeyInfo></signature>
        """
    } ?? ""
    let xml = Array("""
    <?xml version="1.0" encoding="UTF-8"?>
    <xar>
     <toc>
      <creation-time>\(made)</creation-time>
      <checksum style="sha1"><offset>0</offset><size>20</size></checksum>
      \(signature)
      \(members)
     </toc>
    </xar>
    """.utf8)
    let toc = zlib(xml)
    let checksum = Array(Insecure.SHA1.hash(data: toc))
    func be<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.bigEndian) { Array($0) } }
    var file = Array("xar!".utf8) + be(UInt16(28)) + be(UInt16(1)) + be(UInt64(toc.count)) + be(UInt64(xml.count)) + be(UInt32(1))
    file += toc + checksum
    if let chain { file += try chain.sign(sha1: checksum, in: directory) }
    file += content + metadata
    let url = directory.path(name)
    try Data(file).write(to: url)
    return url
}

@Suite struct XIPTests {
    /// The tree the tests archive, and what `xip --expand` makes of it.
    static func tree() -> (cpio: [UInt8], expected: [String: DiskEntry], compressed: Set<String>) {
        var cpio = CpioBuilder()
        var expected: [String: DiskEntry] = [:]
        var compressed: Set<String> = []
        func file(_ path: String, _ data: [UInt8], mode: UInt16 = 0o644, compresses: Bool) {
            cpio.file("./" + path, data, mode: Int(mode))
            expected[path] = DiskEntry(type: "file", mode: mode, contents: data, compressed: compresses)
            if compresses { compressed.insert(path) }
        }
        cpio.directory(".")
        cpio.directory("./Xcode.app")
        cpio.directory("./Xcode.app/Contents", mode: 0o750)
        expected["Xcode.app"] = DiskEntry(type: "directory", mode: 0o755, compressed: false)
        expected["Xcode.app/Contents"] = DiskEntry(type: "directory", mode: 0o750, compressed: false)
        file("Xcode.app/Contents/small", testBytes(100, seed: 1, compressible: true), compresses: false)
        // 16 KiB and under stay plain however well they'd compress.
        file("Xcode.app/Contents/at-threshold", testBytes(16_384, seed: 2, compressible: true), compresses: false)
        file("Xcode.app/Contents/compressible", testBytes(200_001, seed: 3, compressible: true), mode: 0o755, compresses: true)
        file("Xcode.app/Contents/just-over", testBytes(16_385, seed: 4, compressible: true), compresses: true)
        file("Xcode.app/Contents/random", testBytes(100_000, seed: 5, compressible: false), compresses: false)
        // PNGs stay plain.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + testBytes(50_000, seed: 6, compressible: true)
        file("Xcode.app/Contents/image.png", png, compresses: false)
        file("Xcode.app/Contents/large", testBytes(3_000_000, seed: 7, compressible: true), compresses: true)
        cpio.link("./Xcode.app/Contents/link", to: "compressible")
        expected["Xcode.app/Contents/link"] = DiskEntry(type: "link", mode: 0o755, linkTarget: "compressible", compressed: false)
        let shared = testBytes(40_000, seed: 8, compressible: true)
        cpio.hardLinks(["./Xcode.app/Contents/first", "./Xcode.app/second"], shared)
        for path in ["Xcode.app/Contents/first", "Xcode.app/second"] {
            expected[path] = DiskEntry(type: "file", mode: 0o644, contents: shared, compressed: true)
            compressed.insert(path)
        }
        cpio.end()
        return (cpio.bytes, expected, compressed)
    }

    /// Small blocks put headers, names, and link targets across blocks; large ones keep files whole. (Blocks under
    /// 9,363 bytes, which no xip has, leave files across them plain: see `chunksFitBridges`.)
    @Test(arguments: [(16_384, false), (65_536, true), (1 << 20, false)])
    func extractsAsXipExpandDoes(_ blockSize: Int, _ store: Bool) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (cpio, expected, compressed) = Self.tree()
        let url = try makeXIP(pbzx(cpio, blockSize: blockSize, store: store), in: directory)
        let archive = try XIPArchive(path: FilePath(url.path), signature: .none)
        #expect(archive.blockSize == blockSize)
        #expect(archive.contentChecksum?.count == 20)
        // Hard links after the writers, by one writer and by several.
        for (writers, width) in [(1, 1), (8, 4)] {
            let output = directory.path("out-\(writers)")
            var options = AEAExtractionOptions()
            options.writerThreads = writers
            options.fileSystemWidth = width
            let progress = ExtractionProgress()
            options.progress = progress
            let statistics = try await archive.extract(to: FilePath(output.path), options: options)
            #expect(statistics.unreleasedBuffers == 0)
            #expect(statistics.hardLinks == 2)
            // Exact once walked: each hard-linked file's bytes once, every entry but the root. (Less the compressed
            // pieces in which no chunk ends, which Disk doesn't count: with blocks under 64 KiB, most of a large file's.)
            #expect(progress.bytes == progress.expectedBytes)
            #expect(progress.entries == progress.expectedEntries)
            let bytes = statistics.fileBytes - expected["Xcode.app/second"]!.contents!.count
            if blockSize >= 1 << 20 { #expect(progress.expectedBytes == bytes) } else { #expect(progress.expectedBytes <= bytes) }
            #expect(progress.expectedEntries == statistics.entries - 1)
            let tree = try readTree(output)
            #expect(tree == expected)
            for path in compressed { #expect(decmpfsType(output.appending(path: path)) == 8, "\(path)") }
            // Files keep their times; both names of a hard link are one file.
            let metadata = try readMetadata(output)
            #expect(metadata["Xcode.app/Contents/compressible"]?.modification.tv_sec == 1_700_000_123)
            #expect(metadata["Xcode.app/Contents/small"]?.modification.tv_sec == 1_700_000_123)
            #expect(metadata["Xcode.app/second"]?.hardLinks == ["Xcode.app/Contents/first", "Xcode.app/second"])
            #expect(metadata["Xcode.app/second"]?.modification.tv_sec == 1_700_000_456)
        }
        // Stored as Apple's `xip --expand` stores it: an LZVN resource fork.
        let stored = decmpfsStoredBytes(directory.path("out-1/Xcode.app/Contents/compressible"))
        #expect(stored.count > 16 && stored.count < 200_001 / 4)
        // Uncompressed, on request.
        var plain = AEAExtractionOptions()
        plain.diskCompression = .none
        try await archive.extract(to: FilePath(directory.path("plain").path), options: plain)
        #expect(try readTree(directory.path("plain")) == expected.mapValues { var entry = $0; entry.compressed = false; return entry })
    }

    @Test func listsEntries() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (cpio, expected, _) = Self.tree()
        let url = try makeXIP(pbzx(cpio, blockSize: 8_192), in: directory, cpioSize: cpio.count)
        let archive = try XIPArchive(path: FilePath(url.path), signature: .none)
        // Metadata: bzip2 (Bytes' decoder), both checksums checked.
        #expect(archive.metadata?.uncompressedSize == cpio.count)
        #expect(archive.metadata?.fileSystemCompressionFormat == "10.10")
        #expect(archive.metadata?.version == 1)
        nonisolated(unsafe) var paths: [String] = []
        let statistics = try await archive.forEachEntry { paths.append($0.path) }
        #expect(Set(paths) == Set(expected.keys).union([""]))
        #expect(statistics.files == expected.values.count { $0.type == "file" })
        #expect(statistics.symbolicLinks == 1)
        #expect(statistics.filesByDiskCompression[8] == 7) // Flagged by size; PNGs and data that doesn't pay are decided when written.
    }

    /// The content's SHA-1 (in the TOC) catches damage the decoders can't: a byte of a stored block.
    @Test func detectsDamagedContent() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var cpio = CpioBuilder()
        cpio.directory(".")
        cpio.file("./data", testBytes(100_000, seed: 9, compressible: false))
        cpio.end()
        let url = try makeXIP(pbzx(cpio.bytes, blockSize: 65_536, store: true), in: directory)
        let start = try XIPArchive(path: FilePath(url.path), signature: .none).contentStart
        var bytes = Array(try Data(contentsOf: url))
        bytes[start + 12 + 16 + 200 + 5_000] ^= 1 // In the file's contents, past the headers.
        try Data(bytes).write(to: url)
        let archive = try XIPArchive(path: FilePath(url.path), signature: .none)
        await #expect(throws: AEAError.authenticationFailed("the xip's Content SHA-1")) {
            _ = try await archive.extract(to: FilePath(directory.path("out").path))
        }
        await #expect(throws: AEAError.authenticationFailed("the xip's Content SHA-1")) { _ = try await archive.forEachEntry { _ in } }
        var unchecked = AEAReadOptions()
        unchecked.verifyChecksums = false
        try await archive.forEachEntry(options: unchecked) { _ in }
    }

    /// RSA signatures over the TOC checksum, and the chain: verified, rejected, or not evaluated, as asked.
    @Test func verifiesSignatures() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var cpio = CpioBuilder()
        cpio.directory(".")
        cpio.file("./a", testBytes(5_000, seed: 11, compressible: true))
        cpio.end()
        let content = pbzx(cpio.bytes, blockSize: 65_536)
        let chain = try XIPSigningChain(in: directory)
        let url = try makeXIP(content, in: directory, signedBy: chain)
        let path = FilePath(url.path)

        let trusted = try XIPArchive(path: path, signature: .certificateChainTrusting([chain.root]))
        #expect(trusted.signer == "Software Update" && trusted.isSignatureTrusted)
        _ = try await trusted.forEachEntry { _ in }
        let untrusted = try XIPArchive(path: path, signature: .untrustedCertificateChain)
        #expect(untrusted.signer == "Software Update" && !untrusted.isSignatureTrusted)
        #expect(try XIPArchive(path: path, signature: .none).signer == nil)
        // Not Apple's root.
        #expect(throws: AEAError.untrustedSigningKey("the chain doesn't end at Apple Root CA")) { _ = try XIPArchive(path: path) }
        // Another root.
        let other = try XIPSigningChain(in: directory, name: "other")
        #expect(throws: AEAError.untrustedSigningKey("the chain doesn't end at a trusted root")) {
            _ = try XIPArchive(path: path, signature: .certificateChainTrusting([other.root]))
        }

        // A changed signature byte.
        let archive = try XIPArchive(path: path, signature: .none)
        var bytes = Array(try Data(contentsOf: url))
        bytes[archive.heapStart + 20 + 100] ^= 1
        try Data(bytes).write(to: url)
        for check in [XIPSignatureCheck.untrustedCertificateChain, .certificateChainTrusting([chain.root])] {
            #expect(throws: AEAError.invalidSignature) { _ = try XIPArchive(path: path, signature: check) }
        }
        _ = try XIPArchive(path: path, signature: .none) // `xip --expand` doesn't look.

        // Signed by another key than the leaf's.
        let swapped = try makeXIP(content, in: directory, name: "swapped.xip", signedBy: XIPSigningChain(
            in: directory, name: "swapped-chain"
        ))
        var swappedBytes = Array(try Data(contentsOf: swapped))
        let swappedArchive = try XIPArchive(path: FilePath(swapped.path), signature: .none)
        let signedByOther = try other.sign(sha1: Array(swappedBytes[swappedArchive.heapStart..<swappedArchive.heapStart + 20]), in: directory)
        swappedBytes.replaceSubrange(swappedArchive.heapStart + 20..<swappedArchive.heapStart + 276, with: signedByOther)
        try Data(swappedBytes).write(to: swapped)
        #expect(throws: AEAError.invalidSignature) { _ = try XIPArchive(path: FilePath(swapped.path), signature: .untrustedCertificateChain) }

        // Made before the certificates were valid; a leaf without Apple's software update usage; no signature.
        let early = try makeXIP(content, in: directory, name: "early.xip", signedBy: chain, creationTime: "2001-01-01T00:00:00")
        #expect(throws: AEAError.self) { _ = try XIPArchive(path: FilePath(early.path), signature: .certificateChainTrusting([chain.root])) }
        _ = try XIPArchive(path: FilePath(early.path), signature: .untrustedCertificateChain)
        let plain = try XIPSigningChain(in: directory, name: "plain", leafUsage: false)
        let unusable = try makeXIP(content, in: directory, name: "usage.xip", signedBy: plain)
        #expect(throws: AEAError.untrustedSigningKey("the leaf certificate isn't for this kind of signature")) {
            _ = try XIPArchive(path: FilePath(unusable.path), signature: .certificateChainTrusting([plain.root]))
        }
        let unsigned = try makeXIP(content, in: directory, name: "unsigned.xip")
        #expect(throws: AEAError.untrustedSigningKey("the xip isn't signed")) { _ = try XIPArchive(path: FilePath(unsigned.path)) }
    }

    /// Xcode's own xips, wherever ~/Scratch has some (read for their TOC only): signed by Apple's software update key,
    /// with the chain to Apple Root CA.
    @Test(.enabled(if: !Self.downloadedXIPs.isEmpty, "no .xip in ~/Scratch"))
    func verifiesXcodeSignatures() async throws {
        for url in Self.downloadedXIPs {
            let archive = try XIPArchive(path: FilePath(url.path))
            #expect(archive.signer == "Software Update" && archive.isSignatureTrusted, "\(url.lastPathComponent)")
            #expect(archive.blockSize == 16 << 20)
        }
    }

    static var downloadedXIPs: [URL] {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Scratch")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
        return names.filter { $0.hasSuffix(".xip") }.sorted().map { downloads.appending(path: $0) }
    }

    @Test func rejectsDamagedArchives() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (cpio, _, _) = Self.tree()
        let url = try makeXIP(pbzx(cpio, blockSize: 65_536), in: directory)
        let good = Array(try Data(contentsOf: url))
        let archive = try XIPArchive(path: FilePath(url.path), signature: .none)

        // The TOC checksum (the heap's first bytes).
        var bytes = good
        bytes[archive.heapStart + 3] ^= 0x40
        try Data(bytes).write(to: url)
        #expect(throws: AEAError.self) { _ = try XIPArchive(path: FilePath(url.path), signature: .none) }

        // Metadata changed as stored (its last byte, in the bzip2 stream's CRC or end marker).
        bytes = good
        bytes[bytes.count - 1] ^= 0x01
        try Data(bytes).write(to: url)
        #expect(throws: AEAError.authenticationFailed("the xip's Metadata as stored")) {
            _ = try XIPArchive(path: FilePath(url.path), signature: .none)
        }

        // Not a XAR archive.
        bytes = good
        bytes[0] = 0x58
        try Data(bytes).write(to: url)
        #expect(throws: AEAError.self) { _ = try XIPArchive(path: FilePath(url.path), signature: .none) }

        // A cpio stream without its trailer (and the content's checksum unchecked, to reach the walker).
        var truncated = CpioBuilder()
        truncated.directory(".")
        truncated.file("./a", testBytes(1_000, seed: 10, compressible: true))
        let cut = try makeXIP(pbzx(truncated.bytes, blockSize: 65_536), in: directory, name: "cut.xip")
        var options = AEAReadOptions()
        options.verifyChecksums = false
        await #expect(throws: AEAError.invalidArchive("the cpio stream ends without its trailer")) {
            _ = try await XIPArchive(path: FilePath(cut.path), signature: .none).forEachEntry(options: options) { _ in }
        }

        // A header that isn't octal.
        var bad = CpioBuilder()
        bad.directory(".")
        bad.end()
        var badBytes = bad.bytes
        badBytes[20] = 0x39 // A '9' in the mode.
        let notOctal = try makeXIP(pbzx(badBytes, blockSize: 65_536), in: directory, name: "octal.xip")
        await #expect(throws: AEAError.invalidArchive("a cpio header field isn't octal")) {
            _ = try await XIPArchive(path: FilePath(notOctal.path), signature: .none).forEachEntry(options: options) { _ in }
        }
    }
}

@Suite struct XARTimeTests {
    /// `creation-time` through Bytes' `UTCDateTime`: checked fields, so dates that don't exist are rejected (the
    /// hand-written parser before took any day up to 31), and a leap second is allowed.
    @Test func parsesCreationTimes() {
        #expect(XAR.time("1970-01-01T00:00:00") == 0)
        #expect(XAR.time("2026-10-16T17:24:05") == 1_792_171_445)
        #expect(XAR.time("2024-02-29T12:00:00") == 1_709_208_000)
        // A leap second counts as the next minute's first, as POSIX time does.
        #expect(XAR.time("2016-12-31T23:59:60") == 1_483_228_800)
        for text in [
            "2026-02-31T00:00:00", "2025-02-29T00:00:00", "2026-04-31T00:00:00", "2026-13-01T00:00:00",
            "2026-00-10T00:00:00", "2026-01-01T24:00:00", "2026-01-01T00:60:00", "2026-01-01T00:00:61",
            "2026-01-01 00:00:00", "2026-01-01T00:00:00Z", "2026-1-01T00:00:00", "+026-01-01T00:00:00", "",
        ] {
            #expect(XAR.time(text) == nil, "\(text)")
        }
    }
}
