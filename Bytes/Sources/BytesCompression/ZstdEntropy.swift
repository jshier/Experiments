import Builtin
internal import Bytes

// Zstandard's entropy coding (RFC 8878, section 4): FSE table descriptions and decoding tables, Huffman
// weights and decoding tables, and the backward bitstreams both are read from. Table building follows
// libzstd's (`fse_decompress.c`, `huf_decompress.c`, `zstd_decompress_block.c`), so the tables match its
// entry for entry.

@_transparent
func zstdLikely(_ condition: Bool) -> Bool {
    Bool(Builtin.int_expect_Int1(condition._value, true._value))
}

@_transparent
func zstdUnlikely(_ condition: Bool) -> Bool {
    Bool(Builtin.int_expect_Int1(condition._value, false._value))
}

// MARK: - Workspace

/// A decoder's tables and literal buffer, in one allocation made once.
///
/// Raw memory, so the decode loops address it with pointers and no bounds checks: each region's size is a
/// constant here, and every index into a table is in range by construction (a masked root index, or an FSE
/// state, which the table builders keep below the table's size).
// `@usableFromInline` exports the type's metadata: with cross-module optimization, clients destroying a
// `ZstdDecoder` reference it, for its `deinit` (a release build of the tests failed to link without it).
@safe @usableFromInline
struct ZstdWorkspace: ~Copyable {
    /// Room for a block's literals, plus the slack wild copies read past their end.
    static var literalCapacity: Int { Zstd.blockSizeMaximum + 64 }
    static var literalsOffset: Int { 0 }
    /// Huffman decoding table: up to 4,096 entries of up to 4 bytes (12-bit codes, two-symbol entries).
    static var huffmanOffset: Int { literalsOffset + literalCapacity }
    static var huffmanSize: Int { 4096 * 4 }
    /// Sequence decoding tables, 8-byte entries: literal lengths (up to 512), offsets (256), match lengths (512).
    static var literalLengthOffset: Int { huffmanOffset + huffmanSize }
    static var offsetOffset: Int { literalLengthOffset + 512 * 8 }
    static var matchLengthOffset: Int { offsetOffset + 256 * 8 }
    /// The predefined distributions' tables, built once.
    static var literalLengthDefaultOffset: Int { matchLengthOffset + 512 * 8 }
    static var offsetDefaultOffset: Int { literalLengthDefaultOffset + 64 * 8 }
    static var matchLengthDefaultOffset: Int { offsetDefaultOffset + 32 * 8 }
    /// The FSE table that decodes Huffman weights: up to 64 entries of 4 bytes.
    static var weightTableOffset: Int { matchLengthDefaultOffset + 64 * 8 }
    /// Each sequence code's baseline and extra-bit count, as table entries without the state fields:
    /// literal lengths (36 codes), offsets (32), match lengths (53).
    static var literalLengthCodesOffset: Int { weightTableOffset + 64 * 4 }
    static var offsetCodesOffset: Int { literalLengthCodesOffset + 36 * 8 }
    static var matchLengthCodesOffset: Int { offsetCodesOffset + 32 * 8 }
    /// Scratch for building tables: normalized counts (256 `Int16`s), symbols in order and by cell (512 bytes
    /// each, plus 8 for 8-byte stores), each symbol's next state (256 `UInt16`s), Huffman weights (256 bytes).
    static var countsOffset: Int { matchLengthCodesOffset + 56 * 8 }
    static var orderedOffset: Int { countsOffset + 256 * 2 }
    static var cellsOffset: Int { orderedOffset + 512 + 64 }
    static var nextOffset: Int { cellsOffset + 512 + 64 }
    static var weightsOffset: Int { nextOffset + 256 * 2 }
    static var size: Int { weightsOffset + 256 + 64 }

    let base: UnsafeMutableRawPointer

