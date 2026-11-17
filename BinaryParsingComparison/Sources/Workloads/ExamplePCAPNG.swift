//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Binary Parsing open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

// Copied from swift-binary-parsing 0.0.4's Examples (commit 8f0f56a), its files in one, unchanged except for
// renaming its types with an `Example` prefix and leaving out its printing driver (`parsePCaptureNG`), to
// benchmark the example as published. It throws the PNG example's error in one place, as published.
import BinaryParsing

// MARK: PCAPNGParser/PCAPNG.swift

// Using format information from:
// https://ietf-opsawg-wg.github.io/draft-ietf-opsawg-pcap/draft-ietf-opsawg-pcapng.html

public struct ExamplePCAPNG: ExpressibleByParsing {
    public var header: ExampleSectionHeader
    public var blocks: [ExampleBlock]

    @usableFromInline
    init(header: ExampleSectionHeader, blocks: [ExampleBlock]) {
        self.header = header
        self.blocks = blocks
    }

    public init(parsing input: inout ParserSpan) throws {
        let preamble = try UInt32(parsingBigEndian: &input)
        guard preamble == 0x0A0D_0D0A else {
            throw ExampleTestError()
        }

        self.header = try ExampleSectionHeader(parsing: &input)
        self.blocks = try Array(
            parsingAll: &input,
            parser: { [header] input in
                try ExampleBlock(parsing: &input, endianness: header.endianness)
            })
    }
}

// MARK: PCAPNGParser/Blocks/Block.swift

public enum ExampleBlock {
    case sectionHeader(ExampleSectionHeader)
    case interfaceDescription(ExampleInterfaceDescription)
    case enhancedPacket(ExampleEnhancedPacket)
    case custom(code: String, buffer: [UInt8])

    static func custom(
        parsing input: inout ParserSpan, code: UInt32, endianness: Endianness
    ) throws -> Self {
        let blockLength = try Int(
            parsing: &input, storedAs: UInt32.self, endianness: endianness)

        var slice = try input.sliceSpan(byteCount: blockLength - 12)
        let data = Array(parsingRemainingBytes: &slice)

        let blockLengthCheck = try UInt32(parsing: &input, endianness: endianness)
        if blockLengthCheck != blockLength {
            throw ExampleTestError()
        }

        return .custom(code: String(code, radix: 16), buffer: data)
    }

    init(parsing input: inout ParserSpan, endianness: Endianness) throws {
        let code = try UInt32(parsing: &input, endianness: endianness)
        self =
            switch code {
            case 0x0A0D_0D0A:
                throw ExampleTestError(
                    description: "Parsing the header through the general block interface")
            case 0x0000_0001:
                try .interfaceDescription(
                    ExampleInterfaceDescription(parsing: &input, endianness: endianness))
            case 0x0000_0006:
                try .enhancedPacket(
                    ExampleEnhancedPacket(parsing: &input, endianness: endianness))
            default:
                try .custom(parsing: &input, code: code, endianness: endianness)
            }
    }
}

// MARK: PCAPNGParser/Blocks/BlockOption.swift

protocol ExampleBlockOption: Equatable {
    init(
        parsing input: inout ParserSpan,
        for optionCode: UInt16,
        endianness: Endianness
    ) throws

    static var end: Self { get }
}

extension ExampleBlockOption {
    init(parsing input: inout ParserSpan, endianness: Endianness) throws {
        let optionCode = try UInt16(parsing: &input, endianness: endianness)
        let optionSize = try Int(
            parsing: &input, storedAs: UInt16.self, endianness: endianness)

        let optionFieldSize = optionSize.roundedUpTo32Bits  // includes padding
        let paddingBytes = optionFieldSize - optionSize

        // Grab the option slice and discard the padding
        var valueSlice = try input.sliceSpan(byteCount: optionSize)
        try input.seek(toRelativeOffset: paddingBytes)

        self = try Self(
            parsing: &valueSlice, for: optionCode, endianness: endianness)
    }
}

extension FixedWidthInteger {
    var roundedUpTo32Bits: Self {
        (self &+ 0x3) & ~0x3
    }
}

// MARK: PCAPNGParser/Blocks/SectionHeader.swift

public struct ExampleSectionHeader: Equatable {
    public enum Option: Equatable {
        case comment(String)
        case hardware(String)
        case os(String)
        case application(String)
        case end
    }

    public var endianness: Endianness
    public var majorVersion: UInt16
    public var minorVersion: UInt16
    public var sectionLength: Int64?
    public var options: [Option]

    public var isBigEndian: Bool {
        endianness.isBigEndian
    }

