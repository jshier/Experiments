public import Bytes

// The .xz container (the xz file format, version 1.2.1): streams of a header, blocks, an index, and a footer,
// optionally separated by stream padding. Each block has a header (its sizes and filter chain), compressed
// data, padding to 4 bytes, and a check of its uncompressed data. Only the LZMA2 filter alone is supported.

/// The `.xz` format's constants.
enum XZ {
    /// A stream header's magic bytes, FD 37 7A 58 5A 00, as a little-endian integer of six bytes.
    static var headerMagic: UInt64 { 0x5A_587A_37FD }
    /// A stream header's or footer's size.
    static var headerSize: Int { 12 }
    /// The LZMA2 filter's ID.
    static var lzma2Filter: UInt64 { 0x21 }

    /// The size of a check of type `type` (the stream flags' low 4 bits).
    static func checkSize(_ type: Int) -> Int {
        type == 0 ? 0 : 4 &<< ((type &- 1) / 3)
    }

    /// The dictionary size an LZMA2 filter's properties byte gives.
    static func dictionarySize(_ byte: UInt8) throws(BytesError) -> Int {
        guard byte <= 40 else { throw .invalidValue }
        if byte == 40 { return 0xFFFF_FFFF }
        return (2 | Int(byte) & 1) &<< (Int(byte) / 2 &+ 11)
    }

    /// Checks the stream header at `header` (`headerSize` bytes): magic, flags, and the flags' CRC-32.
    ///
    /// - Returns: The check type.
    /// - Throws: ``BytesError/invalidValue`` for the wrong magic, reserved flags, or a reserved check type;
    ///   ``BytesError/mismatch`` for a wrong CRC.
    static func streamHeader(_ header: UnsafePointer<UInt8>) throws(BytesError) -> Int {
        // Unsafe: reads of the header's 12 bytes, which the caller checked are there.
        let magic = unsafe UInt64(UnsafeRawPointer(header).loadUnaligned(as: UInt32.self).littleEndian)
            | UInt64(UnsafeRawPointer(header + 4).loadUnaligned(as: UInt16.self).littleEndian) &<< 32
        guard magic == headerMagic else { throw .invalidValue }
        let flags = unsafe header + 6
        guard unsafe flags[0] == 0, unsafe flags[1] & 0xF0 == 0 else { throw .invalidValue }
        guard unsafe crc32(flags, 2) == UnsafeRawPointer(header + 8).loadUnaligned(as: UInt32.self).littleEndian else {
            throw .mismatch
        }
        let checkType = Int(unsafe flags[1])
        switch checkType {
        case 0, 1, 4, 10: return checkType
        default: throw .invalidValue // Reserved check types.
        }
    }

    /// Throws ``BytesError/invalidValue`` if `count` bytes at `bytes`, fewer than a stream header's, already show
    /// they don't start one.
    static func checkHeaderPrefix(_ bytes: UnsafePointer<UInt8>, count: Int) throws(BytesError) {
        // Unsafe: reads of the `count` bytes the caller has.
        for index in 0..<min(count, 6) where unsafe bytes[index] != UInt8(truncatingIfNeeded: headerMagic &>> UInt64(8 &* index)) {
            throw .invalidValue
        }
    }

    /// Checks the stream footer at `footer` (`headerSize` bytes): its CRC-32, the backward size against the
    /// index's `indexSize`, the flags against the header's `checkType`, and "YZ".
    ///
    /// - Throws: ``BytesError/invalidValue`` for the wrong magic; ``BytesError/mismatch`` for anything else.
    static func checkFooter(_ footer: UnsafePointer<UInt8>, indexSize: Int, checkType: Int) throws(BytesError) {
        // Unsafe: reads of the footer's 12 bytes, which the caller checked are there.
        guard unsafe footer[10] == 0x59, unsafe footer[11] == 0x5A else { throw .invalidValue }
        guard unsafe crc32(footer + 4, 6) == UnsafeRawPointer(footer).loadUnaligned(as: UInt32.self).littleEndian else {
            throw .mismatch
        }
        let backwardSize = unsafe UnsafeRawPointer(footer + 4).loadUnaligned(as: UInt32.self).littleEndian
        guard (Int(backwardSize) &+ 1) &* 4 == indexSize, unsafe footer[8] == 0, unsafe footer[9] == UInt8(checkType) else {
            throw .mismatch
        }
    }

