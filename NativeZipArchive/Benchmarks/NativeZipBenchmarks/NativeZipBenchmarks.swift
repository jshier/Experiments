import Benchmark
import Bytes
import BytesReferenceCodecs

// `TestData`, for the archive-coverage row.
import BytesTestSupport
import Compression
import Disk
import Foundation
import NativeZip
import System
import zlib

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

    // NativeZip's DEFLATE rows ("Bytes"), each beside a "zlib" row of the same name. Until 2026-11-22 the zlib rows ran
    // the library's zlib backend through the same `ZipArchive` calls; that backend is gone, so they're now a pure codec
    // comparison: zlib's `inflate` into a reused 1 MB buffer and zlib's `crc32_z` over each chunk (`ZlibInflater`),
    // called directly, which is the work the backend did. Rows that needed the backend in the library (verifying and
    // extracting with zlib) were dropped.
    for (name, url) in [("text", Fixtures.largeText), ("raster", Fixtures.raster)] {
        // Raster: runs of 2- to 7-byte pixels, matches 2 to 7 bytes back, which copy a repeating pattern.
        Benchmark("Inflate + CRC 32 MB \(name): Bytes", configuration: large) { benchmark in
            let archive = try ZipArchive(url: url)
            let entry = firstFile(archive)
            var decoder = ZipDecoder()
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
            }
        }

        Benchmark("Inflate + CRC 32 MB \(name): zlib", configuration: large) { benchmark in
            let entry = try firstFile(ZipArchive(url: url))
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            let inflater = ZlibInflater()
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                let payload = PayloadLocator.payloadRange(of: entry, in: data)
                let (count, crc) = inflater.decode(data.bytes.extracting(payload))
                precondition(count == Int(entry.uncompressedSize) && crc == entry.crc32)
            }
        }
    }

    Benchmark("Inflate + CRC 2,000 small files: Bytes", configuration: large) { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        let files = archive.entries.filter { $0.kind == .file }
        var decoder = ZipDecoder()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for entry in files {
                try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
            }
        }
    }

    Benchmark("Inflate + CRC 2,000 small files: zlib", configuration: large) { benchmark in
        let files = try ZipArchive(url: Fixtures.smallFiles).entries.filter { $0.kind == .file }
        let data = try Data(contentsOf: Fixtures.smallFiles, options: .alwaysMapped)
        let inflater = ZlibInflater()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for entry in files {
                let payload = PayloadLocator.payloadRange(of: entry, in: data)
                let (count, crc) = inflater.decode(data.bytes.extracting(payload))
                precondition(count == Int(entry.uncompressedSize) && crc == entry.crc32)
            }
        }
    }

    // The same 2,000 files as LZMA and xz entries: every entry starts a stream, which resets the probability model.
    for method in [Fixtures.Method.lzma, .xz] {
        Benchmark("Inflate + CRC 2,000 small files: \(method.label)", configuration: large) { benchmark in
            let archive = try ZipArchive(url: Fixtures.smallMethodArchive(method))
            let files = archive.entries.filter { $0.kind == .file }
            var decoder = ZipDecoder()
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                for entry in files {
                    try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
                }
            }
        } setup: {
            try Fixtures.prepareSmallMethod(method)
        }
    }

    Benchmark("Verify 2,000 small files (parallel): Bytes") { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let failures = await archive.verify()
            precondition(failures.isEmpty)
        }
    }

    extractionBenchmark("Extract 32 MB text: Bytes", archive: Fixtures.largeText, configuration: large)
    extractionBenchmark("Extract 2,000 small files: Bytes", archive: Fixtures.smallFiles, configuration: files)

    // Random bytes, which zip deflates as DEFLATE's stored blocks: a copy and a CRC-32, no decoding to speak of.
    Benchmark("Stored + CRC 32 MB random: Bytes") { benchmark in
        let archive = try ZipArchive(url: Fixtures.largeRandom)
        let entry = firstFile(archive)
        var decoder = ZipDecoder()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
        }
    }

    Benchmark("Stored + CRC 32 MB random: zlib") { benchmark in
        let entry = try firstFile(ZipArchive(url: Fixtures.largeRandom))
        let data = try Data(contentsOf: Fixtures.largeRandom, options: .alwaysMapped)
        let inflater = ZlibInflater()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let payload = PayloadLocator.payloadRange(of: entry, in: data)
            let (count, crc) = inflater.decode(data.bytes.extracting(payload))
            precondition(count == Int(entry.uncompressedSize) && crc == entry.crc32)
        }
    }

    // CRC-32 alone, at the sizes zip entries come in: a large file (from memory), a cache-resident buffer, small
    // files, and tiny ones. Each runs enough bytes per iteration (32 MB) to time. The bytes are made once, in setup
    // (CRC-32's work doesn't depend on them). Bytes' `CRC32` (what NativeZip checks entries with) and zlib's.
    for (label, size) in [("32 MB", 32 << 20), ("256 KB, in cache", 256 << 10), ("1 KB", 1 << 10), ("64 B", 64)] {
        let repeats = (32 << 20) / size
        for (suffix, checksum) in [("Bytes", { CRC32.checksum($0) }), ("zlib", zlibCRC32)] as [(String, (RawSpan) -> UInt32)] {
            Benchmark(
                "CRC-32 \(label): \(suffix)",
                configuration: .init(metrics: [.wallClock, .instructions, .throughput]),
                closure: { (benchmark: Benchmark, bytes: [UInt8]) in
                    for _ in benchmark.scaledIterations {
                        for _ in 0..<repeats {
                            blackHole(checksum(bytes.span.bytes))
                        }
                    }
                },
                setup: { Fixtures.randomBytes(count: size) }
            )
        }
    }

    // The other methods on the same 32 MB of text: decoded through `ZipArchive` (CRC-32 included), and extracted.
    // Deflate64's stream is the DEFLATE row's, recorded as method 9 (`Fixtures.methodArchive`).
    for method in Fixtures.Method.allCases {
        Benchmark("Inflate + CRC 32 MB text: \(method.label)", configuration: large) { benchmark in
            let archive = try ZipArchive(url: Fixtures.methodArchive(method))
            let entry = firstFile(archive)
            var decoder = ZipDecoder()
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
            }
        } setup: {
            try Fixtures.prepareMethod(method)
        }
        extractionBenchmark("Extract 32 MB text: \(method.label)", archive: Fixtures.methodArchive(method), configuration: large) {
            try Fixtures.prepareMethod(method)
        }
    }

    // Encrypted entries of the same 32 MB text, decrypted as they're decoded (ZipDecoder's staging), CRC-32 included.
    for encryption in Fixtures.Encryption.allCases {
        Benchmark(encryption.label, configuration: large) { benchmark in
            let archive = try ZipArchive(url: Fixtures.encryptedArchive(encryption))
            let entry = firstFile(archive)
            var decoder = ZipDecoder()
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                try archive.contents(of: entry, using: &decoder, password: Fixtures.password) { blackHole($0.byteCount) }
            }
        } setup: {
            try Fixtures.prepareEncrypted(encryption)
        }
    }

    // MARK: Building blocks

    // Compression's one-shot raw DEFLATE decoder (`COMPRESSION_ZLIB`) through BytesReferenceCodecs, on the text row's
    // payload, copied to an array once. Since 2026-11-22 each call also allocates its 32 MB output and copies it once
    // (BytesReferenceCodecs' `AppleCompression.decode`); before, the library's hook decoded into one reused array.
    Benchmark("Backend: Compression.framework one-shot 32 MB", configuration: large) { benchmark in
        let archive = try ZipArchive(url: Fixtures.largeText)
        let entry = firstFile(archive)
        let data = try Data(contentsOf: Fixtures.largeText, options: .alwaysMapped)
        let payload = [UInt8](data[PayloadLocator.payloadRange(of: entry, in: data)])
        let size = Int(entry.uncompressedSize)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let output = AppleCompression.decode(payload, capacity: size, COMPRESSION_ZLIB)
            precondition(output.count == size)
        }
    }

    // MARK: Extraction to disk

    // Each sample extracts into a new directory under `Fixtures.output` (a `.noindex` directory, which Spotlight
    // skips). Many small files are removed after each sample, outside the measurement; one large file is kept until
    // teardown (see `Fixtures.remove(_:)` for the measurements behind each).
    func extractionBenchmark(_ name: String, archive url: URL, maxConcurrency: Int? = nil, progress: Bool = false,
                             removesEachSample: Bool = false,
                             configuration: Benchmark.Configuration, setup: (@Sendable () throws -> Void)? = nil) {
        let removeEachSample = removesEachSample || url == Fixtures.smallFiles
        var configuration = configuration
        configuration.metrics = extractionMetrics
        Benchmark(name, configuration: configuration) { benchmark in
            let archive = try ZipArchive(url: url)
            var options = NativeZip.ZipExtractionOptions()
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
        } setup: {
            try setup?()
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

    // The archive-coverage set's `ditto -c -k --sequesterRsrc` archive (`Tools/test-data fetch archive-coverage`; the
    // tests' tree, so this row moves with the set, not with `Fixtures.version`): 2,000 small files and a few large ones
    // (8 MB), with what the rows above lack: AppleDouble entries under `__MACOSX` merged into their items (extended
    // attributes, resource forks, ACLs, Finder info, flags), symbolic links of every kind, read-only and special modes,
    // 24 levels, long and Unicode names. (Its hard links are copies: ZIP has none.) Removed after each sample.
    let coverage = TestData.directory(set: "archive-coverage").appending(path: "tree-ditto.zip")
    extractionBenchmark("Extract coverage tree: ditto AppleDouble", archive: coverage, removesEachSample: true, configuration: files) {
        _ = try TestData.file(set: "archive-coverage", name: "tree-ditto.zip") // Says which fetch to run.
    }

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
            var options = NativeZip.ZipExtractionOptions()
            if progress { options.progress = ExtractionProgress() }
            // The quarantine is the destination's (opened here, as `extract(to:)` opens its own).
            var destinationOptions = DestinationOptions()
            if quarantined { destinationOptions.quarantine = Quarantine(value: Array("0083;673e3000;Safari;".utf8)) }
            let before = SyscallCounter.total
            let destinations = benchmark.scaledIterations.map { _ in FilePath(Fixtures.outputDirectory().path) }
            benchmark.startMeasurement()
            for index in benchmark.scaledIterations {
                if quarantined {
                    // The caller's destination, closed by the caller (as an app closes its staging directory).
                    let destination = try Destination(destinations[index], options: destinationOptions)
                    try await archive.extract(into: destination, options: options)
                    destination.close()
                } else {
                    try await archive.extract(to: destinations[index], options: options)
                }
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
            let failures = try await ZipExtractor.extract(into: destinations[index], stopOnFirstError: true) { extractor async throws(ZipError) in
                for archive in archives {
                    try await extractor.add(archive)
                }
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

/// zlib's raw DEFLATE decoder, called directly, for the "zlib" rows: each chunk decoded into one reused 1 MB buffer
/// and checksummed with zlib's `crc32_z`, the work the library's zlib backend did. (BytesReferenceCodecs' `Zlib`
/// decodes into a new array and copies its input, and has no CRC-32.)
final class ZlibInflater {
    /// On the heap: zlib keeps a pointer back to its stream and checks it on every call.
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)

    init() {
        stream.initialize(to: z_stream())
        // Negative window bits: raw DEFLATE (RFC 1951), as zip method 8 stores it.
        precondition(inflateInit2_(stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
        buffer.deallocate()
    }

    /// Decodes a whole raw DEFLATE `payload` (traps if it's invalid or truncated).
    ///
    /// - Returns: The size and CRC-32 of its output.
    func decode(_ payload: RawSpan) -> (count: Int, crc: UInt32) {
        precondition(inflateReset(stream) == Z_OK)
        var count = 0
        var crc: uLong = 0
        // The pointers describe `payload` and `buffer` exactly, and zlib keeps none past the loop.
        payload.withUnsafeBytes { input in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.pointee.avail_in = uInt(input.count)
            let output = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
            while true {
                stream.pointee.next_out = output
                stream.pointee.avail_out = uInt(buffer.count)
                let status = inflate(stream, Z_NO_FLUSH)
                let produced = buffer.count - Int(stream.pointee.avail_out)
                crc = crc32_z(crc, output, produced)
                count += produced
                if status == Z_STREAM_END { break }
                precondition(status == Z_OK, "zlib inflate: \(status)")
            }
        }
        return (count, UInt32(crc))
    }
}

/// zlib's CRC-32 of `bytes` (the pointer and count describe the span, for the call).
func zlibCRC32(_ bytes: RawSpan) -> UInt32 {
    bytes.withUnsafeBytes { UInt32(crc32_z(0, $0.baseAddress?.assumingMemoryBound(to: Bytef.self), $0.count)) }
}
