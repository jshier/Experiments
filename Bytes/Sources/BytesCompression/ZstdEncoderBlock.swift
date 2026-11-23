internal import Bytes

// A Zstandard encoder's blocks (RFC 8878, 3.1.1.2–3.1.1.3): the match finder's sequences and literals entropy-coded
// into a compressed block, or the block stored raw or as a run when that's smaller. Decisions follow libzstd 1.5.7's
// (`zstd_compress.c`, `zstd_compress_literals.c`, `zstd_compress_sequences.c`): literals raw, as a run, or
// Huffman-coded in one stream or four with a new tree or the previous block's; each sequence field's table
// predefined, a single symbol, FSE-described, or repeated; and the encoder's state (repeat offsets, tables) carried
// to the next block only when a block is compressed, as the decoder carries it.

/// How a previous block's table may be reused (libzstd's `HUF_repeat` and `FSE_repeat`).
enum ZstdRepeatMode {
    /// Not reusable: there's none, or it may lack a symbol.
    case none
    /// Reusable if it has a code for every symbol present.
    case check
    /// Reusable as is.
    case valid
}

/// A sequence field's encoding table: where it is in the workspace, and whether the next block may repeat it.
struct ZstdTableState {
    var region: Int
    var tableLog: Int
    var maximumSymbol: Int
    var repeatMode = ZstdRepeatMode.none
}

/// The literals' Huffman table: which of the two slots, and whether the next block may repeat it.
struct ZstdHuffmanState {
    var slot = 0
    var tableLog = 0
    var maximumSymbol = 0
    var repeatMode = ZstdRepeatMode.none
}

/// What a block leaves for the next one, as the decoder will have it.
struct ZstdEntropyState {
    var huffman = ZstdHuffmanState()
    var literalLength: ZstdTableState
    var offset: ZstdTableState
    var matchLength: ZstdTableState
    /// The three repeat offsets.
    var repeats: (UInt32, UInt32, UInt32) = (1, 4, 8)
}

/// The encoder's workspace layout: tables for the match finder, the sequence store, the entropy coders' tables and
/// scratch, and the staging buffer each block is written to. Offsets in bytes, each region 64-byte aligned.
struct ZstdEncoderLayout {
    let hashTable: Int
    let chainTable: Int
    let sequences: Int
    let literalCodes: Int
    let matchCodes: Int
    let offsetCodes: Int
    let literals: Int
    let staging: Int
    let stagingCapacity: Int
    let huffmanTables: Int
    /// Four table regions per field (predefined, RLE, two slots), literal lengths, offsets, match lengths.
    let fseTables: Int
    let counts: Int
    let histogramScratch: Int
    let normalized: Int
    let fseScratch: Int
    let huffmanScratch: Int
    let descriptionScratch: Int
    let splitScratch: Int
    let codeTables: Int
    let size: Int
    let maximumSequences: Int

    // Code tables in `codeTables`: libzstd's `LL_Code` (64 bytes), `ML_Code` (128), then `LL_bits` (36) and `ML_bits`
    // (53).
    static var literalCodeTable: Int { 0 }
    static var matchCodeTable: Int { 64 }
    static var literalBitsTable: Int { 192 }
    static var matchBitsTable: Int { 256 }

    init(hashLog: Int, chainLog: Int?, blockSizeMaximum: Int) {
        var offset = 0
        func region(_ bytes: Int) -> Int {
            let start = offset
            offset &+= (bytes &+ 63) & ~63
            return start
        }
        hashTable = region(4 &<< hashLog)
        chainTable = chainLog.map { region(4 &<< $0) } ?? 0
        // Every sequence has a match of at least 4 bytes.
        maximumSequences = blockSizeMaximum / 4 &+ 1
        sequences = region(8 &* maximumSequences)
        literalCodes = region(maximumSequences)
        matchCodes = region(maximumSequences)
        offsetCodes = region(maximumSequences)
        // The literals and 32 bytes of slack for wild copies' overrun.
        literals = region(blockSizeMaximum &+ 64)
        // A block (raw, or compressed when smaller) with its header, a frame header before it and a checksum after,
        // and room past the end for the bit writers' 8-byte stores.
        stagingCapacity = blockSizeMaximum &+ 512
        staging = region(stagingCapacity)
        huffmanTables = region(2 &* 256 &* 8)
        fseTables = region(3 &* 4 &* ZstdFSETable.regionSize)
        counts = region(256 &* 4)
        histogramScratch = region(1024 &* 4)
        normalized = region(64 &* 2)
        fseScratch = region(ZstdFSETable.scratchSize)
        huffmanScratch = region(ZstdHuffmanEncoding.buildScratchSize)
        descriptionScratch = region(ZstdHuffmanEncoding.descriptionScratchSize)
        splitScratch = region(ZstdBlockSplitter.scratchSize)
        codeTables = region(320)
        size = offset
    }

    /// The region of field `field`'s (0 literal lengths, 1 offsets, 2 match lengths) table `index` (0 predefined, 1
    /// RLE, 2 and 3 the slots for described tables).
    func fseRegion(_ field: Int, _ index: Int) -> Int {
        fseTables &+ (field &* 4 &+ index) &* ZstdFSETable.regionSize
    }
}

/// A sequence field's fixed properties.
struct ZstdSequenceField {
    let index: Int
    let maximumSymbol: Int
    let maximumTableLog: Int
    let defaultLog: Int
    /// The largest symbol the predefined distribution covers.
    let defaultMaximumSymbol: Int

    static var literalLength: ZstdSequenceField { ZstdSequenceField(index: 0, maximumSymbol: 35, maximumTableLog: 9, defaultLog: 6, defaultMaximumSymbol: 35) }
    static var offset: ZstdSequenceField { ZstdSequenceField(index: 1, maximumSymbol: 31, maximumTableLog: 8, defaultLog: 5, defaultMaximumSymbol: 28) }
    static var matchLength: ZstdSequenceField { ZstdSequenceField(index: 2, maximumSymbol: 52, maximumTableLog: 9, defaultLog: 6, defaultMaximumSymbol: 52) }
}

/// libzstd's strategies, as numbered there (the decisions compare them).
enum ZstdStrategyNumber {
    static var fast: Int { 1 }
    static var doubleFast: Int { 2 }
    static var greedy: Int { 3 }
    static var lazy: Int { 4 }
}

