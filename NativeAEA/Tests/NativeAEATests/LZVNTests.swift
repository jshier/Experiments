@testable import NativeAEA

// Apple's AppleArchive framework only makes the test archives (`aea encrypt -a` and `aa archive -a` don't offer LZVN,
// but the library takes libcompression's LZVN constant, 0x900).
import AppleArchive
import BytesTestSupport
import CryptoKit
import DiskTestSupport
import Foundation
import System
import Testing

/// LZVN: AEA segments (`f`) and `pbzf` blocks, made by Apple's AppleArchive library, decoded with Bytes' LZVN decoder.
@Suite(.diskLifetimes) struct LZVNTests {
    /// libcompression's LZVN (`ArchiveCompression` isn't `Sendable`, so made where it's used).
    static var lzvn: ArchiveCompression { ArchiveCompression(rawValue: 0x900) }

    /// Encrypts `input` into a signed (profile 0) archive with LZVN segments of `blockSize`; returns its signing key.
    private func makeLZVNArchive(_ input: URL, _ output: URL, blockSize: Int) throws -> [UInt8] {
        let key = P256.Signing.PrivateKey()
        let context = ArchiveEncryptionContext(
            profile: .hkdf_sha256_hmac__none__ecdsa_p256, compressionAlgorithm: Self.lzvn, compressionBlockSize: blockSize
        )
        try context.setSigningPrivateKey(key)
        let file = try #require(ArchiveByteStream.fileStream(
            path: FilePath(output.path), mode: .writeOnly, options: [.create, .truncate], permissions: [.ownerReadWrite]
        ))
        let encrypted = try #require(ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context))
        let source = try #require(ArchiveByteStream.fileStream(path: FilePath(input.path), mode: .readOnly, options: [], permissions: []))
        _ = try ArchiveByteStream.process(readingFrom: source, writingTo: encrypted)
        try encrypted.close()
        try file.close()
        try source.close()
        return Array(key.publicKey.x963Representation)
    }

    @Test(arguments: [16_384, 65_536, 1 << 20])
    func decodesLZVNSegments(_ blockSize: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let contents = testBytes(700_001, seed: 1, compressible: true) + testBytes(300_000, seed: 2, compressible: false)
        let input = directory.path("contents.bin")
        try Data(contents).write(to: input)
        let url = directory.path("lzvn.aea")
        let key = try makeLZVNArchive(input, url, blockSize: blockSize)
        let archive = try AEAArchive(url: url, signingKey: .publicKey(key))
        defer { archive.close() }
        #expect(archive.rootHeader.compression == .lzvn)
        let output = directory.path("out.bin")
        for threads in [1, 4] {
            var options = AEAReadOptions()
            options.decodeThreads = threads
            try await archive.decrypt(to: FilePath(output.path), overwrite: true, options: options)
            #expect(try Array(Data(contentsOf: output)) == contents)
        }
    }

    /// An Apple Archive stream in `pbzf` blocks (LZVN), on its own and inside an LZVN AEA archive.
    @Test func extractsPBZFArchives() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.path("source")
        try FileManager.default.createDirectory(at: source.appending(path: "dir"), withIntermediateDirectories: true)
        for (index, size) in [0, 10, 70_000, 400_000].enumerated() {
            try Data(testBytes(size, seed: UInt64(index), compressible: index % 2 == 0)).write(to: source.appending(path: "dir/f\(index)"))
        }
        let raw = directory.path("tree.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", "raw", "-d", source.path, "-o", raw.path])
        let pbz = directory.path("tree-lzvn.aar")
        let file = try #require(ArchiveByteStream.fileStream(
            path: FilePath(pbz.path), mode: .writeOnly, options: [.create, .truncate], permissions: [.ownerReadWrite]
        ))
        let compressed = try #require(ArchiveByteStream.compressionStream(using: Self.lzvn, writingTo: file))
        let input = try #require(ArchiveByteStream.fileStream(path: FilePath(raw.path), mode: .readOnly, options: [], permissions: []))
        _ = try ArchiveByteStream.process(readingFrom: input, writingTo: compressed)
        try compressed.close()
        try file.close()
        try input.close()

        let archiveFile = try AppleArchiveFile(path: FilePath(pbz.path))
        defer { archiveFile.close() }
        #expect(archiveFile.compression == .lzvn)
        let destination = directory.path("out")
        try await archiveFile.extract(to: FilePath(destination.path))
        #expect(try readTree(destination, including: .entries) == readTree(source, including: .entries))

        let url = directory.path("pbzf.aea")
        let key = try makeLZVNArchive(pbz, url, blockSize: 65_536)
        let nested = directory.path("nested")
        let opened = try AEAArchive(url: url, signingKey: .publicKey(key))
        defer { opened.close() }
        try await opened.extract(to: FilePath(nested.path))
        #expect(try readTree(nested, including: .entries) == readTree(source, including: .entries))
    }
}