    /// What a block header says.
    struct BlockHeader {
        var compressedSize: Int?
        var uncompressedSize: Int?
        /// The LZMA2 filter's dictionary size.
        var dictionarySize: Int
    }

    /// Parses the block header of `headerSize` bytes at `block`: its CRC-32, flags, sizes, and filter chain, which
    /// must be LZMA2 alone.
    ///
    /// - Throws: ``BytesError/mismatch`` for a wrong CRC; ``BytesError/invalidValue`` for reserved flags, other
    ///   filters, or nonzero padding; ``BytesError/insufficientData`` for fields running past the header.
    static func blockHeader(_ block: UnsafePointer<UInt8>, headerSize: Int) throws(BytesError) -> BlockHeader {
        // Unsafe: reads within the header's bytes, which the caller checked are there.
        let headerCRC = unsafe UnsafeRawPointer(block + (headerSize &- 4)).loadUnaligned(as: UInt32.self).littleEndian
        guard unsafe crc32(block, headerSize &- 4) == headerCRC else { throw .mismatch }
        var cursor = unsafe XZCursor(base: block, end: headerSize &- 4, position: 1)
        let flags = try cursor.byte()
        guard flags & 0x3C == 0 else { throw .invalidValue }
        var compressedSize: Int?
        var uncompressedSize: Int?
        if flags & 0x40 != 0 {
            let size = try cursor.integer()
            guard size > 0, size <= UInt64(Int.max) else { throw .invalidValue }
            compressedSize = Int(size)
        }
        if flags & 0x80 != 0 {
            let size = try cursor.integer()
            guard size <= UInt64(Int.max) else { throw .invalidValue }
            uncompressedSize = Int(size)
        }
        // One filter, LZMA2, whose one property byte is the dictionary size.
        guard flags & 3 == 0 else { throw .invalidValue }
        guard try cursor.integer() == lzma2Filter, try cursor.integer() == 1 else { throw .invalidValue }
        let dictionarySize = try dictionarySize(cursor.byte())
        while cursor.position < cursor.end {
            guard try cursor.byte() == 0 else { throw .invalidValue }
        }
        return BlockHeader(compressedSize: compressedSize, uncompressedSize: uncompressedSize, dictionarySize: dictionarySize)
    }

    /// The CRC-32 of `count` bytes at `bytes`.
    static func crc32(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> UInt32 {
        // Unsafe: a span over bytes the caller checked are in the input.
        CRC32.checksum(unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: bytes, count: count)))
    }
}

/// What a stream's blocks were, summarized as they're decoded and again as its index lists them, to compare
/// without keeping a list: the count, both sums, and a CRC of the records (as liblzma's `index_hash`).
struct XZIndexSummary: Equatable {
    var count = 0
    var unpaddedSum: UInt64 = 0
    var uncompressedSum: UInt64 = 0
    var crc = CRC32()

    mutating func add(unpadded: UInt64, uncompressed: UInt64) {
        count &+= 1
        unpaddedSum &+= unpadded
        uncompressedSum &+= uncompressed
        let record: InlineArray<2, UInt64> = [unpadded.littleEndian, uncompressed.littleEndian]
        crc.update(record.span.bytes)
    }
}

/// Reads the fields of a header or index: bytes and xz's variable-length integers, each checked against the end.
@safe
struct XZCursor {
    let base: UnsafePointer<UInt8>
    let end: Int
    var position: Int

    /// The next byte.
    mutating func byte() throws(BytesError) -> UInt8 {
        guard position < end else { throw .insufficientData }
        // Unsafe: a read below `end`, which the caller sets within the buffer.
        let value = unsafe base[position]
        position &+= 1
        return value
    }

