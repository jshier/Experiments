public import Bytes
internal import Dispatch
internal import Synchronization

/// DEFLATE (raw, zlib, or gzip) decompressed on several cores at once, where the stream allows it, and
/// sequentially where it doesn't: always the same output as ``DeflateDecoder``.
///
/// A DEFLATE stream has no index, and a block can copy from anywhere in the 32 KB before it, so in general
/// it decodes in order. But a sync flush (an empty stored block: bytes `00 00 FF FF`, as every chunk of a
/// ``ParallelDeflateEncoder`` ends with) leaves the stream between blocks on a byte boundary, and if no
/// later match reaches back across it, what follows decodes on its own. The decoder speculates, as
/// rapidgzip and pugz do, but accepts a speculation only when it's proven right:
///
/// 1. The input is cut into windows, up to ``segmentsPerLane`` per lane, so a lane that runs slow (a busy or
///    efficiency core) holds up one small segment, not a whole share of the stream. Each window's split point
///    is just after the first `00 00 FF FF` in it that a block header could follow (a vectorized scan; most
///    `00 00 FF FF`s inside blocks are followed by bits no header starts with).
/// 2. The lanes take the segments in order, each the next not yet taken, find its split points (each
///    depends only on its window), and decode it from nothing: segment 0 from the stream's first block,
///    segment *j* from split *j* to the next, into a buffer of its own (a window without a split point has
///    no segment). A match reaching back past a segment's start finds no data there and throws. A segment that
///    reaches its end inside a block (the next split was a false `00 00 FF FF`: Huffman-coded bits, or a
///    stored block's data) decodes on to the following split, and so on, until it ends between blocks at
///    one or the stream ends.
/// 3. The segments are joined in order from segment 0, which starts where the stream does. A segment whose
///    start is proven (the previous one ended exactly there, between blocks) and that ended between blocks
///    at a later split, or with the stream's final block, without throwing, is accepted: its start was a
///    real block boundary, its blocks parse the same whatever came before, and its matches stayed within
///    it, so its bytes are the stream's. Its end is then proven, by induction. The lanes copy each accepted
///    segment to the output as soon as every one before it is, while the others are still decoding.
/// 4. A segment that failed (a match across its start, corrupt data) is decoded again sequentially, into
///    the output after what's joined so far, so matches reach the stream's real history, until that
///    decode is between blocks at a later split; the join goes on from there. A bad split costs its own
///    region, not the stream. Only if segment 0 fails (or no split points are found) is the whole stream
///    decoded sequentially.
///
/// Streams from ``ParallelDeflateEncoder`` with `independentChunks`, pigz `-i`, and zlib streams with full
/// flushes decode in parallel. Others (matches across every split) decode their first segment in parallel
/// and the rest sequentially. The segments' bytes are copied to the output in order; gzip's CRC-32 and
/// zlib's Adler-32 are computed per segment and combined.
///
/// Segments keep their buffers, each sized to the largest output it has held (about the stream's output in
/// all, however many segments): after the first stream of a size, decoding allocates nothing.
@safe
public struct ParallelDeflateDecoder: ~Copyable {
    /// The container: raw DEFLATE, zlib, or gzip.
    public let format: DeflateFormat
    /// The most segments decoded at once.
    public var laneCount: Int { lanes.count &- 1 }
    /// How the last stream was decoded: how many segments decoded in parallel were accepted (1 if
    /// sequentially).
    public private(set) var lastSegmentCount = 0
    /// How many segments the last stream was split into (1 if none), for tests: more than
    /// ``lastSegmentCount`` when a split wasn't a block boundary or a segment's region was decoded again.
    package private(set) var lastSplitCount = 0
    /// How many times the last stream's join decoded a failed segment's region again, sequentially.
    package private(set) var lastRepairCount = 0

    /// Each lane's decoder state, raw DEFLATE; then one that reads the container's header (segment 0 starts
    /// after it).
    private var lanes: UniqueArray<InflateLane>
    private var segments: UniqueArray<InflateSegment>
    private var sequential: DeflateDecoder

    /// The smallest window a stream is cut into for its segments, in compressed bytes.
    public static var minimumSegment: Int { 16 << 10 }

    /// The most segments per lane: enough that the lanes finish close together, few enough that each
    /// segment's fixed costs (a reset, a checksum to combine, a copy to start) stay small.
    static var segmentsPerLane: Int { 4 }

