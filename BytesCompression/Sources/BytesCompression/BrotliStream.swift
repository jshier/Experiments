internal import Bytes

/// A meta-block's prefix codes, packed in one arena: each tree's root table (8-bit index), then its
/// subtables. Entries: bits 0–4 the code length (a subtable's index width, for links), bits 5–6 the kind
/// (0 symbol, 1 subtable link, 2 invalid), bits 8–31 the symbol (a link's offset from the tree's start).
///
/// The arena only grows, and is kept across streams: after the first, reading codes allocates nothing. It's allocated
/// uninitialized: every entry a decode reads was written by the table it's in (each tree is built before a symbol is
/// decoded with it, and `HuffmanTable.build` writes every entry of a complete code's root and subtables; a
/// single-symbol code writes its root), so making a decoder touches none of it (RESULTS.md, 2026-11-24).
@safe
struct BrotliPrefixCodes: ~Copyable {
    private var arena: UninitializedBuffer<UInt32>
    private var used = 0
    /// Scratch for reading a code, kept so nothing is zeroed per code: the used symbols in value order, their
    /// lengths, and the symbols in canonical order.
    private var readSymbols: UniqueArray<UInt16>
    private var readLengths: UniqueArray<UInt8>
    private var sortedSymbols: UniqueArray<UInt16>
    static var rootBits: Int { 8 }

    init() {
        arena = UninitializedBuffer(count: 64 << 10)
        readSymbols = UniqueArray(repeating: 0, count: 704)
        readLengths = UniqueArray(repeating: 0, count: 704)
        sortedSymbols = UniqueArray(repeating: 0, count: 704)
    }

    /// Forgets the codes, for the next meta-block.
    mutating func removeAll() {
        used = 0
    }

    /// The arena's entries in use: a mark to drop the tables built after it (``removeAll(after:)``).
    var mark: Int { used }

    /// Drops the tables built since `mark`: a part of a header that ran past the input's end, read again later.
    mutating func removeAll(after mark: Int) {
        used = mark
    }

    /// Decodes a symbol with the tree at `tree`. 15 bits must be buffered.
    @inline(__always)
    func decode(_ bits: inout BitBuffer, tree: Int) -> Int {
        Self.decode(&bits, table: arena.span, tree: tree)
    }

    /// The arena, for decoding many symbols without re-borrowing it each time.
    var table: Span<UInt32> {
        @_lifetime(borrow self)
        get { arena.span }
    }

    /// Decodes a symbol with the tree at `tree` in `table`. 15 bits must be buffered.
    @inline(__always)
    static func decode(_ bits: inout BitBuffer, table: Span<UInt32>, tree: Int) -> Int {
        var entry = table[tree &+ Int(truncatingIfNeeded: bits.bits & 0xFF)]
        if entry & 0x60 == 0x20 {
            let index = Int(truncatingIfNeeded: bits.bits &>> 8) & ((1 &<< Int(entry & 0x1F)) &- 1)
            entry = table[tree &+ Int(entry &>> 8) &+ index]
        }
        bits.consume(bitCount: Int(entry & 0x1F))
        return Int(entry &>> 8)
    }

    /// Reads a prefix code (RFC 7932, 3.4 and 3.5) and builds its table at the end of the arena.
    ///
    /// - Returns: The table's offset in the arena.
    /// - Throws: ``BytesError/invalidValue`` for an invalid code. Past the end of the input, zeros are read and
    ///   the caller checks for the overrun.
    mutating func read(_ bits: inout BitBuffer, alphabetSize: Int) throws(BytesError) -> Int32 {
        var counts = InlineArray<17, Int>(repeating: 0)
        var symbolCount = 0
        bits.refill()
        let skip = Int(bits.read(bitCount: 2))
        var singleSymbol = -1
        if skip == 1 {
            // Simple: 1 to 4 symbols with fixed lengths.
            var alphabetBits = 0
            while (1 &<< alphabetBits) < alphabetSize {
                alphabetBits &+= 1
            }
            let count = Int(bits.read(bitCount: 2)) &+ 1
            var symbols = InlineArray<4, Int>(repeating: 0)
            for index in 0..<count {
                bits.refill()
                let symbol = Int(bits.read(bitCount: alphabetBits))
                guard symbol < alphabetSize || bits.isOverrun else { throw .invalidValue }
                symbols[index] = min(symbol, alphabetSize &- 1)
                for other in 0..<index where symbols[other] == symbols[index] && !bits.isOverrun {
                    throw .invalidValue
                }
            }
            var lengths = InlineArray<4, Int>(repeating: 0)
            switch count {
            case 1:
                singleSymbol = symbols[0]
            case 2:
                lengths = [1, 1, 0, 0]
            case 3:
                lengths = [1, 2, 2, 0]
            default:
                lengths = bits.read(bitCount: 1) == 0 ? [2, 2, 2, 2] : [1, 2, 3, 3]
            }
            if count > 1 {
                // Canonical order, by length then value: an insertion sort of at most four keys.
                var keys = InlineArray<4, Int>(repeating: 0)
                for index in 0..<count {
                    var slot = index
                    let key = lengths[index] &<< 16 | symbols[index]
                    while slot > 0 && keys[slot &- 1] > key {
                        keys[slot] = keys[slot &- 1]
                        slot &-= 1
                    }
                    keys[slot] = key
                }
                var sorted = sortedSymbols.mutableSpan
                for index in 0..<count {
                    sorted[index] = UInt16(truncatingIfNeeded: keys[index])
                    counts[keys[index] &>> 16] &+= 1
                }
                symbolCount = count
            }
        } else {
            var symbols = readSymbols.mutableSpan
            var lengths = readLengths.mutableSpan
            symbolCount = try Self.readComplexCodeLengths(
                &bits, skip: skip, alphabetSize: alphabetSize, symbols: &symbols, lengths: &lengths, counts: &counts
            )
            // A counting sort of the used symbols, read in value order, into canonical order.
            var offsets = InlineArray<17, Int>(repeating: 0)
            for length in 1..<16 {
                offsets[length &+ 1] = offsets[length] &+ counts[length]
            }
            let readSymbols = readSymbols.span
            let readLengths = readLengths.span
            var sorted = sortedSymbols.mutableSpan
            for index in 0..<symbolCount {
                let length = Int(readLengths[index]) & 0xF
                sorted[offsets[length]] = readSymbols[index]
                offsets[length] &+= 1
            }
        }
        if bits.isOverrun {
            // Truncated: the lengths may not be a valid code, and the caller starts over. A trivial table keeps
            // the arena consistent meanwhile.
            singleSymbol = 0
        }
        // Built at the end of the arena, which grows if needed.
        let capacity = Brotli.maximumTableSize(alphabetSize: alphabetSize)
        if used &+ capacity > arena.count {
            var bigger = UninitializedBuffer<UInt32>(count: max(arena.count &* 2, used &+ capacity))
            do {
                var target = bigger.mutableSpan
                let old = arena.span
                for index in 0..<used {
                    target[index] = old[index]
                }
            }
            arena = bigger
        }
        let offset = used
        var all = arena.mutableSpan
        var table = all._mutatingExtracting(offset..<(offset &+ capacity))
        if singleSymbol >= 0 {
            // One symbol, with a code of no bits.
            for index in 0..<(1 << Self.rootBits) {
                table[index] = UInt32(singleSymbol) &<< 8
            }
            used &+= 1 << Self.rootBits
        } else {
            used &+= try HuffmanTable.build(
                sortedSymbols: sortedSymbols.span.extracting(0..<symbolCount), counts: counts,
                bitOrder: .leastSignificantFirst, rootBits: Self.rootBits, maximumCodeLength: 15,
                allowingIncomplete: false, into: &table, invalid: 2 &<< 5,
                symbol: { symbol, length in UInt32(truncatingIfNeeded: length | symbol &<< 8) },
                subtable: { offset, bits in UInt32(truncatingIfNeeded: bits | offset &<< 8) | 1 &<< 5 }
            )
        }
        return Int32(truncatingIfNeeded: offset)
    }

