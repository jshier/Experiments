import BinaryParsing
import Bytes

// LZ4 frame decoding (independent blocks, as `lz4` writes by default), written two ways:
//
// - `decodeWithBytes`: `Bytes` reading the frame and sequences, `BytesWriter` writing each block straight
//   into the output array's new capacity, with `copy(fromDistance:count:allowingOverrun:)` for matches.
// - `decodeWithParserSpan`: the same, reading with `ParserSpan` instead: the input side alone differs.
//
// swift-binary-parsing's example (`ExampleLZ4`) appends literals to a `Data` and copies matches through a
// new `Array` per match.

public struct LZ4Error: Error {}

public enum LZ4 {
    // MARK: Bytes

    public static func decodeWithBytes(_ data: RawSpan) throws -> [UInt8] {
        var reader = BytesReader(data)
        try reader.expect(0x04_22_4D_18 as Byte4) // 0x184D2204, little-endian
        let flags = try reader.read(Byte.self)
        let descriptor = try reader.read(Byte.self)
        let sizeCode = Int(descriptor[Bits<3>.self, at: 4])
        // Version 01; reserved bits clear; block sizes 64 KB to 4 MB; independent blocks only.
        guard flags[Crumb.self, at: 6] == 0b01, !flags[bit: 1], !descriptor[bit: 7],
              descriptor[Nibble.self, at: 0] == 0, sizeCode >= 4, flags[bit: 5]
        else { throw LZ4Error() }
        let blockMaximum = 1 << (8 &+ 2 &* sizeCode)
        let hasBlockChecksums = flags[bit: 4]
        let contentSize = flags[bit: 3] ? Int(try reader.read(Byte8.self, .littleEndian)) : 0
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
                try output.append(addingCapacity: block.byteCount) { (span: inout OutputSpan<UInt8>) throws(BytesError) in
                    try span.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in try writer.write(block) }
                }
            } else {
                try output.append(addingCapacity: blockMaximum) { (span: inout OutputSpan<UInt8>) throws(BytesError) in
                    try span.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                        try decodeBlock(block, into: &writer)
                    }
                }
            }
        }
        return output
    }

    /// One block's sequences: a token (literal and match length nibbles), the literals, a 2-byte distance,
    /// and the match. The last sequence has literals only.
    @inline(always)
    static func decodeBlock(_ block: RawSpan, into writer: inout BytesWriter) throws(BytesError) {
        var reader = BytesReader(block)
        while true {
            let token = try reader.read(Byte.self)
            let literalCount = try length(Int(token.highHalf), &reader)
            try writer.write(try reader.read(byteCount: literalCount))
            if reader.isAtEnd { return }
            let distance = Int(try reader.read(Byte2.self, .littleEndian))
            guard distance != 0 else { throw .invalidValue }
            let count = try length(Int(token.lowHalf), &reader) &+ 4
            try writer.copy(fromDistance: distance, count: count, allowingOverrun: true)
        }
    }

    /// A length: the token's nibble, plus following bytes while they're 255 if the nibble is 15.
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
                try output.append(addingCapacity: blockMaximum) { (span: inout OutputSpan<UInt8>) throws(any Error) in
                    try span.withBytesWriter { (writer: inout BytesWriter) throws(any Error) in
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
            try writer.write(try input.sliceSpan(byteCount: literalCount).bytes)
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
