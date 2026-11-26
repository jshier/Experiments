internal import Bytes
internal import BytesAsync
internal import BytesCompression
import Synchronization

/// Reusable decompression state: a decoder for every supported method plus output buffers.
///
/// Create one per worker and pass it to ``ZipArchive/contents(of:using:password:_:)-77zt7``. Every method decodes with
/// `BytesCompression`, in Swift: DEFLATE and Deflate64, bzip2, LZMA, xz, and Zstandard, a chunk at a time by its
/// `ChunkedDecompressor` (one `Decompressor` and two output buffers). Its buffers and each method's state are allocated
/// once (a method's on the first entry that needs it), so steady-state decoding performs no allocations. Encrypted
/// entries are decrypted in pieces into the chunked decompressor's staged input as it takes them: no entry is held
/// whole in memory. What's ZIP's stays here: the methods (``ZipArchive/Method``, mapped to BytesCompression's formats,
/// LZMA's 9-byte header included), decryption, the LZMA end marker's size limit, and the errors. It's `~Copyable`
/// because it uniquely owns its buffers.
@safe
public struct ZipDecoder: ~Copyable {
    /// The chunk pump: every method's decoder, two output buffers, and the staged input for encrypted entries (made on
    /// the first one, so decoders that never see one (a worker per core, verifying) don't allocate it). LZMA's and xz's
    /// window (one, shared) grows to the largest dictionary they've needed (no larger than an entry).
    private var chunks = ChunkedDecompressor()
    /// The current encrypted entry's decryption, and its payload (in the mapped file), which it reads.
    private var decryptor: PayloadDecryptor?
    private var payload = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    /// For an LZMA entry whose flags say it ends with an end marker: its recorded size, the decoder's maximum (the
    /// decoder stops at the first byte past it, which is reported as ``ZipError/sizeMismatch(_:expected:actual:)``).
    /// `nil` otherwise.
    private var lzmaMaximumSize: UInt64?
    /// The entry ``nextChunk(into:)`` hands out: its name (for errors), and whether it's a stored entry being decrypted.
    private var entryPath = ""
    private var decryptsStored = false

    /// Creates a decoder and allocates its buffers (about 2 MB; the second buffer's pages are touched only by
    /// pipelined extraction).
    public init() {}

    /// Inflates a complete raw-DEFLATE `payload`, calling `body` with each chunk of output.
    ///
    /// The chunks borrow the decoder's buffer and are valid only during each call to `body`.
    ///
    /// - Parameters:
    ///   - payload: The compressed stream.
    ///   - path: The entry's name, for errors.
    ///   - body: Called with each non-empty chunk, in order.
    /// - Throws: ``ZipError/decoding(_:_:)`` for invalid or truncated data; whatever `body` throws.
    mutating func inflate(_ payload: RawSpan, path: String, _ body: (RawSpan) throws(ZipError) -> Void) throws(ZipError) {
        try payload.withUnsafeBytes { input throws(ZipError) in
            try unsafe begin(input, method: ZipArchive.Method.deflated, size: nil, endMarker: false, path: path)
            try run(path: path, body)
        }
    }

