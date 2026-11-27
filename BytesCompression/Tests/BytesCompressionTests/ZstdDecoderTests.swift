import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import CZstd
import Testing

// MARK: - The reference library

/// libzstd's experimental parameters this file uses (C macros Swift doesn't import).
let zstdMaxBlockSize = ZSTD_c_experimentalParam18
let zstdLiteralCompressionMode = ZSTD_c_experimentalParam5

/// libzstd's compression of `data` with `parameters` (on top of the compression level).
func zstdCompress(_ data: [UInt8], level: Int32 = 3, parameters: [(ZSTD_cParameter, Int32)] = []) -> [UInt8] {
    let context = ZSTD_createCCtx()!
    defer { ZSTD_freeCCtx(context) }
    precondition(ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, level)) == 0)
    for (parameter, value) in parameters {
        precondition(ZSTD_isError(ZSTD_CCtx_setParameter(context, parameter, value)) == 0, "parameter \(parameter)")
    }
    var output = [UInt8](repeating: 0, count: ZSTD_compressBound(data.count) + 64)
    let size = data.withUnsafeBytes { input in
        output.withUnsafeMutableBytes { output in
            ZSTD_compress2(context, output.baseAddress, output.count, input.baseAddress, input.count)
        }
    }
    precondition(ZSTD_isError(size) == 0, String(cString: ZSTD_getErrorName(size)))
    return Array(output[..<size])
}

/// libzstd's streaming compression of `data`, without a pledged size: frames that don't state their content
/// size. Flushed every `flushEvery` bytes, which ends a block there.
func zstdCompressStreaming(
    _ data: [UInt8], level: Int32 = 3, flushEvery: Int = .max, parameters: [(ZSTD_cParameter, Int32)] = []
) -> [UInt8] {
    let context = ZSTD_createCCtx()!
    defer { ZSTD_freeCCtx(context) }
    precondition(ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, level)) == 0)
    for (parameter, value) in parameters {
        precondition(ZSTD_isError(ZSTD_CCtx_setParameter(context, parameter, value)) == 0)
    }
    var result: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: ZSTD_CStreamOutSize())
    var offset = 0
    repeat {
        let end = min(offset + flushEvery, data.count)
        let isLast = end == data.count
        data.withUnsafeBytes { all in
            var input = ZSTD_inBuffer(src: all.baseAddress.map { $0 + offset }, size: end - offset, pos: 0)
            while true {
                let (remaining, produced) = chunk.withUnsafeMutableBytes { buffer in
                    var output = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                    let remaining = ZSTD_compressStream2(context, &output, &input, isLast ? ZSTD_e_end : ZSTD_e_flush)
                    precondition(ZSTD_isError(remaining) == 0)
                    return (remaining, output.pos)
                }
                result += chunk[..<produced]
                if remaining == 0 && input.pos == input.size { break }
            }
        }
        offset = end
    } while offset < data.count
    return result
}

/// libzstd's decoding of `data`, which must be whole frames.
func zstdReferenceDecompress(_ data: [UInt8], capacity: Int) -> Outcome {
    var output = [UInt8](repeating: 0, count: max(capacity, 1))
    let size = data.withUnsafeBytes { input in
        output.withUnsafeMutableBytes { output in
            ZSTD_decompress(output.baseAddress, output.count, input.baseAddress, input.count)
        }
    }
    guard ZSTD_isError(size) == 0 else { return .failed }
    return .decoded(Array(output[..<size]))
}

// MARK: - Drivers

/// Decodes with `decompressAll` into exactly `capacity` bytes.
func zstdDecodeAll(_ data: [UInt8], capacity: Int, decoder: inout ZstdDecoder) -> Result<[UInt8], BytesError> {
    var output = [UInt8](repeating: 0, count: capacity)
    var produced = 0
    do {
        try output.withOutputRawSpan { span throws(BytesError) in
            let consumed = try decoder.decompressAll(data.span.bytes, into: &span)
            precondition(consumed == data.count)
            produced = span.byteCount
        }
    } catch {
        return .failure(error)
    }
    return .success(Array(output[..<produced]))
}

