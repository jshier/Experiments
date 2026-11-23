import Benchmark
import Bytes
import BytesTestSupport
import CReferences
import Foundation
import HTTP3
import HTTPBytes

// QPACK (RFC 9204): HTTPBytes' decoder and encoder against ls-qpack and cursed-http (C), each run as a connection
// would: one decoder or encoder for a sequence of field sections, the encoder stream's instructions delivered before
// each section, each section that used the dynamic table acknowledged at once (the encoders take the peer's Section
// Acknowledgment; the decoders write their decoder stream). Per iteration: the whole corpus (http-corpus' 401 request
// or 383 response field sets, static only or with a 4,096-byte table; or qifs' fb-resp-hq as nghttp3 encoded it, 4,096
// bytes, never blocking), from a fresh table. HTTPBytes' decoder hands out views (names resolved to known names,
// characters checked once per literal); ls-qpack copies each field into a buffer; cursed-http hands out views with its
// characters checked. Every setup checks every section: HTTPBytes' decoder must give every field of every section byte
// for byte (of its own encoder's output and of each C encoder's), and each C decoder must give every section's field
// count and the corpus' total bytes.

// MARK: - Fixtures

/// Field sets, in every form the coders take, and a connection's bytes to decode.
final class QPACKFixture: @unchecked Sendable {
    /// Each set's fields, as bytes.
    let sets: [[(name: [UInt8], value: [UInt8])]]
    /// Each set as an HTTPBytes field store.
    let stores: [HTTPFieldStore]
    /// For the C encoders: every field's name then value, one after another; per field its offset, name length, value
    /// length; where each set's fields end.
    let flat: [UInt8]
    let offsets: [UInt32]
    let setEnds: [Int]
    /// The table capacity (0: static only).
    let capacity: Int
    /// A connection to decode: section i's instructions end at `instructionEnds[i]`, its section at `sectionEnds[i]`.
    let bytes: [UInt8]
    let instructionEnds: [Int]
    let sectionEnds: [Int]
    let fieldCounts: [Int32]
    /// The fields' bytes (names and values), which the C decoders return.
    let total: Int
    /// Each set's Section Acknowledgment (stream 4i): bytes, set i's ending at `acknowledgmentEnds[i]`.
    let acknowledgments: [UInt8]
    let acknowledgmentEnds: [Int]

    /// Sets, with the connection's bytes as `encoded` gives them (or HTTPBytes' encoder if `nil`).
    init(sets: [[(name: [UInt8], value: [UInt8])]], capacity: Int, encoded: (bytes: [UInt8], instructionEnds: [Int], sectionEnds: [Int])? = nil) {
        self.sets = sets
        self.capacity = capacity
        stores = sets.map { set in
            var store = HTTPFieldStore()
            for (name, value) in set {
                let view = HTTPFieldView(name: name.span.bytes, value: value.span.bytes, knownName: HTTPFieldName(lowercase: name.span.bytes))
                try! store.append(view)
            }
            return store
        }
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
        fieldCounts = sets.map { Int32($0.count) }
        total = sets.reduce(0) { $0 + $1.reduce(0) { $0 + $1.name.count + $1.value.count } }
        var acknowledgments: [UInt8] = [], acknowledgmentEnds: [Int] = []
        for index in sets.indices {
            var ack = [UInt8](repeating: 0, count: 16)
            let n = ack.withOutputRawSpan { (span) -> Int in
                try! HPACKPrefixInteger.write(index * 4, prefixBits: 7, flags: 0x80, into: &span)
                return span.byteCount
            }
            acknowledgments += ack[0..<n]
            acknowledgmentEnds.append(acknowledgments.count)
        }
        self.acknowledgments = acknowledgments
        self.acknowledgmentEnds = acknowledgmentEnds
        let connection = encoded ?? qpackEncodeConnection(sets: stores, capacity: capacity, acknowledgments: acknowledgments, ends: acknowledgmentEnds)
        bytes = connection.bytes
        instructionEnds = connection.instructionEnds
        sectionEnds = connection.sectionEnds
    }

