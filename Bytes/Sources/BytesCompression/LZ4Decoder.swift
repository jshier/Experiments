public import Bytes

/// An LZ4 decoder for Apple's two LZ4 forms: raw blocks (Compression's `COMPRESSION_LZ4_RAW`, Apple Archive's
/// `pbz4` blocks) and Compression's framed stream (`COMPRESSION_LZ4`).
///
/// ```swift
/// let decoder = LZ4Decoder()
/// try decoder.decompressRaw(block, decodedSize: size, into: &output)    // one raw block, exactly `size` bytes
/// let consumed = try decoder.decompressFramed(stream, into: &output)  // `bv41` … `bv4$`
/// ```
///
/// A raw block is LZ4's block format with nothing around it: sequences of a token, literals, and a match, the
/// last with literals only. Compression's framed stream is a series of blocks, each with a 4-byte magic and
/// little-endian sizes: `bv41`, the decoded size, the encoded size, and a raw block (whose matches may reach
/// back into earlier blocks); `bv4-`, a size, and that many stored bytes; and `bv4$`, the end.
///
/// The decoder keeps no state and allocates nothing. Its loop copies literals and matches 16 bytes at a time
/// while there's room past them in both buffers, and exactly near their ends. Malformed input throws; it never
/// reads or writes outside the buffers.
@safe
public struct LZ4Decoder: Sendable {
    /// Creates a decoder.
    public init() {}

    /// Decodes one raw LZ4 block, all of `input`, into exactly `decodedSize` bytes of `output`'s free capacity.
    ///
    /// The block may end with a literal run, as LZ4's format requires, or with a match that fills the output.
    ///
    /// - Parameters:
    ///   - input: The block, and nothing else.
    ///   - decodedSize: The decoded size, which the container states (raw blocks don't).
    ///   - output: Where to append the decoded bytes; it needs room for `decodedSize` of them. Bytes of its free
    ///     capacity past those may be overwritten.
    /// - Throws: ``BytesError/insufficientCapacity`` if `output` has room for fewer than `decodedSize` bytes, or
    ///   the block decodes to more; ``BytesError/insufficientData`` if the input ends early (inside a sequence,
    ///   or before `decodedSize` bytes); ``BytesError/invalidValue`` for a match offset of 0 or one reaching
    ///   before the output's start, or a negative `decodedSize`.
    public func decompressRaw(_ input: RawSpan, decodedSize: Int, into output: inout OutputRawSpan) throws(BytesError) {
        guard decodedSize >= 0 else { throw .invalidValue }
        guard decodedSize <= output.freeCapacity else { throw .insufficientCapacity }
        try unsafe LZBuffers.with(input, &output) { input, count, output, capacity throws(BytesError) -> ((), Int) in
            // Unsafe: pointers to the ends of the buffers. Safe: `count` and `capacity` are their sizes, and
            // `decodedSize <= capacity`.
            let blockEnd = unsafe output + decodedSize
            let end = try unsafe Self.decodeBlock(
                input, inputEnd: input + count, inputLimit: input + count,
                base: output, output: output, outputEnd: blockEnd, outputLimit: output + capacity
            )
            guard unsafe end == blockEnd else { throw .insufficientData }
            return ((), decodedSize)
        }
    }

    /// Decodes Compression's framed LZ4 stream (`COMPRESSION_LZ4`), from its first block through its `bv4$` end
    /// marker, into `output`'s free capacity.
    ///
    /// - Parameters:
    ///   - input: The stream, at its start. Bytes after its end marker are left alone.
    ///   - output: Where to append the decoded bytes; it needs room for all of them. Bytes of its free capacity
    ///     past them may be overwritten.
    /// - Returns: The number of input bytes decoded, through the end marker.
    /// - Throws: ``BytesError/insufficientData`` if the input ends early; ``BytesError/insufficientCapacity`` if
    ///   the output doesn't fit; ``BytesError/invalidValue`` for an unknown block magic or a corrupt block,
    ///   including one that doesn't decode to its stated size.
    public func decompressFramed(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        try unsafe LZBuffers.with(input, &output) { input, count, output, capacity throws(BytesError) -> (Int, Int) in
            try unsafe Self.decodeFramed(input, count: count, output: output, capacity: capacity)
        }
    }

    /// Block magics, as little-endian integers.
    enum Magic {
        static var compressed: UInt32 { 0x3134_7662 } // "bv41"
        static var stored: UInt32 { 0x2D34_7662 } // "bv4-"
        static var end: UInt32 { 0x2434_7662 } // "bv4$"
    }