/// Decodes `data` in `chunk`-byte pieces of input into `outputChunk`-byte pieces of output, passing the
/// unconsumed input again, as a network client does; the last piece with `.finish`.
func zstdDecodeStreaming(
    _ data: [UInt8], chunk: Int, outputChunk: Int, decoder: inout ZstdDecoder, sizeHint: Int? = nil
) -> Result<[UInt8], BytesError> {
    decoder.reset(sizeHint: sizeHint)
    var result: [UInt8] = []
    var pending: [UInt8] = []
    var offset = 0
    var buffer = [UInt8](repeating: 0, count: outputChunk)
    do {
        while true {
            let end = min(offset + chunk, data.count)
            pending += data[offset..<end]
            offset = end
            let isLast = offset == data.count
            var progress: TransformProgress
            repeat {
                progress = try buffer.withOutputRawSpan { span throws(BytesError) in
                    try decoder.transform(pending.span.bytes, into: &span, flush: isLast ? .finish : .none)
                }
                result += buffer[..<progress.produced]
                pending.removeFirst(progress.consumed)
            } while progress.status == .needsOutput
            if progress.status == .finished {
                #expect(pending.isEmpty)
                return .success(result)
            }
            #expect(!isLast, "Needs input after the last piece without throwing")
            if isLast { return .failure(.insufficientData) }
        }
    } catch {
        return .failure(error)
    }
}

/// Both ways of decoding, checked against each other: the one-shot result, which the streaming one must match.
func zstdDecodeBothWays(_ data: [UInt8], capacity: Int, chunk: Int = 1 << 16, outputChunk: Int = 1 << 16) -> Result<[UInt8], BytesError> {
    var decoder = ZstdDecoder()
    let all = zstdDecodeAll(data, capacity: capacity, decoder: &decoder)
    let streamed = zstdDecodeStreaming(data, chunk: chunk, outputChunk: outputChunk, decoder: &decoder)
    switch (all, streamed) {
    case let (.success(a), .success(b)): #expect(a == b, "One-shot and streaming outputs differ")
    case (.failure, .failure): break
    default: Issue.record("One-shot \(all.map(\.count)) and streaming \(streamed.map(\.count)) disagree")
    }
    return all
}

// MARK: - Inputs

