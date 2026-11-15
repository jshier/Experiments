public import Bytes

/// A Brotli (RFC 7932) encoder, in one call or as input arrives: HTTP's `Content-Encoding: br`.
///
/// ```swift
/// var encoder = BrotliEncoder(quality: 5)
/// try encoder.compressAll(body, into: &output)              // a whole stream
///
/// encoder.reset()                                           // the next stream, in pieces
/// var progress = try encoder.compress(chunk, into: &output)
/// progress = try encoder.compress(lastChunk, into: &output, flush: .finish)
/// ```
///
/// A fast encoder in the style of Google's lower qualities: a hash table of 4-byte prefixes with buckets of
/// recent positions (deeper as the quality rises), the last distances tried first (1, 2, or 4 of them by
/// quality), and lazy matching from quality 3 on, scored as Google's is (bytes saved against the distance's
/// cost). Each meta-block has one block type per category and one literal code; incompressible data goes in
/// uncompressed meta-blocks. Qualities 1 through 9 differ in search depth; 0 is 1, and 10 and 11 are 9.
///
/// Encoding allocates nothing after initialization. Table positions are absolute and offset per stream, so
/// ``reset()`` normally doesn't clear the tables (only when positions near 2^32).
@safe
public struct BrotliEncoder: ~Copyable {
    /// The quality, 1 through 9.
    public let quality: Int
    /// log2 of the window size, 10 through 24.
    public let windowBits: Int

    private var engine: BrotliEngine
    /// The streaming window: the stream's window of history, then room for input.
    private var window: UniqueArray<UInt8>
    private var windowEnd = 0
    /// The next window byte to compress.
    private var position = 0
    private var headerWritten = false
    private var isFinished = false
    private var flushed = false

    /// Input room in the streaming window beyond the history.
    static var area: Int { 256 << 10 }
    /// Input kept back from compression until more arrives, so matches can reach past it.
    static var lookahead: Int { 1024 }

    /// Creates an encoder, allocating its tables and window.
    ///
    /// - Parameters:
    ///   - quality: 1 (fastest) through 9; 0 means 1, 10 and 11 mean 9.
    ///   - windowBits: log2 of the window (how far back matches reach), 10 through 24. The streaming window
    ///     takes `2^windowBits` bytes plus 256 KB.
    public init(quality: Int = 5, windowBits: Int = 22) {
        self.quality = min(max(quality, 1), 9)
        self.windowBits = min(max(windowBits, 10), 24)
        engine = BrotliEngine(quality: self.quality, windowBits: self.windowBits)
        window = UniqueArray(repeating: 0, count: (1 &<< self.windowBits) &+ Self.area)
    }

    /// Prepares to encode a new stream, discarding anything not delivered. Keeps the allocations.
    public mutating func reset() {
        engine.reset()
        windowEnd = 0
        position = 0
        headerWritten = false
        isFinished = false
        flushed = false
    }

    /// An upper bound on the compressed size of `byteCount` bytes, for one ``compressAll(_:into:)`` call:
    /// the input in uncompressed meta-blocks, with their headers.
    public static func maximumCompressedSize(forByteCount byteCount: Int) -> Int {
        byteCount &+ (byteCount &>> 14) &* 8 &+ 32
    }

    /// Encodes `input` as one whole stream, appending it to `output`.
    ///
    /// - Throws: ``BytesError/insufficientCapacity`` if the stream doesn't fit (`output` then holds part of
    ///   it). ``maximumCompressedSize(forByteCount:)`` bytes of free capacity are always enough.
    public mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) {
        precondition(!headerWritten, "compressAll needs a fresh or reset encoder")
        engine.writeStreamHeader()
        headerWritten = true
        var position = 0
        let end = input.byteCount
        while position < end {
            try deliverAll(into: &output)
            position = engine.compressMetablock(input, from: position, limit: end, dataEnd: end, origin: 0)
        }
        engine.writeLastEmptyMetablock()
        try deliverAll(into: &output)
    }

    private mutating func deliverAll(into output: inout OutputRawSpan) throws(BytesError) {
        _ = deliver(into: &output)
        guard engine.stagedByteCount == 0 else { throw .insufficientCapacity }
    }

    /// Encodes as much of `input` as it can, appending output to `output`, continuing the current stream.
    ///
    /// Input is copied into the encoder's window; ``TransformProgress/consumed`` falls short of `input` only when
    /// the output is full. Keep calling with the same `flush` until the status is `needsInput` (or
    /// `finished`).
    ///
    /// - Parameters:
    ///   - input: The next bytes to compress.
    ///   - output: Where to append compressed bytes.
    ///   - flush: ``TransformFlush/flush`` ends the output on a byte boundary the decoder can decode everything
    ///     up to (an empty metadata block after the current meta-block); ``TransformFlush/finish`` ends the stream.
    /// - Returns: What was consumed and produced, and why it returned.
    public mutating func compress(
        _ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush = .none
    ) throws(BytesError) -> TransformProgress {
        if !headerWritten {
            engine.writeStreamHeader()
            headerWritten = true
        }
        var consumed = 0
        var produced = 0
        while true {
            produced &+= deliver(into: &output)
            if engine.stagedByteCount > 0 {
                return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
            }
            if isFinished {
                return TransformProgress(consumed: consumed, produced: produced, status: .finished)
            }
            if consumed < input.byteCount {
                let room = window.count &- windowEnd
                if room > 0 {
                    let count = min(room, input.byteCount &- consumed)
                    var span = window.mutableSpan
                    var raw = MutableRawSpan(mutating: &span)
                    var writer = try BytesWriter(&raw, atByteOffset: windowEnd)
                    try writer.write(input.extracting(consumed..<(consumed &+ count)))
                    windowEnd &+= count
                    consumed &+= count
                    flushed = false
                } else if position < windowEnd &- Self.lookahead {
                    compressMetablock(limit: windowEnd &- Self.lookahead)
                } else {
                    slide()
                }
                continue
            }
            switch flush {
            case .none:
                return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
            case .flush:
                if position < windowEnd {
                    compressMetablock(limit: windowEnd)
                } else if !flushed {
                    engine.writeFlushMarker()
                    flushed = true
                } else {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
                }
            case .finish:
                if position < windowEnd {
                    compressMetablock(limit: windowEnd)
                } else {
                    engine.writeLastEmptyMetablock()
                    isFinished = true
                }
            }
        }
    }

    private mutating func compressMetablock(limit: Int) {
        let span = window.span.bytes
        position = engine.compressMetablock(span, from: position, limit: limit, dataEnd: windowEnd, origin: engine.windowOrigin)
    }

    /// Keeps the window's history before ``position`` and everything after it, moving them to the front.
    private mutating func slide() {
        let start = max(0, position &- engine.windowSize)
        guard start > 0 else { return }
        let count = windowEnd &- start
        var span = window.mutableSpan
        // Unsafe: a raw copy within the window. Safe: both ranges are inside it, and `copyMemory` allows them
        // to overlap.
        span.withUnsafeMutableBytes { buffer in
            unsafe buffer.baseAddress!.copyMemory(from: buffer.baseAddress!.advanced(by: start), byteCount: count)
        }
        position &-= start
        windowEnd &-= start
        engine.windowOrigin &+= start
    }

    private mutating func deliver(into output: inout OutputRawSpan) -> Int {
        let count = min(engine.stagedByteCount, output.freeCapacity)
        guard count > 0 else { return 0 }
        // Unsafe: a raw copy into the output's free capacity. Safe: `count` bytes are staged and fit, and only
        // they are counted as initialized.
        engine.stagedBytes.withUnsafeBytes { source in
            unsafe output.withUnsafeMutableBytes { buffer, initializedCount in
                unsafe buffer.baseAddress!.advanced(by: initializedCount).copyMemory(from: source.baseAddress!, byteCount: count)
                initializedCount &+= count
            }
        }
        engine.consumeStaged(count)
        return count
    }
}

