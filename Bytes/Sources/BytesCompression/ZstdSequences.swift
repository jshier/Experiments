internal import Bytes

// A compressed block's sequences section (RFC 8878, 3.1.1.3.2) and their execution: the decode loop is
// libzstd's (`ZSTD_decompressSequences_body`, `ZSTD_execSequence`), sequences decoded and executed one at a
// time with wild copies, edge cases in an out-of-line careful path.

/// The history a block's matches may reach: the frame's output so far in the same buffer, from
/// `prefixStart`, and for a streaming window that wrapped, an older segment `dictionaryStart..<dictionaryEnd`
/// that logically precedes it. Offsets into the output buffer.
struct ZstdHistory {
    var prefixStart: Int
    var dictionaryStart = 0
    var dictionaryEnd = 0
    /// The most a match may reach back through the older segment (the frame's window).
    var windowSize = Int.max
}

/// Decodes compressed blocks: the entropy tables and repeat offsets carried from block to block within a
/// frame, and the memory they live in.
@safe
struct ZstdBlockDecoder: ~Copyable {
    var workspace = ZstdWorkspace()
    /// The current Huffman table's index width, or 0 if this frame has none yet.
    var huffmanTableLog = 0
    /// Whether the current Huffman table is double-symbol (libzstd's X2) rather than single-symbol (X1).
    var huffmanIsDouble = false
    /// Whether this frame has sequence tables to repeat.
    var hasSequenceTables = false
    /// The sequence tables in use: offsets into the workspace, and their accuracy logs.
    var literalLengthTable = (offset: ZstdWorkspace.literalLengthDefaultOffset, log: Zstd.literalLengthDefaultLog)
    var offsetTable = (offset: ZstdWorkspace.offsetDefaultOffset, log: Zstd.offsetDefaultLog)
    var matchLengthTable = (offset: ZstdWorkspace.matchLengthDefaultOffset, log: Zstd.matchLengthDefaultLog)
    var repeatOffsets = (1, 4, 8)

    /// Forgets the previous frame's tables and offsets.
    mutating func startFrame() {
        huffmanTableLog = 0
        hasSequenceTables = false
        repeatOffsets = (1, 4, 8)
    }

    // MARK: Blocks

    /// Decodes the compressed block of `count` bytes at `source` into `output` at `start`.
    ///
    /// - Parameters:
    ///   - source: The block's content (after its header).
    ///   - count: Its size: at most `blockSizeMaximum`.
    ///   - output: The output buffer, which holds the history too.
    ///   - start: Where the block's output starts in `output`.
    ///   - limit: The end of `output`: wild copies may write anywhere before it.
    ///   - history: What matches may reach.
    ///   - blockSizeMaximum: The frame's largest block.
    /// - Returns: The block's decoded size.
    /// - Throws: ``BytesError/invalidValue`` for corrupt data, ``BytesError/insufficientCapacity`` if the output
    ///   doesn't fit before `limit`.
    mutating func decodeCompressedBlock(
        _ source: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer, at start: Int, limit: Int,
        history: ZstdHistory, blockSizeMaximum: Int
    ) throws(BytesError) -> Int {
        guard count <= blockSizeMaximum else { throw .invalidValue }
        let (literals, literalsSize) = try unsafe decodeLiterals(source, available: count, blockSizeMaximum: blockSizeMaximum)
        // Unsafe: pointers into the block. Safe: `literalsSize <= count`, checked by `decodeLiterals`.
        var position = literalsSize
        let sequenceCount = try unsafe readSequenceHeaders(source, at: &position, count: count)
        var end = start
        var literalPosition = 0
        if sequenceCount == 0 {
            guard position == count else { throw .invalidValue }
        } else {
            // The tables' states are absolute indices of 8-byte entries in the workspace.
            (end, literalPosition) = try unsafe Self.executeSequences(
                count: sequenceCount, stream: source + position, streamSize: count &- position,
                tables: UnsafePointer(workspace.pointer(0).assumingMemoryBound(to: UInt64.self)),
                literalLengthTable: (literalLengthTable.offset &>> 3, literalLengthTable.log),
                offsetTable: (offsetTable.offset &>> 3, offsetTable.log),
                matchLengthTable: (matchLengthTable.offset &>> 3, matchLengthTable.log),
                literals: literals, output: output, at: start, limit: limit, history: history,
                repeatOffsets: &repeatOffsets
            )
        }
        // The literals after the last sequence.
        let rest = unsafe literals.count &- literalPosition
        guard rest <= limit &- end else { throw .insufficientCapacity }
        // Unsafe: a copy within the output and literal buffers. Safe: `rest` bytes remain in each (checked).
        unsafe (output + end).copyMemory(from: literals.base + literalPosition, byteCount: rest)
        end &+= rest
        guard end &- start <= blockSizeMaximum else { throw .invalidValue }
        return end &- start
    }

