import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import CBrotli
import CLZMA
import Foundation
import Testing

/// What a streaming decoder holds back. `ByteTransform.maximumUnitByteCount` is the most unconsumed input a call may need
/// before it can make progress; `Pipeline` sizes its buffer by it and traps when a stage holds more. bzip2 and Brotli
/// declared 1 while holding a block's tables or a meta-block's header (a valid 49 KB bzip2 stream and Brotli's `-q 11`
/// output trapped a `Pipeline` with 256-byte buffers; a corrupt bzip2 stream's code lengths ran on without end), and read
/// them again from the start on every call, quadratic in input that arrives a little at a time. Both now read those
/// headers a part at a time, keeping the parts read, so what they hold back is one part at most: bzip2's 1,324 bytes (one
/// table's code lengths, each at most 20 steps from the last), Brotli's 451 (a command tree's prefix code).
@Suite struct StreamingUnitTests {
    /// Each streaming format, with a sample stream.
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case deflate, zlib, gzip, deflate64, brotli, zstd, bzip2, lzma, xz
        var testDescription: String { rawValue }

        /// The format, a stream of it, and what the stream decodes to.
        func sample() throws -> (format: DecompressionFormat, stream: [UInt8], decoded: [UInt8]) {
            let text = SampleBytes.text(30_000, seed: 41)
            switch self {
            case .deflate: return (.deflate(.raw), zlibCompress(text, format: .raw, level: 9), text)
            case .zlib: return (.deflate(.zlib), zlibCompress(text, format: .zlib, level: 6), text)
            case .gzip: return (.deflate(.gzip), zlibCompress(text, format: .gzip, level: 6), text)
            case .deflate64: return (.deflate64, Deflate64Tests.short, Deflate64Tests.shortData)
            case .brotli:
                // Quality 11 splits blocks and models contexts: a header of many prefix codes.
                let data = SampleBytes.mixed(60_000, seed: 42)
                return (.brotli, googleBrotliCompress(data, quality: 11), data)
            case .zstd: return try (.zstd(), compressed(text, .zstd(level: 3)), text)
            case .bzip2: return (.bzip2, bzip2Compress(text, level: 9), text)
            case .lzma:
                let properties = try LZMAProperties(byte: 0x5D, dictionarySize: 8 << 20) // liblzma's preset 6
                return (.lzma(properties), lzma1Compress(text, options: lzmaOptions(preset: 6), marker: true), text)
            case .xz: return (.xz(), xzCompress(text, preset: 6), text)
            }
        }
    }

    /// What ``trickle(_:_:step:)`` saw.
    struct Trickled {
        var output: [UInt8] = []
        /// The most input a call left unconsumed when it asked for more.
        var mostHeld = 0
        /// What decoding threw, if it did.
        var error: BytesError?
    }

    /// Decodes `stream` through `Decompressor.transform`, giving it `step` more bytes on each call after those it left
    /// (with `.finish` once all are given), into 64 KiB of room at a time.
    static func trickle(_ stream: [UInt8], _ format: DecompressionFormat, step: Int = 1) -> Trickled {
        var result = Trickled()
        var decompressor: Decompressor
        do throws(BytesError) {
            decompressor = try Decompressor(for: format)
        } catch {
            result.error = error
            return result
        }
        var room = [UInt8](repeating: 0, count: 64 << 10)
        var consumed = 0
        var available = 0
        while true {
            available = min(available + step, stream.count)
            let flush: TransformFlush = available == stream.count ? .finish : .none
            while true {
                let progress: TransformProgress
                do throws(BytesError) {
                    progress = try room.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
                        try decompressor.transform(stream.span.bytes.extracting(consumed..<available), into: &span, flush: flush)
                    }
                } catch {
                    result.error = error
                    return result
                }
                result.output += room.prefix(progress.produced)
                consumed += progress.consumed
                if progress.status == .needsOutput { continue }
                if progress.status == .finished { return result }
                result.mostHeld = max(result.mostHeld, available - consumed)
                break
            }
            if available == stream.count {
                // `.finish` never asks for more: it finishes or throws.
                Issue.record("Asked for more input after it ended")
                return result
            }
        }
    }

    @Test func declaredUnits() throws {
        let units: [(DecompressionFormat, Int)] = try [
            (.deflate(.raw), 289), (.deflate(.gzip), 289), (.deflate64, 289), (.brotli, 451), (.zstd(), 1), (.bzip2, 1_324),
            (.lzma(LZMAProperties(dictionarySize: 1 << 20)), 20), (.xz(), 65_542),
        ]
        for (format, unit) in units {
            #expect(format.maximumUnitByteCount == unit, "\(format)")
            // Staged input holds two units, and 256 KB at least.
            #expect(ChunkedDecompressor.stagingCapacity(for: format) == 256 << 10, "\(format)")
        }
        for format: DecompressionFormat in [.lzfse, .lzvn, .lz4(framed: false), .lzbitmap, .lzraven] {
            #expect(format.maximumUnitByteCount == nil, "\(format)")
        }
        #expect(Decompressor.maximumUnitByteCount == 65_542)
        #expect(BZip2Decoder.maximumUnitByteCount == 1_324)
        #expect(BrotliDecoder.maximumUnitByteCount == 451)
        #expect(DeflateDecoder.maximumUnitByteCount == 289)
    }

    /// Fed a byte at a time, no decoder ever holds back as much as its declared unit.
    @Test(arguments: Kind.allCases)
    func heldBackStaysUnderTheUnit(_ kind: Kind) throws {
        let (format, stream, decoded) = try kind.sample()
        let unit = try #require(format.maximumUnitByteCount)
        let result = Self.trickle(stream, format)
        #expect(result.error == nil)
        #expect(result.output == decoded)
        #expect(result.mostHeld < unit, "\(kind): held \(result.mostHeld) of a \(unit)-byte unit")
    }

    /// `Pipeline` sizes its buffer by the second stage's unit: with 256 bytes asked for, bzip2's tables (here a block
    /// of 180,000 bytes at level 9) and Brotli's headers trapped it.
    @Test func smallPipelineBuffersDecode() throws {
        let text = SampleBytes.text(180_000, seed: 43)
        let bzip2 = bzip2Compress(text, level: 9)
        var bzip2Pipeline = CopyStage().promoted(to: BytesError.self).then(BZip2Decoder(), bufferCapacity: 256)
        #expect(try run(&bzip2Pipeline, bzip2, chunk: 256, outputChunk: 4_096) == text)

        let (_, brotli, decoded) = try Kind.brotli.sample()
        var brotliPipeline = CopyStage().promoted(to: BytesError.self).then(BrotliDecoder(), bufferCapacity: 256)
        #expect(try run(&brotliPipeline, brotli, chunk: 256, outputChunk: 4_096) == decoded)

        // A crafted header of over 100 KB: 256 block types and trees of each kind, full context maps.
        let crafted = BrotliHeaderCraft.largeHeaderStream()
        var craftedPipeline = CopyStage().promoted(to: BytesError.self).then(BrotliDecoder(), bufferCapacity: 256)
        #expect(try run(&craftedPipeline, crafted, chunk: 256, outputChunk: 4_096) == BrotliHeaderCraft.decoded)
    }

    /// The crafted header is a valid stream: Google's decoder and this one agree on it.
    @Test func craftedBrotliHeaderDecodes() {
        let crafted = BrotliHeaderCraft.largeHeaderStream()
        #expect(crafted.count > 100_000)
        #expect(googleBrotliDecompress(crafted) == .decoded(BrotliHeaderCraft.decoded))
        #expect(brotliDecodeAll(crafted) == .decoded(BrotliHeaderCraft.decoded))
        // In 97-byte steps (a byte at a time in the bulk tests): every part of it stops short of an input's end somewhere.
        let result = Self.trickle(crafted, .brotli, step: 97)
        #expect(result.error == nil)
        #expect(result.output == BrotliHeaderCraft.decoded)
        #expect(result.mostHeld < BrotliDecoder.maximumUnitByteCount)
    }

    /// A code length takes at most 20 steps of ±1 from the last (19 reach any of 1 through 20): the 21st is corrupt, so
    /// the most a table's code lengths take is bounded. libbzip2 accepts any number of `+1 −1` pairs; no encoder writes
    /// them.
    @Test func codeLengthStepsAreBounded() {
        // 20 steps per length, every length: the tables are read, then the input ends before any symbol.
        let twenty = BZip2Craft.tables(groups: 2, selectors: 1, steps: 20)
        #expect(Self.decodeAll(twenty, .bzip2) == .insufficientData)
        #expect(Self.trickle(twenty, .bzip2).error == .insufficientData)
        let twentyOne = BZip2Craft.tables(groups: 2, selectors: 1, steps: 20, extraStepsOnFirst: 1)
        #expect(Self.decodeAll(twentyOne, .bzip2) == .invalidValue)
        #expect(Self.trickle(twentyOne, .bzip2).error == .invalidValue)
    }

    /// The bound is a deliberate difference from libbzip2: a real stream with 12 `+1 −1` pairs added to its first code
    /// length decodes there (to the same bytes: the CRCs cover the data, not the bits), and is corrupt here.
    @Test func libbzip2TakesStepsTheBoundRefuses() {
        let text = SampleBytes.text(20_000, seed: 44)
        let padded = BZip2Craft.withExtraSteps(bzip2Compress(text, level: 9), pairs: 12)
        #expect(bzip2ReferenceDecompress(padded, capacity: text.count) == text)
        #expect(Self.decodeAll(padded, .bzip2) == .invalidValue)
    }

    /// The largest tables the format allows (32,767 selectors of 6 bits, 6 tables of 258 lengths, each 20 steps from the
    /// last: 32 KB), in 97-byte steps (a byte at a time in the bulk tests): what's held back is one part at most.
    @Test func largestBZip2TablesInSteps() {
        let tables = BZip2Craft.tables(groups: 6, selectors: 32_767, steps: 20)
        let result = Self.trickle(tables, .bzip2, step: 97)
        #expect(result.error == .insufficientData)
        #expect(result.mostHeld < BZip2Decoder.maximumUnitByteCount)
        #expect(Self.decodeAll(tables, .bzip2) == .insufficientData)
    }

    /// A corrupt stream whose first code length steps `+1 −1` for 100 KB: it throws as soon as the steps pass the bound,
    /// whole, a byte at a time, and through a `Pipeline` with small buffers, which it trapped (the decoder held it all).
    @Test func endlessCodeLengthStepsThrow() throws {
        let corrupt = BZip2Craft.endlessSteps(byteCount: 100_000)
        #expect(Self.decodeAll(corrupt, .bzip2) == .invalidValue)
        let trickled = Self.trickle(corrupt, .bzip2)
        #expect(trickled.error == .invalidValue)
        #expect(trickled.mostHeld < BZip2Decoder.maximumUnitByteCount)
        var pipeline = CopyStage().promoted(to: BytesError.self).then(BZip2Decoder(), bufferCapacity: 256)
        #expect(throws: BytesError.invalidValue) { _ = try run(&pipeline, corrupt, chunk: 256, outputChunk: 4_096) }
    }

    /// The format's whole-buffer decode of `stream`: the error it throws, or `nil`.
    static func decodeAll(_ stream: [UInt8], _ format: DecompressionFormat) -> BytesError? {
        let room = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { room.deallocate() }
        do throws(BytesError) {
            var decompressor = try Decompressor(for: format)
            var span = OutputRawSpan(buffer: room, initializedCount: 0)
            _ = try decompressor.decompressAll(stream.span.bytes, into: &span)
            _ = span.finalize(for: room)
            return nil
        } catch {
            return error
        }
    }
}

