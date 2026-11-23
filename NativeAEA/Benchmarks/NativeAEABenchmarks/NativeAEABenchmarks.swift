import Benchmark
import BytesTestSupport
import Disk
import Foundation
@_spi(Benchmarking) import NativeAEA
import System

// How package-benchmark runs this executable: once to list the benchmarks, then once more for each benchmark it runs,
// and every start runs the registration closure (`benchmarks`, below). So registration only names benchmarks;
// everything a benchmark needs (the opened archive, its first segment decoded) is made in its `setup`, in the one
// process that runs it.
//
// Iterations are set per group, so that one run gives stable numbers in a few seconds a benchmark:
// - Single-threaded operations report instructions and mallocs, which don't vary between iterations; the iterations
//   are there for the time's p50 (up to 1,000, or half a second).
// - Decoding segment 0 (about 0.1 s): 10 iterations.
// - Whole archives (listing: about 1.3 s for the synthetic archive; extraction: 1.3–2.3 s) run without warmup
//   iterations (`setup` reads the archive into the page cache instead), 3 and 2 times. A real archive runs once.

/// The synthetic archive `Tools/test-data fetch nativeaea-synthetic` makes, and optionally a real one named by
/// `NATIVEAEA_ARCHIVE` (with `NATIVEAEA_SIGN_PUB` if its certificate chain isn't Apple's). The real one isn't in the
/// repository: Xcode's (`Xcode_27.3_beta_2.aea`, about 10 s an extraction) was kept in `~/Scratch`:
///
///     NATIVEAEA_ARCHIVE=~/Scratch/Xcode_27.3_beta_2.aea swift package --disable-sandbox benchmark
enum Fixtures {
    static let directory = TestData.directory(set: "nativeaea-synthetic")
    static let synthetic = directory.appending(path: "synthetic.aea")
    static let syntheticKey = directory.appending(path: "signing.pub.pem")
    /// Extractions go here, each iteration into its own directory, removed after the benchmark (not between
    /// iterations, so removing one doesn't overlap the next one's measurement).
    static let output = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "NativeAEABenchmarks.noindex")

    static func open(_ url: URL, key: URL?) throws -> AEAArchive {
        try AEAArchive(url: url, signingKey: key.map { try AEASigningKey.publicKey(contentsOf: $0) } ?? .certificateChain)
    }

    static var archives: [ArchiveFixture] {
        var archives: [ArchiveFixture] = []
        if FileManager.default.fileExists(atPath: synthetic.path) {
            archives.append(ArchiveFixture(name: "synthetic", url: synthetic, key: syntheticKey, isReal: false))
        } else {
            print("NativeAEABenchmarks: run `Tools/test-data fetch nativeaea-synthetic` for the synthetic archive's benchmarks")
        }
        if let path = ProcessInfo.processInfo.environment["NATIVEAEA_ARCHIVE"] {
            let key = ProcessInfo.processInfo.environment["NATIVEAEA_SIGN_PUB"].map { URL(fileURLWithPath: $0) }
            archives.append(ArchiveFixture(name: "Xcode", url: URL(fileURLWithPath: path), key: key, isReal: true))
        }
        return archives
    }

    static func removeOutput() {
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        // Removing takes about as long as extracting (2.2 s for the synthetic archive's 30,000 entries, 13 s for
        // Xcode's 167,000), whatever the method: `rm -rf` on 4 or 8 subtrees at once saved 10–15%.
        if (try? FileManager.default.removeItem(at: output)) != nil { return }
        // Extracted directories can be read-only, which stops removing their entries: make those writable, then try
        // again. (Only after a failure: walking Xcode's tree for them costs 2.8 s, and neither archive has any.)
        _ = try? ExternalTool.run("/usr/bin/find", [output.path, "-type", "d", "!", "-perm", "-u+w", "-exec", "chmod", "u+w", "{}", "+"])
        try? FileManager.default.removeItem(at: output)
    }
}

/// An archive to benchmark, and what the benchmarks need from it, each made on first use (from a benchmark's
/// `setup`, so never inside a measurement).
///
/// `@unchecked Sendable`: a process runs one benchmark, and its setup, iterations, and teardown run one after another,
/// so the lazy properties are never made concurrently.
final class ArchiveFixture: @unchecked Sendable {
    let name: String
    let url: URL
    let key: URL?
    /// A real archive (Xcode's): whole-archive benchmarks run it once (the synthetic one: listing 3 times, extraction
    /// 2).
    let isReal: Bool

