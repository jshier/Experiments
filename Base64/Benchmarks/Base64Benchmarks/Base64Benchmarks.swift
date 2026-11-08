import Base64
import Benchmark
import Bytes
import Foundation

extension BenchmarkMetric {
    /// Input bytes encoded per second.
    static let inputThroughput = BenchmarkMetric.custom("Throughput (MB/s)", polarity: .prefersLarger, useScalingFactor: false)
}

// MARK: - Fixtures

/// Input sizes: from short (a token, a header value) to beyond every cache (64 MB in, 85 MB out).
let sizes: [(label: String, count: Int)] = [
    ("64 B", 64), ("1 KB", 1 << 10), ("16 KB", 16 << 10), ("1 MB", 1 << 20), ("64 MB", 64 << 20),
]

/// Each measured iteration encodes at least this many bytes, repeating short inputs, so the clock
/// resolves it.
let bytesPerIteration = 4 << 20

/// Random input of each size, and an exactly sized output buffer for each.
let inputs: [Int: [UInt8]] = Dictionary(uniqueKeysWithValues: sizes.map { size in
    var generator = SystemRandomNumberGenerator()
    return (size.count, (0..<size.count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
})
let inputData: [Int: Data] = inputs.mapValues { Data($0) }
nonisolated(unsafe) var outputs: [Int: [UInt8]] = Dictionary(uniqueKeysWithValues: sizes.map {
    ($0.count, [UInt8](repeating: 0, count: Base64.encodedByteCount(of: $0.count)))
})

func repetitions(_ count: Int) -> Int { max(1, bytesPerIteration / count) }

// MARK: - Encoders

/// Bytes: `BytesReader` → `Base64.encode` → `BytesWriter`, into a preallocated buffer.
func encodeWithBytes(_ count: Int) {
    let input = inputs[count]!
    var output = outputs.removeValue(forKey: count)!
    for _ in 0..<repetitions(count) {
        var span = output.mutableSpan
        var writer = BytesWriter(&span)
        var reader = BytesReader(input.span)
        try! Base64.encode(&reader, into: &writer)
    }
    outputs[count] = output
}

/// The usual scalar encoder, for comparison: a 64-character table, one lookup per character. Each lookup
/// is a load from an index computed per character (a gather), so the loop doesn't vectorize.
func encodeScalar(_ input: Span<UInt8>, into output: inout MutableSpan<UInt8>) {
    let table: InlineArray<64, UInt8> = [
        65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90,
        97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117,
        118, 119, 120, 121, 122, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 43, 47,
    ]
    let groups = input.count / 3
    for group in 0..<groups {
        let b0 = input[3 * group], b1 = input[3 * group + 1], b2 = input[3 * group + 2]
        output[4 * group] = table[Int(b0 >> 2)]
        output[4 * group + 1] = table[Int((b0 & 3) << 4 | b1 >> 4)]
        output[4 * group + 2] = table[Int((b1 & 15) << 2 | b2 >> 6)]
        output[4 * group + 3] = table[Int(b2 & 63)]
    }
    let index = groups * 4
    switch input.count % 3 {
    case 1:
        let b0 = input[groups * 3]
        output[index] = table[Int(b0 >> 2)]
        output[index + 1] = table[Int((b0 & 3) << 4)]
        output[index + 2] = 61
        output[index + 3] = 61
    case 2:
        let b0 = input[groups * 3], b1 = input[groups * 3 + 1]
        output[index] = table[Int(b0 >> 2)]
        output[index + 1] = table[Int((b0 & 3) << 4 | b1 >> 4)]
        output[index + 2] = table[Int((b1 & 15) << 2)]
        output[index + 3] = 61
    default:
        break
    }
}

func encodeWithScalarTable(_ count: Int) {
    let input = inputs[count]!
    var output = outputs.removeValue(forKey: count)!
    for _ in 0..<repetitions(count) {
        var span = output.mutableSpan
        encodeScalar(input.span, into: &span)
    }
    outputs[count] = output
}

/// Foundation: `Data.base64EncodedData()`, which allocates its result.
func encodeWithFoundation(_ count: Int) {
    let data = inputData[count]!
    for _ in 0..<repetitions(count) {
        blackHole(data.base64EncodedData())
    }
}

/// `Base64.encodedString`: one allocation, the `String`.
func encodeToString(_ count: Int) {
    let input = inputs[count]!
    for _ in 0..<repetitions(count) {
        blackHole(Base64.encodedString(input.span.bytes))
    }
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = { registerBenchmarks() }

func registerBenchmarks() {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .instructions, .mallocCountTotal, .inputThroughput],
        units: [.inputThroughput: .count], // Unscaled, so MB/s reads as labeled.
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .seconds(1),
        maxIterations: 1_000
    )

    // The encoders agree, once, before anything is measured.
    for (_, count) in sizes where count < 64 << 20 {
        encodeWithBytes(count)
        let encoded = outputs[count]!
        encodeWithScalarTable(count)
        precondition(outputs[count]! == encoded, "scalar encoder differs at \(count)")
        precondition(Array(inputData[count]!.base64EncodedData()) == encoded, "Foundation differs at \(count)")
    }

    let encoders: [(name: String, run: (Int) -> Void)] = [
        ("Bytes (BytesReader → BytesWriter)", encodeWithBytes),
        ("Scalar table", encodeWithScalarTable),
        ("Foundation base64EncodedData", encodeWithFoundation),
        ("Bytes encodedString", encodeToString),
    ]
    for (label, count) in sizes {
        for encoder in encoders {
            Benchmark("Encode \(label): \(encoder.name)") { (benchmark: Benchmark) in
                for _ in benchmark.scaledIterations {
                    let clock = ContinuousClock()
                    let start = clock.now
                    encoder.run(count)
                    let seconds: Double = (clock.now - start) / .seconds(1)
                    benchmark.measurement(.inputThroughput, Int(Double(count * repetitions(count)) / seconds / 1e6))
                }
            }
        }
    }

    // Allocation checks: encoding into a buffer must not allocate, at any size. Static thresholds of zero
    // (`Thresholds/`), so `swift package benchmark thresholds check --filter 'Allocations:.*'` fails if it
    // does. Warmup runs the fixtures' lazy initializers.
    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    // No spaces: `thresholds update` writes "_" for them in file names, but `thresholds check` looks files
    // up by the unaltered name (benchmark 1.38.1, ordo-one/benchmark#373).
    for (label, count) in sizes {
        Benchmark("Allocations:Encode_\(label.replacing(" ", with: "_"))", configuration: zeroAllocations) { (benchmark: Benchmark) in
            for _ in benchmark.scaledIterations {
                encodeWithBytes(count)
            }
        }
    }
}
