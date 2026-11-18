internal import Bytes

// The sequence loop: decode a sequence's three values from the FSE states and the backward bitstream, then
// copy its literals and its match. Positions are integer offsets into the output and literal buffers, so
// every bound is an integer comparison; memory is touched through pointers formed only after the checks.

/// Copies used by the sequence loop, all through raw pointers whose bounds the callers establish.
enum ZstdCopy {
    @inline(__always)
    static func copy16(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer) {
        // Unsafe: a 16-byte move. Safe: the callers keep both within their buffers.
        unsafe destination.storeBytes(of: source.loadUnaligned(as: SIMD16<UInt8>.self), as: SIMD16<UInt8>.self)
    }

    @inline(__always)
    static func copy8(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer) {
        // Unsafe: an 8-byte move. Safe: the callers keep both within their buffers.
        unsafe destination.storeBytes(of: source.loadUnaligned(as: UInt64.self), as: UInt64.self)
    }

    /// Copies `count` bytes 16 at a time, as libzstd's `ZSTD_wildcopy`: writes up to 32 bytes past them, and
    /// reads as far past the source. The source must end at least 16 bytes before the destination starts, or
    /// be in another buffer.
    @inline(__always)
    static func wild16(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer, _ count: Int) {
        // Unsafe: 16-byte moves. Safe: the callers leave 32 bytes of room past both ends.
        unsafe copy16(destination, source)
        guard count > 16 else { return }
        var offset = 16
        repeat {
            unsafe copy16(destination + offset, source + offset)
            unsafe copy16(destination + (offset &+ 16), source + (offset &+ 16))
            offset &+= 32
        } while offset < count
    }

    /// Copies a match of `count` bytes from `offset` back, as libzstd's `ZSTD_overlapCopy8` and the 8-byte
    /// `ZSTD_wildcopy`: offsets below 8 are first spread to 8 or more with two 4-byte moves. Writes up to 8
    /// bytes past the match.
    @inline(__always)
    static func overlapping(_ destination: UnsafeMutableRawPointer, offset: Int, count: Int) {
        // Unsafe: moves within the output. Safe: the source starts `offset >= 1` bytes back, in the history
        // (checked by the caller), each move reads only bytes already written, and the caller leaves room
        // for the overrun.
        var source = unsafe UnsafeRawPointer(destination - offset)
        if offset < 8 {
            // libzstd's dec32table and dec64table, a byte per offset.
            let add = Int(truncatingIfNeeded: (0x0404_0404_0102_0100 as UInt64) &>> UInt64(offset &<< 3) & 0xFF)
            let subtract = Int(truncatingIfNeeded: (0x0B0A_0908_0708_0808 as UInt64) &>> UInt64(offset &<< 3) & 0xFF)
            unsafe destination.storeBytes(of: source.load(as: UInt8.self), as: UInt8.self)
            unsafe destination.storeBytes(of: source.load(fromByteOffset: 1, as: UInt8.self), toByteOffset: 1, as: UInt8.self)
            unsafe destination.storeBytes(of: source.load(fromByteOffset: 2, as: UInt8.self), toByteOffset: 2, as: UInt8.self)
            unsafe destination.storeBytes(of: source.load(fromByteOffset: 3, as: UInt8.self), toByteOffset: 3, as: UInt8.self)
            unsafe source += add
            unsafe destination.storeBytes(of: source.loadUnaligned(as: UInt32.self), toByteOffset: 4, as: UInt32.self)
            unsafe source -= subtract
        } else {
            unsafe copy8(destination, source)
        }
        guard count > 8 else { return }
        // Now 8 or more bytes apart.
        var index = 8
        repeat {
            unsafe copy8(destination + index, source + index)
            index &+= 8
        } while index < count
    }

    /// Copies `count` bytes from `source` to `destination` in `buffer`, forward, as a match does: when they
    /// overlap, bytes written earlier are read again. Never writes past `destination + count + 32`, nor past
    /// `limit`.
    static func match(in buffer: UnsafeMutableRawPointer, from source: Int, to destination: Int, count: Int, limit: Int) {
        let distance = destination &- source
        // Unsafe: moves within the buffer. Safe: the callers checked `source >= 0` and
        // `destination + count <= limit`, and the wild forms run only with 32 bytes of room past the match.
        if destination &+ count &+ Zstd.wildCopyOverrun <= limit {
            if distance >= 16 {
                unsafe wild16(buffer + destination, buffer + source, count)
            } else {
                unsafe overlapping(buffer + destination, offset: distance, count: count)
            }
            return
        }
        var index = 0
        if distance >= 8 {
            while index &+ 8 <= count {
                unsafe copy8(buffer + (destination &+ index), buffer + (source &+ index))
                index &+= 8
            }
        }
        while index < count {
            unsafe (buffer + (destination &+ index)).storeBytes(of: (buffer + (source &+ index)).load(as: UInt8.self), as: UInt8.self)
            index &+= 1
        }
    }
}

