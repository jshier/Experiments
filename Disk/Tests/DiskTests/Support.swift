import BytesTestSupport
import Darwin
@testable import Disk
import Foundation
import Synchronization
import System
import Testing

// Temporary directories (`TemporaryDirectory`, removed with read-only files and ACLs) and `ExternalTool.run` are Bytes'
// `BytesTestSupport`; the bulk trait is `BytesTesting`'s. Reading what an extraction wrote (`readTree`, `readItem`,
// extended attributes, ACLs, `decmpfs`) is `DiskTestSupport`.

extension TemporaryDirectory {
    convenience init() throws {
        try self.init(prefix: "DiskTests")
    }

    /// `name` in the directory, as a `FilePath`.
    func filePath(_ name: String) -> FilePath { FilePath(path(name).path(percentEncoded: false)) }
}

/// An `EntryPath` from a string literal (tests only: traps on an invalid one). The string is copied into a buffer the
/// path borrows for `body`.
func withEntryPath<R>(_ string: String, _ body: (EntryPath) throws -> R) throws -> R {
    let bytes = Array(string.utf8)
    return try bytes.withUnsafeBytes { buffer in
        let span = RawSpan(_unsafeBytes: buffer)
        return try body(EntryPath(validating: span))
    }
}

/// Deterministic bytes: `compressible` repeats text; otherwise random.
func testBytes(_ count: Int, seed: UInt64, compressible: Bool) -> [UInt8] {
    if compressible { return SampleBytes.text(count, seed: seed) }
    var generator = SplitMix64(seed: seed)
    return generator.bytes(count)
}

/// An item's `lstat`, or `nil` if it isn't there.
func stat(_ url: URL) -> stat? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? info : nil
}

/// A source's own error (``ArraySource``'s failing file), which Disk carries back in ``DiskError/source(_:)``.
struct DecodingFailure: Error, Equatable {
    var file: Int
}

/// Files' contents held in memory, handed out whole or in `pieces` writes; counts releases, to check every job's
/// contents are released exactly once.
final class ArraySource: ContentSource, PieceSource, @unchecked Sendable {
    // Unchecked: `files` is set before the extraction and only read during it; the counts are atomic.
    let files: [[UInt8]]
    /// Writes per file: 1 (whole, in place) or more (gathered or streamed).
    let writesPerFile: Int
    /// Fail the file with this index (a decoding error).
    let failing: Int?
    /// Fail the files with these indexes after writing all their bytes (a checksum that comes out wrong).
    let failingAfterWriting: Set<Int>
    let released = Atomic<Int>(0)
    let retained = Atomic<Int>(0)
    /// A delay per file, for cancellation tests.
    let delay: Duration?

    /// Pieces of large files: copies the writers may overwrite.
    let pieces = Mutex<[[UInt8]]>([])
    let pieceStorage: [UnsafeMutableRawBufferPointer]

    init(_ files: [[UInt8]], writesPerFile: Int = 1, failing: Int? = nil, failingAfterWriting: Set<Int> = [], delay: Duration? = nil, pieces: [[UInt8]] = []) {
        self.files = files
        self.writesPerFile = writesPerFile
        self.failing = failing
        self.failingAfterWriting = failingAfterWriting
        self.delay = delay
        pieceStorage = pieces.map { piece in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, piece.count), alignment: 16)
            piece.withUnsafeBytes { buffer.copyMemory(from: $0) }
            return buffer
        }
    }

    deinit {
        for buffer in pieceStorage { buffer.deallocate() }
    }

    /// A file (`index >= 0`) or a piece (`-1 - index`).
    typealias Contents = Int

    func write(_ contents: Int, to output: inout FileOutput) async throws(DiskError) {
        if let delay { try? await Task.sleep(for: delay) }
        if contents == failing { throw .source(DecodingFailure(file: contents)) }
        let bytes = files[contents]
        let writes = max(1, writesPerFile)
        let step = max(1, (bytes.count + writes - 1) / writes)
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + step)
            try await bytes.withUnsafeBytesAsyncForTests { buffer throws(DiskError) in
                try await output.write(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: buffer[offset..<end])))
            }
            offset = end
        }
        if failingAfterWriting.contains(contents) { throw .source(DecodingFailure(file: contents)) }
    }

    var releaseCount: Int { released.load(ordering: .relaxed) }
    var retainCount: Int { retained.load(ordering: .relaxed) }

    func release(_ contents: Int) {
        released.add(1, ordering: .relaxed)
    }

    func retain(_ contents: Int) {
        retained.add(1, ordering: .relaxed)
    }

    func withPiece<R>(_ contents: Int, _ body: (inout MutableRawSpan) throws(DiskError) -> R) throws(DiskError) -> R {
        let buffer = pieceStorage[-1 - contents]
        var span = MutableRawSpan(_unsafeBytes: buffer)
        return try body(&span)
    }
}

extension Array where Element == UInt8 {
    /// The array's bytes for an async body (the array is kept alive by the caller for the call).
    func withUnsafeBytesAsyncForTests<R, E: Error>(_ body: (UnsafeRawBufferPointer) async throws(E) -> R) async throws(E) -> R {
        let buffer = withUnsafeBytes { $0 }
        defer { withExtendedLifetime(self) {} }
        return try await body(buffer)
    }
}

/// Runs an extraction of `files` (path, bytes) and `directories` into `destination`, all files planned as given.
@discardableResult
func extract(
    _ entries: [(path: String, bytes: [UInt8])], into destination: Destination, options: ExtractionSettings = .init(),
    storage: Storage = .plain, writesPerFile: Int = 1, metadata: EntryMetadata = .init()
) async throws -> (ExtractionReport, ArraySource) {
    let source = ArraySource(entries.map(\.bytes), writesPerFile: writesPerFile)
    let report = try await Extraction.run(into: destination, source: source, settings: options) { (planner: inout Planner<ArraySource>) throws(DiskError) in
        for (index, entry) in entries.enumerated() {
            _ = try await planFile(&planner, entry.path, index: index, size: entry.bytes.count, metadata: metadata, storage: storage)
        }
    }
    return (report, source)
}

/// Plans one file whose contents are `ArraySource` file `index`.
func planFile<S: ContentSource>(
    _ planner: inout Planner<S>, _ path: String, index: S.Contents, size: Int?, metadata: EntryMetadata = .init(),
    storage: Storage = .plain, attachments: Bool = false, hardLinked: Bool = false, tag: Int = 0
) async throws(DiskError) -> EntryToken {
    let bytes = Array(path.utf8)
    return try await bytes.withUnsafeBytesAsyncForTests { (buffer) async throws(DiskError) -> EntryToken in
        let entry = try EntryPath(validating: RawSpan(_unsafeBytes: buffer))
        return try await planner.file(entry, size: size, contents: index, metadata: metadata, storage: storage, attachments: attachments, hardLinked: hardLinked, tag: tag)
    }
}

/// Calls `body` with an `EntryPath` for `path` (for planner calls).
@discardableResult
func withPath<R, E: Error>(_ path: String, _ body: (EntryPath) throws(E) -> R) throws(E) -> R {
    let bytes = Array(path.utf8)
    let buffer = bytes.withUnsafeBytes { $0 }
    defer { withExtendedLifetime(bytes) {} }
    // Test paths are valid.
    return try body(try! EntryPath(validating: RawSpan(_unsafeBytes: buffer)))
}