    /// Creates a decoder.
    ///
    /// - Parameters:
    ///   - format: The container.
    ///   - lanes: How many segments to decode at once, at least 1: usually every core (with several segments a
    ///     lane, efficiency cores add their share).
    public init(format: DeflateFormat = .raw, lanes: Int) {
        self.format = format
        let laneCount = max(lanes, 1)
        var lanes = UniqueArray<InflateLane>(capacity: laneCount &+ 1)
        for index in 0...laneCount {
            // The last reads the container's header; the others start inside the DEFLATE data.
            lanes.append(InflateLane(format: index == laneCount ? format : .raw))
        }
        self.lanes = lanes
        let segmentCount = laneCount &* Self.segmentsPerLane
        var segments = UniqueArray<InflateSegment>(capacity: segmentCount)
        for _ in 0..<segmentCount {
            segments.append(InflateSegment())
        }
        self.segments = segments
        sequential = DeflateDecoder(format: format)
    }

    // MARK: - Synchronous

    /// Decompresses one whole stream from `input` into `output`, in parallel if the stream allows it.
    /// Blocks the calling thread until done.
    ///
    /// - Returns: The bytes of `input` the stream took (bytes after it are left alone).
    /// - Throws: As ``DeflateDecoder/decompressAll(_:into:)``: ``BytesError/invalidValue`` for a corrupt
    ///   stream, ``BytesError/insufficientData`` for a truncated one, ``BytesError/insufficientCapacity``
    ///   if `output` is too small, ``BytesError/mismatch`` for a wrong checksum or length.
    public mutating func decompressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        try decompressAll(input, into: &output, stop: nil)
    }

    /// Decompresses as ``decompressAll(_:into:)`` does, stopping early when `stop` is set (from any thread: an
    /// async call's cancellation handler). The lanes check it as they take each segment, and the call checks it
    /// once they're done, before the join; a sequential decode, once started, runs to the end.
    ///
    /// - Throws: ``BytesError/cancelled`` if `stop` was set before the segments were joined (nothing appended to
    ///   `output`, though the lanes may have copied segments into its free capacity); otherwise as
    ///   ``decompressAll(_:into:)``.
    package mutating func decompressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, stop: StopFlag?
    ) throws(BytesError) -> Int {
        let segmentCount = min(segments.count, input.byteCount / Self.minimumSegment)
        // Parallel if there's a split point past the first target (if not, the scan from there found none, and
        // the stream is decoded sequentially, straight into `output`). The container's header is read here:
        // every segment then decodes raw DEFLATE, segment 0 from the first block. (A header that's bad, cut
        // short, or reaching the first target: decoded sequentially, which throws the right error.)
        if segmentCount > 1, let blocks = try? lanes[laneCount].stream.readHeader(input),
           case let points = SplitPoints(first: blocks, count: segmentCount, end: input.byteCount),
           blocks < points.target(1), SplitPoints.firstBlockStart(input, in: points.target(1)..<input.byteCount) != nil {
            var joined: (consumed: Int, accepted: Int, repairs: Int)?
            // Unsafe: the output's free capacity lent to the workers, which copy accepted segments into it as they
            // finish. Safe: `concurrentPerform` returns before this closure does, and only the bytes the join
            // reports are counted (none if it throws, or for a sequential decode after it).
            _ = try unsafe output.withLentFreeCapacity { target throws(BytesError) -> Int in
                let delivery = unsafe decodeSegments(input, points: points, into: target, stop: stop)
                if stop?.isStopped == true { throw .cancelled }
                var span = unsafe MutableRawSpan(_unsafeBytes: target.buffer)
                guard let result = try join(input, points: points, delivered: delivery, into: &span) else { return 0 }
                joined = (result.consumed, result.accepted, result.repairs)
                return result.produced
            }
            lastSplitCount = 0
            for j in 0..<segmentCount where segments[j].exists {
                lastSplitCount &+= 1
            }
            if let (consumed, accepted, repairs) = joined {
                lastSegmentCount = accepted
                lastRepairCount = repairs
                return consumed
            }
        } else {
            lastSplitCount = 1
        }
        if stop?.isStopped == true { throw .cancelled }
        lastSegmentCount = 1
        lastRepairCount = 0
        sequential.reset()
        return try sequential.decompressAll(input, into: &output)
    }

    // MARK: - Engine

    /// Decodes the segments on the lanes, each worker taking the next segment not yet taken, and copies each
    /// accepted segment to `target` as soon as every segment before it is (``InflateDelivery``): by whichever
    /// worker finishes the segment that makes it ready, while the others go on decoding.
    ///
    /// - Returns: What was delivered: the segments up to the first that failed or wasn't decoded in time (the
    ///   join goes on from there).
    private mutating func decodeSegments(_ input: RawSpan, points: SplitPoints, into target: LentMutableBytes, stop: StopFlag?) -> InflateDelivery {
        let segmentCount = points.count
        let lanes = unsafe laneBuffer()
        let segments = unsafe segmentBuffer()
        for j in 0..<segmentCount {
            // Unsafe: writes the segments. Safe: no worker is running.
            unsafe segments.buffer[j].isDecoded = false
        }
        let format = format
        let next = Atomic(0)
        let delivery = Mutex(InflateDelivery(checksum: format.initialChecksum))
        // Unsafe: lanes, segments, and the target shared between threads. Safe: lane `w` is only worker `w`'s;
        // each segment is decoded by one worker (the counter hands each index out once), and read by others only
        // after it's published under the lock; the target is written only by the one delivering worker, each
        // segment's bytes at its own offset; `concurrentPerform` returns only when every worker has.
        DispatchQueue.concurrentPerform(iterations: min(laneCount, segmentCount)) { w in
            while true {
                let j = next.wrappingAdd(1, ordering: .relaxed).oldValue
                guard j < segmentCount, stop?.isStopped != true else { break }
                unsafe segments.buffer[j].decode(input, segment: j, points: points, checksum: format, with: &lanes.buffer[w].stream)
                delivery.withLock { _ in unsafe segments.buffer[j].isDecoded = true }
                unsafe InflateDelivery.deliverReady(delivery, segments: segments, count: segmentCount, format: format, into: target)
            }
        }
        return delivery.withLock { $0 }
    }

    /// Joins the segments into `output` in stream order, after those the workers delivered: each segment whose
    /// start is proven and that ended between blocks at a split (or with the final block) is copied; a failed
    /// one's region is decoded again sequentially, straight into `output` after the bytes joined so far (its
    /// real history), until that decode is between blocks at a later split. Then checks the container's trailer.
    ///
    /// - Returns: The input consumed, the output produced, the segments accepted, and the regions decoded
    ///   again; or `nil` if segment 0 failed (decode sequentially instead, which throws the stream's own error).
    /// - Throws: ``BytesError/insufficientCapacity`` if `output` is too small, ``BytesError/mismatch`` for a
    ///   trailer that doesn't match, ``BytesError/insufficientData`` for a missing one; a region decoded again
    ///   throws as ``DeflateDecoder/decompressAll(_:into:)`` would at that point of the stream.
    private mutating func join(
        _ input: RawSpan, points: SplitPoints, delivered: InflateDelivery, into span: inout MutableRawSpan
    ) throws(BytesError) -> (consumed: Int, produced: Int, accepted: Int, repairs: Int)? {
        if case .failed = segments[0].outcome { return nil }
        let format = format
        var total = delivered.produced
        var checksum = delivered.checksum
        var accepted = delivered.accepted
        var repairs = 0
        var j = delivered.next
        // Where the trailer starts, once the final block is joined.
        var trailer = delivered.trailer
        if trailer < 0 {
            while true {
                let start = total
                let outcome: SegmentOutcome
                let segmentChecksum: UInt32
                if case .failed = segments[j].outcome {
                    // Segment `j`'s start is proven; its from-scratch decode failed. Decode its region again,
                    // after the true history. (The repairs use lane 0's stream, raw DEFLATE: the workers are done.)
                    (total, outcome) = try Self.repair(
                        input, segment: j, from: segments[j].start, points: points, stream: &lanes[0].stream, into: &span, at: total
                    )
                    segmentChecksum = format.checksum(span.bytes.extracting(start..<total))
                    repairs &+= 1
                } else {
                    let length = segments[j].produced
                    guard length <= span.byteCount &- total else { throw .insufficientCapacity }
                    segments[j].copy(into: &span, at: total)
                    total &+= length
                    outcome = segments[j].outcome
                    segmentChecksum = segments[j].checksum
                    accepted &+= 1
                }
                checksum = format.combine(checksum, segmentChecksum, secondLength: total &- start)
                switch outcome {
                case let .boundary(next):
                    j = next
                    continue
                case let .finished(end):
                    trailer = end
                case .failed:
                    preconditionFailure("Joined a failed segment")
                }
                break
            }
        }
        // The last segment was decoded as raw DEFLATE: the trailer follows its final block.
        var reader = try AlignedBytesReader(input, atByteOffset: trailer)
        let bytes = try reader.read(byteCount: format.trailerSize)
        guard format.trailerMatches(bytes, checksum: checksum, length: UInt32(truncatingIfNeeded: total)) else { throw .mismatch }
        return (reader.byteOffset, total, max(accepted, 1), repairs)
    }

    /// Decodes sequentially from segment `j`'s start, `start`, a proven block boundary, into `output` at `offset`
    /// (the bytes before it the stream's real output), until the decode is between blocks exactly at a later
    /// split or the stream ends.
    ///
    /// - Returns: The output's new end, and where the decode stopped: `.boundary(k)` at split `k`, or
    ///   `.finished` with the trailer's offset.
    /// - Throws: ``BytesError/insufficientCapacity`` if `output` fills, ``BytesError/insufficientData`` if the
    ///   input ends inside the stream; corrupt data as ``DeflateDecoder``.
    static func repair(
        _ input: RawSpan, segment j: Int, from start: Int, points: SplitPoints, stream: inout InflateStream,
        into output: inout MutableRawSpan, at offset: Int
    ) throws(BytesError) -> (end: Int, outcome: SegmentOutcome) {
        stream.reset()
        var position = start &<< 3
        var end = offset
        var (k, stop) = points.split(after: j, input)
        while true {
            let result = try stream.run(input.extracting(0..<stop), from: position, into: &output, at: end)
            position = result.position
            end = result.end
            switch result.stop {
            case .outputFull:
                throw .insufficientCapacity
            case .finished:
                return (end, .finished((position &+ 7) &>> 3))
            case .needsInput:
                guard k < points.count else { throw .insufficientData }
                if position == stop &<< 3 && stream.isBetweenBlocks { return (end, .boundary(k)) }
                (k, stop) = points.split(after: k, input)
            }
        }
    }

    private mutating func laneBuffer() -> UnsafeLanes<InflateLane> {
        var span = lanes.mutableSpan
        // Unsafe: the lanes' storage as a pointer that outlives the closure. Safe: `lanes` never changes size
        // after initialization, and callers use the pointer only within the method that took it.
        return span.withUnsafeMutableBufferPointer { unsafe UnsafeLanes(buffer: $0) }
    }

    private mutating func segmentBuffer() -> UnsafeLanes<InflateSegment> {
        var span = segments.mutableSpan
        // Unsafe and safe as `laneBuffer()`.
        return span.withUnsafeMutableBufferPointer { unsafe UnsafeLanes(buffer: $0) }
    }
}