    @inlinable
    static var byteOrderMagic: UInt32 { (0x1A2B_3C4D as UInt32).littleEndian }

    init(parsing input: inout ParserSpan) throws {
        //    0                   1                   2                   3
        //    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
        //    +---------------------------------------------------------------+
        //  0 |                   Block Type = 0x0A0D0D0A                     |
        //    +---------------------------------------------------------------+
        //  4 |                      Block Total Length                       |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  8 |                      Byte-Order Magic                         |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 12 |          Major Version        |         Minor Version         |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 16 |                                                               |
        //    |                          Section Length                       |
        //    |                                                               |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 24 /                                                               /
        //    /                      Options (variable)                       /
        //    /                                                               /
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //    |                      Block Total Length                       |
        //    +---------------------------------------------------------------+
        let fixedFieldSize = 28

        let _rawblockLength = try UInt32(parsingLittleEndian: &input)
        let magicNumber = try UInt32(parsingLittleEndian: &input)

        self.endianness =
            switch magicNumber {
            case Self.byteOrderMagic: .little
            case Self.byteOrderMagic.byteSwapped: .big
            default: throw ExampleTestError()
            }

        let _correctOrderBlockLength =
            endianness.isBigEndian
            ? _rawblockLength.byteSwapped
            : _rawblockLength
        guard let blockLength = Int(exactly: _correctOrderBlockLength),
            blockLength >= fixedFieldSize
        else {
            throw ExampleTestError()
        }
        guard blockLength > fixedFieldSize else {
            throw ExampleTestError()
        }

        self.majorVersion = try UInt16(parsing: &input, endianness: endianness)
        self.minorVersion = try UInt16(parsing: &input, endianness: endianness)

        let _rawSectionLength = try Int64(parsing: &input, endianness: endianness)
        self.sectionLength =
            switch _rawSectionLength {
            case let length where length >= 0:
                length
            case -1:
                nil
            default:
                throw ExampleTestError()
            }

        let optionsLength = blockLength - 28
        var optionsSlice = try input.sliceSpan(byteCount: optionsLength)
        self.options = try Array(parsingAll: &optionsSlice) { [endianness] slice in
            try Option(parsing: &slice, endianness: endianness)
        }

        let blockLengthCheck = try UInt32(parsing: &input, endianness: endianness)
        if blockLengthCheck != blockLength {
            throw ExampleTestError()
        }
    }
}

extension ExampleSectionHeader.Option: ExampleBlockOption {
    init(
        parsing input: inout ParserSpan,
        for optionCode: UInt16,
        endianness: Endianness
    ) throws {
        self =
            switch optionCode {
            case 0:
                .end
            case 1:
                .comment(String(parsingUTF8: &input))
            case 2:
                .hardware(String(parsingUTF8: &input))
            case 3:
                .os(String(parsingUTF8: &input))
            case 4:
                .application(String(parsingUTF8: &input))
            default:
                throw ExampleTestError()
            }
    }
}