extension ZstdBlockDecoder {
    /// Decodes `count` sequences from the bitstream at `stream` and executes them into `output` from `start`.
    ///
    /// Register pressure decides this loop's speed: it keeps a bitstream, three FSE states, three repeat
    /// offsets, and its positions and limits live. So the three tables are indexed from one pointer (their
    /// states are absolute entry indices in the workspace), and the output and literal positions are pointers.
    /// Bounds are checked as distances between pointers in the same buffer.
    ///
    /// - Parameters:
    ///   - tables: The workspace, as 8-byte entries.
    ///   - literalLengthTable: The literal length table's first entry, and its accuracy log; likewise the others.
    /// - Returns: The output's new end, and how many literals the sequences used.
    /// - Throws: ``BytesError/invalidValue`` for corrupt sequences (a bitstream not consumed exactly, literals
    ///   or history overrun), ``BytesError/insufficientCapacity`` if the output reaches `limit`.
    @inline(never)
    static func executeSequences(
        count: Int, stream: UnsafeRawPointer, streamSize: Int, tables: UnsafePointer<UInt64>,
        literalLengthTable: (index: Int, log: Int), offsetTable: (index: Int, log: Int), matchLengthTable: (index: Int, log: Int),
        literals: ZstdLiterals, output: UnsafeMutableRawPointer, at start: Int, limit: Int,
        history: ZstdHistory, repeatOffsets: inout (Int, Int, Int)
    ) throws(BytesError) -> (end: Int, literalPosition: Int) {
        // Unsafe: the bitstream reader, table lookups, and copies. Safe: the reader stays within the stream;
        // FSE states are absolute indices within each table's region of the workspace (by construction: an
        // entry's next state plus its state bits stays below the table's end); copies are bounds-checked as
        // described at each.
        var bits = try unsafe ZstdReverseBits(stream, count: streamSize)
        var literalLengthState = literalLengthTable.index &+ bits.read(literalLengthTable.log)
        bits.reload()
        var offsetState = offsetTable.index &+ bits.read(offsetTable.log)
        bits.reload()
        var matchLengthState = matchLengthTable.index &+ bits.read(matchLengthTable.log)
        bits.reload()
        var (repeat0, repeat1, repeat2) = repeatOffsets
        var literal = unsafe literals.base
        let literalEnd = unsafe literals.base + literals.count
        let prefixStart = unsafe output + history.prefixStart
        var position = unsafe output + start
        // Sequences ending at or before `wildEnd` take the fast path: their wild copies' overrun stays below
        // `limit`. (With less than that room in all, none do.)
        let wildEnd = unsafe limit &- start >= Zstd.wildCopyOverrun ? output + (limit &- Zstd.wildCopyOverrun) : output + start
        var remaining = count

        repeat {
            let literalLengthEntry = unsafe tables[literalLengthState]
            let matchLengthEntry = unsafe tables[matchLengthState]
            let offsetEntry = unsafe tables[offsetState]
            let literalLengthBase = Int(truncatingIfNeeded: literalLengthEntry &>> 32)
            let literalLengthBits = Int(truncatingIfNeeded: literalLengthEntry &>> 16) & 0xFF
            let matchLengthBits = Int(truncatingIfNeeded: matchLengthEntry &>> 16) & 0xFF
            let offsetBits = Int(truncatingIfNeeded: offsetEntry &>> 16) & 0xFF
            let offsetBase = Int(truncatingIfNeeded: offsetEntry &>> 32)

            // The offset: a new one (codes 2 and up), or one of the three repeat offsets.
            var offset: Int
            if offsetBits > 1 {
                offset = offsetBase &+ bits.readFast(offsetBits)
                repeat2 = repeat1
                repeat1 = repeat0
                repeat0 = offset
            } else {
                let noLiterals = literalLengthBase == 0
                if offsetBits == 0 {
                    // Repeat offset 1, or 2 when there are no literals (swapping the two).
                    offset = noLiterals ? repeat1 : repeat0
                    if noLiterals {
                        repeat1 = repeat0
                        repeat0 = offset
                    }
                } else {
                    let index = offsetBase &+ (noLiterals ? 1 : 0) &+ bits.readFast(1)
                    var value = index == 3 ? repeat0 &- 1 : (index == 1 ? repeat1 : repeat2)
                    if value == 0 { value = Int.max } // Corrupt: fails the history check below.
                    if index != 1 { repeat2 = repeat1 }
                    repeat1 = repeat0
                    repeat0 = value
                    offset = value
                }
            }
            let matchLength = Int(truncatingIfNeeded: matchLengthEntry &>> 32) &+ bits.read(matchLengthBits)
            // 57 bits are buffered after a reload; the states take up to 26. Long extra bits need another reload.
            if offsetBits &+ matchLengthBits &+ literalLengthBits >= 31 {
                bits.reload()
            }
            let literalLength = literalLengthBase &+ bits.read(literalLengthBits)
            remaining &-= 1
            if remaining > 0 {
                literalLengthState = Int(truncatingIfNeeded: literalLengthEntry & 0xFFFF)
                    &+ bits.read(Int(truncatingIfNeeded: literalLengthEntry &>> 24) & 0xFF)
                matchLengthState = Int(truncatingIfNeeded: matchLengthEntry & 0xFFFF)
                    &+ bits.read(Int(truncatingIfNeeded: matchLengthEntry &>> 24) & 0xFF)
                offsetState = Int(truncatingIfNeeded: offsetEntry & 0xFFFF)
                    &+ bits.read(Int(truncatingIfNeeded: offsetEntry &>> 24) & 0xFF)
                bits.reload()
            }

            // Execute. The fast path needs the literals present (with the literal storage's 32 bytes of slack
            // after them), the match within the frame's history in this buffer, and the sequence to end by
            // `wildEnd`. Lengths are below 2^18 and offsets below 2^31, so the sums can't overflow.
            let sequenceLength = literalLength &+ matchLength
            let reach = unsafe position - prefixStart // How far back the history goes.
            if zstdLikely(
                unsafe literalLength <= literalEnd - literal && sequenceLength <= wildEnd - position
                    && offset <= reach &+ literalLength
            ) {
                unsafe ZstdCopy.copy16(position, literal)
                if zstdUnlikely(literalLength > 16) {
                    unsafe ZstdCopy.wild16(position + 16, literal + 16, literalLength &- 16)
                }
                let match = unsafe position + literalLength
                if zstdLikely(offset >= 16) {
                    unsafe ZstdCopy.wild16(match, match - offset, matchLength)
                } else {
                    unsafe ZstdCopy.overlapping(match, offset: offset, count: matchLength)
                }
            } else {
                try unsafe executeCarefully(
                    output: output, at: position - output, limit: limit, literals: literals.base,
                    at: literal - literals.base, end: literals.count, literalLength: literalLength,
                    matchLength: matchLength, offset: offset, history: history
                )
            }
            unsafe position += sequenceLength
            unsafe literal += literalLength
        } while remaining > 0

        guard bits.isAtEnd else { throw .invalidValue }
        repeatOffsets = (repeat0, repeat1, repeat2)
        return unsafe (position - output, literal - literals.base)
    }