/// Compresses blocks: the workspace (match tables, sequence store, entropy tables, staging) and the entropy state
/// carried from block to block within a frame.
@safe
struct ZstdBlockEncoder: ~Copyable {
    let workspace: CodecWorkspace
    let layout: ZstdEncoderLayout
    /// The state the last compressed block left (libzstd's `prevCBlock`).
    var previous: ZstdEntropyState
    /// The state this block will leave if it's compressed (`nextCBlock`).
    var next: ZstdEntropyState

    init(hashLog: Int, chainLog: Int?, blockSizeMaximum: Int) {
        let layout = ZstdEncoderLayout(hashLog: hashLog, chainLog: chainLog, blockSizeMaximum: blockSizeMaximum)
        self.layout = layout
        // Zeroed: hash table entries of 0 are below every frame's first index.
        workspace = CodecWorkspace(byteCount: layout.size)
        let initial = ZstdEntropyState(
            literalLength: ZstdTableState(region: layout.fseRegion(0, 0), tableLog: 6, maximumSymbol: 35),
            offset: ZstdTableState(region: layout.fseRegion(1, 0), tableLog: 5, maximumSymbol: 28),
            matchLength: ZstdTableState(region: layout.fseRegion(2, 0), tableLog: 6, maximumSymbol: 52)
        )
        previous = initial
        next = initial
        // Unsafe: the predefined tables built into their regions, and the code tables copied into theirs; each
        // fits (`ZstdFSETable.regionSize`, 320 bytes).
        let normalized = unsafe workspace.pointer(layout.normalized).assumingMemoryBound(to: Int16.self)
        let scratch = unsafe workspace.pointer(layout.fseScratch)
        let defaults: [(norm: [Int16], log: Int, field: Int)] = [
            (Zstd.literalLengthDefaultNorm, 6, 0), (Zstd.offsetDefaultNorm, 5, 1), (Zstd.matchLengthDefaultNorm, 6, 2),
        ]
        for (norm, log, field) in defaults {
            for (index, value) in norm.enumerated() { unsafe normalized[index] = value }
            unsafe ZstdFSETable.build(
                workspace.pointer(layout.fseRegion(field, 0)), normalized: normalized, maximumSymbol: norm.count &- 1,
                tableLog: log, scratch: scratch
            )
        }
        let codes = unsafe workspace.pointer(layout.codeTables)
        let literalCodes: [UInt8] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 16, 17, 17, 18, 18, 19, 19,
            20, 20, 20, 20, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23,
            24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
        ]
        for (index, value) in literalCodes.enumerated() {
            unsafe codes.storeBytes(of: value, toByteOffset: ZstdEncoderLayout.literalCodeTable &+ index, as: UInt8.self)
        }
        for index in 0..<128 {
            let value: UInt8 = index < 32 ? UInt8(index) : index < 40 ? UInt8(32 &+ (index &- 32) / 2)
                : index < 48 ? UInt8(36 &+ (index &- 40) / 4) : index < 64 ? UInt8(38 &+ (index &- 48) / 8)
                : index < 96 ? UInt8(40 &+ (index &- 64) / 16) : 42
            unsafe codes.storeBytes(of: value, toByteOffset: ZstdEncoderLayout.matchCodeTable &+ index, as: UInt8.self)
        }
        for (index, value) in Zstd.literalLengthBits.enumerated() {
            unsafe codes.storeBytes(of: value, toByteOffset: ZstdEncoderLayout.literalBitsTable &+ index, as: UInt8.self)
        }
        for (index, value) in Zstd.matchLengthBits.enumerated() {
            unsafe codes.storeBytes(of: value, toByteOffset: ZstdEncoderLayout.matchBitsTable &+ index, as: UInt8.self)
        }
    }

    /// Forgets the previous frame's tables and offsets (`ZSTD_reset_compressedBlockState`).
    mutating func startFrame() {
        previous.huffman.repeatMode = .none
        previous.literalLength.repeatMode = .none
        previous.offset.repeatMode = .none
        previous.matchLength.repeatMode = .none
        previous.repeats = (1, 4, 8)
    }

    @inline(__always)
    var stagingPointer: UnsafeMutableRawPointer { unsafe workspace.pointer(layout.staging) }

    @inline(__always)
    func sequenceStore() -> ZstdSequenceStore {
        unsafe ZstdSequenceStore(
            sequences: workspace.pointer(layout.sequences).assumingMemoryBound(to: UInt64.self),
            literals: workspace.pointer(layout.literals)
        )
    }

    /// `ZSTD_minGain`: what a compressed block or literals section must save over its raw form.
    @inline(__always)
    static func minimumGain(_ size: Int) -> Int { (size &>> 6) &+ 2 }

    // MARK: - Block

    /// Entropy-codes the sequences and literals in `store` (from a block of `blockSize` bytes) at `output`
    /// (`ZSTD_entropyCompressSeqStore`), leaving the resulting state in ``next``.
    ///
    /// - Returns: The compressed block's size, or 0 if it should be stored raw: not smaller by the minimum gain, or
    ///   too large for `capacity`.
    ///
    /// - Parameter compressesLiterals: Whether literals may be Huffman-coded (libzstd turns it off for the fast
    ///   strategy with a target length, its negative levels).
    mutating func entropyCompress(
        _ store: ZstdSequenceStore, blockSize: Int, into output: UnsafeMutableRawPointer, capacity: Int, strategy: Int,
        compressesLiterals: Bool = true
    ) -> Int {
        let sequenceCount = store.count
        next.huffman = previous.huffman
        next.literalLength = previous.literalLength
        next.offset = previous.offset
        next.matchLength = previous.matchLength

        // Literals.
        let literalSize: Int
        if compressesLiterals {
            let suspectUncompressible = sequenceCount == 0 || store.literalCount / sequenceCount >= 20
            literalSize = unsafe compressLiterals(
                UnsafeRawPointer(store.literals), count: store.literalCount, into: output, capacity: capacity,
                strategy: strategy, suspectUncompressible: suspectUncompressible
            )
        } else {
            literalSize = unsafe Self.writeRawLiterals(UnsafeRawPointer(store.literals), count: store.literalCount, into: output)
        }
        var position = literalSize

        // The sequences section's header.
        guard capacity &- position >= 4 else { return 0 }
        // Unsafe: header stores, within `capacity` (checked).
        if sequenceCount < 128 {
            unsafe output.storeBytes(of: UInt8(truncatingIfNeeded: sequenceCount), toByteOffset: position, as: UInt8.self)
            position &+= 1
        } else if sequenceCount < 0x7F00 {
            unsafe output.storeBytes(of: UInt8(truncatingIfNeeded: (sequenceCount &>> 8) &+ 0x80), toByteOffset: position, as: UInt8.self)
            unsafe output.storeBytes(of: UInt8(truncatingIfNeeded: sequenceCount), toByteOffset: position &+ 1, as: UInt8.self)
            position &+= 2
        } else {
            unsafe output.storeBytes(of: 0xFF, toByteOffset: position, as: UInt8.self)
            unsafe output.storeBytes(of: UInt16(truncatingIfNeeded: sequenceCount &- 0x7F00).littleEndian, toByteOffset: position &+ 1, as: UInt16.self)
            position &+= 3
        }
        if sequenceCount > 0 {
            let modesPosition = position
            position &+= 1
            computeCodes(store)
            // Each table description is at most `descriptionBound` bytes.
            guard capacity &- position >= 3 &* ZstdFSEEncoding.descriptionBound else { return 0 }
            var lastDescriptionSize = 0
            var literalLengthState = next.literalLength
            var offsetState = next.offset
            var matchLengthState = next.matchLength
            let literalLengthMode = unsafe buildTable(
                .literalLength, codes: workspace.pointer(layout.literalCodes), count: sequenceCount,
                state: &literalLengthState, previousState: previous.literalLength, strategy: strategy,
                output: output + position, written: &position, lastDescriptionSize: &lastDescriptionSize
            )
            let offsetMode = unsafe buildTable(
                .offset, codes: workspace.pointer(layout.offsetCodes), count: sequenceCount,
                state: &offsetState, previousState: previous.offset, strategy: strategy,
                output: output + position, written: &position, lastDescriptionSize: &lastDescriptionSize
            )
            let matchLengthMode = unsafe buildTable(
                .matchLength, codes: workspace.pointer(layout.matchCodes), count: sequenceCount,
                state: &matchLengthState, previousState: previous.matchLength, strategy: strategy,
                output: output + position, written: &position, lastDescriptionSize: &lastDescriptionSize
            )
            next.literalLength = literalLengthState
            next.offset = offsetState
            next.matchLength = matchLengthState
            unsafe output.storeBytes(
                of: UInt8(truncatingIfNeeded: literalLengthMode &<< 6 | offsetMode &<< 4 | matchLengthMode &<< 2),
                toByteOffset: modesPosition, as: UInt8.self
            )
            let streamSize = unsafe encodeSequences(store, into: output + position, capacity: capacity &- position)
            if streamSize == 0 { return 0 }
            // libzstd ≤ 1.3.4 misreads a block whose last table description and bitstream are under 4 bytes.
            if lastDescriptionSize > 0 && lastDescriptionSize &+ streamSize < 4 { return 0 }
            position &+= streamSize
        }
        if position >= blockSize &- Self.minimumGain(blockSize) { return 0 }
        return position
    }

    /// Makes `next` the state for the next block: the block was written compressed.
    mutating func confirm() {
        previous = next
    }

    // MARK: Literals

    /// Writes the literals section of the `count` literals at `literals` (`ZSTD_compressLiterals`).
    ///
    /// - Returns: The section's size.
    mutating func compressLiterals(
        _ literals: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer, capacity: Int, strategy: Int,
        suspectUncompressible: Bool
    ) -> Int {
        // Too few to try (`ZSTD_minLiteralsToCompress`).
        let minimum = previous.huffman.repeatMode == .valid ? 6 : 8 &<< min(9 &- strategy, 3)
        if count < minimum { return unsafe Self.writeRawLiterals(literals, count: count, into: output) }

        let headerSize = 3 &+ (count >= 1024 ? 1 : 0) &+ (count >= 16 << 10 ? 1 : 0)
        var singleStream = count < 256
        if previous.huffman.repeatMode == .valid && headerSize == 3 { singleStream = true }
        var repeatMode = previous.huffman.repeatMode
        var newTable = false
        // Unsafe: the stream written after the header, within `capacity` (the bit writers stop at its end).
        let size = unsafe compressHuffman(
            literals, count: count, into: output + headerSize, capacity: capacity &- headerSize, singleStream: singleStream,
            repeatMode: &repeatMode, preferRepeat: strategy < ZstdStrategyNumber.lazy && count <= 1024,
            suspectUncompressible: suspectUncompressible, newTable: &newTable
        )
        if size == 0 || size >= count &- Self.minimumGain(count) {
            next.huffman = previous.huffman
            return unsafe Self.writeRawLiterals(literals, count: count, into: output)
        }
        if size == 1 {
            // One symbol: a run. (A 1-byte stream is possible only below 8 literals, so check those.)
            var identical = true
            if count < 8 {
                // Unsafe: loads below `count`.
                let first = unsafe literals.load(as: UInt8.self)
                for index in 1..<count where unsafe literals.load(fromByteOffset: index, as: UInt8.self) != first {
                    identical = false
                }
            }
            if identical {
                next.huffman = previous.huffman
                return unsafe Self.writeRunLiterals(literals, count: count, into: output)
            }
        }
        let type: Int
        if repeatMode == .none {
            type = 2
            if newTable {
                next.huffman.repeatMode = .check
            }
        } else {
            type = 3
        }
        // Unsafe: header stores within the first 5 bytes, which `capacity` holds.
        switch headerSize {
        case 3:
            let header = type | (singleStream ? 0 : 1) &<< 2 | count &<< 4 | size &<< 14
            unsafe output.storeBytes(of: UInt16(truncatingIfNeeded: header).littleEndian, as: UInt16.self)
            unsafe output.storeBytes(of: UInt8(truncatingIfNeeded: header &>> 16), toByteOffset: 2, as: UInt8.self)
        case 4:
            let header = type | 2 &<< 2 | count &<< 4 | size &<< 18
            unsafe output.storeBytes(of: UInt32(truncatingIfNeeded: header).littleEndian, as: UInt32.self)
        default:
            let header = type | 3 &<< 2 | count &<< 4 | size &<< 22
            unsafe output.storeBytes(of: UInt32(truncatingIfNeeded: header).littleEndian, as: UInt32.self)
            unsafe output.storeBytes(of: UInt8(truncatingIfNeeded: size &>> 10), toByteOffset: 4, as: UInt8.self)
        }
        return headerSize &+ size
    }

    /// A raw literals section.
    static func writeRawLiterals(_ literals: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer) -> Int {
        // Unsafe: the header and the literals, within the staging buffer, which holds a block and more.
        let headerSize = unsafe writeLiteralsHeader(type: 0, count: count, into: output)
        unsafe (output + headerSize).copyMemory(from: literals, byteCount: count)
        return headerSize &+ count
    }

    /// An RLE literals section: the first literal, `count` times.
    static func writeRunLiterals(_ literals: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer) -> Int {
        // Unsafe: the header and one byte, within the staging buffer.
        let headerSize = unsafe writeLiteralsHeader(type: 1, count: count, into: output)
        unsafe output.storeBytes(of: literals.load(as: UInt8.self), toByteOffset: headerSize, as: UInt8.self)
        return headerSize &+ 1
    }

    @inline(__always)
    static func writeLiteralsHeader(type: Int, count: Int, into output: UnsafeMutableRawPointer) -> Int {
        // Unsafe: up to 3 header bytes (stores of 2 and 4), within the staging buffer.
        if count <= 31 {
            unsafe output.storeBytes(of: UInt8(truncatingIfNeeded: type | count &<< 3), as: UInt8.self)
            return 1
        }
        if count <= 4095 {
            unsafe output.storeBytes(of: UInt16(truncatingIfNeeded: type | 1 &<< 2 | count &<< 4).littleEndian, as: UInt16.self)
            return 2
        }
        unsafe output.storeBytes(of: UInt32(truncatingIfNeeded: type | 3 &<< 2 | count &<< 4).littleEndian, as: UInt32.self)
        return 3
    }

    /// `HUF_compress_internal`: the literals with the previous tree or a new one.
    ///
    /// - Returns: The streams' size (with the tree's description when new); 1 for a single symbol (the caller writes
    ///   a run); 0 when Huffman coding isn't worth it.
    private mutating func compressHuffman(
        _ literals: UnsafeRawPointer, count: Int, into output: UnsafeMutableRawPointer, capacity: Int, singleStream: Bool,
        repeatMode: inout ZstdRepeatMode, preferRepeat: Bool, suspectUncompressible: Bool, newTable: inout Bool
    ) -> Int {
        // Unsafe: the workspace's tables and scratch through pointers, each region sized for what's written (counts
        // 256, tables 256 entries), and the streams within `capacity`.
        let previousTable = unsafe UnsafePointer(
            workspace.pointer(layout.huffmanTables &+ previous.huffman.slot &* 2048).assumingMemoryBound(to: UInt64.self)
        )
        let previousLog = previous.huffman.tableLog
        let source = unsafe literals.assumingMemoryBound(to: UInt8.self)
        @inline(__always)
        func encode(_ table: UnsafePointer<UInt64>, log: Int, at start: Int) -> Int {
            let size = singleStream
                ? unsafe ZstdHuffmanEncoding.encodeStream(
                    output + start, capacity: capacity &- start, source: source, count: count, table: table, tableLog: log
                )
                : unsafe ZstdHuffmanEncoding.encodeFourStreams(
                    output + start, capacity: capacity &- start, source: source, count: count, table: table, tableLog: log
                )
            if size == 0 { return 0 }
            let total = start &+ size
            return total >= count &- 1 ? 0 : total
        }
        if preferRepeat && repeatMode == .valid { return unsafe encode(previousTable, log: previousLog, at: 0) }

        let counts = unsafe workspace.pointer(layout.counts).assumingMemoryBound(to: UInt32.self)
        let sampleSize = 4096
        if suspectUncompressible && count >= sampleSize &* 10 {
            var maximumBegin = 255
            var maximumEnd = 255
            let begin = unsafe ZstdHistogram.count(literals, count: sampleSize, into: counts, maximumSymbol: &maximumBegin)
            let end = unsafe ZstdHistogram.count(literals + (count &- sampleSize), count: sampleSize, into: counts, maximumSymbol: &maximumEnd)
            if begin &+ end <= (2 &* sampleSize) &>> 7 &+ 4 { return 0 }
        }
        var maximumSymbol = 255
        let largest = unsafe ZstdHistogram.countBytes(
            literals, count: count, into: counts,
            scratch: workspace.pointer(layout.histogramScratch).assumingMemoryBound(to: UInt32.self), maximumSymbol: &maximumSymbol
        )
        if largest == count {
            unsafe output.storeBytes(of: literals.load(as: UInt8.self), as: UInt8.self)
            return 1
        }
        if largest <= (count &>> 7) &+ 4 { return 0 }

        if repeatMode == .check && !(unsafe ZstdHuffmanEncoding.isValid(
            previousTable, tableMaximumSymbol: previous.huffman.maximumSymbol, counts: counts, maximumSymbol: maximumSymbol
        )) {
            repeatMode = .none
        }
        if preferRepeat && repeatMode != .none { return unsafe encode(previousTable, log: previousLog, at: 0) }

        // A new tree, in the other slot.
        let slot = 1 &- previous.huffman.slot
        let table = unsafe workspace.pointer(layout.huffmanTables &+ slot &* 2048).assumingMemoryBound(to: UInt64.self)
        let tableLog = ZstdFSEEncoding.optimalTableLog(
            ZstdHuffmanEncoding.maximumCodeLength, total: count, maximumSymbol: maximumSymbol, minus: 1
        )
        let bits = unsafe ZstdHuffmanEncoding.buildTable(
            table, counts: counts, maximumSymbol: maximumSymbol, maximumBits: tableLog,
            scratch: workspace.pointer(layout.huffmanScratch)
        )
        guard let descriptionSize = unsafe ZstdHuffmanEncoding.writeDescription(
            output, capacity: capacity, table: table, maximumSymbol: maximumSymbol, tableLog: bits,
            scratch: workspace.pointer(layout.descriptionScratch)
        ) else { return 0 }
        if repeatMode != .none {
            let oldSize = unsafe ZstdHuffmanEncoding.estimateSize(previousTable, counts: counts, maximumSymbol: maximumSymbol)
            let newSize = unsafe ZstdHuffmanEncoding.estimateSize(table, counts: counts, maximumSymbol: maximumSymbol)
            if oldSize <= descriptionSize &+ newSize || descriptionSize &+ 12 >= count {
                return unsafe encode(previousTable, log: previousLog, at: 0)
            }
        }
        if descriptionSize &+ 12 >= count { return 0 }
        repeatMode = .none
        newTable = true
        next.huffman = ZstdHuffmanState(slot: slot, tableLog: bits, maximumSymbol: maximumSymbol, repeatMode: .none)
        return unsafe encode(UnsafePointer(table), log: bits, at: descriptionSize)
    }

    // MARK: Sequences

    /// `ZSTD_seqToCodes`: each sequence's literal length, match length, and offset codes.
    private func computeCodes(_ store: ZstdSequenceStore) {
        // Unsafe: loads of `store.count` sequences, code stores below it (the code regions hold the maximum), and
        // code-table lookups at lengths below 64 and 128.
        let literalCodes = unsafe workspace.pointer(layout.literalCodes).assumingMemoryBound(to: UInt8.self)
        let matchCodes = unsafe workspace.pointer(layout.matchCodes).assumingMemoryBound(to: UInt8.self)
        let offsetCodes = unsafe workspace.pointer(layout.offsetCodes).assumingMemoryBound(to: UInt8.self)
        let tables = unsafe UnsafeRawPointer(workspace.pointer(layout.codeTables))
        for index in 0..<store.count {
            let sequence = unsafe store.sequences[index]
            let offBase = UInt32(truncatingIfNeeded: sequence)
            let literalLength = Int(truncatingIfNeeded: (sequence &>> 32) & 0xFFFF)
            let matchBase = Int(truncatingIfNeeded: sequence &>> 48)
            unsafe offsetCodes[index] = UInt8(truncatingIfNeeded: 31 &- offBase.leadingZeroBitCount)
            unsafe literalCodes[index] = literalLength > 63
                ? UInt8(truncatingIfNeeded: ZstdFSEEncoding.highBit(literalLength) &+ 19)
                : tables.load(fromByteOffset: ZstdEncoderLayout.literalCodeTable &+ literalLength, as: UInt8.self)
            unsafe matchCodes[index] = matchBase > 127
                ? UInt8(truncatingIfNeeded: ZstdFSEEncoding.highBit(matchBase) &+ 36)
                : tables.load(fromByteOffset: ZstdEncoderLayout.matchCodeTable &+ matchBase, as: UInt8.self)
        }
        if store.longLengthPosition >= 0 {
            if store.longLengthIsMatch {
                unsafe matchCodes[store.longLengthPosition] = 52
            } else {
                unsafe literalCodes[store.longLengthPosition] = 35
            }
        }
    }

    /// Chooses one sequence field's table, builds it, and writes its description (`ZSTD_buildSequencesStatistics`
    /// for one field: `ZSTD_selectEncodingType`, then `ZSTD_buildCTable`).
    ///
    /// - Returns: The field's mode: 0 predefined, 1 RLE, 2 described, 3 repeated.
    private func buildTable(
        _ field: ZstdSequenceField, codes: UnsafeMutableRawPointer, count: Int, state: inout ZstdTableState,
        previousState: ZstdTableState, strategy: Int, output: UnsafeMutableRawPointer, written: inout Int,
        lastDescriptionSize: inout Int
    ) -> Int {
        // Unsafe: counts (64 entries, codes below that), normalized counts and scratch from the workspace, and the
        // description's stores at `output` (the caller checked `descriptionBound` bytes of room).
        let counts = unsafe workspace.pointer(layout.counts).assumingMemoryBound(to: UInt32.self)
        var maximumSymbol = field.maximumSymbol
        // Four interleaved tables for many codes (`HIST_countFast_wksp`): runs of one code would otherwise make each
        // increment wait for the one before.
        let mostFrequent = unsafe ZstdHistogram.countBytes(
            UnsafeRawPointer(codes), count: count, into: counts,
            scratch: workspace.pointer(layout.histogramScratch).assumingMemoryBound(to: UInt32.self), maximumSymbol: &maximumSymbol
        )
        let defaultAllowed = field.index != 1 || maximumSymbol <= field.defaultMaximumSymbol
        state.repeatMode = previousState.repeatMode
        let mode = unsafe selectMode(
            field, repeatMode: &state.repeatMode, counts: counts, maximumSymbol: maximumSymbol, mostFrequent: mostFrequent,
            count: count, previousState: previousState, defaultAllowed: defaultAllowed, strategy: strategy
        )
        switch mode {
        case 1:
            let region = layout.fseRegion(field.index, 1)
            unsafe ZstdFSETable.buildRLE(workspace.pointer(region), symbol: maximumSymbol)
            state = ZstdTableState(region: region, tableLog: 0, maximumSymbol: maximumSymbol, repeatMode: state.repeatMode)
            unsafe output.storeBytes(of: codes.load(as: UInt8.self), as: UInt8.self)
            written &+= 1
        case 3:
            state = ZstdTableState(
                region: previousState.region, tableLog: previousState.tableLog, maximumSymbol: previousState.maximumSymbol,
                repeatMode: state.repeatMode
            )
        case 0:
            state = ZstdTableState(
                region: layout.fseRegion(field.index, 0), tableLog: field.defaultLog, maximumSymbol: field.defaultMaximumSymbol,
                repeatMode: state.repeatMode
            )
        default:
            let tableLog = ZstdFSEEncoding.optimalTableLog(field.maximumTableLog, total: count, maximumSymbol: maximumSymbol)
            var total = count
            let last = Int(unsafe codes.load(fromByteOffset: count &- 1, as: UInt8.self))
            if unsafe counts[last] > 1 {
                unsafe counts[last] &-= 1
                total &-= 1
            }
            let normalized = unsafe workspace.pointer(layout.normalized).assumingMemoryBound(to: Int16.self)
            _ = unsafe ZstdFSEEncoding.normalize(
                normalized, tableLog: tableLog, counts: counts, total: total, maximumSymbol: maximumSymbol,
                useLowProbabilityCount: total >= 2048
            )
            let size = unsafe ZstdFSEEncoding.writeDescription(output, normalized: normalized, maximumSymbol: maximumSymbol, tableLog: tableLog)
            // The slot the previous block's table isn't in.
            let first = layout.fseRegion(field.index, 2)
            let region = previousState.region == first ? layout.fseRegion(field.index, 3) : first
            unsafe ZstdFSETable.build(
                workspace.pointer(region), normalized: normalized, maximumSymbol: maximumSymbol, tableLog: tableLog,
                scratch: workspace.pointer(layout.fseScratch)
            )
            state = ZstdTableState(region: region, tableLog: tableLog, maximumSymbol: maximumSymbol, repeatMode: state.repeatMode)
            written &+= size
            lastDescriptionSize = size
        }
        return mode
    }

    /// `ZSTD_selectEncodingType`: libzstd's heuristics below the lazy strategies, its cost estimates from them on.
    private func selectMode(
        _ field: ZstdSequenceField, repeatMode: inout ZstdRepeatMode, counts: UnsafePointer<UInt32>, maximumSymbol: Int,
        mostFrequent: Int, count: Int, previousState: ZstdTableState, defaultAllowed: Bool, strategy: Int
    ) -> Int {
        if mostFrequent == count {
            repeatMode = .none
            // Predefined beats RLE for two sequences or fewer.
            return defaultAllowed && count <= 2 ? 0 : 1
        }
        if strategy < ZstdStrategyNumber.lazy {
            if defaultAllowed {
                let multiplier = 10 &- strategy
                let dynamicMinimum = ((1 &<< field.defaultLog) &* multiplier) &>> 3
                if repeatMode == .valid && count < 1000 { return 3 }
                if count < dynamicMinimum || mostFrequent < count &>> (field.defaultLog &- 1) {
                    repeatMode = .none
                    return 0
                }
            }
        } else {
            // Costs in bits, scaled as libzstd's (`Int.max` for "not possible").
            let basicCost = defaultAllowed ? unsafe crossEntropyCost(field, counts: counts, maximumSymbol: maximumSymbol) : Int.max
            let repeatCost = repeatMode != .none
                ? unsafe fseBitCost(previousState, counts: counts, maximumSymbol: maximumSymbol) : Int.max
            let descriptionCost = unsafe descriptionCost(field, counts: counts, maximumSymbol: maximumSymbol, count: count)
            let compressedCost = (descriptionCost &<< 3) &+ (unsafe Self.entropyCost(counts, maximumSymbol: maximumSymbol, total: count))
            if basicCost <= repeatCost && basicCost <= compressedCost {
                repeatMode = .none
                return 0
            }
            if repeatCost <= compressedCost { return 3 }
        }
        repeatMode = .check
        return 2
    }

    /// `ZSTD_crossEntropyCost` of the counts against the field's predefined distribution.
    private func crossEntropyCost(_ field: ZstdSequenceField, counts: UnsafePointer<UInt32>, maximumSymbol: Int) -> Int {
        let norm: [Int16] = switch field.index {
        case 0: Zstd.literalLengthDefaultNorm
        case 1: Zstd.offsetDefaultNorm
        default: Zstd.matchLengthDefaultNorm
        }
        let shift = 8 &- field.defaultLog
        var cost = 0
        // Unsafe: counts up to `maximumSymbol`, within the predefined distribution (checked by the caller).
        for symbol in 0...maximumSymbol {
            let value = Int(norm[symbol])
            let probability = (value != -1 ? value : 1) &<< shift
            cost &+= Int(unsafe counts[symbol]) &* Self.inverseProbabilityLog256[probability]
        }
        return cost &>> 8
    }

    /// `ZSTD_fseBitCost` of the counts with the previous block's table, or `Int.max` if it lacks a symbol.
    private func fseBitCost(_ state: ZstdTableState, counts: UnsafePointer<UInt32>, maximumSymbol: Int) -> Int {
        if state.maximumSymbol < maximumSymbol { return Int.max }
        let accuracyLog = 8
        var cost = 0
        // Unsafe: the table's transforms, up to `maximumSymbol` (at most the table's), and counts.
        let table = unsafe UnsafeRawPointer(workspace.pointer(state.region))
        for symbol in 0...maximumSymbol {
            let bitCost = unsafe ZstdFSETable.bitCost(table, tableLog: state.tableLog, symbol: symbol, accuracyLog: accuracyLog)
            let symbolCount = Int(unsafe counts[symbol])
            if symbolCount == 0 { continue }
            if bitCost >= (state.tableLog &+ 1) &<< accuracyLog { return Int.max }
            cost &+= symbolCount &* bitCost
        }
        return cost &>> accuracyLog
    }

    /// `ZSTD_NCountCost`: the size of the table description a new table would need.
    private func descriptionCost(_ field: ZstdSequenceField, counts: UnsafePointer<UInt32>, maximumSymbol: Int, count: Int) -> Int {
        // Unsafe: normalized counts in the workspace, and the description written to the scratch (bound: 80 bytes).
        let normalized = unsafe workspace.pointer(layout.normalized).assumingMemoryBound(to: Int16.self)
        let tableLog = ZstdFSEEncoding.optimalTableLog(field.maximumTableLog, total: count, maximumSymbol: maximumSymbol)
        guard unsafe ZstdFSEEncoding.normalize(
            normalized, tableLog: tableLog, counts: counts, total: count, maximumSymbol: maximumSymbol,
            useLowProbabilityCount: count >= 2048
        ) else { return Int.max &>> 4 }
        return unsafe ZstdFSEEncoding.writeDescription(
            workspace.pointer(layout.fseScratch), normalized: normalized, maximumSymbol: maximumSymbol, tableLog: tableLog
        )
    }

    /// `ZSTD_entropyCost`: the counts' cost at their own probabilities.
    private static func entropyCost(_ counts: UnsafePointer<UInt32>, maximumSymbol: Int, total: Int) -> Int {
        var cost = 0
        // Unsafe: counts up to `maximumSymbol`.
        for symbol in 0...maximumSymbol {
            let count = Int(unsafe counts[symbol])
            var probability = (256 &* count) / total
            if count != 0 && probability == 0 { probability = 1 }
            cost &+= count &* inverseProbabilityLog256[probability]
        }
        return cost &>> 8
    }

    /// `kInverseProbabilityLog256`: -log2(x / 256) in 1/256 bits.
    static let inverseProbabilityLog256: [Int] = [
        0, 2048, 1792, 1642, 1536, 1453, 1386, 1329, 1280, 1236, 1197, 1162, 1130, 1100, 1073, 1047, 1024, 1001, 980, 960,
        941, 923, 906, 889, 874, 859, 844, 830, 817, 804, 791, 779, 768, 756, 745, 734, 724, 714, 704, 694, 685, 676, 667,
        658, 650, 642, 633, 626, 618, 610, 603, 595, 588, 581, 574, 567, 561, 554, 548, 542, 535, 529, 523, 517, 512, 506,
        500, 495, 489, 484, 478, 473, 468, 463, 458, 453, 448, 443, 438, 434, 429, 424, 420, 415, 411, 407, 402, 398, 394,
        390, 386, 382, 377, 373, 370, 366, 362, 358, 354, 350, 347, 343, 339, 336, 332, 329, 325, 322, 318, 315, 311, 308,
        305, 302, 298, 295, 292, 289, 286, 282, 279, 276, 273, 270, 267, 264, 261, 258, 256, 253, 250, 247, 244, 241, 239,
        236, 233, 230, 228, 225, 222, 220, 217, 215, 212, 209, 207, 204, 202, 199, 197, 194, 192, 190, 187, 185, 182, 180,
        178, 175, 173, 171, 168, 166, 164, 162, 159, 157, 155, 153, 151, 149, 146, 144, 142, 140, 138, 136, 134, 132, 130,
        128, 126, 123, 121, 119, 117, 115, 114, 112, 110, 108, 106, 104, 102, 100, 98, 96, 94, 93, 91, 89, 87, 85, 83, 82,
        80, 78, 76, 74, 73, 71, 69, 67, 66, 64, 62, 61, 59, 57, 55, 54, 52, 50, 49, 47, 46, 44, 42, 41, 39, 37, 36, 34, 33,
        31, 30, 28, 26, 25, 23, 22, 20, 19, 17, 16, 14, 13, 11, 10, 8, 7, 5, 4, 2, 1,
    ]

    /// `ZSTD_encodeSequences`: the sequences' bitstream, from the last sequence to the first, three interleaved FSE
    /// states and each sequence's extra bits, in the order the decoder reads them backward.
    ///
    /// - Returns: The bitstream's size, or 0 if it doesn't fit in `capacity`.
    private func encodeSequences(_ store: ZstdSequenceStore, into output: UnsafeMutableRawPointer, capacity: Int) -> Int {
        // Unsafe: sequence and code loads below `store.count`, bit-count lookups at codes (below 36 and 53), the
        // tables' states (by construction), and the writer within `capacity`.
        guard var writer = unsafe ZstdBitWriter(output, capacity: capacity) else { return 0 }
        let literalCodes = unsafe workspace.pointer(layout.literalCodes).assumingMemoryBound(to: UInt8.self)
        let matchCodes = unsafe workspace.pointer(layout.matchCodes).assumingMemoryBound(to: UInt8.self)
        let offsetCodes = unsafe workspace.pointer(layout.offsetCodes).assumingMemoryBound(to: UInt8.self)
        let tables = unsafe UnsafeRawPointer(workspace.pointer(layout.codeTables))
        let literalBits = unsafe (tables + ZstdEncoderLayout.literalBitsTable).assumingMemoryBound(to: UInt8.self)
        let matchBits = unsafe (tables + ZstdEncoderLayout.matchBitsTable).assumingMemoryBound(to: UInt8.self)
        let sequences = unsafe store.sequences
        let last = store.count &- 1

        var matchLengthState = unsafe ZstdFSEState(
            workspace.pointer(next.matchLength.region), tableLog: next.matchLength.tableLog, symbol: Int(matchCodes[last])
        )
        var offsetState = unsafe ZstdFSEState(
            workspace.pointer(next.offset.region), tableLog: next.offset.tableLog, symbol: Int(offsetCodes[last])
        )
        var literalLengthState = unsafe ZstdFSEState(
            workspace.pointer(next.literalLength.region), tableLog: next.literalLength.tableLog, symbol: Int(literalCodes[last])
        )
        do {
            let sequence = unsafe sequences[last]
            writer.add((sequence &>> 32) & 0xFFFF, Int(unsafe literalBits[Int(literalCodes[last])]))
            writer.add(sequence &>> 48, Int(unsafe matchBits[Int(matchCodes[last])]))
            writer.add(sequence & 0xFFFF_FFFF, Int(unsafe offsetCodes[last]))
            writer.flush()
        }
        var index = last &- 1
        while index >= 0 {
            let literalCode = Int(unsafe literalCodes[index])
            let offsetCode = Int(unsafe offsetCodes[index])
            let matchCode = Int(unsafe matchCodes[index])
            let literalLengthBits = Int(unsafe literalBits[literalCode])
            let matchLengthBits = Int(unsafe matchBits[matchCode])
            let sequence = unsafe sequences[index]
            offsetState.encode(offsetCode, into: &writer)
            matchLengthState.encode(matchCode, into: &writer)
            literalLengthState.encode(literalCode, into: &writer)
            let extraBits = offsetCode &+ matchLengthBits &+ literalLengthBits
            if extraBits >= 64 &- 7 &- (9 &+ 9 &+ 8) { writer.flush() }
            writer.add((sequence &>> 32) & 0xFFFF, literalLengthBits)
            writer.add(sequence &>> 48, matchLengthBits)
            if extraBits > 56 { writer.flush() }
            writer.add(sequence & 0xFFFF_FFFF, offsetCode)
            writer.flush()
            index &-= 1
        }
        matchLengthState.flush(into: &writer)
        offsetState.flush(into: &writer)
        literalLengthState.flush(into: &writer)
        return writer.close()
    }
}

