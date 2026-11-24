internal import Bytes

// The DEFLATE encoder's engine: matchfinders, parsers, and the block writer, after libdeflate's
// `deflate_compress.c` (Eric Biggers), on spans. `DeflateEncoder` drives it over the caller's input (one
// shot) or its own window (streaming).
//
// Positions in the hash tables are 16-bit, relative to a base that advances 32 KB at a time (libdeflate's
// `mf_pos_t`): half the memory of 32-bit positions, and rebasing is a vectorized pass over the tables
// every 32 KB of input. A table entry at or below `cutoff` (32 KB behind) is out of the window. Rebasing
// happens when a position reaches 32 KB past the base *or passes it*: positions that aren't inserted (a
// flush's last few bytes) can step over the boundary, and checking for equality alone then never rebased
// again, losing every match after.
//
// Hot loops load from the input with unchecked loads, each justified by the parse's invariants: positions
// in the tables are positions already seen (so inside the buffer), and lengths never exceed `maxLength`,
// which is at most the bytes left in the buffer.
//
// Block writing flushes its `BitWriter` unchecked (`unsafeFlush`): each block starts only once `hasRoom`
// confirms the staging buffer holds the block's worst case plus `BitWriter.slack`.

/// How a level parses: libdeflate's strategies.
enum DeflateStrategy {
    /// Stored blocks only.
    case stored
    /// A hash table of 2-entry buckets, greedy parsing, no block splitting.
    case fastest
    /// Hash chains, the longest match at each position.
    case greedy
    /// Hash chains, and a lookahead of one position for a better match.
    case lazy
    /// A lookahead of two positions.
    case lazy2
}

/// A compression level's parameters (libdeflate's for levels 0 through 9).
struct DeflateLevelParameters {
    var strategy: DeflateStrategy
    var maxSearchDepth: Int
    var niceLength: Int

    init(level: Int) {
        switch level {
        case ...0: self = .init(.stored, 0, 0)
        case 1: self = .init(.fastest, 1, 32)
        case 2: self = .init(.greedy, 6, 10)
        case 3: self = .init(.greedy, 12, 14)
        case 4: self = .init(.greedy, 16, 30)
        case 5: self = .init(.lazy, 16, 30)
        case 6: self = .init(.lazy, 35, 65)
        case 7: self = .init(.lazy, 100, 130)
        case 8: self = .init(.lazy2, 300, Deflate.maximumMatch)
        default: self = .init(.lazy2, 600, Deflate.maximumMatch)
        }
    }

    private init(_ strategy: DeflateStrategy, _ maxSearchDepth: Int, _ niceLength: Int) {
        self.strategy = strategy
        self.maxSearchDepth = maxSearchDepth
        self.niceLength = niceLength
    }
}

/// Symbol frequencies of the block being parsed.
struct DeflateFrequencies {
    var literalLength = InlineArray<288, UInt32>(repeating: 0)
    var distance = InlineArray<32, UInt32>(repeating: 0)
}

/// A block's Huffman codes: lengths and bit-reversed codewords.
struct DeflateCodes {
    var literalLengthCodewords = InlineArray<288, UInt32>(repeating: 0)
    var literalLengthLengths = InlineArray<288, UInt8>(repeating: 0)
    var distanceCodewords = InlineArray<32, UInt32>(repeating: 0)
    var distanceLengths = InlineArray<32, UInt8>(repeating: 0)

    /// The fixed code (RFC 1951, 3.2.6).
    static var fixed: DeflateCodes {
        var codes = DeflateCodes()
        codes.literalLengthLengths = Deflate.fixedLiteralLengths
        codes.distanceLengths = InlineArray(repeating: 5)
        var lengths = codes.literalLengthLengths.span
        var codewords = codes.literalLengthCodewords.mutableSpan
        HuffmanCodeBuilder.canonicalCodewords(lengths, &codewords)
        lengths = codes.distanceLengths.span
        codewords = codes.distanceCodewords.mutableSpan
        HuffmanCodeBuilder.canonicalCodewords(lengths, &codewords)
        return codes
    }
}

/// libdeflate's block-splitting heuristic: literals and matches are sorted into 10 kinds of observation, and
/// every 512 observations the distribution of the newest ones is compared with the block's so far. A large
/// enough difference ends the block. Cheap enough to run per symbol, and no codes are built to decide.
struct BlockSplitStatistics {
    var newObservations = InlineArray<10, UInt32>(repeating: 0)
    var observations = InlineArray<10, UInt32>(repeating: 0)
    var newCount: UInt32 = 0
    var count: UInt32 = 0

    static var observationsPerCheck: UInt32 { 512 }
    static var minimumBlockLength: Int { 5000 }

    /// A literal: its top two bits and lowest bit make 8 kinds.
    @inline(__always)
    mutating func observeLiteral(_ literal: UInt8) {
        newObservations[Int((literal &>> 5) & 0x6 | literal & 1)] &+= 1
        newCount &+= 1
    }

    /// A match: short (under 9) or long.
    @inline(__always)
    mutating func observeMatch(length: Int) {
        newObservations[length >= 9 ? 9 : 8] &+= 1
        newCount &+= 1
    }

    /// Whether to end the block at `position`.
    @inline(__always)
    mutating func shouldEndBlock(blockStart: Int, position: Int, end: Int) -> Bool {
        guard newCount >= Self.observationsPerCheck, position &- blockStart >= Self.minimumBlockLength,
              end &- position >= Self.minimumBlockLength else { return false }
        return check(blockLength: position &- blockStart)
    }

    /// The sum of absolute differences between the old and new distributions, scaled by both counts to stay
    /// in integers, against a cutoff of 200/512 (raised for short blocks, whose Huffman tables cost more).
    private mutating func check(blockLength: Int) -> Bool {
        if count > 0 {
            var totalDelta: UInt32 = 0
            for kind in 0..<10 {
                let expected = observations[kind] &* newCount
                let actual = newObservations[kind] &* count
                totalDelta &+= actual > expected ? actual &- expected : expected &- actual
            }
            let items = count &+ newCount
            var cutoff = UInt64(newCount &* 200 / 512) &* UInt64(count)
            if blockLength < 10000 && items < 8192 {
                cutoff &+= cutoff &* UInt64(8192 &- items) / 8192
            }
            if UInt64(totalDelta) &+ UInt64(blockLength / 4096) &* UInt64(count) >= cutoff {
                return true
            }
        }
        for kind in 0..<10 {
            observations[kind] &+= newObservations[kind]
            newObservations[kind] = 0
        }
        count &+= newCount
        newCount = 0
        return false
    }
}

/// The encoder's state: tables, the block being built, and the output staged for delivery.
@safe
struct DeflateCompressor: ~Copyable {
    let parameters: DeflateLevelParameters

    // MARK: Matchfinder

    /// The window as the matchfinder sees it: positions are 16-bit, relative to `base`.
    static var windowSize: Int { 32768 }
    static var hash3Bits: Int { 15 }
    static var hash4Bits: Int { 16 }
    /// An empty table entry: always out of the window.
    static var emptyEntry: Int16 { Int16.min }

    /// Hash-chain heads for 3-byte prefixes (one entry each); unused at level 1.
    private var hash3: UniqueArray<Int16>
    /// Hash-chain heads for 4-byte prefixes, or at level 1, its table of 2-entry buckets (a 15-bit hash, two
    /// entries each).
    private var hash4: UniqueArray<Int16>
    /// Each position's previous position with the same 4-byte hash, indexed by relative position.
    private var chains: UniqueArray<Int16>
    /// The buffer offset that relative position 0 stands for.
    var base = 0
    /// Hashes of the next position, computed when the previous one is searched.
    private var nextHash3 = 0
    private var nextHash4 = 0

