import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import CLZMA
import Foundation
import Testing

// MARK: - Drivers

/// Streams `data` through `decompress` (a decoder's `decompress(_:into:)`) as a pipeline would: output in pieces of
/// `outputChunk` bytes; input as the whole rest of the stream every call (`split` nil), or grown by the sizes in
/// `split` in turn whenever the decoder asks for input, with what it didn't consume passed again.
///
/// - Parameter concatenated: Whether `.finished` before the end of `data` can be followed by more (xz streams).
/// - Returns: The output and the input consumed; `.insufficientData` if the decoder asks for input after all of
///   `data`; the decoder's error otherwise.
func streamDecode(
    _ data: [UInt8], outputChunk: Int, split: [Int]? = nil, concatenated: Bool = false,
    _ decompress: (RawSpan, inout OutputRawSpan) throws(BytesError) -> TransformProgress
) -> Result<(output: [UInt8], consumed: Int), BytesError> {
    var output: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: outputChunk)
    var consumed = 0
    var fed = split == nil ? data.count : 0
    var piece = 0
    var calls = 0
    while true {
        calls += 1
        guard calls < 50_000_000 else {
            Issue.record("the decoder didn't finish")
            return .failure(.invalidValue)
        }
        let progress: TransformProgress
        do throws(BytesError) {
            progress = try chunk.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
                try decompress(data.span.bytes.extracting(consumed..<fed), &span)
            }
        } catch {
            return .failure(error)
        }
        output += chunk.prefix(progress.produced)
        consumed += progress.consumed
        switch progress.status {
        case .needsOutput:
            continue
        case .finished where !concatenated || consumed == data.count:
            return .success((output, consumed))
        case .finished, .needsInput:
            guard fed < data.count, let split else { return .failure(.insufficientData) }
            fed = min(data.count, fed + split[piece % split.count])
            piece += 1
        }
    }
}

func streamXZ(_ data: [UInt8], outputChunk: Int, split: [Int]? = nil, decoder: inout XZDecoder) -> Result<[UInt8], BytesError> {
    decoder.reset()
    return streamDecode(data, outputChunk: outputChunk, split: split, concatenated: true) { (input, output) throws(BytesError) in
        try decoder.decompress(input, into: &output)
    }.map(\.output)
}

func streamXZ(_ data: [UInt8], outputChunk: Int, split: [Int]? = nil) -> Result<[UInt8], BytesError> {
    var decoder = XZDecoder()
    return streamXZ(data, outputChunk: outputChunk, split: split, decoder: &decoder)
}

func streamLZMA(
    _ data: [UInt8], properties: LZMAProperties, size: Int?, outputChunk: Int, split: [Int]? = nil, decoder: inout LZMADecoder
) -> Result<(output: [UInt8], consumed: Int), BytesError> {
    do throws(BytesError) {
        try decoder.reset(properties: properties, uncompressedSize: size)
    } catch {
        return .failure(error)
    }
    return streamDecode(data, outputChunk: outputChunk, split: split) { (input, output) throws(BytesError) in
        try decoder.decompress(input, into: &output)
    }
}

/// Raw LZMA1 with liblzma: with an end marker (`marker`), or without one (LZMA1EXT).
func lzma1Compress(_ data: [UInt8], options: lzma_options_lzma, marker: Bool) -> [UInt8] {
    var options = options
    if !marker { options.ext_flags = 0 }
    return lzmaRawCompress(data, filter: marker ? LZMAFilterID.lzma1 : LZMAFilterID.lzma1Extended, options: options)
}

/// Output chunk sizes for an input of `count` bytes: 1 and 7 only for small ones (they're a call per byte or seven).
func outputChunks(for count: Int) -> [Int] {
    (count <= 20_000 ? [1, 7] : count <= 100_000 ? [7] : []) + [4096, 65_536, 1 << 20]
}

/// Input piece sizes: one byte at a time, odd sizes, and sizes around the units' (an LZMA symbol's 20 bytes, the
/// tail margin, a 64 KiB chunk).
let inputSplits: [[Int]] = [[1], [7, 19, 33], [20], [1000, 1, 3, 70_000], [65_542]]

// MARK: - Tests

@Suite("Streaming LZMA and xz")
struct LZMAStreamingTests {
    // MARK: .xz

