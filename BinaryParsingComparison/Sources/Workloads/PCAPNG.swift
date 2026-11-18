import BinaryParsing // `Endianness`, in the example's section header.
import Bytes

// PCAPNG captures: swift-binary-parsing's PCAPNGParser example (`ExamplePCAPNG`), ported to `Bytes`. It reads
// the section header and every block after it into the example's own types, so both sides build the same result,
// including its allocations: an array of options per block, a `String` per text option, and each packet's data
// and each unknown block as a new `[UInt8]`. Only the parsing differs.
//
// - A section's byte order is its byte-order magic's, decided once: the magic is read first (8 bytes in), then
//   the whole capture is parsed by code generic over the cursor's byte order (`LittleEndianBytesReader` or
//   `BigEndianBytesReader`), specialized for each, with no test per field. (The example passes an `Endianness`
//   value to every read.)
// - Each block's fixed fields are one fixed-size section, and its options and packet data are sections, so no
//   read runs past its part of the block.
// - Options are tag-length-value records padded to 4 bytes: one loop (`readOptions`) for the three kinds.
//
// Every value is read once: the byte-order magic is read to choose the parser, which skips it.

extension ExampleSectionHeader {
    /// A memberwise initializer, which the example's type doesn't get (its parser is declared in its body).
    init(endianness: Endianness, majorVersion: UInt16, minorVersion: UInt16, sectionLength: Int64?, options: [Option]) {
        self.endianness = endianness
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.sectionLength = sectionLength
        self.options = options
    }
}

extension ExampleEnhancedPacket {
    /// A memberwise initializer, which the example's type doesn't get (its parser is declared in its body).
    init(
        interfaceID: UInt32, timestampHigh: UInt32, timestampLow: UInt32, capturedLength: Int, originalLength: Int,
        packetData: Packet, options: [Option]
    ) {
        self.interfaceID = interfaceID
        self.timestampHigh = timestampHigh
        self.timestampLow = timestampLow
        self.capturedLength = capturedLength
        self.originalLength = originalLength
        self.packetData = packetData
        self.options = options
    }
}

/// PCAPNG's named bit fields.
enum PCAPNGFields {
    /// An option code's top bit: a custom option.
    static var customOption: BitFlag { BitFlag(bit: 15) }
}

public enum PCAPNG {
    /// Parses a PCAPNG capture with `Bytes`, as the example does: one section.
    ///
    /// - Parameter data: The capture.
    /// - Returns: The section header and every block after it, as the example's types.
    /// - Throws: `BytesError.mismatch` for a bad preamble or a block whose trailing length differs;
    ///   `BytesError.invalidValue` for an unknown byte-order magic, option, or hash algorithm, a bad section
    ///   length, or a block too short for its fields; `BytesError.insufficientData` if a block is cut short.
    public static func parseWithBytes(_ data: RawSpan) throws(BytesError) -> ExamplePCAPNG {
        // The byte-order magic follows the preamble and the block length, which is in the order it names.
        var magic = try AlignedBytesReader(data, atByteOffset: 8)
        return switch try magic.read(Byte4.self, .littleEndian) {
        case 0x1A2B_3C4D: try parse(data, LittleEndianBytes.self)
        case 0x4D3C_2B1A: try parse(data, BigEndianBytes.self)
        default: throw .invalidValue
        }
    }

    /// The parser in one byte order: specialized for each.
    static func parse<Mode: ByteOrderedCursorMode>(_ data: RawSpan, _: Mode.Type) throws(BytesError) -> ExamplePCAPNG {
        var reader = GenericBytesReader<Mode>(data)
        try reader.expect(0x0A0D_0D0A as UInt32) // A palindrome: the same in either order.
        let header = try readSectionHeader(&reader)
        var blocks: [ExampleBlock] = []
        while !reader.isAtEnd {
            try blocks.append(readBlock(&reader))
        }
        return ExamplePCAPNG(header: header, blocks: blocks)
    }

    // MARK: Blocks

