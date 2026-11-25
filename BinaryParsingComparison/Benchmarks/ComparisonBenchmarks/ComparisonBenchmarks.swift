import Benchmark
import BytesTestSupport
import Foundation
import Workloads

/// A test file: from the package's Data/, or from the repository's TestData/ (swift-binary-parsing's samples and
/// swift-help.lz4, made by `Tools/test-data fetch swift-binary-parsing swift-help-lz4`).
func dataFile(_ name: String) -> [UInt8] {
    let local = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Data/\(name)")
    for url in [local] + ["swift-binary-parsing", "swift-help-lz4"].map({ TestData.directory(set: $0).appending(path: name) }) {
        if let data = try? Data(contentsOf: url) { return Array(data) }
    }
    fatalError("\(name) is missing: run Tools/test-data fetch swift-binary-parsing swift-help-lz4")
}

// Fixtures are `Lazy` (BytesTestSupport): made on first use. The benchmark tool starts this executable once to list
// the benchmarks and again for each benchmark, and every start runs the registration closure: fixtures (and their
// checks) are made in the setup of the benchmarks that use them, so each process makes only its own.

/// A test file, read on first use.
func lazyFile(_ name: String) -> Lazy<[UInt8]> { Lazy { dataFile(name) } }

// MARK: - Fixtures

/// 2,000 entries, ~170 KB.
let directoryFixture = Lazy { makeCentralDirectory(count: 2_000) }
/// The macro-declared records give the hand-written parser's result.
let checkedMacroRecords = Lazy {
    let directory = directoryFixture.value
    precondition(try! CentralDirectory.parseWithBytesMacros(directory.span.bytes) == CentralDirectory.parseWithBytes(directory.span.bytes))
}

/// 768 KB of random bytes: both integer widths fit.
let integersFixture = Lazy {
    var rng = SystemRandomNumberGenerator()
    return (0..<(3 << 18)).map { _ in UInt8.random(in: 0...255, using: &rng) }
}

/// swift-help (10.6 MB, 64-bit ELF: 9 program headers, 56 sections) decompressed from swift-help.lz4, the same
/// bytes as the example's ELF/swift-help.
let swiftHelpFixture = Lazy {
    let compressed = dataFile("swift-help.lz4")
    return try! LZ4.decodeWithBytes(compressed.span.bytes)
}

/// swift-help's headers, parsed once, and the same bytes as `Data`, for the section-name benchmarks; each name
/// checked against the example's.
let helpHeadersFixture = Lazy {
    let swiftHelp = swiftHelpFixture.value
    let headers = try! ELF.parseWithBytes(swiftHelp.span.bytes)
    let data = Data(swiftHelp)
    for index in headers.sectionHeaders.indices {
        precondition(ELF.sectionName(at: index, of: headers, in: swiftHelp.span.bytes) == headers.sectionName(at: index, data: data))
    }
    return (headers: headers, data: data)
}

