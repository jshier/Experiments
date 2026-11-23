import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import CZstd
import Foundation
import Testing

// MARK: - Drivers

/// `ZstdEncoder.compressAll` of `data` into a buffer of `ZstdEncoder.maximumCompressedSize`.
func zstdEncodeAll(_ data: [UInt8], encoder: inout ZstdEncoder) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: ZstdEncoder.maximumCompressedSize(forByteCount: data.count))
    var produced = 0
    do {
        try output.withOutputRawSpan { span throws(BytesError) in
            try encoder.compressAll(data.span.bytes, into: &span)
            produced = span.byteCount
        }
    } catch {
        Issue.record("compressAll threw \(error)")
    }
    return Array(output[..<produced])
}

/// `ZstdEncoder.compress` of `data` in `chunk`-byte pieces into `outputChunk`-byte pieces of output, each piece
/// followed by `flush` (the last by `.finish`), as a server streams a body.
func zstdEncodeStreaming(
    _ data: [UInt8], chunk: Int, outputChunk: Int = 1 << 16, flush: TransformFlush = .none, encoder: inout ZstdEncoder
) -> [UInt8] {
    encoder.reset()
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: outputChunk)
    var offset = 0
    repeat {
        let end = min(offset + chunk, data.count)
        let isLast = end == data.count
        var pending = Array(data[offset..<end])
        var progress: TransformProgress
        repeat {
            do {
                progress = try buffer.withOutputRawSpan { span throws(BytesError) in
                    try encoder.compress(pending.span.bytes, into: &span, flush: isLast ? .finish : flush)
                }
            } catch {
                Issue.record("compress threw \(error)")
                return result
            }
            result += buffer[..<progress.produced]
            pending.removeFirst(progress.consumed)
        } while progress.status == .needsOutput
        #expect(pending.isEmpty)
        #expect(progress.status == (isLast ? .finished : .needsInput))
        offset = end
    } while offset < data.count
    return result
}

/// libzstd's frame for `data` with exactly `parameters` (and its own defaults otherwise: content size stated).
func zstdReferenceEncode(_ data: [UInt8], parameters: ZstdEncoder.Parameters, checksum: Bool) -> [UInt8] {
    zstdCompress(data, parameters: zstdReferenceParameters(parameters, checksum: checksum))
}

/// `parameters` as libzstd's `ZSTD_cParameter`s.
func zstdReferenceParameters(_ parameters: ZstdEncoder.Parameters, checksum: Bool) -> [(ZSTD_cParameter, Int32)] {
    [
        (ZSTD_c_strategy, Int32(parameters.strategy.rawValue)), (ZSTD_c_windowLog, Int32(parameters.windowLog)),
        (ZSTD_c_hashLog, Int32(parameters.hashLog)), (ZSTD_c_chainLog, Int32(parameters.chainLog)),
        (ZSTD_c_searchLog, 1), (ZSTD_c_minMatch, Int32(parameters.minimumMatchLength)),
        (ZSTD_c_targetLength, Int32(parameters.targetLength)), (ZSTD_c_checksumFlag, checksum ? 1 : 0),
    ]
}

/// Checks that `frame` decodes to `data` with libzstd and with `ZstdDecoder` (one call and streamed).
func expectZstdDecodes(_ frame: [UInt8], to data: [UInt8], _ comment: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let reference = zstdReferenceDecompress(frame, capacity: data.count + 64)
    #expect(reference == .decoded(data), "\(comment): libzstd", sourceLocation: sourceLocation)
    let ours = zstdDecodeBothWays(frame, capacity: data.count + 64)
    #expect((try? ours.get()) == data, "\(comment): ZstdDecoder", sourceLocation: sourceLocation)
}

/// The index of the first byte where `a` and `b` differ, or `nil`.
func firstDifference(_ a: [UInt8], _ b: [UInt8]) -> Int? {
    for index in 0..<min(a.count, b.count) where a[index] != b[index] { return index }
    return a.count == b.count ? nil : min(a.count, b.count)
}

