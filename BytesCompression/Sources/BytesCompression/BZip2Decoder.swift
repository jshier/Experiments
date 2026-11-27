package import Bytes
#if HardwareCRC && arch(arm64) && !Portable
internal import CBytesCompression
#endif

/// A bzip2 decoder: the `.bz2` format of bzip2 0.9.5 and later (Julian Seward's), whole streams into a whole
/// buffer, or into output of any size, as it's wanted.
///
/// ```swift
/// var decoder = BZip2Decoder()
/// let consumed = try decoder.decompressAll(stream, into: &output)   // through the end-of-stream marker
///
/// decoder.reset()                                                   // the next stream, a buffer at a time
/// let progress = try decoder.decompress(rest, into: &chunk)
/// ```
///
/// A stream is a 4-byte header (`BZh1` through `BZh9`, the block size in 100,000s), blocks, and an end marker
/// with a CRC of the block CRCs. Each block is up to that many bytes, run-length encoded (runs of 4 to 255 equal
/// bytes as 4 and a count), Burrows–Wheeler transformed, move-to-front coded, zero runs coded in bijective base
/// 2 (RUNA and RUNB), and Huffman coded with up to six tables chosen per 50 symbols. Streams written one after
/// another (`cat a.bz2 b.bz2`, and parallel compressors' output) are decoded as one.
///
/// Decoding a block takes four passes:
///
/// 1. Symbols: Huffman codes through a 10-bit lookup table per table (longer codes, and the end of the block,
///    from the canonical limits), with each refill's 8 bytes loaded a symbol ahead; the move-to-front list's
///    first 16 bytes in a register (a `tbl`, an `ext`, and a select per move); RUNA and RUNB against indices
///    without branches. Out come runs of equal bytes (the BWT, run-length coded) and each byte's count.
/// 2. Links: for each position, where its byte's occurrence sorts to (the inverse BWT), written from the runs
///    as ramps, 4 entries at a time.
/// 3. The walk: the links followed from the block's origin, a dependent load per byte from 3.6 MB. Large blocks
///    are cut into up to 879 segments, 24 followed at once (`BZip2Segments`), which overlaps the loads' latency;
///    small ones are walked from both ends at once.
/// 4. The run-length coding undone into the output, 16 bytes at a time where no 4 equal bytes end.
///
/// Then the block's CRC (bzip2's: CRC-32's polynomial, most significant bit first, folded with `pmull` on
/// Apple silicon) is checked, and at the end the stream's. Blocks old encoders "randomized" (bzip2 0.9.0 and
/// 0.9.5 did, for repetitive data; 1.0 never does) are decoded too.
///
/// ``decompress(_:into:)`` decodes a block at a time into the workspace and undoes its run-length coding
/// straight into the caller's output, stopping wherever that fills (a block can expand far beyond its 900 KB
/// through runs), so memory stays the workspace's however large the stream.
///
/// The decoder's workspace (7.8 MB: links for the largest block, its runs, tables) is allocated once, at
/// creation, and not zeroed (a small stream touches only the pages it uses); decoding allocates nothing. Malformed input throws; it never reads or writes outside the buffers.
@safe
package struct BZip2Decoder: ~Copyable {
    var workspace = BZip2Workspace()
    /// Where ``decompress(_:into:)`` is in the current stream.
    var streaming = BZip2StreamingState()

    /// Creates a decoder, allocating its workspace.
    package init() {}

    /// Decodes a bzip2 stream, and any streams that directly follow it, into `output`'s free capacity.
    ///
    /// The fastest way to decode, when the output has room for all of it. Every call starts a new stream: a decoder
    /// used before (by any call) starts over as after ``reset()``, keeping its memory, so it discards any stream
    /// ``decompress(_:into:)`` was decoding.
    ///
    /// - Parameters:
    ///   - input: The stream, at its `BZh` header. Bytes after the last stream's end marker (rounded up to a
    ///     whole byte) that don't start another stream are left alone.
    ///   - output: Where to append the decoded bytes; it needs room for all of them (for `decodedSize`, when
    ///     given). Bytes of its free capacity past them may be overwritten (none past `decodedSize`).
    ///   - decodedSize: The size the container says the stream decodes to, if it does: a stream decoding to more
    ///     or fewer bytes throws ``BytesError/mismatch``.
    /// - Returns: The number of input bytes decoded, through the last stream's end marker.
    /// - Throws: ``BytesError/insufficientData`` if the input ends early; ``BytesError/insufficientCapacity``
    ///   if the output doesn't fit (or has room for fewer than `decodedSize` bytes); ``BytesError/mismatch`` if
    ///   the stream decodes to a size other than `decodedSize`; ``BytesError/checksumMismatch`` for a CRC that
    ///   doesn't match; ``BytesError/invalidValue`` for a missing header, corrupt data, or a negative
    ///   `decodedSize`.
    package mutating func decompressAll(
        _ input: RawSpan, into output: inout OutputRawSpan, decodedSize: Int? = nil
    ) throws(BytesError) -> Int {
        reset()
        if let decodedSize {
            guard decodedSize >= 0 else { throw .invalidValue }
            guard decodedSize <= output.freeCapacity else { throw .insufficientCapacity }
        }
        let workspace = unsafe workspace.base
        return try unsafe LZBuffers.with(input, &output, byteCount: decodedSize) { input, count, output, capacity throws(BytesError) -> (Int, Int) in
            // Unsafe: the buffers' addresses (a placeholder for an empty output, never written: every write is
            // checked against the capacity first).
            let result = try unsafe BZip2Stream.decode(
                input, count: count, output: output.assumingMemoryBound(to: UInt8.self), capacity: capacity,
                overrun: decodedSize == nil ? .insufficientCapacity : .mismatch, workspace: workspace
            )
            if let decodedSize, result.produced != decodedSize { throw .mismatch }
            return (result.consumed, result.produced)
        }
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension BZip2Decoder: @unchecked Sendable {}

// MARK: - Streams and blocks

enum BZip2Stream {
    /// The longest Huffman code bzip2 allows.
    static var maximumCodeLength: Int { 20 }
    /// Bits of the primary lookup tables: codes this long or shorter take one lookup.
    static var tableBits: Int { 10 }
    /// The most selectors a block uses (900,000 / 50, plus slack, as libbzip2 keeps); more are read and ignored.
    static var maximumSelectors: Int { 18_002 }
    /// The 48-bit block and end-of-stream magics (the BCD digits of π and √π).
    static var blockMagic: UInt64 { 0x3141_5926_5359 }
    static var endMagic: UInt64 { 0x1772_4538_5090 }

    /// Decodes the stream at the start of `input`, then each stream that directly follows.
    ///
    /// - Returns: The input consumed, and the bytes written.
    static func decode(
        _ input: UnsafeRawPointer, count: Int, output: UnsafeMutablePointer<UInt8>, capacity: Int,
        overrun: BytesError, workspace: UnsafeMutableRawPointer
    ) throws(BytesError) -> (consumed: Int, produced: Int) {
        // Unsafe: header byte loads. Safe: each is below `count`. (The bytes there must start "BZh".)
        for index in 0..<min(count, 3) {
            let expected = UInt8(truncatingIfNeeded: 0x42_5A_68 &>> (16 &- index &* 8))
            guard unsafe input.load(fromByteOffset: index, as: UInt8.self) == expected else { throw .invalidValue }
        }
        guard count >= 4 else { throw .insufficientData }
        var position = 0
        var produced = 0
        repeat {
            (position, produced) = try unsafe decodeStream(
                input, count: count, at: position, output: output, at: produced, capacity: capacity, overrun: overrun,
                workspace: workspace
            )
        } while unsafe startsStream(input, count: count, at: position)
        return (position, produced)
    }

    /// Whether a stream header (`BZh1` through `BZh9`) is at `position`.
    static func startsStream(_ input: UnsafeRawPointer, count: Int, at position: Int) -> Bool {
        guard count &- position >= 4 else { return false }
        // Unsafe: a 4-byte load. Safe: 4 bytes remain at `position`.
        let header = UInt32(bigEndian: unsafe input.loadUnaligned(fromByteOffset: position, as: UInt32.self))
        return header &>> 8 == 0x42_5A_68 && header & 0xFF >= 0x31 && header & 0xFF <= 0x39
    }

    /// Decodes one stream, from its header through its end marker.
    ///
    /// - Returns: The input position after the stream (its last byte's padding bits included), and the output's.
    static func decodeStream(
        _ input: UnsafeRawPointer, count: Int, at start: Int, output: UnsafeMutablePointer<UInt8>,
        at outputStart: Int, capacity: Int, overrun: BytesError, workspace: UnsafeMutableRawPointer
    ) throws(BytesError) -> (Int, Int) {
        // Unsafe: the header's level byte, and the workspace's regions. Safe: `decode` checked that 4 bytes
        // remain (or `startsStream` did); the regions are within the workspace by their constant offsets.
        let level = Int(unsafe input.load(fromByteOffset: start &+ 3, as: UInt8.self)) &- 0x30
        guard level >= 1 && level <= 9 else { throw .invalidValue }
        let blockLimit = level &* 100_000
        var bits = unsafe BZip2Bits(input, end: count, at: start &+ 4)
        var produced = outputStart
        var combinedCRC: UInt32 = 0
        let block = unsafe (workspace + BZip2Workspace.runs).assumingMemoryBound(to: UInt8.self)
        while true {
            let magic = bits.read(48)
            if magic == endMagic {
                let stored = UInt32(truncatingIfNeeded: bits.read(32))
                guard !bits.isOverrun else { throw .insufficientData }
                guard stored == combinedCRC else { throw .checksumMismatch }
                return ((bits.bitPosition &+ 7) &>> 3, produced)
            }
            guard magic == blockMagic else { throw bits.failure }
            let storedCRC = UInt32(truncatingIfNeeded: bits.read(32))
            let randomized = bits.read(1) != 0
            let origin = Int(truncatingIfNeeded: bits.read(24))
            var tables = try unsafe readTableHeader(&bits, workspace: workspace)
            let complete: Bool
            (bits, complete) = try unsafe readTableBody(bits, &tables, workspace: workspace)
            guard complete else { throw .insufficientData }
            let header = tables.header
            let length: Int
            let runCount: Int
            (bits, length, runCount) = try unsafe decodeSymbols(bits, header: header, workspace: workspace, blockLimit: blockLimit)
            guard !bits.isOverrun else { throw .insufficientData }
            guard origin < length else { throw .invalidValue }
            if length >= BZip2Segments.minimumBlock {
                unsafe linkPadded(workspace, count: runCount)
                try unsafe BZip2Segments.walk(workspace, count: length, origin: origin)
            } else {
                unsafe link(workspace, count: runCount)
                unsafe walk(workspace, count: length, origin: origin)
            }
            if randomized { unsafe derandomize(block, count: length) }
            let blockStart = produced
            produced = try unsafe expandRuns(UnsafePointer(block), count: length, output: output, at: produced, capacity: capacity, overrun: overrun)
            let crc = unsafe BZip2CRC.checksum(output + blockStart, count: produced &- blockStart)
            guard crc == storedCRC else { throw .checksumMismatch }
            combinedCRC = (combinedCRC &<< 1 | combinedCRC &>> 31) ^ crc
        }
    }

    // MARK: Tables

    /// The most ±1 steps a code length takes from the one before it: lengths are 1 through 20, so 19 reach any
    /// of them (libbzip2 writes the fewest). More is corrupt (libbzip2 accepts any number of `+1 −1` pairs): the
    /// bound keeps a table's code lengths, and so what a streaming call may need at once, finite.
    static var maximumLengthSteps: Int { 20 }

    /// The most bits one table's code lengths take: a 5-bit start, then for each symbol (up to 258) at most
    /// ``maximumLengthSteps`` 2-bit steps and a stop bit. The largest part of a block that's read whole (see
    /// ``readTableBody(_:_:workspace:)``), so the most input a streaming call needs at once.
    static var maximumTableLengthBits: Int { 5 &+ 258 &* (2 &* maximumLengthSteps &+ 1) }

    /// The selectors read as one part of a block's tables: at most 6 bits each (`ones < groupCount <= 6`).
    static var selectorBatch: Int { 256 }

    /// Reads a block's symbol map and its table and selector counts, writing the move-to-front list into the
    /// workspace: 290 bits at most, read whole (a streaming caller reads them again, with the block's magic, CRC,
    /// and origin before them, when they run past the input).
    ///
    /// - Returns: The tables' progress, with no selectors or code lengths read yet.
    /// - Throws: ``BytesError/invalidValue`` for an empty map, a table count other than 2 through 6, or no
    ///   selectors; ``BytesError/insufficientData`` for those read past the input's end.
    @inline(__always)
    static func readTableHeader(_ bits: inout BZip2Bits, workspace: UnsafeMutableRawPointer) throws(BytesError) -> BZip2TableProgress {
        // Unsafe: the list region. Safe: within the workspace by its constant offset; indices below 256, its size.
        let list = unsafe (workspace + BZip2Workspace.list).assumingMemoryBound(to: UInt8.self)
        // The symbol map: 16 bits saying which ranges of 16 bytes appear, then 16 bits for each that does.
        let ranges = bits.read(16)
        var symbolCount = 0
        for range in 0..<16 where ranges & (0x8000 &>> UInt64(range)) != 0 {
            let used = bits.read(16)
            for low in 0..<16 where used & (0x8000 &>> UInt64(low)) != 0 {
                // Unsafe: a list store. Safe: at most 256 bytes appear, the list's size.
                unsafe list[symbolCount] = UInt8(truncatingIfNeeded: range &<< 4 | low)
                symbolCount &+= 1
            }
        }
        guard symbolCount > 0 else { throw bits.failure }
        let groupCount = Int(truncatingIfNeeded: bits.read(3))
        guard groupCount >= 2 && groupCount <= 6 else { throw bits.failure }
        let selectorCount = Int(truncatingIfNeeded: bits.read(15))
        guard selectorCount >= 1 else { throw bits.failure }
        return BZip2TableProgress(alphabetSize: symbolCount &+ 2, groupCount: groupCount, storedSelectorCount: selectorCount)
    }

    /// Reads a block's selectors and code lengths from where `progress` says, building each table's decoding
    /// tables in the workspace once its lengths are read.
    ///
    /// The tables are read in parts, each whole or not at all: ``selectorBatch`` selectors at a time, then one
    /// table's code lengths at a time. A part that runs past the input's end is left for the next call (the bits
    /// returned are at its start, and `progress` names it), so input that arrives a little at a time costs each
    /// part once, not the whole tables again on every call.
    ///
    /// - Returns: The bits after the tables, and `true`; or, when the input ran out, the bits at the start of the
    ///   part it ran out in, and `false`.
    /// - Throws: ``BytesError/invalidValue`` for a selector past the tables, a code length outside 1 through 20, or
    ///   one more than ``maximumLengthSteps`` steps from the one before.
    @inline(never)
    static func readTableBody(
        _ bits: BZip2Bits, _ progress: inout BZip2TableProgress, workspace: UnsafeMutableRawPointer
    ) throws(BytesError) -> (BZip2Bits, Bool) {
        // Unsafe: the workspace's regions. Safe: within it by their constant offsets; every index is below its
        // region's size (stated at each use).
        var bits = bits
        let groupCount = progress.groupCount
        // Selectors are move-to-front indices of the tables, in unary: the list is six bytes of a register. Past the
        // input's end, zeros are read: valid selectors, which only the batch's overrun check tells from input.
        let selectors = unsafe (workspace + BZip2Workspace.selectors).assumingMemoryBound(to: UInt8.self)
        while progress.selector < progress.storedSelectorCount {
            let start = bits
            let end = min(progress.selector &+ selectorBatch, progress.storedSelectorCount)
            var order = progress.order
            for index in progress.selector..<end {
                if bits.count < 8 { bits.refill() }
                let ones = (~bits.bits).leadingZeroBitCount
                guard ones < groupCount else { throw .invalidValue } // Ones are the input's: zeros follow its end.
                bits.consume(ones &+ 1)
                let shift = UInt64(truncatingIfNeeded: ones &* 8)
                let table = order &>> shift & 0xFF
                let below: UInt64 = (1 &<< shift) &- 1
                order = order & ~(0xFF &<< shift | below) | (order & below) &<< 8 | table
                // Unsafe: a selector store. Safe: below `maximumSelectors`, the region's size.
                if index < maximumSelectors { unsafe selectors[index] = UInt8(truncatingIfNeeded: table) }
            }
            guard !bits.isOverrun else { return (start, false) }
            progress.selector = end
            progress.order = order
        }

        // Code lengths: a 5-bit start, then per symbol, deltas of ±1 (`10` and `11`) ended by a `0`.
        let alphabetSize = progress.alphabetSize
        let lengths = unsafe (workspace + BZip2Workspace.lengths).assumingMemoryBound(to: UInt8.self)
        while progress.group < groupCount {
            let start = bits
            let group = progress.group
            var length = Int(truncatingIfNeeded: bits.read(5))
            for symbol in 0..<alphabetSize {
                var steps = 0
                while true {
                    guard length >= 1 && length <= maximumCodeLength else {
                        // Zeros past the input's end (a start of 0, or a step's second bit) are its end, not corrupt data.
                        if bits.isOverrun { return (start, false) }
                        throw .invalidValue
                    }
                    if bits.count < 2 { bits.refill() }
                    let next = bits.bits &>> 62
                    if next & 2 == 0 {
                        bits.consume(1)
                        break
                    }
                    // A step's first bit is the input's (zeros follow its end), so too many steps are corrupt data.
                    guard steps < maximumLengthSteps else { throw .invalidValue }
                    steps &+= 1
                    bits.consume(2)
                    length &+= next & 1 == 0 ? 1 : -1
                }
                // Unsafe: a length store. Safe: `group` is below 6 and `symbol` below 258, the region's rows.
                unsafe lengths[group &* BZip2Workspace.lengthsStride &+ symbol] = UInt8(truncatingIfNeeded: length)
            }
            guard !bits.isOverrun else { return (start, false) }
            unsafe BZip2Tables.build(
                lengths: lengths + group &* BZip2Workspace.lengthsStride, count: alphabetSize,
                into: workspace + BZip2Workspace.groups + group &* BZip2Tables.stride
            )
            progress.group = group &+ 1
        }
        return (bits, true)
    }

    // MARK: Huffman and move-to-front decoding

    /// Decodes the block's symbols into runs of equal bytes (the block's BWT, run-length coded: each run's length
    /// in bits 8–31, its byte in 0–7), counting each byte.
    ///
    /// Consecutive runs have different bytes: a run ends at a move-to-front index other than 0.
    ///
    /// - Returns: The bit reader after the end-of-block symbol, the block's length, and its number of runs.
    @inline(never)
    static func decodeSymbols(
        _ bits: BZip2Bits, header: BZip2BlockHeader, workspace: UnsafeMutableRawPointer, blockLimit: Int
    ) throws(BytesError) -> (BZip2Bits, Int, Int) {
        // Unsafe: the selectors' and tables' addresses, and `BZip2SymbolState`'s accesses. Safe: selectors are
        // read below `selectorCount`, at most the region's 18,002, and each is a table below `groupCount`, at most
        // 6; the symbol state's accesses are bounded as its `decode` says.
        var state = unsafe BZip2SymbolState(bits: bits, header: header, workspace: workspace)
        let selectors = unsafe (workspace + BZip2Workspace.selectors).assumingMemoryBound(to: UInt8.self)
        let groups = unsafe workspace + BZip2Workspace.groups
        var group = 0
        while true {
            guard group < header.selectorCount else { throw state.bits.failure }
            let table = unsafe UnsafeRawPointer(groups + Int(selectors[group]) &* BZip2Tables.stride)
            group &+= 1
            var ended = false
            if state.bits.end &- state.bits.next >= 160 {
                // 50 symbols take at most 1,000 bits: every refill's 8 bytes are in the input. Each refill's
                // word is loaded a symbol ahead, so the load's latency isn't in the chain from one symbol's
                // length to the next one's lookup.
                var word = unsafe state.bits.nextWord()
                for _ in 0..<50 {
                    state.bits.refill(with: word)
                    word = unsafe state.bits.nextWord()
                    if try unsafe state.decode(table) {
                        ended = true
                        break
                    }
                }
            } else {
                (state, ended) = try unsafe decodeGroupCarefully(state, table: table)
            }
            if ended {
                guard state.length <= blockLimit else { throw state.bits.failure }
                return (state.bits, state.length, state.runCount)
            }
        }
    }

    /// Decodes a group of 50 symbols near the input's end, checking each refill. Out of line, so the main loop
    /// has no calls to save its registers around.
    ///
    /// - Returns: The state after it, and whether the block ended.
    @inline(never)
    static func decodeGroupCarefully(
        _ state: BZip2SymbolState, table: UnsafeRawPointer
    ) throws(BytesError) -> (BZip2SymbolState, Bool) {
        var state = state
        for _ in 0..<50 {
            state.bits.refill()
            if try unsafe state.decode(table) { return (state, true) }
        }
        return (state, false)
    }

    /// Moves the byte at `index` (0 through 255) of the move-to-front list to its front: the list's first 16
    /// bytes in `front`, the rest in memory at `list + 16`.
    ///
    /// - Returns: The byte.
    @inline(__always)
    static func moveToFront(_ front: inout SIMD16<UInt8>, _ list: UnsafeMutableRawPointer, index: Int) -> UInt8 {
        // Unsafe: loads and stores within the list. Safe: `index` is below 256, the list's size; 16-byte moves
        // start at 16 or more and end at `index`.
        let lanes = SIMD16<UInt8>(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
        if likely(index < 16) {
            // The byte picked with a `tbl` (every lane), then lanes 1 through `index` take the lane before them
            // and lane 0 the byte: an `ext` and a select. All in registers, about 6 cycles from one move to the
            // next.
            let picked = ByteLanes(SIMD16<UInt8>(repeating: UInt8(truncatingIfNeeded: index))).lookup(in: front)
            let shifted = SIMD16<UInt8>(
                picked[15], front[0], front[1], front[2], front[3], front[4], front[5], front[6],
                front[7], front[8], front[9], front[10], front[11], front[12], front[13], front[14]
            )
            front = front.replacing(with: shifted, where: lanes .<= SIMD16<UInt8>(repeating: UInt8(truncatingIfNeeded: index)))
            return picked[0]
        }
        let byte = unsafe list.load(fromByteOffset: index, as: UInt8.self)
        let last = front[15]
        let second = unsafe (list + 16).loadUnaligned(as: SIMD16<UInt8>.self)
        if index < 32 {
            // Positions 16 through `index` of the second block take the byte before them.
            let shifted = SIMD16<UInt8>(
                last, second[0], second[1], second[2], second[3], second[4], second[5], second[6],
                second[7], second[8], second[9], second[10], second[11], second[12], second[13], second[14]
            )
            let moved = lanes .<= SIMD16<UInt8>(repeating: UInt8(truncatingIfNeeded: index &- 16))
            unsafe (list + 16).storeBytes(of: second.replacing(with: shifted, where: moved), as: SIMD16<UInt8>.self)
        } else {
            // From the top down, 16 bytes at a time (each move reads below what the previous one wrote), then
            // positions 16 through 31, from the second block loaded before any store.
            var offset = index &- 16
            while offset >= 16 {
                unsafe (list + (offset &+ 1)).storeBytes(of: (list + offset).loadUnaligned(as: SIMD16<UInt8>.self), as: SIMD16<UInt8>.self)
                offset &-= 16
            }
            let shifted = SIMD16<UInt8>(
                last, second[0], second[1], second[2], second[3], second[4], second[5], second[6],
                second[7], second[8], second[9], second[10], second[11], second[12], second[13], second[14]
            )
            unsafe (list + 16).storeBytes(of: shifted, as: SIMD16<UInt8>.self)
        }
        let splat = SIMD16<UInt8>(repeating: byte)
        front = SIMD16<UInt8>(
            splat[15], front[0], front[1], front[2], front[3], front[4], front[5], front[6],
            front[7], front[8], front[9], front[10], front[11], front[12], front[13], front[14]
        )
        return byte
    }

    // MARK: Inverse Burrows–Wheeler transform

    /// Links the block's positions both ways, from its runs: with the bytes sorted (each byte's occurrences in
    /// position order), position `i`'s byte sorts to `j`; `tt[j]` gets `i` and the byte (the sorted column's,
    /// `F[j]`), and `back[i]` gets `j` and the byte (the BWT's, `L[i]`). Each in bits 8–31 and 0–7.
    ///
    /// Following `tt` from the block's origin gives its bytes from the first on; following `back`, from the last
    /// back. For blocks smaller than `BZip2Segments.minimumBlock` (larger ones use only `tt`, with padded rows:
    /// ``linkPadded(_:count:)``).
    @inline(never)
    static func link(_ workspace: UnsafeMutableRawPointer, count runCount: Int) {
        // Unsafe: count, run, and link accesses. Safe: counts are indexed by bytes; each byte's starts are the
        // counts of the bytes before it, which `decodeSymbols` made the counts of the runs' bytes, so every target
        // range ends by the block's length (below 32,768), as do the positions; `tt` has 2²⁰ entries, and `back`
        // 32,768 and room for 4-entry stores past them.
        let runs = unsafe UnsafePointer((workspace + BZip2Workspace.runs).assumingMemoryBound(to: UInt32.self))
        let starts = unsafe (workspace + BZip2Workspace.frequencies).assumingMemoryBound(to: UInt32.self)
        let tt = unsafe (workspace + BZip2Workspace.tt).assumingMemoryBound(to: UInt32.self)
        let back = unsafe (workspace + BZip2Workspace.back).assumingMemoryBound(to: UInt32.self)
        // Each byte's start: the counts `decodeSymbols` made of the bytes before it.
        var total: UInt32 = 0
        for byte in 0..<256 {
            let frequency = unsafe starts[byte]
            unsafe starts[byte] = total
            total &+= frequency
        }
        // Runs' entries are ramps: positions and targets rise by one (256 in the fields) per entry. A run's first
        // four go without branches on its length (1 or more is unpredictable): `back` gets four (any past the run
        // are written again by the next runs, or are past the block), and `tt` those within the run, the others
        // going to an entry no block uses (2²⁰ − 1). (An empty run, only ever the block's first, writes one entry,
        // which a later run writes again.)
        let ramp = SIMD4<UInt32>(0, 256, 512, 768)
        let unused = (1 &<< 20) &- 1
        var position: UInt32 = 0
        for index in 0..<runCount {
            let run = unsafe runs[index]
            let byte = run & 0xFF
            let length = run &>> 8
            let target = unsafe starts[Int(byte)]
            unsafe starts[Int(byte)] = target &+ length
            let forward = position &<< 8 | byte
            let to = Int(target)
            unsafe UnsafeMutableRawPointer(back + Int(position)).storeBytes(
                of: SIMD4(repeating: target &<< 8 | byte) &+ ramp, as: SIMD4<UInt32>.self
            )
            unsafe tt[to] = forward
            unsafe tt[length > 1 ? to &+ 1 : unused] = forward &+ 256
            unsafe tt[length > 2 ? to &+ 2 : unused] = forward &+ 512
            unsafe tt[length > 3 ? to &+ 3 : unused] = forward &+ 768
            if length > 4 {
                var forwards = SIMD4<UInt32>(repeating: forward) &+ ramp &+ 1024
                var backwards = SIMD4<UInt32>(repeating: (target &+ 4) &<< 8 | byte) &+ ramp
                let from = unsafe back + Int(position)
                var offset = 4
                while offset &+ 4 <= Int(length) {
                    unsafe UnsafeMutableRawPointer(tt + (to &+ offset)).storeBytes(of: forwards, as: SIMD4<UInt32>.self)
                    unsafe UnsafeMutableRawPointer(from + offset).storeBytes(of: backwards, as: SIMD4<UInt32>.self)
                    forwards &+= 1024
                    backwards &+= 1024
                    offset &+= 4
                }
                while offset < Int(length) {
                    unsafe tt[to &+ offset] = forwards[0]
                    unsafe from[offset] = backwards[0]
                    forwards &+= 256
                    backwards &+= 256
                    offset &+= 1
                }
            }
            position &+= length
        }
    }

    /// `link` for blocks walked in segments: `tt` only, and each byte's rows followed by 4 unused entries, so
    /// that every run's entries are stored 4 at a time, without branches on its length: past a run, the stores
    /// reach only later entries of its byte (written again by later runs) or the 4 after them. Row `j` (sorted
    /// by byte `b`) is at `j + 4b`, as entries' links say too.
    @inline(never)
    static func linkPadded(_ workspace: UnsafeMutableRawPointer, count runCount: Int) {
        // Unsafe: count, start, run, and link accesses. Safe: counts and starts are indexed by bytes; each byte's
        // start is the counts of the bytes before it, which `decodeSymbols` made the counts of the runs' bytes, so
        // every run's padded entries end by the block's length plus 4 × 256 (and up to 3 more), within `tt`'s
        // 2²⁰; the rows' bytes advance only while rows remain, which the counts cover.
        let runs = unsafe UnsafePointer((workspace + BZip2Workspace.runs).assumingMemoryBound(to: UInt32.self))
        let counts = unsafe UnsafePointer((workspace + BZip2Workspace.frequencies).assumingMemoryBound(to: UInt32.self))
        let starts = unsafe (workspace + BZip2Workspace.starts).assumingMemoryBound(to: UInt32.self)
        let tt = unsafe (workspace + BZip2Workspace.tt).assumingMemoryBound(to: UInt32.self)
        var total: UInt32 = 0
        for byte in 0..<256 {
            unsafe starts[byte] = total
            total &+= unsafe counts[byte]
        }
        // The byte whose rows hold `position`, and their end: links to rows are padded by it.
        var rowByte: UInt32 = 0
        var rowEnd = unsafe counts[0]
        var position: UInt32 = 0
        while position >= rowEnd && rowByte < 255 {
            rowByte &+= 1
            rowEnd &+= unsafe counts[Int(rowByte)]
        }
        let ramp = SIMD4<UInt32>(0, 256, 512, 768)
        for index in 0..<runCount {
            let run = unsafe runs[index]
            let byte = run & 0xFF
            let length = run &>> 8
            let target = unsafe starts[Int(byte)]
            unsafe starts[Int(byte)] = target &+ length
            let to = unsafe tt + Int(target &+ byte &<< 2)
            if likely(position &+ length <= rowEnd) {
                // Every row this run links to has one byte: a ramp.
                var links = SIMD4<UInt32>(repeating: (position &+ rowByte &<< 2) &<< 8 | byte) &+ ramp
                var offset = 0
                repeat {
                    unsafe UnsafeMutableRawPointer(to + offset).storeBytes(of: links, as: SIMD4<UInt32>.self)
                    links &+= 1024
                    offset &+= 4
                } while offset < Int(length)
            } else {
                for offset in 0..<Int(length) {
                    let row = position &+ UInt32(truncatingIfNeeded: offset)
                    while row >= rowEnd && rowByte < 255 {
                        rowByte &+= 1
                        rowEnd &+= unsafe counts[Int(rowByte)]
                    }
                    unsafe to[offset] = (row &+ rowByte &<< 2) &<< 8 | byte
                }
            }
            position &+= length
            while position >= rowEnd && rowByte < 255 {
                rowByte &+= 1
                rowEnd &+= unsafe counts[Int(rowByte)]
            }
        }
    }

    /// Row `row`'s place in ``linkPadded(_:count:)``'s `tt`: after 4 unused entries for each byte before its own.
    static func paddedRow(_ row: Int, counts: UnsafePointer<UInt32>) -> Int {
        // Unsafe: count loads. Safe: indexed by bytes.
        var end = 0
        for byte in 0..<256 {
            end &+= Int(unsafe counts[byte])
            if row < end { return row &+ byte &<< 2 }
        }
        return row // Past the block: not a row.
    }

    /// Follows the links from the block's origin, forward from its first byte and back from its last at once,
    /// meeting in the middle: two independent chains of dependent loads, which the CPU overlaps.
    @inline(never)
    static func walk(_ workspace: UnsafeMutableRawPointer, count: Int, origin: Int) {
        // Unsafe: link loads, and stores of the block's bytes. Safe: `tt`'s links are below 2²⁰ (24-bit fields
        // holding positions below 900,000), its size; `back`'s are positions in this block, which `link` wrote
        // for each position (below `count`, under 32,768, `back`'s size); the stores are below `count`.
        let tt = unsafe UnsafePointer((workspace + BZip2Workspace.tt).assumingMemoryBound(to: UInt32.self))
        let back = unsafe UnsafePointer((workspace + BZip2Workspace.back).assumingMemoryBound(to: UInt32.self))
        let block = unsafe (workspace + BZip2Workspace.runs).assumingMemoryBound(to: UInt8.self)
        var forward = origin
        var backward = origin
        var first = 0
        var last = count &- 1
        while first < last {
            let next = unsafe tt[forward]
            let previous = unsafe back[backward]
            unsafe block[first] = UInt8(truncatingIfNeeded: next)
            unsafe block[last] = UInt8(truncatingIfNeeded: previous)
            forward = Int(truncatingIfNeeded: next &>> 8)
            backward = Int(truncatingIfNeeded: previous &>> 8)
            first &+= 1
            last &-= 1
        }
        if first == last { unsafe block[first] = UInt8(truncatingIfNeeded: tt[forward]) }
    }

    /// Flips the low bit of the bytes bzip2's randomization table picks.
    static func derandomize(_ block: UnsafeMutablePointer<UInt8>, count: Int) {
        // Unsafe: byte updates. Safe: below `count`, checked.
        var start = 0
        var index = 0
        while true {
            // Each entry, 50 through 999, is the distance to the next flip but one, counted from the byte after the
            // previous entry's span.
            let gap = Int(BZip2Randomization.table[index])
            index = (index &+ 1) & 511
            let flip = start &+ gap &- 2
            if flip >= count { return }
            unsafe block[flip] ^= 1
            start &+= gap
        }
    }

    /// Undoes the run-length coding (4 equal bytes, then a count of more) of the block's `count` bytes into the
    /// output from `start`: 16 bytes at a time where no 4 equal bytes end among them.
    ///
    /// - Returns: Where the output ended.
    @inline(never)
    static func expandRuns(
        _ block: UnsafePointer<UInt8>, count: Int, output: UnsafeMutablePointer<UInt8>, at start: Int,
        capacity: Int, overrun: BytesError
    ) throws(BytesError) -> Int {
        // Unsafe: as `expand` says.
        try unsafe expand(
            block, count: count, from: BZip2Expansion(), output: output, at: start, capacity: capacity, stopsWhenFull: false,
            overrun: overrun
        ).end
    }

    /// ``expandRuns(_:count:output:at:capacity:overrun:)`` resumable: from `state`, stopping where the output
    /// fills (mid-run if need be) instead of throwing.
    ///
    /// - Returns: Where it stopped (the block is done when `state.isDone(count:)`), and where the output ended.
    @inline(never)
    static func expandRunsResumably(
        _ block: UnsafePointer<UInt8>, count: Int, from state: BZip2Expansion, output: UnsafeMutablePointer<UInt8>,
        at start: Int, capacity: Int
    ) throws(BytesError) -> (state: BZip2Expansion, end: Int) {
        // Unsafe: as `expand` says.
        try unsafe expand(
            block, count: count, from: state, output: output, at: start, capacity: capacity, stopsWhenFull: true,
            overrun: .insufficientCapacity
        )
    }

    /// The run-length decoding, from `state`: with `stopsWhenFull`, it returns where the output fills; otherwise
    /// a full output throws `overrun`.
    @inline(__always)
    static func expand(
        _ block: UnsafePointer<UInt8>, count: Int, from state: BZip2Expansion, output: UnsafeMutablePointer<UInt8>,
        at start: Int, capacity: Int, stopsWhenFull: Bool, overrun: BytesError
    ) throws(BytesError) -> (state: BZip2Expansion, end: Int) {
        // Unsafe: block loads and output stores. Safe: 16-byte loads start at 3 or more and end by `count`;
        // 16-byte stores run only with 16 bytes of room; every other store is checked against `capacity`, and
        // `state.index` is at most `count` (it's only ever this function's own).
        @inline(always) func load(_ offset: Int) -> SIMD16<UInt8> {
            unsafe UnsafeRawPointer(block + offset).loadUnaligned(as: SIMD16<UInt8>.self)
        }
        var index = state.index
        var end = start
        var last = state.last // The previous byte; -1 after a run's count.
        var same = state.same // Equal bytes ending at `last`, 1 through 4.
        if stopsWhenFull && state.pending > 0 {
            // The rest of a run whose count didn't fit last time.
            let room = capacity &- end
            let written = min(state.pending, room)
            unsafe repeatByte(output + end, UInt8(truncatingIfNeeded: last), count: written, room: room)
            end &+= written
            if written < state.pending {
                return (BZip2Expansion(index: index, last: last, same: same, pending: state.pending &- written), end)
            }
            same = 0
            last = -1
        }
        while index < count {
            if same < 4 && index >= 3 && count &- index >= 16 && capacity &- end >= 16 {
                // No 4 equal bytes end in these 16 (the 3 before them included): no count among them, and none
                // after them, so they're copied as they are.
                let bytes = load(index)
                let differences = (load(index &- 3) ^ load(index &- 2)) | (load(index &- 2) ^ load(index &- 1))
                    | (load(index &- 1) ^ bytes)
                let ends = ByteLanes(differences).matching(0)
                if !ends.any {
                    unsafe UnsafeMutableRawPointer(output + end).storeBytes(of: bytes, as: SIMD16<UInt8>.self)
                    end &+= 16
                    index &+= 16
                    let byte = unsafe block[index &- 1]
                    last = Int(byte)
                    same = unsafe byte != block[index &- 2] ? 1 : byte != block[index &- 3] ? 2 : 3
                    continue
                }
                // The lanes before the first where 4 equal bytes end are copied as they are. (One byte at a time,
                // the 16 were checked again at every byte.) When there are 3 or more, they set `same`, and the
                // byte there is the run's fourth, below.
                let clear = ends.nibbleMask.trailingZeroBitCount &>> 2
                if clear >= 3 {
                    unsafe UnsafeMutableRawPointer(output + end).storeBytes(of: bytes, as: SIMD16<UInt8>.self)
                    end &+= clear
                    index &+= clear
                    let byte = unsafe block[index &- 1]
                    last = Int(byte)
                    same = unsafe byte != block[index &- 2] ? 1 : byte != block[index &- 3] ? 2 : 3
                }
            }
            let byte = Int(unsafe block[index])
            if same == 4 {
                // `byte` is the run's count: more of `last`.
                index &+= 1
                let room = capacity &- end
                guard byte <= room else {
                    guard stopsWhenFull else { throw overrun }
                    // As much as fits; the rest next time.
                    unsafe repeatByte(output + end, UInt8(truncatingIfNeeded: last), count: room, room: room)
                    return (BZip2Expansion(index: index, last: last, same: same, pending: byte &- room), capacity)
                }
                unsafe repeatByte(output + end, UInt8(truncatingIfNeeded: last), count: byte, room: room)
                end &+= byte
                same = 0
                last = -1
                continue
            }
            guard end < capacity else {
                guard stopsWhenFull else { throw overrun }
                return (BZip2Expansion(index: index, last: last, same: same, pending: 0), end)
            }
            index &+= 1
            unsafe output[end] = UInt8(truncatingIfNeeded: byte)
            end &+= 1
            same = byte == last ? same &+ 1 : 1
            last = byte
        }
        // Four equal bytes always have a count after them.
        guard same != 4 else { throw .invalidValue }
        return (BZip2Expansion(index: index, last: last, same: same, pending: 0), end)
    }

    /// Writes `count` copies of `byte` with 16-byte stores when `room` leaves space for their overrun, exactly
    /// otherwise.
    @inline(__always)
    static func repeatByte(_ output: UnsafeMutablePointer<UInt8>, _ byte: UInt8, count: Int, room: Int) {
        // Unsafe: stores. Safe: `count` is at most `room`, and the 16-byte stores run only while 16 bytes past
        // the run fit in it.
        if room &- count >= 16 {
            let vector = SIMD16<UInt8>(repeating: byte)
            var index = 0
            repeat {
                unsafe UnsafeMutableRawPointer(output + index).storeBytes(of: vector, as: SIMD16<UInt8>.self)
                index &+= 16
            } while index < count
        } else {
            unsafe output.update(repeating: byte, count: count)
        }
    }
}

/// `decodeSymbols`' state: the bit reader, and the runs so far. A struct whose methods are always inlined, so its
/// fields stay in registers.
@safe
struct BZip2SymbolState {
    var bits: BZip2Bits
    let runs: UnsafeMutablePointer<UInt32>
    let counts: UnsafeMutablePointer<UInt32>
    let list: UnsafeMutableRawPointer
    let endOfBlock: Int
    let alphabetSize: Int
    /// Bytes so far, including the current run's.
    var length = 0
    var runCount = 0
    /// The current run: its byte (the list's front) and length.
    var runByte: UInt32
    var runLength = 0
    /// RUNA and RUNB since the run's byte: the next one's place in its count.
    var shift = 0
    /// The list's first 16 bytes, kept in a register (the memory's are stale until the block ends).
    var front: SIMD16<UInt8>

    @unsafe @inline(__always)
    init(bits: BZip2Bits, header: BZip2BlockHeader, workspace: UnsafeMutableRawPointer) {
        self.bits = bits
        unsafe runs = (workspace + BZip2Workspace.runs).assumingMemoryBound(to: UInt32.self)
        unsafe counts = (workspace + BZip2Workspace.frequencies).assumingMemoryBound(to: UInt32.self)
        unsafe counts.initialize(repeating: 0, count: 256)
        unsafe list = workspace + BZip2Workspace.list
        endOfBlock = header.alphabetSize &- 1
        alphabetSize = header.alphabetSize
        runByte = UInt32(unsafe list.load(as: UInt8.self))
        front = unsafe list.loadUnaligned(as: SIMD16<UInt8>.self)
    }

    /// Decodes one symbol from at least 20 buffered bits with `table`'s codes, and adds it to the runs.
    ///
    /// - Returns: Whether it was the end of the block.
    @unsafe @inline(__always)
    mutating func decode(_ table: UnsafeRawPointer) throws(BytesError) -> Bool {
        // Unsafe: the table lookup, the run's store, and the list's move. Safe: primary indices are 10-bit values,
        // below the tables' 1024 entries; symbols are below the alphabet size (the tables hold no others), so
        // list indices (symbol − 1) are below 256, the list's size; there's at most one run per symbol, and at
        // most 50 symbols per selector, whose count is at most 18,002: the runs' region holds 900,100; counts are
        // indexed by bytes.
        let primary = unsafe table.assumingMemoryBound(to: UInt16.self)
        var entry = Int(unsafe primary[Int(truncatingIfNeeded: bits.bits &>> UInt64(64 &- BZip2Stream.tableBits))])
        if unlikely(entry < 1 &<< 9) {
            // A long code, an invalid one, or the end of the block (which the primary table leaves out, so that
            // this one test covers it).
            entry = unsafe BZip2Tables.decodeSlowly(bits.bits, table: table, alphabetSize: alphabetSize)
            guard entry >= 0 else { throw bits.failure }
            if entry & 0x1FF == endOfBlock {
                bits.consume(entry &>> 9)
                unsafe runs[runCount] = UInt32(truncatingIfNeeded: runLength) &<< 8 | runByte
                runCount &+= 1
                unsafe counts[Int(runByte)] &+= UInt32(truncatingIfNeeded: runLength)
                return true
            }
        }
        let symbol = entry & 0x1FF
        bits.consume(entry &>> 9)
        // Without branches on the symbol (RUNA and RUNB against indices are unpredictable): RUNA (0) and RUNB (1)
        // add 1 or 2 times 2^shift more of the run's byte (bijective base 2) and move index 0 (no change); an
        // index (2 and up, less 1) ends the run, stored where it's always stored, and starts one of the byte it
        // moves to the front.
        guard likely(shift < 21) else { throw bits.failure }
        let isRun = symbol < 2
        let added = isRun ? (symbol &+ 1) &<< shift : 1
        unsafe runs[runCount] = UInt32(truncatingIfNeeded: runLength) &<< 8 | runByte
        runCount &+= isRun ? 0 : 1
        unsafe counts[Int(runByte)] &+= isRun ? 0 : UInt32(truncatingIfNeeded: runLength)
        runLength = isRun ? runLength &+ added : 1
        shift = isRun ? shift &+ 1 : 0
        length &+= added
        runByte = UInt32(unsafe BZip2Stream.moveToFront(&front, list, index: isRun ? 0 : symbol &- 1))
        return false
    }
}

/// Where undoing a block's run-length coding stopped: the next byte of the block, the bytes before it, and the
/// copies of a run still to write when the output filled in the middle of one.
struct BZip2Expansion {
    /// The next byte of the block to read.
    var index = 0
    /// The previous byte; -1 after a run's count.
    var last = -1
    /// Equal bytes ending at `last`, 1 through 4.
    var same = 0
    /// Copies of `last` still to write: a run's count that didn't fit.
    var pending = 0

    /// Whether all of a block of `count` bytes has been written.
    func isDone(count: Int) -> Bool { index == count && pending == 0 }
}

/// What `decodeSymbols` needs from a block's tables.
struct BZip2BlockHeader {
    /// Symbols: RUNA, RUNB, a move-to-front index per byte used but the first, and the end of block.
    var alphabetSize: Int
    /// Selectors stored: one per 50 symbols.
    var selectorCount: Int
}

/// How far a block's tables have been read (`readTableBody`): its counts, then the selectors and tables done so far.
/// The selectors, code lengths, and built tables themselves are in the workspace.
struct BZip2TableProgress {
    /// Symbols: RUNA, RUNB, a move-to-front index per byte used but the first, and the end of block.
    var alphabetSize = 0
    /// Huffman tables, 2 through 6.
    var groupCount = 0
    /// Selectors in the stream, up to 32,767 (those past ``BZip2Stream/maximumSelectors`` are read and dropped).
    var storedSelectorCount = 0
    /// The next selector to read, and the tables' move-to-front order after the ones before it.
    var selector = 0
    var order: UInt64 = 0x05_04_03_02_01_00
    /// The next table whose code lengths are read.
    var group = 0

    /// What decoding the block's symbols needs.
    var header: BZip2BlockHeader {
        BZip2BlockHeader(alphabetSize: alphabetSize, selectorCount: min(storedSelectorCount, BZip2Stream.maximumSelectors))
    }
}

// MARK: - Walking in segments

/// The inverse BWT's walk for large blocks, as many independent chains: the block's cycle of links cut at
/// evenly spaced positions into segments, `lanes` of them followed at once (one step of each in turn), each into
/// pages of its lane, then copied out in the cycle's order.
///
/// A walk is one chain of dependent loads from a 3.6 MB table: about 30 cycles a step, the CPU idle meanwhile.
/// Independent chains overlap (a probe of random chains through 900,000 entries on an M3: 7.6 ns a step for one
/// chain, 2.0 for 8, 1.1 for 16, 0.8 for 24 and for 32). Each segment starts at a marked entry (its own entry
/// saved, a mark and the segment's number put in its place) and ends at the next mark it meets, which names the
/// segment after it. Segments are about 1,024 bytes, so lanes stay busy to the end: a lane that finishes takes the
/// next segment.
enum BZip2Segments {
    /// Blocks smaller than this take the two-chain walk.
    static var minimumBlock: Int { 32 &<< 10 }
    /// Chains followed at once (24 against 16: dickens −5%, xml −8% time; 32 no better).
    static var lanes: Int { 24 }
    static var pageSize: Int { 1024 }
    static var maximumSegments: Int { 1024 }
    static var mark: UInt32 { 0x8000_0000 }

    // Regions of the workspace's runs region (free once the links are made), after the block's bytes.
    static var arena: Int { BZip2Workspace.runs &+ (1 &<< 20) } // the block's bytes and 2 pages per lane
    static var pageLinks: Int { BZip2Workspace.runs &+ (2 &<< 20) } // the page after each, in its lane
    static var segments: Int { BZip2Workspace.runs &+ (3 &<< 20) } // 4 4-byte fields per segment
    static var laneState: Int { segments &+ maximumSegments &* 16 } // 4 8-byte fields per lane

    /// Walks the block's `count` bytes (at least `minimumBlock`) from `origin` into the block region.
    ///
    /// - Throws: ``BytesError/invalidValue`` if the origin's cycle of links is longer than the block (corrupt
    ///   data).
    @inline(never)
    static func walk(_ workspace: UnsafeMutableRawPointer, count: Int, origin: Int) throws(BytesError) {
        // Unsafe: link, page, and record accesses. Safe: rows are below 2²⁰, `tt`'s size (an unmarked entry's
        // high bits are a padded row, below 900,000 + 4 × 256); segment numbers are below `segmentCount`, which is at most
        // `maximumSegments`; pages: each lane writes its bytes in order, taking a new page when one fills, so the
        // bytes walked (at most `count`, each row in one segment) take at most `count / pageSize + 2 * lanes`
        // pages, which the arena holds; copies out stop at `count` bytes.
        let tt = unsafe (workspace + BZip2Workspace.tt).assumingMemoryBound(to: UInt32.self)
        let arena = unsafe (workspace + arena).assumingMemoryBound(to: UInt8.self)
        let pageLinks = unsafe (workspace + pageLinks).assumingMemoryBound(to: UInt32.self)
        let records = unsafe (workspace + segments).assumingMemoryBound(to: UInt32.self)
        let saved = unsafe records // per segment: its start's entry,
        let offsets = unsafe records + maximumSegments // its first byte's place in the arena,
        let lengths = unsafe records + 2 &* maximumSegments // its length,
        let following = unsafe records + 3 &* maximumSegments // and the segment after it.
        let state = unsafe (workspace + laneState).assumingMemoryBound(to: Int.self)
        let rows = unsafe state // per lane: the next row,
        let writes = unsafe state + lanes // the next byte's place in the arena,
        let current = unsafe state + 2 &* lanes // the segment it's walking,
        let walked = unsafe state + 3 &* lanes // and the bytes it walked before this page.

        // Segment 0 starts at the origin, the others at evenly spaced rows (moved off the origin). Rows are
        // padded, as `linkPadded` leaves them.
        let counts = unsafe UnsafePointer((workspace + BZip2Workspace.frequencies).assumingMemoryBound(to: UInt32.self))
        let segmentCount = min(maximumSegments, count &>> 10)
        for segment in 0..<segmentCount {
            var row = segment == 0 ? origin : segment &* count / segmentCount
            if segment > 0 && row == origin { row &+= 1 }
            row = unsafe BZip2Stream.paddedRow(row, counts: counts)
            unsafe saved[segment] = tt[row]
            unsafe tt[row] = mark | UInt32(truncatingIfNeeded: segment)
        }

        var pages = 0
        var nextSegment = 0
        var active = 0
        // Starts `segment` on `lane`: its first byte is its start's saved entry's.
        @inline(__always) func begin(_ lane: Int, _ segment: Int) {
            let entry = unsafe saved[segment]
            let write = unsafe writes[lane]
            unsafe offsets[segment] = UInt32(truncatingIfNeeded: write)
            unsafe current[lane] = segment
            unsafe lengths[segment] = UInt32(truncatingIfNeeded: walked[lane] &+ write & (pageSize &- 1))
            unsafe arena[write] = UInt8(truncatingIfNeeded: entry)
            unsafe writes[lane] = write &+ 1
            unsafe rows[lane] = Int(truncatingIfNeeded: entry &>> 8)
            if (write &+ 1) & (pageSize &- 1) == 0 { newPage(lane) }
        }
        // Gives `lane` a new page after its full one.
        @inline(__always) func newPage(_ lane: Int) {
            let full = (unsafe writes[lane] &- 1) / pageSize
            unsafe pageLinks[full] = UInt32(truncatingIfNeeded: pages)
            unsafe writes[lane] = pages &* pageSize
            unsafe walked[lane] &+= pageSize
            pages &+= 1
        }
        while active < lanes && nextSegment < segmentCount {
            unsafe writes[active] = pages &* pageSize
            unsafe walked[active] = 0
            pages &+= 1
            begin(active, nextSegment)
            nextSegment &+= 1
            active &+= 1
        }

        while active > 0 {
            var lane = 0
            while lane < active {
                let entry = unsafe tt[rows[lane]]
                if likely(entry < mark) {
                    let write = unsafe writes[lane]
                    unsafe arena[write] = UInt8(truncatingIfNeeded: entry)
                    unsafe rows[lane] = Int(truncatingIfNeeded: entry &>> 8)
                    unsafe writes[lane] = write &+ 1
                    if unlikely((write &+ 1) & (pageSize &- 1) == 0) { newPage(lane) }
                    lane &+= 1
                    continue
                }
                // The segment ends at the next one's start.
                let segment = unsafe current[lane]
                let write = unsafe writes[lane]
                unsafe lengths[segment] = UInt32(truncatingIfNeeded: walked[lane] &+ write & (pageSize &- 1)) &- lengths[segment]
                unsafe following[segment] = entry & 0xFFFF
                if nextSegment < segmentCount {
                    begin(lane, nextSegment)
                    nextSegment &+= 1
                    lane &+= 1
                } else {
                    // Retired: the last active lane takes its place.
                    active &-= 1
                    unsafe rows[lane] = rows[active]
                    unsafe writes[lane] = writes[active]
                    unsafe current[lane] = current[active]
                    unsafe walked[lane] = walked[active]
                }
            }
        }

        // Copy the segments out in the cycle's order, from the origin's, around to it again.
        let block = unsafe (workspace + BZip2Workspace.runs).assumingMemoryBound(to: UInt8.self)
        var segment = 0
        var end = 0
        repeat {
            var remaining = Int(unsafe lengths[segment])
            guard remaining <= count &- end else { throw .invalidValue }
            var offset = Int(unsafe offsets[segment])
            while remaining > 0 {
                let piece = min(remaining, pageSize &- offset & (pageSize &- 1))
                unsafe (block + end).update(from: arena + offset, count: piece)
                end &+= piece
                remaining &-= piece
                // The next page, only while the segment goes on: the page it ends in may not be full, and then has
                // no link (the workspace isn't zeroed: RESULTS.md, 2026-11-24).
                if remaining > 0 { offset = unsafe Int(pageLinks[offset / pageSize]) &* pageSize }
            }
            segment = Int(unsafe following[segment])
        } while segment != 0
        // A block that's a power of a shorter string (as `abcabc`) has a cycle of links per copy, the origin's
        // the first copy: the walk repeats it, as libbzip2's does.
        guard end > 0 else {
            throw .invalidValue
        }
        while end < count {
            let piece = min(end, count &- end)
            unsafe (block + end).update(from: block, count: piece)
            end &+= piece
        }
    }
}

// MARK: - Bits

/// bzip2's bitstream, most significant bit first, in a 64-bit register refilled 8 bytes at a time (as Bytes'
/// `BitBuffer`, over raw memory). Past the end of the input it adds zeros; ``isOverrun`` reports reading them.
@safe
struct BZip2Bits {
    let input: UnsafeRawPointer
    let end: Int
    /// The next bit in bit 63. Bits past `count` hold the input's next bits or zeros, which a refill ORs in
    /// again at the same positions.
    var bits: UInt64 = 0
    var count = 0
    /// The next input byte to load; past `end` once zeros have been added.
    var next: Int

    @unsafe
    init(_ input: UnsafeRawPointer, end: Int, at position: Int) {
        unsafe self.input = input
        self.end = end
        next = position
    }

    /// Fills the register to at least 56 bits.
    @inline(__always)
    mutating func refill() {
        if likely(end &- next >= 8) {
            // Unsafe: an 8-byte load. Safe: the branch checked that 8 bytes remain.
            let word = UInt64(bigEndian: unsafe input.loadUnaligned(fromByteOffset: next, as: UInt64.self))
            bits |= word &>> UInt64(truncatingIfNeeded: count)
            next &+= (63 &- count) &>> 3
            count |= 56
        } else {
            (bits, count, next) = unsafe Self.refillSlowly(bits, count, next, input: input, end: end)
        }
    }

    /// The 8 bytes at the next byte to load, for ``refill(with:)``.
    ///
    /// - Precondition: 8 bytes remain.
    @unsafe @inline(__always)
    func nextWord() -> UInt64 {
        UInt64(bigEndian: unsafe input.loadUnaligned(fromByteOffset: next, as: UInt64.self))
    }

    /// Fills the register to at least 56 bits from `word`, the 8 bytes at the next byte to load (loaded before
    /// the register's last bits were consumed: the next byte to load doesn't change until a refill).
    @inline(__always)
    mutating func refill(with word: UInt64) {
        bits |= word &>> UInt64(truncatingIfNeeded: count)
        next &+= (63 &- count) &>> 3
        count |= 56
    }

    /// Within 8 bytes of the end: adds bytes one at a time, zeros past the end.
    @inline(never)
    static func refillSlowly(
        _ bits: UInt64, _ count: Int, _ next: Int, input: UnsafeRawPointer, end: Int
    ) -> (UInt64, Int, Int) {
        var bits = bits
        var count = count
        var next = next
        while count <= 56 {
            // Unsafe: a byte load. Safe: below `end`.
            let byte = next < end ? UInt64(unsafe input.load(fromByteOffset: next, as: UInt8.self)) : 0
            bits |= byte &<< UInt64(truncatingIfNeeded: 56 &- count)
            next &+= 1
            count &+= 8
        }
        return (bits, count, next)
    }

    @inline(__always)
    mutating func consume(_ bitCount: Int) {
        bits &<<= UInt64(truncatingIfNeeded: bitCount)
        count &-= bitCount
    }

    /// Reads the next `bitCount` bits, 1 through 56, refilling first if needed.
    @inline(__always)
    mutating func read(_ bitCount: Int) -> UInt64 {
        if count < bitCount { refill() }
        let value = bits &>> UInt64(truncatingIfNeeded: 64 &- bitCount)
        consume(bitCount)
        return value
    }

    /// The position of the next bit, from the start of the input.
    var bitPosition: Int { next &<< 3 &- count }

    /// Whether bits past the end of the input were read.
    var isOverrun: Bool { bitPosition > end &<< 3 }

    /// The input's bits not yet read (negative once zeros past its end have been).
    var remainingBits: Int { end &<< 3 &- bitPosition }

    /// The error for a value that isn't valid: ``BytesError/insufficientData`` if it came from past the end.
    var failure: BytesError { isOverrun ? .insufficientData : .invalidValue }
}

// MARK: - Huffman tables

/// A Huffman table's decoding tables, in `stride` bytes of the workspace: a primary table indexed by the next
/// 10 bits (each entry the code's length in bits 9–13 and its symbol in 0–8, or 0 for a longer or invalid
/// code), then for longer codes, per length, the left-aligned 32-bit limit of the codes that long or shorter
/// and the offset from a code to its symbol's place in the symbols sorted by length.
enum BZip2Tables {
    static var primarySize: Int { 2 &<< BZip2Stream.tableBits }
    static var limits: Int { primarySize } // 24 8-byte limits, by length
    static var offsets: Int { primarySize &+ 192 } // 24 4-byte offsets, by length
    static var symbols: Int { primarySize &+ 288 } // 258 2-byte symbols, by length
    static var stride: Int { primarySize &+ 1024 }

    /// Builds the tables for `count` symbols' code lengths (1 through 20), assigned canonically as bzip2
    /// does: by length, then by symbol.
    static func build(lengths: UnsafePointer<UInt8>, count: Int, into table: UnsafeMutableRawPointer) {
        // Unsafe: the tables' stores. Safe: lengths are 1 through 20, counts' and offsets' indices; symbols
        // are stored at their places by length, below `count` (at most 258); primary entries are stored only
        // for codes that fit their length, so below 1024.
        let tableBits = BZip2Stream.tableBits
        var counts = InlineArray<24, Int>(repeating: 0)
        for symbol in 0..<count {
            counts[Int(unsafe lengths[symbol])] &+= 1
        }
        var starts = InlineArray<24, Int>(repeating: 0)
        var total = 0
        for length in 1...20 {
            starts[length] = total
            total &+= counts[length]
        }
        let sorted = unsafe (table + symbols).assumingMemoryBound(to: UInt16.self)
        var next = starts
        for symbol in 0..<count {
            let length = Int(unsafe lengths[symbol])
            unsafe sorted[next[length]] = UInt16(truncatingIfNeeded: symbol)
            next[length] &+= 1
        }
        let primary = unsafe table.assumingMemoryBound(to: UInt16.self)
        unsafe primary.initialize(repeating: 0, count: 1 &<< tableBits)
        let limit = unsafe (table + limits).assumingMemoryBound(to: UInt64.self)
        let offset = unsafe (table + offsets).assumingMemoryBound(to: Int32.self)
        var code = 0
        for length in 1...20 {
            let first = code
            unsafe limit[length] = UInt64(truncatingIfNeeded: first &+ counts[length]) &<< UInt64(32 &- length)
            unsafe offset[length] = Int32(truncatingIfNeeded: starts[length] &- first)
            if length <= tableBits {
                let span = 1 &<< (tableBits &- length)
                for index in 0..<counts[length] {
                    let code = first &+ index
                    if code >= 1 &<< length { break } // Oversubscribed: the rest can't be decoded.
                    let symbol = unsafe sorted[starts[length] &+ index]
                    // The end of the block (the last symbol) takes the slow path: one test fewer per symbol.
                    if symbol == count &- 1 { continue }
                    let entry = UInt16(truncatingIfNeeded: length &<< 9) | symbol
                    unsafe (primary + code &* span).initialize(repeating: entry, count: span)
                }
            }
            code = (first &+ counts[length]) &<< 1
        }
    }

    /// Decodes a code from the next bits (at least 20 buffered) by its canonical limits: the codes the primary
    /// table leaves out (longer ones, and the end of the block's).
    ///
    /// - Returns: The code's length in bits 9–13 and its symbol in 0–8, or -1 for no valid code.
    @inline(__always)
    static func decodeSlowly(_ bits: UInt64, table: UnsafeRawPointer, alphabetSize: Int) -> Int {
        // Unsafe: limit, offset, and symbol loads. Safe: lengths are 1 through 20, within 24; the symbol's place
        // is checked to be below `alphabetSize`.
        let next = bits &>> 32
        let limit = unsafe (table + limits).assumingMemoryBound(to: UInt64.self)
        let offset = unsafe (table + offsets).assumingMemoryBound(to: Int32.self)
        let sorted = unsafe (table + symbols).assumingMemoryBound(to: UInt16.self)
        for length in 1...BZip2Stream.maximumCodeLength where unsafe next < limit[length] {
            let place = Int(unsafe offset[length]) &+ Int(truncatingIfNeeded: next &>> UInt64(32 &- length))
            guard place >= 0 && place < alphabetSize else { return -1 }
            return length &<< 9 | Int(unsafe sorted[place])
        }
        return -1
    }
}

// MARK: - CRC

/// bzip2's CRC: CRC-32's polynomial (0x04C11DB7) most significant bit first, initial and final value all ones
/// (CRC-32/BZIP2). Apple silicon folds 64 bytes per step with `pmull`; the rest takes eight 256-entry tables
/// ("slicing by 8"), 8 bytes per step.
package enum BZip2CRC {
    // `tables`: BZip2CRCTables.swift (`package` for the tests that check it).

    /// The CRC of `count` bytes at `data`.
    static func checksum(_ data: UnsafePointer<UInt8>, count: Int) -> UInt32 {
        unsafe ~extend(0xFFFF_FFFF, data, count: count)
    }

    /// Continues the unconditioned register `crc` (all ones to start, inverted at the end) with `count` bytes at
    /// `data`: folded 64 bytes at a time where there are 64 or more, then with the tables.
    static func extend(_ crc: UInt32, _ data: UnsafePointer<UInt8>, count: Int) -> UInt32 {
        tables.withUnsafeBufferPointer { tables in
            // The tables' base address, valid in this closure (2,048 entries, a static literal).
            let tables = tables.baseAddress!
            var crc = crc
            var index = 0
            #if HardwareCRC && arch(arm64) && !Portable
            if count >= 64 {
                let folded = unsafe fold(crc, UnsafeRawPointer(data), count)
                index = folded.count
                // The folded block, in memory order, continued with the rest.
                var block = CRCFold.reverse(folded.state)
                crc = withUnsafeBytes(of: &block) { unsafe update(0, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), 16, tables) }
            }
            #endif
            return unsafe update(crc, data + index, count &- index, tables)
        }
    }

    /// Updates the unconditioned register `crc` with `count` bytes at `data`, eight at a time with the tables.
    static func update(_ crc: UInt32, _ data: UnsafePointer<UInt8>, _ count: Int, _ tables: UnsafePointer<UInt32>) -> UInt32 {
        // Unsafe: table lookups and input loads. Safe: every index is a byte plus a multiple of 256 below 2048,
        // the tables' size; loads stay below `count`, which the caller's buffer holds.
        var crc = crc
        var index = 0
        while count &- index >= 8 {
            let word = UInt64(bigEndian: unsafe UnsafeRawPointer(data + index).loadUnaligned(as: UInt64.self))
                ^ UInt64(crc) &<< 32
            crc = unsafe tables[7 &* 256 &+ Int(word &>> 56)] ^ tables[6 &* 256 &+ Int(word &>> 48 & 0xFF)]
                ^ tables[5 &* 256 &+ Int(word &>> 40 & 0xFF)] ^ tables[4 &* 256 &+ Int(word &>> 32 & 0xFF)]
                ^ tables[3 &* 256 &+ Int(word &>> 24 & 0xFF)] ^ tables[2 &* 256 &+ Int(word &>> 16 & 0xFF)]
                ^ tables[256 &+ Int(word &>> 8 & 0xFF)] ^ tables[Int(word & 0xFF)]
            index &+= 8
        }
        while index < count {
            crc = unsafe crc &<< 8 ^ tables[Int(crc &>> 24 ^ UInt32(data[index]))]
            index &+= 1
        }
        return crc
    }
}

#if HardwareCRC && arch(arm64) && !Portable
extension BZip2CRC {
    // Folding constants: a block's high (first) 8 bytes moved d bits forward are them times x^(d + 64) mod P, its
    // low 8 times x^d mod P; most significant bit first, products need no reflection. Lane 0 multiplies the low
    // half, lane 1 the high.
    static var fold512: SIMD16<UInt8> {
        bitCast(SIMD2<UInt64>(0xE622_8B11, 0x8833_794C), to: SIMD16<UInt8>.self)
    }

    static var fold128: SIMD16<UInt8> {
        bitCast(SIMD2<UInt64>(0xE8A4_5605, 0xC5B9_CD4C), to: SIMD16<UInt8>.self)
    }

    /// Folds the whole 16-byte blocks of `count` bytes (at least 64) at `input` into one, four accumulators
    /// moving 64 bytes per step, with `crc` (the unconditioned register) XORed into the first 4 bytes.
    ///
    /// - Returns: The folded block, byte-reversed (a polynomial), whose CRC from zero continued with the bytes
    ///   after `count` (rounded down to 16) is the CRC of all of them; and that rounded count.
    // Not inlined, as before the body was shared with CRC-64's.
    @inline(never)
    static func fold(_ crc: UInt32, _ input: UnsafeRawPointer, _ count: Int) -> (state: SIMD16<UInt8>, count: Int) {
        // Unsafe and safe as `CRCFold.fold`: `count` bytes at `input`, at least 64 (the caller checks).
        unsafe CRCFold.fold(
            bitCast(SIMD2<UInt64>(0, UInt64(crc) &<< 32), to: SIMD16<UInt8>.self), input, count, reversed: true,
            fold512: fold512, fold128: fold128
        )
    }
}
#endif

// MARK: - Randomization

/// Randomized blocks (bzip2 0.9.0 and 0.9.5): the gaps between the bytes whose low bit was flipped, cycled.
enum BZip2Randomization {
    static let table: [Int16] = [
        619, 720, 127, 481, 931, 816, 813, 233, 566, 247, 985, 724, 205, 454, 863, 491,
        741, 242, 949, 214, 733, 859, 335, 708, 621, 574, 73, 654, 730, 472, 419, 436,
        278, 496, 867, 210, 399, 680, 480, 51, 878, 465, 811, 169, 869, 675, 611, 697,
        867, 561, 862, 687, 507, 283, 482, 129, 807, 591, 733, 623, 150, 238, 59, 379,
        684, 877, 625, 169, 643, 105, 170, 607, 520, 932, 727, 476, 693, 425, 174, 647,
        73, 122, 335, 530, 442, 853, 695, 249, 445, 515, 909, 545, 703, 919, 874, 474,
        882, 500, 594, 612, 641, 801, 220, 162, 819, 984, 589, 513, 495, 799, 161, 604,
        958, 533, 221, 400, 386, 867, 600, 782, 382, 596, 414, 171, 516, 375, 682, 485,
        911, 276, 98, 553, 163, 354, 666, 933, 424, 341, 533, 870, 227, 730, 475, 186,
        263, 647, 537, 686, 600, 224, 469, 68, 770, 919, 190, 373, 294, 822, 808, 206,
        184, 943, 795, 384, 383, 461, 404, 758, 839, 887, 715, 67, 618, 276, 204, 918,
        873, 777, 604, 560, 951, 160, 578, 722, 79, 804, 96, 409, 713, 940, 652, 934,
        970, 447, 318, 353, 859, 672, 112, 785, 645, 863, 803, 350, 139, 93, 354, 99,
        820, 908, 609, 772, 154, 274, 580, 184, 79, 626, 630, 742, 653, 282, 762, 623,
        680, 81, 927, 626, 789, 125, 411, 521, 938, 300, 821, 78, 343, 175, 128, 250,
        170, 774, 972, 275, 999, 639, 495, 78, 352, 126, 857, 956, 358, 619, 580, 124,
        737, 594, 701, 612, 669, 112, 134, 694, 363, 992, 809, 743, 168, 974, 944, 375,
        748, 52, 600, 747, 642, 182, 862, 81, 344, 805, 988, 739, 511, 655, 814, 334,
        249, 515, 897, 955, 664, 981, 649, 113, 974, 459, 893, 228, 433, 837, 553, 268,
        926, 240, 102, 654, 459, 51, 686, 754, 806, 760, 493, 403, 415, 394, 687, 700,
        946, 670, 656, 610, 738, 392, 760, 799, 887, 653, 978, 321, 576, 617, 626, 502,
        894, 679, 243, 440, 680, 879, 194, 572, 640, 724, 926, 56, 204, 700, 707, 151,
        457, 449, 797, 195, 791, 558, 945, 679, 297, 59, 87, 824, 713, 663, 412, 693,
        342, 606, 134, 108, 571, 364, 631, 212, 174, 643, 304, 329, 343, 97, 430, 751,
        497, 314, 983, 374, 822, 928, 140, 206, 73, 263, 980, 736, 876, 478, 430, 305,
        170, 514, 364, 692, 829, 82, 855, 953, 676, 246, 369, 970, 294, 750, 807, 827,
        150, 790, 288, 923, 804, 378, 215, 828, 592, 281, 565, 555, 710, 82, 896, 831,
        547, 261, 524, 462, 293, 465, 502, 56, 661, 821, 976, 991, 658, 869, 905, 758,
        745, 193, 768, 550, 608, 933, 378, 286, 215, 979, 792, 961, 61, 688, 793, 644,
        986, 403, 106, 366, 905, 644, 372, 567, 466, 434, 645, 210, 389, 550, 919, 135,
        780, 773, 635, 389, 707, 100, 626, 958, 165, 504, 920, 176, 193, 713, 857, 265,
        203, 50, 668, 108, 645, 990, 626, 197, 510, 357, 358, 850, 858, 364, 936, 638,
    ]
}

// MARK: - Workspace

/// The decoder's workspace, one allocation made once (7.8 MB): the links forward (`tt`, 2²⁰ entries, more than
/// the largest block's 900,000 and its padding) and back (`back`, for blocks walked from both ends, smaller than
/// `BZip2Segments.minimumBlock`), the block's runs (then its bytes, and the segments' pages), the Huffman tables,
/// selectors, move-to-front list, byte counts and starts, and code lengths. (The CRC tables are a static literal,
/// `BZip2CRC.tables`.)
@safe @usableFromInline
struct BZip2Workspace: ~Copyable {
    static var tt: Int { 0 } // 2²⁰ 4-byte entries
    static var back: Int { 4 &<< 20 } // 32,768 4-byte entries, and 4-entry stores' overrun
    // 4-byte runs, one per symbol at most (50 per selector: 900,100), or the block's 900,000 bytes.
    static var runs: Int { back &+ (BZip2Segments.minimumBlock &+ 64) &* 4 }
    static var groups: Int { runs &+ 3_600_448 } // 6 tables of `BZip2Tables.stride`
    static var selectors: Int { groups &+ 6 &* BZip2Tables.stride } // 18,002 bytes
    static var list: Int { selectors &+ 18_048 } // 256 bytes, and slack
    static var frequencies: Int { list &+ 320 } // 256 4-byte counts
    static var starts: Int { frequencies &+ 1024 } // 256 4-byte starts
    static var lengths: Int { starts &+ 1024 } // 6 rows of `lengthsStride`
    static var lengthsStride: Int { 264 }
    static var size: Int { lengths &+ 6 &* 264 }

    /// Uninitialized but the move-to-front list: making a decoder touches none of the 7.8 MB, and a small block
    /// touches only the pages it uses (it was 516 K instructions to make one, almost all zeroing: RESULTS.md,
    /// 2026-11-24). Every region is written before it's read, each block's own (a block reads nothing an earlier
    /// one left):
    /// - `tt`: `link` or `linkPadded` writes every row of the block (each byte's rows are the targets of its runs,
    ///   whose lengths are the counts the rows come from), and the walks read only rows: the origin (below the
    ///   length), the segments' starts (`paddedRow` of rows), and links, which name rows. The entries past a run's
    ///   end, the 4 after each byte's rows, and entry 2²⁰ − 1 are written and never read.
    /// - `back`: `link` stores at least a run's length at its position, so every position of the block; `walk`
    ///   reads positions.
    /// - `runs`: `decodeSymbols` writes the runs `link` reads; then the walks write the block's bytes (all of
    ///   them) that `expand` reads, and the segment walk's arena, page links, records, and lane state, each before
    ///   it's read (`BZip2Segments.walk` says how).
    /// - `groups`: `BZip2Tables.build` writes every entry it and `decodeSlowly` read (the primary table whole,
    ///   limits and offsets for lengths 1–20, the sorted symbols below the alphabet size), for each table the
    ///   selectors name (selectors name only the block's tables).
    /// - `selectors`, `frequencies`, `starts`, `lengths`: written for the block before they're read (the
    ///   selectors below the count read, the counts zeroed by `BZip2SymbolState`, the starts from them, the
    ///   lengths of each table before it's built).
    /// - `list` is zeroed: `BZip2SymbolState` and `moveToFront` load 16 bytes at a time, which reach past the
    ///   bytes the block's header wrote (bytes never moved to the front: indices are below the symbol count).
    let memory: CodecWorkspace

    init() {
        memory = CodecWorkspace(byteCount: Self.size, zeroed: false)
        // Unsafe: zeroing the list region. Safe: within the allocation by its constant offset (320 bytes, before
        // `frequencies`).
        unsafe (memory.base + Self.list).initializeMemory(as: UInt8.self, repeating: 0, count: Self.frequencies &- Self.list)
    }

    // Unsafe: the allocation's address. Safe: valid while the workspace (which owns it) lives.
    var base: UnsafeMutableRawPointer { unsafe memory.base }
}
