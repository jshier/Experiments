internal import Bytes

// A DEFLATE (RFC 1951) decoder built on `Bytes`. The bitstream is read through a `BitBuffer` (least
// significant bit first): block headers and code-length tables field by field as `Bits`, and Huffman codes
// by indexing two-level lookup tables with the buffered bits. Back-references are
// `BytesWriter.copy(fromDistance:count:)`.
//
// It decodes into a caller's buffer and stops when fewer than 258 bytes (the longest match) are free, so a
// stream decodes in resumable steps of about a buffer each. Between steps the caller moves the last 32 KB
// of output (the window back-references can reach) to the front of the buffer it decodes into next.

/// A Huffman decoding table entry, packed into 32 bits, in the style of libdeflate's: everything the
/// decode loop needs comes from one load.
///
/// - bits 0–7: the bits a match of this code consumes, code plus extra bits (the code alone otherwise);
/// - bits 8–11: the code's length, where its extra bits start (a subtable's index width, for links);
/// - bits 12–14: the kind;
/// - bits 16–31: the value: a literal, a length or distance base, or a subtable's offset.
struct HuffmanEntry {
    var raw: UInt32

    enum Kind: UInt32 {
        /// A literal byte, or a code-length symbol (0 through 18).
        case literal
        /// A match length or distance: `value` plus the extra bits.
        case lengthOrDistance
        case endOfBlock
        /// Codes longer than the root continue in a subtable at `value`, indexed by `codeLength` more bits.
        case subtable
        /// No code maps here, or the symbol is reserved.
        case invalid
    }

    @inline(__always)
    init(codeLength: Int, kind: Kind, value: Int, extraBits: Int = 0) {
        raw = UInt32(codeLength &+ extraBits) | UInt32(codeLength) << 8 | kind.rawValue << 12 | UInt32(value) << 16
    }

    @inline(__always) init(raw: UInt32) { self.raw = raw }

    /// Bits to consume: the code, plus a length's or distance's extra bits.
    /// Masked to 6 bits, the width a variable shift uses: so `BitBuffer.consume` can shift by the raw entry
    /// (ARM's `lsr` ignores the rest), keeping the mask off the decode loop's critical path.
    @inline(__always) var totalBits: Int { Int(raw & 0x3F) }
    @inline(__always) var codeLength: Int { Int(raw >> 8 & 0xF) }
    @inline(__always) var kind: UInt32 { raw >> 12 & 0x7 }
    @inline(__always) var value: Int { Int(raw >> 16) }

    /// The extra bits' value, from bits whose first is this entry's code's first.
    @inline(__always)
    func extra(_ bits: UInt64) -> Int {
        Int(truncatingIfNeeded: (bits & ((1 &<< UInt64(totalBits)) &- 1)) &>> UInt64(codeLength))
    }

    static var invalid: Self { Self(codeLength: 0, kind: .invalid, value: 0) }
}

/// What a code's symbol decodes to, for each alphabet.
enum Alphabet {
    case literalLength, distance

    /// The entry for `symbol` with a code of `codeLength` bits.
    @inline(__always)
    func entry(_ symbol: Int, codeLength: Int) -> HuffmanEntry {
        switch self {
        case .literalLength:
            switch symbol {
            case 0..<256: return HuffmanEntry(codeLength: codeLength, kind: .literal, value: symbol)
            case 256: return HuffmanEntry(codeLength: codeLength, kind: .endOfBlock, value: 0)
            case 257..<286:
                let index = symbol &- 257
                return HuffmanEntry(
                    codeLength: codeLength, kind: .lengthOrDistance,
                    value: Int(Self.lengthBases[index]), extraBits: Int(Self.lengthExtraBits[index])
                )
            default: return HuffmanEntry(codeLength: codeLength, kind: .invalid, value: 0) // 286, 287
            }
        case .distance:
            guard symbol < 30 else { return HuffmanEntry(codeLength: codeLength, kind: .invalid, value: 0) }
            return HuffmanEntry(
                codeLength: codeLength, kind: .lengthOrDistance,
                value: Int(Self.distanceBases[symbol]), extraBits: Int(Self.distanceExtraBits[symbol])
            )
        }
    }

