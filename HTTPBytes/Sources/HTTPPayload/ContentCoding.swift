public import Bytes
public import BytesCompression
public import HTTP1
public import HTTPBytes

/// A content coding (RFC 9110 §8.4.1): how a representation's bytes are compressed.
@frozen
public enum HTTPContentCoding: Sendable, Hashable {
    /// No coding.
    case identity
    /// `gzip` (and `x-gzip`): DEFLATE in gzip's container.
    case gzip
    /// `deflate`: DEFLATE in zlib's container (RFC 9110 §8.4.1.2). Raw DEFLATE, which some servers send under this
    /// name, is accepted when decoding.
    case deflate
    /// `br`: Brotli (RFC 7932).
    case brotli
    /// `zstd`: Zstandard (RFC 8878), with RFC 9659's window limit of 8 MB.
    case zstd

    /// The coding named `token` (any case), or `nil` for codings this module doesn't decode (`compress`, `dcb`, …).
    @inlinable
    public init?(token: RawSpan) {
        if HTTPToken.equalsIgnoringCase(token, "gzip") || HTTPToken.equalsIgnoringCase(token, "x-gzip") { self = .gzip }
        else if HTTPToken.equalsIgnoringCase(token, "br") { self = .brotli }
        else if HTTPToken.equalsIgnoringCase(token, "zstd") { self = .zstd }
        else if HTTPToken.equalsIgnoringCase(token, "deflate") { self = .deflate }
        else if HTTPToken.equalsIgnoringCase(token, "identity") { self = .identity }
        else { return nil }
    }

    /// The coding's name, as `Content-Encoding` spells it.
    public var token: StaticString {
        switch self {
        case .identity: "identity"
        case .gzip: "gzip"
        case .deflate: "deflate"
        case .brotli: "br"
        case .zstd: "zstd"
        }
    }

    /// RFC 9659 §3: a zstd content coding's window is at most 8 MB, so a decoder may refuse larger ones.
    @inlinable static var zstdWindowLimit: Int { 8 << 20 }

    /// The format the coding's streams decode as, where the coding alone decides it: the one mapping from content
    /// codings to BytesCompression's `DecompressionFormat`. gzip is DEFLATE in gzip's container, br Brotli, zstd
    /// Zstandard with RFC 9659's 8 MB window. `nil` for identity (nothing to decode), and for deflate, which is zlib or
    /// raw DEFLATE by its first two bytes (`DeflateFormat(zlibOrRaw:)`, once they've arrived). Whether a stream's end
    /// can be followed by another (gzip members, zstd frames) is the format's (`allowsConcatenation`).
    @inlinable var decompressionFormat: DecompressionFormat? {
        switch self {
        case .gzip: .deflate(.gzip)
        case .brotli: .brotli
        case .zstd: .zstd(maximumWindowSize: Self.zstdWindowLimit)
        case .deflate, .identity: nil
        }
    }
}

/// Why a body couldn't be decoded or encoded.
@frozen
public enum HTTPPayloadError: Error, Sendable, Hashable {
    /// `Content-Encoding` names a coding this module doesn't decode (a server answers 415).
    case unsupportedCoding
    /// More than two codings applied in turn.
    case tooManyCodings
    /// The coded bytes are malformed, or end before the stream does.
    case malformed
    /// The decoded body would pass the decoder's limit: a decompression bomb, or a body larger than allowed.
    case tooLarge
    /// The output had no room.
    case outOfRoom
    /// The body's chunked transfer coding is malformed (``HTTPBodyDecoder``).
    case chunked(HTTP1Error)
    /// The connection closed before the body's framing ended (``HTTPBodyDecoder``).
    case incompleteBody
}

