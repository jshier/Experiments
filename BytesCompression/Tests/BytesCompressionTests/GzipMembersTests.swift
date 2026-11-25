import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTesting
import BytesTestSupport
import Testing

// gzip files of several members (RFC 1952 §2.2: `cat a.gz b.gz`, pigz, BGZF), made by zlib and by Bytes' encoder, some
// with every optional header field: whole, streamed (input cut at every byte, a byte at a time), into the caller's
// buffers after history, in parallel, and through `Decompressor` and the pipeline contract. Each member's CRC-32 and
// length are checked, bytes after a member must start another, and a member can't reach into the one before.

/// A gzip member around raw DEFLATE `deflated` of `payload`, with the optional header fields given.
func gzipMember(
    _ deflated: [UInt8], of payload: [UInt8], name: String? = nil, comment: String? = nil, extra: [UInt8]? = nil,
    headerCRC: Bool = false, modificationTime: UInt32 = 0, operatingSystem: UInt8 = 255
) -> [UInt8] {
    var flags: UInt8 = 0
    if headerCRC { flags |= 2 }
    if extra != nil { flags |= 4 }
    if name != nil { flags |= 8 }
    if comment != nil { flags |= 16 }
    var header: [UInt8] = [0x1F, 0x8B, 8, flags]
    header += littleEndian(modificationTime, count: 4) + [0, operatingSystem]
    if let extra { header += littleEndian(UInt32(extra.count), count: 2) + extra }
    if let name { header += Array(name.utf8) + [0] }
    if let comment { header += Array(comment.utf8) + [0] }
    if headerCRC { header += littleEndian(CRC32.checksum(header.span.bytes), count: 2) }
    return header + deflated + littleEndian(CRC32.checksum(payload.span.bytes), count: 4) + littleEndian(UInt32(truncatingIfNeeded: payload.count), count: 4)
}

/// `value`'s low `count` bytes, little-endian.
func littleEndian(_ value: UInt32, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) }
}

/// Bytes' gzip encoding of `data`.
func bytesGzip(_ data: [UInt8], level: Int = 6) -> [UInt8] {
    encodeAll(data, format: .gzip, level: level)
}

/// A file of members: what each decodes to, and the members end to end.
struct GzipFile {
    var members: [[UInt8]] = []
    var payloads: [[UInt8]] = []

    var bytes: [UInt8] { members.flatMap(\.self) }
    var decoded: [UInt8] { payloads.flatMap(\.self) }

    mutating func append(_ member: [UInt8], decodesTo payload: [UInt8]) {
        members.append(member)
        payloads.append(payload)
    }

    /// Six members, each `size` bytes of data or so: zlib's, Bytes', one with every optional field (FNAME,
    /// FCOMMENT, FEXTRA, FHCRC) around stored blocks, an empty one of each encoder, and one with a name last.
    static func mixed(size: Int) -> GzipFile {
        let text = SampleBytes.deflateSamples.first { $0.name == "text" }!.bytes
        let random = SampleBytes.deflateSamples.first { $0.name == "random" }!.bytes
        let runs = SampleBytes.deflateSamples.first { $0.name == "runs" }!.bytes
        let periodic = SampleBytes.deflateSamples.first { $0.name == "periodic" }!.bytes
        var file = GzipFile()
        let first = Array(text.prefix(size))
        file.append(zlibCompress(first, format: .gzip), decodesTo: first)
        let second = Array(runs.prefix(size / 2))
        file.append(bytesGzip(second, level: 1), decodesTo: second)
        let third = Array(random.prefix(size / 4))
        file.append(
            gzipMember(zlibCompress(third), of: third, name: "random.bin", comment: "every field", extra: [0x42, 0x43, 2, 0, 7, 9],
                       headerCRC: true, modificationTime: 1_700_000_000, operatingSystem: 3),
            decodesTo: third
        )
        file.append(bytesGzip([]), decodesTo: [])
        file.append(zlibCompress([], format: .gzip), decodesTo: [])
        let last = Array(periodic.prefix(size)) + Array("z".utf8)
        file.append(gzipMember(encodeAll(last, format: .raw, level: 6), of: last, name: "last.txt", modificationTime: 12_345, operatingSystem: 3),
                    decodesTo: last)
        return file
    }
}

