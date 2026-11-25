import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Testing

/// Streams past 4 GiB, encoded and decoded a piece at a time (nothing is held whole): Brotli's table positions wrap
/// (`BrotliMatcher.streamBase`), and gzip's trailer holds the length modulo 2^32 (RFC 1952's ISIZE), which the encoder
/// must write and the decoder compare that way. About 4.5 GiB each; release builds only (`BULK_TESTS=1`).
@Suite(.bulk) struct LongStreamBulkTests {
    /// 4.5 GiB: past 2^32 by half a gigabyte.
    static let pieceCount = 4608
    static let pieceSize = 1 << 20

    /// A compressible megabyte (a period of 251 bytes, shifted every 4 KiB), the same for every piece but its first 8
    /// bytes, which hold the piece's index: a stream that's compressible but not one repeated block.
    static let block: [UInt8] = (0..<pieceSize).map { UInt8(truncatingIfNeeded: $0 % 251 &+ ($0 >> 12) &* 7) }

    static func piece(_ index: Int) -> [UInt8] {
        var piece = block
        for byte in 0..<8 {
            piece[byte] = UInt8(truncatingIfNeeded: index >> (8 * byte))
        }
        return piece
    }

    /// Checks decoded bytes against the pieces as they arrive.
    struct Checker {
        var index = 0
        var offset = 0
        var expected = LongStreamBulkTests.piece(0)
        var total = 0
        var mismatchAt: Int?

        mutating func check(_ bytes: ArraySlice<UInt8>) {
            var bytes = bytes
            while !bytes.isEmpty {
                let count = min(bytes.count, LongStreamBulkTests.pieceSize - offset)
                if mismatchAt == nil, !bytes.prefix(count).elementsEqual(expected[offset..<(offset + count)]) {
                    mismatchAt = total
                }
                bytes = bytes.dropFirst(count)
                offset += count
                total += count
                if offset == LongStreamBulkTests.pieceSize {
                    index += 1
                    offset = 0
                    expected = LongStreamBulkTests.piece(index)
                }
            }
        }
    }

    /// Encodes the pieces with `compress` and decodes as the compressed bytes arrive, with `decompressor` (reset for the
    /// format). Returns the decoded byte count, whether everything matched, and the stream's last 8 bytes.
    static func roundTrip(
        _ decompressor: inout Decompressor,
        compress: (_ input: RawSpan, _ output: inout OutputRawSpan, _ flush: TransformFlush) throws(BytesError) -> TransformProgress
    ) throws(BytesError) -> (decoded: Int, matched: Bool, finished: Bool, tail: [UInt8]) {
        var checker = Checker()
        var compressed = [UInt8](repeating: 0, count: 2 * pieceSize)
        var pending: [UInt8] = [] // Compressed bytes the decoder hasn't consumed.
        var decoded = [UInt8](repeating: 0, count: pieceSize)
        var tail: [UInt8] = []
        var finished = false
        for index in 0..<pieceCount {
            let input = piece(index)
            let flush: TransformFlush = index == pieceCount - 1 ? .finish : .none
            var consumed = 0
            repeat {
                let progress = try compressed.withOutputRawSpan { span throws(BytesError) in
                    try compress(input.span.bytes.extracting(consumed...), &span, flush)
                }
                consumed += progress.consumed
                pending += compressed[..<progress.produced]
                tail = Array((tail + compressed[..<progress.produced]).suffix(8))
                // Decode what's there.
                var start = 0
                while true {
                    let step = try decoded.withOutputRawSpan { span throws(BytesError) in
                        try decompressor.decompress(pending.span.bytes.extracting(start...), into: &span)
                    }
                    start += step.consumed
                    checker.check(decoded[..<step.produced])
                    if step.status == .finished { finished = true }
                    if step.status != .needsOutput { break }
                }
                pending.removeFirst(start)
                if progress.status == .finished { break }
            } while consumed < input.count || flush == .finish
        }
        return (checker.total, checker.mismatchAt == nil, finished, tail)
    }

    /// Brotli at quality 1, streamed: positions pass 2^32 a little before the end and wrap.
    @Test func brotliPast4GiB() throws {
        var encoder = BrotliEncoder(quality: 1, windowBits: 22)
        var decompressor = try Decompressor(for: .brotli)
        let result = try Self.roundTrip(&decompressor) { input, output, flush throws(BytesError) in
            try encoder.compress(input, into: &output, flush: flush)
        }
        #expect(result.decoded == Self.pieceCount * Self.pieceSize)
        #expect(result.matched && result.finished)
    }

    /// gzip at level 1, streamed: the trailer's length is the total modulo 2^32, and the decoder accepts it.
    @Test func gzipLengthPast4GiB() throws {
        var encoder = DeflateEncoder(format: .gzip, level: 1)
        var decompressor = try Decompressor(for: .deflate(.gzip))
        let result = try Self.roundTrip(&decompressor) { input, output, flush throws(BytesError) in
            try encoder.compress(input, into: &output, flush: flush)
        }
        let total = Self.pieceCount * Self.pieceSize
        #expect(total > Int(UInt32.max))
        #expect(result.decoded == total)
        #expect(result.matched && result.finished)
        let length = UInt32(truncatingIfNeeded: total)
        #expect(result.tail.suffix(4).elementsEqual((0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) }), "ISIZE")
    }
}