/// Where a parallel decode's segments start: segment 0 where the first block does, segment *j* just after the
/// first `00 00 FF FF` in its window, `target(j) ..< target(j + 1)`, that can start a block (``canStartBlock``),
/// if there is one; then the input's end, as split `count`. A window without one has no segment: the one before
/// runs on to the next split.
///
/// Each split depends only on its own window, so the worker that takes a segment finds its start and end itself,
/// in parallel with the others, instead of one thread scanning for all of them before any starts (0.23 ms of a
/// 3.8 ms decode, Silesia's mozilla on 32 lanes).
struct SplitPoints {
    /// Where the first block starts, after the container's header.
    let first: Int
    /// How many windows: the most segments.
    let count: Int
    /// The input's size.
    let end: Int

    /// The start of segment `j`'s window: evenly spread.
    @inline(__always)
    func target(_ j: Int) -> Int { j &* end / count }

    /// Segment `j`'s start, or `nil` if its window has no split point.
    func split(_ j: Int, _ input: RawSpan) -> Int? {
        if j == 0 { return first }
        if j >= count { return end }
        return Self.firstBlockStart(input, in: target(j)..<target(j &+ 1))
    }

    /// The first split point after split `j`: its index (`count` for the input's end) and offset.
    func split(after j: Int, _ input: RawSpan) -> (index: Int, offset: Int) {
        var k = j &+ 1
        while true {
            if let offset = split(k, input) { return (k, offset) }
            k &+= 1
        }
    }

