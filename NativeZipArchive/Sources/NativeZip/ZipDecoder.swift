internal import Bytes
internal import BytesAsync
internal import BytesCompression
import Synchronization

/// Reusable decompression state: a decoder for every supported method plus output buffers.
///
/// Create one per worker and pass it to ``ZipArchive/contents(of:using:password:_:)-77zt7``. Every method decodes with
/// `BytesCompression`'s `Decompressor`, in Swift: DEFLATE and Deflate64, bzip2, LZMA, xz, and Zstandard. Its buffers
/// and each method's state are allocated once (a method's on the first entry that needs it), so steady-state decoding
/// performs no allocations. Encrypted entries are decrypted in pieces into a staging buffer the decoder owns, as
/// their decompressor takes input: no entry is held whole in memory. It's `~Copyable` because it uniquely owns its
/// buffers.
@safe
public struct ZipDecoder: ~Copyable {
    /// Output is handed to callers in chunks of at most about this many bytes.
    @usableFromInline static let chunkSize = 1 << 20
    /// The largest window: how far back a back-reference can reach (Deflate64's 64 KB; DEFLATE uses 32 KB of
    /// it). DEFLATE decodes straight into the output buffers, keeping that much of the previous output at the
    /// front of each.
    static let historySize = 64 << 10

    /// How the current entry decodes.
    private enum Mode {
        /// An unencrypted entry of at most a chunk, of any method: one call straight into the output buffer, no
        /// window, checked against the recorded size.
        case whole(size: Int)
        /// DEFLATE or Deflate64: straight into the output buffers, after this much of the last output as history.
        case history(Int)
        /// The others: through the method's own window, a chunk at a time.
        case stream
    }

    /// Decrypted input waiting for a decompressor, 256 KB: decryption fills it as the decompressor drains it. Each
    /// decoder needs far less than this to make progress (at most a 64 KB LZMA2 chunk, for xz).
    static let stagingSize = 256 << 10

    /// Every method's decoder, each method's state made on its first entry. LZMA's and xz's window (one, shared)
    /// grows to the largest dictionary they've needed (no larger than an entry).
    private var decompressor = Decompressor()
    /// Decrypted input for the decompressors, refilled as they consume it. Made on the first encrypted entry, so
    /// decoders that never see one (a worker per core, verifying) don't allocate it.
    private var staging: ByteBuffer?
    /// The current encrypted entry's decryption, and its payload (in the mapped file), which it reads.
    private var decryptor: PayloadDecryptor?
    private var payload = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    /// Two output buffers, each history plus a chunk. The second is used only when chunks alternate (a large entry
    /// decoded on one task and written on another, ``nextChunk(into:)``); its pages are untouched otherwise. Raw
    /// allocations rather than arrays because chunks of them cross tasks and suspensions (see ``Chunk``); freed in
    /// `deinit`, never reallocated.
    private let buffers: (UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer)
    /// The current unencrypted entry's compressed input, and how much of it the decoder has consumed.
    private var input = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    private var consumed = 0
    private var mode = Mode.stream
    /// For an LZMA entry whose flags say it ends with an end marker: the most output it may produce (the decoder
    /// is then given no size, so the marker is required). `nil` otherwise.
    private var outputLimit: UInt64?
    /// The output produced for the current entry, checked against ``outputLimit``.
    private var produced: UInt64 = 0
    /// The entry ``nextChunk(into:)`` hands out: its name (for errors), and whether it's a stored entry being decrypted.
    private var entryPath = ""
    private var decryptsStored = false
    /// Where the last step's output ended, and in which buffer: the next step's history.
    private var lastBuffer = 0
    private var lastEnd = 0

    /// Creates a decoder and allocates its buffers (about 2 MB; the second buffer's pages are touched only by
    /// pipelined extraction).
    public init() {
        let size = Self.historySize + Self.chunkSize
        unsafe buffers = (.allocate(byteCount: size, alignment: 16), .allocate(byteCount: size, alignment: 16))
    }