    /// An http-corpus QIF file.
    convenience init(qif file: String, capacity: Int) {
        let url = try! TestData.file(set: "http-corpus", name: file)
        self.init(sets: qifSets(try! String(contentsOf: url, encoding: .isoLatin1)), capacity: capacity)
    }

    /// A qifs interop file (offline interop format) and its QIF file: sections in the file's order, each after the
    /// encoder stream bytes that precede it. The file must never block (blocked streams 0). The corpus' encoders started
    /// with the table at its maximum capacity (a draft before Set Dynamic Table Capacity): that instruction comes first.
    convenience init(interop path: String, qif: String, capacity: Int) {
        let text = try! String(contentsOf: TestData.file(set: "qifs", name: "qifs/\(qif).qif"), encoding: .isoLatin1)
        let all = qifSets(text)
        let data = try! [UInt8](Data(contentsOf: TestData.file(set: "qifs", name: "encoded/\(path)")))
        var bytes: [UInt8] = [], instructionEnds: [Int] = [], sectionEnds: [Int] = [], sets: [[(name: [UInt8], value: [UInt8])]] = []
        var capacityInstruction = [UInt8](repeating: 0, count: 8)
        let n = capacityInstruction.withOutputRawSpan { (span) -> Int in
            try! HPACKPrefixInteger.write(capacity, prefixBits: 5, flags: 0x20, into: &span)
            return span.byteCount
        }
        bytes += capacityInstruction[0..<n]
        var offset = 0
        while offset + 12 <= data.count {
            let stream = data[offset..<offset + 8].reduce(0) { $0 << 8 | Int($1) }
            let length = data[offset + 8..<offset + 12].reduce(0) { $0 << 8 | Int($1) }
            let record = data[offset + 12..<offset + 12 + length]
            offset += 12 + length
            if stream == 0 {
                bytes += record
            } else {
                instructionEnds.append(bytes.count)
                bytes += record
                sectionEnds.append(bytes.count)
                sets.append(all[stream - 1])
            }
        }
        self.init(sets: sets, capacity: capacity, encoded: (bytes, instructionEnds, sectionEnds))
    }
}

/// QIF text's field sets: `name TAB value` lines, a blank line between sets, `#` comments.
func qifSets(_ text: String) -> [[(name: [UInt8], value: [UInt8])]] {
    var sets: [[(name: [UInt8], value: [UInt8])]] = [], current: [(name: [UInt8], value: [UInt8])] = []
    func bytes(_ text: Substring) -> [UInt8] { text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("#") { continue }
        if line.isEmpty {
            if !current.isEmpty { sets.append(current) }
            current = []
            continue
        }
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        current.append((bytes(parts[0]), parts.count > 1 ? bytes(parts[1]) : []))
    }
    if !current.isEmpty { sets.append(current) }
    return sets
}

/// HTTPBytes' encoder's connection for `sets`: each section after its instructions, acknowledged at once.
func qpackEncodeConnection(sets: [HTTPFieldStore], capacity: Int, acknowledgments: [UInt8], ends: [Int])
    -> (bytes: [UInt8], instructionEnds: [Int], sectionEnds: [Int]) {
    var encoder = QPACKEncoder(maximumTableCapacity: capacity)
    if capacity > 0 { encoder.setPeerSettings(maximumTableCapacity: UInt64(capacity), blockedStreams: 100) }
    var bytes: [UInt8] = [], instructionEnds: [Int] = [], sectionEnds: [Int] = []
    var section = [UInt8](repeating: 0, count: 1 << 16), instructions = [UInt8](repeating: 0, count: 1 << 16)
    var ackStart = 0
    for (index, store) in sets.enumerated() {
        var instructionCount = 0
        let sectionCount = try! section.withOutputRawSpan { (sectionSpan) throws(QPACKError) -> Int in
            try instructions.withOutputRawSpan { (instructionSpan) throws(QPACKError) -> Int in
                try encoder.encode(store, stream: UInt64(index * 4), into: &sectionSpan, instructions: &instructionSpan)
                instructionCount = instructionSpan.byteCount
                return sectionSpan.byteCount
            }
        }
        bytes += instructions[0..<instructionCount]
        instructionEnds.append(bytes.count)
        bytes += section[0..<sectionCount]
        sectionEnds.append(bytes.count)
        if encoder.unacknowledgedSectionCount > 0 {
            _ = try! encoder.processDecoderStream(Array(acknowledgments[ackStart..<ends[index]]).span.bytes)
        }
        ackStart = ends[index]
    }
    return (bytes, instructionEnds, sectionEnds)
}