/// 10,000 PUBLISH packets, 2.2 MB; both parsers checked for the same result.
let publishesFixture = Lazy {
    let stream = makeMQTTPublishStream(packetCount: 10_000)
    precondition(try! MQTTPublish.parseWithBytes(stream.span.bytes) == MQTTPublish.parseWithParserSpan(stream.span.bytes))
    return stream
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    // Registration only: fixtures are `Lazy`, made (and checked) in each benchmark's setup.
    //
    // Iterations take from 1 µs (a 352-byte ELF header) to 190 ms (the example's LZ4 decoder on swift-help):
    // 100 samples or a second, whichever comes first (the slowest few get 5–25, as they did with 1,000 allowed).
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .seconds(1),
        maxIterations: 100
    )

    // MARK: Zip central directory (2,000 entries, ~170 KB): our parser, ported

    let prepareDirectory: () async throws -> Void = { _ = directoryFixture.value }
    Benchmark("Zip directory: Bytes", closure: { benchmark in
        let directory = directoryFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithBytes(directory.span.bytes))
        }
    }, setup: prepareDirectory)
    Benchmark("Zip directory: ParserSpan", closure: { benchmark in
        let directory = directoryFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithParserSpan(directory.span.bytes))
        }
    }, setup: prepareDirectory)
    Benchmark("Zip directory, fixed-size records: Bytes", closure: { benchmark in
        let directory = directoryFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithBytesRecords(directory.span.bytes))
        }
    }, setup: prepareDirectory)
    Benchmark("Zip directory, fixed-size records: ParserSpan", closure: { benchmark in
        let directory = directoryFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithParserSpanRecords(directory.span.bytes))
        }
    }, setup: prepareDirectory)
    // The records declared with `@BinaryRecord` and `@BitFields`; checked against the hand-written parser first.
    Benchmark("Zip directory, macro records: Bytes", closure: { benchmark in
        let directory = directoryFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithBytesMacros(directory.span.bytes))
        }
    }, setup: { checkedMacroRecords.value })

    // MARK: Integers (768 KB of big-endian values)

    let prepareIntegers: () async throws -> Void = { _ = integersFixture.value }
    Benchmark("UInt32 big-endian, per value: Bytes", closure: { benchmark in
        let integers = integersFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(Integers.sum32Bytes(integers.span.bytes))
        }
    }, setup: prepareIntegers)
    Benchmark("UInt32 big-endian, forEach: Bytes", closure: { benchmark in
        let integers = integersFixture.value
        for _ in benchmark.scaledIterations {
            blackHole(Integers.sum32BytesForEach(integers.span.bytes))
        }
    }, setup: prepareIntegers)
    Benchmark("UInt32 big-endian, per value: ParserSpan", closure: { benchmark in
        let integers = integersFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(Integers.sum32ParserSpan(integers.span.bytes))
        }
    }, setup: prepareIntegers)
    Benchmark("24-bit big-endian, per value: Bytes", closure: { benchmark in
        let integers = integersFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(Integers.sum24Bytes(integers.span.bytes))
        }
    }, setup: prepareIntegers)
    Benchmark("24-bit big-endian, forEach: Bytes", closure: { benchmark in
        let integers = integersFixture.value
        for _ in benchmark.scaledIterations {
            blackHole(Integers.sum24BytesForEach(integers.span.bytes))
        }
    }, setup: prepareIntegers)
    Benchmark("24-bit big-endian, per value: ParserSpan (byteCount: 3)", closure: { benchmark in
        let integers = integersFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(Integers.sum24ParserSpan(integers.span.bytes))
        }
    }, setup: prepareIntegers)

    // MARK: QOI decoding: swift-binary-parsing's example, ported

    for file in ["antelope.qoi", "tricolor.qoi"] {
        let fixture = lazyFile(file)
        let prepare: () async throws -> Void = { _ = fixture.value }
        Benchmark("QOI \(file): swift-binary-parsing example", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(ExampleQOI(parsing: data).pixels.count)
            }
        }, setup: prepare)
        Benchmark("QOI \(file): Bytes", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(QOI.decodeWithBytes(data.span.bytes).pixels.count)
            }
        }, setup: prepare)
        // The algorithm the example and the ParserSpan port use: runs a pixel per iteration.
        Benchmark("QOI \(file): Bytes, pixel-at-a-time runs", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(QOI.decodeWithBytesPixelRuns(data.span.bytes).pixels.count)
            }
        }, setup: prepare)
        Benchmark("QOI \(file): ParserSpan, same algorithm", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(QOI.decodeWithParserSpan(data.span.bytes).pixels.count)
            }
        }, setup: prepare)
    }

    // MARK: LZ4 decompression: swift-binary-parsing's example, ported

    for file in ["swift-help.lz4", "tricolor.qoi.lz4"] {
        let fixture = lazyFile(file)
        let prepare: () async throws -> Void = { _ = fixture.value }
        Benchmark("LZ4 \(file): swift-binary-parsing example", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(ExampleLZ4(parsing: data).data.count)
            }
        }, setup: prepare)
        Benchmark("LZ4 \(file): Bytes", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(LZ4.decodeWithBytes(data.span.bytes).count)
            }
        }, setup: prepare)
        // The algorithm the ParserSpan port uses: exact literal copies.
        Benchmark("LZ4 \(file): Bytes, exact literal copies", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(LZ4.decodeWithBytesExactLiterals(data.span.bytes).count)
            }
        }, setup: prepare)
        Benchmark("LZ4 \(file): ParserSpan, same algorithm", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(LZ4.decodeWithParserSpan(data.span.bytes).count)
            }
        }, setup: prepare)
    }

    // MARK: ELF, PNG, PCAPNG, and binary property lists: swift-binary-parsing's examples, ported

    //
    // Each port builds the example's own result types, so both sides allocate the same results. Each pair is
    // checked for the same result once, in its benchmarks' setup (the tests compare every value).

    // helloworld (352 bytes, 32-bit) as it is; swift-help (10.6 MB, 64-bit: 9 program headers, 56 sections)
    // decompressed from swift-help.lz4, the same bytes as the example's ELF/swift-help.
    for (file, fixture) in [("helloworld", lazyFile("helloworld")), ("swift-help", swiftHelpFixture)] {
        let checked = Lazy {
            let data = fixture.value
            precondition(try! String(describing: ELF.parseWithBytes(data.span.bytes)) == String(describing: ExampleELF(parsing: data)))
        }
        Benchmark("ELF \(file): swift-binary-parsing example", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(ExampleELF(parsing: data).sectionHeaders.count)
            }
        }, setup: { checked.value })
        Benchmark("ELF \(file): Bytes", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(ELF.parseWithBytes(data.span.bytes).sectionHeaders.count)
            }
        }, setup: { checked.value })
    }
    // Every section's name (56), from the headers parsed once: the example's deferred parsing.
    Benchmark("ELF swift-help, section names: swift-binary-parsing example", closure: { benchmark in
        let (helpHeaders, helpData) = helpHeadersFixture.value
        for _ in benchmark.scaledIterations {
            for index in helpHeaders.sectionHeaders.indices {
                blackHole(helpHeaders.sectionName(at: index, data: helpData))
            }
        }
    }, setup: { _ = helpHeadersFixture.value })
    Benchmark("ELF swift-help, section names: Bytes", closure: { benchmark in
        let helpHeaders = helpHeadersFixture.value.headers
        let swiftHelp = swiftHelpFixture.value
        for _ in benchmark.scaledIterations {
            for index in helpHeaders.sectionHeaders.indices {
                blackHole(ELF.sectionName(at: index, of: helpHeaders, in: swiftHelp.span.bytes))
            }
        }
    }, setup: { _ = helpHeadersFixture.value })

    // tiny.png (10 KB, 7 chunks), tricolor.png (31 KB, 8), antelope.png (4.6 MB, 288: 281 IDAT chunks of 16 KB,
    // each copied into an array by both, as the example's model has it).
    for file in ["tiny.png", "tricolor.png", "antelope.png"] {
        let fixture = lazyFile(file)
        // The example's chunks describe themselves by kind and size: enough to check here.
        let checked = Lazy {
            let data = fixture.value
            precondition(try! String(describing: PNG.parseWithBytes(data.span.bytes)) == String(describing: ExamplePNG(parsing: data)))
        }
        Benchmark("PNG \(file): swift-binary-parsing example", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(ExamplePNG(parsing: data).chunks.count)
            }
        }, setup: { checked.value })
        Benchmark("PNG \(file): Bytes", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(PNG.parseWithBytes(data.span.bytes).chunks.count)
            }
        }, setup: { checked.value })
    }

    // sample.pcap (224 bytes: a section header and an interface), and a synthetic capture of 1,000 packets
    // (60–1,459 bytes each, 746 KB) with comment, flags, and hash options.
    for (name, fixture) in [("sample.pcap", lazyFile("sample.pcap")), ("1,000 packets", Lazy { makePCAPNG(packetCount: 1_000) })] {
        let checked = Lazy {
            let data = fixture.value
            precondition(try! String(describing: PCAPNG.parseWithBytes(data.span.bytes)) == String(describing: ExamplePCAPNG(parsing: data)))
        }
        Benchmark("PCAPNG \(name): swift-binary-parsing example", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(ExamplePCAPNG(parsing: data).blocks.count)
            }
        }, setup: { checked.value })
        Benchmark("PCAPNG \(name): Bytes", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(PCAPNG.parseWithBytes(data.span.bytes).blocks.count)
            }
        }, setup: { checked.value })
    }

    // sample.plist (1 KB, 71 objects), and a synthetic one written by Foundation: 1,000 dictionaries of 9 values
    // (152 KB, 8,990 objects).
    for (name, fixture) in [("sample.plist", lazyFile("sample.plist")), ("1,000 records", Lazy { makeBinaryPList(recordCount: 1_000) })] {
        // Dictionaries describe themselves in no fixed order: the offset tables and the top object's size here.
        let checked = Lazy {
            let data = fixture.value
            let parsed = try! BPList.parseWithBytes(data.span.bytes), expected = try! ExampleBPList(parsing: data)
            precondition(parsed.trailer.offsetTable == expected.trailer.offsetTable)
            precondition(parsed.topObject.childCount == expected.topObject.childCount)
        }
        Benchmark("BPList \(name): swift-binary-parsing example", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(ExampleBPList(parsing: data).topObject.childCount)
            }
        }, setup: { checked.value })
        Benchmark("BPList \(name): Bytes", closure: { benchmark in
            let data = fixture.value
            for _ in benchmark.scaledIterations {
                try blackHole(BPList.parseWithBytes(data.span.bytes).topObject.childCount)
            }
        }, setup: { checked.value })
    }

    // MARK: MQTT PUBLISH packets (10,000, 2.2 MB): our parser, ported

    Benchmark("MQTT PUBLISH stream: Bytes", closure: { benchmark in
        let publishes = publishesFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(MQTTPublish.parseWithBytes(publishes.span.bytes))
        }
    }, setup: { _ = publishesFixture.value })
    Benchmark("MQTT PUBLISH stream: ParserSpan", closure: { benchmark in
        let publishes = publishesFixture.value
        for _ in benchmark.scaledIterations {
            try blackHole(MQTTPublish.parseWithParserSpan(publishes.span.bytes))
        }
    }, setup: { _ = publishesFixture.value })
}
