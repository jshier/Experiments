public import Bytes

/// An LZFSE encoder: the streams Compression writes for `COMPRESSION_LZFSE` (see ``LZFSEDecoder``), as APFS
/// compression (`decmpfs` types 11 and 12, each 64 KiB chunk a stream) and Apple Archive's `pbze` blocks hold.
///
/// ```swift
/// var encoder = LZFSEEncoder()                                  // allocates its table and buffers once
/// let written = try encoder.compressAll(input, into: &output)  // blocks, then `bvx$`
/// ```
///
/// By default the stream is Compression's, byte for byte (checked on the Silesia corpus, whole and in 64 KiB
/// chunks); with ``LZVNEncoder/Parse/reference``, the lzfse reference encoder's (github.com/lzfse/lzfse,
/// `lzfse_encode_buffer`). The two differ in two constants: Compression's `bvxn` blocks are its own LZVN (see
/// ``LZVNEncoder``), and it writes pending literals once more than 945 pile up with no match (3 × 315; the
/// reference waits for 2,520), which moves some block boundaries.
/// - Under 8 bytes, a stored block (`bvx-`);
/// - under 4,096 bytes, an LZVN block (`bvxn`, ``LZVNEncoder``), or a stored one if that doesn't shrink it;
/// - otherwise LZFSE blocks (`bvx2`) of up to 40,000 literals and 10,000 matches. The match search hashes 4 bytes
///   into a line of the 4 latest positions with that hash, keeps the longest match (back to 262,139 bytes), and
///   holds it until the next shows whether they overlap; the literals and the matches' lengths and distances are
///   coded with FSE (tANS) tables normalized from each block's counts.
///
/// When the stream doesn't fit, a stored block is written instead if that fits, as Compression does: an input
/// that doesn't compress takes more room than a stored block only when there's room for it.
///
/// Encoding allocates nothing after initialization. The match table isn't cleared between inputs (see
/// ``LZVNEncoder``).
@safe
public struct LZFSEEncoder: ~Copyable {
    /// Whose parse an encoder reproduces: Compression's or the lzfse reference's.
    public typealias Parse = LZVNEncoder.Parse

    var table = LZMatchTable()
    var workspace = LZFSEEncoderWorkspace()
    /// Whose streams this encoder writes.
    public let parse: Parse

    /// Creates an encoder, allocating its match table and block buffers (about 800 KB).
    ///
    /// - Parameter parse: Whose streams to write: Compression's by default.
    public init(parse: Parse = .compression) {
        self.parse = parse
    }

    /// An upper bound on the encoded size of `byteCount` bytes, end marker included.
    ///
    /// - Parameter byteCount: The input's size.
    /// - Returns: A size no stream of that input exceeds.
    public static func maximumCompressedSize(forByteCount byteCount: Int) -> Int {
        // At most 10 bits per literal, 54 per match, and a header of up to 662 bytes per block.
        byteCount &+ byteCount / 4 &+ (byteCount / 1024 &+ 1) &* 700 &+ 64
    }

