import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import CLZMA
import Compression
import Foundation
import Testing

// MARK: - The reference library

/// liblzma's filter IDs and flags (C macros Swift doesn't import).
enum LZMAFilterID {
    static let lzma1: lzma_vli = 0x4000_0000_0000_0001
    static let lzma1Extended: lzma_vli = 0x4000_0000_0000_0002
    static let lzma2: lzma_vli = 0x21
    static let x86: lzma_vli = 0x04
    static let delta: lzma_vli = 0x03
    static let end: lzma_vli = .max
    static let extreme: UInt32 = 0x8000_0000
}

/// liblzma's options for `preset` (a level 0–9, optionally with `LZMAFilterID.extreme`).
func lzmaOptions(preset: UInt32, dictionary: UInt32? = nil, lc: UInt32? = nil, lp: UInt32? = nil, pb: UInt32? = nil) -> lzma_options_lzma {
    var options = lzma_options_lzma()
    precondition(lzma_lzma_preset(&options, preset) == 0)
    if let dictionary { options.dict_size = dictionary }
    if let lc { options.lc = lc }
    if let lp { options.lp = lp }
    if let pb { options.pb = pb }
    return options
}

/// liblzma's `.xz` encoding of `data` with the LZMA2 `options` (after `filtersBefore`, such as BCJ), one block.
func xzCompress(_ data: [UInt8], options: lzma_options_lzma, check: lzma_check = LZMA_CHECK_CRC64, filtersBefore: [lzma_vli] = []) -> [UInt8] {
    var options = options
    var delta = lzma_options_delta()
    delta.type = LZMA_DELTA_TYPE_BYTE
    delta.dist = 4
    var output = [UInt8](repeating: 0, count: lzma_stream_buffer_bound(data.count))
    var size = 0
    let status = withUnsafeMutablePointer(to: &options) { lzma2 in
        withUnsafeMutablePointer(to: &delta) { delta in
            var filters = filtersBefore.map { lzma_filter(id: $0, options: $0 == LZMAFilterID.delta ? UnsafeMutableRawPointer(delta) : nil) }
            filters.append(lzma_filter(id: LZMAFilterID.lzma2, options: UnsafeMutableRawPointer(lzma2)))
            filters.append(lzma_filter(id: LZMAFilterID.end, options: nil))
            return data.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { out in
                    lzma_stream_buffer_encode(&filters, check, nil, input.baseAddress, input.count, out.baseAddress, &size, out.count)
                }
            }
        }
    }
    precondition(status == LZMA_OK, "lzma_stream_buffer_encode: \(status)")
    return Array(output[..<size])
}

/// liblzma's `.xz` encoding at `preset`.
func xzCompress(_ data: [UInt8], preset: UInt32, check: lzma_check = LZMA_CHECK_CRC64) -> [UInt8] {
    xzCompress(data, options: lzmaOptions(preset: preset), check: check)
}

/// liblzma's multithreaded encoder on one thread: blocks of `blockSize` bytes, each header stating its sizes.
func xzCompressBlocks(_ data: [UInt8], preset: UInt32, blockSize: UInt64, check: lzma_check = LZMA_CHECK_CRC32) -> [UInt8] {
    var stream = lzma_stream()
    var options = lzma_mt()
    options.threads = 1
    options.block_size = blockSize
    options.preset = preset
    options.check = check
    precondition(lzma_stream_encoder_mt(&stream, &options) == LZMA_OK)
    defer { lzma_end(&stream) }
    return run(&stream, data)
}

/// `.lzma` (LZMA-Alone) encoding: the 13-byte header, then LZMA1 with an end marker.
func lzmaAloneCompress(_ data: [UInt8], options: lzma_options_lzma) -> [UInt8] {
    var stream = lzma_stream()
    var options = options
    precondition(lzma_alone_encoder(&stream, &options) == LZMA_OK)
    defer { lzma_end(&stream) }
    return run(&stream, data)
}

