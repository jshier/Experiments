internal import Bytes

// Zstandard's entropy coders, encoding side (RFC 8878, section 4): the forward bit writer that makes backward
// bitstreams, FSE normalization, table descriptions, and encoding tables, and Huffman trees limited to 11 bits with
// their weight descriptions. Each follows libzstd 1.5.7 (`fse_compress.c`, `huf_compress.c`, `bitstream.h`) decision
// for decision, so a block's tables and streams come out as libzstd's do; the tests compare whole frames byte for byte.

// MARK: - Bit writer

/// libzstd's `BIT_CStream_t`: bits added at increasing positions of a 64-bit container, flushed little-endian a
/// whole number of bytes at a time. A decoder reads the result from its end (``ZstdReverseBits``), so what's
/// written last is read first: sequences and Huffman symbols are written from the last to the first.
///
/// Every flush stores 8 bytes at ``pointer``, which never passes ``limit`` (8 bytes before the buffer's end): a
/// stream that would overflow stops advancing there, and ``close()`` reports it as 0, as libzstd's does. So the
/// stores need no checks, and an encoder learns only at the end that its output didn't fit.
@safe
struct ZstdBitWriter {
    var container: UInt64 = 0
    var bitCount = 0
    var pointer: UnsafeMutableRawPointer
    let start: UnsafeMutableRawPointer
    let limit: UnsafeMutableRawPointer

    /// A writer over `capacity` bytes at `start`, or `nil` if that's no more than 8 (`BIT_initCStream`'s check).
    @unsafe @inline(__always)
    init?(_ start: UnsafeMutableRawPointer, capacity: Int) {
        guard capacity > 8 else { return nil }
        unsafe self.start = start
        unsafe pointer = start
        unsafe limit = start + (capacity &- 8)
    }

    /// Adds the low `count` bits of `value` (`count` at most 32, and at most 63 bits buffered after).
    @inline(__always)
    mutating func add(_ value: UInt64, _ count: Int) {
        container |= (value & ((1 &<< UInt64(truncatingIfNeeded: count)) &- 1)) &<< UInt64(truncatingIfNeeded: bitCount)
        bitCount &+= count
    }

    /// Adds `value`, which has no bits above the low `count`.
    @inline(__always)
    mutating func addFast(_ value: UInt64, _ count: Int) {
        container |= value &<< UInt64(truncatingIfNeeded: bitCount)
        bitCount &+= count
    }

    /// Writes the container's whole bytes (`BIT_flushBits`).
    @inline(__always)
    mutating func flush() {
        let bytes = bitCount &>> 3
        // Unsafe: an 8-byte store. Safe: `pointer <= limit`, 8 bytes before the end of the buffer (kept so below).
        unsafe pointer.storeBytes(of: container.littleEndian, as: UInt64.self)
        unsafe pointer += bytes
        if unsafe pointer > limit { unsafe pointer = limit }
        bitCount &= 7
        // At most 63 bits are ever buffered, so at most 7 bytes go.
        container = container &>> UInt64(truncatingIfNeeded: bytes &<< 3)
    }

    /// Adds the end marker and writes the rest.
    ///
    /// - Returns: The stream's size in bytes, or 0 if it didn't fit.
    @inline(__always)
    mutating func close() -> Int {
        addFast(1, 1)
        flush()
        // Unsafe: pointer comparisons and distance within the buffer.
        if unsafe pointer >= limit { return 0 }
        return unsafe (pointer - start) &+ (bitCount > 0 ? 1 : 0)
    }
}

/// libzstd's `HUF_CStream_t`: Huffman codes added at the top of a 64-bit container that shifts right, so a code
/// table entry (its value in the top bits, its length in the low 8) goes in with one shift and one OR, the shift amount
/// the entry itself (a shift uses its amount's low 6 bits). The low bits an entry ORs in are below the valid bits, and
/// shifted out before a flush reads them, as long as at least 4 bits stay free ("fast" adds); a group's last add may
/// need to clear them. Positions keep the bit count in their low 8 bits (the entries' value bits land above). Two
/// containers, so a group can be built while the previous one shifts in.
@safe
struct ZstdHuffmanWriter {
    var container0: UInt64 = 0
    var container1: UInt64 = 0
    var position0: UInt64 = 0
    var position1: UInt64 = 0
    var pointer: UnsafeMutableRawPointer
    let start: UnsafeMutableRawPointer
    let limit: UnsafeMutableRawPointer

    /// A writer over `capacity` bytes at `start`, or `nil` if that's no more than 8.
    @unsafe @inline(__always)
    init?(_ start: UnsafeMutableRawPointer, capacity: Int) {
        guard capacity > 8 else { return nil }
        unsafe self.start = start
        unsafe pointer = start
        unsafe limit = start + (capacity &- 8)
    }

    @inline(__always)
    mutating func add0(_ entry: UInt64, fast: Bool) {
        container0 = (container0 &>> entry) | (fast ? entry : entry & ~0xFF)
        position0 &+= entry
    }

    @inline(__always)
    mutating func add1(_ entry: UInt64, fast: Bool) {
        container1 = (container1 &>> entry) | (fast ? entry : entry & ~0xFF)
        position1 &+= entry
    }

    /// Shifts the second container's codes in after the first's (`HUF_mergeIndex1`).
    @inline(__always)
    mutating func merge1() {
        container0 = (container0 &>> (position1 & 0xFF)) | container1
        position0 &+= position1
    }

    /// Writes the whole bytes (`HUF_flushBits`); unless `fast`, the pointer stops at the limit (the caller then finds
    /// the stream didn't fit). Fast flushes rely on the caller's bound instead.
    @inline(__always)
    mutating func flush(fast: Bool) {
        let bits = position0 & 0xFF
        // Unsafe: an 8-byte store at `pointer`, which stays at or below `limit`, 8 bytes before the buffer's end (by
        // the clamp, or by the caller's bound for fast flushes).
        unsafe pointer.storeBytes(of: (container0 &>> (64 &- bits)).littleEndian, as: UInt64.self)
        position0 &= 7
        unsafe pointer += Int(truncatingIfNeeded: bits &>> 3)
        if !fast && (unsafe pointer > limit) { unsafe pointer = limit }
    }

    /// Adds the end marker and writes the rest (`HUF_closeCStream`).
    ///
    /// - Returns: The stream's size, or 0 if it didn't fit.
    @inline(__always)
    mutating func close() -> Int {
        add0(1 | 1 &<< 63, fast: false)
        flush(fast: false)
        // Unsafe: pointer comparison and distance within the buffer.
        if unsafe pointer >= limit { return 0 }
        return unsafe (pointer - start) &+ (position0 & 0xFF > 0 ? 1 : 0)
    }
}

// MARK: - FSE

/// An FSE encoding table in a workspace (libzstd's `FSE_CTable`): next states by symbol (`UInt16`s, from the start
/// of the region), then each symbol's transform at ``symbolOffset``: the bits it costs (high 16 bits of a threshold,
/// `deltaNbBits`) and where its states start (`deltaFindState`), packed in a `UInt64`.
enum ZstdFSETable {
    /// Where the symbol transforms start in a table's region: after 512 states (log 9, the sequences' largest).
    static var symbolOffset: Int { 1024 }
    /// A table's region: states, then up to 64 symbols' transforms.
    static var regionSize: Int { symbolOffset + 64 * 8 }
    /// Scratch for ``build(_:normalized:maximumSymbol:tableLog:scratch:)``: cumulative counts, then the spread.
    static var scratchSize: Int { 160 + 2 * 512 + 16 }