    /// Every LZMA sample (but the large one) at two presets, through every output chunk size, whole input.
    @Test func xzMatchesWholeBuffer() {
        var decoder = XZDecoder()
        for (name, data) in lzmaSamples() where name != "large" {
            for preset: UInt32 in [0, 6] {
                let compressed = xzCompress(data, preset: preset)
                let expected = xzDecode(compressed, capacity: data.count)
                #expect(expected == .success(data))
                for chunk in outputChunks(for: data.count) {
                    #expect(streamXZ(compressed, outputChunk: chunk, decoder: &decoder) == expected, "\(name) preset \(preset), chunks of \(chunk)")
                }
            }
        }
    }

    /// Input split every which way, with blocks that state their sizes and blocks that don't, several streams, and
    /// stream padding.
    @Test func xzSplitInput() {
        let parts = lzmaSamples().filter { ["text", "records", "odd", "one byte", "empty"].contains($0.name) }.map { Array($0.bytes.prefix(60_000)) }
        var file: [UInt8] = []
        var expected: [UInt8] = []
        for (index, part) in parts.enumerated() {
            file += index.isMultiple(of: 2) ? xzCompress(part, preset: 1, check: [LZMA_CHECK_CRC32, LZMA_CHECK_CRC64, LZMA_CHECK_NONE][index % 3])
                : xzCompressBlocks(part, preset: 3, blockSize: 25_000)
            file += [UInt8](repeating: 0, count: 4 * (index % 3))
            expected += part
        }
        var decoder = XZDecoder()
        for split in inputSplits {
            for chunk in [7, 4096, 1 << 20] where split != [1] || chunk != 7 {
                #expect(streamXZ(file, outputChunk: chunk, split: split, decoder: &decoder) == .success(expected), "split \(split), chunks of \(chunk)")
            }
        }
    }

    /// Larger than the window's room (2 MiB) with a 64 KiB dictionary: the window slides, and matches reach back
    /// across slides. The default dictionary (8 MiB) keeps it all.
    @Test func xzSlidesTheWindow() {
        let large = largeSample()
        let data = Array((large + large.reversed()).prefix(5 << 20))
        var decoder = XZDecoder()
        for dictionary: UInt32 in [1 << 16, 8 << 20] {
            let compressed = xzCompress(data, options: lzmaOptions(preset: 0, dictionary: dictionary))
            #expect(streamXZ(compressed, outputChunk: 1 << 20, decoder: &decoder) == .success(data), "dictionary \(dictionary)")
        }
        // Sizes in the block headers: windows sized by them.
        let blocks = xzCompressBlocks(data, preset: 0, blockSize: 3 << 20)
        #expect(streamXZ(blocks, outputChunk: 65_536, split: [100_000], decoder: &decoder) == .success(data))
    }

