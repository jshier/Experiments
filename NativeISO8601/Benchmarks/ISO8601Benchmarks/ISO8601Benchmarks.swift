import Benchmark
import Foundation
import NativeISO8601

let benchmarks: @Sendable () -> Void = {
    // Each iteration parses 1,000 timestamps; results are reported per parse.
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuTotal, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 10,
        scalingFactor: .kilo,
        maxDuration: .seconds(2),
        maxIterations: 1_000
    )

    let samples: [(name: String, input: String)] = [
        ("UTC", "2024-01-15T10:30:45Z"),
        ("fractional", "2024-01-15T10:30:45.123Z"),
        ("offset", "2024-01-15T10:30:45+05:30"),
    ]

    // A varied corpus so branch prediction can't memorize a single input.
    let corpus: [String] = (0..<1_000).map { index in
        let date = Date(timeIntervalSince1970: Double(index) * 7_919_123.0 + 0.125 * Double(index % 8))
        let formatter = ISO8601DateFormatter()
        if index.isMultiple(of: 2) { formatter.formatOptions.insert(.withFractionalSeconds) }
        if index.isMultiple(of: 3) { formatter.timeZone = TimeZone(secondsFromGMT: (index % 24 - 12) * 3600) }
        return formatter.string(from: date)
    }

    // MARK: NativeISO8601

    // The harness's own per-parse cost (input copy, result sink), to subtract from the rows below.
    Benchmark("Floor: harness overhead") { benchmark in
        let input = samples[0].input
        for _ in benchmark.scaledIterations {
            blackHole(identity(input).utf8.count)
        }
    }

    for (name, input) in samples {
        Benchmark("Native String (\(name))") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(try ISO8601.date(from: identity(input)))
            }
        }
    }

    Benchmark("Floor: String.utf8.span") { benchmark in
        let input = samples[0].input
        for _ in benchmark.scaledIterations {
            let input = identity(input)
            blackHole(input.utf8.span.count)
        }
    }

    Benchmark("Floor: Data.bytes") { benchmark in
        let data = Data(samples[0].input.utf8)
        for _ in benchmark.scaledIterations {
            let data = identity(data)
            blackHole(data.bytes.byteCount)
        }
    }

    Benchmark("Floor: Data.span") { benchmark in
        let data = Data(samples[0].input.utf8)
        for _ in benchmark.scaledIterations {
            let data = identity(data)
            blackHole(data.span.count)
        }
    }

    Benchmark("Native Data (UTC)") { benchmark in
        let data = Data(samples[0].input.utf8)
        for _ in benchmark.scaledIterations {
            blackHole(try ISO8601.date(from: identity(data)))
        }
    }

    // Span inputs, acquired once outside the loop: the minimum-overhead way to call the parser,
    // e.g. when slicing timestamps out of a larger buffer such as a JSON document.
    Benchmark("Native Span<UInt8> (UTC)") { benchmark in
        let storage = Array(samples[0].input.utf8)
        let span = storage.span
        for _ in benchmark.scaledIterations {
            blackHole(try ISO8601.date(from: span))
        }
    }

    Benchmark("Native RawSpan (UTC)") { benchmark in
        let storage = Array(samples[0].input.utf8)
        let bytes = storage.span.bytes
        for _ in benchmark.scaledIterations {
            blackHole(try ISO8601.date(from: bytes))
        }
    }

    Benchmark("Native UTF8Span (UTC)") { benchmark in
        let input = samples[0].input
        let text = input.utf8Span
        for _ in benchmark.scaledIterations {
            blackHole(try ISO8601.date(from: text))
        }
    }

    // Span acquired from a fresh [UInt8] copy every iteration, matching the String/Data rows.
    Benchmark("Native [UInt8].span (UTC)") { benchmark in
        let bytes = Array(samples[0].input.utf8)
        for _ in benchmark.scaledIterations {
            let bytes = identity(bytes)
            blackHole(try ISO8601.date(from: bytes.span))
        }
    }

    // General-path forms: everything the SWAR prefix doesn't cover.
    let generalSamples: [(name: String, input: String)] = [
        ("basic format", "20240115T103045Z"),
        ("expanded year", "+002024-01-15T10:30:45Z"),
        ("week date", "2024-W03-1T10:30:45Z"),
        ("reduced: year-month", "2024-01"),
    ]
    for (name, input) in generalSamples {
        Benchmark("Native String (\(name))") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(try ISO8601.date(from: identity(input)))
            }
        }
    }

    // The components API, which also builds an `ISO8601.Timestamp`.
    Benchmark("Native Timestamp (offset)") { benchmark in
        let input = samples[2].input
        for _ in benchmark.scaledIterations {
            blackHole(try ISO8601.timestamp(from: identity(input)))
        }
    }

    Benchmark("Native String (mixed corpus)") { benchmark in
        for _ in 0..<benchmark.scaledIterations.count / corpus.count {
            for input in corpus {
                blackHole(try ISO8601.date(from: input))
            }
        }
    }

    // MARK: Foundation

    for (name, input) in samples {
        Benchmark("ISO8601DateFormatter (\(name))") { benchmark in
            let formatter = ISO8601DateFormatter()
            if name == "fractional" { formatter.formatOptions.insert(.withFractionalSeconds) }
            for _ in benchmark.scaledIterations {
                blackHole(formatter.date(from: identity(input))!)
            }
        }
    }

    Benchmark("ISO8601DateFormatter (mixed corpus)") { benchmark in
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        for _ in 0..<benchmark.scaledIterations.count / corpus.count {
            for input in corpus {
                // The formatter needs to be told whether to expect fractional seconds.
                blackHole((input.utf8.contains(UInt8(ascii: ".")) ? fractional : plain).date(from: input)!)
            }
        }
    }

    for (name, input) in samples {
        Benchmark("Date.ISO8601FormatStyle (\(name))") { benchmark in
            let style = Date.ISO8601FormatStyle(includingFractionalSeconds: name == "fractional")
            for _ in benchmark.scaledIterations {
                blackHole(try style.parse(identity(input)))
            }
        }
    }
}