/// A command: a run of literals, then a copy (or, for the meta-block's last, nothing).
///
/// `@usableFromInline`: Swift 6.4's default cross-module optimization inlined the encoder's destructor into
/// clients, which then referenced this type's metadata, unexported for an internal type: a link error.
@usableFromInline
struct BrotliCommand {
    var insert: UInt32
    var copy: UInt32
    /// The distance's code: 0 through 15 for the last distances, otherwise the distance plus 15.
    var distanceCode: UInt32
    /// The insert-and-copy symbol; below 128, the distance is implicit (the last one).
    var symbol: UInt16
}

/// The encoder's engine: the hash table, the commands of the meta-block being built, and staged output.
@safe
struct BrotliEngine: ~Copyable {
    let windowSize: Int
    let windowBits: Int
    /// Hash table: `1 << bucketBits` buckets of `1 << blockBits` positions (absolute, plus 1; 0 is empty).
    private var buckets: UniqueArray<UInt32>
    /// Insertions per bucket, for the round robin within it.
    private var bucketCounts: UniqueArray<UInt32>
    /// Each entry's tag (8 more hash bits), for buckets of 16 or more: compared 16 at a time.
    private var bucketTags: UniqueArray<UInt8>
    /// The parser's settings, stream position base, and last distances.
    private var matcher: BrotliMatcher
    /// The stream position of the streaming window's byte 0 (0 for one-shot input).
    var windowOrigin = 0

    private var commands: UniqueArray<BrotliCommand>
    static var maximumCommands: Int { 65536 }
    /// The longest copy the parser makes.
    static var maximumCopy: Int { 1 << 20 }
    /// The stream's end in the table's position space so far: where the next stream's positions start.
    private var streamEnd = 0
    /// The longest meta-block: shorter ones adapt their codes faster, longer ones pay for codes less often.
    static var metablockLength: Int { 1 << 18 }

    private var staging: UniqueArray<UInt8>
    private var stagingStart = 0
    private var stagingEnd = 0
    private var pendingBits: UInt64 = 0
    private var pendingBitCount = 0
    static var stagingCapacity: Int { 2 &* (metablockLength &+ 16 << 10) }

    init(quality: Int, windowBits: Int) {
        self.windowBits = windowBits
        let windowSize = (1 &<< windowBits) &- 16
        self.windowSize = windowSize
        // Google's choices for its hashers, about: one entry per bucket at the lowest qualities, then 2 to 64
        // entries (`blockBits`) per bucket, in fewer buckets, as the quality rises.
        let bucketBits: Int
        let blockBits: Int
        switch quality {
        case 1, 2: (bucketBits, blockBits) = (16, 0)
        case 3: (bucketBits, blockBits) = (16, 1)
        case 4: (bucketBits, blockBits) = (15, 2)
        case 5: (bucketBits, blockBits) = (14, 4)
        case 6: (bucketBits, blockBits) = (15, 4)
        case 7: (bucketBits, blockBits) = (15, 5)
        default: (bucketBits, blockBits) = (15, 6)
        }
        matcher = BrotliMatcher(
            quality: quality, bucketBits: bucketBits, blockBits: blockBits, lazyMatching: quality >= 3, windowSize: windowSize
        )
        buckets = UniqueArray(repeating: 0, count: 1 &<< (bucketBits &+ blockBits))
        bucketCounts = UniqueArray(repeating: 0, count: 1 &<< bucketBits)
        bucketTags = UniqueArray(repeating: 0, count: blockBits >= 4 ? 1 &<< (bucketBits &+ blockBits) : 16)
        commands = UniqueArray(repeating: BrotliCommand(insert: 0, copy: 0, distanceCode: 0, symbol: 0), count: Self.maximumCommands)
        staging = UniqueArray(repeating: 0, count: Self.stagingCapacity)
    }

