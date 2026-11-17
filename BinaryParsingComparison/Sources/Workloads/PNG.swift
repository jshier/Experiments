import Bytes
import BytesMacros

// PNG chunks: swift-binary-parsing's PNGParser example (`ExamplePNG`), ported to `Bytes`. It reads the signature
// and every chunk into the example's own types, so both sides build the same result, including its copies: each
// IDAT and unknown chunk's data as a new `[UInt8]` (antelope.png's 281 IDAT chunks are 4.6 MB of copies), and the
// iTXt chunk's strings. Only the parsing differs.
//
// - The file is big-endian throughout: a `BigEndianBytesReader`, with integers read by type.
// - Each chunk's length and type are a `@BinaryRecord` (one bounds check); its data is a section, so nothing
//   in a chunk reads past it. IHDR and pHYs are fixed-size sections of that, so their fields' checks fold.
//   (`@BinaryRecord` has no single-byte fields, which both have: they're read by hand.)
// - The chunk-order rules are the example's, with the chunk kinds seen so far in a bit mask instead of a
//   `Set` (which allocates).
//
// Every value is read once. The CRC is skipped unchecked, as the example reads and discards it.

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
        case 0x4948_4452: try .header(readHeader(&body)) // IHDR
        case 0x6954_5874: try .text(readText(&body)) // iTXt
        case 0x7048_5973: try .pixelDimensions(readPixelDimensions(&body)) // pHYs
        case 0x4944_4154: .data([UInt8](copying: body.remainingBytes)) // IDAT
        case 0x4945_4E44: .end // IEND
        // The type's 4 bytes again, as text: they were read once, as a number to switch on.
        default: .other(header.type.utf8, [UInt8](copying: body.remainingBytes))
        }
        try reader.skip(byteCount: 4) // The CRC.
        return chunk
    }

    @inline(__always)
    static func readHeader(_ body: inout BigEndianBytesReader) throws(BytesError) -> ExampleChunk.Header {
        var fields = try body.readSection(byteCount: 13)
        let width = try fields.read(Int.self, as: Byte4.self)
        let height = try fields.read(Int.self, as: Byte4.self)
        let bitDepth = try fields.read(UInt8.self)
        let colorType = try fields.read(ExampleChunk.Header.ColorType.self, as: Byte.self)
        try fields.skip(byteCount: 2) // The compression and filter methods, discarded as in the example.
        let interlaced = switch try fields.read(UInt8.self) {
        case 0: false
        case 1: true
        default: throw .invalidValue
        }
        return ExampleChunk.Header(
            width: width, height: height, bitDepth: bitDepth, colorType: colorType, interlaced: interlaced
        )
    }

    @inline(__always)
    static func readPixelDimensions(_ body: inout BigEndianBytesReader) throws(BytesError) -> ExampleChunk.PixelDimensions {
        var fields = try body.readSection(byteCount: 9)
        return try ExampleChunk.PixelDimensions(
            width: fields.read(UInt32.self), height: fields.read(UInt32.self), unitSpecifier: fields.read(UInt8.self)
        )
    }

    @inline(__always)
    static func readText(_ body: inout BigEndianBytesReader) throws(BytesError) -> ExampleChunk.InternationalText {
        let keyword = String(copying: try body.readNulTerminatedUTF8())
        guard keyword.count < 80 else { throw .invalidValue }
        let compressionFlag = try body.read(UInt8.self)
        guard compressionFlag <= 1 else { throw .invalidValue }
        let compressionMethod = try body.read(UInt8.self)
        guard compressionMethod == 0 else { throw .invalidValue }
        let languageTag = String(copying: try body.readNulTerminatedUTF8())
        let translatedKeyword = String(copying: try body.readNulTerminatedUTF8())
        // Validated, where the example repairs invalid UTF-8 (`String(parsingUTF8:)`): the same for valid text.
        let text = String(copying: try body.readUTF8(byteCount: body.remainingByteCount))
        return ExampleChunk.InternationalText(
            keyword: keyword, compressionFlag: compressionFlag, compressionMethod: compressionMethod,
            languageTag: languageTag, translatedKeyword: translatedKeyword, text: text
        )
    }
}
