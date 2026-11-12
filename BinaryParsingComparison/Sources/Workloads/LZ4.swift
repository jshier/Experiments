import BinaryParsing
import Bytes

// LZ4 frame decoding (independent blocks, as `lz4` writes by default), written two ways:
//
// - `decodeWithBytes`: `Bytes` reading the frame and sequences, `BytesWriter` writing each block straight
//   into the output array's new capacity, with `copy(fromDistance:count:allowingOverrun:)` for matches and
//   `write(from:byteCount:allowingOverrun:)` for literals (16-byte steps, as LZ4's reference decoder).
// - `decodeWithBytesExactLiterals`: the same, but copying literals exactly (`write(_: RawSpan)`), as
//   `decodeWithBytes` did before Bytes had the overrun copy.
// - `decodeWithParserSpan`: `decodeWithBytesExactLiterals` reading with `ParserSpan` instead: the input side
//   alone differs. It's kept as it is, against the shipping swift-binary-parsing.
//
// swift-binary-parsing's example (`ExampleLZ4`) appends literals to a `Data` and copies matches through a
// new `Array` per match.

/// An LZ4 frame the decoders reject: a descriptor that isn't version 1 with independent blocks of 64 KB or
/// more (or, for the `ParserSpan` decoder, a bad magic or a match distance of 0).
public struct LZ4Error: Error {}

public enum LZ4 {
    // MARK: Bytes

    /// Decodes an LZ4 frame with `Bytes`, copying literals 16 bytes at a time, as LZ4's reference decoder.
    ///
    /// Checksums (header, block, and content) are skipped, not verified.
    ///
    /// - Parameter data: The frame: independent blocks, as `lz4` writes by default.
    /// - Returns: The decompressed bytes.
    /// - Throws: ``LZ4Error`` if the frame descriptor isn't supported; `BytesError.mismatch` if the magic is
    ///   wrong; `BytesError.insufficientData` for truncated input; `BytesError.invalidValue` for a match
    ///   distance of 0 or before the start of the block's output; `BytesError.insufficientCapacity` for a
    ///   block that decompresses to more than the frame's block size.
    public static func decodeWithBytes(_ data: RawSpan) throws -> [UInt8] {
        try decodeWithBytes(data, overrunningLiterals: true)
    }

    /// Decodes an LZ4 frame with `Bytes`, copying literals exactly.
    ///
    /// - Parameter data: The frame.
    /// - Returns: The decompressed bytes.
    /// - Throws: As ``decodeWithBytes(_:)``.
    public static func decodeWithBytesExactLiterals(_ data: RawSpan) throws -> [UInt8] {
        try decodeWithBytes(data, overrunningLiterals: false)
    }

    /// The decoder behind the two above, inlined into each with `overrunningLiterals` a constant: the other
    /// path folds away.
    ///
    /// - Parameters:
    ///   - data: The frame.
    ///   - overrunningLiterals: Whether literals are copied in 16-byte steps that may overrun, or exactly.
    /// - Returns: The decompressed bytes.
    /// - Throws: As ``decodeWithBytes(_:)``.
    @inline(always)
    static func decodeWithBytes(_ data: RawSpan, overrunningLiterals: Bool) throws -> [UInt8] {
        var reader = BytesReader(data)
        try reader.expect(0x04_22_4D_18 as Byte4) // 0x184D2204, little-endian
        let flags = try reader.read(Byte.self)
        let descriptor = try reader.read(Byte.self)
        let sizeCode = Int(descriptor[Bits<3>.self, at: 4])
        // Version 01, reserved bit 1 clear, independent blocks (bit 5); the descriptor's reserved bits
        // clear; block sizes 64 KB to 4 MB.
        guard flags.matches(0b0110_0000, mask: 0b1110_0010), descriptor.matches(0, mask: 0b1000_1111), sizeCode >= 4
        else { throw LZ4Error() }
        let blockMaximum = 1 << (8 &+ 2 &* sizeCode)
        let hasBlockChecksums = flags[bit: 4]
        let contentSize = try flags[bit: 3] ? reader.read(Int.self, as: Byte8.self, .littleEndian) : 0
        if flags[bit: 0] { try reader.skip(byteCount: 4) } // dictionary ID
        try reader.skip(byteCount: 1) // header checksum

        var output: [UInt8] = []
        output.reserveCapacity(contentSize > 0 ? contentSize : data.byteCount &* 3)
        while true {
            let size = try reader.read(Byte4.self, .littleEndian)
            if size == 0 { break } // EndMark
            let block = try reader.read(byteCount: Int(size[bits: 0..<31]))
            if hasBlockChecksums { try reader.skip(byteCount: 4) }
            if size[bit: 31] { // Stored uncompressed.
                try output.append(byteCapacity: block.byteCount) { writer throws(BytesError) in try writer.write(block) }
            } else {
                try output.append(byteCapacity: blockMaximum) { writer throws(BytesError) in
                    // A constant in each call, so each inlined decoder has one literal copy. (Passing the flag
                    // through made LLVM merge the two variants into one function and kept the flag as a run-time
                    // test in the sequence loop.) This is one test per block.
                    if overrunningLiterals {
                        try decodeBlock(block, into: &writer, overrunningLiterals: true)
                    } else {
                        try decodeBlock(block, into: &writer, overrunningLiterals: false)
                    }
                }
            }
        }
        return output
    }