/// Corpus files and the worst cases, a byte at a time.
@Suite(.bulk) struct StreamingUnitBulkTests {
    /// A corpus file's first 2 MB, and its streams in each streaming format (Brotli at quality 11, whose headers are the
    /// largest), made once for both corpus tests.
    struct CorpusFile {
        let name: String
        let data: [UInt8]
        let streams: [(format: DecompressionFormat, stream: [UInt8])]
    }

    static let corpus: [CorpusFile] = ["dickens", "mozilla", "x-ray", "samba", "xml", "ooffice"].compactMap { name in
        guard let url = Corpus.file("silesia/\(name)"), let contents = try? Data(contentsOf: url) else { return nil }
        let data = Array(contents.prefix(2 << 20))
        return CorpusFile(name: name, data: data, streams: [
            (.deflate(.zlib), zlibCompress(data, format: .zlib, level: 9)),
            (.brotli, googleBrotliCompress(data, quality: 11)),
            (.zstd(), (try? compressed(data, .zstd(level: 3))) ?? []),
            (.bzip2, bzip2Compress(data, level: 9)),
            (.xz(), xzCompress(data, preset: 6)),
        ])
    }

    /// Each corpus stream fed a byte at a time: no decoder holds back its unit.
    @Test func corpusHeldBackStaysUnderTheUnit() throws {
        for file in Self.corpus {
            for (format, stream) in file.streams {
                let unit = try #require(format.maximumUnitByteCount)
                let result = StreamingUnitTests.trickle(stream, format)
                #expect(result.error == nil, "\(file.name) \(format)")
                #expect(result.output == file.data, "\(file.name) \(format)")
                #expect(result.mostHeld < unit, "\(file.name) \(format): held \(result.mostHeld) of a \(unit)-byte unit")
            }
        }
    }