    @inline(__always)
    static func readSectionHeader<Mode: ByteOrderedCursorMode>(
        _ reader: inout GenericBytesReader<Mode>
    ) throws(BytesError) -> ExampleSectionHeader {
        var fields = try reader.readSection(byteCount: 20)
        let blockLength = try fields.read(UInt32.self)
        try fields.skip(byteCount: 4) // The byte-order magic: read to choose `Mode`.
        let majorVersion = try fields.read(UInt16.self)
        let minorVersion = try fields.read(UInt16.self)
        let sectionLength: Int64? = switch try fields.read(Int64.self) {
        case let length where length >= 0: length
        case -1: nil // Unspecified.
        default: throw .invalidValue
        }
        guard blockLength > 28 else { throw .invalidValue } // The example requires options.
        var options = try reader.readSection(byteCount: Int(blockLength) &- 28)
        let parsedOptions = try readOptions(&options) { (code, value) throws(BytesError) -> ExampleSectionHeader.Option in
            switch code {
            case 0: .end
            case 1: .comment(try text(&value))
            case 2: .hardware(try text(&value))
            case 3: .os(try text(&value))
            case 4: .application(try text(&value))
            default: throw .invalidValue
            }
        }
        try reader.expect(blockLength)
        return ExampleSectionHeader(
            endianness: Mode.byteOrder == .bigEndian ? .big : .little, majorVersion: majorVersion,
            minorVersion: minorVersion, sectionLength: sectionLength, options: parsedOptions
        )
    }

    @inline(__always)
    static func readBlock<Mode: ByteOrderedCursorMode>(_ reader: inout GenericBytesReader<Mode>) throws(BytesError) -> ExampleBlock {
        let code = try reader.read(UInt32.self)
        switch code {
        case 0x0A0D_0D0A: throw .invalidValue // Another section: not supported, as in the example.
        case 0x0000_0001: return .interfaceDescription(try readInterfaceDescription(&reader))
        case 0x0000_0006: return .enhancedPacket(try readEnhancedPacket(&reader))
        default:
            let blockLength = try reader.read(UInt32.self)
            // Under 12 bytes, the length is negative: `invalidValue`.
            let buffer = [UInt8](copying: try reader.read(byteCount: Int(blockLength) &- 12))
            try reader.expect(blockLength)
            return .custom(code: String(code, radix: 16), buffer: buffer)
        }
    }

    @inline(__always)
    static func readInterfaceDescription<Mode: ByteOrderedCursorMode>(
        _ reader: inout GenericBytesReader<Mode>
    ) throws(BytesError) -> ExampleInterfaceDescription {
        var fields = try reader.readSection(byteCount: 12)
        let blockLength = try fields.read(UInt32.self)
        let linkType = try fields.read(UInt16.self)
        try fields.skip(byteCount: 2) // Reserved.
        let snapshotLength = try fields.read(Int.self, as: Byte4.self)
        // Under 20 bytes, the length is negative: `invalidValue` (the example traps, on a `UInt32` subtraction).
        var options = try reader.readSection(byteCount: Int(blockLength) &- 20)
        let parsedOptions = try readOptions(&options) { (code, value) throws(BytesError) -> ExampleInterfaceDescription.Option in
            switch code {
            case 0: .end
            case 1: .comment(try text(&value))
            case 2: .name(try text(&value))
            case 3: .description(try text(&value))
            case 4: .ipv4Address(try value.read(UInt64.self))
            case 5: .ipv6Address(try value.read(UInt64.self), try value.read(UInt64.self), try value.read(UInt8.self))
            // 8 bytes from a 6-byte option, as in the example (so a well-formed one throws).
            case 6: .macAddress(try value.read(UInt64.self) >> 16)
            case 7: .euiAddress(try value.read(UInt64.self))
            case 8: .interfaceSpeed(try value.read(UInt64.self))
            case 9: .timestampResolution(ExampleTimestampResolution(_resolutionByte: try value.read(UInt8.self)))
            case 10: .timeZone(String(copying: try value.readUTF8(byteCount: 4)))
            case 11: .filter([UInt8](copying: value.readRemainingBytes()))
            case 12: .os(try text(&value))
            case 13: .fcsLength(Int(try value.read(UInt8.self)))
            case 14: .timestampOffset(try value.read(Int.self, as: Byte8.self))
            default: throw .invalidValue
            }
        }
        try reader.expect(blockLength)
        return ExampleInterfaceDescription(linkType: linkType, snapshotLength: snapshotLength, options: parsedOptions)
    }