    /// One block's sequences: a token (literal and match length nibbles), the literals, a 2-byte distance,
    /// and the match. The last sequence has literals only.
    ///
    /// - Parameters:
    ///   - block: The compressed block.
    ///   - writer: Where the decompressed bytes go.
    ///   - overrunningLiterals: Whether literals are copied in 16-byte steps that may overrun, or exactly.
    /// - Throws: `BytesError.insufficientData` if the block ends inside a sequence;
    ///   `BytesError.invalidValue` if a match distance is 0 or reaches before the start of `writer`'s
    ///   output; `BytesError.insufficientCapacity` if the output outgrows `writer`.
    @inline(always)
    static func decodeBlock(_ block: RawSpan, into writer: inout BytesWriter, overrunningLiterals: Bool) throws(BytesError) {
        var reader = BytesReader(block)
        while true {
            let token = try reader.read(Byte.self)
            let literalCount = try length(Int(token.highHalf), &reader)
            if overrunningLiterals {
                // 16 bytes at a time while both cursors have room, as LZ4's reference decoder copies literals:
                // most runs are under 16 bytes, so one load and one store, with no branch on the length.
                try writer.write(from: &reader, byteCount: literalCount, allowingOverrun: true)
            } else {
                try writer.write(reader.read(byteCount: literalCount))
            }
            if reader.isAtEnd { return }
            let distance = try reader.read(Int.self, as: Byte2.self, .littleEndian)
            guard distance != 0 else { throw .invalidValue }
            let count = try length(Int(token.lowHalf), &reader) &+ 4
            try writer.copy(fromDistance: distance, count: count, allowingOverrun: true)
        }
    }

    /// A length: the token's nibble, plus following bytes while they're 255 if the nibble is 15.
    ///
    /// - Parameters:
    ///   - nibble: The token's literal or match nibble, 0 through 15.
    ///   - reader: The block, positioned after the token (or after the literals, for the match length).
    /// - Returns: The length, before the match's minimum of 4 is added.
    /// - Throws: `BytesError.insufficientData` if the block ends inside the length.
    @inline(always)
    static func length(_ nibble: Int, _ reader: inout BytesReader) throws(BytesError) -> Int {
        guard nibble == 15 else { return nibble }
        var length = nibble
        while true {
            let byte = try reader.read(Byte.self)
            length &+= Int(byte)
            if byte != 255 { return length }
        }
    }

    // MARK: ParserSpan

    /// Decodes an LZ4 frame with `ParserSpan`: the algorithm of ``decodeWithBytesExactLiterals(_:)``.
    ///
    /// - Parameter data: The frame.
    /// - Returns: The decompressed bytes.
    /// - Throws: ``LZ4Error`` as for ``decodeWithBytes(_:)``, and for a wrong magic or a match distance of
    ///   0; `ParsingError` for truncated input; `BytesError` from the writer for a match reaching before
    ///   the start of the block's output or a block that decompresses to more than the block size.
    public static func decodeWithParserSpan(_ data: RawSpan) throws -> [UInt8] {
        var input = ParserSpan(data)
        guard try UInt32(parsingLittleEndian: &input) == 0x184D_2204 else { throw LZ4Error() }
        let flags = try UInt8(parsing: &input)
        let descriptor = try UInt8(parsing: &input)
        let sizeCode = Int(descriptor >> 4 & 7)
        guard flags >> 6 == 0b01, flags & 0b10 == 0, descriptor & 0x8F == 0, sizeCode >= 4, flags & 0x20 != 0
        else { throw LZ4Error() }
        let blockMaximum = 1 << (8 &+ 2 &* sizeCode)
        let hasBlockChecksums = flags & 0x10 != 0
        let contentSize = flags & 0x08 != 0 ? try Int(parsing: &input, storedAsLittleEndian: UInt64.self) : 0
        if flags & 1 != 0 { try input.seek(toRelativeOffset: 4) }
        try input.seek(toRelativeOffset: 1)

        var output: [UInt8] = []
        output.reserveCapacity(contentSize > 0 ? contentSize : data.byteCount &* 3)
        while true {
            let size = try UInt32(parsingLittleEndian: &input)
            if size == 0 { break }
            let block = try input.sliceSpan(byteCount: size & 0x7FFF_FFFF).bytes
            if hasBlockChecksums { try input.seek(toRelativeOffset: 4) }
            if size & 0x8000_0000 != 0 {
                try output.append(addingCapacity: block.byteCount) { (span: inout OutputSpan<UInt8>) throws(BytesError) in
                    try span.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in try writer.write(block) }
                }
            } else {
                try output.append(addingCapacity: blockMaximum) { (span: inout OutputSpan<UInt8>) throws in
                    try span.withBytesWriter { (writer: inout BytesWriter) throws in
                        try decodeBlockParserSpan(block, into: &writer)
                    }
                }
            }
        }
        return output
    }

    @inline(always)
    static func decodeBlockParserSpan(_ block: RawSpan, into writer: inout BytesWriter) throws {
        var input = ParserSpan(block)
        while true {
            let token = try UInt8(parsing: &input)
            let literalCount = try lengthParserSpan(Int(token >> 4), &input)
            try writer.write(input.sliceSpan(byteCount: literalCount).bytes)
            if input.isEmpty { return }
            let distance = try Int(parsing: &input, storedAsLittleEndian: UInt16.self)
            guard distance != 0 else { throw LZ4Error() }
            let count = try lengthParserSpan(Int(token & 0xF), &input) &+ 4
            try writer.copy(fromDistance: distance, count: count, allowingOverrun: true)
        }
    }

    @inline(always)
    static func lengthParserSpan(_ nibble: Int, _ input: inout ParserSpan) throws(ParsingError) -> Int {
        guard nibble == 15 else { return nibble }
        var length = nibble
        while true {
            let byte = try UInt8(parsing: &input)
            length &+= Int(byte)
            if byte != 255 { return length }
        }
    }
}
