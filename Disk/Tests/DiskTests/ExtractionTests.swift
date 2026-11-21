import BytesTestSupport
import BytesTesting
import Darwin
@testable import Disk
import Foundation
import System
import Testing

/// The scheduler: every entry kind planned, written by writers, finished after them.
@Suite struct ExtractionTests {
    /// A tree with every kind of entry and metadata item, written through the planner.
    @Test(arguments: [(1, 1), (4, 2), (16, 6)])
    func extractsEveryKindOfEntry(_ writers: Int, _ width: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var destinationOptions = DestinationOptions()
        destinationOptions.permissions = .exact
        let destination = try Destination(directory.filePath("out"), options: destinationOptions)
        let files: [[UInt8]] = [
            testBytes(100, seed: 1, compressible: true), testBytes(70_000, seed: 2, compressible: true), [],
            testBytes(5_000, seed: 3, compressible: false), testBytes(2_000_000, seed: 4, compressible: true), Array("ro".utf8),
        ]
        let source = ArraySource(files)
        var options = ExtractionSettings()
        options.writers = writers
        options.fileSystemWidth = width
        let progress = ExtractionProgress(expectedEntries: 12, expectedBytes: files.reduce(0) { $0 + $1.count })
        options.progress = progress
        let time = EntryTimes(modification: Timestamp(seconds: 1_500_000_000))
        var attributes = ExtendedAttributeBlob()
        attributes.append(name: "com.example.a", value: ([1, 2] as [UInt8]).span.bytes)
        let blob = attributes.bytes
        let report = try await Extraction.run(into: destination, source: source, options: options) { (planner: inout Planner<ArraySource>) throws(DiskError) in
            try withPath("top") { (path) throws(DiskError) in try planner.directory(path, metadata: EntryMetadata(mode: 0o755, times: time)) }
            try withPath("top/locked") { (path) throws(DiskError) in try planner.directory(path, metadata: EntryMetadata(mode: 0o555, times: time)) }
            let first = try await planFile(&planner, "top/a.txt", index: 0, size: 100, metadata: EntryMetadata(mode: 0o600, times: time), hardLinked: true)
            _ = try await planFile(&planner, "top/locked/b.bin", index: 1, size: 70_000, metadata: EntryMetadata(times: time), storage: .compressed(.appleArchive))
            _ = try await planFile(&planner, "implicit/parents/empty", index: 2, size: 0)
            _ = try await planFile(&planner, "top/random", index: 3, size: 5_000, storage: .compressed(.appleArchive))
            _ = try await planFile(&planner, "top/large", index: 4, size: 2_000_000, metadata: EntryMetadata(times: time), storage: .compressed(.appleArchive))
            let readOnly = try await planFile(&planner, "top/ro", index: 5, size: 2, metadata: EntryMetadata(mode: 0o444), attachments: true)
            try planner.addExtendedAttributes(blob.span.bytes, to: readOnly)
            try withPath("top/link") { (path) throws(DiskError) in try planner.symbolicLink(path, target: Array("a.txt".utf8).span.bytes, metadata: EntryMetadata(times: time)) }
            try withPath("other-name") { (path) throws(DiskError) in try planner.hardLink(path, to: first) }
            try withPath("top/pipe") { (path) throws(DiskError) in try planner.specialFile(path, .fifo, metadata: EntryMetadata(mode: 0o600)) }
        }
        #expect(source.releaseCount == files.count)
        #expect(report.files == 6 && report.directories == 2 && report.symbolicLinks == 1 && report.hardLinks == 1 && report.specialFiles == 1)
        #expect(report.fileBytes == files.reduce(0) { $0 + $1.count })
        #expect(report.forkFiles == 2 && report.plainFiles == 4)
        #expect(progress.entries == 11)
        #expect(progress.bytes == files.reduce(0) { $0 + $1.count })
        #expect(progress.fractionCompleted == 1)
        let out = directory.path("out")
        let tree = try readTree(out)
        #expect(tree["top/a.txt"]?.contents == files[0] && tree["top/a.txt"]?.mode == 0o600 && tree["top/a.txt"]?.modification == 1_500_000_000)
        #expect(tree["top/locked/b.bin"]?.contents == files[1])
        #expect(tree["top/locked"]?.mode == 0o555 && tree["top/locked"]?.modification == 1_500_000_000)
        #expect(tree["top"]?.modification == 1_500_000_000)
        #expect(tree["implicit/parents/empty"]?.contents == [])
        #expect(tree["top/large"]?.contents == files[4] && tree["top/large"]?.modification == 1_500_000_000)
        #expect(tree["top/ro"]?.mode == 0o444)
        #expect(extendedAttribute(out.appending(path: "top/ro"), "com.example.a") == [1, 2])
        #expect(tree["top/link"]?.linkTarget == "a.txt" && tree["top/link"]?.modification == 1_500_000_000)
        #expect(tree["top/pipe"]?.type == "fifo")
        #expect(stat(out.appending(path: "other-name"))!.st_ino == stat(out.appending(path: "top/a.txt"))!.st_ino)
        #expect(decmpfsType(out.appending(path: "top/locked/b.bin")) == 14)
        #expect(decmpfsType(out.appending(path: "top/random")) == nil)
    }

