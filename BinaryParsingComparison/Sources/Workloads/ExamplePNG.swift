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
// renaming its types with an `Example` prefix and leaving out its printing driver (`parsePNG`), to benchmark
// the example as published.
import BinaryParsing

// MARK: PNGParser/PNG.swift

// Using format information from https://www.w3.org/TR/2003/REC-PNG-20031110/

public struct ExamplePNG {
    public var header: ExampleChunk.Header
    public var chunks: [ExampleChunk]
}

extension ExamplePNG: ExpressibleByParsing {
    public init(parsing input: inout ParserSpan) throws {
        let preamble = try UInt64(parsingBigEndian: &input)
        guard preamble == 0x89_50_4E_47_0D_0A_1A_0A else {
            throw ExamplePNGParsingError()
        }

        let firstChunk = try ExampleChunk(parsing: &input)
        guard case let .header(header) = firstChunk else {
            throw ExamplePNGParsingError()
        }
        self.header = header

        var state = ExamplePNGParserState.headerParsed()
        chunks = try Array(parsingAll: &input) { input in
            let chunk = try ExampleChunk(parsing: &input)
            try state.nextState(for: chunk.kind)
            return chunk
        }
    }
}

// MARK: PNGParser/PNGParserState.swift

enum ExamplePNGParserState {
    case initial
    case headerParsed(Set<ExampleChunk.Kind> = [])
    case data
    case end

    mutating func nextState(for event: ExampleChunk.Kind) throws {
        switch (self, event) {
        case (.initial, .header):
            self = .headerParsed([])
        case (.initial, _):
            throw ExampleTestError(description: "Header must be first chunk")
        case (_, .header):
            throw ExampleTestError(description: "Only one header chunk allowed")
        case (.headerParsed, .data):
            self = .data
        case (.headerParsed, .end):
            throw ExampleTestError(description: "At least one data chunk required")
        case (.headerParsed(var chunks), let newChunk):
            let inserted = chunks.insert(newChunk).inserted
            if !newChunk.multipleAllowed && !inserted {
                throw ExampleTestError(description: "No more than one \(event) chunk allowed")
            }
            self = .headerParsed(chunks)
        case (.data, .data):
            break
        case (.data, .end):
            self = .end
        case (.data, _):
            throw ExampleTestError(description: "Only data and end once data starts")
        case (.end, _):
            throw ExampleTestError(description: "No chunks allowed after end")
        }
    }
}

// MARK: PNGParser/Chunks/Chunk.swift

public enum ExampleChunk {
    case header(Header)
    case text(InternationalText)
    case pixelDimensions(PixelDimensions)
    case data([UInt8])
    case other(String, [UInt8])
    case end

    init(parsing input: inout ParserSpan) throws {
        let length = try UInt32(parsingBigEndian: &input)
        let id = try UInt32(parsingBigEndian: &input)

        var slice = try input.sliceSpan(byteCount: length)
        self =
            switch id {
            case 0x49_48_44_52: // IHDR
                try .header(Header(parsing: &slice))
            case 0x69_54_58_74: // iTXt
                try .text(InternationalText(parsing: &slice))
            case 0x70_48_59_73: // pHYs
                try .pixelDimensions(PixelDimensions(parsing: &slice))
            case 0x49_44_41_54: // IDAT
                .data(Array(parsingRemainingBytes: &slice))
            case 0x49_45_4E_44: // IEND
                .end
            default:
                try .other(id.utf8, Array(parsingRemainingBytes: &slice))
            }

        // TODO: Check end boundary?

        _ = try UInt32(parsingBigEndian: &input)
    }
}

extension ExampleChunk {
    enum Kind: Int {
        case header
        case text
        case pixelDimensions
        case data
        case other
        case end

        var multipleAllowed: Bool {
            switch self {
            case .other: true
            default: false
            }
        }
    }

    var kind: Kind {
        switch self {
        case .header: .header
        case .text: .text
        case .pixelDimensions: .pixelDimensions
        case .data: .data
        case .other: .other
        case .end: .end
        }
    }
}

extension ExampleChunk: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .header(header):
            String(describing: header)
        case let .text(text):
            "Text: \(text.keyword)\n\(text.text)"
        case let .pixelDimensions(dims):
            "Dimensions: \(dims.width) x \(dims.height)"
        case let .data(data):
            "Data: \(data.count) bytes"
        case let .other(tag, data):
            "Other (\(tag)): \(data.count) bytes"
        case .end:
            "End"
        }
    }
}

// MARK: PNGParser/Chunks/Header.swift