    /// A variable-length integer: up to 9 bytes, 7 bits each, least significant first, and minimal (no
    /// trailing zero byte).
    mutating func integer() throws(BytesError) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<9 {
            let byte = try self.byte()
            value |= UInt64(byte & 0x7F) &<< UInt64(7 &* index)
            if byte & 0x80 == 0 {
                guard byte != 0 || index == 0 else { throw .invalidValue }
                return value
            }
        }
        throw .invalidValue
    }

    /// A little-endian 32-bit integer.
    mutating func uint32() throws(BytesError) -> UInt32 {
        guard end &- position >= 4 else { throw .insufficientData }
        // Unsafe: a read of four bytes below `end`.
        let value = UInt32(littleEndian: unsafe UnsafeRawPointer(base + position).loadUnaligned(as: UInt32.self))
        position &+= 4
        return value
    }
}

extension LZMA2Decoder {
    // MARK: .xz

    /// Decodes a complete `.xz` file into `output`'s free capacity: one or more streams (with stream padding
    /// between them), each of any number of blocks.
    ///
    /// Stream headers, footers, block headers, and indexes are checked: their CRC-32s, each block's sizes
    /// against its header and the index, and the footer against the header. Blocks must use the LZMA2 filter
    /// alone. Checks of the uncompressed data are verified for CRC-32 and CRC-64; SHA-256 checks are skipped
    /// (read but not verified).
    ///
    /// - Parameters:
    ///   - input: The whole file, and nothing else.
    ///   - output: Where to append the decompressed bytes; it needs room for all of them.
    /// - Returns: The number of input bytes decoded: all of them.
    /// - Throws: ``BytesError/insufficientData`` for a truncated file; ``BytesError/insufficientCapacity`` if
    ///   the output doesn't fit; ``BytesError/mismatch`` for a wrong CRC, check, or size; and
    ///   ``BytesError/invalidValue`` for corrupt data, trailing bytes that aren't a stream, or an unsupported
    ///   filter (BCJ, delta, or any but LZMA2 alone) or check type (any but none, CRC-32, CRC-64, SHA-256).
    public mutating func decompressXZ(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        guard input.byteCount > 0 else { throw .insufficientData }
        return try output.withFreeCapacity { span, written throws(BytesError) -> Int in
            try span.withUnsafeMutableBytes { outputBuffer throws(BytesError) -> Int in
                try input.withUnsafeBytes { inputBuffer throws(BytesError) -> Int in
                    // Unsafe: base addresses of the buffers (a placeholder for an empty output, never written).
                    written = try unsafe decodeXZ(
                        inputBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: inputBuffer.count,
                        output: (outputBuffer.baseAddress ?? UnsafeMutableRawPointer(bitPattern: 1)!).assumingMemoryBound(to: UInt8.self),
                        capacity: outputBuffer.count
                    )
                    return inputBuffer.count
                }
            }
        }
    }

