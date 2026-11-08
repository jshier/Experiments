import BinaryParsing
import Bytes

// QOI decoding (https://qoiformat.org), the same algorithm as swift-binary-parsing's example (including its
// loop condition, so all three produce the same pixels), written two ways:
//
// - `decodeWithBytes`: `Bytes` reading, `BytesWriter` writing into the output array.
// - `decodeWithParserSpan`: the same, reading with `ParserSpan` instead: the input side alone differs.
//
// Both keep pixels as `SIMD4<UInt8>` (lane-wise wrapping arithmetic for the deltas, one store per pixel)
// and the 64-entry index in an `InlineArray`, as the example's TODOs suggest.

public struct DecodedImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var channels: Int
    public var pixels: [UInt8]
}

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

    public static func decodeWithBytes(_ data: RawSpan) throws -> DecodedImage {
        var reader = Bytes(data)
        try reader.expect(0x71_6F_69_66 as Byte4) // "qoif"
        let width = Int(try reader.read(Byte4.self, .bigEndian))
        let height = Int(try reader.read(Byte4.self, .bigEndian))
        let channels = Int(try reader.read(Byte.self))
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
                    guard run == 0 else {
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

    // MARK: ParserSpan

    public static func decodeWithParserSpan(_ data: RawSpan) throws -> DecodedImage {
        var input = ParserSpan(data)
        guard try UInt32(parsingBigEndian: &input) == 0x716F_6966 else { throw QOIError() }
        let width = try Int(parsing: &input, storedAsBigEndian: UInt32.self)
        let height = try Int(parsing: &input, storedAsBigEndian: UInt32.self)
        let channels = Int(try UInt8(parsing: &input))
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
                        pixel = bitCast(try UInt32(parsingLittleEndian: &input), to: SIMD4<UInt8>.self)
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

extension ExampleQOI {
    /// The example's result in the common shape, for comparing outputs.
    public var decodedImage: DecodedImage {
        DecodedImage(width: width, height: height, channels: Int(channels.rawValue), pixels: [UInt8](pixels))
    }
}
