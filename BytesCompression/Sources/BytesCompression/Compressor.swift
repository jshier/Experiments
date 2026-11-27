public import Bytes

/// A format a ``Compressor`` encodes, with its parameters: ``Decompressor``'s ``DecompressionFormat``, the other way.
///
/// ```swift
/// var compressor = Compressor()
/// try compressor.reset(for: .lzbitmap)          // an APFS chunk
/// try compressor.compressAll(chunk, into: &fork)
/// ```
///
/// Parameters follow one rule, here and in each format's encoder: levels above the encoder's highest run as its
/// highest; a negative level, or a window out of its format's range, is invalid (``Compressor/reset(for:)`` throws;
/// the encoders' initializers, which can't throw, trap).
public enum CompressionFormat: Hashable, Sendable {
    /// DEFLATE (RFC 1951) in its container, at `level`: 1–9, or 0 for stored blocks; higher levels run as 9. Streams.
    case deflate(DeflateFormat, level: Int = 6)
    /// Brotli (RFC 7932) at `quality`, 0–11 (0 runs as 1; 10 and 11 run as 9, the highest this encoder has; higher as
    /// 9 too), with a window of 2^`windowBits` bytes, 10 through 24. Streams.
    case brotli(quality: Int = 5, windowBits: Int = 22)
    /// Zstandard (RFC 8878) at libzstd's `level`: 1–4, or 0 for libzstd's default (3); higher levels run as 4. With a
    /// window of 2^`windowLog` bytes, 10 through 27 (the level's if `nil`). Streams.
    case zstd(level: Int = 3, windowLog: Int? = nil)
    /// Apple's LZFSE (Compression's bytes). Whole buffers only.
    case lzfse
    /// Apple's LZVN (Compression's bytes). Whole buffers only.
    case lzvn
    /// Apple's LZBITMAP (Compression's bytes). Whole buffers only.
    case lzbitmap

    /// Zstandard for HTTP's `zstd` content coding (RFC 9659): a 512 KiB window
    /// (``ZstdEncoder/Parameters/httpWindowLog``), whatever the level's own, well within the 8 MiB a recipient must
    /// accept (``DecompressionFormat/zstdForHTTP``, the other way).
    ///
    /// - Parameter level: As ``zstd(level:windowLog:)``'s.
    public static func zstdForHTTP(level: Int = 3) -> Self {
        .zstd(level: level, windowLog: ZstdEncoder.Parameters.httpWindowLog)
    }

    /// Whether ``Compressor/compress(_:into:flush:)`` encodes it in pieces: everything but Apple's LZ formats, which
    /// encode only whole buffers (``Compressor/compressAll(_:into:)``).
    public var isStreamable: Bool {
        switch self {
        case .deflate, .brotli, .zstd: true
        case .lzfse, .lzvn, .lzbitmap: false
        }
    }

    /// An upper bound on the encoded size of `byteCount` bytes, for one ``Compressor/compressAll(_:into:)`` call:
    /// output with this much room always takes the whole stream (the format's encoder's bound; DEFLATE's counts its
    /// container's header and trailer). Saturates at `Int.max` for sizes no buffer has.
    ///
    /// - Parameter byteCount: The input's size, 0 or more.
    public func maximumCompressedSize(forByteCount byteCount: Int) -> Int {
        precondition(byteCount >= 0, "A size is 0 or more")
        // Each bound is the input plus a fraction of it plus a constant: past `Int.max / 2` they'd wrap.
        guard byteCount <= Int.max / 2 else { return .max }
        return switch self {
        case let .deflate(container, _): DeflateEncoder.maximumCompressedSize(forByteCount: byteCount, format: container)
        case .brotli: BrotliEncoder.maximumCompressedSize(forByteCount: byteCount)
        case .zstd: ZstdEncoder.maximumCompressedSize(forByteCount: byteCount)
        case .lzfse: LZFSEEncoder.maximumCompressedSize(forByteCount: byteCount)
        case .lzvn: LZVNEncoder.maximumCompressedSize(forByteCount: byteCount)
        case .lzbitmap: LZBitmapEncoder.maximumCompressedSize(forByteCount: byteCount)
        }
    }