    /// libzstd's `FSE_TABLESTEP`: how far apart consecutive cells of a symbol are spread.
    @inline(__always)
    static func step(_ size: Int) -> Int { (size &>> 1) &+ (size &>> 3) &+ 3 }

    /// Builds the table for the normalized counts `normalized` (-1 for "less than one") at `table`
    /// (`FSE_buildCTable_wksp`), with zstd's spread, so a decoder building from the same counts mirrors it.
    static func build(
        _ table: UnsafeMutableRawPointer, normalized: UnsafePointer<Int16>, maximumSymbol: Int, tableLog: Int,
        scratch: UnsafeMutableRawPointer
    ) {
        // Unsafe: the table's and scratch's regions through pointers. Safe: states are below `1 << tableLog` (at most
        // 512), symbols at most `maximumSymbol` (below 64), cumulative counts below the scratch's 80 entries, and the
        // spread's 8-byte stores within its `2 * size + 8` bytes. (On spans, the per-cell checks of data-dependent
        // indexes, `cumulative[symbol]` and `states[slot]`, cost about 4 K instructions a block with new tables.)
        let size = 1 &<< tableLog
        let mask = size &- 1
        let states = unsafe table.assumingMemoryBound(to: UInt16.self)
        let transforms = unsafe (table + symbolOffset).assumingMemoryBound(to: UInt64.self)
        let cumulative = unsafe scratch.assumingMemoryBound(to: UInt16.self)
        let cells = unsafe (scratch + 160).assumingMemoryBound(to: UInt8.self)
        let symbolCount = maximumSymbol &+ 1
        var highThreshold = size &- 1

        unsafe cumulative[0] = 0
        for symbol in 1...symbolCount {
            let count = Int(unsafe normalized[symbol &- 1])
            if count == -1 {
                unsafe cumulative[symbol] = cumulative[symbol &- 1] &+ 1
                unsafe cells[highThreshold] = UInt8(truncatingIfNeeded: symbol &- 1)
                highThreshold &-= 1
            } else {
                unsafe cumulative[symbol] = cumulative[symbol &- 1] &+ UInt16(truncatingIfNeeded: count)
            }
        }
        unsafe cumulative[symbolCount] = UInt16(truncatingIfNeeded: size &+ 1)

        let step = step(size)
        if highThreshold == size &- 1 {
            // No "less than one" symbols: lay the symbols out in order 8 bytes at a time, then step through them.
            let spread = unsafe cells + size
            var position = 0
            var value: UInt64 = 0
            for symbol in 0..<symbolCount {
                let count = Int(unsafe normalized[symbol])
                unsafe UnsafeMutableRawPointer(spread + position).storeBytes(of: value, as: UInt64.self)
                var index = 8
                while index < count {
                    unsafe UnsafeMutableRawPointer(spread + (position &+ index)).storeBytes(of: value, as: UInt64.self)
                    index &+= 8
                }
                position &+= count
                value &+= 0x0101_0101_0101_0101
            }
            var cell = 0
            var index = 0
            while index < size {
                unsafe cells[cell & mask] = spread[index]
                unsafe cells[(cell &+ step) & mask] = spread[index &+ 1]
                cell = (cell &+ 2 &* step) & mask
                index &+= 2
            }
        } else {
            var position = 0
            for symbol in 0..<symbolCount {
                let count = Int(unsafe normalized[symbol])
                var placed = 0
                while placed < count {
                    unsafe cells[position] = UInt8(truncatingIfNeeded: symbol)
                    position = (position &+ step) & mask
                    while position > highThreshold { position = (position &+ step) & mask }
                    placed &+= 1
                }
            }
        }

        // Next states, sorted by symbol.
        for cell in 0..<size {
            let symbol = Int(unsafe cells[cell])
            let slot = Int(unsafe cumulative[symbol])
            unsafe cumulative[symbol] = UInt16(truncatingIfNeeded: slot &+ 1)
            unsafe states[slot] = UInt16(truncatingIfNeeded: size &+ cell)
        }

        // Each symbol's transform.
        var total = 0
        for symbol in 0..<symbolCount {
            let count = Int(unsafe normalized[symbol])
            let deltaNbBits: Int
            var deltaFindState = 0
            switch count {
            case 0:
                deltaNbBits = ((tableLog &+ 1) &<< 16) &- size
            case -1, 1:
                deltaNbBits = (tableLog &<< 16) &- size
                deltaFindState = total &- 1
                total &+= 1
            default:
                let maximumBitsOut = tableLog &- (Int.bitWidth &- 1 &- (count &- 1).leadingZeroBitCount)
                let minimumStatePlus = count &<< maximumBitsOut
                deltaNbBits = (maximumBitsOut &<< 16) &- minimumStatePlus
                deltaFindState = total &- count
                total &+= count
            }
            unsafe transforms[symbol] = UInt64(UInt32(truncatingIfNeeded: deltaNbBits))
                | UInt64(UInt32(truncatingIfNeeded: deltaFindState)) &<< 32
        }
    }

    /// Builds the table of an RLE-coded field (`FSE_buildCTable_rle`): log 0, so encoding `symbol` writes nothing.
    static func buildRLE(_ table: UnsafeMutableRawPointer, symbol: Int) {
        // Unsafe: stores at the region's start and at `symbol`'s transform, below 64.
        unsafe table.storeBytes(of: 0, as: UInt32.self)
        unsafe (table + symbolOffset).storeBytes(of: 0, toByteOffset: symbol &* 8, as: UInt64.self)
    }

    /// `FSE_bitCost`: the cost of `symbol` in 1/256 bits (`accuracyLog` 8), from its transform.
    @inline(__always)
    static func bitCost(_ table: UnsafeRawPointer, tableLog: Int, symbol: Int, accuracyLog: Int) -> Int {
        // Unsafe: a transform load, `symbol` within the table's symbols (checked by the caller).
        let transform = unsafe (table + symbolOffset).load(fromByteOffset: symbol &* 8, as: UInt64.self)
        let deltaNbBits = Int(UInt32(truncatingIfNeeded: transform))
        let minimumBits = deltaNbBits &>> 16
        let threshold = (minimumBits &+ 1) &<< 16
        let size = 1 &<< tableLog
        let deltaFromThreshold = threshold &- (deltaNbBits &+ size)
        let normalizedDelta = (deltaFromThreshold &<< accuracyLog) &>> tableLog
        return (minimumBits &+ 1) &* (1 &<< accuracyLog) &- normalizedDelta
    }
}

/// An FSE encoder's state for one table (libzstd's `FSE_CState_t`).
@safe
struct ZstdFSEState {
    var value: UInt32
    let states: UnsafePointer<UInt16>
    let transforms: UnsafePointer<UInt64>
    let tableLog: Int

    /// Starts on `symbol`, the last one to be written, with no bits out (`FSE_initCState2`).
    @unsafe @inline(__always)
    init(_ table: UnsafeRawPointer, tableLog: Int, symbol: Int) {
        unsafe states = table.assumingMemoryBound(to: UInt16.self)
        unsafe transforms = (table + ZstdFSETable.symbolOffset).assumingMemoryBound(to: UInt64.self)
        self.tableLog = tableLog
        // Unsafe: a transform and a state load; the state index is within the table by construction.
        let transform = unsafe transforms[symbol]
        let deltaNbBits = UInt32(truncatingIfNeeded: transform)
        let deltaFindState = Int(Int32(truncatingIfNeeded: transform &>> 32))
        let bitsOut = (deltaNbBits &+ (1 &<< 15)) &>> 16
        let start = (bitsOut &<< 16) &- deltaNbBits
        value = UInt32(unsafe states[Int(start &>> bitsOut) &+ deltaFindState])
    }