    /// The offset just after the first `00 00 FF FF` starting in `range` that a block can start after (and that
    /// isn't the input's end), or `nil`.
    static func firstBlockStart(_ input: RawSpan, in range: Range<Int>) -> Int? {
        let window = input.extracting(0..<min(range.upperBound &+ 3, input.byteCount))
        var position = range.lowerBound
        while true {
            // A sync flush's empty stored block: `00 00 FF FF`.
            guard let marker = window.firstByteOffset(of: [0x00, 0x00, 0xFF, 0xFF] as Byte4, from: position) else { return nil }
            let start = marker &+ 4
            guard start < input.byteCount else { return nil }
            // Most `00 00 FF FF`s inside blocks are followed by bits no block header can start with.
            if canStartBlock(input, at: start) { return start }
            position = marker &+ 1
        }
    }

    /// Whether the bytes at `offset` can begin a block, by what every valid header obeys: not the reserved
    /// type; for a stored block, a length and its complement; for a dynamic one, at most 286 literal/length
    /// and 30 distance codes. Rejects about half of the false `00 00 FF FF`s inside blocks (in Silesia's
    /// mozilla at level 1, the one splits landed on), and no real block.
    static func canStartBlock(_ input: RawSpan, at offset: Int) -> Bool {
        // Too near the end to tell: the decode will.
        guard var reader = try? AlignedBytesReader(input, atByteOffset: offset),
              let bytes = try? reader.read(Byte5.self, .littleEndian) else { return true }
        switch (bytes &>> 1) & 3 {
        case 0: // Stored: LEN, then NLEN, from the next byte.
            return (bytes &>> 8) & 0xFFFF == ~(bytes &>> 24) & 0xFFFF
        case 2: // Dynamic: HLIT (5 bits) + 257, then HDIST (5 bits) + 1.
            return (bytes &>> 3) & 0x1F <= 29 && (bytes &>> 8) & 0x1F <= 29
        case 3:
            return false
        default:
            return true
        }
    }
}