    /// Through a `Pipeline` with 256-byte buffers (each decoder's unit, if larger): Brotli's `-q 11` output of mozilla,
    /// x-ray, dickens, and samba trapped one with 1 or 2 KB buffers.
    @Test func corpusThroughSmallPipelineBuffers() throws {
        for file in Self.corpus {
            for (format, stream) in file.streams {
                let decoded: [UInt8]
                switch format {
                case .brotli:
                    var pipeline = CopyStage().promoted(to: BytesError.self).then(BrotliDecoder(), bufferCapacity: 256)
                    decoded = try run(&pipeline, stream, chunk: 256, outputChunk: 4_096)
                case .bzip2:
                    var pipeline = CopyStage().promoted(to: BytesError.self).then(BZip2Decoder(), bufferCapacity: 256)
                    decoded = try run(&pipeline, stream, chunk: 256, outputChunk: 4_096)
                case .deflate(.zlib):
                    var pipeline = CopyStage().promoted(to: BytesError.self).then(DeflateDecoder(format: .zlib), bufferCapacity: 256)
                    decoded = try run(&pipeline, stream, chunk: 256, outputChunk: 4_096)
                default:
                    continue
                }
                #expect(decoded == file.data, "\(file.name) \(format)")
            }
        }
    }

    /// The largest headers, a byte at a time, in time: read again from their start on every call they took about the
    /// square of their size (a ~190 KB Brotli header, some 10¹⁰ byte-steps); a part at a time, they take seconds at most.
    @Test func largestHeadersAByteAtATime() {
        let clock = ContinuousClock()
        // Brotli: 256 block types and trees of each kind, full context maps.
        let brotli = BrotliHeaderCraft.largeHeaderStream()
        var result = StreamingUnitTests.Trickled()
        let brotliTime = clock.measure { result = StreamingUnitTests.trickle(brotli, .brotli) }
        #expect(result.error == nil)
        #expect(result.output == BrotliHeaderCraft.decoded)
        #expect(result.mostHeld < BrotliDecoder.maximumUnitByteCount)
        #expect(brotliTime < .seconds(20), "\(brotliTime)")

        // bzip2: the format's most selectors (32,767, 6 bits each) and 6 tables of 258 lengths, each 20 steps from the
        // last: 32 KB of tables, then the input ends.
        let bzip2 = BZip2Craft.tables(groups: 6, selectors: 32_767, steps: 20)
        #expect(bzip2.count > 32_000)
        let bzip2Time = clock.measure { result = StreamingUnitTests.trickle(bzip2, .bzip2) }
        #expect(result.error == .insufficientData)
        #expect(result.mostHeld < BZip2Decoder.maximumUnitByteCount)
        // Each table's lengths are a whole part: it held back nearly one, from any bit of the byte it starts in.
        #expect(result.mostHeld > BZip2Decoder.maximumUnitByteCount - 4)
        #expect(bzip2Time < .seconds(20), "\(bzip2Time)")
        #expect(StreamingUnitTests.decodeAll(bzip2, .bzip2) == .insufficientData)
    }
}

