import Benchmark
@_spi(Benchmarking) import Disk
import Foundation
@_spi(Benchmarking) import NativeZip
import System

/// Disk's file system calls per iteration (the `SyscallCounting` trait: `swift package --traits SyscallCounting
/// --scratch-path .build-syscalls --disable-sandbox benchmark`); not recorded without it.
let diskSyscalls = BenchmarkMetric.custom("Disk syscalls", polarity: .prefersSmaller, useScalingFactor: false)

/// Records Disk's calls since `before`, per iteration.
func recordDiskSyscalls(_ benchmark: Benchmark, since before: Int) {
    guard SyscallCounter.isEnabled else { return }
    benchmark.measurement(diskSyscalls, (SyscallCounter.total - before) / max(1, benchmark.scaledIterations.count))
}

// The benchmark tool launches this executable once to list the benchmarks and again for every benchmark it runs,
// so registration does no work: the fixtures are made or found in `Benchmark.setup` (before a benchmark runs, never
// for a listing), one-time checks run in their benchmark's `setup`, and inputs every sample shares are made there too.
let benchmarks: @Sendable () -> Void = {
    // Under a millisecond a sample (parsing, CRC-32, verifying in parallel): 50 samples, a fraction of a second.
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuTotal, .instructions, .mallocCountTotal, .peakMemoryResident],
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: .seconds(1),
        maxIterations: 50
    )
    // 5–35 ms a sample (32 MB decoded or extracted, 2,000 small files decoded): 20 samples, under a second. Their
    // instruction p50s match 50 samples' within 1%; times are steady to a few percent.
    let large = Benchmark.Configuration(maxDuration: .seconds(2), maxIterations: 20)
    // 2,000 files created on disk, 80–200 ms a sample plus about 100 ms deleting them: as many samples as fit in 2 s
    // (6–12). The file system sets their spread, not the sample count: samples differ by 20–40%, and with identical
    // code two runs' p50s differed by up to 16% (instructions up to 9%, 30% for the floors: kernel work). Compare these
    // only within one interleaved run, or by several runs.
    let files = Benchmark.Configuration(maxDuration: .seconds(2), maxIterations: 12)
    // Extraction rows also count the process's system calls (package-benchmark's `.syscalls`: every thread's Unix and
    // Mach calls, waits and the allocator included), comparable across the old writer and Disk's.
    let extractionMetrics = Benchmark.defaultConfiguration.metrics + [.syscalls, diskSyscalls]

    Benchmark.setup = { try Fixtures.prepare() }

    // MARK: Parsing

    Benchmark("Parse central directory (2,000 entries)") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(ZipArchive(url: Fixtures.smallFiles))
        }
    }

    // The `Bytes` parser above against the original `ByteReader` one, which must agree on every entry: checked once,
    // before this benchmark runs.
    Benchmark("Parse central directory: original ByteReader") { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(ZipArchive.entriesUsingByteReader(of: Fixtures.smallFiles))
        }
    } setup: {
        try Fixtures.checkParsersAgree()
    }

    Benchmark("Locate 2,000 payloads") { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for entry in archive.entries {
                try blackHole(archive.payloadCount(of: entry))
            }
        }
    }

    Benchmark("Locate 2,000 payloads: original ByteReader") { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for entry in archive.entries {
                try blackHole(archive.payloadCountUsingByteReader(of: entry))
            }
        }
    }

    // MARK: Decompression (no filesystem writes)

    // Archives are opened in every sample (outside the measurement), so each sample maps them afresh and touches
    // their pages for the first time inside the measurement, as a program extracting an archive does.
    func firstFile(_ archive: ZipArchive) -> ZipEntry {
        archive.entries.first { $0.kind == .file }!
    }

    // Each DEFLATE benchmark runs with the `Bytes` decoder (the default) and with zlib.
    for backend in [ZipDecoder.Backend.bytes, .zlib] {
        let suffix = backend == .bytes ? "Bytes" : "zlib"

        Benchmark("Inflate + CRC 32 MB text: \(suffix)", configuration: large) { benchmark in
            let archive = try ZipArchive(url: Fixtures.largeText)
            let entry = firstFile(archive)
            var decoder = ZipDecoder(backend: backend)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
            }
        }

        // Runs of 2- to 7-byte pixels: matches 2 to 7 bytes back, which copy a repeating pattern.
        Benchmark("Inflate + CRC 32 MB raster: \(suffix)", configuration: large) { benchmark in
            let archive = try ZipArchive(url: Fixtures.raster)
            let entry = firstFile(archive)
            var decoder = ZipDecoder(backend: backend)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
            }
        }

        Benchmark("Inflate + CRC 2,000 small files: \(suffix)", configuration: large) { benchmark in
            let archive = try ZipArchive(url: Fixtures.smallFiles)
            let files = archive.entries.filter { $0.kind == .file }
            var decoder = ZipDecoder(backend: backend)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                for entry in files {
                    try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
                }
            }
        }

        Benchmark("Verify 2,000 small files (parallel): \(suffix)") { benchmark in
            let archive = try ZipArchive(url: Fixtures.smallFiles)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                let failures = await archive.verify(backend: backend)
                precondition(failures.isEmpty)
            }
        }

        extractionBenchmark("Extract 32 MB text: \(suffix)", archive: Fixtures.largeText, backend: backend, configuration: large)
        extractionBenchmark("Extract 2,000 small files: \(suffix)", archive: Fixtures.smallFiles, backend: backend, configuration: files)

        // A stored entry is only a CRC: the backends' checksums end to end.
        Benchmark("Stored + CRC 32 MB random: \(suffix)") { benchmark in
            let archive = try ZipArchive(url: Fixtures.largeRandom)
            let entry = firstFile(archive)
            var decoder = ZipDecoder(backend: backend)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
            }
        }

        // CRC-32 alone, at the sizes zip entries come in: a large file (from memory), a cache-resident
        // buffer, small files, and tiny ones. Each runs enough bytes per iteration (32 MB) to time. The
        // bytes are made once, in setup (CRC-32's work doesn't depend on them).
        for (label, size) in [("32 MB", 32 << 20), ("256 KB, in cache", 256 << 10), ("1 KB", 1 << 10), ("64 B", 64)] {
            let repeats = (32 << 20) / size
            Benchmark(
                "CRC-32 \(label): \(suffix)",
                configuration: .init(metrics: [.wallClock, .instructions, .throughput]),
                closure: { (benchmark: Benchmark, bytes: [UInt8]) in
                    for _ in benchmark.scaledIterations {
                        for _ in 0..<repeats {
                            blackHole(DeflateBackends.crc32(bytes.span.bytes, backend: backend))
                        }
                    }
                },
                setup: { Fixtures.randomBytes(count: size) }
            )
        }
    }

    // MARK: Building blocks

    Benchmark("Backend: Compression.framework one-shot 32 MB", configuration: large) { benchmark in
        let archive = try ZipArchive(url: Fixtures.largeText)
        let entry = firstFile(archive)
        // Grab the raw payload once via the archive's own bytes; decode it repeatedly.
        let data = try Data(contentsOf: Fixtures.largeText, options: .alwaysMapped)
        let payload = PayloadLocator.payloadRange(of: entry, in: data)
        var output = [UInt8](repeating: 0, count: Int(entry.uncompressedSize))
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let produced = DeflateBackends.compressionOneShot(data.bytes.extracting(payload), into: &output)
            precondition(produced == output.count)
        }
    }

    // MARK: Extraction to disk

    // Each sample extracts into a new directory under `Fixtures.output` (a `.noindex` directory, which Spotlight
    // skips). Many small files are removed after each sample, outside the measurement; one large file is kept until
    // teardown (see `Fixtures.remove(_:)` for the measurements behind each).
    func extractionBenchmark(_ name: String, archive url: URL, maxConcurrency: Int? = nil, backend: ZipDecoder.Backend = .bytes,
                             progress: Bool = false, configuration: Benchmark.Configuration) {
        let removeEachSample = url == Fixtures.smallFiles
        var configuration = configuration
        configuration.metrics = extractionMetrics
        Benchmark(name, configuration: configuration) { benchmark in
            let archive = try ZipArchive(url: url)
            var options = NativeZip.ExtractionOptions()
            options.backend = backend
            if let maxConcurrency { options.maxConcurrency = maxConcurrency }
            // Polled by nobody: the cost of counting (one relaxed add per file, or per chunk of a streamed one).
            if progress { options.progress = ExtractionProgress() }
            let before = SyscallCounter.total
            for _ in benchmark.scaledIterations {
                let destination = Fixtures.outputDirectory()
                benchmark.startMeasurement()
                try await archive.extract(to: FilePath(destination.path), options: options)
                benchmark.stopMeasurement()
                if removeEachSample { Fixtures.remove(destination) }
            }
            recordDiskSyscalls(benchmark, since: before)
        } teardown: {
            Fixtures.removeOutput()
        }
    }

    // Zstandard (method 93, the `zstd` command at level 3) against the DEFLATE rows above, on the same 32 MB.
    for (label, url) in [("text", Fixtures.zstdText), ("raster", Fixtures.zstdRaster)] {
        Benchmark("Zstd + CRC 32 MB \(label)", configuration: large) { benchmark in
            let archive = try ZipArchive(url: url)
            let entry = firstFile(archive)
            var decoder = ZipDecoder()
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
            }
        }
    }
    extractionBenchmark("Extract 32 MB text: Zstd", archive: Fixtures.zstdText, configuration: large)

    for workers in [1, 2, 4, 8] {
        extractionBenchmark("Extract 2,000 small files (\(workers) worker\(workers == 1 ? "" : "s"))",
                            archive: Fixtures.smallFiles, maxConcurrency: workers, configuration: files)
    }

    // `ExtractionProgress` counting, polled by nobody: against the rows without it (instructions; RESULTS.md, 2026-11-20).
    extractionBenchmark("Extract 2,000 small files (1 worker), progress", archive: Fixtures.smallFiles, maxConcurrency: 1,
                        progress: true, configuration: files)
    extractionBenchmark("Extract 2,000 small files: Bytes, progress", archive: Fixtures.smallFiles, progress: true, configuration: files)
    extractionBenchmark("Extract 32 MB text: Bytes, progress", archive: Fixtures.largeText, progress: true, configuration: large)

    // The kernel cost of creating the same files with no decoding at all: a floor for extraction.
    Benchmark("Floor: create + write 2,000 files (no decoding)", configuration: files) { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        let files = archive.entries.filter { $0.kind == .file }
        let directories = Set(files.map { FilePath($0.path).removingLastComponent() })
        let payload = [UInt8](repeating: 0x61, count: 10_000)
        for _ in benchmark.scaledIterations {
            let destination = Fixtures.outputDirectory()
            let root = FilePath(destination.path)
            for directory in directories {
                try FileManager.default.createDirectory(atPath: root.pushing(directory).string, withIntermediateDirectories: true)
            }
            benchmark.startMeasurement()
            for entry in files {
                let descriptor = try FileDescriptor.open(root.pushing(FilePath(entry.path)), .writeOnly,
                                                         options: [.create, .truncate], permissions: .ownerReadWrite)
                try descriptor.closeAfter { _ = try descriptor.writeAll(payload) }
            }
            benchmark.stopMeasurement()
            Fixtures.remove(destination)
        }
    }

    // Same, but each file is opened relative to an already-open descriptor for its directory (openat),
    // so the kernel resolves one path component instead of the whole absolute path.
    Benchmark("Floor: create + write 2,000 files via openat", configuration: files) { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        let files = archive.entries.filter { $0.kind == .file }
        let directories = Set(files.map { FilePath($0.path).removingLastComponent() })
        let payload = [UInt8](repeating: 0x61, count: 10_000)
        for _ in benchmark.scaledIterations {
            let destination = Fixtures.outputDirectory()
            let root = FilePath(destination.path)
            var descriptors: [FilePath: FileDescriptor] = [:]
            for directory in directories {
                try FileManager.default.createDirectory(atPath: root.pushing(directory).string, withIntermediateDirectories: true)
                descriptors[directory] = try FileDescriptor.open(root.pushing(directory), .readOnly, options: [.directory])
            }
            let names = files.map { (FilePath($0.path).removingLastComponent(), FilePath($0.path).lastComponent!.string) }
            benchmark.startMeasurement()
            for (directory, name) in names {
                let descriptor = FileDescriptor(rawValue: openat(descriptors[directory]!.rawValue, name, O_WRONLY | O_CREAT | O_TRUNC, 0o600))
                try descriptor.closeAfter { _ = try descriptor.writeAll(payload) }
            }
            benchmark.stopMeasurement()
            for descriptor in descriptors.values {
                try descriptor.close()
            }
            Fixtures.remove(destination)
        }
    }

    extractionBenchmark("Extract 32 MB random", archive: Fixtures.largeRandom, configuration: large)

    // RESULTS.md's step15 jobs (measured there with hyperfine through `nunzip`): 20,000 files of 1–8 KB, and eight
    // archives of one 64 MB text file each, extracted together by one pool. Each sample extracts into its own directory;
    // the trees are removed in the teardown (deleting 20,000 files costs about as much as extracting them).
    let whole = Benchmark.Configuration(metrics: extractionMetrics, warmupIterations: 0, maxDuration: .seconds(10), maxIterations: 3)
    // "quarantined": the archive's quarantine on everything extracted (what an app does; one `fsetxattr` more a file).
    for (suffix, progress, quarantined) in [("", false, false), (", progress", true, false), (", quarantined", false, true)] {
        Benchmark("Extract 20,000 small files\(suffix)", configuration: whole) { benchmark in
            let archive = try ZipArchive(url: Fixtures.smallFiles20k)
            var options = NativeZip.ExtractionOptions()
            if progress { options.progress = ExtractionProgress() }
            if quarantined { options.quarantine = Quarantine(value: Array("0083;673e3000;Safari;".utf8)) }
            let before = SyscallCounter.total
            let destinations = benchmark.scaledIterations.map { _ in FilePath(Fixtures.outputDirectory().path) }
            benchmark.startMeasurement()
            for index in benchmark.scaledIterations {
                try await archive.extract(to: destinations[index], options: options)
            }
            benchmark.stopMeasurement()
            recordDiskSyscalls(benchmark, since: before)
        } setup: {
            try Fixtures.prepareLarge()
        } teardown: {
            Fixtures.removeOutput()
        }
    }

    Benchmark("Extract 8 archives of 64 MB text (one pool)", configuration: whole) { benchmark in
        let archives = try Fixtures.textArchives.map { try ZipArchive(url: $0) }
        let before = SyscallCounter.total
        let destinations = benchmark.scaledIterations.map { _ in FilePath(Fixtures.outputDirectory().path) }
        benchmark.startMeasurement()
        for index in benchmark.scaledIterations {
            let failures = try await ZipExtractor.extract(into: destinations[index], stopOnFirstError: true) { extractor in
                for archive in archives { try await extractor.add(archive) }
            }
            precondition(failures.isEmpty)
        }
        benchmark.stopMeasurement()
        recordDiskSyscalls(benchmark, since: before)
    } setup: {
        try Fixtures.prepareLarge()
    } teardown: {
        Fixtures.removeOutput()
    }
}

/// Finds an entry's payload byte range by parsing its local header (benchmark-only helper).
enum PayloadLocator {
    static func payloadRange(of entry: ZipEntry, in data: Data) -> Range<Int> {
        let bytes = data.bytes
        let header = Int(entry.localHeaderOffset)
        let nameLength = Int(bytes.load(fromByteOffset: header + 26, as: UInt16.self, .littleEndian))
        let extraLength = Int(bytes.load(fromByteOffset: header + 28, as: UInt16.self, .littleEndian))
        let start = header + 30 + nameLength + extraLength
        return start..<start + Int(entry.compressedSize)
    }
}