/// Raw encoding with one LZMA filter: LZMA1 (end marker), LZMA1 without an end marker (`LZMAFilterID.lzma1Extended`),
/// or LZMA2.
func lzmaRawCompress(_ data: [UInt8], filter: lzma_vli, options: lzma_options_lzma) -> [UInt8] {
    var options = options
    var output = [UInt8](repeating: 0, count: data.count + data.count / 2 + 1024)
    var size = 0
    let status = withUnsafeMutablePointer(to: &options) { lzma in
        var filters = [lzma_filter(id: filter, options: UnsafeMutableRawPointer(lzma)), lzma_filter(id: LZMAFilterID.end, options: nil)]
        return data.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                lzma_raw_buffer_encode(&filters, nil, input.baseAddress, input.count, out.baseAddress, &size, out.count)
            }
        }
    }
    precondition(status == LZMA_OK, "lzma_raw_buffer_encode: \(status)")
    return Array(output[..<size])
}

/// Runs a liblzma encoder over all of `data`.
private func run(_ stream: inout lzma_stream, _ data: [UInt8]) -> [UInt8] {
    var result: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    data.withUnsafeBufferPointer { input in
        stream.next_in = input.baseAddress
        stream.avail_in = input.count
        while true {
            let status = chunk.withUnsafeMutableBufferPointer { out in
                stream.next_out = out.baseAddress
                stream.avail_out = out.count
                return lzma_code(&stream, LZMA_FINISH)
            }
            result += chunk[..<(chunk.count - stream.avail_out)]
            if status == LZMA_STREAM_END { break }
            precondition(status == LZMA_OK, "lzma_code: \(status)")
        }
    }
    return result
}

/// liblzma's decoding of a whole `.xz` file, or `nil` if it fails.
func xzReferenceDecompress(_ data: [UInt8], capacity: Int) -> [UInt8]? {
    var output = [UInt8](repeating: 0, count: max(capacity, 1))
    var memoryLimit: UInt64 = .max
    var inputPosition = 0
    var outputPosition = 0
    let status = data.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { out in
            lzma_stream_buffer_decode(&memoryLimit, 0x08 /* LZMA_CONCATENATED */, nil, input.baseAddress, &inputPosition, input.count, out.baseAddress, &outputPosition, out.count)
        }
    }
    return status == LZMA_OK && inputPosition == data.count ? Array(output[..<outputPosition]) : nil
}

/// Apple's Compression encoding of `data` with `COMPRESSION_LZMA` (an `.xz` file).
func appleLZMACompress(_ data: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: data.count + data.count / 2 + 4096)
    let size = data.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { out in
            compression_encode_buffer(out.baseAddress!, out.count, input.baseAddress ?? UnsafePointer(bitPattern: 1)!, input.count, nil, COMPRESSION_LZMA)
        }
    }
    precondition(size > 0)
    return Array(output[..<size])
}

// MARK: - Drivers

/// Decodes an `.xz` file into exactly `capacity` bytes.
func xzDecode(_ data: [UInt8], capacity: Int, decoder: inout LZMA2Decoder) -> Result<[UInt8], BytesError> {
    var output = [UInt8](repeating: 0, count: capacity)
    var produced = 0
    do {
        try output.withOutputRawSpan { span throws(BytesError) in
            let consumed = try decoder.decompressXZ(data.span.bytes, into: &span)
            precondition(consumed == data.count)
            produced = span.byteCount
        }
    } catch {
        return .failure(error)
    }
    return .success(Array(output[..<produced]))
}

func xzDecode(_ data: [UInt8], capacity: Int) -> Result<[UInt8], BytesError> {
    var decoder = LZMA2Decoder()
    return xzDecode(data, capacity: capacity, decoder: &decoder)
}