/// Inputs for Zstandard: the shared samples, plus ones that make RLE blocks, incompressible blocks, and
/// matches at the edges of small windows.
func zstdSamples() -> [(name: String, bytes: [UInt8])] {
    var rng = SplitMix64(seed: 93)
    var mixed: [UInt8] = []
    while mixed.count < 600_000 {
        switch rng.next() % 4 {
        case 0: mixed += [UInt8](repeating: UInt8(truncatingIfNeeded: rng.next()), count: Int(rng.next() % 200_000)) // RLE blocks
        case 1: mixed += (0..<Int(rng.next() % 5_000)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        case 2:
            let distance = Int(rng.next() % UInt64(max(1, mixed.count))) + 1
            let length = Int(rng.next() % 3_000) + 3
            for _ in 0..<length where mixed.count >= distance {
                mixed.append(mixed[mixed.count - distance])
            }
        default: mixed += Array("the quick brown fox jumps over the lazy dog ".utf8.shuffled(using: &rng).prefix(Int(rng.next() % 40)))
        }
    }
    // After random bytes, copies of them separated by single zeros: blocks whose literals are all zeros (RLE
    // literals).
    let seed = (0..<60_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
    var zeros = seed
    while zeros.count < 200_000 {
        let start = Int(rng.next() % 59_000)
        zeros.append(0)
        zeros += seed[start..<(start + 24 + Int(rng.next() % 200))]
    }
    return samples() + [
        ("mixed", mixed), ("RLE literals", zeros), ("small text", Array(mixed.prefix(5_000))), ("letters", skewedLetters(100_000)),
    ]
}

/// Random letters, some far more common than others: no matches, and literals that compress to about half,
/// which the decoder decodes with double-symbol Huffman tables.
func skewedLetters(_ count: Int) -> [UInt8] {
    var rng = SplitMix64(seed: UInt64(count))
    return (0..<count).map { _ in
        let roll = rng.next() % 64
        return roll < 32 ? UInt8(ascii: "e") + UInt8(roll % 4) : UInt8(ascii: "a") + UInt8(roll % 26)
    }
}

/// Many frames' worth of settings: levels, block sizes, windows, literal modes, checksums, content sizes.
func zstdSettings() -> [(name: String, level: Int32, parameters: [(ZSTD_cParameter, Int32)])] {
    [
        ("level -5", -5, []), ("level 1", 1, []), ("level 3", 3, [(ZSTD_c_checksumFlag, 1)]),
        ("level 6 no size", 6, [(ZSTD_c_contentSizeFlag, 0)]), ("level 9", 9, [(ZSTD_c_checksumFlag, 1)]),
        ("level 19", 19, [(ZSTD_c_checksumFlag, 1)]), ("level 22", 22, []),
        ("small blocks", 7, [(zstdMaxBlockSize, 1024), (ZSTD_c_checksumFlag, 1)]),
        ("target blocks", 12, [(ZSTD_c_targetCBlockSize, 1340)]),
        ("raw literals", 5, [(zstdLiteralCompressionMode, 2)]),
        ("window 10", 3, [(ZSTD_c_windowLog, 10), (ZSTD_c_checksumFlag, 1)]),
        ("window 17 btultra", 16, [(ZSTD_c_windowLog, 17)]),
        ("long 24", 19, [(ZSTD_c_windowLog, 24), (ZSTD_c_enableLongDistanceMatching, 1)]),
    ]
}

// MARK: - Frame survey

/// What a set of frames uses: block types, literal and sequence modes, header forms. Checks that tests cover
/// what they claim to.
struct ZstdSurvey {
    var blockTypes = Set<Int>()
    var literalTypes = Set<Int>()
    var fourStreams = false
    var oneStream = false
    var sequenceModes = [Set<Int>](repeating: [], count: 3) // Literal lengths, offsets, match lengths.
    var contentSizeFieldSizes = Set<Int>()
    var singleSegment = false
    var checksums = false
    var skippable = false

    mutating func add(_ data: [UInt8]) {
        var position = 0
        func byte(_ index: Int) -> Int { Int(data[index]) }
        while position + 4 <= data.count {
            let magic = UInt32(byte(position)) | UInt32(byte(position + 1)) << 8 | UInt32(byte(position + 2)) << 16 | UInt32(byte(position + 3)) << 24
            if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
                skippable = true
                position += 8 + (byte(position + 4) | byte(position + 5) << 8 | byte(position + 6) << 16 | byte(position + 7) << 24)
                continue
            }
            guard magic == 0xFD2F_B528 else { return }
            let descriptor = byte(position + 4)
            let single = descriptor & 0x20 != 0
            let fcsCode = descriptor >> 6
            let fcsSize = fcsCode == 0 ? (single ? 1 : 0) : 1 << fcsCode
            contentSizeFieldSizes.insert(fcsSize)
            singleSegment = singleSegment || single
            checksums = checksums || descriptor & 4 != 0
            position += 5 + (single ? 0 : 1) + [0, 1, 2, 4][descriptor & 3] + fcsSize
            while true {
                let header = byte(position) | byte(position + 1) << 8 | byte(position + 2) << 16
                position += 3
                let type = (header >> 1) & 3
                let size = header >> 3
                blockTypes.insert(type)
                if type == 2 { surveyBlock(Array(data[position..<(position + size)])) }
                position += type == 1 ? 1 : size
                if header & 1 != 0 { break }
            }
            if descriptor & 4 != 0 { position += 4 }
        }
    }

    private mutating func surveyBlock(_ block: [UInt8]) {
        let header = Int(block[0])
        let type = header & 3
        literalTypes.insert(type)
        let sizeFormat = (header >> 2) & 3
        var position: Int
        if type < 2 {
            let headerSize = sizeFormat == 1 ? 2 : sizeFormat == 3 ? 3 : 1
            let size = sizeFormat == 1 ? (header | Int(block[1]) << 8) >> 4
                : sizeFormat == 3 ? (header | Int(block[1]) << 8 | Int(block[2]) << 16) >> 4 : header >> 3
            position = headerSize + (type == 0 ? size : 1)
        } else {
            if sizeFormat == 0 { oneStream = true } else { fourStreams = true }
            let fields = (0..<5).reduce(0) { $0 | (($1 < block.count ? Int(block[$1]) : 0) << (8 * $1)) }
            let (headerSize, compressed) = switch sizeFormat {
            case 0, 1: (3, (fields >> 14) & 0x3FF)
            case 2: (4, (fields >> 18) & 0x3FFF)
            default: (5, (fields >> 22) & 0x3FFFF)
            }
            position = headerSize + compressed
        }
        guard position < block.count else { return }
        var sequences = Int(block[position])
        position += 1
        if sequences == 0 { return }
        if sequences == 255 { position += 2 } else if sequences >= 128 { position += 1 }
        let modes = Int(block[position])
        sequences = 0
        sequenceModes[0].insert(modes >> 6)
        sequenceModes[1].insert((modes >> 4) & 3)
        sequenceModes[2].insert((modes >> 2) & 3)
    }
}

// MARK: - Hand-built frames

enum ZstdFrames {
    /// A frame header with the given fields; `window` is the window descriptor byte (omitted when single segment).
    static func header(contentSize: UInt64?, fieldSize: Int, singleSegment: Bool, window: UInt8 = 0x58, checksum: Bool = false, dictionaryID: UInt32 = 0, dictionaryIDSize: Int = 0) -> [UInt8] {
        let fcsCode = switch fieldSize { case 0, 1: 0; case 2: 1; case 4: 2; default: 3 }
        let dictionaryCode = switch dictionaryIDSize { case 0: 0; case 1: 1; case 2: 2; default: 3 }
        var bytes: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        bytes.append(UInt8(fcsCode << 6 | (singleSegment ? 0x20 : 0) | (checksum ? 4 : 0) | dictionaryCode))
        if !singleSegment { bytes.append(window) }
        for index in 0..<dictionaryIDSize {
            bytes.append(UInt8(truncatingIfNeeded: dictionaryID >> (8 * index)))
        }
        if let contentSize, fieldSize > 0 {
            let stored = fieldSize == 2 ? contentSize - 256 : contentSize
            for index in 0..<fieldSize {
                bytes.append(UInt8(truncatingIfNeeded: stored >> (8 * UInt64(index))))
            }
        }
        return bytes
    }

    /// A block header.
    static func blockHeader(type: Int, size: Int, last: Bool) -> [UInt8] {
        let value = size << 3 | type << 1 | (last ? 1 : 0)
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value >> 16)]
    }

    /// The low 32 bits of the XXH64 of `content`, little-endian: a frame's checksum.
    static func checksum(_ content: [UInt8]) -> [UInt8] {
        let value = UInt32(truncatingIfNeeded: XXHash64.hash(content.span.bytes))
        return (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// A skippable frame holding `payload`.
    static func skippable(_ payload: [UInt8], nibble: UInt8 = 0) -> [UInt8] {
        let size = UInt32(payload.count)
        return [0x50 | nibble, 0x2A, 0x4D, 0x18] + (0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) } + payload
    }
}

