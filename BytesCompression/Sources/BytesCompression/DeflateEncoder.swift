public import Bytes

/// A DEFLATE (RFC 1951) encoder for raw, zlib (RFC 1950), and gzip (RFC 1952) streams, in one call or as
/// input arrives.
///
/// ```swift
/// var encoder = DeflateEncoder(format: .gzip, level: 6)    // allocates its tables and buffers once
/// try encoder.compressAll(body, into: &output)              // a whole stream
///
/// encoder.reset()                                           // the next stream, in pieces
/// var progress = try encoder.compress(chunk, into: &output)
/// progress = try encoder.compress(lastChunk, into: &output, flush: .finish)
/// ```
///
/// Levels follow libdeflate's (1 through 9; 0 stores): level 1 is a hash table of 2-entry buckets with
/// greedy parsing, 2 through 4 hash chains with greedy parsing, 5 through 7 lazy parsing, 8 and 9 a
/// two-position lookahead, searching deeper as the level rises. Blocks end where the data's statistics
/// change, and each is written stored, with the fixed code, or with its own code, whichever is smallest.
///
/// Encoding allocates nothing after initialization. ``compressAll(_:into:)`` searches the caller's input
/// directly; ``compress(_:into:flush:)`` copies input into a window of its own.
@safe
public struct DeflateEncoder: ~Copyable {
    /// The container format.
    public let format: DeflateFormat
    /// The compression level, 0 through 9.
    public private(set) var level: Int

    private var compressor: DeflateCompressor

    /// The streaming window: 32 KB of history, then room for input. Uninitialized until input is copied in: blocks read
    /// only bytes before `windowEnd` (the end they're given as the data's, which bounds every load).
    private var window: StagingBuffer
    private var windowEnd = 0
    /// The next window byte to compress.
    private var position = 0

    private var headerWritten = false
    private var finalBlockWritten = false
    private var isFinished = false
    /// A sync flush was written and no input has come since.
    private var flushed = false
    private var checksum: UInt32
    private var length: UInt32 = 0

    /// A gzip header other than the default 10 bytes (``init(gzipHeader:level:)``), and its bytes for the current
    /// stream: built at the stream's start into storage made once, and delivered ahead of the staged output (it has
    /// no size limit the staging buffer could take).
    private var gzipHeader: GzipHeader?
    private var headerBytes: [UInt8] = []
    /// The header's bytes not yet delivered (its last ones): a counter, so the checks every delivery makes are one
    /// compare with no load of the array.
    private var headerRemaining = 0

    static var historySize: Int { Deflate.windowSize }
    static var windowCapacity: Int { historySize + (256 << 10) }
    /// Input kept back from compression until more arrives: a longest match, and 8 bytes for loads.
    static var lookahead: Int { Deflate.maximumMatch + 8 }

    /// Creates an encoder, allocating its tables and buffers (about 1.5 MB, most of it untouched until a stream reaches
    /// it: only the match finder's tables are filled).
    ///
    /// - Parameters:
    ///   - format: The container to write.
    ///   - level: The compression level: 0 (stored) through 9; higher levels run as 9. Negative levels trap (zlib's
    ///     -1, its default, is 6 here: a level that silently stored the data would surprise); `Compressor` throws for
    ///     them instead.
    public init(format: DeflateFormat = .raw, level: Int = 6) {
        precondition(level >= 0, "DEFLATE levels are 0 through 9")
        self.format = format
        self.level = min(level, 9)
        compressor = DeflateCompressor(level: self.level)
        window = StagingBuffer(count: Self.windowCapacity)
        checksum = format.initialChecksum
    }

    /// Creates a gzip encoder that writes `gzipHeader` at each stream's start: a file name, comment, time, OS, extra
    /// field, or header CRC (the extra flags are the level's, as with the default header).
    ///
    /// - Parameters:
    ///   - gzipHeader: The header for every stream (member) it encodes.
    ///   - level: As ``init(format:level:)``'s.
    public init(gzipHeader: GzipHeader, level: Int = 6) {
        self.init(format: .gzip, level: level)
        if !gzipHeader.isDefault {
            self.gzipHeader = gzipHeader
            headerBytes.reserveCapacity(gzipHeader.encodedByteCount)
        }
    }

