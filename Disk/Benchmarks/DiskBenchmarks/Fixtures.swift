import BytesTestSupport
@_spi(Benchmarking) import Disk
import Foundation
import System

// How package-benchmark runs this executable: once to list the benchmarks, then once for each benchmark it runs, and
// every start runs the registration closure. So registration only names benchmarks: trees are made lazily
// (`Lazy`), in a benchmark's `setup`, in the process that runs it.

/// Where extractions go: each iteration into its own directory, removed in `teardown` (removing a tree costs about as
/// much as making it). `.noindex`, so Spotlight leaves it alone.
enum Output {
    static let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "DiskBenchmarks.noindex")

    /// Destinations for `count` iterations, made before the measurement (paths allocate).
    static func paths(_ count: Int, _ name: String) -> [FilePath] {
        let stamp = UUID().uuidString
        return (0..<count).map { FilePath(root.appending(path: "\(name)-\(stamp)-\($0)").path) }
    }

    static func remove() {
        TreeRemoval.remove(root.path)
    }
}

/// A tree to extract: every file's contents in one buffer (a `MemorySource` over it), every path in another.
final class Tree: @unchecked Sendable {
    // Unchecked: made once in a benchmark's setup, read only after.
    enum Kind { case directory, file, link, hardLink }

    struct Entry {
        var kind: Kind
        var path: Range<Int>
        /// Contents (files), target (links: in `paths`), the file linked to (hard links: an entry index).
        var data: Range<Int>
        var mode: UInt16 = 0o644
        var attributes = false
    }

    let contents: UnsafeMutableRawBufferPointer
    let paths: UnsafeMutableRawBufferPointer
    let entries: [Entry]
    let fileCount: Int
    let byteCount: Int

    init(_ build: (inout Builder) -> Void) {
        var builder = Builder()
        build(&builder)
        let contents = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, builder.contents.count), alignment: 16_384)
        builder.contents.withUnsafeBytes { contents.copyMemory(from: $0) }
        self.contents = contents
        let paths = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, builder.paths.count), alignment: 16)
        builder.paths.withUnsafeBytes { paths.copyMemory(from: $0) }
        self.paths = paths
        entries = builder.entries
        fileCount = builder.entries.count { $0.kind == .file }
        byteCount = builder.contents.count
    }

    struct Builder {
        var contents: [UInt8] = []
        var paths: [UInt8] = []
        var entries: [Entry] = []

        mutating func path(_ string: String) -> Range<Int> {
            let start = paths.count
            paths.append(contentsOf: string.utf8)
            return start..<paths.count
        }

        mutating func directory(_ path: String) {
            entries.append(Entry(kind: .directory, path: self.path(path), data: 0..<0, mode: 0o755))
        }

        mutating func file(_ path: String, _ bytes: [UInt8], mode: UInt16 = 0o644, attributes: Bool = false) {
            let start = contents.count
            contents.append(contentsOf: bytes)
            entries.append(Entry(kind: .file, path: self.path(path), data: start..<contents.count, mode: mode, attributes: attributes))
        }

        mutating func link(_ path: String, to target: String) {
            let range = self.path(path)
            entries.append(Entry(kind: .link, path: range, data: self.path(target), mode: 0o755))
        }

        mutating func hardLink(_ path: String, to entry: Int) {
            entries.append(Entry(kind: .hardLink, path: self.path(path), data: entry..<entry))
        }
    }

    @_lifetime(borrow self)
    func path(_ entry: Entry) -> RawSpan {
        let span = RawSpan(_unsafeStart: paths.baseAddress! + entry.path.lowerBound, byteCount: entry.path.count)
        return _overrideLifetime(span, borrowing: self)
    }

    @_lifetime(borrow self)
    func target(_ entry: Entry) -> RawSpan {
        let span = RawSpan(_unsafeStart: paths.baseAddress! + entry.data.lowerBound, byteCount: entry.data.count)
        return _overrideLifetime(span, borrowing: self)
    }

    var source: MemorySource { unsafe MemorySource(base: UnsafeRawPointer(contents.baseAddress!), count: contents.count) }

    /// The bytes of a deterministic file: text-like (compressible), binary-like (partly), or random, as NativeAEA's
    /// synthetic archive mixes them.
    static func bytes(_ size: Int, seed: UInt64, kind: UInt64) -> [UInt8] {
        switch kind % 20 {
        case 0..<10: return SampleBytes.text(size, seed: seed)
        case 10..<19: return SampleBytes.periodic(size, period: 4_096, seed: seed)
        default: return SampleBytes.random(size, seed: seed)
        }
    }

    /// `count` files of 1–8 KB, 100 a directory (what NativeZip's small-file measurements used).
    static func smallFiles(_ count: Int) -> Tree {
        Tree { builder in
            var generator = SplitMix64(seed: UInt64(count))
            for index in 0..<count {
                if index % 100 == 0 { builder.directory("d\(index / 100)") }
                let size = 1_024 + Int(generator.next() % 7_168)
                builder.file("d\(index / 100)/file\(index).txt", SampleBytes.text(size, seed: UInt64(index)))
            }
        }
    }

    /// `count` files of 1–64 KB of mixed contents (for APFS compression).
    static func compressible(_ count: Int) -> Tree {
        Tree { builder in
            var generator = SplitMix64(seed: 64)
            for index in 0..<count {
                if index % 100 == 0 { builder.directory("d\(index / 100)") }
                let size = 1_024 + Int(generator.next() % 64_512)
                builder.file("d\(index / 100)/f\(index)", bytes(size, seed: UInt64(index), kind: generator.next()))
            }
        }
    }

    /// `count` files with three extended attributes each (planned with attachments: finished after the writers).
    static func withAttributes(_ count: Int) -> Tree {
        Tree { builder in
            for index in 0..<count {
                if index % 100 == 0 { builder.directory("d\(index / 100)") }
                builder.file("d\(index / 100)/f\(index)", SampleBytes.text(2_000, seed: UInt64(index)), attributes: true)
            }
        }
    }

    /// `count` files and a second name for each.
    static func hardLinks(_ count: Int) -> Tree {
        Tree { builder in
            for index in 0..<count {
                if index % 100 == 0 {
                    builder.directory("d\(index / 100)")
                    builder.directory("links\(index / 100)")
                }
                builder.file("d\(index / 100)/f\(index)", SampleBytes.text(2_000, seed: UInt64(index)))
                builder.hardLink("links\(index / 100)/l\(index)", to: builder.entries.count - 1)
            }
        }
    }

    /// One file of `size` bytes.
    static func large(_ size: Int) -> Tree {
        Tree { builder in builder.file("large.bin", SampleBytes.periodic(size, period: 1 << 20, seed: 1)) }
    }

    /// An Xcode-like tree, laid out as NativeAEA's synthetic archive (`make-stream.py`): frameworks of 500 files each,
    /// sizes from Xcode 27.3 beta 2's distribution (54% under 4 KiB, 38% under 64 KiB, 7% under 1 MiB, the rest
    /// larger), a `Resources` link per framework, and a hard-linked second name for every tenth file (Xcode's xip has
    /// 32,009 hard-linked names in 167,193 items).
    static func xcodeLike(frameworks: Int) -> Tree {
        Tree { builder in
            var generator = SplitMix64(seed: 27_3_2)
            func size() -> Int {
                let bucket = generator.next() % 1_000
                if bucket < 540 { return Int(generator.next() % 4_096) }
                if bucket < 920 { return 4_096 + Int(generator.next() % 61_440) }
                if bucket < 990 { return 65_536 + Int(generator.next() % 983_040) }
                if bucket < 999 { return (1 << 20) + Int(generator.next() % (5 << 20)) }
                return (16 << 20) + Int(generator.next() % (8 << 20))
            }
            builder.directory("Synthetic.app")
            builder.directory("Synthetic.app/Contents")
            builder.directory("Synthetic.app/Contents/Frameworks")
            for framework in 0..<frameworks {
                let base = "Synthetic.app/Contents/Frameworks/F\(framework).framework"
                for directory in ["", "/Versions", "/Versions/A", "/Versions/A/Resources", "/Versions/A/Headers"] {
                    builder.directory(base + directory)
                }
                builder.link(base + "/Resources", to: "Versions/A/Resources")
                for index in 0..<500 {
                    let folder = index % 2 == 0 ? "Resources" : "Headers"
                    builder.file("\(base)/Versions/A/\(folder)/file\(index)", bytes(size(), seed: generator.next(), kind: generator.next()), mode: index % 7 == 0 ? 0o755 : 0o644)
                    if index % 10 == 0 { builder.hardLink("\(base)/Versions/A/\(folder)/same\(index)", to: builder.entries.count - 1) }
                }
            }
        }
    }
}

