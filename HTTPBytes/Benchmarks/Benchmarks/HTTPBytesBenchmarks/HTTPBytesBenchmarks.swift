import Benchmark
import Bytes
import BytesTestSupport
import CReferences
import Foundation
import HTTP1
import HTTPBytes
import HTTPTypes

// HTTPBytes against the references, row by row. Registration only names benchmarks; fixtures load in `setup` (on first
// use of a `Lazy`), and each setup runs its work once and checks the result. Per iteration: the whole corpus (401
// request heads, 232 KB; 383 response heads, 365 KB; top-1k: 3,533 request heads, 4.1 MB, 2,054 response heads, 4.1 MB),
// 1,000 heads of the synthetic rows, or one 1 MB body.

// MARK: - Fixtures

/// Heads, concatenated as a connection would receive them, and where each starts. `bytes` has 64 bytes of padding
/// after the heads (cursed-http's parsers read up to 64 bytes past what they're given); `count` is the heads' bytes.
final class HeadCorpus: Sendable {
    let bytes: [UInt8]
    let count: Int
    let offsets: [Int]

    init(bytes: [UInt8]) {
        self.bytes = bytes + [UInt8](repeating: 0, count: 64)
        count = bytes.count
        var offsets: [Int] = []
        var start = 0, index = 0
        while index + 4 <= bytes.count {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                offsets.append(start)
                index += 4
                start = index
            } else {
                index += 1
            }
        }
        self.offsets = offsets
    }

    convenience init(set: String = "http-corpus", file: String) {
        let url = try! TestData.file(set: set, name: file)
        self.init(bytes: [UInt8](try! Data(contentsOf: url)))
    }

    /// `count` copies of one head.
    convenience init(repeating head: String, count: Int) {
        self.init(bytes: Array(String(repeating: head, count: count).utf8))
    }

    /// Each head's end (`offsets[i + 1]`, or `count` for the last), for parsing each from a span of exactly its bytes.
    var ends: [Int] { offsets.dropFirst().map(\.self) + [count] }
}

let requests = Lazy { HeadCorpus(file: "requests.http1") }
let responses = Lazy { HeadCorpus(file: "responses.http1") }
let top1kRequests = Lazy { HeadCorpus(set: "http-top1k", file: "requests.http1") }
let top1kResponses = Lazy { HeadCorpus(set: "http-top1k", file: "responses.http1") }
let tinyRequests = Lazy { HeadCorpus(repeating: "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", count: 1_000) }

/// 1,000 requests of 20 fields whose values are `length` bytes.
func fieldLengthCorpus(_ length: Int) -> HeadCorpus {
    let value = String(repeating: "v", count: length)
    let head = "GET /resource HTTP/1.1\r\n" + (0..<20).map { "X-Field-\($0): \(value)\r\n" }.joined() + "\r\n"
    return HeadCorpus(repeating: head, count: 1_000)
}