    /// Encodes `symbol`: writes the state's low bits and moves to the next state (`FSE_encodeSymbol`).
    @inline(__always)
    mutating func encode(_ symbol: Int, into writer: inout ZstdBitWriter) {
        // Unsafe: a transform and a state load; states stay within the table by construction.
        let transform = unsafe transforms[symbol]
        let deltaNbBits = UInt32(truncatingIfNeeded: transform)
        let deltaFindState = Int(Int32(truncatingIfNeeded: transform &>> 32))
        let bitsOut = Int((value &+ deltaNbBits) &>> 16)
        writer.add(UInt64(value), bitsOut)
        value = UInt32(unsafe states[Int(value &>> UInt32(truncatingIfNeeded: bitsOut)) &+ deltaFindState])
    }

    /// Writes the final state, which the decoder reads first (`FSE_flushCState`).
    @inline(__always)
    func flush(into writer: inout ZstdBitWriter) {
        writer.add(UInt64(value), tableLog)
        writer.flush()
    }
}

/// FSE's normalization and table descriptions (`fse_compress.c`).
enum ZstdFSEEncoding {
    static var minimumTableLog: Int { 5 }
    static var maximumTableLog: Int { 12 }

    @inline(__always)
    static func highBit(_ value: Int) -> Int { Int.bitWidth &- 1 &- value.leadingZeroBitCount }

    /// `FSE_minTableLog`: the least accuracy that represents `total` symbols drawn from `maximumSymbol + 1`.
    static func minimumTableLog(total: Int, maximumSymbol: Int) -> Int {
        min(highBit(total) &+ 1, highBit(maximumSymbol) &+ 2)
    }

    /// `FSE_optimalTableLog_internal`: the accuracy for `total` symbols, at most `maximumTableLog`.
    static func optimalTableLog(_ maximumLog: Int, total: Int, maximumSymbol: Int, minus: Int = 2) -> Int {
        let maximumBitsSource = highBit(total &- 1) &- minus
        var tableLog = maximumLog
        if maximumBitsSource < tableLog { tableLog = maximumBitsSource }
        let minimumBits = minimumTableLog(total: total, maximumSymbol: maximumSymbol)
        if minimumBits > tableLog { tableLog = minimumBits }
        return min(max(tableLog, minimumTableLog), maximumTableLog)
    }

    /// `FSE_normalizeCount`: scales `counts` (summing to `total`) to `1 << tableLog`, rare symbols to -1 ("less
    /// than one") or 1.
    ///
    /// - Returns: Whether it succeeded (the secondary method can fail on pathological counts).
    static func normalize(
        _ normalized: inout MutableSpan<Int16>, tableLog: Int, counts: Span<UInt32>, total: Int, maximumSymbol: Int,
        useLowProbabilityCount: Bool
    ) -> Bool {
        // Checked accesses at symbols up to `maximumSymbol`, which both spans hold: the loops' checks fold.
        precondition(maximumSymbol < normalized.count && maximumSymbol < counts.count)
        let restToBeat: InlineArray<8, UInt64> = [0, 473_195, 504_333, 520_860, 550_000, 700_000, 750_000, 830_000]
        let lowProbabilityCount: Int16 = useLowProbabilityCount ? -1 : 1
        let scale = UInt64(62 &- tableLog)
        let step = (UInt64(1) &<< 62) / UInt64(total)
        let vStep = UInt64(1) &<< (scale &- 20)
        var stillToDistribute = 1 &<< tableLog
        var largest = 0
        var largestProbability: Int16 = 0
        let lowThreshold = UInt32(truncatingIfNeeded: total &>> tableLog)
        for symbol in 0...maximumSymbol {
            let count = counts[symbol]
            if count == 0 {
                normalized[symbol] = 0
                continue
            }
            if count <= lowThreshold {
                normalized[symbol] = lowProbabilityCount
                stillToDistribute &-= 1
            } else {
                let scaled = UInt64(count) &* step
                var probability = Int16(truncatingIfNeeded: scaled &>> scale)
                if probability < 8 {
                    let rest = vStep &* restToBeat[Int(probability)]
                    if scaled &- (UInt64(probability) &<< scale) > rest { probability &+= 1 }
                }
                if probability > largestProbability {
                    largestProbability = probability
                    largest = symbol
                }
                normalized[symbol] = probability
                stillToDistribute &-= Int(probability)
            }
        }
        if -stillToDistribute >= Int(normalized[largest]) &>> 1 {
            return normalizeSecondary(
                &normalized, tableLog: tableLog, counts: counts, total: total, maximumSymbol: maximumSymbol,
                lowProbabilityCount: lowProbabilityCount
            )
        }
        normalized[largest] &+= Int16(truncatingIfNeeded: stillToDistribute)
        return true
    }

    /// `FSE_normalizeM2`: the secondary method, when rounding left the largest symbol too little.
    private static func normalizeSecondary(
        _ normalized: inout MutableSpan<Int16>, tableLog: Int, counts: Span<UInt32>, total: Int, maximumSymbol: Int,
        lowProbabilityCount: Int16
    ) -> Bool {
        // Checked accesses, as `normalize`.
        precondition(maximumSymbol < normalized.count && maximumSymbol < counts.count)
        let notYetAssigned: Int16 = -2
        var distributed = 0
        var total = total
        let lowThreshold = total &>> tableLog
        var lowOne = (total &* 3) &>> (tableLog &+ 1)
        for symbol in 0...maximumSymbol {
            let count = Int(counts[symbol])
            if count == 0 {
                normalized[symbol] = 0
            } else if count <= lowThreshold {
                normalized[symbol] = lowProbabilityCount
                distributed &+= 1
                total &-= count
            } else if count <= lowOne {
                normalized[symbol] = 1
                distributed &+= 1
                total &-= count
            } else {
                normalized[symbol] = notYetAssigned
            }
        }
        var toDistribute = (1 &<< tableLog) &- distributed
        if toDistribute == 0 { return true }
        if total / toDistribute > lowOne {
            lowOne = (total &* 3) / (toDistribute &* 2)
            for symbol in 0...maximumSymbol {
                let count = Int(counts[symbol])
                if normalized[symbol] == notYetAssigned && count <= lowOne {
                    normalized[symbol] = 1
                    distributed &+= 1
                    total &-= count
                }
            }
            toDistribute = (1 &<< tableLog) &- distributed
        }
        if distributed == maximumSymbol &+ 1 {
            // Every value is poor: give the rest to the most frequent.
            var maximumValue = 0
            var maximumCount: UInt32 = 0
            for symbol in 0...maximumSymbol where counts[symbol] > maximumCount {
                maximumValue = symbol
                maximumCount = counts[symbol]
            }
            normalized[maximumValue] &+= Int16(truncatingIfNeeded: toDistribute)
            return true
        }
        if total == 0 {
            var symbol = 0
            while toDistribute > 0 {
                if normalized[symbol] > 0 {
                    toDistribute &-= 1
                    normalized[symbol] &+= 1
                }
                symbol = (symbol &+ 1) % (maximumSymbol &+ 1)
            }
            return true
        }
        let vStepLog = UInt64(62 &- tableLog)
        let mid = (UInt64(1) &<< (vStepLog &- 1)) &- 1
        let rStep = ((UInt64(1) &<< vStepLog) &* UInt64(toDistribute) &+ mid) / UInt64(total)
        var running = mid
        for symbol in 0...maximumSymbol where normalized[symbol] == notYetAssigned {
            let end = running &+ UInt64(counts[symbol]) &* rStep
            let weight = Int(end &>> vStepLog) &- Int(running &>> vStepLog)
            if weight < 1 { return false }
            normalized[symbol] = Int16(truncatingIfNeeded: weight)
            running = end
        }
        return true
    }