    init(name: String, url: URL, key: URL?, isReal: Bool) {
        self.name = name
        self.url = url
        self.key = key
        self.isReal = isReal
    }

    private var opened: AEAArchive?

    /// The archive, opened on first use and kept until `close()`.
    var archive: AEAArchive {
        if let opened { return opened }
        let archive = try! Fixtures.open(url, key: key)
        opened = archive
        return archive
    }

    /// Closes the archive if it was opened: a benchmark's teardown.
    func close() {
        opened?.close()
        opened = nil
    }

    /// Segment 0, stored and decoded, and the headers that start in it.
    struct FirstSegment {
        var stored: [UInt8]
        /// Decoded by Compression (BytesReferenceCodecs), the reference both decoders' outputs are checked against.
        var decoded: [UInt8]
        /// The headers that end in the segment (their blobs may not).
        var headerCount = 0
    }

    lazy var firstSegment: FirstSegment = {
        let stored = try! archive.storedBytes(of: 0)
        let decoded = SegmentDecoder.reference(stored, rawSize: archive.segments[0].rawSize, compression: archive.rootHeader.compression)
        precondition(decoded.count == archive.segments[0].rawSize, "Compression decoded \(decoded.count) bytes of segment 0")
        var segment = FirstSegment(stored: stored, decoded: decoded)
        var position = 0
        segment.decoded.span.bytes.withUnsafeBytes { bytes in
            while position + 6 <= bytes.count {
                guard let size = try? AppleArchive.headerByteCount(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: bytes[position...]))),
                      position + size <= bytes.count,
                      let header = try? AppleArchive.parseHeader(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: bytes[position..<(position + size)])))
                else { break }
                position += size + header.blobByteCount
                segment.headerCount += 1
            }
        }
        return segment
    }()

    /// Reads the whole file once, so whole-archive benchmarks start from the page cache (their warmup iteration did
    /// this before, at the cost of a whole iteration).
    func warmPageCache() {
        _ = archive
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: 16 << 20), !chunk.isEmpty {}
    }
}

/// A segment decoder and its output buffer, made in the benchmark's setup.
///
/// `@unchecked Sendable`: used by one benchmark's setup and iterations, one after another.
final class DecodeState: @unchecked Sendable {
    var decoder: SegmentDecoder?
    var output: [UInt8] = []
}

