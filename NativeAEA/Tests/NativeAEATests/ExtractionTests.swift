import BytesTestSupport
import BytesTesting
import Disk
import DiskTestSupport
import Foundation
@testable import NativeAEA
import System
import Testing

/// Extraction: trees `aa archive` makes from real directories, Xcode-style streams with APFS compression (`AFT`),
/// files across segment boundaries, and hostile paths.
@Suite struct ExtractionTests {
    /// A source tree with every kind of entry and the sizes that matter: empty, under and over a chunk (64 KiB),
    /// over a batch (1 MiB), over a segment (the archives use 64 KiB and 1 KiB segments).
    private static func makeSourceTree(at root: URL) throws {
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

    /// The source tree and `aa`'s raw stream of it, shared (read only) by every case.
    private static let tree: Result<(source: URL, stream: URL), any Error> = SharedFixtures.make { directory in
        let source = directory.path("source")
        try makeSourceTree(at: source)
        let stream = directory.path("tree.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", "raw", "-d", source.path, "-o", stream.path])
        return (source, stream)
    }

    /// Extractions starting together leave the process's umask as it was, and each makes the source's modes. (Reading
    /// the umask as `umask(0)` then restoring it let a second extraction read 0 in between and keep it: the process
    /// then made every later file without the umask's bits cleared, and tree comparisons across the run failed.)
    @Test func concurrentExtractionsKeepTheUmask() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        let (source, stream) = try Self.tree.get()
        let url = try makeAEA(stream, keys: keys, in: directory, compression: "copy", blockSize: "64k")
        let expected = try readTree(source, including: .entries)
        let before = getumask()
        for round in 0..<3 {
            let destinations = (0..<8).map { directory.path("out-\(round)-\($0)") }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for destination in destinations {
                    group.addTask {
                        var options = AEAExtractionOptions()
                        options.disk.writers = 2
                        _ = try await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(destination.path), options: options)
                    }
                }
                try await group.waitForAll()
            }
            #expect(getumask() == before, "round \(round)")
            for destination in destinations {
                #expect(try readTree(destination, including: .entries) == expected, "\(destination.lastPathComponent)")
            }
        }
    }

    @Test(arguments: [("lzma", "64k"), ("lz4", "1k"), ("zlib", "4m"), ("copy", "64k")])
    func extractsATreeAaArchived(_ compression: String, _ blockSize: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        let (source, stream) = try Self.tree.get()
        let url = try makeAEA(stream, keys: keys, in: directory, compression: compression, blockSize: blockSize)

        for threads in [1, 4] {
            let destination = directory.path("out-\(threads)")
            var options = AEAExtractionOptions()
            options.read.decodeThreads = threads
            options.disk.writers = threads
            options.disk.fileSystemWidth = min(threads, 2)
            // Entries made relative to opened parents (Disk's `.descriptors`) as well as by path.
            options.relativeToParents = threads > 1
            let statistics = try await AEAArchive(url: url, signingKey: keys.signingKey)
                .extract(to: FilePath(destination.path), options: options)
            #expect(statistics.unreleasedBuffers == 0)
            #expect(try readTree(destination, including: .entries) == readTree(source, including: .entries))
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
    private static func xcodeStyleStream(in directory: TemporaryDirectory) throws -> (URL, [String: [UInt8]]) {
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
        return (stream, files)
    }

    /// The Xcode-style stream and its files, made once.
    private static let xcodeStyle: Result<(directory: TemporaryDirectory, stream: URL, files: [String: [UInt8]]), any Error> =
        SharedFixtures.make { directory in
            let (stream, files) = try xcodeStyleStream(in: directory)
            return (directory, stream, files)
        }

    /// `aea`'s signed, LZMA-compressed container of the Xcode-style stream, one per segment size, each made once.
    private static func makeXcodeStyleAEA(_ blockSize: String) -> Result<URL, any Error> {
        Result {
            let (directory, stream, _) = try xcodeStyle.get()
            return try makeAEA(stream, keys: SharedFixtures.keys.get(), in: directory, blockSize: blockSize)
        }
    }
    private static let xcodeStyle64k = makeXcodeStyleAEA("64k")
    private static let xcodeStyle1k = makeXcodeStyleAEA("1k")
    private static let xcodeStyle1m = makeXcodeStyleAEA("1m")

    /// The shared Xcode-style archive in segments of `blockSize`, its signing key, and its files.
    private static func xcodeStyleArchive(blockSize: String = "64k") throws -> (URL, SigningKeys, [String: [UInt8]]) {
        let url = switch blockSize {
        case "1k": try xcodeStyle1k.get()
        case "1m": try xcodeStyle1m.get()
        default: try xcodeStyle64k.get()
        }
        return (url, try SharedFixtures.keys.get(), try xcodeStyle.get().files)
    }

    /// Every mode at every segment size, but LZBITMAP forks (`.archived`, the slowest to encode in debug builds)
    /// only in 64 KiB segments: the forks of 1 KiB and 1 MiB segments are exercised with LZFSE here, and with
    /// LZBITMAP in `ExtractionBulkTests`.
    static let xcodeStyleCases: [(DiskCompressionMode, String)] = [
        (.archived, "64k"), (.lzfse, "64k"), (.lzfse, "1k"), (.lzfse, "1m"), (.none, "64k"), (.none, "1k"), (.none, "1m"),
    ]

    @Test(arguments: Self.xcodeStyleCases)
    func extractsXcodeStyleArchives(_ mode: DiskCompressionMode, _ blockSize: String) async throws {
        try await Self.checkXcodeStyleArchive(mode, blockSize)
    }

    static func checkXcodeStyleArchive(_ mode: DiskCompressionMode, _ blockSize: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys, files) = try Self.xcodeStyleArchive(blockSize: blockSize)
        let destination = directory.path("out")
        var options = AEAExtractionOptions()
        options.diskCompression = mode
        options.disk.writers = 6
        options.disk.fileSystemWidth = 3
        let statistics = try await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(destination.path), options: options)
        #expect(statistics.unreleasedBuffers == 0)
        let tree = try readTree(destination, including: .entries)
        for (path, bytes) in files {
            let entry = try #require(tree[path], "\(path)")
            #expect(entry.contents == bytes, "\(path)")
            let type = decmpfsType(destination.appending(path: path))
            switch mode {
            case .none:
                #expect(entry.isCompressed == false && type == nil, "\(path)")
            case .archived, .lzfse:
                // The same decisions; `.lzfse` makes LZFSE (11, 12) of what the archive makes LZBITMAP (13, 14).
                let (inline, fork): (UInt32, UInt32) = mode == .archived ? (13, 14) : (11, 12)
                if bytes.isEmpty {
                    #expect(entry.isCompressed == false, "\(path)")
                } else if bytes.count <= 3_000 || path.contains("filler") && bytes.count <= 3_000 {
                    #expect(type == inline, "\(path) inline")
                } else if path.contains("random"), bytes.count > 3_600 {
                    // Doesn't compress: plain, as Apple's extractor leaves such files.
                    #expect(entry.isCompressed == false, "\(path) plain")
                } else if path.contains("text"), bytes.count > 65_536 {
                    // Compressed into the resource fork, in one piece or several (with 16 KiB segments, the
                    // smallest `aea` makes for "1k", a chunk spans up to five).
                    #expect(type == fork, "\(path) fork")
                }
            }
        }
        #expect(tree["App.app/Contents/link"]?.linkTarget == "mixed")
        #expect(tree["App.app/Contents/link"]?.mode == 0o644)
        #expect(tree["App.app/Contents"]?.mode == 0o555)
    }

    /// Whether a file is stored compressed is decided on the whole file, as `aa extract` decides it on the same
    /// stream: files across segments whose start compresses and whose whole doesn't, and the other way around.
    /// The stream of files whose storage is decided on the whole file, and `aa extract`'s extraction of it, made once.
    private static let decisions: Result<(stream: URL, reference: URL, files: [(String, [UInt8])]), any Error> =
        SharedFixtures.make { directory in
            var writer = ArchiveStreamWriter()
            writer.directory("")
            let files: [(String, [UInt8])] = [
                // Compresses at first, not overall: plain.
                ("text-then-random", testBytes(300_000, seed: 1, compressible: true) + testBytes(5_000_000, seed: 2, compressible: false)),
                // Doesn't compress at first, does overall: compressed.
                ("random-then-text", testBytes(1_200_000, seed: 3, compressible: false) + testBytes(10_000_000, seed: 4, compressible: true)),
                // Near the threshold either way.
                ("near-plain", testBytes(140_000, seed: 5, compressible: true) + testBytes(2_000_000, seed: 6, compressible: false)),
                ("near-compressed", testBytes(220_000, seed: 7, compressible: true) + testBytes(2_000_000, seed: 8, compressible: false)),
                ("text", testBytes(3_000_000, seed: 9, compressible: true)),
                ("random", testBytes(3_000_000, seed: 10, compressible: false)),
            ]
            for (path, bytes) in files { writer.file(path, bytes, diskCompression: 14, flags: 0x20) }
            let stream = directory.path("decisions.aar")
            try writer.write(to: stream)
            let reference = directory.path("reference")
            try ExternalTool.run("/usr/bin/aa", ["extract", "-i", stream.path, "-d", reference.path])
            return (stream, reference, files)
        }

    @Test(arguments: ["16k", "64k", "1m"])
    func decidesStorageOnTheWholeFileAsAppleDoes(_ blockSize: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        let (stream, reference, files) = try Self.decisions.get()
        let url = try makeAEA(stream, keys: keys, in: directory, blockSize: blockSize)
        let destination = directory.path("out")
        let statistics = try await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(destination.path))
        #expect(statistics.unreleasedBuffers == 0)
        for (path, bytes) in files {
            #expect(Array(try Data(contentsOf: destination.appending(path: path))) == bytes, "\(path)")
            let expected = decmpfsType(reference.appending(path: path))
            #expect(decmpfsType(destination.appending(path: path)) == expected, "\(path): Apple's \(expected.map(String.init) ?? "plain")")
        }
        #expect(decmpfsType(reference.appending(path: "text-then-random")) == nil)
        #expect(decmpfsType(reference.appending(path: "random-then-text")) == 14)
    }

    /// APFS compression with BytesCompression's encoders against `aa extract` on the same stream, for both codecs:
    /// small files at many sizes (where the room an encoder gets changes its output), and files whose last chunk is
    /// short. LZBITMAP (14) is stored byte for byte as `aa` stores it; LZFSE (12) decodes to the same bytes in the
    /// same form (its streams are the open lzfse reference's, not Compression's).
    @Test func compressesFilesAsAppleDoes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        var writer = ArchiveStreamWriter()
        writer.directory("")
        var files: [(String, [UInt8], UInt8)] = []
        let sizes = Array(stride(from: 20, through: 4_200, by: 83)) + [65_536 + 168, 131_072 + 280, 200_000, 3_000_000 + 7]
        for codec: UInt8 in [12, 14] {
            for (index, size) in sizes.enumerated() {
                for compressible in [true, false] where compressible || index % 8 == 0 {
                    let path = "\(codec)-\(compressible ? "text" : "random")-\(size)"
                    let bytes = testBytes(size, seed: UInt64(index * 2 + (compressible ? 0 : 1)), compressible: compressible)
                    writer.file(path, bytes, diskCompression: codec, flags: 0x20)
                    files.append((path, bytes, codec))
                }
            }
        }
        let stream = directory.path("codecs.aar")
        try writer.write(to: stream)
        let url = try makeAEA(stream, keys: keys, in: directory, blockSize: "64k")
        let reference = directory.path("reference")
        try ExternalTool.run("/usr/bin/aa", ["extract", "-i", stream.path, "-d", reference.path])
        let destination = directory.path("out")
        let statistics = try await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(destination.path))
        #expect(statistics.unreleasedBuffers == 0)
        var compressed = 0
        for (path, bytes, codec) in files {
            let mine = destination.appending(path: path), theirs = reference.appending(path: path)
            #expect(Array(try Data(contentsOf: mine)) == bytes, "\(path)")
            let type = decmpfsType(theirs)
            #expect(decmpfsType(mine) == type, "\(path): Apple's \(type.map(String.init) ?? "plain")")
            if codec == 14 { #expect(decmpfsStoredBytes(mine) == decmpfsStoredBytes(theirs), "\(path): stored bytes") }
            if type != nil { compressed += 1 }
        }
        #expect(compressed > files.count / 2)
    }

    /// A link pointing outside the destination, and an entry whose path goes through it: the second must not be made
    /// (nor, overwriting, anything outside deleted), whichever is made first. With one lane they're made in order.
    @Test(arguments: [false, true])
    func neverCreatesThroughAnArchivedLink(_ overwrite: Bool) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        let outside = directory.path("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appending(path: "victim")
        try Data("keep me".utf8).write(to: victim)
        var writer = ArchiveStreamWriter()
        writer.directory("")
        writer.link("a", to: outside.path)
        writer.link("a/victim", to: "planted")
        writer.special("a/fifo", type: "P")
        let stream = directory.path("escape.aar")
        try writer.write(to: stream)
        let url = try makeAEA(stream, keys: keys, in: directory)
        var options = AEAExtractionOptions()
        options.disk.fileSystemWidth = 1
        options.overwrite = overwrite
        _ = try? await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(directory.path("out").path), options: options)
        // Nothing was made or removed outside.
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep me")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["victim"])
    }

    /// Progress, as an app polls it: the totals start as the payload's size, become exact once the walk has read the
    /// stream (every file's bytes, every entry made), and the counters reach them.
    @Test func reportsProgress() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // 16 KiB segments (`aea`'s smallest): most files are written in pieces.
        let (url, keys, files) = try Self.xcodeStyleArchive(blockSize: "1k")
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        let bytes = files.values.reduce(0) { $0 + $1.count }
        for mode in [DiskCompressionMode.none, .archived] {
            let progress = ExtractionProgress()
            var options = AEAExtractionOptions()
            options.disk.writers = 4
            options.diskCompression = mode
            options.disk.progress = progress
            let statistics = try await archive.extract(to: FilePath(directory.path("out-\(mode)").path), options: options)
            #expect(progress.bytes == progress.expectedBytes, "\(mode)")
            #expect(progress.entries == progress.expectedEntries, "\(mode)")
            #expect(progress.expectedEntries >= files.count && progress.expectedEntries <= statistics.entries, "\(mode)")
            #expect(progress.fractionCompleted == 1, "\(mode)")
            #expect(statistics.unreleasedBuffers == 0)
            // Every file's bytes, compressed large files' pieces in which no chunk ends included.
            #expect(progress.expectedBytes == bytes, "\(mode)")
        }
    }

    @Test func refusesToOverwriteUnlessAsked() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys, _) = try Self.xcodeStyleArchive()
        let destination = FilePath(directory.path("out").path)
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        try await archive.extract(to: destination)
        // Disk's error as it threw it: the first entry that's there.
        let error = await #expect(throws: AEAError.self) { try await archive.extract(to: destination) }
        guard case .disk(.exists(let path))? = error else {
            Issue.record("expected an existing entry, got \(String(describing: error))")
            return
        }
        #expect(!path.isEmpty)
        #expect(error?.description == "already exists: \(path)")
        var options = AEAExtractionOptions()
        options.overwrite = true
        let statistics = try await archive.extract(to: destination, options: options)
        #expect(statistics.unreleasedBuffers == 0)
    }

    @Test(arguments: ["../escape", "/absolute", "a//b", "a/../../b", "a/.."])
    func rejectsUnsafePaths(_ path: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        var writer = ArchiveStreamWriter()
        writer.directory("a")
        writer.file(path, Array("payload".utf8))
        let stream = directory.path("unsafe.aar")
        try writer.write(to: stream)
        let url = try makeAEA(stream, keys: keys, in: directory)
        let destination = directory.path("inside/out")
        await #expect(throws: AEAError.self) {
            try await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(destination.path))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path("escape").path))
        #expect(!FileManager.default.fileExists(atPath: directory.path("inside/escape").path))
    }

    @Test func neverWritesThroughALink() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        let outside = directory.path("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var writer = ArchiveStreamWriter()
        writer.link("evil", to: outside.path)
        writer.file("evil/planted", Array("payload".utf8))
        let stream = directory.path("links.aar")
        try writer.write(to: stream)
        let url = try makeAEA(stream, keys: keys, in: directory)
        await #expect(throws: AEAError.self) {
            try await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(directory.path("out").path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func listsWhatItExtracts() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys, files) = try Self.xcodeStyleArchive()
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        var listed: [String: Int] = [:]
        let statistics = try await archive.forEachEntry { entry in
            if entry.header.type == .regularFile { listed[entry.path] = entry.size }
        }
        #expect(listed == files.mapValues(\.count))
        #expect(statistics.unreleasedBuffers == 0)
        // Verifying alone (no entries made) counts the same.
        let verified = try await archive.verify()
        #expect(verified.entries == statistics.entries && verified.files == files.count && verified.fileBytes == statistics.fileBytes)
        #expect(verified.filesByDiskCompression == statistics.filesByDiskCompression)
        #expect(verified.unreleasedBuffers == 0)
        for input in SegmentInput.allCases {
            var options = AEAReadOptions()
            options.input = input
            options.decodeThreads = 3
            options.extraBuffers = 0
            #expect(try await archive.forEachEntry(options: options) { _ in }.files == files.count)
        }
    }
}

@Suite(.bulk) struct ExtractionBulkTests {
    /// The modes and segment sizes `ExtractionTests.extractsXcodeStyleArchives` leaves out: LZBITMAP forks in 1 KiB
    /// and 1 MiB segments.
    @Test(arguments: ["1k", "1m"])
    func extractsXcodeStyleArchives(_ blockSize: String) async throws {
        try await ExtractionTests.checkXcodeStyleArchive(.archived, blockSize)
    }
}