/// Decodes a raw LZMA2 stream into exactly `capacity` bytes; the result's consumed count too.
func lzma2Decode(_ data: [UInt8], dictionarySize: Int, capacity: Int, decoder: inout LZMA2Decoder) -> Result<(output: [UInt8], consumed: Int), BytesError> {
    var output = [UInt8](repeating: 0, count: capacity)
    var produced = 0
    var consumed = 0
    do {
        try output.withOutputRawSpan { span throws(BytesError) in
            consumed = try decoder.decompressLZMA2(data.span.bytes, dictionarySize: dictionarySize, into: &span)
            produced = span.byteCount
        }
    } catch {
        return .failure(error)
    }
    return .success((Array(output[..<produced]), consumed))
}

/// Decodes raw LZMA1 into exactly `capacity` bytes.
func lzmaDecode(
    _ data: [UInt8], properties: LZMAProperties, size: Int?, capacity: Int, decoder: inout LZMA2Decoder
) -> Result<(output: [UInt8], consumed: Int), BytesError> {
    var output = [UInt8](repeating: 0, count: capacity)
    var produced = 0
    var consumed = 0
    do {
        try output.withOutputRawSpan { span throws(BytesError) in
            consumed = try decoder.decompressLZMA(data.span.bytes, properties: properties, uncompressedSize: size, into: &span)
            produced = span.byteCount
        }
    } catch {
        return .failure(error)
    }
    return .success((Array(output[..<produced]), consumed))
}

extension Result where Success == (output: [UInt8], consumed: Int) {
    var output: [UInt8]? { (try? get())?.output }
}

// MARK: - Inputs

/// Inputs for LZMA: the shared samples, plus binary-like data (structs with small fields, short distances),
/// text and random bytes interleaved (uncompressed LZMA2 chunks between compressed ones), and long runs.
func lzmaSamples() -> [(name: String, bytes: [UInt8])] {
    var rng = SplitMix64(seed: 2026)
    // Records of a fixed layout: matches at distance 16, 32, 48, literals after matches.
    var records: [UInt8] = []
    for index in 0..<20_000 {
        records += [UInt8(index & 0xFF), UInt8(index >> 8 & 0xFF), 0, 0, 0x7F, 0, 0, 1]
        records += (0..<8).map { _ in rng.next() % 4 == 0 ? UInt8(truncatingIfNeeded: rng.next()) : 0 }
    }
    // Random runs then text: LZMA2 writes the random runs as uncompressed chunks.
    let text = samples().first { $0.name == "text" }!.bytes
    var mixed: [UInt8] = []
    while mixed.count < 700_000 {
        mixed += (0..<Int(rng.next() % 90_000 + 70_000)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let start = Int(rng.next() % UInt64(text.count - 100_000))
        mixed += text[start..<(start + Int(rng.next() % 90_000) + 10_000)]
    }
    let zeros = [UInt8](repeating: 0, count: 300_000)
    return samples() + [("records", records), ("random then text", mixed), ("zeros", zeros), ("odd", Array(text.prefix(12_345)))]
}

/// What LZMA2 control bytes a raw stream uses: the reset levels and chunk kinds.
func lzma2Controls(_ data: [UInt8]) -> Set<UInt8> {
    var controls = Set<UInt8>()
    var position = 0
    while position < data.count {
        let control = data[position]
        if control == 0 { break }
        if control >= 0x80 {
            controls.insert(control & 0xE0)
            let packed = (Int(data[position + 3]) << 8 | Int(data[position + 4])) + 1
            position += (control >= 0xC0 ? 6 : 5) + packed
        } else {
            controls.insert(control)
            position += 3 + (Int(data[position + 1]) << 8 | Int(data[position + 2])) + 1
        }
    }
    return controls
}

/// The `xz` command, if installed.
func xzCommand() -> URL? {
    ["/opt/homebrew/bin/xz", "/usr/local/bin/xz", "/usr/bin/xz"].lazy.map { URL(filePath: $0) }.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }
}