    // MARK: Block

    /// Sequences: a run of literals, then a match (length 0 for the block's last run). Packed: the run
    /// length in bits 0–31, the match length in bits 32–40, the distance in bits 48–63.
    private var sequences: UniqueArray<UInt64>
    static var maximumSequences: Int { 50000 }
    private var frequencies = DeflateFrequencies()
    private var split = BlockSplitStatistics()
    /// The shortest match worth taking: 3 to 9, from how many distinct literals the data uses. 0 until the
    /// stream's first block scans its data.
    private var minimumMatch = 0
    /// Each match length's symbol, minus 257.
    private var lengthSlots = InlineArray<259, UInt8>(repeating: 0)
    private var codes = DeflateCodes()
    private let fixedCodes = DeflateCodes.fixed

    /// The longest block before the split heuristic gets a say (levels 2–9), and the fastest level's block
    /// length (level 1 doesn't split).
    static var softMaximumBlockLength: Int { 300_000 }
    static var fastBlockLength: Int { 65535 }
    static var fastMaximumSequences: Int { 8192 }

    // MARK: Output

    /// Compressed bytes waiting to be delivered, and the bit writer's partial byte.
    private var staging: UniqueArray<UInt8>
    private(set) var stagingStart = 0
    private(set) var stagingEnd = 0
    private var pendingBits: UInt64 = 0
    private var pendingBitCount = 0

    /// The staging buffer: twice the largest block's worst case.
    static var stagingCapacity: Int { 2 * (softMaximumBlockLength + 8 * 1024) }

    init(level: Int) {
        // Computed into a local first: reading `self.parameters` here, before the arrays below were
        // initialized, made Swift 6.4.2's optimized build treat their first assignments as reassignments and
        // free the uninitialized "old" arrays (a crash in release builds only).
        let parameters = DeflateLevelParameters(level: level)
        let chained = parameters.strategy != .fastest && parameters.strategy != .stored
        self.parameters = parameters
        hash3 = UniqueArray(repeating: Self.emptyEntry, count: 1 << Self.hash3Bits)
        hash4 = UniqueArray(repeating: Self.emptyEntry, count: 1 << Self.hash4Bits)
        chains = UniqueArray(repeating: Self.emptyEntry, count: chained ? Self.windowSize : 0)
        sequences = UniqueArray(repeating: 0, count: Self.maximumSequences &+ 1)
        staging = UniqueArray(repeating: 0, count: Self.stagingCapacity)
        lengthSlots = Self.makeLengthSlots()
    }

    /// Each match length's symbol, minus 257.
    private static func makeLengthSlots() -> InlineArray<259, UInt8> {
        var slots = InlineArray<259, UInt8>(repeating: 0)
        for slot in 0..<28 {
            for length in Int(Deflate.lengthBases[slot])..<Int(Deflate.lengthBases[slot &+ 1]) {
                slots[length] = UInt8(slot)
            }
        }
        slots[258] = 28 // 258 has its own symbol, not 227 + 31.
        return slots
    }

    /// Forgets the window and any staged output, for a new stream.
    ///
    /// The chains aren't cleared: a search only follows a chain from a head inserted in this stream, and every
    /// link after it was written when its position was inserted (the first insertion into a bucket links to
    /// the empty head).
    mutating func reset() {
        Self.clear(&hash3)
        Self.clear(&hash4)
        base = 0
        nextHash3 = 0
        nextHash4 = 0
        minimumMatch = 0
        stagingStart = 0
        stagingEnd = 0
        pendingBits = 0
        pendingBitCount = 0
    }

    /// Inserts `buffer[start..<end]` into the matchfinder without emitting anything: history for a stream
    /// that begins at `end`, which matches may then reach back into (zlib's `deflateSetDictionary`). A
    /// parallel encoder primes each chunk's compressor with the 32 KB before the chunk, so the chunks join
    /// into one stream that compresses almost as well as a sequential one.
    ///
    /// - Parameters:
    ///   - buffer: The data: the history, then the stream from `end`.
    ///   - start: Where the history starts.
    ///   - end: Where it ends and the stream begins.
    /// - Precondition: The compressor is new or reset, and the history is at most 32 KB.
    mutating func prime(_ buffer: RawSpan, from start: Int, to end: Int) {
        precondition(base == 0 && end &- start <= Self.windowSize && start >= 0 && end <= buffer.byteCount)
        base = start
        // Each inserted position's hash needs 4 bytes from it.
        let last = min(end, buffer.byteCount &- 4)
        switch parameters.strategy {
        case .stored:
            return
        case .fastest:
            var table = hash4.mutableSpan
            precondition(table.count == 1 << 16)
            var position = start
            while position < last {
                let bucket = (Self.hash(Self.load32(buffer, position), bits: 15) & ((1 << 15) &- 1)) &<< 1
                table[bucket | 1] = table[bucket]
                table[bucket] = Int16(truncatingIfNeeded: position &- start)
                position &+= 1
            }
            if end &+ 4 <= buffer.byteCount {
                nextHash4 = Self.hash(Self.load32(buffer, end), bits: 15)
            }
        case .greedy, .lazy, .lazy2:
            var hash3 = hash3.mutableSpan
            var hash4 = hash4.mutableSpan
            var chains = chains.mutableSpan
            precondition(hash3.count == 1 << Self.hash3Bits && hash4.count == 1 << Self.hash4Bits && chains.count == Self.windowSize)
            var position = start
            while position < last {
                let current = position &- start
                let sequence = Self.load32(buffer, position)
                let h3 = Self.hash(sequence & 0xFF_FFFF, bits: Self.hash3Bits)
                let h4 = Self.hash(sequence, bits: Self.hash4Bits)
                hash3[h3 & ((1 << Self.hash3Bits) &- 1)] = Int16(truncatingIfNeeded: current)
                chains[current & (Self.windowSize &- 1)] = hash4[h4 & ((1 << Self.hash4Bits) &- 1)]
                hash4[h4 & ((1 << Self.hash4Bits) &- 1)] = Int16(truncatingIfNeeded: current)
                position &+= 1
            }
            if end &+ 4 <= buffer.byteCount {
                let sequence = Self.load32(buffer, end)
                nextHash3 = Self.hash(sequence & 0xFF_FFFF, bits: Self.hash3Bits)
                nextHash4 = Self.hash(sequence, bits: Self.hash4Bits)
            }
        }
    }

    /// Empties a table, 16 bytes per store. A loop of element stores (and `MutableSpan.update(repeating:)`)
    /// compiled to one 2-byte store per entry: 59% of compressing a 2.7 KB file.
    ///
    /// `storeBytes(repeating:count:as:)` requires the span's start aligned for its type, and a `UniqueArray<Int16>`
    /// promises only 2 bytes: a `SIMD8<Int16>` needs 16, which the allocator gives in practice but the type doesn't
    /// promise. So the start is checked once: aligned (always, today), one 16-byte store per group (3 instructions);
    /// otherwise unaligned stores, whose bounds checks don't fold (8 instructions per group). The
    /// `InlineArray<8, Int16>` form, aligned as `Int16`, compiled to one 2-byte store per entry. (Typing the tables by
    /// their store stride would make the alignment the type's own.)
    static func clear(_ table: inout UniqueArray<Int16>) {
        var span = table.mutableSpan
        let groups = span.count &>> 3 // The tables' sizes are multiples of 8 entries.
        var bytes = span.mutableBytes
        let empty = SIMD8<Int16>(repeating: emptyEntry)
        // The start's address as an integer: only its value is read, never memory through it.
        let aligned = bytes.withUnsafeBytes { Int(bitPattern: $0.baseAddress) & (MemoryLayout<SIMD8<Int16>>.alignment &- 1) == 0 }
        if aligned {
            bytes.storeBytes(repeating: empty, count: groups, as: SIMD8<Int16>.self)
            return
        }
        var offset = 0
        while offset < groups &<< 4 {
            bytes.storeBytes(of: empty, toByteOffset: offset, as: SIMD8<Int16>.self)
            offset &+= 16
        }
    }