@Suite("Zstandard decoding")
struct ZstdDecoderTests {
    /// `DecompressionFormat.zstd()`'s default window limit is written as a literal (a public case's default can't name
    /// the package decoder): it's the decoder's own.
    @Test func formatsDefaultWindowIsTheDecoders() {
        #expect(DecompressionFormat.zstd() == .zstd(maximumWindowSize: ZstdDecoder.defaultMaximumWindowSize))
    }

    // MARK: Round trips

    @Test func roundTripsEverySetting() {
        var survey = ZstdSurvey()
        for (name, data) in zstdSamples() where name != "large" {
            for setting in zstdSettings() {
                let compressed = zstdCompress(data, level: setting.level, parameters: setting.parameters)
                survey.add(compressed)
                let decoded = zstdDecodeBothWays(compressed, capacity: data.count, chunk: 4093, outputChunk: 777)
                #expect(decoded == .success(data), "\(name), \(setting.name)")
            }
        }
        // The settings reach every block type, literal mode, and sequence table mode.
        #expect(survey.blockTypes == [0, 1, 2])
        #expect(survey.literalTypes == [0, 1, 2, 3])
        #expect(survey.oneStream && survey.fourStreams)
        #expect(survey.sequenceModes[0] == [0, 1, 2, 3], "literal length modes \(survey.sequenceModes[0])")
        #expect(survey.sequenceModes[1] == [0, 1, 2, 3], "offset modes \(survey.sequenceModes[1])")
        #expect(survey.sequenceModes[2] == [0, 1, 2, 3], "match length modes \(survey.sequenceModes[2])")
        #expect(survey.singleSegment && survey.checksums)
        #expect(survey.contentSizeFieldSizes.isSuperset(of: [0, 1, 2, 4]))
    }

    @Test func roundTripsLargeInputs() {
        let large = samples().first { $0.name == "large" }!.bytes
        let settings: [(Int32, [(ZSTD_cParameter, Int32)])] = [(1, []), (19, [(ZSTD_c_checksumFlag, 1)])]
        for (level, parameters) in settings {
            let compressed = zstdCompress(large, level: level, parameters: parameters)
            #expect(zstdDecodeBothWays(compressed, capacity: large.count) == .success(large), "level \(level)")
        }
    }

    @Test func roundTripsStreamedFrames() {
        for (name, data) in zstdSamples() where name != "large" {
            // No content size, blocks ended at every flush.
            let compressed = zstdCompressStreaming(data, level: 4, flushEvery: 9_999, parameters: [(ZSTD_c_checksumFlag, 1)])
            #expect(zstdDecodeBothWays(compressed, capacity: data.count, chunk: 1 << 15, outputChunk: 1 << 12) == .success(data), "\(name)")
        }
    }