    @Test func xzDictionaryLimits() {
        let data = Array(lzmaSamples().first { $0.name == "text" }!.bytes.prefix(100_000))
        // A header's 1.5 GiB dictionary on a 100 KB file: the window grows only with the output (a limit of 64 KiB
        // holds the dictionary that's used). The block header's dictionary byte (after its size, flags, filter ID,
        // and properties size) and CRC-32 rewritten: liblzma's encoder would allocate gigabytes for the dictionary.
        var compressed = xzCompress(data, options: lzmaOptions(preset: 1, dictionary: 1 << 16))
        let headerEnd = 12 + (Int(compressed[12]) + 1) * 4
        let filter = compressed[12..<headerEnd].firstRange(of: [0x21, 0x01, 8])! // LZMA2, one byte: 64 KiB.
        compressed[filter.upperBound - 1] = 37 // 3 << 29
        let crc = CRC32.checksum(compressed.span.bytes.extracting(12..<(headerEnd - 4)))
        compressed.replaceSubrange((headerEnd - 4)..<headerEnd, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        var small = XZDecoder(maximumDictionarySize: 64 << 10)
        #expect(streamXZ(compressed, outputChunk: 4096, decoder: &small) == .success(data))
        // A dictionary that has to be kept past the limit.
        let large = largeSample()
        let far = xzCompress(Array((large + large).prefix(5 << 20)), options: lzmaOptions(preset: 0, dictionary: 8 << 20))
        #expect(streamXZ(far, outputChunk: 1 << 20, decoder: &small) == .failure(.insufficientCapacity))
    }

    /// Size hints, as zip records every entry's size: a new decoder's window is no larger than the hint, so a stream
    /// decodes with its own size as the hint (input split and whole), and one that outgrows a hint smaller than its
    /// dictionary fails instead of growing the window. (A window an earlier stream made larger stays.) Smaller rooms
    /// than the dictionary slide more often and decode the same.
    @Test func sizeHints() throws {
        let data = Array(largeSample().prefix(1 << 20))
        let xz = xzCompress(data, preset: 6) // An 8 MiB dictionary; xz states no sizes in its block headers.
        var decoder = XZDecoder()
        decoder.reset(sizeHint: data.count / 2)
        #expect(streamXZ(xz, outputChunk: 65_536, decoder: &decoder) == .failure(.insufficientCapacity))
        for split in [nil, [7, 19, 1000], [65_542]] as [[Int]?] {
            decoder.reset(sizeHint: data.count)
            #expect(streamXZ(xz, outputChunk: 65_536, split: split, decoder: &decoder) == .success(data), "split \(String(describing: split))")
        }
        decoder.reset(sizeHint: nil)
        #expect(streamXZ(xz, outputChunk: 65_536, decoder: &decoder) == .success(data))

        // Raw LZMA with its end marker and no size (zip's flag bit 1): the hint caps the window.
        let properties = try LZMAProperties(byte: 0x5D, dictionarySize: 8 << 20)
        let lzma = lzma1Compress(data, options: lzmaOptions(preset: 6), marker: true)
        var lzmaDecoder = LZMADecoder()
        func stream(hint: Int?, split: [Int]? = nil) throws -> Result<(output: [UInt8], consumed: Int), BytesError> {
            try lzmaDecoder.reset(properties: properties, sizeHint: hint)
            return streamDecode(lzma, outputChunk: 65_536, split: split) { (input, output) throws(BytesError) in
                try lzmaDecoder.decompress(input, into: &output)
            }
        }
        #expect(try stream(hint: data.count / 2).map(\.output) == .failure(.insufficientCapacity))
        // `reset()` keeps the hint.
        lzmaDecoder.reset()
        #expect(streamDecode(lzma, outputChunk: 65_536) { (input, output) throws(BytesError) in
            try lzmaDecoder.decompress(input, into: &output)
        }.map(\.output) == .failure(.insufficientCapacity))
        for split in [nil, [7, 19, 1000]] as [[Int]?] {
            #expect(try stream(hint: data.count, split: split).map(\.output) == .success(data), "split \(String(describing: split))")
        }

