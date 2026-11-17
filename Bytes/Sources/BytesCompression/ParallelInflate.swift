public import Bytes
public import Dispatch

/// DEFLATE (raw, zlib, or gzip) decompressed on several cores at once, where the stream allows it, and
/// sequentially where it doesn't: always the same output as ``DeflateDecoder``.
///
/// A DEFLATE stream has no index, and a block can copy from anywhere in the 32 KB before it, so in general
/// it decodes in order. But a sync flush (an empty stored block: bytes `00 00 FF FF`, as every chunk of a
/// ``ParallelDeflateEncoder`` ends with) leaves the stream between blocks on a byte boundary, and if no
/// later match reaches back across it, what follows decodes on its own. The decoder speculates, as
/// rapidgzip and pugz do, but accepts a speculation only when it's proven right:
///
/// 1. It picks up to ``laneCount`` − 1 split points, each just after a `00 00 FF FF`, spread evenly through
///    the input (a vectorized scan from each target).
/// 2. Every lane decodes its segment at once, from nothing: lane 0 from the stream's start, lane *j* from
///    split *j* to split *j* + 1, into a buffer of its own. A match reaching back past a segment's start
///    finds no data there and throws.
/// 3. Segment *j* is accepted only if segment *j* − 1 ended exactly at its start, between blocks, and
///    nothing threw. Then segment *j*'s start was a real block boundary, its blocks parse the same whatever
///    came before, and its matches stayed within it, so its bytes are the stream's. By induction from lane
///    0, which starts where the stream does, all are.
/// 4. If any check fails (no split points, a match across a split, a false `00 00 FF FF` inside a block),
///    the whole stream is decoded sequentially, the speculation's time lost.
///
/// Streams from ``ParallelDeflateEncoder`` with `independentChunks`, pigz `-i`, and zlib streams with full
/// flushes decode in parallel. Others decode sequentially. The segments' bytes are copied to the output in
/// order; gzip's CRC-32 and zlib's Adler-32 are computed per segment and combined.
///
/// Lanes keep their buffers, which grow to the largest segment seen: after the first stream of a size,
/// decoding allocates nothing.
@safe
public struct ParallelDeflateDecoder: ~Copyable {
    /// The container: raw DEFLATE, zlib, or gzip.
    public let format: DeflateFormat
    /// The most segments decoded at once.
    public var laneCount: Int { lanes.count }
    /// How the last stream was decoded: in how many segments (1 if sequentially).
    public private(set) var lastSegmentCount = 0

    private var lanes: UniqueArray<InflateLane>
    private var splits: UniqueArray<Int>
    private var sequential: DeflateDecoder

    /// The shortest segment worth a lane, in compressed bytes.
    public static var minimumSegment: Int { 16 << 10 }

    /// Creates a decoder.
    ///
    /// - Parameters:
    ///   - format: The container.
    ///   - lanes: How many segments to decode at once, at least 1.
    public init(format: DeflateFormat = .raw, lanes: Int) {
        self.format = format
        let laneCount = max(lanes, 1)
        var lanes = UniqueArray<InflateLane>(capacity: laneCount)
        for index in 0..<laneCount {
            // Lane 0 reads the container's header; the others start inside the DEFLATE data.
            lanes.append(InflateLane(format: index == 0 ? format : .raw))
        }
        self.lanes = lanes
        splits = UniqueArray(repeating: 0, count: laneCount &+ 1)
        sequential = DeflateDecoder(format: format)
    }

    // MARK: - Synchronous

