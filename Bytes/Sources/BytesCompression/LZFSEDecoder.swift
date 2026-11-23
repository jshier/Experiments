public import Bytes

/// An LZFSE decoder: the format Compression writes for `COMPRESSION_LZFSE`, and Apple Archive's `pbze` blocks.
///
/// ```swift
/// var decoder = LZFSEDecoder()
/// let consumed = try decoder.decompressAll(stream, into: &output)   // through the `bvx$` end marker
/// ```
///
/// An LZFSE stream is a series of blocks, each starting with a 4-byte magic: `bvx2` (LZFSE with compressed
/// frequency tables) and `bvx1` (with plain ones), `bvxn` (LZVN, see ``LZVNDecoder``), `bvx-` (stored), and
/// `bvx$` (the end). An LZFSE block holds up to 40,000 literals, coded with four interleaved FSE (tANS) states,
/// and up to 10,000 matches, each a literal length, a match length, and a distance (or 0 for the previous
/// one), FSE-coded with extra bits. Both bitstreams are read backward. Matches may reach back into earlier
/// blocks.
///
/// Decoding follows the reference decoder (github.com/lzfse/lzfse): a block's literals are decoded into a
/// buffer first, then its matches are decoded and executed one at a time, copying 16 bytes at a time while
/// there's room past them in the output, and exactly near its end. The decoder's tables and literal buffer
/// (48 KB) are allocated once, at creation; decoding allocates nothing. Malformed input throws; it never reads
/// or writes outside the buffers.
@safe
public struct LZFSEDecoder: ~Copyable {
    var workspace = LZFSEWorkspace()

    /// Creates a decoder, allocating its tables and literal buffer.
    public init() {}