/// `xz ARGUMENTS` with `data` as its input, writing to its output.
func runXZ(_ command: URL, _ arguments: [String], _ data: [UInt8]) throws -> [UInt8] {
    let directory = try TemporaryDirectory(prefix: "lzma-tests")
    defer { directory.remove() }
    let input = directory.path("input")
    try Data(data).write(to: input)
    let process = Process()
    process.executableURL = command
    process.arguments = arguments + ["--stdout", "--keep", input.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "xz \(arguments) failed")
    return [UInt8](output)
}

// MARK: - Tests

@Suite("LZMA, LZMA2, and xz decoding")
struct LZMADecoderTests {
    // MARK: .xz

    @Test func roundTripsEveryPreset() {
        var decoder = LZMA2Decoder()
        for (name, data) in lzmaSamples() where name != "large" {
            for preset: UInt32 in [0, 1, 3, 6, 9, 6 | LZMAFilterID.extreme] {
                let compressed = xzCompress(data, preset: preset)
                #expect(xzDecode(compressed, capacity: data.count, decoder: &decoder) == .success(data), "\(name), preset \(preset)")
            }
        }
    }

    @Test func verifiesEveryCheck() {
        let data = Array(lzmaSamples().first { $0.name == "records" }!.bytes.prefix(50_000))
        for check in [LZMA_CHECK_NONE, LZMA_CHECK_CRC32, LZMA_CHECK_CRC64, LZMA_CHECK_SHA256] {
            let compressed = xzCompress(data, preset: 6, check: check)
            #expect(xzDecode(compressed, capacity: data.count) == .success(data), "check \(check)")
            // A wrong uncompressed byte: CRC-32 and CRC-64 catch it (SHA-256 isn't verified). Change the last
            // byte of the check itself, which decoding doesn't otherwise read.
            guard check != LZMA_CHECK_NONE else { continue }
            let checkSize = [LZMA_CHECK_CRC32: 4, LZMA_CHECK_CRC64: 8, LZMA_CHECK_SHA256: 32][check]!
            let indexAndFooter = compressed.count - 12 - 12 // The index is 12 bytes here: one record.
            var corrupt = compressed
            corrupt[indexAndFooter - checkSize] ^= 0x40
            let expected: Result<[UInt8], BytesError> = check == LZMA_CHECK_SHA256 ? .success(data) : .failure(.mismatch)
            #expect(xzDecode(corrupt, capacity: data.count) == expected, "corrupt check \(check)")
        }
    }

    @Test func roundTripsLargeInputs() {
        // Over 2 MB: several LZMA2 chunks, matches across chunks; and an output with exactly that room.
        let large = samples().first { $0.name == "large" }!.bytes
        for preset: UInt32 in [1, 6, 9 | LZMAFilterID.extreme] {
            let compressed = xzCompress(large, preset: preset)
            #expect(xzDecode(compressed, capacity: large.count) == .success(large), "preset \(preset)")
        }
    }

    @Test func roundTripsAppleCompression() {
        let text = samples().first { $0.name == "text" }!.bytes
        let large = samples().first { $0.name == "large" }!.bytes
        for size in [0, 1, 2, 15, 16, 17, 1_000, 65_537, 199_999] {
            let data = Array(text.prefix(size))
            #expect(xzDecode(appleLZMACompress(data), capacity: data.count) == .success(data), "\(size) bytes")
        }
        #expect(xzDecode(appleLZMACompress(large), capacity: large.count) == .success(large), "large")
    }

    @Test func decodesEveryLiteralAndPositionSetting() {
        let data = Array(lzmaSamples().first { $0.name == "records" }!.bytes.prefix(200_000))
        var decoder = LZMA2Decoder()
        for (lc, lp, pb): (UInt32, UInt32, UInt32) in [(0, 0, 0), (3, 0, 2), (4, 0, 4), (0, 4, 0), (1, 3, 1), (2, 2, 3), (3, 1, 2), (0, 2, 2)] {
            for dictionary: UInt32 in [4096, 1 << 16, 3 << 20] {
                let compressed = xzCompress(data, options: lzmaOptions(preset: 6, dictionary: dictionary, lc: lc, lp: lp, pb: pb))
                #expect(xzDecode(compressed, capacity: data.count, decoder: &decoder) == .success(data), "lc \(lc) lp \(lp) pb \(pb), dictionary \(dictionary)")
            }
        }
    }

