internal import Bytes

// A compressed block's literals section (RFC 8878, 3.1.1.3.1): raw, RLE, or Huffman-coded in one stream
// or four, with a new tree or the previous block's.

extension ZstdHuffman {
    /// Decodes symbols from `bits` into `output` up to `end` with a single-symbol table, as libzstd's
    /// `HUF_decodeStreamX1`: four symbols per reload while the stream lasts, then the rest from what's
    /// buffered.
    @inline(__always)
    static func decodeStreamX1(
        _ bits: inout ZstdReverseBits, table: UnsafePointer<UInt16>, tableLog: Int,
        from output: UnsafeMutablePointer<UInt8>, to end: UnsafeMutablePointer<UInt8>
    ) {
        // Unsafe: table lookups and stores. Safe: indices are `tableLog`-bit values, within the table, and
        // every store is below `end`, which the caller bounds.
        var pointer = unsafe output
        @inline(__always)
        func symbol() {
            let entry = unsafe table[bits.peek(tableLog)]
            bits.consumed &+= Int(entry & 0xFF)
            unsafe pointer.pointee = UInt8(truncatingIfNeeded: entry &>> 8)
            unsafe pointer += 1
        }
        if unsafe end - pointer > 3 {
            while bits.reloadStatus() == .unfinished, unsafe pointer < end - 3 {
                symbol()
                symbol()
                symbol()
                symbol()
            }
        } else {
            _ = bits.reloadStatus()
        }
        while unsafe pointer < end {
            symbol()
        }
    }

    /// Decodes a single Huffman stream of `count` bytes into `size` bytes at `output`.
    ///
    /// - Throws: ``BytesError/invalidValue`` if the stream isn't consumed exactly.
    static func decodeOneStream(
        _ source: UnsafeRawPointer, count: Int, table: UnsafeRawPointer, tableLog: Int, double: Bool,
        into output: UnsafeMutablePointer<UInt8>, size: Int
    ) throws(BytesError) {
        // Unsafe: the stream and output. Safe: the caller vouches for `count` bytes at `source` and `size`
        // at `output`.
        var bits = try unsafe ZstdReverseBits(source, count: count)
        if double {
            unsafe decodeStreamX2(&bits, table: table.assumingMemoryBound(to: UInt32.self), tableLog: tableLog, from: output, to: output + size)
        } else {
            unsafe decodeStreamX1(&bits, table: table.assumingMemoryBound(to: UInt16.self), tableLog: tableLog, from: output, to: output + size)
        }
        guard bits.isAtEnd else { throw .invalidValue }
    }

