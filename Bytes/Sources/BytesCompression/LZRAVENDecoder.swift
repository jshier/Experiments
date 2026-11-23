public import Bytes

// LZRAVEN (`COMPRESSION_LZRAVEN`, 0xD05): Apple's LZ77 coder of macOS 27 and iOS 27, which Apple Encrypted
// Archives (`aea -a lzraven`) and Apple Archive streams (`pbzm`) use. Undocumented: the format, worked out from
// libcompression's `rav_decode_buffer` and `RavDecodeBlock`, is in Benchmarks/LZRAVEN-FORMAT.md.
//
// In short: an 8-byte header, then blocks of up to 512 KiB of output, each stored or coded, then a zero word.
// A coded block is 32-bit words read by eight interleaved rANS decoders (64-bit states, 14-bit probabilities,
// taking turns symbol by symbol), with adaptive 16-symbol distributions in an LZMA-like model: literals by
// nibbles in the context of the previous byte and the byte at the last distance, matches as one of 16 kinds
// (7 distance ranges, a one-byte repeat, 4 repeated distances with short or long lengths). The model carries
// over from block to block, and matches reach anywhere back in the output. A block's last 32 bytes are the
// low halves of the decoders' final states. Branch filters for x86 and ARM64 code, flagged per block, run
// over the output at the end.

/// Decodes LZRAVEN, Apple's Compression algorithm `COMPRESSION_LZRAVEN` (macOS 27, iOS 27): what
/// `compression_encode_buffer` writes, an Apple Encrypted Archive's segments (`aea -a lzraven`), and an Apple
/// Archive stream's blocks (`pbzm`).
///
/// ```swift
/// var decoder = LZRAVENDecoder()
/// _ = try decoder.decompressAll(segment, decodedSize: segmentSize, into: &output)   // exactly `segmentSize` bytes
/// ```
///
/// Each call decodes a whole buffer into the caller's memory, which is also the history matches copy from. The
/// decoder's model (19 KB, kept twice: the working copy, and the initial one it's reset from) is allocated once, at
/// creation; decoding allocates nothing. Malformed input throws;
/// it never reads or writes outside the buffers.
@safe
public struct LZRAVENDecoder: ~Copyable {
    var workspace = LZRAVENWorkspace()

    /// The first four bytes of every LZRAVEN buffer, little-endian: `2B 00 CA EC`.
    public static var magic: UInt32 { 0xECCA_002B }

    /// The most output one block makes: blocks start at multiples of it.
    static var blockSize: Int { 1 << 19 }

    /// Creates a decoder, allocating its model.
    public init() {}

    /// Decodes a whole LZRAVEN buffer (header, blocks, end marker, and nothing after) into `output`'s free capacity:
    /// an Apple Encrypted Archive segment or an Apple Archive block, whose container states the size.
    ///
    /// - Parameters:
    ///   - input: The whole buffer: header, blocks, and end marker.
    ///   - decodedSize: The size the container says the buffer decodes to, if it does: a buffer decoding to more or
    ///     fewer bytes is corrupt.
    ///   - output: Where to append the decoded bytes; it needs room for all of them (for `decodedSize`, when
    ///     given). Bytes of its free capacity past them may be overwritten (none past `decodedSize`).
    /// - Returns: The number of input bytes decoded: all of them.
    /// - Throws: ``BytesError/insufficientData`` if the input ends early; ``BytesError/insufficientCapacity`` if
    ///   the output doesn't fit (or has room for fewer than `decodedSize` bytes); ``BytesError/mismatch`` if the
    ///   buffer decodes to a size other than `decodedSize`; ``BytesError/invalidValue`` for corrupt data, bytes
    ///   after the end marker, or a negative `decodedSize`.
    public mutating func decompressAll(
        _ input: RawSpan, decodedSize: Int? = nil, into output: inout OutputRawSpan
    ) throws(BytesError) -> Int {
        if let decodedSize {
            guard decodedSize >= 0 else { throw .invalidValue }
            guard decodedSize <= output.freeCapacity else { throw .insufficientCapacity }
        }
        return try unsafe LZBuffers.with(input, &output, byteCount: decodedSize) { input, count, output, capacity throws(BytesError) -> (Int, Int) in
            let decoded: Int
            do throws(BytesError) {
                // Unsafe: the buffers' addresses (placeholders when empty: an empty input is rejected before any
                // read, and nothing is written to an empty output).
                decoded = try unsafe decode(
                    input.assumingMemoryBound(to: UInt8.self), count: count,
                    output: output.assumingMemoryBound(to: UInt8.self), capacity: capacity
                )
            } catch .insufficientCapacity where decodedSize != nil {
                throw .mismatch
            }
            if let decodedSize, decoded != decodedSize { throw .mismatch }
            return (count, decoded)
        }
    }

