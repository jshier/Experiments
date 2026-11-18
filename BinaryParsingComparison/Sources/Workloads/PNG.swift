import Bytes
import BytesMacros

// PNG chunks: swift-binary-parsing's PNGParser example (`ExamplePNG`), ported to `Bytes`. It reads the signature
// and every chunk into the example's own types, so both sides build the same result, including its copies: each
// IDAT and unknown chunk's data as a new `[UInt8]` (antelope.png's 281 IDAT chunks are 4.6 MB of copies), and the
// iTXt chunk's strings. Only the parsing differs.
//
// - The file is big-endian throughout: a `BigEndianBytesReader`, with integers read by type.
// - Each chunk's length and type are a `@BinaryRecord` (one bounds check); its data is a section, so nothing
//   in a chunk reads past it. IHDR and pHYs are records too (one-byte fields, and `Padding` for the two IHDR
//   bytes the example discards), so their fields' checks fold.
// - iTXt's keywords are NUL-terminated (`read(utf8TerminatedBy: 0)`).
// - The chunk-order rules are the example's, with the chunk kinds seen so far in a bit mask instead of a
//   `Set` (which allocates).
//
// Every value is read once. The CRC is skipped unchecked, as the example reads and discards it.

/// The IHDR chunk's 13 bytes.
@BinaryRecord(.bigEndian)
struct PNGImageHeader {
    @Field(Byte4.self) var width: Int
    @Field(Byte4.self) var height: Int
    @Field(Byte.self) var bitDepth: UInt8
    @Field(Byte.self) var colorType: ExampleChunk.Header.ColorType
    var methods: Padding<Byte2> // The compression and filter methods, discarded as in the example.
    @Field(Byte.self) var interlace: UInt8
}

/// The pHYs chunk's 9 bytes.
@BinaryRecord(.bigEndian)
struct PNGPixelDimensions {
    @Field(Byte4.self) var width: UInt32
    @Field(Byte4.self) var height: UInt32
    @Field(Byte.self) var unitSpecifier: UInt8
}

/// A chunk's length and type: the 8 bytes before its data.
@BinaryRecord(.bigEndian)
struct PNGChunkHeader {
    @Field(Byte4.self) var length: Int
    @Field(Byte4.self) var type: UInt32
}

/// The example's chunk-order rules (`ExamplePNGParserState`), after the header chunk.
struct PNGChunkOrder {
    enum Stage { case beforeData, data, end }
    var stage = Stage.beforeData
    /// The kinds seen before the data, a bit each by raw value.
    var seen: UInt8 = 0

    @inline(__always)
    mutating func advance(to kind: ExampleChunk.Kind) throws(BytesError) {
        switch (stage, kind) {
        case (_, .header): throw .invalidValue // Only one header.
        case (.beforeData, .data): stage = .data
        case (.beforeData, .end): throw .invalidValue // At least one data chunk.
        case (.beforeData, _):
            let bit: UInt8 = 1 << kind.rawValue
            guard kind.multipleAllowed || seen & bit == 0 else { throw .invalidValue }
            seen |= bit
        case (.data, .data): break
        case (.data, .end): stage = .end
        case (.data, _), (.end, _): throw .invalidValue // Only data, then the end.
        }
    }
}

public enum PNG {
    /// Parses a PNG file's chunks with `Bytes`, as the example does.
    ///
    /// - Parameter data: The file.
    /// - Returns: The header and every chunk after it, as the example's types.
    /// - Throws: `BytesError.mismatch` for a bad signature; `BytesError.invalidValue` if the first chunk isn't
    ///   IHDR, chunks are out of order, or a field is invalid; `BytesError.insufficientData` if a chunk is cut
    ///   short.
    public static func parseWithBytes(_ data: RawSpan) throws(BytesError) -> ExamplePNG {
        var reader = BigEndianBytesReader(data)
        try reader.expect(0x8950_4E47_0D0A_1A0A as UInt64)
        guard case .header(let header) = try readChunk(&reader) else { throw .invalidValue }
        var order = PNGChunkOrder()
        var chunks: [ExampleChunk] = []
        while !reader.isAtEnd {
            let chunk = try readChunk(&reader)
            try order.advance(to: chunk.kind)
            chunks.append(chunk)
        }
        return ExamplePNG(header: header, chunks: chunks)
    }

    @inline(__always)
    static func readChunk(_ reader: inout BigEndianBytesReader) throws(BytesError) -> ExampleChunk {
        let header = try reader.read(PNGChunkHeader.self)
        var body = try reader.readSection(byteCount: header.length)
        let chunk: ExampleChunk = switch header.type {
        // The type as the big-endian integer the header read it as (the example's own type is a `UInt32`).
        case Byte4(ascii: "IHDR").bigEndian: try .header(readHeader(&body))
        case Byte4(ascii: "iTXt").bigEndian: try .text(readText(&body))
        case Byte4(ascii: "pHYs").bigEndian: try .pixelDimensions(readPixelDimensions(&body))
        case Byte4(ascii: "IDAT").bigEndian: .data([UInt8](copying: body.remainingBytes))
        case Byte4(ascii: "IEND").bigEndian: .end
        // The type's 4 bytes again, as text: they were read once, as a number to switch on.
        default: .other(header.type.utf8, [UInt8](copying: body.remainingBytes))
        }
        try reader.skip(byteCount: 4) // The CRC.
        return chunk
    }

    @inline(__always)
    static func readHeader(_ body: inout BigEndianBytesReader) throws(BytesError) -> ExampleChunk.Header {
        let fields = try body.read(PNGImageHeader.self)
        let interlaced = switch fields.interlace {
        case 0: false
        case 1: true
        default: throw .invalidValue
        }
        return ExampleChunk.Header(
            width: fields.width, height: fields.height, bitDepth: fields.bitDepth, colorType: fields.colorType,
            interlaced: interlaced
        )
    }

    @inline(__always)
    static func readPixelDimensions(_ body: inout BigEndianBytesReader) throws(BytesError) -> ExampleChunk.PixelDimensions {
        let fields = try body.read(PNGPixelDimensions.self)
        return ExampleChunk.PixelDimensions(width: fields.width, height: fields.height, unitSpecifier: fields.unitSpecifier)
    }

    @inline(__always)
    static func readText(_ body: inout BigEndianBytesReader) throws(BytesError) -> ExampleChunk.InternationalText {
        let keyword = String(copying: try body.read(utf8TerminatedBy: 0))
        guard keyword.count < 80 else { throw .invalidValue }
        let compressionFlag = try body.read(UInt8.self)
        guard compressionFlag <= 1 else { throw .invalidValue }
        let compressionMethod = try body.read(UInt8.self)
        guard compressionMethod == 0 else { throw .invalidValue }
        let languageTag = String(copying: try body.read(utf8TerminatedBy: 0))
        let translatedKeyword = String(copying: try body.read(utf8TerminatedBy: 0))
        // Validated, where the example repairs invalid UTF-8 (`String(parsingUTF8:)`): the same for valid text.
        let text = String(copying: try body.readUTF8(byteCount: body.remainingByteCount))
        return ExampleChunk.InternationalText(
            keyword: keyword, compressionFlag: compressionFlag, compressionMethod: compressionMethod,
            languageTag: languageTag, translatedKeyword: translatedKeyword, text: text
        )
    }
}
