import Benchmark
import Bytes
import BytesTestSupport
import CReferences
import Foundation
import HTTP2
import HTTPBytes
import NIOCore
import NIOHPACK

// HPACK (RFC 7541): HTTPBytes' decoder and encoder against ls-hpack and cursed-http (C) and swift-nio-http2's NIOHPACK (Swift
// today), each
// run as a connection would: one decoder or encoder for a sequence of field blocks sharing a 4,096-byte dynamic table.
// Per iteration: the whole corpus (401 request or 383 response field sets from http-corpus, or hpack-test-case's story 30:
// 646 responses), from a fresh table. HTTPBytes' decoder hands out views (names resolved to known names, nothing
// copied, characters checked once per literal); ls-hpack copies each field into a buffer; cursed-http hands out views
// with its characters checked; NIOHPACK builds `HPACKHeaders` of strings. Every setup checks every
// block: its field count, and for HTTPBytes and the encoders, every name and value.

// MARK: - Fixtures

/// Field sets, in every form the coders take, and blocks to decode.
final class HPACKFixture: @unchecked Sendable {
    /// Each set's fields, as bytes.
    let sets: [[(name: [UInt8], value: [UInt8])]]
    /// Each set as an HTTPBytes field store.
    let stores: [HTTPFieldStore]
    /// Each set as NIOHPACK's headers.
    let nioHeaders: [HPACKHeaders]
    /// For ls-hpack: every field's name then value, one after another; per field its offset, name length, value length;
    /// where each set's fields end.
    let flat: [UInt8]
    let offsets: [UInt32]
    let setEnds: [Int]
    /// Blocks to decode, one after another, block i ending at `blockEnds[i]`; as NIO buffers; and each block's field
    /// count.
    let blocks: [UInt8]
    let blockEnds: [Int]
    let nioBlocks: [NIOCore.ByteBuffer]
    let fieldCounts: [Int32]

    /// Sets, with `blocks` encoded from them by `encoded` (or HTTPBytes' encoder if `nil`).
    init(sets: [[(name: [UInt8], value: [UInt8])]], encoded: [[UInt8]]? = nil) {
        self.sets = sets
        stores = sets.map { set in
            var store = HTTPFieldStore()
            for (name, value) in set {
                // As a decoder would store them: unchecked (some of the story's values aren't valid HTTP/1 values).
                let view = HTTPFieldView(name: name.span.bytes, value: value.span.bytes, knownName: HTTPFieldName(lowercase: name.span.bytes))
                try! store.append(view)
            }
            return store
        }
        nioHeaders = sets.map { set in HPACKHeaders(set.map { (String(decoding: $0.name, as: UTF8.self), String(decoding: $0.value, as: UTF8.self)) }) }
        var flat: [UInt8] = [], offsets: [UInt32] = [], setEnds: [Int] = []
        for set in sets {
            for (name, value) in set {
                offsets += [UInt32(flat.count), UInt32(name.count), UInt32(value.count)]
                flat += name + value
            }
            setEnds.append(offsets.count / 3)
        }
        self.flat = flat
        self.offsets = offsets
        self.setEnds = setEnds
        let encodedBlocks = encoded ?? hpackEncodeEach(sets: stores)
        blocks = encodedBlocks.flatMap { $0 }
        var end = 0
        blockEnds = encodedBlocks.map { end += $0.count; return end }
        nioBlocks = encodedBlocks.map { NIOCore.ByteBuffer(bytes: $0) }
        fieldCounts = sets.map { Int32($0.count) }
    }

