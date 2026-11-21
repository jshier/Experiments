/// Where a scheduled file's contents come from: the client's memory (decoded archive buffers, a mapping) or its decoder,
/// named by a small value the write queue carries.
///
/// The scheduler never copies a file's bytes unless the source hands them over in several writes: a writer calls
/// ``write(_:to:)``, which gives it the bytes (in place, from the source's own memory), and ``release(_:)`` when it's
/// done with them (written, skipped, or failed), so the source can reuse the memory.
///
/// ```swift
/// // An archive whose decoded buffers are reference-counted (NativeAEA's pool):
/// struct PoolSource: ContentSource {
///     let pool: BufferPool
///     struct Contents: Sendable { var buffer: Int32; var offset: Int32; var count: Int32 }
///     func write(_ contents: Contents, to output: inout FileOutput) async throws(DiskError) {
///         try await output.write(pool.span(contents))   // the whole file, in place
///     }
///     func release(_ contents: Contents) { pool.release(Int(contents.buffer)) }
/// }
/// ```
public protocol ContentSource: Sendable {
    /// What a job carries to name a file's contents: a buffer index and range, an entry, a decoder's input.
    associatedtype Contents: Sendable

    /// Gives a writer the file's bytes: in one ``FileOutput/write(_:)`` (most files: written as they are), or
    /// several (decoded a chunk at a time). Runs on the writer, outside the file system limit: decoding here is CPU
    /// work like compression.
    func write(_ contents: Contents, to output: inout FileOutput) async throws(DiskError)

    /// The writer is done with `contents`. Called exactly once per scheduled file, whatever happened.
    func release(_ contents: Contents)

    /// Holds `contents` for one more ``release(_:)``: pieces of large files only (``PieceSource``).
    func retain(_ contents: Contents)

    /// Calls `body` with a piece's bytes, which the writer may overwrite: no other job reads them. They must stay at
    /// the same address until the last ``release(_:)`` (the writer uses them across its waits). Pieces of large files
    /// only (``PieceSource``).
    func withPiece<R>(_ contents: Contents, _ body: (inout MutableRawSpan) throws(DiskError) -> R) throws(DiskError) -> R
}

extension ContentSource {
    /// Sources of whole files only: never called.
    public func retain(_ contents: Contents) {}

    /// Sources of whole files only: never called (the large-file methods need a ``PieceSource``).
    public func withPiece<R>(_ contents: Contents, _ body: (inout MutableRawSpan) throws(DiskError) -> R) throws(DiskError) -> R {
        preconditionFailure("withPiece: not a PieceSource")
    }
}

/// A source of large files that arrive in pieces (``Planner/beginLargeFile(_:size:metadata:storage:first:minimumPieceSize:tag:)``):
/// each piece's bytes stay valid, and are the job's alone, until it's released.
///
/// Writers compress a piece in place, over its own consumed input, so a piece needs no memory of its own; and a
/// piece in which no 64 KiB chunk ends is held (``retain(_:)``) by the job of the piece that completes the chunk.
///
/// A piece source implements ``ContentSource/retain(_:)`` and ``ContentSource/withPiece(_:_:)``.
public protocol PieceSource: ContentSource {}

/// Contents already in memory for the whole extraction (a mapped file, arrays the caller keeps): ranges of one
/// buffer, nothing released.
@safe
public struct MemorySource: ContentSource, @unchecked Sendable {
    /// The bytes, at a stable address the caller keeps for the whole extraction.
    let base: UnsafeRawPointer
    let count: Int

    /// Contents: a range of the buffer.
    public typealias Contents = Range<Int>

    /// A source over `count` bytes at `base`.
    ///
    /// The caller keeps the bytes valid and unchanged until ``Extraction/run(into:source:options:_:)`` returns: an
    /// `@unsafe` entry point, for clients whose bytes are already mapped (measured: no copy into a staging buffer).
    @unsafe
    public init(base: UnsafeRawPointer, count: Int) {
        // Unsafe: stores the caller's pointer. Safe: read only by `write`, during the extraction, while the caller
        // keeps the bytes valid and unchanged (this initializer's contract).
        unsafe self.base = base
        self.count = count
    }

    public func write(_ contents: Range<Int>, to output: inout FileOutput) async throws(DiskError) {
        precondition(contents.lowerBound >= 0 && contents.upperBound <= count, "contents outside the source")
        // Unsafe: a span over raw memory at `base` plus an offset. Safe: within the caller's `count` bytes (checked
        // above), valid for the extraction (the initializer's contract); the span is used only in this call.
        let span = unsafe RawSpan(_unsafeStart: base + contents.lowerBound, byteCount: contents.count)
        try await output.write(span)
    }

    public func release(_ contents: Range<Int>) {}
}