    /// Split at every size from 1 byte: every header, block, and checksum boundary.
    @Test func streamsInAnyPieces() {
        let data = zstdSamples().first { $0.name == "mixed" }!.bytes.prefix(40_000)
        let compressed = zstdCompress(Array(data), level: 9, parameters: [(ZSTD_c_checksumFlag, 1), (zstdMaxBlockSize, 3000)])
        var decoder = ZstdDecoder()
        for (chunk, outputChunk) in [(1, 1), (1, 1 << 16), (2, 3), (7, 64), (13, 1000), (100, 1), (1 << 20, 17)] {
            let decoded = zstdDecodeStreaming(compressed, chunk: chunk, outputChunk: outputChunk, decoder: &decoder)
            #expect(decoded == .success(Array(data)), "input \(chunk), output \(outputChunk)")
        }
    }

    /// Small windows wrap the streaming window many times: matches then reach into the older segment, and
    /// across its end into the newer one.
    @Test func wrapsTheStreamingWindow() {
        let data = zstdSamples().first { $0.name == "mixed" }!.bytes + samples().first { $0.name == "large" }!.bytes.prefix(1_500_000)
        for windowLog: Int32 in [10, 12, 17, 20] {
            let compressed = zstdCompress(data, level: 19, parameters: [(ZSTD_c_windowLog, windowLog), (ZSTD_c_checksumFlag, 1), (ZSTD_c_contentSizeFlag, 0)])
            var decoder = ZstdDecoder()
            for (chunk, outputChunk) in [(1 << 16, 1 << 16), (999, 333)] {
                let decoded = zstdDecodeStreaming(compressed, chunk: chunk, outputChunk: outputChunk, decoder: &decoder)
                #expect(decoded == .success(data), "window log \(windowLog), pieces \(chunk)")
            }
        }
    }

    /// `zstd --long=27`: a 128 MB window, matches tens of megabytes back.
    @Test func decodesLongWindows() {
        var rng = SplitMix64(seed: 27)
        let block = (0..<(1 << 20)).map { _ in UInt8(truncatingIfNeeded: rng.next() % 7 &* 37) }
        var data: [UInt8] = []
        for round in 0..<6 {
            data += block.map { $0 &+ UInt8(round & 1) }
        } // Repeats 1 and 2 MB back.
        // Streamed, so the encoder doesn't know the size and keeps the whole window in the header.
        let compressed = zstdCompressStreaming(data, level: 3, flushEvery: 1 << 20, parameters: [(ZSTD_c_windowLog, 27), (ZSTD_c_enableLongDistanceMatching, 1)])
        #expect((try? ZstdFrameHeader(parsing: compressed.span.bytes))??.windowSize == 1 << 27)
        #expect(compressed.count < data.count / 4)
        #expect(zstdDecodeBothWays(compressed, capacity: data.count, chunk: 1 << 20, outputChunk: 1 << 20) == .success(data))
        // A decoder limited to smaller windows rejects the frame when streaming, before allocating; one-shot
        // decoding needs no window, so it still works.
        var small = ZstdDecoder(maximumWindowSize: 1 << 26)
        #expect(zstdDecodeStreaming(compressed, chunk: 1 << 20, outputChunk: 1 << 20, decoder: &small) == .failure(.limitExceeded))
        #expect(zstdDecodeAll(compressed, capacity: data.count, decoder: &small) == .success(data))
    }

    /// A frame that states no content size, its window 128 MiB (a 6-byte header: window log 27), then one raw block of
    /// 1,000 bytes. Streamed with no hint, the decoder reserves the whole window (it zero-filled it, every page resident,
    /// before 2026-11-24); with the container's size as the hint (zip records it), the window is the hint. A stream that
    /// decodes past its hint, with a match reaching further back than the hint, decodes right or throws: never wrong bytes.
    @Test func sizeHintBoundsTheWindow() {
        let data = SampleBytes.random(1_000, seed: 4)
        let blockHeader = 1 | (data.count << 3) // Last block, raw, its size.
        let frame: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x88]
            + [UInt8(blockHeader & 0xFF), UInt8((blockHeader >> 8) & 0xFF), UInt8(blockHeader >> 16)] + data
        var decoder = ZstdDecoder()
        #expect(zstdDecodeStreaming(frame, chunk: 4_096, outputChunk: 4_096, decoder: &decoder, sizeHint: 1_000) == .success(data))
        #expect(decoder.windowCapacity < 1_000 + (128 << 10) + 1_024)
        var unhinted = ZstdDecoder()
        #expect(zstdDecodeStreaming(frame, chunk: 4_096, outputChunk: 4_096, decoder: &unhinted) == .success(data))
        #expect(unhinted.windowCapacity >= 128 << 20)