    @Test func decodesMultipleBlocksAndStreams() {
        let parts = lzmaSamples().filter { $0.name != "large" }.map(\.bytes)
        var stream: [UInt8] = []
        var expected: [UInt8] = []
        for (index, part) in parts.enumerated() {
            // Blocks with sizes in their headers, of several sizes.
            stream += xzCompressBlocks(part, preset: UInt32(index % 7), blockSize: UInt64(10_000 + 37_000 * index))
            stream += [UInt8](repeating: 0, count: 4 * (index % 3)) // Stream padding.
            expected += part
        }
        #expect(xzDecode(stream, capacity: expected.count) == .success(expected))
        #expect(xzReferenceDecompress(stream, capacity: expected.count) == expected)
    }

    @Test func decodesFilesFromTheCommand() throws {
        guard let xz = xzCommand() else { return }
        let samples = lzmaSamples().filter { ["text", "records", "random then text", "odd", "one byte", "empty"].contains($0.name) }
        let settings: [[String]] = [
            ["-0"], ["-9", "--extreme"], ["--check=none"], ["--check=crc32"], ["--check=sha256"],
            ["--lzma2=dict=64KiB,lc=0,lp=2,pb=0"], ["--lzma2=preset=6,lc=4,pb=4"], ["--block-size=20000"],
            ["--block-size=100000", "-T2"],
        ]
        for (name, data) in samples {
            for setting in settings {
                let compressed = try runXZ(xz, ["--compress", "--format=xz"] + setting, data)
                #expect(xzDecode(compressed, capacity: data.count) == .success(data), "\(name): xz \(setting)")
            }
        }
        // `.lzma` files.
        let text = samples.first { $0.name == "text" }!.bytes
        var decoder = LZMA2Decoder()
        for setting in [["-6"], ["--lzma1=preset=6,lc=0,lp=4,pb=0"]] {
            let compressed = try runXZ(xz, ["--compress", "--format=lzma"] + setting, text)
            var output = [UInt8](repeating: 0, count: text.count)
            let consumed = try output.withOutputRawSpan { span throws(BytesError) in try decoder.decompressLZMAFile(compressed.span.bytes, into: &span) }
            #expect(consumed == compressed.count && output == text, "xz --format=lzma \(setting)")
        }
    }

    @Test func rejectsOtherFilters() {
        let data = Array(lzmaSamples().first { $0.name == "records" }!.bytes.prefix(10_000))
        for filter in [LZMAFilterID.x86, LZMAFilterID.delta] {
            let compressed = xzCompress(data, options: lzmaOptions(preset: 6), filtersBefore: [filter])
            #expect(xzReferenceDecompress(compressed, capacity: data.count) == data)
            #expect(xzDecode(compressed, capacity: data.count) == .failure(.invalidValue), "filter \(filter)")
        }
    }

    @Test func rejectsMalformedFiles() {
        let data = Array("Malformed xz files. ".utf8)
        let good = xzCompress(data, preset: 6)
        var cases: [(String, [UInt8], BytesError)] = [
            ("empty", [], .insufficientData),
            ("not xz", [0x28, 0xB5, 0x2F, 0xFD] + good.dropFirst(4), .invalidValue),
            ("trailing garbage", good + [1, 2, 3, 4], .invalidValue),
            ("padding not a multiple of 4", good + [0, 0], .invalidValue),
            ("truncated footer", Array(good.dropLast()), .insufficientData),
        ]
        var wrongFlags = good
        wrongFlags[7] = 0x01 // CRC-32 instead of CRC-64: the header's CRC no longer matches.
        cases.append(("header CRC", wrongFlags, .mismatch))
        var reserved = good
        reserved[6] = 0x80
        cases.append(("reserved flags", reserved, .invalidValue))
        for (name, file, error) in cases {
            #expect(xzDecode(file, capacity: 1000) == .failure(error), "\(name)")
        }
        // Too small an output.
        #expect(xzDecode(good, capacity: data.count - 1) == .failure(.insufficientCapacity))
    }

