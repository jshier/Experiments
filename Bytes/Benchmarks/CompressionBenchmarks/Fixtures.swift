import Benchmark
import BytesReferenceCodecs
import BytesTestSupport
import Foundation
import zlib

// How these benchmarks keep a run short:
//
// - package-benchmark runs each benchmark in a process of its own, and every process (and the one that lists the
//   benchmarks) runs the whole registration closure before it's told which benchmark to run. Anything made while
//   registering is made once per benchmark in the target, whether that benchmark runs or not: loading the corpus,
//   compressing it, checking every decoder on it, and generating RSA keys took 20 s per process, 830 processes a
//   run. So registration makes names and `Lazy` values only, and a benchmark's `setup` makes what it uses.
// - A benchmark's setup runs its operation once and checks the result (`register`): a broken benchmark fails
//   before it's measured, and the run warms the caches as a warmup iteration would.
// - Iterations stop once p50 is stable: `Fixtures.configuration(forByteCount:)`.

/// Registers `name`: `run` once per iteration on the fixture. Setup makes the fixture, then runs `run` once and
/// checks its result with `check` (that first run is also the warmup: large inputs' configurations have none).
func register<F, R>(
    _ name: String, configuration: Benchmark.Configuration? = nil, _ fixture: Lazy<F>,
    check: @escaping (F, R) -> Bool = { _, _ in true }, _ run: @escaping (F) -> R
) {
    Benchmark(name, configuration: configuration ?? Benchmark.defaultConfiguration) { benchmark in
        let fixture = fixture.value
        for _ in benchmark.scaledIterations {
            blackHole(run(fixture))
        }
    } setup: {
        let fixture = fixture.value
        precondition(check(fixture, run(fixture)), "\(name): wrong result")
    }
}

/// Benchmark inputs: files from the corpus `Tools/corpus fetch` downloads (Silesia, and web assets), plus
/// generated JSON. Missing corpus files are skipped.
enum Fixtures {
    /// An input: its name and size are known when registering (a corpus file's from its size on disk), its bytes
    /// are read on first use.
    final class Sample: @unchecked Sendable { // Read on first use by the one benchmark a process runs, on one thread.
        let name: String
        let byteCount: Int
        private let path: String?
        private var make: (() -> [UInt8])?
        private var loaded: [UInt8]?

        init(name: String, bytes: [UInt8]) {
            self.name = name
            byteCount = bytes.count
            path = nil
            loaded = bytes
        }

        /// Bytes of a size known when registering, made on first use by `make`.
        init(name: String, byteCount: Int, make: @escaping () -> [UInt8]) {
            self.name = name
            self.byteCount = byteCount
            path = nil
            self.make = make
        }

        /// The corpus file at `relativePath` (its first `limit` bytes), or `nil` if the corpus doesn't have it.
        init?(name: String, corpusPath relativePath: String, limit: Int = .max) {
            let path = corpusRoot.appending(path: relativePath).path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else { return nil }
            self.name = name
            byteCount = min(size, limit)
            self.path = path
        }

        var bytes: [UInt8] {
            if let loaded { return loaded }
            let bytes = make.map { $0() } ?? [UInt8](FileManager.default.contents(atPath: path!)!.prefix(byteCount))
            precondition(bytes.count == byteCount)
            loaded = bytes
            make = nil
            return bytes
        }

        /// The size for benchmark names, as in "dickens (10.2 MB)".
        var label: String { Fixtures.label(name, byteCount: byteCount) }
    }

    static func label(_ name: String, byteCount: Int) -> String {
        let size = byteCount >= 1 << 20
            ? String(format: "%.1f MB", Double(byteCount) / Double(1 << 20))
            : String(format: "%.1f KB", Double(byteCount) / 1024)
        return "\(name) (\(size))"
    }

    static var corpusRoot: URL { Corpus.root }

    /// Text, markup, binary, and web assets: what HTTP compression sees, and Silesia's standard files.
    static let corpusFiles = [
        "silesia/dickens", // English text
        "silesia/xml", // XML
        "silesia/x-ray", // 12-bit medical image: barely compressible
        "silesia/samba", // a tar of source code
        "web/Main.js", // a large JavaScript bundle
        "web/Main.css",
    ]

    static let samples: [Sample] = {
        var samples = corpusFiles.compactMap { path in
            Sample(name: String(path.split(separator: "/").last!), corpusPath: path)
        }
        samples.append(Sample(name: "JSON", bytes: json(count: 16)))
        samples.append(Sample(name: "JSON", bytes: json(count: 1_200)))
        return samples
    }()

    /// A Silesia file (its first `limit` bytes), or `nil` if the corpus doesn't have it.
    static func silesia(_ name: String, limit: Int = .max) -> Sample? {
        Sample(name: name, corpusPath: "silesia/\(name)", limit: limit)
    }