    @inline(__always)
    static func readEnhancedPacket<Mode: ByteOrderedCursorMode>(
        _ reader: inout GenericBytesReader<Mode>
    ) throws(BytesError) -> ExampleEnhancedPacket {
        var fields = try reader.readSection(byteCount: 24)
        let blockLength = try fields.read(UInt32.self)
        let interfaceID = try fields.read(UInt32.self)
        let timestampHigh = try fields.read(UInt32.self)
        let timestampLow = try fields.read(UInt32.self)
        let capturedLength = try fields.read(Int.self, as: Byte4.self)
        let originalLength = try fields.read(Int.self, as: Byte4.self)

        let paddedLength = capturedLength.roundedUpToMultipleOf4
        var packet = try reader.readSection(byteCount: capturedLength)
        try reader.skip(byteCount: paddedLength &- capturedLength)
        let packetData = try readPacket(&packet)

        // A negative length (a block too short for its packet) is `invalidValue`.
        var options = try reader.readSection(byteCount: Int(blockLength) &- 32 &- paddedLength)
        let parsedOptions = try readOptions(&options) { (code, value) throws(BytesError) -> ExampleEnhancedPacket.Option in
            if code[PCAPNGFields.customOption] { return .custom(code, [UInt8](copying: value.readRemainingBytes())) }
            return switch code {
            case 0: .end
            case 1: .comment(try text(&value))
            case 2: .flags(try value.read(UInt32.self))
            case 3: .hash(try readHashAlgorithm(&value))
            case 4: .dropCount(try value.read(UInt64.self))
            case 5: .packetID(try value.read(UInt64.self))
            case 6: .queue(try value.read(UInt32.self))
            case 7: .verdict([UInt8](copying: value.readRemainingBytes()))
            case 8: .processIDthreadID(try value.read(UInt64.self))
            default: throw .invalidValue
            }
        }
        try reader.expect(blockLength)
        return ExampleEnhancedPacket(
            interfaceID: interfaceID, timestampHigh: timestampHigh, timestampLow: timestampLow,
            capturedLength: capturedLength, originalLength: originalLength, packetData: packetData, options: parsedOptions
        )
    }

    /// The example's reading of a packet: an Ethernet frame with its preamble and frame check sequence.
    @inline(__always)
    static func readPacket<Mode: ByteOrderedCursorMode>(
        _ packet: inout GenericBytesReader<Mode>
    ) throws(BytesError) -> ExampleEnhancedPacket.Packet {
        var header = try packet.readSection(byteCount: 22)
        let hasPreamble = try header.read(UInt64.self) == 0x5555_5555_5555_555D
        let destination = try header.read(UInt64.self, as: Byte6.self)
        let source = try header.read(UInt64.self, as: Byte6.self)
        let type = try header.read(UInt16.self)
        guard packet.remainingByteCount >= 4 else { throw .insufficientData }
        let data = [UInt8](copying: try packet.read(byteCount: packet.remainingByteCount &- 4))
        let fcs = try packet.read(UInt32.self)
        return ExampleEnhancedPacket.Packet(
            hasPreamble: hasPreamble, destinationAddress: ExampleEnhancedPacket.MACAddress(address: destination),
            sourceAddres: ExampleEnhancedPacket.MACAddress(address: source), type: type, data: data, fcs: fcs
        )
    }

    @inline(__always)
    static func readHashAlgorithm<Mode: ByteOrderedCursorMode>(
        _ value: inout GenericBytesReader<Mode>
    ) throws(BytesError) -> ExampleEnhancedPacket.HashAlgorithm {
        switch try value.read(UInt8.self) {
        case 0: .twosComplement
        case 1: .xor
        case 2: .crc32(try value.read(UInt32.self))
        case 3: .md5(try value.read(UInt64.self), try value.read(UInt64.self))
        case 4: .sha1(try value.read(UInt64.self), try value.read(UInt64.self), try value.read(UInt8.self))
        case 5: .toeplitz(try value.read(UInt32.self))
        default: throw .invalidValue
        }
    }

    // MARK: Options

    /// Reads a block's options: tag-length-value records, each padded to 4 bytes, to the end of `section`.
    ///
    /// - Parameters:
    ///   - section: The block's options.
    ///   - parse: Makes an option from its code and a cursor over its value.
    /// - Returns: The options, in order.
    @inline(__always)
    static func readOptions<Mode: ByteOrderedCursorMode, Option>(
        _ section: inout GenericBytesReader<Mode>,
        _ parse: (UInt16, inout GenericBytesReader<Mode>) throws(BytesError) -> Option
    ) throws(BytesError) -> [Option] {
        var options: [Option] = []
        try section.forEachRecord(tag: Byte2.self, length: Byte2.self, paddedTo: 4) { (code, value) throws(BytesError) in
            try options.append(parse(code, &value))
        }
        // Trailing bytes too few for an option's code and length: the example reads them and throws.
        guard section.isAtEnd else { throw .insufficientData }
        return options
    }

