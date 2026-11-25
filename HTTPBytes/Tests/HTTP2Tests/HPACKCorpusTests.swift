import Bytes
import BytesTesting
import BytesTestSupport
import Foundation
import HTTP2
import HTTPBytes
import Testing

/// The hpack-test-case corpus (`Tools/test-data fetch hpack-test-case`): real header sets ("stories" of requests or
/// responses sharing one compression context) as encoded by 14 implementations, and as raw headers.
enum HPACKCorpus {
    struct Case {
        var tableSize: Int?
        var wire: [UInt8]
        var headers: [(name: [UInt8], value: [UInt8])]
    }

    /// The implementations' directories (every one but `raw-data`, which has no wire bytes).
    static let implementations = [
        "go-hpack", "haskell-http2-linear", "haskell-http2-linear-huffman", "haskell-http2-naive",
        "haskell-http2-naive-huffman", "haskell-http2-static", "haskell-http2-static-huffman", "nghttp2",
        "nghttp2-16384-4096", "nghttp2-change-table-size", "node-http2-hpack", "python-hpack",
        "swift-nio-hpack-huffman", "swift-nio-hpack-plain-text",
    ]

    /// The story files in a directory, sorted.
    static func stories(in directory: String) -> [String] {
        guard let root = try? TestData.file(set: "hpack-test-case", name: directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().map { "\(directory)/\($0)" }
    }

    /// A story's cases, in order.
    static func load(_ path: String) throws -> [Case] {
        let url = try TestData.file(set: "hpack-test-case", name: path)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return (object["cases"] as! [[String: Any]]).map { item in
            let headers = (item["headers"] as! [[String: String]]).map { pair in
                (name: Array(pair.keys.first!.utf8), value: Array(pair.values.first!.utf8))
            }
            return Case(tableSize: item["header_table_size"] as? Int, wire: hexBytes((item["wire"] as? String) ?? ""), headers: headers)
        }
    }

    /// Decodes every case of a story in order with one decoder, checking each against its headers.
    @discardableResult
    static func checkDecoding(_ path: String) throws -> Int {
        let cases = try load(path)
        var total = 0
        var decoder = HPACKDecoder(maximumTableSize: 4_096)
        for (index, item) in cases.enumerated() {
            if let size = item.tableSize { decoder.setMaximumTableSize(size) }
            let decoded = try decodeBytes(&decoder, item.wire)
            total += decoded.count
            #expect(decoded.count == item.headers.count, "\(path) case \(index)")
            for (field, expected) in zip(decoded, item.headers) where field.name != expected.name || field.value != expected.value {
                Issue.record("\(path) case \(index): \(String(decoding: field.name, as: UTF8.self)) differs")
                break
            }
        }
        return total
    }

    /// Encodes every case of a raw story with one encoder, decodes the output with one decoder (as the peer would),
    /// and checks the fields come back, in order and byte for byte.
    static func checkRoundTrip(_ path: String, strategy: HPACKIndexingStrategy, huffman: Bool, tableSize: Int = 4_096) throws {
        let cases = try load(path)
        var encoder = HPACKEncoder(maximumTableSize: tableSize)
        encoder.setPeerMaximumTableSize(tableSize)
        encoder.usesHuffmanCoding = huffman
        var decoder = HPACKDecoder(maximumTableSize: tableSize)
        var output = [UInt8](repeating: 0, count: 1 << 16)
        for (index, item) in cases.enumerated() {
            let written = try output.withOutputRawSpan { span throws(HPACKError) -> Int in
                for (name, value) in item.headers {
                    try encoder.encode(name: name.span.bytes, value: value.span.bytes, indexing: strategy, into: &span)
                }
                return span.byteCount
            }
            let decoded = try decodeBytes(&decoder, Array(output[0..<written]))
            #expect(decoded.map(\.name) == item.headers.map(\.name), "\(path) case \(index)")
            #expect(decoded.map(\.value) == item.headers.map(\.value), "\(path) case \(index)")
            #expect(encoder.tableSize == decoder.tableSize && encoder.tableCount == decoder.tableCount, "\(path) case \(index): tables")
        }
    }

    /// Every field of a block as bytes.
    static func decodeBytes(_ decoder: inout HPACKDecoder, _ block: [UInt8]) throws(HPACKError) -> [(name: [UInt8], value: [UInt8])] {
        var fields: [(name: [UInt8], value: [UInt8])] = []
        let span = block.span.bytes
        while let field = try decoder.next(in: span) {
            fields.append((Array(copying: field.name), Array(copying: field.value)))
        }
        return fields
    }

    /// Truncates the first block of a story at every byte: each prefix either decodes to a prefix of the fields (it ends
    /// on a representation's boundary) or throws ``HPACKError/truncated``.
    static func checkTruncation(_ path: String) throws {
        guard let first = try load(path).first, first.tableSize ?? 4_096 == 4_096 else { return }
        var full = HPACKDecoder()
        let expected = try decodeBytes(&full, first.wire)
        for cut in 0..<first.wire.count {
            var decoder = HPACKDecoder()
            do throws(HPACKError) {
                let decoded = try decodeBytes(&decoder, Array(first.wire[0..<cut]))
                #expect(decoded.count < expected.count, "\(path) cut at \(cut)")
                #expect(zip(decoded, expected).allSatisfy { $0.name == $1.name && $0.value == $1.value }, "\(path) cut at \(cut)")
            } catch {
                #expect(error == .truncated, "\(path) cut at \(cut)")
            }
        }
    }
}

@Suite struct HPACKCorpusTests {
    /// The first four stories of every implementation.
    @Test(arguments: HPACKCorpus.implementations)
    func decodesStories(_ implementation: String) throws {
        let stories = HPACKCorpus.stories(in: implementation)
        try #require(!stories.isEmpty, "Tools/test-data fetch hpack-test-case")
        var total = 0
        for story in stories.prefix(4) {
            total += try HPACKCorpus.checkDecoding(story)
        }
        #expect(total > 200, "fields decoded: \(total)")
    }

