import Foundation

/// Deterministic benchmark archives, generated once and cached in a fixed temporary directory.
enum Fixtures {
    static let version = 2
    static let root = URL(filePath: NSTemporaryDirectory()).appending(path: "NativeZipBenchmarkFixtures-v\(version)")

    static var smallFiles: URL { root.appending(path: "small.zip") } // 2,000 text files, ~4–16 KB each
    static var largeText: URL { root.appending(path: "text.zip") } // one 32 MB deflated text file
    static var largeRandom: URL { root.appending(path: "random.zip") } // one 32 MB stored (incompressible) file
    static var raster: URL { root.appending(path: "raster.zip") } // one 32 MB deflated file of pixel runs

    /// A per-iteration scratch directory for extraction output, always inside `root`.
    static func scratchDirectory() -> URL {
        root.appending(path: "scratch").appending(path: UUID().uuidString)
    }

    /// Removes a directory previously returned by `scratchDirectory()`, refusing anything else.
    static func removeScratch(_ url: URL) {
        let scratch = root.appending(path: "scratch").standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(scratch) else { fatalError("Refusing to remove \(url.path)") }
        try? FileManager.default.removeItem(at: url)
    }

    static func prepare() throws {
        let fileManager = FileManager.default
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
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.arguments = ["-qr", archive.path, directory]
        process.currentDirectoryURL = source
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