        // 20 KB, then the same 20 KB again (matches 20 KB back), decoded with a hint of 10 KB.
        let twice = SampleBytes.random(20_000, seed: 5)
        let repeated = zstdCompressStreaming(twice + twice, level: 3)
        switch zstdDecodeStreaming(repeated, chunk: 1_000, outputChunk: 1_000, decoder: &decoder, sizeHint: 10_000) {
        case let .success(decoded): #expect(decoded == twice + twice)
        case .failure: break
        }
    }

    @Test func convenienceDecodesToAnArray() throws {
        let data = Array(zstdSamples().first { $0.name == "text" }!.bytes)
        let compressed = zstdCompress(data, level: 3)
        #expect(try ZstdDecoder.decompress(compressed.span.bytes, maximumSize: 1 << 30) == data)
        let unsized = zstdCompressStreaming(data, level: 3)
        #expect(try ZstdDecoder.decompress(unsized.span.bytes, maximumSize: 1 << 30) == data)
        #expect(throws: BytesError.limitExceeded) { _ = try ZstdDecoder.decompress(compressed.span.bytes, maximumSize: 1000) }
        #expect(throws: BytesError.limitExceeded) { _ = try ZstdDecoder.decompress(unsized.span.bytes, maximumSize: 1000) }
    }

    /// A frame header's content size is believed only as far as its input could expand (a 4-byte RLE block per
    /// 128 KiB): a 14-byte frame claiming 2^62 bytes made an array of that size (a trap in `malloc`) before a block
    /// was read. Now it's refused before anything is allocated; an RLE frame at the limit still decodes.
    @Test func convenienceRefusesSizesTheInputCantHold() throws {
        // Magic, a descriptor with an 8-byte content size and no single segment, a window byte, then the size.
        let claimed: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0xC0, 0x00] + (0..<8).map { $0 == 7 ? 0x40 : 0 }
        #expect(throws: BytesError.invalidValue) { _ = try ZstdDecoder.decompress(claimed.span.bytes, maximumSize: 1 << 30) }
        let data = [UInt8](repeating: 7, count: 1 << 20)
        let rle = zstdCompress(data, level: 3)
        #expect(try ZstdDecoder.decompress(rle.span.bytes, maximumSize: 1 << 30) == data)
    }

    // MARK: Frames

    @Test func decodesConcatenatedAndSkippableFrames() {
        let parts = zstdSamples().filter { $0.name != "large" }.map(\.bytes)
        var stream: [UInt8] = ZstdFrames.skippable([1, 2, 3], nibble: 0xF)
        var expected: [UInt8] = []
        for (index, part) in parts.enumerated() {
            stream += zstdCompress(part, level: Int32(index % 5 + 1), parameters: [(ZSTD_c_checksumFlag, Int32(index) & 1)])
            stream += ZstdFrames.skippable(Array(repeating: UInt8(index), count: index * 10))
            expected += part
        }
        #expect(zstdDecodeBothWays(stream, capacity: expected.count, chunk: 5000, outputChunk: 3000) == .success(expected))
        #expect(zstdReferenceDecompress(stream, capacity: expected.count) == .decoded(expected))
        // Only skippable frames: nothing out.
        #expect(zstdDecodeBothWays(ZstdFrames.skippable([9, 9]), capacity: 0) == .success([]))
    }

    @Test func decodesEveryHeaderForm() {
        let content = Array("Zstandard frame header forms. ".utf8)
        let raw = ZstdFrames.blockHeader(type: 0, size: content.count, last: true) + content
        let rle = ZstdFrames.blockHeader(type: 1, size: 300, last: true) + [0x41]
        let cases: [(name: String, frame: [UInt8], expected: [UInt8])] = [
            ("1-byte size, single segment", ZstdFrames.header(contentSize: UInt64(content.count), fieldSize: 1, singleSegment: true) + raw, content),
            ("2-byte size", ZstdFrames.header(contentSize: 300, fieldSize: 2, singleSegment: false) + rle, [UInt8](repeating: 0x41, count: 300)),
            ("4-byte size", ZstdFrames.header(contentSize: UInt64(content.count), fieldSize: 4, singleSegment: false) + raw, content),
            ("8-byte size", ZstdFrames.header(contentSize: UInt64(content.count), fieldSize: 8, singleSegment: true) + raw, content),
            ("no size", ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false, window: 0x07) + raw, content),
            ("checksum", ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false, checksum: true) + raw + ZstdFrames.checksum(content), content),
            ("empty", ZstdFrames.header(contentSize: 0, fieldSize: 1, singleSegment: true) + ZstdFrames.blockHeader(type: 0, size: 0, last: true), []),
            ("several blocks", ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false) + ZstdFrames.blockHeader(type: 0, size: content.count, last: false) + content + rle, content + [UInt8](repeating: 0x41, count: 300)),
        ]
        for (name, frame, expected) in cases {
            #expect(zstdDecodeBothWays(frame, capacity: expected.count, chunk: 3, outputChunk: 7) == .success(expected), "\(name)")
            #expect(zstdReferenceDecompress(frame, capacity: expected.count) == .decoded(expected), "libzstd: \(name)")
            #expect((try? ZstdFrameHeader(parsing: frame.span.bytes))??.contentSize == (name == "no size" || name == "several blocks" || name == "checksum" ? nil : UInt64(expected.count)))
        }
        let header = try? ZstdFrameHeader(parsing: ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false, window: 0x5B, dictionaryID: 7, dictionaryIDSize: 2).span.bytes)
        #expect(header?.windowSize == (1 << 21) + 3 * (1 << 18))
        #expect(header?.dictionaryID == 7)
    }

    @Test func rejectsMalformedFrames() {
        let content: [UInt8] = [1, 2, 3, 4]
        let raw = ZstdFrames.blockHeader(type: 0, size: 4, last: true) + content
        let cases: [(String, [UInt8], BytesError)] = [
            ("not a frame", [0x28, 0xB5, 0x2F, 0xFE, 0, 0, 0, 0], .invalidValue),
            // Valid frames this decoder can't read: a later version's feature, a dictionary; a window past 2^31 is over
            // its limit.
            ("reserved bit", [0x28, 0xB5, 0x2F, 0xFD, 0x08, 0x58] + raw, .unsupported),
            ("dictionary", ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false, dictionaryID: 5, dictionaryIDSize: 1) + raw, .unsupported),
            ("reserved block type", ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false) + ZstdFrames.blockHeader(type: 3, size: 4, last: true) + content, .invalidValue),
            ("block over the window", ZstdFrames.header(contentSize: 4, fieldSize: 1, singleSegment: true) + ZstdFrames.blockHeader(type: 1, size: 5, last: true) + [0], .invalidValue),
            ("wrong content size", ZstdFrames.header(contentSize: 300, fieldSize: 2, singleSegment: false) + raw, .mismatch),
            ("wrong checksum", ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false, checksum: true) + raw + [0, 0, 0, 0], .checksumMismatch),
            ("window log 42", [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0xF8] + raw, .limitExceeded),
            ("trailing garbage", ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false) + raw + [0x28, 0xB5, 0x2F, 0x00, 0, 0], .invalidValue),
            ("truncated", ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false) + raw.dropLast(), .insufficientData),
            ("empty", [], .insufficientData),
        ]
        for (name, frame, error) in cases {
            #expect(zstdDecodeBothWays(frame, capacity: 1000, chunk: 2, outputChunk: 3) == .failure(error), "\(name)")
        }
        // Too small an output for one-shot decoding.
        let compressed = zstdCompress([UInt8](repeating: 7, count: 10_000), level: 3, parameters: [(ZSTD_c_contentSizeFlag, 0)])
        var decoder = ZstdDecoder()
        #expect(zstdDecodeAll(compressed, capacity: 9_999, decoder: &decoder) == .failure(.insufficientCapacity))
    }

    // MARK: Malformed input

    /// Every byte of small frames changed, and every truncation: decoding throws or succeeds, never traps
    /// or reads outside the input; with a checksum, success means the original content.
    static let corruptionFrames: [(name: String, content: [UInt8], frame: [UInt8])] = {
        let text = Array(zstdSamples().first { $0.name == "text" }!.bytes.prefix(3_000))
        let mixed = Array(zstdSamples().first { $0.name == "mixed" }!.bytes.prefix(2_000))
        let letters = skewedLetters(12_000)
        return [
            ("text 1", text, zstdCompress(text, level: 1, parameters: [(ZSTD_c_checksumFlag, 1)])),
            ("text 19", text, zstdCompress(text, level: 19, parameters: [(ZSTD_c_checksumFlag, 1)])),
            ("mixed small blocks", mixed, zstdCompress(mixed, level: 9, parameters: [(ZSTD_c_checksumFlag, 1), (zstdMaxBlockSize, 1024)])),
            ("text raw literals", text, zstdCompress(text, level: 3, parameters: [(ZSTD_c_checksumFlag, 1), (zstdLiteralCompressionMode, 2)])),
            ("text no checksum", text, zstdCompress(text, level: 6)),
            ("letters, double-symbol tables", letters, zstdCompress(letters, level: 3, parameters: [(ZSTD_c_checksumFlag, 1)])),
        ]
    }()

    /// Every byte flipped and every cut in each frame's first 64 bytes (frame and block headers, table
    /// descriptions) and last 16 (the checksum, the last sequences), and every 9th byte between; every byte in
    /// ZstdBulkTests.
    @Test(arguments: 0..<6)
    func survivesCorruption(frame: Int) {
        Self.checkSurvivesCorruption(Self.corruptionFrames[frame]) { index, count in index < 64 || index >= count - 16 || index % 9 == 0 }
    }

    static func checkSurvivesCorruption(_ sample: (name: String, content: [UInt8], frame: [UInt8]), at positions: (_ index: Int, _ count: Int) -> Bool) {
        var decoder = ZstdDecoder()
        for (name, content, frame) in [sample] {
            for index in 0..<frame.count where positions(index, frame.count) {
                for mask: UInt8 in content.count > 10_000 ? [0xFF, 0x01] : [0xFF, 0x01, 0x80, 0x10] {
                    var corrupt = frame
                    corrupt[index] ^= mask
                    let all = zstdDecodeAll(corrupt, capacity: content.count + 100, decoder: &decoder)
                    let streamed = zstdDecodeStreaming(corrupt, chunk: 61, outputChunk: 1000, decoder: &decoder)
                    if frame[4] & 4 != 0 { // Checksummed: success must mean the right content.
                        if case let .success(output) = all { #expect(output == content, "\(name): byte \(index) ^ \(mask)") }
                        if case let .success(output) = streamed { #expect(output == content, "\(name) streamed: byte \(index) ^ \(mask)") }
                    }
                }
            }
            for length in 0..<frame.count where positions(length, frame.count) {
                let truncated = Array(frame.prefix(length))
                #expect(zstdDecodeAll(truncated, capacity: content.count, decoder: &decoder) == .failure(.insufficientData), "\(name) cut at \(length)")
                #expect(zstdDecodeStreaming(truncated, chunk: 97, outputChunk: 500, decoder: &decoder) == .failure(.insufficientData), "\(name) streamed, cut at \(length)")
            }
        }
    }

    @Test func survivesRandomInput() {
        var rng = SplitMix64(seed: 404)
        var decoder = ZstdDecoder()
        for size in [0, 1, 5, 6, 10, 20, 100, 1000, 20_000] {
            for _ in 0..<200 {
                // A valid header, then garbage: block headers, literals, and sequences of every kind.
                var frame = ZstdFrames.header(contentSize: nil, fieldSize: 0, singleSegment: false, window: UInt8(rng.next() % 0x80))
                frame += (0..<size).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                _ = zstdDecodeAll(frame, capacity: 1 << 18, decoder: &decoder)
                _ = zstdDecodeStreaming(frame, chunk: 1 << 16, outputChunk: 1 << 16, decoder: &decoder)
            }
        }
    }

    // MARK: Checksums

    @Test func hashesLikeXXH64() {
        // Published values for XXH64 with seed 0.
        #expect(XXHash64.hash([UInt8]().span.bytes) == 0xEF46_DB37_51D8_E999)
        // Every length up to 300, whole and in pieces, against the checksum libzstd writes into frames.
        var rng = SplitMix64(seed: 64)
        let bytes = (0..<300).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        for length in 0...300 {
            let data = Array(bytes.prefix(length))
            let frame = zstdCompress(data, level: 1, parameters: [(ZSTD_c_checksumFlag, 1)])
            let expected = frame.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            #expect(UInt32(truncatingIfNeeded: XXHash64.hash(data.span.bytes)) == expected, "length \(length)")
            var hasher = XXHash64()
            var offset = 0
            var step = 1
            while offset < length {
                let end = min(offset + step, length)
                hasher.update(data.span.bytes.extracting(offset..<end))
                offset = end
                step = step * 3 % 41 + 1
            }
            #expect(UInt32(truncatingIfNeeded: hasher.digest) == expected, "length \(length) in pieces")
        }
    }
}

/// Every byte of every corruption frame flipped and every cut.
@Suite(.bulk) struct ZstdBulkTests {
    @Test(arguments: 0..<6)
    func survivesCorruption(frame: Int) {
        ZstdDecoderTests.checkSurvivesCorruption(ZstdDecoderTests.corruptionFrames[frame]) { _, _ in true }
    }
}