// MARK: - Pre-splitting

/// libzstd 1.5.7's block pre-splitter (`zstd_preSplit.c`): whether a full 128 KB block's statistics change partway, so
/// it's better as two blocks with tables of their own. From the borders (the `fast` strategy: its first, middle, and
/// last 512 bytes) or by 8 KB chunks sampled every 43rd byte (`dfast`).
enum ZstdBlockSplitter {
    // Two fingerprints of 1,024 counts and an event total each.
    static var fingerprintSize: Int { 1024 &* 4 &+ 8 }
    static var scratchSize: Int { 2 &* fingerprintSize &+ 64 }

    /// The size of the next block of the `remaining` bytes at `source`, at most `blockSizeMaximum`
    /// (`ZSTD_optimalBlockSize`).
    static func blockSize(
        _ source: UnsafeRawPointer, remaining: Int, blockSizeMaximum: Int, strategy: Int, savings: Int,
        scratch: UnsafeMutableRawPointer
    ) -> Int {
        let full = 128 << 10
        if remaining < full || blockSizeMaximum < full { return min(remaining, blockSizeMaximum) }
        if savings < 3 { return full }
        // Unsafe: the scratch's two fingerprints, and reads within the block's 128 KB.
        if strategy == ZstdStrategyNumber.fast {
            return unsafe splitFromBorders(source, scratch: scratch)
        }
        // `splitLevels`: dfast 1, greedy and lazy 2; then level - 1 picks the sampling.
        let level = strategy == ZstdStrategyNumber.doubleFast ? 0 : 1
        return unsafe splitByChunks(source, level: level, scratch: scratch)
    }