    /// Decompresses one whole stream from `input` into `output`, in parallel if the stream allows it.
    /// Blocks the calling thread until done.
    ///
    /// - Returns: The bytes of `input` the stream took (bytes after it are left alone).
    /// - Throws: As ``DeflateDecoder/decompressAll(_:into:)``: ``BytesError/invalidValue`` for a corrupt
    ///   stream, ``BytesError/insufficientData`` for a truncated one, ``BytesError/insufficientCapacity``
    ///   if `output` is too small.
    public mutating func decompressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        let segments = findSplits(input)
        if segments > 1 {
            let lanes = unsafe laneBuffer()
            let splits = unsafe splitBuffer()
            let format = format
            // Unsafe: lane `j` from thread `j`. Safe: each thread touches only its own lane, and
            // `concurrentPerform` returns only when every iteration has finished.
            DispatchQueue.concurrentPerform(iterations: segments) { j in
                unsafe lanes.buffer[j].decode(input, from: splits.buffer[j], to: splits.buffer[j &+ 1], isLast: j == segments &- 1, checksum: format)
            }
            if let consumed = try unsafe Self.join(lanes, segments: segments, input: input, format: format, into: &output) {
                lastSegmentCount = segments
                return consumed
            }
        }
        lastSegmentCount = 1
        sequential.reset()
        return try sequential.decompressAll(input, into: &output)
    }

    // MARK: - Async

    /// Decompresses as ``decompressAll(_:into:)`` does, on `queue`: the calling task suspends until it's done,
    /// and its thread is free meanwhile.
    ///
    /// - Returns: The bytes of `input` the stream took.
    /// - Throws: As ``decompressAll(_:into:)``.
    public nonisolated(nonsending) mutating func decompressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, on queue: DispatchQueue
    ) async throws(BytesError) -> Int {
        // Unsafe: the decoder, the input, and the output's free capacity as pointers, for a closure on
        // another thread. Safe: all are borrowed for this whole call, which waits for the closure; only the
        // bytes it reports are counted as initialized.
        let source = input.withUnsafeBytes { unsafe UnsafeBytes(buffer: $0) }
        let target = unsafe output.withUnsafeMutableBytes { buffer, initializedCount in
            unsafe UnsafeMutableBytes(buffer: UnsafeMutableRawBufferPointer(rebasing: buffer[initializedCount...]))
        }
        // The decoder's pointer escapes its closure: `self` is an `inout` parameter, whose storage stays put
        // until this call returns, and the closure finishes before then.
        let decoder = withUnsafeMutablePointer(to: &self) { unsafe UnsafeDecoder(pointer: $0) }
        let result: Result<(consumed: Int, produced: Int), BytesError> = await unsafe withUnsafeContinuation { continuation in
            queue.async {
                let input = unsafe RawSpan(_unsafeBytes: source.buffer)
                var output = unsafe OutputRawSpan(buffer: target.buffer, initializedCount: 0)
                do throws(BytesError) {
                    let consumed = try unsafe decoder.pointer.pointee.decompressAll(input, into: &output)
                    unsafe continuation.resume(returning: .success((consumed, unsafe output.finalize(for: target.buffer))))
                } catch {
                    unsafe continuation.resume(returning: .failure(error))
                }
            }
        }
        let (consumed, produced) = try result.get()
        // Unsafe: counts the bytes the decoder wrote as initialized. Safe: it initialized exactly those, at the
        // start of the free capacity.
        unsafe output.withUnsafeMutableBytes { _, initializedCount in
            initializedCount &+= produced
        }
        return consumed
    }

    // MARK: - Engine

    /// Picks the segments' starts: 0, then up to `laneCount - 1` byte offsets just after a `00 00 FF FF`,
    /// spread evenly, then the input's end.
    ///
    /// - Returns: The number of segments.
    private mutating func findSplits(_ input: RawSpan) -> Int {
        let count = input.byteCount
        var splits = splits.mutableSpan
        splits[0] = 0
        let wanted = min(lanes.count, count / Self.minimumSegment)
        var segments = 1
        var from = Self.minimumSegment
        if wanted > 1 {
            for j in 1..<wanted {
                let target = max(from, j &* count / wanted)
                // A sync flush's empty stored block: `00 00 FF FF`.
                guard let marker = input.firstByteOffset(of: [0x00, 0x00, 0xFF, 0xFF] as Byte4, from: min(target, count)) else { break }
                let start = marker &+ 4
                guard start < count else { break }
                splits[segments] = start
                segments &+= 1
                from = start &+ Self.minimumSegment
            }
        }
        splits[segments] = count
        return segments
    }

    /// Checks the lanes' segments and, if every one is proven, copies them to `output` in order and checks
    /// the container's trailer.
    ///
    /// - Returns: The input consumed, or `nil` if a segment isn't proven (decode sequentially instead).
    /// - Throws: ``BytesError/insufficientCapacity`` if `output` is too small, ``BytesError/invalidValue`` for
    ///   a trailer that doesn't match, ``BytesError/insufficientData`` for a missing one.
    static func join(
        _ lanes: UnsafeLanes<InflateLane>, segments: Int, input: RawSpan, format: DeflateFormat, into output: inout OutputRawSpan
    ) throws(BytesError) -> Int? {
        var total = 0
        for j in 0..<segments {
            // Unsafe: reads the lanes. Safe: the round is over.
            let outcome = unsafe lanes.buffer[j].outcome
            if j < segments &- 1 {
                guard outcome == .boundary else { return nil }
            } else {
                guard case .finished = outcome else { return nil }
            }
            total &+= unsafe lanes.buffer[j].produced
        }
        guard output.freeCapacity >= total else { throw .insufficientCapacity }
        var checksum: UInt32 = format == .zlib ? 1 : 0
        for j in 0..<segments {
            let laneChecksum = unsafe lanes.buffer[j].checksum
            let length = unsafe lanes.buffer[j].produced
            switch format {
            case .raw: break
            case .zlib: checksum = Adler32.combine(checksum, laneChecksum, secondLength: length)
            case .gzip: checksum = CRC32.combine(checksum, laneChecksum, secondLength: length)
            }
        }
        guard case let .finished(end) = unsafe lanes.buffer[segments &- 1].outcome else { return nil }
        // The last segment was decoded as raw DEFLATE: the trailer follows its final block.
        var reader = try AlignedBytesReader(input, atByteOffset: end)
        switch format {
        case .raw:
            break
        case .zlib:
            guard try reader.read(Byte4.self, .bigEndian) == checksum else { throw .invalidValue }
        case .gzip:
            guard try reader.read(Byte4.self, .littleEndian) == checksum,
                  try reader.read(Byte4.self, .littleEndian) == UInt32(truncatingIfNeeded: total) else { throw .invalidValue }
        }
        for j in 0..<segments {
            // Unsafe: reads the lanes. Safe: the round is over. (Copying the segments in parallel instead
            // measured no faster: a round waits for its slowest segment, not the copies.)
            try unsafe lanes.buffer[j].deliver(into: &output)
        }
        return reader.byteOffset
    }

    private mutating func laneBuffer() -> UnsafeLanes<InflateLane> {
        var span = lanes.mutableSpan
        // Unsafe: the lanes' storage as a pointer that outlives the closure. Safe: `lanes` never changes size
        // after initialization, and callers use the pointer only within the method that took it.
        return span.withUnsafeMutableBufferPointer { unsafe UnsafeLanes(buffer: $0) }
    }

    private mutating func splitBuffer() -> UnsafeSplits {
        var span = splits.mutableSpan
        // Unsafe and safe as `laneBuffer()`.
        return span.withUnsafeMutableBufferPointer { unsafe UnsafeSplits(buffer: UnsafeBufferPointer($0)) }
    }
}