    /// The most bytes ``writeDescription(_:normalized:maximumSymbol:tableLog:)`` writes for an alphabet of up to 64
    /// symbols at log 9 (`FSE_NCountWriteBound`, plus the 2-byte flushes).
    static var descriptionBound: Int { 80 }

    /// Writes the table description of `normalized` at the start of `output` (`FSE_writeNCount`).
    ///
    /// - Returns: Its size in bytes.
    static func writeDescription(
        _ output: UnsafeMutableRawPointer, normalized: Span<Int16>, maximumSymbol: Int, tableLog: Int
    ) -> Int {
        // Checked loads of the counts (up to `maximumSymbol`, which the span holds: their checks fold). Unsafe: stores
        // to `output`, which has room for `descriptionBound` bytes: at most one 2-byte flush per symbol or per 24 zero
        // symbols, plus the last two. (Checked stores to a span cost about 20 instructions a symbol.)
        precondition(maximumSymbol < normalized.count)
        var out = 0
        var bitStream = UInt32(truncatingIfNeeded: tableLog &- minimumTableLog)
        var bitCount = 4
        let size = 1 &<< tableLog
        var remaining = size &+ 1
        var threshold = size
        var bits = tableLog &+ 1
        var symbol = 0
        let alphabetSize = maximumSymbol &+ 1
        var previousWasZero = false

        while symbol < alphabetSize && remaining > 1 {
            if previousWasZero {
                var start = symbol
                while symbol < alphabetSize && normalized[symbol] == 0 { symbol &+= 1 }
                if symbol == alphabetSize { break }
                while symbol >= start &+ 24 {
                    start &+= 24
                    bitStream &+= 0xFFFF &<< UInt32(truncatingIfNeeded: bitCount)
                    unsafe flush16(output, &out, &bitStream)
                }
                while symbol >= start &+ 3 {
                    start &+= 3
                    bitStream &+= 3 &<< UInt32(truncatingIfNeeded: bitCount)
                    bitCount &+= 2
                }
                bitStream &+= UInt32(truncatingIfNeeded: symbol &- start) &<< UInt32(truncatingIfNeeded: bitCount)
                bitCount &+= 2
                if bitCount > 16 {
                    unsafe flush16(output, &out, &bitStream)
                    bitCount &-= 16
                }
            }
            var count = Int(normalized[symbol])
            symbol &+= 1
            let maximum = (2 &* threshold &- 1) &- remaining
            remaining &-= count < 0 ? -count : count
            count &+= 1
            if count >= threshold { count &+= maximum }
            bitStream &+= UInt32(truncatingIfNeeded: count) &<< UInt32(truncatingIfNeeded: bitCount)
            bitCount &+= bits
            if count < maximum { bitCount &-= 1 }
            previousWasZero = count == 1
            while remaining < threshold {
                bits &-= 1
                threshold &>>= 1
            }
            if bitCount > 16 {
                unsafe flush16(output, &out, &bitStream)
                bitCount &-= 16
            }
        }
        unsafe output.storeBytes(of: UInt16(truncatingIfNeeded: bitStream).littleEndian, toByteOffset: out, as: UInt16.self)
        out &+= (bitCount &+ 7) / 8
        return out
    }

    /// Writes the low 16 bits of `bitStream` at `out`, and moves both past them.
    @inline(__always)
    private static func flush16(_ output: UnsafeMutableRawPointer, _ out: inout Int, _ bitStream: inout UInt32) {
        // Unsafe: a 2-byte store within the description's room (see `writeDescription`).
        unsafe output.storeBytes(of: UInt16(truncatingIfNeeded: bitStream).littleEndian, toByteOffset: out, as: UInt16.self)
        out &+= 2
        bitStream = bitStream &>> 16
    }
}

// MARK: - Histograms

enum ZstdHistogram {
    /// Counts the `count` bytes at `source` into `counts` (`maximumSymbol + 1` entries, zeroed first), and lowers
    /// `maximumSymbol` to the largest present (`HIST_count_simple`).
    ///
    /// - Returns: The largest count.
    @inline(__always)
    static func count(_ source: Span<UInt8>, into counts: inout MutableSpan<UInt32>, maximumSymbol: inout Int) -> Int {
        // Checked accesses: the bytes' indexes fold; the counts' fold for a 256-entry table, and are checked for a
        // smaller one (the callers' bound for what the bytes hold: Huffman weights).
        precondition(maximumSymbol < counts.count)
        // Only the counts that can be read: `buildTable` passes 256 entries for at most 53 symbols.
        var used = counts._mutatingExtracting(0..<(maximumSymbol &+ 1))
        used.update(repeating: 0)
        if source.isEmpty {
            maximumSymbol = 0
            return 0
        }
        if counts.count >= 256 {
            for index in source.indices { counts[Int(source[index])] &+= 1 }
        } else {
            for index in source.indices { counts[Int(source[index])] &+= 1 }
        }
        while counts[maximumSymbol] == 0 { maximumSymbol &-= 1 }
        var largest: UInt32 = 0
        for symbol in 0...maximumSymbol { largest = max(largest, counts[symbol]) }
        return Int(largest)
    }

    /// Counts bytes as ``count(_:into:maximumSymbol:)`` does with four interleaved tables, for large inputs
    /// (`HIST_count_parallel_wksp`): the same result, without each increment waiting on the previous one when
    /// neighbouring bytes are equal.
    static func countBytes(
        _ source: Span<UInt8>, into counts: inout MutableSpan<UInt32>, scratch: inout MutableSpan<UInt32>,
        maximumSymbol: inout Int
    ) -> Int {
        guard source.count >= 1500 else {
            return Self.count(source, into: &counts, maximumSymbol: &maximumSymbol)
        }
        // Checked accesses that fold: 8-byte words as elements (byte arrays, so any address is aligned for them; read
        // with `bitCast`, which keeps them in registers), four 256-entry tables in `scratch` (1,024 entries) at byte
        // values, and 256 counts.
        precondition(scratch.count == 1024 && counts.count >= 256)
        scratch.update(repeating: 0)
        let words = Span<InlineArray<8, UInt8>>(viewing: source.bytes.extracting(first: source.count & ~15))
        for index in words.indices {
            let word = bitCast(words[index], to: UInt64.self)
            scratch[Int(truncatingIfNeeded: word & 0xFF)] &+= 1
            scratch[256 &+ Int(truncatingIfNeeded: (word &>> 8) & 0xFF)] &+= 1
            scratch[512 &+ Int(truncatingIfNeeded: (word &>> 16) & 0xFF)] &+= 1
            scratch[768 &+ Int(truncatingIfNeeded: (word &>> 24) & 0xFF)] &+= 1
            scratch[Int(truncatingIfNeeded: (word &>> 32) & 0xFF)] &+= 1
            scratch[256 &+ Int(truncatingIfNeeded: (word &>> 40) & 0xFF)] &+= 1
            scratch[512 &+ Int(truncatingIfNeeded: (word &>> 48) & 0xFF)] &+= 1
            scratch[768 &+ Int(truncatingIfNeeded: word &>> 56)] &+= 1
        }
        for index in (source.count & ~15)..<source.count {
            scratch[Int(source[index])] &+= 1
        }
        var largest: UInt32 = 0
        var maximum = 0
        for symbol in 0..<256 {
            let total = scratch[symbol] &+ scratch[256 &+ symbol] &+ scratch[512 &+ symbol] &+ scratch[768 &+ symbol]
            counts[symbol] = total
            if total != 0 { maximum = symbol }
            largest = max(largest, total)
        }
        maximumSymbol = maximum
        return Int(largest)
    }
}