    /// Prepares to encode a new stream at `level` (as the initializer takes it), keeping the allocations: `Compressor`'s
    /// reset between levels of one container. Tables the level reads that the earlier ones didn't are allocated now.
    mutating func reset(level: Int) {
        precondition(level >= 0, "DEFLATE levels are 0 through 9")
        self.level = min(level, 9)
        compressor.reset(level: self.level)
        resetStream()
    }

    /// Prepares to encode a new stream, discarding anything not yet delivered. Keeps the allocations.
    public mutating func reset() {
        compressor.reset()
        resetStream()
    }

    /// The stream's state, apart from the compressor's.
    private mutating func resetStream() {
        windowEnd = 0
        position = 0
        headerWritten = false
        finalBlockWritten = false
        isFinished = false
        flushed = false
        checksum = format.initialChecksum
        length = 0
        // Nothing of a custom header pending: `writeHeader` builds the next stream's (a store, not a `removeAll`: this
        // runs for every stream, and the default header never touches the bytes).
        headerRemaining = 0
    }

    /// An upper bound on the compressed size of `byteCount` bytes for this encoder's streams: the static bound, plus a
    /// gzip header's size beyond the default 10 bytes.
    ///
    /// - Parameter byteCount: The input's size.
    public func maximumCompressedSize(forByteCount byteCount: Int) -> Int {
        Self.maximumCompressedSize(forByteCount: byteCount, format: format) &+ ((gzipHeader?.encodedByteCount ?? 10) &- 10)
    }

    /// An upper bound on the compressed size of `byteCount` bytes, header and trailer included, for one
    /// ``compressAll(_:into:)`` call (with the default gzip header: see ``maximumCompressedSize(forByteCount:)`` for an
    /// encoder's own).
    ///
    /// - Parameters:
    ///   - byteCount: The input's size.
    ///   - format: The container.
    /// - Returns: A size no stream of that input exceeds.
    public static func maximumCompressedSize(forByteCount byteCount: Int, format: DeflateFormat) -> Int {
        byteCount &+ byteCount / 800 &+ 64
    }

    // MARK: - One shot