/// One decoding stage: a coding's decoder.
@usableFromInline
struct ContentDecodingStage: ~Copyable {
    @usableFromInline var coding: HTTPContentCoding
    @usableFromInline var decompressor = Decompressor()
    /// For `deflate`: whether the stream's container has been decided (zlib, or raw DEFLATE).
    @usableFromInline var decided = false
    /// At the end of a stream: for gzip and zstd, the end of a member or frame (more may follow: RFC 1952 §2.2, RFC
    /// 8878 §3); for the others, the end of the stream.
    @usableFromInline var finished = false

    /// Whether the coding's streams may be concatenated (gzip members, zstd frames): data after an end is the next one.
    /// The format's to say (deflate's zlib and raw streams don't, so its undecided `nil` reads right).
    @inlinable var continuesAfterEnd: Bool { coding.decompressionFormat?.allowsConcatenation ?? false }

    /// At an end after which no more data may come: the body's data must end here.
    @inlinable var isClosed: Bool { finished && !continuesAfterEnd }

    @inlinable
    init(_ coding: HTTPContentCoding) throws(HTTPPayloadError) {
        self.coding = coding
        try reset(coding)
    }

    /// Prepares for a new stream coded with `coding`, keeping the codecs' state made for earlier streams (one decoder
    /// per format: gzip's and deflate's streams share `Decompressor`'s DEFLATE decoder).
    @inlinable
    mutating func reset(_ coding: HTTPContentCoding) throws(HTTPPayloadError) {
        self.coding = coding
        decided = false
        finished = false
        guard let format = coding.decompressionFormat else { return }
        do throws(BytesError) {
            try decompressor.reset(for: format)
        } catch {
            throw .unsupportedCoding
        }
    }

    @inlinable
    mutating func decode(_ input: RawSpan, into output: inout OutputRawSpan) throws(HTTPPayloadError) -> TransformProgress {
        if finished {
            // More data after a member or frame begins the next one; after any other stream's end, nothing does.
            if input.byteCount == 0 || !continuesAfterEnd { return TransformProgress(consumed: 0, produced: 0, status: .finished) }
            finished = false
        }
        do throws(BytesError) {
            let progress: TransformProgress
            switch coding {
            case .identity:
                let take = Swift.min(input.byteCount, output.freeCapacity)
                output.append(copying: input.extracting(0..<take))
                return TransformProgress(consumed: take, produced: take, status: take < input.byteCount ? .needsOutput : .needsInput)
            case .deflate where !decided:
                // zlib or raw DEFLATE (which browsers accept under this name), by the first two bytes.
                guard let container = DeflateFormat(zlibOrRaw: input) else { return TransformProgress(consumed: 0, produced: 0, status: .needsInput) }
                try decompressor.reset(for: .deflate(container))
                decided = true
                progress = try decompressor.decompress(input, into: &output)
            default:
                progress = try decompressor.decompress(input, into: &output)
            }
            if progress.status == .finished { finished = true }
            return progress
        } catch {
            switch error {
            // A decoder's own limit (zstd's window above RFC 9659's 8 MB): not `outOfRoom`, which would send a caller
            // that drains the output round forever.
            case .limitExceeded: throw .tooLarge
            case .insufficientCapacity: throw .outOfRoom
            default: throw .malformed
            }
        }
    }
}

