internal import Bytes
import Compression
import zlib

/// Reusable decompression state: a DEFLATE decoder plus output buffers.
///
/// Create one per worker and pass it to ``ZipArchive/contents(of:using:_:)``. Everything is allocated once,
/// so steady-state decoding performs no allocations. It's `~Copyable` because it uniquely owns its buffers.
@safe
public struct ZipDecoder: ~Copyable {
    /// Which DEFLATE implementation decodes.
    public enum Backend: Sendable, Hashable {
        /// The decoder in this package, built on `Bytes` (`Inflater`).
        case bytes
        /// zlib's `inflate`, for comparison.
        case zlib
    }

    /// The implementation this decoder uses, fixed at creation. It also picks the CRC-32 implementation.
    public let backend: Backend

    /// Output is handed to callers in chunks of at most about this many bytes.
    @usableFromInline static let chunkSize = 1 << 20
    /// The DEFLATE window: how far back a back-reference can reach. The `Bytes` decoder keeps this much of
    /// the previous output at the front of each buffer.
    static let historySize = 32 << 10

    // zlib keeps a back-pointer to its `z_stream`, so the stream must live at a stable heap address
    // rather than inline in this (movable) struct. `nil` for the `Bytes` backend.
    private let stream: UnsafeMutablePointer<z_stream>?
    private var inflater: Inflater
    /// Two output buffers, each history plus a chunk. The second is used only by the pipelined path; its
    /// pages are untouched otherwise. Raw allocations rather than arrays because the pipelined path sends
    /// chunks of them to child tasks (see ``Chunk``); freed in `deinit`, never reallocated.
    private let buffers: (UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer)
    /// The current entry's compressed input and how much of it has been handed to zlib.
    private var input = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    private var consumed = 0
    /// Where the last step's output ended, and in which buffer: the next step's history.
    private var lastBuffer = 0
    private var lastEnd = 0