    /// Several writes per file, gathered (small) or streamed (large), give the same tree as one write.
    @Test(arguments: [1, 3])
    func gathersAndStreams(_ writes: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let entries = (0..<40).map { ("d\($0 % 4)/f\($0)", testBytes($0 * 9_973 % 300_000, seed: UInt64($0), compressible: $0 % 3 != 0)) }
        var options = ExtractionSettings()
        options.stagingCapacity = 100_000
        let destination = try Destination(directory.filePath("out"))
        let (report, source) = try await extract(entries, into: destination, options: options, storage: .compressed(.appleArchive), writesPerFile: writes)
        #expect(report.files == entries.count && source.releaseCount == entries.count)
        for (path, bytes) in entries { #expect(try item(directory.path("out/\(path)")).contents == bytes, "\(path)") }
    }

    /// A file in pieces, compressed in parallel and in place, across bridges (pieces smaller than a chunk), and one
    /// whose fork doesn't pay (rewritten plain from it).
    @Test(arguments: [(12_000, true), (100_000, true), (1 << 20, true), (12_000, false), (200_000, false)])
    func writesLargeFilesInPieces(_ pieceSize: Int, _ compressible: Bool) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let size = 3_000_000 + 17
        let bytes = testBytes(size, seed: 11, compressible: compressible)
        let pieces = stride(from: 0, to: size, by: pieceSize).map { Array(bytes[$0..<min(size, $0 + pieceSize)]) }
        let source = ArraySource([], pieces: pieces)
        let destination = try Destination(directory.filePath("out"))
        var options = ExtractionSettings()
        options.writers = 6
        // Every byte counted, those of pieces bridged into a later piece's job (no chunk ends in them) included.
        let progress = ExtractionProgress(expectedEntries: 1, expectedBytes: size)
        options.progress = progress
        let report = try await Extraction.run(into: destination, source: source, options: options) { (planner: inout Planner<ArraySource>) throws(DiskError) in
            let file = try await withPathAsync("big") { (path) async throws(DiskError) in
                try await planner.beginLargeFile(path, size: size, metadata: EntryMetadata(mode: 0o644), storage: .compressed(.appleArchive),
                                                 first: bytes.span.bytes, minimumPieceSize: pieceSize)
            }
            #expect(file.isCompressed)
            #expect(file.entry == .none)
            var offset = 0
            for index in pieces.indices {
                try await planner.piece(-1 - index, of: file, at: offset, count: pieces[index].count)
                offset += pieces[index].count
            }
        }
        #expect(source.releaseCount == pieces.count + source.retainCount)
        #expect(report.files == 1)
        #expect(progress.bytes == size && progress.entries == 1)
        #expect(progress.fractionCompleted == 1)
        let url = directory.path("out/big")
        #expect(try item(url).contents == bytes)
        #expect(decmpfsType(url) == (compressible ? 14 : nil))
        // The same file written whole is stored the same.
        var writer = FileWriter(try Destination(directory.filePath("whole")))
        try withPath("big") { try writer.writeFile($0, contents: bytes.span.bytes, storage: .compressed(.appleArchive)) }
        #expect(decmpfsStoredBytes(url) == decmpfsStoredBytes(directory.path("whole/big")))
    }

