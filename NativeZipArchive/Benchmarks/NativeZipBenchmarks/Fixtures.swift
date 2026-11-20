import BytesTestSupport
import Foundation
@_spi(Benchmarking) import NativeZip
import zlib

/// Deterministic benchmark archives, generated once and cached in a fixed temporary directory.
enum Fixtures {
    static let version = 3
    static let root = URL(filePath: NSTemporaryDirectory()).appending(path: "NativeZipBenchmarkFixtures-v\(version)")

    static var smallFiles: URL { root.appending(path: "small.zip") } // 2,000 text files, ~4–16 KB each
    static var largeText: URL { root.appending(path: "text.zip") } // one 32 MB deflated text file
    static var largeRandom: URL { root.appending(path: "random.zip") } // one 32 MB stored (incompressible) file
    static var raster: URL { root.appending(path: "raster.zip") } // one 32 MB deflated file of pixel runs
    static var zstdText: URL { root.appending(path: "text-zstd.zip") } // the 32 MB text as Zstandard (method 93), level 3
    static var zstdRaster: URL { root.appending(path: "raster-zstd.zip") } // the 32 MB raster as Zstandard, level 3

    /// Where extraction benchmarks write: `.noindex`, so Spotlight doesn't index what they extract.
    static var output: URL { root.appending(path: "output.noindex") }

    /// A new directory (not yet created) for one sample's extraction output, inside `output`.
    static func outputDirectory() -> URL {
        output.appending(path: UUID().uuidString)
    }