let qpackRequestsStatic = Lazy { QPACKFixture(qif: "requests.qif", capacity: 0) }
let qpackResponsesStatic = Lazy { QPACKFixture(qif: "responses.qif", capacity: 0) }
let qpackRequestsDynamic = Lazy { QPACKFixture(qif: "requests.qif", capacity: 4_096) }
let qpackResponsesDynamic = Lazy { QPACKFixture(qif: "responses.qif", capacity: 4_096) }
let qpackInterop = Lazy { QPACKFixture(interop: "qpack-05/nghttp3/fb-resp-hq.out.4096.0.1", qif: "fb-resp-hq", capacity: 4_096) }

/// Coders made once, reset per iteration (a new connection's state with no allocation).
nonisolated(unsafe) var sharedQPACKDecoder = QPACKDecoder(maximumTableCapacity: 4_096)
nonisolated(unsafe) var sharedQPACKStaticEncoder = QPACKEncoder(maximumTableCapacity: 0)
nonisolated(unsafe) var sharedQPACKDynamicEncoder: QPACKEncoder = {
    var encoder = QPACKEncoder(maximumTableCapacity: 4_096)
    encoder.setPeerSettings(maximumTableCapacity: 4_096, blockedStreams: 100)
    return encoder
}()
nonisolated(unsafe) var qpackFeedback = [UInt8](repeating: 0, count: 4_096)
nonisolated(unsafe) var qpackSectionOutput = [UInt8](repeating: 0, count: 1 << 20)
nonisolated(unsafe) var qpackInstructionOutput = [UInt8](repeating: 0, count: 1 << 20)
nonisolated(unsafe) var qpackCOutput = [UInt8](repeating: 0, count: 1 << 21)
nonisolated(unsafe) var qpackCInstructionEnds = [Int](repeating: 0, count: 4_096)
nonisolated(unsafe) var qpackCSectionEnds = [Int](repeating: 0, count: 4_096)

// MARK: - Workloads

/// HTTPBytes: every section's fields as views; each value's and name's length and known name summed (so nothing is
/// optimized away); the decoder stream written after each section. Returns -1 if a section fails, blocks, or has the
/// wrong number of fields.
@inline(never)
func qpackDecodeHTTPBytes(_ fixture: QPACKFixture, _ decoder: inout QPACKDecoder, _ feedback: inout [UInt8]) -> Int {
    decoder.reset()
    let bytes = fixture.bytes          // a local: a span of a class's stored array lasts only for the access
    let all = bytes.span.bytes
    var start = 0
    var total = 0
    do throws(QPACKError) {
        for index in 0..<fixture.sectionEnds.count {
            let instructionEnd = fixture.instructionEnds[index]
            if instructionEnd > start {
                guard try decoder.processEncoderStream(all.extracting(start..<instructionEnd)) == instructionEnd &- start else { return -1 }
            }
            let section = all.extracting(instructionEnd..<fixture.sectionEnds[index])
            guard try decoder.begin(section, stream: UInt64(index &* 4)) else { return -1 }
            var count: Int32 = 0
            while let field = try decoder.next(in: section) {
                total &+= field.value.byteCount &+ field.name.byteCount &+ Int(field.knownName?.index ?? 0)
                count &+= 1
            }
            if count != fixture.fieldCounts[index] { return -1 }
            if decoder.hasDecoderInstructions {
                feedback.withOutputRawSpan { (span) -> Void in decoder.writeDecoderInstructions(into: &span) }
            }
            start = fixture.sectionEnds[index]
        }
    } catch { return -1 }
    return total
}

