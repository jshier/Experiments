import Bytes
import BytesCompression
import CLibDeflate
import Compression
import Foundation
import Testing
import zlib

/// Compressed sizes of the benchmark corpus with each encoder and level, for `Benchmarks/RESULTS.md`.
/// Opt in: `COMPRESSION_REPORT=1 swift test -c release --filter RatioReport` prints a tab-separated table.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COMPRESSION_REPORT"] != nil))
struct RatioReport {
    static var corpusRoot: URL {
        if let path = ProcessInfo.processInfo.environment["EXPERIMENTS_CORPUS"] { return URL(filePath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Experiments/corpus")
    }

    static let files = ["silesia/dickens", "silesia/xml", "silesia/x-ray", "silesia/samba", "web/Main.js", "web/Main.css"]

    static func libdeflateSize(_ data: [UInt8], level: Int32) -> Int {
        let compressor = libdeflate_alloc_compressor(level)
        defer { libdeflate_free_compressor(compressor) }
        var output = [UInt8](repeating: 0, count: data.count + data.count / 100 + 1024)
        return data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { libdeflate_deflate_compress(compressor, input.baseAddress, input.count, $0.baseAddress, $0.count) }
        }
    }

    static func appleSize(_ data: [UInt8]) -> Int {
        var output = [UInt8](repeating: 0, count: data.count + data.count / 100 + 1024)
        return data.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer {
                compression_encode_buffer($0.baseAddress!, $0.count, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
    }

    @Test func deflateSizes() {
        var lines = ["file\tsize\tBytes 1\tBytes 6\tBytes 9\tzlib 1\tzlib 6\tzlib 9\tlibdeflate 1\tlibdeflate 6\tlibdeflate 9\tlibdeflate 12\tApple"]
        for path in Self.files {
            guard let contents = FileManager.default.contents(atPath: Self.corpusRoot.appending(path: path).path) else { continue }
            let data = [UInt8](contents)
            var row = [path, "\(data.count)"]
            for level in [1, 6, 9] {
                let compressed = encodeAll(data, format: .raw, level: level)
                #expect(decodeAll(compressed, format: .raw) == .decoded(data))
                row.append("\(compressed.count)")
            }
            for level: Int32 in [1, 6, 9] {
                row.append("\(zlibCompress(data, format: .raw, level: level).count)")
            }
            for level: Int32 in [1, 6, 9, 12] {
                row.append("\(Self.libdeflateSize(data, level: level))")
            }
            row.append("\(Self.appleSize(data))")
            lines.append(row.joined(separator: "\t"))
        }
        print(lines.joined(separator: "\n"))
    }

    @Test func brotliSizes() {
        var lines = ["file\tsize\tBytes 1\tBytes 5\tBytes 9\tGoogle 1\tGoogle 5\tGoogle 9\tGoogle 11"]
        for path in Self.files {
            guard let contents = FileManager.default.contents(atPath: Self.corpusRoot.appending(path: path).path) else { continue }
            let data = [UInt8](contents)
            var row = [path, "\(data.count)"]
            for quality in [1, 5, 9] {
                let compressed = brotliEncodeAll(data, quality: quality)
                #expect(brotliDecodeAll(compressed) == .decoded(data))
                row.append("\(compressed.count)")
            }
            for quality: Int32 in [1, 5, 9, 11] {
                row.append("\(googleBrotliCompress(data, quality: quality).count)")
            }
            lines.append(row.joined(separator: "\t"))
        }
        print(lines.joined(separator: "\n"))
    }
}
