import Bytes
import BytesCompression
import BytesTestSupport
import CLZMA
import Testing

/// The codecs' `unsupported` and `checksumMismatch` (open item 27): valid data using what no decoder here does, and
/// stored checks that fail, each told apart from corrupt data (`invalidValue`), one call and streamed. (The sites other
/// suites already reach: zstd's in `ZstdDecoderTests.rejectsMalformedFrames`, gzip's in `GzipMembersTests`, xz's
/// stream header and filters in `LZMADecoderTests`.)
@Suite("Error vocabulary")
struct ErrorVocabularyTests {
    static let text = Array(String(repeating: "Errors name what went wrong: unsupported data, or a failed check. ", count: 300).utf8)

    /// The errors decoding `stream` as `format` throws in one call and streamed in small pieces (`nil`: decoded; a
    /// format that decodes only whole buffers isn't streamed).
    static func errors(_ stream: [UInt8], _ format: DecompressionFormat) -> (whole: BytesError?, streamed: BytesError?) {
        var decompressor = Decompressor()
        var output = [UInt8](repeating: 0, count: text.count + 1024)
        var whole: BytesError?
        do throws(BytesError) {
            try decompressor.reset(for: format)
            _ = try output.withOutputRawSpan { span throws(BytesError) in try decompressor.decompressAll(stream.span.bytes, into: &span) }
        } catch {
            whole = error
        }
        guard format.isStreamable else { return (whole, nil) }
        do throws(BytesError) {
            try decompressor.reset(for: format)
        } catch {
            return (whole, error)
        }
        let result = streamDecode(stream, outputChunk: 1000, split: [1, 7, 100]) { input, output throws(BytesError) in
            try decompressor.decompress(input, into: &output)
        }
        return switch result {
        case .success: (whole, nil)
        case let .failure(error): (whole, error)
        }
    }

    /// zlib's preset dictionary (FDICT): a valid header naming a dictionary, which no decoder here takes.
    @Test func zlibPresetDictionary() {
        // CMF 0x78 (DEFLATE, 32 KiB), FLG 0x20 (FDICT; check bits make 0x7820 a multiple of 31), a dictionary ID.
        let stream: [UInt8] = [0x78, 0x20, 0, 0, 0, 1] + encodeAll(Self.text, format: .raw, level: 6) + [0, 0, 0, 0]
        let (whole, streamed) = Self.errors(stream, .deflate(.zlib))
        #expect(whole == .unsupported && streamed == .unsupported)
        // The same header without the check bits: corrupt.
        let corrupt: [UInt8] = [0x78, 0x21] + Array(stream.dropFirst(2))
        let corruptErrors = Self.errors(corrupt, .deflate(.zlib))
        #expect(corruptErrors.whole == .invalidValue && corruptErrors.streamed == .invalidValue)
    }