    mutating func reset() {
        // The next stream starts past everything this one could have inserted, plus a window: its entries
        // are then too far back to match.
        let next = UInt64(matcher.streamBase) &+ UInt64(streamEnd) &+ UInt64(windowSize) &+ 1
        if next > UInt64(UInt32.max) &- (1 << 30) {
            var span = buckets.mutableSpan
            span.withUnsafeMutableBytes { buffer in
                // Unsafe: raw stores into the table. Safe: within its bytes.
                _ = unsafe buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
            matcher.streamBase = 0
        } else {
            matcher.streamBase = UInt32(next)
        }
        windowOrigin = 0
        streamEnd = 0
        matcher.distanceCache = [4, 11, 15, 16]
        matcher.filterByTags = false
        stagingStart = 0
        stagingEnd = 0
        pendingBits = 0
        pendingBitCount = 0
    }

    // MARK: - Staging

    var stagedByteCount: Int { stagingEnd &- stagingStart }

    var stagedBytes: RawSpan {
        @_lifetime(borrow self)
        get { staging.span.bytes.extracting(stagingStart..<stagingEnd) }
    }

    mutating func consumeStaged(_ count: Int) {
        stagingStart &+= count
        if stagingStart == stagingEnd {
            stagingStart = 0
            stagingEnd = 0
        }
    }

    @inline(__always)
    private mutating func withWriter<R>(_ body: (inout DeflateBitWriter) -> R) -> R {
        var span = staging.mutableSpan
        var writer = DeflateBitWriter(MutableRawSpan(mutating: &span), offset: stagingEnd, bits: pendingBits, count: pendingBitCount)
        let result = body(&writer)
        stagingEnd = writer.offset
        pendingBits = writer.bits
        pendingBitCount = writer.count
        return result
    }

    /// WBITS (RFC 7932, 9.1).
    mutating func writeStreamHeader() {
        let bits = windowBits
        withWriter { writer in
            switch bits {
            case 16: writer.add(0, bitCount: 1)
            case 17: writer.add(0b000_0001, bitCount: 7)
            case 18...24: writer.add(UInt64(bits &- 17) &<< 1 | 1, bitCount: 4)
            default: writer.add(UInt64(bits &- 8) &<< 4 | 1, bitCount: 7) // 10 through 15
            }
        }
    }

    /// ISLAST and ISLASTEMPTY, padded to a byte.
    mutating func writeLastEmptyMetablock() {
        withWriter { writer in
            writer.add(0b11, bitCount: 2)
            writer.alignToByte()
        }
    }

    /// An empty metadata block, padded to a byte: everything before it can be decoded (Google's flush).
    mutating func writeFlushMarker() {
        withWriter { writer in
            // ISLAST 0, MNIBBLES 3 (metadata), reserved 0, MSKIPBYTES 0.
            writer.add(0b00_0_11_0, bitCount: 6)
            writer.alignToByte()
        }
    }

    // MARK: - Compressing

    /// Compresses `buffer[start..<limit]` (or less: the meta-block length, the command store) into one
    /// meta-block, matches reaching up to `dataEnd` and back up to the window.
    ///
    /// - Parameters:
    ///   - origin: The stream position of `buffer[0]`.
    /// - Returns: Where the meta-block ended.
    mutating func compressMetablock(_ buffer: RawSpan, from start: Int, limit: Int, dataEnd: Int, origin: Int) -> Int {
        let end = min(limit, start &+ Self.metablockLength)
        let commandCount: Int
        let parsedEnd: Int
        let distancesBefore = matcher.distanceCache
        do {
            var commands = commands.mutableSpan
            var buckets = buckets.mutableSpan
            var counts = bucketCounts.mutableSpan
            var tags = bucketTags.mutableSpan
            (parsedEnd, commandCount) = matcher.parse(buffer, from: start, to: end, dataEnd: dataEnd, origin: origin, &commands, &buckets, &counts, &tags)
        }
        if !writeMetablock(buffer, from: start, to: parsedEnd, commandCount: commandCount) {
            // Stored uncompressed: the decoder never sees these commands, so their distances never reach its
            // last distances. Neither may they reach the encoder's.
            matcher.distanceCache = distancesBefore
        }
        streamEnd = max(streamEnd, origin &+ parsedEnd)
        return parsedEnd
    }

    @inline(__always)
    static func load32(_ buffer: RawSpan, _ offset: Int) -> UInt32 {
        // Unsafe: an unchecked load. Safe: callers keep 4 bytes inside the buffer.
        UInt32(littleEndian: unsafe buffer.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    static func hash(_ value: UInt32, bits: Int) -> Int {
        Int(truncatingIfNeeded: (value &* 0x1E35_A7BD) &>> UInt32(32 &- bits))
    }

    // Google's scores: a literal byte saved is worth 135, a bit of distance costs 30.
    static var scoreBase: Int { 1920 }

    @inline(__always)
    static func score(length: Int, distance: Int) -> Int {
        scoreBase &+ 135 &* length &- 30 &* (63 &- distance.leadingZeroBitCount)
    }

    @inline(__always)
    static func lastDistanceScore(length: Int, cacheIndex: Int) -> Int {
        let penalty = cacheIndex == 0 ? 0 : 39 &+ ((0x1CA10 &>> (cacheIndex & 0xE)) & 0xE)
        return 135 &* length &+ scoreBase &+ 15 &- penalty
    }
}

/// The parser's settings and state, a value apart from the engine's tables and buffers: the parse borrows
/// those mutably, which a method of the engine itself couldn't do.
struct BrotliMatcher {
    let quality: Int
    let bucketBits: Int
    let blockBits: Int
    let lazyMatching: Bool
    let windowSize: Int
    /// The absolute position of the current stream's byte 0: streams follow each other in the table's
    /// position space, so older streams' entries are out of every window and the table needn't be cleared.
    var streamBase: UInt32 = 0
    /// The last four distances, the most recent first.
    var distanceCache: InlineArray<4, Int> = [4, 11, 15, 16]
    /// Whether searches compare tags before loading candidates, for this meta-block: when, in the last one, the
    /// tags would have ruled out most of a bucket. Where most candidates match, the tag check only adds a load
    /// and branches ahead of the candidates' loads (17–30% slower on text at qualities 5 and 9); where most
    /// don't, it saves a miss per candidate (35% faster on x-ray). Only buckets of 16 or more have tags,
    /// which are stored either way.
    var filterByTags = false

    /// What the tags ruled out in the searches that compared them.
    struct TagStatistics {
        /// Searches in buckets with tags, to sample every 32nd while not filtering.
        var calls = 0
        /// Searches that compared tags.
        var searches = 0
        /// Filled entries whose tag didn't match, over those searches.
        var rejected = 0
    }

    // The engine's helpers, by their short names.
    @inline(__always) static func load32(_ buffer: RawSpan, _ offset: Int) -> UInt32 { BrotliEngine.load32(buffer, offset) }
    @inline(__always) static func hash(_ value: UInt32, bits: Int) -> Int { BrotliEngine.hash(value, bits: bits) }
    @inline(__always) static func score(length: Int, distance: Int) -> Int { BrotliEngine.score(length: length, distance: distance) }
    @inline(__always) static func lastDistanceScore(length: Int, cacheIndex: Int) -> Int {
        BrotliEngine.lastDistanceScore(length: length, cacheIndex: cacheIndex)
    }
    @inline(__always) static func command(insert: Int, copy: Int, distanceCode: Int) -> BrotliCommand {
        BrotliEngine.command(insert: insert, copy: copy, distanceCode: distanceCode)
    }
    static var maximumCommands: Int { BrotliEngine.maximumCommands }
    static var maximumCopy: Int { BrotliEngine.maximumCopy }

    /// The best match at `position`: the last distances first, then the hash bucket's positions. Inserts
    /// `position` into its bucket.
    ///
    /// - Parameters:
    ///   - statistics: Accumulates what the tags rule out, to choose `filterByTags` for the next meta-block.
    ///   - single: Whether the table has one entry per bucket (qualities 1 and 2); a constant at each call.
    @inline(__always)
    func findMatch(
        _ buffer: RawSpan, _ position: Int, maxLength: Int, maxDistance: Int, origin: Int,
        _ buckets: inout MutableSpan<UInt32>, _ counts: inout MutableSpan<UInt32>, _ tags: inout MutableSpan<UInt8>,
        _ statistics: inout TagStatistics, single: Bool
    ) -> (length: Int, distance: Int, score: Int) {
        var bestLength = 0
        var bestDistance = 0
        var bestScore = 0
        let cacheChecks = quality >= 5 ? 4 : quality >= 3 ? 2 : 1
        for index in 0..<cacheChecks {
            let distance = distanceCache[index]
            guard distance <= maxDistance else { continue }
            let length = DeflateCompressor.extend(buffer, position, position &- distance, from: 0, maxLength: maxLength)
            guard length >= (index == 0 ? 3 : 4) else { continue }
            let score = Self.lastDistanceScore(length: length, cacheIndex: index)
            if score > bestScore {
                bestLength = length
                bestDistance = distance
                bestScore = score
            }
        }
        let head = Self.load32(buffer, position)
        let key = Self.hash(head, bits: bucketBits)
        let absolute = streamBase &+ UInt32(truncatingIfNeeded: origin &+ position) &+ 1
        if single {
            let entry = buckets[key]
            buckets[key] = absolute
            let distance = Int(absolute &- entry)
            if entry != 0 && distance <= maxDistance && distance > 0 {
                let candidate = position &- distance
                if Self.load32(buffer, candidate) == head {
                    let length = DeflateCompressor.extend(buffer, position, candidate, from: 4, maxLength: maxLength)
                    let score = Self.score(length: length, distance: distance)
                    if score > bestScore {
                        bestLength = length
                        bestDistance = distance
                        bestScore = score
                    }
                }
            }
            return (bestLength, bestDistance, bestScore)
        }
        let size = 1 &<< blockBits
        let mask = size &- 1
        let first = key &<< blockBits
        let count = Int(counts[key])
        @inline(__always)
        func consider(_ index: Int) {
            let entry = buckets[first &+ index]
            let distance = Int(absolute &- entry)
            guard distance <= maxDistance && distance > 0 else { return }
            let candidate = position &- distance
            // Worth extending only if it agrees at the byte that would make it longer, and at the start.
            if bestLength < maxLength
                && DeflateCompressor.byte(buffer, candidate &+ bestLength) == DeflateCompressor.byte(buffer, position &+ bestLength)
                && Self.load32(buffer, candidate) == head {
                let length = DeflateCompressor.extend(buffer, position, candidate, from: 4, maxLength: maxLength)
                let score = Self.score(length: length, distance: distance)
                if score > bestScore {
                    bestLength = length
                    bestDistance = distance
                    bestScore = score
                }
            }
        }
        let tag = Self.tag(head, bucketBits: bucketBits)
        // Entries come newest first, and once one is out of the window the rest are: a bucket whose newest is
        // out holds nothing to check. (Earlier streams' entries stay in the table, out of every window: a short
        // stream would otherwise check 16 per search. Breaking out of the loops instead cost large inputs 3–5%.)
        let live = count > 0 && Int(absolute &- buckets[first &+ ((count &- 1) & mask)]) <= maxDistance
        let scan = live && !filterByTags
        if live && blockBits >= 4 {
            // Every search with tags, and every 32nd without, counts the bucket's entries the tags rule out:
            // the misses they save, which picks the next meta-block's mode (`filterByTags`).
            statistics.calls &+= 1
            if filterByTags || statistics.calls & 31 == 0 {
                let matches = Self.tagMatches(tags.span.bytes, first: first, size: size, tag: tag)
                statistics.searches &+= 1
                statistics.rejected &+= min(count, size) &- matches.nonzeroBitCount
                if filterByTags {
                    // Most recent first, as the scan: of equal-length candidates the first is kept (the byte
                    // check after the best length rejects the rest), and the nearest keeps distances repeating,
                    // which Brotli codes cheaply (in slot order, files came out 4% larger). Rotating the mask
                    // puts the newest slot in the top bit; the rest follow downward, wrapping.
                    let shift = size &- 1 &- ((count &- 1) & mask)
                    let width = UInt64(size)
                    var order = shift == 0 ? matches : (matches &<< UInt64(shift)) | (matches &>> (width &- UInt64(shift)))
                    if size < 64 { order &= (1 &<< width) &- 1 }
                    while order != 0 {
                        let bit = 63 &- order.leadingZeroBitCount
                        consider((bit &- shift) & mask)
                        order &= ~(1 &<< UInt64(bit))
                    }
                }
            }
        }
        if scan {
            // Most recent first; older entries are farther still.
            var index = count
            let stop = count &- min(count, size)
            while index > stop {
                index &-= 1
                consider(index & mask)
            }
        }
        buckets[first &+ (count & mask)] = absolute
        if blockBits >= 4 {
            tags[first &+ (count & mask)] = tag
        }
        counts[key] = UInt32(truncatingIfNeeded: count &+ 1)
        return (bestLength, bestDistance, bestScore)
    }

    /// Which of a bucket's slots hold `tag`, slot i in bit i. Google's SIMD hashers' idea: each entry keeps 8
    /// more bits of its hash, compared 16 at once, so only entries whose tag matches need loading from the
    /// data (each load a likely cache miss).
    @inline(__always)
    static func tagMatches(_ tags: RawSpan, first: Int, size: Int, tag: UInt8) -> UInt64 {
        let wanted = ByteLanes(SIMD16(repeating: tag))
        var matches: UInt64 = 0
        var group = 0
        while group < size {
            // Unsafe: an unchecked 16-byte load of tags. Safe: `first + group + 16` is within the bucket.
            let lanes = unsafe tags.unsafeLoadUnaligned(fromUncheckedByteOffset: first &+ group, as: SIMD16<UInt8>.self)
            matches |= UInt64(laneMask(ByteLanes(lanes ^ wanted.vector).matching(0))) &<< UInt64(group)
            group &+= 16
        }
        return matches
    }

    /// The 8 hash bits after the bucket's: the entry's tag.
    @inline(__always)
    static func tag(_ value: UInt32, bucketBits: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (value &* 0x1E35_A7BD) &>> UInt32(24 &- bucketBits))
    }

    /// Which of 16 lanes matched, one bit each (lane 0 in bit 0): each half's high bits shifted to bit 0 of
    /// their bytes, then gathered into one byte by a multiply (byte i's bit lands in bit 56 + i). Portable,
    /// and two multiplies; NEON's `shrn` would be one instruction.
    @inline(__always)
    static func laneMask(_ matches: ByteMatches) -> UInt32 {
        let halves = unsafe unsafeBitCast(matches.highBits, to: SIMD2<UInt64>.self) // Safe: both are 16 plain bytes.
        // Lane i is byte i of the halves on a little-endian CPU; a big-endian one swaps them back.
        let first = UInt64(littleEndian: halves[0])
        let second = UInt64(littleEndian: halves[1])
        // Parenthesized: Swift's shifts bind tighter than multiplication.
        let low = (((first &>> 7) & 0x0101_0101_0101_0101) &* 0x0102_0408_1020_4080) &>> 56
        let high = (((second &>> 7) & 0x0101_0101_0101_0101) &* 0x0102_0408_1020_4080) &>> 56
        return UInt32(truncatingIfNeeded: low | high &<< 8)
    }

    /// Inserts `position` into its bucket without searching.
    @inline(__always)
    private func insertPosition(
        _ buffer: RawSpan, _ position: Int, origin: Int,
        _ buckets: inout MutableSpan<UInt32>, _ counts: inout MutableSpan<UInt32>, _ tags: inout MutableSpan<UInt8>, single: Bool
    ) {
        let head = Self.load32(buffer, position)
        let key = Self.hash(head, bits: bucketBits)
        let absolute = streamBase &+ UInt32(truncatingIfNeeded: origin &+ position) &+ 1
        if single {
            buckets[key] = absolute
        } else {
            let count = Int(counts[key])
            let slot = (key &<< blockBits) &+ (count & ((1 &<< blockBits) &- 1))
            buckets[slot] = absolute
            if blockBits >= 4 { tags[slot] = Self.tag(head, bucketBits: bucketBits) }
            counts[key] = UInt32(truncatingIfNeeded: count &+ 1)
        }
    }

    /// Google's `ComputeDistanceCode`: a short code for the last distances and the last two plus or minus 1
    /// to 3, or the distance plus 15.
    @inline(__always)
    private func distanceCode(_ distance: Int) -> Int {
        let last = distanceCache[0]
        let second = distanceCache[1]
        if distance == last { return 0 }
        if distance == second { return 1 }
        let offset0 = distance &+ 3 &- last
        if offset0 >= 0 && offset0 < 7 { return (0x975_0468 &>> (4 &* offset0)) & 0xF }
        let offset1 = distance &+ 3 &- second
        if offset1 >= 0 && offset1 < 7 { return (0xFDB_1ACE &>> (4 &* offset1)) & 0xF }
        if distance == distanceCache[2] { return 2 }
        if distance == distanceCache[3] { return 3 }
        return distance &+ 15
    }

    /// Parses `buffer[start..<end]` into commands (Google's `CreateBackwardReferences`, lazy for qualities 3
    /// and up). Ends early if the command store fills.
    ///
    /// - Returns: Where parsing ended, and the number of commands, the last one literals only.
    mutating func parse(
        _ buffer: RawSpan, from start: Int, to end: Int, dataEnd: Int, origin: Int,
        _ commands: inout MutableSpan<BrotliCommand>, _ buckets: inout MutableSpan<UInt32>, _ counts: inout MutableSpan<UInt32>,
        _ tags: inout MutableSpan<UInt8>
    ) -> (end: Int, commandCount: Int) {
        // A copy for each table: with the buckets' code (and its tags) in the loop, the one-entry table's
        // (qualities 1 and 2) ran 7–10% more instructions.
        if blockBits == 0 {
            return parseSingle(buffer, from: start, to: end, dataEnd: dataEnd, origin: origin, &commands, &buckets, &counts, &tags)
        }
        return parseBuckets(buffer, from: start, to: end, dataEnd: dataEnd, origin: origin, &commands, &buckets, &counts, &tags)
    }

    /// `parse` for a one-entry table (qualities 1 and 2).
    @inline(never)
    private mutating func parseSingle(
        _ buffer: RawSpan, from start: Int, to end: Int, dataEnd: Int, origin: Int,
        _ commands: inout MutableSpan<BrotliCommand>, _ buckets: inout MutableSpan<UInt32>, _ counts: inout MutableSpan<UInt32>,
        _ tags: inout MutableSpan<UInt8>
    ) -> (end: Int, commandCount: Int) {
        parse(buffer, from: start, to: end, dataEnd: dataEnd, origin: origin, &commands, &buckets, &counts, &tags, single: true)
    }

    /// `parse` for buckets of several entries (quality 3 and up).
    @inline(never)
    private mutating func parseBuckets(
        _ buffer: RawSpan, from start: Int, to end: Int, dataEnd: Int, origin: Int,
        _ commands: inout MutableSpan<BrotliCommand>, _ buckets: inout MutableSpan<UInt32>, _ counts: inout MutableSpan<UInt32>,
        _ tags: inout MutableSpan<UInt8>
    ) -> (end: Int, commandCount: Int) {
        parse(buffer, from: start, to: end, dataEnd: dataEnd, origin: origin, &commands, &buckets, &counts, &tags, single: false)
    }

    /// `parse`'s body, for a one-entry table (`single`, a constant at each call) or buckets.
    @inline(__always)
    private mutating func parse(
        _ buffer: RawSpan, from start: Int, to end: Int, dataEnd: Int, origin: Int,
        _ commands: inout MutableSpan<BrotliCommand>, _ buckets: inout MutableSpan<UInt32>, _ counts: inout MutableSpan<UInt32>,
        _ tags: inout MutableSpan<UInt8>, single: Bool
    ) -> (end: Int, commandCount: Int) {
        var position = start
        var insert = 0
        var count = 0
        var statistics = TagStatistics()
        let limit = Self.maximumCommands &- 1
        let skipWindow = quality < 9 ? 64 : 512
        var skipFrom = position &+ skipWindow
        // A match needs 4 bytes to hash and compare; near the end, only literals.
        while position &+ 4 <= end && count < limit {
            // Capped so a meta-block stays far below Brotli's 2^24-byte limit.
            let maxLength = min(dataEnd &- position, Self.maximumCopy)
            let maxDistance = min(origin &+ position, windowSize)
            var match = findMatch(buffer, position, maxLength: maxLength, maxDistance: maxDistance, origin: origin, &buckets, &counts, &tags, &statistics, single: single)
            guard match.length >= 4 || (match.length == 3 && match.distance == distanceCache[0]) else {
                insert &+= 1
                position &+= 1
                // Long without a match: skip ahead, hashing less often (incompressible data).
                if position > skipFrom {
                    let step = position > skipFrom &+ 4 &* skipWindow ? 4 : 2
                    let jump = min(position &+ step &* 4, end &- 4)
                    while position < jump {
                        insertPosition(buffer, position, origin: origin, &buckets, &counts, &tags, single: single)
                        insert &+= step
                        position &+= step
                    }
                }
                continue
            }
            if lazyMatching {
                // Look one position ahead (up to four times) for a clearly better match.
                var delayed = 0
                while position &+ 5 <= end && delayed < 4 {
                    let next = findMatch(
                        buffer, position &+ 1, maxLength: maxLength &- 1, maxDistance: min(origin &+ position &+ 1, windowSize),
                        origin: origin, &buckets, &counts, &tags, &statistics, single: single
                    )
                    guard next.score >= match.score &+ 175 else { break }
                    position &+= 1
                    insert &+= 1
                    match = next
                    delayed &+= 1
                }
            }
            let code = distanceCode(match.distance)
            if code != 0 {
                distanceCache[3] = distanceCache[2]
                distanceCache[2] = distanceCache[1]
                distanceCache[1] = distanceCache[0]
                distanceCache[0] = match.distance
            }
            commands[count] = Self.command(insert: insert, copy: match.length, distanceCode: code)
            count &+= 1
            // Insert the copy's positions (the first was inserted by the search).
            let copyEnd = min(position &+ match.length, end &- 4)
            var inserted = position &+ 1
            while inserted < copyEnd {
                insertPosition(buffer, inserted, origin: origin, &buckets, &counts, &tags, single: single)
                inserted &+= 1
            }
            position &+= match.length
            insert = 0
            skipFrom = position &+ 2 &* match.length &+ skipWindow
        }
        if position < end {
            insert &+= end &- position
            position = end
        }
        // Tags when they rule out more than half the bucket. Per search, of 16 entries at quality 5: text 3 to 6
        // (dickens 3.8, Main.js 4.0, samba 6.1), binaries and tables 10 to 14 (mozilla 10.3, osdb 11.2, x-ray 14.2).
        filterByTags = !single && statistics.searches > 0 && statistics.rejected &* 2 > statistics.searches &<< blockBits
        commands[count] = BrotliCommand(insert: UInt32(insert), copy: 0, distanceCode: 0, symbol: 0)
        return (position, count &+ 1)
    }
}

extension BrotliEngine {
    /// A command, with its insert-and-copy symbol (Google's `GetInsertLengthCode`, `GetCopyLengthCode`, and
    /// `CombineLengthCodes`).
    @inline(__always)
    static func command(insert: Int, copy: Int, distanceCode: Int) -> BrotliCommand {
        let insertCode = insertLengthCode(insert)
        let copyCode = copyLengthCode(copy)
        let low = (copyCode & 7) | (insertCode & 7) &<< 3
        let symbol: Int
        if distanceCode == 0 && insertCode < 8 && copyCode < 16 {
            symbol = copyCode < 8 ? low : low | 64
        } else {
            var offset = 2 &* ((copyCode &>> 3) &+ 3 &* (insertCode &>> 3))
            offset = (offset &<< 5) &+ 0x40 &+ ((0x52_0D40 &>> offset) & 0xC0)
            symbol = offset | low
        }
        return BrotliCommand(insert: UInt32(insert), copy: UInt32(copy), distanceCode: UInt32(distanceCode), symbol: UInt16(symbol))
    }

    @inline(__always)
    static func insertLengthCode(_ length: Int) -> Int {
        if length < 6 { return length }
        if length < 130 {
            let bits = (63 &- (length &- 2).leadingZeroBitCount) &- 1
            return (bits &<< 1) &+ ((length &- 2) &>> bits) &+ 2
        }
        if length < 2114 { return (63 &- (length &- 66).leadingZeroBitCount) &+ 10 }
        if length < 6210 { return 21 }
        if length < 22594 { return 22 }
        return 23
    }

    @inline(__always)
    static func copyLengthCode(_ length: Int) -> Int {
        if length < 10 { return length &- 2 }
        if length < 134 {
            let bits = (63 &- (length &- 6).leadingZeroBitCount) &- 1
            return (bits &<< 1) &+ ((length &- 6) &>> bits) &+ 4
        }
        if length < 2118 { return (63 &- (length &- 70).leadingZeroBitCount) &+ 12 }
        return 23
    }

    /// The distance symbol and its extra bits (NPOSTFIX 0, NDIRECT 0): `code` itself below 16, otherwise
    /// two symbols per power of two of the distance plus 3.
    @inline(__always)
    static func distanceSymbol(_ code: Int) -> (symbol: Int, extraBits: Int, extra: Int) {
        guard code >= 16 else { return (code, 0, 0) }
        let value = code &- 12 // The distance plus 3.
        let bits = (63 &- value.leadingZeroBitCount) &- 1
        let prefix = (value &>> bits) & 1
        return (16 &+ 2 &* (bits &- 1) &+ prefix, bits, value &- ((2 &+ prefix) &<< bits))
    }

    // MARK: - Writing meta-blocks

    /// Writes the meta-block of `buffer[start..<end]` from the parsed commands: compressed with three prefix
    /// codes, or uncompressed if that's smaller.
    ///
    /// - Returns: Whether it was written compressed (with the commands).
    private mutating func writeMetablock(_ buffer: RawSpan, from start: Int, to end: Int, commandCount: Int) -> Bool {
        let length = end &- start
        guard length > 0 else { return true }
        var literalCounts = InlineArray<256, UInt32>(repeating: 0)
        var commandCounts = InlineArray<704, UInt32>(repeating: 0)
        var distanceCounts = InlineArray<64, UInt32>(repeating: 0)
        let lastSymbol: Int
        do {
            let commandList = commands.span.extracting(0..<commandCount)
            var position = start
            for index in 0..<commandCount {
                let command = commandList[index]
                for offset in 0..<Int(command.insert) {
                    literalCounts[Int(DeflateCompressor.byte(buffer, position &+ offset))] &+= 1
                }
                position &+= Int(command.insert) &+ Int(command.copy)
                guard command.copy > 0 else { continue }
                commandCounts[Int(command.symbol)] &+= 1
                if command.symbol >= 128 {
                    distanceCounts[Self.distanceSymbol(Int(command.distanceCode)).symbol] &+= 1
                }
            }
            // The last command has no copy: its insert-and-copy symbol still has to be coded (copy length code
            // 0 means a copy of 2, ignored at the meta-block's end).
            let last = commandList[commandCount &- 1]
            lastSymbol = Int(Self.command(insert: Int(last.insert), copy: 2, distanceCode: 0).symbol)
            if last.insert > 0 {
                commandCounts[lastSymbol] &+= 1
            }
        }

        var literalCodes = BrotliCode<256>()
        var commandCodes = BrotliCode<704>()
        var distanceCodes = BrotliCode<64>()
        literalCodes.build(literalCounts.span, maximumLength: 15)
        commandCodes.build(commandCounts.span, maximumLength: 15)
        distanceCodes.build(distanceCounts.span, maximumLength: 15)

        // Estimate: the codes' bits for the data, against storing it.
        var bits = 0
        do {
            let lengths = literalCodes.lengths.span
            let counts = literalCounts.span
            for symbol in 0..<256 { bits &+= Int(counts[symbol]) &* Int(lengths[symbol]) }
        }
        do {
            let lengths = commandCodes.lengths.span
            let counts = commandCounts.span
            for symbol in 0..<704 where counts[symbol] != 0 {
                let cell = symbol &>> 6
                let insertCode = Int(Brotli.cellInsertCodes[cell]) &+ (symbol &>> 3 & 7)
                let copyCode = Int(Brotli.cellCopyCodes[cell]) &+ (symbol & 7)
                bits &+= Int(counts[symbol]) &* (Int(lengths[symbol]) &+ Int(Brotli.insertExtraBits[insertCode]) &+ Int(Brotli.copyExtraBits[copyCode]))
            }
        }
        do {
            let lengths = distanceCodes.lengths.span
            let counts = distanceCounts.span
            for symbol in 0..<64 where counts[symbol] != 0 {
                let extra = symbol < 16 ? 0 : 1 &+ ((symbol &- 16) &>> 1)
                bits &+= Int(counts[symbol]) &* (Int(lengths[symbol]) &+ extra)
            }
        }
        // The trees cost up to about 300 bytes; data that doesn't shrink by more goes uncompressed.
        if bits / 8 &+ 300 >= length {
            writeUncompressedMetablock(buffer, from: start, to: end)
            return false
        }

        var span = staging.mutableSpan
        var writer = DeflateBitWriter(MutableRawSpan(mutating: &span), offset: stagingEnd, bits: pendingBits, count: pendingBitCount)
        Self.writeMetablockLength(length, isUncompressed: false, to: &writer)
        // One block type per category, NPOSTFIX 0, NDIRECT 0, context mode 0 (LSB6), one literal tree, one
        // distance tree: 1 + 1 + 1 + 2 + 4 + 2 + 1 + 1 bits.
        writer.add(0, bitCount: 13)
        writer.flush()
        literalCodes.store(to: &writer)
        commandCodes.store(to: &writer)
        distanceCodes.store(to: &writer)
        Self.writeCommands(
            buffer, from: start, commands.span.extracting(0..<commandCount), lastSymbol: lastSymbol,
            literals: literalCodes, commands: commandCodes, distances: distanceCodes, to: &writer
        )
        stagingEnd = writer.offset
        pendingBits = writer.bits
        pendingBitCount = writer.count
        return true
    }

    /// ISLAST 0, MNIBBLES, MLEN - 1, ISUNCOMPRESSED.
    private static func writeMetablockLength(_ length: Int, isUncompressed: Bool, to writer: inout DeflateBitWriter) {
        let value = length &- 1
        let nibbles = value < 1 &<< 16 ? 4 : value < 1 &<< 20 ? 5 : 6
        writer.add(UInt64(nibbles &- 4) &<< 1, bitCount: 3)
        writer.add(UInt64(value), bitCount: nibbles &* 4)
        writer.add(isUncompressed ? 1 : 0, bitCount: 1)
        writer.flush()
    }

    private mutating func writeUncompressedMetablock(_ buffer: RawSpan, from start: Int, to end: Int) {
        withWriter { writer in
            Self.writeMetablockLength(end &- start, isUncompressed: true, to: &writer)
            writer.alignToByte()
            writer.write(buffer.extracting(start..<end))
        }
    }

    /// Writes the commands: each insert-and-copy code and lengths' extra bits, its literals, and its
    /// distance code if it has one.
    @inline(never)
    private static func writeCommands(
        _ buffer: RawSpan, from start: Int, _ commands: Span<BrotliCommand>, lastSymbol: Int,
        literals: borrowing BrotliCode<256>, commands commandCode: borrowing BrotliCode<704>,
        distances: borrowing BrotliCode<64>, to writer: inout DeflateBitWriter
    ) {
        let literalCodewords = literals.codewords.span
        let literalLengths = literals.lengths.span
        let commandCodewords = commandCode.codewords.span
        let commandLengths = commandCode.lengths.span
        let distanceCodewords = distances.codewords.span
        let distanceLengths = distances.lengths.span
        var position = start
        for index in commands.indices {
            let command = commands[index]
            let insert = Int(command.insert)
            let copy = Int(command.copy)
            if copy == 0 && insert == 0 { break }
            let symbol = copy == 0 ? lastSymbol : Int(command.symbol)
            let cell = symbol &>> 6
            let insertCode = Int(Brotli.cellInsertCodes[cell]) &+ (symbol &>> 3 & 7)
            let copyCode = Int(Brotli.cellCopyCodes[cell]) &+ (symbol & 7)
            writer.add(UInt64(commandCodewords[symbol]), bitCount: Int(commandLengths[symbol]))
            writer.add(UInt64(insert &- Int(Brotli.insertBases[insertCode])), bitCount: Int(Brotli.insertExtraBits[insertCode]))
            writer.flush()
            let copyValue = copy == 0 ? 0 : copy &- Int(Brotli.copyBases[copyCode])
            writer.add(UInt64(copyValue), bitCount: Int(Brotli.copyExtraBits[copyCode]))
            writer.flush()
            var remaining = insert
            while remaining >= 3 {
                for offset in 0..<3 {
                    let literal = Int(DeflateCompressor.byte(buffer, position &+ offset))
                    writer.add(UInt64(literalCodewords[literal]), bitCount: Int(literalLengths[literal]))
                }
                writer.flush()
                position &+= 3
                remaining &-= 3
            }
            while remaining > 0 {
                let literal = Int(DeflateCompressor.byte(buffer, position))
                writer.add(UInt64(literalCodewords[literal]), bitCount: Int(literalLengths[literal]))
                position &+= 1
                remaining &-= 1
            }
            writer.flush()
            guard copy > 0 else { break }
            if symbol >= 128 {
                let (distanceSymbol, extraBits, extra) = distanceSymbol(Int(command.distanceCode))
                writer.add(UInt64(distanceCodewords[distanceSymbol]), bitCount: Int(distanceLengths[distanceSymbol]))
                writer.add(UInt64(extra), bitCount: extraBits)
                writer.flush()
            }
            position &+= copy
        }
    }
}

/// A prefix code over an alphabet of `size` symbols: built from counts, written in Brotli's simple or
/// complex form (RFC 7932, 3.4 and 3.5), the complex form's lengths run-length coded as Google's encoder does.
struct BrotliCode<let size: Int> {
    var lengths = InlineArray<size, UInt8>(repeating: 0)
    var codewords = InlineArray<size, UInt32>(repeating: 0)
    /// The used symbols if at most 4, ordered by code length.
    var symbols = InlineArray<4, Int>(repeating: 0)
    var symbolCount = 0

    mutating func build(_ counts: Span<UInt32>, maximumLength: Int) {
        symbolCount = 0
        for symbol in 0..<size where counts[symbol] != 0 {
            if symbolCount < 4 { symbols[symbolCount] = symbol }
            symbolCount &+= 1
            if symbolCount > 4 { break }
        }
        if symbolCount <= 1 {
            // One symbol or none (then symbol 0 stands in): a code of no bits.
            if symbolCount == 0 { symbols[0] = 0 }
            var lengths = lengths.mutableSpan
            for index in 0..<size { lengths[index] = 0 }
            return
        }
        var lengths = lengths.mutableSpan
        var codewords = codewords.mutableSpan
        HuffmanCodeBuilder.build(frequencies: counts, maximumLength: maximumLength, lengths: &lengths, codewords: &codewords)
        if symbolCount <= 4 {
            // Simple codes list symbols by code length (then value).
            for i in 0..<symbolCount {
                for j in (i &+ 1)..<symbolCount where lengths[symbols[j]] < lengths[symbols[i]] {
                    let swap = symbols[i]
                    symbols[i] = symbols[j]
                    symbols[j] = swap
                }
            }
        }
    }

    /// The bits that represent `size - 1`: a simple code's symbol width.
    static var symbolBits: Int {
        var bits = 0
        while (size &- 1) &>> bits != 0 { bits &+= 1 }
        return bits
    }

    func store(to writer: inout DeflateBitWriter) {
        if symbolCount <= 4 {
            storeSimple(to: &writer)
        } else {
            storeComplex(to: &writer)
        }
    }

    private func storeSimple(to writer: inout DeflateBitWriter) {
        let count = max(symbolCount, 1)
        writer.add(1 | UInt64(count &- 1) &<< 2, bitCount: 4) // HSKIP 1, NSYM - 1
        for index in 0..<count {
            writer.add(UInt64(symbols[index]), bitCount: Self.symbolBits)
            writer.flush()
        }
        if count == 4 {
            writer.add(lengths[symbols[0]] == 1 ? 1 : 0, bitCount: 1) // Tree select: 1, 2, 3, 3 or all 2.
        }
        writer.flush()
    }

    /// Google's `BrotliStoreHuffmanTree`: the lengths run-length coded with repeat codes 16 and 17, those
    /// symbols' own code (at most 5 bits), and its lengths with a fixed code.
    private func storeComplex(to writer: inout DeflateBitWriter) {
        let lengths = lengths.span
        var items = InlineArray<720, UInt8>(repeating: 0)
        var extras = InlineArray<720, UInt8>(repeating: 0)
        var itemCount = 0
        var end = size
        while end > 0 && lengths[end &- 1] == 0 { end &-= 1 }
        // Decide whether runs pay, as Google does.
        var zeroRuns = 0
        var zeroRunCount = 1
        var valueRuns = 0
        var valueRunCount = 1
        var index = 0
        while index < end {
            let value = lengths[index]
            var run = 1
            while index &+ run < end && lengths[index &+ run] == value { run &+= 1 }
            if run >= 3 && value == 0 { zeroRuns &+= run; zeroRunCount &+= 1 }
            if run >= 4 && value != 0 { valueRuns &+= run; valueRunCount &+= 1 }
            index &+= run
        }
        let runsForValues = size > 50 && valueRuns > valueRunCount &* 2
        let runsForZeros = size > 50 && zeroRuns > zeroRunCount &* 2
        func append(_ item: UInt8, _ extra: UInt8 = 0) {
            items[itemCount] = item
            extras[itemCount] = extra
            itemCount &+= 1
        }
        /// Appends repeat codes for `count` more of a run (each code multiplies the previous one's count by 4,
        /// or 8 for zeros, plus its own), most significant first.
        func appendRepeats(_ code: UInt8, _ count: Int, extraBits: Int) {
            var repetitions = count &- 3
            let first = itemCount
            while true {
                append(code, UInt8(repetitions & ((1 &<< extraBits) &- 1)))
                repetitions &>>= extraBits
                if repetitions == 0 { break }
                repetitions &-= 1
            }
            var low = first
            var high = itemCount &- 1
            while low < high {
                let item = items[low]
                items[low] = items[high]
                items[high] = item
                let extra = extras[low]
                extras[low] = extras[high]
                extras[high] = extra
                low &+= 1
                high &-= 1
            }
        }
        var previous: UInt8 = 8
        index = 0
        while index < end {
            let value = lengths[index]
            var run = 1
            if (value != 0 && runsForValues) || (value == 0 && runsForZeros) {
                while index &+ run < end && lengths[index &+ run] == value { run &+= 1 }
            }
            var remaining = run
            if value == 0 {
                if remaining == 11 {
                    append(0)
                    remaining &-= 1
                }
                if remaining < 3 {
                    for _ in 0..<remaining { append(0) }
                } else {
                    appendRepeats(17, remaining, extraBits: 3)
                }
            } else {
                if previous != value {
                    append(value)
                    remaining &-= 1
                }
                if remaining == 7 {
                    append(value)
                    remaining &-= 1
                }
                if remaining < 3 {
                    for _ in 0..<remaining { append(value) }
                } else {
                    appendRepeats(16, remaining, extraBits: 2)
                }
                previous = value
            }
            index &+= run
        }
        // The code-length code.
        var counts = InlineArray<18, UInt32>(repeating: 0)
        for item in 0..<itemCount { counts[Int(items[item])] &+= 1 }
        var used = 0
        var only = 0
        for symbol in 0..<18 where counts[symbol] != 0 {
            used &+= 1
            only = symbol
        }
        var codeLengths = InlineArray<18, UInt8>(repeating: 0)
        var codeCodewords = InlineArray<18, UInt32>(repeating: 0)
        if used == 1 {
            codeLengths[only] = 1 // Sent as length 1; the symbols then take no bits.
        } else {
            var lengthSpan = codeLengths.mutableSpan
            var codewordSpan = codeCodewords.mutableSpan
            HuffmanCodeBuilder.build(frequencies: counts.span, maximumLength: 5, lengths: &lengthSpan, codewords: &codewordSpan)
        }
        // Its lengths in the fixed order, with the fixed code (values written least significant bit first).
        let order = Brotli.codeLengthOrder
        let fixedCodes: InlineArray<6, UInt8> = [0, 7, 3, 2, 1, 15]
        let fixedLengths: InlineArray<6, UInt8> = [2, 4, 3, 2, 2, 4]
        var stored = 18
        if used > 1 {
            while stored > 0 && codeLengths[Int(order[stored &- 1])] == 0 { stored &-= 1 }
        }
        var skip = 0
        if codeLengths[Int(order[0])] == 0 && codeLengths[Int(order[1])] == 0 {
            skip = codeLengths[Int(order[2])] == 0 ? 3 : 2
        }
        writer.add(UInt64(skip), bitCount: 2)
        for position in skip..<stored {
            let length = Int(codeLengths[Int(order[position])])
            writer.add(UInt64(fixedCodes[length]), bitCount: Int(fixedLengths[length]))
            if position % 8 == 7 { writer.flush() }
        }
        writer.flush()
        if used == 1 { codeLengths[only] = 0 }
        for item in 0..<itemCount {
            let symbol = Int(items[item])
            writer.add(UInt64(codeCodewords[symbol]), bitCount: Int(codeLengths[symbol]))
            if symbol == 16 { writer.add(UInt64(extras[item]), bitCount: 2) }
            if symbol == 17 { writer.add(UInt64(extras[item]), bitCount: 3) }
            writer.flush()
        }
    }
}
