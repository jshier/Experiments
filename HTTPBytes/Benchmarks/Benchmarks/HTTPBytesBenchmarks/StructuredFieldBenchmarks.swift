import Benchmark
import Bytes
import HTTPBytes
import RawStructuredFieldValues

// Structured Field Values (RFC 9651): HTTPBytes' views against swift-http-structured-headers' parser (what a Swift
// server on swift-nio parses with). Per iteration: 1,000 parses of one field value, every member, parameter, and value
// read (HTTPBytes decodes strings and byte sequences on demand: here only their lengths are read, as a caller checking
// a value would; swift-http-structured-headers decodes them while parsing).

let priorityValue = Array("u=5, i".utf8)
let dictionaryValue = Array("a=1, b;x=?0;y=\"some string\", c=(1 2 3);p=:cHJldGVuZCB0aGlzIGlzIGJpbmFyeQ==:, d=4.5, e=@1659578233, f=token".utf8)
let listValue = Array("\"Sec-CH-UA-Platform\", \"Sec-CH-UA-Model\", sec-ch-ua;v=\"126\", (1 2);q=0.5, ?1".utf8)

/// Every member of a dictionary: its key, value kind, and parameters, summed so nothing is optimized away.
@inline(never)
func walkHTTPBytesDictionary(_ bytes: [UInt8]) -> Int {
    var total = 0
    for _ in 0..<1_000 {
        var dictionary = HTTPStructuredDictionary(bytes.span.bytes)
        do {
            while let member = try dictionary.next() {
                total &+= member.key.byteCount
                switch member.value {
                case .item(let item):
                    total &+= weight(item.bareItem)
                    var parameters = item.parameters
                    while let parameter = parameters.next() { total &+= parameter.key.byteCount }
                case .innerList(var list):
                    while let item = list.next() { total &+= weight(item.bareItem) }
                }
            }
        } catch { return -1 }
    }
    return total
}

@inline(never)
func walkHTTPBytesList(_ bytes: [UInt8]) -> Int {
    var total = 0
    for _ in 0..<1_000 {
        var list = HTTPStructuredList(bytes.span.bytes)
        do {
            while let member = try list.next() {
                switch member {
                case .item(let item):
                    total &+= weight(item.bareItem)
                    var parameters = item.parameters
                    while let parameter = parameters.next() { total &+= parameter.key.byteCount }
                case .innerList(var inner):
                    while let item = inner.next() { total &+= weight(item.bareItem) }
                }
            }
        } catch { return -1 }
    }
    return total
}

@inline(__always)
func weight(_ item: HTTPStructuredBareItem) -> Int {
    switch item {
    case .integer(let value): Int(truncatingIfNeeded: value)
    case .decimal(let value): Int(truncatingIfNeeded: value.thousandths)
    case .string(let value): value.byteCount
    case .token(let value): value.byteCount
    case .byteSequence(let value): value.byteCount
    case .boolean(let value): value ? 1 : 0
    case .date(let value): Int(truncatingIfNeeded: value)
    case .displayString(let value): value.byteCount
    }
}

@inline(never)
func parsePriorities() -> Int {
    var total = 0
    for _ in 0..<1_000 {
        guard let priority = try? HTTPPriority(parsing: priorityValue.span.bytes) else { return -1 }
        total &+= priority.urgency &+ (priority.isIncremental ? 1 : 0)
    }
    return total
}

@inline(never)
func referenceDictionary(_ bytes: [UInt8]) -> Int {
    var total = 0
    for _ in 0..<1_000 {
        var parser = StructuredFieldValueParser(bytes)
        guard let dictionary = try? parser.parseDictionaryFieldValue() else { return -1 }
        for (key, value) in dictionary {
            total &+= key.utf8.count
            switch value {
            case .item(let item): total &+= item.rfc9651Parameters.count &+ 1
            case .innerList(let list): total &+= list.bareInnerList.count
            }
        }
    }
    return total
}

@inline(never)
func referenceList(_ bytes: [UInt8]) -> Int {
    var total = 0
    for _ in 0..<1_000 {
        var parser = StructuredFieldValueParser(bytes)
        guard let list = try? parser.parseListFieldValue() else { return -1 }
        for member in list {
            switch member {
            case .item(let item): total &+= item.rfc9651Parameters.count &+ 1
            case .innerList(let inner): total &+= inner.bareInnerList.count
            }
        }
    }
    return total
}

func registerStructuredFieldBenchmarks() {
    func register(_ name: String, _ run: @escaping () -> Int) {
        Benchmark(name) { benchmark in
            for _ in benchmark.scaledIterations { blackHole(run()) }
        } setup: {
            precondition(run() > 0, "\(name): failed")
        }
    }
    register("Structured Fields: 1,000 Priority fields: HTTPBytes HTTPPriority", parsePriorities)
    register("Structured Fields: 1,000 Priority fields: swift-http-structured-headers") { referenceDictionary(priorityValue) }
    register("Structured Fields: 1,000 dictionaries (7 members): HTTPBytes") { walkHTTPBytesDictionary(dictionaryValue) }
    register("Structured Fields: 1,000 dictionaries (7 members): swift-http-structured-headers") { referenceDictionary(dictionaryValue) }
    register("Structured Fields: 1,000 lists (5 members): HTTPBytes") { walkHTTPBytesList(listValue) }
    register("Structured Fields: 1,000 lists (5 members): swift-http-structured-headers") { referenceList(listValue) }

    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal], warmupIterations: 1, maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    Benchmark("Allocations:StructuredFields_dictionary", configuration: zeroAllocations) { benchmark in
        for _ in benchmark.scaledIterations { blackHole(walkHTTPBytesDictionary(dictionaryValue)) }
    }
}
