import Benchmark
import BytesTestSupport
@_spi(Benchmarking) import Disk
import Foundation
import System

// Disk's benchmarks. Every extraction goes into its own directory under `Output.root` (`.noindex`), removed in the
// teardown. Metrics: time, CPU, instructions (the process's: writers' and kernel's work included), mallocs, the
// process's syscalls (package-benchmark's `.syscalls`: every thread's Unix and Mach calls, waits included), and Disk's
// own file system calls (`Disk syscalls`, with the `SyscallCounting` trait: `./bench syscalls`).
//
//     swift package --disable-sandbox benchmark                                   # times
//     swift package --traits SyscallCounting --disable-sandbox benchmark          # with Disk's call counts

let diskSyscalls = BenchmarkMetric.custom("Disk syscalls", polarity: .prefersSmaller, useScalingFactor: false)
/// Times the planner suspended for room in the write queue (``ExtractionReport/plannerWaits``): each one a wake-up.
let plannerWaits = BenchmarkMetric.custom("Planner waits", polarity: .prefersSmaller, useScalingFactor: false)

/// Runs `body` over `iterations` destinations made before the measurement, and records Disk's call count and the
/// planner's waits.
func measure(_ benchmark: Benchmark, _ name: String, _ body: (FilePath) async throws -> ExtractionReport<Never>) async throws {
    let paths = Output.paths(benchmark.scaledIterations.count, name)
    let before = SyscallCounter.total
    var waits = 0
    benchmark.startMeasurement()
    for index in benchmark.scaledIterations {
        waits += try await body(paths[index]).plannerWaits
    }
    benchmark.stopMeasurement()
    let iterations = max(1, benchmark.scaledIterations.count)
    if SyscallCounter.isEnabled { benchmark.measurement(diskSyscalls, (SyscallCounter.total - before) / iterations) }
    benchmark.measurement(plannerWaits, waits / iterations)
}

enum Trees {
    static let small2k = Lazy { Tree.smallFiles(2_000) }
    static let small20k = Lazy { Tree.smallFiles(20_000) }
    static let compressible = Lazy { Tree.compressible(2_000) }
    static let attributes = Lazy { Tree.withAttributes(2_000) }
    static let hardLinks = Lazy { Tree.hardLinks(2_000) }
    static let xcodeLike = Lazy { Tree.xcodeLike(frameworks: 10) }
    static let gigabyte = Lazy { Tree.large(1 << 30) }
    static let oneFile = Lazy { Tree.large(32_768) }
}

