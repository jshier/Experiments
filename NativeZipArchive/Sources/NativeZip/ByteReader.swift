/// A forward-only, bounds-checked reader of little-endian fields over borrowed bytes.
///
/// The original parser's reader, kept for the benchmarks' comparison with `Bytes`' `BytesReader` (see
/// `ZipArchive.entriesUsingByteReader(of:)`).
///
/// It's `~Escapable`: it can't outlive the memory it reads (for us, the memory-mapped archive),
/// and every sub-span it hands out carries that same lifetime. Nothing is copied.
struct ByteReader: ~Escapable {
    private(set) var remaining: RawSpan

    @_lifetime(copy bytes)
    init(_ bytes: RawSpan) {
        remaining = bytes
    }

    /// Starts reading `bytes` at `offset`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to read.
    ///   - offset: Where to start, from 0 through `bytes.byteCount` (the end is allowed).
    /// - Throws: ``ZipError/truncated(_:)`` if `offset` is outside that range.
    @_lifetime(copy bytes)
    init(_ bytes: RawSpan, at offset: Int) throws(ZipError) {
        guard offset >= 0, offset <= bytes.byteCount else { throw .truncated("record at offset \(offset)") }
        remaining = bytes.extracting(droppingFirst: offset)
    }

    var isEmpty: Bool { remaining.byteCount == 0 }
    var count: Int { remaining.byteCount }

    @_lifetime(self: copy self)
    mutating func read<T: FixedWidthInteger & ConvertibleFromBytes>(_: T.Type = T.self) throws(ZipError) -> T {
        let size = MemoryLayout<T>.size
        guard remaining.byteCount >= size else { throw .truncated("\(T.self)") }
        defer { remaining = remaining.extracting(droppingFirst: size) }
        return remaining.load(fromByteOffset: 0, as: T.self, .littleEndian)
    }

    /// Reads a 4-byte little-endian signature and checks it.
    ///
    /// - Parameters:
    ///   - signature: The expected value.
    ///   - what: Names the record, for the error; evaluated only on a mismatch.
    /// - Throws: ``ZipError/badSignature(_:)`` with `what` if it doesn't match; ``ZipError/truncated(_:)`` if
    ///   fewer than 4 bytes remain.
    @_lifetime(self: copy self)
    mutating func expect(_ signature: UInt32, _ what: @autoclosure () -> String) throws(ZipError) {
        guard try read(UInt32.self) == signature else { throw .badSignature(what()) }
    }

    /// Consumes the next `count` bytes and returns them as a span borrowing the same memory.
    ///
    /// - Parameter count: The number of bytes to consume.
    /// - Returns: The consumed bytes.
    /// - Throws: ``ZipError/truncated(_:)`` if `count` is negative or more than remain.
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func read(count: Int) throws(ZipError) -> RawSpan {
        guard count >= 0, count <= remaining.byteCount else { throw .truncated("\(count) bytes") }
        defer { remaining = remaining.extracting(droppingFirst: count) }
        return remaining.extracting(first: count)
    }

    @_lifetime(self: copy self)
    mutating func skip(_ count: Int) throws(ZipError) {
        _ = try read(count: count)
    }
}