    /// Reads a complex prefix code's code lengths: the code-length code's lengths in a fixed order, then the
    /// symbols' lengths with repeat codes 16 (the last nonzero length) and 17 (zeros). Collects only the
    /// used symbols, in value order, with their lengths, and counts each length; runs of zeros cost nothing.
    ///
    /// - Returns: The number of used symbols.
    private static func readComplexCodeLengths(
        _ bits: inout BitBuffer, skip: Int, alphabetSize: Int,
        symbols: inout MutableSpan<UInt16>, lengths: inout MutableSpan<UInt8>, counts: inout InlineArray<17, Int>
    ) throws(BytesError) -> Int {
        var codeLengthLengths = InlineArray<18, UInt8>(repeating: 0)
        var space = 32
        var codes = 0
        for index in skip..<18 {
            bits.refill()
            let peek = Int(bits.peek(bitCount: 4))
            let value = Brotli.codeLengthPrefixValues[peek]
            bits.consume(bitCount: Int(Brotli.codeLengthPrefixLengths[peek]))
            codeLengthLengths[Int(Brotli.codeLengthOrder[index])] = value
            if value != 0 {
                space &-= 32 &>> Int(value)
                codes &+= 1
                if space <= 0 { break }
            }
        }
        if bits.isOverrun { return 0 }
        guard codes == 1 || space == 0 else { throw .invalidValue }
        // The code-length code: codes of at most 5 bits, decoded with a direct 32-entry table.
        var table = InlineArray<32, UInt16>(repeating: 0) // symbol << 8 | length
        if codes == 1 {
            var symbol = 0
            for index in 0..<18 where codeLengthLengths[index] != 0 {
                symbol = index
            }
            for index in 0..<32 {
                table[index] = UInt16(symbol) &<< 8
            }
        } else {
            // Canonical order for 18 symbols on the stack (the code-length form zeroes room for 320).
            var counts = InlineArray<17, Int>(repeating: 0)
            for index in 0..<18 {
                counts[Int(codeLengthLengths[index]) & 7] &+= 1
            }
            counts[0] = 0
            var offsets = InlineArray<8, Int>(repeating: 0)
            for length in 1..<7 {
                offsets[length &+ 1] = offsets[length] &+ counts[length]
            }
            var sorted = InlineArray<18, UInt16>(repeating: 0)
            for index in 0..<18 {
                let length = Int(codeLengthLengths[index]) & 7
                if length != 0 {
                    sorted[offsets[length]] = UInt16(truncatingIfNeeded: index)
                    offsets[length] &+= 1
                }
            }
            var span = table.mutableSpan
            _ = try HuffmanTable.build(
                sortedSymbols: sorted.span.extracting(0..<codes), counts: counts, bitOrder: .leastSignificantFirst,
                rootBits: 5, maximumCodeLength: 5, allowingIncomplete: false, into: &span, invalid: 0,
                symbol: { symbol, length in UInt16(truncatingIfNeeded: symbol &<< 8 | length) },
                subtable: { _, _ in 0 }
            )
        }
        precondition(symbols.count >= alphabetSize && lengths.count >= alphabetSize)
        var used = 0
        var symbol = 0
        var previous: UInt8 = 8
        var repeatCount = 0
        var repeatLength: UInt8 = 0
        var remaining = 32768
        while symbol < alphabetSize && remaining > 0 {
            bits.refill()
            let entry = table[Int(bits.peek(bitCount: 5))]
            bits.consume(bitCount: Int(entry & 0xFF))
            let code = Int(entry &>> 8)
            if code < 16 {
                repeatCount = 0
                if code != 0 {
                    symbols[used] = UInt16(truncatingIfNeeded: symbol)
                    lengths[used] = UInt8(truncatingIfNeeded: code)
                    used &+= 1
                    counts[code] &+= 1
                    previous = UInt8(truncatingIfNeeded: code)
                    remaining &-= 32768 &>> code
                }
                symbol &+= 1
            } else {
                let extraBits = code == 16 ? 2 : 3
                let length: UInt8 = code == 16 ? previous : 0
                if repeatLength != length {
                    repeatCount = 0
                    repeatLength = length
                }
                let old = repeatCount
                if repeatCount > 0 {
                    repeatCount = (repeatCount &- 2) &<< extraBits
                }
                repeatCount &+= Int(bits.read(bitCount: extraBits)) &+ 3
                let delta = repeatCount &- old
                guard symbol &+ delta <= alphabetSize else {
                    if bits.isOverrun { return used }
                    throw .invalidValue
                }
                if length != 0 {
                    for offset in 0..<delta {
                        symbols[used &+ offset] = UInt16(truncatingIfNeeded: symbol &+ offset)
                        lengths[used &+ offset] = length
                    }
                    used &+= delta
                    counts[Int(length)] &+= delta
                    remaining &-= delta &<< (15 &- Int(length))
                }
                symbol &+= delta
            }
            if bits.isOverrun { return used }
        }
        guard remaining == 0 else { throw .invalidValue }
        return used
    }

    /// Reads a block count with the tree at `tree`: up to 15 + 24 bits.
    @inline(__always)
    func readBlockCount(_ bits: inout BitBuffer, tree: Int) -> Int {
        let code = decode(&bits, tree: tree)
        return Int(Brotli.blockCountBases[code]) &+ Int(bits.read(bitCount: Int(Brotli.blockCountExtraBits[code])))
    }
}

/// Block switching for the three categories: literals (0), commands (1), distances (2).
struct BrotliBlocks {
    var typeCounts = InlineArray<3, Int>(repeating: 1)
    var types = InlineArray<3, Int>(repeating: 0)
    var previousTypes = InlineArray<3, Int>(repeating: 1)
    /// Symbols left in each category's current block.
    var lengths = InlineArray<3, Int>(repeating: 1 << 24)
    var typeTrees = InlineArray<3, Int32>(repeating: 0)
    var countTrees = InlineArray<3, Int32>(repeating: 0)

    /// Switches `category` to its next block type: a block-type code and a block count, up to 15 + 15 + 24
    /// bits, read from `window` (the bit buffer's bits after a refill: 56 or more).
    ///
    /// Out of line: rare, and inlined three times it pushed the command loop past the inliner's budget. It
    /// takes the bits by value and returns how many it used, so the caller's bit buffer never has its
    /// address taken: passed `inout` to a call, it lived in memory for the whole loop (stored and reloaded
    /// around every literal, with its bit order tested at run time).
    ///
    /// - Returns: The bits used.
    @inline(never)
    mutating func switchBlock(_ window: UInt64, category: Int, table: Span<UInt32>) -> Int {
        var used = 0
        let code = Self.decode(window, table: table, tree: Int(UInt32(bitPattern: typeTrees[category])), used: &used)
        var type: Int = switch code {
        case 0: previousTypes[category]
        case 1: types[category] &+ 1
        default: code &- 2
        }
        if type >= typeCounts[category] { type &-= typeCounts[category] }
        previousTypes[category] = types[category]
        types[category] = type
        let countCode = Self.decode(window &>> UInt64(used), table: table, tree: Int(UInt32(bitPattern: countTrees[category])), used: &used)
        let extraBits = Int(Brotli.blockCountExtraBits[countCode])
        let extra = Int(truncatingIfNeeded: (window &>> UInt64(used)) & ((1 &<< UInt64(extraBits)) &- 1))
        lengths[category] = Int(Brotli.blockCountBases[countCode]) &+ extra
        return used &+ extraBits
    }

    /// Decodes a symbol from the low bits of `window` with the tree at `tree`, adding its length to `used`.
    @inline(__always)
    static func decode(_ window: UInt64, table: Span<UInt32>, tree: Int, used: inout Int) -> Int {
        var entry = table[tree &+ Int(truncatingIfNeeded: window & 0xFF)]
        if entry & 0x60 == 0x20 {
            let index = Int(truncatingIfNeeded: window &>> 8) & ((1 &<< Int(entry & 0x1F)) &- 1)
            entry = table[tree &+ Int(entry &>> 8) &+ index]
        }
        used &+= Int(entry & 0x1F)
        return Int(entry &>> 8)
    }
}