    /// Decodes four Huffman streams (a 6-byte jump table, then the streams) into `size` bytes at `output`,
    /// each stream filling a quarter.
    ///
    /// With 11-bit tables and streams of 8 bytes or more, the four are decoded together in libzstd's fast
    /// loop (`HUF_decompress4X1_usingDTable_internal_fast_c_loop`): five symbols per stream per round, each
    /// stream's bits held with a sentinel bit below them, so the trailing zero count says how many were
    /// consumed and a reload is a load, an OR, and a shift. Rounds run in batches whose count is worked out
    /// beforehand from the input and output left, so the loop itself checks nothing. Each stream's last
    /// symbols, and small or 12-bit cases, are decoded one stream at a time.
    ///
    /// - Throws: ``BytesError/invalidValue`` if the jump table doesn't fit or a stream isn't consumed exactly.
    ///
    /// With a double-symbol table (`double`), the same, with libzstd's X2 loop: up to two symbols per lookup.
    static func decodeFourStreams(
        _ source: UnsafeRawPointer, count: Int, table: UnsafeRawPointer, tableLog: Int, double: Bool,
        into output: UnsafeMutablePointer<UInt8>, size: Int
    ) throws(BytesError) {
        guard count >= 10, size >= 6 else { throw .invalidValue }
        // Unsafe: loads of the jump table, then pointers within the `count` bytes at `source` and the `size`
        // at `output`, each checked against those bounds below.
        let length1 = Int(UInt16(littleEndian: unsafe source.loadUnaligned(as: UInt16.self)))
        let length2 = Int(UInt16(littleEndian: unsafe source.loadUnaligned(fromByteOffset: 2, as: UInt16.self)))
        let length3 = Int(UInt16(littleEndian: unsafe source.loadUnaligned(fromByteOffset: 4, as: UInt16.self)))
        let length4 = count &- 6 &- length1 &- length2 &- length3
        guard length1 > 0, length2 > 0, length3 > 0, length4 > 0 else { throw .invalidValue }
        let start1 = 6
        let start2 = start1 &+ length1
        let start3 = start2 &+ length2
        let start4 = start3 &+ length3
        let segment = (size &+ 3) &>> 2
        let lengths = (length1, length2, length3, length4)
        let starts = (start1, start2, start3, start4)

        var done = (0, 0, 0, 0) // Symbols decoded per stream by the fast loop.
        var unread = (0, 0, 0, 0)
        if tableLog == fastTableLog, length1 >= 8, length2 >= 8, length3 >= 8, length4 >= 8, 3 &* segment < size {
            let result = if double {
                try unsafe decodeFourStreamsFastDouble(
                    source, starts: starts, count: count, table: table.assumingMemoryBound(to: UInt32.self), output: output,
                    size: size, segment: segment
                )
            } else {
                try unsafe decodeFourStreamsFast(
                    source, starts: starts, count: count, table: table.assumingMemoryBound(to: UInt16.self), output: output,
                    size: size, segment: segment
                )
            }
            done = result.done
            unread = result.unread
        } else {
            unread = (length1 &* 8, length2 &* 8, length3 &* 8, length4 &* 8)
        }

        // Each stream's remaining symbols, through a bit reader positioned where the fast loop left it.
        for stream in 0..<4 {
            let start: Int
            let length: Int
            let decoded: Int
            let left: Int
            switch stream {
            case 0: (start, length, decoded, left) = (starts.0, lengths.0, done.0, unread.0)
            case 1: (start, length, decoded, left) = (starts.1, lengths.1, done.1, unread.1)
            case 2: (start, length, decoded, left) = (starts.2, lengths.2, done.2, unread.2)
            default: (start, length, decoded, left) = (starts.3, lengths.3, done.3, unread.3)
            }
            let segmentStart = min(stream &* segment, size)
            let segmentEnd = stream == 3 ? size : min(segmentStart &+ segment, size)
            guard left >= 0, left <= length &* 8, segmentStart &+ decoded <= segmentEnd else { throw .invalidValue }
            var bits: ZstdReverseBits
            if left == length &* 8 {
                bits = try unsafe ZstdReverseBits(source + start, count: length)
            } else {
                bits = unsafe ZstdReverseBits(source + start, count: length, unread: left)
            }
            if double {
                unsafe decodeStreamX2(
                    &bits, table: table.assumingMemoryBound(to: UInt32.self), tableLog: tableLog, from: output + segmentStart + decoded,
                    to: output + segmentEnd
                )
            } else {
                unsafe decodeStreamX1(
                    &bits, table: table.assumingMemoryBound(to: UInt16.self), tableLog: tableLog, from: output + segmentStart + decoded,
                    to: output + segmentEnd
                )
            }
            guard bits.isAtEnd else { throw .invalidValue }
        }
    }

