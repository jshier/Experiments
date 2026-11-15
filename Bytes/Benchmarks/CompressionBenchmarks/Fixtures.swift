import Foundation
import zlib

/// Benchmark inputs: files from the corpus `Tools/corpus fetch` downloads (Silesia, and web assets), plus
/// generated JSON. Missing corpus files are skipped.
enum Fixtures {
    struct Sample {
        let name: String
        let bytes: [UInt8]

        /// The size for benchmark names, as in "dickens (10.2 MB)".
        var label: String {
            let size = bytes.count >= 1 << 20
                ? String(format: "%.1f MB", Double(bytes.count) / Double(1 << 20))
                : String(format: "%.1f KB", Double(bytes.count) / 1024)
            return "\(name) (\(size))"
        }
    }

    static var corpusRoot: URL {
        if let path = ProcessInfo.processInfo.environment["EXPERIMENTS_CORPUS"] { return URL(filePath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Experiments/corpus")
    }

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
        var samples = corpusFiles.compactMap { path -> Sample? in
            guard let data = FileManager.default.contents(atPath: corpusRoot.appending(path: path).path) else { return nil }
            return Sample(name: String(path.split(separator: "/").last!), bytes: [UInt8](data))
        }
        samples.append(Sample(name: "JSON", bytes: json(count: 16)))
        samples.append(Sample(name: "JSON", bytes: json(count: 1_200)))
        return samples
    }()

    /// An API response: `count` records like `{"id":17,"name":"sensor-17","temperature":21.5,…}`.
    static func json(count: Int) -> [UInt8] {
        var generator = SplitMix64(state: UInt64(count))
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

    /// `make()`'s result, cached in the corpus directory under `key`: each benchmark runs in its own process,
    /// which registers every benchmark again, and Google's quality 11 takes tens of seconds per file.
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
        var stream = z_stream()
        precondition(deflateInit2_(&stream, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))) + 64)
        var input = data
        let status = input.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                stream.next_in = input.baseAddress
                stream.avail_in = uInt(input.count)
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        precondition(status == Z_STREAM_END)
        return Array(output[..<Int(stream.total_out)])
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