    /// Allocates the workspace, zeroed, and builds the code and predefined tables.
    init() {
        unsafe base = UnsafeMutableRawPointer.allocate(byteCount: Self.size, alignment: 64)
        // Unsafe: initializing and filling fresh memory. Safe: the allocation is `size` bytes, and each region
        // written is within it, at the offsets above.
        unsafe base.initializeMemory(as: UInt8.self, repeating: 0, count: Self.size)
        for alphabet in [ZstdSequenceAlphabet.literalLength, .offset, .matchLength] {
            let codes = unsafe (base + alphabet.codesOffset).assumingMemoryBound(to: UInt64.self)
            for code in 0...alphabet.maximumSymbol {
                let (baseline, bits) = alphabet.baseAndBits(code)
                unsafe codes[code] = UInt64(baseline) &<< 32 | UInt64(bits) &<< 16
            }
        }
        // The predefined distributions are valid, so building them can't fail.
        let tables: [(Int, [Int16], Int, ZstdSequenceAlphabet)] = [
            (Self.literalLengthDefaultOffset, Zstd.literalLengthDefaultNorm, Zstd.literalLengthDefaultLog, .literalLength),
            (Self.offsetDefaultOffset, Zstd.offsetDefaultNorm, Zstd.offsetDefaultLog, .offset),
            (Self.matchLengthDefaultOffset, Zstd.matchLengthDefaultNorm, Zstd.matchLengthDefaultLog, .matchLength),
        ]
        let counts = unsafe (base + Self.countsOffset).assumingMemoryBound(to: Int16.self)
        for (offset, norm, log, alphabet) in tables {
            for (symbol, count) in norm.enumerated() {
                unsafe counts[symbol] = count
            }
            try! unsafe ZstdFSE.buildSequenceTable(
                (base + offset).assumingMemoryBound(to: UInt64.self), index: offset / 8, maximumSymbol: norm.count - 1, tableLog: log,
                codes: (base + alphabet.codesOffset).assumingMemoryBound(to: UInt64.self), scratch: ZstdTableScratch(self)
            )
        }
    }

    deinit {
        // Unsafe: freeing the allocation. Safe: only `deinit` frees it, once.
        unsafe base.deallocate()
    }

    /// A pointer `offset` bytes into the workspace.
    @inline(__always)
    func pointer(_ offset: Int) -> UnsafeMutableRawPointer {
        // Unsafe: pointer arithmetic. Safe: every caller passes one of the region offsets above.
        unsafe base + offset
    }
}

/// A raw byte buffer owned by a decoder: its streaming window or its input stash. Grows by replacement.
@safe @usableFromInline // Exported for clients' destroys, as `ZstdWorkspace`.
struct ZstdBuffer: ~Copyable {
    private(set) var base: UnsafeMutableRawPointer?
    private(set) var capacity = 0

    init() {}

    /// Makes room for at least `capacity` bytes, zeroed, discarding the contents if it reallocates.
    mutating func reserve(_ capacity: Int) {
        guard capacity > self.capacity else { return }
        // Unsafe: replacing the allocation. Safe: the old one is freed exactly once, and the new one is
        // zeroed before anything reads it.
        unsafe base?.deallocate()
        let memory = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 64)
        unsafe memory.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        unsafe base = memory
        self.capacity = capacity
    }

    deinit {
        // Unsafe: freeing the allocation. Safe: only `deinit` and `reserve` free it, each once.
        unsafe base?.deallocate()
    }
}

// MARK: - Backward bitstreams

/// A bitstream read backward (RFC 8878, 4.1): from its last byte, whose highest set bit marks the end,
/// toward its first, most significant bits first. As libzstd's `BIT_DStream_t`: a 64-bit container loaded
/// little-endian from `position`, with `consumed` bits used from its top.
///
/// Reads past the start of the stream give meaningless bits but never touch memory outside it; ``isAtEnd``
/// says whether a stream was consumed exactly.
@safe
struct ZstdReverseBits {
    var container: UInt64
    /// Bits used from the top of ``container``; more than 64 once the stream is overrun.
    var consumed: Int
    /// Where ``container`` was loaded from: 8 bytes, or the whole stream if it's shorter.
    var position: UnsafeRawPointer
    /// The stream's first byte.
    let start: UnsafeRawPointer

    /// libzstd's reload results, for the loops that decode until the stream runs out.
    enum Status: Comparable {
        case unfinished, endOfBuffer, completed, overflow
    }

    /// Starts reading the stream of `count` bytes at `start`, after its end marker.
    ///
    /// - Throws: ``BytesError/invalidValue`` for an empty stream or one whose last byte is 0 (no end marker).
    @unsafe @inline(__always)
    init(_ start: UnsafeRawPointer, count: Int) throws(BytesError) {
        guard count >= 1 else { throw .invalidValue }
        // Unsafe: loads within the stream. Safe: `count >= 1` bytes at `start`; the 8-byte load is at
        // `count - 8 >= 0`, or the bytes are loaded one at a time.
        let last = unsafe start.load(fromByteOffset: count &- 1, as: UInt8.self)
        guard last != 0 else { throw .invalidValue }
        unsafe self.start = start
        consumed = last.leadingZeroBitCount &+ 1
        if count >= 8 {
            unsafe position = start + (count &- 8)
            container = UInt64(littleEndian: unsafe position.loadUnaligned(as: UInt64.self))
        } else {
            unsafe position = start
            var value: UInt64 = 0
            for index in 0..<count {
                value |= UInt64(unsafe start.load(fromByteOffset: index, as: UInt8.self)) &<< UInt64(8 &* index)
            }
            container = value
            consumed &+= (8 &- count) &* 8
        }
    }