    /// With failures recorded instead of stopping: the rest is extracted, failures listed by tag, contents released.
    @Test func recordsFailuresAndGoesOn() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let files = (0..<20).map { testBytes(1_000 + $0, seed: UInt64($0), compressible: true) }
        let source = ArraySource(files, failing: 7)
        var options = ExtractionSettings()
        options.stopsOnFirstFailure = false
        let destination = try Destination(directory.filePath("out"))
        // An existing file where one entry goes.
        try FileManager.default.createDirectory(at: directory.path("out"), withIntermediateDirectories: true)
        try Data([9]).write(to: directory.path("out/f3"))
        let report = try await Extraction.run(into: destination, source: source, options: options) { (planner: inout Planner<ArraySource>) throws(DiskError) in
            for index in files.indices {
                _ = try await planFile(&planner, "f\(index)", index: index, size: files[index].count, tag: index)
            }
        }
        #expect(source.releaseCount == files.count)
        #expect(Set(report.failures.map(\.tag)) == [3, 7])
        // The source's own error, as it threw it.
        let decoding = report.failures.first { $0.tag == 7 }?.error
        #expect(decoding == .source(DecodingFailure(file: 7)))
        #expect(decoding?.sourceError as? DecodingFailure == DecodingFailure(file: 7))
        #expect(report.files == 18)
        #expect(!FileManager.default.fileExists(atPath: directory.path("out/f7").path))
        #expect(try item(directory.path("out/f3")).contents == [9])
    }

    /// A source can fail a file after writing all of it (a checksum it computes as it goes): whole, gathered, streamed,
    /// batched, plain and compressed, the file is removed and its permit given back (with a width of 1, a permit kept
    /// would stop every later file), and the rest is written.
    @Test(arguments: [1, 3])
    func failsFilesAfterTheirLastWrite(_ writes: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // Small (whole or gathered), 300 KB (gathered with 3 writes: one batch), 2 MB (several batches, or streamed), empty.
        let sizes = [100, 5_000, 300_000, 2_000_000, 0, 7_000]
        let files = sizes.enumerated().map { testBytes($0.element, seed: UInt64($0.offset), compressible: true) }
        for (name, storage) in [("plain", Storage.plain), ("compressed", .compressed(.appleArchive))] {
            let source = ArraySource(files, writesPerFile: writes, failingAfterWriting: [0, 2, 3, 4])
            var options = ExtractionSettings()
            options.writers = 2
            options.fileSystemWidth = 1
            options.stopsOnFirstFailure = false
            let out = "out-\(name)"
            let destination = try Destination(directory.filePath(out))
            let report = try await Extraction.run(into: destination, source: source, options: options) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                for index in files.indices {
                    _ = try await planFile(&planner, "f\(index)", index: index, size: files[index].count, storage: storage, tag: index)
                }
            }
            #expect(Set(report.failures.map(\.tag)) == [0, 2, 3, 4])
            #expect(report.failures.allSatisfy { $0.error == .source(DecodingFailure(file: $0.tag)) })
            #expect(report.files == 2 && source.releaseCount == files.count)
            for index in files.indices {
                let exists = FileManager.default.fileExists(atPath: directory.path("\(out)/f\(index)").path)
                #expect(exists == !source.failingAfterWriting.contains(index), "\(index)")
            }
            #expect(try item(directory.path("\(out)/f5")).contents == files[5])
        }
    }

    /// The first failure stops everything and is thrown; contents are still all released.
    @Test func stopsAtTheFirstFailure() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let files = (0..<200).map { testBytes(500, seed: UInt64($0), compressible: true) }
        let source = ArraySource(files, failing: 3)
        let destination = try Destination(directory.filePath("out"))
        let calls = Counter()
        do {
            try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                for index in files.indices {
                    calls.add()
                    _ = try await planFile(&planner, "f\(index)", index: index, size: 500)
                }
            }
            Issue.record("no error")
        } catch {
            // The source's own error, as it threw it.
            guard case .disk(.source(let failure)) = error else { Issue.record("\(error)"); return }
            #expect(failure as? DecodingFailure == DecodingFailure(file: 3))
        }
        // Every file handed to the planner (it stops taking them once stopped) is released once.
        #expect(source.releaseCount == calls.value)
    }

    /// A size that doesn't match the contents fails the file (and removes it).
    @Test func checksContentsAgainstTheSize() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = ArraySource([[1, 2, 3]], writesPerFile: 3)
        let destination = try Destination(directory.filePath("out"))
        await #expect(throws: ExtractionError<DiskError>.self) {
            try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                _ = try await planFile(&planner, "short", index: 0, size: 4)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path("out/short").path))
    }

    /// A plan's own error comes back as `.plan`, after the writers finish what was queued.
    @Test func returnsThePlansOwnError() async throws {
        struct WalkerError: Error {}
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = ArraySource([[1]])
        let destination = try Destination(directory.filePath("out"))
        do {
            try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(WalkerError) in
                _ = try? await planFile(&planner, "one", index: 0, size: 1)
                throw WalkerError()
            }
            Issue.record("no error")
        } catch {
            guard case .plan = error else { Issue.record("\(error)"); return }
        }
        #expect(source.releaseCount == 1)
    }
}

/// `withPath` for async bodies.
func withPathAsync<R>(_ path: String, _ body: (EntryPath) async throws(DiskError) -> R) async throws(DiskError) -> R {
    let bytes = Array(path.utf8)
    return try await bytes.withUnsafeBytesAsyncForTests { (buffer) async throws(DiskError) -> R in
        try await body(try EntryPath(validating: RawSpan(_unsafeBytes: buffer)))
    }
}

@Suite(.bulk) struct ExtractionBulkTests {
    /// Thousands of files, every writer and width combination, random sizes and storage: the tree matches, every
    /// content released once.
    @Test(arguments: [(1, 1), (2, 1), (8, 4), (24, 6), (32, 12)])
    func stress(_ writers: Int, _ width: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var generator = SplitMix64(seed: UInt64(writers * 100 + width))
        let entries = (0..<3_000).map { index -> (String, [UInt8]) in
            let size = Int(generator.next() % 200_000) >> Int(generator.next() % 8)
            return ("d\(index % 37)/e\(index % 5)/f\(index)", testBytes(size, seed: UInt64(index), compressible: index % 4 != 0))
        }
        var options = ExtractionSettings()
        options.writers = writers
        options.fileSystemWidth = width
        options.queueCapacity = 64
        options.queuePathBytes = 4_096
        let destination = try Destination(directory.filePath("out"))
        let (report, source) = try await extract(entries, into: destination, options: options, storage: .compressed(.appleArchive), writesPerFile: Int(generator.next() % 3) + 1)
        #expect(report.files == entries.count && source.releaseCount == entries.count)
        for (path, bytes) in entries { #expect(try item(directory.path("out/\(path)")).contents == bytes) }
    }
}
