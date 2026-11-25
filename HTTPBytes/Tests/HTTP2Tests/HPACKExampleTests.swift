import Bytes
import HTTP2
import HTTPBytes
import Testing

/// RFC 7541 Appendix C: every example, decoded, with the dynamic table after each block; and the encoder's output for
/// the same fields, decoded back.
@Suite struct HPACKExampleTests {
    /// One block of an example: its bytes, its fields, and the table after it (newest first) with its size.
    struct Step {
        var hex: String
        var fields: [(String, String)]
        var table: [(String, String)]
        var size: Int
    }

    static let date1 = "Mon, 21 Oct 2013 20:13:21 GMT"
    static let date2 = "Mon, 21 Oct 2013 20:13:22 GMT"
    static let cookie = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"

    static let requestFields: [[(String, String)]] = [
        [(":method", "GET"), (":scheme", "http"), (":path", "/"), (":authority", "www.example.com")],
        [(":method", "GET"), (":scheme", "http"), (":path", "/"), (":authority", "www.example.com"), ("cache-control", "no-cache")],
        [(":method", "GET"), (":scheme", "https"), (":path", "/index.html"), (":authority", "www.example.com"), ("custom-key", "custom-value")],
    ]
    static let requestTables: [[(String, String)]] = [
        [(":authority", "www.example.com")],
        [("cache-control", "no-cache"), (":authority", "www.example.com")],
        [("custom-key", "custom-value"), ("cache-control", "no-cache"), (":authority", "www.example.com")],
    ]
    static let responseFields: [[(String, String)]] = [
        [(":status", "302"), ("cache-control", "private"), ("date", date1), ("location", "https://www.example.com")],
        [(":status", "307"), ("cache-control", "private"), ("date", date1), ("location", "https://www.example.com")],
        [(":status", "200"), ("cache-control", "private"), ("date", date2), ("location", "https://www.example.com"),
         ("content-encoding", "gzip"), ("set-cookie", cookie)],
    ]
    static let responseTables: [[(String, String)]] = [
        [("location", "https://www.example.com"), ("date", date1), ("cache-control", "private"), (":status", "302")],
        [(":status", "307"), ("location", "https://www.example.com"), ("date", date1), ("cache-control", "private")],
        [("set-cookie", cookie), ("content-encoding", "gzip"), ("date", date2)],
    ]

    static let requests = [
        "8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d",
        "8286 84be 5808 6e6f 2d63 6163 6865",
        "8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65",
    ]
    static let huffmanRequests = [
        "8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff",
        "8286 84be 5886 a8eb 1064 9cbf",
        "8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf",
    ]
    static let responses = [
        """
        4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3120 474d
        546e 1768 7474 7073 3a2f 2f77 7777 2e65 7861 6d70 6c65 2e63 6f6d
        """,
        "4803 3330 37c1 c0bf",
        """
        88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3220 474d 54c0 5a04 677a 6970 7738 666f
        6f3d 4153 444a 4b48 514b 425a 584f 5157 454f 5049 5541 5851 5745 4f49 553b 206d 6178 2d61 6765 3d33 3630 303b
        2076 6572 7369 6f6e 3d31
        """,
    ]
    static let huffmanResponses = [
        """
        4882 6402 5885 aec3 771a 4b61 96d0 7abe 9410 54d4 44a8 2005 9504 0b81 66e0 82a6 2d1b ff6e 919d 29ad 1718 63c7
        8f0b 97c8 e9ae 82ae 43d3
        """,
        "4883 640e ffc1 c0bf",
        """
        88c1 6196 d07a be94 1054 d444 a820 0595 040b 8166 e084 a62d 1bff c05a 839b d9ab 77ad 94e7 821d d7f2 e6c7 b335
        dfdf cd5b 3960 d5af 2708 7f36 72c1 ab27 0fb5 291f 9587 3160 65c0 03ed 4ee5 b106 3d50 07
        """,
    ]

    func run(_ blocks: [String], fields: [[(String, String)]], tables: [[(String, String)]], sizes: [Int], tableSize: Int) throws {
        var decoder = HPACKDecoder(maximumTableSize: tableSize)
        for (index, hex) in blocks.enumerated() {
            let decoded = try decodeAll(&decoder, hexBytes(hex))
            #expect(decoded == HTTP2Tests.fields(fields[index]), "block \(index)")
            #expect(tableEntries(decoder) == HTTP2Tests.fields(tables[index]), "table after block \(index)")
            #expect(decoder.tableSize == sizes[index], "table size after block \(index)")
        }
    }