/// Feeds `data` to `call` in pieces ending at `cuts` (then the rest), each call given the bytes not yet consumed,
/// output into `outputChunk`-byte buffers; `.finish` with the last piece. A `.finished` before the input ends asks
/// for the next piece (a member's end), unless `pipeline`: then it's a contract violation.
func feed(
    _ data: [UInt8], cuts: [Int], outputChunk: Int, pipeline: Bool = false,
    _ call: (RawSpan, inout OutputRawSpan, TransformFlush) throws(BytesError) -> TransformProgress
) -> Result<[UInt8], BytesError> {
    let ends = cuts.filter { $0 > 0 && $0 < data.count }.sorted() + [data.count]
    var piece = 0
    var output: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: outputChunk)
    var consumed = 0
    var calls = 0
    while true {
        calls += 1
        guard calls < 10_000_000 else { return .failure(.invalidValue) }
        let available = ends[piece]
        let flush: TransformFlush = available == data.count ? .finish : .none
        let progress: TransformProgress
        do throws(BytesError) {
            progress = try buffer.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
                try call(data.span.bytes.extracting(consumed..<available), &span, flush)
            }
        } catch {
            return .failure(error)
        }
        output += buffer.prefix(progress.produced)
        consumed += progress.consumed
        switch progress.status {
        case .needsOutput:
            continue
        case .finished where available == data.count:
            return consumed == data.count ? .success(output) : .failure(.invalidValue)
        case .finished, .needsInput:
            if pipeline && progress.status == .finished {
                Issue.record("`.finished` before `.finish`")
                return .failure(.invalidValue)
            }
            if available == data.count { return .failure(.insufficientData) }
            piece += 1
        }
    }
}

/// `decompress(_:into:historyCount:)` into a buffer of history and `room`, the history moved to its front after each
/// call, input in pieces ending at `cuts`.
func feedWithHistory(_ data: [UInt8], cuts: [Int], room: Int, decoder: inout DeflateDecoder) -> Result<[UInt8], BytesError> {
    let ends = cuts.filter { $0 > 0 && $0 < data.count }.sorted() + [data.count]
    var piece = 0
    let historySize = decoder.historySize
    var buffer = [UInt8](repeating: 0, count: historySize + room)
    var output: [UInt8] = []
    var history = 0
    var consumed = 0
    while true {
        let progress: TransformProgress
        do throws(BytesError) {
            var span = buffer.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            progress = try decoder.decompress(data.span.bytes.extracting(consumed..<ends[piece]), into: &raw, historyCount: history)
        } catch {
            return .failure(error)
        }
        consumed += progress.consumed
        let end = history + progress.produced
        output += buffer[history..<end]
        let kept = min(historySize, end)
        buffer.replaceSubrange(0..<kept, with: buffer[(end - kept)..<end])
        history = kept
        switch progress.status {
        case .needsOutput:
            if progress.produced == 0 { return .failure(.insufficientCapacity) }
        case .finished where ends[piece] == data.count:
            return consumed == data.count ? .success(output) : .failure(.invalidValue)
        case .finished, .needsInput:
            if ends[piece] == data.count { return .failure(.insufficientData) }
            piece += 1
        }
    }
}

/// Decodes `data` whole with `decompressAll`, into exactly `capacity` bytes of room.
func gunzipAll(_ data: [UInt8], capacity: Int? = nil, decoder: inout DeflateDecoder) -> Result<[UInt8], BytesError> {
    var output = [UInt8](repeating: 0, count: capacity ?? max(1 << 16, data.count * 8))
    do throws(BytesError) {
        var consumed = 0
        let count = try output.withOutputRawSpan { span throws(BytesError) -> Int in
            consumed = try decoder.decompressAll(data.span.bytes, into: &span)
            return span.byteCount
        }
        guard consumed == data.count else { return .failure(.invalidValue) }
        return .success(Array(output.prefix(count)))
    } catch {
        return .failure(error)
    }
}

