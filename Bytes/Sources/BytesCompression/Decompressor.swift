public import Bytes

/// A compressed format a ``Decompressor`` decodes, with what its container records about the stream.
///
/// ```swift
/// var decompressor = Decompressor()
/// try decompressor.reset(for: .xz(sizeHint: entry.uncompressedSize))   // zip's method 95
/// let progress = try decompressor.decompress(payload, into: &output)
/// ```
public enum DecompressionFormat: Hashable, Sendable {
    /// DEFLATE (RFC 1951) in its container: raw (zip's method 8, PNG), zlib, or gzip. Streams, and decodes into the
    /// caller's buffers after history (``historySize``).
    case deflate(DeflateFormat)
    /// PKWARE's Deflate64 (zip's method 9), raw. Streams, and decodes into the caller's buffers after history.
    case deflate64
    /// Brotli (RFC 7932). Streams.
    case brotli
    /// Zstandard (RFC 8878): one frame or several. Streams.
    case zstd
    /// bzip2: one stream or several. Streams.
    case bzip2
    /// Raw LZMA (LZMA1): zip's method 14 after its 4-byte header and the properties, `.lzma` files after their
    /// 13-byte header. Streams.
    ///
    /// - Parameters:
    ///   - properties: lc, lp, pb, and the dictionary size, from the container.
    ///   - uncompressedSize: The decompressed size, if the container states it: the stream may then end with an end
    ///     marker or without one. With `nil`, it must end with an end marker.
    ///   - sizeHint: The most the stream decodes to, when the container records it but the stream must end with
    ///     its marker (zip's general-purpose flag bit 1): the streaming window is no larger.
    case lzma(LZMAProperties, uncompressedSize: Int? = nil, sizeHint: Int? = nil)
    /// `.xz` files (zip's method 95, and Apple Encrypted Archives' LZMA segments). Streams.
    ///
    /// - Parameter sizeHint: The file's decompressed size, if the container records it (zip does): the streaming
    ///   window is no larger.
    case xz(sizeHint: Int? = nil)
    /// Apple's LZFSE (`bvx2`, `bvx-`, `bvxn` blocks). Whole buffers only.
    case lzfse
    /// Apple's LZVN, a raw stream. Whole buffers only.
    case lzvn
    /// LZ4: one raw block (Apple Encrypted Archives' segments), or Compression's `bv41` frames (`framed`). Whole
    /// buffers only; a raw block needs its decoded size (``Decompressor/decompressAll(_:into:decodedSize:)``).
    case lz4(framed: Bool)
    /// Apple's LZBITMAP. Whole buffers only.
    case lzbitmap
    /// Apple's LZRAVEN. Whole buffers only.
    case lzraven

    /// Whether ``Decompressor/decompress(_:into:)`` decodes it in pieces: everything but Apple's LZ formats and
    /// LZ4, which decode only whole buffers (``Decompressor/decompressAll(_:into:decodedSize:)``).
    public var isStreamable: Bool {
        switch self {
        case .deflate, .deflate64, .brotli, .zstd, .bzip2, .lzma, .xz: true
        case .lzfse, .lzvn, .lz4, .lzbitmap, .lzraven: false
        }
    }

    /// For the formats that decode straight into the caller's buffers
    /// (``Decompressor/decompress(_:into:historyCount:)``), how much of the latest output each buffer must start
    /// with: DEFLATE's 32 KB window, Deflate64's 64 KB. `nil` for the others, which keep their own windows.
    public var historySize: Int? {
        switch self {
        case .deflate: DeflateVariant.deflate.windowSize
        case .deflate64: DeflateVariant.deflate64.windowSize
        default: nil
        }
    }
}