    /// Decodes an LZFSE stream, from its first block through its `bvx$` end marker, into `output`'s free
    /// capacity.
    ///
    /// - Parameters:
    ///   - input: The stream, at its start. Bytes after its end marker are left alone.
    ///   - output: Where to append the decoded bytes; it needs room for all of them. Bytes of its free capacity
    ///     past them may be overwritten.
    /// - Returns: The number of input bytes decoded, through the end marker.
    /// - Throws: ``BytesError/insufficientData`` if the input ends early; ``BytesError/insufficientCapacity`` if
    ///   the output doesn't fit; ``BytesError/invalidValue`` for an unknown block magic or a corrupt block,
    ///   including one that doesn't decode to its stated size.
    public mutating func decompressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        let workspace = unsafe workspace.base
        return try unsafe LZBuffers.with(input, &output) { input, count, output, capacity throws(BytesError) -> (Int, Int) in
            try unsafe Self.decodeStream(input, count: count, output: output, capacity: capacity, workspace: workspace)
        }
    }

    /// Block magics, as little-endian integers.
    enum Magic {
        static var lzfseV2: UInt32 { 0x3278_7662 } // "bvx2"
        static var lzfseV1: UInt32 { 0x3178_7662 } // "bvx1"
        static var lzvn: UInt32 { 0x6E78_7662 } // "bvxn"
        static var stored: UInt32 { 0x2D78_7662 } // "bvx-"
        static var end: UInt32 { 0x2478_7662 } // "bvx$"
    }

    /// Decodes blocks from `input` into `output`.
    ///
    /// - Returns: The input consumed and the bytes written.
    static func decodeStream(
        _ input: UnsafeRawPointer, count: Int, output: UnsafeMutableRawPointer, capacity: Int,
        workspace: UnsafeMutableRawPointer
    ) throws(BytesError) -> (Int, Int) {
        var position = 0
        var end = 0
        // Unsafe: header loads, copies, and pointers into the buffers. Safe: each is preceded by a check that the
        // input holds the bytes read and the output has room for the bytes written.
        while true {
            guard count &- position >= 4 else { throw .insufficientData }
            let magic = UInt32(littleEndian: unsafe input.loadUnaligned(fromByteOffset: position, as: UInt32.self))
            switch magic {
            case Magic.end:
                return (position &+ 4, end)
            case Magic.lzfseV2, Magic.lzfseV1:
                let header = try unsafe LZFSEBlockHeader(
                    input + position, available: count &- position, isV2: magic == Magic.lzfseV2,
                    frequencies: workspace + LZFSEWorkspace.frequencies
                )
                guard header.decodedSize <= capacity &- end else { throw .insufficientCapacity }
                try unsafe decodeBlock(
                    header, at: input + position, base: output, output: output + end, outputLimit: output + capacity,
                    workspace: workspace
                )
                position &+= header.size
                end &+= header.decodedSize
            case Magic.lzvn:
                guard count &- position >= 12 else { throw .insufficientData }
                let decoded = Int(UInt32(littleEndian: unsafe input.loadUnaligned(fromByteOffset: position &+ 4, as: UInt32.self)))
                let encoded = Int(UInt32(littleEndian: unsafe input.loadUnaligned(fromByteOffset: position &+ 8, as: UInt32.self)))
                position &+= 12
                guard encoded <= count &- position else { throw .insufficientData }
                guard decoded <= capacity &- end else { throw .insufficientCapacity }
                let inputEnd = unsafe input + (position &+ encoded)
                let outputEnd = unsafe output + (end &+ decoded)
                do throws(BytesError) {
                    let (reachedInput, reachedOutput) = try unsafe LZVNDecoder.decode(
                        input + position, inputEnd: inputEnd, inputLimit: input + count,
                        base: output, output: output + end, outputEnd: outputEnd, outputLimit: output + capacity
                    )
                    guard unsafe reachedInput == inputEnd && reachedOutput == outputEnd else { throw BytesError.invalidValue }
                } catch {
                    throw .invalidValue // The block disagrees with its header.
                }
                position &+= encoded
                end &+= decoded
            case Magic.stored:
                guard count &- position >= 8 else { throw .insufficientData }
                let size = Int(UInt32(littleEndian: unsafe input.loadUnaligned(fromByteOffset: position &+ 4, as: UInt32.self)))
                position &+= 8
                guard size <= count &- position else { throw .insufficientData }
                guard size <= capacity &- end else { throw .insufficientCapacity }
                unsafe LZCopy.exact(output + end, input + position, size)
                position &+= size
                end &+= size
            default:
                throw .invalidValue
            }
        }
    }

    /// Decodes an LZFSE block whose header is `header`, at `block`, into `output`.
    @inline(never)
    static func decodeBlock(
        _ header: LZFSEBlockHeader, at block: UnsafeRawPointer, base: UnsafeMutableRawPointer,
        output: UnsafeMutableRawPointer, outputLimit: UnsafeMutableRawPointer, workspace: UnsafeMutableRawPointer
    ) throws(BytesError) {
        // Unsafe: the workspace's tables, and pointers to the block's parts. Safe: the header checked that the
        // input holds the block's header and payloads, and the caller that the output has room for its bytes.
        let frequencies = unsafe UnsafePointer((workspace + LZFSEWorkspace.frequencies).assumingMemoryBound(to: UInt16.self))
        let literalTable = unsafe (workspace + LZFSEWorkspace.literalTable).assumingMemoryBound(to: UInt32.self)
        let lTable = unsafe (workspace + LZFSEWorkspace.lTable).assumingMemoryBound(to: UInt64.self)
        let mTable = unsafe (workspace + LZFSEWorkspace.mTable).assumingMemoryBound(to: UInt64.self)
        let dTable = unsafe (workspace + LZFSEWorkspace.dTable).assumingMemoryBound(to: UInt64.self)
        unsafe LZFSETables.buildValueTable(
            states: 64, frequencies: frequencies, symbols: 20, extraBits: LZFSETables.lExtraBits, base: LZFSETables.lBase, into: lTable
        )
        unsafe LZFSETables.buildValueTable(
            states: 64, frequencies: frequencies + 20, symbols: 20, extraBits: LZFSETables.mExtraBits, base: LZFSETables.mBase, into: mTable
        )
        unsafe LZFSETables.buildValueTable(
            states: 256, frequencies: frequencies + 40, symbols: 64, extraBits: LZFSETables.dExtraBits, base: LZFSETables.dBase, into: dTable
        )
        unsafe LZFSETables.buildLiteralTable(frequencies: frequencies + 104, into: literalTable)

        let literalStream = unsafe block + header.headerSize
        let lmdStream = unsafe literalStream + header.literalPayloadSize
        let literals = unsafe (workspace + LZFSEWorkspace.literals).assumingMemoryBound(to: UInt8.self)
        try unsafe decodeLiterals(
            header, stream: literalStream, end: lmdStream, table: literalTable, into: literals
        )
        let outputEnd = unsafe output + header.decodedSize
        let reached = try unsafe executeMatches(
            header, stream: lmdStream, end: lmdStream + header.lmdPayloadSize,
            tables: (UnsafePointer(lTable), UnsafePointer(mTable), UnsafePointer(dTable)), literals: literals, literalEnd: literals + header.literalCount,
            base: base, output: output, outputEnd: outputEnd, outputLimit: outputLimit
        )
        guard unsafe reached == outputEnd else { throw .invalidValue }
    }

    /// Decodes the block's literals into `literals`: four interleaved FSE states over one backward bitstream,
    /// four literals per refill.
    @inline(never)
    static func decodeLiterals(
        _ header: LZFSEBlockHeader, stream: UnsafeRawPointer, end: UnsafeRawPointer,
        table: UnsafePointer<UInt32>, into literals: UnsafeMutablePointer<UInt8>
    ) throws(BytesError) {
        // Unsafe: table lookups, and stores into the literal buffer. Safe: states stay below 1024, the table's
        // size (the header checked the initial ones; the table's entries keep the next ones in range); the
        // literal count, rounded up to 4, is at most the buffer's 40,000.
        var bits = try unsafe LZFSEReverseBits(stream, end: end, padding: header.literalBits)
        var state0 = header.literalStates.0
        var state1 = header.literalStates.1
        var state2 = header.literalStates.2
        var state3 = header.literalStates.3
        var index = 0
        while index < header.literalCount {
            try bits.reload()
            let entry0 = unsafe table[state0]
            state0 = Int(truncatingIfNeeded: entry0 &>> 16) &+ bits.read(Int(truncatingIfNeeded: entry0 & 0xFF))
            let entry1 = unsafe table[state1]
            state1 = Int(truncatingIfNeeded: entry1 &>> 16) &+ bits.read(Int(truncatingIfNeeded: entry1 & 0xFF))
            let entry2 = unsafe table[state2]
            state2 = Int(truncatingIfNeeded: entry2 &>> 16) &+ bits.read(Int(truncatingIfNeeded: entry2 & 0xFF))
            let entry3 = unsafe table[state3]
            state3 = Int(truncatingIfNeeded: entry3 &>> 16) &+ bits.read(Int(truncatingIfNeeded: entry3 & 0xFF))
            let four = (entry0 &>> 8) & 0xFF | (entry1 & 0xFF00) | (entry2 & 0xFF00) &<< 8 | (entry3 & 0xFF00) &<< 16
            unsafe UnsafeMutableRawPointer(literals + index).storeBytes(of: four.littleEndian, as: UInt32.self)
            index &+= 4
        }
        guard bits.isValid else { throw .invalidValue }
    }

    /// Decodes the block's matches and executes each: its literals from `literals`, then its match.
    ///
    /// - Returns: Where the output ended.
    @inline(never)
    static func executeMatches(
        _ header: LZFSEBlockHeader, stream: UnsafeRawPointer, end: UnsafeRawPointer,
        tables: (UnsafePointer<UInt64>, UnsafePointer<UInt64>, UnsafePointer<UInt64>),
        literals: UnsafePointer<UInt8>, literalEnd: UnsafePointer<UInt8>,
        base: UnsafeMutableRawPointer, output: UnsafeMutableRawPointer, outputEnd: UnsafeMutableRawPointer,
        outputLimit: UnsafeMutableRawPointer
    ) throws(BytesError) -> UnsafeMutableRawPointer {
        // Unsafe: table lookups, reads of the literal buffer, and copies into the output. Safe: states stay below
        // each table's size (as for literals); each sequence's literals are checked to end by `literalEnd`, and
        // the literal buffer has `LZCopy.overrun` bytes of slack past its 40,000; each sequence is checked to end
        // by `outputEnd`, and wild copies run only while `outputFast` leaves room for their overrun; matches start
        // at `base` or later (checked).
        var bits = try unsafe LZFSEReverseBits(stream, end: end, padding: header.lmdBits)
        let (lTable, mTable, dTable) = unsafe tables
        var lState = header.lState
        var mState = header.mState
        var dState = header.dState
        var literal = unsafe UnsafeRawPointer(literals)
        let literalEnd = unsafe UnsafeRawPointer(literalEnd)
        var op = unsafe output
        // As an offset from `output`, negative with less room than the overrun, so that no copy (not even an empty
        // one, which still moves 16 bytes) takes the fast path then (see `LZ4Decoder.decodeBlock`).
        let outputFast = unsafe min(outputEnd - output, (outputLimit - output) &- LZCopy.overrun)
        var distance = 0 // The previous distance: none yet, which no match may use.
        var remaining = header.matchCount
        while remaining > 0 {
            // L, M, and D take at most 14, 17, and 23 bits: one refill.
            try bits.reload()
            let lEntry = unsafe lTable[lState]
            let lValue = bits.read(Int(truncatingIfNeeded: lEntry & 0xFF))
            let lExtra = Int(truncatingIfNeeded: lEntry &>> 8) & 0xFF
            lState = Int(truncatingIfNeeded: lEntry &>> 16) & 0xFFFF &+ lValue &>> lExtra
            let literalLength = Int(truncatingIfNeeded: lEntry &>> 32) &+ lValue & (1 &<< lExtra &- 1)
            let mEntry = unsafe mTable[mState]
            let mValue = bits.read(Int(truncatingIfNeeded: mEntry & 0xFF))
            let mExtra = Int(truncatingIfNeeded: mEntry &>> 8) & 0xFF
            mState = Int(truncatingIfNeeded: mEntry &>> 16) & 0xFFFF &+ mValue &>> mExtra
            let matchLength = Int(truncatingIfNeeded: mEntry &>> 32) &+ mValue & (1 &<< mExtra &- 1)
            let dEntry = unsafe dTable[dState]
            let dValue = bits.read(Int(truncatingIfNeeded: dEntry & 0xFF))
            let dExtra = Int(truncatingIfNeeded: dEntry &>> 8) & 0xFF
            dState = Int(truncatingIfNeeded: dEntry &>> 16) & 0xFFFF &+ dValue &>> dExtra
            let newDistance = Int(truncatingIfNeeded: dEntry &>> 32) &+ dValue & (1 &<< dExtra &- 1)
            if newDistance != 0 { distance = newDistance }
            remaining &-= 1

            guard unsafe literalLength <= literalEnd - literal else { throw .invalidValue }
            // 1 through the bytes before the match: one unsigned comparison.
            guard unsafe UInt(bitPattern: distance &- 1) < UInt(bitPattern: op + literalLength - base) else {
                throw .invalidValue
            }
            if likely(unsafe literalLength &+ matchLength <= outputFast &- (op - output)) {
                unsafe LZCopy.wild(op, literal, literalLength)
                unsafe op += literalLength
                unsafe LZCopy.match(op, offset: distance, count: matchLength)
                unsafe op += matchLength
            } else {
                guard unsafe literalLength &+ matchLength <= outputEnd - op else { throw .invalidValue }
                unsafe LZCopy.exact(op, literal, literalLength)
                unsafe op += literalLength
                unsafe LZCopy.exactMatch(op, offset: distance, count: matchLength)
                unsafe op += matchLength
            }
            unsafe literal += literalLength
        }
        guard bits.isValid else { throw .invalidValue }
        return unsafe op
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension LZFSEDecoder: @unchecked Sendable {}

/// An LZFSE block's header, `bvx1` or `bvx2`, read and checked.
struct LZFSEBlockHeader {
    /// The header's size: 772 bytes for `bvx1`, stated in the header for `bvx2`.
    var headerSize: Int
    var decodedSize: Int
    /// The literal count, rounded up to 4: the literal decoder writes them 4 at a time.
    var literalCount: Int
    var matchCount: Int
    var literalPayloadSize: Int
    var lmdPayloadSize: Int
    /// The padding bits at the end of each stream, 0 through 8 (the reference format's -bits).
    var literalBits: Int
    var lmdBits: Int
    var literalStates: (Int, Int, Int, Int)
    var lState: Int
    var mState: Int
    var dState: Int

    /// The whole block's size in the input.
    var size: Int { headerSize &+ literalPayloadSize &+ lmdPayloadSize }

    /// Reads the header at `block` (`available` bytes to the input's end), writing its 360 frequencies to
    /// `frequencies`, and checks it: the counts and states in range, the frequency tables' sums at most their
    /// state counts, and the payloads present.
    ///
    /// - Throws: ``BytesError/insufficientData`` if the input ends inside the block; ``BytesError/invalidValue``
    ///   for a header out of range.
    init(_ block: UnsafeRawPointer, available: Int, isV2: Bool, frequencies: UnsafeMutableRawPointer) throws(BytesError) {
        let table = unsafe frequencies.assumingMemoryBound(to: UInt16.self)
        // Unsafe: header loads, and stores to the frequency table. Safe: each load is checked to be within
        // `available` bytes; the table holds 360 entries.
        if isV2 {
            guard available >= 32 else { throw .insufficientData }
            decodedSize = Int(UInt32(littleEndian: unsafe block.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            let v0 = UInt64(littleEndian: unsafe block.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            let v1 = UInt64(littleEndian: unsafe block.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
            let v2 = UInt64(littleEndian: unsafe block.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
            func field(_ value: UInt64, _ offset: UInt64, _ width: UInt64) -> Int {
                Int(truncatingIfNeeded: value &>> offset & (1 &<< width &- 1))
            }
            literalCount = field(v0, 0, 20)
            literalPayloadSize = field(v0, 20, 20)
            matchCount = field(v0, 40, 20)
            literalBits = 7 &- field(v0, 60, 3)
            literalStates = (field(v1, 0, 10), field(v1, 10, 10), field(v1, 20, 10), field(v1, 30, 10))
            lmdPayloadSize = field(v1, 40, 20)
            lmdBits = 7 &- field(v1, 60, 3)
            headerSize = field(v2, 0, 32)
            lState = field(v2, 32, 10)
            mState = field(v2, 42, 10)
            dState = field(v2, 52, 10)
            guard headerSize >= 32 else { throw .invalidValue }
            guard headerSize <= available else { throw .insufficientData }
            try unsafe Self.decodeFrequencies(block + 32, count: headerSize &- 32, into: table)
        } else {
            headerSize = 772
            guard available >= headerSize else { throw .insufficientData }
            func load32(_ offset: Int) -> Int {
                // Unsafe: a load within the 772-byte header, checked above.
                Int(UInt32(littleEndian: unsafe block.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            func load16(_ offset: Int) -> Int {
                // Unsafe: a load within the 772-byte header, checked above.
                Int(UInt16(littleEndian: unsafe block.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            }
            decodedSize = load32(4)
            literalCount = load32(12)
            matchCount = load32(16)
            literalPayloadSize = load32(20)
            lmdPayloadSize = load32(24)
            literalBits = -Int(Int32(truncatingIfNeeded: load32(28)))
            literalStates = (load16(32), load16(34), load16(36), load16(38))
            lmdBits = -Int(Int32(truncatingIfNeeded: load32(40)))
            lState = load16(44)
            mState = load16(46)
            dState = load16(48)
            for index in 0..<360 {
                unsafe table[index] = UInt16(load16(50 &+ 2 &* index))
            }
        }
        guard literalCount <= 40_000, matchCount <= 10_000,
              literalBits >= 0, literalBits <= 8, lmdBits >= 0, lmdBits <= 8,
              literalStates.0 < 1024, literalStates.1 < 1024, literalStates.2 < 1024, literalStates.3 < 1024,
              lState < 64, mState < 64, dState < 256
        else { throw .invalidValue }
        literalCount = (literalCount &+ 3) & ~3
        guard unsafe Self.sum(table, 20) <= 64, unsafe Self.sum(table + 20, 20) <= 64, unsafe Self.sum(table + 40, 64) <= 256,
              unsafe Self.sum(table + 104, 256) <= 1024
        else { throw .invalidValue }
        guard literalPayloadSize &+ lmdPayloadSize <= available &- headerSize else { throw .insufficientData }
    }

    private static func sum(_ table: UnsafeMutablePointer<UInt16>, _ count: Int) -> Int {
        var total = 0
        for index in 0..<count {
            // Unsafe: a read within the 360-entry table (the callers' ranges end by 360).
            total &+= Int(unsafe table[index])
        }
        return total
    }

    /// Decodes `bvx2`'s frequency tables: 360 values in a fixed prefix code read from the low bits up, which
    /// must end in the header's last byte. An empty table section means all zeros.
    private static func decodeFrequencies(_ bytes: UnsafeRawPointer, count: Int, into table: UnsafeMutablePointer<UInt16>) throws(BytesError) {
        if count == 0 {
            // Unsafe: filling the 360-entry table.
            unsafe table.update(repeating: 0, count: 360)
            return
        }
        var accumulator: UInt32 = 0
        var accumulated = 0
        var position = 0
        // Unsafe: byte loads below `count`, and stores within the 360-entry table.
        for index in 0..<360 {
            while position < count && accumulated &+ 8 <= 32 {
                accumulator |= UInt32(unsafe bytes.load(fromByteOffset: position, as: UInt8.self)) &<< UInt32(accumulated)
                accumulated &+= 8
                position &+= 1
            }
            // Codes, low bit first: x0 (value x), x01 (2 + x), xx011 (4 + xx), xxxx0111 (8 + xxxx), and
            // xxxxxxxxxx1111 (24 + xxxxxxxxxx).
            let length: Int
            let value: UInt32
            if accumulator & 1 == 0 {
                (length, value) = (2, accumulator &>> 1 & 1)
            } else if accumulator & 2 == 0 {
                (length, value) = (3, 2 &+ (accumulator &>> 2 & 1))
            } else if accumulator & 4 == 0 {
                (length, value) = (5, 4 &+ (accumulator &>> 3 & 3))
            } else if accumulator & 8 == 0 {
                (length, value) = (8, 8 &+ (accumulator &>> 4 & 0xF))
            } else {
                (length, value) = (14, 24 &+ (accumulator &>> 4 & 0x3FF))
            }
            guard length <= accumulated else { throw .invalidValue }
            unsafe table[index] = UInt16(value)
            accumulator &>>= UInt32(length)
            accumulated &-= length
        }
        guard accumulated < 8, position == count else { throw .invalidValue }
    }
}

/// A backward bitstream: bytes are read from the end toward the start, bits from the most significant down.
/// The last byte's top `padding` bits (0 through 8) are zeros the encoder added.
///
/// The container holds the 8 bytes at `position`; `consumed` counts the bits used from its top. Reading past
/// the stream's start is allowed into the 8 bytes before it (the header or another stream, always there) and
/// reported by ``isValid``; reloads that would go further throw.
@safe
struct LZFSEReverseBits {
    var container: UInt64
    var consumed: Int
    var position: UnsafeRawPointer
    let start: UnsafeRawPointer
    /// The lowest position a reload may load from: 8 bytes before `start`.
    let floor: UnsafeRawPointer

    /// Starts reading the stream from `start` to `end`.
    ///
    /// - Precondition: The 8 bytes before `start` are readable.
    /// - Throws: ``BytesError/invalidValue`` if the stream is too short for its padding, or the padding bits
    ///   aren't 0.
    @unsafe @inline(__always)
    init(_ start: UnsafeRawPointer, end: UnsafeRawPointer, padding: Int) throws(BytesError) {
        // Unsafe: an 8-byte load ending at `end`, and pointers 8 bytes before `start`. Safe: the stream's start
        // has 8 readable bytes before it (the caller's precondition), so the load is within the input.
        unsafe self.start = start
        unsafe floor = start - 8
        unsafe position = end - 8
        container = UInt64(littleEndian: unsafe position.loadUnaligned(as: UInt64.self))
        consumed = padding
        // A stream shorter than 8 bytes is read from the bytes before it too, as the reference reads short
        // literal streams; ``isValid`` reports whether that went past its start.
        guard padding == 0 || container &>> UInt64(64 &- padding) == 0 else { throw .invalidValue }
    }

    /// The next `count` bits, 0 through 56.
    @inline(__always)
    mutating func read(_ count: Int) -> Int {
        BackwardBits.read(count, from: container, consumed: &consumed)
    }

    /// Refills the container to at least 57 unread bits.
    ///
    /// - Throws: ``BytesError/invalidValue`` if the stream was overrun by more than the 8 bytes before it.
    @inline(__always)
    mutating func reload() throws(BytesError) {
        // Unsafe: an 8-byte load. Safe: at or above `floor`, and at or below the previous position, so within
        // the stream or the 8 readable bytes before it.
        let next = unsafe position - (consumed &>> 3)
        guard likely(unsafe next >= floor) else { throw .invalidValue }
        unsafe position = next
        consumed &= 7
        container = UInt64(littleEndian: unsafe next.loadUnaligned(as: UInt64.self))
    }

    /// Whether every bit read was in the stream.
    var isValid: Bool {
        // Unsafe: a distance between pointers into the input.
        unsafe (position - start) &* 8 &+ 64 >= consumed
    }
}

/// The decoder's workspace: the FSE tables, frequencies, and literal buffer, one allocation made once.
@safe @usableFromInline
struct LZFSEWorkspace: ~Copyable {
    static var lTable: Int { 0 } // 64 8-byte entries
    static var mTable: Int { 512 } // 64 8-byte entries
    static var dTable: Int { 1024 } // 256 8-byte entries
    static var literalTable: Int { 3072 } // 1024 4-byte entries
    static var frequencies: Int { 7168 } // 360 2-byte values
    static var literals: Int { 7936 } // 40,000 literals and copies' slack
    static var size: Int { 7936 + 40_000 + 64 }

    /// Zeroed: zeros keep the literal buffer's slack defined for the wild copies that read it.
    let memory = CodecWorkspace(byteCount: size)

    // Unsafe: the allocation's address. Safe: valid while the workspace (which owns it) lives.
    var base: UnsafeMutableRawPointer { unsafe memory.base }
}

/// LZFSE's FSE decoding tables and the L, M, and D symbols' extra bits and base values.
enum LZFSETables {
    static let lExtraBits: InlineArray<20, UInt8> = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 5, 8]
    static let lBase: InlineArray<20, Int32> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 20, 28, 60]
    static let mExtraBits: InlineArray<20, UInt8> = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 5, 8, 11]
    static let mBase: InlineArray<20, Int32> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 24, 56, 312]
    static let dExtraBits: InlineArray<64, UInt8> = [
        0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7,
        8, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 15, 15,
    ]
    static let dBase: InlineArray<64, Int32> = [
        0, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 28, 36, 44, 52, 60, 76, 92, 108, 124, 156, 188, 220, 252, 316, 380, 444,
        508, 636, 764, 892, 1020, 1276, 1532, 1788, 2044, 2556, 3068, 3580, 4092, 5116, 6140, 7164, 8188, 10236, 12284,
        14332, 16380, 20476, 24572, 28668, 32764, 40956, 49148, 57340, 65532, 81916, 98300, 114684, 131068, 163836,
        196604, 229372,
    ]

    /// Fills a value decoder table of `states` entries (a power of 2) from `symbols` frequencies whose sum is at
    /// most `states`: each entry is the bits to read (state and extra bits) in bits 0–7, the extra bits in 8–15,
    /// the next state's base in 16–31, and the symbol's base value in 32–63. States no symbol has are zeros.
    ///
    /// The entries' next states stay below `states`, whatever bits are read: for each symbol of frequency `f`
    /// and shift `k` (so `states <= f << k < 2 * states`), its states' bases and bit counts cover `0..<states`.
    static func buildValueTable<let n: Int>(
        states: Int, frequencies: UnsafePointer<UInt16>, symbols: Int, extraBits: InlineArray<n, UInt8>,
        base: InlineArray<n, Int32>, into table: UnsafeMutablePointer<UInt64>
    ) {
        // Unsafe: reads of `symbols` frequencies, and writes of `states` entries. Safe: the frequencies sum to at
        // most `states` (the header checked), so the writes stay within the table.
        var index = 0
        let leading = UInt32(states).leadingZeroBitCount
        for symbol in 0..<symbols {
            let frequency = Int(unsafe frequencies[symbol])
            if frequency == 0 { continue }
            let k = UInt32(frequency).leadingZeroBitCount &- leading
            let j0 = (2 &* states) &>> k &- frequency
            let extra = UInt64(extraBits[symbol])
            let value = UInt64(UInt32(bitPattern: base[symbol])) &<< 32 | extra &<< 8
            for j in 0..<frequency {
                let entry: UInt64
                if j < j0 {
                    entry = value | UInt64((frequency &+ j) &<< k &- states) &<< 16 | (UInt64(k) &+ extra)
                } else {
                    entry = value | UInt64((j &- j0) &<< (k &- 1)) &<< 16 | (UInt64(k &- 1) &+ extra)
                }
                unsafe table[index] = entry
                index &+= 1
            }
        }
        while index < states {
            unsafe table[index] = 0
            index &+= 1
        }
    }

    /// Fills the literal decoder table, 1024 entries, from 256 frequencies whose sum is at most 1024: each entry
    /// is the bits to read in bits 0–7, the symbol in 8–15, and the next state's base in 16–31.
    static func buildLiteralTable(frequencies: UnsafePointer<UInt16>, into table: UnsafeMutablePointer<UInt32>) {
        // Unsafe: as `buildValueTable`.
        let states = 1024
        var index = 0
        let leading = UInt32(states).leadingZeroBitCount
        for symbol in 0..<256 {
            let frequency = Int(unsafe frequencies[symbol])
            if frequency == 0 { continue }
            let k = UInt32(frequency).leadingZeroBitCount &- leading
            let j0 = (2 &* states) &>> k &- frequency
            let value = UInt32(symbol) &<< 8
            for j in 0..<frequency {
                let entry: UInt32
                if j < j0 {
                    entry = value | UInt32((frequency &+ j) &<< k &- states) &<< 16 | UInt32(k)
                } else {
                    entry = value | UInt32((j &- j0) &<< (k &- 1)) &<< 16 | UInt32(k &- 1)
                }
                unsafe table[index] = entry
                index &+= 1
            }
        }
        while index < states {
            unsafe table[index] = 0
            index &+= 1
        }
    }
}