    /// A QIF file of http-corpus: `name TAB value` lines, a blank line between sets.
    convenience init(qif file: String) {
        let url = try! TestData.file(set: "http-corpus", name: file)
        let text = try! String(contentsOf: url, encoding: .utf8)
        var sets: [[(name: [UInt8], value: [UInt8])]] = [], current: [(name: [UInt8], value: [UInt8])] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if !current.isEmpty { sets.append(current) }
                current = []
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            current.append((Array(parts[0].utf8), parts.count > 1 ? Array(parts[1].utf8) : []))
        }
        if !current.isEmpty { sets.append(current) }
        self.init(sets: sets)
    }

    /// An hpack-test-case story: the sets from raw-data, the blocks as `encoder` (a directory) encoded them.
    convenience init(story: String, encoder: String) {
        func load(_ directory: String) -> [[String: Any]] {
            let url = try! TestData.file(set: "hpack-test-case", name: "\(directory)/\(story)")
            return (try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["cases"] as! [[String: Any]]
        }
        let sets = load("raw-data").map { item in
            (item["headers"] as! [[String: String]]).map { pair in (name: Array(pair.keys.first!.utf8), value: Array(pair.values.first!.utf8)) }
        }
        let wire = load(encoder).map { hexadecimal($0["wire"] as! String) }
        self.init(sets: sets, encoded: wire)
    }
}

func hexadecimal(_ text: String) -> [UInt8] {
    let digits = Array(text.utf8)
    func value(_ digit: UInt8) -> UInt8 { digit <= 0x39 ? digit - 0x30 : (digit | 0x20) - 0x61 + 10 }
    return stride(from: 0, to: digits.count, by: 2).map { value(digits[$0]) << 4 | value(digits[$0 + 1]) }
}

/// HTTPBytes' encoder's blocks for `sets`, one connection.
func hpackEncodeEach(sets: [HTTPFieldStore]) -> [[UInt8]] {
    var encoder = HTTP2.HPACKEncoder()
    // Every field, as the C and NIO encoders take them (the corpora have `connection` fields).
    encoder.removesConnectionSpecificFields = false
    var output = [UInt8](repeating: 0, count: 1 << 16)
    return sets.map { store in
        let written = try! output.withOutputRawSpan { (span) throws(HPACKError) -> Int in
            try encoder.encode(store, into: &span)
            return span.byteCount
        }
        return Array(output[0..<written])
    }
}

let hpackRequests = Lazy { HPACKFixture(qif: "requests.qif") }
let hpackResponses = Lazy { HPACKFixture(qif: "responses.qif") }
let hpackStory = Lazy { HPACKFixture(story: "story_30.json", encoder: "nghttp2") }

/// Coders made once, reset per iteration (a new connection's state with no allocation).
nonisolated(unsafe) var sharedDecoder = HTTP2.HPACKDecoder()
nonisolated(unsafe) var sharedEncoder: HTTP2.HPACKEncoder = {
    // Every field, as the C and NIO encoders take them (the corpora have `connection` fields).
    var encoder = HTTP2.HPACKEncoder()
    encoder.removesConnectionSpecificFields = false
    return encoder
}()
nonisolated(unsafe) var encoderOutput = [UInt8](repeating: 0, count: 1 << 20)
nonisolated(unsafe) var nioOutput = ByteBufferAllocator().buffer(capacity: 1 << 20)
nonisolated(unsafe) var lshpackOutput = [UInt8](repeating: 0, count: 1 << 20)
nonisolated(unsafe) var lshpackBlockEnds = [Int](repeating: 0, count: 4_096)

// MARK: - Workloads

/// HTTPBytes: every block's fields as views; each value's length and known name summed (so nothing is optimized away).
/// Returns -1 if a block fails or has the wrong number of fields.
@inline(never)
func hpackDecodeHTTPBytes(_ fixture: HPACKFixture, _ decoder: inout HTTP2.HPACKDecoder) -> Int {
    decoder.reset()
    let blocks = fixture.blocks          // a local: a span of a class's stored array lasts only for the access
    let all = blocks.span.bytes
    var start = 0
    var total = 0
    do throws(HPACKError) {
        for (index, end) in fixture.blockEnds.enumerated() {
            let block = all.extracting(start..<end)
            var count: Int32 = 0
            while let field = try decoder.next(in: block) {
                total &+= field.value.byteCount &+ field.name.byteCount &+ Int(field.knownName?.index ?? 0)
                count &+= 1
            }
            if count != fixture.fieldCounts[index] { return -1 }
            start = end
        }
    } catch { return -1 }
    return total
}

