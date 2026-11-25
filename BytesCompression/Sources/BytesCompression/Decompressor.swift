public import Bytes

/// A compressed format a ``Decompressor`` decodes, with what its container records about the stream.
///
/// ```swift
/// var decompressor = Decompressor()
/// try decompressor.reset(for: .xz(sizeHint: entry.uncompressedSize))   // zip's method 95
/// let progress = try decompressor.decompress(payload, into: &output)
/// ```
public enum DecompressionFormat: Hashable, Sendable {
    /// DEFLATE (RFC 1951) in its container: raw (zip's method 8, PNG), zlib, or gzip (one member or several). Streams,
    /// and decodes into the caller's buffers after history (``historySize``).
    case deflate(DeflateFormat)
    /// PKWARE's Deflate64 (zip's method 9), raw. Streams, and decodes into the caller's buffers after history.
    case deflate64
    /// Brotli (RFC 7932). Streams.
    case brotli
    /// Zstandard (RFC 8878): one frame or several. Streams.
    ///
    /// - Parameters:
    ///   - maximumWindowSize: The largest window streaming may allocate: a frame needing more is refused
    ///     (``BytesError/limitExceeded``) before anything is allocated. 128 MB (the decoder's own default) unless the
    ///     container sets its own: HTTP's `zstd` content coding, 8 MB (RFC 9659 §3).
    ///   - sizeHint: The most the data decodes to, when the container records it (zip does): no frame's window is
    ///     larger, so a frame without a content size can't make the decoder reserve a 128 MB window for a small
    ///     entry. Matches reaching further back than the hint are refused.
    // The default is `ZstdDecoder.defaultMaximumWindowSize`'s value: a public case's default can't name the package
    // decoder (only `Decompressor` is public), and `ZstdDecoderTests` checks the two agree.
    case zstd(maximumWindowSize: Int = 1 << 27, sizeHint: Int? = nil)
    /// bzip2: one stream or several. Streams.
    case bzip2
    /// Raw LZMA (LZMA1): zip's method 14 after its 4-byte header and the properties, `.lzma` files after their
    /// 13-byte header. Streams.
    ///
    /// - Parameters:
    ///   - properties: lc, lp, pb, and the dictionary size, from the container.
    ///   - uncompressedSize: The decompressed size, if the container states it: the stream may then end with an end
    ///     marker or without one. With `nil`, it must end with an end marker.
    ///   - maximumSize: The most the stream may decode to, when the container records it but the stream must end
    ///     with its marker (zip's general-purpose flag bit 1): a stream decoding past it throws
    ///     ``BytesError/limitExceeded`` at the first byte past, and the streaming window is no larger. Ignored with
    ///     `uncompressedSize`.
    case lzma(LZMAProperties, uncompressedSize: Int? = nil, maximumSize: Int? = nil)
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
    package var isStreamable: Bool {
        switch self {
        case .deflate, .deflate64, .brotli, .zstd, .bzip2, .lzma, .xz: true
        case .lzfse, .lzvn, .lz4, .lzbitmap, .lzraven: false
        }
    }

    /// Whether another stream may follow the end of one, decoded as its continuation: gzip members, Zstandard frames,
    /// xz and bzip2 streams. A decoder of these that reports ``TransformStatus/finished`` with input still to come may
    /// go on when given more (``endIsFinal(unconsumed:inputEnded:)``).
    public var allowsConcatenation: Bool {
        switch self {
        case .deflate(.gzip), .zstd, .xz, .bzip2: true
        default: false
        }
    }

    /// Whether a stream's end, reported by its decoder with `unconsumed` bytes of the input it was given left over, is
    /// the end of the data: always when the input has ended or the format doesn't concatenate; otherwise only when the
    /// decoder saw what follows and left it, which only bzip2 does (four or more bytes that aren't a `BZh` header).
    /// gzip, Zstandard, and xz report an end only with all their input consumed (a following byte is read as the next
    /// stream's start); bzip2 also reports one with 1–3 bytes left, too few to tell.
    ///
    /// - Parameters:
    ///   - unconsumed: The input bytes the decoder didn't consume.
    ///   - inputEnded: Whether no more input will come.
    func endIsFinal(unconsumed: Int, inputEnded: Bool) -> Bool {
        guard !inputEnded, allowsConcatenation else { return true }
        if case .bzip2 = self { return unconsumed >= 4 }
        return false
    }