    /// Creates a decoder and allocates its buffers (about 2 MB; the second buffer's pages are touched only by
    /// pipelined extraction).
    ///
    /// - Parameter backend: Which DEFLATE implementation decodes.
    /// - Precondition: For ``Backend/zlib``, zlib initializes successfully.
    public init(backend: Backend = .bytes) {
        self.backend = backend
        inflater = Inflater()
        if backend == .zlib {
            let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            unsafe stream.initialize(to: z_stream())
            // Negative window bits: raw DEFLATE (RFC 1951) with no zlib header, as zip method 8 stores it.
            let status = unsafe inflateInit2_(stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            precondition(status == Z_OK, "inflateInit2 failed: \(status)")
            unsafe self.stream = stream
        } else {
            unsafe stream = nil
        }
        let size = Self.historySize + Self.chunkSize
        unsafe buffers = (.allocate(byteCount: size, alignment: 16), .allocate(byteCount: size, alignment: 16))
    }

    deinit {
        if let stream = unsafe stream {
            unsafe inflateEnd(stream)
            unsafe stream.deallocate()
        }
        unsafe buffers.0.deallocate()
        unsafe buffers.1.deallocate()
    }

    /// Inflates a complete raw-DEFLATE `payload`, calling `body` with each chunk of output.
    ///
    /// The chunks borrow the decoder's buffer and are valid only during each call to `body`.
    ///
    /// - Parameters:
    ///   - payload: The compressed stream.
    ///   - path: The entry's name, for errors.
    ///   - body: Called with each non-empty chunk, in order.
    /// - Throws: ``ZipError/corruptData(_:)`` for invalid or truncated data; whatever `body` throws.
    @usableFromInline
    mutating func inflate(_ payload: RawSpan, path: String, _ body: (RawSpan) throws -> Void) throws {
        try payload.withUnsafeBytes { input in
            try unsafe begin(input, path: path)
            while true {
                let (chunk, finished) = try unsafe step(into: 0, path: path)
                if unsafe !chunk.isEmpty { try body(unsafe chunk.bytes) }
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
    /// has finished, and consumers run one at a time, in order. Decoding into a buffer reads the other's
    /// last 32 KB as history while its consumer may be reading it too: both only read. `observe` sees each
    /// chunk first, in the decoding task (for CRC and size accounting).
    ///
    /// - Parameters:
    ///   - input: The compressed stream.
    ///   - path: The entry's name, for errors.
    ///   - observe: Called with each chunk before it's consumed, in the decoding task.
    ///   - consume: Called with each chunk in a child task, one at a time, in order.
    /// - Throws: ``ZipError/corruptData(_:)`` for invalid or truncated data; whatever `consume` throws.
    /// - Precondition: `input` stays valid for the whole call (it points into a ``MappedFile``).
    mutating func inflatePipelined(
        _ input: UnsafeRawBufferPointer,
        path: String,
        observe: (RawSpan) -> Void,
        consume: @escaping @Sendable (Chunk) throws -> Void
    ) async throws {
        try unsafe begin(input, path: path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var target = 0
            var consumerRunning = false
            while true {
                let (output, finished) = try unsafe step(into: target, path: path)
                if unsafe !output.isEmpty {
                    // Region isolation (rightly) sees this chunk as part of `self`, since it points into our
                    // buffer. Sending it is still race-free because of the hand-off protocol below: this
                    // buffer isn't written again until its consumer has finished.
                    nonisolated(unsafe) let chunk = unsafe Chunk(bytes: output)
                    observe(unsafe chunk.bytes.bytes)
                    // The previous consumer must finish before the next starts (ordering), and before
                    // its buffer is decoded into again (which happens on the following iteration).
                    if consumerRunning { try await group.next() }
                    group.addTask { try unsafe consume(chunk) }
                    consumerRunning = true
                    target ^= 1
                }
                if finished { break }
            }
            try await group.waitForAll()
        }
    }

    private mutating func begin(_ input: UnsafeRawBufferPointer, path: String) throws {
        unsafe self.input = input
        consumed = 0
        lastEnd = 0
        switch backend {
        case .bytes:
            inflater.reset()
        case .zlib:
            guard unsafe inflateReset(stream!) == Z_OK else { throw ZipError.corruptData(path) }
        }
    }

    /// Decodes the next chunk into buffer `index` (0 or 1).
    ///
    /// - Parameters:
    ///   - index: Which of the two buffers to decode into.
    ///   - path: The entry's name, for errors.
    /// - Returns: The chunk (excluding history) and whether the stream ended.
    /// - Throws: ``ZipError/corruptData(_:)`` for invalid or truncated data.
    private mutating func step(into index: Int, path: String) throws -> (chunk: UnsafeRawBufferPointer, finished: Bool) {
        let output = unsafe index == 0 ? buffers.0 : buffers.1
        switch backend {
        case .bytes:
            // History: the last 32 KB of the previous step's output, moved to the front of this buffer.
            let history = min(Self.historySize, lastEnd)
            if history > 0 {
                let previous = unsafe lastBuffer == 0 ? buffers.0 : buffers.1
                unsafe output.baseAddress!.copyMemory(from: previous.baseAddress! + (lastEnd - history), byteCount: history)
            }
            let (end, finished): (Int, Bool)
            do {
                // Unsafe: spans over memory this type owns. Safe: `buffers` are allocated for the decoder's
                // lifetime, and `input` points into a mapped file that outlives the entry's decoding (see
                // `inflatePipelined`); both spans end with this call. Owned buffers can't be safe types here:
                // the pipelined path hands chunks to child tasks across suspension points, which a span or an
                // `Array`'s storage can't outlive.
                var span = unsafe MutableRawSpan(_unsafeBytes: output)
                (end, finished) = try unsafe inflater.decode(RawSpan(_unsafeBytes: input), into: &span, start: history)
            } catch {
                throw ZipError.corruptData(path)
            }
            lastBuffer = index
            lastEnd = end
            return unsafe (UnsafeRawBufferPointer(rebasing: output[history..<end]), finished)
        case .zlib:
            let chunk = unsafe UnsafeMutableRawBufferPointer(rebasing: output[..<Self.chunkSize])
            let (produced, finished) = try unsafe zlibStep(into: chunk, path: path)
            return unsafe (UnsafeRawBufferPointer(rebasing: chunk[..<produced]), finished)
        }
    }

    /// Runs zlib until `output` is full or the stream ends. Unsafe: zlib's C API takes raw pointers and
    /// lengths. Safe: they describe `input` and `output` exactly, and zlib doesn't keep them past the call.
    ///
    /// - Parameters:
    ///   - output: Where to write.
    ///   - path: The entry's name, for errors.
    /// - Returns: The bytes written and whether the stream ended.
    /// - Throws: ``ZipError/corruptData(_:)`` on a zlib error or if no progress is possible (truncated input).
    private mutating func zlibStep(into output: UnsafeMutableRawBufferPointer, path: String) throws -> (produced: Int, finished: Bool) {
        let stream = unsafe stream!
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

/// Alternative DEFLATE implementations, exposed only so benchmarks and tests can compare them.
@_spi(Benchmarking)
public enum DeflateBackends {
    /// Decodes with Compression.framework's one-shot decoder (COMPRESSION_ZLIB is raw DEFLATE).
    ///
    /// Unsafe: a C API of pointers and lengths, each describing a buffer valid for the call.
    ///
    /// - Parameters:
    ///   - payload: The compressed stream.
    ///   - output: Where to write; its count is the capacity.
    /// - Returns: The number of bytes produced (0 on failure).
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

    /// Inflates a raw-DEFLATE `payload` with `decoder`, without verifying a size or CRC-32.
    ///
    /// - Parameters:
    ///   - payload: The compressed stream.
    ///   - decoder: The decoder to use.
    ///   - discarding: If `true`, the output is dropped, for timing decoding alone.
    /// - Returns: The output, or an empty array if `discarding`.
    /// - Throws: ``ZipError/corruptData(_:)`` for invalid or truncated data.
    public static func inflate(_ payload: RawSpan, using decoder: inout ZipDecoder, discarding: Bool = false) throws -> [UInt8] {
        var output: [UInt8] = []
        try decoder.inflate(payload, path: "payload") { chunk in
            if !discarding { output.append(copying: chunk) }
        }
        return output
    }

    /// The CRC-32 of `bytes` with `backend`'s implementation, as entry verification computes it.
    ///
    /// - Parameters:
    ///   - bytes: The data to checksum.
    ///   - backend: Whose CRC-32 to use.
    /// - Returns: The checksum.
    public static func crc32(_ bytes: RawSpan, backend: ZipDecoder.Backend) -> UInt32 {
        UInt32(truncatingIfNeeded: ZipDecoder.crc32(0, bytes, backend: backend))
    }
}

extension ZipDecoder {
    /// `crc` (a CRC-32) updated with `bytes`, by `backend`'s implementation: `Bytes`' `CRC32` with the
    /// `Bytes` decoder, zlib's with zlib's. Static, taking the backend, so it can run inside `inflate`'s
    /// callbacks, which can't access the decoder. Not inlinable: `Bytes` is an internal import.
    ///
    /// - Parameters:
    ///   - crc: The CRC-32 so far (0 to start).
    ///   - bytes: The next data.
    ///   - backend: Whose CRC-32 to use.
    /// - Returns: The updated CRC-32, in the low 32 bits.
    @usableFromInline
    static func crc32(_ crc: UInt, _ bytes: RawSpan, backend: Backend) -> UInt {
        switch backend {
        case .bytes:
            UInt(CRC32.checksum(bytes, continuing: UInt32(truncatingIfNeeded: crc)))
        case .zlib:
            zlibCRC32(crc, bytes)
        }
    }
}

/// CRC-32 via zlib (hardware-accelerated). Its C API isn't bounds-annotated, so it takes the span's pointer
/// and count, valid for the call.
///
/// - Parameters:
///   - crc: The CRC-32 so far (0 to start).
///   - bytes: The next data.
/// - Returns: The updated CRC-32.
func zlibCRC32(_ crc: UInt, _ bytes: RawSpan) -> UInt {
    bytes.withUnsafeBytes { buffer in
        unsafe UInt(zlib.crc32_z(uLong(crc), buffer.baseAddress?.assumingMemoryBound(to: Bytef.self), buffer.count))
    }
}