    // MARK: Raw LZMA2 and LZMA

    @Test func decodesRawLZMA2() {
        var decoder = LZMA2Decoder()
        var controls = Set<UInt8>()
        for (name, data) in lzmaSamples() {
            let options = lzmaOptions(preset: 6, dictionary: 1 << 20)
            let compressed = lzmaRawCompress(data, filter: LZMAFilterID.lzma2, options: options)
            controls.formUnion(lzma2Controls(compressed))
            // With bytes after the end marker, which are left alone.
            let decoded = lzma2Decode(compressed + [0xAA, 0xBB], dictionarySize: 1 << 20, capacity: data.count, decoder: &decoder)
            #expect(decoded.output == data, "\(name)")
            #expect((try? decoded.get())?.consumed == compressed.count, "\(name)")
        }
        // Compressed chunks with every reset level but properties without a dictionary reset, and uncompressed
        // chunks with and without a dictionary reset.
        #expect(controls.isSuperset(of: [0x01, 0x02, 0x80, 0xA0, 0xC0, 0xE0]), "controls \(controls.map { String($0, radix: 16) })")

        // A dictionary reset in the middle: two streams' chunks, end to end.
        let first = Array(samples().first { $0.name == "text" }!.bytes.prefix(70_000))
        let second = Array(first.reversed())
        let options = lzmaOptions(preset: 3)
        let joined = lzmaRawCompress(first, filter: LZMAFilterID.lzma2, options: options).dropLast()
            + lzmaRawCompress(second, filter: LZMAFilterID.lzma2, options: options)
        #expect(lzma2Decode(Array(joined), dictionarySize: 1 << 23, capacity: 140_000, decoder: &decoder).output == first + second)

        // A dictionary smaller than the stream's distances.
        let large = Array(samples().first { $0.name == "large" }!.bytes.prefix(1 << 20))
        let far = lzmaRawCompress(large, filter: LZMAFilterID.lzma2, options: lzmaOptions(preset: 6, dictionary: 1 << 20))
        #expect(lzma2Decode(far, dictionarySize: 1 << 12, capacity: large.count, decoder: &decoder).output == nil)
    }

    @Test func decodesRawLZMA() throws {
        var decoder = LZMA2Decoder()
        let data = Array(lzmaSamples().first { $0.name == "records" }!.bytes.prefix(150_000))
        for (lc, lp, pb): (UInt32, UInt32, UInt32) in [(3, 0, 2), (0, 0, 0), (4, 0, 4), (1, 3, 1), (0, 4, 0)] {
            let options = lzmaOptions(preset: 6, dictionary: 1 << 20, lc: lc, lp: lp, pb: pb)
            let properties = try LZMAProperties(literalContextBits: Int(lc), literalPositionBits: Int(lp), positionBits: Int(pb), dictionarySize: 1 << 20)
            // With an end marker (raw LZMA1 always has one): size unknown, or known.
            let marked = lzmaRawCompress(data, filter: LZMAFilterID.lzma1, options: options)
            #expect(lzmaDecode(marked, properties: properties, size: nil, capacity: data.count, decoder: &decoder).output == data, "lc \(lc) lp \(lp) pb \(pb)")
            #expect(lzmaDecode(marked, properties: properties, size: data.count, capacity: data.count, decoder: &decoder).output == data)
            #expect((try? lzmaDecode(marked + [9, 9], properties: properties, size: nil, capacity: data.count + 10, decoder: &decoder).get())?.consumed == marked.count)
            // Without one: size known.
            var extended = options
            extended.ext_flags = 0
            let unmarked = lzmaRawCompress(data, filter: LZMAFilterID.lzma1Extended, options: extended)
            #expect(unmarked.count < marked.count)
            #expect(lzmaDecode(unmarked, properties: properties, size: data.count, capacity: data.count, decoder: &decoder).output == data)
            // Sizes that don't match: an end marker too early, a stream that goes on.
            #expect(lzmaDecode(marked, properties: properties, size: data.count + 1, capacity: data.count + 1, decoder: &decoder) .output == nil)
            #expect(lzmaDecode(marked, properties: properties, size: nil, capacity: data.count - 1, decoder: &decoder).output == nil)
        }
        // `.lzma` files, through liblzma's encoder.
        let alone = lzmaAloneCompress(data, options: lzmaOptions(preset: 6))
        var output = [UInt8](repeating: 0, count: data.count)
        let consumed = try output.withOutputRawSpan { span throws(BytesError) in try decoder.decompressLZMAFile(alone.span.bytes, into: &span) }
        #expect(consumed == alone.count && output == data)
        #expect(try LZMAProperties(byte: 0x5D, dictionarySize: 0).byte == 0x5D)
        #expect(throws: BytesError.invalidValue) { _ = try LZMAProperties(byte: 225, dictionarySize: 0) }
    }