/// Every way to decode `data` as gzip: whole (the sequential, parallel, and `Decompressor` decoders), streamed into
/// the decoder's window and through `transform` with input cut at `cuts`, and after history. Each result, by name.
/// Without `whole`, only the ways that take input in pieces.
func gunzipEveryWay(_ data: [UInt8], cuts: [Int] = [], outputChunk: Int = 4096, whole: Bool = true) -> [(String, Result<[UInt8], BytesError>)] {
    var results: [(String, Result<[UInt8], BytesError>)] = []
    var decoder = DeflateDecoder(format: .gzip)
    if whole {
        results.append(("decompressAll", gunzipAll(data, decoder: &decoder)))
        results.append(("decompressAll again", gunzipAll(data, decoder: &decoder)))
    }
    decoder.reset()
    results.append(("decompress", feed(data, cuts: cuts, outputChunk: outputChunk) { input, output, _ throws(BytesError) in
        try decoder.decompress(input, into: &output)
    }))
    decoder.reset()
    results.append(("transform", feed(data, cuts: cuts, outputChunk: outputChunk, pipeline: true) { input, output, flush throws(BytesError) in
        try decoder.transform(input, into: &output, flush: flush)
    }))
    decoder.reset()
    results.append(("history", feedWithHistory(data, cuts: cuts, room: max(outputChunk, 300), decoder: &decoder)))
    do throws(BytesError) {
        var decompressor = try Decompressor(for: .deflate(.gzip))
        results.append(("Decompressor.transform", feed(data, cuts: cuts, outputChunk: outputChunk, pipeline: true) { input, output, flush throws(BytesError) in
            try decompressor.transform(input, into: &output, flush: flush)
        }))
        guard whole else { return results }
        var output = [UInt8](repeating: 0, count: max(1 << 16, data.count * 8))
        let count = try output.withOutputRawSpan { span throws(BytesError) -> Int in
            _ = try decompressor.decompressAll(data.span.bytes, into: &span)
            return span.byteCount
        }
        results.append(("Decompressor.decompressAll", .success(Array(output.prefix(count)))))
    } catch {
        results.append(("Decompressor.decompressAll", .failure(error)))
    }
    var parallel = ParallelDeflateDecoder(format: .gzip, lanes: 4)
    var output = [UInt8](repeating: 0, count: max(1 << 16, data.count * 8))
    do throws(BytesError) {
        var consumed = 0
        let count = try output.withOutputRawSpan { span throws(BytesError) -> Int in
            consumed = try parallel.decompressAll(data.span.bytes, into: &span)
            return span.byteCount
        }
        results.append(("parallel", consumed == data.count ? .success(Array(output.prefix(count))) : .failure(.invalidValue)))
    } catch {
        results.append(("parallel", .failure(error)))
    }
    return results
}

@Suite struct GzipMembersTests {
    static let file = GzipFile.mixed(size: 20_000)
    /// Small members, for cutting the input at every byte.
    static let small = GzipFile.mixed(size: 300)

    @Test func everyMemberEveryWay() {
        let file = Self.file
        #expect(Zlib.decompressMembers(file.bytes) == file.decoded)
        for (cuts, outputChunk) in [([], 1 << 20), ([7, 19, 1000, 5000, 30_000], 4096), (Array(stride(from: 0, to: file.bytes.count, by: 997)), 333)] {
            for (name, result) in gunzipEveryWay(file.bytes, cuts: cuts, outputChunk: outputChunk) {
                #expect(result == .success(file.decoded), "\(name), cuts \(cuts.count), output \(outputChunk)")
            }
        }
    }

    /// Input in two pieces, cut at every byte (across every member boundary), and a byte at a time.
    @Test func inputCutAnywhere() {
        let file = Self.small
        let bytes = file.bytes
        for cut in 0...bytes.count {
            for (name, result) in gunzipEveryWay(bytes, cuts: [cut], outputChunk: 97, whole: false) {
                #expect(result == .success(file.decoded), "\(name), cut at \(cut)")
            }
        }
        for (name, result) in gunzipEveryWay(bytes, cuts: Array(0..<bytes.count), outputChunk: 5, whole: false) {
            #expect(result == .success(file.decoded), "\(name), a byte at a time")
        }
    }

    /// One member alone, and many small ones: the same output.
    @Test func manyMembers() {
        let data = Array(largeSample().prefix(300_000))
        var file = GzipFile()
        for (index, start) in stride(from: 0, to: data.count, by: 4096).enumerated() {
            let part = Array(data[start..<min(start + 4096, data.count)])
            file.append(index.isMultiple(of: 2) ? bytesGzip(part) : zlibCompress(part, format: .gzip), decodesTo: part)
        }
        for (name, result) in gunzipEveryWay(file.bytes, cuts: Array(stride(from: 0, to: file.bytes.count, by: 7_001)), outputChunk: 65_536) {
            #expect(result == .success(data), "\(name)")
        }
    }

