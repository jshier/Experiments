import Benchmark
import Foundation
import Workloads

func dataFile(_ name: String) -> [UInt8] {
    let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Data/\(name)")
    return Array(try! Data(contentsOf: url))
}

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .seconds(1),
        maxIterations: 1_000
    )

    // MARK: Zip central directory (2,000 entries, ~170 KB): our parser, ported

    let directory = makeCentralDirectory(count: 2_000)
    Benchmark("Zip directory: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithBytes(directory.span.bytes))
        }
    }
    Benchmark("Zip directory: ParserSpan") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithParserSpan(directory.span.bytes))
        }
    }
    Benchmark("Zip directory, fixed-size records: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithBytesRecords(directory.span.bytes))
        }
    }
    Benchmark("Zip directory, fixed-size records: ParserSpan") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithParserSpanRecords(directory.span.bytes))
        }
    }
    // The records declared with `@BinaryRecord` and `@BitFields`; checked against the hand-written parser first.
    precondition(try! CentralDirectory.parseWithBytesMacros(directory.span.bytes) == CentralDirectory.parseWithBytes(directory.span.bytes))
    Benchmark("Zip directory, macro records: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(CentralDirectory.parseWithBytesMacros(directory.span.bytes))
        }
    }

    // MARK: Integers (768 KB of big-endian values)

    var rng = SystemRandomNumberGenerator()
    let integers = (0..<(3 << 18)).map { _ in UInt8.random(in: 0...255, using: &rng) } // 768 KB: both widths fit
    Benchmark("UInt32 big-endian, per value: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(Integers.sum32Bytes(integers.span.bytes))
        }
    }
    Benchmark("UInt32 big-endian, forEach: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Integers.sum32BytesForEach(integers.span.bytes))
        }
    }
    Benchmark("UInt32 big-endian, per value: ParserSpan") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(Integers.sum32ParserSpan(integers.span.bytes))
        }
    }
    Benchmark("24-bit big-endian, per value: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(Integers.sum24Bytes(integers.span.bytes))
        }
    }
    Benchmark("24-bit big-endian, forEach: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Integers.sum24BytesForEach(integers.span.bytes))
        }
    }
    Benchmark("24-bit big-endian, per value: ParserSpan (byteCount: 3)") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(Integers.sum24ParserSpan(integers.span.bytes))
        }
    }

    // MARK: QOI decoding: swift-binary-parsing's example, ported

    for file in ["antelope.qoi", "tricolor.qoi"] {
        let data = dataFile(file)
        Benchmark("QOI \(file): swift-binary-parsing example") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(ExampleQOI(parsing: data).pixels.count)
            }
        }
        Benchmark("QOI \(file): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(QOI.decodeWithBytes(data.span.bytes).pixels.count)
            }
        }
        // The algorithm the example and the ParserSpan port use: runs a pixel per iteration.
        Benchmark("QOI \(file): Bytes, pixel-at-a-time runs") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(QOI.decodeWithBytesPixelRuns(data.span.bytes).pixels.count)
            }
        }
        Benchmark("QOI \(file): ParserSpan, same algorithm") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(QOI.decodeWithParserSpan(data.span.bytes).pixels.count)
            }
        }
    }

    // MARK: LZ4 decompression: swift-binary-parsing's example, ported

    for file in ["swift-help.lz4", "tricolor.qoi.lz4"] {
        let data = dataFile(file)
        Benchmark("LZ4 \(file): swift-binary-parsing example") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(ExampleLZ4(parsing: data).data.count)
            }
        }
        Benchmark("LZ4 \(file): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(LZ4.decodeWithBytes(data.span.bytes).count)
            }
        }
        // The algorithm the ParserSpan port uses: exact literal copies.
        Benchmark("LZ4 \(file): Bytes, exact literal copies") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(LZ4.decodeWithBytesExactLiterals(data.span.bytes).count)
            }
        }
        Benchmark("LZ4 \(file): ParserSpan, same algorithm") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(LZ4.decodeWithParserSpan(data.span.bytes).count)
            }
        }
    }

    // MARK: ELF, PNG, PCAPNG, and binary property lists: swift-binary-parsing's examples, ported
    //
    // Each port builds the example's own result types, so both sides allocate the same results. Each pair is
    // checked for the same result once, here (the tests compare every value).

    // helloworld (352 bytes, 32-bit) as it is; swift-help (10.6 MB, 64-bit: 9 program headers, 56 sections)
    // decompressed from swift-help.lz4, the same bytes as the example's ELF/swift-help.
    let compressedHelp = dataFile("swift-help.lz4")
    let swiftHelp = try! LZ4.decodeWithBytes(compressedHelp.span.bytes)
    for (file, data) in [("helloworld", dataFile("helloworld")), ("swift-help", swiftHelp)] {
        precondition(try! String(describing: ELF.parseWithBytes(data.span.bytes)) == String(describing: ExampleELF(parsing: data)))
        Benchmark("ELF \(file): swift-binary-parsing example") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(ExampleELF(parsing: data).sectionHeaders.count)
            }
        }
        Benchmark("ELF \(file): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(ELF.parseWithBytes(data.span.bytes).sectionHeaders.count)
            }
        }
    }
    // Every section's name (56), from the headers parsed once: the example's deferred parsing.
    let helpHeaders = try! ELF.parseWithBytes(swiftHelp.span.bytes)
    let helpData = Data(swiftHelp)
    for index in helpHeaders.sectionHeaders.indices {
        precondition(ELF.sectionName(at: index, of: helpHeaders, in: swiftHelp.span.bytes) == helpHeaders.sectionName(at: index, data: helpData))
    }
    Benchmark("ELF swift-help, section names: swift-binary-parsing example") { benchmark in
        for _ in benchmark.scaledIterations {
            for index in helpHeaders.sectionHeaders.indices {
                blackHole(helpHeaders.sectionName(at: index, data: helpData))
            }
        }
    }
    Benchmark("ELF swift-help, section names: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            for index in helpHeaders.sectionHeaders.indices {
                blackHole(ELF.sectionName(at: index, of: helpHeaders, in: swiftHelp.span.bytes))
            }
        }
    }

    // tiny.png (10 KB, 7 chunks), tricolor.png (31 KB, 8), antelope.png (4.6 MB, 288: 281 IDAT chunks of 16 KB,
    // each copied into an array by both, as the example's model has it).
    for file in ["tiny.png", "tricolor.png", "antelope.png"] {
        let data = dataFile(file)
        // The example's chunks describe themselves by kind and size: enough to check here.
        precondition(try! String(describing: PNG.parseWithBytes(data.span.bytes)) == String(describing: ExamplePNG(parsing: data)))
        Benchmark("PNG \(file): swift-binary-parsing example") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(ExamplePNG(parsing: data).chunks.count)
            }
        }
        Benchmark("PNG \(file): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(PNG.parseWithBytes(data.span.bytes).chunks.count)
            }
        }
    }

    // sample.pcap (224 bytes: a section header and an interface), and a synthetic capture of 1,000 packets
    // (60–1,459 bytes each, 746 KB) with comment, flags, and hash options.
    for (name, data) in [("sample.pcap", dataFile("sample.pcap")), ("1,000 packets", makePCAPNG(packetCount: 1_000))] {
        precondition(try! String(describing: PCAPNG.parseWithBytes(data.span.bytes)) == String(describing: ExamplePCAPNG(parsing: data)))
        Benchmark("PCAPNG \(name): swift-binary-parsing example") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(ExamplePCAPNG(parsing: data).blocks.count)
            }
        }
        Benchmark("PCAPNG \(name): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(PCAPNG.parseWithBytes(data.span.bytes).blocks.count)
            }
        }
    }

    // sample.plist (1 KB, 71 objects), and a synthetic one written by Foundation: 1,000 dictionaries of 9 values
    // (152 KB, 8,990 objects).
    for (name, data) in [("sample.plist", dataFile("sample.plist")), ("1,000 records", makeBinaryPList(recordCount: 1_000))] {
        // Dictionaries describe themselves in no fixed order: the offset tables and the top object's size here.
        let parsed = try! BPList.parseWithBytes(data.span.bytes), expected = try! ExampleBPList(parsing: data)
        precondition(parsed.trailer.offsetTable == expected.trailer.offsetTable)
        precondition(parsed.topObject.childCount == expected.topObject.childCount)
        Benchmark("BPList \(name): swift-binary-parsing example") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(ExampleBPList(parsing: data).topObject.childCount)
            }
        }
        Benchmark("BPList \(name): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                try blackHole(BPList.parseWithBytes(data.span.bytes).topObject.childCount)
            }
        }
    }

    // MARK: MQTT PUBLISH packets (10,000, 2.2 MB): our parser, ported

    let publishes = makeMQTTPublishStream(packetCount: 10_000)
    precondition(try! MQTTPublish.parseWithBytes(publishes.span.bytes) == MQTTPublish.parseWithParserSpan(publishes.span.bytes))
    Benchmark("MQTT PUBLISH stream: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(MQTTPublish.parseWithBytes(publishes.span.bytes))
        }
    }
    Benchmark("MQTT PUBLISH stream: ParserSpan") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(MQTTPublish.parseWithParserSpan(publishes.span.bytes))
        }
    }
}