enum ZstdEncoderSamples {
    /// Inputs that reach every block and literal form: empty, 1 byte, block boundaries, incompressible bytes, runs,
    /// text, and the decoder tests' mixtures.
    static let all: [(name: String, bytes: [UInt8])] = {
        var rng = SplitMix64(seed: 7)
        let random = (0..<300_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let text = Array(String(repeating: "Zstandard frames hold blocks of literals and sequences. ", count: 6000).utf8)
        var samples: [(String, [UInt8])] = [
            ("empty", []), ("1 byte", [42]), ("6 bytes", Array("abcdef".utf8)), ("7 bytes", Array("abcdefg".utf8)),
            ("random 1000", Array(random.prefix(1000))), ("random 300 000", random),
            ("zeros 131 072", [UInt8](repeating: 0, count: 131_072)),
            ("zeros 300 000", [UInt8](repeating: 0, count: 300_000)),
            ("text 131 071", Array(text.prefix(131_071))), ("text 131 072", Array(text.prefix(131_072))),
            ("text 131 073", Array(text.prefix(131_073))), ("text 262 144", Array(text.prefix(262_144))),
            ("random then zeros", Array(random.prefix(150_000)) + [UInt8](repeating: 0, count: 200_000)),
        ]
        samples += zstdSamples()
        return samples
    }()

    /// The levels' parameters, and some others: small windows and tables, every hash length, a target length.
    static let parameters: [(name: String, parameters: ZstdEncoder.Parameters)] = {
        var list = (1...ZstdEncoder.Parameters.maximumLevel).map { ("level \($0)", ZstdEncoder.Parameters(level: $0)) }
        list += [
            ("fast 4", .init(strategy: .fast, windowLog: 17, hashLog: 12, chainLog: 12, minimumMatchLength: 4)),
            ("fast 5 target 3", .init(strategy: .fast, windowLog: 18, hashLog: 15, chainLog: 12, minimumMatchLength: 5, targetLength: 3)),
            ("dfast 4", .init(strategy: .doubleFast, windowLog: 16, hashLog: 15, chainLog: 13, minimumMatchLength: 4)),
            ("dfast 6", .init(strategy: .doubleFast, windowLog: 20, hashLog: 16, chainLog: 14, minimumMatchLength: 6)),
            ("dfast 7", .init(strategy: .doubleFast, windowLog: 12, hashLog: 10, chainLog: 9, minimumMatchLength: 7)),
            ("window 10", ZstdEncoder.Parameters(level: 3, windowLog: 10)),
            ("http 3", ZstdEncoder.Parameters(level: 3, windowLog: ZstdEncoder.Parameters.httpWindowLog)),
        ]
        return list
    }()
}

// MARK: - Tests

@Suite("Zstandard encoding")
struct ZstdEncoderTests {
    /// Every sample at every level: the frame is libzstd's, byte for byte, with the same parameters, and it decodes.
    @Test(arguments: ZstdEncoderSamples.parameters.indices)
    func matchesLibzstd(_ index: Int) {
        let (name, parameters) = ZstdEncoderSamples.parameters[index]
        for checksum in [false, true] {
            var encoder = ZstdEncoder(parameters: parameters, checksum: checksum)
            for (sample, data) in ZstdEncoderSamples.all {
                let ours = zstdEncodeAll(data, encoder: &encoder)
                let reference = zstdReferenceEncode(data, parameters: parameters, checksum: checksum)
                let difference = firstDifference(ours, reference)
                #expect(difference == nil, "\(name), \(sample), checksum \(checksum): differs at \(difference ?? -1) (\(ours.count) against \(reference.count) bytes)")
                expectZstdDecodes(ours, to: data, "\(name), \(sample)")
            }
        }
    }

    /// A whole body given to `compress` with `.finish`, or streamed in pieces after `reset(contentSize:)`, makes the
    /// same frame as `compressAll`: same parameters, same blocks, through the streaming window (which slides when the
    /// content is larger than it).
    @Test(arguments: [0, 2, 5, 9])
    func streamsTheOneShotFrame(_ index: Int) {
        let (name, parameters) = ZstdEncoderSamples.parameters[index]
        var encoder = ZstdEncoder(parameters: parameters, checksum: true)
        for (sample, data) in ZstdEncoderSamples.all {
            let expected = zstdEncodeAll(data, encoder: &encoder)
            let atOnce = zstdEncodeStreaming(data, chunk: max(data.count, 1), outputChunk: 1000, encoder: &encoder)
            #expect(atOnce == expected, "\(name), \(sample): at once")
            for chunk in [1000, 65536, 200_000] where chunk < data.count {
                encoder.reset(contentSize: data.count)
                var pieces: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                var offset = 0
                while true {
                    let end = min(offset + chunk, data.count)
                    var pending = Array(data[offset..<end])
                    var progress: TransformProgress
                    repeat {
                        progress = try! buffer.withOutputRawSpan { span throws(BytesError) in
                            try encoder.compress(pending.span.bytes, into: &span, flush: end == data.count ? .finish : .none)
                        }
                        pieces += buffer[..<progress.produced]
                        pending.removeFirst(progress.consumed)
                    } while progress.status == .needsOutput
                    offset = end
                    if offset == data.count { break }
                }
                #expect(pieces == expected, "\(name), \(sample): \(chunk)-byte pieces after reset(contentSize:)")
            }
        }
    }