    /// Continues the `count`-byte stream at `start` with `unread` bits left: where a fast loop stopped.
    ///
    /// - Precondition: `count >= 8`, and `0 <= unread <= 8 * count`.
    @unsafe @inline(__always)
    init(_ start: UnsafeRawPointer, count: Int, unread: Int) {
        unsafe self.start = start
        // The lowest `unread` bits of the stream are left: load the 8 bytes that end with the next one, as low
        // as possible without going below the start.
        let skipped = max(0, (unread &- 64 &+ 7) &>> 3)
        // Unsafe: an 8-byte load. Safe: `skipped <= count - 8`, since `unread <= 8 * count`.
        unsafe position = start + skipped
        container = UInt64(littleEndian: unsafe position.loadUnaligned(as: UInt64.self))
        consumed = 64 &- (unread &- skipped &* 8)
    }

    /// The next `count` bits, 0 through 56 (0 reads nothing and gives 0).
    @inline(__always)
    mutating func read(_ count: Int) -> Int {
        let value = ((container &<< UInt64(truncatingIfNeeded: consumed)) &>> 1) &>> UInt64(truncatingIfNeeded: 63 &- count)
        consumed &+= count
        return Int(truncatingIfNeeded: value)
    }

    /// The next `count` bits, 1 through 56.
    @inline(__always)
    mutating func readFast(_ count: Int) -> Int {
        let value = (container &<< UInt64(truncatingIfNeeded: consumed)) &>> UInt64(truncatingIfNeeded: 64 &- count)
        consumed &+= count
        return Int(truncatingIfNeeded: value)
    }

    /// The next `count` bits (1 through 56) without consuming them.
    @inline(__always)
    func peek(_ count: Int) -> Int {
        Int(truncatingIfNeeded: (container &<< UInt64(truncatingIfNeeded: consumed)) &>> UInt64(truncatingIfNeeded: 64 &- count))
    }

    /// Refills the container to at least 57 valid bits while 8 bytes remain below it: the decode loops' reload.
    @inline(__always)
    mutating func reload() {
        let bytes = consumed &>> 3
        // Unsafe: pointer distance and an 8-byte load. Safe: `position - bytes > start`, and the load is at or
        // below the previous position, whose 8 bytes are in the stream.
        let available = unsafe position - start
        if zstdLikely(available > bytes) {
            unsafe position -= bytes
            consumed &= 7
            container = UInt64(littleEndian: unsafe position.loadUnaligned(as: UInt64.self))
        } else {
            unsafe (container, consumed, position) = Self.reloadNearStart(container, consumed, position, start: start)
        }
    }

    /// Within 8 bytes of the start: the first 8 bytes (streams of 8 or more), or nothing. Values in and out,
    /// not `inout`: a reader passed by address to a function that isn't inlined lives in memory for the whole
    /// decode loop.
    @inline(never)
    static func reloadNearStart(
        _ container: UInt64, _ consumed: Int, _ position: UnsafeRawPointer, start: UnsafeRawPointer
    ) -> (UInt64, Int, UnsafeRawPointer) {
        // Unsafe: an 8-byte load at the start. Safe: `position > start` only for streams of 8 or more bytes.
        let available = unsafe position - start
        guard consumed <= 64, available > 0 else { return unsafe (container, consumed, position) }
        return unsafe (UInt64(littleEndian: start.loadUnaligned(as: UInt64.self)), consumed &- available &* 8, start)
    }

    /// libzstd's `BIT_reloadDStream`, for the loops that stop on its result.
    mutating func reloadStatus() -> Status {
        if consumed > 64 { return .overflow }
        // Unsafe: pointer distance and arithmetic, and 8-byte loads. Safe: the stream is at least 8 bytes when
        // `position > start`, and loads stay at or above `start`.
        let available = unsafe position - start
        if available >= 8 {
            unsafe position -= consumed &>> 3
            consumed &= 7
            container = UInt64(littleEndian: unsafe position.loadUnaligned(as: UInt64.self))
            return .unfinished
        }
        if available == 0 { return consumed < 64 ? .endOfBuffer : .completed }
        var bytes = consumed &>> 3
        var status = Status.unfinished
        if bytes > available {
            bytes = available
            status = .endOfBuffer
        }
        unsafe position -= bytes
        consumed &-= bytes &* 8
        container = UInt64(littleEndian: unsafe position.loadUnaligned(as: UInt64.self))
        return status
    }

