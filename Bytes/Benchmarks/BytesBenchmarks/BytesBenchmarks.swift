import Benchmark
import Bytes
import BytesTestSupport

// Fixtures are `Lazy` values (BytesTestSupport), made by the setup of a benchmark that uses them: package-benchmark
// runs each benchmark in a process of its own, and every process (and the one that lists them) runs the whole
// registration closure first, so what registration makes is made once per benchmark in the target, whichever runs.

/// Registers `name`: `run` once per iteration on the fixture. Setup makes the fixture, then runs `run` once and checks
/// its result with `check` (that first run warms the caches too).
func register<F, R>(
    _ name: String, configuration: Benchmark.Configuration? = nil, _ fixture: Lazy<F>,
    check: @escaping (F, R) -> Bool = { _, _ in true }, _ run: @escaping (F) throws -> R
) {
    Benchmark(name, configuration: configuration ?? Benchmark.defaultConfiguration) { benchmark in
        let fixture = fixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(run(fixture))
        }
    } setup: {
        let fixture = fixture.value
        let result = try run(fixture)
        precondition(check(fixture, result), "\(name): wrong result")
    }
}

/// The zip central directory, the bit-field records, the big-endian words, and the search haystack: made by the setup
/// of a benchmark that uses them.
let directory = Lazy { makeCentralDirectory(count: 2_000) }
let bitStream = Lazy { (0..<(128 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) } }
let searchHaystack = Lazy {
    var tail = (0..<65_557).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
    tail.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x05, 0x06])
    return tail
}

let searchSignature: Byte4 = 0x50_4B_05_06