        // Rooms smaller than the dictionary (1 MiB here): more slides, the same output. (xz keeps a chunk's 2 MiB
        // whatever the limit.)
        let large = Array((largeSample() + largeSample().reversed()).prefix(3 << 20))
        let small = try LZMAProperties(byte: 0x5D, dictionarySize: 1 << 20)
        let raw = lzma1Compress(large, options: lzmaOptions(preset: 6, dictionary: 1 << 20), marker: true)
        let xzLarge = xzCompress(large, options: lzmaOptions(preset: 6, dictionary: 1 << 20))
        for room in [1 << 18, 1 << 19] {
            lzmaDecoder.windowRoomLimit = room
            try lzmaDecoder.reset(properties: small)
            #expect(streamDecode(raw, outputChunk: 1 << 20, split: [100_000]) { (input, output) throws(BytesError) in
                try lzmaDecoder.decompress(input, into: &output)
            }.map(\.output) == .success(large), "room \(room)")
            decoder.windowRoomLimit = room
            #expect(streamXZ(xzLarge, outputChunk: 1 << 20, split: [100_000], decoder: &decoder) == .success(large), "room \(room)")
        }
    }

    @Test func xzEdgeCases() {
        var decoder = XZDecoder()
        // An empty file, and empty content.
        #expect(streamXZ([], outputChunk: 1, decoder: &decoder) == .failure(.insufficientData))
        let empty = xzCompress([], preset: 6)
        #expect(streamXZ(empty, outputChunk: 1, decoder: &decoder) == .success([]))
        for split in inputSplits {
            #expect(streamXZ(empty, outputChunk: 7, split: split, decoder: &decoder) == .success([]))
        }
        // Reuse after an error, and after a reset mid-file.
        let data = Array(lzmaSamples().first { $0.name == "records" }!.bytes.prefix(30_000))
        let good = xzCompress(data, preset: 6)
        #expect(streamXZ([0x28, 0xB5, 0x2F, 0xFD] + good.dropFirst(4), outputChunk: 4096, decoder: &decoder) == .failure(.invalidValue))
        var output = [UInt8](repeating: 0, count: 100)
        let progress = try? output.withOutputRawSpan { span throws(BytesError) in try decoder.decompress(good.span.bytes, into: &span) }
        #expect(progress == nil) // The error stays until a reset.
        _ = try? output.withOutputRawSpan { span throws(BytesError) in
            decoder.reset()
            _ = try decoder.decompress(good.span.bytes, into: &span)
        }
        let finishedEarly = decoder.isFinished
        #expect(!finishedEarly)
        #expect(streamXZ(good, outputChunk: 4096, decoder: &decoder) == .success(data))
        let finished = decoder.isFinished
        #expect(finished)
        // The malformed files the whole-buffer decoder rejects.
        let cases: [(String, [UInt8], BytesError)] = [
            ("trailing garbage", good + [1, 2, 3, 4], .invalidValue),
            ("truncated footer", Array(good.dropLast()), .insufficientData),
            ("other filter", xzCompress(data, options: lzmaOptions(preset: 6), filtersBefore: [LZMAFilterID.delta]), .invalidValue),
        ]
        for (name, file, error) in cases {
            #expect(streamXZ(file, outputChunk: 4096, decoder: &decoder) == .failure(error), "\(name)")
        }
        var wrongCheck = good
        wrongCheck[good.count - 24 - 1] ^= 0x40 // The CRC-64's last byte.
        #expect(streamXZ(wrongCheck, outputChunk: 4096, decoder: &decoder) == .failure(.mismatch))
    }

    @Test func xzTransform() throws {
        let data = Array(lzmaSamples().first { $0.name == "text" }!.bytes.prefix(50_000))
        let compressed = xzCompress(data, preset: 6)
        var decoder = XZDecoder()
        var output: [UInt8] = []
        let progress = try decoder.transform(compressed.span.bytes, appending: &output, flush: .finish)
        #expect(progress.status == .finished && progress.consumed == compressed.count && output == data)
        decoder.reset()
        output = []
        #expect(throws: BytesError.insufficientData) {
            _ = try decoder.transform(compressed.span.bytes.extracting(..<(compressed.count - 1)), appending: &output, flush: .finish)
        }
    }

    // MARK: Raw LZMA

    /// Every lc/lp/pb mix, with and without an end marker, size known or not, through every output chunk size.
    @Test func lzmaMatchesWholeBuffer() throws {
        let data = Array(lzmaSamples().first { $0.name == "records" }!.bytes.prefix(80_000))
        var decoder = LZMADecoder()
        var whole = LZMA2Decoder()
        for (lc, lp, pb): (UInt32, UInt32, UInt32) in [(3, 0, 2), (0, 0, 0), (4, 0, 4), (1, 3, 1), (0, 4, 0), (2, 2, 3)] {
            let options = lzmaOptions(preset: 6, dictionary: 1 << 20, lc: lc, lp: lp, pb: pb)
            let properties = try LZMAProperties(literalContextBits: Int(lc), literalPositionBits: Int(lp), positionBits: Int(pb), dictionarySize: 1 << 20)
            for marker in [true, false] {
                let compressed = lzma1Compress(data, options: options, marker: marker)
                for size in marker ? [nil, data.count] : [data.count] {
                    let expected = lzmaDecode(compressed, properties: properties, size: size, capacity: data.count, decoder: &whole)
                    #expect(expected.output == data)
                    for chunk in outputChunks(for: data.count) {
                        let streamed = streamLZMA(compressed, properties: properties, size: size, outputChunk: chunk, decoder: &decoder)
                        #expect(streamed.output == data, "lc \(lc) lp \(lp) pb \(pb), marker \(marker), size \(String(describing: size)), chunks of \(chunk)")
                        #expect((try? streamed.get())?.consumed == compressed.count)
                    }
                }
            }
        }
    }

    /// Input split everywhere: symbols cut at every point, near the careful loop's margins.
    @Test func lzmaSplitInput() throws {
        let properties = try LZMAProperties(byte: 0x5D, dictionarySize: 1 << 16)
        var decoder = LZMADecoder()
        for (name, data) in lzmaSamples() where ["text", "random then text", "zeros", "odd"].contains(name) {
            let sample = Array(data.prefix(120_000))
            for marker in [true, false] {
                let compressed = lzma1Compress(sample, options: lzmaOptions(preset: 6, dictionary: 1 << 16), marker: marker)
                for split in inputSplits {
                    for chunk in [4096, 1 << 20] {
                        let streamed = streamLZMA(compressed + [0xAA], properties: properties, size: sample.count, outputChunk: chunk, split: split, decoder: &decoder)
                        #expect(streamed.output == sample, "\(name), marker \(marker), split \(split), chunks of \(chunk)")
                        #expect((try? streamed.get())?.consumed == compressed.count)
                    }
                }
            }
        }
    }

    /// Larger than the window's room with a small dictionary, so the window slides (its room is 256 KiB here); and
    /// a dictionary larger than the entry, which the window never allocates.
    @Test func lzmaDictionaries() throws {
        let data = Array(largeSample().prefix(1 << 20))
        var decoder = LZMADecoder()
        for dictionary in [4096, 100_000, 1 << 20] {
            let compressed = lzma1Compress(data, options: lzmaOptions(preset: 3, dictionary: UInt32(dictionary)), marker: true)
            let properties = try LZMAProperties(byte: 0x5D, dictionarySize: dictionary)
            for size in [nil, data.count] {
                #expect(streamLZMA(compressed, properties: properties, size: size, outputChunk: 65_536, split: [50_000], decoder: &decoder).output == data, "dictionary \(dictionary)")
            }
        }
        // A 1.5 GiB dictionary on 100 KB: decodes with a 64 KiB limit, size known or not. (Encoded with a small one:
        // liblzma's encoder would allocate gigabytes for it.)
        let text = Array(lzmaSamples().first { $0.name == "text" }!.bytes.prefix(100_000))
        let compressed = lzma1Compress(text, options: lzmaOptions(preset: 3, dictionary: 1 << 16), marker: true)
        let huge = try LZMAProperties(byte: 0x5D, dictionarySize: 1536 << 20)
        var limited = LZMADecoder(maximumDictionarySize: 64 << 10)
        for size in [nil, text.count] {
            #expect(streamLZMA(compressed, properties: huge, size: size, outputChunk: 4096, decoder: &limited).output == text)
        }
        // A dictionary that has to be kept past the limit: 1 MB with a 1 MiB dictionary, a 64 KiB limit.
        let far = lzma1Compress(data, options: lzmaOptions(preset: 3, dictionary: 1 << 20), marker: true)
        let properties = try LZMAProperties(byte: 0x5D, dictionarySize: 1 << 20)
        #expect(streamLZMA(far, properties: properties, size: nil, outputChunk: 65_536, decoder: &limited).output == nil)
    }

    @Test func lzmaEdgeCases() throws {
        var decoder = LZMADecoder()
        let properties = try LZMAProperties(byte: 0x5D, dictionarySize: 1 << 16)
        // No stream yet.
        var output = [UInt8](repeating: 0, count: 10)
        #expect(throws: BytesError.invalidValue) {
            try output.withOutputRawSpan { span throws(BytesError) in _ = try decoder.decompress([0, 0, 0, 0, 0].span.bytes, into: &span) }
        }
        #expect(throws: BytesError.invalidValue) { try decoder.reset(properties: properties, uncompressedSize: -1) }
        // Zero-length streams: with an end marker (size known or not), and without (size 0).
        let options = lzmaOptions(preset: 6, dictionary: 1 << 16)
        for marker in [true, false] {
            let compressed = lzma1Compress([], options: options, marker: marker)
            for size in marker ? [nil, 0] : [0] {
                for split in [nil] + inputSplits {
                    let streamed = streamLZMA(compressed, properties: properties, size: size, outputChunk: 1, split: split, decoder: &decoder)
                    #expect(streamed.output == [], "marker \(marker), size \(String(describing: size))")
                    #expect((try? streamed.get())?.consumed == compressed.count)
                }
            }
        }
        // Sizes that don't match: an end marker too early, a stream that goes on.
        let data = Array(lzmaSamples().first { $0.name == "text" }!.bytes.prefix(10_000))
        let marked = lzma1Compress(data, options: options, marker: true)
        #expect(streamLZMA(marked, properties: properties, size: data.count + 1, outputChunk: 4096, decoder: &decoder).output == nil)
        let unmarked = lzma1Compress(data, options: options, marker: false)
        #expect(streamLZMA(unmarked, properties: properties, size: nil, outputChunk: 4096, decoder: &decoder).map(\.output) == .failure(.insufficientData))
        #expect(streamLZMA(unmarked, properties: properties, size: data.count - 1, outputChunk: 4096, decoder: &decoder).output == nil)
        // Reuse: lc 4 grows the model (liblzma encodes no more than lc + lp = 4); then back, after `reset()`.
        let wide = try LZMAProperties(literalContextBits: 4, literalPositionBits: 0, positionBits: 0, dictionarySize: 1 << 16)
        let wideStream = lzma1Compress(data, options: lzmaOptions(preset: 6, dictionary: 1 << 16, lc: 4, lp: 0, pb: 0), marker: true)
        #expect(streamLZMA(wideStream, properties: wide, size: nil, outputChunk: 4096, decoder: &decoder).output == data)
        #expect(streamLZMA(marked, properties: properties, size: nil, outputChunk: 4096, decoder: &decoder).output == data)
        decoder.reset()
        let finishedEarly = decoder.isFinished
        #expect(!finishedEarly)
        var all: [UInt8] = []
        let progress = try decoder.transform(marked.span.bytes, appending: &all, flush: .finish)
        let finished = decoder.isFinished
        #expect(progress.status == .finished && all == data && finished)
    }

    /// NativeZip's zip method-14 vectors (`Tools/test-data fetch nativezip-lzma`): the 4-byte zip header, the 5
    /// property bytes, and the stream; each against the whole-buffer decoder.
    @Test func zipPayloads() throws {
        let table = try String(contentsOf: TestData.file(set: "nativezip-lzma", name: "vectors.tsv"), encoding: .utf8)
        var decoder = LZMADecoder()
        var whole = LZMA2Decoder()
        var count = 0
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t").map(String.init)
            let name = fields[0]
            let size = Int(fields[2])!
            let payload = try [UInt8](Data(contentsOf: TestData.file(set: "nativezip-lzma", name: "\(name).lzma")))
            let dictionary = Int(UInt32(payload[5]) | UInt32(payload[6]) << 8 | UInt32(payload[7]) << 16 | UInt32(payload[8]) << 24)
            let properties = try LZMAProperties(byte: payload[4], dictionarySize: dictionary)
            let stream = Array(payload.dropFirst(9))
            let expected = lzmaDecode(stream, properties: properties, size: size, capacity: size, decoder: &whole).output
            #expect(expected?.count == size, "\(name)")
            for (chunk, split) in [(1 << 20, nil), (4096, [33]), (7, [1])] where size <= 200_000 || chunk >= 4096 {
                #expect(streamLZMA(stream, properties: properties, size: size, outputChunk: chunk, split: split, decoder: &decoder).output == expected, "\(name), chunks of \(chunk)")
            }
            count += 1
        }
        #expect(count >= 18)
    }

    // MARK: Malformed input

    /// Streams cut short throw (the driver's `.insufficientData`, or a corruption error), never hang; corrupt bytes
    /// throw or decode, never trap, and with a CRC-64 a decoded file is the original. Every position in the first 64
    /// bytes and the last 32 and every 7th between, here; every position in LZMAStreamingBulkTests.
    @Test func survivesCorruption() throws {
        try Self.checkSurvivesCorruption { index, count in index < 64 || index >= count - 32 || index % 7 == 0 }
    }

    static func checkSurvivesCorruption(at positions: (_ index: Int, _ count: Int) -> Bool) throws {
        let text = Array(samples().first { $0.name == "text" }!.bytes.prefix(3_000))
        let records = Array(lzmaSamples().first { $0.name == "records" }!.bytes.prefix(4_000))
        let file = xzCompress(text, preset: 6)
        var xz = XZDecoder()
        var lzma = LZMADecoder()
        for index in 0..<file.count where positions(index, file.count) {
            for mask: UInt8 in [0xFF, 0x01, 0x80] {
                var corrupt = file
                corrupt[index] ^= mask
                for split in [nil, [5]] {
                    if case let .success(output) = streamXZ(corrupt, outputChunk: 1000, split: split, decoder: &xz) {
                        #expect(output == text, "xz: byte \(index) ^ \(mask)")
                    }
                }
            }
        }
        for length in 0..<file.count where positions(length, file.count) {
            #expect(streamXZ(Array(file.prefix(length)), outputChunk: 1000, split: [3], decoder: &xz) == .failure(.insufficientData), "xz cut at \(length)")
        }
        let properties = try LZMAProperties(byte: 0x5D, dictionarySize: 1 << 16)
        for marker in [true, false] {
            let raw = lzma1Compress(records, options: lzmaOptions(preset: 6, dictionary: 1 << 16), marker: marker)
            for index in 0..<raw.count where positions(index, raw.count) {
                for mask: UInt8 in [0xFF, 0x01, 0x80] {
                    var corrupt = raw
                    corrupt[index] ^= mask
                    for size in [nil, records.count] {
                        _ = streamLZMA(corrupt, properties: properties, size: size, outputChunk: 1000, split: [11], decoder: &lzma)
                    }
                }
            }
            for length in 0..<raw.count where positions(length, raw.count) {
                let cut = Array(raw.prefix(length))
                for size in marker ? [nil, records.count] : [records.count] {
                    #expect(streamLZMA(cut, properties: properties, size: size, outputChunk: 1000, decoder: &lzma).output == nil, "LZMA cut at \(length)")
                }
            }
        }
    }

    /// Random bytes as LZMA and as xz chunks after valid headers, never trapping or hanging.
    @Test func survivesRandomInput() throws {
        try Self.checkSurvivesRandomInput(rounds: 20)
    }

    static func checkSurvivesRandomInput(rounds: Int) throws {
        var rng = SplitMix64(seed: 4242)
        var lzma = LZMADecoder()
        let properties = try [LZMAProperties(byte: 0x5D, dictionarySize: 1 << 16), LZMAProperties(literalContextBits: 8, literalPositionBits: 4, positionBits: 4, dictionarySize: 1 << 12)]
        for size in [0, 1, 5, 6, 20, 100, 1000, 20_000] {
            for round in 0..<rounds {
                let raw = [0] + (0..<size).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                _ = streamLZMA(raw, properties: properties[round & 1], size: nil, outputChunk: 4096, split: [13], decoder: &lzma)
                _ = streamLZMA(raw, properties: properties[round & 1], size: size * 3, outputChunk: 4096, decoder: &lzma)
            }
        }
    }
}

