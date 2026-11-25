public import Bytes

/// An LZVN encoder: Apple's byte-oriented LZ77 format (see ``LZVNDecoder``), as LZFSE writes for small inputs
/// (`bvxn` blocks) and Apple Encrypted Archives hold in raw segments.
///
/// ```swift
/// var encoder = LZVNEncoder()                                   // allocates its 512 KB table once
/// let written = try encoder.compressAll(input, into: &output)  // opcodes, then the end-of-stream opcode
/// ```
///
/// By default the stream is the one Apple's Compression writes for raw LZVN (`compression_encode_buffer` with
/// algorithm 0x900, which APFS `decmpfs` type 8 resource forks and `bvxn` blocks hold), byte for byte, and it fails
/// where Compression fails: Compression's encoder is the lzfse reference encoder's (github.com/lzfse/lzfse,
/// `lzvn_encode_buffer`) with another hash, so ``Parse/reference`` writes the reference's streams instead.
///
/// The parse: a hash of 3 bytes picks a line of the 4 latest positions with that hash; each position tries them
/// and the previous match's distance, extending matches forward and back over pending literals; a match is held
/// until the next one shows whether the two overlap, and the better is kept. Distances reach back 65,535 bytes.
///
/// Room is checked as Compression checks it, so a stream needs more room than its size: each literal must leave 9
/// or 10 bytes free beyond the 8 the end-of-stream opcode takes, each match 1 byte. Where Compression differs:
/// - Under 8 bytes, Compression fails (returns 0) for any room; this writes the bytes as a literal, as the reference
///   does (9 bytes more than the input, so a caller storing what doesn't shrink decides as with Compression).
/// - From 2 GiB, Compression's (and the reference's) 32-bit table positions wrap, and it stops finding matches
///   through the table; this encoder rebases its table and keeps finding them, so the streams differ (each valid).
///   Over 4 GiB − 1 bytes, Compression fails.
///
/// Encoding allocates nothing after initialization. The table isn't cleared between inputs: positions are stored
/// with a bias that grows from one input to the next, so the last input's entries read as the initial ones.
@safe
package struct LZVNEncoder: ~Copyable {
    /// Whose parse an encoder reproduces, byte for byte.
    package enum Parse: Sendable, Hashable {
        /// Apple's Compression's (`compression_encode_buffer` with algorithm 0x900 for raw LZVN, and the `bvxn`
        /// blocks of `COMPRESSION_LZFSE`).
        case compression
        /// The open lzfse reference encoder's (github.com/lzfse/lzfse at e634ca5).
        case reference
    }

    var table = LZMatchTable()
    /// Whose streams this encoder writes.
    package let parse: Parse

    /// Creates an encoder, allocating its match table (512 KB).
    ///
    /// - Parameter parse: Whose streams to write: Compression's by default.
    package init(parse: Parse = .compression) {
        self.parse = parse
    }

    /// An upper bound on the room encoding `byteCount` bytes needs, end-of-stream opcode included.
    ///
    /// - Parameter byteCount: The input's size.
    /// - Returns: Room that always suffices.
    package static func maximumCompressedSize(forByteCount byteCount: Int) -> Int {
        // A literal of 4 or more bytes costs 1 byte more (2 per 271 bytes); a match, no more than its length; and
        // the room checks keep up to 18 bytes free at the end.
        byteCount &+ byteCount / 4 &+ 32
    }

    /// Encodes `input` as a raw LZVN stream, ending with the end-of-stream opcode, appending it to `output`.
    ///
    /// Every call starts a new stream: an encoder used before writes what a fresh one would (the table's old entries
    /// read as empty), keeping its memory. ``maximumCompressedSize(forByteCount:)`` bytes of free capacity are always
    /// enough.
    ///
    /// - Parameters:
    ///   - input: All the data.
    ///   - output: Where to append the stream (its count says how much was appended).
    /// - Throws: ``BytesError/insufficientCapacity`` where Compression (or the reference) fails for an output of
    ///   `output`'s free capacity; `output` is then unchanged, though its free capacity may have been overwritten.
    package mutating func compressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) {
        var bias = table.reserveBias(forByteCount: input.byteCount)
        let parse = parse
        _ = try unsafe LZBuffers.with(input, &output) { input, count, output, capacity throws(BytesError) -> (Int, Int) in
            let written = try unsafe Self.encode(
                input, count: count, output: output, capacity: capacity, table: &table.entries, bias: &bias, parse: parse
            )
            return (written, written)
        }
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension LZVNEncoder: @unchecked Sendable {}

/// A candidate match: `begin ..< end` repeats the bytes `distance` back. `gain` is its length less the bytes
/// its distance costs (1 at the previous distance, 2 below 0x600, 3 above), as the reference ranks them.
struct LZVNMatch {
    var begin: Int
    var end: Int
    var distance: Int
    var gain: Int

    /// No match: length 0.
    @inline(__always)
    static var none: Self { Self(begin: 0, end: 0, distance: 0, gain: 0) }

    @inline(__always)
    var length: Int { end &- begin }

    /// Takes `candidate` if it gains more, or as much and ends at least 2 bytes further.
    @inline(__always)
    mutating func update(_ candidate: Self) {
        if candidate.gain > gain || (candidate.gain == gain && candidate.end > end &+ 1) {
            self = candidate
        }
    }
}

extension LZVNEncoder {
    static var maximumDistance: Int { 0xFFFF }
    /// Pending literals past which some are written out, though no match is near.
    static var maximumLiteralBacklog: Int { 400 }

    /// The 3-byte hash: Compression's (Fibonacci hashing, the product's top 14 bits: `LZMatchTable.lines` is
    /// 2^14) or the reference's (`hash3i`).
    @inline(__always)
    static func hash(_ value: UInt32, compression: Bool) -> Int {
        if compression {
            return Int(truncatingIfNeeded: ((value & 0xFF_FFFF) &* 0x9E37_79B1) &>> 18)
        }
        return Int(truncatingIfNeeded: ((value & 0xFF_FFFF) &* (1 &+ 1 &<< 6 &+ 1 &<< 12)) &>> 12) & (LZMatchTable.lines &- 1)
    }

    /// Encodes `count` bytes at `src` into `output` with `parse`'s parse.
    @unsafe @inline(__always)
    static func encode(
        _ src: UnsafeRawPointer, count: Int, output: UnsafeMutableRawPointer, capacity: Int,
        table: inout LZMatchTable.Lines, bias: inout Int, parse: Parse
    ) throws(BytesError) -> Int {
        // Unsafe: as `encode(_:count:output:capacity:table:bias:compressionHash:)`.
        switch parse {
        case .compression:
            try unsafe encodeCompression(src, count: count, output: output, capacity: capacity, table: &table, bias: &bias)
        case .reference:
            try unsafe encodeReference(src, count: count, output: output, capacity: capacity, table: &table, bias: &bias)
        }
    }

    /// Compression's parse: a copy of the encoder with its hash.
    @unsafe @inline(never)
    static func encodeCompression(
        _ src: UnsafeRawPointer, count: Int, output: UnsafeMutableRawPointer, capacity: Int,
        table: inout LZMatchTable.Lines, bias: inout Int
    ) throws(BytesError) -> Int {
        // Unsafe: as `encode(_:count:output:capacity:table:bias:compressionHash:)`.
        try unsafe encode(src, count: count, output: output, capacity: capacity, table: &table, bias: &bias, compressionHash: true)
    }

    /// The reference's parse: a copy of the encoder with its hash.
    @unsafe @inline(never)
    static func encodeReference(
        _ src: UnsafeRawPointer, count: Int, output: UnsafeMutableRawPointer, capacity: Int,
        table: inout LZMatchTable.Lines, bias: inout Int
    ) throws(BytesError) -> Int {
        // Unsafe: as `encode(_:count:output:capacity:table:bias:compressionHash:)`.
        try unsafe encode(src, count: count, output: output, capacity: capacity, table: &table, bias: &bias, compressionHash: false)
    }

    /// Encodes `count` bytes at `src` into `output`, opcodes then the end-of-stream opcode.
    ///
    /// - Parameters:
    ///   - table: The match table, whose positions below `bias` are stale (from earlier inputs).
    ///   - bias: Added to positions stored in the table; lowered when the table is rebased for a long input.
    ///   - compressionHash: Compression's hash, or the reference's (a constant: each parse is its own copy).
    /// - Returns: The bytes written.
    /// - Throws: ``BytesError/insufficientCapacity`` where Compression's and the reference's room checks fail for
    ///   `capacity` bytes (every check is theirs, so the first that fails fails the stream, as theirs do: what's left
    ///   would be written as one literal, which needs more room still).
    @unsafe @inline(__always)
    static func encode(
        _ src: UnsafeRawPointer, count: Int, output: UnsafeMutableRawPointer, capacity: Int,
        table: inout LZMatchTable.Lines, bias: inout Int, compressionHash: Bool
    ) throws(BytesError) -> Int {
        // Unsafe: loads from the input, and stores to the output. Safe: positions searched end 8 bytes before the
        // input's end, and matches are extended no further than its end or back before its start; each emitted
        // sequence is checked to fit in the output first (`Emitter`), whose room excludes the last 8 bytes, then taken
        // by the end-of-stream opcode. (Table lines are checked: each hash is below `LZMatchTable.lines`.)
        // The lines as a local span, its count stated (see `LZMatchTable.insert`).
        var lines = table.mutableSpan
        precondition(lines.count == LZMatchTable.lines)
        guard capacity >= 8 else { throw .insufficientCapacity }
        var out = unsafe Emitter(output, capacity: capacity &- 8, input: src, inputEnd: src + count)
        var literalStart = 0
        if count >= 8 {
            let currentEnd = count &- 8
            let first = unsafe WordReads.load32(src, 0)
            var pending = LZVNMatch.none
            var previousDistance = 0
            var current = 0
            var bias32 = Int32(truncatingIfNeeded: bias)
            while current < currentEnd {
                // Stored positions stay below `Int32.max`: past that, the table is rebased.
                let segmentEnd = min(currentEnd, LZMatchTable.positionLimit &- bias)
                if segmentEnd <= current {
                    LZMatchTable.rebase(&lines, position: current, bias: &bias)
                    bias32 = Int32(truncatingIfNeeded: bias)
                    continue
                }
                // Entries below the input's bias are stale; after a rebase (past 1 GiB, where the reference's
                // initial entries are out of reach anyway) none are.
                let staleThreshold = SIMD4<Int32>(repeating: max(bias32, 0))
                let firstVector = SIMD4<UInt32>(repeating: first)
                while current < segmentEnd {
                    if current < literalStart {
                        // Inside a written match: only the table is updated.
                        let stop = min(literalStart, segmentEnd)
                        repeat {
                            let value = unsafe WordReads.load32(src, current)
                            _ = LZMatchTable.insert(
                                &lines, at: Self.hash(value, compression: compressionHash),
                                position: Int32(truncatingIfNeeded: current) &+ bias32, value: value
                            )
                            current &+= 1
                        } while current < stop
                        continue
                    }
                    let value = unsafe WordReads.load32(src, current)
                    let position32 = Int32(truncatingIfNeeded: current) &+ bias32
                    let (stored, values) = LZMatchTable.insert(
                        &lines, at: Self.hash(value, compression: compressionHash), position: position32, value: value
                    )
                    do {
                        // Stale entries are the reference's initial ones: position 0, and the input's first 4 bytes.
                        // Arithmetic, no masks: a comparison's mask used to select compiled a lane at a time,
                        // through the stack. (Stored positions are 0 or more, and the threshold too, so the
                        // difference doesn't overflow.)
                        let staleBits = SIMD4<UInt32>(truncatingIfNeeded: (stored &- staleThreshold) &>> 31)
                        let positions = stored &+ ((staleThreshold &- stored) & SIMD4<Int32>(truncatingIfNeeded: staleBits))
                        let candidates = values ^ ((values ^ firstVector) & staleBits)
                        let distances = SIMD4<UInt32>(truncatingIfNeeded: SIMD4<Int32>(repeating: position32) &- positions)
                        let differences = candidates ^ SIMD4(repeating: value)
                        // At least 3 bytes agree, at a distance of 1 through 65,535.
                        let usable = (differences & SIMD4(repeating: 0xFF_FFFF)) .== SIMD4<UInt32>.zero
                            .& ((distances &- SIMD4(repeating: 1)) .< SIMD4(repeating: UInt32(Self.maximumDistance)))
                        var lanes = LZMatchTable.laneBits(usable)
                        var incoming = LZVNMatch.none
                        while lanes != 0 {
                            let lane = lanes.trailingZeroBitCount &>> 4
                            lanes &= lanes &- 1
                            let distance = Int(distances[lane])
                            let candidate = unsafe Self.match(
                                src, count: count, literalStart: literalStart, at: current, distance: distance
                            )
                            incoming.update(candidate)
                        }
                        if previousDistance != 0 {
                            let other = unsafe WordReads.load32(src, current &- previousDistance)
                            let difference = value ^ other
                            if difference & 0xFF_FFFF == 0 {
                                var candidate = unsafe Self.match(
                                    src, count: count, literalStart: literalStart, at: current, distance: previousDistance
                                )
                                candidate.gain = candidate.length &- 1
                                incoming.update(candidate)
                            }
                        }

                        // What to write, if anything: one call site, so that the output's state stays in registers.
                        var emit = LZVNMatch.none
                        if incoming.length == 0 {
                            if current &- literalStart >= Self.maximumLiteralBacklog {
                                if pending.length != 0 {
                                    emit = pending
                                    pending = .none
                                } else {
                                    // Rare: a long literal alone.
                                    try unsafe out.longLiteral(from: literalStart)
                                    literalStart &+= 271
                                }
                            }
                        } else if pending.length == 0 {
                            pending = incoming
                        } else if pending.end <= incoming.begin {
                            // No overlap: write the pending match, keep the new one.
                            emit = pending
                            pending = incoming
                        } else {
                            // Overlapping: write the one that gains more.
                            emit = incoming.gain > pending.gain ? incoming : pending
                            pending = .none
                        }
                        if emit.length != 0 {
                            try unsafe out.match(emit, literalStart: literalStart, previousDistance: previousDistance)
                            previousDistance = emit.distance
                            literalStart = emit.end
                        }
                    }
                    current &+= 1
                }
            }
            // As the reference: a match still pending at the end is written as literals.
        }
        unsafe out.position = try unsafe Emitter.finalLiteral(out, from: literalStart, count: count &- literalStart)
        try unsafe out.endOfStream()
        return unsafe out.position - output
    }

    /// The match at `current` against `distance` back, whose first 3 bytes agree: extended forward as the
    /// reference does (its 4th byte, then 4 bytes at a time while all 4 agree and there are more than 4 bytes
    /// left, so it stops where the reference's does), and back over pending literals.
    @inline(__always)
    static func match(
        _ src: UnsafeRawPointer, count: Int, literalStart: Int, at current: Int, distance: Int
    ) -> LZVNMatch {
        // Unsafe: byte loads within the input. Safe: forward, below `count`; back, at `1` or more.
        // From the 4th byte: where it differs, the extension stops there at once, which is the reference's 3-byte
        // match. (Branching on whether 3 or 4 bytes agree mispredicted: dickens ran 13% more cycles.) The
        // reference's 4-byte steps from the 5th byte stop at the first step boundary at or past `count - 4`, which
        // is past the 4th byte: positions searched end 8 bytes before `count`.
        let limit = current &+ 4 &+ ((count &- 8 &- current &+ 3) & ~3)
        let end = unsafe LZMatchTable.extend(src, from: current &+ 3, distance: distance, limit: limit, count: count)
        var begin = current
        var reference = current &- distance
        while unsafe reference > 0 && begin > literalStart
            && src.load(fromByteOffset: begin &- 1, as: UInt8.self) == src.load(fromByteOffset: reference &- 1, as: UInt8.self) {
            begin &-= 1
            reference &-= 1
        }
        let length = end &- begin
        return LZVNMatch(begin: begin, end: end, distance: distance, gain: length &- (distance < 0x600 ? 2 : 3))
    }
}

/// Writes LZVN opcodes as Compression's and the reference's `emit` do, checking room first as they do: the fast
/// path copies literals 16 bytes at a time where there's slack past them in both buffers (more than their checks
/// ask for); otherwise their checks are made exactly and the bytes copied exactly.
@safe
struct Emitter {
    var position: UnsafeMutableRawPointer
    /// The output's end less the 8 bytes kept for the end-of-stream opcode (the encoders' `dst_end`): every check
    /// is against it.
    let end: UnsafeMutableRawPointer
    let input: UnsafeRawPointer
    let inputEnd: UnsafeRawPointer

    @unsafe @inline(__always)
    init(_ output: UnsafeMutableRawPointer, capacity: Int, input: UnsafeRawPointer, inputEnd: UnsafeRawPointer) {
        // Unsafe: the end of the output buffer.
        unsafe position = output
        unsafe end = output + capacity
        unsafe self.input = input
        unsafe self.inputEnd = inputEnd
    }

    /// A literal of `count` bytes at `start` (an input offset), then `match`, which starts where it ends.
    ///
    /// `@inline(always)`, with the exact path out of line: as a call, the output position lived in memory for the
    /// whole search loop.
    @unsafe @inline(always)
    mutating func match(_ match: LZVNMatch, literalStart start: Int, previousDistance: Int) throws(BytesError) {
        let literalCount = match.begin &- start
        let length = match.length
        // Unsafe: distances between pointers into the buffers.
        // Room for the literal and its opcodes (2 bytes per 271), up to 15 bytes of overrun, the match's opcode
        // and 4-byte literal store, and its continuations (2 bytes per 271): more than the 10 bytes Compression's
        // checks keep free after a literal's pieces and the 1 after a match.
        let need = literalCount &+ (literalCount &+ length) &>> 7 &+ 32
        if likely(unsafe need <= end - position && literalCount &+ 16 <= inputEnd - (input + start)) {
            unsafe write(literal: input + start, literalCount, length, match.distance, previousDistance, exact: false)
        } else {
            try unsafe matchExactly(literalCount, length, match.distance, previousDistance, literal: input + start)
        }
    }

    /// `match` near the ends of the buffers: Compression's room checks made exactly, its literal copied exactly.
    @unsafe @inline(never)
    mutating func matchExactly(_ literalCount: Int, _ length: Int, _ distance: Int, _ previousDistance: Int, literal: UnsafeRawPointer) throws(BytesError) {
        // Unsafe: a distance between pointers into the output, and stores checked to fit.
        let (literalSize, free) = Self.literalSize(literalCount, inline: 3)
        let size = Self.size(literalCount, length, distance, previousDistance)
        let room = unsafe end - position
        // Compression's checks (the reference's `emit`, then `lzvn_emit_match`): each piece of the literal leaves 9
        // or 10 bytes free, and the match at least 1.
        guard literalSize &+ free <= room && size < room else { throw .insufficientCapacity }
        unsafe write(literal: literal, literalCount, length, distance, previousDistance, exact: true)
    }

    /// 271 literal bytes at `start` (an input offset), with no match near: one 2-byte opcode and the bytes.
    /// (Out of line, the search loop ran 2–5% more instructions; and as a call to `literal(from:count:)` with
    /// Compression's checks, its state was reloaded after each: 12% more on random bytes.)
    @unsafe @inline(always)
    mutating func longLiteral(from start: Int) throws(BytesError) {
        // Unsafe: as `match`.
        let room = unsafe end - position
        // Compression checks 271 + 10 against the room before.
        guard room >= 282 else { throw .insufficientCapacity }
        let source = unsafe input + start
        unsafe position.storeBytes(of: UInt16(0xE0 | (271 - 16) << 8).littleEndian, as: UInt16.self)
        unsafe copy(position + 2, source, 271, exact: room < 2 + 271 + 16 || 271 + 16 > inputEnd - source)
        unsafe position += 2 + 271
    }

    /// The literal ending the input, after `emitter`'s output: out of line and static (taking the emitter's
    /// state and returning its new position), which kept the search loop's output position in registers (as a
    /// `mutating` call, or inlined, the loop ran 1–3% more instructions).
    ///
    /// - Returns: The output position after the literal.
    @unsafe @inline(never)
    static func finalLiteral(_ emitter: Emitter, from start: Int, count: Int) throws(BytesError) -> UnsafeMutableRawPointer {
        // Unsafe: as `literal(from:count:)`.
        var emitter = emitter
        try unsafe emitter.literal(from: start, count: count)
        return unsafe emitter.position
    }

    /// A literal alone: `count` bytes at `start` (an input offset).
    @unsafe @inline(__always)
    mutating func literal(from start: Int, count: Int) throws(BytesError) {
        // Unsafe: as `match`.
        var remaining = count
        var source = unsafe input + start
        let room = unsafe end - position
        // Compression's checks (the reference's `emit_literal`): each piece leaves 9 or 10 bytes free. An empty
        // literal writes nothing and isn't checked.
        let (size, free) = Self.literalSize(count, inline: 0)
        guard count == 0 || size &+ free <= room else { throw .insufficientCapacity }
        let exact = unsafe size &+ 16 > room || count &+ 16 > inputEnd - source
        while remaining > 15 {
            let chunk = min(remaining, 271)
            unsafe position.storeBytes(of: 0xE0, as: UInt8.self)
            unsafe position.storeBytes(of: UInt8(truncatingIfNeeded: chunk &- 16), toByteOffset: 1, as: UInt8.self)
            unsafe copy(position + 2, source, chunk, exact: exact)
            unsafe position += 2 &+ chunk
            unsafe source += chunk
            remaining &-= chunk
        }
        if remaining > 0 {
            unsafe position.storeBytes(of: UInt8(truncatingIfNeeded: 0xE0 &+ remaining), as: UInt8.self)
            unsafe copy(position + 1, source, remaining, exact: exact)
            unsafe position += 1 &+ remaining
        }
    }

    /// The end-of-stream opcode, 6, and 7 zero bytes, in the 8 bytes past `end` kept for it.
    @unsafe @inline(__always)
    mutating func endOfStream() throws(BytesError) {
        // Unsafe: an 8-byte store, checked to fit (it always does: every write before left `position` at or before
        // `end`).
        guard unsafe end - position >= 0 else { throw .insufficientCapacity }
        unsafe position.storeBytes(of: UInt64(6).littleEndian, as: UInt64.self)
        unsafe position += 8
    }

    @unsafe @inline(__always)
    func copy(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer, _ count: Int, exact: Bool) {
        // Unsafe: copies the callers checked (exact) or left 16 bytes of room past (wild).
        if exact {
            unsafe LZCopy.exact(destination, source, count)
        } else {
            unsafe LZCopy.wild(destination, source, count)
        }
    }

    /// The size of a literal's own opcodes and bytes: pieces of up to 271 bytes behind 2-byte opcodes while more
    /// than 15 bytes remain, then the rest behind a 1-byte opcode if more than `inline` remain (in a match, up to 3
    /// ride in its opcode). And the room Compression's checks keep free after it: 10 bytes after a 1-byte opcode's
    /// piece (it checks `L + 10` against the room before), 9 after a 2-byte one (`x + 10`, 1 byte more of opcode)
    /// or before a match with no literal pieces (`8`).
    @inline(__always)
    static func literalSize(_ count: Int, inline: Int) -> (size: Int, free: Int) {
        var remaining = count
        var size = 0
        while remaining > 15 {
            let chunk = min(remaining, 271)
            size &+= 2 &+ chunk
            remaining &-= chunk
        }
        if remaining > inline {
            return (size &+ 1 &+ remaining, 10)
        }
        return (size, 9)
    }

    /// The bytes `write` takes.
    static func size(_ literalCount: Int, _ length: Int, _ distance: Int, _ previousDistance: Int) -> Int {
        var length = length
        // What rides in the match's opcode.
        var literalCount = literalCount
        var size = literalSize(literalCount, inline: 3).size
        while literalCount > 15 {
            literalCount &-= min(literalCount, 271)
        }
        if literalCount > 3 { literalCount = 0 }
        let first = min(length, 10 &- 2 &* literalCount)
        length &-= first
        if distance == previousDistance {
            size &+= 1
        } else if distance < 2048 &- 2 &* 256 {
            size &+= 2
        } else {
            size &+= 3
            if !(distance >= 1 &<< 14 || length == 0 || first &+ length > 34) { length = 0 }
        }
        size &+= literalCount
        while length > 15 {
            length &-= min(length, 271)
            size &+= 2
        }
        if length > 0 { size &+= 1 }
        return size
    }

    /// Writes the literal and the match (the reference's `emit`). Literals of 4 or more bytes get their own
    /// opcodes; up to 3 ride in the match's. The match's opcode takes up to 10 bytes of it (fewer with literal
    /// bytes, as the reference), the rest follows at the previous distance.
    @unsafe @inline(__always)
    mutating func write(
        literal: UnsafeRawPointer, _ literalCount: Int, _ length: Int, _ distance: Int, _ previousDistance: Int, exact: Bool
    ) {
        // Unsafe: stores checked to fit by the callers, and literal loads within the input (a match of 3 or more
        // bytes follows the literal, so 4 bytes from a literal of up to 3 are in the input).
        var source = unsafe literal
        var literalCount = literalCount
        var length = length
        while literalCount > 15 {
            let chunk = min(literalCount, 271)
            unsafe position.storeBytes(of: 0xE0, as: UInt8.self)
            unsafe position.storeBytes(of: UInt8(truncatingIfNeeded: chunk &- 16), toByteOffset: 1, as: UInt8.self)
            unsafe copy(position + 2, source, chunk, exact: exact)
            unsafe position += 2 &+ chunk
            unsafe source += chunk
            literalCount &-= chunk
        }
        if literalCount > 3 {
            unsafe position.storeBytes(of: UInt8(truncatingIfNeeded: 0xE0 &+ literalCount), as: UInt8.self)
            unsafe copy(position + 1, source, literalCount, exact: exact)
            unsafe position += 1 &+ literalCount
            unsafe source += literalCount
            literalCount = 0
        }
        var first = min(length, 10 &- 2 &* literalCount)
        length &-= first
        first &-= 3
        let literalBytes = unsafe source.loadUnaligned(as: UInt32.self)
        var opcodeLength: Int
        if distance == previousDistance {
            if literalCount == 0 {
                unsafe position.storeBytes(of: UInt8(truncatingIfNeeded: 0xF0 &+ first &+ 3), as: UInt8.self)
            } else {
                unsafe position.storeBytes(of: UInt8(truncatingIfNeeded: literalCount &<< 6 &+ first &<< 3 &+ 6), as: UInt8.self)
            }
            opcodeLength = 1
        } else if distance < 2048 &- 2 &* 256 {
            // Small: LLMMMDDD DDDDDDDD.
            unsafe position.storeBytes(
                of: UInt16(truncatingIfNeeded: distance &>> 8 &+ literalCount &<< 6 &+ first &<< 3 | (distance & 0xFF) &<< 8).littleEndian,
                as: UInt16.self
            )
            opcodeLength = 2
        } else if distance >= 1 &<< 14 || length == 0 || first &+ 3 &+ length > 34 {
            // Large: LLMMM111 DDDDDDDD DDDDDDDD.
            unsafe position.storeBytes(of: UInt8(truncatingIfNeeded: literalCount &<< 6 &+ first &<< 3 &+ 7), as: UInt8.self)
            unsafe position.storeBytes(of: UInt16(truncatingIfNeeded: distance).littleEndian, toByteOffset: 1, as: UInt16.self)
            opcodeLength = 3
        } else {
            // Medium: 101LLMMM DDDDDDMM DDDDDDDD, the whole match.
            first &+= length
            length = 0
            unsafe position.storeBytes(of: UInt8(truncatingIfNeeded: 0xA0 &+ first &>> 2 &+ literalCount &<< 3), as: UInt8.self)
            unsafe position.storeBytes(of: UInt16(truncatingIfNeeded: distance &<< 2 | first & 3).littleEndian, toByteOffset: 1, as: UInt16.self)
            opcodeLength = 3
        }
        unsafe position += opcodeLength
        if exact {
            unsafe LZCopy.exact(position, source, literalCount)
        } else {
            unsafe position.storeBytes(of: literalBytes, as: UInt32.self)
        }
        unsafe position += literalCount
        while length > 15 {
            let chunk = min(length, 271)
            unsafe position.storeBytes(of: UInt16(truncatingIfNeeded: 0xF0 | (chunk &- 16) &<< 8).littleEndian, as: UInt16.self)
            unsafe position += 2
            length &-= chunk
        }
        if length > 0 {
            unsafe position.storeBytes(of: UInt8(truncatingIfNeeded: 0xF0 &+ length), as: UInt8.self)
            unsafe position += 1
        }
    }
}

/// The LZVN and LZFSE encoders' match table: 16,384 lines, each the 4 latest positions with its hash and the 4
/// bytes at each, newest first (the reference encoders' layout: positions, then values, 32 bytes a line).
///
/// Positions are stored plus a bias, as `Int32`. Each input's bias starts at least ``gap`` above every position
/// stored before, so an earlier input's entries are too far back to match (and LZVN's read as unused), and the
/// table needn't be cleared between inputs (512 KB, more than a 64 KiB input's encoding writes). It's cleared
/// when the bias runs high, and rebased within an input that runs past `Int32.max`.
// `@usableFromInline` exports the type's metadata, which clients destroying an encoder reference (as
// `ZstdWorkspace`).
@safe @usableFromInline
struct LZMatchTable: ~Copyable {
    /// A line: the 4 latest positions with its hash, newest first, and the 4 bytes at each.
    @usableFromInline // Exported for clients' destroys of the table, as the table's.
    struct Line: BitwiseCopyable {
        var positions: SIMD4<Int32>
        var values: SIMD4<UInt32>

        static var empty: Self { Self(positions: .zero, values: .zero) }
    }

    /// The lines, indexed by a hash: masked into the table (Bytes' `MaskedTable`), so a line can't be out of range.
    /// The encoders state its count once per call, so the optimizer knows the mask and drops it from Compression's
    /// hash (the product's top 14 bits) and the reference's (masked already).
    typealias Lines = MaskedTable<Line>

    static var lines: Int { 1 << 14 }
    /// More than any match distance (LZFSE's 262,139).
    static var gap: Int { 1 << 21 }
    /// The highest stored position, plus room.
    static var positionLimit: Int { Int(Int32.max) &- 64 }

    var entries = Lines(count: lines, repeating: .empty)
    /// The next input's bias.
    var nextBias = gap

    /// The bias for an input of `byteCount` bytes, clearing the table first if the bias ran high. The next input's
    /// is reserved before encoding, so that an encode that throws (or rebases, which only lowers its bias) leaves
    /// no entry the next input could take for its own.
    mutating func reserveBias(forByteCount byteCount: Int) -> Int {
        if nextBias > Self.positionLimit / 2 {
            entries.fill(.empty)
            nextBias = Self.gap
        }
        let bias = nextBias
        nextBias = bias &+ byteCount &+ Self.gap
        return bias
    }

    /// Lowers every stored position so that `position` (in the input) is stored as ``gap``, clamping at 0 (far
    /// out of reach either way), and lowers `bias` to match.
    static func rebase(_ lines: inout MutableSpan<Line>, position: Int, bias: inout Int) {
        let delta = position &+ bias &- gap
        let deltaVector = SIMD4<Int32>(repeating: Int32(truncatingIfNeeded: delta))
        for line in lines.indices {
            let positions = lines[line].positions &- deltaVector
            // Negative lanes to 0: clearing every bit where the sign is set.
            lines[line].positions = positions & ~(positions &>> 31)
        }
        bias &-= delta
    }

    /// Adds `position` and its 4 bytes, `value`, to the front of line `hash`, dropping the oldest entry.
    ///
    /// The encoders pass the table's lines as a span held in a local for the whole encode, its count stated: the
    /// index's check then folds (each hash is below ``lines``), and the base stays in a register. (Through the
    /// table's masked subscript, the table passed `inout`, the base was loaded again at every searched position,
    /// and LZFSE ran up to 1.2% more instructions.)
    ///
    /// - Returns: The line's positions and values before.
    @inline(__always)
    static func insert(_ lines: inout MutableSpan<Line>, at hash: Int, position: Int32, value: UInt32) -> (SIMD4<Int32>, SIMD4<UInt32>) {
        let line = lines[hash]
        let stored = line.positions
        let values = line.values
        // A rotation, then the new lane: `ext` and `ins`. (Building the vector from the new lane and three old
        // ones compiled to two `ext`s, a `movi`, and an `ins` each.)
        var newStored = SIMD4(stored[3], stored[0], stored[1], stored[2])
        newStored[0] = position
        var newValues = SIMD4(values[3], values[0], values[1], values[2])
        newValues[0] = value
        lines[hash] = Line(positions: newStored, values: newValues)
        return (stored, values)
    }

    /// A comparison's mask as lanes of all ones or zeros: its storage.
    @inline(__always)
    static func lanes(_ mask: SIMDMask<SIMD4<Int32>>) -> SIMD4<Int32> {
        mask._storage
    }

    /// The lanes `mask` sets, one bit each: lane `i` in bit `16i` (narrowed in one instruction, then masked, so
    /// that clearing the lowest set bit visits each lane once).
    @inline(__always)
    static func laneBits(_ mask: SIMDMask<SIMD4<Int32>>) -> UInt64 {
        let narrowed = SIMD4<UInt16>(truncatingIfNeeded: lanes(mask))
        return bitCast(narrowed, to: UInt64.self) & 0x0001_0001_0001_0001
    }

    /// The first position at or after `start` where the bytes there and `distance` back differ, or `limit` if
    /// there's none before it. 8 bytes at a time while 8 remain in the input, then a byte at a time.
    ///
    /// - Precondition: `start - distance >= 0`, `limit <= count`.
    @unsafe @inline(__always)
    static func extend(_ src: UnsafeRawPointer, from start: Int, distance: Int, limit: Int, count: Int) -> Int {
        // Unsafe: loads below `count`, at `start - distance` or later.
        var position = start
        while position &+ 8 <= count {
            let difference = unsafe src.loadUnaligned(fromByteOffset: position, as: UInt64.self)
                ^ src.loadUnaligned(fromByteOffset: position &- distance, as: UInt64.self)
            if difference != 0 {
                return min(position &+ UInt64(littleEndian: difference).trailingZeroBitCount &>> 3, limit)
            }
            position &+= 8
            if position >= limit { return limit }
        }
        while position < limit {
            if unsafe src.load(fromByteOffset: position, as: UInt8.self) != src.load(fromByteOffset: position &- distance, as: UInt8.self) {
                return position
            }
            position &+= 1
        }
        return limit
    }

    /// ``extend(_:from:distance:limit:count:)`` 16 bytes at a time after the first 8 (most matches are short).
    /// LZFSE's search ran 1–3% fewer instructions with it on Silesia; LZVN's, whose matches are shorter, 0.5–1.5% more.
    @unsafe @inline(__always)
    static func extendWide(_ src: UnsafeRawPointer, from start: Int, distance: Int, limit: Int, count: Int) -> Int {
        // Unsafe: loads below `count`, at `start - distance` or later.
        var position = start
        if position &+ 8 <= count {
            let difference = unsafe src.loadUnaligned(fromByteOffset: position, as: UInt64.self)
                ^ src.loadUnaligned(fromByteOffset: position &- distance, as: UInt64.self)
            if difference != 0 {
                return min(position &+ UInt64(littleEndian: difference).trailingZeroBitCount &>> 3, limit)
            }
            position &+= 8
            if position >= limit { return limit }
            while position &+ 16 <= count {
                let equal = unsafe src.loadUnaligned(fromByteOffset: position, as: SIMD16<UInt8>.self)
                    .== src.loadUnaligned(fromByteOffset: position &- distance, as: SIMD16<UInt8>.self)
                // Each lane 0xFF where equal; narrowed to 4 bits a lane and inverted, the first difference's.
                let lanes = equal.lanes(as: SIMD8<UInt16>.self)
                let differing = ~bitCast(SIMD8<UInt8>(truncatingIfNeeded: lanes &>> 4), to: UInt64.self)
                if differing != 0 {
                    return min(position &+ UInt64(littleEndian: differing).trailingZeroBitCount &>> 2, limit)
                }
                position &+= 16
                if position >= limit { return limit }
            }
        }
        while position &+ 8 <= count {
            let difference = unsafe src.loadUnaligned(fromByteOffset: position, as: UInt64.self)
                ^ src.loadUnaligned(fromByteOffset: position &- distance, as: UInt64.self)
            if difference != 0 {
                return min(position &+ UInt64(littleEndian: difference).trailingZeroBitCount &>> 3, limit)
            }
            position &+= 8
            if position >= limit { return limit }
        }
        while position < limit {
            if unsafe src.load(fromByteOffset: position, as: UInt8.self) != src.load(fromByteOffset: position &- distance, as: UInt8.self) {
                return position
            }
            position &+= 1
        }
        return limit
    }
}