/// One decoder for every format here, with each format's state made on first use and kept: a client that decodes
/// entries of several formats (an archive's methods, an encrypted archive's segments) resets it per entry and
/// allocates nothing after each format's first.
///
/// ```swift
/// var decompressor = Decompressor()
///
/// // Whole buffers: a segment into exactly its decoded size.
/// try decompressor.reset(for: .lzfse)
/// let consumed = try decompressor.decompressAll(segment, into: &output, decodedSize: rawSize)
///
/// // Streams: a zip entry a chunk at a time.
/// try decompressor.reset(for: .bzip2)
/// let progress = try decompressor.decompress(payload, into: &chunk)
///
/// // DEFLATE into the caller's buffers, after the history moved to their front.
/// try decompressor.reset(for: .deflate64)
/// let step = try decompressor.decompress(payload, into: &buffer, historyCount: history)
/// ```
///
/// Each call goes to the format's own decoder (``DeflateDecoder``, ``BZip2Decoder``, ``XZDecoder``, …) after one
/// `switch`: their loops are unchanged. Raw LZMA and xz share one streaming window: the one decoding has it.
/// It's `~Copyable` because it owns the decoders' memory.
@safe
public struct Decompressor: ~Copyable {
    /// The format the decoder was last reset for; `nil` before the first.
    public private(set) var format: DecompressionFormat?

    /// Which decoder the current format uses.
    private enum Codec {
        case none, deflate, zlib, gzip, deflate64, brotli, zstd, bzip2, lzma, xz, lzfse, lzvn, lz4Raw, lz4Framed, lzbitmap, lzraven
    }

    private var codec: Codec
    /// A raw LZMA or xz stream was started (``reset(for:)``) and its streaming decoder not yet made or reset.
    private var streamPending = false

    // Each made on its first stream, then kept.
    private var deflate: DeflateDecoder?
    private var zlib: DeflateDecoder?
    private var gzip: DeflateDecoder?
    private var deflate64: DeflateDecoder?
    private var brotli: BrotliDecoder?
    private var zstd: ZstdDecoder?
    private var bzip2: BZip2Decoder?
    /// Streaming raw LZMA and xz.
    private var lzma: LZMADecoder?
    private var xz: XZDecoder?
    /// Whole buffers of raw LZMA and xz, decoded straight into the caller's output (no window).
    private var lzma2: LZMA2Decoder?
    private var lzfse: LZFSEDecoder?
    private var lzbitmap: LZBitmapDecoder?
    private var lzraven: LZRAVENDecoder?

    /// Creates a decoder for `format`, making that format's state.
    ///
    /// - Parameter format: The first format to decode; ``reset(for:)`` changes it.
    /// - Throws: As ``reset(for:)``.
    public init(for format: DecompressionFormat) throws(BytesError) {
        codec = .none
        try reset(for: format)
    }

    /// Creates a decoder with no state: ``reset(for:)`` makes each format's on its first stream.
    public init() {
        codec = .none
    }

    /// Prepares to decode a new stream of `format`, discarding output not yet delivered. Makes the format's state on
    /// its first use; allocates nothing after that (a raw LZMA or xz window grows when a later stream needs more).
    ///
    /// - Parameter format: The stream's format.
    /// - Throws: ``BytesError/invalidValue`` for a negative size or hint.
    public mutating func reset(for format: DecompressionFormat) throws(BytesError) {
        self.format = format
        switch format {
        case let .deflate(container):
            switch container {
            case .raw:
                codec = .deflate
                if deflate == nil { deflate = DeflateDecoder(format: .raw) } else { deflate!.reset() }
            case .zlib:
                codec = .zlib
                if zlib == nil { zlib = DeflateDecoder(format: .zlib) } else { zlib!.reset() }
            case .gzip:
                codec = .gzip
                if gzip == nil { gzip = DeflateDecoder(format: .gzip) } else { gzip!.reset() }
            }
        case .deflate64:
            codec = .deflate64
            if deflate64 == nil { deflate64 = DeflateDecoder(variant: .deflate64) } else { deflate64!.reset() }
        case .brotli:
            codec = .brotli
            if brotli == nil { brotli = BrotliDecoder() } else { brotli!.reset() }
        case .zstd:
            codec = .zstd
            if zstd == nil { zstd = ZstdDecoder() } else { zstd!.reset() }
        case .bzip2:
            codec = .bzip2
            if bzip2 == nil { bzip2 = BZip2Decoder() } else { bzip2!.reset() }
        // Raw LZMA and xz: the streaming decoder (its model and window) is made or reset on the first streaming call,
        // so a stream decoded whole (``decompressAll(_:into:decodedSize:)``, with ``LZMA2Decoder``) makes only one
        // probability model.
        case let .lzma(_, uncompressedSize, sizeHint):
            if let uncompressedSize, uncompressedSize < 0 { throw .invalidValue }
            if let sizeHint, sizeHint < 0 { throw .invalidValue }
            codec = .lzma
            streamPending = true
        case let .xz(sizeHint):
            if let sizeHint, sizeHint < 0 { throw .invalidValue }
            codec = .xz
            streamPending = true
        case .lzfse:
            codec = .lzfse
            if lzfse == nil { lzfse = LZFSEDecoder() }
        case .lzvn:
            codec = .lzvn
        case let .lz4(framed):
            codec = framed ? .lz4Framed : .lz4Raw
        case .lzbitmap:
            codec = .lzbitmap
            if lzbitmap == nil { lzbitmap = LZBitmapDecoder() }
        case .lzraven:
            codec = .lzraven
            if lzraven == nil { lzraven = LZRAVENDecoder() }
        }
    }