    /// Whether every bit of the stream was read, and no more.
    var isAtEnd: Bool {
        unsafe position == start && consumed == 64
    }
}


// MARK: - FSE

/// Pointers to a workspace's scratch for building tables (raw memory: `InlineArray`s passed `borrowing` were
/// copied, 512 bytes, at every subscript in the spreading loop).
@unsafe
struct ZstdTableScratch {
    let counts: UnsafeMutablePointer<Int16>
    let ordered: UnsafeMutablePointer<UInt8>
    let cells: UnsafeMutablePointer<UInt8>
    let next: UnsafeMutablePointer<UInt16>
    let weights: UnsafeMutablePointer<UInt8>

    @inline(__always)
    init(_ workspace: borrowing ZstdWorkspace) {
        // Unsafe: pointers to the workspace's scratch regions, sized for the largest tables.
        unsafe counts = unsafe workspace.pointer(ZstdWorkspace.countsOffset).assumingMemoryBound(to: Int16.self)
        unsafe ordered = unsafe workspace.pointer(ZstdWorkspace.orderedOffset).assumingMemoryBound(to: UInt8.self)
        unsafe cells = unsafe workspace.pointer(ZstdWorkspace.cellsOffset).assumingMemoryBound(to: UInt8.self)
        unsafe next = unsafe workspace.pointer(ZstdWorkspace.nextOffset).assumingMemoryBound(to: UInt16.self)
        unsafe weights = unsafe workspace.pointer(ZstdWorkspace.weightsOffset).assumingMemoryBound(to: UInt8.self)
    }
}

/// Which sequence field a table decodes, for its entries' baselines and extra bits.
enum ZstdSequenceAlphabet {
    case literalLength, offset, matchLength

    var maximumSymbol: Int {
        switch self {
        case .literalLength: Zstd.maximumLiteralLengthCode
        case .offset: Zstd.maximumOffsetCode
        case .matchLength: Zstd.maximumMatchLengthCode
        }
    }

    var maximumTableLog: Int {
        switch self {
        case .literalLength: Zstd.literalLengthTableLogMaximum
        case .offset: Zstd.offsetTableLogMaximum
        case .matchLength: Zstd.matchLengthTableLogMaximum
        }
    }

    /// Where the workspace keeps each code's baseline and extra bits.
    var codesOffset: Int {
        switch self {
        case .literalLength: ZstdWorkspace.literalLengthCodesOffset
        case .offset: ZstdWorkspace.offsetCodesOffset
        case .matchLength: ZstdWorkspace.matchLengthCodesOffset
        }
    }

    /// The baseline and extra-bit count of `code`.
    func baseAndBits(_ code: Int) -> (base: UInt32, bits: UInt8) {
        switch self {
        case .literalLength: (Zstd.literalLengthBase[code], Zstd.literalLengthBits[code])
        case .offset: (Zstd.offsetBase(code), UInt8(code))
        case .matchLength: (Zstd.matchLengthBase[code], Zstd.matchLengthBits[code])
        }
    }
}

// A sequence decoding table entry is 64 bits, as libzstd's `ZSTD_seqSymbol`: the next state's base (bits
// 0–15), the value's extra-bit count (16–23), the state's bit count (24–31), and the value's baseline (32–63).

enum ZstdFSE {
    /// 32 bits of the description at `bitPosition`, zeros past `available` bytes: at least 25 meaningful.
    @inline(__always)
    private static func peek(_ source: UnsafeRawPointer, available: Int, at bitPosition: Int) -> UInt32 {
        let byte = bitPosition &>> 3
        var word: UInt32 = 0
        if byte &+ 4 <= available {
            // Unsafe: a 4-byte load. Safe: within `available` bytes of `source`, checked.
            word = UInt32(littleEndian: unsafe source.loadUnaligned(fromByteOffset: byte, as: UInt32.self))
        } else {
            var index = 0
            while byte &+ index < available, index < 4 {
                // Unsafe: a byte load. Safe: below `available`, checked.
                word |= UInt32(unsafe source.load(fromByteOffset: byte &+ index, as: UInt8.self)) &<< UInt32(8 &* index)
                index &+= 1
            }
        }
        return word &>> UInt32(bitPosition & 7)
    }