    /// Streams of unknown size, in pieces of every kind, flushed or not, into small output buffers: every frame
    /// decodes, unflushed ones within 1% of the one-shot frame's size.
    @Test(arguments: [0, 2, 3, 9])
    func streams(_ index: Int) {
        let (name, parameters) = ZstdEncoderSamples.parameters[index]
        var encoder = ZstdEncoder(parameters: parameters, checksum: index & 1 == 0)
        for (sample, data) in ZstdEncoderSamples.all where data.count > 1000 {
            let oneShot = zstdEncodeAll(data, encoder: &encoder)
            for (chunk, outputChunk, flush) in [(1, 7, TransformFlush.none), (777, 100, .none), (70_000, 1 << 16, .none), (5_000, 1 << 16, .flush)]
            where chunk > 1 || data.count <= 20_000 {
                let frame = zstdEncodeStreaming(data, chunk: chunk, outputChunk: outputChunk, flush: flush, encoder: &encoder)
                expectZstdDecodes(frame, to: data, "\(name), \(sample), \(chunk)-byte pieces, \(flush)")
                if flush == .none {
                    #expect(frame.count <= oneShot.count + oneShot.count / 100 + 64, "\(name), \(sample): \(frame.count) against \(oneShot.count)")
                }
            }
        }
    }

    /// Many small flushes: each ends a block, and the frame still decodes; a flush with nothing new adds nothing.
    @Test func flushesOften() throws {
        var encoder = ZstdEncoder(level: 1, checksum: true)
        let data = Array(ZstdEncoderSamples.all.first { $0.name == "text 131 071" }!.bytes.prefix(40_000))
        let frame = zstdEncodeStreaming(data, chunk: 100, flush: .flush, encoder: &encoder)
        expectZstdDecodes(frame, to: data, "100-byte flushes")
        // Every flush is a block: 400 of them.
        #expect(frame.count > 400 * 3)

        encoder.reset()
        var output = [UInt8](repeating: 0, count: 1000)
        let progress = try output.withOutputRawSpan { span throws(BytesError) in
            _ = try encoder.compress([UInt8](repeating: 9, count: 10).span.bytes, into: &span, flush: .flush)
            let before = span.byteCount
            let again = try encoder.compress(RawSpan(), into: &span, flush: .flush)
            #expect(span.byteCount == before)
            return again
        }
        #expect(progress.status == .needsInput)
    }

    /// An empty stream ended at once is the empty frame `compressAll` makes, and libzstd's.
    @Test func emptyStreams() {
        for checksum in [false, true] {
            var encoder = ZstdEncoder(level: 3, checksum: checksum)
            let oneShot = zstdEncodeAll([], encoder: &encoder)
            #expect(oneShot == zstdReferenceEncode([], parameters: encoder.parameters, checksum: checksum))
            #expect(zstdEncodeStreaming([], chunk: 1, encoder: &encoder) == oneShot)
            expectZstdDecodes(oneShot, to: [], "empty")
        }
    }

    /// A stream promised one size that delivers another throws.
    @Test func rejectsTheWrongContentSize() {
        var encoder = ZstdEncoder(level: 1)
        encoder.reset(contentSize: 10)
        var output = [UInt8](repeating: 0, count: 100)
        #expect(throws: BytesError.mismatch) {
            _ = try output.withOutputRawSpan { span throws(BytesError) in
                try encoder.compress([UInt8](repeating: 1, count: 5).span.bytes, into: &span, flush: .finish)
            }
        }
    }

    /// A body larger than the window: the frame isn't a single segment (whose window would be its size), it states the
    /// configured window, and decoders limited to that window decode it, one call or streamed.
    @Test func respectsTheWindow() throws {
        let data = Self.nineMegabytes
        let parameters = ZstdEncoder.Parameters(level: 3, windowLog: ZstdEncoder.Parameters.httpWindowLog)
        var encoder = ZstdEncoder(parameters: parameters, checksum: true)
        for frame in [zstdEncodeAll(data, encoder: &encoder), zstdEncodeStreaming(data, chunk: 100_000, encoder: &encoder)] {
            let header = try #require(try ZstdFrameHeader(parsing: frame.span.bytes))
            #expect(!header.isSingleSegment)
            #expect(header.windowSize == 1 << 19)
            var decoder = ZstdDecoder(maximumWindowSize: 1 << 19)
            #expect((try? zstdDecodeStreaming(frame, chunk: 1 << 16, outputChunk: 1 << 16, decoder: &decoder).get()) == data)
            #expect(Self.libzstdDecodes(frame, windowLog: 19) == data)
        }
        // And small bodies are single segments, their window their size.
        let small = zstdEncodeAll(Array(data.prefix(100_000)), encoder: &encoder)
        let header = try #require(try ZstdFrameHeader(parsing: small.span.bytes))
        #expect(header.isSingleSegment && header.windowSize == 100_000)
    }