/// A Brotli stream's state, tables, and context maps, decoding into whatever buffer it's given.
@safe
struct BrotliStream: ~Copyable {
    private var codes = BrotliPrefixCodes()
    /// Each literal, command, and distance tree's offset in the codes' arena.
    private var literalTrees: UniqueArray<Int32>
    private var commandTrees: UniqueArray<Int32>
    private var distanceTrees: UniqueArray<Int32>
    /// For each literal block type whose 64 contexts all map to one tree, that tree's offset; -1 otherwise.
    private var trivialLiteralTrees: UniqueArray<Int32>
    private var blocks = BrotliBlocks()

    /// The literal context map (64 entries per block type) and the distance context map (4 per block type). Zeroed: as
    /// an `UninitializedBuffer`, the literal map (16 KB) saved its fill but the fast loop ran up to 0.4% more
    /// instructions on Brotli's decode rows (RESULTS.md, 2026-11-24, E1).
    private var literalContextMap: UniqueArray<UInt8>
    private var distanceContextMap: UniqueArray<UInt8>
    /// Each literal block type's context mode, times 512: the offset of its lookup table.
    private var contextModes: UniqueArray<UInt16>

    enum Stage {
        case streamHeader
        case metablockHeader
        case metadata(remaining: Int)
        case uncompressed(remaining: Int)
        case compressedHeader
        case commands
        case done
    }

    private(set) var stage = Stage.streamHeader
    /// Bits of the next call's first input byte already consumed.
    var bitOffset = 0
    /// The window size the stream declared: how far back a copy may reach.
    private(set) var windowSize = (1 << 16) &- 16
    /// Bytes decoded since the stream's start.
    private var position = 0
    private var isLastMetablock = false
    /// Bytes left in the current meta-block.
    private var metablockRemaining = 0

    private var postfixBits = 0
    private var directCodes = 0
    private var distanceAlphabetSize = 16

    /// The part of a compressed meta-block's header ``readCompressedHeader(_:at:)`` reads next. Each part is read
    /// whole or not at all, and the parts before it stay read: input that arrives a little at a time costs each part
    /// once, and the most input a call needs at once is the largest part (``maximumPartBits``), not the header.
    private enum HeaderPart {
        /// A category's block type count, its block-type and block-count codes, and its first block's count
        /// (categories 0, 1, 2: literals, commands, distances).
        case blockTypes(Int)
        /// The distance parameters, the literal block types' context modes, the literal tree count, and the literal
        /// context map's code.
        case literalMapStart
        /// The literal context map's entries from ``mapIndex``, one at a time.
        case literalMap
        /// The literal context map's move-to-front bit.
        case literalMapEnd
        /// The distance tree count and the distance context map's code.
        case distanceMapStart
        case distanceMap
        case distanceMapEnd
        /// Each tree, one at a time.
        case literalTrees(Int)
        case commandTrees(Int)
        case distanceTrees(Int)
    }

    private var headerPart = HeaderPart.blockTypes(0)
    private var literalTreeCount = 1
    private var distanceTreeCount = 1
    /// The context map being read: its next entry, its code's offset in the arena, and its longest zero-run code.
    private var mapIndex = 0
    private var mapTree = 0
    private var mapMaximumRun = 0

    /// The last four distances, the most recent at `distanceIndex - 1`.
    private var distances = InlineArray<4, Int>(repeating: 0)
    private var distanceIndex = 0

    // The command in progress.
    private enum CommandPhase {
        case start
        case literals
        case distance
        case copy
    }

    private var phase = CommandPhase.start
    private var insertRemaining = 0
    private var copyLength = 0
    private var copyRemaining = 0
    private var copyDistance = 0
    /// The command's distance is the last one, without a distance code (insert-and-copy cells 0 and 1).
    private var implicitDistance = false

    /// Each insert-and-copy symbol's lengths, one load in the fast loop: insert base (bits 0–15), copy base (16–31),
    /// insert extra bits (32–39), copy extra bits (40–47), and bit 48 for an implicit distance. A copy of
    /// `brotliCommandTable`, a literal (RESULTS.md, 2026-11-24): computing it was 79% of making a decoder, and the fast
    /// loop reading the global itself ran 1.1–1.7% more instructions than with this copy.
    private let commandTable: UniqueArray<UInt64>

    /// The command table's derivation, which tests check the literal against.
    static func makeCommandTable() -> [UInt64] {
        var table = [UInt64](repeating: 0, count: 704)
        var span = table.mutableSpan
        for symbol in 0..<704 {
            let cell = symbol &>> 6
            let insertCode = Int(Brotli.cellInsertCodes[cell]) &+ (symbol &>> 3 & 7)
            let copyCode = Int(Brotli.cellCopyCodes[cell]) &+ (symbol & 7)
            span[symbol] = UInt64(Brotli.insertBases[insertCode]) | UInt64(Brotli.copyBases[copyCode]) &<< 16
                | UInt64(Brotli.insertExtraBits[insertCode]) &<< 32 | UInt64(Brotli.copyExtraBits[copyCode]) &<< 40
                | (cell < 2 ? 1 &<< 48 : 0)
        }
        return table
    }

    init() {
        literalTrees = UniqueArray(repeating: 0, count: 256)
        commandTrees = UniqueArray(repeating: 0, count: 256)
        distanceTrees = UniqueArray(repeating: 0, count: 256)
        trivialLiteralTrees = UniqueArray(repeating: -1, count: 256)
        literalContextMap = UniqueArray(repeating: 0, count: 64 &* 256)
        distanceContextMap = UniqueArray(repeating: 0, count: 4 &* 256)
        contextModes = UniqueArray(repeating: 0, count: 256)
        var commands = UniqueArray<UInt64>(repeating: 0, count: 704)
        do {
            var span = commands.mutableSpan
            let source = brotliCommandTable
            for index in 0..<704 {
                span[index] = source[index]
            }
        }
        commandTable = commands
        distances = [16, 15, 11, 4]
    }

    mutating func reset() {
        stage = .streamHeader
        bitOffset = 0
        windowSize = (1 << 16) &- 16
        position = 0
        isLastMetablock = false
        metablockRemaining = 0
        phase = .start
        distances = [16, 15, 11, 4]
        distanceIndex = 0
    }

    var isDone: Bool {
        if case .done = stage { return true }
        return false
    }

    // MARK: - Running

    enum Stop: Equatable {
        case needsInput, outputFull, finished
        /// The careful loop is at a command's start with room again: back to the fast loop (internal to `run`).
        case fastAgain
    }

    /// The fast loop runs while this much input remains at a command's start, and this much output room.
    ///
    /// A command's lengths take at most 117 bits (a block switch, 15 + 15 + 24; the insert-and-copy code, 15;
    /// its extra bits, 24 + 24), leaving 267 of these 384 for its literals, which stop with 128 left (a
    /// literal block switch, 54, comes first): the distance takes at most 93 (a block switch, the code, 15,
    /// and 24 extra bits). 128 bytes kept small streams in the careful loop: most of a 269-byte stream.
    static var fastInput: Int { 48 }
    static var fastRoom: Int { 64 }

    /// Input within which units are checked for overrunning the end: more than any unit needs.
    static var safeInput: Int { 16 }