    /// Decodes framed blocks from `input` into `output`.
    ///
    /// - Returns: The input consumed and the bytes written.
    static func decodeFramed(
        _ input: UnsafeRawPointer, count: Int, output: UnsafeMutableRawPointer, capacity: Int
    ) throws(BytesError) -> (Int, Int) {
        var position = 0
        var end = 0
        // Unsafe: header loads, a copy, and pointers into the buffers. Safe: each is preceded by a check that the
        // input holds the bytes read and the output has room for the bytes written.
        while true {
            guard count &- position >= 4 else { throw .insufficientData }
            let magic = UInt32(littleEndian: unsafe input.loadUnaligned(fromByteOffset: position, as: UInt32.self))
            if magic == Magic.end {
                return (position &+ 4, end)
            } else if magic == Magic.compressed {
                guard count &- position >= 12 else { throw .insufficientData }
                let decoded = Int(UInt32(littleEndian: unsafe input.loadUnaligned(fromByteOffset: position &+ 4, as: UInt32.self)))
                let encoded = Int(UInt32(littleEndian: unsafe input.loadUnaligned(fromByteOffset: position &+ 8, as: UInt32.self)))
                position &+= 12
                guard encoded <= count &- position else { throw .insufficientData }
                guard decoded <= capacity &- end else { throw .insufficientCapacity }
                let blockEnd = unsafe output + (end &+ decoded)
                do throws(BytesError) {
                    let reached = try unsafe decodeBlock(
                        input + position, inputEnd: input + (position &+ encoded), inputLimit: input + count,
                        base: output, output: output + end, outputEnd: blockEnd, outputLimit: output + capacity
                    )
                    guard unsafe reached == blockEnd else { throw BytesError.invalidValue }
                } catch {
                    throw .invalidValue // The block disagrees with its header.
                }
                position &+= encoded
                end &+= decoded
            } else if magic == Magic.stored {
                guard count &- position >= 8 else { throw .insufficientData }
                let size = Int(UInt32(littleEndian: unsafe input.loadUnaligned(fromByteOffset: position &+ 4, as: UInt32.self)))
                position &+= 8
                guard size <= count &- position else { throw .insufficientData }
                guard size <= capacity &- end else { throw .insufficientCapacity }
                unsafe LZCopy.exact(output + end, input + position, size)
                position &+= size
                end &+= size
            } else {
                throw .invalidValue
            }
        }
    }