/// Extracts `tree` into `path` through the scheduler.
@discardableResult
func extract(
    _ tree: Tree, into path: FilePath, options: ExtractionSettings = .init(), destinationOptions: DestinationOptions = .init(),
    storage: Storage = .plain
) async throws -> ExtractionReport {
    let destination = try Destination(path, options: destinationOptions)
    var blob = ExtendedAttributeBlob()
    for name in ["com.example.one", "com.example.two", "com.example.three"] { blob.append(name: name, value: SampleBytes.text(40, seed: 1).span.bytes) }
    let attributes = blob.bytes
    // Archived files have times: every file gets one (one `fsetattrlist` with the mode).
    let times = EntryTimes(modification: Timestamp(seconds: 1_700_000_000))
    return try await Extraction.run(into: destination, source: tree.source, settings: options) { (planner: inout Planner<MemorySource>) throws(DiskError) in
        var tokens: [EntryToken] = []
        let hasLinks = tree.entries.contains { $0.kind == .hardLink }
        if hasLinks { tokens = Array(repeating: .none, count: tree.entries.count) }
        for (index, entry) in tree.entries.enumerated() {
            let path = try EntryPath(validating: tree.path(entry))
            switch entry.kind {
            case .directory:
                try planner.directory(path, metadata: EntryMetadata(mode: entry.mode))
            case .file:
                let token = try await planner.file(
                    path, size: entry.data.count, contents: entry.data, metadata: EntryMetadata(mode: entry.mode, times: times), storage: storage,
                    attachments: entry.attributes, hardLinked: hasLinks
                )
                if entry.attributes { try planner.addExtendedAttributes(attributes.span.bytes, to: token) }
                if hasLinks { tokens[index] = token }
            case .link:
                try planner.symbolicLink(path, target: tree.target(entry), metadata: EntryMetadata(mode: entry.mode))
            case .hardLink:
                try planner.hardLink(path, to: tokens[entry.data.lowerBound])
            }
        }
    }
}
