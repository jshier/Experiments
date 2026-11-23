import BytesTestSupport
import DiskTestSupport
import Foundation
@testable import NativeAEA
import System
import Testing

/// Apple Archive files as `aa archive` writes them: plain, and `pbz`-compressed with every algorithm, on their own
/// and inside AEA containers (whose decoded segments are then a `pbz` stream).
@Suite(.diskLifetimes) struct AppleArchiveFileTests {
    private static func makeSourceTree(at root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appending(path: "a/b"), withIntermediateDirectories: true)
        for (index, size) in [0, 1, 5_000, 70_000, 300_000, 1_100_000, 2_500_000].enumerated() {
            try Data(testBytes(size, seed: UInt64(index), compressible: index % 2 == 0)).write(to: root.appending(path: "a/file\(index)"))
        }
        try manager.createSymbolicLink(atPath: root.appending(path: "a/b/link").path, withDestinationPath: "../file1")
        try Data(testBytes(4_000_000, seed: 50, compressible: true)).write(to: root.appending(path: "a/b/big"))
    }

    /// The source tree, made once and only read.
    private static let source = SharedFixtures.make { directory in
        let source = directory.path("source")
        try makeSourceTree(at: source)
        return source
    }

    @Test(arguments: ["raw", "lzfse", "lzma", "zlib", "lz4", "lzbitmap", "lzraven"])
    func extractsAaArchives(_ compression: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = try Self.source.get()
        let archive = directory.path("tree-\(compression).aar")
        // Small blocks: files and headers cross many of them.
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", compression, "-b", "256k", "-d", source.path, "-o", archive.path])
        let file = try AppleArchiveFile(path: FilePath(archive.path))
        defer { file.close() }
        #expect((file.compression == nil) == (compression == "raw"))

        var paths: [String] = []
        let listing = try await file.forEachEntry { paths.append($0.path) }
        #expect(listing.unreleasedBuffers == 0)
        #expect(paths.contains("a/b/big"))

        for threads in [1, 4] {
            let destination = directory.path("out-\(threads)")
            var options = AEAExtractionOptions()
            options.read.decodeThreads = threads
            options.disk.writers = threads
            let statistics = try await file.extract(to: FilePath(destination.path), options: options)
            #expect(statistics.unreleasedBuffers == 0)
            #expect(try readTree(destination, including: .entries) == readTree(source, including: .entries), "\(threads) threads")
        }
    }

    @Test(arguments: ["lzfse", "lz4", "raw"])
    func extractsCompressedArchivesInsideAEA(_ compression: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        let source = try Self.source.get()
        let stream = directory.path("tree.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", compression, "-b", "256k", "-d", source.path, "-o", stream.path])
        // Segments of a different size than the blocks, so blocks cross segments.
        let url = try makeAEA(stream, keys: keys, in: directory, compression: "copy", blockSize: "100k")
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { archive.close() }
        for threads in [1, 4] {
            let destination = directory.path("out-\(threads)")
            var options = AEAExtractionOptions()
            options.read.decodeThreads = threads
            options.disk.writers = threads
            let statistics = try await archive.extract(to: FilePath(destination.path), options: options)
            #expect(statistics.unreleasedBuffers == 0)
            #expect(try readTree(destination, including: .entries) == readTree(source, including: .entries), "\(threads) threads")
        }
        var count = 0
        try await archive.forEachEntry { _ in count += 1 }
        #expect(count > 10)
    }

    /// A block that doesn't decode, mid-stream: the extraction throws (and doesn't hang with threads waiting on
    /// buffers or staging), on its own and inside an AEA container.
    @Test func corruptBlocksFailCleanly() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        let source = try Self.source.get()
        let archive = directory.path("tree.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", "lzfse", "-b", "64k", "-d", source.path, "-o", archive.path])
        var bytes = Array(try Data(contentsOf: archive))
        // Corrupt a compressed block past the first (stored blocks have no checks in `pbz`: their damage can't be
        // detected, by `aa` either).
        func bigEndian(_ at: Int) -> Int { (0..<8).reduce(0) { $0 << 8 | Int(bytes[at + $1]) } }
        var offset = 12, block = 0, target: Range<Int>?
        while offset + 16 <= bytes.count {
            let raw = bigEndian(offset), stored = bigEndian(offset + 8)
            if block > 2, stored < raw, target == nil { target = (offset + 16 + stored / 4)..<(offset + 16 + stored / 2) }
            offset += 16 + stored
            block += 1
        }
        let corrupted = try #require(target)
        for index in corrupted { bytes[index] ^= 0x5A }
        let corrupt = directory.path("corrupt.aar")
        try Data(bytes).write(to: corrupt)
        let file = try AppleArchiveFile(path: FilePath(corrupt.path))
        defer { file.close() }
        for threads in [1, 8] {
            var options = AEAExtractionOptions()
            options.read.decodeThreads = threads
            options.disk.writers = threads
            await #expect(throws: AEAError.self) { try await file.extract(to: FilePath(directory.path("out-\(threads)").path), options: options) }
            let url = try makeAEA(corrupt, keys: keys, in: directory, compression: "copy", blockSize: "100k")
            await #expect(throws: AEAError.self) {
                let opened = try AEAArchive(url: url, signingKey: keys.signingKey)
                defer { opened.close() }
                try await opened.extract(to: FilePath(directory.path("aea-out-\(threads)").path), options: options)
            }
        }
    }

    @Test func rejectsWhatIsntAnArchive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let junk = directory.path("junk.aar")
        try Data("not an archive at all".utf8).write(to: junk)
        #expect(throws: AEAError.self) { _ = try AppleArchiveFile(path: FilePath(junk.path)) }
        // A pbz stream cut short.
        let source = try Self.source.get()
        let archive = directory.path("tree.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", "lzfse", "-b", "256k", "-d", source.path, "-o", archive.path])
        let bytes = try Data(contentsOf: archive)
        let cut = directory.path("cut.aar")
        try bytes.prefix(bytes.count - 1000).write(to: cut)
        let file = try AppleArchiveFile(path: FilePath(cut.path))
        defer { file.close() }
        await #expect(throws: AEAError.self) { try await file.extract(to: FilePath(directory.path("out").path)) }
    }
}