    /// Decodes from bit `start` of `input` into `output` from `outputStart` until more input is needed, the
    /// output is full, or the stream ends. Bytes before `outputStart` are the latest output (history).
    mutating func run(
        _ input: RawSpan, from start: Int, into output: inout MutableRawSpan, at outputStart: Int
    ) throws(BytesError) -> (position: Int, end: Int, stop: Stop) {
        var bitPosition = start
        var end = outputStart
        let inputBits = input.byteCount &<< 3
        while true {
            switch stage {
            case .done:
                return (bitPosition, end, .finished)
            case .streamHeader:
                var bits = try BitBuffer(input, atBitPosition: bitPosition, bitOrder: .leastSignificantFirst)
                bits.refill()
                let windowBits: Int
                if bits.read(bitCount: 1) == 0 {
                    windowBits = 16
                } else {
                    let n = Int(bits.read(bitCount: 3))
                    if n != 0 {
                        windowBits = 17 &+ n
                    } else {
                        let m = Int(bits.read(bitCount: 3))
                        guard m != 1 else { throw .invalidValue } // Large windows aren't RFC 7932.
                        windowBits = m == 0 ? 17 : 8 &+ m
                    }
                }
                guard bits.bitPosition <= inputBits else { return (bitPosition, end, .needsInput) }
                windowSize = (1 << windowBits) &- 16
                bitPosition = bits.bitPosition
                stage = .metablockHeader
            case .metablockHeader:
                guard try readMetablockHeader(input, at: &bitPosition) else { return (bitPosition, end, .needsInput) }
            case let .metadata(remaining):
                let byteOffset = bitPosition &>> 3
                let count = min(remaining, input.byteCount &- byteOffset)
                bitPosition &+= count &<< 3
                if count < remaining {
                    stage = .metadata(remaining: remaining &- count)
                    return (bitPosition, end, .needsInput)
                }
                stage = isLastMetablock ? .done : .metablockHeader
            case let .uncompressed(remaining):
                let byteOffset = bitPosition &>> 3
                let count = min(min(remaining, input.byteCount &- byteOffset), output.byteCount &- end)
                var writer = try AlignedBytesWriter(&output, atByteOffset: end)
                try writer.write(input.extracting(byteOffset..<(byteOffset &+ count)))
                bitPosition &+= count &<< 3
                end &+= count
                position &+= count
                guard count == remaining else {
                    stage = .uncompressed(remaining: remaining &- count)
                    return (bitPosition, end, end == output.byteCount ? .outputFull : .needsInput)
                }
                stage = .metablockHeader // An uncompressed meta-block is never the last.
            case .compressedHeader:
                guard try readCompressedHeader(input, at: &bitPosition) else { return (bitPosition, end, .needsInput) }
                stage = .commands
                phase = .start
            case .commands:
                var done = false
                if phase == .start && input.byteCount &- (bitPosition &>> 3) >= Self.fastInput && output.byteCount &- end >= Self.fastRoom {
                    let fast = try decodeCommandsFast(input, from: bitPosition, into: &output, at: end)
                    bitPosition = fast.position
                    end = fast.end
                    done = fast.metablockDone
                }
                if !done {
                    let result = try decodeCommands(input, from: bitPosition, into: &output, at: end)
                    bitPosition = result.position
                    end = result.end
                    if result.stop == .fastAgain { continue }
                    guard result.metablockDone else { return (bitPosition, end, result.stop) }
                }
                if isLastMetablock {
                    // The rest of the last byte must be zeros.
                    if bitPosition & 7 != 0 {
                        var bits = try BitBuffer(input, atBitPosition: bitPosition, bitOrder: .leastSignificantFirst)
                        bits.refill()
                        guard bits.read(bitCount: 8 &- bitPosition & 7) == 0 else { throw .invalidValue }
                        guard bits.bitPosition <= inputBits else { return (bitPosition, end, .needsInput) }
                        bitPosition = bits.bitPosition
                    }
                    stage = .done
                } else {
                    stage = .metablockHeader
                }
            }
        }
    }

    // MARK: - Headers

    /// Reads a meta-block header up to its compressed part (or a metadata or uncompressed block's length),
    /// all or nothing.
    private mutating func readMetablockHeader(_ input: RawSpan, at bitPosition: inout Int) throws(BytesError) -> Bool {
        let inputBits = input.byteCount &<< 3
        var bits = try BitBuffer(input, atBitPosition: bitPosition, bitOrder: .leastSignificantFirst)
        bits.refill()
        let isLast = bits.read(bitCount: 1) == 1
        if isLast && bits.read(bitCount: 1) == 1 {
            // ISLASTEMPTY: the stream ends, padded with zeros to a byte.
            let partial = bits.bitPosition & 7
            if partial != 0 { guard bits.read(bitCount: 8 &- partial) == 0 else { throw .invalidValue } }
            guard bits.bitPosition <= inputBits else { return false }
            bitPosition = bits.bitPosition
            stage = .done
            return true
        }
        // Fields are checked only once the header is known to be all there: past the end, zeros are read, and
        // a truncated header isn't an invalid one.
        var invalid = false
        let nibbles = Int(bits.read(bitCount: 2))
        if nibbles == 3 {
            // Metadata: a reserved bit, the skip length's byte count, the length, then padding. Google's decoder
            // accepts metadata as the last meta-block, ending the stream after it, so this does too.
            invalid = bits.read(bitCount: 1) != 0
            let byteCount = Int(bits.read(bitCount: 2))
            var skip = 0
            for index in 0..<byteCount {
                bits.refill()
                let byte = Int(bits.read(bitCount: 8))
                if index == byteCount &- 1 && byteCount > 1 && byte == 0 { invalid = true }
                skip |= byte &<< (8 &* index)
            }
            if byteCount > 0 { skip &+= 1 }
            let partial = bits.bitPosition & 7
            bits.refill()
            if partial != 0 && bits.read(bitCount: 8 &- partial) != 0 { invalid = true }
            guard bits.bitPosition <= inputBits else { return false }
            guard !invalid else { throw .invalidValue }
            bitPosition = bits.bitPosition
            isLastMetablock = isLast
            stage = .metadata(remaining: skip)
            return true
        }
        let nibbleCount = 4 &+ nibbles
        var length = 0
        for index in 0..<nibbleCount {
            let nibble = Int(bits.read(bitCount: 4))
            if index == nibbleCount &- 1 && nibbleCount > 4 && nibble == 0 { invalid = true }
            length |= nibble &<< (4 &* index)
        }
        length &+= 1
        var isUncompressed = false
        if !isLast {
            isUncompressed = bits.read(bitCount: 1) == 1
        }
        if isUncompressed {
            let partial = bits.bitPosition & 7
            bits.refill()
            if partial != 0 && bits.read(bitCount: 8 &- partial) != 0 { invalid = true }
        }
        guard bits.bitPosition <= inputBits else { return false }
        guard !invalid else { throw .invalidValue }
        bitPosition = bits.bitPosition
        isLastMetablock = isLast
        metablockRemaining = length
        if isUncompressed {
            stage = .uncompressed(remaining: length)
        } else {
            stage = .compressedHeader
            headerPart = .blockTypes(0)
            codes.removeAll()
        }
        return true
    }

    /// The most bits a prefix code of `alphabetSize` symbols takes (RFC 7932, 3.4 and 3.5): a complex code's 2-bit
    /// HSKIP and up to 18 code-length code lengths of at most 4 bits, then at most 5 bits a symbol (the code-length
    /// code's longest code; a repeat code's 7 or 8 bits cover at least 3 symbols). A simple code takes at most 45.
    static func maximumPrefixCodeBits(alphabetSize: Int) -> Int { 2 &+ 18 &* 4 &+ 5 &* alphabetSize }

    /// The most bits a part of a compressed header (``HeaderPart``) takes: a command tree's code, 704 symbols, 3,594
    /// bits. The others: a category's block types (11 + codes of up to 258 and 26 symbols + 39 = 1,618), the distance
    /// parameters, context modes, and literal map's start (6 + 512 + 11 + 5 + a code of up to 272 symbols = 1,968), a
    /// context map entry (a 15-bit code and up to 16 run bits), a distance map's start (1,450), a literal tree (1,354),
    /// and a distance tree (up to 520 symbols: 2,674).
    static var maximumPartBits: Int { maximumPrefixCodeBits(alphabetSize: 704) }

