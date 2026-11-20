public import Bytes

/// An LZVN decoder: Apple's byte-oriented LZ77 format, which LZFSE uses for small blocks (`bvxn`), and which
/// stands alone in kernel caches, `decmpfs` compression, and Apple Encrypted Archives.
///
/// ```swift
/// let decoder = LZVNDecoder()
/// let consumed = try decoder.decompressAll(stream, into: &output)   // through the end-of-stream opcode
/// ```
///
/// An LZVN stream is a series of opcodes, each a byte with up to two operand bytes: a literal of 0 to 3 bytes
/// followed by a match (with a new distance of 11, 14, or 16 bits, or the previous one), a literal alone (up
/// to 271 bytes), or a match alone at the previous distance (up to 271 bytes). It ends with opcode 6 and 7
/// more bytes.
///
/// The decoder keeps no state and allocates nothing. Its loop copies literals and matches 16 bytes at a time
/// while there's room past them in both buffers, and exactly near their ends. Malformed input throws; it never
/// reads or writes outside the buffers.
@safe
public struct LZVNDecoder: Sendable {
    /// Creates a decoder.
    public init() {}

    /// Decodes a raw LZVN stream, from its first opcode through its end-of-stream opcode, into `output`'s free
    /// capacity.
    ///
    /// - Parameters:
    ///   - input: The stream, at its start. Bytes after its end are left alone.
    ///   - output: Where to append the decoded bytes; it needs room for all of them. Bytes of its free capacity
    ///     past them may be overwritten.
    /// - Returns: The number of input bytes decoded, through the end-of-stream opcode.
    /// - Throws: ``BytesError/insufficientData`` if the input ends before the end-of-stream opcode;
    ///   ``BytesError/insufficientCapacity`` if the output doesn't fit; ``BytesError/invalidValue`` for an
    ///   undefined opcode, or a match distance of 0 or one reaching before the output's start.
    public func decompressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        try unsafe LZBuffers.with(input, &output) { input, count, output, capacity throws(BytesError) -> (Int, Int) in
            // Unsafe: pointers to the ends of the buffers, and distances between pointers into them.
            let (inputEnd, outputEnd) = try unsafe Self.decode(
                input, inputEnd: input + count, inputLimit: input + count,
                base: output, output: output, outputEnd: output + capacity, outputLimit: output + capacity
            )
            return unsafe (inputEnd - input, outputEnd - output)
        }
    }

    /// Decodes opcodes from `input` until the end-of-stream opcode, which must end by `inputEnd`, into `output`,
    /// which must not pass `outputEnd`.
    ///
    /// Literals and matches are copied 16 bytes at a time while `inputLimit` and `outputLimit` (the ends of the
    /// buffers, at or past the stream's) leave room for the overrun.
    ///
    /// - Parameters:
    ///   - base: The first byte matches may reach back to.
    /// - Returns: The end of the end-of-stream opcode, and where the output ended.
    /// - Throws: ``BytesError/insufficientData`` if the input ends first; ``BytesError/insufficientCapacity`` if
    ///   the output would pass `outputEnd`; ``BytesError/invalidValue`` for an undefined opcode, or a match
    ///   distance of 0 or one reaching before `base`.
    @inline(never)
    static func decode(
        _ input: UnsafeRawPointer, inputEnd: UnsafeRawPointer, inputLimit: UnsafeRawPointer,
        base: UnsafeMutableRawPointer, output: UnsafeMutableRawPointer, outputEnd: UnsafeMutableRawPointer,
        outputLimit: UnsafeMutableRawPointer
    ) throws(BytesError) -> (UnsafeRawPointer, UnsafeMutableRawPointer) {
        // Unsafe: loads from the input, and copies into the output. Safe: each opcode's bytes and literal are
        // checked to end by `inputEnd` before they're read, and each copy to end by `outputEnd`; wild copies
        // run only while `inputFast` and `outputFast` (at most the limits less the overrun) leave room for what
        // they read and write past the bytes copied; matches start at `base` or later (checked).
        var ip = unsafe input
        var op = unsafe output
        // As offsets from `input` and `output`, negative with less room than the overrun, so that no copy (not even
        // an empty one) takes the fast path then (see `LZ4Decoder.decodeBlock`).
        let inputFast = unsafe min(inputEnd - input, (inputLimit - input) &- LZCopy.overrun)
        let outputFast = unsafe min(outputEnd - output, (outputLimit - output) &- LZCopy.overrun)
        var distance = 0 // The previous match distance: none yet, which no match may use.
        while true {
            guard unsafe ip < inputEnd else { throw .insufficientData }
            let opcode = Int(unsafe ip.load(as: UInt8.self))
            if zstdLikely(opcode < 0xE0) {
                // A literal of 0 to 3 bytes, then a match: LLMMMDDD DDDDDDDD (small distance), LLMMM111 DDDDDDDD
                // DDDDDDDD (large), LLMMM110 (previous), or 101LLMMM DDDDDDMM DDDDDDDD (medium).
                var literalLength = opcode &>> 6
                var matchLength = (opcode &>> 3) & 7 &+ 3
                var opcodeLength = 1
                let low = opcode & 7
                if zstdLikely(UInt(bitPattern: opcode &- 0xA0) >= 0x20) {
                    // Undefined: 0x70–0x7F and 0xD0–0xDF.
                    if zstdUnlikely((0x2080 &>> (opcode &>> 4)) & 1 != 0) { throw .invalidValue }
                    // (Choosing the distance and opcode length with selects rather than these branches ran 12–18%
                    // more instructions, 10% faster on dickens, 5% slower on the 1.6 KB JSON: kept as branches.)
                    if low < 6 {
                        guard unsafe inputEnd - ip >= 2 else { throw .insufficientData }
                        distance = low &<< 8 | Int(unsafe ip.load(fromByteOffset: 1, as: UInt8.self))
                        opcodeLength = 2
                    } else if low == 7 {
                        guard unsafe inputEnd - ip >= 3 else { throw .insufficientData }
                        distance = Int(UInt16(littleEndian: unsafe ip.loadUnaligned(fromByteOffset: 1, as: UInt16.self)))
                        opcodeLength = 3
                    } else if zstdUnlikely(opcode < 0x40) {
                        // No literal and the previous distance: the end of the stream (6), no operation (0x0E,
                        // 0x16), or undefined.
                        if opcode == 6 {
                            guard unsafe inputEnd - ip >= 8 else { throw .insufficientData }
                            return unsafe (ip + 8, op)
                        }
                        guard opcode == 0x0E || opcode == 0x16 else { throw .invalidValue }
                        unsafe ip += 1
                        continue
                    }
                } else {
                    guard unsafe inputEnd - ip >= 3 else { throw .insufficientData }
                    let operand = Int(UInt16(littleEndian: unsafe ip.loadUnaligned(fromByteOffset: 1, as: UInt16.self)))
                    literalLength = (opcode &>> 3) & 3
                    matchLength = (low &<< 2 | operand & 3) &+ 3
                    distance = operand &>> 2
                    opcodeLength = 3
                }
                let sequenceLength = literalLength &+ matchLength
                if zstdLikely(unsafe opcodeLength &+ literalLength <= inputFast &- (ip - input) && sequenceLength <= outputFast &- (op - output)) {
                    // The literal as one 4-byte move: at most 3 bytes, the rest overwritten by the match.
                    unsafe op.storeBytes(of: ip.loadUnaligned(fromByteOffset: opcodeLength, as: UInt32.self), as: UInt32.self)
                    unsafe ip += opcodeLength &+ literalLength
                    unsafe op += literalLength
                    guard unsafe UInt(bitPattern: distance &- 1) < UInt(bitPattern: op - base) else { throw .invalidValue }
                    unsafe LZCopy.match(op, offset: distance, count: matchLength)
                    unsafe op += matchLength
                } else {
                    guard unsafe opcodeLength &+ literalLength <= inputEnd - ip else { throw .insufficientData }
                    guard unsafe sequenceLength <= outputEnd - op else { throw .insufficientCapacity }
                    unsafe LZCopy.exact(op, ip + opcodeLength, literalLength)
                    unsafe ip += opcodeLength &+ literalLength
                    unsafe op += literalLength
                    guard unsafe UInt(bitPattern: distance &- 1) < UInt(bitPattern: op - base) else { throw .invalidValue }
                    unsafe LZCopy.exactMatch(op, offset: distance, count: matchLength)
                    unsafe op += matchLength
                }
            } else if opcode < 0xF0 {
                // A literal alone: 1110LLLL, or 11100000 LLLLLLLL for 16 to 271 bytes.
                var literalLength = opcode & 15
                var opcodeLength = 1
                if literalLength == 0 {
                    guard unsafe inputEnd - ip >= 2 else { throw .insufficientData }
                    literalLength = Int(unsafe ip.load(fromByteOffset: 1, as: UInt8.self)) &+ 16
                    opcodeLength = 2
                }
                if zstdLikely(unsafe opcodeLength &+ literalLength <= inputFast &- (ip - input) && literalLength <= outputFast &- (op - output)) {
                    unsafe LZCopy.wild(op, ip + opcodeLength, literalLength)
                } else {
                    guard unsafe opcodeLength &+ literalLength <= inputEnd - ip else { throw .insufficientData }
                    guard unsafe literalLength <= outputEnd - op else { throw .insufficientCapacity }
                    unsafe LZCopy.exact(op, ip + opcodeLength, literalLength)
                }
                unsafe ip += opcodeLength &+ literalLength
                unsafe op += literalLength
            } else {
                // A match alone at the previous distance: 1111MMMM, or 11110000 MMMMMMMM for 16 to 271 bytes.
                var matchLength = opcode & 15
                if matchLength == 0 {
                    guard unsafe inputEnd - ip >= 2 else { throw .insufficientData }
                    matchLength = Int(unsafe ip.load(fromByteOffset: 1, as: UInt8.self)) &+ 16
                    unsafe ip += 2
                } else {
                    unsafe ip += 1
                }
                guard unsafe UInt(bitPattern: distance &- 1) < UInt(bitPattern: op - base) else { throw .invalidValue }
                if zstdLikely(unsafe matchLength <= outputFast &- (op - output)) {
                    unsafe LZCopy.match(op, offset: distance, count: matchLength)
                } else {
                    guard unsafe matchLength <= outputEnd - op else { throw .insufficientCapacity }
                    unsafe LZCopy.exactMatch(op, offset: distance, count: matchLength)
                }
                unsafe op += matchLength
            }
        }
    }
}
