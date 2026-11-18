internal import Bytes
internal import CBZip2
import Compression
import zlib

/// Reusable decompression state: decoders for every supported method plus output buffers.
///
/// Create one per worker and pass it to ``ZipArchive/contents(of:using:password:_:)``. Its buffers are
/// allocated once, so steady-state DEFLATE decoding performs no allocations (bzip2, xz, and LZMA set up
/// their libraries' or decoder's state per entry; encrypted entries are decrypted into a buffer that grows
/// to the largest payload). It's `~Copyable` because it uniquely owns its buffers.
@safe
public struct ZipDecoder: ~Copyable {
    /// Which DEFLATE implementation decodes.
    public enum Backend: Sendable, Hashable {
        /// The decoder in this package, built on `Bytes` (`Inflater`).
        case bytes
        /// zlib's `inflate`, for comparison. (Deflate64, which zlib can't read, always uses `Inflater`.)
        case zlib
    }

    /// The implementation this decoder uses for DEFLATE, fixed at creation. It also picks the CRC-32
    /// implementation.
    public let backend: Backend

    /// Output is handed to callers in chunks of at most about this many bytes.
    @usableFromInline static let chunkSize = 1 << 20
    /// The largest window: how far back a back-reference can reach (Deflate64's 64 KB; DEFLATE uses 32 KB of
    /// it). The `Inflater` keeps that much of the previous output at the front of each buffer.
    static let historySize = 64 << 10

    /// What decodes the current entry.
    private enum Codec {
        case inflate(window: Int), zlib, bzip2, lzma, xz
    }