    @Test func roundTrips() throws {
        let stories = HPACKCorpus.stories(in: "raw-data")
        try #require(!stories.isEmpty, "Tools/test-data fetch hpack-test-case")
        for story in stories.prefix(3) {
            try HPACKCorpus.checkRoundTrip(story, strategy: .automatic, huffman: true)
            try HPACKCorpus.checkRoundTrip(story, strategy: .prefer, huffman: false)
            try HPACKCorpus.checkRoundTrip(story, strategy: .automatic, huffman: true, tableSize: 256)
        }
    }

    @Test func truncation() throws {
        for implementation in ["nghttp2", "go-hpack", "python-hpack", "haskell-http2-linear-huffman"] {
            for story in HPACKCorpus.stories(in: implementation).prefix(4) {
                try HPACKCorpus.checkTruncation(story)
            }
        }
    }
}

@Suite(.bulk) struct HPACKCorpusBulkTests {
    @Test(arguments: HPACKCorpus.implementations)
    func decodesEveryStory(_ implementation: String) throws {
        for story in HPACKCorpus.stories(in: implementation) {
            try HPACKCorpus.checkDecoding(story)
        }
    }

    @Test(arguments: [HPACKIndexingStrategy.automatic, .prefer, .avoid, .disable])
    func roundTripsEveryStory(_ strategy: HPACKIndexingStrategy) throws {
        for story in HPACKCorpus.stories(in: "raw-data") {
            try HPACKCorpus.checkRoundTrip(story, strategy: strategy, huffman: true)
            try HPACKCorpus.checkRoundTrip(story, strategy: strategy, huffman: false)
            try HPACKCorpus.checkRoundTrip(story, strategy: strategy, huffman: true, tableSize: 0)
            try HPACKCorpus.checkRoundTrip(story, strategy: strategy, huffman: true, tableSize: 512)
            try HPACKCorpus.checkRoundTrip(story, strategy: strategy, huffman: true, tableSize: 65_536)
        }
    }

    @Test(arguments: HPACKCorpus.implementations)
    func truncatesEveryFirstBlock(_ implementation: String) throws {
        for story in HPACKCorpus.stories(in: implementation) {
            try HPACKCorpus.checkTruncation(story)
        }
    }
}