    /// bzip2's block CRC and stream CRC: `checksumMismatch`; streamed, every later call throws the same error until a
    /// reset (it rethrew `invalidValue`).
    @Test func bzip2Checks() throws {
        let stream = bzip2Compress(Self.text, level: 9)
        // "BZh9", the block magic (6 bytes), then the block's CRC; the stream's CRC is in the last 4–5 bytes
        // (after the 48-bit end magic, not byte-aligned): flip a bit in its middle.
        for offset in [10, stream.count - 3] {
            var bytes = stream
            bytes[offset] ^= 0x10
            let (whole, streamed) = Self.errors(bytes, .bzip2)
            #expect(whole == .checksumMismatch && streamed == .checksumMismatch, "byte \(offset)")
        }
        var bytes = stream
        bytes[10] ^= 0x10
        var decoder = BZip2Decoder()
        var output = [UInt8](repeating: 0, count: Self.text.count)
        for _ in 0..<2 {
            #expect(throws: BytesError.checksumMismatch) {
                _ = try output.withOutputRawSpan { span throws(BytesError) in try decoder.decompress(bytes.span.bytes, into: &span) }
            }
        }
    }

    /// Brotli's large-window escape (Google's extension beyond RFC 7932).
    @Test func brotliLargeWindow() {
        // WBITS: 1, then 000, then 001 (least significant bit first): the escape.
        let (whole, streamed) = Self.errors([0x11, 0, 0, 0, 0, 0], .brotli)
        #expect(whole == .unsupported && streamed == .unsupported)
    }

    /// LZBITMAP's `0x0C` and `0x0D` variants: their stored chunks decode, a compressed chunk (another format, which
    /// nothing here reads) is `unsupported`.
    @Test func lzbitmapOtherVariants() throws {
        var compressor = try Compressor(for: .lzbitmap)
        var stream = [UInt8](repeating: 0, count: CompressionFormat.lzbitmap.maximumCompressedSize(forByteCount: Self.text.count))
        let count = try stream.withOutputRawSpan { span throws(BytesError) -> Int in
            try compressor.compressAll(Self.text.span.bytes, into: &span)
            return span.byteCount
        }
        stream.removeSubrange(count...)
        #expect(Self.errors(stream, .lzbitmap).whole == nil)
        for variant: UInt8 in [0x0C, 0x0D] {
            var bytes = stream
            bytes[3] = variant
            #expect(Self.errors(bytes, .lzbitmap).whole == .unsupported, "variant \(variant)")
        }
    }

    /// A stored block whose NLEN isn't LEN's complement: corrupt (`invalidValue`; it was `mismatch`).
    @Test func storedBlockComplement() {
        // BFINAL 1, BTYPE 00, then LEN 4 and an NLEN that isn't its complement, then the 4 bytes.
        let stream: [UInt8] = [0x01, 4, 0, 0xFB, 0xFE, 1, 2, 3, 4]
        let (whole, streamed) = Self.errors(stream, .deflate(.raw))
        #expect(whole == .invalidValue && streamed == .invalidValue)
        var good = stream
        good[4] = 0xFF
        #expect(Self.errors(good, .deflate(.raw)).whole == nil)
    }

    /// `stream`'s first xz block header with `change` applied to its bytes and its CRC made right.
    static func xzBlockHeader(_ stream: [UInt8], _ change: (inout [UInt8], Int) -> Void) -> [UInt8] {
        // The block header follows the 12-byte stream header: its size byte, flags, …, CRC-32.
        let size = (Int(stream[12]) + 1) * 4
        var bytes = stream
        change(&bytes, size)
        let crc = CRC32.checksum(bytes.span.bytes.extracting(12..<(12 + size - 4)))
        for index in 0..<4 {
            bytes[12 + size - 4 + index] = UInt8(truncatingIfNeeded: crc >> (8 * index))
        }
        return bytes
    }

    /// LZMA2's properties byte with its reserved bits 6–7 set (xz 5.3.1: `unsupported`), and with a size code past 40
    /// (`invalidValue`).
    @Test func xzLZMA2Properties() {
        let stream = xzCompress(Self.text, preset: 6)
        // After the flags, the sizes the flags say are there (variable-length integers), then the filter ID (0x21), the
        // properties' size (1), and the properties byte.
        var position = 14
        for flag: UInt8 in [0x40, 0x80] where stream[13] & flag != 0 {
            while stream[position] & 0x80 != 0 {
                position += 1
            }
            position += 1
        }
        #expect(stream[position] == 0x21 && stream[position + 1] == 1)
        let properties = position + 2
        let reserved = Self.xzBlockHeader(stream) { bytes, _ in bytes[properties] |= 0x40 }
        #expect(Self.errors(reserved, .xz()).whole == .unsupported && Self.errors(reserved, .xz()).streamed == .unsupported)
        let tooLarge = Self.xzBlockHeader(stream) { bytes, _ in bytes[properties] = 41 }
        #expect(Self.errors(tooLarge, .xz()).whole == .invalidValue && Self.errors(tooLarge, .xz()).streamed == .invalidValue)
    }

    /// An xz block header setting reserved flags (its CRC made right): a later version's block.
    @Test func xzReservedBlockFlags() {
        let stream = xzCompress(Self.text, preset: 6)
        let bytes = Self.xzBlockHeader(stream) { bytes, _ in bytes[13] |= 0x04 }
        let (whole, streamed) = Self.errors(bytes, .xz())
        #expect(whole == .unsupported && streamed == .unsupported)
        // The CRC left as it was: damage, caught by the check first.
        var damaged = stream
        damaged[13] |= 0x04
        let damagedErrors = Self.errors(damaged, .xz())
        #expect(damagedErrors.whole == .checksumMismatch && damagedErrors.streamed == .checksumMismatch)
    }
}