/// HTTPBytes, as a server or client takes a field section: decoded, then checked by RFC 9113 §8.2–8.3 (characters,
/// connection-specific fields, pseudo-header fields). -1 if decoding fails.
@inline(never)
func hpackDecodeAndValidate(_ fixture: HPACKFixture, _ decoder: inout HTTP2.HPACKDecoder, _ section: HTTP2FieldValidator.Section) -> Int {
    decoder.reset()
    let blocks = fixture.blocks
    let all = blocks.span.bytes
    var start = 0
    var total = 0
    do {
        for end in fixture.blockEnds {
            let block = all.extracting(start..<end)
            var validator = HTTP2FieldValidator(section)
            var malformed = false
            while let field = try decoder.next(in: block) {
                // A malformed section (the corpora have some `connection` fields) is a stream error: its block is still
                // decoded, to keep the table.
                if !malformed {
                    do throws(HTTP2FieldError) { try validator.check(field) } catch { malformed = true }
                }
                total &+= field.value.byteCount
            }
            if !malformed, let seen = try? validator.finish() { total &+= Int(seen.present) }
            start = end
        }
    } catch { return -1 }
    return total
}

/// A C decoder over every block: ls-hpack (every field copied into a buffer) or cursed-http (views, characters checked).
typealias HPACKCDecoder = @convention(c) (UnsafePointer<UInt8>?, UnsafePointer<Int>?, UnsafePointer<Int32>?, Int) -> Int
typealias HPACKCEncoder = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UInt32>?, UnsafePointer<Int>?, Int, UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?) -> Int

@inline(never)
func hpackDecodeC(_ fixture: HPACKFixture, _ decode: HPACKCDecoder) -> Int {
    fixture.blocks.withUnsafeBufferPointer { blocks in
        fixture.blockEnds.withUnsafeBufferPointer { ends in
            fixture.fieldCounts.withUnsafeBufferPointer { counts in
                decode(blocks.baseAddress, ends.baseAddress, counts.baseAddress, ends.count)
            }
        }
    }
}

/// NIOHPACK: every block into `HPACKHeaders`.
@inline(never)
func hpackDecodeNIO(_ fixture: HPACKFixture) -> Int {
    var decoder = NIOHPACK.HPACKDecoder(allocator: ByteBufferAllocator())
    var total = 0
    do {
        for (index, block) in fixture.nioBlocks.enumerated() {
            var buffer = block
            let headers = try decoder.decodeHeaders(from: &buffer)
            if headers.count != Int(fixture.fieldCounts[index]) { return -1 }
            total &+= headers.count
        }
    } catch { return -1 }
    return total
}

/// HTTPBytes: every set into one output buffer; the bytes written.
@inline(never)
func hpackEncodeHTTPBytes(_ fixture: HPACKFixture, _ encoder: inout HTTP2.HPACKEncoder, _ output: inout [UInt8],
                          blockEnds: UnsafeMutableBufferPointer<Int>? = nil) -> Int {
    encoder.reset()
    do throws(HPACKError) {
        return try output.withOutputRawSpan { (span) throws(HPACKError) -> Int in
            for (index, store) in fixture.stores.enumerated() {
                try encoder.encode(store, into: &span)
                blockEnds?[index] = span.byteCount
            }
            return span.byteCount
        }
    } catch { return -1 }
}

/// A C encoder: every set into one output buffer.
@inline(never)
func hpackEncodeC(_ fixture: HPACKFixture, _ encode: HPACKCEncoder, _ output: inout [UInt8], _ blockEnds: inout [Int]) -> Int {
    fixture.flat.withUnsafeBufferPointer { flat in
        fixture.offsets.withUnsafeBufferPointer { offsets in
            fixture.setEnds.withUnsafeBufferPointer { setEnds in
                output.withUnsafeMutableBufferPointer { out in
                    blockEnds.withUnsafeMutableBufferPointer { ends in
                        flat.withMemoryRebound(to: CChar.self) { chars in
                            encode(chars.baseAddress, offsets.baseAddress, setEnds.baseAddress, setEnds.count,
                                                out.baseAddress, out.count, ends.baseAddress)
                        }
                    }
                }
            }
        }
    }
}