    /// A first member large enough to decode in parallel, then more.
    @Test func parallelFirstMember() throws {
        let data = Array(largeSample().prefix(1 << 20))
        var encoder = ParallelDeflateEncoder(format: .gzip, level: 1, chunkSize: 64 << 10, lanes: 4, independentChunks: true)
        var first = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: data.count))
        let count = try first.withOutputRawSpan { span throws(BytesError) -> Int in
            try encoder.compressAll(data.span.bytes, into: &span)
            return span.byteCount
        }
        let stream = Array(first.prefix(count)) + Self.file.bytes
        var decoder = ParallelDeflateDecoder(format: .gzip, lanes: 4)
        var output = [UInt8](repeating: 0, count: data.count + Self.file.decoded.count)
        let consumed = try output.withOutputRawSpan { span throws(BytesError) -> Int in
            try decoder.decompressAll(stream.span.bytes, into: &span)
        }
        #expect(consumed == stream.count)
        #expect(output == data + Self.file.decoded)
        #expect(decoder.lastSegmentCount > 1)
    }

    /// After a member: another member's header, or the end. Anything else throws `invalidValue`, as soon as a byte
    /// shows it; a header cut short is truncation.
    @Test func bytesAfterAMember() {
        let member = Self.small.members[0]
        for garbage: [UInt8] in [[0], [1, 2, 3], [0x1F, 0x8C], [0x1F, 0x8B, 0x07], [0x1F, 0x8B, 0x08, 0xE0, 0, 0, 0, 0, 0, 3, 3, 0], Array(repeating: 0, count: 100)] {
            for (name, result) in gunzipEveryWay(member + garbage, cuts: [member.count]) {
                #expect(result == .failure(.invalidValue), "\(name), \(garbage.prefix(4))")
            }
        }
        for truncated: [UInt8] in [[0x1F], [0x1F, 0x8B, 0x08], [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0], Array(Self.small.members[1].dropLast(1))] {
            for (name, result) in gunzipEveryWay(member + truncated, cuts: [member.count]) {
                #expect(result == .failure(.insufficientData), "\(name), \(truncated.count) bytes")
            }
        }
    }

    /// The pipeline contract: a member's end reads as `needsInput` until `.finish`, then `.finished`, with no more
    /// input needed; `decompress` reports `.finished` there, and `isFinished` is true.
    @Test func endOfAMemberInPieces() throws {
        let member = Self.small.members[0]
        var decoder = DeflateDecoder(format: .gzip)
        var output = [UInt8](repeating: 0, count: 1 << 16)
        var progress = try output.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
            try decoder.transform(member.span.bytes, into: &span, flush: .none)
        }
        #expect(progress.status == .needsInput && progress.consumed == member.count)
        let finished = decoder.isFinished // `#expect` doesn't take a `~Copyable` value's property.
        #expect(finished)
        let empty: [UInt8] = []
        progress = try output.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
            try decoder.transform(empty.span.bytes, into: &span, flush: .finish)
        }
        #expect(progress == TransformProgress(consumed: 0, produced: 0, status: .finished))
        decoder.reset()
        progress = try output.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
            try decoder.decompress(member.span.bytes, into: &span)
        }
        #expect(progress.status == .finished && progress.consumed == member.count)
        progress = try output.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
            try decoder.decompress(empty.span.bytes, into: &span)
        }
        #expect(progress.status == .finished && progress.consumed == 0)
        // An empty input after the last member at `.finish`: through a pipeline whose first stage has finished.
        var pipeline = DeflateEncoder(format: .gzip).then(DeflateDecoder(format: .gzip))
        var decoded: [UInt8] = []
        let text = Self.small.payloads[0]
        let result = try pipeline.transform(text.span.bytes, appending: &decoded, flush: .finish)
        #expect(result.status == .finished && decoded == text)
    }

    /// Each member's CRC-32, length, and header CRC are checked.
    @Test func checksPerMember() {
        let file = Self.file
        let trailerCRC = file.members[0].count + file.members[1].count - 8 // The second member's CRC-32.
        let lengthByte = file.members[0..<3].map(\.count).reduce(0, +) - 1 // The third member's ISIZE.
        let headerCRC = file.members[0].count + file.members[1].count + 10 + 2 + 6 + 11 + 12 // The third's FHCRC.
        for offset in [trailerCRC, lengthByte, headerCRC] {
            var bytes = file.bytes
            bytes[offset] ^= 1
            for (name, result) in gunzipEveryWay(bytes, cuts: [offset]) {
                #expect(result == .failure(.mismatch), "\(name), byte \(offset)")
            }
        }
    }

    /// A member's matches reach only its own output: one copying from before its start throws, though the member
    /// before holds data there (and the trailer is right for that data).
    @Test func noMatchesIntoTheMemberBefore() {
        let first = Self.small.members.last! // Its data ends in "z".
        // A fixed-code block: a match of 3 at distance 1, then the end of the block.
        let reaching = gzipMember([0x03, 0x02, 0x00], of: Array("zzz".utf8))
        var decoder = DeflateDecoder(format: .gzip)
        #expect(gunzipAll(reaching, decoder: &decoder) == .failure(.invalidValue))
        for (name, result) in gunzipEveryWay(first + reaching, cuts: [first.count]) {
            #expect(result == .failure(.invalidValue), "\(name)")
        }
    }

    /// The latest member's header, at no cost to decoding: its fixed fields and which optional ones it has.
    @Test func headers() throws {
        // Read into constants: `#expect` and `#require` don't take a `~Copyable` value's property.
        var decoder = DeflateDecoder(format: .gzip)
        let none = decoder.gzipHeader
        #expect(none == nil)
        let file = Self.small
        #expect(gunzipAll(file.bytes, decoder: &decoder) == .success(file.decoded))
        let lastHeader = decoder.gzipHeader
        let last = try #require(lastHeader)
        #expect(last.hasName && !last.hasComment && !last.hasExtraField && !last.hasHeaderCRC && !last.isText)
        #expect(last.modificationTime == 12_345 && last.operatingSystem == 3)
        // Member by member.
        decoder.reset()
        let afterReset = decoder.gzipHeader
        #expect(afterReset == nil)
        var output = [UInt8](repeating: 0, count: 1 << 16)
        for (index, member) in file.members.enumerated() {
            _ = try output.withOutputRawSpan { span throws(BytesError) -> TransformProgress in
                try decoder.decompress(member.span.bytes, into: &span)
            }
            let memberHeader = decoder.gzipHeader
            let header = try #require(memberHeader)
            if index == 2 {
                #expect(header.hasName && header.hasComment && header.hasExtraField && header.hasHeaderCRC)
                #expect(header.modificationTime == 1_700_000_000)
            }
        }
        var raw = DeflateDecoder(format: .raw)
        _ = gunzipAll(zlibCompress(file.decoded), decoder: &raw)
        let rawHeader = raw.gzipHeader
        #expect(rawHeader == nil)
    }
}