    deinit {
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
    /// - Throws: ``ZipError/decoding(_:_:)`` for invalid or truncated data; whatever `body` throws.
    mutating func inflate(_ payload: RawSpan, path: String, _ body: (RawSpan) throws(ZipError) -> Void) throws(ZipError) {
        try payload.withUnsafeBytes { (input) throws(ZipError) in
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
    @_spi(Testing)
    public mutating func decodePayload(
        _ payload: RawSpan, method: UInt16, uncompressedSize: UInt64, hasEndMarker: Bool = false,
        _ chunk: (RawSpan) throws(ZipError) -> Void
    ) throws(ZipError) {
        let path = "payload"
        var written: UInt64 = 0
        try payload.withUnsafeBytes { (input) throws(ZipError) in
            try unsafe begin(input, method: method, size: uncompressedSize, endMarker: hasEndMarker, path: path)
            try run(path: path) { (piece) throws(ZipError) in
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
        try payload.withUnsafeBytes { (payload) throws(ZipError) in
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
    /// pieces as the decompressor takes input, and returns an empty buffer.
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
                let (aes, counter, ciphertext) = try key.withUTF8 { (utf8) throws(WinZipAES.Failure) in
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
        if staging == nil { staging = ByteBuffer(capacity: Self.stagingSize) }
        return unsafe UnsafeRawBufferPointer(start: nil, count: 0)
    }

    /// Decrypts the next chunk of a stored entry into buffer `index`.
    private mutating func decryptStored(into index: Int) -> Chunk {
        let output = unsafe UnsafeMutableRawBufferPointer(rebasing: (index == 0 ? buffers.0 : buffers.1)[..<Self.chunkSize])
        // Unsafe: spans over the payload (in the mapped archive, valid for the entry) and over this decoder's
        // buffer; neither outlives the call.
        var span = unsafe MutableRawSpan(_unsafeBytes: output)
        let count = unsafe decryptor!.decryptNext(from: RawSpan(_unsafeBytes: payload), into: &span)
        return unsafe Chunk(bytes: UnsafeRawBufferPointer(rebasing: output[..<count]))
    }

    /// Decrypts the next piece of ciphertext into the staging buffer's free space, after compacting what the
    /// decompressor hasn't consumed to its front.
    ///
    /// - Returns: The number of bytes decrypted: 0 once all the ciphertext has been.
    private mutating func refillStaging() -> Int {
        guard var decryptor, !decryptor.isFinished else { return 0 }
        _ = staging!.compact()
        // Unsafe: a span over the payload, in the mapped archive and valid for the entry.
        let source = unsafe RawSpan(_unsafeBytes: payload)
        let count = staging!.fill { output in
            output.withFreeCapacity { span, written in
                written = decryptor.decryptNext(from: source, into: &span)
                return written
            }
        }
        self.decryptor = decryptor
        return count
    }

    /// Forgets the entry's decryption.
    private mutating func endDecryption() {
        decryptor = nil
        unsafe payload = UnsafeRawBufferPointer(start: nil, count: 0)
        if staging != nil { staging!.removeAll() }
    }

    // MARK: Input

    /// The input the decoder hasn't consumed yet: the rest of the payload, or for an encrypted entry what's
    /// decrypted in the staging buffer. Unsafe: the bytes outlive any borrow of their owner. Safe: the payload is
    /// in the mapped archive, valid for the entry, and the staging buffer is this decoder's, allocated once; neither
    /// changes until ``consumeInput(_:)`` or ``refillInput()``, and callers use the bytes only before those.
    private func pendingInput() -> UnsafeRawBufferPointer {
        guard decryptor != nil else { return unsafe UnsafeRawBufferPointer(rebasing: input[consumed...]) }
        switch staging {
        case let .some(buffer): return buffer.unread.withUnsafeBytes { unsafe $0 }
        case .none: preconditionFailure("An encrypted entry has a staging buffer")
        }
    }

    /// Marks `count` bytes of ``pendingInput()`` consumed.
    private mutating func consumeInput(_ count: Int) {
        if decryptor != nil { staging!.consume(count) } else { consumed &+= count }
    }

    /// Makes more input pending: decrypts the next piece of an encrypted entry.
    ///
    /// - Returns: The bytes added: 0 for an unencrypted entry (its whole payload is pending), or once all the
    ///   ciphertext has been decrypted.
    private mutating func refillInput() -> Int {
        decryptor == nil ? 0 : refillStaging()
    }

    // MARK: Stepping

    /// Starts decoding an entry's `input` with `method`'s decoder.
    ///
    /// - Parameters:
    ///   - size: The entry's recorded size; `nil` for a bare stream of unknown size (``inflate(_:path:_:)``).
    ///   - endMarker: For LZMA, general-purpose flag bit 1: the stream ends with an end marker.
    ///
    /// - Throws: ``ZipError/unsupportedMethod(_:_:)``; ``ZipError/decoding(_:_:)`` when the decoder can't start.
    private mutating func begin(
        _ input: UnsafeRawBufferPointer, method: UInt16, size: UInt64?, endMarker: Bool, path: String
    ) throws(ZipError) {
        unsafe self.input = input
        consumed = 0
        lastEnd = 0
        produced = 0
        outputLimit = nil
        // `prepareInput` made the staging buffer for an encrypted entry: it starts empty.
        if staging != nil { staging!.removeAll() }
        let format: DecompressionFormat
        switch method {
        case ZipArchive.Method.deflated: format = .deflate(.raw)
        case ZipArchive.Method.deflate64: format = .deflate64
        case ZipArchive.Method.bzip2: format = .bzip2
        case ZipArchive.Method.zstd: format = .zstd
        // Zip method 95 stores a whole `.xz` stream; the recorded size keeps a small entry's window small.
        case ZipArchive.Method.xz: format = .xz(sizeHint: size.flatMap { Int(exactly: $0) })
        case ZipArchive.Method.lzma: format = try lzmaFormat(size: size, endMarker: endMarker, path: path)
        default: throw .unsupportedMethod(method, path)
        }
        do throws(BytesError) {
            try decompressor.reset(for: format)
        } catch {
            throw ZipError(decoding: error, path)
        }
        // Small and unencrypted: one call into the output buffer, which is the history, with no window. (A wrong
        // size in the header makes it throw, as corrupt data.)
        if decryptor == nil, let size, size <= UInt64(Self.chunkSize) {
            mode = .whole(size: Int(size))
        } else if let history = format.historySize {
            mode = .history(history)
        } else {
            mode = .stream
        }
    }

    /// Reads an LZMA entry's zip header (APPNOTE 5.8.8: a 2-byte version, the properties' size, 5, as 2 bytes, then
    /// the properties: the lc/lp/pb byte and the dictionary size) and returns the format of the raw stream after it.
    ///
    /// With the end-marker flag the decoder is given no size, so the stream must end with a marker, and the output is
    /// limited to `size` here (and the window to it); without it, the stream ends at `size`, with a marker or without
    /// one.
    ///
    /// - Throws: ``ZipError/unsupportedMethod(_:_:)`` for a header or properties this decoder can't read;
    ///   ``ZipError/truncated(_:)`` for a payload too short to hold them; ``ZipError/decoding(_:_:)``
    ///   (`invalidValue`) for an entry of no size, or one larger than memory can hold.
    private mutating func lzmaFormat(size: UInt64?, endMarker: Bool, path: String) throws(ZipError) -> DecompressionFormat {
        // An encrypted entry's header is in its first decrypted bytes.
        while unsafe pendingInput().count < 9, refillInput() > 0 {}
        let header = unsafe pendingInput()
        guard header.count >= 9 else { throw .truncated("LZMA header for '\(path)'") }
        // Unsafe: loads from the 9 bytes just checked.
        let propertiesSize = unsafe UInt16(header[2]) | UInt16(header[3]) << 8
        let dictionarySize = unsafe UInt32(header[5]) | UInt32(header[6]) << 8 | UInt32(header[7]) << 16 | UInt32(header[8]) << 24
        let properties: LZMAProperties
        do throws(BytesError) {
            guard propertiesSize == 5 else { throw .invalidValue }
            properties = unsafe try LZMAProperties(byte: header[4], dictionarySize: Int(dictionarySize))
        } catch {
            throw .unsupportedMethod(ZipArchive.Method.lzma, path)
        }
        consumeInput(9)
        guard let size, let count = Int(exactly: size) else { throw .decoding(.invalidValue, path) }
        if endMarker { outputLimit = size }
        return .lzma(properties, uncompressedSize: endMarker ? nil : count, sizeHint: endMarker ? count : nil)
    }

    /// Decodes the next chunk into buffer `index` (0 or 1).
    ///
    /// - Parameters:
    ///   - index: Which of the two buffers to decode into.
    ///   - path: The entry's name, for errors.
    /// - Returns: The chunk (excluding history) and whether the stream ended.
    /// - Throws: ``ZipError/decoding(_:_:)`` with the decoder's error for invalid or truncated data
    ///   (``ZipError/cancelled`` for a cancelled one).
    private mutating func step(into index: Int, path: String) throws(ZipError) -> (chunk: UnsafeRawBufferPointer, finished: Bool) {
        let output = unsafe index == 0 ? buffers.0 : buffers.1
        let limit: UInt64
        do throws(BytesError) {
            switch mode {
            case let .history(historySize):
                return try unsafe inflateStep(into: index, output, historySize: historySize)
            case let .whole(size):
                // Unsafe: spans over this decoder's buffer (all of it: a decoder may write past the content, into
                // free capacity) and the entry's pending input, in the mapped archive (see `pendingInput`); the
                // output span is finalized before return.
                var span = unsafe OutputRawSpan(buffer: output, initializedCount: 0)
                _ = try unsafe decompressor.decompressAll(RawSpan(_unsafeBytes: pendingInput()), into: &span, decodedSize: size)
                let produced = unsafe span.finalize(for: output)
                return unsafe (UnsafeRawBufferPointer(rebasing: output[..<produced]), true)
            case .stream:
                let chunk = unsafe UnsafeMutableRawBufferPointer(rebasing: output[..<Self.chunkSize])
                let (count, finished) = try unsafe streamStep(into: chunk)
                produced &+= UInt64(count)
                guard let outputLimit, produced > outputLimit else {
                    return unsafe (UnsafeRawBufferPointer(rebasing: chunk[..<count]), finished)
                }
                limit = outputLimit
            }
        } catch {
            throw ZipError(decoding: error, path)
        }
        // An LZMA stream ending with an end marker ran past the entry's size.
        throw .sizeMismatch(path, expected: limit, actual: produced)
    }

    /// Inflates the next chunk straight into buffer `index`, after the last window of the previous chunk's output,
    /// moved to its front as history.
    ///
    /// - Returns: The chunk (excluding history) and whether the stream ended.
    private mutating func inflateStep(
        into index: Int, _ output: UnsafeMutableRawBufferPointer, historySize: Int
    ) throws(BytesError) -> (chunk: UnsafeRawBufferPointer, finished: Bool) {
        let history = min(historySize, lastEnd)
        if history > 0 {
            let previous = unsafe lastBuffer == 0 ? buffers.0 : buffers.1
            unsafe output.baseAddress!.copyMemory(from: previous.baseAddress! + (lastEnd - history), byteCount: history)
        }
        // Unsafe: a span over this decoder's buffer, allocated for its lifetime; it ends with this call. (Owned
        // buffers can't be safe types here: chunks cross tasks and suspension points (`nextChunk`), which a span or
        // an `Array`'s storage can't outlive.)
        var span = unsafe MutableRawSpan(_unsafeBytes: output)
        var end = history
        var finished = false
        while true {
            // Unsafe: the pending input, used before it's consumed or refilled (see `pendingInput`).
            let source = unsafe RawSpan(_unsafeBytes: pendingInput())
            let progress = try decompressor.decompress(source, into: &span, historyCount: end)
            consumeInput(progress.consumed)
            end &+= progress.produced
            if progress.status == .finished { finished = true; break }
            if progress.status == .needsOutput { break }
            // Needs input: decrypt more, or the stream was cut short.
            guard refillInput() > 0 else { throw .insufficientData }
        }
        lastBuffer = index
        lastEnd = end
        return unsafe (UnsafeRawBufferPointer(rebasing: output[history..<end]), finished)
    }

    /// Runs the current entry's streaming decoder (bzip2, LZMA, xz, or Zstandard) until `output` is full or the
    /// stream ends, from the payload or, for an encrypted entry, from the staging buffer, refilled as it's consumed.
    ///
    /// - Returns: The bytes written to `output`, and whether the stream ended.
    /// - Throws: The decoder's errors; ``BytesError/insufficientData`` for a stream that needs input after all of
    ///   it has been given (truncated).
    private mutating func streamStep(into output: UnsafeMutableRawBufferPointer) throws(BytesError) -> (produced: Int, finished: Bool) {
        // Unsafe: an output span over this decoder's buffer. Safe: it covers exactly `output`, which the decoder
        // owns, and is finalized before the call returns.
        var span = unsafe OutputRawSpan(buffer: output, initializedCount: 0)
        var finished = false
        while span.freeCapacity > 0 {
            // Unsafe: the pending input, used before it's consumed or refilled (see `pendingInput`).
            let source = unsafe RawSpan(_unsafeBytes: pendingInput())
            let progress = try decompressor.decompress(source, into: &span)
            consumeInput(progress.consumed)
            if progress.status == .finished { finished = true; break }
            if progress.status == .needsOutput { break }
            // Needs input: decrypt more, or the stream was cut short.
            guard refillInput() > 0 else { throw .insufficientData }
        }
        return unsafe (span.finalize(for: output), finished)
    }
}

/// A rendezvous between a decoder making chunks and the one task consuming them, in order (BytesAsync's
/// `AsyncHandoff`): the decoder's `send` returns once the consumer has finished the previous chunk and taken the new
/// one, so two decoder buffers can alternate. Nothing is allocated per chunk.
typealias ChunkHandoff = AsyncHandoff<ZipDecoder.Chunk>

// MARK: - Benchmarking hooks

/// NativeZip's DEFLATE decoding on its own, exposed only so benchmarks and tests can time and check it.
@_spi(Benchmarking)
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
