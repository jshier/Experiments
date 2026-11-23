import Benchmark
import Bytes
import BytesTestSupport
import Foundation
import HTTPBytes
import HTTPPayload

// Field values: HTTPBytes' value parsers over every value of a field in the corpora's heads (http-corpus and top-1k,
// requests or responses), and Foundation's `Date.HTTPFormatStyle` for dates (what a Swift server reaches for today; it
// takes `String`s, made in setup). Per iteration: every value once.

/// The values of the fields named `names` (any case) in `corpora`' heads, in one byte array.
struct FieldValueSet {
    let bytes: [UInt8]
    let ranges: [Range<Int>]

    init(_ corpora: [HeadCorpus], _ names: [String]) {
        let wanted = names.map { Array($0.lowercased().utf8) + [0x3A] }
        var bytes: [UInt8] = [], ranges: [Range<Int>] = []
        for corpus in corpora {
            let all = corpus.bytes[..<corpus.count]
            var lineStart = all.startIndex
            while lineStart < all.endIndex {
                var lineEnd = lineStart
                while lineEnd < all.endIndex, all[lineEnd] != 0x0D { lineEnd += 1 }
                let line = all[lineStart..<lineEnd].map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
                for name in wanted where line.starts(with: name) {
                    var start = lineStart + name.count, end = lineEnd
                    while start < end, all[start] == 0x20 || all[start] == 0x09 { start += 1 }
                    while end > start, all[end - 1] == 0x20 || all[end - 1] == 0x09 { end -= 1 }
                    let offset = bytes.count
                    bytes += all[start..<end]
                    ranges.append(offset..<bytes.count)
                }
                lineStart = lineEnd + 2
            }
        }
        self.bytes = bytes
        self.ranges = ranges
    }

    /// The values as strings (Foundation's input).
    var strings: [String] { ranges.map { String(decoding: bytes[$0], as: UTF8.self) } }
}

let responseDates = Lazy { FieldValueSet([responses.value, top1kResponses.value], ["date", "last-modified"]) }
let responseDateStrings = Lazy { responseDates.value.strings }
let contentTypes = Lazy { FieldValueSet([responses.value, top1kResponses.value], ["content-type"]) }
let cacheControls = Lazy { FieldValueSet([responses.value, top1kResponses.value], ["cache-control"]) }
let entityTags = Lazy { FieldValueSet([responses.value, top1kResponses.value], ["etag"]) }
let accepts = Lazy { FieldValueSet([requests.value, top1kRequests.value], ["accept"]) }
let acceptEncodings = Lazy { FieldValueSet([requests.value, top1kRequests.value], ["accept-encoding"]) }
let acceptLanguages = Lazy { FieldValueSet([requests.value, top1kRequests.value], ["accept-language"]) }
let cookies = Lazy { FieldValueSet([requests.value, top1kRequests.value], ["cookie"]) }
let hosts = Lazy { FieldValueSet([requests.value, top1kRequests.value], ["host"]) }
/// Request targets: the second word of each request line.
let targets = Lazy { () -> FieldValueSet in
    var bytes: [UInt8] = [], ranges: [Range<Int>] = []
    for corpus in [requests.value, top1kRequests.value] {
        for offset in corpus.offsets {
            var start = offset
            while corpus.bytes[start] != 0x20 { start += 1 }
            start += 1
            var end = start
            while corpus.bytes[end] != 0x20 { end += 1 }
            let at = bytes.count
            bytes += corpus.bytes[start..<end]
            ranges.append(at..<bytes.count)
        }
    }
    return FieldValueSet(bytes: bytes, ranges: ranges)
}

extension FieldValueSet {
    init(bytes: [UInt8], ranges: [Range<Int>]) {
        self.bytes = bytes
        self.ranges = ranges
    }
}

/// Runs `body` on each value; the sum of its results.
@inline(__always)
func eachValue(_ set: FieldValueSet, _ body: (RawSpan) -> Int) -> Int {
    let all = set.bytes.span.bytes
    var total = 0
    for range in set.ranges { total &+= body(all.extracting(range)) }
    return total
}

@inline(never) func parseDates(_ set: FieldValueSet) -> Int {
    eachValue(set) { value in Int(truncatingIfNeeded: (try? HTTPDate(parsing: value))?.secondsSince1970 ?? -1) }
}

@inline(never) func parseDatesFoundation(_ strings: [String]) -> Int {
    let style = Date.HTTPFormatStyle()
    var total = 0
    for string in strings { total &+= Int((try? style.parseStrategy.parse(string))?.timeIntervalSince1970 ?? -1) }
    return total
}

@inline(never) func formatDates(_ count: Int, into output: inout [UInt8]) -> Int {
    var total = 0
    for index in 0..<count {
        let date = HTTPDate(secondsSince1970: 1_700_000_000 &+ Int64(index) &* 86_413)
        let written = try? output.withOutputRawSpan(overwritingFrom: 0) { (span) throws(BytesError) -> Int in
            try span.withAlignedBytesWriter { (writer) throws(BytesError) in try date.write(to: &writer) }
            return span.byteCount
        }
        total &+= written ?? -1
    }
    return total
}

@inline(never) func formatDatesFoundation(_ count: Int) -> Int {
    let style = Date.HTTPFormatStyle()
    var total = 0
    for index in 0..<count {
        total &+= Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 86_413)).formatted(style).utf8.count
    }
    return total
}

@inline(never) func cachedDates(_ count: Int) -> Int {
    var cache = HTTPDateCache()
    var total = 0
    // A server's `Date` for 1,000 responses over 10 seconds.
    for index in 0..<count { total &+= cache.imfFixdate(HTTPDate(secondsSince1970: 1_700_000_000 &+ Int64(index / 100))).byteCount }
    return total
}