@Suite(.bulk) struct GzipMembersBulkTests {
    /// 1 MB of text in 64 KB and 4 KB members, alternately Bytes' and zlib's, decoded every way with input in pieces of
    /// several sizes.
    @Test(arguments: [64 << 10, 4 << 10])
    func megabyteInMembers(memberSize: Int) {
        let data = Array(largeSample().prefix(1 << 20))
        var file = GzipFile()
        for (index, start) in stride(from: 0, to: data.count, by: memberSize).enumerated() {
            let part = Array(data[start..<min(start + memberSize, data.count)])
            file.append(index.isMultiple(of: 2) ? bytesGzip(part) : zlibCompress(part, format: .gzip), decodesTo: part)
        }
        #expect(Zlib.decompressMembers(file.bytes) == data)
        var rng = SplitMix64(seed: UInt64(memberSize))
        for pieces in [1, 10, 1_000] {
            let cuts = (0..<(pieces - 1)).map { _ in Int(rng.next() % UInt64(file.bytes.count)) }
            for (name, result) in gunzipEveryWay(file.bytes, cuts: cuts, outputChunk: 1 << 16) {
                #expect(result == .success(data), "\(name), \(pieces) pieces")
            }
        }
    }

    /// The small file cut into three pieces at every pair of points around member boundaries.
    @Test func threePiecesAroundBoundaries() {
        let file = GzipMembersTests.small
        let bytes = file.bytes
        var boundaries: [Int] = []
        var end = 0
        for member in file.members.dropLast() {
            end += member.count
            boundaries.append(end)
        }
        for boundary in boundaries {
            for first in max(0, boundary - 12)...min(bytes.count, boundary + 12) {
                for second in first...min(bytes.count, first + 24) {
                    for (name, result) in gunzipEveryWay(bytes, cuts: [first, second], outputChunk: 61, whole: false) {
                        #expect(result == .success(file.decoded), "\(name), cuts \(first), \(second)")
                    }
                }
            }
        }
    }
}