    @inline(__always)
    private static func events(_ scratch: UnsafeMutableRawPointer, _ which: Int) -> UnsafeMutablePointer<UInt32> {
        unsafe (scratch + which &* fingerprintSize).assumingMemoryBound(to: UInt32.self)
    }

    @inline(__always)
    private static func eventCount(_ scratch: UnsafeMutableRawPointer, _ which: Int) -> UnsafeMutablePointer<UInt64> {
        unsafe (scratch + (which &* fingerprintSize &+ 4096)).assumingMemoryBound(to: UInt64.self)
    }

    /// `fpDistance`: how far apart two fingerprints' distributions are.
    private static func distance(
        _ first: UnsafePointer<UInt32>, _ firstCount: UInt64, _ second: UnsafePointer<UInt32>, _ secondCount: UInt64,
        hashLog: Int
    ) -> UInt64 {
        var total: UInt64 = 0
        // Unsafe: entries below `1 << hashLog`, at most 1,024.
        for index in 0..<(1 &<< hashLog) {
            let a = Int64(unsafe first[index]) &* Int64(bitPattern: secondCount)
            let b = Int64(unsafe second[index]) &* Int64(bitPattern: firstCount)
            total &+= (a &- b).magnitude
        }
        return total
    }

    /// `compareFingerprints`: whether the new chunk differs from what came before by more than the threshold.
    private static func differs(
        _ reference: UnsafePointer<UInt32>, _ referenceCount: UInt64, _ new: UnsafePointer<UInt32>, _ newCount: UInt64,
        penalty: Int, hashLog: Int
    ) -> Bool {
        let p50 = referenceCount &* newCount
        let deviation = unsafe distance(reference, referenceCount, new, newCount, hashLog: hashLog)
        let threshold = p50 &* UInt64(14 &+ penalty) / 16
        return deviation >= threshold
    }