    /// Why an encoder can't take the parameters, or `nil` if it can: ``BytesError/unsupported`` for a negative
    /// Zstandard level (libzstd's fast levels, which this encoder doesn't have); ``BytesError/invalidValue`` for
    /// another negative level or quality, or a window out of its format's range (Brotli's 10 through 24, Zstandard's
    /// 10 through 27).
    var parameterError: BytesError? {
        switch self {
        case let .deflate(_, level): level >= 0 ? nil : .invalidValue
        case let .brotli(quality, windowBits): quality >= 0 && (10...24).contains(windowBits) ? nil : .invalidValue
        case let .zstd(level, windowLog):
            if let windowLog, !(10...27).contains(windowLog) { .invalidValue } else if level < 0 { .unsupported } else { nil }
        case .lzfse, .lzvn, .lzbitmap: nil
        }
    }
}

/// One encoder for every format here with an encoder, chosen at run time, each format's encoder made on first use and
/// kept: a client that encodes with several (an extraction's APFS chunks, an HTTP body's content coding) allocates
/// nothing after each format's first.
///
/// ```swift
/// var compressor = Compressor()
/// try compressor.reset(for: .deflate(.gzip, level: 6))
/// let progress = try compressor.compress(body, into: &output, flush: .finish)   // a stream, in pieces
///
/// try compressor.reset(for: .lzfse)
/// try compressor.compressAll(chunk, into: &output)                             // a whole buffer
/// let encoded = try compressor.compressAll(chunk)                              // or into a new array
/// ```
///
/// Each call goes to the format's own encoder (``DeflateEncoder``, ``BrotliEncoder``, ``ZstdEncoder``,
/// ``LZFSEEncoder``, ``LZVNEncoder``, ``LZBitmapEncoder``) after one `switch`: their loops are unchanged. An encoder is
/// made again only when its parameters change (a quality, a window, a DEFLATE container: a DEFLATE level changes in
/// place, keeping the encoder's memory). It's `~Copyable` because it owns the
/// encoders' memory.
@safe
public struct Compressor: ~Copyable {
    /// The format the encoder was last reset for; `nil` before the first.
    public private(set) var format: CompressionFormat?

    /// Whether the current format's encoder is made and reset: false before the first ``reset(for:)`` and after
    /// ``releaseMemory()``, when coding calls throw ``BytesError/invalidValue``.
    private var isReady = false

    // Each made on first use, and kept with the format it was made for.
    private var deflate: DeflateEncoder?
    private var deflateFormat: CompressionFormat?
    private var brotli: BrotliEncoder?
    private var brotliFormat: CompressionFormat?
    private var zstd: ZstdEncoder?
    private var zstdFormat: CompressionFormat?
    private var lzfse: LZFSEEncoder?
    private var lzvn: LZVNEncoder?
    private var lzbitmap: LZBitmapEncoder?

    /// Creates an encoder with no state: ``reset(for:)`` makes each format's on its first use.
    public init() {}

    /// Creates an encoder for `format`, making that format's encoder.
    ///
    /// - Throws: As ``reset(for:)``.
    public init(for format: CompressionFormat) throws(BytesError) {
        try reset(for: format)
    }

    /// Prepares to encode a new stream of `format`. Makes the format's encoder on its first use, or when its parameters
    /// differ from the kept one's; otherwise resets it, keeping its memory. High levels and qualities run as each
    /// encoder's highest (``CompressionFormat`` says which).
    ///
    /// - Throws: ``BytesError/invalidValue`` for parameters no encoder takes: a negative level or quality, a window out
    ///   of its format's range; ``BytesError/unsupported`` for a negative Zstandard level (libzstd's fast levels). The
    ///   current format is then unchanged.
    public mutating func reset(for format: CompressionFormat) throws(BytesError) {
        if let error = format.parameterError { throw error }
        switch format {
        case let .deflate(container, level):
            if deflateFormat == format {
                deflate!.reset()
            } else if case let .deflate(kept, _)? = deflateFormat, kept == container {
                // Another level of the same container: the encoder's memory serves any level.
                deflate!.reset(level: level)
            } else {
                deflate = DeflateEncoder(format: container, level: level)
            }
            deflateFormat = format
        case let .brotli(quality, windowBits):
            if brotliFormat == format { brotli!.reset() } else { brotli = BrotliEncoder(quality: quality, windowBits: windowBits) }
            brotliFormat = format
        case let .zstd(level, windowLog):
            if zstdFormat == format { zstd!.reset() } else { zstd = ZstdEncoder(level: level, windowLog: windowLog) }
            zstdFormat = format
        // Apple's encoders start a new stream on every call: nothing to reset.
        case .lzfse:
            if lzfse == nil { lzfse = LZFSEEncoder() }
        case .lzvn:
            if lzvn == nil { lzvn = LZVNEncoder() }
        case .lzbitmap:
            if lzbitmap == nil { lzbitmap = LZBitmapEncoder() }
        }
        self.format = format
        isReady = true
    }