    /// Reads an FSE table description (RFC 8878, 4.1.1) at `source`, as libzstd's `FSE_readNCount`.
    ///
    /// - Parameters:
    ///   - source: The description's first byte.
    ///   - available: Bytes from `source` that may belong to it.
    ///   - maximumSymbol: The largest symbol the alphabet has (at most 255).
    ///   - maximumLog: The largest accuracy log allowed.
    ///   - counts: Receives the normalized counts (-1 for "less than one"), `maximumSymbol + 1` of them.
    /// - Returns: The accuracy log, the last symbol described, and the description's size in bytes.
    /// - Throws: ``BytesError/invalidValue`` for an accuracy log too large, counts that don't add up, too many
    ///   symbols, or a description longer than `available`.
    static func readNormalizedCounts(
        _ source: UnsafeRawPointer, available: Int, maximumSymbol: Int, maximumLog: Int,
        into counts: UnsafeMutablePointer<Int16>
    ) throws(BytesError) -> (tableLog: Int, maximumSymbol: Int, size: Int) {
        // Unsafe: stores into `counts`, at indices at most `maximumSymbol` (checked before each).
        for index in 0...maximumSymbol {
            unsafe counts[index] = 0
        }
        let tableLog = Int(unsafe peek(source, available: available, at: 0) & 0xF) &+ 5
        guard tableLog <= maximumLog else { throw .invalidValue }
        var bitPosition = 4
        var remaining = (1 &<< tableLog) &+ 1
        var threshold = 1 &<< tableLog
        var bitCount = tableLog &+ 1
        var symbol = 0
        var previousWasZero = false
        while true {
            if previousWasZero {
                // A run of zero counts: 2-bit repeat fields, 3 meaning "three more, and another field".
                while true {
                    let repeated = Int(unsafe peek(source, available: available, at: bitPosition) & 3)
                    bitPosition &+= 2
                    symbol &+= repeated
                    if repeated != 3 || symbol > maximumSymbol { break }
                }
                guard symbol <= maximumSymbol else { throw .invalidValue }
            }
            let bits = Int(unsafe peek(source, available: available, at: bitPosition))
            let maximum = (2 &* threshold &- 1) &- remaining
            var count: Int
            if bits & (threshold &- 1) < maximum {
                count = bits & (threshold &- 1)
                bitPosition &+= bitCount &- 1
            } else {
                count = bits & (2 &* threshold &- 1)
                if count >= threshold { count &-= maximum }
                bitPosition &+= bitCount
            }
            count &-= 1 // Counts are stored plus one; -1 means "less than one".
            remaining &-= count < 0 ? 1 : count
            unsafe counts[symbol] = Int16(truncatingIfNeeded: count)
            symbol &+= 1
            previousWasZero = count == 0
            if remaining < threshold {
                if remaining <= 1 { break }
                bitCount = Int.bitWidth &- remaining.leadingZeroBitCount // highest bit + 1
                threshold = 1 &<< (bitCount &- 1)
            }
            if symbol > maximumSymbol { break }
        }
        guard remaining == 1, bitPosition <= available &* 8 else { throw .invalidValue }
        return (tableLog, symbol &- 1, (bitPosition &+ 7) &>> 3)
    }