    // MARK: Malformed input

    /// Bytes of small files changed, and truncations: decoding throws or succeeds, never traps or reads outside the
    /// input; with a CRC-64, success means the original content. Every position in the first 64 bytes (headers,
    /// properties, the first chunk) and the last 32 (index, footer, check), and every 9th between; every position in
    /// LZMABulkTests.
    @Test func survivesCorruption() throws {
        try Self.checkSurvivesCorruption { index, count in index < 64 || index >= count - 32 || index % 9 == 0 }
    }

    static func checkSurvivesCorruption(at positions: (_ index: Int, _ count: Int) -> Bool) throws {
        let text = Array(samples().first { $0.name == "text" }!.bytes.prefix(3_000))
        let records = Array(lzmaSamples().first { $0.name == "records" }!.bytes.prefix(4_000))
        let files: [(name: String, content: [UInt8], file: [UInt8], checked: Bool)] = [
            ("text 6", text, xzCompress(text, preset: 6), true),
            ("text 0 no check", text, xzCompress(text, preset: 0, check: LZMA_CHECK_NONE), false),
            ("records 9e", records, xzCompress(records, preset: 9 | LZMAFilterID.extreme), true),
            ("records lc0 lp2", records, xzCompress(records, options: lzmaOptions(preset: 6, lc: 0, lp: 2, pb: 0)), true),
        ]
        var decoder = LZMA2Decoder()
        for (name, content, file, checked) in files {
            for index in 0..<file.count where positions(index, file.count) {
                for mask: UInt8 in [0xFF, 0x01, 0x80, 0x10] {
                    var corrupt = file
                    corrupt[index] ^= mask
                    let result = xzDecode(corrupt, capacity: content.count + 100, decoder: &decoder)
                    if checked, case let .success(output) = result {
                        #expect(output == content, "\(name): byte \(index) ^ \(mask)")
                    }
                }
            }
            for length in 0..<file.count where positions(length, file.count) {
                #expect(xzDecode(Array(file.prefix(length)), capacity: content.count, decoder: &decoder) == .failure(.insufficientData), "\(name) cut at \(length)")
            }
        }
        // Raw streams cut anywhere.
        let raw2 = lzmaRawCompress(records, filter: LZMAFilterID.lzma2, options: lzmaOptions(preset: 6))
        for length in 0..<raw2.count where positions(length, raw2.count) {
            #expect(lzma2Decode(Array(raw2.prefix(length)), dictionarySize: 1 << 23, capacity: records.count, decoder: &decoder).output == nil, "LZMA2 cut at \(length)")
        }
        let raw1 = lzmaRawCompress(records, filter: LZMAFilterID.lzma1, options: lzmaOptions(preset: 6))
        let properties = try LZMAProperties(byte: 0x5D, dictionarySize: 1 << 23)
        for length in 0..<raw1.count where positions(length, raw1.count) {
            let decoded = lzmaDecode(Array(raw1.prefix(length)), properties: properties, size: nil, capacity: records.count + 10, decoder: &decoder)
            #expect(decoded.output == nil, "LZMA cut at \(length)")
        }
    }