/// Every byte of the corruption files changed and every cut; 200 rounds of random input; and the large sample through
/// every split.
@Suite(.bulk) struct LZMAStreamingBulkTests {
    @Test func survivesCorruption() throws { try LZMAStreamingTests.checkSurvivesCorruption { _, _ in true } }

    @Test func survivesRandomInput() throws { try LZMAStreamingTests.checkSurvivesRandomInput(rounds: 200) }

    @Test func largeThroughEverySplit() throws {
        let large = largeSample()
        var xz = XZDecoder()
        var lzma = LZMADecoder()
        let properties = try LZMAProperties(byte: 0x5D, dictionarySize: 1 << 20)
        for preset: UInt32 in [0, 6, 9 | LZMAFilterID.extreme] {
            let file = xzCompress(large, preset: preset)
            let raw = lzma1Compress(large, options: lzmaOptions(preset: preset, dictionary: 1 << 20), marker: preset != 6)
            for split in [nil] + inputSplits {
                for chunk in [7, 65_536, 1 << 20] where split != [1] || chunk != 7 {
                    #expect(streamXZ(file, outputChunk: chunk, split: split, decoder: &xz) == .success(large), "xz \(preset), split \(String(describing: split)), chunks of \(chunk)")
                    #expect(streamLZMA(raw, properties: properties, size: large.count, outputChunk: chunk, split: split, decoder: &lzma).output == large, "LZMA \(preset), split \(String(describing: split)), chunks of \(chunk)")
                }
            }
        }
    }
}