    static var lengthBases: InlineArray<29, UInt16> {
        [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    }
    static var lengthExtraBits: InlineArray<29, UInt8> {
        [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    }
    static var distanceBases: InlineArray<30, UInt16> {
        [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
         4097, 6145, 8193, 12289, 16385, 24577]
    }
    static var distanceExtraBits: InlineArray<30, UInt8> {
        [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    }
}

/// The three block types; 3 is reserved, so reading it throws.
enum BlockType: UInt8 {
    case stored, fixedHuffman, dynamicHuffman
}

@safe
struct Inflater: ~Copyable {
    /// Root table widths: codes up to this long take one lookup, longer ones a second in a subtable.
    static var literalRootBits: Int { 11 }
    static var distanceRootBits: Int { 8 }

    /// The longest match, and so the room to keep free before decoding a symbol.
    static var maximumMatch: Int { 258 }

    // Tables, in one array: the fixed code's two (built once) and the current dynamic block's two. The
    // sizes cover the largest tables any valid code can need (from zlib's `enough`: 2,342 entries for
    // 11-bit literal/length roots, 402 for 8-bit distance roots). Read through spans, so every lookup is
    // bounds-checked; see `decodeSymbols` for why that costs nothing on the root lookups.
    static var tableSize: Int { 2560 }
    static var distanceTableSize: Int { 512 }
    static var fixedLiterals: Int { 0 }
    static var fixedDistances: Int { tableSize }
    static var dynamicLiterals: Int { tableSize + distanceTableSize }
    static var dynamicDistances: Int { 2 * tableSize + distanceTableSize }
    static var totalSize: Int { 2 * tableSize + 2 * distanceTableSize }

    private var tables = [UInt32](repeating: 0, count: totalSize)
    /// The code-length code, which only headers use: `Bytes`' plain table, entries holding just the symbol.
    private var codeLengthTable = HuffmanTable(symbolCount: 19, maximumCodeLength: 7, rootBits: 7)

    // Where the stream is between steps.
    private enum State {
        case blockHeader
        case stored(remaining: Int)
        case huffman(fixed: Bool)
        case done
    }
    private var state = State.blockHeader
    private var isFinalBlock = false
    /// The next bit to read, from the start of the input.
    private var bitPosition = 0

    init() {
        // The fixed code (RFC 1951, 3.2.6): literal/lengths 8, 9, 7, and 8 bits; 32 distance codes of 5 bits.
        var literalLengths = InlineArray<288, UInt8>(repeating: 8)
        for symbol in 144..<256 { literalLengths[symbol] = 9 }
        for symbol in 256..<280 { literalLengths[symbol] = 7 }
        let distanceLengths = InlineArray<32, UInt8>(repeating: 5)
        // The fixed code is valid, so building it can't throw.
        try! buildTable(literalLengths.span, .literalLength, at: Self.fixedLiterals, rootBits: Self.literalRootBits)
        try! buildTable(distanceLengths.span, .distance, at: Self.fixedDistances, rootBits: Self.distanceRootBits)
    }

    /// Prepares to decode a new stream.
    mutating func reset() {
        state = .blockHeader
        isFinalBlock = false
        bitPosition = 0
    }

    /// Decodes from `input` (the whole compressed stream, the same on every call) into `output`, writing
    /// from `start`, until the stream ends or fewer than ``maximumMatch`` bytes are free. Bytes before
    /// `start` are history that back-references may reach.
    ///
    /// Returns where the output ends, and whether the stream is finished. Throws ``BytesError`` for corrupt
    /// or truncated data.
    ///
    /// Each kind of work is its own function taking and returning plain positions, building its own
    /// `BitBuffer` and `BytesWriter` as locals: the symbol loop's cursors then live in registers. (One big
    /// function was too large for the inliner, so `BytesWriter.copy` stayed a call, and passing the writer to
    /// it kept the writer in memory: 2x slower.)
    mutating func decode(
        _ input: RawSpan, into output: inout MutableRawSpan, start: Int
    ) throws(BytesError) -> (end: Int, finished: Bool) {
        var position = start
        while true {
            switch state {
            case .done:
                return (position, true)
            case .blockHeader:
                if isFinalBlock {
                    state = .done
                } else {
                    try readBlockHeader(input)
                }
            case .stored(let remaining):
                let count = min(remaining, output.byteCount &- position)
                var reader = Bytes(input)
                try reader.seek(toBitPosition: bitPosition)
                var writer = BytesWriter(output._mutatingExtracting(...))
                try writer.skip(byteCount: position)
                try writer.write(try reader.read(byteCount: count))
                bitPosition = reader.bitPosition
                position = writer.byteCount
                guard count == remaining else {
                    state = .stored(remaining: remaining &- count)
                    return (position, false) // Output full.
                }
                state = .blockHeader
            case .huffman(let fixed):
                let literals = fixed ? Self.fixedLiterals : Self.dynamicLiterals
                let distances = fixed ? Self.fixedDistances : Self.dynamicDistances
                let tables = tables.span
                let result = try Self.decodeSymbols(
                    input, from: bitPosition,
                    literals: tables.extracting(literals..<(literals &+ Self.tableSize)),
                    distances: tables.extracting(distances..<(distances &+ Self.distanceTableSize)),
                    into: &output, at: position
                )
                bitPosition = result.bitPosition
                position = result.end
                guard result.endOfBlock else { return (position, false) } // Output full.
                state = .blockHeader
            }
        }
    }

    /// Reads a block header at ``bitPosition``: the final flag, the type, and a stored block's length or a
    /// dynamic block's tables.
    private mutating func readBlockHeader(_ input: RawSpan) throws(BytesError) {
        var reader = Bytes(input, bitOrder: .leastSignificantFirst)
        try reader.seek(toBitPosition: bitPosition)
        var bits = BitBuffer(reader)
        isFinalBlock = bits.read(Bit.self).isSet
        switch try bits.read(BlockType.self, as: Crumb.self) {
        case .stored:
            bits.alignToByte()
            var stored = try bits.finish()
            let length = try stored.read(Byte2.self, .littleEndian)
            try stored.expect(Byte2(~length, .littleEndian)) // NLEN, the one's complement
            bitPosition = stored.bitPosition
            state = .stored(remaining: Int(length))
            return
        case .fixedHuffman:
            state = .huffman(fixed: true)
        case .dynamicHuffman:
            try readDynamicTables(&bits)
            state = .huffman(fixed: false)
        }
        // A truncated header reads zeros from the buffer; caught here.
        guard !bits.isOverrun else { throw .insufficientData }
        bitPosition = bits.bitPosition
    }

    /// Decodes Huffman-coded symbols from `bitPosition` into `output` from `end`, until the block ends or
    /// fewer than ``maximumMatch`` bytes are free.
    ///
    /// Table lookups are bounds-checked. Stating the tables' sizes once, here, makes those checks free for
    /// root lookups: with the count a known constant, the optimizer sees that a masked root index is in
    /// bounds. Only subtable lookups (codes longer than the root, rare) keep a check.
    private static func decodeSymbols(
        _ input: RawSpan, from bitPosition: Int,
        literals: Span<UInt32>, distances: Span<UInt32>,
        into output: inout MutableRawSpan, at end: Int
    ) throws(BytesError) -> (bitPosition: Int, end: Int, endOfBlock: Bool) {
        precondition(literals.count == tableSize && distances.count == distanceTableSize)
        var reader = Bytes(input, bitOrder: .leastSignificantFirst)
        try reader.seek(toBitPosition: bitPosition)
        var bits = BitBuffer(reader)
        var writer = BytesWriter(output._mutatingExtracting(...))
        try writer.skip(byteCount: end)
        var endOfBlock = false

        // The next symbol's entry is looked up ahead of time (as libdeflate does): at the top of each
        // iteration it's ready, so decoding doesn't wait for a refill, a mask, and a table load first.
        // After a match, the next lookup happens before the match is copied, overlapping the two.
        bits.refill()
        var entry = lookup(literals, bits.bits, rootBits: literalRootBits)
        // Room for three literals, a match, and its copy's overrun.
        symbols: while writer.remainingByteCount >= 3 &+ maximumMatch &+ BytesWriter.copyOverrun {
            if entry.kind == HuffmanEntry.Kind.literal.rawValue {
                // Literals come in runs: up to three per refill (15 bits each of the 56 or more buffered).
                // Each lookup after a literal reads valid bits (41, then 26 or more left), and a refill only
                // adds bits above them, so an entry that isn't a literal stays valid across the refill.
                // (A run that continues while enough bits are buffered measured 10% slower on literal-only
                // data: its exit branch mispredicts.)
                bits.consume(bitCount: entry.totalBits)
                try writer.write(Byte(truncatingIfNeeded: entry.value))
                // Root entries first: a literal there can't be a subtable link, so the common case skips
                // that check. Anything else is resolved below.
                entry = rootEntry(literals, bits.bits, rootBits: literalRootBits)
                if entry.kind == HuffmanEntry.Kind.literal.rawValue {
                    bits.consume(bitCount: entry.totalBits)
                    try writer.write(Byte(truncatingIfNeeded: entry.value))
                    entry = rootEntry(literals, bits.bits, rootBits: literalRootBits)
                    if entry.kind == HuffmanEntry.Kind.literal.rawValue {
                        bits.consume(bitCount: entry.totalBits)
                        try writer.write(Byte(truncatingIfNeeded: entry.value))
                        // 11 or more bits are left: enough for the root lookup, which then doesn't wait for the
                        // refill's load (only a long code's subtable lookup needs the refilled bits).
                        let root = rootEntry(literals, bits.bits, rootBits: literalRootBits)
                        bits.refill()
                        entry = resolve(root, literals, bits.bits, rootBits: literalRootBits)
                        continue
                    }
                }
                // 26 or more bits: enough to resolve any code.
                entry = resolve(entry, literals, bits.bits, rootBits: literalRootBits)
                // A match needs up to 48 bits: 15 + 5 for its length, 15 + 13 for its distance.
                bits.refill()
            }
            switch entry.kind {
            case HuffmanEntry.Kind.literal.rawValue:
                // A long literal code, from a subtable: rare. 56 or more bits buffered.
                bits.consume(bitCount: entry.totalBits)
                try writer.write(Byte(truncatingIfNeeded: entry.value))
                entry = lookup(literals, bits.bits, rootBits: literalRootBits)
            case HuffmanEntry.Kind.lengthOrDistance.rawValue:
                // 48 or more bits buffered. After the length, 28 or more: enough for the distance, decoded
                // from a copy of them, so the refill started here overlaps it instead of delaying it. After
                // the distance, 28 or more remain: enough for the next root lookup, made before a second
                // refill (which the next symbol needs, if it's another match) for the same reason.
                let length = entry.value &+ entry.extra(bits.bits)
                bits.consume(bitCount: entry.totalBits)
                let window = bits.bits
                bits.refill()
                let distanceEntry = lookup(distances, window, rootBits: distanceRootBits)
                guard distanceEntry.kind == HuffmanEntry.Kind.lengthOrDistance.rawValue else { throw .invalidValue }
                let distance = distanceEntry.value &+ distanceEntry.extra(window)
                bits.consume(bitCount: distanceEntry.totalBits)
                let root = rootEntry(literals, bits.bits, rootBits: literalRootBits)
                bits.refill()
                entry = resolve(root, literals, bits.bits, rootBits: literalRootBits)
                // Throws `invalidValue` for a distance reaching before the output's start.
                try writer.copy(fromDistance: distance, count: length, allowingOverrun: true)
            case HuffmanEntry.Kind.endOfBlock.rawValue:
                bits.consume(bitCount: entry.totalBits)
                endOfBlock = true
                break symbols
            default:
                throw .invalidValue
            }
        }
        // A truncated stream reads zeros from the buffer; caught here, once per step.
        guard !bits.isOverrun else { throw .insufficientData }
        return (bits.bitPosition, writer.byteCount, endOfBlock)
    }

    /// The entry for the code at the start of `bits`.
    @inline(__always)
    private static func lookup(_ table: Span<UInt32>, _ bits: UInt64, rootBits: Int) -> HuffmanEntry {
        resolve(rootEntry(table, bits, rootBits: rootBits), table, bits, rootBits: rootBits)
    }

    /// The root table's entry for the start of `bits`: needs only `rootBits` valid bits.
    @inline(__always)
    private static func rootEntry(_ table: Span<UInt32>, _ bits: UInt64, rootBits: Int) -> HuffmanEntry {
        HuffmanEntry(raw: table[Int(truncatingIfNeeded: bits) & ((1 &<< rootBits) &- 1)])
    }

    /// `entry`, or for a link to a subtable, the subtable's entry for the bits after the root's.
    @inline(__always)
    private static func resolve(
        _ entry: HuffmanEntry, _ table: Span<UInt32>, _ bits: UInt64, rootBits: Int
    ) -> HuffmanEntry {
        guard entry.kind == HuffmanEntry.Kind.subtable.rawValue else { return entry }
        let index = Int(truncatingIfNeeded: bits &>> UInt64(rootBits)) & ((1 &<< entry.codeLength) &- 1)
        return HuffmanEntry(raw: table[entry.value &+ index])
    }

    // MARK: - Dynamic block headers

    /// The code-length code's symbols, in the order the header lists their lengths.
    private static var codeLengthOrder: InlineArray<19, UInt8> {
        [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    }

    /// Reads a dynamic block's header (RFC 1951, 3.2.7) and builds its two tables.
    private mutating func readDynamicTables(_ bits: inout BitBuffer) throws(BytesError) {
        let literalCount = Int(bits.read(Bits<5>.self)) &+ 257   // HLIT
        let distanceCount = Int(bits.read(Bits<5>.self)) &+ 1    // HDIST
        let codeLengthCount = Int(bits.read(Nibble.self)) &+ 4   // HCLEN
        guard literalCount <= 286, distanceCount <= 30 else { throw .invalidValue }

        // The code-length code: 3 bits per length, in a fixed order.
        var codeLengthLengths = InlineArray<19, UInt8>(repeating: 0)
        for index in 0..<codeLengthCount {
            codeLengthLengths[Int(Self.codeLengthOrder[index])] = bits.read(Bits<3>.self).rawValue
        }
        // zlib rejects incomplete code-length codes, unlike the others.
        try codeLengthTable.build(codeLengths: codeLengthLengths.span, bitOrder: .leastSignificantFirst, allowingIncomplete: false)

        // The literal/length and distance code lengths, as one sequence with run-length codes 16 to 18.
        var lengths = InlineArray<316, UInt8>(repeating: 0)
        let total = literalCount &+ distanceCount
        var index = 0
        while index < total {
            bits.refill()
            let symbol = try codeLengthTable.decode(&bits)
            let repeated: UInt8
            let count: Int
            switch symbol {
            case 0...15:
                lengths[index] = UInt8(symbol)
                index &+= 1
                continue
            case 16: // The previous length, 3 to 6 times.
                guard index > 0 else { throw .invalidValue }
                repeated = lengths[index &- 1]
                count = 3 &+ Int(bits.read(Crumb.self))
            case 17: // Zero, 3 to 10 times.
                repeated = 0
                count = 3 &+ Int(bits.read(Bits<3>.self))
            default: // 18: zero, 11 to 138 times.
                repeated = 0
                count = 11 &+ Int(bits.read(Bits<7>.self))
            }
            guard index &+ count <= total else { throw .invalidValue }
            for offset in index..<(index &+ count) { lengths[offset] = repeated }
            index &+= count
        }
        guard !bits.isOverrun else { throw .insufficientData }
        guard lengths[256] != 0 else { throw .invalidValue } // A block needs its end code.

        let span = lengths.span
        try buildTable(span.extracting(0..<literalCount), .literalLength, at: Self.dynamicLiterals, rootBits: Self.literalRootBits)
        try buildTable(span.extracting(literalCount..<total), .distance, at: Self.dynamicDistances, rootBits: Self.distanceRootBits)
    }

    // MARK: - Tables

    /// Builds the decoding table at `offset` in ``tables`` for the canonical Huffman code with code `lengths`
    /// (0 for unused symbols), with `alphabet`'s packed entries, using `Bytes`' canonical-code builder.
    ///
    /// Accepts the incomplete codes zlib does: an empty one (a block without matches) and a single 1-bit
    /// code (RFC 1951 allows it for distances, zlib for literals too).
    private mutating func buildTable(
        _ lengths: Span<UInt8>, _ alphabet: Alphabet, at offset: Int, rootBits: Int
    ) throws(BytesError) {
        let size = alphabet == .literalLength ? Self.tableSize : Self.distanceTableSize
        var all = tables.mutableSpan
        var table = all._mutatingExtracting(offset..<(offset &+ size))
        _ = try HuffmanTable.build(
            codeLengths: lengths, bitOrder: .leastSignificantFirst, rootBits: rootBits, maximumCodeLength: 15,
            into: &table, invalid: HuffmanEntry.invalid.raw,
            symbol: { symbol, length in alphabet.entry(symbol, codeLength: length).raw },
            subtable: { offset, bits in HuffmanEntry(codeLength: bits, kind: .subtable, value: offset).raw }
        )
    }
}