    @Test func literalWithIndexing() throws {
        var decoder = HPACKDecoder()
        let decoded = try decodeAll(&decoder, hexBytes("400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"))
        #expect(decoded == fields([("custom-key", "custom-header")]))
        #expect(tableEntries(decoder) == fields([("custom-key", "custom-header")]))
        #expect(decoder.tableSize == 55)
    }

    @Test func literalWithoutIndexing() throws {
        var decoder = HPACKDecoder()
        let decoded = try decodeAll(&decoder, hexBytes("040c 2f73 616d 706c 652f 7061 7468"))
        #expect(decoded == fields([(":path", "/sample/path")]))
        #expect(decoded.first?.known == .pseudoPath)
        #expect(decoder.tableCount == 0)
    }

    @Test func literalNeverIndexed() throws {
        var decoder = HPACKDecoder()
        let decoded = try decodeAll(&decoder, hexBytes("1008 7061 7373 776f 7264 0673 6563 7265 74"))
        #expect(decoded == [DecodedField(name: "password", value: "secret", neverIndexed: true)])
        #expect(decoder.tableCount == 0)
    }

    @Test func indexedField() throws {
        var decoder = HPACKDecoder()
        let decoded = try decodeAll(&decoder, hexBytes("82"))
        #expect(decoded == fields([(":method", "GET")]))
        #expect(decoded.first?.known == .pseudoMethod)
        #expect(decoder.tableCount == 0)
    }

    @Test func requests() throws {
        try run(Self.requests, fields: Self.requestFields, tables: Self.requestTables, sizes: [57, 110, 164], tableSize: 4_096)
    }

    @Test func huffmanRequests() throws {
        try run(Self.huffmanRequests, fields: Self.requestFields, tables: Self.requestTables, sizes: [57, 110, 164], tableSize: 4_096)
    }

    /// C.5: the table is 256 bytes (the setting), so entries are evicted.
    @Test func responses() throws {
        try run(Self.responses, fields: Self.responseFields, tables: Self.responseTables, sizes: [222, 222, 215], tableSize: 256)
    }

    @Test func huffmanResponses() throws {
        try run(Self.huffmanResponses, fields: Self.responseFields, tables: Self.responseTables, sizes: [222, 222, 215], tableSize: 256)
    }
}

/// The encoder on Appendix C's fields: indexing everything (as the RFC's examples do), its output is the RFC's bytes,
/// with and without Huffman coding.
@Suite struct HPACKEncoderExampleTests {
    func encode(_ blocks: [[(String, String)]], tableSize: Int, huffman: Bool) throws -> [[UInt8]] {
        var encoder = HPACKEncoder(maximumTableSize: tableSize)
        encoder.setPeerMaximumTableSize(tableSize)
        encoder.usesHuffmanCoding = huffman
        var output = [UInt8](repeating: 0, count: 4_096)
        return try blocks.map { block in
            let written = try output.withOutputRawSpan { span throws(HPACKError) -> Int in
                for (name, value) in block {
                    let nameBytes = latin1(name), valueBytes = latin1(value)
                    try encoder.encode(name: nameBytes.span.bytes, value: valueBytes.span.bytes, indexing: .prefer, into: &span)
                }
                return span.byteCount
            }
            return Array(output[0..<written])
        }
    }

    @Test func requests() throws {
        #expect(try encode(HPACKExampleTests.requestFields, tableSize: 4_096, huffman: false) == HPACKExampleTests.requests.map(hexBytes))
        #expect(try encode(HPACKExampleTests.requestFields, tableSize: 4_096, huffman: true) == HPACKExampleTests.huffmanRequests.map(hexBytes))
    }

    @Test func responses() throws {
        // The RFC's 256-byte table starts without a size update (it's the decoder's setting): encode with that table,
        // dropping the update the encoder sends when its peer's setting changes from 4,096.
        // One difference: C.6.2 Huffman-codes "307" in 3 bytes, as long as the raw string; this encoder codes only when
        // shorter (raw is cheaper to decode), so that block is C.5.2's.
        var huffmanResponses = HPACKExampleTests.huffmanResponses
        huffmanResponses[1] = HPACKExampleTests.responses[1]
        for (huffman, expected) in [(false, HPACKExampleTests.responses), (true, huffmanResponses)] {
            var blocks = try encode(HPACKExampleTests.responseFields, tableSize: 256, huffman: huffman)
            #expect(blocks[0].prefix(3) == [0x3F, 0xE1, 0x01], "a size update to 256")
            blocks[0].removeFirst(3)
            for (index, block) in blocks.enumerated() {
                #expect(block == hexBytes(expected[index]), "block \(index), huffman \(huffman): \(block.map { String($0, radix: 16) })")
            }
        }
    }
}