    /// An API response: `count` records like `{"id":17,"name":"sensor-17","temperature":21.5,…}`.
    static func json(count: Int) -> [UInt8] {
        var generator = SplitMix64(seed: UInt64(count))
        var text = "["
        for index in 0..<count {
            if index > 0 { text += "," }
            let temperature = Double(generator.next() % 4000) / 100 - 5
            let active = generator.next() & 1 == 0
            text += #"{"id":\#(index),"name":"sensor-\#(index)","temperature":\#(temperature),"#
            text += #""active":\#(active),"tags":["building-\#(generator.next() % 12)","floor-\#(generator.next() % 30)"]}"#
        }
        return Array((text + "]").utf8)
    }

    /// `make()`'s result, cached in the corpus directory under `key`: Google's quality 11 takes tens of seconds
    /// per file, and each benchmark using it runs in a process of its own.
    static func cached(_ key: String, _ make: () -> [UInt8]) -> [UInt8] {
        let url = corpusRoot.appending(path: "cache").appending(path: key)
        if let data = FileManager.default.contents(atPath: url.path) { return [UInt8](data) }
        let bytes = make()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(bytes).write(to: url)
        return bytes
    }

    /// zlib's encoding of `data` at `level`, in `windowBits`' format (-15 raw, 15 zlib, 31 gzip).
    static func zlibCompress(_ data: [UInt8], level: Int32 = 6, windowBits: Int32 = -15) -> [UInt8] {
        Zlib.compress(data, windowBits: windowBits, level: level)
    }

    /// 1 MiB that doesn't compress (SplitMix64, seed 1): what every codec meets in already-compressed files.
    static let random = Sample(name: "random", byteCount: 1 << 20) { noise(1 << 20, seed: 1) }

    /// `count` pseudo-random bytes, 8 per step of SplitMix64 from `seed`.
    static func noise(_ count: Int, seed: UInt64) -> [UInt8] {
        var generator = SplitMix64(seed: seed)
        return generator.packedBytes(count)
    }

    /// The allocation gates' input: a 120 KB API response, then a 1.6 KB one (several blocks of every codec).
    static func gateContent() -> [UInt8] {
        json(count: 1_200) + json(count: 16)
    }

    // MARK: Round trips, for setups' checks

    /// Whether zlib decodes `encoded` (in `windowBits`' format: -15 raw, 15 zlib, 31 gzip) to exactly `expected`.
    static func inflates(_ encoded: ArraySlice<UInt8>, to expected: [UInt8], windowBits: Int32 = -15) -> Bool {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: expected.count + 64)
        var input = Array(encoded)
        let status = input.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                stream.next_in = input.baseAddress
                stream.avail_in = uInt(input.count)
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        return status == Z_STREAM_END && Int(stream.total_out) == expected.count && output.prefix(expected.count).elementsEqual(expected)
    }

    /// Whether Google's brotli decodes `encoded` to exactly `expected`.
    static func brotliDecodes(_ encoded: ArraySlice<UInt8>, to expected: [UInt8]) -> Bool {
        var output = [UInt8](repeating: 0, count: expected.count + 64)
        let input = Array(encoded)
        return GoogleBrotli.decompressIfValid(input, into: &output) == expected.count && output.prefix(expected.count).elementsEqual(expected)
    }

    /// Whether a streaming encoder's total size is within 1% (and 64 bytes) of the one-shot encoding's: the streams
    /// themselves went through a reused window, but a lost match or a broken window shows as size.
    static func sizeMatches(_ streamed: Int, oneShot: Int) -> Bool {
        abs(streamed - oneShot) <= oneShot / 100 + 64
    }

    // MARK: Configurations

    // Timing configurations count no allocations: package-benchmark's malloc interposer costs every allocation time
    // (about 10% on large transfers), which biases comparisons against references that allocate per call (CryptoKit,
    // Google's brotli). Allocations are counted by the zero-malloc gates (`allocationConfiguration`).

    /// Most benchmarks: up to 1,000 samples in 200 ms (operations under 0.2 ms get all 1,000, a 10 ms one 20), and
    /// one warmup iteration after setup's checked run.
    static var defaultConfiguration: Benchmark.Configuration {
        .init(
            metrics: [.wallClock, .instructions, .throughput],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .milliseconds(200),
            maxIterations: 1_000
        )
    }

    /// Inputs of 1 MB and more (2–500 ms an operation): 10 samples, or as many as fit in a second (at least two up
    /// to 500 ms), with setup's checked run as the warmup. Single-threaded operations this long vary by a percent or
    /// two from one iteration to the next, well inside the 5–10% runs drift by; instruction counts not at all.
    static var largeConfiguration: Benchmark.Configuration {
        .init(
            metrics: [.wallClock, .instructions, .throughput],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(1),
            maxIterations: 10
        )
    }

    static func configuration(forByteCount byteCount: Int) -> Benchmark.Configuration {
        byteCount >= 1 << 20 ? largeConfiguration : defaultConfiguration
    }

    /// The zero-malloc gates (`Thresholds/`): allocation counts are deterministic, so a few iterations suffice.
    static var allocationConfiguration: Benchmark.Configuration {
        .init(
            metrics: [.mallocCountTotal],
            warmupIterations: 1,
            maxIterations: 10,
            thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
        )
    }
}

