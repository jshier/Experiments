import Compression
import zlib

/// Reusable decompression state: a zlib inflate stream plus an output buffer.
///
/// Create one per worker and pass it to ``ZipArchive/contents(of:using:_:)``. zlib's state is allocated
/// once and reset with `inflateReset` between entries, so steady-state decoding performs no allocations.
/// It's `~Copyable` because it uniquely owns C resources that are released in `deinit`.
@safe
public struct ZipDecoder: ~Copyable {
    /// Output is handed to callers in chunks of at most this many bytes.
    @usableFromInline static let chunkSize = 1 << 20

    // zlib keeps a back-pointer to its `z_stream`, so the stream must live at a stable heap address
    // rather than inline in this (movable) struct.
    private let stream: UnsafeMutablePointer<z_stream>
    private let buffer: UnsafeMutableRawBufferPointer
    /// Second output buffer, used only by the pipelined path; its pages are untouched otherwise.
    private let spare: UnsafeMutableRawBufferPointer
    /// The current entry's compressed input and how much of it has been handed to zlib.
    private var input = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    private var consumed = 0

    public init() {
        unsafe stream = .allocate(capacity: 1)
        unsafe stream.initialize(to: z_stream())
        // Negative window bits: raw DEFLATE (RFC 1951) with no zlib header, as zip method 8 stores it.
        let status = unsafe inflateInit2_(stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        precondition(status == Z_OK, "inflateInit2 failed: \(status)")
        unsafe buffer = .allocate(byteCount: Self.chunkSize, alignment: 16)
        unsafe spare = .allocate(byteCount: Self.chunkSize, alignment: 16)
    }

    deinit {
        unsafe inflateEnd(stream)
        unsafe stream.deallocate()
        unsafe buffer.deallocate()
        unsafe spare.deallocate()
    }

    /// Inflates a complete raw-DEFLATE `payload`, calling `body` with each chunk of output.
    @usableFromInline
    mutating func inflate(_ payload: RawSpan, path: String, _ body: (RawSpan) throws -> Void) throws {
        try payload.withUnsafeBytes { input in
            try unsafe begin(input, path: path)
            while true {
                let (produced, finished) = try unsafe step(into: buffer, path: path)
                if produced > 0 {
                    try body(unsafe UnsafeRawBufferPointer(rebasing: buffer[..<produced]).bytes)
                }
                if finished { return }
            }
        }
    }

    /// A chunk of decoder output handed to a concurrent consumer. Valid until that consumer returns.
    /// Not `Sendable`: each chunk is created fresh and *sent* to exactly one child task.
    @unsafe
    struct Chunk {
        let bytes: UnsafeRawBufferPointer
    }

    /// Inflates `input`, overlapping `consume` of chunk N (in a child task) with inflating chunk N+1.
    ///
    /// Two buffers alternate: a buffer is decoded into only after the consumer of its previous contents
    /// has finished, and consumers run one at a time, in order. `observe` sees each chunk first, in the
    /// decoding task (for CRC and size accounting).
    ///
    /// - Precondition: `input` stays valid for the whole call (it points into a ``MappedFile``).
    mutating func inflatePipelined(
        _ input: UnsafeRawBufferPointer,
        path: String,
        observe: (RawSpan) -> Void,
        consume: @escaping @Sendable (Chunk) throws -> Void
    ) async throws {
        try unsafe begin(input, path: path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var useSpare = false
            var consumerRunning = false
            while true {
                let output = unsafe useSpare ? spare : buffer
                let (produced, finished) = try unsafe step(into: output, path: path)
                if produced > 0 {
                    // Region isolation (rightly) sees this chunk as part of `self`, since it points into our
                    // buffer. Sending it is still race-free because of the hand-off protocol below: this
                    // buffer isn't touched again until its consumer has finished.
                    nonisolated(unsafe) let chunk = unsafe Chunk(bytes: UnsafeRawBufferPointer(rebasing: output[..<produced]))
                    observe(unsafe chunk.bytes.bytes)
                    // The previous consumer must finish before the next starts (ordering), and before
                    // its buffer is decoded into again (which happens on the following iteration).
                    if consumerRunning { try await group.next() }
                    group.addTask { try unsafe consume(chunk) }
                    consumerRunning = true
                    useSpare.toggle()
                }
                if finished { break }
            }
            try await group.waitForAll()
        }
    }

    private mutating func begin(_ input: UnsafeRawBufferPointer, path: String) throws {
        guard unsafe inflateReset(stream) == Z_OK else { throw ZipError.corruptData(path) }
        unsafe self.input = input
        consumed = 0
    }

    /// Runs zlib until `output` is full or the stream ends.
    private mutating func step(into output: UnsafeMutableRawBufferPointer, path: String) throws -> (produced: Int, finished: Bool) {
        // `avail_in` is 32 bits, so feed payloads larger than 4 GB in pieces.
        if unsafe stream.pointee.avail_in == 0, unsafe consumed < input.count {
            let count = unsafe min(input.count - consumed, Int(UInt32.max))
            unsafe stream.pointee.next_in = UnsafeMutablePointer(
                mutating: input.baseAddress!.advanced(by: consumed).assumingMemoryBound(to: Bytef.self)
            )
            unsafe stream.pointee.avail_in = uInt(count)
            consumed += count
        }
        unsafe stream.pointee.next_out = output.baseAddress!.assumingMemoryBound(to: Bytef.self)
        unsafe stream.pointee.avail_out = uInt(output.count)
        let status = unsafe zlib.inflate(stream, Z_NO_FLUSH)
        let produced = unsafe output.count - Int(stream.pointee.avail_out)
        let pendingInput = unsafe stream.pointee.avail_in > 0 || consumed < input.count
        switch status {
        case Z_STREAM_END: return (produced, true)
        case Z_OK where produced > 0 || pendingInput: return (produced, false)
        default: throw ZipError.corruptData(path) // Errors, or no progress possible (truncated input).
        }
    }
}

// MARK: - Benchmarking hooks

/// Alternative DEFLATE implementations, exposed only so benchmarks can compare them.
@_spi(Benchmarking)
public enum DeflateBackends {
    /// Compression.framework's one-shot decoder (COMPRESSION_ZLIB is raw DEFLATE). Returns bytes produced.
    public static func compressionOneShot(_ payload: RawSpan, into output: inout [UInt8]) -> Int {
        let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_ZLIB)
        return withUnsafeTemporaryAllocation(byteCount: scratchSize, alignment: 16) { scratch in
            payload.withUnsafeBytes { input in
                output.withUnsafeMutableBufferPointer { output in
                    unsafe compression_decode_buffer(
                        output.baseAddress!, output.count,
                        input.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
                        scratch.baseAddress, COMPRESSION_ZLIB
                    )
                }
            }
        }
    }

    /// CRC-32 as used for entry verification.
    public static func crc32(_ bytes: RawSpan) -> UInt32 {
        UInt32(truncatingIfNeeded: NativeZip.crc32(0, bytes))
    }
}

/// CRC-32 via zlib (hardware-accelerated). Its C API isn't bounds-annotated, so it takes the span's pointer.
@usableFromInline
func crc32(_ crc: UInt, _ bytes: RawSpan) -> UInt {
    bytes.withUnsafeBytes { buffer in
        unsafe UInt(zlib.crc32_z(uLong(crc), buffer.baseAddress?.assumingMemoryBound(to: Bytef.self), buffer.count))
    }
}