    /// Decodes one block's sequences, from `input` until `inputEnd`, into `output`, which must not pass
    /// `outputEnd`.
    ///
    /// The block ends where the input does, after a sequence's literals or its match. Literals and matches are
    /// copied 16 bytes at a time while `inputLimit` and `outputLimit` (the ends of the buffers, at or past the
    /// block's) leave room for the overrun.
    ///
    /// - Parameters:
    ///   - base: The first byte matches may reach back to.
    /// - Returns: Where the output ended.
    /// - Throws: ``BytesError/insufficientData`` if the input ends inside a sequence;
    ///   ``BytesError/insufficientCapacity`` if the output would pass `outputEnd`; ``BytesError/invalidValue``
    ///   for an offset of 0 or one reaching before `base`.
    @inline(never)
    static func decodeBlock(
        _ input: UnsafeRawPointer, inputEnd: UnsafeRawPointer, inputLimit: UnsafeRawPointer,
        base: UnsafeMutableRawPointer, output: UnsafeMutableRawPointer, outputEnd: UnsafeMutableRawPointer,
        outputLimit: UnsafeMutableRawPointer
    ) throws(BytesError) -> UnsafeMutableRawPointer {
        // Unsafe: loads from the input, and copies into the output. Safe: each load is preceded by a check that
        // it's before `inputEnd`, and each copy by one that it fits before `outputEnd`; wild copies run only while
        // `inputFast` and `outputFast` (at most the limits less the overrun) leave room for what they write and
        // read past the bytes copied; matches start at `base` or later (checked).
        var ip = unsafe input
        var op = unsafe output
        // Where the 16-byte copies may run: literals ending before `inputFast` and `outputFast`, matches before
        // `outputFast`. Both are within the block, and leave room for the overrun in the buffers; with less room
        // than the overrun they're the buffer's start. The comparisons against them are strict, so that then no
        // copy (not even an empty one, which still moves 16 bytes) takes the fast path: `ip` is never before the
        // start. (With `<=`, empty literals near the end copied 16 bytes, and the shortcut wrote 46, past the
        // output. Offsets from the buffers' starts, compared with `<=`, fixed it too, for 10–17% more
        // instructions: the offsets were recomputed for every sequence.)
        let inputFast = unsafe min(inputEnd, inputLimit - min(LZCopy.overrun, inputLimit - input))
        let outputFast = unsafe min(outputEnd, outputLimit - min(LZCopy.overrun, outputLimit - output))
        // The shortcut, lz4's own: a sequence of at most 14 literals and a match of at most 18 bytes, starting
        // more than 32 bytes before `inputFast` and 48 before `outputFast`, is a token, a 16-byte literal move, an
        // offset, and two 16-byte match moves (or the short-offset copy), with no other checks: its offset is
        // in the input (14 literals end 17 bytes before `inputFast`), and its 32 bytes of match fit. (The buffer's
        // start, the same way, when there's less room: then no sequence takes it.)
        let inputShortcut = unsafe inputFast - min(32, inputFast - input)
        let outputShortcut = unsafe outputFast - min(48, outputFast - output)
        while true {
            guard unsafe ip < inputEnd else { return unsafe op } // The block ends after a match.
            let token = Int(unsafe ip.load(as: UInt8.self))
            unsafe ip += 1
            // (Chaining shortcut sequences without the end check above cost 2–3% more instructions: LLVM laid
            // the loop out worse.)
            if zstdLikely(unsafe ip < inputShortcut && op < outputShortcut && token & 0xF0 != 0xF0 && token & 0x0F != 0x0F) {
                let literalLength = token &>> 4
                unsafe LZCopy.copy16(op, ip)
                unsafe ip += literalLength
                unsafe op += literalLength
                let offset = Int(UInt16(littleEndian: unsafe ip.loadUnaligned(as: UInt16.self)))
                unsafe ip += 2
                guard unsafe UInt(bitPattern: offset &- 1) < UInt(bitPattern: op - base) else { throw .invalidValue }
                let matchLength = token & 0x0F &+ 4
                if zstdLikely(offset >= 16) {
                    unsafe LZCopy.copy16(op, op - offset)
                    unsafe LZCopy.copy16(op + 16, op + (16 &- offset))
                } else {
                    unsafe ZstdCopy.overlapping(op, offset: offset, count: matchLength)
                }
                unsafe op += matchLength
                continue
            }

            // Literals.
            var literalLength = token &>> 4
            if zstdUnlikely(literalLength == 15) {
                try unsafe readLength(&literalLength, &ip, inputEnd)
            }
            if zstdLikely(unsafe literalLength < inputFast - ip && literalLength < outputFast - op) {
                unsafe LZCopy.wild(op, ip, literalLength)
            } else {
                guard unsafe literalLength <= inputEnd - ip else { throw .insufficientData }
                guard unsafe literalLength <= outputEnd - op else { throw .insufficientCapacity }
                unsafe LZCopy.exact(op, ip, literalLength)
            }
            unsafe ip += literalLength
            unsafe op += literalLength

            // The match: an offset, unless the block ends here.
            let left = unsafe inputEnd - ip
            if zstdUnlikely(left < 2) {
                if left == 0 { return unsafe op }
                throw .insufficientData
            }
            let offset = Int(UInt16(littleEndian: unsafe ip.loadUnaligned(as: UInt16.self)))
            unsafe ip += 2
            var matchLength = token & 15
            if zstdUnlikely(matchLength == 15) {
                try unsafe readLength(&matchLength, &ip, inputEnd)
            }
            matchLength &+= 4
            // 1 through the bytes written: one unsigned comparison.
            guard unsafe UInt(bitPattern: offset &- 1) < UInt(bitPattern: op - base) else { throw .invalidValue }
            if zstdLikely(unsafe matchLength < outputFast - op) {
                unsafe LZCopy.match(op, offset: offset, count: matchLength)
            } else {
                guard unsafe matchLength <= outputEnd - op else { throw .insufficientCapacity }
                unsafe LZCopy.exactMatch(op, offset: offset, count: matchLength)
            }
            unsafe op += matchLength
        }
    }

    /// Adds a length's continuation bytes to `length`: each is added, and a 255 means another follows.
    ///
    /// `@inline(always)`: with `@inline(__always)` it stayed a call, which kept the input position in memory for
    /// the whole loop.
    @inline(always)
    static func readLength(_ length: inout Int, _ ip: inout UnsafeRawPointer, _ end: UnsafeRawPointer) throws(BytesError) {
        // Unsafe: byte loads. Safe: each is checked to be before `end`.
        var byte: Int
        repeat {
            guard unsafe ip < end else { throw .insufficientData }
            byte = Int(unsafe ip.load(as: UInt8.self))
            unsafe ip += 1
            length &+= byte
        } while byte == 255
    }
}