    /// Reads a compressed meta-block's header: block types and counts, distance parameters, context modes and
    /// maps, and all its prefix codes.
    ///
    /// It reads a part at a time (``HeaderPart``), each whole: a part that runs past the input's end is read again from
    /// its start on the next call (the tables it built dropped), and the parts before it are kept. So input that
    /// arrives a byte at a time costs each part about its size squared, not the header's, and the most input a call
    /// needs at once is the largest part (``maximumPartBits``).
    ///
    /// - Returns: Whether the header is complete. `bitPosition` is after the last whole part (context map entries are
    ///   parts of their own) either way.
    private mutating func readCompressedHeader(_ input: RawSpan, at bitPosition: inout Int) throws(BytesError) -> Bool {
        var bits = try BitBuffer(input, atBitPosition: bitPosition, bitOrder: .leastSignificantFirst)
        while true {
            // The part's tables, built at the end of the arena, are dropped if it isn't all there.
            let mark = codes.mark
            let next: HeaderPart?
            switch headerPart {
            case let .blockTypes(category):
                bits.refill()
                let count = Self.readVariableLengthUInt8(&bits) &+ 1
                blocks.typeCounts[category] = count
                blocks.types[category] = 0
                blocks.previousTypes[category] = 1
                if count >= 2 {
                    blocks.typeTrees[category] = try codes.read(&bits, alphabetSize: count &+ 2)
                    blocks.countTrees[category] = try codes.read(&bits, alphabetSize: 26)
                    bits.refill()
                    blocks.lengths[category] = codes.readBlockCount(&bits, tree: Int(blocks.countTrees[category]))
                } else {
                    blocks.lengths[category] = 1 << 24
                }
                next = category < 2 ? .blockTypes(category &+ 1) : .literalMapStart
            case .literalMapStart:
                bits.refill()
                postfixBits = Int(bits.read(bitCount: 2))
                directCodes = Int(bits.read(bitCount: 4)) &<< postfixBits
                distanceAlphabetSize = 16 &+ directCodes &+ (48 &<< postfixBits)
                do {
                    var modes = contextModes.mutableSpan
                    for type in 0..<blocks.typeCounts[0] {
                        bits.refill()
                        modes[type] = UInt16(bits.read(bitCount: 2)) &<< 9
                    }
                }
                bits.refill()
                literalTreeCount = Self.readVariableLengthUInt8(&bits) &+ 1
                if try startContextMap(&bits, treeCount: literalTreeCount) {
                    next = .literalMap
                } else {
                    var map = literalContextMap.mutableSpan
                    Self.clear(&map, count: 64 &* blocks.typeCounts[0])
                    next = .distanceMapStart
                }
            case .literalMap:
                var map = literalContextMap.mutableSpan
                let complete = try Self.readContextMapEntries(
                    &bits, index: &mapIndex, size: 64 &* blocks.typeCounts[0], tree: mapTree, maximumRun: mapMaximumRun,
                    table: codes.table, into: &map, position: &bitPosition
                )
                guard complete else { return false }
                next = .literalMapEnd
            case .literalMapEnd:
                var map = literalContextMap.mutableSpan
                guard Self.finishContextMap(&bits, size: 64 &* blocks.typeCounts[0], into: &map) else { return false }
                next = .distanceMapStart
            case .distanceMapStart:
                bits.refill()
                distanceTreeCount = Self.readVariableLengthUInt8(&bits) &+ 1
                if try startContextMap(&bits, treeCount: distanceTreeCount) {
                    next = .distanceMap
                } else {
                    var map = distanceContextMap.mutableSpan
                    Self.clear(&map, count: 4 &* blocks.typeCounts[2])
                    next = .literalTrees(0)
                }
            case .distanceMap:
                var map = distanceContextMap.mutableSpan
                let complete = try Self.readContextMapEntries(
                    &bits, index: &mapIndex, size: 4 &* blocks.typeCounts[2], tree: mapTree, maximumRun: mapMaximumRun,
                    table: codes.table, into: &map, position: &bitPosition
                )
                guard complete else { return false }
                next = .distanceMapEnd
            case .distanceMapEnd:
                var map = distanceContextMap.mutableSpan
                guard Self.finishContextMap(&bits, size: 4 &* blocks.typeCounts[2], into: &map) else { return false }
                next = .literalTrees(0)
            case let .literalTrees(tree):
                let offset = try codes.read(&bits, alphabetSize: 256)
                var trees = literalTrees.mutableSpan
                trees[tree] = offset
                if tree &+ 1 < literalTreeCount {
                    next = .literalTrees(tree &+ 1)
                } else {
                    // Each literal block type whose contexts all use one tree (recomputed if this part is read again).
                    let map = literalContextMap.span
                    var trivial = trivialLiteralTrees.mutableSpan
                    for type in 0..<blocks.typeCounts[0] {
                        let first = map[type &<< 6]
                        var same = true
                        for context in 1..<64 where map[type &<< 6 | context] != first {
                            same = false
                        }
                        trivial[type] = same ? trees[Int(first)] : -1
                    }
                    next = .commandTrees(0)
                }
            case let .commandTrees(tree):
                let offset = try codes.read(&bits, alphabetSize: 704)
                var trees = commandTrees.mutableSpan
                trees[tree] = offset
                next = tree &+ 1 < blocks.typeCounts[1] ? .commandTrees(tree &+ 1) : .distanceTrees(0)
            case let .distanceTrees(tree):
                let offset = try codes.read(&bits, alphabetSize: distanceAlphabetSize)
                var trees = distanceTrees.mutableSpan
                trees[tree] = offset
                next = tree &+ 1 < distanceTreeCount ? .distanceTrees(tree &+ 1) : nil
            }
            guard !bits.isOverrun else {
                codes.removeAll(after: mark)
                return false
            }
            bitPosition = bits.bitPosition
            guard let next else { return true }
            headerPart = next
        }
    }

    /// RFC 7932's VarLenUint8: 0, or 1 through 255 in a prefix of 3 bits and up to 7 more. 11 bits buffered.
    private static func readVariableLengthUInt8(_ bits: inout BitBuffer) -> Int {
        guard bits.read(bitCount: 1) == 1 else { return 0 }
        let n = Int(bits.read(bitCount: 3))
        return n == 0 ? 1 : (1 &<< n) &+ Int(bits.read(bitCount: n))
    }

    /// Zeros a context map's first `count` entries: the map of a single tree, which isn't sent.
    private static func clear(_ map: inout MutableSpan<UInt8>, count: Int) {
        for index in 0..<count {
            map[index] = 0
        }
    }

    /// Starts a context map (RFC 7932, 7.3) of `treeCount` trees: reads its longest zero-run code and its prefix
    /// code, kept for its entries (``mapMaximumRun``, ``mapTree``). With one tree, the map is all zeros and isn't sent.
    ///
    /// - Returns: Whether the map has entries to read.
    private mutating func startContextMap(_ bits: inout BitBuffer, treeCount: Int) throws(BytesError) -> Bool {
        guard treeCount >= 2 else { return false }
        bits.refill()
        mapMaximumRun = bits.read(bitCount: 1) == 1 ? Int(bits.read(bitCount: 4)) &+ 1 : 0
        mapTree = try Int(codes.read(&bits, alphabetSize: treeCount &+ mapMaximumRun))
        mapIndex = 0
        return true
    }

    /// Reads a context map's entries from `index` to `size`, each a part of its own: run-length coded zeros and tree
    /// indices in the code at `tree` (in `table`).
    ///
    /// - Returns: Whether all of them were read. Either way `index` and `position` are after the last whole entry: an
    ///   entry that runs past the input's end is read again on the next call.
    private static func readContextMapEntries(
        _ bits: inout BitBuffer, index: inout Int, size: Int, tree: Int, maximumRun: Int, table: Span<UInt32>,
        into map: inout MutableSpan<UInt8>, position: inout Int
    ) throws(BytesError) -> Bool {
        var current = index
        var committed = position
        while current < size {
            bits.refill()
            let symbol = BrotliPrefixCodes.decode(&bits, table: table, tree: tree)
            var end = current &+ 1
            if symbol == 0 {
                map[current] = 0
            } else if symbol <= maximumRun {
                let run = (1 &<< symbol) &+ Int(bits.read(bitCount: symbol))
                guard current &+ run <= size else {
                    if bits.isOverrun { break } // Truncated: read again with more input.
                    throw .invalidValue
                }
                for offset in current..<(current &+ run) {
                    map[offset] = 0
                }
                end = current &+ run
            } else {
                map[current] = UInt8(truncatingIfNeeded: symbol &- maximumRun)
            }
            if bits.isOverrun { break }
            current = end
            committed = bits.bitPosition
        }
        index = current
        position = committed
        return current == size
    }