/// HTTPBytes: every set into one section output and one encoder stream output, each section that used the table
/// acknowledged at once; the bytes written. `instructionEnds` and `sectionEnds` get each set's ends in the two outputs.
@inline(never)
func qpackEncodeHTTPBytes(_ fixture: QPACKFixture, _ encoder: inout QPACKEncoder, _ sections: inout [UInt8], _ instructions: inout [UInt8],
                          instructionEnds: UnsafeMutableBufferPointer<Int>? = nil, sectionEnds: UnsafeMutableBufferPointer<Int>? = nil) -> Int {
    encoder.reset()
    let acknowledgments = fixture.acknowledgments
    let acknowledgmentBytes = acknowledgments.span.bytes
    do throws(QPACKError) {
        return try sections.withOutputRawSpan { (sectionSpan) throws(QPACKError) -> Int in
            try instructions.withOutputRawSpan { (instructionSpan) throws(QPACKError) -> Int in
                var ackStart = 0
                for (index, store) in fixture.stores.enumerated() {
                    try encoder.encode(store, stream: UInt64(index &* 4), into: &sectionSpan, instructions: &instructionSpan)
                    let ackEnd = fixture.acknowledgmentEnds[index]
                    if encoder.unacknowledgedSectionCount > 0 {
                        _ = try encoder.processDecoderStream(acknowledgmentBytes.extracting(ackStart..<ackEnd))
                    }
                    ackStart = ackEnd
                    instructionEnds?[index] = instructionSpan.byteCount
                    sectionEnds?[index] = sectionSpan.byteCount
                }
                return sectionSpan.byteCount &+ instructionSpan.byteCount
            }
        }
    } catch { return -1 }
}

typealias QPACKCDecoder = @convention(c) (UnsafePointer<UInt8>?, UnsafePointer<Int>?, UnsafePointer<Int>?, UnsafePointer<Int32>?, Int, UInt32) -> Int
typealias QPACKCEncoder = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UInt32>?, UnsafePointer<Int>?, Int, UInt32,
                                          UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int>?) -> Int

/// A C decoder over the connection.
@inline(never)
func qpackDecodeC(_ fixture: QPACKFixture, _ decode: QPACKCDecoder) -> Int {
    fixture.bytes.withUnsafeBufferPointer { bytes in
        fixture.instructionEnds.withUnsafeBufferPointer { instructionEnds in
            fixture.sectionEnds.withUnsafeBufferPointer { sectionEnds in
                fixture.fieldCounts.withUnsafeBufferPointer { counts in
                    decode(bytes.baseAddress, instructionEnds.baseAddress, sectionEnds.baseAddress, counts.baseAddress, sectionEnds.count,
                           UInt32(fixture.capacity))
                }
            }
        }
    }
}

