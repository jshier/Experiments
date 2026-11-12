import BinaryParsing
import Bytes

// QOI decoding (https://qoiformat.org), the same algorithm as swift-binary-parsing's example (including its
// loop condition, so all three produce the same pixels), written two ways:
//
// - `decodeWithBytes`: `Bytes` reading, `BytesWriter` writing into the output array, each QOI_OP_RUN as one
//   `write(repeating:byteCount:count:)`.
// - `decodeWithBytesPixelRuns`: the same, but writing runs a pixel per loop iteration, as the example does
//   (and as `decodeWithBytes` did before Bytes had run fills).
// - `decodeWithParserSpan`: `decodeWithBytesPixelRuns` reading with `ParserSpan` instead: the input side
//   alone differs. It's kept as it is, against the shipping swift-binary-parsing.
//
// All of them keep pixels as `SIMD4<UInt8>` (lane-wise wrapping arithmetic for the deltas, one store per pixel)
// and the 64-entry index in an `InlineArray`, as the example's TODOs suggest.

/// A decoded image, in a shape common to all the decoders.
public struct DecodedImage: Equatable, Sendable {
    /// The width in pixels.
    public var width: Int
    /// The height in pixels.
    public var height: Int
    /// The bytes per pixel: 3 (RGB) or 4 (RGBA).
    public var channels: Int
    /// The pixels, row by row from the top left, `channels` bytes each.
    public var pixels: [UInt8]
}

/// A QOI file the decoders reject: a bad header, or an image of 400 million pixels or more.
public struct QOIError: Error {}

public enum QOI {
    static var maximumPixelCount: Int { 400_000_000 }

    @inline(__always)
    static func hash(_ pixel: SIMD4<UInt8>) -> Int {
        Int((pixel &* SIMD4(3, 5, 7, 11)).wrappedSum() & 63)
    }

    @inline(__always)
    static func store(_ pixel: SIMD4<UInt8>, channels: Int, to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(UInt64(bitCast(pixel, to: UInt32.self)), byteCount: channels, allowingOverrun: true)
    }

    // MARK: Bytes

    /// Decodes a QOI image with `Bytes`, writing each run with one fill.
    ///
    /// Decoding stops when the image is full or fewer than 8 bytes remain (the end marker's size, as in the
    /// example's loop condition), so truncated input gives a shorter ``DecodedImage/pixels`` rather than an
    /// error.
    ///
    /// - Parameter data: The QOI file.
    /// - Returns: The image.
    /// - Throws: ``QOIError`` if the channel count or color space is invalid, a dimension is 0, or the pixel
    ///   count overflows or reaches 400 million; `BytesError.mismatch` if the magic isn't `qoif`;
    ///   `BytesError.insufficientData` if the header is cut short.
    public static func decodeWithBytes(_ data: RawSpan) throws -> DecodedImage {
        try decodeWithBytes(data, fillingRuns: true)
    }

    /// Decodes a QOI image with `Bytes`, writing runs a pixel per loop iteration, as the example does.
    ///
    /// - Parameter data: The QOI file.
    /// - Returns: The image, as ``decodeWithBytes(_:)`` returns it.
    /// - Throws: As ``decodeWithBytes(_:)``.
    public static func decodeWithBytesPixelRuns(_ data: RawSpan) throws -> DecodedImage {
        try decodeWithBytes(data, fillingRuns: false)
    }

    /// The decoder behind the two above, inlined into each with `fillingRuns` a constant: the other path
    /// folds away.
    ///
    /// - Parameters:
    ///   - data: The QOI file.
    ///   - fillingRuns: Whether to write each run at once, or a pixel per iteration.
    /// - Returns: The image.
    /// - Throws: As ``decodeWithBytes(_:)``.
    @inline(always)
    static func decodeWithBytes(_ data: RawSpan, fillingRuns: Bool) throws -> DecodedImage {
        var reader = BytesReader(data)
        try reader.expect(0x71_6F_69_66 as Byte4) // "qoif"
        let width = try reader.read(Int.self, as: Byte4.self, .bigEndian)
        let height = try reader.read(Int.self, as: Byte4.self, .bigEndian)
        let channels = try Int(reader.read(Byte.self))
        let colorSpace = try reader.read(Byte.self)
        guard channels == 3 || channels == 4, colorSpace <= 1, width > 0, height > 0 else { throw QOIError() }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount < maximumPixelCount else { throw QOIError() }
        let total = pixelCount &* channels

        // Both cursors are locals of this function, so they stay in registers. (Captured by the closures
        // of `[UInt8](capacity:)` and `withBytesWriter`, they lived in memory: see RESULTS.md.)
        var pixels = [UInt8](repeating: 0, count: total)
        var output = pixels.mutableSpan
        var writer = BytesWriter(&output)
        do {
            var cache = InlineArray<64, SIMD4<UInt8>>(repeating: .zero)
            var previous = SIMD4<UInt8>(0, 0, 0, 255)
            var run = 0
            var position = 0
            while position < total, reader.remainingByteCount >= 8 {
                defer { position &+= channels }
                guard fillingRuns || run == 0 else {
                    run &-= 1
                    try store(previous, channels: channels, to: &writer)
                    continue
                }
                let first = try reader.read(Byte.self)
                let pixel: SIMD4<UInt8>
                switch first {
                case 0xFF: // QOI_OP_RGBA
                    pixel = try reader.load(SIMD4<UInt8>.self)
                case 0xFE: // QOI_OP_RGB
                    let rgb = try reader.read(Byte3.self)
                    pixel = SIMD4(rgb[0], rgb[1], rgb[2], previous[3])
                default:
                    let value = UInt8(first[Bits<6>.self, at: 0])
                    switch first[Crumb.self, at: 6] {
                    case 0b00: // QOI_OP_INDEX
                        pixel = cache[Int(value)]
                    case 0b01: // QOI_OP_DIFF: three 2-bit deltas, biased by 2
                        let delta = SIMD4(
                            UInt8(first[Crumb.self, at: 4]), UInt8(first[Crumb.self, at: 2]),
                            UInt8(first[Crumb.self, at: 0]), 2
                        ) &- 2
                        pixel = previous &+ delta
                    case 0b10: // QOI_OP_LUMA: green's delta, then red's and blue's relative to it
                        let second = try reader.read(Byte.self)
                        let green = value &- 32
                        pixel = previous &+ SIMD4(
                            green &- 8 &+ UInt8(second.highHalf), green, green &- 8 &+ UInt8(second.lowHalf), 0
                        )
                    default: // QOI_OP_RUN: this pixel and `value` more
                        guard fillingRuns else {
                            run = Int(value)
                            pixel = previous
                            break
                        }
                        // All at once, cut off at the end of the image as the pixel-at-a-time loop is. (Its
                        // input check can't end a run early: runs read nothing.)
                        let count = min(Int(value) &+ 1, (total &- position) / channels)
                        try writer.write(repeating: UInt64(bitCast(previous, to: UInt32.self)), byteCount: channels, count: count)
                        position &+= (count &- 1) &* channels // The `defer` adds the first.
                        cache[hash(previous)] = previous
                        continue
                    }
                }
                try store(pixel, channels: channels, to: &writer)
                cache[hash(pixel)] = pixel
                previous = pixel
            }
        }
        let written = writer.byteCount
        _ = consume writer
        _ = consume output
        pixels.removeLast(total &- written)
        return DecodedImage(width: width, height: height, channels: channels, pixels: pixels)
    }