    /// Spreads the symbols of the counts in `scratch` over a table of `1 << tableLog` cells (RFC 8878,
    /// 4.1.1), as libzstd does: "less than one" symbols at the end, the rest stepped through the table. Leaves
    /// each cell's symbol in `scratch.cells`, and each symbol's first state in `scratch.next`.
    ///
    /// - Throws: ``BytesError/invalidValue`` if the counts don't fill the table exactly.
    @inline(__always)
    private static func spread(maximumSymbol: Int, tableLog: Int, scratch: ZstdTableScratch) throws(BytesError) {
        // Unsafe: scratch stores, each index checked against the table size, which the scratch holds (512
        // cells, 8 bytes of slack for the ordered symbols' 8-byte stores).
        let size = 1 &<< tableLog
        let mask = size &- 1
        var high = size &- 1
        for symbol in 0...maximumSymbol {
            let count = Int(unsafe scratch.counts[symbol])
            if count == -1 {
                guard high >= 0 else { throw .invalidValue }
                unsafe scratch.cells[high] = UInt8(truncatingIfNeeded: symbol)
                high &-= 1
                unsafe scratch.next[symbol] = 1
            } else {
                unsafe scratch.next[symbol] = UInt16(truncatingIfNeeded: count)
            }
        }
        let step = (size &>> 1) &+ (size &>> 3) &+ 3
        if high == size &- 1 {
            // No "less than one" symbols: lay the symbols out in order, 8 bytes at a time, then step through
            // them. The same placement as below, without a loop whose length varies per symbol.
            var position = 0
            var value: UInt64 = 0
            for symbol in 0...maximumSymbol {
                let count = Int(unsafe scratch.counts[symbol])
                guard position &+ count <= size else { throw .invalidValue }
                var index = 0
                repeat {
                    unsafe UnsafeMutableRawPointer(scratch.ordered + (position &+ index)).storeBytes(of: value, as: UInt64.self)
                    index &+= 8
                } while index < count
                position &+= count
                value &+= 0x0101_0101_0101_0101
            }
            guard position == size else { throw .invalidValue }
            var cell = 0
            var index = 0
            while index < size {
                unsafe scratch.cells[cell] = scratch.ordered[index]
                unsafe scratch.cells[(cell &+ step) & mask] = scratch.ordered[index &+ 1]
                cell = (cell &+ 2 &* step) & mask
                index &+= 2
            }
            return
        }
        var position = 0
        var placed = 0
        for symbol in 0...maximumSymbol {
            let count = Int(unsafe scratch.counts[symbol])
            var left = count
            while left > 0 {
                guard placed <= high else { throw .invalidValue }
                unsafe scratch.cells[position] = UInt8(truncatingIfNeeded: symbol)
                placed &+= 1
                left &-= 1
                repeat {
                    position = (position &+ step) & mask
                } while position > high
            }
        }
        guard position == 0, placed == high &+ 1 else { throw .invalidValue }
    }

    /// Builds a sequence decoding table at `table`, `1 << tableLog` entries, from the counts in `scratch` and
    /// each code's baseline and extra bits in `codes`.
    ///
    /// States are absolute: `index` is the table's position in the workspace (in entries), and each entry's next
    /// state base includes it, so the decode loop indexes all three tables from one pointer.
    static func buildSequenceTable(
        _ table: UnsafeMutablePointer<UInt64>, index: Int, maximumSymbol: Int, tableLog: Int, codes: UnsafePointer<UInt64>,
        scratch: ZstdTableScratch
    ) throws(BytesError) {
        try unsafe spread(maximumSymbol: maximumSymbol, tableLog: tableLog, scratch: scratch)
        let size = 1 &<< tableLog
        // Unsafe: table stores below `size`, which the caller's table holds; symbols are at most
        // `maximumSymbol`, within `codes` and `next`.
        for cell in 0..<size {
            let symbol = Int(unsafe scratch.cells[cell])
            let state = Int(unsafe scratch.next[symbol])
            unsafe scratch.next[symbol] = UInt16(truncatingIfNeeded: state &+ 1)
            let stateBits = tableLog &- (Int.bitWidth &- 1 &- state.leadingZeroBitCount)
            let nextState = index &+ (state &<< stateBits) &- size
            unsafe table[cell] = codes[symbol] | UInt64(truncatingIfNeeded: stateBits) &<< 24 | UInt64(truncatingIfNeeded: nextState)
        }
    }

    /// Builds the one-entry table of an RLE-coded sequence field: `symbol` always, no bits read, the state staying
    /// at `index`, the entry's own.
    static func buildRLETable(_ table: UnsafeMutablePointer<UInt64>, index: Int, symbol: Int, codes: UnsafePointer<UInt64>) {
        // Unsafe: a store and a load. Safe: every sequence table has an entry, and `symbol` is a valid code.
        unsafe table[0] = codes[symbol] | UInt64(truncatingIfNeeded: index)
    }

    /// Builds a byte-symbol decoding table at `table`: entries with the next state's base (bits 0–15), the
    /// symbol (16–23), and the state's bit count (24–31).
    static func buildByteTable(
        _ table: UnsafeMutablePointer<UInt32>, maximumSymbol: Int, tableLog: Int, scratch: ZstdTableScratch
    ) throws(BytesError) {
        try unsafe spread(maximumSymbol: maximumSymbol, tableLog: tableLog, scratch: scratch)
        let size = 1 &<< tableLog
        // Unsafe: table stores below `size`, which the caller's table holds.
        for cell in 0..<size {
            let symbol = Int(unsafe scratch.cells[cell])
            let state = Int(unsafe scratch.next[symbol])
            unsafe scratch.next[symbol] = UInt16(truncatingIfNeeded: state &+ 1)
            let stateBits = tableLog &- (Int.bitWidth &- 1 &- state.leadingZeroBitCount)
            let nextState = (state &<< stateBits) &- size
            unsafe table[cell] = UInt32(truncatingIfNeeded: nextState) | UInt32(truncatingIfNeeded: symbol) &<< 16
                | UInt32(truncatingIfNeeded: stateBits) &<< 24
        }
    }
}