    /// The four-stream fast loop. Returns how many symbols each stream decoded and how many of its bits are
    /// left.
    ///
    /// Bounds: each round reads at most 55 bits (7 bytes) per stream and writes 5 bytes per stream. A batch
    /// of `n` rounds starts only when stream 0's load position is `7n` bytes above the section's start, and
    /// streams 1 to 3 are at or above stream 0 (so they are too); and stream 3's output (the shortest
    /// segment) has `5n` bytes left, so the others, which advance in step, stay within their segments.
    @inline(__always)
    static func decodeFourStreamsFast(
        _ source: UnsafeRawPointer, starts: (Int, Int, Int, Int), count: Int, table: UnsafePointer<UInt16>,
        output: UnsafeMutablePointer<UInt8>, size: Int, segment: Int
    ) throws(BytesError) -> (done: (Int, Int, Int, Int), unread: (Int, Int, Int, Int)) {
        // Unsafe: all loads are 8 bytes at positions within the section (see above), stores within `output`.
        var ip0 = starts.1 &- 8
        var ip1 = starts.2 &- 8
        var ip2 = starts.3 &- 8
        var ip3 = count &- 8
        @inline(__always)
        func load(_ position: Int) -> UInt64 {
            // Unsafe and safe as the function's comment says: positions within the section, 8 bytes before its
            // streams' ends.
            UInt64(littleEndian: unsafe source.loadUnaligned(fromByteOffset: position, as: UInt64.self))
        }
        @inline(__always)
        func initial(_ position: Int) throws(BytesError) -> UInt64 {
            let last = UInt8(truncatingIfNeeded: load(position) &>> 56)
            guard last != 0 else { throw .invalidValue } // No end marker.
            return (load(position) | 1) &<< UInt64(last.leadingZeroBitCount &+ 1)
        }
        var bits0 = try initial(ip0)
        var bits1 = try initial(ip1)
        var bits2 = try initial(ip2)
        var bits3 = try initial(ip3)
        var op0 = 0
        var op1 = segment
        var op2 = 2 &* segment
        var op3 = 3 &* segment

        while true {
            let outputRounds = (size &- op3) / 5
            let inputRounds = ip0 / 7
            let rounds = min(outputRounds, inputRounds)
            if rounds == 0 { break }
            // Streams whose load positions crossed are corrupt: stop, and let the checks below throw.
            if ip1 < ip0 || ip2 < ip1 || ip3 < ip2 { break }
            let limit = op3 &+ rounds &* 5
            repeat {
                @inline(__always)
                func decode(_ bits: inout UInt64, _ op: Int, _ index: Int) {
                    // Unsafe: a lookup and a store. Safe: the index is the top 11 bits, within the table's 2048
                    // entries; `op + index` stays below `limit`, within `output` (the rounds were counted for it).
                    let entry = unsafe table[Int(truncatingIfNeeded: bits &>> 53)]
                    bits &<<= UInt64(entry & 0x3F)
                    unsafe output[op &+ index] = UInt8(truncatingIfNeeded: entry &>> 8)
                }
                for index in 0..<5 {
                    decode(&bits0, op0, index)
                    decode(&bits1, op1, index)
                    decode(&bits2, op2, index)
                    decode(&bits3, op3, index)
                }
                @inline(__always)
                func reload(_ bits: inout UInt64, _ ip: inout Int) {
                    let consumed = bits.trailingZeroBitCount
                    ip &-= consumed &>> 3
                    bits = (load(ip) | 1) &<< UInt64(consumed & 7)
                }
                reload(&bits0, &ip0)
                reload(&bits1, &ip1)
                reload(&bits2, &ip2)
                reload(&bits3, &ip3)
                op0 &+= 5
                op1 &+= 5
                op2 &+= 5
                op3 &+= 5
            } while op3 < limit
        }

        // Unread bits: the stream's bytes below the load position, plus the container's bits above the
        // sentinel, less the consumed ones.
        @inline(__always)
        func unread(_ bits: UInt64, _ ip: Int, _ start: Int) -> Int {
            (ip &- start) &* 8 &+ 64 &- bits.trailingZeroBitCount
        }
        return (
            (op0, op1 &- segment, op2 &- 2 &* segment, op3 &- 3 &* segment),
            (unread(bits0, ip0, starts.0), unread(bits1, ip1, starts.1), unread(bits2, ip2, starts.2), unread(bits3, ip3, starts.3))
        )
    }
}

/// Where a block's literals are: in the decoder's literal buffer, or in the input itself (raw literals with
/// room after them for wild copies).
@unsafe
struct ZstdLiterals {
    var base: UnsafeRawPointer
    var count: Int
}