    /// Reads a context map's move-to-front bit, and undoes the transform if it's set.
    ///
    /// - Returns: Whether the bit was in the input (the map is unchanged if not).
    private static func finishContextMap(_ bits: inout BitBuffer, size: Int, into map: inout MutableSpan<UInt8>) -> Bool {
        bits.refill()
        let isTransformed = bits.read(bitCount: 1) == 1
        guard !bits.isOverrun else { return false }
        if isTransformed {
            // Inverse move-to-front.
            var order = InlineArray<256, UInt8>(repeating: 0)
            for value in 0..<256 {
                order[value] = UInt8(value)
            }
            for index in 0..<size {
                let position = Int(map[index])
                let value = order[position]
                map[index] = value
                var shift = position
                while shift > 0 {
                    order[shift] = order[shift &- 1]
                    shift &-= 1
                }
                order[0] = value
            }
        }
        return true
    }

    // MARK: - Commands

    /// Decodes the meta-block's commands into `output` from `outputStart`.
    ///
    /// Works in units, each finished or not started: a block switch, a command's insert-and-copy code and
    /// lengths, a literal, a distance, a piece of a copy. While 16 bytes of input remain no unit can run past
    /// the end; within them, each unit is checked afterwards and abandoned (its state untouched) if it did.
    ///
    /// - Returns: The bit position, output end, whether the meta-block is complete, and otherwise why it
    ///   stopped.
    private mutating func decodeCommands(
        _ input: RawSpan, from start: Int, into output: inout MutableRawSpan, at outputStart: Int
    ) throws(BytesError) -> (position: Int, end: Int, metablockDone: Bool, stop: Stop) {
        var bits = try BitBuffer(input, atBitPosition: start, bitOrder: .leastSignificantFirst)
        var writer = try AlignedBytesWriter(&output, atByteOffset: outputStart)
        let inputBits = input.byteCount &<< 3
        let safeBits = Self.safeInput &<< 3
        /// The stream position of `output[0]`.
        let origin = position &- outputStart
        let lookupTable = brotliContextLookup // A local to borrow from: a global's span can't outlive the access.
        let lookup = lookupTable.span
        let literalMap = literalContextMap.span
        let distanceMap = distanceContextMap.span
        let modes = contextModes.span
        let literalTrees = literalTrees.span
        let commandTrees = commandTrees.span
        let distanceTrees = distanceTrees.span
        var stop = Stop.needsInput
        var done = false

        // The literal context's previous two bytes.
        var p1: UInt8 = 0
        var p2: UInt8 = 0
        let written = writer.byteCount
        if written >= 1 { p1 = writer.writtenBytes.load(fromByteOffset: written &- 1, as: UInt8.self) }
        if written >= 2 { p2 = writer.writtenBytes.load(fromByteOffset: written &- 2, as: UInt8.self) }

        units: while true {
            let unitStart = bits.bitPosition
            let checked = inputBits &- unitStart < safeBits
            switch phase {
            case .start:
                if metablockRemaining == 0 {
                    done = true
                    break units
                }
                // Room again (well past the fast loop's thresholds, so the two don't alternate): back to it.
                if inputBits &- unitStart >= 2 &* Self.fastInput &* 8 && writer.remainingByteCount >= 4096 {
                    stop = .fastAgain
                    break units
                }
                bits.refill()
                if blocks.lengths[1] == 0 {
                    // A block switch is a unit of its own.
                    let saved = blocks
                    let used = blocks.switchBlock(bits.bits, category: 1, table: codes.table)
                    bits.consume(bitCount: used)
                    if checked && bits.bitPosition > inputBits {
                        blocks = saved
                        bits = try BitBuffer(input, atBitPosition: unitStart, bitOrder: .leastSignificantFirst)
                        break units
                    }
                    continue
                }
                let symbol = codes.decode(&bits, tree: Int(commandTrees[blocks.types[1]]))
                let cell = symbol &>> 6
                let insertCode = Int(Brotli.cellInsertCodes[cell]) &+ (symbol &>> 3 & 7)
                let copyCode = Int(Brotli.cellCopyCodes[cell]) &+ (symbol & 7)
                bits.refill()
                let insert = Int(Brotli.insertBases[insertCode]) &+ Int(bits.read(bitCount: Int(Brotli.insertExtraBits[insertCode])))
                bits.refill()
                let copy = Int(Brotli.copyBases[copyCode]) &+ Int(bits.read(bitCount: Int(Brotli.copyExtraBits[copyCode])))
                if checked && bits.bitPosition > inputBits {
                    bits = try BitBuffer(input, atBitPosition: unitStart, bitOrder: .leastSignificantFirst)
                    break units
                }
                blocks.lengths[1] &-= 1
                insertRemaining = insert
                copyLength = copy
                implicitDistance = cell < 2
                phase = .literals
            case .literals:
                if insertRemaining == 0 {
                    if metablockRemaining == 0 {
                        // The meta-block ended with the literals: the copy is ignored.
                        phase = .start
                        done = true
                        break units
                    }
                    phase = .distance
                    continue
                }
                guard metablockRemaining > 0 else { throw .invalidValue } // Literals past the meta-block's end.
                guard writer.remainingByteCount >= 1 else {
                    stop = .outputFull
                    break units
                }
                bits.refill()
                if blocks.lengths[0] == 0 {
                    let saved = blocks
                    let used = blocks.switchBlock(bits.bits, category: 0, table: codes.table)
                    bits.consume(bitCount: used)
                    if checked && bits.bitPosition > inputBits {
                        blocks = saved
                        bits = try BitBuffer(input, atBitPosition: unitStart, bitOrder: .leastSignificantFirst)
                        break units
                    }
                    continue
                }
                // Literals: as many as the run, the meta-block, the block, the output, and (when checked) one at a
                // time allow, without leaving the loop.
                let type = blocks.types[0]
                let mode = Int(modes[type])
                let mapBase = type &<< 6
                // Pairwise `min`: with three or more arguments it's variadic, and allocated an array per call.
                let count = checked ? 1 : min(min(insertRemaining, metablockRemaining), min(blocks.lengths[0], writer.remainingByteCount))
                var decoded = 0
                while decoded < count {
                    if !checked && inputBits &- bits.bitPosition < safeBits { break }
                    let literalStart = bits.bitPosition
                    bits.refill()
                    let context = Int(lookup[mode | Int(p1)] | lookup[mode | 256 | Int(p2)])
                    let tree = Int(literalTrees[Int(literalMap[mapBase | context])])
                    let literal = UInt8(truncatingIfNeeded: codes.decode(&bits, tree: tree))
                    if checked && bits.bitPosition > inputBits {
                        bits = try BitBuffer(input, atBitPosition: literalStart, bitOrder: .leastSignificantFirst)
                        break
                    }
                    try writer.write(Byte(truncatingIfNeeded: literal))
                    p2 = p1
                    p1 = literal
                    decoded &+= 1
                }
                insertRemaining &-= decoded
                metablockRemaining &-= decoded
                blocks.lengths[0] &-= decoded
                if checked && decoded == 0 { break units }
            case .distance:
                if implicitDistance {
                    copyDistance = distances[(distanceIndex &- 1) & 3]
                } else {
                    bits.refill()
                    if blocks.lengths[2] == 0 {
                        let saved = blocks
                        let used = blocks.switchBlock(bits.bits, category: 2, table: codes.table)
                        bits.consume(bitCount: used)
                        if checked && bits.bitPosition > inputBits {
                            blocks = saved
                            bits = try BitBuffer(input, atBitPosition: unitStart, bitOrder: .leastSignificantFirst)
                            break units
                        }
                        continue
                    }
                    let context = min(copyLength, 5) &- 2
                    let tree = Int(distanceTrees[Int(distanceMap[blocks.types[2] &<< 2 | context])])
                    let code = codes.decode(&bits, tree: tree)
                    bits.refill()
                    var distance: Int
                    if code < 16 {
                        distance = specialDistance(code)
                    } else if code < 16 &+ directCodes {
                        distance = code &- 15
                    } else {
                        let value = code &- directCodes &- 16
                        let extraBits = 1 &+ (value &>> (postfixBits &+ 1))
                        let high = value &>> postfixBits
                        let low = value & ((1 &<< postfixBits) &- 1)
                        let offset = ((2 &+ (high & 1)) &<< extraBits) &- 4
                        distance = ((offset &+ Int(bits.read(bitCount: extraBits))) &<< postfixBits) &+ low &+ directCodes &+ 1
                    }
                    if checked && bits.bitPosition > inputBits {
                        bits = try BitBuffer(input, atBitPosition: unitStart, bitOrder: .leastSignificantFirst)
                        break units
                    }
                    guard distance > 0 else { throw .invalidValue }
                    blocks.lengths[2] &-= 1
                    // Distance code 0 and dictionary references leave the last distances as they are.
                    if code != 0 && distance <= min(windowSize, origin &+ writer.byteCount) {
                        distances[distanceIndex & 3] = distance
                        distanceIndex &+= 1
                    }
                    copyDistance = distance
                }
                copyRemaining = copyLength
                phase = .copy
            case .copy:
                let maximum = min(windowSize, origin &+ writer.byteCount)
                if copyDistance > maximum {
                    // A static dictionary word, transformed: all at once.
                    guard let count = try Self.writeDictionaryWord(
                        length: copyLength, id: copyDistance &- maximum &- 1, limit: metablockRemaining,
                        to: &writer, p1: &p1, p2: &p2
                    ) else {
                        stop = .outputFull
                        break units
                    }
                    metablockRemaining &-= count
                    phase = .start
                    continue
                }
                guard copyRemaining <= metablockRemaining else { throw .invalidValue }
                let room = writer.remainingByteCount
                guard room > 0 else {
                    stop = .outputFull
                    break units
                }
                let count = min(copyRemaining, room)
                if room >= count &+ AlignedBytesWriter.copyOverrun {
                    try writer.copy(fromDistance: copyDistance, count: count, allowingOverrun: true)
                } else {
                    try writer.copy(fromDistance: copyDistance, count: count)
                }
                copyRemaining &-= count
                metablockRemaining &-= count
                let output = writer.writtenBytes
                p1 = output.load(fromByteOffset: output.byteCount &- 1, as: UInt8.self)
                p2 = output.load(fromByteOffset: output.byteCount &- 2, as: UInt8.self)
                if copyRemaining == 0 { phase = .start }
            }
        }
        position = origin &+ writer.byteCount
        return (bits.bitPosition, writer.byteCount, done, stop)
    }