    // MARK: - Staging

    /// Staged bytes not yet delivered.
    var stagedBytes: RawSpan {
        @_lifetime(borrow self)
        get { staging.span.bytes.extracting(stagingStart..<stagingEnd) }
    }

    /// Marks `count` staged bytes delivered.
    mutating func consumeStaged(_ count: Int) {
        stagingStart &+= count
        if stagingStart == stagingEnd {
            stagingStart = 0
            stagingEnd = 0
        }
    }

    /// Hands the staged bytes over without copying them: swaps the staging buffer with `buffer`, an empty one
    /// of ``stagingCapacity`` bytes, and returns where in it the staged bytes are.
    ///
    /// - Precondition: The output is byte-aligned (after a sync flush or the final block's alignment).
    mutating func takeStaged(swapping buffer: inout UniqueArray<UInt8>) -> Range<Int> {
        precondition(pendingBitCount == 0 && buffer.count == Self.stagingCapacity)
        swap(&staging, &buffer)
        let range = stagingStart..<stagingEnd
        stagingStart = 0
        stagingEnd = 0
        return range
    }

    /// Whether `byteCount` more bytes (plus the writer's slack) fit in the staging buffer.
    func hasRoom(_ byteCount: Int) -> Bool {
        Self.stagingCapacity &- stagingEnd >= byteCount &+ BitWriter.slack &+ 16
    }

    /// Stages bytes written outside a block (a container header or trailer). The writer must be aligned.
    mutating func stage(_ bytes: RawSpan) {
        precondition(pendingBitCount == 0 && hasRoom(bytes.byteCount))
        var span = staging.mutableSpan
        span.copyBytes(from: bytes, toByteOffset: stagingEnd)
        stagingEnd &+= bytes.byteCount
    }

    /// Runs `body` with a bit writer at the end of the staged output, then keeps what it wrote.
    @inline(__always)
    private mutating func withWriter<R>(_ body: (inout BitWriter) -> R) -> R {
        var span = staging.mutableSpan
        var writer = BitWriter(MutableRawSpan(mutating: &span), byteOffset: stagingEnd, bits: pendingBits, bitCount: pendingBitCount)
        let result = body(&writer)
        stagingEnd = writer.byteOffset
        pendingBits = writer.pendingBits
        pendingBitCount = writer.pendingBitCount
        return result
    }

    /// Pads the output to a byte boundary (before a container trailer).
    mutating func alignOutput() {
        withWriter { $0.alignToByte() }
    }

    /// Writes an empty stored block: a sync flush, after which everything so far can be decoded.
    mutating func writeSyncMarker() {
        // Unsafe: an unchecked flush of 7 bytes at most. Safe: written between blocks, whose output the staging
        // buffer holds with room to spare (``stagingCapacity``: twice the largest block's worst case).
        withWriter { writer in
            writer.add(0, bitCount: 3) // Not final, stored.
            writer.alignToByte()
            writer.add(0xFFFF_0000, bitCount: 32) // LEN 0, NLEN 0xFFFF.
            unsafe writer.unsafeFlush()
        }
    }

    // MARK: - Compressing

    /// Compresses `buffer[start..<limit]` into one block, matches reaching up to `dataEnd` and back into the
    /// history before `start`.
    ///
    /// - Parameters:
    ///   - buffer: The data, with history before `start` and lookahead after `limit`.
    ///   - start: Where the block starts.
    ///   - limit: Where the block should end; it may end earlier (block splitting, the sequence store
    ///     filling) or later (by up to a match).
    ///   - dataEnd: The end of the data available for matches.
    ///   - isFinal: Whether this is the stream's last block, if it reaches `limit`.
    /// - Returns: Where the block ended.
    /// - Precondition: The staging buffer has room for the block's worst case.
    mutating func compressBlock(_ buffer: RawSpan, from start: Int, limit: Int, dataEnd: Int, isFinal: Bool) -> Int {
        let end: Int
        switch parameters.strategy {
        case .stored:
            end = min(limit, start &+ 65535)
            writeStoredBlock(buffer, from: start, to: end, isFinal: isFinal && end >= limit)
            return end
        case .fastest:
            let blockEnd = Self.maximumBlockEnd(start, limit, Self.fastBlockLength)
            end = parseFastest(buffer, from: start, blockEnd: blockEnd, dataEnd: dataEnd)
        case .greedy, .lazy, .lazy2:
            if minimumMatch == 0 { // The stream's first block.
                minimumMatch = Self.minimumMatchLength(scanning: buffer, from: start, to: dataEnd, depth: parameters.maxSearchDepth)
            }
            let blockEnd = Self.maximumBlockEnd(start, limit, Self.softMaximumBlockLength)
            end = parseChained(buffer, from: start, blockEnd: blockEnd, dataEnd: dataEnd)
            minimumMatch = Self.minimumMatchLength(frequencies, depth: parameters.maxSearchDepth)
        }
        writeBlock(buffer, from: start, to: end, isFinal: isFinal && end >= limit)
        return end
    }

    /// Where a block starting at `start` may end: `limit`, unless more than `softMaximum` plus a minimum
    /// block remains.
    static func maximumBlockEnd(_ start: Int, _ limit: Int, _ softMaximum: Int) -> Int {
        limit &- start < softMaximum &+ BlockSplitStatistics.minimumBlockLength ? limit : start &+ softMaximum
    }

    /// Writes an empty final block (a stream of no data).
    mutating func writeEmptyFinalBlock() {
        let fixed = fixedCodes
        // Unsafe and safe as `writeSyncMarker()`: 10 bits.
        withWriter { writer in
            writer.add(0b011, bitCount: 3) // Final, fixed Huffman.
            writer.add(UInt64(fixed.literalLengthCodewords[256]), bitCount: Int(fixed.literalLengthLengths[256]))
            unsafe writer.unsafeFlush()
        }
    }

    // MARK: Minimum match length

    /// libdeflate's choice of the shortest match from the number of distinct literals: with few literals,
    /// literals code short, and a 3-byte match costs more than its literals.
    static func minimumMatchLength(literalCount: Int, depth: Int) -> Int {
        let table: InlineArray<80, UInt8> = [
            9, 9, 9, 9, 9, 9, 8, 8, 7, 7, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
            4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
            4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        ]
        guard literalCount < 80 else { return 3 }
        var length = Int(table[literalCount])
        // A shallow search rarely finds the long matches a high minimum needs.
        if depth < 16 {
            length = min(length, depth < 5 ? 4 : depth < 10 ? 5 : 7)
        }
        return length
    }

    /// The minimum match length from the distinct bytes in the first 4 KB of `buffer[start..<end]`.
    static func minimumMatchLength(scanning buffer: RawSpan, from start: Int, to end: Int, depth: Int) -> Int {
        guard end &- start >= 512 else { return 3 } // The fixed code is likely best: allow short matches.
        var used = InlineArray<256, Bool>(repeating: false)
        for offset in start..<min(end, start &+ 4096) {
            used[Int(buffer.load(fromByteOffset: offset, as: UInt8.self))] = true
        }
        var count = 0
        for byte in 0..<256 where used[byte] {
            count &+= 1
        }
        return minimumMatchLength(literalCount: count, depth: depth)
    }

