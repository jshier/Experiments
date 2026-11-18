import Foundation
@testable import NativeAEA
import System
import Testing

/// Extraction: trees `aa archive` makes from real directories, Xcode-style streams with APFS compression (`AFT`),
/// files across segment boundaries, and hostile paths.
@Suite struct ExtractionTests {
    /// A source tree with every kind of entry and the sizes that matter: empty, under and over a chunk (64 KiB),
    /// over a batch (1 MiB), over a segment (the archives use 64 KiB and 1 KiB segments).
    private func makeSourceTree(at root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appending(path: "a/b/c"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        let sizes = [0, 1, 100, 4_095, 65_535, 65_536, 65_537, 131_072, 200_000, 1_048_577, 3_000_001]
        for (index, size) in sizes.enumerated() {
            try Data(testBytes(size, seed: UInt64(index), compressible: index % 2 == 0)).write(to: root.appending(path: "a/file\(index)"))
        }
        try Data(testBytes(70_000, seed: 99, compressible: true)).write(to: root.appending(path: "a/b/c/deep"))
        try manager.createSymbolicLink(atPath: root.appending(path: "a/link").path, withDestinationPath: "file1")
        try manager.createSymbolicLink(atPath: root.appending(path: "a/b/dangling").path, withDestinationPath: "../../nowhere")
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root.appending(path: "a/file2").path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "a/file3").path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.appending(path: "a/b/c").path)
    }

    @Test(arguments: [("lzma", "64k"), ("lz4", "1k"), ("zlib", "4m"), ("copy", "64k")])
    func extractsATreeAaArchived(_ compression: String, _ blockSize: String) throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SigningKeys(in: directory)
        let source = directory.path("source")
        try makeSourceTree(at: source)
        let stream = directory.path("tree.aar")
        try Tools.run("/usr/bin/aa", ["archive", "-a", "raw", "-d", source.path, "-o", stream.path])
        let url = try makeAEA(stream, keys: keys, in: directory, compression: compression, blockSize: blockSize)

        for threads in [1, 4] {
            let destination = directory.path("out-\(threads)")
            var options = AEAExtractionOptions()
            options.read.decodeThreads = threads
            options.writerThreads = threads
            options.fileSystemWidth = min(threads, 2)
            let statistics = try AEAArchive(url: url, signingKey: keys.signingKey)
                .extract(to: FilePath(destination.path), options: options)
            #expect(statistics.unreleasedBuffers == 0)
            #expect(try readTree(destination) == readTree(source))
            // Times, as `aa` archived them.
            for path in ["a/file9", "a/b/c", "a/link"] {
                var extracted = stat(), original = stat()
                lstat(destination.appending(path: path).path, &extracted)
                lstat(source.appending(path: path).path, &original)
                #expect(extracted.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, "\(path)")
                #expect(extracted.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec, "\(path)")
            }
        }
    }

    /// Xcode's layout: every file with `AFT1` 14 and `FLG1` 0x20, sizes chosen to land on and across segment
    /// boundaries (64 KiB segments: files of several segments are written in pieces).
    private func xcodeStyleArchive(in directory: TemporaryDirectory, keys: SigningKeys, blockSize: String = "64k") throws -> (URL, [String: [UInt8]]) {
        var writer = ArchiveStreamWriter()
        var files: [String: [UInt8]] = [:]
        writer.directory("")
        writer.directory("App.app")
        writer.directory("App.app/Contents", mode: 0o555)
        let sizes = [0, 7, 3_000, 3_600, 30_000, 65_536, 65_537, 70_000, 150_000, 1_048_576, 1_200_000, 5_000_000]
        var serial = 0
        for compressible in [true, false] {
            for size in sizes {
                let path = "App.app/Contents/\(compressible ? "text" : "random")-\(size)-\(serial)"
                let bytes = testBytes(size, seed: UInt64(serial), compressible: compressible)
                writer.file(path, bytes, mode: serial % 3 == 0 ? 0o444 : 0o644, diskCompression: 14, flags: 0x20)
                files[path] = bytes
                serial += 1
                // A small file between, so the next large file starts at a different offset in its segment.
                let filler = "App.app/Contents/filler-\(serial)"
                let fillerBytes = testBytes(serial * 997 % 5_000, seed: UInt64(serial + 1000), compressible: true)
                writer.file(filler, fillerBytes, diskCompression: 14, flags: 0x20)
                files[filler] = fillerBytes
            }
        }
        // A large file that's compressible after a first megabyte that isn't, and the reverse.
        let mixed = testBytes(1_100_000, seed: 7, compressible: false) + testBytes(3_000_000, seed: 8, compressible: true)
        writer.file("App.app/Contents/mixed", mixed, diskCompression: 14, flags: 0x20)
        files["App.app/Contents/mixed"] = mixed
        writer.link("App.app/Contents/link", to: "mixed", mode: 0o644)
        let stream = directory.path("xcode-style.aar")
        try writer.write(to: stream)
        return (try makeAEA(stream, keys: keys, in: directory, blockSize: blockSize), files)
    }

    @Test(arguments: [DiskCompressionMode.archived, .none], ["64k", "1k", "1m"])
    func extractsXcodeStyleArchives(_ mode: DiskCompressionMode, _ blockSize: String) throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SigningKeys(in: directory)
        let (url, files) = try xcodeStyleArchive(in: directory, keys: keys, blockSize: blockSize)
        let destination = directory.path("out")
        var options = AEAExtractionOptions()
        options.diskCompression = mode
        options.writerThreads = 6
        options.fileSystemWidth = 3
        let statistics = try AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(destination.path), options: options)
        #expect(statistics.unreleasedBuffers == 0)
        let tree = try readTree(destination)
        for (path, bytes) in files {
            let entry = try #require(tree[path], "\(path)")
            #expect(entry.contents == bytes, "\(path)")
            let type = decmpfsType(destination.appending(path: path))
            switch mode {
            case .none:
                #expect(!entry.compressed && type == nil, "\(path)")
            case .archived:
                if bytes.isEmpty {
                    #expect(!entry.compressed, "\(path)")
                } else if bytes.count <= 3_000 || path.contains("filler") && bytes.count <= 3_000 {
                    #expect(type == 13, "\(path) inline")
                } else if path.contains("random"), bytes.count > 3_600 {
                    // Doesn't compress: plain, as Apple's extractor leaves such files.
                    #expect(!entry.compressed, "\(path) plain")
                } else if path.contains("text"), bytes.count > 65_536 {
                    // With segments under a chunk (`aea` makes them at least 16 KiB), files across segments are
                    // written plain; otherwise compressed into the resource fork, in one piece or several.
                    #expect(type == (blockSize == "1k" ? nil : 14), "\(path) fork")
                }
            }
        }
        #expect(tree["App.app/Contents/link"]?.linkTarget == "mixed")
        #expect(tree["App.app/Contents/link"]?.mode == 0o644)
        #expect(tree["App.app/Contents"]?.mode == 0o555)
    }

    @Test func refusesToOverwriteUnlessAsked() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SigningKeys(in: directory)
        let (url, _) = try xcodeStyleArchive(in: directory, keys: keys)
        let destination = FilePath(directory.path("out").path)
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        try archive.extract(to: destination)
        #expect(throws: AEAError.self) { try archive.extract(to: destination) }
        var options = AEAExtractionOptions()
        options.overwrite = true
        let statistics = try archive.extract(to: destination, options: options)
        #expect(statistics.unreleasedBuffers == 0)
    }

    @Test(arguments: ["../escape", "/absolute", "a//b", "a/../../b", "a/.."])
    func rejectsUnsafePaths(_ path: String) throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SigningKeys(in: directory)
        var writer = ArchiveStreamWriter()
        writer.directory("a")
        writer.file(path, Array("payload".utf8))
        let stream = directory.path("unsafe.aar")
        try writer.write(to: stream)
        let url = try makeAEA(stream, keys: keys, in: directory)
        let destination = directory.path("inside/out")
        #expect(throws: AEAError.self) {
            try AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(destination.path))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path("escape").path))
        #expect(!FileManager.default.fileExists(atPath: directory.path("inside/escape").path))
    }

    @Test func neverWritesThroughALink() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SigningKeys(in: directory)
        let outside = directory.path("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var writer = ArchiveStreamWriter()
        writer.link("evil", to: outside.path)
        writer.file("evil/planted", Array("payload".utf8))
        let stream = directory.path("links.aar")
        try writer.write(to: stream)
        let url = try makeAEA(stream, keys: keys, in: directory)
        #expect(throws: AEAError.self) {
            try AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(directory.path("out").path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func listsWhatItExtracts() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SigningKeys(in: directory)
        let (url, files) = try xcodeStyleArchive(in: directory, keys: keys)
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        var listed: [String: Int] = [:]
        let statistics = try archive.forEachEntry { entry in
            if entry.header.type == .regularFile { listed[entry.path] = entry.size }
        }
        #expect(listed == files.mapValues(\.count))
        #expect(statistics.unreleasedBuffers == 0)
        for input in SegmentInput.allCases {
            var options = AEAReadOptions()
            options.input = input
            options.decodeThreads = 3
            options.extraBuffers = 0
            #expect(try archive.forEachEntry(options: options) { _ in }.files == files.count)
        }
    }
}