    // MARK: ParserSpan

    /// Decodes a QOI image with `ParserSpan`: the algorithm of ``decodeWithBytesPixelRuns(_:)``.
    ///
    /// - Parameter data: The QOI file.
    /// - Returns: The image, as ``decodeWithBytes(_:)`` returns it.
    /// - Throws: ``QOIError`` as for ``decodeWithBytes(_:)``, and for a wrong magic; `ParsingError` if the
    ///   header is cut short or the pixel count overflows.
    public static func decodeWithParserSpan(_ data: RawSpan) throws -> DecodedImage {
        var input = ParserSpan(data)
        guard try UInt32(parsingBigEndian: &input) == 0x716F_6966 else { throw QOIError() }
        let width = try Int(parsing: &input, storedAsBigEndian: UInt32.self)
        let height = try Int(parsing: &input, storedAsBigEndian: UInt32.self)
        let channels = try Int(UInt8(parsing: &input))
        let colorSpace = try UInt8(parsing: &input)
        guard channels == 3 || channels == 4, colorSpace <= 1, width > 0, height > 0 else { throw QOIError() }
        let pixelCount = try width.multipliedThrowingOnOverflow(by: height)
        guard pixelCount < maximumPixelCount else { throw QOIError() }
        let total = pixelCount &* channels

        // Both cursors are locals of this function, so they stay in registers. (Captured by the closures
        // of `[UInt8](capacity:)` and `withBytesWriter`, they lived in memory: see RESULTS.md.)
        var pixels = [UInt8](repeating: 0, count: total)
        var output = pixels.mutableSpan
        var writer = BytesWriter(&output)
        do {
            var cache = InlineArray<64, SIMD4<UInt8>>(repeating: .zero)
            var previous = SIMD4<UInt8>(0, 0, 0, 255)
            var run = 0
            var position = 0
            while position < total, input.count >= 8 {
                defer { position &+= channels }
                guard run == 0 else {
                    run &-= 1
                    try store(previous, channels: channels, to: &writer)
                    continue
                }
                let first = try UInt8(parsing: &input)
                let pixel: SIMD4<UInt8>
                switch first {
                case 0xFF:
                    pixel = try bitCast(UInt32(parsingLittleEndian: &input), to: SIMD4<UInt8>.self)
                case 0xFE:
                    let red = try UInt8(parsing: &input)
                    let green = try UInt8(parsing: &input)
                    let blue = try UInt8(parsing: &input)
                    pixel = SIMD4(red, green, blue, previous[3])
                default:
                    let value = first & 0x3F
                    switch first & 0xC0 {
                    case 0x00:
                        pixel = cache[Int(value)]
                    case 0x40:
                        let delta = SIMD4(first >> 4 & 3, first >> 2 & 3, first & 3, 2) &- 2
                        pixel = previous &+ delta
                    case 0x80:
                        let second = try UInt8(parsing: &input)
                        let green = value &- 32
                        pixel = previous &+ SIMD4(green &- 8 &+ second >> 4, green, green &- 8 &+ second & 0xF, 0)
                    default:
                        run = Int(value)
                        pixel = previous
                    }
                }
                try store(pixel, channels: channels, to: &writer)
                cache[hash(pixel)] = pixel
                previous = pixel
            }
        }
        let written = writer.byteCount
        _ = consume writer
        _ = consume output
        pixels.removeLast(total &- written)
        return DecodedImage(width: width, height: height, channels: channels, pixels: pixels)
    }
}

public extension ExampleQOI {
    /// The example's result in the common shape, for comparing outputs.
    var decodedImage: DecodedImage {
        DecodedImage(width: width, height: height, channels: Int(channels.rawValue), pixels: [UInt8](pixels))
    }
}