// MARK: - Huffman

/// Huffman trees and streams for literals (`huf_compress.c`). Codes are at most 11 bits (`LitHufLog`); a code table
/// holds a `UInt32` per symbol: the code's length in the low 8 bits, its value above them. zstd assigns code values
/// rank by rank, the longest codes from 0, in symbol order within a rank, and its streams are read backward from
/// their ends: so values are written as they are, not bit-reversed (unlike DEFLATE's).
enum ZstdHuffmanEncoding {
    /// The longest literal code (`LitHufLog`).
    static var maximumCodeLength: Int { 11 }
    /// The largest table log libzstd's builder accepts (`HUF_TABLELOG_MAX`).
    static var tableLogLimit: Int { 12 }

    // Scratch layout for building (`HUF_buildCTable_wksp_tables`): 513 tree nodes of 8 bytes (count in the low 32
    // bits, the symbol in bits 32–39, its length in 40–47, its parent in 48–63), slot 0 a sentinel, then 192 rank
    // positions of two `UInt16`s.
    static var nodesOffset: Int { 0 }
    static var rankPositionOffset: Int { 513 * 8 }
    static var buildScratchSize: Int { rankPositionOffset + 192 * 4 }

    @inline(__always)
    static func nodeCount(_ node: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: node) }
    @inline(__always)
    static func nodeSymbol(_ node: UInt64) -> Int { Int(truncatingIfNeeded: (node &>> 32) & 0xFF) }
    @inline(__always)
    static func nodeBits(_ node: UInt64) -> Int { Int(truncatingIfNeeded: (node &>> 40) & 0xFF) }
    @inline(__always)
    static func nodeParent(_ node: UInt64) -> Int { Int(truncatingIfNeeded: node &>> 48) }
    @inline(__always)
    static func withCount(_ node: UInt64, _ count: UInt32) -> UInt64 { (node & ~0xFFFF_FFFF) | UInt64(count) }
    @inline(__always)
    static func withBits(_ node: UInt64, _ bits: Int) -> UInt64 {
        (node & ~(0xFF &<< 40)) | (UInt64(truncatingIfNeeded: bits) & 0xFF) &<< 40
    }
    @inline(__always)
    static func withParent(_ node: UInt64, _ parent: Int) -> UInt64 {
        (node & 0x0000_FFFF_FFFF_FFFF) | UInt64(truncatingIfNeeded: parent) &<< 48
    }

    /// `HUF_getIndex`: the sort bucket of a count, exact below 166, by power of two above.
    @inline(__always)
    static func bucket(_ count: UInt32) -> Int {
        count < 166 ? Int(count) : ZstdFSEEncoding.highBit(Int(count)) &+ 158
    }

    /// Sorts the symbols `0...maximumSymbol` by decreasing count into `nodes` (index 0 is the first node), as
    /// `HUF_sort` does: buckets, each of the large ones sorted by quicksort.
    static func sort(
        _ nodes: UnsafeMutablePointer<UInt64>, counts: UnsafePointer<UInt32>, maximumSymbol: Int,
        rankPositions: UnsafeMutablePointer<UInt16>
    ) {
        // Unsafe: 192 rank positions (base at even, current at odd indices), nodes below `maximumSymbol + 1`.
        let symbolCount = maximumSymbol &+ 1
        unsafe rankPositions.update(repeating: 0, count: 384)
        for symbol in 0..<symbolCount {
            unsafe rankPositions[bucket(counts[symbol]) &* 2] &+= 1
        }
        var rank = 191
        while rank > 0 {
            unsafe rankPositions[(rank &- 1) &* 2] &+= rankPositions[rank &* 2]
            unsafe rankPositions[(rank &- 1) &* 2 &+ 1] = rankPositions[(rank &- 1) &* 2]
            rank &-= 1
        }
        for symbol in 0..<symbolCount {
            let count = unsafe counts[symbol]
            let slot = (bucket(count) &+ 1) &* 2 &+ 1
            let position = Int(unsafe rankPositions[slot])
            unsafe rankPositions[slot] &+= 1
            unsafe nodes[position] = UInt64(count) | UInt64(symbol) &<< 32
        }
        for rank in 166..<191 {
            let start = Int(unsafe rankPositions[rank &* 2])
            let size = Int(unsafe rankPositions[rank &* 2 &+ 1]) &- start
            if size > 1 { unsafe quickSort(nodes + start, 0, size &- 1) }
        }
    }

    private static func insertionSort(_ nodes: UnsafeMutablePointer<UInt64>, _ low: Int, _ high: Int) {
        // Unsafe: nodes between `low` and `high`, within the caller's bucket.
        let base = unsafe nodes + low
        let size = high &- low &+ 1
        var index = 1
        while index < size {
            let key = unsafe base[index]
            var other = index &- 1
            while other >= 0 && nodeCount(unsafe base[other]) < nodeCount(key) {
                unsafe base[other &+ 1] = base[other]
                other &-= 1
            }
            unsafe base[other &+ 1] = key
            index &+= 1
        }
    }

    private static func partition(_ nodes: UnsafeMutablePointer<UInt64>, _ low: Int, _ high: Int) -> Int {
        // Unsafe: nodes between `low` and `high`, within the caller's bucket.
        let pivot = nodeCount(unsafe nodes[high])
        var index = low &- 1
        for other in low..<high where nodeCount(unsafe nodes[other]) > pivot {
            index &+= 1
            unsafe (nodes[index], nodes[other]) = (nodes[other], nodes[index])
        }
        unsafe (nodes[index &+ 1], nodes[high]) = (nodes[high], nodes[index &+ 1])
        return index &+ 1
    }

    private static func quickSort(_ nodes: UnsafeMutablePointer<UInt64>, _ low: Int, _ high: Int) {
        if high &- low < 8 {
            unsafe insertionSort(nodes, low, high)
            return
        }
        var low = low
        var high = high
        while low < high {
            let pivot = unsafe partition(nodes, low, high)
            if pivot &- low < high &- pivot {
                unsafe quickSort(nodes, low, pivot &- 1)
                low = pivot &+ 1
            } else {
                unsafe quickSort(nodes, pivot &+ 1, high)
                high = pivot &- 1
            }
        }
    }

    /// Builds a code table at `table` (256 entries) for `counts`, at most `maximumBits` long (`HUF_buildCTable_wksp`).
    ///
    /// - Returns: The longest code's length (the table's log).
    static func buildTable(
        _ table: UnsafeMutablePointer<UInt64>, counts: UnsafePointer<UInt32>, maximumSymbol: Int, maximumBits: Int,
        scratch: UnsafeMutableRawPointer
    ) -> Int {
        // Unsafe: the scratch's nodes (513, slot 0 the sentinel at index -1) and rank positions, and the table's
        // entries up to `maximumSymbol`.
        let nodeBase = unsafe (scratch + nodesOffset).assumingMemoryBound(to: UInt64.self)
        unsafe nodeBase.update(repeating: 0, count: 513)
        let nodes = unsafe nodeBase + 1
        unsafe sort(nodes, counts: counts, maximumSymbol: maximumSymbol,
                    rankPositions: (scratch + rankPositionOffset).assumingMemoryBound(to: UInt16.self))
        let lastNonZero = unsafe buildTree(nodes, maximumSymbol: maximumSymbol)
        let bits = unsafe limitHeight(nodes, lastNonZero: lastNonZero, target: maximumBits)
        unsafe buildCodes(table, nodes: nodes, lastNonZero: lastNonZero, maximumSymbol: maximumSymbol, maximumBits: bits)
        return bits
    }

    /// `HUF_buildTree`: an unlimited Huffman tree over the sorted symbols, internal nodes from index 256.
    ///
    /// - Returns: The index of the rarest symbol with a nonzero count.
    private static func buildTree(_ nodes: UnsafeMutablePointer<UInt64>, maximumSymbol: Int) -> Int {
        // Unsafe: nodes from -1 (the sentinel) to 511.
        let startNode = 256
        var lastNonZero = maximumSymbol
        while nodeCount(unsafe nodes[lastNonZero]) == 0 { lastNonZero &-= 1 }
        var lowSymbol = lastNonZero
        let root = startNode &+ lowSymbol &- 1
        var lowNode = startNode
        var next = startNode
        unsafe nodes[next] = withCount(nodes[next], nodeCount(nodes[lowSymbol]) &+ nodeCount(nodes[lowSymbol &- 1]))
        unsafe nodes[lowSymbol] = withParent(nodes[lowSymbol], next)
        unsafe nodes[lowSymbol &- 1] = withParent(nodes[lowSymbol &- 1], next)
        next &+= 1
        lowSymbol &-= 2
        if next <= root {
            for index in next...root { unsafe nodes[index] = withCount(nodes[index], 1 &<< 30) }
        }
        unsafe nodes[-1] = withCount(nodes[-1], 1 &<< 31) // The sentinel.

        while next <= root {
            let first: Int
            if nodeCount(unsafe nodes[lowSymbol]) < nodeCount(unsafe nodes[lowNode]) {
                first = lowSymbol
                lowSymbol &-= 1
            } else {
                first = lowNode
                lowNode &+= 1
            }
            let second: Int
            if nodeCount(unsafe nodes[lowSymbol]) < nodeCount(unsafe nodes[lowNode]) {
                second = lowSymbol
                lowSymbol &-= 1
            } else {
                second = lowNode
                lowNode &+= 1
            }
            unsafe nodes[next] = withCount(nodes[next], nodeCount(nodes[first]) &+ nodeCount(nodes[second]))
            unsafe nodes[first] = withParent(nodes[first], next)
            unsafe nodes[second] = withParent(nodes[second], next)
            next &+= 1
        }

        unsafe nodes[root] = withBits(nodes[root], 0)
        var index = root &- 1
        while index >= startNode {
            unsafe nodes[index] = withBits(nodes[index], nodeBits(nodes[nodeParent(nodes[index])]) &+ 1)
            index &-= 1
        }
        for index in 0...lastNonZero {
            unsafe nodes[index] = withBits(nodes[index], nodeBits(nodes[nodeParent(nodes[index])]) &+ 1)
        }
        return lastNonZero
    }

    /// `HUF_setMaxHeight`: limits the tree's codes to `target` bits, repaying the lengthened codes' cost with the
    /// cheapest shortenings, as libzstd does.
    ///
    /// - Returns: The longest code's length.
    private static func limitHeight(_ nodes: UnsafeMutablePointer<UInt64>, lastNonZero: Int, target: Int) -> Int {
        // Unsafe: nodes from 0 to `lastNonZero`, and a 14-entry local rank table.
        let largestBits = nodeBits(unsafe nodes[lastNonZero])
        if largestBits <= target { return largestBits }
        var totalCost = 0
        let baseCost = 1 &<< (largestBits &- target)
        var index = lastNonZero
        while nodeBits(unsafe nodes[index]) > target {
            totalCost &+= baseCost &- (1 &<< (largestBits &- nodeBits(unsafe nodes[index])))
            unsafe nodes[index] = withBits(nodes[index], target)
            index &-= 1
        }
        while nodeBits(unsafe nodes[index]) == target { index &-= 1 }
        totalCost &>>= largestBits &- target

        let noSymbol = 0xF0F0_F0F0
        var rankLast = InlineArray<14, Int>(repeating: noSymbol)
        do {
            var currentBits = target
            var position = index
            while position >= 0 {
                let bits = nodeBits(unsafe nodes[position])
                if bits < currentBits {
                    currentBits = bits
                    rankLast[target &- currentBits] = position
                }
                position &-= 1
            }
        }

        while totalCost > 0 {
            var bitsToDecrease = ZstdFSEEncoding.highBit(totalCost) &+ 1
            while bitsToDecrease > 1 {
                let highPosition = rankLast[bitsToDecrease]
                let lowPosition = rankLast[bitsToDecrease &- 1]
                if highPosition == noSymbol {
                    bitsToDecrease &-= 1
                    continue
                }
                if lowPosition == noSymbol { break }
                let highTotal = nodeCount(unsafe nodes[highPosition])
                let lowTotal = 2 &* nodeCount(unsafe nodes[lowPosition])
                if highTotal <= lowTotal { break }
                bitsToDecrease &-= 1
            }
            while bitsToDecrease <= tableLogLimit && rankLast[bitsToDecrease] == noSymbol {
                bitsToDecrease &+= 1
            }
            totalCost &-= 1 &<< (bitsToDecrease &- 1)
            let lengthened = rankLast[bitsToDecrease]
            unsafe nodes[lengthened] = withBits(nodes[lengthened], nodeBits(nodes[lengthened]) &+ 1)
            if rankLast[bitsToDecrease &- 1] == noSymbol {
                rankLast[bitsToDecrease &- 1] = rankLast[bitsToDecrease]
            }
            if rankLast[bitsToDecrease] == 0 {
                rankLast[bitsToDecrease] = noSymbol
            } else {
                rankLast[bitsToDecrease] &-= 1
                if nodeBits(unsafe nodes[rankLast[bitsToDecrease]]) != target &- bitsToDecrease {
                    rankLast[bitsToDecrease] = noSymbol
                }
            }
        }

        while totalCost < 0 {
            if rankLast[1] == noSymbol {
                while nodeBits(unsafe nodes[index]) == target { index &-= 1 }
                unsafe nodes[index &+ 1] = withBits(nodes[index &+ 1], nodeBits(nodes[index &+ 1]) &- 1)
                rankLast[1] = index &+ 1
                totalCost &+= 1
                continue
            }
            let shortened = rankLast[1] &+ 1
            unsafe nodes[shortened] = withBits(nodes[shortened], nodeBits(nodes[shortened]) &- 1)
            rankLast[1] &+= 1
            totalCost &+= 1
        }
        return target
    }

    /// `HUF_buildCTableFromTree`: each symbol's length, then values rank by rank, in symbol order within a rank.
    private static func buildCodes(
        _ table: UnsafeMutablePointer<UInt64>, nodes: UnsafePointer<UInt64>, lastNonZero: Int, maximumSymbol: Int,
        maximumBits: Int
    ) {
        // Unsafe: table entries up to `maximumSymbol`, nodes up to it.
        var perRank = InlineArray<13, UInt16>(repeating: 0)
        var valuePerRank = InlineArray<13, UInt16>(repeating: 0)
        for index in 0...lastNonZero { perRank[nodeBits(unsafe nodes[index])] &+= 1 }
        var minimum: UInt16 = 0
        var bits = maximumBits
        while bits > 0 {
            valuePerRank[bits] = minimum
            minimum &+= perRank[bits]
            minimum &>>= 1
            bits &-= 1
        }
        for index in 0...maximumSymbol {
            let node = unsafe nodes[index]
            unsafe table[nodeSymbol(node)] = UInt64(truncatingIfNeeded: nodeBits(node))
        }
        for symbol in 0...maximumSymbol {
            let length = Int(unsafe table[symbol])
            guard length > 0 else { continue }
            let value = valuePerRank[length]
            valuePerRank[length] &+= 1
            // The value at the top (`HUF_setValue`), so adding a code to a stream is a shift and an OR.
            unsafe table[symbol] = UInt64(truncatingIfNeeded: length) | UInt64(value) &<< UInt64(64 &- length)
        }
    }

    /// `HUF_estimateCompressedSize`: the bytes `counts` take with `table`.
    static func estimateSize(_ table: Span<UInt64>, counts: Span<UInt32>, maximumSymbol: Int) -> Int {
        // Checked accesses at symbols up to `maximumSymbol`, which both spans hold: the checks fold.
        precondition(maximumSymbol < table.count && maximumSymbol < counts.count)
        var bits = 0
        for symbol in 0...maximumSymbol {
            bits &+= Int(table[symbol] & 0xFF) &* Int(counts[symbol])
        }
        return bits &>> 3
    }

    /// `HUF_validateCTable`: whether `table` (for symbols up to `tableMaximumSymbol`) has a code for every symbol
    /// counted.
    static func isValid(_ table: Span<UInt64>, tableMaximumSymbol: Int, counts: Span<UInt32>, maximumSymbol: Int) -> Bool {
        if tableMaximumSymbol < maximumSymbol { return false }
        // Checked accesses at symbols up to `maximumSymbol`, which both spans hold: the checks fold.
        precondition(maximumSymbol < table.count && maximumSymbol < counts.count)
        var bad = false
        for symbol in 0...maximumSymbol {
            bad = bad || (counts[symbol] != 0 && table[symbol] & 0xFF == 0)
        }
        return !bad
    }

    // MARK: Tree descriptions

    /// Scratch for ``writeDescription(_:capacity:table:maximumSymbol:tableLog:scratch:)``: weights (256), their
    /// counts (13 `UInt32`s), normalized counts (13 `Int16`s), an FSE table, and its build scratch.
    static var weightsOffset: Int { 0 }
    static var weightCountsOffset: Int { 256 }
    static var weightNormalizedOffset: Int { weightCountsOffset + 64 }
    static var weightTableOffset: Int { weightNormalizedOffset + 64 }
    static var weightBuildOffset: Int { weightTableOffset + ZstdFSETable.regionSize }
    static var descriptionScratchSize: Int { weightBuildOffset + ZstdFSETable.scratchSize }

    /// Writes the tree description of `table` (`HUF_writeCTable_wksp`): weights FSE-compressed when that's shorter
    /// than half the symbols, otherwise 4 bits each.
    ///
    /// - Returns: The description's size, or `nil` if neither form is possible (more than 128 weights that FSE
    ///   doesn't shrink).
    static func writeDescription(
        _ output: UnsafeMutableRawPointer, capacity: Int, table: Span<UInt64>, maximumSymbol: Int, tableLog: Int,
        scratch: UnsafeMutableRawPointer
    ) -> Int? {
        // Unsafe: a span over the scratch's weights (256), and stores to `output` within `capacity` (checked for the
        // direct form; the FSE form checks its own). The weights' and table's accesses are checked.
        var weights = unsafe MutableSpan(_unsafeStart: (scratch + weightsOffset).assumingMemoryBound(to: UInt8.self), count: 256)
        precondition(maximumSymbol < 256 && maximumSymbol < table.count)
        for symbol in 0..<maximumSymbol {
            let length = Int(table[symbol] & 0xFF)
            weights[symbol] = length == 0 ? 0 : UInt8(truncatingIfNeeded: tableLog &+ 1 &- length)
        }
        guard capacity >= 1 else { return nil }
        let size = unsafe compressWeights(
            output + 1, capacity: capacity &- 1, weights: weights.span.extracting(first: maximumSymbol), scratch: scratch
        )
        if size > 1 && size < maximumSymbol / 2 {
            unsafe output.storeBytes(of: UInt8(truncatingIfNeeded: size), as: UInt8.self)
            return size &+ 1
        }
        guard maximumSymbol <= 128, (maximumSymbol &+ 1) / 2 &+ 1 <= capacity else { return nil }
        unsafe output.storeBytes(of: UInt8(truncatingIfNeeded: 127 &+ maximumSymbol), as: UInt8.self)
        weights[maximumSymbol] = 0
        var symbol = 0
        while symbol < maximumSymbol {
            let byte = weights[symbol] &<< 4 &+ weights[symbol &+ 1]
            unsafe output.storeBytes(of: byte, toByteOffset: symbol / 2 &+ 1, as: UInt8.self)
            symbol &+= 2
        }
        return (maximumSymbol &+ 1) / 2 &+ 1
    }

    /// `HUF_compressWeights`: the weights' FSE description and stream.
    ///
    /// - Returns: The size, 0 if FSE can't shrink them, 1 if they're all one value.
    private static func compressWeights(
        _ output: UnsafeMutableRawPointer, capacity: Int, weights: Span<UInt8>, scratch: UnsafeMutableRawPointer
    ) -> Int {
        let count = weights.count
        if count <= 1 { return 0 }
        // Unsafe: spans over the scratch's regions as laid out above (weights are at most 12, within the 16 counts),
        // the description at `output` (`descriptionBound` bytes, checked below), the weights' table built in the
        // scratch, and its stream at `output` within `capacity`.
        let normalizedPointer = unsafe (scratch + weightNormalizedOffset).assumingMemoryBound(to: Int16.self)
        var counts = unsafe MutableSpan(_unsafeStart: (scratch + weightCountsOffset).assumingMemoryBound(to: UInt32.self), count: 16)
        var normalized = unsafe MutableSpan(_unsafeStart: normalizedPointer, count: 32)
        var maximumSymbol = tableLogLimit
        let largest = ZstdHistogram.count(weights, into: &counts, maximumSymbol: &maximumSymbol)
        if largest == count { return 1 }
        if largest == 1 { return 0 }
        let tableLog = ZstdFSEEncoding.optimalTableLog(6, total: count, maximumSymbol: maximumSymbol)
        guard ZstdFSEEncoding.normalize(
            &normalized, tableLog: tableLog, counts: counts.span, total: count, maximumSymbol: maximumSymbol,
            useLowProbabilityCount: false
        ) else { return 0 }
        // The description is at most 13 symbols' worth: far below the capacity the callers give (64 bytes and up).
        guard capacity >= ZstdFSEEncoding.descriptionBound else { return 0 }
        let headerSize = unsafe ZstdFSEEncoding.writeDescription(
            output, normalized: normalized.span, maximumSymbol: maximumSymbol, tableLog: tableLog
        )
        let table = unsafe scratch + weightTableOffset
        unsafe ZstdFSETable.build(
            table, normalized: normalizedPointer, maximumSymbol: maximumSymbol, tableLog: tableLog, scratch: scratch + weightBuildOffset
        )
        let streamSize = weights.withUnsafeBufferPointer { source in
            unsafe compressFSE(
                output + headerSize, capacity: capacity &- headerSize, source: source.baseAddress!, count: count,
                table: table, tableLog: tableLog
            )
        }
        if streamSize == 0 { return 0 }
        return headerSize &+ streamSize
    }

    /// `FSE_compress_usingCTable`: `count` symbols with two interleaved states, from the last.
    ///
    /// - Returns: The stream's size, or 0 if it doesn't fit or there are 2 symbols or fewer.
    private static func compressFSE(
        _ output: UnsafeMutableRawPointer, capacity: Int, source: UnsafePointer<UInt8>, count: Int,
        table: UnsafeRawPointer, tableLog: Int
    ) -> Int {
        if count <= 2 { return 0 }
        // Unsafe: symbol loads below `count`, and the bit writer within `capacity`.
        guard var writer = unsafe ZstdBitWriter(output, capacity: capacity) else { return 0 }
        var index = count
        @inline(__always)
        func next() -> Int {
            index &-= 1
            return Int(unsafe source[index])
        }
        var state1: ZstdFSEState
        var state2: ZstdFSEState
        if count & 1 != 0 {
            state1 = unsafe ZstdFSEState(table, tableLog: tableLog, symbol: next())
            state2 = unsafe ZstdFSEState(table, tableLog: tableLog, symbol: next())
            state1.encode(next(), into: &writer)
            writer.flush()
        } else {
            state2 = unsafe ZstdFSEState(table, tableLog: tableLog, symbol: next())
            state1 = unsafe ZstdFSEState(table, tableLog: tableLog, symbol: next())
        }
        if (count &- 2) & 2 != 0 {
            state2.encode(next(), into: &writer)
            state1.encode(next(), into: &writer)
            writer.flush()
        }
        while index > 0 {
            state2.encode(next(), into: &writer)
            state1.encode(next(), into: &writer)
            state2.encode(next(), into: &writer)
            state1.encode(next(), into: &writer)
            writer.flush()
        }
        state2.flush(into: &writer)
        state1.flush(into: &writer)
        return writer.close()
    }

    // MARK: Streams

    /// Encodes the `count` bytes at `source` as one stream (`HUF_compress1X_usingCTable`): from the last byte to the
    /// first, so the decoder reads the first first. libzstd's loop: a group of codes per flush, sized so the group
    /// fits beside the 7 bits a flush leaves, every other group in a second container so consecutive groups don't
    /// wait on each other.
    ///
    /// - Returns: The stream's size, or 0 if it doesn't fit in `capacity`.
    static func encodeStream(
        _ output: UnsafeMutableRawPointer, capacity: Int, source: UnsafePointer<UInt8>, count: Int,
        table: UnsafePointer<UInt64>, tableLog: Int
    ) -> Int {
        guard capacity >= 8, var writer = unsafe ZstdHuffmanWriter(output, capacity: capacity) else { return 0 }
        // Unsafe: the loops' byte loads below `count` and table loads at byte values; the writer's stores within
        // `capacity`: checked at each flush, or (the unchecked loops) by the bound of `tableLog` bits a byte plus 8.
        if capacity < (count &* tableLog) &>> 3 &+ 8 || tableLog > 11 {
            unsafe encodeLoop(&writer, source, count, table, unroll: 4, fastFlush: false, lastFast: false)
        } else {
            switch tableLog {
            case 11: unsafe encodeLoop(&writer, source, count, table, unroll: 5, fastFlush: true, lastFast: false)
            case 10: unsafe encodeLoop(&writer, source, count, table, unroll: 5, fastFlush: true, lastFast: true)
            case 9: unsafe encodeLoop(&writer, source, count, table, unroll: 6, fastFlush: true, lastFast: false)
            case 8: unsafe encodeLoop(&writer, source, count, table, unroll: 7, fastFlush: true, lastFast: false)
            case 7: unsafe encodeLoop(&writer, source, count, table, unroll: 8, fastFlush: true, lastFast: false)
            default: unsafe encodeLoop(&writer, source, count, table, unroll: 9, fastFlush: true, lastFast: true)
            }
        }
        return writer.close()
    }

    /// `HUF_compress1X_usingCTable_internal_body_loop`: the codes of `source[count - 1]` down to `source[0]`, `unroll`
    /// per flush, alternate groups in the writer's second container.
    @inline(__always)
    private static func encodeLoop(
        _ writer: inout ZstdHuffmanWriter, _ source: UnsafePointer<UInt8>, _ count: Int, _ table: UnsafePointer<UInt64>,
        unroll: Int, fastFlush: Bool, lastFast: Bool
    ) {
        // Unsafe: byte loads below `count`, table loads at byte values.
        var index = count
        var remainder = index % unroll
        if remainder > 0 {
            while remainder > 0 {
                index &-= 1
                writer.add0(unsafe table[Int(source[index])], fast: false)
                remainder &-= 1
            }
            writer.flush(fast: fastFlush)
        }
        if index % (2 &* unroll) != 0 {
            for offset in 1..<unroll { writer.add0(unsafe table[Int(source[index &- offset])], fast: true) }
            writer.add0(unsafe table[Int(source[index &- unroll])], fast: lastFast)
            writer.flush(fast: fastFlush)
            index &-= unroll
        }
        while index > 0 {
            for offset in 1..<unroll { writer.add0(unsafe table[Int(source[index &- offset])], fast: true) }
            writer.add0(unsafe table[Int(source[index &- unroll])], fast: lastFast)
            writer.flush(fast: fastFlush)
            writer.container1 = 0
            writer.position1 = 0
            for offset in 1..<unroll { writer.add1(unsafe table[Int(source[index &- unroll &- offset])], fast: true) }
            writer.add1(unsafe table[Int(source[index &- 2 &* unroll])], fast: lastFast)
            writer.merge1()
            writer.flush(fast: fastFlush)
            index &-= 2 &* unroll
        }
    }

    /// Encodes as four streams with a jump table (`HUF_compress4X_usingCTable`): each a quarter, the last the rest.
    ///
    /// - Returns: The size, or 0 if a stream doesn't fit (or exceeds 65,535 bytes), or `count` is below 12.
    static func encodeFourStreams(
        _ output: UnsafeMutableRawPointer, capacity: Int, source: UnsafePointer<UInt8>, count: Int,
        table: UnsafePointer<UInt64>, tableLog: Int
    ) -> Int {
        if capacity < 6 &+ 1 &+ 1 &+ 1 &+ 8 { return 0 }
        if count < 12 { return 0 }
        let segment = (count &+ 3) / 4
        var position = 6
        // Unsafe: streams written within `capacity`, sources within `count`.
        for stream in 0..<4 {
            let start = stream &* segment
            let length = stream == 3 ? count &- start : segment
            let size = unsafe encodeStream(
                output + position, capacity: capacity &- position, source: source + start, count: length, table: table,
                tableLog: tableLog
            )
            if size == 0 || size > 65535 { return 0 }
            if stream < 3 {
                unsafe output.storeBytes(of: UInt16(truncatingIfNeeded: size).littleEndian, toByteOffset: stream &* 2, as: UInt16.self)
            }
            position &+= size
        }
        return position
    }
}