/// NIOHPACK: every set into one reused buffer.
@inline(never)
func hpackEncodeNIO(_ fixture: HPACKFixture, _ output: inout NIOCore.ByteBuffer, blockEnds: UnsafeMutableBufferPointer<Int>? = nil) -> Int {
    var encoder = NIOHPACK.HPACKEncoder(allocator: ByteBufferAllocator())
    output.clear()
    do {
        for (index, headers) in fixture.nioHeaders.enumerated() {
            try encoder.encode(headers: headers, to: &output)
            blockEnds?[index] = output.readableBytes
        }
    } catch { return -1 }
    return output.readableBytes
}

// MARK: - Checks

/// Whether `bytes`, split at `ends`, decode (by HTTPBytes' decoder, one connection) to the fixture's sets exactly.
func hpackBlocksDecode(_ bytes: [UInt8], ends: [Int], to fixture: HPACKFixture) -> Bool {
    guard ends.count == fixture.sets.count else { return false }
    var decoder = HTTP2.HPACKDecoder()
    var start = 0
    for (index, end) in ends.enumerated() {
        guard end >= start, end <= bytes.count else { return false }
        let block = Array(bytes[start..<end])
        let span = block.span.bytes
        var fields: [(name: [UInt8], value: [UInt8])] = []
        do throws(HPACKError) {
            while let field = try decoder.next(in: span) { fields.append((Array(copying: field.name), Array(copying: field.value))) }
        } catch { return false }
        let expected = fixture.sets[index]
        guard fields.count == expected.count, zip(fields, expected).allSatisfy({ $0.name == $1.name && $0.value == $1.value }) else {
            return false
        }
        start = end
    }
    return true
}

/// HTTPBytes' decoder gives every block's fields exactly.
func hpackDecodesExactly(_ fixture: HPACKFixture) -> Int {
    hpackBlocksDecode(fixture.blocks, ends: fixture.blockEnds, to: fixture) && hpackDecodeHTTPBytes(fixture, &sharedDecoder) > 0 ? 1 : 0
}

/// NIOHPACK's decoder gives every block's fields exactly.
func hpackNIODecodesExactly(_ fixture: HPACKFixture) -> Int {
    var decoder = NIOHPACK.HPACKDecoder(allocator: ByteBufferAllocator())
    for (index, block) in fixture.nioBlocks.enumerated() {
        var buffer = block
        guard let headers = try? decoder.decodeHeaders(from: &buffer) else { return 0 }
        let expected = fixture.sets[index]
        guard headers.count == expected.count,
              zip(headers, expected).allSatisfy({ Array($0.name.utf8) == $1.name && Array($0.value.utf8) == $1.value }) else { return 0 }
    }
    return 1
}

/// The encoded size, on standard error (setup only): an encoder's speed means little without its compression.
func reportEncodedSize(_ encoder: String, _ corpus: String, _ bytes: Int) {
    FileHandle.standardError.write(Data("HPACK encoded size (\(corpus)): \(encoder) \(bytes) B\n".utf8))
}

// MARK: - Benchmarks

