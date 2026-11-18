import Foundation
@testable import NativeAEA
import System
import Testing

/// The container: prologue, signature, MACs, checksums, segment compressions; checked against archives Apple's
/// `aea` writes.
@Suite struct FormatTests {
    /// A small archive of a stream this suite writes, in the given container settings.
    private func archive(
        compression: String = "lzma", blockSize: String = "64k", checksum: String = "sha256",
        withCertificateChain: Bool = false
    ) throws -> (TemporaryDirectory, SigningKeys, URL, ArchiveStreamWriter) {
        let directory = try TemporaryDirectory()
        let keys = try SigningKeys(in: directory)
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

    @Test func readsTheContainer() throws {
        let (directory, keys, url, writer) = try archive()
        defer { directory.remove() }
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        #expect(archive.prologue.profile == .signed)
        #expect(archive.rootHeader.rawSize == writer.bytes.count)
        #expect(archive.rootHeader.segmentSize == 65_536)
        #expect(archive.rootHeader.compression == .lzma)
        #expect(archive.rootHeader.checksum == .sha256)
        #expect(archive.segments.map(\.rawSize).reduce(0, +) == writer.bytes.count)
        #expect(archive.segments.count == (writer.bytes.count + 65_535) / 65_536)
        // The identifier is what `aea id` prints.
        let id = try Tools.run("/usr/bin/aea", ["id", "-i", url.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(archive.identifier.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() == id)
    }

    @Test(arguments: ["lzma", "lzfse", "lzbitmap", "lzraven", "lz4", "zlib", "copy"])
    func decodesEverySegmentCompression(_ compression: String) throws {
        let (directory, keys, url, writer) = try archive(compression: compression)
        defer { directory.remove() }
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        var paths: [String] = []
        let statistics = try archive.forEachEntry { paths.append($0.path) }
        #expect(paths == ["", "folder", "folder/small.txt", "folder/text.txt", "folder/random.bin", "folder/link"])
        #expect(statistics.fileBytes == 5 + 300_000 + 200_000)
        _ = writer
    }

    @Test(arguments: ["none", "murmur64", "sha256"])
    func verifiesEveryChecksum(_ checksum: String) throws {
        let (directory, keys, url, _) = try archive(checksum: checksum)
        defer { directory.remove() }
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        #expect(archive.rootHeader.checksum.byteCount == ["none": 0, "murmur64": 8, "sha256": 32][checksum])
        try archive.forEachEntry { _ in }
    }

    @Test(arguments: ["lzma", "lz4"], ["1k", "4m"])
    func readsOtherSegmentSizes(_ compression: String, _ blockSize: String) throws {
        let (directory, keys, url, _) = try archive(compression: compression, blockSize: blockSize)
        defer { directory.remove() }
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        // `aea` makes segments at least 16 KiB.
        #expect(archive.rootHeader.segmentSize == (blockSize == "1k" ? 16_384 : 4 << 20))
        let statistics = try archive.forEachEntry { _ in }
        #expect(statistics.files == 3)
    }

    @Test func readsTheCertificateChain() throws {
        let (directory, _, url, _) = try archive(withCertificateChain: true)
        defer { directory.remove() }
        // Self-signed: not trusted, but usable when asked.
        #expect(throws: AEAError.self) { _ = try AEAArchive(url: url) }
        let archive = try AEAArchive(url: url, signingKey: .untrustedCertificateChain)
        #expect(archive.signer.subject == "NativeAEA tests")
        #expect(!archive.signer.isTrusted)
        #expect(archive.prologue.authDataEntries?.first?.key == AEASignature.certificateChainKey)
    }

    @Test func rejectsAnotherKey() throws {
        let (directory, _, url, _) = try archive()
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

    @Test func detectsTampering() throws {
        let (directory, keys, url, _) = try archive()
        defer { directory.remove() }
        let key = try keys.signingKey
        let archive = try AEAArchive(url: url, signingKey: key)
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
        #expect(throws: AEAError.authenticationFailed("segment 2")) { try tampered.forEachEntry { _ in } }
        // Without MACs, the checksum (or the decoder) catches it.
        var options = AEAReadOptions()
        options.verifyMACs = false
        #expect(throws: AEAError.self) { try tampered.forEachEntry(options: options) { _ in } }
    }

    @Test func detectsTruncation() throws {
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

    @Test func parsesHeaderFields() throws {
        var writer = ArchiveStreamWriter()
        writer.file("a/b", [1, 2, 3], mode: 0o4755, diskCompression: 14, flags: 0x20)
        let bytes = writer.bytes
        let count = try bytes.span.bytes.withUnsafeBytes { try AppleArchive.headerByteCount(RawSpan(_unsafeBytes: $0)) }
        let header = try bytes.span.bytes.extracting(0..<count).withUnsafeBytes { try AppleArchive.parseHeader(RawSpan(_unsafeBytes: $0)) }
        #expect(header.type == .regularFile)
        #expect(header.mode == 0o4755)
        #expect(header.diskCompression == 14)
        #expect(header.flags == 0x20)
        #expect(header.data?.count == 3)
        #expect(header.path?.count == 3)
        #expect(count + 3 == bytes.count)
    }
}