    /// For the formats that decode straight into the caller's buffers
    /// (``Decompressor/decompress(_:into:historyCount:)``), how much of the latest output each buffer must start
    /// with: DEFLATE's 32 KB window, Deflate64's 64 KB. `nil` for the others, which keep their own windows.
    package var historySize: Int? {
        switch self {
        case .deflate: DeflateVariant.deflate.windowSize
        case .deflate64: DeflateVariant.deflate64.windowSize
        default: nil
        }
    }

    /// For the formats that stream, the most unconsumed input their decoder needs before it can make progress (its
    /// `ByteTransform.maximumUnitByteCount`): a buffer between it and its source holds at least this much, or a stream
    /// can stall with the buffer full. `nil` for the formats that decode only whole buffers (``isStreamable``).
    ///
    /// DEFLATE and Deflate64: 289 bytes (a dynamic block's header); Brotli: 451 (a command tree's prefix code; a
    /// meta-block's header is read a prefix code and context map entry at a time); Zstandard: 1 (it keeps partial
    /// units itself); bzip2: 1,324 (one Huffman table's code lengths); raw LZMA: 20; xz: 65,542 (an LZMA2 chunk).
    public var maximumUnitByteCount: Int? {
        switch self {
        case .deflate, .deflate64: DeflateDecoder.maximumUnitByteCount
        case .brotli: BrotliDecoder.maximumUnitByteCount
        case .zstd: ZstdDecoder.maximumUnitByteCount
        case .bzip2: BZip2Decoder.maximumUnitByteCount
        case .lzma: LZMADecoder.maximumUnitByteCount
        case .xz: XZDecoder.maximumUnitByteCount
        case .lzfse, .lzvn, .lz4, .lzbitmap, .lzraven: nil
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
        case none, deflate, deflate64, brotli, zstd, bzip2, lzma, xz, lzfse, lzvn, lz4Raw, lz4Framed, lzbitmap, lzraven
    }

    private var codec: Codec
    /// A raw LZMA or xz stream was started (``reset(for:)``) and its streaming decoder not yet made or reset.
    private var streamPending = false

    // Each made on its first stream, then kept.
    /// DEFLATE in every container (raw, zlib, gzip): one decoder, reset to each stream's. (Its window and tables are
    /// 184 KiB; one decoder per container took that three times over.)
    private var deflate: DeflateDecoder?
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
    /// - Throws: ``BytesError/invalidValue`` for a negative size, hint, or window limit.
    public mutating func reset(for format: DecompressionFormat) throws(BytesError) {
        self.format = format
        switch format {
        case let .deflate(container):
            codec = .deflate
            // A DEFLATE decoder takes every container (Deflate64's are raw only), so the reset doesn't throw.
            if deflate == nil { deflate = DeflateDecoder(format: container) } else { try deflate!.reset(format: container) }
        case .deflate64:
            codec = .deflate64
            if deflate64 == nil { deflate64 = DeflateDecoder(variant: .deflate64) } else { deflate64!.reset() }
        case .brotli:
            codec = .brotli
            if brotli == nil { brotli = BrotliDecoder() } else { brotli!.reset() }
        case let .zstd(maximumWindowSize, sizeHint):
            guard maximumWindowSize >= 0, (sizeHint ?? 0) >= 0 else { throw .invalidValue }
            codec = .zstd
            // The decoder is kept while the limit is the same (a container's streams all have its limit); the hint is
            // per stream, so it doesn't make a new one.
            let kept = switch zstd {
            case let .some(decoder): decoder.maximumWindowSize == maximumWindowSize
            case .none: false
            }
            if !kept { zstd = ZstdDecoder(maximumWindowSize: maximumWindowSize) }
            zstd!.reset(sizeHint: sizeHint)
        case .bzip2:
            codec = .bzip2
            if bzip2 == nil { bzip2 = BZip2Decoder() } else { bzip2!.reset() }
        // Raw LZMA and xz: the streaming decoder (its model and window) is made or reset on the first streaming call,
        // so a stream decoded whole (``decompressAll(_:into:decodedSize:)``, with ``LZMA2Decoder``) makes only one
        // probability model.
        case let .lzma(_, uncompressedSize, maximumSize):
            if let uncompressedSize, uncompressedSize < 0 { throw .invalidValue }
            if let maximumSize, maximumSize < 0 { throw .invalidValue }
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

    /// Frees every format's state, as ``init()`` holds none, keeping ``format``: the next ``reset(for:)``, or
    /// ``reset()`` for the same format (a pipeline's next message), makes the format's state again.
    ///
    /// Each format's decoder keeps its memory between streams so that reusing it allocates nothing. Most of that is
    /// small, but a streaming window grows to the largest stream's (Zstandard's up to its window limit, 128 MiB by
    /// default; raw LZMA's and xz's to a dictionary plus room) and stays at that size. Call this when the decompressor
    /// will sit idle (an HTTP connection between messages, an app between archives) or after a stream with a large
    /// window. Windows of 9 MiB or more (zstd's past HTTP's 8 MiB limit, xz's from `xz -5` on) go back to the system at
    /// once; smaller allocations go back to malloc, which keeps them for the process's next allocations. Dropping the
    /// decompressor frees the same memory.
    ///
    /// Making a format's state again costs about 2–44 K instructions (RESULTS.md, "Small inputs and making coders"),
    /// plus faulting in a large window's pages as the next stream touches them.
    ///
    /// It discards a stream in progress; until the next reset, decoding calls throw ``BytesError/invalidValue``.
    public mutating func releaseMemory() {
        codec = .none
        streamPending = false
        deflate = nil
        deflate64 = nil
        brotli = nil
        zstd = nil
        bzip2 = nil
        lzma = nil
        xz = nil
        lzma2 = nil
        lzfse = nil
        lzbitmap = nil
        lzraven = nil
    }

    /// Makes or resets the raw LZMA or xz streaming decoder for the current format, on the first streaming call after
    /// ``reset(for:)``.
    private mutating func startStream() throws(BytesError) {
        streamPending = false
        switch format {
        case let .lzma(properties, uncompressedSize, maximumSize)?:
            if lzma == nil { lzma = LZMADecoder() }
            takeWindow(forXZ: false)
            try lzma!.reset(properties: properties, uncompressedSize: uncompressedSize, maximumSize: maximumSize)
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
    /// decoder's `decompress(_:into:)`, which says how input may be split (anywhere; the most unconsumed input it needs
    /// to make progress is the format's ``DecompressionFormat/maximumUnitByteCount``, xz's 65,542 bytes the largest).
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
        default: throw .invalidValue
        }
    }

    // MARK: Whole buffers

    /// Decodes a whole stream, from its start, straight into `output`'s free capacity: no window and no copies,
    /// the fastest way when the output has room for all of it. Every call starts a new stream of the current format,
    /// whatever was decoded before, keeping the decoders' memory; it discards any stream ``decompress(_:into:)`` was
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
            return try bzip2!.decompressAll(input, into: &output, decodedSize: decodedSize)
        case .lzbitmap:
            return try lzbitmap!.decompressAll(input, into: &output, decodedSize: decodedSize)
        case .lzraven:
            return try lzraven!.decompressAll(input, into: &output, decodedSize: decodedSize)
        case .lz4Raw:
            guard let decodedSize else { throw .invalidValue }
            try LZ4Decoder().decompressRaw(input, into: &output, decodedSize: decodedSize)
            return input.byteCount
        // The others, checked after.
        // Each decoder's one-shot call starts a new stream itself.
        case .deflate:
            consumed = try deflate!.decompressAll(input, into: &output)
        case .deflate64:
            consumed = try deflate64!.decompressAll(input, into: &output)
        case .brotli:
            consumed = try brotli!.decompressAll(input, into: &output)
        case .zstd:
            consumed = try zstd!.decompressAll(input, into: &output)
        case .lzma:
            guard case let .lzma(properties, uncompressedSize, maximumSize)? = format else { preconditionFailure("Raw LZMA's format") }
            if lzma2 == nil { lzma2 = LZMA2Decoder() }
            streamPending = true // A streaming call after this starts the stream over.
            consumed = try lzma2!.decompressAll(
                input, properties: properties, into: &output, decodedSize: uncompressedSize, maximumSize: maximumSize
            )
        case .xz:
            if lzma2 == nil { lzma2 = LZMA2Decoder() }
            streamPending = true
            consumed = try lzma2!.decompressAll(input, into: &output)
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

    /// Decodes a whole stream into a new array, as ``decompressAll(_:into:decodedSize:)`` decodes into a buffer: at most
    /// `maximumSize` bytes, and exactly `decodedSize` when the container records it.
    ///
    /// ```swift
    /// var decompressor = try Decompressor(for: .deflate(.zlib))
    /// let toc = try decompressor.decompressAll(compressed, maximumSize: 64 << 20, decodedSize: tocSize)
    /// ```
    ///
    /// The array is reserved once (`decodedSize`, or `maximumSize` without it) and decoded into in place: nothing is
    /// zeroed or copied.
    ///
    /// - Parameters:
    ///   - input: The stream, as ``decompressAll(_:into:decodedSize:)`` takes it.
    ///   - maximumSize: The most the stream may decode to: a limit the caller sets, so the input can't make it
    ///     allocate more.
    ///   - decodedSize: The size the container says the stream decodes to, if it does.
    /// - Returns: The decoded bytes.
    /// - Throws: As ``decompressAll(_:into:decodedSize:)``; ``BytesError/limitExceeded`` for a `decodedSize` above
    ///   `maximumSize`, or (without one) a stream that decodes to more than `maximumSize` bytes;
    ///   ``BytesError/invalidValue`` for a negative `maximumSize`.
    public mutating func decompressAll(_ input: RawSpan, maximumSize: Int, decodedSize: Int? = nil) throws(BytesError) -> [UInt8] {
        guard maximumSize >= 0 else { throw .invalidValue }
        if let decodedSize {
            guard decodedSize >= 0 else { throw .invalidValue }
            guard decodedSize <= maximumSize else { throw .limitExceeded }
        }
        let capacity = decodedSize ?? maximumSize
        // An empty array reserved, then appended to: the standard library's specialized `append(addingCapacity:)`
        // (`init(capacity:initializingWith:)` goes through an unspecialized allocation, ~500 instructions more).
        var bytes: [UInt8] = []
        bytes.reserveCapacity(capacity)
        try bytes.append(addingCapacity: capacity) { (span: inout OutputSpan<UInt8>) throws(BytesError) in
            // Unsafe: an output span over the array's new capacity. Safe: it covers only the uninitialized part and
            // ends with the closure; what the decoder wrote is added to the initialized count.
            try unsafe span.withUnsafeMutableBufferPointer { buffer, initializedCount throws(BytesError) in
                let free = unsafe UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(buffer)[initializedCount...])
                var output = unsafe OutputRawSpan(buffer: free, initializedCount: 0)
                do throws(BytesError) {
                    _ = try decompressAll(input, into: &output, decodedSize: decodedSize)
                } catch .insufficientCapacity where decodedSize == nil {
                    // The room is the caller's maximum: the stream decodes to more than it allows.
                    throw .limitExceeded
                }
                initializedCount &+= unsafe output.finalize(for: free)
            }
        }
        return bytes
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension Decompressor: @unchecked Sendable {}

extension Decompressor: ResettableByteTransform {
    public typealias Failure = BytesError

    /// The most unconsumed input a call may need before it can make progress, whatever the format: the largest of
    /// the formats' units (``DecompressionFormat/maximumUnitByteCount``), xz's 65,542 bytes. A client that knows its
    /// formats sizes its buffers by theirs.
    public static var maximumUnitByteCount: Int {
        // Pairwise: `max` of three or more arguments is variadic, an array per call.
        let lz = max(LZMADecoder.maximumUnitByteCount, XZDecoder.maximumUnitByteCount)
        let entropy = max(BZip2Decoder.maximumUnitByteCount, ZstdDecoder.maximumUnitByteCount)
        let huffman = max(DeflateDecoder.maximumUnitByteCount, BrotliDecoder.maximumUnitByteCount)
        return max(lz, max(entropy, huffman))
    }

    /// Starts the current format's stream again (``reset(for:)`` with the same format); before the first, does
    /// nothing.
    public mutating func reset() {
        guard let format else { return }
        // The format was accepted once, so it's accepted again.
        try? reset(for: format)
    }

    /// Decodes as the format's decoder's `transform(_:into:flush:)` does: at `.finish`, input that ends inside the
    /// stream throws ``BytesError/insufficientData``; for formats where another stream may follow (gzip members,
    /// Zstandard frames, xz and bzip2 streams), a stream's end reads as ``TransformStatus/needsInput`` until then.
    ///
    /// - Throws: As ``decompress(_:into:)``.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        if streamPending { try startStream() }
        return switch codec {
        case .deflate: try deflate!.transform(input, into: &output, flush: flush)
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