    /// Makes or resets the raw LZMA or xz streaming decoder for the current format, on the first streaming call after
    /// ``reset(for:)``.
    private mutating func startStream() throws(BytesError) {
        streamPending = false
        switch format {
        case let .lzma(properties, uncompressedSize, sizeHint)?:
            if lzma == nil { lzma = LZMADecoder() }
            takeWindow(forXZ: false)
            try lzma!.reset(properties: properties, uncompressedSize: uncompressedSize, sizeHint: sizeHint)
        case let .xz(sizeHint)?:
            if xz == nil { xz = XZDecoder() }
            takeWindow(forXZ: true)
            xz!.reset(sizeHint: sizeHint)
        default:
            break
        }
    }

    /// Gives the raw LZMA or xz decoder (whichever is about to decode) the one window: the larger of the two, the
    /// other freed. Both have delivered everything (each is reset before it decodes).
    private mutating func takeWindow(forXZ: Bool) {
        guard lzma != nil, xz != nil else { return }
        if forXZ {
            guard lzma!.window.capacity > 0 else { return }
            if lzma!.window.capacity > xz!.window.capacity { xz!.window.exchangeMemory(with: &lzma!.window) }
            lzma!.window.free()
        } else {
            guard xz!.window.capacity > 0 else { return }
            if xz!.window.capacity > lzma!.window.capacity { lzma!.window.exchangeMemory(with: &xz!.window) }
            xz!.window.free()
        }
    }

    /// Whether the stream has ended and all its output has been delivered. Always `false` for formats that decode
    /// only whole buffers.
    public var isFinished: Bool {
        // Borrowed with `switch` (`x!.property` would consume the optional).
        switch codec {
        case .deflate: switch deflate { case let .some(d): d.isFinished; case .none: false }
        case .zlib: switch zlib { case let .some(d): d.isFinished; case .none: false }
        case .gzip: switch gzip { case let .some(d): d.isFinished; case .none: false }
        case .deflate64: switch deflate64 { case let .some(d): d.isFinished; case .none: false }
        case .brotli: switch brotli { case let .some(d): d.isFinished; case .none: false }
        case .zstd: switch zstd { case let .some(d): d.isFinished; case .none: false }
        case .bzip2: switch bzip2 { case let .some(d): d.isFinished; case .none: false }
        case .lzma: !streamPending && { switch lzma { case let .some(d): d.isFinished; case .none: false } }()
        case .xz: !streamPending && { switch xz { case let .some(d): d.isFinished; case .none: false } }()
        case .none, .lzfse, .lzvn, .lz4Raw, .lz4Framed, .lzbitmap, .lzraven: false
        }
    }

    // MARK: Streaming