    /// Executes a sequence the fast path can't: near the output's end, past the literals (corrupt), or
    /// reaching into the older segment of a wrapped window (or before the history: corrupt).
    @inline(never)
    static func executeCarefully(
        output: UnsafeMutableRawPointer, at position: Int, limit: Int, literals: UnsafeRawPointer, at literal: Int,
        end literalEnd: Int, literalLength: Int, matchLength: Int, offset: Int, history: ZstdHistory
    ) throws(BytesError) {
        guard literalLength <= literalEnd &- literal else { throw .invalidValue }
        guard literalLength &+ matchLength <= limit &- position else { throw .insufficientCapacity }
        // Unsafe: copies within the output and literal buffers. Safe: the literals are within theirs, and the
        // whole sequence fits before `limit` (both checked above); match sources are checked below.
        unsafe (output + position).copyMemory(from: literals + literal, byteCount: literalLength)
        var destination = position &+ literalLength
        var count = matchLength
        let prefixLength = destination &- history.prefixStart
        if offset > prefixLength {
            // Into the older segment: libzstd's "external dictionary".
            let back = offset &- prefixLength
            guard offset <= history.windowSize, back <= history.dictionaryEnd &- history.dictionaryStart else {
                throw .invalidValue
            }
            let first = min(count, back)
            unsafe (output + destination).copyMemory(from: output + (history.dictionaryEnd &- back), byteCount: first)
            destination &+= first
            count &-= first
            guard count > 0 else { return }
            // The rest continues from the start of the current segment.
            unsafe ZstdCopy.match(in: output, from: history.prefixStart, to: destination, count: count, limit: limit)
        } else {
            unsafe ZstdCopy.match(in: output, from: destination &- offset, to: destination, count: count, limit: limit)
        }
    }
}