    /// An option's value as text: all of it, validated (the example repairs invalid UTF-8; the same for valid
    /// text).
    @inline(__always)
    static func text<Mode: ByteOrderedCursorMode>(_ value: inout GenericBytesReader<Mode>) throws(BytesError) -> String {
        String(copying: try value.readUTF8(byteCount: value.remainingByteCount))
    }
}

// MARK: - Synthetic captures

/// A synthetic capture for the benchmarks: the sample's section header and interface, then `packetCount`
/// enhanced packet blocks of 60 to 1,459 bytes, some with a comment, flags, and a hash option.
///
/// - Parameters:
///   - packetCount: The number of packets.
///   - bigEndian: Whether to write the capture big-endian.
/// - Returns: The capture's bytes.
public func makePCAPNG(packetCount: Int, bigEndian: Bool = false) -> [UInt8] {
    struct Block {
        var bytes: [UInt8] = []
        let bigEndian: Bool
        mutating func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: bigEndian ? value.bigEndian : value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        mutating func pad() { bytes += repeatElement(0, count: bytes.count.roundedUpToMultipleOf4 - bytes.count) }
        mutating func option(_ code: UInt16, _ value: [UInt8]) {
            append(code)
            append(UInt16(value.count))
            bytes += value
            pad()
        }
        mutating func option(_ code: UInt16, _ text: String) { option(code, Array(text.utf8)) }
    }
    var capture: [UInt8] = []
    func appendBlock(type: UInt32, _ body: (inout Block) -> Void) {
        var block = Block(bigEndian: bigEndian)
        body(&block)
        var framed = Block(bigEndian: bigEndian)
        framed.append(type)
        framed.append(UInt32(block.bytes.count + 12))
        framed.bytes += block.bytes
        framed.append(UInt32(block.bytes.count + 12))
        capture += framed.bytes
    }
    appendBlock(type: 0x0A0D_0D0A) { block in
        block.append(UInt32(0x1A2B_3C4D))
        block.append(UInt16(1))
        block.append(UInt16(0))
        block.append(Int64(-1))
        block.option(2, "arm64")
        block.option(3, "Darwin Kernel Version 24.4.0")
        block.option(4, "tcpdump (libpcap version 1.10.1)")
        block.option(0, [])
    }
    appendBlock(type: 1) { block in
        block.append(UInt16(1)) // Ethernet
        block.append(UInt16(0))
        block.append(UInt32(524_288))
        block.option(2, "en0")
        block.option(9, [6])
        block.option(0, [])
    }
    var state: UInt32 = 0x1234_5678
    for index in 0..<packetCount {
        appendBlock(type: 6) { block in
            let captured = 60 + (index &* 701) % 1_400
            block.append(UInt32(0))
            block.append(UInt32(0x0006_1A2B))
            block.append(UInt32(truncatingIfNeeded: 1_000_000 &* index))
            block.append(UInt32(captured))
            block.append(UInt32(captured + index % 3))
            // The example's frame layout: a preamble, two MAC addresses, the type, data, and the FCS.
            block.bytes += index.isMultiple(of: 2) ? [0x5D, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55] : Array(repeating: 0xAA, count: 8)
            for _ in 0..<(captured - 8) {
                state = state &* 1_664_525 &+ 1_013_904_223
                block.bytes.append(UInt8(truncatingIfNeeded: state >> 24))
            }
            block.pad()
            if index.isMultiple(of: 4) { block.option(1, "packet \(index)") }
            if index.isMultiple(of: 3) {
                var flags = Block(bigEndian: bigEndian)
                flags.append(UInt32(index & 3))
                block.option(2, flags.bytes)
            }
            if index.isMultiple(of: 5) {
                var hash = Block(bigEndian: bigEndian)
                hash.bytes.append(2) // CRC-32
                hash.append(UInt32(truncatingIfNeeded: index &* 2_654_435_761))
                block.option(3, hash.bytes)
            }
            block.option(0, [])
        }
    }
    return capture
}