    /// 40 rounds per size here, 200 in LZMABulkTests.
    @Test func survivesRandomInput() throws {
        try Self.checkSurvivesRandomInput(rounds: 40)
    }

    static func checkSurvivesRandomInput(rounds: Int) throws {
        var rng = SplitMix64(seed: 1729)
        var decoder = LZMA2Decoder()
        // lc 8, lp 4 (more literal contexts than LZMA2 allows: the model grows) for every other round.
        let properties = try [LZMAProperties(byte: 0x5D, dictionarySize: 1 << 16), LZMAProperties(literalContextBits: 8, literalPositionBits: 4, positionBits: 4, dictionarySize: 1 << 16)]
        for size in [0, 1, 5, 6, 10, 20, 100, 1000, 20_000] {
            for round in 0..<rounds {
                // A valid LZMA2 chunk header, then garbage; and garbage as LZMA1 after a valid first byte.
                var chunk: [UInt8] = [0xE0 | UInt8(round & 0x1F), UInt8(truncatingIfNeeded: rng.next()), UInt8(truncatingIfNeeded: rng.next()), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF), 0x5D, 0]
                chunk += (0..<size).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                _ = lzma2Decode(chunk, dictionarySize: 1 << 16, capacity: 1 << 18, decoder: &decoder)
                let raw = [0] + (0..<size).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                _ = lzmaDecode(raw, properties: properties[round & 1], size: nil, capacity: 1 << 16, decoder: &decoder)
                _ = lzmaDecode(raw, properties: properties[round & 1], size: size * 3, capacity: size * 3, decoder: &decoder)
            }
        }
    }

    // MARK: Checksums

    @Test func computesCRC64LikeLiblzma() {
        #expect(CRC64.checksum(Array("123456789".utf8).span.bytes) == 0x995D_C9BB_DF19_39FA)
        var rng = SplitMix64(seed: 64)
        let bytes = (0..<600).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        for length in 0...600 {
            let data = Array(bytes.prefix(length))
            let expected = data.withUnsafeBufferPointer { lzma_crc64($0.baseAddress, $0.count, 0) }
            #expect(CRC64.checksum(data.span.bytes) == expected, "length \(length)")
            var crc = CRC64()
            var offset = 0
            var step = 1
            while offset < length {
                let end = min(offset + step, length)
                crc.update(data.span.bytes.extracting(offset..<end))
                offset = end
                step = step * 3 % 41 + 1
            }
            #expect(crc.value == expected, "length \(length) in pieces")
        }
        // Long inputs: many folding steps, then every remainder of 64-byte steps, 16-byte steps, and bytes.
        let long = (0..<(1 << 20) + 200).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        for length in [4096, 65_536 + 79, 1 << 20, (1 << 20) + 127, (1 << 20) + 200] {
            let data = Array(long.prefix(length))
            let expected = data.withUnsafeBufferPointer { lzma_crc64($0.baseAddress, $0.count, 0) }
            #expect(CRC64.checksum(data.span.bytes) == expected, "length \(length)")
            #expect(CRC64.checksum(data.span.bytes.extracting(1000...), continuing: CRC64.checksum(data.span.bytes.extracting(..<1000))) == expected)
        }
    }
}

/// Every byte of the corruption files changed and every cut, and 200 rounds of random input per size.
@Suite(.bulk) struct LZMABulkTests {
    @Test func survivesCorruption() throws { try LZMADecoderTests.checkSurvivesCorruption { _, _ in true } }

    @Test func survivesRandomInput() throws { try LZMADecoderTests.checkSurvivesRandomInput(rounds: 200) }
}