    // zlib, bzip2, and Compression keep back-pointers to their stream structures, so those live at stable
    // heap addresses rather than inline in this (movable) struct. zlib's is created with the decoder (for the
    // zlib backend); the others on first use. Each is `nil` until then.
    private let stream: UnsafeMutablePointer<z_stream>?
    private var bzip: UnsafeMutablePointer<bz_stream>?
    private var xzStream: UnsafeMutablePointer<compression_stream>?
    private var inflater: Inflater
    private var lzma = LZMADecoder()
    /// Two output buffers, each history plus a chunk. The second is used only by the pipelined path; its
    /// pages are untouched otherwise. Raw allocations rather than arrays because the pipelined path sends
    /// chunks of them to child tasks (see ``Chunk``); freed in `deinit`, never reallocated.
    private let buffers: (UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer)
    /// Decrypted payloads, grown as needed (and released after a large one).
    private var decrypted = unsafe UnsafeMutableRawBufferPointer(start: nil, count: 0)
    /// The current entry's compressed input and how much of it has been handed to a C library.
    private var input = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    private var consumed = 0
    private var codec = Codec.inflate(window: 32 << 10)
    /// Whether a bzip2 or xz stream is initialized and must be ended.
    private var streamOpen = false
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
        unsafe bzip = nil
        unsafe xzStream = nil
        let size = Self.historySize + Self.chunkSize
        unsafe buffers = (.allocate(byteCount: size, alignment: 16), .allocate(byteCount: size, alignment: 16))
    }

    deinit {
        if streamOpen {
            switch codec {
            case .bzip2: _ = unsafe BZ2_bzDecompressEnd(bzip!)
            case .xz: _ = unsafe compression_stream_destroy(xzStream!)
            default: break
            }
        }
        if let stream = unsafe stream {
            unsafe inflateEnd(stream)
            unsafe stream.deallocate()
        }
        if let bzip = unsafe bzip { unsafe bzip.deallocate() }
        if let xzStream = unsafe xzStream { unsafe xzStream.deallocate() }
        unsafe buffers.0.deallocate()
        unsafe buffers.1.deallocate()
        unsafe decrypted.deallocate()
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
            try unsafe begin(input, method: ZipArchive.Method.deflated, size: 0, endMarker: false, path: path)
            try run(path: path, body)
        }
    }

    /// Decrypts (if needed) and decompresses an entry's `payload`, calling `body` with each chunk of output.
    ///
    /// The chunks borrow the decoder's buffers and are valid only during each call to `body`. A stored entry
    /// arrives here only when it's encrypted: its plaintext is one chunk.
    ///
    /// - Parameters:
    ///   - payload: The entry's payload, as stored in the archive.
    ///   - entry: The entry.
    ///   - password: The password for an encrypted entry.
    ///   - body: Called with each non-empty chunk, in order.
    /// - Throws: ``ZipError/unsupportedMethod(_:_:)``; the errors of decryption (see ``ZipError``);
    ///   ``ZipError/corruptData(_:)`` for invalid or truncated data; whatever `body` throws.
    @usableFromInline
    mutating func decode(_ payload: RawSpan, entry: ZipEntry, password: String?, _ body: (RawSpan) throws -> Void) throws {
        defer { releaseLargeDecryption() }
        try payload.withUnsafeBytes { payload in
            let input = try unsafe decryptIfNeeded(payload, entry: entry, password: password)
            if entry.method == ZipArchive.Method.stored {
                // Unsafe: a span over the decrypted buffer. Safe: it's this decoder's and isn't touched
                // until the next entry; the span ends with the call.
                if unsafe !input.isEmpty { try body(unsafe RawSpan(_unsafeBytes: input)) }
                return
            }
            try unsafe begin(input, method: entry.method, size: entry.uncompressedSize, endMarker: entry.flags & 0x2 != 0, path: entry.path)
            try run(path: entry.path, body)
        }
    }

    /// Steps the current stream to its end, calling `body` with each chunk, and closes it.
    private mutating func run(path: String, _ body: (RawSpan) throws -> Void) throws {
        defer { closeStream() }
        while true {
            let (chunk, finished) = try unsafe step(into: 0, path: path)
            if unsafe !chunk.isEmpty { try body(unsafe chunk.bytes) }
            if finished { return }
        }
    }

    /// A chunk of decoder output handed to a concurrent consumer. Valid until that consumer returns.
    /// Not `Sendable`: each chunk is created fresh and *sent* to exactly one child task.
    @unsafe
    struct Chunk {
        let bytes: UnsafeRawBufferPointer
    }

    /// Decodes an entry, overlapping `consume` of chunk N (in a child task) with decoding chunk N+1.
    ///
    /// Two buffers alternate: a buffer is decoded into only after the consumer of its previous contents
    /// has finished, and consumers run one at a time, in order. Decoding into a buffer reads the other's
    /// last 32 or 64 KB as history while its consumer may be reading it too: both only read.
    ///
    /// - Parameters:
    ///   - payload: The entry's payload, as stored.
    ///   - entry: The entry: not stored (unless encrypted, then it's one chunk).
    ///   - password: The password for an encrypted entry.
    ///   - consume: Called with each chunk in a child task, one at a time, in order.
    /// - Throws: The errors of ``decode(_:entry:password:_:)``; whatever `consume` throws.
    /// - Precondition: `payload` stays valid for the whole call (it points into a ``MappedFile``).
    mutating func decodePipelined(
        _ payload: UnsafeRawBufferPointer,
        entry: ZipEntry,
        password: String?,
        consume: @escaping @Sendable (Chunk) throws -> Void
    ) async throws {
        defer { releaseLargeDecryption() }
        let input = try unsafe decryptIfNeeded(payload, entry: entry, password: password)
        if entry.method == ZipArchive.Method.stored {
            try unsafe consume(Chunk(bytes: input))
            return
        }
        try unsafe begin(input, method: entry.method, size: entry.uncompressedSize, endMarker: entry.flags & 0x2 != 0, path: entry.path)
        defer { closeStream() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var target = 0
            var consumerRunning = false
            while true {
                let (output, finished) = try unsafe step(into: target, path: entry.path)
                if unsafe !output.isEmpty {
                    // Region isolation (rightly) sees this chunk as part of `self`, since it points into our
                    // buffer. Sending it is still race-free because of the hand-off protocol below: this
                    // buffer isn't written again until its consumer has finished.
                    nonisolated(unsafe) let chunk = unsafe Chunk(bytes: output)
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

    // MARK: Decryption

    /// The payload's compressed data: `payload` itself, or for an encrypted entry, its decryption in
    /// ``decrypted``.
    ///
    /// - Throws: ``ZipError/passwordRequired(_:)`` without a password; ``ZipError/incorrectPassword(_:)``
    ///   when its check fails; ``ZipError/authenticationFailed(_:)`` for an AES entry whose authentication
    ///   code doesn't match; ``ZipError/unsupportedEncryption(_:)``; ``ZipError/truncated(_:)``.
    private mutating func decryptIfNeeded(_ payload: UnsafeRawBufferPointer, entry: ZipEntry, password: String?) throws -> UnsafeRawBufferPointer {
        guard let encryption = entry.encryption else { return unsafe payload }
        if case .unsupported = encryption { throw ZipError.unsupportedEncryption(entry.path) }
        guard let password else { throw ZipError.passwordRequired(entry.path) }
        let key = Array(password.utf8)
        // Unsafe: spans over `payload` (valid for this call) and over `decrypted`, which this decoder owns.
        let source = unsafe RawSpan(_unsafeBytes: payload)
        switch encryption {
        case .traditional:
            let header = TraditionalCipher.headerSize
            guard source.byteCount >= header else { throw ZipError.truncated("encryption header for '\(entry.path)'") }
            var cipher = TraditionalCipher(password: key)
            // With a data descriptor the CRC wasn't known when the header was made: it checks the time instead.
            let expected = entry.flags & 0x8 != 0 ? UInt8(truncatingIfNeeded: entry.dosTime >> 8) : UInt8(truncatingIfNeeded: entry.crc32 >> 24)
            guard cipher.checkByte(source.extracting(0..<header)) == expected else { throw ZipError.incorrectPassword(entry.path) }
            let count = source.byteCount - header
            reserveDecrypted(count)
            var output = unsafe MutableSpan<UInt8>(_unsafeStart: decrypted.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
            cipher.decrypt(Span(viewing: source.extracting(header...)), into: &output)
            return unsafe UnsafeRawBufferPointer(rebasing: decrypted[..<count])
        case let .aes(bits, _):
            let count = WinZipAES.plaintextSize(payloadSize: source.byteCount, bits: bits)
            reserveDecrypted(count)
            do {
                _ = try unsafe WinZipAES.decrypt(source, bits: bits, password: key, into: decrypted)
            } catch {
                switch error {
                case .badPassword: throw ZipError.incorrectPassword(entry.path)
                case .authenticationFailed: throw ZipError.authenticationFailed(entry.path)
                case .truncated: throw ZipError.truncated("encryption header for '\(entry.path)'")
                }
            }
            return unsafe UnsafeRawBufferPointer(rebasing: decrypted[..<count])
        case .unsupported:
            throw ZipError.unsupportedEncryption(entry.path)
        }
    }

    /// Makes ``decrypted`` hold at least `count` bytes (at least one, so its base address isn't `nil`).
    /// Unsafe: raw allocation. Safe: the old buffer isn't referenced past this point (its contents are dead).
    private mutating func reserveDecrypted(_ count: Int) {
        guard unsafe decrypted.count < max(count, 1) else { return }
        unsafe decrypted.deallocate()
        unsafe decrypted = .allocate(byteCount: max(count, 4096), alignment: 16)
    }

    /// Frees a decryption buffer over 64 MB once its entry is done, so one big encrypted entry doesn't pin
    /// its size for the decoder's life.
    private mutating func releaseLargeDecryption() {
        guard unsafe decrypted.count > 64 << 20 else { return }
        unsafe decrypted.deallocate()
        unsafe decrypted = UnsafeMutableRawBufferPointer(start: nil, count: 0)
    }

    // MARK: Stepping

    private mutating func begin(_ input: UnsafeRawBufferPointer, method: UInt16, size: UInt64, endMarker: Bool, path: String) throws {
        closeStream()
        unsafe self.input = input
        consumed = 0
        lastEnd = 0
        switch method {
        case ZipArchive.Method.deflated where backend == .zlib:
            codec = .zlib
            guard unsafe inflateReset(stream!) == Z_OK else { throw ZipError.corruptData(path) }
        case ZipArchive.Method.deflated:
            codec = .inflate(window: 32 << 10)
            inflater.reset()
        case ZipArchive.Method.deflate64:
            codec = .inflate(window: 64 << 10)
            inflater.reset(deflate64: true)
        case ZipArchive.Method.bzip2:
            codec = .bzip2
            if unsafe bzip == nil { unsafe bzip = .allocate(capacity: 1) }
            unsafe bzip!.initialize(to: bz_stream())
            guard unsafe BZ2_bzDecompressInit(bzip!, 0, 0) == BZ_OK else { throw ZipError.corruptData(path) }
            streamOpen = true
        case ZipArchive.Method.xz:
            codec = .xz
            if unsafe xzStream == nil { unsafe xzStream = .allocate(capacity: 1) }
            // Compression's LZMA decoder reads the xz container, which zip method 95 stores.
            guard unsafe compression_stream_init(xzStream!, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
                throw ZipError.corruptData(path)
            }
            streamOpen = true
        case ZipArchive.Method.lzma:
            codec = .lzma
            do {
                try unsafe lzma.reset(payload: RawSpan(_unsafeBytes: input), uncompressedSize: size, hasEndMarker: endMarker)
            } catch {
                throw error == .unsupportedHeader ? ZipError.unsupportedMethod(method, path) : ZipError.corruptData(path)
            }
        default:
            throw ZipError.unsupportedMethod(method, path)
        }
    }

    /// Ends an open bzip2 or xz stream, releasing its library state.
    private mutating func closeStream() {
        guard streamOpen else { return }
        streamOpen = false
        switch codec {
        case .bzip2: _ = unsafe BZ2_bzDecompressEnd(bzip!)
        case .xz: _ = unsafe compression_stream_destroy(xzStream!)
        default: break
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
        switch codec {
        case let .inflate(window):
            // History: the last window of the previous step's output, moved to the front of this buffer.
            let history = min(window, lastEnd)
            if history > 0 {
                let previous = unsafe lastBuffer == 0 ? buffers.0 : buffers.1
                unsafe output.baseAddress!.copyMemory(from: previous.baseAddress! + (lastEnd - history), byteCount: history)
            }
            let (end, finished): (Int, Bool)
            do {
                // Unsafe: spans over memory this type owns. Safe: `buffers` are allocated for the decoder's
                // lifetime, and `input` points into a mapped file or ``decrypted``, which outlive the entry's
                // decoding (see `decodePipelined`); both spans end with this call. Owned buffers can't be safe
                // types here: the pipelined path hands chunks to child tasks across suspension points, which a
                // span or an `Array`'s storage can't outlive.
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
        case .bzip2:
            let chunk = unsafe UnsafeMutableRawBufferPointer(rebasing: output[..<Self.chunkSize])
            let (produced, finished) = try unsafe bzip2Step(into: chunk, path: path)
            return unsafe (UnsafeRawBufferPointer(rebasing: chunk[..<produced]), finished)
        case .xz:
            let chunk = unsafe UnsafeMutableRawBufferPointer(rebasing: output[..<Self.chunkSize])
            let (produced, finished) = try unsafe xzStep(into: chunk, path: path)
            return unsafe (UnsafeRawBufferPointer(rebasing: chunk[..<produced]), finished)
        case .lzma:
            let chunk = unsafe UnsafeMutableRawBufferPointer(rebasing: output[..<Self.chunkSize])
            do {
                // Unsafe: spans over this decoder's buffer and the entry's input, as for `.inflate`.
                var span = unsafe MutableRawSpan(_unsafeBytes: chunk)
                let (produced, finished) = try unsafe lzma.decode(RawSpan(_unsafeBytes: input), into: &span)
                return unsafe (UnsafeRawBufferPointer(rebasing: chunk[..<produced]), finished)
            } catch {
                throw ZipError.corruptData(path)
            }
        }
    }

    /// The next piece of input for a C library whose counts are 32 bits: payloads over 4 GB go in pieces.
    private mutating func nextInput() -> (UnsafeRawPointer?, Int) {
        let count = unsafe min(input.count - consumed, Int(UInt32.max))
        defer { consumed += count }
        return unsafe (input.baseAddress.map { unsafe $0 + consumed }, count)
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
        if unsafe stream.pointee.avail_in == 0, unsafe consumed < input.count {
            let (start, count) = unsafe nextInput()
            unsafe stream.pointee.next_in = UnsafeMutablePointer(mutating: start?.assumingMemoryBound(to: Bytef.self))
            unsafe stream.pointee.avail_in = uInt(count)
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

    /// Runs libbz2 until `output` is full or the stream ends. Unsafe: its C API takes raw pointers and
    /// lengths. Safe: they describe `input` and `output` exactly, valid for the call.
    private mutating func bzip2Step(into output: UnsafeMutableRawBufferPointer, path: String) throws -> (produced: Int, finished: Bool) {
        let stream = unsafe bzip!
        unsafe stream.pointee.next_out = output.baseAddress!.assumingMemoryBound(to: CChar.self)
        unsafe stream.pointee.avail_out = UInt32(output.count)
        while unsafe stream.pointee.avail_out > 0 {
            if unsafe stream.pointee.avail_in == 0, unsafe consumed < input.count {
                let (start, count) = unsafe nextInput()
                unsafe stream.pointee.next_in = UnsafeMutablePointer(mutating: start?.assumingMemoryBound(to: CChar.self))
                unsafe stream.pointee.avail_in = UInt32(count)
            }
            let before = unsafe stream.pointee.avail_out
            let status = unsafe BZ2_bzDecompress(stream)
            let produced = unsafe output.count - Int(stream.pointee.avail_out)
            if status == BZ_STREAM_END { return (produced, true) }
            guard status == BZ_OK else { throw ZipError.corruptData(path) }
            // No output and no input left: truncated.
            if unsafe stream.pointee.avail_out == before, unsafe stream.pointee.avail_in == 0, unsafe consumed >= input.count {
                throw ZipError.corruptData(path)
            }
        }
        return (output.count, false)
    }

    /// Runs Compression's xz decoder until `output` is full or the stream ends. Unsafe: a C API of raw
    /// pointers and lengths. Safe: they describe `input` and `output` exactly, valid for the call.
    private mutating func xzStep(into output: UnsafeMutableRawBufferPointer, path: String) throws -> (produced: Int, finished: Bool) {
        let stream = unsafe xzStream!
        unsafe stream.pointee.dst_ptr = output.baseAddress!.assumingMemoryBound(to: UInt8.self)
        unsafe stream.pointee.dst_size = output.count
        while unsafe stream.pointee.dst_size > 0 {
            if unsafe stream.pointee.src_size == 0, unsafe consumed < input.count {
                // Compression's counts are full-width: hand over the rest at once.
                let count = unsafe input.count - consumed
                unsafe stream.pointee.src_ptr = input.baseAddress!.advanced(by: consumed).assumingMemoryBound(to: UInt8.self)
                unsafe stream.pointee.src_size = count
                consumed += count
            }
            let before = unsafe stream.pointee.dst_size
            let status = unsafe compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = unsafe output.count - stream.pointee.dst_size
            if status == COMPRESSION_STATUS_END { return (produced, true) }
            guard status == COMPRESSION_STATUS_OK else { throw ZipError.corruptData(path) }
            if unsafe stream.pointee.dst_size == before, unsafe stream.pointee.src_size == 0 { throw ZipError.corruptData(path) }
        }
        return (output.count, false)
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

    /// The CRC-32 of two pieces joined, from each piece's CRC-32 and the second's length.
    static func combineCRC32(_ first: UInt32, _ second: UInt32, secondLength: Int) -> UInt32 {
        CRC32.combine(first, second, secondLength: secondLength)
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