    /// Starts the current format's stream again (``reset(for:)`` with the same format), making its encoder again after
    /// ``releaseMemory()``; before the first, does nothing.
    public mutating func reset() {
        guard let format else { return }
        // Accepted once, so accepted again.
        try? reset(for: format)
    }

    /// Frees every format's encoder, as ``init()`` holds none, keeping ``format``: the next ``reset(for:)``, or
    /// ``reset()`` for the same format (the next body), makes the format's encoder again. As
    /// ``Decompressor/releaseMemory()``: for an encoder that will sit idle. Each encoder holds its tables and a streaming
    /// window (DEFLATE about 1.5 MB, Brotli and Zstandard up to their window plus a block or 256 KB).
    ///
    /// It discards a stream in progress; until the next reset, coding calls throw ``BytesError/invalidValue``.
    public mutating func releaseMemory() {
        isReady = false
        deflate = nil
        deflateFormat = nil
        brotli = nil
        brotliFormat = nil
        zstd = nil
        zstdFormat = nil
        lzfse = nil
        lzvn = nil
        lzbitmap = nil
    }

    /// Encodes as much of `input` as fits into `output`, continuing the current stream: the format's encoder's
    /// `compress(_:into:flush:)`. `.finish` ends the stream; `.flush` makes everything so far decodable.
    ///
    /// - Throws: The format's encoder's errors; ``BytesError/unsupported`` for a format that encodes only whole
    ///   buffers (``CompressionFormat/isStreamable``); ``BytesError/invalidValue`` before the first ``reset(for:)``
    ///   (or after ``releaseMemory()``).
    public mutating func compress(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        guard isReady else { throw .invalidValue }
        switch format {
        case .deflate?: return try deflate!.compress(input, into: &output, flush: flush)
        case .brotli?: return try brotli!.compress(input, into: &output, flush: flush)
        case .zstd?: return try zstd!.compress(input, into: &output, flush: flush)
        case .lzfse?, .lzvn?, .lzbitmap?: throw .unsupported
        case nil: throw .invalidValue
        }
    }

    /// Encodes `input` as one whole stream of the current format, appending it to `output`. Every call starts a new
    /// stream, whatever was encoded before, keeping the encoder's memory.
    ///
    /// - Throws: ``BytesError/insufficientCapacity`` if the stream doesn't fit in `output`'s free capacity, by the
    ///   format's encoder's rules (Apple's need room beyond the stream: Compression's); room for
    ///   ``CompressionFormat/maximumCompressedSize(forByteCount:)`` always fits. The encoder's other errors;
    ///   ``BytesError/invalidValue`` before the first ``reset(for:)`` (or after ``releaseMemory()``).
    public mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) {
        guard isReady else { throw .invalidValue }
        switch format {
        case .deflate?: try deflate!.compressAll(input, into: &output)
        case .brotli?: try brotli!.compressAll(input, into: &output)
        case .zstd?: try zstd!.compressAll(input, into: &output)
        case .lzfse?: try lzfse!.compressAll(input, into: &output)
        case .lzvn?: try lzvn!.compressAll(input, into: &output)
        case .lzbitmap?: try lzbitmap!.compressAll(input, into: &output)
        case nil: throw .invalidValue
        }
    }

    /// Encodes `input` as one whole stream of the current format into a new array, as
    /// ``compressAll(_:into:)`` encodes into a buffer.
    ///
    /// ```swift
    /// var compressor = try Compressor(for: .zstd(level: 3))
    /// let frame = try compressor.compressAll(body)
    /// ```
    ///
    /// The array is reserved once, for the format's ``CompressionFormat/maximumCompressedSize(forByteCount:)``, and
    /// encoded into in place: nothing is zeroed or copied. Its capacity stays that bound.
    ///
    /// - Throws: As ``compressAll(_:into:)``.
    public mutating func compressAll(_ input: RawSpan) throws(BytesError) -> [UInt8] {
        guard isReady, let format else { throw .invalidValue }
        let capacity = format.maximumCompressedSize(forByteCount: input.byteCount)
        var bytes: [UInt8] = []
        try bytes.append(writingUpTo: capacity) { (output: inout OutputRawSpan) throws(BytesError) in
            try compressAll(input, into: &output)
        }
        return bytes
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension Compressor: @unchecked Sendable {}

extension Compressor: ResettableByteTransform {
    public typealias Failure = BytesError

    /// Encodes as ``compress(_:into:flush:)`` does: a stage of a `Pipeline` whose format is chosen at run time.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        try compress(input, into: &output, flush: flush)
    }
}