/// How a segment's decoding ended.
enum SegmentOutcome: Equatable {
    /// Between blocks exactly at split *k* (the segment's own end, or a later split when the ones between
    /// weren't block boundaries): proven if the segment's start was.
    case boundary(Int)
    /// With the stream's final block, at this byte offset (the trailer's start, for a raw lane).
    case finished(Int)
    /// Otherwise: a match reaching before the segment, an invalid block, or the input's end inside a block.
    case failed
}

/// The segments a parallel decode has copied to the output so far, in stream order: each accepted and every one
/// before it, so the join starts after them.
struct InflateDelivery {
    /// The next segment to deliver: its start is proven.
    var next = 0
    /// Output bytes delivered.
    var produced = 0
    /// The delivered bytes' container checksum.
    var checksum: UInt32
    /// Segments delivered.
    var accepted = 0
    /// Where the trailer starts, once the segment with the final block is delivered; -1 before.
    var trailer = -1
    /// Whether a worker is copying a segment.
    var delivering = false

    /// Copies segments to `target` in order while the next one is decoded and accepted and no other worker is
    /// copying; stops at one that failed (the join decodes its region again) or doesn't fit (the join throws).
    ///
    /// Unsafe: segments and target are shared pointers. Safe: a segment is read only after its worker published
    /// it under the lock, and only by the one worker holding `delivering`, which alone writes the target.
    static func deliverReady(
        _ state: borrowing Mutex<InflateDelivery>, segments: UnsafeLanes<InflateSegment>, count segmentCount: Int,
        format: DeflateFormat, into target: LentMutableBytes
    ) {
        while true {
            let claimed: (segment: Int, offset: Int)? = state.withLock { state in
                let j = state.next
                guard !state.delivering, state.trailer < 0, j < segmentCount, unsafe segments.buffer[j].isDecoded,
                      unsafe segments.buffer[j].outcome != .failed,
                      unsafe segments.buffer[j].produced <= target.buffer.count &- state.produced else { return nil }
                state.delivering = true
                return (j, state.produced)
            }
            guard let (j, offset) = claimed else { return }
            // Unsafe: a span over the lent target. Safe: only this worker writes it now, within its bounds.
            var span = unsafe MutableRawSpan(_unsafeBytes: target.buffer)
            unsafe segments.buffer[j].copy(into: &span, at: offset)
            let length = unsafe segments.buffer[j].produced
            let segmentChecksum = unsafe segments.buffer[j].checksum
            let outcome = unsafe segments.buffer[j].outcome
            state.withLock { state in
                state.delivering = false
                state.produced &+= length
                state.accepted &+= 1
                state.checksum = format.combine(state.checksum, segmentChecksum, secondLength: length)
                switch outcome {
                case let .boundary(k): state.next = k
                case let .finished(end): state.trailer = end
                case .failed: break
                }
            }
        }
    }
}