    /// 9 MiB of text with matches near and far.
    static let nineMegabytes: [UInt8] = {
        var rng = SplitMix64(seed: 9)
        let words = ["window", "frame", "block", "literal", "sequence", "offset", "match", "entropy", "table", "zstd"]
        var text: [UInt8] = []
        text.reserveCapacity(9 << 20)
        while text.count < 9 << 20 {
            if rng.next() % 50 == 0 && text.count > 4 << 20 {
                // A copy from far back: beyond a 512 KB window, within 8 MB.
                let start = Int(rng.next() % UInt64(text.count - (1 << 20)))
                text += text[start..<(start + 300)]
            } else {
                text += Array(words[Int(rng.next() % 10)].utf8) + [UInt8(ascii: " ")]
            }
        }
        return Array(text.prefix(9 << 20))
    }()

    /// libzstd's streaming decoder, its window limited to `windowLog`.
    static func libzstdDecodes(_ frame: [UInt8], windowLog: Int32) -> [UInt8]? {
        let stream = ZSTD_createDStream()!
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, windowLog)) == 0 else { return nil }
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        return frame.withUnsafeBytes { all -> [UInt8]? in
            var input = ZSTD_inBuffer(src: all.baseAddress, size: all.count, pos: 0)
            while true {
                let (remaining, produced) = chunk.withUnsafeMutableBytes { buffer in
                    var output = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                    let remaining = ZSTD_decompressStream(stream, &output, &input)
                    return (remaining, output.pos)
                }
                if ZSTD_isError(remaining) != 0 { return nil }
                result += chunk[..<produced]
                if remaining == 0 { return result }
                if input.pos == input.size && produced == 0 { return nil }
            }
        }
    }

    /// Indices near 3.5 GB are moved down mid-frame: the frame is unchanged (libzstd's), one call or streamed.
    @Test func correctsIndices() {
        let data = Array(ZstdEncoderSamples.all.first { $0.name == "mixed" }!.bytes.prefix(600_000))
        for level in [1, 3] {
            var encoder = ZstdEncoder(level: level, windowLog: 17, checksum: true)
            let expected = zstdReferenceEncode(data, parameters: encoder.parameters, checksum: true)
            encoder.setNextIndex((3500 << 20) - 200_000)
            #expect(zstdEncodeAll(data, encoder: &encoder) == expected, "level \(level), one call")
            // The next frame continues from the corrected indices.
            #expect(zstdEncodeAll(data, encoder: &encoder) == expected, "level \(level), after")
            encoder.setNextIndex((3500 << 20) - 300_000)
            encoder.reset(contentSize: data.count)
            var output = [UInt8](repeating: 0, count: ZstdEncoder.maximumCompressedSize(forByteCount: data.count))
            let streamed = output.withOutputRawSpan { span in
                var offset = 0
                while offset < data.count {
                    let end = min(offset + 50_000, data.count)
                    let progress = try! encoder.compress(data[offset..<end].span.bytes, into: &span, flush: end == data.count ? .finish : .none)
                    offset += progress.consumed
                }
                return span.byteCount
            }
            #expect(Array(output[..<streamed]) == expected, "level \(level), streamed")
        }
    }

    /// Memory: the tables at creation, the window as streams need it.
    @Test func reportsMemory() {
        var encoder = ZstdEncoder(level: 3, windowLog: ZstdEncoder.Parameters.httpWindowLog)
        let tables = encoder.memoryUsage
        // Hash tables of 512 and 256 KB, a 128 KB block's sequences (256 KB), literals, and staging.
        #expect(tables < 3 << 19)
        _ = zstdEncodeStreaming(Self.nineMegabytes, chunk: 1 << 20, encoder: &encoder)
        #expect(encoder.memoryUsage == tables + (1 << 19) + (128 << 10))
    }
}

// MARK: - Bulk