// MARK: - Huffman

enum ZstdHuffman {
    /// The longest code libzstd accepts (RFC 8878 caps codes at 11 bits).
    static var tableLogMaximum: Int { 12 }
    /// The table width the fast loops decode with: shorter codes are rescaled to it.
    static var fastTableLog: Int { 11 }

    /// Reads a Huffman tree description (RFC 8878, 4.2.1) at `source` into `scratch.weights`: the weights,
    /// direct or FSE-coded, and the implied last one.
    ///
    /// - Parameters:
    ///   - source: The description's header byte.
    ///   - available: The bytes that may belong to it.
    ///   - weightTable: Room for the FSE table that decodes weights (64 entries).
    /// - Returns: The number of symbols (the last one's weight included), the longest code's length, and the
    ///   description's size in bytes.
    /// - Throws: ``BytesError/invalidValue`` for a description that's truncated or doesn't make a valid code.
    static func readWeights(
        _ source: UnsafeRawPointer, available: Int, weightTable: UnsafeMutablePointer<UInt32>, scratch: ZstdTableScratch
    ) throws(BytesError) -> (symbolCount: Int, tableLog: Int, size: Int) {
        guard available >= 1 else { throw .invalidValue }
        // Unsafe: loads within `available` bytes of `source`, each checked first, and stores into the
        // 256-byte weights scratch at indices below 256.
        let header = Int(unsafe source.load(as: UInt8.self))
        let count: Int
        let size: Int
        if header >= 128 {
            // Direct: 4 bits per weight, two per byte, the first in the high nibble.
            count = header &- 127
            size = (count &+ 1) &>> 1
            guard size &+ 1 <= available else { throw .invalidValue }
            for index in 0..<count {
                let byte = unsafe source.load(fromByteOffset: 1 &+ index &>> 1, as: UInt8.self)
                unsafe scratch.weights[index] = index & 1 == 0 ? byte &>> 4 : byte & 0xF
            }
        } else {
            size = header
            guard size &+ 1 <= available else { throw .invalidValue }
            count = try unsafe decodeWeights(source + 1, count: size, table: weightTable, scratch: scratch)
        }
        guard count < 256 else { throw .invalidValue }

        var total = 0
        var weightOneCount = 0
        for index in 0..<count {
            let weight = Int(unsafe scratch.weights[index])
            guard weight <= tableLogMaximum else { throw .invalidValue }
            if weight == 1 { weightOneCount &+= 1 }
            total &+= (1 &<< weight) &>> 1
        }
        guard total > 0 else { throw .invalidValue }
        // The last weight makes the total the next power of two.
        let tableLog = Int.bitWidth &- total.leadingZeroBitCount // highest bit + 1
        guard tableLog <= tableLogMaximum else { throw .invalidValue }
        let rest = (1 &<< tableLog) &- total
        guard rest & (rest &- 1) == 0 else { throw .invalidValue }
        let lastWeight = Int.bitWidth &- rest.leadingZeroBitCount // highest bit + 1
        unsafe scratch.weights[count] = UInt8(truncatingIfNeeded: lastWeight)
        if lastWeight == 1 { weightOneCount &+= 1 }
        // A valid tree has an even number of weight-1 (longest) codes, at least two.
        guard weightOneCount >= 2, weightOneCount & 1 == 0 else { throw .invalidValue }
        return (count &+ 1, tableLog, size &+ 1)
    }