// MARK: - Crafted streams

/// bzip2 streams written bit by bit: a block's tables as large as the format allows, and corrupt ones.
enum BZip2Craft {
    /// bzip2's bits, most significant first.
    struct Bits {
        var bytes: [UInt8] = []
        var pending: UInt64 = 0
        var count = 0

        mutating func write(_ value: UInt64, bits: Int) {
            for shift in stride(from: bits - 1, through: 0, by: -1) {
                pending = pending << 1 | (value >> UInt64(shift)) & 1
                count += 1
                if count == 8 {
                    bytes.append(UInt8(truncatingIfNeeded: pending))
                    pending = 0
                    count = 0
                }
            }
        }

        /// The bytes, the last padded with zeros.
        func finished() -> [UInt8] {
            count == 0 ? bytes : bytes + [UInt8(truncatingIfNeeded: pending << UInt64(8 - count))]
        }
    }

    /// A stream header, then a block's header and its symbol map (`symbols` bytes in use, the first ones), its table and
    /// selector counts.
    static func blockStart(symbols: Int, groups: Int, selectors: Int) -> Bits {
        var bits = Bits()
        for byte in Array("BZh9".utf8) {
            bits.write(UInt64(byte), bits: 8)
        }
        bits.write(0x3141_5926_5359, bits: 48) // the block magic
        bits.write(0, bits: 32) // CRC
        bits.write(0, bits: 1) // not randomized
        bits.write(0, bits: 24) // origin
        let ranges = (symbols + 15) / 16
        bits.write(UInt64(0xFFFF) << UInt64(16 - ranges) & 0xFFFF, bits: 16)
        for range in 0..<ranges {
            let used = min(16, symbols - range * 16)
            bits.write(UInt64(0xFFFF) << UInt64(16 - used) & 0xFFFF, bits: 16)
        }
        bits.write(UInt64(groups), bits: 3)
        bits.write(UInt64(selectors), bits: 15)
        return bits
    }