    /// Encodes `input` as an LZFSE stream, through its `bvx$` end marker, appending it to `output`.
    ///
    /// Every call starts a new stream: an encoder used before writes what a fresh one would (the match table's old
    /// entries read as empty), keeping its memory. ``maximumCompressedSize(forByteCount:)`` bytes of free capacity
    /// are always enough.
    ///
    /// - Parameters:
    ///   - input: All the data.
    ///   - output: Where to append the stream.
    /// - Returns: The number of bytes appended.
    /// - Throws: ``BytesError/insufficientCapacity`` if neither the stream nor a stored block of the input fits;
    ///   `output` is then unchanged, though its free capacity may have been overwritten.
    public mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        let base = unsafe table.base
        let workspace = unsafe workspace.base
        var bias = table.reserveBias(forByteCount: input.byteCount)
        let parse = parse
        return try unsafe LZBuffers.with(input, &output) { input, count, output, capacity throws(BytesError) -> (Int, Int) in
            let written = try unsafe Self.encode(
                input, count: count, output: output, capacity: capacity, table: base, bias: &bias, workspace: workspace, parse: parse
            )
            return (written, written)
        }
    }

    /// Below this, an LZVN block (`bvxn`) rather than LZFSE ones.
    static var lzvnThreshold: Int { 4096 }

    /// Encodes `count` bytes at `src` into `output`: LZFSE or LZVN blocks, or a stored block when the input is
    /// tiny, doesn't shrink as LZVN, or doesn't fit compressed.
    ///
    /// - Returns: The bytes written.
    static func encode(
        _ src: UnsafeRawPointer, count: Int, output: UnsafeMutableRawPointer, capacity: Int,
        table: UnsafeMutableRawPointer, bias: inout Int, workspace: UnsafeMutableRawPointer, parse: Parse
    ) throws(BytesError) -> Int {
        // Unsafe: block headers stored in the output, and pointers into it. Safe: each is checked to fit in
        // `capacity` first.
        if count >= 8 {
            if count < lzvnThreshold {
                if capacity > 16 {
                    do throws(BytesError) {
                        // As Compression: the payload goes after the block's 12-byte header, given the room less it
                        // and the 4-byte end marker.
                        let payload = try unsafe LZVNEncoder.encode(
                            src, count: count, output: output + 12, capacity: capacity &- 16, table: table, bias: &bias, parse: parse
                        )
                        if payload < count {
                            unsafe output.storeBytes(of: LZFSEDecoder.Magic.lzvn.littleEndian, as: UInt32.self)
                            unsafe output.storeBytes(of: UInt32(count).littleEndian, toByteOffset: 4, as: UInt32.self)
                            unsafe output.storeBytes(of: UInt32(payload).littleEndian, toByteOffset: 8, as: UInt32.self)
                            unsafe output.storeBytes(of: LZFSEDecoder.Magic.end.littleEndian, toByteOffset: 12 &+ payload, as: UInt32.self)
                            return payload &+ 16
                        }
                    } catch {
                        // Too big for the output: stored, below, if that fits.
                    }
                }
            } else {
                do throws(BytesError) {
                    return try unsafe LZFSEFrontEnd.encode(
                        src, count: count, output: output, capacity: capacity, table: table, bias: &bias, workspace: workspace,
                        literalBacklog: LZFSEFrontEnd.literalBacklog(parse)
                    )
                } catch {
                    // Too big for the output: stored, below, if that fits.
                }
            }
        }
        // A stored block's size is 32 bits (the reference stores one only under `INT32_MAX`, as here).
        guard count &+ 12 <= capacity && count < Int(Int32.max) else { throw .insufficientCapacity }
        unsafe output.storeBytes(of: LZFSEDecoder.Magic.stored.littleEndian, as: UInt32.self)
        unsafe output.storeBytes(of: UInt32(truncatingIfNeeded: count).littleEndian, toByteOffset: 4, as: UInt32.self)
        unsafe LZCopy.exact(output + 8, src, count)
        unsafe output.storeBytes(of: LZFSEDecoder.Magic.end.littleEndian, toByteOffset: 8 &+ count, as: UInt32.self)
        return count &+ 12
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension LZFSEEncoder: @unchecked Sendable {}

/// LZFSE's match search: the reference's `lzfse_encode_base` and `lzfse_encode_finish` (Compression's
/// `lzfseEncodeBase` and `lzfseEncodeFinish` are the same but for the literal backlog).
enum LZFSEFrontEnd {
    static var maximumDistance: Int { 262_139 }
    /// Longer matches are cut (the reference's `LZFSE_ENCODE_MAX_MATCH_LENGTH`, 100 times the longest M value).
    static var maximumMatchLength: Int { 235_900 }
    /// A match this long is written at once.
    static var goodMatchLength: Int { 40 }

    /// Pending literals past which some are written though no match comes: 3 × 315 in Compression
    /// (`lzfseEncodeBase` compares with 946), 8 × 315 in the reference.
    @inline(__always)
    static func literalBacklog(_ parse: LZFSEEncoder.Parse) -> Int {
        parse == .compression ? 3 &* LZFSEBlocks.maximumL : 8 &* LZFSEBlocks.maximumL
    }

    /// The 4-byte multiplicative hash of the reference (`hashX`).
    @inline(__always)
    static func hash(_ value: UInt32) -> Int {
        Int(truncatingIfNeeded: (value &* 2_654_435_761) &>> 18)
    }

    /// Encodes `count` bytes (4,096 or more) as LZFSE blocks and the end marker.
    ///
    /// - Parameter literalBacklog: ``literalBacklog(_:)``'s, for the parse.
    /// - Returns: The bytes written.
    /// - Throws: ``BytesError/insufficientCapacity`` if they don't fit in `capacity` bytes.
    @inline(never)
    static func encode(
        _ src: UnsafeRawPointer, count: Int, output: UnsafeMutableRawPointer, capacity: Int,
        table: UnsafeMutableRawPointer, bias: inout Int, workspace: UnsafeMutableRawPointer, literalBacklog: Int
    ) throws(BytesError) -> Int {
        // Unsafe: loads from the input and table lines. Safe: positions searched end 8 bytes before the input's
        // end, and matches extend no further than its end or back before its start; table lines are `hash(_:)`
        // (below `LZMatchTable.lines`) times 32 bytes into the table.
        var blocks = unsafe LZFSEBlocks(src, count: count, output: output, capacity: capacity, workspace: workspace)
        var pendingPosition = 0
        var pendingReference = 0
        var pendingLength = 0
        let encodeEnd = count &- 8
        var position = 0
        var bias32 = Int32(truncatingIfNeeded: bias)
        while position < encodeEnd {
            let segmentEnd = min(encodeEnd, LZMatchTable.positionLimit &- bias)
            if segmentEnd <= position {
                unsafe LZMatchTable.rebase(table, position: position, bias: &bias)
                bias32 = Int32(truncatingIfNeeded: bias)
                continue
            }
            let farthest = SIMD4<UInt32>(repeating: UInt32(maximumDistance))
            while position < segmentEnd {
                let literalStart = blocks.literalStart
                if position < literalStart {
                    // Inside a written match: only the table is updated.
                    let stop = min(literalStart, segmentEnd)
                    repeat {
                        let value = UInt32(littleEndian: unsafe src.loadUnaligned(fromByteOffset: position, as: UInt32.self))
                        _ = unsafe LZMatchTable.insert(table + hash(value) &<< 5, position: Int32(truncatingIfNeeded: position) &+ bias32, value: value)
                        position &+= 1
                    } while position < stop
                    continue
                }
                let value = UInt32(littleEndian: unsafe src.loadUnaligned(fromByteOffset: position, as: UInt32.self))
                let position32 = Int32(truncatingIfNeeded: position) &+ bias32
                let (stored, values) = unsafe LZMatchTable.insert(table + hash(value) &<< 5, position: position32, value: value)
                // Candidates: the same 4 bytes, close enough. (Stored positions are never above the current one.)
                let distances = SIMD4<UInt32>(truncatingIfNeeded: SIMD4<Int32>(repeating: position32) &- stored)
                let usable = (values .== SIMD4(repeating: value)) .& (distances .<= farthest)
                var lanes = LZMatchTable.laneBits(usable)
                var incomingLength = 0
                var incomingReference = 0
                if lanes != 0 {
                    // As the reference: 8-byte steps from 4 while the length is below `maxLength`, so a match stops
                    // at the first step boundary at or past it.
                    let maxLength = count &- position &- 8
                    let limit = position &+ 4 &+ (max(maxLength &- 4, 0) &+ 7) & ~7
                    repeat {
                        let lane = lanes.trailingZeroBitCount &>> 4
                        lanes &= lanes &- 1
                        let distance = Int(distances[lane])
                        let end = unsafe LZMatchTable.extendWide(src, from: position &+ 4, distance: distance, limit: limit, count: count)
                        if end &- position > incomingLength {
                            incomingLength = end &- position
                            incomingReference = position &- distance
                        }
                    } while lanes != 0
                }
                // What to write, if anything: one call site, so that the back end's state stays in registers.
                var emitPosition = 0
                var emitReference = 0
                var emitLength = -1
                if incomingLength == 0 {
                    // Keep literals from piling up past a block's worth when no match comes.
                    if position &- literalStart > literalBacklog {
                        if pendingLength > 0 {
                            (emitPosition, emitReference, emitLength) = (pendingPosition, pendingReference, pendingLength)
                            pendingLength = 0
                        } else {
                            // Literals alone: a match of length 0 at distance 1.
                            emitPosition = literalStart &+ LZFSEBlocks.maximumL
                            (emitReference, emitLength) = (emitPosition &- 1, 0)
                        }
                    }
                } else {
                    incomingLength = min(incomingLength, maximumMatchLength)
                    // Extend back over pending literals.
                    var incomingPosition = position
                    while unsafe incomingPosition > literalStart && incomingReference > 0
                        && src.load(fromByteOffset: incomingReference &- 1, as: UInt8.self)
                            == src.load(fromByteOffset: incomingPosition &- 1, as: UInt8.self)
                    {
                        incomingPosition &-= 1
                        incomingReference &-= 1
                    }
                    incomingLength &+= position &- incomingPosition
                    if incomingLength >= goodMatchLength {
                        (emitPosition, emitReference, emitLength) = (incomingPosition, incomingReference, incomingLength)
                        pendingLength = 0
                    } else if pendingLength == 0 {
                        (pendingPosition, pendingReference, pendingLength) = (incomingPosition, incomingReference, incomingLength)
                    } else if pendingPosition &+ pendingLength <= incomingPosition {
                        // No overlap: write the pending match, keep the new one.
                        (emitPosition, emitReference, emitLength) = (pendingPosition, pendingReference, pendingLength)
                        (pendingPosition, pendingReference, pendingLength) = (incomingPosition, incomingReference, incomingLength)
                    } else {
                        // Overlapping: write the longer.
                        if incomingLength > pendingLength {
                            (emitPosition, emitReference, emitLength) = (incomingPosition, incomingReference, incomingLength)
                        } else {
                            (emitPosition, emitReference, emitLength) = (pendingPosition, pendingReference, pendingLength)
                        }
                        pendingLength = 0
                    }
                }
                if emitLength >= 0 {
                    try unsafe blocks.match(position: emitPosition, reference: emitReference, length: emitLength)
                }
                position &+= 1
            }
        }
        if pendingLength > 0 {
            try unsafe blocks.match(position: pendingPosition, reference: pendingReference, length: pendingLength)
        }
        if count &- blocks.literalStart > 0 {
            try unsafe blocks.literals(count &- blocks.literalStart)
        }
        try unsafe blocks.flush()
        return try unsafe blocks.end()
    }
}

/// LZFSE's back end: matches split into L, M, D triples (literal count, match length, distance) and their
/// literals collected for a block, the block written when it's full (the reference's `lzfse_push_lmd`,
/// `lzfse_push_match`, `lzfse_backend_match`).
@safe
struct LZFSEBlocks {
    static var maximumL: Int { 315 }
    static var maximumM: Int { 2359 }
    static var matchesPerBlock: Int { 10_000 }
    static var literalsPerBlock: Int { 40_000 }

    let src: UnsafeRawPointer
    let count: Int
    let workspace: UnsafeMutableRawPointer
    let literals: UnsafeMutablePointer<UInt8>
    let lValues: UnsafeMutablePointer<UInt32>
    let mValues: UnsafeMutablePointer<UInt32>
    let dValues: UnsafeMutablePointer<UInt32>
    /// The first input byte not yet in a triple.
    var literalStart = 0
    var matchCount = 0
    var literalCount = 0
    var output: UnsafeMutableRawPointer
    let start: UnsafeMutableRawPointer
    let outputEnd: UnsafeMutableRawPointer

    @unsafe @inline(__always)
    init(_ src: UnsafeRawPointer, count: Int, output: UnsafeMutableRawPointer, capacity: Int, workspace: UnsafeMutableRawPointer) {
        // Unsafe: pointers to the workspace's regions and the output's end.
        unsafe start = output
        unsafe self.src = src
        self.count = count
        unsafe self.workspace = workspace
        unsafe literals = (workspace + LZFSEEncoderWorkspace.literals).assumingMemoryBound(to: UInt8.self)
        unsafe lValues = (workspace + LZFSEEncoderWorkspace.lValues).assumingMemoryBound(to: UInt32.self)
        unsafe mValues = (workspace + LZFSEEncoderWorkspace.mValues).assumingMemoryBound(to: UInt32.self)
        unsafe dValues = (workspace + LZFSEEncoderWorkspace.dValues).assumingMemoryBound(to: UInt32.self)
        unsafe self.output = output
        unsafe outputEnd = output + capacity
    }

    /// Adds the match at `position` of `length` bytes from `reference` (0 for literals alone), with the literals
    /// before it: as triples, L split at 315 (with M 0) and M at 2,359. Writes the block first if they don't fit.
    ///
    /// `@inline(always)`: with `@inline(__always)` it stayed a call, which kept the back end's state in memory for
    /// the whole search loop.
    @unsafe @inline(always)
    mutating func match(position: Int, reference: Int, length: Int) throws(BytesError) {
        var l = position &- literalStart
        var m = length
        let distance = UInt32(truncatingIfNeeded: position &- reference)
        // The triples this takes: the reference checks each as it adds it and undoes them all if one doesn't
        // fit; the last is the one to check.
        let lSplits = l > Self.maximumL ? (l &- Self.maximumL &- 1) / Self.maximumL &+ 1 : 0
        let lLeft = l &- lSplits &* Self.maximumL
        let mSplits = m > Self.maximumM ? (m &- Self.maximumM &- 1) / Self.maximumM &+ 1 : 0
        let triples = lSplits &+ mSplits &+ (lLeft > 0 || m &- mSplits &* Self.maximumM > 0 ? 1 : 0)
        if unlikely(matchCount &+ triples &+ 8 > Self.matchesPerBlock || literalCount &+ l &+ 16 > Self.literalsPerBlock) {
            try unsafe flush()
        }
        if likely(lSplits == 0 && mSplits == 0) {
            unsafe push(l, UInt32(truncatingIfNeeded: m), distance)
            return
        }
        while l > Self.maximumL {
            // Distance 1, the most common: no match follows.
            unsafe push(Self.maximumL, 0, 1)
            l &-= Self.maximumL
        }
        while m > Self.maximumM {
            unsafe push(l, UInt32(Self.maximumM), distance)
            l = 0
            m &-= Self.maximumM
        }
        if l > 0 || m > 0 {
            unsafe push(l, UInt32(truncatingIfNeeded: m), distance)
        }
    }

    /// Adds `count` literals alone.
    @unsafe @inline(__always)
    mutating func literals(_ count: Int) throws(BytesError) {
        let position = literalStart &+ count
        try unsafe match(position: position, reference: position &- 1, length: 0)
    }

    /// Adds one triple and its `l` literals, moving `literalStart` past them and the match.
    @unsafe @inline(__always)
    mutating func push(_ l: Int, _ m: UInt32, _ d: UInt32) {
        // Unsafe: stores to the workspace's arrays and copies from the input. Safe: `match` checked that the
        // triple and its literals (plus 16 bytes of copy slack) fit in the block's buffers; literals are copied
        // 16 bytes at a time only while the input has 16 bytes past them.
        unsafe lValues[matchCount] = UInt32(truncatingIfNeeded: l)
        unsafe mValues[matchCount] = m
        unsafe dValues[matchCount] = d
        matchCount &+= 1
        if likely(literalStart &+ l &+ 16 <= count) {
            unsafe LZCopy.wild(literals + literalCount, src + literalStart, l)
        } else {
            unsafe LZCopy.exact(literals + literalCount, src + literalStart, l)
        }
        literalCount &+= l
        literalStart &+= l &+ Int(m)
    }

    /// Writes the block, if it has anything.
    @unsafe
    mutating func flush() throws(BytesError) {
        guard literalCount > 0 || matchCount > 0 else { return }
        unsafe output = try LZFSEBlockWriter.write(
            literalCount: literalCount, matchCount: matchCount, workspace: workspace, output: output, outputEnd: outputEnd
        )
        literalCount = 0
        matchCount = 0
    }

    /// Writes the end marker.
    ///
    /// - Returns: The bytes written in all.
    @unsafe
    mutating func end() throws(BytesError) -> Int {
        // Unsafe: a 4-byte store, checked to fit.
        guard unsafe outputEnd - output >= 4 else { throw .insufficientCapacity }
        unsafe output.storeBytes(of: LZFSEDecoder.Magic.end.littleEndian, as: UInt32.self)
        unsafe output += 4
        return unsafe output - start
    }
}

/// Writes an LZFSE block (`bvx2`) from the workspace's literals and triples: the reference's
/// `lzfse_encode_matches`.
enum LZFSEBlockWriter {
    /// The most a block takes: its header (32 bytes and up to 630 of frequencies), 10 bits per literal and 54 per
    /// triple (each stream with its 8 bytes of flush slack, and the triples' 8 bytes of padding).
    static func maximumSize(literalCount: Int, matchCount: Int) -> Int {
        662 &+ (literalCount &* 10 &+ 7) / 8 &+ (matchCount &* 54 &+ 7) / 8 &+ 40
    }

    /// Writes the block at `output`, directly if the worst case fits, otherwise in the workspace's block buffer and
    /// then copied if it fits.
    ///
    /// - Returns: The block's end in the output.
    /// - Throws: ``BytesError/insufficientCapacity`` if it doesn't fit before `outputEnd`.
    @inline(never)
    static func write(
        literalCount: Int, matchCount: Int, workspace: UnsafeMutableRawPointer,
        output: UnsafeMutableRawPointer, outputEnd: UnsafeMutableRawPointer
    ) throws(BytesError) -> UnsafeMutableRawPointer {
        // Unsafe: the workspace's regions, and the output. Safe: the block is written where its worst case fits:
        // the output, or the workspace's block buffer (sized for a full block), then copied after a check.
        let literals = unsafe (workspace + LZFSEEncoderWorkspace.literals).assumingMemoryBound(to: UInt8.self)
        let lValues = unsafe (workspace + LZFSEEncoderWorkspace.lValues).assumingMemoryBound(to: UInt32.self)
        let mValues = unsafe (workspace + LZFSEEncoderWorkspace.mValues).assumingMemoryBound(to: UInt32.self)
        let dValues = unsafe (workspace + LZFSEEncoderWorkspace.dValues).assumingMemoryBound(to: UInt32.self)
        let counts = unsafe (workspace + LZFSEEncoderWorkspace.counts).assumingMemoryBound(to: UInt32.self)
        let frequencies = unsafe (workspace + LZFSEEncoderWorkspace.frequencies).assumingMemoryBound(to: UInt16.self)
        let encoders = unsafe (workspace + LZFSEEncoderWorkspace.encoders).assumingMemoryBound(to: LZFSESymbolEncoder.self)

        // 4 interleaved literal streams: a multiple of 4 literals, padded with zeros (the buffer has slack).
        var paddedCount = literalCount
        while paddedCount & 3 != 0 {
            unsafe literals[paddedCount] = 0
            paddedCount &+= 1
        }

        // Distances equal to the previous one (within the block) as 0.
        var previous: UInt32 = 0
        for index in 0..<matchCount {
            let distance = unsafe dValues[index]
            if distance == previous {
                unsafe dValues[index] = 0
            } else {
                previous = distance
            }
        }

        // Symbol counts: L, M, D, then literals, as the header orders the frequencies.
        unsafe counts.update(repeating: 0, count: 360)
        var rawCount = 0
        for index in 0..<matchCount {
            let l = Int(unsafe lValues[index])
            let m = Int(unsafe mValues[index])
            rawCount &+= l &+ m
            unsafe counts[LZFSECodes.l(l).symbol] &+= 1
            unsafe counts[20 &+ LZFSECodes.m(m).symbol] &+= 1
            unsafe counts[40 &+ LZFSECodes.d(Int(dValues[index])).symbol] &+= 1
        }
        unsafe countLiterals(literals, paddedCount, into: counts + 104)

        unsafe LZFSEFSE.normalize(states: 64, symbols: 20, counts: counts, into: frequencies)
        unsafe LZFSEFSE.normalize(states: 64, symbols: 20, counts: counts + 20, into: frequencies + 20)
        unsafe LZFSEFSE.normalize(states: 256, symbols: 64, counts: counts + 40, into: frequencies + 40)
        unsafe LZFSEFSE.normalize(states: 1024, symbols: 256, counts: counts + 104, into: frequencies + 104)
        unsafe LZFSEFSE.buildEncoders(states: 64, symbols: 20, frequencies: frequencies, into: encoders)
        unsafe LZFSEFSE.buildEncoders(states: 64, symbols: 20, frequencies: frequencies + 20, into: encoders + 20)
        unsafe LZFSEFSE.buildEncoders(states: 256, symbols: 64, frequencies: frequencies + 40, into: encoders + 40)
        unsafe LZFSEFSE.buildEncoders(states: 1024, symbols: 256, frequencies: frequencies + 104, into: encoders + 104)

        let worst = maximumSize(literalCount: paddedCount, matchCount: matchCount)
        let direct = unsafe worst <= outputEnd - output
        let block = unsafe direct ? output : workspace + LZFSEEncoderWorkspace.block

        // The header: 32 bytes of fields, then the frequencies in a fixed prefix code, low bits first.
        let headerSize = unsafe writeFrequencies(frequencies, to: block + 32)
        var stream = unsafe block + headerSize

        // Literals, last first so that they decode first to last.
        var bits = LZFSEOutBits()
        var states: (Int, Int, Int, Int) = (0, 0, 0, 0)
        let literalEncoders = unsafe UnsafePointer(encoders + 104)
        var index = paddedCount
        // Where the last group of literals started, then the last triple: Compression's room checks (below).
        var lastLiterals = unsafe stream
        while index > 0 {
            unsafe lastLiterals = stream
            index &-= 4
            unsafe LZFSEFSE.encode(&states.3, Int(literals[index &+ 3]), literalEncoders, &bits)
            unsafe LZFSEFSE.encode(&states.2, Int(literals[index &+ 2]), literalEncoders, &bits)
            unsafe LZFSEFSE.encode(&states.1, Int(literals[index &+ 1]), literalEncoders, &bits)
            unsafe LZFSEFSE.encode(&states.0, Int(literals[index]), literalEncoders, &bits)
            unsafe bits.flush(&stream)
        }
        unsafe bits.finish(&stream)
        let literalBits = bits.count
        let literalPayload = unsafe stream - (block + headerSize)

        // Triples, last first, after 8 bytes of padding: D, M, L, each its extra bits then its symbol's state.
        let lmdStart = unsafe stream
        unsafe stream.storeBytes(of: UInt64(0), as: UInt64.self)
        unsafe stream += 8
        bits = LZFSEOutBits()
        var lState = 0
        var mState = 0
        var dState = 0
        let lEncoders = unsafe UnsafePointer(encoders)
        let mEncoders = unsafe UnsafePointer(encoders + 20)
        let dEncoders = unsafe UnsafePointer(encoders + 40)
        index = matchCount
        var lastTriple = unsafe stream
        while index > 0 {
            unsafe lastTriple = stream
            index &-= 1
            let d = LZFSECodes.d(Int(unsafe dValues[index]))
            bits.push(d.extraBits, count: d.extraCount)
            unsafe LZFSEFSE.encode(&dState, d.symbol, dEncoders, &bits)
            let m = LZFSECodes.m(Int(unsafe mValues[index]))
            bits.push(m.extraBits, count: m.extraCount)
            unsafe LZFSEFSE.encode(&mState, m.symbol, mEncoders, &bits)
            let l = LZFSECodes.l(Int(unsafe lValues[index]))
            bits.push(l.extraBits, count: l.extraCount)
            unsafe LZFSEFSE.encode(&lState, l.symbol, lEncoders, &bits)
            unsafe bits.flush(&stream)
        }
        unsafe bits.finish(&stream)
        let lmdBits = bits.count
        let lmdPayload = unsafe stream - lmdStart

        // The header's fields.
        let v0 = UInt64(paddedCount) | UInt64(literalPayload) &<< 20 | UInt64(matchCount) &<< 40 | UInt64(7 &+ literalBits) &<< 60
        let v1 = UInt64(states.0) | UInt64(states.1) &<< 10 | UInt64(states.2) &<< 20 | UInt64(states.3) &<< 30
            | UInt64(lmdPayload) &<< 40 | UInt64(7 &+ lmdBits) &<< 60
        let v2 = UInt64(headerSize) | UInt64(lState) &<< 32 | UInt64(mState) &<< 42 | UInt64(dState) &<< 52
        unsafe block.storeBytes(of: LZFSEDecoder.Magic.lzfseV2.littleEndian, as: UInt32.self)
        unsafe block.storeBytes(of: UInt32(truncatingIfNeeded: rawCount).littleEndian, toByteOffset: 4, as: UInt32.self)
        unsafe block.storeBytes(of: v0.littleEndian, toByteOffset: 8, as: UInt64.self)
        unsafe block.storeBytes(of: v1.littleEndian, toByteOffset: 16, as: UInt64.self)
        unsafe block.storeBytes(of: v2.littleEndian, toByteOffset: 24, as: UInt64.self)

        let size = unsafe stream - block
        // Compression's (and the reference's) room checks, at the offsets in the block they make them: a whole
        // `lzfse_compressed_block_header_v2` (752 bytes) at the block's start, 16 bytes before each group of 4
        // literals and each triple, and 8 for the triples' padding. Each position only grows, so the last of each
        // kind decides. (Where they fail, the stream is stored if that fits, as Compression stores it.)
        let room = unsafe outputEnd - output
        let checked = max(
            752,
            paddedCount > 0 ? unsafe lastLiterals - block &+ 16 : 0,
            unsafe lmdStart - block &+ 8,
            matchCount > 0 ? unsafe lastTriple - block &+ 16 : 0,
            size
        )
        guard checked <= room else { throw .insufficientCapacity }
        if !direct {
            unsafe LZCopy.exact(output, block, size)
        }
        return unsafe output + size
    }

    /// Adds each literal's count to `counts`.
    @unsafe @inline(__always)
    static func countLiterals(_ literals: UnsafePointer<UInt8>, _ count: Int, into counts: UnsafeMutablePointer<UInt32>) {
        // Unsafe: reads below `count`, and 256 counts.
        for index in 0..<count {
            unsafe counts[Int(literals[index])] &+= 1
        }
    }

    /// Writes the 360 frequencies in `bvx2`'s prefix code (as ``LZFSEBlockHeader`` reads them), low bits first.
    ///
    /// - Returns: The header's size: 32 bytes and the frequencies' bytes.
    @unsafe
    static func writeFrequencies(_ frequencies: UnsafePointer<UInt16>, to destination: UnsafeMutableRawPointer) -> Int {
        // Unsafe: byte stores, at most 630 (360 codes of up to 14 bits).
        var accumulator: UInt32 = 0
        var accumulated = 0
        var written = 0
        for index in 0..<360 {
            let value = Int(unsafe frequencies[index])
            let (code, length): (Int, Int)
            switch value {
            case 0: (code, length) = (0, 2)
            case 1: (code, length) = (2, 2)
            case 2: (code, length) = (1, 3)
            case 3: (code, length) = (5, 3)
            case 4...7: (code, length) = (3 | (value &- 4) &<< 3, 5)
            case 8...23: (code, length) = (7 | (value &- 8) &<< 4, 8)
            default: (code, length) = (15 | (value &- 24) &<< 4, 14)
            }
            accumulator |= UInt32(truncatingIfNeeded: code) &<< UInt32(accumulated)
            accumulated &+= length
            while accumulated >= 8 {
                unsafe destination.storeBytes(of: UInt8(truncatingIfNeeded: accumulator), toByteOffset: written, as: UInt8.self)
                accumulator &>>= 8
                accumulated &-= 8
                written &+= 1
            }
        }
        if accumulated > 0 {
            unsafe destination.storeBytes(of: UInt8(truncatingIfNeeded: accumulator), toByteOffset: written, as: UInt8.self)
            written &+= 1
        }
        return 32 &+ written
    }
}

/// A forward bitstream for FSE coding: bits accumulated from the low end, whole bytes written out by flushes
/// (the reference's 64-bit `fse_out_stream`). The decoder reads it from the end back.
struct LZFSEOutBits {
    var bits: UInt64 = 0
    /// Bits held; after ``finish(_:)``, minus the padding bits (0 through -7).
    var count = 0

    @inline(__always)
    mutating func push(_ value: UInt64, count width: Int) {
        bits |= value &<< UInt64(truncatingIfNeeded: count)
        count &+= width
    }

    /// Writes the whole bytes held. Stores 8 bytes: the caller leaves room.
    @unsafe @inline(__always)
    mutating func flush(_ stream: inout UnsafeMutableRawPointer) {
        // Unsafe: an 8-byte store; the block's worst case leaves 8 bytes of slack.
        let whole = count & ~7
        unsafe stream.storeBytes(of: bits.littleEndian, as: UInt64.self)
        unsafe stream += whole &>> 3
        // At most 56: pushes between flushes total 54 bits or fewer, onto 7 left.
        bits &>>= UInt64(truncatingIfNeeded: whole)
        count &-= whole
    }

    /// Writes the last bits, padded with zeros to a byte.
    @unsafe @inline(__always)
    mutating func finish(_ stream: inout UnsafeMutableRawPointer) {
        // Unsafe: as `flush`.
        let rounded = (count &+ 7) & ~7
        unsafe stream.storeBytes(of: bits.littleEndian, as: UInt64.self)
        unsafe stream += rounded &>> 3
        bits = 0
        count &-= rounded
    }
}

/// One symbol's FSE encoding entry (the reference's `fse_encoder_entry`): states at or above `s0` write `k` bits
/// and move by `delta0`; those below write `k - 1` and move by `delta1`.
struct LZFSESymbolEncoder {
    var s0: Int16
    var k: Int16
    var delta0: Int16
    var delta1: Int16
}

/// FSE table normalization and encoding, as the reference's `lzfse_fse.c`.
enum LZFSEFSE {
    /// Scales `symbols` counts to frequencies summing to `states` (a power of 2): each rounded to nearest, at
    /// least 1 for a symbol that occurs; the difference given to (or, if small, taken from) the most frequent
    /// symbol, or else taken from all in steps.
    @unsafe
    static func normalize(states: Int, symbols: Int, counts: UnsafePointer<UInt32>, into frequencies: UnsafeMutablePointer<UInt16>) {
        // Unsafe: `symbols` counts read and frequencies written.
        var total: UInt32 = 0
        for symbol in 0..<symbols { total &+= unsafe counts[symbol] }
        let step: UInt32 = total == 0 ? 0 : (1 << 31) / total
        let shift = UInt32(UInt32(states).leadingZeroBitCount &- 1)
        var remaining = states
        var maxFrequency = 0
        var maxSymbol = 0
        for symbol in 0..<symbols {
            let count = unsafe counts[symbol]
            var frequency = Int(((count &* step) &>> shift &+ 1) &>> 1)
            if frequency == 0 && count != 0 { frequency = 1 }
            unsafe frequencies[symbol] = UInt16(truncatingIfNeeded: frequency)
            remaining &-= frequency
            if frequency > maxFrequency {
                maxFrequency = frequency
                maxSymbol = symbol
            }
        }
        if -remaining < maxFrequency &>> 2 {
            unsafe frequencies[maxSymbol] = UInt16(truncatingIfNeeded: Int(frequencies[maxSymbol]) &+ remaining)
        } else {
            var overrun = -remaining
            var shift = 3
            while overrun != 0 && shift >= 0 {
                for symbol in 0..<symbols {
                    let frequency = Int(unsafe frequencies[symbol])
                    if frequency > 1 {
                        let taken = min((frequency &- 1) &>> shift, overrun)
                        unsafe frequencies[symbol] = UInt16(truncatingIfNeeded: frequency &- taken)
                        overrun &-= taken
                        if overrun == 0 { break }
                    }
                }
                shift &-= 1
            }
        }
    }

    /// Fills the encoding entries of the symbols with nonzero frequencies (the reference's
    /// `fse_init_encoder_table`).
    @unsafe
    static func buildEncoders(states: Int, symbols: Int, frequencies: UnsafePointer<UInt16>, into table: UnsafeMutablePointer<LZFSESymbolEncoder>) {
        // Unsafe: `symbols` frequencies read and entries written.
        var offset = 0
        let leading = UInt32(states).leadingZeroBitCount
        for symbol in 0..<symbols {
            let frequency = Int(unsafe frequencies[symbol])
            if frequency == 0 { continue }
            let k = UInt32(frequency).leadingZeroBitCount &- leading
            // With `k` 0 (one symbol has every state), every state is at or above `s0`: `delta1` is unused.
            let delta1 = k > 0 ? offset &- frequency &+ states &>> (k &- 1) : 0
            unsafe table[symbol] = LZFSESymbolEncoder(
                s0: Int16(truncatingIfNeeded: frequency &<< k &- states), k: Int16(truncatingIfNeeded: k),
                delta0: Int16(truncatingIfNeeded: offset &- frequency &+ states &>> k), delta1: Int16(truncatingIfNeeded: delta1)
            )
            offset &+= frequency
        }
    }

    /// Encodes `symbol`: writes the low bits of `state` and moves it (the reference's `fse_encode`).
    @unsafe @inline(__always)
    static func encode(_ state: inout Int, _ symbol: Int, _ table: UnsafePointer<LZFSESymbolEncoder>, _ bits: inout LZFSEOutBits) {
        // Unsafe: a table read; the symbol occurs, so its entry was built.
        let entry = unsafe table[symbol]
        let high = state >= Int(entry.s0)
        let count = Int(entry.k) &- (high ? 0 : 1)
        let delta = Int(high ? entry.delta0 : entry.delta1)
        bits.push(UInt64(truncatingIfNeeded: state) & (1 &<< UInt64(truncatingIfNeeded: count) &- 1), count: count)
        state = delta &+ state &>> count
    }
}

/// LZFSE's L, M, and D values as symbols and extra bits (the reference's `l_base_from_value` and its tables).
enum LZFSECodes {
    struct Code {
        var symbol: Int
        var extraBits: UInt64
        var extraCount: Int
    }

    /// L: 0–15 as themselves, then 16 + 2 bits, 20 + 3, 28 + 5, 60 + 8 (up to 315).
    @inline(__always)
    static func l(_ value: Int) -> Code {
        if value < 16 { return Code(symbol: value, extraBits: 0, extraCount: 0) }
        let (symbol, base, count) = value < 20 ? (16, 16, 2) : value < 28 ? (17, 20, 3) : value < 60 ? (18, 28, 5) : (19, 60, 8)
        return Code(symbol: symbol, extraBits: UInt64(value &- base), extraCount: count)
    }

    /// M: 0–15 as themselves, then 16 + 3 bits, 24 + 5, 56 + 8, 312 + 11 (up to 2,359).
    @inline(__always)
    static func m(_ value: Int) -> Code {
        if value < 16 { return Code(symbol: value, extraBits: 0, extraCount: 0) }
        let (symbol, base, count) = value < 24 ? (16, 16, 3) : value < 56 ? (17, 24, 5) : value < 312 ? (18, 56, 8) : (19, 312, 11)
        return Code(symbol: symbol, extraBits: UInt64(value &- base), extraCount: count)
    }

    /// D: symbol `4k + j` covers `4(2^k - 1) + j 2^k` with `k` extra bits (0 for the previous distance; up to
    /// 262,139).
    @inline(__always)
    static func d(_ value: Int) -> Code {
        // `value + 4` is in `[2^(k+2), 2^(k+3))`.
        let k = (Int.bitWidth &- 3) &- (value &+ 4).leadingZeroBitCount
        let j = (value &+ 4 &- 1 &<< (k &+ 2)) &>> k
        let base = 4 &* (1 &<< k &- 1) &+ j &<< k
        return Code(symbol: 4 &* k &+ j, extraBits: UInt64(truncatingIfNeeded: value &- base), extraCount: k)
    }
}

/// The LZFSE encoder's buffers, one allocation made once: a block's literals and triples, the symbol counts,
/// frequencies, and encoding entries, and a buffer for a block that might not fit in the output.
@safe @usableFromInline
struct LZFSEEncoderWorkspace: ~Copyable {
    static var literals: Int { 0 } // 40,000 literals, 4 of padding, and copies' slack
    static var lValues: Int { 40_064 } // 10,000 UInt32
    static var mValues: Int { 80_064 }
    static var dValues: Int { 120_064 }
    static var counts: Int { 160_064 } // 360 UInt32
    static var frequencies: Int { 161_504 } // 360 UInt16
    static var encoders: Int { 162_240 } // 360 8-byte entries
    static var block: Int { 165_120 } // a full block's worst case
    static var size: Int { block &+ LZFSEBlockWriter.maximumSize(literalCount: 40_000, matchCount: 10_000) &+ 64 }

    /// Zeroed: zeros keep the literal buffer's slack defined for the wild copies that read it.
    let memory = CodecWorkspace(byteCount: size)

    // Unsafe: the allocation's address. Safe: valid while the workspace (which owns it) lives.
    var base: UnsafeMutableRawPointer { unsafe memory.base }
}
