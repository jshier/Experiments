import Benchmark
import Foundation
@_spi(Benchmarking) import NativeAEA
import System

/// The synthetic archive `Tools/test-data fetch nativeaea-synthetic` makes, and optionally a real one (Xcode's)
/// named by `NATIVEAEA_ARCHIVE` (with `NATIVEAEA_SIGN_PUB` if its certificate chain isn't Apple's).
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "TestData/nativeaea-synthetic")
    static let synthetic = directory.appending(path: "synthetic.aea")
    static let syntheticKey = directory.appending(path: "signing.pub.pem")
    /// Extractions go here, each iteration into its own directory, removed after the benchmark.
    static let output = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "NativeAEABenchmarks.noindex")

    static func open(_ url: URL, key: URL?) throws -> AEAArchive {
        try AEAArchive(url: url, signingKey: key.map { try AEASigningKey.publicKey(contentsOf: $0) } ?? .certificateChain)
    }

    static var archives: [(name: String, url: URL, key: URL?)] {
        var archives: [(String, URL, URL?)] = []
        if FileManager.default.fileExists(atPath: synthetic.path) {
            archives.append(("synthetic", synthetic, syntheticKey))
        } else {
            print("NativeAEABenchmarks: run `Tools/test-data fetch nativeaea-synthetic` for the synthetic archive's benchmarks")
        }
        if let path = ProcessInfo.processInfo.environment["NATIVEAEA_ARCHIVE"] {
            archives.append(("Xcode", URL(fileURLWithPath: path), ProcessInfo.processInfo.environment["NATIVEAEA_SIGN_PUB"].map { URL(fileURLWithPath: $0) }))
        }
        return archives
    }

    static func removeOutput() {
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        // Extracted files and directories can be read-only.
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+w", output.path]
        try? chmod.run()
        chmod.waitUntilExit()
        try? FileManager.default.removeItem(at: output)
    }
}

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuTotal, .instructions, .mallocCountTotal, .peakMemoryResident],
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: .seconds(3),
        maxIterations: 20
    )

    // No malloc counts where the pipeline's threads run: package-benchmark's malloc interposer traps when a thread
    // exits (`count_free` → `_tlv_get_addr` → `calloc`, in `_pthread_tsd_cleanup`). The pipeline's allocations are
    // counted per segment by the single-threaded benchmarks.
    let threadedMetrics: [BenchmarkMetric] = [.wallClock, .cpuTotal, .peakMemoryResident]

    for (name, url, key) in Fixtures.archives {
        // MARK: Container

        Benchmark("Open and verify: \(name)") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(try Fixtures.open(url, key: key))
            }
        }

        // MARK: Segments and headers

        let archive = try! Fixtures.open(url, key: key)
        let segment = 0
        let stored = try! archive.storedBytes(of: segment)
        var decoded = [UInt8](repeating: 0, count: archive.segments[segment].rawSize)
        try! SegmentDecoding(archive, backend: .system).decode(stored, into: &decoded)

        for backend in SegmentDecoderBackend.allCases {
            // One 16 MiB segment, decoded: throughput is 16 MiB per iteration.
            Benchmark(
                "Decode segment 0: \(name): \(backend)",
                configuration: .init(metrics: [.wallClock, .cpuTotal, .instructions, .mallocCountTotal, .throughput])
            ) { benchmark in
                let decoder = SegmentDecoding(archive, backend: backend)
                var output = [UInt8](repeating: 0, count: decoded.count)
                try decoder.decode(stored, into: &output)
                precondition(output == decoded)
                benchmark.startMeasurement()
                for _ in benchmark.scaledIterations {
                    try decoder.decode(stored, into: &output)
                }
            }
        }

        // Headers in the first segment, parsed (blobs skipped): the walker's own work per entry.
        let headerCount: Int = {
            var count = 0
            var position = 0
            decoded.span.bytes.withUnsafeBytes { bytes in
                while position + 6 <= bytes.count {
                    guard let size = try? AppleArchive.headerByteCount(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: bytes[position...]))),
                          position + size <= bytes.count,
                          let header = try? AppleArchive.parseHeader(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: bytes[position..<(position + size)])))
                    else { break }
                    position += size + header.blobByteCount
                    count += 1
                }
            }
            return count
        }()
        Benchmark("Parse \(headerCount) headers: \(name) segment 0") { benchmark in
            for _ in benchmark.scaledIterations {
                var position = 0
                try decoded.span.bytes.withUnsafeBytes { bytes throws(AEAError) in
                    for _ in 0..<headerCount {
                        let size = try AppleArchive.headerByteCount(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: bytes[position...])))
                        let header = try AppleArchive.parseHeader(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: bytes[position..<(position + size)])))
                        position += size + header.blobByteCount
                    }
                }
                blackHole(position)
            }
        }

        // MARK: Whole archives

        for backend in SegmentDecoderBackend.allCases {
            Benchmark(
                "List (decode, verify, parse): \(name): \(backend)",
                configuration: .init(metrics: threadedMetrics, maxDuration: .seconds(20), maxIterations: 5)
            ) { benchmark in
                var options = AEAReadOptions()
                options.decoder = backend
                for _ in benchmark.scaledIterations {
                    blackHole(try archive.forEachEntry(options: options) { _ in })
                }
            }
        }

        for mode in DiskCompressionMode.allCases {
            Benchmark(
                "Extract: \(name): \(mode)",
                configuration: .init(metrics: threadedMetrics, maxDuration: .seconds(60), maxIterations: 3, teardown: { Fixtures.removeOutput() })
            ) { benchmark in
                Fixtures.removeOutput()
                var options = AEAExtractionOptions()
                options.diskCompression = mode
                benchmark.startMeasurement()
                for iteration in benchmark.scaledIterations {
                    blackHole(try archive.extract(to: FilePath(Fixtures.output.appending(path: "\(iteration)-\(UUID().uuidString)").path), options: options))
                }
            }
        }
    }
}