    /// Encodes `input` as one whole stream, appending it to `output`.
    ///
    /// Every call starts a new stream: an encoder used before (by any call) starts over as after ``reset()``,
    /// keeping its memory; a fresh or reset one pays nothing for that. ``maximumCompressedSize(forByteCount:format:)``
    /// bytes of free capacity are always enough.
    ///
    /// - Parameters:
    ///   - input: All the data.
    ///   - output: Where to append the stream.
    /// - Throws: ``BytesError/insufficientCapacity`` if the stream doesn't fit (`output` then holds part of
    ///   it).
    public mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) {
        // Only a used encoder resets: the reset clears the match finder's tables, which a fresh one has clear.
        if headerWritten { reset() }
        writeHeader()
        updateChecksum(input)
        var position = 0
        let end = input.byteCount
        if end == 0 {
            compressor.writeEmptyFinalBlock()
        }
        while position < end {
            try deliverAll(into: &output)
            position = compressor.compressBlock(input, from: position, limit: end, dataEnd: end, isFinal: true)
        }
        writeTrailer()
        try deliverAll(into: &output)
    }

    /// Delivers all staged output, or throws if it doesn't fit.
    private mutating func deliverAll(into output: inout OutputRawSpan) throws(BytesError) {
        _ = deliver(into: &output)
        guard compressor.stagedBytes.byteCount == 0, headerRemaining == 0 else { throw .insufficientCapacity }
    }

    // MARK: - Streaming

    /// Encodes as much of `input` as it can, appending output to `output`, continuing the current stream.
    ///
    /// Input is copied into the encoder's window, so ``TransformProgress/consumed`` only falls short of `input`
    /// when the output is full (`needsOutput`); pass the rest again. Keep calling with the same `flush`
    /// until the status is `needsInput` (or `finished`, for ``TransformFlush/finish``).
    ///
    /// - Parameters:
    ///   - input: The next bytes to compress.
    ///   - output: Where to append compressed bytes.
    ///   - flush: Whether to end the output on a decodable boundary, or end the stream, once `input` is
    ///     consumed.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: Nothing yet; typed for the decoders' errors, so pipelines compose.
    public mutating func compress(
        _ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush = .none
    ) throws(BytesError) -> TransformProgress {
        if !headerWritten {
            writeHeader()
        }
        var consumed = 0
        var produced = 0
        while true {
            produced &+= deliver(into: &output)
            if compressor.stagedBytes.byteCount > 0 || headerRemaining > 0 {
                return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
            }
            if isFinished {
                return TransformProgress(consumed: consumed, produced: produced, status: .finished)
            }
            if consumed < input.byteCount {
                let room = Self.windowCapacity &- windowEnd
                if room > 0 {
                    let count = min(room, input.byteCount &- consumed)
                    let bytes = input.extracting(consumed..<(consumed &+ count))
                    updateChecksum(bytes)
                    var span = window.mutableSpan
                    span.copyBytes(from: bytes, toByteOffset: windowEnd)
                    windowEnd &+= count
                    consumed &+= count
                    flushed = false
                } else if position < windowEnd &- Self.lookahead {
                    compressBlock(limit: windowEnd &- Self.lookahead, isFinal: false)
                } else {
                    slide()
                }
                continue
            }
            // All of `input` is in the window.
            switch flush {
            case .none:
                return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
            case .flush:
                if position < windowEnd {
                    compressBlock(limit: windowEnd, isFinal: false)
                } else if !flushed {
                    compressor.writeSyncMarker()
                    flushed = true
                } else {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
            case .finish:
                if position < windowEnd {
                    compressBlock(limit: windowEnd, isFinal: true)
                } else {
                    if !finalBlockWritten {
                        compressor.writeEmptyFinalBlock()
                    }
                    writeTrailer()
                    isFinished = true
                }
            }
        }
    }

    /// Compresses one block of the window from ``position``.
    private mutating func compressBlock(limit: Int, isFinal: Bool) {
        let span = window.span.bytes
        position = compressor.compressBlock(span, from: position, limit: limit, dataEnd: windowEnd, isFinal: isFinal)
        if isFinal && position >= limit {
            finalBlockWritten = true
        }
    }

    /// Moves the last 32 KB before ``position``, and everything after it, to the front of the window.
    private mutating func slide() {
        let start = max(0, position &- Self.historySize)
        guard start > 0 else { return }
        var span = window.mutableSpan
        span.copyBytes(within: start..<windowEnd, toByteOffset: 0)
        position &-= start
        windowEnd &-= start
        compressor.base &-= start
    }

    /// Copies a custom gzip header not yet delivered, then staged output, into `output`, as much as fits. Inlined (the
    /// header's part is out of line): as a call, it cost about 65 instructions a stream on 64-byte streams.
    @inline(__always)
    private mutating func deliver(into output: inout OutputRawSpan) -> Int {
        var delivered = 0
        if headerRemaining > 0 {
            // A custom header, at the stream's start: before anything staged.
            delivered = deliverHeader(into: &output)
            guard headerRemaining == 0 else { return delivered }
        }
        let count = min(compressor.stagedBytes.byteCount, output.freeCapacity)
        guard count > 0 else { return delivered }
        output.append(copying: compressor.stagedBytes.extracting(0..<count))
        compressor.consumeStaged(count)
        return delivered &+ count
    }

    /// Copies as much of a custom gzip header's remaining bytes as fits: out of line, as rare as the header.
    @inline(never)
    private mutating func deliverHeader(into output: inout OutputRawSpan) -> Int {
        let start = headerBytes.count &- headerRemaining
        let count = min(headerRemaining, output.freeCapacity)
        output.append(copying: headerBytes.span.bytes.extracting(start..<(start &+ count)))
        headerRemaining &-= count
        return count
    }

    // MARK: - Container

    private mutating func updateChecksum(_ bytes: RawSpan) {
        checksum = format.checksum(bytes, continuing: checksum)
        length &+= UInt32(truncatingIfNeeded: bytes.byteCount)
    }

    @inline(__always)
    private mutating func writeHeader() {
        headerWritten = true
        if gzipHeader != nil {
            writeGzipHeader()
            return
        }
        let header = format.header(level: level)
        if header.byteCount > 0 { compressor.stage(header.bytes.span.bytes.extracting(0..<header.byteCount)) }
    }

    /// Builds a custom gzip header's bytes for the stream: out of line, so the default header's path stays as it was.
    @inline(never)
    private mutating func writeGzipHeader() {
        gzipHeader!.encode(into: &headerBytes, extraFlags: DeflateFormat.gzipExtraFlags(level: level))
        headerRemaining = headerBytes.count
    }

    private mutating func writeTrailer() {
        compressor.alignOutput()
        let trailer = format.trailer(checksum: checksum, length: length)
        if trailer.byteCount > 0 { compressor.stage(trailer.bytes.span.bytes.extracting(0..<trailer.byteCount)) }
    }
}