    /// `ZSTD_splitBlock_fromBorders`.
    private static func splitFromBorders(_ source: UnsafeRawPointer, scratch: UnsafeMutableRawPointer) -> Int {
        // Unsafe: the scratch (zeroed here) and reads of three 512-byte segments of the 128 KB block.
        let segment = 512
        let blockSize = 128 << 10
        unsafe scratch.initializeMemory(as: UInt8.self, repeating: 0, count: 2 &* fingerprintSize)
        let past = unsafe events(scratch, 0)
        let new = unsafe events(scratch, 1)
        // libzstd's middle fingerprint overlaps the first one's unused high entries.
        let middle = unsafe (scratch + 512 &* 4).assumingMemoryBound(to: UInt32.self)
        for index in 0..<segment {
            unsafe past[Int(source.load(fromByteOffset: index, as: UInt8.self))] &+= 1
            unsafe new[Int(source.load(fromByteOffset: blockSize &- segment &+ index, as: UInt8.self))] &+= 1
        }
        let count = UInt64(segment)
        if !(unsafe differs(past, count, new, count, penalty: 0, hashLog: 8)) { return blockSize }
        for index in 0..<segment {
            unsafe middle[Int(source.load(fromByteOffset: blockSize / 2 &- segment / 2 &+ index, as: UInt8.self))] &+= 1
        }
        let fromBegin = unsafe distance(past, count, middle, count, hashLog: 8)
        let fromEnd = unsafe distance(new, count, middle, count, hashLog: 8)
        let minimumDistance = UInt64(segment &* segment / 3)
        if (Int64(bitPattern: fromBegin) &- Int64(bitPattern: fromEnd)).magnitude < minimumDistance { return 64 << 10 }
        return fromBegin > fromEnd ? 32 << 10 : 96 << 10
    }