    // MARK: Sequence headers

    /// Reads the sequences section's header at `position`: the sequence count, and the three tables.
    ///
    /// - Returns: The number of sequences.
    private mutating func readSequenceHeaders(
        _ source: UnsafeRawPointer, at position: inout Int, count: Int
    ) throws(BytesError) -> Int {
        // Unsafe: byte loads, each below `count` (checked first).
        @inline(__always)
        func byte(_ index: Int) -> Int {
            Int(unsafe source.load(fromByteOffset: index, as: UInt8.self))
        }
        guard position < count else { throw .invalidValue }
        var sequences = byte(position)
        position &+= 1
        if sequences == 0 { return 0 }
        if sequences == 255 {
            guard position &+ 2 <= count else { throw .invalidValue }
            sequences = byte(position) &+ byte(position &+ 1) &<< 8 &+ 0x7F00
            position &+= 2
        } else if sequences >= 128 {
            guard position < count else { throw .invalidValue }
            sequences = (sequences &- 128) &<< 8 &+ byte(position)
            position &+= 1
        }
        guard position < count else { throw .invalidValue }
        let modes = byte(position)
        position &+= 1
        guard modes & 3 == 0 else { throw .invalidValue } // Reserved bits.
        literalLengthTable = try unsafe readTable(.literalLength, mode: modes &>> 6, source, at: &position, count: count, current: literalLengthTable)
        offsetTable = try unsafe readTable(.offset, mode: (modes &>> 4) & 3, source, at: &position, count: count, current: offsetTable)
        matchLengthTable = try unsafe readTable(.matchLength, mode: (modes &>> 2) & 3, source, at: &position, count: count, current: matchLengthTable)
        hasSequenceTables = true
        return sequences
    }

    /// Sets up one sequence field's table for `mode`: predefined, RLE, FSE-coded, or repeated.
    private func readTable(
        _ alphabet: ZstdSequenceAlphabet, mode: Int, _ source: UnsafeRawPointer, at position: inout Int, count: Int,
        current: (offset: Int, log: Int)
    ) throws(BytesError) -> (offset: Int, log: Int) {
        let own: Int
        let defaultTable: (offset: Int, log: Int)
        switch alphabet {
        case .literalLength:
            own = ZstdWorkspace.literalLengthOffset
            defaultTable = (ZstdWorkspace.literalLengthDefaultOffset, Zstd.literalLengthDefaultLog)
        case .offset:
            own = ZstdWorkspace.offsetOffset
            defaultTable = (ZstdWorkspace.offsetDefaultOffset, Zstd.offsetDefaultLog)
        case .matchLength:
            own = ZstdWorkspace.matchLengthOffset
            defaultTable = (ZstdWorkspace.matchLengthDefaultOffset, Zstd.matchLengthDefaultLog)
        }
        let entries = unsafe workspace.pointer(own).assumingMemoryBound(to: UInt64.self)
        let codes = unsafe UnsafePointer(workspace.pointer(alphabet.codesOffset).assumingMemoryBound(to: UInt64.self))
        let scratch = unsafe ZstdTableScratch(workspace)
        switch mode {
        case 0:
            return defaultTable
        case 1:
            guard position < count else { throw .invalidValue }
            // Unsafe: a byte load below `count` (checked).
            let symbol = Int(unsafe source.load(fromByteOffset: position, as: UInt8.self))
            position &+= 1
            guard symbol <= alphabet.maximumSymbol else { throw .invalidValue }
            unsafe ZstdFSE.buildRLETable(entries, index: own / 8, symbol: symbol, codes: codes)
            return (own, 0)
        case 2:
            // Unsafe: reading the description within the block, and building into the table's region, which
            // holds `1 << maximumTableLog` entries.
            let (log, maximumSymbol, size) = try unsafe ZstdFSE.readNormalizedCounts(
                source + position, available: count &- position, maximumSymbol: alphabet.maximumSymbol,
                maximumLog: alphabet.maximumTableLog, into: scratch.counts
            )
            try unsafe ZstdFSE.buildSequenceTable(
                entries, index: own / 8, maximumSymbol: maximumSymbol, tableLog: log, codes: codes, scratch: scratch
            )
            position &+= size
            return (own, log)
        default:
            guard hasSequenceTables else { throw .invalidValue } // Nothing to repeat in this frame.
            return current
        }
    }
}