/// A body's content codings undone, as the bytes arrive (RFC 9110 §8.4): `Content-Encoding` lists the codings in the
/// order they were applied, so they're decoded in reverse. One coding decodes straight from the input into the output;
/// two (rare: `Content-Encoding: gzip, br`) decode through a 64 KiB buffer made once.
///
/// ```swift
/// var decoder = try HTTPContentDecoder(contentEncoding: fields.firstValue(of: .contentEncoding)!)
/// let progress = try decoder.decode(chunkData, into: &output)   // from HTTP1ChunkedDecoder's .data slices, say
/// … then, when the body has ended: try decoder.finish()
/// ```
///
/// Decoders are those of BytesCompression (no zlib or Compression framework): DEFLATE, Brotli, Zstandard. A limit on the
/// decoded size guards against decompression bombs (a few KB that decode to gigabytes).
///
/// Input may arrive in any pieces, each passed once: a body's pieces aren't contiguous (chunked data between size
/// lines), so bytes a codec can't use yet (a symbol cut by a piece's end) are kept in a carry buffer, made the first
/// time it's needed, and continued from with the next piece. `consumed` is less than a piece only when the output is
/// full; pass the rest of that piece again after draining the output.
public struct HTTPContentDecoder: ~Copyable {
    /// The most decoded bytes allowed: ``HTTPPayloadError/tooLarge`` past it.
    public let maximumDecodedByteCount: Int
    /// Decoded bytes so far.
    public private(set) var decodedByteCount = 0
    @usableFromInline var last: ContentDecodingStage
    @usableFromInline var first: ContentDecodingStage?
    /// For two codings: the outer coding's output, waiting for the inner coding's decoder (64 KiB, made once).
    @usableFromInline var middle: RawStorage?
    @usableFromInline var middleStart = 0
    @usableFromInline var middleCount = 0
    /// Input a codec left unconsumed at the end of a piece, kept for the next piece (made the first time it's needed).
    @usableFromInline var carry: RawStorage?
    @usableFromInline var carryCount = 0
    /// The carry buffer's size: twice the most unconsumed input any codec here needs before it can make progress
    /// (`DecompressionFormat.maximumUnitByteCount`), so a unit it holds back and the bytes that complete it fit. That's
    /// Brotli's 451 bytes (a command tree's prefix code: a meta-block's header is read a code at a time); DEFLATE's is 289
    /// (a dynamic block's header), and Zstandard keeps partial units itself. 902 bytes.
    @inlinable static var carryCapacity: Int {
        // The formats HTTP's codings decode as (gzip and deflate are DEFLATE's containers).
        let deflate = DecompressionFormat.deflate(.raw).maximumUnitByteCount ?? 0
        let brotli = DecompressionFormat.brotli.maximumUnitByteCount ?? 0
        let zstd = DecompressionFormat.zstd().maximumUnitByteCount ?? 0
        return 2 &* Swift.max(brotli, Swift.max(deflate, zstd))
    }

    @inlinable static var middleCapacity: Int { 64 << 10 }

    /// A decoder for `contentEncoding`, a `Content-Encoding` field value (a comma-separated list of codings).
    ///
    /// - Throws: ``HTTPPayloadError/unsupportedCoding`` for a coding this module doesn't decode,
    ///   ``HTTPPayloadError/tooManyCodings`` for more than two (not counting `identity`).
    public init(contentEncoding: RawSpan, maximumDecodedByteCount: Int = 1 << 30) throws(HTTPPayloadError) {
        let (coding, then) = try Self.codings(contentEncoding)
        try self.init(applied: coding, then: then, maximumDecodedByteCount: maximumDecodedByteCount)
    }

    /// The codings a `Content-Encoding` value lists, in the order applied (`identity` left out).
    @usableFromInline
    static func codings(_ contentEncoding: RawSpan) throws(HTTPPayloadError) -> (HTTPContentCoding, HTTPContentCoding?) {
        var codings: InlineArray<2, HTTPContentCoding> = .init(repeating: .identity)
        var count = 0
        var unsupported = false, tooMany = false
        HTTPList.forEachElement(of: contentEncoding) { token in
            guard let coding = HTTPContentCoding(token: token) else { unsupported = true; return }
            guard coding != .identity else { return }
            guard count < 2 else { tooMany = true; return }
            codings[count] = coding
            count &+= 1
        }
        if unsupported { throw .unsupportedCoding }
        if tooMany { throw .tooManyCodings }
        return (count == 0 ? .identity : codings[0], count == 2 ? codings[1] : nil)
    }