public extension ExampleChunk {
    // An IHDR chunk contains:
    //
    // Width  4 bytes
    // Height  4 bytes
    // Bit depth  1 byte
    // Colour type  1 byte
    // Compression method  1 byte
    // Filter method  1 byte
    // Interlace method  1 byte

    struct Header {
        public enum ColorType: UInt8 {
            case grayscale = 0
            case trueColor = 2
            case indexedColor = 3
            case grayscaleAlpha = 4
            case trueColorAlpha = 6
        }

        public var width: Int
        public var height: Int
        public var bitDepth: UInt8
        public var colorType: ColorType
        public var interlaced: Bool
    }
}

struct ExamplePNGParsingError: Error {}

public extension ExampleChunk.Header {
    init(parsing input: inout ParserSpan) throws {
        width = try Int(parsing: &input, storedAsBigEndian: UInt32.self)
        height = try Int(parsing: &input, storedAsBigEndian: UInt32.self)
        bitDepth = try UInt8(parsing: &input)
        colorType = try ColorType(parsing: &input)

        // Discard reserved value
        _ = try UInt16(parsingBigEndian: &input)

        interlaced = try pngBool(parsing: &input)
    }
}

extension ExampleChunk.Header: CustomStringConvertible {
    public var description: String {
        """
        ExamplePNG Header:
        - width: \(width)
        - height: \(height)
        - bitDepth: \(bitDepth)
        - colorType: \(colorType)
        - interlaced: \(interlaced)
        """
    }
}

public extension ExampleChunk.Header {
    init(properties: (Int, Int, UInt8, ColorType, Bool)) {
        width = properties.0
        height = properties.1
        bitDepth = properties.2
        colorType = properties.3
        interlaced = properties.4
    }
}

// MARK: - Bool parsing approaches

func pngBool(parsing input: inout ParserSpan) throws -> Bool {
    switch try UInt8(parsing: &input) {
    case 1: true
    case 0: false
    default: throw ExamplePNGParsingError()
    }
}

struct ExamplePNGBool {
    var value: Bool

    init(parsing input: inout ParserSpan) throws {
        let value = try UInt8(parsing: &input)
        switch value {
        case 1: self.value = true
        case 0: self.value = false
        default:
            throw ExamplePNGParsingError()
        }
    }

    func output(_ output: inout ParserSpan) {}
}

extension Bool {
    init(parsingOneOrZero input: inout ParserSpan) throws {
        let value = try UInt8(parsing: &input)
        switch value {
        case 1: self = true
        case 0: self = false
        default:
            throw ExamplePNGParsingError()
        }
    }
}

// MARK: PNGParser/Chunks/InternationalText.swift

public extension ExampleChunk {
    // An iTXt chunk contains:
    //
    // Keyword  1-79 bytes (character string)
    // Null separator  1 byte (null character)
    // Compression flag  1 byte
    // Compression method  1 byte
    // Language tag  0 or more bytes (character string)
    // Null separator  1 byte (null character)
    // Translated keyword  0 or more bytes
    // Null separator  1 byte (null character)
    // Text  0 or more bytes

    struct InternationalText {
        public var keyword: String
        public var compressionFlag: UInt8
        public var compressionMethod: UInt8
        public var languageTag: String
        public var translatedKeyword: String
        public var text: String
    }
}

extension ExampleChunk.InternationalText {
    init(parsing input: inout ParserSpan) throws {
        keyword = try String(parsingNulTerminated: &input)
        guard keyword.count < 80 else {
            throw ExamplePNGParsingError()
        }

        compressionFlag = try UInt8(parsing: &input)
        guard compressionFlag <= 1 else {
            throw ExamplePNGParsingError()
        }
        compressionMethod = try UInt8(parsing: &input)
        guard compressionMethod == 0 else {
            throw ExamplePNGParsingError()
        }

        languageTag = try String(parsingNulTerminated: &input)
        translatedKeyword = try String(parsingNulTerminated: &input)
        text = String(parsingUTF8: &input)
    }
}

// MARK: PNGParser/Chunks/PixelDimensions.swift

public extension ExampleChunk {
    // An pHYs chunk contains:
    //
    // Pixels per unit, X axis  4 bytes (PNG unsigned integer)
    // Pixels per unit, Y axis  4 bytes (PNG unsigned integer)
    // Unit specifier  1 byte

    struct PixelDimensions {
        public var width: UInt32
        public var height: UInt32
        public var unitSpecifier: UInt8
    }
}

public extension ExampleChunk.PixelDimensions {
    init(parsing input: inout ParserSpan) throws {
        width = try UInt32(parsingBigEndian: &input)
        height = try UInt32(parsingBigEndian: &input)
        unitSpecifier = try UInt8(parsing: &input)
    }
}