@inline(never) func parseContentTypes(_ set: FieldValueSet) -> Int {
    eachValue(set) { value in
        guard let type = try? HTTPMediaType(parsing: value) else { return -1 }
        return type.subtype.byteCount &+ (type.charset == nil ? 0 : 1)
    }
}

@inline(never) func parseCacheControls(_ set: FieldValueSet) -> Int {
    eachValue(set) { value in
        let control = HTTPCacheControl(parsing: value)
        return (control.maxAge ?? 0) &+ (control.noStore ? 1 : 0) &+ 1
    }
}

@inline(never) func parseEntityTags(_ set: FieldValueSet) -> Int {
    eachValue(set) { value in (try? HTTPEntityTag(parsing: value))?.opaque.byteCount ?? -1 }
}

let textHTML: (type: [UInt8], subtype: [UInt8]) = (Array("text".utf8), Array("html".utf8))
@inline(never) func acceptWeights(_ set: FieldValueSet) -> Int {
    let type = textHTML.type, subtype = textHTML.subtype
    return eachValue(set) { value in (try? HTTPAcceptList.weight(ofMediaType: type.span.bytes, subtype.span.bytes, in: value)) ?? -1 }
}

@inline(never) func negotiateCodings(_ set: FieldValueSet) -> Int {
    let available: [HTTPContentCoding] = [.brotli, .gzip, .identity]
    return eachValue(set) { value in
        switch HTTPContentCoding.negotiated(acceptEncoding: value, available: available) {
        case .brotli?: 3
        case .gzip?: 2
        case .identity?: 1
        default: 0
        }
    }
}

let enUS = Array("en-US".utf8)
@inline(never) func languageWeights(_ set: FieldValueSet) -> Int {
    let tag = enUS
    return eachValue(set) { value in (try? HTTPAcceptList.weight(ofLanguage: tag.span.bytes, in: value)) ?? -1 }
}

@inline(never) func iterateCookies(_ set: FieldValueSet) -> Int {
    eachValue(set) { value in
        var cookies = HTTPCookies(value)
        var total = 0
        while let cookie = cookies.next() { total &+= cookie.name.byteCount &+ cookie.value.byteCount }
        return total
    }
}

@inline(never) func parseHosts(_ set: FieldValueSet) -> Int {
    eachValue(set) { value in
        guard let host = try? HTTPHost(parsing: value) else { return -1 }
        return host.host.byteCount &+ (host.port ?? 0)
    }
}

@inline(never) func splitTargets(_ set: FieldValueSet) -> Int {
    eachValue(set) { value in
        let parts = HTTPTargetComponents(value)
        var total = parts.path.byteCount
        var items = parts.queryItems
        while let item = items.next() { total &+= item.name.byteCount &+ 1 }
        return total
    }
}

func registerFieldValueBenchmarks() {
    func register(_ name: String, _ run: @escaping () -> Int) {
        Benchmark(name) { benchmark in
            for _ in benchmark.scaledIterations { blackHole(run()) }
        } setup: {
            precondition(run() > 0, "\(name): failed")
        }
    }
    nonisolated(unsafe) var output = [UInt8](repeating: 0, count: 64)
    register("Field values: Date, Last-Modified (responses): HTTPBytes HTTPDate") { parseDates(responseDates.value) }
    register("Field values: Date, Last-Modified (responses): Foundation Date.HTTPFormatStyle") { parseDatesFoundation(responseDateStrings.value) }
    register("Field values: 1,000 dates written: HTTPBytes HTTPDate") { formatDates(1_000, into: &output) }
    register("Field values: 1,000 dates written: Foundation Date.HTTPFormatStyle") { formatDatesFoundation(1_000) }
    register("Field values: 1,000 Date fields from a cache (10 seconds): HTTPBytes HTTPDateCache") { cachedDates(1_000) }
    register("Field values: Content-Type (responses): HTTPBytes HTTPMediaType") { parseContentTypes(contentTypes.value) }
    register("Field values: Cache-Control (responses): HTTPBytes HTTPCacheControl") { parseCacheControls(cacheControls.value) }
    register("Field values: ETag (responses): HTTPBytes HTTPEntityTag") { parseEntityTags(entityTags.value) }
    register("Field values: Accept (requests), weight of text/html: HTTPBytes") { acceptWeights(accepts.value) }
    register("Field values: Accept-Encoding (requests), br/gzip/identity negotiated: HTTPBytes") { negotiateCodings(acceptEncodings.value) }
    register("Field values: Accept-Language (requests), weight of en-US: HTTPBytes") { languageWeights(acceptLanguages.value) }
    register("Field values: Cookie (requests), every cookie: HTTPBytes HTTPCookies") { iterateCookies(cookies.value) }
    register("Field values: Host (requests): HTTPBytes HTTPHost") { parseHosts(hosts.value) }
    register("Field values: request targets, path and query items: HTTPBytes") { splitTargets(targets.value) }

    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal], warmupIterations: 1, maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    func gate(_ name: String, _ run: @escaping () -> Int) {
        Benchmark(name, configuration: zeroAllocations) { benchmark in
            precondition(run() > 0)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations { blackHole(run()) }
        }
    }
    gate("Allocations:FieldValues_dates") { parseDates(responseDates.value) &+ formatDates(100, into: &output) &+ cachedDates(100) }
    gate("Allocations:FieldValues_cache_control") { parseCacheControls(cacheControls.value) }
    gate("Allocations:FieldValues_accept") { acceptWeights(accepts.value) &+ languageWeights(acceptLanguages.value) }
    gate("Allocations:FieldValues_cookies_targets") { iterateCookies(cookies.value) &+ splitTargets(targets.value) &+ parseHosts(hosts.value) }
}