    /// Prepares to decode another body (the next message on a connection), coded as `contentEncoding` says, keeping the
    /// codecs and buffers made for earlier bodies: after the first body of each coding, decoding allocates nothing.
    ///
    /// - Throws: As ``init(contentEncoding:maximumDecodedByteCount:)``; the decoder is then unusable until a reset
    ///   succeeds.
    public mutating func reset(contentEncoding: RawSpan) throws(HTTPPayloadError) {
        let (coding, then) = try Self.codings(contentEncoding)
        try reset(applied: coding, then: then)
    }

    /// Prepares to decode another body coded with `coding`, then (if not `nil`) with `then`, keeping the codecs and
    /// buffers made for earlier bodies.
    public mutating func reset(applied coding: HTTPContentCoding, then: HTTPContentCoding? = nil) throws(HTTPPayloadError) {
        decodedByteCount = 0
        carryCount = 0
        middleStart = 0
        middleCount = 0
        if let then {
            try last.reset(coding)
            if first == nil { first = try ContentDecodingStage(then) } else { try first!.reset(then) }
            if middle == nil { middle = RawStorage(byteCount: Self.middleCapacity, alignment: RawStorage.small) }
        } else {
            first = nil
            try last.reset(coding)
        }
    }

    /// A decoder for a body coded with `coding`, then (if not `nil`) with `then`.
    public init(applied coding: HTTPContentCoding, then: HTTPContentCoding? = nil, maximumDecodedByteCount: Int = 1 << 30) throws(HTTPPayloadError) {
        self.maximumDecodedByteCount = maximumDecodedByteCount
        // Decoding runs in reverse: the coding applied last is undone first.
        if let then {
            first = try ContentDecodingStage(then)
            last = try ContentDecodingStage(coding)
            middle = RawStorage(byteCount: Self.middleCapacity, alignment: RawStorage.small)
        } else {
            first = nil
            last = try ContentDecodingStage(coding)
        }
    }

    /// Whether the coded stream is at an end: the body may end here (for gzip and zstd, the end of a member or frame,
    /// which more may follow).
    public var isFinished: Bool { last.finished }

    /// Whether the coded stream has ended for good: no more body data may follow (after a gzip member or a zstd frame,
    /// the next one may).
    @inlinable var isClosed: Bool { last.isClosed }

    /// Decodes as much of `input` as it can into `output`.
    ///
    /// - Returns: The input consumed (pass the rest again with more) and the output produced; `.finished` once the
    ///   coded stream has ended.
    public mutating func decode(_ input: RawSpan, into output: inout OutputRawSpan) throws(HTTPPayloadError) -> TransformProgress {
        let before = output.byteCount
        let progress = carryCount == 0 ? try decodeDirect(input, into: &output) : try decodeCarried(input, into: &output)
        decodedByteCount &+= output.byteCount &- before
        guard decodedByteCount <= maximumDecodedByteCount else { throw .tooLarge }
        return progress
    }

    /// Decodes straight from `input`. When the codecs stop short of its end wanting more input (a symbol or a unit cut by
    /// the piece's end: they ask for the rest again with what follows), the rest is kept in the carry buffer and reported
    /// consumed: a body's pieces aren't contiguous (chunk data between size lines), so a caller can't pass it again with
    /// more. The common case, a piece decoded to its end, copies nothing.
    @usableFromInline
    mutating func decodeDirect(_ input: RawSpan, into output: inout OutputRawSpan) throws(HTTPPayloadError) -> TransformProgress {
        var progress = first == nil ? try last.decode(input, into: &output) : try decodeStacked(input, into: &output)
        if progress.status == .needsInput, progress.consumed < input.byteCount {
            try stash(input.extracting(droppingFirst: progress.consumed))
            progress.consumed = input.byteCount
        }
        return progress
    }