    /// Decodes whole commands while the input and output have room, with no checks for their ends: Google's
    /// fast path. At least ``fastInput`` bytes of input at each command's start cover its lengths; its
    /// literals are decoded only as far as the input certainly reaches (15 bits each, keeping 128 bits for the
    /// distance); copies only with room for them and the copy's overrun. Otherwise it saves the command's
    /// state and returns, for the careful loop to finish.
    ///
    /// Written for the register allocator: the bit buffer, output position, block state, and last distances
    /// are locals, written back once at the end, and neither the bit buffer nor the output is passed to a
    /// call (a call taking either `inout` keeps it in memory for the whole loop). Table indices are masked
    /// to their tables' sizes, which the preconditions state, so their bounds checks fold away. The literal
    /// context's last two bytes are loaded from the output at each literal run's start rather than tracked
    /// through copies and dictionary words.
    ///
    /// - Returns: The bit position, the output end, and whether the meta-block is complete.
    private mutating func decodeCommandsFast(
        _ input: RawSpan, from start: Int, into output: inout MutableRawSpan, at outputStart: Int
    ) throws(BytesError) -> (position: Int, end: Int, metablockDone: Bool) {
        var bits = try BitBuffer(input, atBitPosition: start, bitOrder: .leastSignificantFirst)
        let inputBits = input.byteCount &<< 3
        let origin = position &- outputStart
        let lookupTable = brotliContextLookup // A local to borrow from: a global's span can't outlive the access.
        let lookup = lookupTable.span
        let literalMap = literalContextMap.span
        let distanceMap = distanceContextMap.span
        let modes = contextModes.span
        let literalTrees = literalTrees.span
        let trivialTrees = trivialLiteralTrees.span
        let commandTrees = commandTrees.span
        let distanceTrees = distanceTrees.span
        let commands = commandTable.span
        let table = codes.table
        precondition(commands.count == 704 && lookup.count == 2048 && literalMap.count == 64 &* 256
            && distanceMap.count == 4 &* 256 && modes.count == 256 && literalTrees.count == 256
            && trivialTrees.count == 256 && commandTrees.count == 256 && distanceTrees.count == 256)
        var blocks = blocks
        var left = metablockRemaining
        var distances = distances
        var distanceIndex = distanceIndex
        let windowSize = windowSize
        let directCodes = directCodes
        let postfixBits = postfixBits
        var end = outputStart
        var suspended = false

        commands: while left > 0 {
            guard inputBits &- bits.bitPosition >= Self.fastInput &* 8, output.byteCount &- end >= Self.fastRoom else { break }
            bits.refill()
            if blocks.lengths[1] == 0 {
                let used = blocks.switchBlock(bits.bits, category: 1, table: table)
                bits.consume(bitCount: used)
                bits.refill()
            }
            let symbol = BrotliPrefixCodes.decode(&bits, table: table, tree: Int(UInt32(bitPattern: commandTrees[blocks.types[1] & 0xFF])))
            let entry = commands[symbol]
            bits.refill()
            let insertBits = Int(truncatingIfNeeded: entry &>> 32 & 0xFF)
            let insert = Int(truncatingIfNeeded: entry & 0xFFFF) &+ Int(truncatingIfNeeded: bits.peek(bitCount: insertBits))
            bits.consume(bitCount: insertBits)
            bits.refill()
            let copyBits = Int(truncatingIfNeeded: entry &>> 40 & 0xFF)
            let copy = Int(truncatingIfNeeded: entry &>> 16 & 0xFFFF) &+ Int(truncatingIfNeeded: bits.peek(bitCount: copyBits))
            bits.consume(bitCount: copyBits)
            blocks.lengths[1] &-= 1
            let implicit = entry &>> 48 != 0
            guard insert <= left else { throw .invalidValue } // Literals past the meta-block's end.

            // Literals, a block's run at a time.
            var remaining = insert
            while remaining > 0 {
                bits.refill()
                if blocks.lengths[0] == 0 {
                    let used = blocks.switchBlock(bits.bits, category: 0, table: table)
                    bits.consume(bitCount: used)
                    bits.refill()
                }
                let safe = (inputBits &- bits.bitPosition &- 128) / 15
                let count = min(min(remaining, blocks.lengths[0]), min(output.byteCount &- end, safe))
                guard count > 0 else {
                    // Near an end: the careful loop finishes the command.
                    insertRemaining = remaining
                    copyLength = copy
                    implicitDistance = implicit
                    phase = .literals
                    suspended = true
                    break commands
                }
                let type = blocks.types[0] & 0xFF
                let trivial = trivialTrees[type]
                var index = 0
                if trivial >= 0 {
                    // The block type uses one tree whatever the context (Google's "trivial literal context"):
                    // no context to compute, so successive literals don't wait on each other.
                    // Three literals per refill: 15 bits each of the 56 or more buffered.
                    let tree = Int(trivial)
                    while index &+ 3 <= count {
                        bits.refill()
                        let first = UInt8(truncatingIfNeeded: BrotliPrefixCodes.decode(&bits, table: table, tree: tree))
                        let second = UInt8(truncatingIfNeeded: BrotliPrefixCodes.decode(&bits, table: table, tree: tree))
                        let third = UInt8(truncatingIfNeeded: BrotliPrefixCodes.decode(&bits, table: table, tree: tree))
                        // Unsafe: stores without bounds checks. Safe: `count` is at most the room after `end`,
                        // checked above, and `index + 3 <= count`.
                        unsafe output.storeBytes(of: first, toUncheckedByteOffset: end &+ index, as: UInt8.self)
                        unsafe output.storeBytes(of: second, toUncheckedByteOffset: end &+ index &+ 1, as: UInt8.self)
                        unsafe output.storeBytes(of: third, toUncheckedByteOffset: end &+ index &+ 2, as: UInt8.self)
                        index &+= 3
                    }
                    while index < count {
                        bits.refill()
                        let literal = UInt8(truncatingIfNeeded: BrotliPrefixCodes.decode(&bits, table: table, tree: tree))
                        output.storeBytes(of: literal, toByteOffset: end &+ index, as: UInt8.self)
                        index &+= 1
                    }
                } else {
                    let mode = Int(modes[type]) & 0x600
                    let mapBase = type &<< 6
                    var p1: UInt8 = 0
                    var p2: UInt8 = 0
                    do {
                        let history = output.bytes
                        if end >= 1 { p1 = history.load(fromByteOffset: end &- 1, as: UInt8.self) }
                        if end >= 2 { p2 = history.load(fromByteOffset: end &- 2, as: UInt8.self) }
                    }
                    // Up to three literals per refill: 15 bits each of the 56 or more buffered.
                    while index < count {
                        bits.refill()
                        let group = min(count &- index, 3)
                        var step = 0
                        repeat {
                            let context = Int(lookup[mode | Int(p1)] | lookup[mode | 256 | Int(p2)]) & 0x3F
                            let tree = Int(UInt32(bitPattern: literalTrees[Int(literalMap[mapBase | context])]))
                            let literal = UInt8(truncatingIfNeeded: BrotliPrefixCodes.decode(&bits, table: table, tree: tree))
                            // Unsafe: a store without a bounds check. Safe: `count` is at most the room after
                            // `end`, checked above, and `index + step < count`.
                            unsafe output.storeBytes(of: literal, toUncheckedByteOffset: end &+ index &+ step, as: UInt8.self)
                            p2 = p1
                            p1 = literal
                            step &+= 1
                        } while step < group
                        index &+= group
                    }
                }
                end &+= count
                remaining &-= count
                left &-= count
                blocks.lengths[0] &-= count
            }
            if left == 0 { break } // The copy is ignored at the meta-block's end.

            // The distance.
            let distance: Int
            if implicit {
                distance = distances[(distanceIndex &- 1) & 3]
            } else {
                bits.refill()
                if blocks.lengths[2] == 0 {
                    let used = blocks.switchBlock(bits.bits, category: 2, table: table)
                    bits.consume(bitCount: used)
                    bits.refill()
                }
                let context = min(copy, 5) &- 2
                let tree = Int(UInt32(bitPattern: distanceTrees[Int(distanceMap[(blocks.types[2] & 0xFF) &<< 2 | context & 3])]))
                let code = BrotliPrefixCodes.decode(&bits, table: table, tree: tree)
                bits.refill()
                if code < 16 {
                    distance = Self.specialDistance(code, distances, distanceIndex)
                } else if code < 16 &+ directCodes {
                    distance = code &- 15
                } else {
                    let value = code &- directCodes &- 16
                    let extraBits = 1 &+ (value &>> (postfixBits &+ 1))
                    let high = value &>> postfixBits
                    let low = value & ((1 &<< postfixBits) &- 1)
                    let offset = ((2 &+ (high & 1)) &<< extraBits) &- 4
                    distance = ((offset &+ Int(bits.read(bitCount: extraBits))) &<< postfixBits) &+ low &+ directCodes &+ 1
                }
                guard distance > 0 else { throw .invalidValue }
                blocks.lengths[2] &-= 1
                if code != 0 && distance <= min(windowSize, origin &+ end) {
                    distances[distanceIndex & 3] = distance
                    distanceIndex &+= 1
                }
            }

            // The copy.
            let maximum = min(windowSize, origin &+ end)
            if distance > maximum {
                var word = InlineArray<48, UInt8>(repeating: 0)
                let count = try Self.dictionaryWord(length: copy, id: distance &- maximum &- 1, into: &word)
                guard count <= left else { throw .invalidValue }
                guard output.byteCount &- end >= count else {
                    copyLength = copy
                    copyDistance = distance
                    copyRemaining = copy
                    phase = .copy
                    suspended = true
                    break commands
                }
                var index = 0
                while index < count {
                    output.storeBytes(of: word[index], toByteOffset: end &+ index, as: UInt8.self)
                    index &+= 1
                }
                end &+= count
                left &-= count
                continue
            }
            guard copy <= left else { throw .invalidValue }
            guard output.byteCount &- end >= copy &+ AlignedBytesWriter.copyOverrun else {
                copyLength = copy
                copyDistance = distance
                copyRemaining = copy
                phase = .copy
                suspended = true
                break commands
            }
            do {
                var writer = try AlignedBytesWriter(&output, atByteOffset: end)
                try writer.copy(fromDistance: distance, count: copy, allowingOverrun: true)
                end = writer.byteCount
            }
            left &-= copy
        }
        if !suspended { phase = .start }
        self.blocks = blocks
        metablockRemaining = left
        self.distances = distances
        self.distanceIndex = distanceIndex
        position = origin &+ end
        return (bits.bitPosition, end, !suspended && left == 0)
    }