    /// A stream that ends after one block's tables: every byte in use (258 symbols), `groups` tables, `selectors` selectors
    /// of as many bits as `groups` allows (`groups - 1` ones and a zero), and every code length 9, reached in `steps` steps
    /// (up half of them, down again) from the last; the first length takes `extraStepsOnFirst` more (up).
    static func tables(groups: Int, selectors: Int, steps: Int, extraStepsOnFirst: Int = 0) -> [UInt8] {
        var bits = blockStart(symbols: 256, groups: groups, selectors: selectors)
        for _ in 0..<selectors {
            bits.write((UInt64(1) << UInt64(groups - 1) - 1) << 1, bits: groups)
        }
        for group in 0..<groups {
            bits.write(9 - UInt64(group == 0 ? extraStepsOnFirst : 0), bits: 5)
            for symbol in 0..<258 {
                if group == 0 && symbol == 0 {
                    for _ in 0..<extraStepsOnFirst {
                        bits.write(0b10, bits: 2)
                    }
                }
                for _ in 0..<steps / 2 {
                    bits.write(0b10, bits: 2)
                } // +1
                for _ in 0..<steps / 2 {
                    bits.write(0b11, bits: 2)
                } // −1
                bits.write(0, bits: 1)
            }
        }
        return bits.finished()
    }