/// A request whose 1 MB body is chunked in `chunkSize`-byte chunks.
func chunkedMessage(chunkSize: Int) -> (message: [UInt8], bodyStart: Int, bodyCount: Int) {
    var generator = SplitMix64(seed: 1)
    let body = (0..<(1 << 20)).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
    var message = Array("POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
    let bodyStart = message.count
    var offset = 0
    while offset < body.count {
        let size = min(chunkSize, body.count - offset)
        message += Array(String(size, radix: 16).utf8) + [0x0D, 0x0A] + body[offset..<offset + size] + [0x0D, 0x0A]
        offset += size
    }
    message += Array("0\r\n\r\n".utf8)
    return (message, bodyStart, body.count)
}

let chunked4K = Lazy { chunkedMessage(chunkSize: 4 << 10) }
let chunked64K = Lazy { chunkedMessage(chunkSize: 64 << 10) }

// MARK: - Workloads

/// The top-1k corpus's limits: one request has a 57 KB target (the default limit is 8 KB, 414 beyond it).
let largeLimits = HTTP1ParserOptions(maximumHeadByteCount: 128 << 10, maximumTargetByteCount: 64 << 10)

/// Every event of one request head; the head's length (what was read is kept, so nothing is optimized away). Each
/// field's name and value spans are read, as picohttpparser's array of them is filled; with `knownNames`, each field's
/// known name is looked up too (HTTP/1 fields look it up when asked: ``HTTPFieldView/knownName``).
@inline(__always)
func requestEvents(_ bytes: RawSpan, options: HTTP1ParserOptions, knownNames: Bool) -> Int {
    var parser = HTTP1RequestParser(options: options)
    var total = 0
    do {
        while true {
            switch try parser.next(in: bytes) {
            case let .requestLine(line): total &+= line.method.byteCount &+ line.target.byteCount
            case let .field(field):
                total &+= field.name.byteCount &+ field.value.byteCount
                if knownNames { total &+= Int(field.knownName?.index ?? 0) }
            case let .end(count): blackHole(total); return count
            case .needsMore: return -1
            }
        }
    } catch { return -2 }
}

@inline(__always)
func responseEvents(_ bytes: RawSpan, options: HTTP1ParserOptions, knownNames: Bool) -> Int {
    var parser = HTTP1ResponseParser(options: options)
    var total = 0
    do {
        while true {
            switch try parser.next(in: bytes) {
            case let .statusLine(line): total &+= line.status.code &+ line.reasonPhrase.byteCount
            case let .field(field):
                total &+= field.name.byteCount &+ field.value.byteCount
                if knownNames { total &+= Int(field.knownName?.index ?? 0) }
            case let .end(count): blackHole(total); return count
            case .needsMore: return -1
            }
        }
    } catch { return -2 }
}

@inline(never) func parseRequestEvents(_ bytes: RawSpan) -> Int { requestEvents(bytes, options: HTTP1ParserOptions(), knownNames: false) }
@inline(never) func parseRequestEventsKnown(_ bytes: RawSpan) -> Int { requestEvents(bytes, options: HTTP1ParserOptions(), knownNames: true) }
@inline(never) func parseResponseEvents(_ bytes: RawSpan) -> Int { responseEvents(bytes, options: HTTP1ParserOptions(), knownNames: false) }
@inline(never) func parseResponseEventsKnown(_ bytes: RawSpan) -> Int { responseEvents(bytes, options: HTTP1ParserOptions(), knownNames: true) }
@inline(never) func parseLargeRequestEvents(_ bytes: RawSpan) -> Int { requestEvents(bytes, options: largeLimits, knownNames: false) }
@inline(never) func parseLargeRequestEventsKnown(_ bytes: RawSpan) -> Int { requestEvents(bytes, options: largeLimits, knownNames: true) }
@inline(never) func parseLargeResponseEvents(_ bytes: RawSpan) -> Int { responseEvents(bytes, options: largeLimits, knownNames: false) }
@inline(never) func parseLargeResponseEventsKnown(_ bytes: RawSpan) -> Int { responseEvents(bytes, options: largeLimits, knownNames: true) }

/// A request head into an owned, reused field store: what a server keeping the fields past its read buffer does.
@inline(never)
func parseRequestIntoStore(_ bytes: RawSpan, _ store: inout HTTPFieldStore) -> Int {
    var parser = HTTP1RequestParser()
    store.removeAll()
    do {
        while true {
            switch try parser.next(in: bytes) {
            case .requestLine: continue
            case let .field(field): try store.append(field)
            case let .end(count): blackHole(store.count); return count
            case .needsMore: return -1
            }
        }
    } catch { return -2 }
}

/// A request head into swift-http-types' `HTTPFields` (names and values as strings), from HTTPBytes' views: what a
/// server using swift-http-types does with them.
@inline(never)
func parseRequestIntoHTTPFields(_ bytes: RawSpan) -> Int {
    var parser = HTTP1RequestParser()
    var fields = HTTPFields()
    do {
        while true {
            switch try parser.next(in: bytes) {
            case .requestLine: continue
            case let .field(field):
                guard let name = HTTPField.Name(string(field.name)) else { return -3 }
                fields.append(HTTPField(name: name, value: string(field.value)))
            case let .end(count): blackHole(fields.count); return count
            case .needsMore: return -1
            }
        }
    } catch { return -2 }
}

@inline(__always)
func string(_ bytes: RawSpan) -> String {
    bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
}

/// 1 if every head parses to exactly its length, else 0: what each setup checks. (A sum of results can't tell: the
/// first baseline's request rows summed heads that had failed early, and measured the failures.) With `alone`, each
/// head is given only its own bytes; otherwise everything from its start on, as a connection's buffer holds it.
func everyHead(_ corpus: HeadCorpus, alone: Bool = false, _ parse: (RawSpan) -> Int) -> Int {
    let bytes = corpus.bytes
    let span = bytes.span.bytes.extracting(0..<corpus.count)
    for (offset, end) in zip(corpus.offsets, corpus.ends)
        where parse(span.extracting(offset..<(alone ? end : corpus.count))) != end - offset {
        return 0
    }
    return 1
}

func everyHeadC(_ corpus: HeadCorpus, alone: Bool = false,
                _ parse: (UnsafePointer<CChar>, Int, UnsafeMutablePointer<Int32>) -> Int) -> Int {
    corpus.bytes.withUnsafeBytes { raw in
        let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
        var fields: Int32 = 0
        for (offset, end) in zip(corpus.offsets, corpus.ends)
            where parse(base + offset, (alone ? end : corpus.count) - offset, &fields) != end - offset {
            return 0
        }
        return 1
    }
}

@inline(never)
func eachHead(_ corpus: HeadCorpus, _ parse: (RawSpan) -> Int) -> Int {
    let bytes = corpus.bytes
    let span = bytes.span.bytes.extracting(0..<corpus.count)
    var total = 0
    for offset in corpus.offsets {
        total &+= parse(span.extracting(droppingFirst: offset))
    }
    return total
}

/// Each head from a span of exactly its bytes, as a server that has read one request has it.
@inline(never)
func eachHeadAlone(_ corpus: HeadCorpus, _ ends: [Int], _ parse: (RawSpan) -> Int) -> Int {
    let bytes = corpus.bytes
    let span = bytes.span.bytes
    var total = 0
    for (offset, end) in zip(corpus.offsets, ends) {
        total &+= parse(span.extracting(offset..<end))
    }
    return total
}

@inline(never)
func eachHeadC(_ corpus: HeadCorpus, _ parse: (UnsafePointer<CChar>, Int, UnsafeMutablePointer<Int32>) -> Int) -> Int {
    corpus.bytes.withUnsafeBytes { raw in
        let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
        var total = 0, fields: Int32 = 0
        for offset in corpus.offsets {
            total &+= parse(base + offset, corpus.count - offset, &fields) &+ Int(fields)
        }
        return total
    }
}

@inline(never)
func eachHeadAloneC(_ corpus: HeadCorpus, _ ends: [Int], _ parse: (UnsafePointer<CChar>, Int, UnsafeMutablePointer<Int32>) -> Int) -> Int {
    corpus.bytes.withUnsafeBytes { raw in
        let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
        var total = 0, fields: Int32 = 0
        for (offset, end) in zip(corpus.offsets, ends) {
            total &+= parse(base + offset, end - offset, &fields) &+ Int(fields)
        }
        return total
    }
}

/// A chunked body's data, every event's bytes counted.
@inline(never)
func decodeChunked(_ body: RawSpan) -> Int {
    var decoder = HTTP1ChunkedDecoder()
    var unread = body
    var total = 0
    do {
        while true {
            var consumed = 0
            switch try decoder.next(in: unread, consumed: &consumed) {
            case let .data(data): total &+= data.byteCount
            case .trailer: break
            case .end: return total
            case .needsMore: return -1
            }
            unread = unread.extracting(droppingFirst: consumed)
        }
    } catch { return -2 }
}

/// swift-http-types makes `Host` unavailable as a name constant (HTTP/2 and 3 use `:authority`); HTTP/1 requests have it.
let hostName = HTTPField.Name("Host")!

/// Looks up three names (two present, one absent) 1,000 times.
@inline(never)
func lookUpStore(_ store: borrowing HTTPFieldStore) -> Int {
    var total = 0
    for _ in 0..<1_000 {
        if let value = store.firstValue(of: .host) { total &+= value.byteCount }
        if let value = store.firstValue(of: .userAgent) { total &+= value.byteCount }
        if store.firstValue(of: .contentLength) != nil { total &+= 1 }
    }
    return total
}

@inline(never)
func lookUpHTTPFields(_ fields: HTTPFields) -> Int {
    var total = 0
    for _ in 0..<1_000 {
        if let value = fields[hostName] { total &+= value.utf8.count }
        if let value = fields[.userAgent] { total &+= value.utf8.count }
        if fields[.contentLength] != nil { total &+= 1 }
    }
    return total
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .milliseconds(500),
        maxIterations: 200
    )

    func register(_ name: String, setup: @escaping () -> Int, _ run: @escaping () -> Int) {
        Benchmark(name) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(run())
            }
        } setup: {
            precondition(setup() > 0, "\(name): failed")
        }
    }

    // Heads, every field's name and value found: HTTPBytes' events, and the C parsers (each fills an array of fields,
    // or records them from callbacks). "known names" also looks each field's name up (`knownName`), which the plain
    // rows, like the C parsers, don't. Each head is parsed from a span of everything after its start, as in a
    // connection's buffer; "alone" rows give each head only its own bytes, as a server that has read one request.
    func registerHeads(_ label: String, _ corpus: Lazy<HeadCorpus>, response: Bool, large: Bool = false, alone: Bool = false) {
        let kind = response ? "response" : "request"
        let swiftRows: [(String, (RawSpan) -> Int)] = switch (response, large) {
        case (false, false): [("HTTPBytes", parseRequestEvents), ("HTTPBytes, known names", parseRequestEventsKnown)]
        case (false, true): [("HTTPBytes", parseLargeRequestEvents), ("HTTPBytes, known names", parseLargeRequestEventsKnown)]
        case (true, false): [("HTTPBytes", parseResponseEvents), ("HTTPBytes, known names", parseResponseEventsKnown)]
        case (true, true): [("HTTPBytes", parseLargeResponseEvents), ("HTTPBytes, known names", parseLargeResponseEventsKnown)]
        }
        let cRows: [(String, (UnsafePointer<CChar>, Int, UnsafeMutablePointer<Int32>) -> Int)] = response
            ? [("picohttpparser", pico_parse_response), ("llhttp", llhttp_parse_response), ("cursed-http", cursed_parse_response)]
            : [("picohttpparser", pico_parse_request), ("llhttp", llhttp_parse_request), ("cursed-http", cursed_parse_request)]
        for (name, parse) in swiftRows {
            register("HTTP/1 \(kind) heads (\(label)): \(name)", setup: { everyHead(corpus.value, alone: alone, parse) }) {
                alone ? eachHeadAlone(corpus.value, corpus.value.ends, parse) : eachHead(corpus.value, parse)
            }
        }
        for (name, parse) in cRows {
            register("HTTP/1 \(kind) heads (\(label)): \(name)", setup: { everyHeadC(corpus.value, alone: alone, parse) }) {
                alone ? eachHeadAloneC(corpus.value, corpus.value.ends, parse) : eachHeadC(corpus.value, parse)
            }
        }
    }
    registerHeads("401 requests, 232 KB", requests, response: false)
    registerHeads("383 responses, 365 KB", responses, response: true)
    registerHeads("top-1k, 3,533 requests, 4.1 MB", top1kRequests, response: false, large: true)
    registerHeads("top-1k, 2,054 responses, 4.1 MB", top1kResponses, response: true, large: true)
    registerHeads("1,000 tiny requests, 38 B", tinyRequests, response: false)
    registerHeads("1,000 tiny requests, 38 B, alone", tinyRequests, response: false, alone: true)

    // Field value length: 1,000 heads of 20 fields each, values of one length.
    for length in [1, 8, 15, 16, 31, 32, 64, 128] {
        registerHeads("1,000 × 20 fields of \(length) B", Lazy { fieldLengthCorpus(length) }, response: false)
    }

    // Keeping the fields: an owned store reused across heads, against swift-http-types' `HTTPFields` built from strings.
    nonisolated(unsafe) var store = HTTPFieldStore()
    register("HTTP/1 requests into owned fields (401 requests): HTTPBytes HTTPFieldStore", setup: {
        everyHead(requests.value) { parseRequestIntoStore($0, &store) }
    }) {
        eachHead(requests.value) { parseRequestIntoStore($0, &store) }
    }
    register("HTTP/1 requests into owned fields (401 requests): swift-http-types HTTPFields", setup: {
        everyHead(requests.value, parseRequestIntoHTTPFields)
    }) {
        eachHead(requests.value, parseRequestIntoHTTPFields)
    }

    // Looking fields up by name, 3,000 lookups in the first request's 6 fields.
    nonisolated(unsafe) var lookupStore = HTTPFieldStore()
    nonisolated(unsafe) var lookupFields = HTTPFields()
    let prepareLookups = {
        let corpus = requests.value
        _ = eachHead(HeadCorpus(bytes: Array(corpus.bytes[0..<corpus.offsets[1]]))) { parseRequestIntoStore($0, &lookupStore) }
        lookupFields = HTTPFields()
        for index in 0..<lookupStore.count {
            let field = lookupStore.field(at: index)
            lookupFields.append(HTTPField(name: HTTPField.Name(string(field.name))!, value: string(field.value)))
        }
        // The first request has no `Host` after the request line: add one, as HTTP/1.1 requires.
        try! lookupStore.append(.host, value: Array("static.xx.fbcdn.net".utf8).span.bytes)
        lookupFields[hostName] = "static.xx.fbcdn.net"
    }
    register("Fields: 3,000 lookups by name: HTTPBytes HTTPFieldStore", setup: { prepareLookups(); return lookUpStore(lookupStore) }) {
        lookUpStore(lookupStore)
    }
    register("Fields: 3,000 lookups by name: swift-http-types HTTPFields", setup: { prepareLookups(); return lookUpHTTPFields(lookupFields) }) {
        lookUpHTTPFields(lookupFields)
    }

    // A 1 MB chunked body: HTTPBytes' decoder (slices of the input, nothing copied) and llhttp's (its `on_body`
    // callbacks, which include parsing the message's 73-byte head). picohttpparser's decoder works in place, moving the
    // data, so it can't run on the same buffer twice: not measured.
    for (label, message) in [("4 KB chunks", chunked4K), ("64 KB chunks", chunked64K)] {
        register("HTTP/1 chunked body (1 MB, \(label)): HTTPBytes", setup: {
            let (bytes, start, count) = message.value
            return decodeChunked(bytes.span.bytes.extracting(droppingFirst: start)) == count ? 1 : 0
        }) {
            let bytes = message.value.message
            return decodeChunked(bytes.span.bytes.extracting(droppingFirst: message.value.bodyStart))
        }
        register("HTTP/1 chunked body (1 MB, \(label)): llhttp", setup: {
            let (bytes, _, count) = message.value
            return bytes.withUnsafeBytes { llhttp_parse_chunked_message($0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) } == count ? 1 : 0
        }) {
            message.value.message.withUnsafeBytes { llhttp_parse_chunked_message($0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) }
        }
    }

    // Allocation gates: HTTPBytes' parsing allocates nothing (the store, once grown, nothing either).
    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    let gates: [(String, () -> Int)] = [
        ("Allocations:HTTP1_request_heads", { eachHead(requests.value, parseRequestEvents) }),
        ("Allocations:HTTP1_response_heads", { eachHead(responses.value, parseResponseEvents) }),
        ("Allocations:HTTP1_requests_into_HTTPFieldStore", { eachHead(requests.value) { parseRequestIntoStore($0, &store) } }),
        ("Allocations:HTTP1_chunked_body", {
            let bytes = chunked4K.value.message
            return decodeChunked(bytes.span.bytes.extracting(droppingFirst: chunked4K.value.bodyStart))
        }),
    ]
    for (name, run) in gates {
        Benchmark(name, configuration: zeroAllocations) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(run())
            }
        }
    }

    registerHPACKBenchmarks()
    registerQPACKBenchmarks()
    registerStructuredFieldBenchmarks()
    registerPayloadBenchmarks()
    registerFieldValueBenchmarks()
}