    /// Removes a directory returned by `outputDirectory()`, refusing anything else.
    ///
    /// The 2,000-file benchmarks call this after every sample, outside the measurement. Leaving their files until
    /// teardown was tried: extraction then ran 1–23% slower (instructions +4–15%) as the files piled up, and deleting
    /// them all at the end (unlinked on 8 threads) took longer than deleting as it went. One 32 MB file is kept
    /// until teardown instead: deleted after every sample, some samples of `Extract 32 MB random` took 2–9x as long (the
    /// p50 went from 3.9 to 9 ms in one run); kept, one run's samples were all within 15% of the fastest (a single
    /// observation: another run, under other agents' load, still spread from 3.9 to 16 ms).
    static func remove(_ directory: URL) {
        let parent = output.standardizedFileURL.path + "/"
        guard directory.standardizedFileURL.path.hasPrefix(parent) else { fatalError("Refusing to remove \(directory.path)") }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes every sample's directory under `output` (a benchmark's teardown).
    static func removeOutput() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [] {
            remove(output.appending(path: name))
        }
    }

    /// `count` pseudo-random bytes (SplitMix64, eight bytes a step, so made quickly).
    static func randomBytes(count: Int) -> [UInt8] {
        var rng = SplitMix64(seed: UInt64(count))
        return rng.packedBytes(count)
    }

    /// Checks the `Bytes` central-directory parser against the original `ByteReader` one: the same entries and payload
    /// ranges in every fixture archive.
    static func checkParsersAgree() throws {
        for url in [smallFiles, largeText, largeRandom] {
            let archive = try ZipArchive(url: url)
            let original = try ZipArchive.entriesUsingByteReader(of: url)
            precondition(archive.entries.count == original.count)
            for (new, old) in Swift.zip(archive.entries, original) {
                let sameHeader = new.path == old.path && new.kind == old.kind && new.method == old.method && new.flags == old.flags
                let sameSizes = new.crc32 == old.crc32 && new.compressedSize == old.compressedSize
                    && new.uncompressedSize == old.uncompressedSize && new.localHeaderOffset == old.localHeaderOffset
                let sameAttributes = new.posixPermissions == old.posixPermissions && new.modificationDate == old.modificationDate
                precondition(sameHeader && sameSizes && sameAttributes, "Parsers disagree on \(new.path)")
                let payload = try archive.payloadCount(of: new)
                let originalPayload = try archive.payloadCountUsingByteReader(of: old)
                precondition(payload == originalPayload, "Payloads disagree on \(new.path)")
            }
        }
    }

    /// Makes the fixture archives if they aren't there yet (about 20 s; then cached in `root`), and the output
    /// directory. Called from `Benchmark.setup`, so only before a benchmark runs, not when they're listed.
    static func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: largeRandom.path) { return }

        let source = root.appending(path: "source")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        var rng = SplitMix64(seed: 0x5EED)

        // Many small files in nested directories.
        let small = source.appending(path: "small")
        for index in 0..<2000 {
            let directory = small.appending(path: "dir\(index % 40)/sub\(index % 7)")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = 4096 + Int(rng.next() % 12288)
            try text(byteCount: size, using: &rng).write(to: directory.appending(path: "file\(index).txt"))
        }

        let largeTextDirectory = source.appending(path: "text")
        try fileManager.createDirectory(at: largeTextDirectory, withIntermediateDirectories: true)
        try text(byteCount: 32 << 20, using: &rng).write(to: largeTextDirectory.appending(path: "big.txt"))

        let largeRandomDirectory = source.appending(path: "random")
        try fileManager.createDirectory(at: largeRandomDirectory, withIntermediateDirectories: true)
        var random = Data(count: 32 << 20)
        random.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 8) {
                buffer.storeBytes(of: rng.next(), toByteOffset: index, as: UInt64.self)
            }
        }
        try random.write(to: largeRandomDirectory.appending(path: "big.bin"))

        let rasterDirectory = source.appending(path: "raster")
        try fileManager.createDirectory(at: rasterDirectory, withIntermediateDirectories: true)
        try rasterData(byteCount: 32 << 20, using: &rng).write(to: rasterDirectory.appending(path: "big.raw"))

        try zip("small", into: smallFiles, from: source)
        try zip("text", into: largeText, from: source)
        try zip("raster", into: raster, from: source)
        try zstdZip("text", file: "big.txt", into: zstdText, from: source)
        try zstdZip("raster", file: "big.raw", into: zstdRaster, from: source)
        // Last: `prepare` checks for it to tell whether the fixtures are complete.
        try zip("random", into: largeRandom, from: source)
    }

    /// Raster-like data: runs of 1 to 40 identical pixels of 2 to 7 bytes (the width changes every 4 KB),
    /// each run a random pixel. Deflate codes a run as one pixel of literals, then a match one pixel back:
    /// the short distances that repeat a pattern, which text rarely has.
    private static func rasterData(byteCount: Int, using rng: inout SplitMix64) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(byteCount + 4096 + 300)
        while output.count < byteCount {
            let width = 2 + Int(rng.next() % 6)
            let segmentEnd = output.count + 4096
            while output.count < segmentEnd {
                let pixel = rng.next()
                for _ in 0...(rng.next() % 40) {
                    for byte in 0..<width {
                        output.append(UInt8(truncatingIfNeeded: pixel >> (8 * UInt64(byte))))
                    }
                }
            }
        }
        return Data(output.prefix(byteCount))
    }

    /// Word-salad text that compresses roughly like source code (~3–4x).
    private static func text(byteCount: Int, using rng: inout SplitMix64) -> Data {
        let words = ["func", "let", "var", "return", "struct", "import", "Foundation", "self", "init", "throws",
                     "public", "private", "extension", "guard", "else", "case", "switch", "for", "in", "while",
                     "archive", "entry", "offset", "count", "buffer", "stream", "data", "error", "value", "index"]
        var output = Data(capacity: byteCount + 32)
        while output.count < byteCount {
            let word = words[Int(rng.next() % UInt64(words.count))]
            output.append(contentsOf: word.utf8)
            output.append(rng.next() % 12 == 0 ? 0x0A : 0x20)
            if rng.next() % 50 == 0 { output.append(contentsOf: String(rng.next() % 100_000).utf8) }
        }
        return output.prefix(byteCount)
    }

    private static func zip(_ directory: String, into archive: URL, from source: URL) throws {
        try ExternalTool.run("/usr/bin/zip", ["-qr", archive.path, directory], in: source)
    }

    /// A one-entry archive of `directory/file` compressed by the `zstd` command (`brew install zstd`) at level 3:
    /// zip stores the compressed file, then its headers are patched to say method 93 with the original's CRC-32 and
    /// size (no macOS tool writes Zstandard entries).
    private static func zstdZip(_ directory: String, file: String, into archive: URL, from source: URL) throws {
        let original = try Data(contentsOf: source.appending(path: directory).appending(path: file))
        let work = root.appending(path: "zstd-work")
        try FileManager.default.createDirectory(at: work.appending(path: directory), withIntermediateDirectories: true)
        let compressed = work.appending(path: directory).appending(path: file)
        try ExternalTool.run("/usr/bin/env", ["zstd", "-q", "-3", "-f", source.appending(path: directory).appending(path: file).path, "-o", compressed.path], in: work)
        try ExternalTool.run("/usr/bin/zip", ["-q0r", archive.path, directory], in: work)
        var raw = try [UInt8](Data(contentsOf: archive))
        let crc = original.withUnsafeBytes { UInt32(crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count))) }
        func store<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { raw.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        // Local header: method at 8, CRC at 14, uncompressed size at 22. Central header: 10, 16, 24.
        let central = (0..<(raw.count - 4)).last { raw[$0] == 0x50 && raw[$0 + 1] == 0x4B && raw[$0 + 2] == 1 && raw[$0 + 3] == 2 }!
        for (base, method, crcOffset, size) in [(0, 8, 14, 22), (central, 10, 16, 24)] {
            store(UInt16(93), at: base + method)
            store(crc, at: base + crcOffset)
            store(UInt32(original.count), at: base + size)
        }
        try Data(raw).write(to: archive)
    }
}