    /// `stream` (one stream at level 9) with `pairs` more steps up and down (down and up from 20) on its first block's
    /// first code length, right after its 5-bit start: 4 bits a pair, so whole bytes for an even count.
    static func withExtraSteps(_ stream: [UInt8], pairs: Int) -> [UInt8] {
        var bits = stream.flatMap { byte in (0..<8).map { byte >> UInt8(7 - $0) & 1 } }
        var position = 32 + 48 + 32 + 1 + 24 // `BZh9`, the block's magic, CRC, randomized bit, and origin
        func read(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count {
                value = value << 1 | Int(bits[position])
                position += 1
            }
            return value
        }
        let ranges = read(16)
        position += 16 * ranges.nonzeroBitCount
        _ = read(3) // tables
        let selectors = read(15)
        for _ in 0..<selectors {
            while bits[position] == 1 {
                position += 1
            }
            position += 1
        }
        let start = read(5)
        let pair: [UInt8] = start < 20 ? [1, 0, 1, 1] : [1, 1, 1, 0]
        bits.insert(contentsOf: (0..<pairs).flatMap { _ in pair }, at: position)
        return stride(from: 0, to: bits.count, by: 8).map { index in
            (0..<8).reduce(UInt8(0)) { byte, offset in byte << 1 | (index + offset < bits.count ? bits[index + offset] : 0) }
        }
    }

    /// A block whose first code length steps `+1 −1` until the stream is `byteCount` bytes long.
    static func endlessSteps(byteCount: Int) -> [UInt8] {
        var bits = blockStart(symbols: 1, groups: 2, selectors: 1)
        bits.write(0, bits: 1) // the selector
        bits.write(5, bits: 5)
        while bits.bytes.count < byteCount {
            bits.write(0b1011, bits: 4)
        }
        return bits.finished()
    }
}

/// A Brotli stream with about as large a header as the format allows, written bit by bit (RFC 7932): one meta-block of
/// one byte, with 256 block types of each category, 256 literal and distance trees, full context maps, and every prefix
/// code complex, its every length coded in 5 bits.
enum BrotliHeaderCraft {
    /// What the stream decodes to.
    static let decoded: [UInt8] = [0x41]

    /// Brotli's bits, least significant first.
    struct Bits {
        var bytes: [UInt8] = []
        var pending: UInt64 = 0
        var count = 0

        mutating func write(_ value: Int, bits: Int) {
            pending |= UInt64(value) << UInt64(count)
            count += bits
            while count >= 8 {
                bytes.append(UInt8(truncatingIfNeeded: pending))
                pending >>= 8
                count -= 8
            }
        }

        /// The bytes, the last padded with zeros.
        func finished() -> [UInt8] { count == 0 ? bytes : bytes + [UInt8(truncatingIfNeeded: pending)] }
    }

    /// A canonical prefix code (RFC 7932 3.2, as RFC 1951's), its codes bit-reversed for a least-significant-first writer.
    struct Code {
        let lengths: [Int]
        let codes: [Int]

        init(lengths: [Int]) {
            self.lengths = lengths
            var counts = [Int](repeating: 0, count: 16)
            for length in lengths where length > 0 {
                counts[length] += 1
            }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for length in 1..<16 {
                code = (code + counts[length - 1]) << 1 // (No length is 0: `counts[0]` is 0.)
                next[length] = code
            }
            var codes = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                var reversed = 0
                for bit in 0..<length where next[length] >> bit & 1 != 0 {
                    reversed |= 1 << (length - 1 - bit)
                }
                codes[symbol] = reversed
                next[length] += 1
            }
            self.codes = codes
        }