@Suite(.bulk) struct ZstdEncoderBulkTests {
    /// Every corpus file (Silesia and the web assets) at every level, with the HTTP window too: libzstd's frame byte
    /// for byte, and decoded back by `ZstdDecoder`.
    @Test(arguments: [
        "silesia/dickens", "silesia/mozilla", "silesia/mr", "silesia/nci", "silesia/ooffice", "silesia/osdb",
        "silesia/reymont", "silesia/samba", "silesia/sao", "silesia/webster", "silesia/x-ray", "silesia/xml",
        "web/Main.js", "web/Main.css", "web/CodeMirror.js", "web/Three.js", "web/Main.html",
    ])
    func matchesLibzstdOnTheCorpus(_ path: String) {
        guard let url = Corpus.file(path), let contents = FileManager.default.contents(atPath: url.path) else { return }
        let data = [UInt8](contents)
        var settings = (1...ZstdEncoder.Parameters.maximumLevel).map { ZstdEncoder.Parameters(level: $0) }
        settings.append(ZstdEncoder.Parameters(level: 3, windowLog: ZstdEncoder.Parameters.httpWindowLog))
        var decoder = ZstdDecoder()
        for (index, parameters) in settings.enumerated() {
            let checksum = index & 1 == 1
            var encoder = ZstdEncoder(parameters: parameters, checksum: checksum)
            let ours = zstdEncodeAll(data, encoder: &encoder)
            let reference = zstdReferenceEncode(data, parameters: parameters, checksum: checksum)
            #expect(firstDifference(ours, reference) == nil, "\(path), \(parameters): \(ours.count) against \(reference.count)")
            #expect((try? zstdDecodeAll(ours, capacity: data.count, decoder: &decoder).get()) == data, "\(path), \(parameters)")
            // Streamed in 64 KB pieces with its size promised: the same frame.
            if index == 2 {
                encoder.reset(contentSize: data.count)
                var output = [UInt8](repeating: 0, count: ZstdEncoder.maximumCompressedSize(forByteCount: data.count))
                let size = output.withOutputRawSpan { span in
                    var offset = 0
                    while offset < data.count {
                        let end = min(offset + (1 << 16), data.count)
                        let progress = try! encoder.compress(data[offset..<end].span.bytes, into: &span, flush: end == data.count ? .finish : .none)
                        offset += progress.consumed
                    }
                    return span.byteCount
                }
                #expect(Array(output[..<size]) == reference, "\(path), streamed")
            }
        }
    }

    /// Every size around the block size and its quarters, and every small size, at every level: libzstd's frames.
    @Test(arguments: 1...ZstdEncoder.Parameters.maximumLevel)
    func matchesLibzstdAtEverySize(_ level: Int) {
        var rng = SplitMix64(seed: UInt64(level))
        let text = ZstdEncoderSamples.all.first { $0.name == "mixed" }!.bytes
        let random = (0..<140_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let parameters = ZstdEncoder.Parameters(level: level)
        let checksum = level == 2
        var encoder = ZstdEncoder(parameters: parameters, checksum: checksum)
        var sizes = Array(0...300)
        for boundary in [32 << 10, 64 << 10, 96 << 10, 128 << 10] { sizes += (boundary - 40)...(boundary + 40) }
        for size in sizes {
            for source in [text, random] {
                let data = Array(source.prefix(size))
                let ours = zstdEncodeAll(data, encoder: &encoder)
                #expect(ours == zstdReferenceEncode(data, parameters: parameters, checksum: checksum), "level \(level), \(size) bytes")
            }
        }
    }

    /// Streams in random pieces, flushed at random, into random output room: every frame decodes.
    @Test func streamsInRandomPieces() {
        var rng = SplitMix64(seed: 3)
        var decoder = ZstdDecoder()
        for (name, data) in ZstdEncoderSamples.all where data.count > 10_000 {
            for parameters in ZstdEncoderSamples.parameters.map(\.parameters) {
                var encoder = ZstdEncoder(parameters: parameters, checksum: true)
                var frame: [UInt8] = []
                var offset = 0
                while true {
                    let end = min(offset + Int(rng.next() % 50_000), data.count)
                    let isLast = end == data.count
                    let flush: TransformFlush = isLast ? .finish : rng.next() % 4 == 0 ? .flush : .none
                    var pending = Array(data[offset..<end])
                    var progress: TransformProgress
                    repeat {
                        var buffer = [UInt8](repeating: 0, count: 1 + Int(rng.next() % 70_000))
                        progress = try! buffer.withOutputRawSpan { span throws(BytesError) in
                            try encoder.compress(pending.span.bytes, into: &span, flush: flush)
                        }
                        frame += buffer[..<progress.produced]
                        pending.removeFirst(progress.consumed)
                    } while progress.status == .needsOutput
                    offset = end
                    if isLast { break }
                }
                #expect((try? zstdDecodeAll(frame, capacity: data.count, decoder: &decoder).get()) == data, "\(name), \(parameters)")
            }
        }
    }
}