/// A C encoder: every set into one output, each section after its instructions.
@inline(never)
func qpackEncodeC(_ fixture: QPACKFixture, _ encode: QPACKCEncoder, _ output: inout [UInt8], _ instructionEnds: inout [Int],
                  _ sectionEnds: inout [Int]) -> Int {
    fixture.flat.withUnsafeBufferPointer { flat in
        fixture.offsets.withUnsafeBufferPointer { offsets in
            fixture.setEnds.withUnsafeBufferPointer { setEnds in
                output.withUnsafeMutableBufferPointer { out in
                    instructionEnds.withUnsafeMutableBufferPointer { instructionEnds in
                        sectionEnds.withUnsafeMutableBufferPointer { sectionEnds in
                            flat.withMemoryRebound(to: CChar.self) { chars in
                                encode(chars.baseAddress, offsets.baseAddress, setEnds.baseAddress, setEnds.count, UInt32(fixture.capacity),
                                       out.baseAddress, out.count, instructionEnds.baseAddress, sectionEnds.baseAddress)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Checks

/// Whether a connection's bytes (each section after its instructions) decode, by HTTPBytes' decoder, to the fixture's
/// sets exactly.
func qpackConnectionDecodes(_ bytes: [UInt8], instructionEnds: [Int], sectionEnds: [Int], to fixture: QPACKFixture) -> Bool {
    guard sectionEnds.count == fixture.sets.count else { return false }
    var decoder = QPACKDecoder(maximumTableCapacity: Swift.max(fixture.capacity, 1), maximumBlockedStreams: 0)
    var feedback = [UInt8](repeating: 0, count: 4_096)
    var start = 0
    for (index, end) in sectionEnds.enumerated() {
        let instructionEnd = instructionEnds[index]
        guard start <= instructionEnd, instructionEnd <= end, end <= bytes.count else { return false }
        let instructions = Array(bytes[start..<instructionEnd]), section = Array(bytes[instructionEnd..<end])
        var fields: [(name: [UInt8], value: [UInt8])] = []
        do throws(QPACKError) {
            guard try decoder.processEncoderStream(instructions.span.bytes) == instructions.count else { return false }
            let span = section.span.bytes
            guard try decoder.begin(span, stream: UInt64(index * 4)) else { return false }
            while let field = try decoder.next(in: span) { fields.append((Array(copying: field.name), Array(copying: field.value))) }
        } catch { return false }
        feedback.withOutputRawSpan { (span) -> Void in decoder.writeDecoderInstructions(into: &span) }
        let expected = fixture.sets[index]
        guard fields.count == expected.count, zip(fields, expected).allSatisfy({ $0.name == $1.name && $0.value == $1.value }) else {
            return false
        }
        start = end
    }
    return true
}

/// The encoded size, on standard error (setup only): an encoder's speed means little without its compression.
func reportQPACKSize(_ encoder: String, _ corpus: String, _ bytes: Int) {
    FileHandle.standardError.write(Data("QPACK encoded size (\(corpus)): \(encoder) \(bytes) B\n".utf8))
}

// MARK: - Benchmarks

func registerQPACKBenchmarks() {
    func register(_ name: String, setup: @escaping () -> Int, _ run: @escaping () -> Int) {
        Benchmark(name) { benchmark in
            for _ in benchmark.scaledIterations { blackHole(run()) }
        } setup: {
            precondition(setup() > 0, "\(name): failed")
        }
    }

    let decoders = [("ls-qpack", lsqpack_decode_sections), ("cursed-http", cursed_qpack_decode_sections)] as [(String, QPACKCDecoder)]
    let corpora = [
        ("401 requests, static", qpackRequestsStatic), ("383 responses, static", qpackResponsesStatic),
        ("401 requests, 4,096 table", qpackRequestsDynamic), ("383 responses, 4,096 table", qpackResponsesDynamic),
        ("qifs fb-resp-hq by nghttp3, 4,096 table", qpackInterop),
    ]
    for (label, fixture) in corpora {
        register("QPACK decode (\(label)): HTTPBytes", setup: {
            let fixture = fixture.value
            let exact = qpackConnectionDecodes(fixture.bytes, instructionEnds: fixture.instructionEnds, sectionEnds: fixture.sectionEnds, to: fixture)
            return exact && qpackDecodeHTTPBytes(fixture, &sharedQPACKDecoder, &qpackFeedback) > 0 ? 1 : 0
        }) {
            qpackDecodeHTTPBytes(fixture.value, &sharedQPACKDecoder, &qpackFeedback)
        }
        for (reference, decode) in decoders {
            // Each C decoder must give every section's field count and the corpus' bytes.
            register("QPACK decode (\(label)): \(reference)", setup: { qpackDecodeC(fixture.value, decode) == fixture.value.total ? 1 : 0 }) {
                qpackDecodeC(fixture.value, decode)
            }
        }
        guard !label.hasPrefix("qifs") else { continue }

        register("QPACK encode (\(label)): HTTPBytes", setup: {
            let fixture = fixture.value
            var instructionEnds = [Int](repeating: 0, count: fixture.sets.count), sectionEnds = instructionEnds
            let written = instructionEnds.withUnsafeMutableBufferPointer { instructionEnds in
                sectionEnds.withUnsafeMutableBufferPointer { sectionEnds in
                    qpackEncodeShared(fixture, instructionEnds: instructionEnds, sectionEnds: sectionEnds)
                }
            }
            reportQPACKSize("HTTPBytes", label, written)
            // Interleave the two outputs as the peer would receive them, and decode.
            var bytes: [UInt8] = [], connectionInstructionEnds: [Int] = [], connectionSectionEnds: [Int] = []
            var instructionStart = 0, sectionStart = 0
            for index in 0..<fixture.sets.count {
                bytes += qpackInstructionOutput[instructionStart..<instructionEnds[index]]
                connectionInstructionEnds.append(bytes.count)
                bytes += qpackSectionOutput[sectionStart..<sectionEnds[index]]
                connectionSectionEnds.append(bytes.count)
                instructionStart = instructionEnds[index]
                sectionStart = sectionEnds[index]
            }
            guard written > 0, bytes == fixture.bytes,
                  qpackConnectionDecodes(bytes, instructionEnds: connectionInstructionEnds, sectionEnds: connectionSectionEnds, to: fixture) else {
                return 0
            }
            // And the C decoders take it: every section's field count, the corpus' bytes.
            return decoders.allSatisfy { qpackDecodeC(fixture, $0.1) == fixture.total } ? 1 : 0
        }) {
            qpackEncodeShared(fixture.value)
        }
        for (reference, encode) in [("ls-qpack", lsqpack_encode_sets), ("cursed-http", cursed_qpack_encode_sets)] as [(String, QPACKCEncoder)] {
            register("QPACK encode (\(label)): \(reference)", setup: {
                let fixture = fixture.value
                let written = qpackEncodeC(fixture, encode, &qpackCOutput, &qpackCInstructionEnds, &qpackCSectionEnds)
                reportQPACKSize(reference, label, written)
                let count = fixture.sets.count
                return written > 0 && qpackConnectionDecodes(Array(qpackCOutput[0..<written]), instructionEnds: Array(qpackCInstructionEnds[0..<count]),
                                                             sectionEnds: Array(qpackCSectionEnds[0..<count]), to: fixture) ? 1 : 0
            }) {
                qpackEncodeC(fixture.value, encode, &qpackCOutput, &qpackCInstructionEnds, &qpackCSectionEnds)
            }
        }
    }

    // Allocation gates: HTTPBytes' decoding and encoding allocate nothing once the coder and outputs exist.
    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    let gates: [(String, () -> Int)] = [
        ("Allocations:QPACK_decode_requests_static", { qpackDecodeHTTPBytes(qpackRequestsStatic.value, &sharedQPACKDecoder, &qpackFeedback) }),
        ("Allocations:QPACK_decode_requests_dynamic", { qpackDecodeHTTPBytes(qpackRequestsDynamic.value, &sharedQPACKDecoder, &qpackFeedback) }),
        ("Allocations:QPACK_decode_responses_dynamic", { qpackDecodeHTTPBytes(qpackResponsesDynamic.value, &sharedQPACKDecoder, &qpackFeedback) }),
        ("Allocations:QPACK_decode_interop", { qpackDecodeHTTPBytes(qpackInterop.value, &sharedQPACKDecoder, &qpackFeedback) }),
        ("Allocations:QPACK_encode_requests_static", {
            qpackEncodeShared(qpackRequestsStatic.value)
        }),
        ("Allocations:QPACK_encode_requests_dynamic", {
            qpackEncodeShared(qpackRequestsDynamic.value)
        }),
        ("Allocations:QPACK_encode_responses_dynamic", {
            qpackEncodeShared(qpackResponsesDynamic.value)
        }),
    ]
    for (name, run) in gates {
        Benchmark(name, configuration: zeroAllocations) { benchmark in
            for _ in benchmark.scaledIterations { blackHole(run()) }
        } setup: {
            precondition(run() > 0, "\(name): failed")
        }
    }
}

/// `qpackEncodeHTTPBytes` with the shared encoder for the fixture's capacity (static only, or the peer's 4,096 bytes and
/// 100 blocked streams) and the shared outputs.
@inline(__always)
func qpackEncodeShared(_ fixture: QPACKFixture, instructionEnds: UnsafeMutableBufferPointer<Int>? = nil,
                       sectionEnds: UnsafeMutableBufferPointer<Int>? = nil) -> Int {
    fixture.capacity == 0
        ? qpackEncodeHTTPBytes(fixture, &sharedQPACKStaticEncoder, &qpackSectionOutput, &qpackInstructionOutput,
                               instructionEnds: instructionEnds, sectionEnds: sectionEnds)
        : qpackEncodeHTTPBytes(fixture, &sharedQPACKDynamicEncoder, &qpackSectionOutput, &qpackInstructionOutput,
                               instructionEnds: instructionEnds, sectionEnds: sectionEnds)
}