    /// Decodes every stream in `input` into `output`.
    ///
    /// - Returns: The bytes written.
    private mutating func decodeXZ(
        _ input: UnsafePointer<UInt8>, count: Int, output: UnsafeMutablePointer<UInt8>, capacity: Int
    ) throws(BytesError) -> Int {
        var position = 0
        var end = 0
        // Unsafe: reads of the input and its CRCs over pointer ranges, each checked against `count` first.
        repeat {
            // Stream header: magic, flags, and the flags' CRC-32.
            guard count &- position >= XZ.headerSize else {
                // Too short for a header: a truncated one, or (as soon as its bytes show it) not one at all.
                try unsafe XZ.checkHeaderPrefix(input + position, count: count &- position)
                throw .insufficientData
            }
            let checkType = try unsafe XZ.streamHeader(input + position)
            let checkSize = XZ.checkSize(checkType)
            position &+= XZ.headerSize

            // Blocks, up to the index's indicator (a 0 where a block header's size would be).
            var blocks = XZIndexSummary()
            while true {
                guard position < count else { throw .insufficientData }
                let sizeByte = Int(unsafe input[position])
                if sizeByte == 0 { break }
                let block = try unsafe decodeBlock(
                    input + position, count: count &- position, headerSize: (sizeByte &+ 1) &* 4, checkType: checkType,
                    checkSize: checkSize, output: output, start: end, capacity: capacity
                )
                position &+= block.consumed
                blocks.add(unpadded: UInt64(block.unpadded), uncompressed: UInt64(block.end &- end))
                end = block.end
            }

            // Index: the indicator, the record count, the records, padding to 4 bytes, and a CRC-32.
            let indexStart = position
            var cursor = unsafe XZCursor(base: input, end: count, position: position &+ 1)
            var listed = XZIndexSummary()
            let records = try cursor.integer()
            guard records == UInt64(blocks.count) else { throw .mismatch }
            for _ in 0..<blocks.count {
                let unpadded = try cursor.integer()
                let uncompressed = try cursor.integer()
                listed.add(unpadded: unpadded, uncompressed: uncompressed)
            }
            guard listed == blocks else { throw .mismatch }
            while (cursor.position &- indexStart) & 3 != 0 {
                guard try cursor.byte() == 0 else { throw .invalidValue }
            }
            let indexCRC = unsafe XZ.crc32(input + indexStart, cursor.position &- indexStart)
            guard try cursor.uint32() == indexCRC else { throw .mismatch }
            let indexSize = cursor.position &- indexStart
            position = cursor.position

            // Stream footer: a CRC-32 of the backward size and flags, the backward size (the index's), the
            // flags (the header's), and "YZ".
            guard count &- position >= XZ.headerSize else { throw .insufficientData }
            try unsafe XZ.checkFooter(input + position, indexSize: indexSize, checkType: checkType)
            position &+= XZ.headerSize

            // Stream padding: zeros, a multiple of 4 bytes.
            while count &- position >= 4, unsafe UnsafeRawPointer(input + position).loadUnaligned(as: UInt32.self) == 0 {
                position &+= 4
            }
            if position < count && count &- position < 4 {
                throw .invalidValue // Padding that isn't a multiple of 4, or garbage.
            }
        } while position < count
        return end
    }

    /// Decodes the block at `block` (`count` bytes to the input's end) into `output` from `start`.
    ///
    /// - Returns: The block's size in the input (header to check), its unpadded size, and the output's end.
    private mutating func decodeBlock(
        _ block: UnsafePointer<UInt8>, count: Int, headerSize: Int, checkType: Int, checkSize: Int,
        output: UnsafeMutablePointer<UInt8>, start: Int, capacity: Int
    ) throws(BytesError) -> (consumed: Int, unpadded: Int, end: Int) {
        // Unsafe: reads within the block's bytes, each checked against `count` first.
        guard headerSize <= count else { throw .insufficientData }
        let header = try unsafe XZ.blockHeader(block, headerSize: headerSize)
        let compressedSize = header.compressedSize
        let uncompressedSize = header.uncompressedSize
        let dictionarySize = header.dictionarySize

        // The data.
        let dataStart = headerSize
        var available = count &- dataStart
        if let compressedSize {
            guard compressedSize <= available else { throw .insufficientData }
            available = compressedSize
        }
        if let uncompressedSize, uncompressedSize > capacity &- start { throw .insufficientCapacity }
        let (compressed, end) = try unsafe decodeLZMA2(
            block + dataStart, count: available, output: output, start: start, capacity: capacity,
            dictionarySize: dictionarySize
        )
        if let compressedSize, compressed != compressedSize { throw .mismatch }
        if let uncompressedSize, end &- start != uncompressedSize { throw .mismatch }

        // Padding to 4 bytes, then the check.
        var position = dataStart &+ compressed
        while position & 3 != 0 {
            guard position < count else { throw .insufficientData }
            guard unsafe block[position] == 0 else { throw .invalidValue }
            position &+= 1
        }
        guard checkSize <= count &- position else { throw .insufficientData }
        let check = unsafe UnsafeRawPointer(block + position)
        let content = unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: output + start, count: end &- start))
        switch checkType {
        case 1:
            guard unsafe CRC32.checksum(content) == check.loadUnaligned(as: UInt32.self).littleEndian else { throw .mismatch }
        case 4:
            guard unsafe CRC64.checksum(content) == check.loadUnaligned(as: UInt64.self).littleEndian else { throw .mismatch }
        default:
            break // None, or SHA-256: not verified.
        }
        return (position &+ checkSize, dataStart &+ compressed &+ checkSize, end)
    }
}