    /// The minimum match length from the previous block's literals, ignoring the rarest.
    static func minimumMatchLength(_ frequencies: borrowing DeflateFrequencies, depth: Int) -> Int {
        // Through a span: indexing the struct's `InlineArray` field copied the whole array per access.
        let literals = frequencies.literalLength.span
        var total: UInt32 = 0
        for literal in 0..<256 {
            total &+= literals[literal]
        }
        let cutoff = total &>> 10
        var count = 0
        for literal in 0..<256 where literals[literal] > cutoff {
            count &+= 1
        }
        return minimumMatchLength(literalCount: count, depth: depth)
    }

    // MARK: - Matchfinding helpers

    // `LZHash`'s, by their short names. `load32` is unchecked: every caller loads within the buffer (see the
    // file's comment).
    @inline(__always) static func hash(_ value: UInt32, bits: Int) -> Int { LZHash.hash(value, bits: bits) }
    @inline(__always) static func load32(_ buffer: RawSpan, _ offset: Int) -> UInt32 { LZHash.load32(buffer, offset) }

    @inline(__always)
    static func load64(_ buffer: RawSpan, _ offset: Int) -> UInt64 {
        // Unsafe and safe as `load32`.
        UInt64(littleEndian: unsafe buffer.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt64.self))
    }

    @inline(__always)
    static func byte(_ buffer: RawSpan, _ offset: Int) -> UInt8 {
        // Unsafe and safe as `load32`.
        unsafe buffer.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt8.self)
    }

    /// How far the strings at `position` and `candidate` agree, from `start` up to `maxLength`.
    ///
    /// Bytes' unchecked form: the checked `commonPrefixLength` cost 1–8% more instructions in DEFLATE and
    /// 3–18% in Brotli, called per candidate. Unsafe: unchecked loads. Safe: every caller passes `candidate <
    /// position` and `maxLength <= dataEnd - position`, with `dataEnd` within the buffer (see the file's
    /// comment).
    @inline(__always)
    static func extend(_ buffer: RawSpan, _ position: Int, _ candidate: Int, from start: Int, maxLength: Int) -> Int {
        unsafe buffer.unsafeCommonPrefixLength(at: position, and: candidate, from: start, maxLength: maxLength)
    }

    /// Moves the window's base 32 KB forward: every entry drops by 32,768, and those that fall out of the
    /// window become empty. A loop the vectorizer turns into `smax` and `add` on eight lanes at a time.
    static func rebase(_ table: inout MutableSpan<Int16>) {
        for index in table.indices {
            table[index] = max(table[index], 0) &+ Int16.min
        }
    }

    /// The distance's symbol: 0–3 for distances 1–4, then two symbols per power of two.
    @inline(__always)
    static func distanceSlot(_ distance: Int) -> Int {
        let value = UInt32(truncatingIfNeeded: distance &- 1)
        let log = 31 &- value.leadingZeroBitCount
        return value < 4 ? Int(value) : 2 &* log &+ Int(value &>> UInt32(log &- 1) & 1)
    }

    /// The index of the highest set bit.
    @inline(__always)
    static func log2(_ value: Int) -> Int {
        63 &- value.leadingZeroBitCount
    }

    // MARK: - Level 1: hash table, greedy

    /// Parses a block with the fastest level's matchfinder (libdeflate's `ht_matchfinder`): each 4-byte
    /// hash has a bucket of the two most recent positions.
    private mutating func parseFastest(_ buffer: RawSpan, from start: Int, blockEnd: Int, dataEnd: Int) -> Int {
        var table = hash4.mutableSpan
        var sequences = sequences.mutableSpan
        precondition(table.count == 1 << 16 && sequences.count == Self.maximumSequences &+ 1)
        var frequencies = DeflateFrequencies()
        let niceLength = parameters.niceLength
        var position = start
        var base = base
        var nextHash = nextHash4
        var run: UInt32 = 0
        var count = 0
        let mask = (1 << 15) &- 1
        let longest = Deflate.maximumMatch

        while position < blockEnd && count < Self.fastMaximumSequences {
            // Where the per-position checks below always pass: a full-length match and its insertions' hashes
            // fit before `dataEnd` (so `maxLength` is 258, at least 5, and every match's positions get inserted),
            // and a match's last position stays below 32 KB past the base (no rebase). There, a loop without
            // them, which checks the sequence count only after a match (literals don't add sequences); the
            // same steps, so the same output.
            let fastEnd = min(min(blockEnd, dataEnd &- (longest &+ 5)), base &+ Self.windowSize &- longest)
            if position < fastEnd {
                repeat {
                    let current = position &- base
                    let cutoff = current &- Self.windowSize
                    let bucket = (nextHash & mask) &<< 1
                    nextHash = Self.hash(Self.load32(buffer, position &+ 1), bits: 15)
                    let sequence = Self.load32(buffer, position)
                    let first = Int(table[bucket])
                    let second = Int(table[bucket | 1])
                    table[bucket] = Int16(truncatingIfNeeded: current)
                    table[bucket | 1] = Int16(truncatingIfNeeded: first)
                    var length = 0
                    var distance = 0
                    if first > cutoff {
                        let candidate = base &+ first
                        if Self.load32(buffer, candidate) == sequence {
                            length = Self.extend(buffer, position, candidate, from: 4, maxLength: longest)
                            distance = position &- candidate
                        }
                        if second > cutoff && length < niceLength {
                            let candidate = base &+ second
                            if Self.load32(buffer, candidate) == sequence {
                                let other = Self.extend(buffer, position, candidate, from: 4, maxLength: longest)
                                if other > length {
                                    length = other
                                    distance = position &- candidate
                                }
                            }
                        }
                    }
                    if length >= 4 {
                        frequencies.literalLength[257 &+ Int(lengthSlots[length])] &+= 1
                        frequencies.distance[Self.distanceSlot(distance)] &+= 1
                        sequences[count] = UInt64(run) | UInt64(length) &<< 32 | UInt64(distance) &<< 48
                        count &+= 1
                        run = 0
                        var inserted = position &+ 1
                        var current = current &+ 1
                        for _ in 1..<length {
                            let bucket = (nextHash & mask) &<< 1
                            table[bucket | 1] = table[bucket]
                            table[bucket] = Int16(truncatingIfNeeded: current)
                            inserted &+= 1
                            current &+= 1
                            nextHash = Self.hash(Self.load32(buffer, inserted), bits: 15)
                        }
                        position &+= length
                        if count == Self.fastMaximumSequences { break }
                    } else {
                        frequencies.literalLength[Int(Self.byte(buffer, position))] &+= 1
                        run &+= 1
                        position &+= 1
                    }
                } while position < fastEnd
                continue
            }
            // The rest, a position at a time: near the data's end and the window's.
            let maxLength = min(Deflate.maximumMatch, dataEnd &- position)
            var length = 0
            var distance = 0
            if maxLength >= 5 {
                var current = position &- base
                while current >= Self.windowSize {
                    Self.rebase(&table)
                    base &+= Self.windowSize
                    current &-= Self.windowSize
                }
                let cutoff = current &- Self.windowSize
                let bucket = (nextHash & mask) &<< 1
                nextHash = Self.hash(Self.load32(buffer, position &+ 1), bits: 15)
                let sequence = Self.load32(buffer, position)
                let first = Int(table[bucket])
                let second = Int(table[bucket | 1])
                table[bucket] = Int16(truncatingIfNeeded: current)
                table[bucket | 1] = Int16(truncatingIfNeeded: first)
                if first > cutoff {
                    let candidate = base &+ first
                    if Self.load32(buffer, candidate) == sequence {
                        length = Self.extend(buffer, position, candidate, from: 4, maxLength: maxLength)
                        distance = position &- candidate
                    }
                    if second > cutoff && length < niceLength {
                        let candidate = base &+ second
                        if Self.load32(buffer, candidate) == sequence {
                            let other = Self.extend(buffer, position, candidate, from: 4, maxLength: maxLength)
                            if other > length {
                                length = other
                                distance = position &- candidate
                            }
                        }
                    }
                }
            }
            if length >= 4 {
                frequencies.literalLength[257 &+ Int(lengthSlots[length])] &+= 1
                frequencies.distance[Self.distanceSlot(distance)] &+= 1
                sequences[count] = UInt64(run) | UInt64(length) &<< 32 | UInt64(distance) &<< 48
                count &+= 1
                run = 0
                // Insert the match's other positions, if 5 bytes remain after them for their hashes.
                if length &+ 5 <= dataEnd &- position {
                    var inserted = position &+ 1
                    var current = inserted &- base
                    for _ in 1..<length {
                        while current >= Self.windowSize {
                            Self.rebase(&table)
                            base &+= Self.windowSize
                            current &-= Self.windowSize
                        }
                        let bucket = (nextHash & mask) &<< 1
                        table[bucket | 1] = table[bucket]
                        table[bucket] = Int16(truncatingIfNeeded: current)
                        inserted &+= 1
                        current &+= 1
                        nextHash = Self.hash(Self.load32(buffer, inserted), bits: 15)
                    }
                }
                position &+= length
            } else {
                frequencies.literalLength[Int(Self.byte(buffer, position))] &+= 1
                run &+= 1
                position &+= 1
            }
        }
        sequences[count] = UInt64(run)
        self.sequenceCount = count &+ 1
        self.frequencies = frequencies
        self.base = base
        nextHash4 = nextHash
        return position
    }

    /// The number of sequences in the block just parsed, including the last literal run.
    private var sequenceCount = 0

    // MARK: - Levels 2–9: hash chains

    /// Parses a block with hash chains (libdeflate's `hc_matchfinder`): greedy, lazy, or lazy2.
    private mutating func parseChained(_ buffer: RawSpan, from start: Int, blockEnd: Int, dataEnd: Int) -> Int {
        var hash3 = hash3.mutableSpan
        var hash4 = hash4.mutableSpan
        var chains = chains.mutableSpan
        var sequences = sequences.mutableSpan
        precondition(
            hash3.count == 1 << Self.hash3Bits && hash4.count == 1 << Self.hash4Bits
                && chains.count == Self.windowSize && sequences.count == Self.maximumSequences &+ 1
        )
        var state = ChainState(
            base: base, nextHash3: nextHash3, nextHash4: nextHash4, frequencies: DeflateFrequencies(),
            split: BlockSplitStatistics(), run: 0, count: 0
        )
        let position: Int
        switch parameters.strategy {
        case .greedy:
            position = Self.parseGreedy(buffer, start, blockEnd, dataEnd, parameters, minimumMatch, lengthSlots, &hash3, &hash4, &chains, &sequences, &state)
        case .lazy:
            position = Self.parseLazy(buffer, start, blockEnd, dataEnd, parameters, minimumMatch, lengthSlots, lazy2: false, &hash3, &hash4, &chains, &sequences, &state)
        default:
            position = Self.parseLazy(buffer, start, blockEnd, dataEnd, parameters, minimumMatch, lengthSlots, lazy2: true, &hash3, &hash4, &chains, &sequences, &state)
        }
        sequences[state.count] = UInt64(state.run)
        sequenceCount = state.count &+ 1
        frequencies = state.frequencies
        base = state.base
        nextHash3 = state.nextHash3
        nextHash4 = state.nextHash4
        return position
    }

    /// The hash-chain parsers' running state, kept in registers by passing it to one function.
    struct ChainState {
        var base: Int
        var nextHash3: Int
        var nextHash4: Int
        var frequencies: DeflateFrequencies
        var split: BlockSplitStatistics
        var run: UInt32
        var count: Int

        @inline(__always)
        mutating func literal(_ byte: UInt8, observe: Bool = true) {
            frequencies.literalLength[Int(byte)] &+= 1
            if observe { split.observeLiteral(byte) }
            run &+= 1
        }

        @inline(__always)
        mutating func match(length: Int, distance: Int, _ lengthSlots: InlineArray<259, UInt8>, _ sequences: inout MutableSpan<UInt64>) {
            frequencies.literalLength[257 &+ Int(lengthSlots[length])] &+= 1
            frequencies.distance[DeflateCompressor.distanceSlot(distance)] &+= 1
            split.observeMatch(length: length)
            sequences[count] = UInt64(run) | UInt64(length) &<< 32 | UInt64(distance) &<< 48
            count &+= 1
            run = 0
        }
    }

    /// The longest match at `position` (libdeflate's `hc_matchfinder_longest_match`), inserting `position`
    /// into the tables.
    ///
    /// - Parameters:
    ///   - bestLength: Only longer matches count (the minimum match length minus 1, or the current match's).
    ///   - maxLength: The longest match allowed: at most the bytes left.
    ///   - niceLength: Stop searching at a match this long.
    ///   - depth: The most chain entries to visit.
    /// - Returns: The best length (`bestLength` if nothing longer was found) and its distance.
    @inline(__always)
    static func longestMatch(
        _ buffer: RawSpan, _ position: Int, bestLength initialLength: Int, maxLength: Int, niceLength: Int, depth: Int,
        _ hash3: inout MutableSpan<Int16>, _ hash4: inout MutableSpan<Int16>, _ chains: inout MutableSpan<Int16>,
        _ state: inout ChainState
    ) -> (length: Int, distance: Int) {
        var bestLength = initialLength
        guard maxLength >= 5 else { return (bestLength, 0) }
        var current = position &- state.base
        while current >= windowSize {
            rebase(&hash3)
            rebase(&hash4)
            rebase(&chains)
            state.base &+= windowSize
            current &-= windowSize
        }
        let base = state.base
        let cutoff = current &- windowSize
        let windowMask = windowSize &- 1
        let node3 = Int(hash3[state.nextHash3 & ((1 << hash3Bits) &- 1)])
        var node4 = Int(hash4[state.nextHash4 & ((1 << hash4Bits) &- 1)])
        hash3[state.nextHash3 & ((1 << hash3Bits) &- 1)] = Int16(truncatingIfNeeded: current)
        hash4[state.nextHash4 & ((1 << hash4Bits) &- 1)] = Int16(truncatingIfNeeded: current)
        chains[current & windowMask] = Int16(truncatingIfNeeded: node4)
        let next = load32(buffer, position &+ 1)
        state.nextHash3 = hash(next & 0xFF_FFFF, bits: hash3Bits)
        state.nextHash4 = hash(next, bits: hash4Bits)

        var remaining = depth
        var bestCandidate = position
        if bestLength < 4 {
            // A length-3 match: only from the 3-byte table's one entry. A 4-byte match would have updated the
            // 3-byte table too, so an empty entry means none of either.
            guard node3 > cutoff else { return (bestLength, 0) }
            let sequence = load32(buffer, position)
            if bestLength < 3 && load32(buffer, base &+ node3) & 0xFF_FFFF == sequence & 0xFF_FFFF {
                bestLength = 3
                bestCandidate = base &+ node3
            }
            guard node4 > cutoff else { return (bestLength, position &- bestCandidate) }
            // The first 4-byte match.
            while load32(buffer, base &+ node4) != sequence {
                node4 = Int(chains[node4 & windowMask])
                remaining &-= 1
                guard node4 > cutoff && remaining > 0 else { return (bestLength, position &- bestCandidate) }
            }
            bestCandidate = base &+ node4
            bestLength = extend(buffer, position, bestCandidate, from: 4, maxLength: maxLength)
            guard bestLength < niceLength else { return (bestLength, position &- bestCandidate) }
            node4 = Int(chains[node4 & windowMask])
            remaining &-= 1
            guard node4 > cutoff && remaining > 0 else { return (bestLength, position &- bestCandidate) }
        } else {
            guard node4 > cutoff && bestLength < niceLength else { return (bestLength, 0) }
        }
        // Longer matches: a candidate is worth extending only if it agrees at the byte that would make it
        // longer (checked with the 4 bytes ending there) and at the start.
        let head = load32(buffer, position)
        while true {
            let candidate = base &+ node4
            if load32(buffer, candidate &+ bestLength &- 3) == load32(buffer, position &+ bestLength &- 3)
                && load32(buffer, candidate) == head {
                let length = extend(buffer, position, candidate, from: 4, maxLength: maxLength)
                if length > bestLength {
                    bestLength = length
                    bestCandidate = candidate
                    if bestLength >= niceLength { break }
                }
            }
            node4 = Int(chains[node4 & windowMask])
            remaining &-= 1
            guard node4 > cutoff && remaining > 0 else { break }
        }
        return (bestLength, bestCandidate == position ? 0 : position &- bestCandidate)
    }

    /// Inserts `count` positions from `position` without searching (libdeflate's
    /// `hc_matchfinder_skip_bytes`), if 5 bytes remain after them for their hashes.
    @inline(__always)
    static func skip(
        _ buffer: RawSpan, _ position: Int, count: Int, dataEnd: Int,
        _ hash3: inout MutableSpan<Int16>, _ hash4: inout MutableSpan<Int16>, _ chains: inout MutableSpan<Int16>,
        _ state: inout ChainState
    ) {
        guard count > 0 && count &+ 5 <= dataEnd &- position else { return }
        var current = position &- state.base
        var inserted = position
        var h3 = state.nextHash3
        var h4 = state.nextHash4
        for _ in 0..<count {
            while current >= windowSize {
                rebase(&hash3)
                rebase(&hash4)
                rebase(&chains)
                state.base &+= windowSize
                current &-= windowSize
            }
            hash3[h3 & ((1 << hash3Bits) &- 1)] = Int16(truncatingIfNeeded: current)
            chains[current & (windowSize &- 1)] = hash4[h4 & ((1 << hash4Bits) &- 1)]
            hash4[h4 & ((1 << hash4Bits) &- 1)] = Int16(truncatingIfNeeded: current)
            inserted &+= 1
            current &+= 1
            let next = load32(buffer, inserted)
            h3 = hash(next & 0xFF_FFFF, bits: hash3Bits)
            h4 = hash(next, bits: hash4Bits)
        }
        state.nextHash3 = h3
        state.nextHash4 = h4
    }

    /// Greedy parsing: take the longest match at each position (libdeflate's levels 2–4).
    @inline(never)
    static func parseGreedy(
        _ buffer: RawSpan, _ start: Int, _ blockEnd: Int, _ dataEnd: Int, _ parameters: DeflateLevelParameters,
        _ minimumMatch: Int, _ lengthSlots: InlineArray<259, UInt8>,
        _ hash3: inout MutableSpan<Int16>, _ hash4: inout MutableSpan<Int16>, _ chains: inout MutableSpan<Int16>,
        _ sequences: inout MutableSpan<UInt64>, _ state: inout ChainState
    ) -> Int {
        var position = start
        let depth = parameters.maxSearchDepth
        repeat {
            let maxLength = min(Deflate.maximumMatch, dataEnd &- position)
            let niceLength = min(parameters.niceLength, maxLength)
            let (length, distance) = longestMatch(
                buffer, position, bestLength: minimumMatch &- 1, maxLength: maxLength, niceLength: niceLength,
                depth: depth, &hash3, &hash4, &chains, &state
            )
            // A 3-byte match far away costs about as much as its literals.
            if length >= minimumMatch && (length > 3 || distance <= 4096) {
                state.match(length: length, distance: distance, lengthSlots, &sequences)
                skip(buffer, position &+ 1, count: length &- 1, dataEnd: dataEnd, &hash3, &hash4, &chains, &state)
                position &+= length
            } else {
                state.literal(byte(buffer, position))
                position &+= 1
            }
        } while position < blockEnd && state.count < maximumSequences
            && !state.split.shouldEndBlock(blockStart: start, position: position, end: dataEnd)
        return position
    }

    /// Lazy parsing: before taking a match, look for a better one at the next position (and with `lazy2`,
    /// the one after), weighing a longer length against a farther distance (libdeflate's levels 5–9).
    @inline(never)
    static func parseLazy(
        _ buffer: RawSpan, _ start: Int, _ blockEnd: Int, _ dataEnd: Int, _ parameters: DeflateLevelParameters,
        _ minimumMatch: Int, _ lengthSlots: InlineArray<259, UInt8>, lazy2: Bool,
        _ hash3: inout MutableSpan<Int16>, _ hash4: inout MutableSpan<Int16>, _ chains: inout MutableSpan<Int16>,
        _ sequences: inout MutableSpan<UInt64>, _ state: inout ChainState
    ) -> Int {
        var position = start
        let depth = parameters.maxSearchDepth
        repeat {
            var maxLength = min(Deflate.maximumMatch, dataEnd &- position)
            var niceLength = min(parameters.niceLength, maxLength)
            var (length, distance) = longestMatch(
                buffer, position, bestLength: minimumMatch &- 1, maxLength: maxLength, niceLength: niceLength,
                depth: depth, &hash3, &hash4, &chains, &state
            )
            if length < minimumMatch || (length == 3 && distance > 8192) {
                state.literal(byte(buffer, position))
                position &+= 1
                continue
            }
            position &+= 1
            // A match at the position before `position`.
            while true {
                if length >= niceLength {
                    state.match(length: length, distance: distance, lengthSlots, &sequences)
                    skip(buffer, position, count: length &- 1, dataEnd: dataEnd, &hash3, &hash4, &chains, &state)
                    position &+= length &- 1
                    break
                }
                // Half the depth for the lookahead: the first search matters more.
                maxLength = min(Deflate.maximumMatch, dataEnd &- position)
                niceLength = min(parameters.niceLength, maxLength)
                let (nextLength, nextDistance) = longestMatch(
                    buffer, position, bestLength: length &- 1, maxLength: maxLength, niceLength: niceLength,
                    depth: depth &>> 1, &hash3, &hash4, &chains, &state
                )
                position &+= 1
                if nextLength >= length && 4 &* (nextLength &- length) &+ (log2(distance) &- log2(nextDistance)) > 2 {
                    state.literal(byte(buffer, position &- 2))
                    length = nextLength
                    distance = nextDistance
                    continue
                }
                if lazy2 {
                    maxLength = min(Deflate.maximumMatch, dataEnd &- position)
                    niceLength = min(parameters.niceLength, maxLength)
                    let (thirdLength, thirdDistance) = longestMatch(
                        buffer, position, bestLength: length &- 1, maxLength: maxLength, niceLength: niceLength,
                        depth: depth &>> 2, &hash3, &hash4, &chains, &state
                    )
                    position &+= 1
                    if thirdLength >= length && 4 &* (thirdLength &- length) &+ (log2(distance) &- log2(thirdDistance)) > 6 {
                        state.literal(byte(buffer, position &- 3))
                        state.literal(byte(buffer, position &- 2))
                        length = thirdLength
                        distance = thirdDistance
                        continue
                    }
                    state.match(length: length, distance: distance, lengthSlots, &sequences)
                    if length > 3 {
                        skip(buffer, position, count: length &- 3, dataEnd: dataEnd, &hash3, &hash4, &chains, &state)
                        position &+= length &- 3
                    }
                } else {
                    state.match(length: length, distance: distance, lengthSlots, &sequences)
                    skip(buffer, position, count: length &- 2, dataEnd: dataEnd, &hash3, &hash4, &chains, &state)
                    position &+= length &- 2
                }
                break
            }
        } while position < blockEnd && state.count < maximumSequences
            && !state.split.shouldEndBlock(blockStart: start, position: position, end: dataEnd)
        return position
    }

    // MARK: - Writing blocks

    /// Writes stored blocks for `buffer[start..<end]` (at most 65,535 bytes each).
    private mutating func writeStoredBlock(_ buffer: RawSpan, from start: Int, to end: Int, isFinal: Bool) {
        // Unsafe: unchecked flushes. Safe: the block's worst case, which stored data is, fits (`hasRoom`, as the
        // file's comment says).
        withWriter { writer in
            var offset = start
            repeat {
                let count = min(end &- offset, 65535)
                let last = offset &+ count == end
                writer.add(isFinal && last ? 1 : 0, bitCount: 3) // BFINAL, BTYPE 00
                writer.alignToByte()
                writer.add(UInt64(count) | UInt64(~count & 0xFFFF) &<< 16, bitCount: 32)
                unsafe writer.unsafeFlush()
                writer.write(buffer.extracting(offset..<(offset &+ count)))
                offset &+= count
            } while offset < end
        }
    }

    /// Writes the block just parsed, as whichever of stored, fixed, or dynamic Huffman is smallest.
    private mutating func writeBlock(_ buffer: RawSpan, from start: Int, to end: Int, isFinal: Bool) {
        frequencies.literalLength[256] = 1 // The end-of-block code.

        // Dynamic codes: literal/lengths limited to 14 bits (as libdeflate: more codes per bit flush),
        // distances to 15.
        do {
            var literalLengths = codes.literalLengthLengths.mutableSpan
            var literalCodewords = codes.literalLengthCodewords.mutableSpan
            HuffmanCodeBuilder.build(
                frequencies: frequencies.literalLength.span.extracting(0..<286), maximumLength: 14,
                lengths: &literalLengths, codewords: &literalCodewords
            )
            literalLengths[286] = 0
            literalLengths[287] = 0
            var distanceLengths = codes.distanceLengths.mutableSpan
            var distanceCodewords = codes.distanceCodewords.mutableSpan
            HuffmanCodeBuilder.build(
                frequencies: frequencies.distance.span.extracting(0..<30), maximumLength: 15,
                lengths: &distanceLengths, codewords: &distanceCodewords
            )
            distanceLengths[30] = 0
            distanceLengths[31] = 0
        }
        let header = DynamicHeader(literalLengths: codes.literalLengthLengths.span, distanceLengths: codes.distanceLengths.span)

        // Costs in bits, each with the 3-bit block header.
        var extraBits = 0
        for slot in 0..<29 {
            extraBits &+= Int(frequencies.literalLength[257 &+ slot]) &* Int(Deflate.lengthExtraBits[slot])
        }
        for slot in 0..<30 {
            extraBits &+= Int(frequencies.distance[slot]) &* Int(Deflate.distanceExtraBits[slot])
        }
        var dynamicCost = 3 &+ header.bitCount &+ extraBits
        var fixedCost = 3 &+ extraBits
        do {
            let literalFrequencies = frequencies.literalLength.span
            let dynamicLengths = codes.literalLengthLengths.span
            let fixedLengths = fixedCodes.literalLengthLengths.span
            for symbol in 0..<286 {
                let frequency = Int(literalFrequencies[symbol])
                dynamicCost &+= frequency &* Int(dynamicLengths[symbol])
                fixedCost &+= frequency &* Int(fixedLengths[symbol])
            }
            let distanceFrequencies = frequencies.distance.span
            let distanceLengths = codes.distanceLengths.span
            for symbol in 0..<30 {
                let frequency = Int(distanceFrequencies[symbol])
                dynamicCost &+= frequency &* Int(distanceLengths[symbol])
                fixedCost &+= frequency &* 5
            }
        }
        let length = end &- start
        let storedCost = (length / 65535 &+ 1) &* (3 &+ 7 &+ 32) &+ 8 &* length

        if storedCost < min(dynamicCost, fixedCost) {
            writeStoredBlock(buffer, from: start, to: end, isFinal: isFinal)
            return
        }
        let useDynamic = dynamicCost < fixedCost
        let blockCodes = useDynamic ? codes : fixedCodes
        // Each match length's code and extra bits, combined: one table load and one add per match.
        var lengthCodes = InlineArray<259, UInt32>(repeating: 0)
        var lengthBits = InlineArray<259, UInt8>(repeating: 0)
        do {
            // Spans, not the fields: indexing an `InlineArray` field of a struct copies the whole array.
            let slots = lengthSlots.span
            let codewords = blockCodes.literalLengthCodewords.span
            let lengths = blockCodes.literalLengthLengths.span
            let bases = Deflate.lengthBases
            let extraBits = Deflate.lengthExtraBits
            for length in 3...258 {
                let slot = Int(slots[length])
                let codeLength = Int(lengths[257 &+ slot])
                let extra = UInt32(length &- Int(bases[slot]))
                lengthCodes[length] = codewords[257 &+ slot] | extra &<< UInt32(codeLength)
                lengthBits[length] = UInt8(codeLength &+ Int(extraBits[slot]))
            }
        }
        // The writer over `staging` while `sequences` is read: two stored properties, so both can be borrowed
        // (`withWriter` would claim all of `self`).
        var span = staging.mutableSpan
        var writer = BitWriter(MutableRawSpan(mutating: &span), byteOffset: stagingEnd, bits: pendingBits, bitCount: pendingBitCount)
        writer.add((isFinal ? 1 : 0) | (useDynamic ? 0b100 : 0b010), bitCount: 3)
        if useDynamic {
            header.write(to: &writer)
        }
        Self.writeSequences(
            buffer, from: start, sequences.span.extracting(0..<sequenceCount),
            literalCodewords: blockCodes.literalLengthCodewords.span, literalLengths: blockCodes.literalLengthLengths.span,
            distanceCodewords: blockCodes.distanceCodewords.span, distanceLengths: blockCodes.distanceLengths.span,
            lengthCodes: lengthCodes.span, lengthBits: lengthBits.span, &writer
        )
        stagingEnd = writer.byteOffset
        pendingBits = writer.pendingBits
        pendingBitCount = writer.pendingBitCount
    }

    /// Writes a block's sequences and its end-of-block code.
    ///
    /// The codes come as spans: reading an `InlineArray` field of a struct parameter here copied the whole
    /// array (1.4 KB) for every literal, half of level 1's time.
    @inline(never)
    static func writeSequences(
        _ buffer: RawSpan, from start: Int, _ sequences: Span<UInt64>,
        literalCodewords: Span<UInt32>, literalLengths: Span<UInt8>,
        distanceCodewords: Span<UInt32>, distanceLengths: Span<UInt8>,
        lengthCodes: Span<UInt32>, lengthBits: Span<UInt8>, _ writer: inout BitWriter
    ) {
        // Unsafe: unchecked flushes. Safe: the writer is the staging buffer's, checked by `hasRoom` for the
        // block's worst case before the block began (see the file's comment).
        precondition(literalCodewords.count == 288 && literalLengths.count == 288 && distanceCodewords.count == 32
            && distanceLengths.count == 32 && lengthCodes.count == 259 && lengthBits.count == 259)
        var position = start
        for index in sequences.indices {
            let sequence = sequences[index]
            var run = Int(truncatingIfNeeded: sequence & 0xFFFF_FFFF)
            let length = Int(truncatingIfNeeded: sequence &>> 32 & 0x1FF)
            let distance = Int(truncatingIfNeeded: sequence &>> 48)
            // Literals, four per flush (14 bits each at most).
            while run >= 4 {
                for offset in 0..<4 {
                    let literal = Int(byte(buffer, position &+ offset))
                    writer.add(UInt64(literalCodewords[literal]), bitCount: Int(literalLengths[literal]))
                }
                unsafe writer.unsafeFlush()
                position &+= 4
                run &-= 4
            }
            while run > 0 {
                let literal = Int(byte(buffer, position))
                writer.add(UInt64(literalCodewords[literal]), bitCount: Int(literalLengths[literal]))
                position &+= 1
                run &-= 1
            }
            unsafe writer.unsafeFlush()
            guard length != 0 else { continue }
            // A match: the length's code and extra bits from the table, then the distance's, at most 48 bits.
            writer.add(UInt64(lengthCodes[length]), bitCount: Int(lengthBits[length]))
            let slot = distanceSlot(distance)
            let extraBits = slot < 4 ? 0 : (slot &>> 1) &- 1
            let base = slot < 4 ? slot &+ 1 : ((2 | slot & 1) &<< extraBits) &+ 1
            writer.add(UInt64(distanceCodewords[slot]) | UInt64(distance &- base) &<< UInt64(distanceLengths[slot]),
                       bitCount: Int(distanceLengths[slot]) &+ extraBits)
            unsafe writer.unsafeFlush()
            position &+= length
        }
        writer.add(UInt64(literalCodewords[256]), bitCount: Int(literalLengths[256]))
        unsafe writer.unsafeFlush()
    }
}