let benchmarks: @Sendable () -> Void = {
    // Up to 1,000 samples in 200 ms: operations under 0.2 ms get all 1,000, a 10 ms one 20. No malloc counting in
    // timed runs (the interposer costs every allocation time): the `Allocations:` gates count them.
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .instructions, .throughput],
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: .milliseconds(200),
        maxIterations: 1_000
    )

    registerBandwidthBenchmarks()
    registerWriteBenchmarks()
    registerCRCBenchmarks()
    registerRunsAndCopiesBenchmarks()
    registerBuildersAndSectionsBenchmarks()
    registerASCIIBenchmarks()
    registerScanBenchmarks()
    registerTypedCursorBenchmarks()
    registerCoreAdditionsBenchmarks()
    registerAsyncBenchmarks()

    // MARK: Field parsing: a 2,000-entry zip central directory (~170 KB)

    // Every parser's sum is the hand-written offsets' (checked by each benchmark's setup).
    let expected = Lazy {
        let bytes = directory.value
        return try! CentralDirectory.parseWithOffsets(bytes.span.bytes)
    }
    let fields = Lazy { (directory: directory.value, expected: expected.value) }
    let matches = { (f: (directory: [UInt8], expected: UInt64), sum: UInt64) in sum == f.expected }

    register("Fields: Bytes", fields, check: matches) { f in
        try CentralDirectory.parseWithBytes(f.directory.span.bytes)
    }
    // Each entry all or nothing (a streaming parser's records): the closure of `atomically`, against
    // `position` and `rewind(to:)`.
    register("Fields: Bytes, entries in atomically", fields, check: matches) { f in
        try CentralDirectory.parseWithBytesAtomically(f.directory.span.bytes)
    }
    register("Fields: Bytes, entries in atomically, body in the closure", fields, check: matches) { f in
        try CentralDirectory.parseWithBytesAtomicallyLiteral(f.directory.span.bytes)
    }
    register("Fields: Bytes, entries between position and rewind(to:)", fields, check: matches) { f in
        try CentralDirectory.parseWithBytesRewinding(f.directory.span.bytes)
    }
    register("Fields: Bytes, fixed-size records", fields, check: matches) { f in
        try CentralDirectory.parseWithBytesRecords(f.directory.span.bytes)
    }
    // The little-endian reader: every field's byte order in the type, none at the call.
    register("Fields: LittleEndianBytesReader", fields, check: matches) { f in
        try CentralDirectory.parseWithLittleEndianReader(f.directory.span.bytes)
    }
    register("Fields: original ByteReader", fields, check: matches) { f in
        try CentralDirectory.parseWithByteReader(f.directory.span.bytes)
    }
    register("Fields: hand-written offsets", fields) { f in
        try CentralDirectory.parseWithOffsets(f.directory.span.bytes)
    }

    // MARK: Bit fields: 8 fields of 1 to 32 bits per 64-bit record, 128 KB

    let bits = Lazy {
        let stream = bitStream.value
        return (stream: stream, expected: try! BitFields.parseWithBitBuffer(stream.span))
    }
    register("Bits: Bytes", bits, check: { $1 == $0.expected }) { f in
        try BitFields.parseWithBytes(f.stream.span)
    }
    register("Bits: 64-bit buffer reader", bits) { f in
        try BitFields.parseWithBitBuffer(f.stream.span)
    }

    // MARK: Bulk: 1 MB of big-endian UInt32s (256 K values)

    let words = Lazy { (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) } }
    let wordCount = (1 << 20) / 4

    register("Bulk BE32: read(_:_:into:)", words) { words in
        var reader = BytesReader(words.span)
        return try [UInt32](capacity: wordCount) { try reader.read(Byte4.self, .bigEndian, into: &$0) }
    }
    register("Bulk BE32: read(_:_:) per value", words) { words in
        var reader = BytesReader(words.span)
        return try [UInt32](capacity: wordCount) { output in
            while !output.isFull {
                try output.append(reader.read(Byte4.self, .bigEndian))
            }
        }
    }
    register("Bulk BE32: RawSpan.load per value", words) { words in
        let span = words.span.bytes
        return [UInt32](capacity: wordCount) { output in
            for index in 0..<wordCount {
                output.append(span.load(fromByteOffset: index * 4, as: UInt32.self, .bigEndian))
            }
        }
    }
    register("Bulk BE24: read(_:_:into:)", words) { words in
        var reader = BytesReader(words.span)
        return try [UInt32](capacity: words.count / 3) { try reader.read(Byte3.self, .bigEndian, into: &$0) }
    }

    // MARK: Search: a 4-byte signature at the start of 64 KB (the zip EOCD worst case: a max-length comment)

    register("Search 64 KB backwards: lastByteOffset(of:)", searchHaystack, check: { $1 == 0 }) { haystack in
        BytesReader(haystack.span).lastByteOffset(of: searchSignature)
    }
    register("Search 64 KB backwards: RawSpan.load per offset", searchHaystack, check: { $1 == 0 }) { haystack in
        let span = haystack.span.bytes
        var found: Int?
        for offset in stride(from: span.byteCount - 4, through: 0, by: -1)
            where span.load(fromByteOffset: offset, as: UInt32.self, .littleEndian) == 0x0605_4B50 {
            found = offset
            break
        }
        return found
    }

    // MARK: Allocations: every workload that shouldn't allocate, counting only allocations (Allocations.swift)

    // (Each array bound to a local first: a span of `Lazy.value`'s result would outlive that temporary.)
    registerAllocationBenchmarks([
        ("Fields: Bytes", { let bytes = directory.value; blackHole(try! CentralDirectory.parseWithBytes(bytes.span.bytes)) }),
        ("Fields: Bytes, fixed-size records", { let bytes = directory.value; blackHole(try! CentralDirectory.parseWithBytesRecords(bytes.span.bytes)) }),
        ("Fields: Bytes, entries between position and rewind", {
            let bytes = directory.value
            blackHole(try! CentralDirectory.parseWithBytesRewinding(bytes.span.bytes))
        }),
        ("Fields: LittleEndianBytesReader", { let bytes = directory.value; blackHole(try! CentralDirectory.parseWithLittleEndianReader(bytes.span.bytes)) }),
        ("Bits: Bytes", { let stream = bitStream.value; blackHole(try! BitFields.parseWithBytes(stream.span)) }),
        ("Search 64 KB backwards: lastByteOffset(of:)", {
            let haystack = searchHaystack.value
            blackHole(BytesReader(haystack.span).lastByteOffset(of: searchSignature))
        }),
        ("ByteBuffer: 64 MB through 256 KB", { blackHole(streamThroughByteBuffer(byteBufferFixture.value)) }),
    ] + runsAndCopiesWorkloads().map { workload in
        (workload.name, { blackHole(workload.run()) })
    })
}