    /// Decompresses a bare `payload` with `method`'s decoder, calling `chunk` with each piece of output (at most
    /// about 1 MB), and checks that the output is `uncompressedSize` bytes: what reading an unencrypted entry does,
    /// without an archive or a CRC-32. For tests of each method's decoding, whatever decodes it.
    ///
    /// The pieces borrow the decoder's buffer and are valid only during each call to `chunk`.
    ///
    /// - Parameters:
    ///   - payload: The compressed stream, as a zip entry stores it (LZMA's with its 4-byte zip header and
    ///     properties).
    ///   - method: The zip method (``ZipArchive/Method``); not ``ZipArchive/Method/stored``.
    ///   - uncompressedSize: The entry's recorded size.
    ///   - hasEndMarker: For LZMA, general-purpose flag bit 1: the stream ends with an end marker.
    ///   - chunk: Called with each non-empty piece, in order.
    /// - Throws: ``ZipError/unsupportedMethod(_:_:)`` for a method (or LZMA properties) that can't be read;
    ///   ``ZipError/decoding(_:_:)`` for invalid or truncated data; ``ZipError/sizeMismatch(_:expected:actual:)`` for
    ///   output that isn't `uncompressedSize` bytes; whatever `chunk` throws.
    public mutating func decodePayload(
        _ payload: RawSpan, method: UInt16, uncompressedSize: UInt64, hasEndMarker: Bool = false,
        _ chunk: (RawSpan) throws(ZipError) -> Void
    ) throws(ZipError) {
        let path = "payload"
        var written: UInt64 = 0
        try payload.withUnsafeBytes { input throws(ZipError) in
            try unsafe begin(input, method: method, size: uncompressedSize, endMarker: hasEndMarker, path: path)
            try run(path: path) { piece throws(ZipError) in
                written += UInt64(piece.byteCount)
                guard written <= uncompressedSize else {
                    throw .sizeMismatch(path, expected: uncompressedSize, actual: written)
                }
                try chunk(piece)
            }
        }
        guard written == uncompressedSize else { throw .sizeMismatch(path, expected: uncompressedSize, actual: written) }
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
    /// - Throws: The errors of ``beginEntry(_:entry:password:)`` and ``nextChunk(into:)``; whatever `body` throws.
    @usableFromInline
    mutating func decode(
        _ payload: RawSpan, entry: ZipEntry, password: String?, _ body: (RawSpan) throws(ZipError) -> Void
    ) throws(ZipError) {
        defer { endDecryption() }
        try payload.withUnsafeBytes { payload throws(ZipError) in
            let input = try unsafe prepareInput(payload, entry: entry, password: password)
            if entry.method == ZipArchive.Method.stored {
                if decryptor != nil {
                    // Decrypted straight into the output buffer, a chunk at a time.
                    while decryptor?.isFinished == false {
                        // Unsafe: a span over the decoder's buffer. Safe: as for decoded chunks, valid for the call.
                        let chunk = unsafe decryptStored(into: 0)
                        try body(unsafe RawSpan(_unsafeBytes: chunk.bytes))
                    }
                } else if unsafe !input.isEmpty {
                    // Unsafe: a span over the payload. Safe: it's in the mapped archive, valid for the call.
                    try body(unsafe RawSpan(_unsafeBytes: input))
                }
                return
            }
            try unsafe begin(input, method: entry.method, size: entry.uncompressedSize, endMarker: entry.flags & 0x2 != 0, path: entry.path)
            try run(path: entry.path, body)
        }
    }

    /// Steps the current stream to its end, calling `body` with each chunk.
    private mutating func run(path: String, _ body: (RawSpan) throws(ZipError) -> Void) throws(ZipError) {
        while true {
            let (chunk, finished) = try unsafe step(into: 0, path: path)
            if unsafe !chunk.isEmpty { try body(unsafe chunk.bytes) }
            if finished { return }
        }
    }

    /// A chunk of decoder output handed to a concurrent consumer. Valid until that consumer asks for the next.
    /// `@unchecked Sendable`: a pointer into the decoder's buffer, handed to exactly one consumer task, and the
    /// buffer isn't written again until that consumer is done with it (``ChunkHandoff``'s protocol).
    @unsafe
    @usableFromInline
    struct Chunk: @unchecked Sendable {
        @usableFromInline let bytes: UnsafeRawBufferPointer
    }

    // MARK: Pulling chunks

    /// Starts decoding an entry for ``nextChunk(into:)``, which hands out its output a chunk at a time: for callers that
    /// write each chunk before asking for the next (an extraction's writers, which suspend in their writes), or that
    /// decode on one task and write on another (two buffers alternate: see ``nextChunk(into:)``). End with
    /// ``endEntry()``.
    ///
    /// - Parameters:
    ///   - payload: The entry's payload, as stored. It must stay valid until ``endEntry()`` (it points into a
    ///     ``MappedFile``).
    ///   - entry: The entry: compressed, or stored and encrypted (unencrypted stored entries are their payload).
    ///   - password: The password for an encrypted entry.
    /// - Throws: ``ZipError/unsupportedMethod(_:_:)``; the errors of decryption (``ZipError/passwordRequired(_:)``,
    ///   ``ZipError/incorrectPassword(_:)``, ``ZipError/authenticationFailed(_:)``,
    ///   ``ZipError/unsupportedEncryption(_:)``, ``ZipError/truncated(_:)``); ``ZipError/decoding(_:_:)`` for a stream
    ///   whose header can't be read.
    @usableFromInline
    mutating func beginEntry(_ payload: UnsafeRawBufferPointer, entry: ZipEntry, password: String?) throws(ZipError) {
        endEntry()
        let input = try unsafe prepareInput(payload, entry: entry, password: password)
        entryPath = entry.path
        if entry.method == ZipArchive.Method.stored {
            precondition(decryptor != nil, "an unencrypted stored entry is its payload")
            decryptsStored = true
            return
        }
        decryptsStored = false
        try unsafe begin(input, method: entry.method, size: entry.uncompressedSize, endMarker: entry.flags & 0x2 != 0, path: entry.path)
    }

    /// The entry's next chunk of output, decoded (or decrypted) into buffer `index` (0 or 1), and whether it's the last.
    ///
    /// A chunk stays valid until the next call into the same buffer. Decoding into one buffer reads the other's last 32
    /// or 64 KB as history, so a consumer may read one buffer's chunk while the next is decoded into the other (both
    /// only read the first).
    ///
    /// - Throws: ``ZipError/decoding(_:_:)`` for invalid or truncated data (``ZipError/cancelled`` for a decoder that
    ///   was cancelled).
    @usableFromInline
    mutating func nextChunk(into index: Int) throws(ZipError) -> (chunk: Chunk, finished: Bool) {
        if decryptsStored {
            let chunk = unsafe decryptStored(into: index)
            return unsafe (chunk, decryptor?.isFinished ?? true)
        }
        let (output, finished) = try unsafe step(into: index, path: entryPath)
        return unsafe (Chunk(bytes: output), finished)
    }

    /// Ends the entry ``beginEntry(_:entry:password:)`` started (its decryption): after its last chunk, or a failure.
    @usableFromInline
    mutating func endEntry() {
        endDecryption()
    }

    // MARK: Decryption

    /// Prepares the entry's input: for an unencrypted entry, `payload` itself. For an encrypted one, checks the
    /// password (and for AES the whole payload's authentication code), then sets up ``decryptor`` to decrypt in
    /// pieces into the chunked decompressor's staged input as it takes them, and returns an empty buffer.
    ///
    /// - Throws: ``ZipError/passwordRequired(_:)`` without a password; ``ZipError/incorrectPassword(_:)``
    ///   when its check fails; ``ZipError/authenticationFailed(_:)`` for an AES entry whose authentication
    ///   code doesn't match; ``ZipError/unsupportedEncryption(_:)``; ``ZipError/truncated(_:)``.
    private mutating func prepareInput(_ payload: UnsafeRawBufferPointer, entry: ZipEntry, password: String?) throws(ZipError) -> UnsafeRawBufferPointer {
        guard let encryption = entry.encryption else { return unsafe payload }
        if case .unsupported = encryption { throw .unsupportedEncryption(entry.path) }
        guard let password else { throw .passwordRequired(entry.path) }
        var key = password
        // Unsafe: a span over `payload`, valid for this call (it's in the mapped archive).
        let source = unsafe RawSpan(_unsafeBytes: payload)
        let decryptor: PayloadDecryptor
        switch encryption {
        case .traditional:
            let header = TraditionalCipher.headerSize
            guard source.byteCount >= header else { throw .truncated("encryption header for '\(entry.path)'") }
            var cipher = key.withUTF8 { unsafe TraditionalCipher(password: RawSpan(_unsafeBytes: UnsafeRawBufferPointer($0))) }
            // With a data descriptor the CRC wasn't known when the header was made: it checks the time instead.
            let expected = entry.flags & 0x8 != 0 ? UInt8(truncatingIfNeeded: entry.dosTime >> 8) : UInt8(truncatingIfNeeded: entry.crc32 >> 24)
            guard cipher.checkByte(source.extracting(0..<header)) == expected else { throw .incorrectPassword(entry.path) }
            decryptor = PayloadDecryptor(cipher: .traditional(cipher), ciphertext: header..<source.byteCount, position: header)
        case let .aes(bits, _):
            do throws(WinZipAES.Failure) {
                // Unsafe: the password's UTF-8 as a span, valid inside `withUTF8`'s closure, which it doesn't outlive.
                let (aes, counter, ciphertext) = try key.withUTF8 { utf8 throws(WinZipAES.Failure) in
                    try unsafe WinZipAES.open(source, bits: bits, password: RawSpan(_unsafeBytes: UnsafeRawBufferPointer(utf8)))
                }
                decryptor = PayloadDecryptor(cipher: .aes(aes, counter), ciphertext: ciphertext, position: ciphertext.lowerBound)
            } catch {
                switch error {
                case .badPassword: throw .incorrectPassword(entry.path)
                case .authenticationFailed: throw .authenticationFailed(entry.path)
                case .truncated: throw .truncated("encryption header for '\(entry.path)'")
                }
            }
        case .unsupported:
            throw .unsupportedEncryption(entry.path)
        }
        unsafe self.payload = payload
        self.decryptor = decryptor
        return unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    }

    /// Decrypts the next chunk of a stored entry into buffer `index`.
    private mutating func decryptStored(into index: Int) -> Chunk {
        let output = unsafe chunks.chunkRoom(index)
        // Unsafe: spans over the payload (in the mapped archive, valid for the entry) and over this decoder's
        // buffer; neither outlives the call.
        var span = unsafe MutableRawSpan(_unsafeBytes: output)
        let count = unsafe decryptor!.decryptNext(from: RawSpan(_unsafeBytes: payload), into: &span)
        return unsafe Chunk(bytes: UnsafeRawBufferPointer(rebasing: output[..<count]))
    }

    /// Decrypts the next piece of ciphertext into the chunked decompressor's staged input.
    ///
    /// - Returns: The number of bytes decrypted: 0 for an unencrypted entry (its whole payload is the input), or once
    ///   all the ciphertext has been (the staged input has then ended: the stream must finish with what's staged).
    /// - Throws: ``ZipError/decoding(_:_:)`` when the staged input is full (the decoder holds more than it takes).
    private mutating func refillInput(path: String) throws(ZipError) -> Int {
        guard var decryptor, !decryptor.isFinished else {
            if decryptor != nil { chunks.endInput() }
            return 0
        }
        // Unsafe: a span over the payload, in the mapped archive and valid for the entry.
        let source = unsafe RawSpan(_unsafeBytes: payload)
        let count: Int
        do throws(BytesError) {
            count = try chunks.fillInput { span in decryptor.decryptNext(from: source, into: &span) }
        } catch {
            throw ZipError(decoding: error, path)
        }
        self.decryptor = decryptor
        return count
    }

    /// Forgets the entry's decryption.
    private mutating func endDecryption() {
        decryptor = nil
        unsafe payload = UnsafeRawBufferPointer(start: nil, count: 0)
    }

    // MARK: Stepping

    /// Starts decoding an entry's `input` (empty for an encrypted entry: its input is decrypted into the staged input)
    /// with `method`'s decoder.
    ///
    /// - Parameters:
    ///   - size: The entry's recorded size; `nil` for a bare stream of unknown size (``inflate(_:path:_:)``).
    ///   - endMarker: For LZMA, general-purpose flag bit 1: the stream ends with an end marker.
    ///
    /// - Throws: ``ZipError/unsupportedMethod(_:_:)``; ``ZipError/decoding(_:_:)`` when the decoder can't start.
    private mutating func begin(
        _ input: UnsafeRawBufferPointer, method: UInt16, size: UInt64?, endMarker: Bool, path: String
    ) throws(ZipError) {
        lzmaMaximumSize = nil
        if decryptor != nil { chunks.stageInput() } else { unsafe chunks.borrowInput(input) }
        let format: DecompressionFormat
        if method == ZipArchive.Method.lzma {
            format = try lzmaFormat(size: size, endMarker: endMarker, path: path)
        } else {
            // Zip method 95 stores a whole `.xz` stream; the recorded size keeps a small entry's window small.
            guard let mapped = DecompressionFormat(zipMethod: method, uncompressedSize: size.flatMap { Int(exactly: $0) }) else {
                throw .unsupportedMethod(method, path)
            }
            format = mapped
        }
        do throws(BytesError) {
            // A small unencrypted entry decodes in one call into the output buffer (no window); a wrong size in the
            // header makes it throw, as corrupt data.
            try chunks.start(format, decodedSize: size.flatMap { Int(exactly: $0) })
        } catch {
            throw ZipError(decoding: error, path)
        }
    }

    /// Reads an LZMA entry's zip header (BytesCompression's `LZMAProperties(zipHeader:)`: APPNOTE 5.8.8) and returns
    /// the format of the raw stream after it.
    ///
    /// With the end-marker flag, `size` is the decoder's maximum: the stream must end with a marker, at or before it;
    /// without it, the stream ends at `size`, with a marker or without one.
    ///
    /// - Throws: ``ZipError/unsupportedMethod(_:_:)`` for a header or properties this decoder can't read;
    ///   ``ZipError/truncated(_:)`` for a payload too short to hold them; ``ZipError/decoding(_:_:)``
    ///   (`invalidValue`) for an entry of no size, or one larger than memory can hold.
    private mutating func lzmaFormat(size: UInt64?, endMarker: Bool, path: String) throws(ZipError) -> DecompressionFormat {
        let headerSize = LZMAProperties.zipHeaderSize
        // An encrypted entry's header is in its first decrypted bytes.
        while unsafe chunks.pendingInput.count < headerSize, try refillInput(path: path) > 0 {}
        // Unsafe: the pending input, read before it's consumed or refilled (see `ChunkedDecompressor.pendingInput`).
        let header = unsafe RawSpan(_unsafeBytes: chunks.pendingInput)
        guard header.byteCount >= headerSize else { throw .truncated("LZMA header for '\(path)'") }
        let properties: LZMAProperties
        do throws(BytesError) {
            properties = try LZMAProperties(zipHeader: header)
        } catch {
            throw .unsupportedMethod(ZipArchive.Method.lzma, path)
        }
        chunks.consumeInput(headerSize)
        guard let size, let count = Int(exactly: size) else { throw .decoding(.invalidValue, path) }
        if endMarker { lzmaMaximumSize = size }
        return .zipLZMA(properties, uncompressedSize: count, hasEndMarker: endMarker)
    }

    /// Decodes the next chunk into buffer `index` (0 or 1), decrypting more input whenever the decoder runs out.
    ///
    /// - Parameters:
    ///   - index: Which of the two buffers to decode into.
    ///   - path: The entry's name, for errors.
    /// - Returns: The chunk (excluding history) and whether the stream ended.
    /// - Throws: ``ZipError/decoding(_:_:)`` with the decoder's error for invalid or truncated data
    ///   (``ZipError/cancelled`` for a cancelled one); ``ZipError/sizeMismatch(_:expected:actual:)`` for an LZMA stream
    ///   with an end marker that runs past the entry's size.
    private mutating func step(into index: Int, path: String) throws(ZipError) -> (chunk: UnsafeRawBufferPointer, finished: Bool) {
        while true {
            let next: ChunkedDecompressor.Step
            do throws(BytesError) {
                // Unsafe: a chunk is a pointer into the decompressor's buffer, valid until the next call into it.
                unsafe next = try chunks.nextChunk(into: index)
            } catch {
                if error == .limitExceeded, let lzmaMaximumSize {
                    // An LZMA stream ending with an end marker ran past the entry's size: the decoder stopped at the
                    // first byte past it.
                    throw .sizeMismatch(path, expected: lzmaMaximumSize, actual: lzmaMaximumSize &+ 1)
                }
                throw ZipError(decoding: error, path)
            }
            switch unsafe next {
            case let .chunk(chunk, finished):
                return unsafe (chunk, finished)
            case .needsInput:
                // Decrypt more; when there's none, the input has ended, and the next step finishes the stream or
                // throws that it was cut short.
                _ = try refillInput(path: path)
            }
        }
    }
}

/// A rendezvous between a decoder making chunks and the one task consuming them, in order (BytesAsync's
/// `AsyncHandoff`): the decoder's `send` returns once the consumer has finished the previous chunk and taken the new
/// one, so two decoder buffers can alternate. Nothing is allocated per chunk.
typealias ChunkHandoff = AsyncHandoff<ZipDecoder.Chunk>

// MARK: - Benchmarking hooks

/// NativeZip's DEFLATE decoding on its own, exposed only so benchmarks and tests can time and check it.
public enum DeflateBackends {
    /// Inflates a raw-DEFLATE `payload` with `decoder`, without verifying a size or CRC-32.
    ///
    /// - Parameters:
    ///   - payload: The compressed stream.
    ///   - decoder: The decoder to use.
    ///   - discarding: If `true`, the output is dropped, for timing decoding alone.
    /// - Returns: The output, or an empty array if `discarding`.
    /// - Throws: ``ZipError/decoding(_:_:)`` for invalid or truncated data.
    public static func inflate(_ payload: RawSpan, using decoder: inout ZipDecoder, discarding: Bool = false) throws(ZipError) -> [UInt8] {
        var output: [UInt8] = []
        try decoder.inflate(payload, path: "payload") { chunk in
            if !discarding { output.append(copying: chunk) }
        }
        return output
    }
}

extension ZipDecoder {
    /// `crc` (a CRC-32) updated with `bytes`, by `Bytes`' `CRC32`. Static so it can run inside `decode`'s
    /// callbacks, which can't access the decoder. Not inlinable: `Bytes` is an internal import.
    ///
    /// - Parameters:
    ///   - crc: The CRC-32 so far (0 to start).
    ///   - bytes: The next data.
    /// - Returns: The updated CRC-32, in the low 32 bits.
    @usableFromInline
    static func crc32(_ crc: UInt, _ bytes: RawSpan) -> UInt {
        UInt(CRC32.checksum(bytes, continuing: UInt32(truncatingIfNeeded: crc)))
    }

    /// The CRC-32 of two pieces joined, from each piece's CRC-32 and the second's length.
    static func combineCRC32(_ first: UInt32, _ second: UInt32, secondLength: Int) -> UInt32 {
        CRC32.combine(first, second, secondLength: secondLength)
    }
}
