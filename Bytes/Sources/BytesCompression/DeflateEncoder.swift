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
    public let level: Int

    private var compressor: DeflateCompressor

    /// The streaming window: 32 KB of history, then room for input.
    private var window: UniqueArray<UInt8>
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

    static var historySize: Int { Deflate.windowSize }
    static var windowCapacity: Int { historySize + (256 << 10) }
    /// Input kept back from compression until more arrives: a longest match, and 8 bytes for loads.
    static var lookahead: Int { Deflate.maximumMatch + 8 }

    /// Creates an encoder, allocating its tables and buffers (about 1.5 MB).
    ///
    /// - Parameters:
    ///   - format: The container to write.
    ///   - level: The compression level: 0 (stored) through 9; higher levels map to 9.
    public init(format: DeflateFormat = .raw, level: Int = 6) {
        self.format = format
        self.level = min(max(level, 0), 9)
        compressor = DeflateCompressor(level: self.level)
        window = UniqueArray(repeating: 0, count: Self.windowCapacity)
        checksum = format == .zlib ? 1 : 0
    }

    /// Prepares to encode a new stream, discarding anything not yet delivered. Keeps the allocations.
    public mutating func reset() {
        compressor.reset()
        windowEnd = 0
        position = 0
        headerWritten = false
        finalBlockWritten = false
        isFinished = false
        flushed = false
        checksum = format == .zlib ? 1 : 0
        length = 0
    }

    /// An upper bound on the compressed size of `byteCount` bytes, header and trailer included, for one
    /// ``compressAll(_:into:)`` call.
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
    /// The encoder must be fresh or ``reset()``. ``maximumCompressedSize(forByteCount:format:)`` bytes of
    /// free capacity are always enough.
    ///
    /// - Parameters:
    ///   - input: All the data.
    ///   - output: Where to append the stream.
    /// - Throws: ``BytesError/insufficientCapacity`` if the stream doesn't fit (`output` then holds part of
    ///   it).
    public mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) {
        precondition(!headerWritten, "compressAll needs a fresh or reset encoder")
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
        guard compressor.stagedBytes.byteCount == 0 else { throw .insufficientCapacity }
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
            if compressor.stagedBytes.byteCount > 0 {
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

    /// Copies staged output into `output`, as much as fits.
    private mutating func deliver(into output: inout OutputRawSpan) -> Int {
        let count = min(compressor.stagedBytes.byteCount, output.freeCapacity)
        guard count > 0 else { return 0 }
        output.append(copying: compressor.stagedBytes.extracting(0..<count))
        compressor.consumeStaged(count)
        return count
    }

    // MARK: - Container

    private mutating func updateChecksum(_ bytes: RawSpan) {
        switch format {
        case .raw: break
        case .zlib: checksum = Adler32.checksum(bytes, continuing: checksum)
        case .gzip:
            checksum = CRC32.checksum(bytes, continuing: checksum)
            length &+= UInt32(truncatingIfNeeded: bytes.byteCount)
        }
    }

    private mutating func writeHeader() {
        headerWritten = true
        switch format {
        case .raw:
            break
        case .zlib:
            let header = ZlibHeader.header(level: level)
            let bytes: InlineArray<2, UInt8> = [UInt8(header >> 8), UInt8(header & 0xFF)]
            compressor.stage(bytes.span.bytes)
        case .gzip:
            // Magic, DEFLATE, no flags, no time, extra flags (2 slowest, 4 fastest), unknown OS.
            let extra: UInt8 = level >= 8 ? 2 : level <= 1 ? 4 : 0
            let bytes: InlineArray<10, UInt8> = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, extra, 255]
            compressor.stage(bytes.span.bytes)
        }
    }

    private mutating func writeTrailer() {
        compressor.alignOutput()
        switch format {
        case .raw:
            break
        case .zlib:
            let bytes: InlineArray<4, UInt8> = [
                UInt8(checksum >> 24), UInt8(checksum >> 16 & 0xFF), UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF),
            ]
            compressor.stage(bytes.span.bytes)
        case .gzip:
            let bytes: InlineArray<8, UInt8> = [
                UInt8(checksum & 0xFF), UInt8(checksum >> 8 & 0xFF), UInt8(checksum >> 16 & 0xFF), UInt8(checksum >> 24),
                UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24),
            ]
            compressor.stage(bytes.span.bytes)
        }
    }
}