func registerHPACKBenchmarks() {
    func register(_ name: String, setup: @escaping () -> Int, _ run: @escaping () -> Int) {
        Benchmark(name) { benchmark in
            for _ in benchmark.scaledIterations { blackHole(run()) }
        } setup: {
            precondition(setup() > 0, "\(name): failed")
        }
    }

    let corpora = [("401 requests", hpackRequests), ("383 responses", hpackResponses), ("hpack-test-case story 30, 646 responses", hpackStory)]
    for (label, fixture) in corpora {
        register("HPACK decode (\(label)): HTTPBytes", setup: { hpackDecodesExactly(fixture.value) }) {
            hpackDecodeHTTPBytes(fixture.value, &sharedDecoder)
        }
        let section: HTTP2FieldValidator.Section = label.contains("request") ? .request : .response
        register("HPACK decode and validate (\(label)): HTTPBytes", setup: { hpackDecodeAndValidate(fixture.value, &sharedDecoder, section) }) {
            hpackDecodeAndValidate(fixture.value, &sharedDecoder, section)
        }
        // The C decoders check each block's field count themselves; every byte is checked by HTTPBytes' setup.
        for (reference, decode) in [("ls-hpack", lshpack_decode_blocks), ("cursed-http", cursed_hpack_decode_blocks)] as [(String, HPACKCDecoder)] {
            register("HPACK decode (\(label)): \(reference)", setup: { hpackDecodesExactly(fixture.value) &* (hpackDecodeC(fixture.value, decode) > 0 ? 1 : 0) }) {
                hpackDecodeC(fixture.value, decode)
            }
        }
        register("HPACK decode (\(label)): NIOHPACK", setup: { hpackNIODecodesExactly(fixture.value) }) {
            hpackDecodeNIO(fixture.value)
        }

        register("HPACK encode (\(label)): HTTPBytes", setup: {
            let fixture = fixture.value
            var ends = [Int](repeating: 0, count: fixture.sets.count)
            let written = ends.withUnsafeMutableBufferPointer { hpackEncodeHTTPBytes(fixture, &sharedEncoder, &encoderOutput, blockEnds: $0) }
            reportEncodedSize("HTTPBytes", label, written)
            return written > 0 && hpackBlocksDecode(Array(encoderOutput[0..<written]), ends: ends, to: fixture) ? 1 : 0
        }) {
            hpackEncodeHTTPBytes(fixture.value, &sharedEncoder, &encoderOutput)
        }
        for (reference, encode) in [("ls-hpack", lshpack_encode_sets), ("cursed-http", cursed_hpack_encode_sets)] as [(String, HPACKCEncoder)] {
            register("HPACK encode (\(label)): \(reference)", setup: {
                let fixture = fixture.value
                let written = hpackEncodeC(fixture, encode, &lshpackOutput, &lshpackBlockEnds)
                reportEncodedSize(reference, label, written)
                return written > 0 && hpackBlocksDecode(Array(lshpackOutput[0..<written]), ends: Array(lshpackBlockEnds[0..<fixture.sets.count]), to: fixture) ? 1 : 0
            }) {
                hpackEncodeC(fixture.value, encode, &lshpackOutput, &lshpackBlockEnds)
            }
        }
        register("HPACK encode (\(label)): NIOHPACK", setup: {
            let fixture = fixture.value
            var ends = [Int](repeating: 0, count: fixture.sets.count)
            let written = ends.withUnsafeMutableBufferPointer { hpackEncodeNIO(fixture, &nioOutput, blockEnds: $0) }
            reportEncodedSize("NIOHPACK", label, written)
            return written > 0 && hpackBlocksDecode(Array(nioOutput.readableBytesView), ends: ends, to: fixture) ? 1 : 0
        }) {
            hpackEncodeNIO(fixture.value, &nioOutput)
        }
    }

    // Allocation gates: HTTPBytes' decoding and encoding allocate nothing once the coder and output exist.
    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    let gates: [(String, () -> Int)] = [
        ("Allocations:HPACK_decode_requests", { hpackDecodeHTTPBytes(hpackRequests.value, &sharedDecoder) }),
        ("Allocations:HPACK_decode_responses", { hpackDecodeHTTPBytes(hpackResponses.value, &sharedDecoder) }),
        ("Allocations:HPACK_encode_requests", { hpackEncodeHTTPBytes(hpackRequests.value, &sharedEncoder, &encoderOutput) }),
        ("Allocations:HPACK_encode_responses", { hpackEncodeHTTPBytes(hpackResponses.value, &sharedEncoder, &encoderOutput) }),
    ]
    for (name, run) in gates {
        Benchmark(name, configuration: zeroAllocations) { benchmark in
            for _ in benchmark.scaledIterations { blackHole(run()) }
        } setup: {
            precondition(run() > 0, "\(name): failed")
        }
    }
}