/// How a lane's segment ended.
enum SegmentOutcome: Equatable {
    /// Exactly at its end, between blocks: proven if the segment's start was.
    case boundary
    /// With the stream's final block, at this byte offset (the trailer's start, for a raw lane).
    case finished(Int)
    /// Otherwise: a match reaching before the segment, an invalid block, or the wrong end.
    case failed
}

/// One lane of a parallel decoder: its own decoder state and output buffer.
///
/// `@usableFromInline`: clients inline the decoder's destructor, which references this type's metadata (see
/// `BrotliCommand`).
@usableFromInline
struct InflateLane: ~Copyable {
    var stream: InflateStream
    var buffer: UniqueArray<UInt8>
    var produced = 0
    var outcome = SegmentOutcome.failed
    var checksum: UInt32 = 0

    init(format: DeflateFormat) {
        stream = InflateStream(format: format)
        buffer = UniqueArray(repeating: 0, count: 256 << 10)
    }

    /// Decodes `input[start..<end]` from nothing (the last segment: to the stream's end), growing the
    /// buffer as needed, then checksums what it decoded in the container's way.
    mutating func decode(_ input: RawSpan, from start: Int, to end: Int, isLast: Bool, checksum format: DeflateFormat) {
        stream.reset()
        produced = 0
        let source = isLast ? input : input.extracting(0..<end)
        var position = start &<< 3
        outcome = .failed
        while true {
            let result: (position: Int, end: Int, stop: InflateStream.Stop)
            do throws(BytesError) {
                var span = buffer.mutableSpan
                var raw = MutableRawSpan(mutating: &span)
                result = try stream.run(source, from: position, into: &raw, at: produced)
            } catch {
                return
            }
            position = result.position
            produced = result.end
            switch result.stop {
            case .outputFull:
                grow()
                continue
            case .needsInput:
                if !isLast && position == end &<< 3 && stream.isBetweenBlocks { outcome = .boundary }
            case .finished:
                if isLast { outcome = .finished((position &+ 7) &>> 3) }
            }
            break
        }
        let bytes = buffer.span.bytes.extracting(0..<produced)
        switch format {
        case .raw: checksum = 0
        case .zlib: checksum = Adler32.checksum(bytes)
        case .gzip: checksum = CRC32.checksum(bytes)
        }
    }

    /// Doubles the buffer, keeping what's decoded.
    private mutating func grow() {
        var bigger = UniqueArray<UInt8>(repeating: 0, count: buffer.count &* 2)
        var target = bigger.mutableSpan
        target.copyBytes(from: buffer.span.bytes.extracting(0..<produced), toByteOffset: 0)
        buffer = bigger
    }

    /// Copies the segment's bytes to the end of `output`.
    func deliver(into output: inout OutputRawSpan) throws(BytesError) {
        try ParallelDeflateEncoder.append(buffer.span.bytes.extracting(0..<produced), to: &output)
    }
}

/// The split points, for the threads of a round. Unsafe: a pointer, valid while its owner keeps them.
@unsafe
struct UnsafeSplits: @unchecked Sendable {
    let buffer: UnsafeBufferPointer<Int>
}

/// A decoder, for a closure on another thread. Unsafe: a pointer, valid while its owner keeps the decoder
/// borrowed.
@unsafe
struct UnsafeDecoder: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<ParallelDeflateDecoder>
}
