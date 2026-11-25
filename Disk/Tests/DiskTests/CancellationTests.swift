@testable import Disk
import BytesAsync
import BytesTestSupport
import Darwin
import DiskTestSupport
import Foundation
import System
import Testing

/// Cancelling midway: the extraction stops promptly, every content is released once, no descriptor is left open, and
/// nothing is left half-written (finished files stay; a file being written is removed).
@Suite(.diskLifetimes) struct CancellationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [1, 50, 400])
    func cancellingStopsEverything(_ cancelAfter: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let files = (0..<2_000).map { testBytes(2_000 + $0 % 7_000, seed: UInt64($0), compressible: $0 % 2 == 0) }
        let source = ArraySource(files, delay: .microseconds(200))
        let destination = try Destination(directory.filePath("out"))
        defer { destination.close() }
        let planned = RelaxedCounter()
        let task = Task {
            try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                for index in files.indices {
                    planned.add()
                    _ = try await planFile(&planner, "d\(index % 10)/f\(index)", index: index, size: files[index].count, storage: .compressed(.appleArchive))
                }
            }
        }
        while planned.value < cancelAfter {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        let result = await task.result
        guard case let .failure(error) = result, case .disk(.cancelled)? = error as? ExtractionError<DiskError, DecodingFailure> else {
            Issue.record("expected cancellation, got \(result)")
            return
        }
        #expect(source.releaseCount == planned.value)
        // Only the destination's own, until it's closed: the extraction closed everything it opened.
        #expect(OpenFiles.paths(under: directory.url).count == 1)
        destination.close()
        #expect(OpenFiles.paths(under: directory.url).isEmpty)
        // Every file there is complete.
        for (path, item) in try readTree(directory.path("out")) where item.kind == .file {
            let index = Int(path.split(separator: "/").last!.dropFirst())!
            #expect(item.contents == files[index], "\(path)")
        }
    }

    /// Cancelled with a large file's pieces outstanding: the half-written file is removed.
    @Test(.timeLimit(.minutes(1)))
    func cancellingMidFileRemovesIt() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let size = 4_000_000
        let bytes = testBytes(size, seed: 3, compressible: true)
        let pieces = stride(from: 0, to: size, by: 100_000).map { Array(bytes[$0..<min(size, $0 + 100_000)]) }
        let source = ArraySource([], pieces: pieces)
        let destination = try Destination(directory.filePath("out"))
        defer { destination.close() }
        let queued = RelaxedCounter()
        let task = Task {
            try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                let file = try await withPathAsync("big") { path async throws(DiskError) in
                    try await planner.beginLargeFile(path, size: size, storage: .compressed(.appleArchive), first: bytes.span.bytes, minimumPieceSize: 100_000)
                }
                for index in pieces.indices {
                    try await planner.piece(-1 - index, of: file, at: index * 100_000, count: pieces[index].count)
                    queued.add()
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        while queued.value < 5 {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        _ = await task.result
        #expect(source.releaseCount == queued.value + source.retainCount || source.releaseCount == queued.value + 1 + source.retainCount)
        #expect(!FileManager.default.fileExists(atPath: directory.path("out/big").path))
    }
}
