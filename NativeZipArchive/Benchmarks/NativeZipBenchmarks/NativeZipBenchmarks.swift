import Benchmark
import Foundation
@_spi(Benchmarking) import NativeZip
import System

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuTotal, .instructions, .mallocCountTotal, .peakMemoryResident],
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: .seconds(2),
        maxIterations: 50
    )

    do {
        try Fixtures.prepare()
    } catch {
        fatalError("Couldn't create benchmark fixtures: \(error)")
    }

    // MARK: Parsing

    Benchmark("Parse central directory (2,000 entries)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try ZipArchive(url: Fixtures.smallFiles))
        }
    }

    // The `Bytes` parser above against the original `ByteReader` one, which must agree on every entry.
    for url in [Fixtures.smallFiles, Fixtures.largeText, Fixtures.largeRandom] {
        let archive = try! ZipArchive(url: url)
        let original = try! ZipArchive.entriesUsingByteReader(of: url)
        precondition(archive.entries.count == original.count)
        for (new, old) in zip(archive.entries, original) {
            precondition(
                new.path == old.path && new.kind == old.kind && new.method == old.method && new.flags == old.flags
                    && new.crc32 == old.crc32 && new.compressedSize == old.compressedSize
                    && new.uncompressedSize == old.uncompressedSize && new.localHeaderOffset == old.localHeaderOffset
                    && new.posixPermissions == old.posixPermissions && new.modificationDate == old.modificationDate,
                "Parsers disagree on \(new.path)"
            )
            precondition(try! archive.payloadCount(of: new) == (try! archive.payloadCountUsingByteReader(of: old)))
        }
    }

    Benchmark("Parse central directory: original ByteReader") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try ZipArchive.entriesUsingByteReader(of: Fixtures.smallFiles))
        }
    }

    Benchmark("Locate 2,000 payloads") { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for entry in archive.entries { blackHole(try archive.payloadCount(of: entry)) }
        }
    }

    Benchmark("Locate 2,000 payloads: original ByteReader") { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for entry in archive.entries { blackHole(try archive.payloadCountUsingByteReader(of: entry)) }
        }
    }

    // MARK: Decompression (no filesystem writes)

    func firstFile(_ archive: ZipArchive) -> ZipEntry {
        archive.entries.first { $0.kind == .file }!
    }

    // Each DEFLATE benchmark runs with the `Bytes` decoder (the default) and with zlib.
    for backend in [ZipDecoder.Backend.bytes, .zlib] {
        let suffix = backend == .bytes ? "Bytes" : "zlib"

        Benchmark("Inflate + CRC 32 MB text: \(suffix)") { benchmark in
            let archive = try ZipArchive(url: Fixtures.largeText)
            let entry = firstFile(archive)
            var decoder = ZipDecoder(backend: backend)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                try archive.contents(of: entry, using: &decoder) { blackHole($0.byteCount) }
            }
        }

        Benchmark("Inflate + CRC 2,000 small files: \(suffix)") { benchmark in
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

        extractionBenchmark("Extract 32 MB text: \(suffix)", archive: Fixtures.largeText, backend: backend)
        extractionBenchmark("Extract 2,000 small files: \(suffix)", archive: Fixtures.smallFiles, backend: backend)

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
        // buffer, small files, and tiny ones. Each runs enough bytes per iteration (32 MB) to time.
        for (label, size) in [("32 MB", 32 << 20), ("256 KB, in cache", 256 << 10), ("1 KB", 1 << 10), ("64 B", 64)] {
            Benchmark("CRC-32 \(label): \(suffix)", configuration: .init(metrics: [.wallClock, .instructions, .throughput])) { benchmark in
                var rng = SystemRandomNumberGenerator()
                let bytes = (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }
                let repeats = (32 << 20) / size
                benchmark.startMeasurement()
                for _ in benchmark.scaledIterations {
                    for _ in 0..<repeats {
                        blackHole(DeflateBackends.crc32(bytes.span.bytes, backend: backend))
                    }
                }
            }
        }
    }

    // MARK: Building blocks

    Benchmark("Backend: Compression.framework one-shot 32 MB") { benchmark in
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

    func extractionBenchmark(_ name: String, archive url: URL, maxConcurrency: Int? = nil, backend: ZipDecoder.Backend = .bytes) {
        Benchmark(name) { benchmark in
            let archive = try ZipArchive(url: url)
            var options = ExtractionOptions()
            options.backend = backend
            if let maxConcurrency { options.maxConcurrency = maxConcurrency }
            for _ in benchmark.scaledIterations {
                let destination = Fixtures.scratchDirectory()
                benchmark.startMeasurement()
                try await archive.extract(to: FilePath(destination.path), options: options)
                benchmark.stopMeasurement()
                Fixtures.removeScratch(destination)
            }
        }
    }

    for workers in [1, 2, 4, 8] {
        extractionBenchmark("Extract 2,000 small files (\(workers) worker\(workers == 1 ? "" : "s"))",
                            archive: Fixtures.smallFiles, maxConcurrency: workers)
    }

    // The kernel cost of creating the same files with no decoding at all: a floor for extraction.
    Benchmark("Floor: create + write 2,000 files (no decoding)") { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        let files = archive.entries.filter { $0.kind == .file }
        let directories = Set(files.map { FilePath($0.path).removingLastComponent() })
        let payload = [UInt8](repeating: 0x61, count: 10_000)
        for _ in benchmark.scaledIterations {
            let destination = Fixtures.scratchDirectory()
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
            Fixtures.removeScratch(destination)
        }
    }

    // Same, but each file is opened relative to an already-open descriptor for its directory (openat),
    // so the kernel resolves one path component instead of the whole absolute path.
    Benchmark("Floor: create + write 2,000 files via openat") { benchmark in
        let archive = try ZipArchive(url: Fixtures.smallFiles)
        let files = archive.entries.filter { $0.kind == .file }
        let directories = Set(files.map { FilePath($0.path).removingLastComponent() })
        let payload = [UInt8](repeating: 0x61, count: 10_000)
        for _ in benchmark.scaledIterations {
            let destination = Fixtures.scratchDirectory()
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
            for descriptor in descriptors.values { try descriptor.close() }
            Fixtures.removeScratch(destination)
        }
    }

    extractionBenchmark("Extract 32 MB random", archive: Fixtures.largeRandom)

    // Like the CLI: opening (mapping + parsing) is inside the measurement, so first-touch page faults count.
    func openAndExtractBenchmark(_ name: String, archive url: URL) {
        Benchmark(name) { benchmark in
            for _ in benchmark.scaledIterations {
                let destination = Fixtures.scratchDirectory()
                benchmark.startMeasurement()
                try await ZipArchive(url: url).extract(to: FilePath(destination.path))
                benchmark.stopMeasurement()
                Fixtures.removeScratch(destination)
            }
        }
    }

    openAndExtractBenchmark("Open + extract 2,000 small files", archive: Fixtures.smallFiles)
    openAndExtractBenchmark("Open + extract 32 MB text", archive: Fixtures.largeText)
    openAndExtractBenchmark("Open + extract 32 MB random", archive: Fixtures.largeRandom)
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