    /// Decodes the buffer at `input` into `output`, at most `capacity` bytes.
    private mutating func decode(
        _ input: UnsafePointer<UInt8>, count: Int, output: UnsafeMutablePointer<UInt8>, capacity: Int
    ) throws(BytesError) -> Int {
        guard count >= 8 else { throw .insufficientData }
        // Unsafe: reads of the input and copies into the output. Safe: every header is read after checking
        // that the input holds it, each block after checking that the input holds its size, and stored blocks
        // are copied after checking that they fit in the output; coded blocks check their own.
        guard unsafe Self.load32(input, 0) == Self.magic else { throw .invalidValue }
        // The second word's low 26 bits are 0; its top 6 vary by encoder (0 from Compression, 17 from `aa`).
        guard unsafe Self.load32(input, 4) & 0x03FF_FFFF == 0 else { throw .invalidValue }
        // Positions are 32-bit in the format (and in Apple's decoder, which clamps its capacity the same way).
        // (`Int(clamping:)`: on a 32-bit `Int`, positions stop at `Int.max` instead.)
        let capacity = Int(clamping: min(UInt64(capacity), UInt64(UInt32.max)))
        workspace.reset()
        var context = LZRAVENContext()
        var total = 0
        var offset = 8
        while true {
            guard count &- offset >= 4 else { throw .insufficientData }
            let header = unsafe Self.load32(input, offset)
            offset &+= 4
            if header < 0x1000 {
                // The end marker: a zero word, the end of the input.
                guard header == 0, offset == count else { throw .invalidValue }
                break
            }
            // Every block but the last makes a whole block of output.
            guard total & (Self.blockSize &- 1) == 0 else { throw .invalidValue }
            guard total < capacity else { throw .insufficientCapacity }
            let size = Int(header >> 12)
            guard size <= count &- offset else { throw .insufficientData }
            if header & 1 != 0 {
                // Stored. (Compression stores at most a block; larger ones would leave the next block's
                // filter flags undefined in Apple's decoder, so they're rejected.)
                guard size <= Self.blockSize else { throw .invalidValue }
                guard size <= capacity &- total else { throw .insufficientCapacity }
                unsafe LZCopy.exact(UnsafeMutableRawPointer(output + total), UnsafeRawPointer(input + offset), size)
                total &+= size
            } else {
                total &+= try unsafe decodeBlock(
                    input + offset, size: size, output: output, capacity: capacity, start: total, context: &context
                )
            }
            offset &+= size
        }
        unsafe Self.applyFilters(input, output: output, count: total)
        return total
    }