/// A dynamic block's header: the code lengths, run-length coded with the code-length alphabet (RFC 1951,
/// 3.2.7), and that alphabet's own code.
struct DynamicHeader {
    /// Literal/length codes sent (257–286) and distance codes (1–30).
    var literalCount = 257
    var distanceCount = 1
    /// Code-length codes sent, in the permuted order (4–19).
    var codeLengthCount = 4
    /// The run-length items: symbol in bits 0–4, extra bits' value above.
    var items = InlineArray<320, UInt16>(repeating: 0)
    var itemCount = 0
    var codeLengthLengths = InlineArray<19, UInt8>(repeating: 0)
    var codeLengthCodewords = InlineArray<19, UInt32>(repeating: 0)
    /// The header's size in bits, after the block type.
    var bitCount = 0

    /// Built from spans of the codes, into locals, then stored: indexing `InlineArray` fields of structs (a
    /// parameter's, or `self`'s from a nested function) copied the whole array per access, 230 copies per
    /// block.
    init(literalLengths: Span<UInt8>, distanceLengths: Span<UInt8>) {
        var literalCount = 286
        while literalCount > 257 && literalLengths[literalCount &- 1] == 0 {
            literalCount &-= 1
        }
        var distanceCount = 30
        while distanceCount > 1 && distanceLengths[distanceCount &- 1] == 0 {
            distanceCount &-= 1
        }
        self.literalCount = literalCount
        self.distanceCount = distanceCount
        // All lengths in one sequence.
        var lengths = InlineArray<316, UInt8>(repeating: 0)
        for symbol in 0..<literalCount {
            lengths[symbol] = literalLengths[symbol]
        }
        for symbol in 0..<distanceCount {
            lengths[literalCount &+ symbol] = distanceLengths[symbol]
        }
        let total = literalCount &+ distanceCount
        var frequencies = InlineArray<19, UInt32>(repeating: 0)
        var items = InlineArray<320, UInt16>(repeating: 0)
        var itemCount = 0
        var runStart = 0
        func emit(_ symbol: Int, extra: Int = 0) {
            frequencies[symbol] &+= 1
            items[itemCount] = UInt16(symbol | extra &<< 5)
            itemCount &+= 1
        }
        repeat {
            let length = lengths[runStart]
            var runEnd = runStart &+ 1
            while runEnd < total && lengths[runEnd] == length {
                runEnd &+= 1
            }
            if length == 0 {
                while runEnd &- runStart >= 11 {
                    let extra = min(runEnd &- runStart &- 11, 127)
                    emit(18, extra: extra)
                    runStart &+= 11 &+ extra
                }
                if runEnd &- runStart >= 3 {
                    let extra = min(runEnd &- runStart &- 3, 7)
                    emit(17, extra: extra)
                    runStart &+= 3 &+ extra
                }
            } else if runEnd &- runStart >= 4 {
                emit(Int(length))
                runStart &+= 1
                repeat {
                    let extra = min(runEnd &- runStart &- 3, 3)
                    emit(16, extra: extra)
                    runStart &+= 3 &+ extra
                } while runEnd &- runStart >= 3
            }
            while runStart < runEnd {
                emit(Int(length))
                runStart &+= 1
            }
        } while runStart < total

        var codeLengthLengths = InlineArray<19, UInt8>(repeating: 0)
        var codeLengthCodewords = InlineArray<19, UInt32>(repeating: 0)
        do {
            var codeLengths = codeLengthLengths.mutableSpan
            var codewords = codeLengthCodewords.mutableSpan
            HuffmanCodeBuilder.build(frequencies: frequencies.span, maximumLength: 7, lengths: &codeLengths, codewords: &codewords)
        }
        let order = Deflate.codeLengthOrder
        var codeLengthCount = 19
        while codeLengthCount > 4 && codeLengthLengths[Int(order[codeLengthCount &- 1])] == 0 {
            codeLengthCount &-= 1
        }
        var bitCount = 5 &+ 5 &+ 4 &+ 3 &* codeLengthCount
        for symbol in 0..<19 {
            bitCount &+= Int(frequencies[symbol]) &* Int(codeLengthLengths[symbol])
        }
        bitCount &+= 2 &* Int(frequencies[16]) &+ 3 &* Int(frequencies[17]) &+ 7 &* Int(frequencies[18])
        self.items = items
        self.itemCount = itemCount
        self.codeLengthLengths = codeLengthLengths
        self.codeLengthCodewords = codeLengthCodewords
        self.codeLengthCount = codeLengthCount
        self.bitCount = bitCount
    }