    /// Decodes from the carried bytes, topped up from `input` (as much as fits). Reports the bytes of `input` it took.
    @usableFromInline
    mutating func decodeCarried(_ input: RawSpan, into output: inout OutputRawSpan) throws(HTTPPayloadError) -> TransformProgress {
        let storage = carry!
        let take = Swift.min(input.byteCount, Self.carryCapacity &- carryCount)
        // Unsafe: copies into and reads from the carry buffer. Safe: `storage` owns `carryCapacity` bytes, held by a local
        // reference through this call; `carryCount + take` is at most that; the span over them ends with this function.
        if take > 0 {
            input.extracting(0..<take).withUnsafeBytes { bytes in
                unsafe storage.pointer(carryCount).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        carryCount &+= take
        let carried = unsafe RawSpan(_unsafeStart: storage.base, byteCount: carryCount)
        let progress = first == nil ? try last.decode(carried, into: &output) : try decodeStacked(carried, into: &output)
        let left = carryCount &- progress.consumed
        if left > 0, progress.consumed > 0 {
            // Unsafe: moves the unconsumed bytes to the buffer's front (overlapping, memmove semantics). Safe: within it.
            unsafe storage.base.copyMemory(from: storage.pointer(progress.consumed), byteCount: left)
        }
        carryCount = left
        if carryCount == Self.carryCapacity, progress.consumed == 0, progress.produced == 0, progress.status == .needsInput {
            // The codec wants more than the carry buffer holds without having used any of it: not a stream it can decode.
            throw .malformed
        }
        return TransformProgress(consumed: take, produced: progress.produced,
                                 status: progress.status == .finished || carryCount == 0 ? progress.status : progress.status == .needsOutput ? .needsOutput : .needsInput)
    }

    @usableFromInline
    mutating func stash(_ rest: RawSpan) throws(HTTPPayloadError) {
        guard rest.byteCount <= Self.carryCapacity else { throw .malformed }
        if carry == nil { carry = RawStorage(byteCount: Self.carryCapacity, alignment: RawStorage.small) }
        let storage = carry!
        // Unsafe: copies into the carry buffer. Safe: `rest` fits (checked), and the buffer outlives the copy.
        rest.withUnsafeBytes { bytes in unsafe storage.base.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
        carryCount = rest.byteCount
    }

    mutating func decodeStacked(_ input: RawSpan, into output: inout OutputRawSpan) throws(HTTPPayloadError) -> TransformProgress {
        var consumed = 0
        let produced0 = output.byteCount
        let storage = middle!
        // Unsafe: the middle buffer's memory as raw buffers. Safe: `storage` owns `middleCapacity` bytes and outlives
        // this call (a local reference holds it); the output span and the views below stay within those bytes and end
        // with this function.
        let region = unsafe UnsafeMutableRawBufferPointer(start: storage.base, count: Self.middleCapacity)
        var stalled = false
        while true {
            // Refill the middle buffer from the input when the inner decoder has used it up, or has stalled on a partial
            // unit at its end: what's left moves to the front, and more is appended after it.
            if middleStart == middleCount || stalled, consumed < input.byteCount, !(first?.finished ?? true) {
                let leftover = middleCount &- middleStart
                if middleStart > 0, leftover > 0 {
                    // Unsafe: an overlapping move within the buffer (memmove semantics). Safe: both ranges are inside it.
                    unsafe region.baseAddress!.copyMemory(from: region.baseAddress! + middleStart, byteCount: leftover)
                }
                middleStart = 0
                middleCount = leftover
                guard middleCount < Self.middleCapacity else { throw .malformed }
                let free = unsafe UnsafeMutableRawBufferPointer(rebasing: region[middleCount...])
                var buffer = unsafe OutputRawSpan(buffer: free, initializedCount: 0)
                let stageProgress = try first!.decode(input.extracting(droppingFirst: consumed), into: &buffer)
                middleCount &+= unsafe buffer.finalize(for: free)
                consumed &+= stageProgress.consumed
                if stalled, stageProgress.consumed == 0, stageProgress.produced == 0 {
                    // Neither stage can go on with what it has: more input is needed.
                    return TransformProgress(consumed: consumed, produced: output.byteCount &- produced0, status: .needsInput)
                }
            }
            let pending = unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: region[middleStart..<middleCount]))
            let innerProgress = try last.decode(pending, into: &output)
            middleStart &+= innerProgress.consumed
            if innerProgress.status == .finished || innerProgress.status == .needsOutput || output.freeCapacity == 0 {
                return TransformProgress(consumed: consumed, produced: output.byteCount &- produced0, status: innerProgress.status)
            }
            stalled = innerProgress.consumed == 0 && innerProgress.produced == 0
            let inputDone = consumed == input.byteCount || (first?.finished ?? true)
            if inputDone, middleStart == middleCount || stalled {
                return TransformProgress(consumed: consumed, produced: output.byteCount &- produced0, status: .needsInput)
            }
        }
    }

    /// Checks that the coded stream ended (call when the body has): throws ``HTTPPayloadError/malformed`` if it was
    /// cut short. Identity bodies end anywhere.
    public func finish() throws(HTTPPayloadError) {
        // Every stage: with two codings, the outer stream can be cut short after the inner one happened to end.
        guard last.coding == .identity || last.finished else { throw .malformed }
        // A `~Copyable` optional: borrowed with `switch` (`if let` would consume it).
        switch first {
        case let .some(stage): if stage.coding != .identity, !stage.finished { throw .malformed }
        case .none: break
        }
    }
}

/// A body coded with one content coding, as it's produced: BytesCompression's `Compressor` (its DEFLATE (gzip, zlib),
/// Brotli, and Zstandard encoders), the coding mapped to its `CompressionFormat`.
public struct HTTPContentEncoder: ~Copyable {
    /// The coding.
    public let coding: HTTPContentCoding
    @usableFromInline var compressor = Compressor()