extension ZstdBlockDecoder {
    /// Decodes a compressed block's literals section at `source`.
    ///
    /// - Parameters:
    ///   - source: The block's first byte.
    ///   - available: The block's size.
    ///   - blockSizeMaximum: The frame's largest block.
    /// - Returns: The literals and the section's size.
    /// - Throws: ``BytesError/invalidValue`` for a malformed section.
    mutating func decodeLiterals(
        _ source: UnsafeRawPointer, available: Int, blockSizeMaximum: Int
    ) throws(BytesError) -> (literals: ZstdLiterals, size: Int) {
        guard available >= 2 else { throw .invalidValue }
        // Unsafe: header loads, each within `available` bytes, checked first.
        let header = Int(unsafe source.load(as: UInt8.self))
        let type = header & 3
        let sizeFormat = (header &>> 2) & 3
        @inline(__always)
        func byte(_ index: Int) -> Int {
            // Unsafe and safe as the header loads above: callers check `available` before each index.
            Int(unsafe source.load(fromByteOffset: index, as: UInt8.self))
        }
        let literalBuffer = unsafe workspace.pointer(ZstdWorkspace.literalsOffset)

        if type < 2 { // Raw or RLE.
            let headerSize: Int
            let size: Int
            switch sizeFormat {
            case 0, 2:
                headerSize = 1
                size = header &>> 3
            case 1:
                headerSize = 2
                size = (header | byte(1) &<< 8) &>> 4
            default:
                guard available >= 3 else { throw .invalidValue }
                headerSize = 3
                size = (header | byte(1) &<< 8 | byte(2) &<< 16) &>> 4
            }
            guard size <= blockSizeMaximum else { throw .invalidValue }
            if type == 0 {
                guard headerSize &+ size <= available else { throw .invalidValue }
                if headerSize &+ size &+ Zstd.wildCopyOverrun <= available {
                    // Wild copies may read 32 bytes past the literals: the rest of the block.
                    return unsafe (ZstdLiterals(base: unsafe source + headerSize, count: size), headerSize &+ size)
                }
                // Unsafe: a copy into the literal buffer. Safe: `size` is at most the block maximum, which the
                // buffer holds, and the source bytes are within the block (checked).
                unsafe literalBuffer.copyMemory(from: source + headerSize, byteCount: size)
                return unsafe (ZstdLiterals(base: UnsafeRawPointer(literalBuffer), count: size), headerSize &+ size)
            }
            guard headerSize &+ 1 <= available else { throw .invalidValue }
            // Unsafe: filling the literal buffer. Safe: `size` is at most the block maximum.
            unsafe literalBuffer.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: byte(headerSize)), count: size)
            return unsafe (ZstdLiterals(base: UnsafeRawPointer(literalBuffer), count: size), headerSize &+ 1)
        }

        // Huffman-coded: a new tree (2) or the previous one (3).
        guard available >= 5 else { throw .invalidValue }
        let headerSize: Int
        let size: Int
        let compressedSize: Int
        let isSingleStream = sizeFormat == 0
        let fields = header | byte(1) &<< 8 | byte(2) &<< 16 | byte(3) &<< 24 | byte(4) &<< 32
        switch sizeFormat {
        case 0, 1:
            headerSize = 3
            size = (fields &>> 4) & 0x3FF
            compressedSize = (fields &>> 14) & 0x3FF
        case 2:
            headerSize = 4
            size = (fields &>> 4) & 0x3FFF
            compressedSize = (fields &>> 18) & 0x3FFF
        default:
            headerSize = 5
            size = (fields &>> 4) & 0x3FFFF
            compressedSize = (fields &>> 22) & 0x3FFFF
        }
        guard size <= blockSizeMaximum, isSingleStream || size >= 6, headerSize &+ compressedSize <= available else {
            throw .invalidValue
        }
        var streams = unsafe source + headerSize
        var streamsSize = compressedSize
        if type == 2 {
            let weightTable = unsafe workspace.pointer(ZstdWorkspace.weightTableOffset).assumingMemoryBound(to: UInt32.self)
            let scratch = unsafe ZstdTableScratch(workspace)
            let (symbolCount, treeLog, treeSize) = try unsafe ZstdHuffman.readWeights(
                streams, available: compressedSize, weightTable: weightTable, scratch: scratch
            )
            guard treeSize < compressedSize else { throw .invalidValue }
            let table = unsafe workspace.pointer(ZstdWorkspace.huffmanOffset)
            // As libzstd: one stream always gets a single-symbol table; four get a double-symbol one when its
            // cost model says it decodes these literals faster, building time included.
            huffmanIsDouble = !isSingleStream && ZstdHuffman.prefersDoubleTable(size: size, compressedSize: compressedSize)
            if huffmanIsDouble {
                huffmanTableLog = unsafe ZstdHuffman.buildDoubleTable(
                    table.assumingMemoryBound(to: UInt32.self), weights: scratch.weights, symbolCount: symbolCount,
                    tableLog: treeLog, sorted: scratch.ordered
                )
            } else {
                huffmanTableLog = unsafe ZstdHuffman.buildSingleTable(
                    table.assumingMemoryBound(to: UInt16.self), weights: scratch.weights, symbolCount: symbolCount, tableLog: treeLog
                )
            }
            unsafe streams += treeSize
            streamsSize &-= treeSize
        } else {
            guard huffmanTableLog > 0 else { throw .invalidValue } // No previous tree in this frame.
        }
        let table = unsafe UnsafeRawPointer(workspace.pointer(ZstdWorkspace.huffmanOffset))
        let output = unsafe literalBuffer.assumingMemoryBound(to: UInt8.self)
        // Unsafe: decoding into the literal buffer. Safe: `size` is at most the block maximum, and the streams
        // are within the section (checked).
        if isSingleStream {
            try unsafe ZstdHuffman.decodeOneStream(
                streams, count: streamsSize, table: table, tableLog: huffmanTableLog, double: huffmanIsDouble, into: output, size: size
            )
        } else {
            try unsafe ZstdHuffman.decodeFourStreams(
                streams, count: streamsSize, table: table, tableLog: huffmanTableLog, double: huffmanIsDouble, into: output, size: size
            )
        }
        return unsafe (ZstdLiterals(base: UnsafeRawPointer(literalBuffer), count: size), headerSize &+ compressedSize)
    }
}