/// One lane of a parallel decoder: its decoder state, which decodes one segment after another.
///
/// `@usableFromInline`: clients inline the decoder's destructor, which references this type's metadata (see
/// `BrotliCommand`).
@usableFromInline
struct InflateLane: ~Copyable {
    var stream: InflateStream

    init(format: DeflateFormat) {
        stream = InflateStream(format: format)
    }
}

/// One segment of a parallel decode: its output buffer and how its decoding went.
///
/// `@usableFromInline` as ``InflateLane``.
@usableFromInline
struct InflateSegment: ~Copyable {
    var buffer: UniqueArray<UInt8>
    var produced = 0
    var outcome = SegmentOutcome.failed
    var checksum: UInt32 = 0
    /// Whether the segment's decode is done: set and read under a decode's delivery lock.
    var isDecoded = false
    /// Whether the segment's window had a split point, and where it is.
    var exists = false
    var start = 0

    /// The smallest buffer a segment starts with, or grows to.
    static var minimumCapacity: Int { 64 << 10 }

    init() {
        buffer = UniqueArray()
    }

    /// Decodes segment `j` with `stream` from nothing, if its window has a split point: from there until the
    /// decode is between blocks exactly at a later split (the next, unless that one was a false marker) or the
    /// stream ends, growing the buffer as needed; then checksums what it decoded in the container's way.
    mutating func decode(
        _ input: RawSpan, segment j: Int, points: SplitPoints, checksum format: DeflateFormat, with stream: inout InflateStream
    ) {
        produced = 0
        outcome = .failed
        guard let start = points.split(j, input) else {
            exists = false
            return
        }
        exists = true
        self.start = start
        stream.reset()
        // The split the decode runs to.
        var (k, end) = points.split(after: j, input)
        // A first guess at the output, from DEFLATE's typical ratios: allocated without copying while empty.
        let estimate = max(Self.minimumCapacity, (end &- start) &* 4)
        if buffer.count < estimate {
            buffer = UniqueArray(repeating: 0, count: estimate)
        }
        var position = start &<< 3
        while true {
            let result: (position: Int, end: Int, stop: InflateStream.Stop)
            do throws(BytesError) {
                var span = buffer.mutableSpan
                var raw = MutableRawSpan(mutating: &span)
                result = try stream.run(input.extracting(0..<end), from: position, into: &raw, at: produced)
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
                guard k < points.count else { return } // The input ends inside the stream.
                if position == end &<< 3 && stream.isBetweenBlocks {
                    outcome = .boundary(k)
                } else {
                    // Inside a block at split `k`: its `00 00 FF FF` wasn't a sync flush. On to the next.
                    (k, end) = points.split(after: k, input)
                    continue
                }
            case .finished:
                outcome = .finished((position &+ 7) &>> 3)
            }
            break
        }
        checksum = format.checksum(buffer.span.bytes.extracting(0..<produced))
    }

    /// Copies the segment's bytes into `output` at `offset`.
    func copy(into output: inout MutableRawSpan, at offset: Int) {
        output.copyBytes(from: buffer.span.bytes.extracting(0..<produced), toByteOffset: offset)
    }

    /// Doubles the buffer, keeping what's decoded.
    private mutating func grow() {
        var bigger = UniqueArray<UInt8>(repeating: 0, count: max(buffer.count &* 2, Self.minimumCapacity))
        var target = bigger.mutableSpan
        target.copyBytes(from: buffer.span.bytes.extracting(0..<produced), toByteOffset: 0)
        buffer = bigger
    }
}