        /// A complete code of `alphabetSize` symbols with lengths k − 1 and k.
        static func balanced(_ alphabetSize: Int) -> Code {
            var k = 0
            while 1 << k < alphabetSize {
                k += 1
            }
            let short = (1 << k) - alphabetSize
            return Code(lengths: (0..<alphabetSize).map { $0 < short ? k - 1 : k })
        }

        func write(_ symbol: Int, to bits: inout Bits) { bits.write(codes[symbol], bits: lengths[symbol]) }

        /// Writes the code as a complex prefix code (RFC 7932 3.5): every code-length code length sent, and each length
        /// coded in 5 bits (the code-length code gives 16 and 17, unused, 2 bits, and every length 5).
        func writeDefinition(to bits: inout Bits) {
            bits.write(0, bits: 2) // HSKIP
            let codeLengthLengths = (0..<18).map { $0 < 16 ? 5 : 2 }
            // The fixed code for the code-length code's lengths, by value: (pattern, bits).
            let fixed: [Int: (Int, Int)] = [0: (0, 2), 1: (7, 4), 2: (3, 3), 3: (2, 2), 4: (1, 2), 5: (15, 4)]
            for symbol in [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15] {
                let (pattern, count) = fixed[codeLengthLengths[symbol]]!
                bits.write(pattern, bits: count)
            }
            let codeLengthCode = Code(lengths: codeLengthLengths)
            for length in lengths {
                codeLengthCode.write(length, to: &bits)
            }
        }
    }

    /// RFC 7932's VarLenUint8 of `value` (1 through 255).
    static func writeCount(_ value: Int, to bits: inout Bits) {
        bits.write(1, bits: 1)
        var n = 0
        while 1 << (n + 1) <= value {
            n += 1
        }
        bits.write(n, bits: 3)
        if n > 0 { bits.write(value - (1 << n), bits: n) }
    }

    static func largeHeaderStream() -> [UInt8] {
        var bits = Bits()
        bits.write(0, bits: 1) // WBITS: 16
        // Meta-block header: last, not empty, 4 nibbles of MLEN − 1 = 0.
        bits.write(1, bits: 1)
        bits.write(0, bits: 1)
        bits.write(0, bits: 2)
        bits.write(0, bits: 16)
        // 256 block types per category: their codes, a block-count code, and the first block's count (16,625).
        let typeCode = Code.balanced(258), countCode = Code.balanced(26)
        for _ in 0..<3 {
            writeCount(255, to: &bits)
            typeCode.writeDefinition(to: &bits)
            countCode.writeDefinition(to: &bits)
            countCode.write(25, to: &bits)
            bits.write(0, bits: 24)
        }
        bits.write(0, bits: 2) // NPOSTFIX
        bits.write(0, bits: 4) // NDIRECT: 64 distance symbols
        for _ in 0..<256 {
            bits.write(0, bits: 2)
        } // context modes: LSB6
        // The literal context map: 256 trees, no zero runs, each entry the next tree.
        let mapCode = Code.balanced(256)
        for size in [64 * 256, 4 * 256] {
            writeCount(255, to: &bits)
            bits.write(0, bits: 1) // RLEMAX: none
            mapCode.writeDefinition(to: &bits)
            for index in 0..<size {
                mapCode.write(index % 256, to: &bits)
            }
            bits.write(0, bits: 1) // no move-to-front
        }
        let literalCode = Code.balanced(256), commandCode = Code.balanced(704), distanceCode = Code.balanced(64)
        for _ in 0..<256 {
            literalCode.writeDefinition(to: &bits)
        }
        for _ in 0..<256 {
            commandCode.writeDefinition(to: &bits)
        }
        for _ in 0..<256 {
            distanceCode.writeDefinition(to: &bits)
        }
        // One command: insert 1, copy 2 (ignored: the meta-block ends with the literal), symbol 8.
        commandCode.write(8, to: &bits)
        literalCode.write(Int(decoded[0]), to: &bits)
        return bits.finished()
    }
}