extension ExampleSectionHeader: CustomStringConvertible {
    public var description: String {
        """
        Endianness: \(endianness)
        Major Version: \(majorVersion)
        Minor Version: \(minorVersion)
        Section Length: \(sectionLength ?? -1)
        Options:
        \(options.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}

// MARK: PCAPNGParser/Blocks/InterfaceDescription.swift

public struct ExampleTimestampResolution: Equatable {
    @usableFromInline
    var _resolutionByte: UInt8

    @usableFromInline
    init(_resolutionByte: UInt8) {
        self._resolutionByte = _resolutionByte
    }
}

public struct ExampleInterfaceDescription {
    public enum Option: Equatable {
        case comment(String)
        case name(String)
        case description(String)
        case ipv4Address(UInt64)
        case ipv6Address(UInt64, UInt64, UInt8)
        case macAddress(UInt64)
        case euiAddress(UInt64)
        case interfaceSpeed(UInt64)
        case timestampResolution(ExampleTimestampResolution)
        case timeZone(String)
        case filter([UInt8])
        case os(String)
        case fcsLength(Int)
        case timestampOffset(Int)
        case end
    }

    public var linkType: UInt16
    public var snapshotLength: Int
    public var options: [Option]

    @usableFromInline
    init(linkType: UInt16, snapshotLength: Int, options: [Option]) {
        self.linkType = linkType
        self.snapshotLength = snapshotLength
        self.options = options
    }

    init(parsing input: inout ParserSpan, endianness: Endianness) throws {
        //     0                   1                   2                   3
        //     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
        //    +---------------------------------------------------------------+
        //  0 |                    Block Type = 0x00000001                    |
        //    +---------------------------------------------------------------+
        //  4 |                      Block Total Length                       |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  8 |           LinkType            |           Reserved            |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 12 |                            SnapLen                            |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 16 /                                                               /
        //    /                      Options (variable)                       /
        //    /                                                               /
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //    |                      Block Total Length                       |
        //    +---------------------------------------------------------------+
        let blockLength = try UInt32(parsing: &input, endianness: endianness)
        self.linkType = try UInt16(parsing: &input, endianness: endianness)
        _ = try UInt16(parsing: &input, endianness: endianness)
        self.snapshotLength = try Int(
            parsing: &input, storedAs: UInt32.self, endianness: endianness)

        let optionsLength = Int(blockLength - 20)
        var optionsSlice = try input.sliceSpan(byteCount: optionsLength)
        self.options = try Array(parsingAll: &optionsSlice) { [endianness] slice in
            try Option(parsing: &slice, endianness: endianness)
        }

        let blockLengthCheck = try UInt32(parsing: &input, endianness: endianness)
        if blockLengthCheck != blockLength {
            throw ExampleTestError()
        }
    }
}

extension ExampleInterfaceDescription.Option: ExampleBlockOption {
    init(
        parsing input: inout ParserSpan, for optionCode: UInt16,
        endianness: Endianness
    ) throws {
        self =
            switch optionCode {
            case 0:
                .end
            case 1:
                .comment(String(parsingUTF8: &input))
            case 2:
                .name(String(parsingUTF8: &input))
            case 3:
                .description(String(parsingUTF8: &input))
            case 4:
                try .ipv4Address(UInt64(parsing: &input, endianness: endianness))
            case 5:
                try .ipv6Address(
                    UInt64(parsing: &input, endianness: endianness),
                    UInt64(parsing: &input, endianness: endianness),
                    UInt8(parsing: &input))
            case 6:
                try .macAddress(UInt64(parsing: &input, endianness: endianness) >> 16)
            case 7:
                try .euiAddress(UInt64(parsing: &input, endianness: endianness))
            case 8:
                try .interfaceSpeed(UInt64(parsing: &input, endianness: endianness))
            case 9:
                try .timestampResolution(
                    ExampleTimestampResolution(_resolutionByte: UInt8(parsing: &input)))
            case 10:
                try .timeZone(String(parsingUTF8: &input, count: 4))
            case 11:
                .filter(Array(parsingRemainingBytes: &input))
            case 12:
                .os(String(parsingUTF8: &input))
            case 13:
                try .fcsLength(Int(parsing: &input, storedAs: UInt8.self))
            case 14:
                try .timestampOffset(
                    Int(parsing: &input, storedAs: UInt64.self, endianness: endianness))
            default:
                throw ExampleTestError(description: "Unrecognized option")
            }
    }
}

// MARK: PCAPNGParser/Blocks/EnhancedPacket.swift

public struct ExampleEnhancedPacket {
    public enum HashAlgorithm: Equatable {
        case twosComplement
        case xor
        case crc32(UInt32)
        case md5(UInt64, UInt64)
        case sha1(UInt64, UInt64, UInt8)
        case toeplitz(UInt32)

        init(parsing input: inout ParserSpan, endianness: Endianness) throws {
            let code = try UInt8(parsing: &input)
            self =
                switch code {
                case 0: .twosComplement
                case 1: .xor

                case 2:
                    try .crc32(UInt32(parsing: &input, endianness: endianness))
                case 3:
                    try .md5(
                        UInt64(parsing: &input, endianness: endianness),
                        UInt64(parsing: &input, endianness: endianness))
                case 4:
                    try .sha1(
                        UInt64(parsing: &input, endianness: endianness),
                        UInt64(parsing: &input, endianness: endianness),
                        UInt8(parsing: &input))
                case 5:
                    try .toeplitz(
                        UInt32(parsing: &input, endianness: endianness))
                default:
                    throw ExampleTestError(description: "Invalid hash algorithm \(code)")
                }
        }
    }

    public enum Option {
        case comment(String)
        case flags(UInt32)
        case hash(HashAlgorithm)
        case dropCount(UInt64)
        case packetID(UInt64)
        case queue(UInt32)
        case verdict([UInt8])
        case processIDthreadID(UInt64)
        case custom(UInt16, [UInt8])
        case end
    }

    public struct MACAddress: CustomStringConvertible {
        var address: UInt64

        public var description: String {
            withUnsafeBytes(of: address) { buffer in
                buffer.dropFirst(2)
                    .map { $0.hexString(count: 2) }
                    .joined(separator: ":")
            }
        }
    }

    public struct Packet {
        var hasPreamble: Bool
        var destinationAddress: MACAddress
        var sourceAddres: MACAddress
        var type: UInt16
        var data: [UInt8]
        var fcs: UInt32
    }

    public var interfaceID: UInt32
    public var timestampHigh: UInt32
    public var timestampLow: UInt32
    public var capturedLength: Int
    public var originalLength: Int
    public var packetData: Packet
    public var options: [Option]

    init(parsing input: inout ParserSpan, endianness: Endianness) throws {
        //                         1                   2                   3
        //     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  0 |                    Block Type = 0x00000006                    |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  4 |                      Block Total Length                       |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  8 |                         Interface ID                          |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 12 |                        Timestamp (High)                       |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 16 |                        Timestamp (Low)                        |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 20 |                    Captured Packet Length                     |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 24 |                    Original Packet Length                     |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // 28 /                                                               /
        //    /                          Packet Data                          /
        //    /              variable length, padded to 32 bits               /
        //    /                                                               /
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //    /                                                               /
        //    /                      Options (variable)                       /
        //    /                                                               /
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //    |                      Block Total Length                       |
        //    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

        let blockLength = try Int(
            parsing: &input, storedAs: UInt32.self, endianness: endianness)
        self.interfaceID = try UInt32(parsing: &input, endianness: endianness)
        self.timestampHigh = try UInt32(parsing: &input, endianness: endianness)
        self.timestampLow = try UInt32(parsing: &input, endianness: endianness)
        self.capturedLength = try Int(
            parsing: &input, storedAs: UInt32.self, endianness: endianness)
        self.originalLength = try Int(
            parsing: &input, storedAs: UInt32.self, endianness: endianness)

        let paddedPacketLength = capturedLength.roundedUpTo32Bits
        let paddingLength = paddedPacketLength - capturedLength
        let optionsByteCount = blockLength - (32 + paddedPacketLength)

        // Packet parsing
        var packetSlice = try input.sliceSpan(byteCount: capturedLength)
        try input.seek(toRelativeOffset: paddingLength)
        self.packetData = try Packet(parsing: &packetSlice, endianness: endianness)

        // Options parsing
        var optionsSlice = try input.sliceSpan(byteCount: optionsByteCount)
        self.options = try Array(parsingAll: &optionsSlice) { [endianness] slice in
            try Option(parsing: &slice, endianness: endianness)
        }

        // Block length check
        let blockLengthCheck = try UInt32(parsing: &input, endianness: endianness)
        if blockLengthCheck != blockLength {
            throw ExamplePNGParsingError()
        }
    }
}

extension ExampleEnhancedPacket.Option: ExampleBlockOption {
    init(
        parsing input: inout ParserSpan, for optionCode: UInt16,
        endianness: Endianness
    ) throws {
        self =
            switch optionCode {
            case let code where code & 0x8000 != 0:
                try .custom(code, Array(parsingRemainingBytes: &input))
            case 0:
                .end
            case 1:
                .comment(String(parsingUTF8: &input))
            case 2:
                try .flags(UInt32(parsing: &input, endianness: endianness))
            case 3:
                try .hash(
                    ExampleEnhancedPacket.HashAlgorithm(parsing: &input, endianness: endianness))
            case 4:
                try .dropCount(UInt64(parsing: &input, endianness: endianness))
            case 5:
                try .packetID(UInt64(parsing: &input, endianness: endianness))
            case 6:
                try .queue(UInt32(parsing: &input, endianness: endianness))
            case 7:
                .verdict(Array(parsingRemainingBytes: &input))
            case 8:
                try .processIDthreadID(UInt64(parsing: &input, endianness: endianness))
            default:
                throw ExamplePNGParsingError()
            }
    }
}

extension ExampleEnhancedPacket.Packet {
    init(parsing input: inout ParserSpan, endianness: Endianness) throws {
        self.hasPreamble =
            try UInt64(parsing: &input, endianness: endianness)
            == 0x55_55_55_55_55_55_55_5d

        self.destinationAddress = try ExampleEnhancedPacket.MACAddress(
            address: UInt64(parsing: &input, endianness: endianness, byteCount: 6))
        self.sourceAddres = try ExampleEnhancedPacket.MACAddress(
            address: UInt64(parsing: &input, endianness: endianness, byteCount: 6))

        self.type = try UInt16(parsing: &input, endianness: endianness)

        var dataSlice = try input.sliceSpan(byteCount: input.count - 4)
        self.data = Array(parsingRemainingBytes: &dataSlice)

        self.fcs = try UInt32(parsing: &input, endianness: endianness)
    }
}