let benchmarks: @Sendable () -> Void = {
    let metrics: [BenchmarkMetric] = [.wallClock, .cpuTotal, .instructions, .mallocCountTotal, .syscalls, .contextSwitches, diskSyscalls, plannerWaits]
    Benchmark.defaultConfiguration = .init(
        metrics: metrics, warmupIterations: 0, scalingFactor: .one, maxDuration: .seconds(5), maxIterations: 5,
        teardown: { Output.remove() }
    )
    // Per-benchmark configurations don't inherit the default's teardown: each passes it.
    let teardown: Benchmark.BenchmarkTeardownHook = { Output.remove() }

    func register(_ name: String, tree: Lazy<Tree>, iterations: Int = 5, options: ExtractionSettings = .init(),
                  destinationOptions: DestinationOptions = .init(), storage: Storage = .plain) {
        Benchmark(name, configuration: .init(maxIterations: iterations, setup: { _ = tree.value }, teardown: teardown)) { (benchmark: Benchmark) async throws in
            let tree = tree.value
            try await measure(benchmark, name.filter { $0.isLetter || $0.isNumber }) { path in
                try await extract(tree, into: path, options: options, destinationOptions: destinationOptions, storage: storage)
            }
        }
    }

    // MARK: Small files

    register("Small files: 2,000 x 1-8 KB", tree: Trees.small2k)
    register("Small files: 20,000 x 1-8 KB", tree: Trees.small20k, iterations: 3)

    // The setup's cost: one 32 KB file with the default writers (24 here), plain and LZBITMAP.
    register("One file: 32 KB", tree: Trees.oneFile, iterations: 20)
    register("One file: 32 KB, LZBITMAP", tree: Trees.oneFile, iterations: 20, storage: .compressed(.appleArchive))

    // Smaller write queues: the planner waits for room (a wake-up each time it's resumed).
    for capacity in [64, 1_024] {
        var options = ExtractionSettings()
        options.queueCapacity = capacity
        register("Queue: 20,000 small files, \(capacity == 64 ? "64" : "1,024") jobs", tree: Trees.small20k, iterations: 3, options: options)
    }

    var progress = ExtractionSettings()
    progress.progress = ExtractionProgress(expectedEntries: 2_020)
    register("Small files: 2,000 x 1-8 KB, progress", tree: Trees.small2k, options: progress)

    var descriptors = DestinationOptions()
    descriptors.directoryResolution = .descriptors
    register("Small files: 20,000 x 1-8 KB, directory descriptors", tree: Trees.small20k, iterations: 3, destinationOptions: descriptors)
    var notBeneath = DestinationOptions()
    notBeneath.resolvesBeneath = false
    register("Small files: 20,000 x 1-8 KB, without O_RESOLVE_BENEATH", tree: Trees.small20k, iterations: 3, destinationOptions: notBeneath)
    var exact = DestinationOptions()
    exact.permissions = .exact
    var quarantined = exact
    quarantined.quarantine = Quarantine(value: Array("0081;6720ab00;Safari;".utf8))
    register("Small files: 20,000 x 1-8 KB, quarantined", tree: Trees.small20k, iterations: 3, destinationOptions: quarantined)

    // Worker counts: writers in the file system (the width), then writers.
    for width in [1, 2, 4, 6, 8, 12, 16] {
        var options = ExtractionSettings()
        options.writers = 24
        options.fileSystemWidth = width
        register("Workers: 20,000 small files: 24 writers, width \(width)", tree: Trees.small20k, iterations: 3, options: options)
    }
    for writers in [1, 2, 4, 8, 16, 32] {
        var options = ExtractionSettings()
        options.writers = writers
        options.fileSystemWidth = min(6, writers)
        register("Workers: 20,000 small files: \(writers) writers, width \(min(6, writers))", tree: Trees.small20k, iterations: 3, options: options)
    }
    for width in [2, 4, 6, 8, 12] {
        var options = ExtractionSettings()
        options.writers = 24
        options.fileSystemWidth = width
        register("Workers: Xcode-like, LZBITMAP: 24 writers, width \(width)", tree: Trees.xcodeLike, iterations: 2, options: options, storage: .compressed(.appleArchive))
    }

    // MARK: APFS compression

    for (name, policy) in [("LZBITMAP (aa)", StoragePolicy.appleArchive), ("LZFSE", .appleArchiveLZFSE), ("LZVN (xip)", .lzvnForks), ("zlib inline", .zlibInline)] {
        register("Compressed: 2,000 x 1-64 KB: \(name)", tree: Trees.compressible, storage: .compressed(policy))
    }
    register("Compressed: 2,000 x 1-64 KB: plain", tree: Trees.compressible)

    // MARK: Metadata and links

    register("Extended attributes: 2,000 files x 3", tree: Trees.attributes, destinationOptions: exact)
    register("Hard links: 2,000 files + 2,000 links", tree: Trees.hardLinks)

    // MARK: Xcode-like

    register("Xcode-like: 5,000 files, LZBITMAP", tree: Trees.xcodeLike, iterations: 2, storage: .compressed(.appleArchive))
    register("Xcode-like: 5,000 files, LZVN", tree: Trees.xcodeLike, iterations: 2, storage: .compressed(.lzvnForks))
    register("Xcode-like: 5,000 files, plain", tree: Trees.xcodeLike, iterations: 2)

    // MARK: A large file

    register("Large file: 1 GB, one write", tree: Trees.gigabyte, iterations: 3)
    var streamed = ExtractionSettings()
    streamed.stagingCapacity = 1 << 20
    Benchmark("Large file: 1 GB, 8 MiB writes", configuration: .init(maxIterations: 3, setup: { _ = Trees.gigabyte.value }, teardown: teardown)) { (benchmark: Benchmark) async throws in
        let tree = Trees.gigabyte.value
        let source = PieceWriter(base: UnsafeRawPointer(tree.contents.baseAddress!), count: tree.byteCount, piece: 8 << 20)
        try await measure(benchmark, "streamed") { path in
            let destination = try Destination(path)
            defer { destination.close() }
            return try await Extraction.run(into: destination, source: source, settings: streamed) { (planner: inout Planner<PieceWriter>) throws(DiskError) in
                let name = Array("large.bin".utf8)
                try await planner.file(EntryPath(validating: name.span.bytes), size: tree.byteCount, contents: 0)
            }
        }
    }
    Benchmark("Large file: 1 GB, LZBITMAP", configuration: .init(maxIterations: 2, setup: { _ = Trees.gigabyte.value }, teardown: teardown)) { (benchmark: Benchmark) async throws in
        let tree = Trees.gigabyte.value
        try await measure(benchmark, "largecompressed") { path in try await extract(tree, into: path, storage: .compressed(.appleArchive)) }
    }

    // MARK: Allocations (single-threaded: the per-entry cost)

    // `FileWriter`, 1,000 files rewritten in place each iteration: no allocation per file (threshold 0).
    let gate = Lazy { (Tree.smallFiles(1_000), try! Destination(Output.paths(1, "gate")[0], options: { var options = DestinationOptions(); options.existingItems = .replace; return options }())) }
    Benchmark(
        "FileWriter-1000-small-files",
        configuration: .init(metrics: [.wallClock, .instructions, .mallocCountTotal, diskSyscalls], warmupIterations: 1, maxIterations: 10, setup: { _ = gate.value }, teardown: teardown)
    ) { benchmark in
        let (tree, destination) = gate.value
        var writer = FileWriter(destination)
        let before = SyscallCounter.total
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for entry in tree.entries where entry.kind == .file {
                let contents = RawSpan(_unsafeStart: tree.contents.baseAddress! + entry.data.lowerBound, byteCount: entry.data.count)
                try writer.writeFile(EntryPath(validating: tree.path(entry)), contents: contents)
            }
        }
        benchmark.stopMeasurement()
        if SyscallCounter.isEnabled { benchmark.measurement(diskSyscalls, (SyscallCounter.total - before) / benchmark.scaledIterations.count) }
    }
    // The scheduler with one writer, at two sizes: the difference is the per-entry cost.
    for count in [2_000, 20_000] {
        var single = ExtractionSettings()
        single.writers = 1
        single.fileSystemWidth = 1
        register("Single writer: \(count == 2_000 ? "2,000" : "20,000") small files", tree: count == 2_000 ? Trees.small2k : Trees.small20k, iterations: 3, options: single)
        if count == 2_000 {
            single.progress = ExtractionProgress(expectedEntries: 2_020)
            register("Single writer: 2,000 small files, progress", tree: Trees.small2k, iterations: 3, options: single)
        }
    }

    // MARK: Probes: raw calls, before choosing

    let probeBytes = SampleBytes.text(4_000, seed: 3)
    for combined in [false, true] {
        Benchmark("Probe: 2,000 files, mode + flags + times: \(combined ? "one fsetattrlist" : "fchmod, fchflags, fsetattrlist")") { benchmark in
            let paths = Output.paths(benchmark.scaledIterations.count, "probe-attrs")
            try? FileManager.default.createDirectory(at: Output.root, withIntermediateDirectories: true)
            benchmark.startMeasurement()
            for index in benchmark.scaledIterations {
                Probe.smallFiles(in: paths[index].string, count: 2_000, bytes: probeBytes, combined: combined)
            }
        }
    }
    let identical = SampleBytes.text(32_768, seed: 4)
    for clone in [false, true] {
        Benchmark("Probe: 2,000 identical 32 KB files: \(clone ? "clonefileat" : "written")") { benchmark in
            let paths = Output.paths(benchmark.scaledIterations.count, "probe-clone")
            try? FileManager.default.createDirectory(at: Output.root, withIntermediateDirectories: true)
            benchmark.startMeasurement()
            for index in benchmark.scaledIterations {
                Probe.identicalFiles(in: paths[index].string, count: 2_000, bytes: identical, clone: clone)
            }
        }
    }
    for method in Probe.LargeWrite.allCases {
        Benchmark("Probe: 1 GB file: \(method.rawValue)", configuration: .init(maxIterations: 3, setup: { _ = Trees.gigabyte.value }, teardown: teardown)) { benchmark in
            let tree = Trees.gigabyte.value
            try? FileManager.default.createDirectory(at: Output.root, withIntermediateDirectories: true)
            let paths = Output.paths(benchmark.scaledIterations.count, "probe-large")
            benchmark.startMeasurement()
            for index in benchmark.scaledIterations {
                Probe.largeFile(at: paths[index].string, UnsafeRawBufferPointer(tree.contents), method: method)
            }
        }
    }
}

/// One large file from memory, handed to the writer in pieces (as a decoder would): streamed.
struct PieceWriter: ContentSource, @unchecked Sendable {
    let base: UnsafeRawPointer
    let count: Int
    let piece: Int

    func write(_ contents: Int, to output: inout FileOutput) async throws(EntryError<Never>) {
        var offset = 0
        while offset < count {
            let length = min(piece, count - offset)
            do throws(DiskError) {
                try await output.write(RawSpan(_unsafeStart: base + offset, byteCount: length))
            } catch {
                throw .disk(error)
            }
            offset += length
        }
    }

    func release(_ contents: Int) {}
}