    @inline(__always)
    static func load32(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        // Unsafe: a 4-byte load. Safe: the callers check that `offset + 4` is within the buffer.
        UInt32(littleEndian: unsafe UnsafeRawPointer(base).loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    // MARK: Coded blocks

    /// Decodes the coded block of `size` bytes at `input` into `output` from `start`.
    ///
    /// - Returns: The number of bytes it made.
    private func decodeBlock(
        _ input: UnsafePointer<UInt8>, size: Int, output: UnsafeMutablePointer<UInt8>, capacity: Int, start: Int,
        context: inout LZRAVENContext
    ) throws(BytesError) -> Int {
        let model = unsafe workspace.model
        // Setting up the states reads 9 words, and the block must have exactly the words it reads: whole words.
        guard size >= 36, size & 3 == 0 else { throw .invalidValue }
        // Unsafe: the block's words. Safe: the caller checked that the input holds `size` bytes.
        var coder = unsafe LZRAVENCoder(words: input, count: size &>> 2, states: workspace.states)
        let delta = coder.start()
        // The block's output size, as the zigzag-coded difference from the last block's.
        context.previousSize &+= (delta &>> 1) ^ (0 &- (delta & 1))
        // Checked as a `UInt32` first: a corrupt size could be above a 32-bit `Int`'s range.
        guard context.previousSize >= 64, context.previousSize <= UInt32(Self.blockSize) else { throw .invalidValue }
        let blockSize = Int(context.previousSize)
        guard blockSize <= capacity &- start else { throw .insufficientCapacity }
        // The last 32 bytes are the states' low halves; symbols fill the rest.
        let end = start &+ blockSize &- 32
        var position = start
        // Unsafe: reads and writes of the output. Safe: writes are at `position < end`, matches are checked to
        // end by `end`, and their 16-byte copies write (and read) at most 15 bytes past their end, so
        // everything touched is below `start + blockSize <= capacity`. Reads are at `position - distance` with
        // `1 <= distance <= position`: distances are checked when decoded, and the repeated ones were checked
        // then (or are the initial 1, with `position >= 1`), and positions only grow.
        if start == 0 {
            // The buffer's first byte, eight bits from a state.
            unsafe output[0] = UInt8(truncatingIfNeeded: coder.bits(8))
            position = 1
        }
        var rep0 = Int(context.reps.0)
        var rep1 = Int(context.reps.1)
        var rep2 = Int(context.reps.2)
        var rep3 = Int(context.reps.3)
        guard rep0 <= position, rep1 <= position, rep2 <= position, rep3 <= position else { throw .invalidValue }
        var state = context.state
        // The last byte's top 2 bits, the literals' context, kept in a register and taken from a literal's high
        // nibble: so the next literal's first symbol needn't wait for this one's second. (Reloaded from the
        // output, or taken from the whole byte, it put both symbols and a store-to-load forwarding in every
        // literal's dependency chain: incompressible data decoded at half Compression's speed.)
        var previous = Int(unsafe output[position &- 1]) &>> 6

        while position < end {
            let positionState = position & 3
            if unsafe coder.isLiteral(model + (state &<< 2 | positionState)) {
                let high: Int
                let low: Int
                if state < 3 {
                    high = unsafe coder.symbol(model + LZRAVENModel.literalHigh(positionState, previous), .slow)
                    low = unsafe coder.symbol(model + LZRAVENModel.literalLow(positionState, previous, high), .slow)
                } else {
                    // After a match: the byte at the last distance guides the coding.
                    let matchByte = Int(unsafe output[position &- rep0])
                    let selector = LZRAVENModel.matchedSelector(state)
                    high = unsafe coder.symbol(model + LZRAVENModel.matchedHigh(selector, previous, matchByte &>> 4), .fast)
                    low = high != matchByte &>> 4
                        ? unsafe coder.symbol(model + LZRAVENModel.literalLow(positionState, previous, high), .slow)
                        : unsafe coder.symbol(model + LZRAVENModel.matchedLow(selector, matchByte & 15), .fast)
                }
                unsafe output[position] = UInt8(truncatingIfNeeded: high &<< 4 | low)
                previous = high &>> 2
                position &+= 1
                state = LZRAVENModel.stateAfterLiteral(state)
                continue
            }
            let kind = unsafe coder.symbol(model + LZRAVENModel.kind(state), .fast)
            let length: Int
            if kind < 7 {
                // A new distance: kind 0 is 1 to 256, kinds 1 to 6 farther ranges with extra bits.
                length = unsafe coder.length(
                    model, first: LZRAVENModel.matchLength(kind, positionState), ten: LZRAVENModel.matchLengthTen,
                    fourteen: LZRAVENModel.matchLengthFourteen, low: LZRAVENModel.matchLengthLow(positionState)
                ) &+ 2
                let slot = unsafe coder.symbol(model + LZRAVENModel.distance(kind), .slow)
                let low = unsafe coder.symbol(model + (LZRAVENModel.distance(kind) &+ 16), .slow)
                var distanceLess1: UInt32
                if kind == 0 {
                    distanceLess1 = UInt32(truncatingIfNeeded: slot &<< 4 | low)
                } else {
                    let extraBits = UInt32(truncatingIfNeeded: slot &>> 2 &+ kind &<< 2 &- 2)
                    let extra = coder.bits(extraBits)
                    distanceLess1 = (4 | UInt32(truncatingIfNeeded: slot & 3)) &<< (extraBits &+ 4)
                    distanceLess1 &+= extra &<< 4 &+ UInt32(truncatingIfNeeded: low)
                }
                guard Int(distanceLess1) < position else { throw .invalidValue }
                rep3 = rep2
                rep2 = rep1
                rep1 = rep0
                rep0 = Int(distanceLess1) &+ 1
                state = state < 9 ? 11 : 13
            } else if kind == 7 {
                // One byte at the last distance.
                let byte = unsafe output[position &- rep0]
                unsafe output[position] = byte
                previous = Int(byte &>> 6)
                position &+= 1
                state = state < 9 ? 9 : 12
                continue
            } else {
                // A repeated distance, moved to the front: kinds 8 to 11 with lengths 2 to 17, 12 to 15 longer.
                if kind < 12 {
                    length = unsafe coder.symbol(model + LZRAVENModel.repeatShortLength(positionState), .fast) &+ 2
                } else {
                    length = unsafe coder.length(
                        model, first: LZRAVENModel.repeatLongLength(positionState), ten: LZRAVENModel.repeatLengthTen,
                        fourteen: LZRAVENModel.repeatLengthFourteen, low: LZRAVENModel.repeatLengthLow(positionState)
                    ) &+ 18
                }
                // With selects rather than a branch on which one: it's unpredictable.
                let which = kind & 3
                let chosen = which < 2 ? (which == 0 ? rep0 : rep1) : (which == 2 ? rep2 : rep3)
                rep3 = which == 3 ? rep2 : rep3
                rep2 = which >= 2 ? rep1 : rep2
                rep1 = which >= 1 ? rep0 : rep1
                rep0 = chosen
                state = state < 9 ? 10 : 12
            }
            guard length <= end &- position else { throw .invalidValue }
            let destination = unsafe UnsafeMutableRawPointer(output + position)
            if rep0 >= 16 {
                // 16 bytes at a time, at most 15 past the end; each move reads only bytes already written.
                unsafe LZCopy.wild(destination, UnsafeRawPointer(destination - rep0), length)
            } else {
                // The last `rep0` bytes, repeated across 16 by a shuffle, stored every whole number of
                // periods: no load reads what the copy just stored.
                let last = unsafe UnsafeRawPointer(destination - rep0).loadUnaligned(as: SIMD16<UInt8>.self)
                let (shuffle, step) = workspace.pattern(rep0)
                let repeated = ByteLanes(shuffle).lookup(in: last)
                var offset = 0
                repeat {
                    unsafe (destination + offset).storeBytes(of: repeated, as: SIMD16<UInt8>.self)
                    offset &+= step
                } while offset < length
            }
            position &+= length
            // The match's last byte, from its source rather than through the copy's stores.
            previous = Int(unsafe output[position &- 1 &- rep0] &>> 6)
        }
        guard position == end else { throw .invalidValue }
        unsafe coder.finish(into: UnsafeMutableRawPointer(output + end))
        // Every word read, and none past the end.
        guard coder.isAtEnd else { throw .invalidValue }
        context.reps = (UInt32(rep0), UInt32(rep1), UInt32(rep2), UInt32(rep3))
        context.state = state
        return blockSize
    }

    // MARK: Filters

    /// Undoes the branch filters each block's flags ask for, over the decoded output: blocks start at multiples
    /// of ``blockSize``, so the headers, walked again, say which flags go where.
    private static func applyFilters(_ input: UnsafePointer<UInt8>, output: UnsafeMutablePointer<UInt8>, count: Int) {
        var offset = 8
        var start = 0
        // Unsafe: header reads (the decode just walked them) and filtering within the output (`count` bytes).
        while start < count {
            let header = unsafe load32(input, offset)
            offset &+= 4 &+ Int(header >> 12)
            let length = min(count &- start, blockSize)
            if length >= 64 {
                if header & 4 != 0 {
                    unsafe undoX86Filter(output, start: start, end: start &+ length)
                }
                if header & 2 != 0 {
                    unsafe undoARM64Filter(output, start: start &+ Int(header >> 10 & 3), end: start &+ length)
                }
            }
            start &+= blockSize
        }
    }

    /// x86 `call` and `jmp` (E8 and E9) operands: absolute 25-bit targets, stored as bytes 2, 1, 0 and a sign
    /// byte, become relative to the next instruction again.
    static func undoX86Filter(_ output: UnsafeMutablePointer<UInt8>, start: Int, end: Int) {
        var index = start
        // Unsafe: reads and writes of the output. Safe: an operand is read and written only when its 4 bytes
        // end by `end`, which the caller keeps within the output.
        while index &+ 5 <= end {
            if index &+ 20 <= end {
                // Sixteen bytes at a time to the next E8 or E9 (the operand after it fits by `end`).
                let lanes = unsafe UnsafeRawPointer(output + index).loadUnaligned(as: SIMD16<UInt8>.self)
                let matches = ByteLanes(lanes & 0xFE).matching(0xE8).nibbleMask
                guard matches != 0 else {
                    index &+= 16
                    continue
                }
                index &+= matches.trailingZeroBitCount &>> 2
            } else if unsafe output[index] & 0xFE != 0xE8 {
                index &+= 1
                continue
            }
            let operand = index &+ 1
            let sign = unsafe output[operand &+ 3]
            guard sign == 0 || sign == 0xFF else {
                index = operand &+ 3
                continue
            }
            let raw = unsafe UInt32(littleEndian: UnsafeRawPointer(output + operand).loadUnaligned(as: UInt32.self))
            var value = (raw & 0x0100_0000) &- UInt32(truncatingIfNeeded: operand)
            value &+= (raw & 0xFF00) &+ (raw & 0xFF) &<< 16 &+ (raw &>> 16 & 0xFF)
            value = (value & 0x01FF_FFFF) &- (value &<< 1 & 0x0200_0000)
            unsafe UnsafeMutableRawPointer(output + operand).storeBytes(of: value.littleEndian, as: UInt32.self)
            index = operand &+ 4
        }
    }

    /// ARM64 `bl` and `adrp` immediates, made absolute by the encoder, become relative again: each aligned word
    /// from `start` (the block's start plus the offset its flags name) by `end`.
    static func undoARM64Filter(_ output: UnsafeMutablePointer<UInt8>, start: Int, end: Int) {
        var index = start
        // Unsafe: reads and writes of the output. Safe: each word ends by `end`, within the output.
        while index &+ 4 <= end {
            let pointer = unsafe UnsafeMutableRawPointer(output + index)
            var word = unsafe UInt32(littleEndian: pointer.loadUnaligned(as: UInt32.self))
            let position = UInt32(truncatingIfNeeded: index)
            if word & 0xFC00_0000 == 0x9400_0000 {
                // `bl`, with a target within ±32 MB (the immediate's top three bits alike).
                if (word &+ 0x80_0000) & 0x0300_0000 == 0 {
                    let value = word &- position &>> 2
                    let sign = value &>> 23 & 1
                    word = sign &<< 24 | sign &<< 25 | value & 0xFF_FFFF | 0x9400_0000
                    unsafe pointer.storeBytes(of: word.littleEndian, as: UInt32.self)
                }
            } else if word & 0x9F00_0000 == 0x9000_0000 {
                // `adrp`, with a page within ±2 GB (the immediate's top two bits alike).
                if (word &+ 0x40_0000) & 0x80_0000 == 0 {
                    let value = (word &>> 11 & 0x1C_0000 | word &>> 5 & 0x3_FFFF) &- position &>> 12
                    word = word & 0x9000_001F | value &<< 29 | value &<< 4 & 0x80_0000 | value &<< 3 & 0x7F_FFE0
                    unsafe pointer.storeBytes(of: word.littleEndian, as: UInt32.self)
                }
            }
            index &+= 4
        }
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension LZRAVENDecoder: @unchecked Sendable {}

/// What carries over from block to block besides the model: the repeated distances, the state, and the last
/// block's size.
struct LZRAVENContext {
    var reps: (UInt32, UInt32, UInt32, UInt32) = (1, 1, 1, 1)
    var state = 0
    var previousSize: UInt32 = 0
}

/// The adaptive model's layout, in `UInt16`s: binary probabilities, then 16-symbol cumulative distributions of
/// 16 entries each (the last always 0x4000). Offsets are Apple's, halved.
enum LZRAVENModel {
    /// `isMatch[state][position & 3]`: binary, 0x4000 meaning certain.
    static var isMatch: Int { 0 }
    /// Which kind of match, per state (0 to 8 after literals, 9 to 13 after matches).
    static var kinds: Int { 56 }
    /// A literal's high nibble after a match: `[selector][previous >> 6][matchByte >> 4]`.
    static var matchedHighs: Int { 280 }
    /// Its low nibble when the high one agreed with the match byte's: `[selector][matchByte & 15]`.
    static var matchedLows: Int { 3_352 }
    /// A literal's high nibble: `[position & 3][previous >> 6]`.
    static var literalHighs: Int { 4_120 }
    /// Its low nibble: `[position & 3][previous >> 6][high]`.
    static var literalLows: Int { 4_376 }
    static var repeatShortLengths: Int { 8_472 }
    static var repeatLongLengths: Int { 8_536 }
    static var repeatLengthLows: Int { 8_600 }
    static var repeatLengthTen: Int { 8_664 }
    static var repeatLengthFourteen: Int { 8_680 }
    /// A new match's length, `[kind][position & 3]`.
    static var matchLengths: Int { 8_696 }
    static var matchLengthLows: Int { 9_144 }
    static var matchLengthTen: Int { 9_208 }
    static var matchLengthFourteen: Int { 9_224 }
    /// A new distance's two symbols, per kind.
    static var distances: Int { 9_240 }
    static var count: Int { 9_464 }

    @inline(__always) static func kind(_ state: Int) -> Int { kinds &+ state &<< 4 }
    @inline(__always) static func literalHigh(_ positionState: Int, _ previous: Int) -> Int {
        literalHighs &+ (positionState &<< 2 | previous) &<< 4
    }
    @inline(__always) static func literalLow(_ positionState: Int, _ previous: Int, _ high: Int) -> Int {
        literalLows &+ (positionState &<< 6 | previous &<< 4 | high) &<< 4
    }
    @inline(__always) static func matchedHigh(_ selector: Int, _ previous: Int, _ matchHigh: Int) -> Int {
        matchedHighs &+ (selector &<< 6 | previous &<< 4 | matchHigh) &<< 4
    }
    @inline(__always) static func matchedLow(_ selector: Int, _ matchLow: Int) -> Int {
        matchedLows &+ (selector &<< 4 | matchLow) &<< 4
    }
    @inline(__always) static func repeatShortLength(_ positionState: Int) -> Int { repeatShortLengths &+ positionState &<< 4 }
    @inline(__always) static func repeatLongLength(_ positionState: Int) -> Int { repeatLongLengths &+ positionState &<< 4 }
    @inline(__always) static func repeatLengthLow(_ positionState: Int) -> Int { repeatLengthLows &+ positionState &<< 4 }
    @inline(__always) static func matchLength(_ kind: Int, _ positionState: Int) -> Int {
        matchLengths &+ (kind &<< 2 | positionState) &<< 4
    }
    @inline(__always) static func matchLengthLow(_ positionState: Int) -> Int { matchLengthLows &+ positionState &<< 4 }
    @inline(__always) static func distance(_ kind: Int) -> Int { distances &+ kind &<< 5 }

    /// The literal model a matched literal uses in states 3 to 13: 2, 1, 2, 1, 2, 1, then 0.
    @inline(__always) static func matchedSelector(_ state: Int) -> Int {
        Int(truncatingIfNeeded: (0b01_10_01_10_01_10 as UInt32) &>> UInt32(truncatingIfNeeded: (state &- 3) &<< 1) & 3)
    }

    /// The state after a literal: 0, 0, 0, 2, 3, 1, 5, 1, 7, 4, 6, 8, 6, 8.
    @inline(__always) static func stateAfterLiteral(_ state: Int) -> Int {
        Int(truncatingIfNeeded: (0x0086_8647_1513_2000 as UInt64) &>> UInt64(truncatingIfNeeded: state &<< 2) & 15)
    }

    /// Each kind's initial frequency in 64ths, after a literal and after a match: favoring short matches,
    /// one-byte repeats, and the last distance; and short matches.
    static func initialKindCounts(afterMatch: Bool, _ kind: Int) -> UInt16 {
        afterMatch ? (kind < 3 ? 17 : 1) : (kind == 0 || kind == 7 || kind == 8 ? 17 : 1)
    }
}

/// The eight rANS decoders, reading 32-bit words in turn.
@safe
struct LZRAVENCoder {
    /// The next word.
    var cursor: UnsafePointer<UInt8>
    /// The words left: negative once reads have gone past the end.
    var remaining: Int
    /// The states, in the workspace: indexed by `next & 7`, so they live in memory.
    let states: UnsafeMutablePointer<UInt64>
    /// Which state decodes next.
    var next = 0

    init(words: UnsafePointer<UInt8>, count: Int, states: UnsafeMutablePointer<UInt64>) {
        unsafe cursor = words
        remaining = count
        unsafe self.states = states
    }

    var isAtEnd: Bool { remaining == 0 }

    /// The next word, or 0 past the end (which `isAtEnd` then rejects).
    @inline(always)
    mutating func read() -> UInt64 {
        // A branch (well predicted) measured fewer instructions and cycles than loading a clamped index and
        // selecting 0: +13% instructions, +8% cycles on dickens.
        let word: UInt64
        if remaining > 0 {
            // Unsafe: a word of the block. Safe: `remaining > 0` words of 4 bytes are left at `cursor`.
            word = UInt64(UInt32(littleEndian: unsafe UnsafeRawPointer(cursor).loadUnaligned(as: UInt32.self)))
            unsafe cursor += 4
        } else {
            word = 0
        }
        remaining &-= 1
        return word
    }

    /// `x` with the next word below it if it's under 2^32. (A branch: selects instead measured 75% more
    /// instructions and no fewer cycles.)
    @inline(always)
    mutating func refill(_ x: UInt64) -> UInt64 {
        x &>> 32 == 0 ? x &<< 32 | read() : x
    }

    /// Sets up the states from the block's first words and returns the size code that follows. (Inlined: an
    /// out-of-line `mutating` call would keep the coder in memory through the decode loop.)
    @inline(always)
    mutating func start() -> UInt32 {
        // The first state takes in the others: each in turn gives up its low word as another state's low
        // word, takes a new one, and yields a 5-bit count and that many bits, the other state's high word
        // (below a leading 1).
        var x = read() &<< 32
        x |= read()
        // Unsafe: the eight states. Safe: the workspace holds them.
        for k in 1..<8 {
            x = refill(x)
            let low = x & 0xFFFF_FFFF
            let word = read()
            x = (x & 0xFFFF_FFFF_0000_0000 | word) &>> 5
            let bitCount = word & 31
            var value: UInt64 = 0
            if bitCount != 0 {
                x = refill(x)
                value = x & ~(0xFFFF_FFFF &<< bitCount) & 0xFFFF_FFFF
                x &>>= bitCount
            }
            unsafe states[k] = (value &+ 1 &<< bitCount) &<< 32 | low
        }
        x = refill(x)
        unsafe states[0] = x &>> 5
        let bitCount = UInt32(truncatingIfNeeded: x & 31)
        next = 1
        guard bitCount != 0 else { return 0 }
        // The size code: `bitCount` bits from the second state, plus `2^bitCount - 1`.
        let mask = ~(0xFFFF_FFFF as UInt32 &<< bitCount)
        let second = unsafe refill(states[1])
        unsafe states[1] = second &>> bitCount
        next = 2
        return UInt32(truncatingIfNeeded: second) & mask &+ mask
    }

    /// `count` raw bits (0 to 31) from the next state.
    @inline(always)
    mutating func bits(_ count: UInt32) -> UInt32 {
        let k = next & 7
        next &+= 1
        // Unsafe: a state, `k < 8`.
        let x = unsafe refill(states[k])
        unsafe states[k] = x &>> count
        return UInt32(truncatingIfNeeded: x) & ~(0xFFFF_FFFF as UInt32 &<< count)
    }

    /// Whether the next symbol is a literal: a binary decision, adapting by 1/32.
    @inline(always)
    mutating func isLiteral(_ probability: UnsafeMutablePointer<UInt16>) -> Bool {
        let k = next & 7
        next &+= 1
        // Unsafe: a state, `k < 8`, and the probability the caller points at.
        let x = unsafe refill(states[k])
        let slot = x & 0x3FFF
        let p = UInt64(unsafe probability.pointee)
        if slot >= p {
            unsafe probability.pointee = UInt16(truncatingIfNeeded: p &- p &>> 5)
            unsafe states[k] = (x &>> 14) &* (0x4000 &- p) &+ slot &- p
            return true
        }
        unsafe probability.pointee = UInt16(truncatingIfNeeded: p &+ (0x4000 &- p) &>> 5)
        unsafe states[k] = (x &>> 14) &* p &+ slot
        return false
    }

    /// A symbol, 0 to 15, from the distribution at `cdf`, which then adapts toward it at `rate`.
    @inline(always)
    mutating func symbol(_ cdf: UnsafeMutablePointer<UInt16>, _ rate: LZRAVENRate) -> Int {
        let k = next & 7
        next &+= 1
        // Unsafe: a state, `k < 8`, and the 16 entries at `cdf`, which the caller points at in the model.
        let x = unsafe refill(states[k])
        let slot = x & 0x3FFF
        let raw = UnsafeMutableRawPointer(cdf)
        let low = unsafe raw.load(as: SIMD8<Int16>.self)
        let high = unsafe raw.load(fromByteOffset: 16, as: SIMD8<Int16>.self)
        let splat = SIMD8<Int16>(repeating: Int16(truncatingIfNeeded: slot))
        let lowAbove = low .> splat
        let highAbove = high .> splat
        // The symbol is the number of entries at or below the slot.
        let zero = SIMD8<Int16>(repeating: 0)
        let above = zero.replacing(with: 1, where: lowAbove) &+ zero.replacing(with: 1, where: highAbove)
        let symbol = 16 &- Int(above.wrappedSum())
        // Entry 15 is 0x4000, so masked it's the 0 below symbol 0.
        let start = UInt64(unsafe cdf[(symbol &- 1) & 15] & 0x3FFF)
        let frequency = UInt64(unsafe cdf[symbol]) &- start
        // Entries at and above the symbol move toward the top, those below toward the bottom.
        let (lowTop, highTop) = rate.tops
        let lowTarget = LZRAVENRate.lowBottoms.replacing(with: lowTop, where: lowAbove)
        let highTarget = LZRAVENRate.highBottoms.replacing(with: highTop, where: highAbove)
        let shift = rate.shift
        unsafe raw.storeBytes(of: low &+ (lowTarget &- low) &>> shift, as: SIMD8<Int16>.self)
        unsafe raw.storeBytes(of: high &+ (highTarget &- high) &>> shift, toByteOffset: 16, as: SIMD8<Int16>.self)
        unsafe states[k] = (x &>> 14) &* frequency &+ slot &- start
        return symbol
    }

    /// A length, 0 to 330: a symbol from `first`, with 10 and 11 to 15 extended.
    @inline(always)
    mutating func length(_ model: UnsafeMutablePointer<UInt16>, first: Int, ten: Int, fourteen: Int, low: Int) -> Int {
        // Unsafe: distributions in the model, at the caller's offsets.
        var symbol = unsafe self.symbol(model + first, .fast)
        if symbol <= 9 { return symbol }
        if symbol == 10 {
            let more = unsafe self.symbol(model + ten, .fast)
            return 10 &+ more
        }
        if symbol == 15 { return 330 }
        if symbol == 14 {
            let more = unsafe self.symbol(model + fourteen, .fast)
            symbol = 14 &+ more
        }
        let more = unsafe self.symbol(model + low, .fast)
        return symbol &<< 4 &+ more &- 150
    }

    /// Writes the states' low words: the block's last 32 bytes.
    func finish(into destination: UnsafeMutableRawPointer) {
        for k in 0..<8 {
            // Unsafe: the states, and 32 bytes at `destination`, which the caller reserved.
            unsafe destination.storeBytes(of: UInt32(truncatingIfNeeded: states[k]).littleEndian, toByteOffset: k &<< 2, as: UInt32.self)
        }
    }
}

/// How fast a distribution adapts: by 1/64 or 1/128 of the way to its target.
enum LZRAVENRate {
    case fast
    case slow

    @inline(__always) var shift: SIMD8<Int16> { SIMD8(repeating: self == .fast ? 6 : 7) }

    /// Entry `k`'s target when the symbol is above it: `32 * (k + 1)`, so every symbol keeps 32/16384.
    @inline(__always) static var lowBottoms: SIMD8<Int16> { SIMD8(0, 1, 2, 3, 4, 5, 6, 7) &* 32 &+ 32 }
    @inline(__always) static var highBottoms: SIMD8<Int16> { SIMD8(8, 9, 10, 11, 12, 13, 14, 15) &* 32 &+ 32 }

    /// Entry `k`'s target when the symbol is at or below it: `0x4000 - 32 * (15 - k)`, plus `2^shift - 1` so the
    /// arithmetic shift reaches it.
    @inline(__always) var tops: (SIMD8<Int16>, SIMD8<Int16>) {
        let base: Int16 = self == .fast ? 0x3E5F : 0x3E9F
        return (SIMD8(0, 1, 2, 3, 4, 5, 6, 7) &* 32 &+ base, SIMD8(8, 9, 10, 11, 12, 13, 14, 15) &* 32 &+ base)
    }
}

/// The model and the eight states, allocated once.
@safe @usableFromInline // Exported for clients' destroys, as `ZstdWorkspace`.
struct LZRAVENWorkspace: ~Copyable {
    /// The states (64 bytes), the working model, then the model as decoding starts. The working model starts
    /// 16 bytes into a cache line, so its distributions (from byte 0x70) start on 64-byte boundaries.
    private let memory = CodecWorkspace(byteCount: size, zeroed: false)
    // Unsafe: the allocation's address. Safe: valid while the workspace (which owns it) lives.
    private var base: UnsafeMutableRawPointer { unsafe memory.base }
    private static var modelBytes: Int { LZRAVENModel.count &* 2 }
    private static var modelOffset: Int { 80 }
    private static var initialOffset: Int { modelOffset &+ modelBytes }
    /// For each distance `d` below 16, the lanes `0, 1, …, d - 1, 0, 1, …`: a 16-byte shuffle that repeats
    /// the last `d` bytes.
    private static var patternsOffset: Int { initialOffset &+ modelBytes }
    /// Then for each, the largest multiple of `d` up to 16: how far apart the shuffled vector repeats.
    private static var size: Int { patternsOffset &+ 256 &+ 16 }

    init() {
        // Unsafe: initializing fresh memory. Safe: the allocation holds the states and both models.
        unsafe base.initializeMemory(as: UInt8.self, repeating: 0, count: Self.initialOffset)
        let initial = unsafe (base + Self.initialOffset).initializeMemory(
            as: UInt16.self, repeating: 0x2000, count: LZRAVENModel.count
        )
        for state in 0..<14 {
            var sum: UInt16 = 0
            for kind in 0..<16 {
                sum &+= LZRAVENModel.initialKindCounts(afterMatch: state >= 9, kind)
                unsafe initial[LZRAVENModel.kind(state) &+ kind] = sum &<< 8
            }
        }
        // Every other distribution starts uniform.
        for cdf in stride(from: LZRAVENModel.matchedHighs, to: LZRAVENModel.count, by: 16) {
            for entry in 0..<16 {
                unsafe initial[cdf &+ entry] = UInt16(entry &+ 1) &<< 10
            }
        }
        let patterns = unsafe (base + Self.patternsOffset).initializeMemory(as: UInt8.self, repeating: 0, count: 256 &+ 16)
        for distance in 1..<16 {
            for lane in 0..<16 {
                unsafe patterns[distance &<< 4 &+ lane] = UInt8(lane % distance)
            }
            unsafe patterns[256 &+ distance] = UInt8(16 &- 16 % distance)
        }
    }

    /// Distance `d`'s repeating shuffle (`d` from 1 to 15), and the step its vector repeats at.
    @inline(__always)
    func pattern(_ distance: Int) -> (shuffle: SIMD16<UInt8>, step: Int) {
        // Unsafe: loads from the allocation. Safe: 16 bytes at `distance * 16 < 256` in the patterns, and
        // byte `256 + distance` after them.
        let patterns = unsafe base + Self.patternsOffset
        return unsafe (
            patterns.load(fromByteOffset: distance &<< 4, as: SIMD16<UInt8>.self),
            Int(patterns.load(fromByteOffset: 256 &+ distance, as: UInt8.self))
        )
    }

    /// The working model.
    var model: UnsafeMutablePointer<UInt16> {
        // Unsafe: a pointer into the allocation. Safe: the working model is `modelBytes` at `modelOffset`.
        unsafe (base + Self.modelOffset).assumingMemoryBound(to: UInt16.self)
    }

    var states: UnsafeMutablePointer<UInt64> {
        // Unsafe: a pointer into the allocation. Safe: the first 64 bytes.
        unsafe base.assumingMemoryBound(to: UInt64.self)
    }

    /// Restores the model to its initial values.
    func reset() {
        // Unsafe: a copy within the allocation. Safe: both models are `modelBytes` long and don't overlap.
        unsafe (base + Self.modelOffset).copyMemory(from: base + Self.initialOffset, byteCount: Self.modelBytes)
    }
}