    /// Decodes FSE-coded weights (accuracy log at most 6, two interleaved states) into `scratch.weights`, as
    /// libzstd's `FSE_decompress_wksp`, which stops when the bitstream overflows.
    ///
    /// - Returns: The number of weights decoded, at most 255.
    private static func decodeWeights(
        _ source: UnsafeRawPointer, count: Int, table: UnsafeMutablePointer<UInt32>, scratch: ZstdTableScratch
    ) throws(BytesError) -> Int {
        let (tableLog, maximumSymbol, headerSize) = try unsafe ZstdFSE.readNormalizedCounts(
            source, available: count, maximumSymbol: 255, maximumLog: 6, into: scratch.counts
        )
        try unsafe ZstdFSE.buildByteTable(table, maximumSymbol: maximumSymbol, tableLog: tableLog, scratch: scratch)
        // Unsafe: the weights' bitstream, table, and output. Safe: the stream is the rest of the `count` bytes;
        // FSE states stay below the table's `1 << tableLog` entries by construction; outputs are below 255.
        var bits = try unsafe ZstdReverseBits(source + headerSize, count: count &- headerSize)
        var state1 = bits.read(tableLog)
        _ = bits.reloadStatus()
        var state2 = bits.read(tableLog)
        _ = bits.reloadStatus()
        guard bits.reloadStatus() != .overflow else { throw .invalidValue }
        let weights = unsafe scratch.weights

        @inline(__always)
        func decode(_ state: inout Int) -> UInt8 {
            let entry = unsafe table[state]
            let low = bits.read(Int(entry &>> 24))
            state = Int(entry & 0xFFFF) &+ low
            return UInt8(truncatingIfNeeded: entry &>> 16)
        }

        let capacity = 255
        var produced = 0
        while bits.reloadStatus() == .unfinished, produced < capacity &- 3 {
            unsafe weights[produced] = decode(&state1)
            unsafe weights[produced &+ 1] = decode(&state2)
            unsafe weights[produced &+ 2] = decode(&state1)
            unsafe weights[produced &+ 3] = decode(&state2)
            produced &+= 4
        }
        while true {
            guard produced <= capacity &- 2 else { throw .invalidValue }
            unsafe weights[produced] = decode(&state1)
            produced &+= 1
            if bits.reloadStatus() == .overflow {
                unsafe weights[produced] = decode(&state2)
                produced &+= 1
                break
            }
            guard produced <= capacity &- 2 else { throw .invalidValue }
            unsafe weights[produced] = decode(&state2)
            produced &+= 1
            if bits.reloadStatus() == .overflow {
                unsafe weights[produced] = decode(&state1)
                produced &+= 1
                break
            }
        }
        return produced
    }

    /// Builds a single-symbol decoding table (libzstd's X1) at `table` from the weights in `weights`:
    /// entries of `symbol << 8 | length`, indexed by the next `tableLog` bits. Codes shorter than
    /// ``fastTableLog`` are rescaled to it, so the fast loop always looks up 11 bits.
    ///
    /// - Returns: The table's index width.
    static func buildSingleTable(
        _ table: UnsafeMutablePointer<UInt16>, weights: UnsafePointer<UInt8>, symbolCount: Int, tableLog: Int
    ) -> Int {
        // Lengthening every code by the same number of bits doubles each symbol's entries that many times.
        let scale = max(0, fastTableLog &- tableLog)
        let width = tableLog &+ scale
        var rankCounts = InlineArray<16, Int>(repeating: 0)
        // Unsafe: weight loads below `symbolCount` (at most 256), and table stores below `size`.
        for symbol in 0..<symbolCount {
            rankCounts[Int(unsafe weights[symbol]) & 15] &+= 1
        }
        // Symbols ordered by weight, then value: weight 1 (the longest codes) first, at the lowest indices.
        var rankStart = InlineArray<16, Int>(repeating: 0)
        var next = 0
        for weight in 1...tableLogMaximum {
            rankStart[weight] = next
            next &+= rankCounts[weight] &<< (weight &- 1 &+ scale)
        }
        let size = 1 &<< width
        for symbol in 0..<symbolCount {
            let weight = Int(unsafe weights[symbol]) & 15
            guard weight > 0 else { continue }
            let length = 1 &<< (weight &- 1 &+ scale)
            let start = rankStart[weight]
            rankStart[weight] = start &+ length
            // The weights fill exactly `size` entries (they were checked to sum to a power of two); this keeps
            // every store below it regardless.
            guard start &+ length <= size else { continue }
            let entry = UInt16(truncatingIfNeeded: symbol &<< 8 | (width &+ 1 &- (weight &+ scale)))
            if length >= 4 {
                let four = UInt64(entry) &* 0x0001_0001_0001_0001
                var index = 0
                repeat {
                    unsafe UnsafeMutableRawPointer(table + (start &+ index)).storeBytes(of: four, as: UInt64.self)
                    index &+= 4
                } while index < length
            } else {
                unsafe table[start] = entry
                if length == 2 { unsafe table[start &+ 1] = entry }
            }
        }
        return width
    }
}
