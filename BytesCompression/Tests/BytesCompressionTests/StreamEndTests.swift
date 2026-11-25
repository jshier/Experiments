import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Testing

/// Where a stream ends when its input comes in pieces. For the formats that concatenate (gzip members, Zstandard frames,
/// xz and bzip2 streams), a piece that ends exactly where one stream does, or 1–3 bytes into bzip2's next `BZh`, isn't
/// the data's end: another stream may follow in the next piece. Reported as the end, everything after the first stream
/// was dropped with no error (half of two streams came out, `finished`), through `ChunkedDecompressor`'s staged input
/// (a ZipCrypto zstd entry whose first frame filled the staging buffer exactly was refused as a size mismatch) and
/// through bzip2's `transform` (every `Pipeline`).
@Suite struct StreamEndTests {
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case gzip, zstd, xz, bzip2
        var testDescription: String { rawValue }

        var format: DecompressionFormat {
            switch self {
            case .gzip: .deflate(.gzip)
            case .zstd: .zstd()
            case .xz: .xz()
            case .bzip2: .bzip2
            }
        }

        func compress(_ data: [UInt8]) throws -> [UInt8] {
            switch self {
            case .gzip: try compressed(data, .deflate(.gzip, level: 1))
            case .zstd: try compressed(data, .zstd(level: 3))
            case .xz: xzCompress(data, preset: 1)
            case .bzip2: bzip2Compress(data, level: 1)
            }
        }
    }

    static let first = SampleBytes.text(200_000, seed: 11)
    static let second = SampleBytes.mixed(150_000, seed: 12)

    /// Two streams, staged in two pieces: the first ends exactly at the first stream's end, or `past` bytes into the
    /// second. Both streams decode, whole.
    @Test(arguments: Kind.allCases, [0, 1, 2, 3, 4])
    func stagedPieceEndingAtAStreamsEnd(_ kind: Kind, past: Int) throws {
        let a = try kind.compress(Self.first), b = try kind.compress(Self.second)
        var chunks = ChunkedDecompressor()
        let output = try Self.decodeStaged(&chunks, a + b, kind.format, cuts: [a.count + past])
        #expect(output == Self.first + Self.second)
    }

    /// The same through `Decompressor.transform` (what `Pipeline` drives): the first call's input ends at or just past
    /// the first stream's end, without flushing; the rest comes with `.finish`.
    @Test(arguments: Kind.allCases, [0, 1, 2, 3, 4])
    func transformInputEndingAtAStreamsEnd(_ kind: Kind, past: Int) throws {
        let a = try kind.compress(Self.first), b = try kind.compress(Self.second)
        let input = a + b
        var decompressor = Decompressor()
        try decompressor.reset(for: kind.format)
        var output: [UInt8] = []
        var start = 0
        for (end, flush) in [(a.count + past, TransformFlush.none), (input.count, .finish)] {
            while true {
                var room = [UInt8](repeating: 0, count: 65_536)
                let progress = try room.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
                    try decompressor.transform(input.span.bytes.extracting(start..<end), into: &span, flush: flush)
                }
                output += room.prefix(progress.produced)
                start += progress.consumed
                if progress.status == .needsOutput { continue }
                if flush == .none {
                    // Not flushing, the end can't be reported while bytes may follow.
                    #expect(progress.status == .needsInput, "\(kind) \(past): \(progress.status)")
                }
                break
            }
        }
        #expect(output == Self.first + Self.second)
    }

    /// One stream staged whole: it ends once the input does.
    @Test(arguments: Kind.allCases)
    func singleStreamEndsWithTheInput(_ kind: Kind) throws {
        let a = try kind.compress(Self.first)
        var chunks = ChunkedDecompressor()
        #expect(try Self.decodeStaged(&chunks, a, kind.format, cuts: []) == Self.first)
    }

    /// Staged input that ends inside a stream: cut short, after the input has ended.
    @Test(arguments: Kind.allCases)
    func stagedInputCutShortThrows(_ kind: Kind) throws {
        let a = try kind.compress(Self.first)
        var chunks = ChunkedDecompressor()
        #expect(throws: BytesError.insufficientData) { _ = try Self.decodeStaged(&chunks, Array(a.prefix(a.count - 7)), kind.format, cuts: []) }
    }

    /// What follows the last stream. bzip2 reads four or more bytes that aren't `BZh` as the end, leaving them; gzip,
    /// Zstandard, and xz read any following byte as the next stream's start and refuse what isn't one (pinned, so the
    /// decoders aren't "fixed" to a wrong expectation).
    @Test(arguments: Kind.allCases)
    func trailingBytesAfterTheLastStream(_ kind: Kind) throws {
        let a = try kind.compress(Self.first)
        let garbage: [UInt8] = [0x55, 0x66, 0x77, 0x88, 0x99]
        var chunks = ChunkedDecompressor()
        if kind == .bzip2 {
            #expect(try Self.decodeStaged(&chunks, a + garbage, kind.format, cuts: [a.count]) == Self.first)
            #expect(unsafe chunks.pendingInput.count == garbage.count)
        } else {
            #expect(throws: BytesError.self) { _ = try Self.decodeStaged(&chunks, a + garbage, kind.format, cuts: [a.count]) }
        }
    }

    /// Decodes `stream` through staged input, in pieces ending at `cuts` (then the rest), alternating buffers.
    static func decodeStaged(
        _ chunks: inout ChunkedDecompressor, _ stream: [UInt8], _ format: DecompressionFormat, cuts: [Int]
    ) throws(BytesError) -> [UInt8] {
        var output: [UInt8] = []
        let ends = cuts + [stream.count]
        var fed = 0, piece = 0
        chunks.stageInput()
        try chunks.start(format, decodedSize: nil)
        var target = 0
        loop: while true {
            switch try unsafe chunks.nextChunk(into: target) {
            case let .chunk(bytes, finished):
                output.append(copying: unsafe RawSpan(_unsafeBytes: bytes))
                if finished { break loop }
                target ^= 1
            case .needsInput:
                // The next piece, as far as it fits; nothing once all are in (which ends the input).
                _ = try chunks.fillInput { span in
                    // Empty pieces are skipped: adding nothing would end the input.
                    while piece < ends.count, fed == ends[piece] {
                        piece += 1
                    }
                    guard piece < ends.count else { return 0 }
                    let count = min(ends[piece] - fed, span.byteCount)
                    span.withUnsafeMutableBytes { target in
                        stream.withUnsafeBytes { unsafe target.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[fed..<(fed + count)])) }
                    }
                    fed += count
                    if fed == ends[piece] { piece += 1 }
                    return count
                }
            }
        }
        return output
    }
}

/// Every cut point of three concatenated streams (one piece up to the cut, the rest after), staged: the output is the
/// three inputs whole, whatever the cut.
@Suite(.bulk) struct StreamEndBulkTests {
    @Test(arguments: StreamEndTests.Kind.allCases)
    func everyCutOfThreeStreams(_ kind: StreamEndTests.Kind) throws {
        let parts = [SampleBytes.text(3_000, seed: 21), SampleBytes.mixed(2_000, seed: 22), SampleBytes.text(1_500, seed: 23)]
        let stream = try parts.flatMap { try kind.compress($0) }
        let expected = parts.flatMap(\.self)
        var chunks = ChunkedDecompressor()
        for cut in 0...stream.count {
            let output = try StreamEndTests.decodeStaged(&chunks, stream, kind.format, cuts: [cut])
            guard output == expected else {
                Issue.record("\(kind): cut at \(cut) of \(stream.count) gave \(output.count) of \(expected.count) bytes")
                return
            }
        }
    }
}