    /// Decodes as much of `input` as it can, appending to `output`, continuing the current stream: the format's
    /// decoder's `decompress(_:into:)`, which says how input may be split (most formats anywhere; xz at its units,
    /// up to 65,542 bytes, ``XZDecoder/maximumUnitByteCount``).
    ///
    /// - Parameters:
    ///   - input: The next compressed bytes, starting with any not consumed last time.
    ///   - output: Where to append decompressed bytes.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: The format's decoder's errors; ``BytesError/invalidValue`` for a format that decodes only whole
    ///   buffers (``DecompressionFormat/isStreamable``).
    public mutating func decompress(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> TransformProgress {
        if streamPending { try startStream() }
        return switch codec {
        case .deflate: try deflate!.decompress(input, into: &output)
        case .zlib: try zlib!.decompress(input, into: &output)
        case .gzip: try gzip!.decompress(input, into: &output)
        case .deflate64: try deflate64!.decompress(input, into: &output)
        case .brotli: try brotli!.decompress(input, into: &output)
        case .zstd: try zstd!.decompress(input, into: &output)
        case .bzip2: try bzip2!.decompress(input, into: &output)
        case .lzma: try lzma!.decompress(input, into: &output)
        case .xz: try xz!.decompress(input, into: &output)
        case .none, .lzfse, .lzvn, .lz4Raw, .lz4Framed, .lzbitmap, .lzraven: throw .invalidValue
        }
    }

    /// Decodes as much of `input` as it can into `buffer` after its first `historyCount` bytes, continuing the
    /// current stream, for the formats with a ``DecompressionFormat/historySize``: DEFLATE's
    /// ``DeflateDecoder/decompress(_:into:historyCount:)``, which says how to move the history between calls.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes, starting with any not consumed last time.
    ///   - buffer: The history, then room to decode into.
    ///   - historyCount: How many bytes at the start of `buffer` are history.
    /// - Returns: What was consumed and produced (after the history), and why it returned.
    /// - Throws: The decoder's errors; ``BytesError/invalidValue`` for a format without a history size (or before
    ///   the first ``reset(for:)``).
    public mutating func decompress(
        _ input: RawSpan, into buffer: inout MutableRawSpan, historyCount: Int
    ) throws(BytesError) -> TransformProgress {
        switch codec {
        case .deflate: try deflate!.decompress(input, into: &buffer, historyCount: historyCount)
        case .deflate64: try deflate64!.decompress(input, into: &buffer, historyCount: historyCount)
        case .zlib: try zlib!.decompress(input, into: &buffer, historyCount: historyCount)
        case .gzip: try gzip!.decompress(input, into: &buffer, historyCount: historyCount)
        default: throw .invalidValue
        }
    }

    // MARK: Whole buffers

    /// Decodes a whole stream, from its start, straight into `output`'s free capacity: no window and no copies,
    /// the fastest way when the output has room for all of it. Discards any stream ``decompress(_:into:)`` was
    /// decoding (the next one starts with ``reset(for:)``).
    ///
    /// Raw LZMA and xz decode with ``LZMA2Decoder`` here, straight into `output`: no window is made.
    ///
    /// - Parameters:
    ///   - input: The stream. Bytes after its end are left alone (all of a raw LZ4 block, LZRAVEN buffer, or LZVN
    ///     stream is taken as the stream).
    ///   - output: Where to append the decoded bytes; it needs room for all of them. Bytes of its free capacity past
    ///     them may be overwritten.
    ///   - decodedSize: The size the container says the stream decodes to, if it does: a stream decoding to any
    ///     other size throws ``BytesError/mismatch``. Raw LZ4 blocks need it (they don't record their end).
    /// - Returns: The number of input bytes the stream took.
    /// - Throws: The format's decoder's errors; ``BytesError/mismatch`` for a size other than `decodedSize`;
    ///   ``BytesError/insufficientCapacity`` if `output` has room for fewer than `decodedSize` bytes;
    ///   ``BytesError/invalidValue`` for a negative `decodedSize`, or a raw LZ4 block without one.
    public mutating func decompressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, decodedSize: Int? = nil
    ) throws(BytesError) -> Int {
        if let decodedSize {
            guard decodedSize >= 0 else { throw .invalidValue }
            guard decodedSize <= output.freeCapacity else { throw .insufficientCapacity }
        }
        let start = output.byteCount
        let consumed: Int
        switch codec {
        case .none:
            throw .invalidValue
        // The decoders that check `decodedSize` themselves.
        case .bzip2:
            return try bzip2!.decompressAll(input, decodedSize: decodedSize, into: &output)
        case .lzbitmap:
            return try lzbitmap!.decompressAll(input, decodedSize: decodedSize, into: &output)
        case .lzraven:
            return try lzraven!.decompressAll(input, decodedSize: decodedSize, into: &output)
        case .lz4Raw:
            guard let decodedSize else { throw .invalidValue }
            try LZ4Decoder().decompressRaw(input, decodedSize: decodedSize, into: &output)
            return input.byteCount
        // The others, checked after.
        case .deflate:
            deflate!.reset()
            consumed = try deflate!.decompressAll(input, into: &output)
        case .zlib:
            zlib!.reset()
            consumed = try zlib!.decompressAll(input, into: &output)
        case .gzip:
            gzip!.reset()
            consumed = try gzip!.decompressAll(input, into: &output)
        case .deflate64:
            deflate64!.reset()
            consumed = try deflate64!.decompressAll(input, into: &output)
        case .brotli:
            brotli!.reset()
            consumed = try brotli!.decompressAll(input, into: &output)
        case .zstd:
            zstd!.reset()
            consumed = try zstd!.decompressAll(input, into: &output)
        case .lzma:
            guard case let .lzma(properties, uncompressedSize, _)? = format else { preconditionFailure("Raw LZMA's format") }
            if lzma2 == nil { lzma2 = LZMA2Decoder() }
            consumed = try lzma2!.decompressLZMA(input, properties: properties, uncompressedSize: uncompressedSize, into: &output)
        case .xz:
            if lzma2 == nil { lzma2 = LZMA2Decoder() }
            consumed = try lzma2!.decompressXZ(input, into: &output)
        case .lzfse:
            consumed = try lzfse!.decompressAll(input, into: &output)
        case .lzvn:
            consumed = try LZVNDecoder().decompressAll(input, into: &output)
        case .lz4Framed:
            consumed = try LZ4Decoder().decompressFramed(input, into: &output)
        }
        if let decodedSize, output.byteCount &- start != decodedSize { throw .mismatch }
        return consumed
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension Decompressor: @unchecked Sendable {}

extension Decompressor: ResettableByteTransform {
    public typealias Failure = BytesError

    /// The most unconsumed input a call may need before it can make progress: xz's largest unit
    /// (``XZDecoder/maximumUnitByteCount``), the most of any format here.
    public static var maximumUnitByteCount: Int { XZDecoder.maximumUnitByteCount }

    /// Starts the current format's stream again (``reset(for:)`` with the same format); before the first, does
    /// nothing.
    public mutating func reset() {
        guard let format else { return }
        // The format was accepted once, so it's accepted again.
        try? reset(for: format)
    }

    /// Decodes as the format's decoder's `transform(_:into:flush:)` does: at `.finish`, input that ends inside the
    /// stream throws ``BytesError/insufficientData``; for formats where another stream may follow (xz, Zstandard),
    /// a stream's end reads as ``TransformStatus/needsInput`` until then.
    ///
    /// - Throws: As ``decompress(_:into:)``.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        if streamPending { try startStream() }
        return switch codec {
        case .deflate: try deflate!.transform(input, into: &output, flush: flush)
        case .zlib: try zlib!.transform(input, into: &output, flush: flush)
        case .gzip: try gzip!.transform(input, into: &output, flush: flush)
        case .deflate64: try deflate64!.transform(input, into: &output, flush: flush)
        case .brotli: try brotli!.transform(input, into: &output, flush: flush)
        case .zstd: try zstd!.transform(input, into: &output, flush: flush)
        case .bzip2: try bzip2!.transform(input, into: &output, flush: flush)
        case .lzma: try lzma!.transform(input, into: &output, flush: flush)
        case .xz: try xz!.transform(input, into: &output, flush: flush)
        case .none, .lzfse, .lzvn, .lz4Raw, .lz4Framed, .lzbitmap, .lzraven: throw .invalidValue
        }
    }
}