    /// `ZSTD_splitBlock_byChunks`: 8 KB chunks fingerprinted by sampled 2-byte hashes, split at the first that
    /// differs from those before it.
    private static func splitByChunks(_ source: UnsafeRawPointer, level: Int, scratch: UnsafeMutableRawPointer) -> Int {
        let chunkSize = 8 << 10
        let blockSize = 128 << 10
        let samplingRate = level == 0 ? 43 : 11
        let hashLog = level == 0 ? 8 : 9
        // Unsafe: the scratch's fingerprints (entries below `1 << hashLog`) and reads within the block (2-byte reads
        // below each chunk's end).
        unsafe scratch.initializeMemory(as: UInt8.self, repeating: 0, count: 2 &* fingerprintSize)
        let past = unsafe events(scratch, 0)
        let new = unsafe events(scratch, 1)
        @inline(__always)
        func record(_ fingerprint: UnsafeMutablePointer<UInt32>, at start: Int) -> UInt64 {
            unsafe fingerprint.update(repeating: 0, count: 1 &<< hashLog)
            let limit = chunkSize &- 2 &+ 1
            var index = 0
            while index < limit {
                let hash: Int
                if hashLog == 8 {
                    hash = Int(unsafe source.load(fromByteOffset: start &+ index, as: UInt8.self))
                } else {
                    let pair = UInt32(UInt16(littleEndian: unsafe source.loadUnaligned(fromByteOffset: start &+ index, as: UInt16.self)))
                    hash = Int((pair &* 0x9E37_79B9) &>> UInt32(32 &- hashLog))
                }
                unsafe fingerprint[hash] &+= 1
                index &+= samplingRate
            }
            return UInt64(limit / samplingRate)
        }
        var pastCount = unsafe record(past, at: 0)
        var penalty = 3
        var position = chunkSize
        while position <= blockSize &- chunkSize {
            let newCount = unsafe record(new, at: position)
            if unsafe differs(past, pastCount, new, newCount, penalty: penalty, hashLog: hashLog) { return position }
            for index in 0..<1024 { unsafe past[index] &+= new[index] }
            pastCount &+= newCount
            if penalty > 0 { penalty &-= 1 }
            position &+= chunkSize
        }
        return blockSize
    }
}