    /// Writes the header after the block type.
    func write(to writer: inout BitWriter) {
        // Unsafe: unchecked flushes. Safe: a dynamic header is part of its block's worst case, which the staging
        // buffer was checked for (`DeflateCompressor.hasRoom`).
        writer.add(UInt64(literalCount &- 257) | UInt64(distanceCount &- 1) &<< 5 | UInt64(codeLengthCount &- 4) &<< 10, bitCount: 14)
        unsafe writer.unsafeFlush()
        let order = Deflate.codeLengthOrder
        let lengths = codeLengthLengths.span
        let codewords = codeLengthCodewords.span
        let items = items.span
        for index in 0..<codeLengthCount {
            writer.add(UInt64(lengths[Int(order[index])]), bitCount: 3)
            if index % 16 == 15 { unsafe writer.unsafeFlush() }
        }
        unsafe writer.unsafeFlush()
        for index in 0..<itemCount {
            let item = Int(items[index])
            let symbol = item & 0x1F
            writer.add(UInt64(codewords[symbol]), bitCount: Int(lengths[symbol]))
            switch symbol {
            case 16: writer.add(UInt64(item &>> 5), bitCount: 2)
            case 17: writer.add(UInt64(item &>> 5), bitCount: 3)
            case 18: writer.add(UInt64(item &>> 5), bitCount: 7)
            default: break
            }
            unsafe writer.unsafeFlush()
        }
    }
}