let benchmarks: @Sendable () -> Void = {
    // Single-threaded, microseconds or less: instructions and mallocs are the same every iteration, and up to 1,000
    // iterations give the time a stable p50.
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuTotal, .instructions, .mallocCountTotal, .peakMemoryResident],
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: .milliseconds(500),
        maxIterations: 1_000
    )

    // Malloc counts where the pipeline runs: package-benchmark's malloc interposer used to trap when a thread exited
    // (`count_free` → `_tlv_get_addr` → `calloc`, in `_pthread_tsd_cleanup`), when the pipeline had threads of its
    // own. On the cooperative pool, with malloc-interposer 977dc06 (2026-10-29), it doesn't (2026-11-19: about 1,700
    // per synthetic extraction). The interposer adds its header to every allocation whether or not it counts, so
    // counting adds only the per-thread increments.
    // Instructions are the process's (every thread, and the kernel's work for its system calls): the measure that
    // doesn't move with the machine's load (2026-11-20, moving extraction onto Disk).
    let threadedMetrics: [BenchmarkMetric] = [.wallClock, .cpuTotal, .instructions, .peakMemoryResident, .mallocCountTotal]

    for fixture in Fixtures.archives {
        let name = fixture.name

        // MARK: Container

        Benchmark("Open and verify: \(name)") { benchmark in
            for _ in benchmark.scaledIterations {
                let opened = try Fixtures.open(fixture.url, key: fixture.key)
                blackHole(opened)
                opened.close()
            }
        }

        // MARK: Segments and headers

        // "bytes": BytesCompression's decoder, as NativeAEA runs it. "system": Apple's Compression, the reference (until
        // 2026-11-22 NativeAEA's other backend; since then called here, through the same buffer API and scratch memory).
        for kind in SegmentDecoderKind.allCases {
            // One 16 MiB segment, decoded: throughput is 16 MiB per iteration.
            let state = DecodeState()
            Benchmark(
                "Decode segment 0: \(name): \(kind)",
                configuration: .init(
                    metrics: [.wallClock, .cpuTotal, .instructions, .mallocCountTotal, .throughput],
                    warmupIterations: 1,
                    maxDuration: .seconds(2),
                    maxIterations: 10,
                    setup: {
                        let segment = fixture.firstSegment
                        let decoder = SegmentDecoder(fixture.archive, kind: kind)
                        var output = [UInt8](repeating: 0, count: segment.decoded.count)
                        try decoder.decode(segment.stored, into: &output)
                        precondition(output == segment.decoded)
                        state.decoder = decoder
                        state.output = output
                    },
                    teardown: { fixture.close() }
                )
            ) { benchmark in
                let decoder = state.decoder!
                let stored = fixture.firstSegment.stored
                benchmark.startMeasurement()
                for _ in benchmark.scaledIterations {
                    try decoder.decode(stored, into: &state.output)
                }
            }
        }

        // A decoder's state, made once per decoding task (Compression's: its scratch memory).
        for kind in SegmentDecoderKind.allCases {
            Benchmark(
                "Make segment decoder: \(name): \(kind)",
                configuration: .init(setup: { _ = fixture.archive }, teardown: { fixture.close() })
            ) { benchmark in
                let archive = fixture.archive
                benchmark.startMeasurement()
                for _ in benchmark.scaledIterations {
                    blackHole(SegmentDecoder(archive, kind: kind))
                }
            }
        }

        // Headers in the first segment, parsed (blobs skipped): the walker's own work per entry. (The synthetic
        // archive's segment 0 has 170 headers, Xcode 27.3 beta 2's 308. The count was in this benchmark's name, which
        // would need the segment decoded in every process.)
        Benchmark(
            "Parse headers: \(name) segment 0",
            configuration: .init(setup: { _ = fixture.firstSegment }, teardown: { fixture.close() })
        ) { benchmark in
            let segment = fixture.firstSegment
            let decoded = segment.decoded
            let headerCount = segment.headerCount
            benchmark.startMeasurement()
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

        // (The walker's parent lookups, "Resolve parents" and "Directory table", went with its directory table: Disk's
        // planner resolves parents now, 2026-11-20.)

        // MARK: Whole archives

        // Listing decodes on every core and writes nothing: its iterations spread 2–4% within a run, so 3 iterations'
        // p50 (their median). Its decoders are BytesCompression's ("bytes"; the "system" row went with NativeAEA's
        // Compression backend, 2026-11-22: the segment rows above keep Compression as the reference).
        Benchmark(
            "List (decode, verify, parse): \(name): bytes",
            configuration: .init(
                metrics: threadedMetrics,
                warmupIterations: 0,
                maxDuration: .seconds(10),
                maxIterations: fixture.isReal ? 1 : 3,
                setup: { fixture.warmPageCache() },
                teardown: { fixture.close() }
            )
        ) { (benchmark: Benchmark) async throws in
            let options = AEAReadOptions()
            let archive = fixture.archive
            for _ in benchmark.scaledIterations {
                blackHole(try await archive.forEachEntry(options: options) { _ in })
            }
        }

        // Extraction is bound by the file system: its iterations spread 2–14% within a run whatever their number, so
        // 2 iterations' p50 (their minimum). Each iteration extracts into its own directory, and the teardown removes
        // them all (2.2 s per synthetic tree, 13 s per Xcode tree), outside the measurement.
        // "progress": the same extraction counting into an `ExtractionProgress` (one relaxed add per entry and per
        // piece), against "archived" without it.
        for (mode, counted) in DiskCompressionMode.allCases.map({ ($0, false) }) + [(.archived, true)] {
            Benchmark(
                "Extract: \(name): \(mode)\(counted ? ": progress" : "")",
                configuration: .init(
                    metrics: threadedMetrics,
                    warmupIterations: 0,
                    maxDuration: .seconds(10),
                    maxIterations: fixture.isReal ? 1 : 2,
                    setup: {
                        Fixtures.removeOutput()
                        fixture.warmPageCache()
                    },
                    teardown: {
                        fixture.close()
                        Fixtures.removeOutput()
                    }
                )
            ) { (benchmark: Benchmark) async throws in
                var options = AEAExtractionOptions()
                options.diskCompression = mode
                if counted { options.disk.progress = ExtractionProgress() }
                let destination = FilePath(Fixtures.output.appending(path: "\(benchmark.currentIteration)-\(UUID().uuidString)").path)
                let archive = fixture.archive
                benchmark.startMeasurement()
                for _ in benchmark.scaledIterations {
                    blackHole(try await archive.extract(to: destination, options: options))
                }
            }
        }
    }
}
