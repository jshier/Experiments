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
}