    /// Static dictionary word `id` of `length` bytes, transformed, into `word`. Out of line: rare on most
    /// data, and large.
    ///
    /// - Returns: The transformed word's length.
    /// - Throws: ``BytesError/invalidValue`` for a length without words or a transform past the last.
    @inline(never)
    private static func dictionaryWord(length: Int, id: Int, into word: inout InlineArray<48, UInt8>) throws(BytesError) -> Int {
        guard length >= 4 && length <= 24 else { throw .invalidValue }
        let sizeBits = Int(Brotli.dictionarySizeBits[length])
        let index = id & ((1 &<< sizeBits) &- 1)
        let transform = id &>> sizeBits
        guard transform < Brotli.transformCount else { throw .invalidValue }
        let words = brotliDictionaryWords // A local to borrow from: a global's span can't outlive the access.
        return Brotli.transform(
            words.span.bytes, word: Int(Brotli.dictionaryOffsets[length]) &+ index &* length, length: length,
            transform: transform, into: &word
        )
    }

    /// Writes static dictionary word `id` of `length` bytes, transformed, updating the literal context's last
    /// two bytes: the careful loop's form of ``dictionaryWord(length:id:into:)``.
    ///
    /// - Returns: The transformed word's length, or `nil` if the output doesn't have room for it.
    /// - Throws: ``BytesError/invalidValue`` for a length without words, a transform past the last, or a word
    ///   longer than the meta-block's remaining length `limit`.
    private static func writeDictionaryWord(
        length: Int, id: Int, limit: Int, to writer: inout AlignedBytesWriter, p1: inout UInt8, p2: inout UInt8
    ) throws(BytesError) -> Int? {
        var word = InlineArray<48, UInt8>(repeating: 0)
        let count = try dictionaryWord(length: length, id: id, into: &word)
        guard count <= limit else { throw .invalidValue }
        guard writer.remainingByteCount >= count else { return nil }
        for offset in 0..<count {
            try writer.write(Byte(truncatingIfNeeded: word[offset]))
        }
        if count >= 2 {
            p1 = word[count &- 1]
            p2 = word[count &- 2]
        } else if count == 1 {
            p2 = p1
            p1 = word[0]
        }
        return count
    }

    /// Distance codes 0–15: the last distances, and the last two plus or minus 1 to 3.
    @inline(__always)
    private func specialDistance(_ code: Int) -> Int {
        Self.specialDistance(code, distances, distanceIndex)
    }

    /// Branchless, as Google's decoder does it with two tables: which of the last four distances (1 the
    /// latest, through 4), and what to add (-3 through 3). Both are nibble tables in constants, indexed by the
    /// code: codes 0–3 are the last four as they are, 4–9 the latest -1, +1, -2, +2, -3, +3, and 10–15 the
    /// second latest the same way. (A 16-way `switch` was a jump table, mispredicted on copy-heavy data.)
    @inline(__always)
    private static func specialDistance(_ code: Int, _ distances: InlineArray<4, Int>, _ distanceIndex: Int) -> Int {
        let shift = UInt64(truncatingIfNeeded: code &<< 2) & 63
        let back = Int(truncatingIfNeeded: (0x2222_2211_1111_4321 as UInt64) &>> shift & 0xF)
        let delta = Int(truncatingIfNeeded: (0x6051_4260_5142_3333 as UInt64) &>> shift & 0xF) &- 3
        return distances[(distanceIndex &- back) & 3] &+ delta
    }
}