    /// An encoder for `coding` at `level` (DEFLATE 1–9, or 0 for stored blocks; Brotli quality 0–11, 0 running as 1;
    /// Zstandard libzstd's levels 1–4, or 0 for its default, 3, with a 512 KiB window: RFC 9659 limits a `zstd` content
    /// coding's window to 8 MB, and a smaller one keeps memory per response down, at 0–4% in size).
    ///
    /// - Throws: ``HTTPPayloadError/unsupportedCoding`` for a negative level (higher levels than a coding has run as its
    ///   highest: DEFLATE's above 9 as 9, Brotli's 10 and 11 as 9, Zstandard's above 4 as 4).
    public init(_ coding: HTTPContentCoding, level: Int? = nil) throws(HTTPPayloadError) {
        self.coding = coding
        do throws(BytesError) {
            switch coding {
            case .gzip: try compressor.reset(for: .deflate(.gzip, level: level ?? 6))
            case .deflate: try compressor.reset(for: .deflate(.zlib, level: level ?? 6))
            case .brotli: try compressor.reset(for: .brotli(quality: level ?? 5))
            case .identity: break
            case .zstd: try compressor.reset(for: .zstd(level: level ?? 3, windowLog: ZstdEncoder.Parameters.httpWindowLog))
            }
        } catch {
            throw .unsupportedCoding
        }
    }

    /// Starts another body with the same coding and level, keeping the encoder's memory.
    public mutating func reset() {
        compressor.reset()
    }

    /// Encodes as much of `input` as fits into `output`; `flush` `.finish` ends the stream (`.flush` makes everything so
    /// far decodable, for streaming responses).
    public mutating func encode(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(HTTPPayloadError) -> TransformProgress {
        do {
            switch coding {
            case .gzip, .deflate, .brotli, .zstd: return try compressor.compress(input, into: &output, flush: flush)
            default:
                let take = Swift.min(input.byteCount, output.freeCapacity)
                output.append(copying: input.extracting(0..<take))
                return TransformProgress(consumed: take, produced: take,
                                         status: take < input.byteCount ? .needsOutput : flush == .finish ? .finished : .needsInput)
            }
        } catch {
            throw .outOfRoom
        }
    }
}
