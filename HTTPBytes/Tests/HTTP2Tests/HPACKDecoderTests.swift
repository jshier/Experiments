import Bytes
import BytesTesting
import BytesTestSupport
import HTTP2
import HTTPBytes
import Testing

/// The decoder on malformed blocks, table limits, and eviction; prefix integers and the Huffman code alone; the
/// encoder's strategies and size updates; and both against a model of the table on random fields.
@Suite struct HPACKDecoderTests {
    func error(_ hex: String, decoder: inout HPACKDecoder) -> HPACKError? {
        error(bytes: hexBytes(hex), decoder: &decoder)
    }

    func error(bytes: [UInt8], decoder: inout HPACKDecoder) -> HPACKError? {
        do throws(HPACKError) {
            _ = try decodeAll(&decoder, bytes)
            return nil
        } catch {
            // A decoder that threw takes no other block until it's reset (`HPACKError.unfinishedBlock`).
            decoder.resetBlock()
            return error
        }
    }

    func error(_ hex: String, tableSize: Int = 4_096) -> HPACKError? {
        var decoder = HPACKDecoder(maximumTableSize: tableSize)
        return error(hex, decoder: &decoder)
    }

    @Test func malformedBlocks() throws {
        #expect(error("80") == .invalidIndex) // index 0
        #expect(error("be") == .invalidIndex) // 62, an empty dynamic table
        #expect(error("ff 80 01") == .invalidIndex) // 127 + 128
        #expect(error("7e 01 61") == .invalidIndex) // a name index past the tables
        #expect(error("0f 30 01 61") == .invalidIndex) // 15 + 48 = 63, without indexing
        #expect(error("3f e2 1f") == .tableSizeUpdateTooLarge) // 31 + 4066 = 4097
        #expect(error("82 20") == .misplacedTableSizeUpdate) // after a field
        #expect(error("ff ff ff ff ff ff 0f") == .integerOverflow) // 6 continuation bytes
        #expect(error("ff 80 80 80 80 10") == .integerOverflow) // past 2³² − 1
        #expect(error("ff") == .truncated)
        #expect(error("ff 80") == .truncated)
        #expect(error("82 41") == .truncated) // a literal without its value
        #expect(error("00 05 61") == .truncated) // a string past the block's end
        #expect(error("00 81") == .truncated)
        // Huffman (RFC 7541 §5.2): 'a' (00011) then 11 bits of ones; then 3 bits of zeros; then EOS (30 ones) and 2 more.
        #expect(error("00 82 1f ff 01 61") == .invalidHuffmanCode)
        #expect(error("00 81 18 01 61") == .invalidHuffmanCode)
        #expect(error("00 84 ff ff ff ff 01 61") == .invalidHuffmanCode)
        // Valid: 'a' and 3 ones.
        var decoder = HPACKDecoder()
        #expect(try decodeAll(&decoder, hexBytes("00 81 1f 01 61")) == fields([("a", "a")]))
    }

    @Test func errorsAreCompressionErrors() {
        #expect(HPACKError.invalidIndex.http2Error(stream: HTTP2StreamID(1)) == .connection(.compressionError))
        #expect(HPACKError.headerListTooLarge.http2Error(stream: HTTP2StreamID(1)) == .stream(HTTP2StreamID(1), .refusedStream))
    }

    @Test func sizeUpdates() throws {
        var decoder = HPACKDecoder()
        // Two updates at the start are allowed; the table shrinks to the last.
        #expect(try decodeAll(&decoder, hexBytes("20 3f e1 1f 82")) == fields([(":method", "GET")]))
        #expect(decoder.tableMaximumSize == 4_096)
        _ = try decodeAll(&decoder, hexBytes("40 01 61 01 62")) // a: b, 34 bytes
        #expect(decoder.tableSize == 34)
        _ = try decodeAll(&decoder, hexBytes("20")) // to 0: evicts everything
        #expect(decoder.tableCount == 0 && decoder.tableMaximumSize == 0)
        // An update at the end of a block, alone, is a block with no fields.
        #expect(try decodeAll(&decoder, hexBytes("3f e1 1f")) == [])
        #expect(decoder.tableMaximumSize == 4_096)
    }

    @Test func loweredSettingRequiresAnUpdate() throws {
        var decoder = HPACKDecoder()
        decoder.setMaximumTableSize(100)
        #expect(error("82", decoder: &decoder) == .missingTableSizeUpdate)
        decoder.setMaximumTableSize(100)
        #expect(error("3f 46 82", decoder: &decoder) == .tableSizeUpdateTooLarge) // 101: above the setting
        decoder.setMaximumTableSize(100)
        #expect(try decodeAll(&decoder, hexBytes("3f 45 82")) == fields([(":method", "GET")])) // 100
        // Lowered twice then raised: the first update must be at most the smallest.
        decoder.setMaximumTableSize(50)
        decoder.setMaximumTableSize(200)
        #expect(error("3f 45 82", decoder: &decoder) == .missingTableSizeUpdate)
        decoder.setMaximumTableSize(50)
        decoder.setMaximumTableSize(200)
        #expect(try decodeAll(&decoder, hexBytes("3f 13 3f a9 01 82")) == fields([(":method", "GET")])) // 50, then 200
        #expect(decoder.tableMaximumSize == 200)
        // Raised: no update needed, and the table can grow (with more memory) when the peer says so.
        decoder.setMaximumTableSize(8_192)
        #expect(try decodeAll(&decoder, hexBytes("82")).count == 1)
        #expect(try decodeAll(&decoder, hexBytes("3f e1 3f 82")).count == 1) // 8,192
        #expect(decoder.tableMaximumSize == 8_192)
    }

    @Test func growingKeepsEntries() throws {
        var decoder = HPACKDecoder(maximumTableSize: 100)
        _ = try decodeAll(&decoder, hexBytes("40 01 61 01 62 40 01 63 01 64")) // a: b, c: d
        decoder.setMaximumTableSize(10_000)
        #expect(tableEntries(decoder) == fields([("c", "d"), ("a", "b")]))
        #expect(try decodeAll(&decoder, hexBytes("be bf")) == fields([("c", "d"), ("a", "b")]))
    }

    @Test func headerListLimit() throws {
        var decoder = HPACKDecoder(maximumHeaderListSize: 50)
        let block = hexBytes("82 40 01 61 01 62 84") // :method GET (42), a: b (34), :path / (38)
        #expect(error("82 40 01 61 01 62 84", decoder: &decoder) == .headerListTooLarge)
        // The rest of the block can be skipped, keeping the table: a: b was inserted.
        var partial = HPACKDecoder(maximumHeaderListSize: 50)
        let span = block.span.bytes
        #expect(try partial.next(in: span)?.knownName == .pseudoMethod)
        #expect(throws: HPACKError.headerListTooLarge) { _ = try partial.next(in: span) }
        try partial.skipRest(of: span)
        #expect(tableEntries(partial) == fields([("a", "b")]))
        #expect(try decodeAll(&partial, hexBytes("be")) == fields([("a", "b")]))
        // A Huffman string longer than the decoder's scratch (and so the table): skipped, the table emptied.
        var small = HPACKDecoder(maximumTableSize: 64, maximumHeaderListSize: 64)
        _ = try decodeAll(&small, hexBytes("40 01 61 01 62"))
        var long = hexBytes("40 01 78 ff 80 01") // x: a 255-byte Huffman string of 'a's (5 bits each: 408 decoded)
        long += [UInt8](repeating: 0x08, count: 255)
        let longError = error(bytes: long, decoder: &small)
        #expect(longError == .headerListTooLarge)
        #expect(small.tableCount == 0)
    }

    /// A literal whose name is a dynamic entry that inserting it evicts: the name is moved before it's overwritten.
    @Test func nameFromAnEvictedEntry() throws {
        var decoder = HPACKDecoder(maximumTableSize: 50)
        _ = try decodeAll(&decoder, hexBytes("40 04 61616161 01 78")) // aaaa: x (37)
        let decoded = try decodeAll(&decoder, hexBytes("7e 0a 79797979797979797979")) // name 62, 10 'y's (46)
        #expect(decoded == fields([("aaaa", "yyyyyyyyyy")]))
        #expect(tableEntries(decoder) == fields([("aaaa", "yyyyyyyyyy")]))
        // An entry larger than the table empties it.
        _ = try decodeAll(&decoder, hexBytes("40 04 62626262 0f 787878787878787878787878787878"))
        #expect(decoder.tableCount == 0 && decoder.tableSize == 0)
    }

    @Test func knownNames() throws {
        var decoder = HPACKDecoder()
        // A literal `content-type` resolves to its known name; `Content-Type` (uppercase: malformed in HTTP/2) doesn't.
        let decoded = try decodeAll(&decoder, hexBytes("40 0c 636f6e74656e742d74797065 01 61 40 0c 436f6e74656e742d54797065 01 61 be bf"))
        #expect(decoded.map(\.known) == [.contentType, nil, nil, .contentType])
        // Every known name round-trips through the exact lookup; other spellings don't.
        for index in 0..<HTTPFieldName.knownCount {
            let name = HTTPFieldName(index: index)!
            let bytes = Array(copying: name.lowercaseBytes)
            #expect(HTTPFieldName(lowercase: bytes.span.bytes) == name)
            let upper = bytes.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }
            if upper != bytes { #expect(HTTPFieldName(lowercase: upper.span.bytes) == nil) }
        }
        #expect(HTTPFieldName(lowercase: Array("content\rtype".utf8).span.bytes) == nil)
    }

    @Test func neverIndexedIsReported() throws {
        var encoder = HPACKEncoder()
        var decoder = HPACKDecoder()
        var store = HTTPFieldStore()
        try store.append(.authorization, value: Array("Bearer secret-token-value".utf8).span.bytes, flags: HTTPFieldStore.neverIndexed)
        try store.append(.userAgent, value: Array("test".utf8).span.bytes)
        let block = try encodeBlock(&encoder, store)
        #expect(Array(block.prefix(2)) == [0x1F, 0x08], "\(block)") // never indexed, name index 23 (15 + 8)
        var decoded = HTTPFieldStore()
        try decoder.decode(block.span.bytes, into: &decoded)
        #expect(decoded.count == 2 && decoded.flags(at: 0) == HTTPFieldStore.neverIndexed && decoded.flags(at: 1) == 0)
        #expect(decoder.tableCount == 1) // only user-agent
    }

    @Test func automaticStrategy() throws {
        var encoder = HPACKEncoder()
        var store = HTTPFieldStore()
        try store.append(.cookie, value: Array("short=1".utf8).span.bytes) // under 20 bytes: never indexed
        try store.append(.pseudoPath, value: Array("/a/b/c".utf8).span.bytes) // not indexed
        try store.append(.contentType, value: Array("text/html".utf8).span.bytes) // indexed
        var decoder = HPACKDecoder()
        let block = try encodeBlock(&encoder, store)
        let decoded = try decodeAll(&decoder, block)
        #expect(decoded.map(\.neverIndexed) == [true, false, false])
        #expect(tableEntries(decoder) == fields([("content-type", "text/html")]))
        // The second time, content-type is one byte.
        let again = try encodeBlock(&encoder, store)
        #expect(again.last == 0xBE)
    }

    @Test func encoderSizeUpdates() throws {
        var encoder = HPACKEncoder(maximumTableSize: 8_192)
        var decoder = HPACKDecoder(maximumTableSize: 4_096)
        var store = HTTPFieldStore()
        try store.append(.contentType, value: Array("text/html".utf8).span.bytes)
        _ = try decodeAll(&decoder, encodeBlock(&encoder, store))
        // Lowered to 0, then raised to 2,048, between blocks: updates to 0 and 2,048.
        encoder.setPeerMaximumTableSize(0)
        encoder.setPeerMaximumTableSize(2_048)
        decoder.setMaximumTableSize(0)
        decoder.setMaximumTableSize(2_048)
        let block = try encodeBlock(&encoder, store)
        #expect(Array(block.prefix(4)) == [0x20, 0x3F, 0xE1, 0x0F])
        _ = try decodeAll(&decoder, block)
        #expect(decoder.tableMaximumSize == 2_048 && encoder.tableMaximumSize == 2_048)
        #expect(tableEntries(decoder) == fields([("content-type", "text/html")]))
        // A setting above what the encoder was made with: it uses its own maximum.
        encoder.setPeerMaximumTableSize(1 << 20)
        #expect(encoder.tableMaximumSize == 8_192)
    }

    @Test func outputTooSmall() throws {
        var encoder = HPACKEncoder()
        var store = HTTPFieldStore()
        try store.append(.userAgent, value: Array("a long user agent string".utf8).span.bytes)
        var output = [UInt8](repeating: 0, count: 10)
        #expect(throws: HPACKError.outputTooSmall) {
            try output.withOutputRawSpan { span throws(HPACKError) in try encoder.encode(store, into: &span) }
        }
    }

    @Test func prefixIntegers() throws {
        // RFC 7541 C.1: 10 and 1337 with 5-bit prefixes, 42 with 8 bits.
        for (value, bits, bytes) in [(10, 5, [0x0A]), (1_337, 5, [0x1F, 0x9A, 0x0A]), (42, 8, [0x2A]), (0xFFFF_FFFF, 1, [0x01, 0xFE, 0xFF, 0xFF, 0xFF, 0x0F])] as [(Int, Int, [UInt8])] {
            var output = [UInt8](repeating: 0, count: 8)
            let written = try output.withOutputRawSpan { span throws(HPACKPrefixIntegerError) -> Int in
                try HPACKPrefixInteger.write(value, prefixBits: bits, into: &span)
                return span.byteCount
            }
            #expect(Array(output[0..<written]) == bytes)
            #expect(HPACKPrefixInteger.byteCount(of: value, prefixBits: bits) == bytes.count)
            var offset = 0
            #expect(try HPACKPrefixInteger.read(from: bytes.span.bytes, at: &offset, prefixBits: bits) == value)
            #expect(offset == bytes.count)
        }
        var offset = 0
        #expect(throws: HPACKPrefixIntegerError.truncated) { _ = try HPACKPrefixInteger.read(from: [UInt8]([0x1F, 0x9A]).span.bytes, at: &offset, prefixBits: 5) }
        #expect(throws: HPACKPrefixIntegerError.overflow) { _ = try HPACKPrefixInteger.read(from: [UInt8]([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x10]).span.bytes, at: &offset, prefixBits: 1) }
    }

    @Test func huffmanAPI() throws {
        var generator = SplitMix64(seed: 7)
        for length in [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 64, 127, 128, 200, 1_000] {
            // Printable text, and every byte value.
            for alphabet in [Array(0x20...0x7E) as [UInt8], Array(0...255) as [UInt8]] {
                let input = (0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }
                var coded = [UInt8](repeating: 0, count: length * 4 + 8)
                let codedCount = try coded.withOutputRawSpan { span throws(HPACKHuffmanError) -> Int in
                    try HPACKHuffman.encode(input.span.bytes, into: &span)
                    return span.byteCount
                }
                #expect(codedCount == HPACKHuffman.encodedCount(of: input.span.bytes))
                // Exactly as much room as the result, and plenty: the careful and fast paths.
                for room in [length, length + 32] {
                    var decoded = [UInt8](repeating: 0, count: room)
                    let decodedCount = try decoded.withOutputRawSpan { span throws(HPACKHuffmanError) -> Int in
                        try HPACKHuffman.decode(coded.span.bytes.extracting(0..<codedCount), into: &span)
                        return span.byteCount
                    }
                    #expect(Array(decoded[0..<decodedCount]) == input, "length \(length), room \(room)")
                }
                if length > 0 {
                    var tooSmall = [UInt8](repeating: 0, count: length - 1)
                    #expect(throws: HPACKHuffmanError.outputTooSmall) {
                        try tooSmall.withOutputRawSpan { span throws(HPACKHuffmanError) in
                            try HPACKHuffman.decode(coded.span.bytes.extracting(0..<codedCount), into: &span)
                        }
                    }
                }
            }
        }
    }

    /// Random fields through the encoder and decoder at several table sizes, both tables checked against a model
    /// (a list of entries, evicted from the end) after every block.
    @Test(arguments: [0, 64, 100, 256, 1_000, 4_096])
    func modelTables(_ tableSize: Int) throws {
        try Self.checkModel(tableSize: tableSize, blocks: 200, seed: UInt64(tableSize))
    }

    static func checkModel(tableSize: Int, blocks: Int, seed: UInt64) throws {
        var generator = SplitMix64(seed: seed)
        func random(_ bound: Int) -> Int { Int(generator.next() % UInt64(bound)) }
        let names = ["a", "x-custom", "content-type", "user-agent", "cookie", "x-long-header-name-for-testing", ":path"]
        var encoder = HPACKEncoder(maximumTableSize: tableSize)
        encoder.setPeerMaximumTableSize(tableSize)
        var decoder = HPACKDecoder(maximumTableSize: tableSize)
        var model: [(String, String)] = []
        let strategies: [HPACKIndexingStrategy] = [.automatic, .prefer, .avoid, .disable]
        for _ in 0..<blocks {
            var pairs: [([UInt8], [UInt8])] = []
            var expected: [DecodedField] = []
            var strategy: [HPACKIndexingStrategy] = []
            for _ in 0..<(1 + random(8)) {
                let name = names[random(names.count)]
                let value = String(repeating: Character(Unicode.Scalar(UInt8(0x61 + random(4)))), count: random(3) == 0 ? random(200) : random(12))
                pairs.append((Array(name.utf8), Array(value.utf8)))
                expected.append(DecodedField(name: name, value: value))
                strategy.append(strategies[random(4)])
            }
            var output = [UInt8](repeating: 0, count: 1 << 14)
            let written = try output.withOutputRawSpan { span throws(HPACKError) -> Int in
                for (index, (name, value)) in pairs.enumerated() {
                    try encoder.encode(name: name.span.bytes, value: value.span.bytes, indexing: strategy[index], into: &span)
                }
                return span.byteCount
            }
            let decoded = try decodeAll(&decoder, Array(output[0..<written]))
            #expect(decoded.map { DecodedField(name: $0.name, value: $0.value) } == expected)
            // The model: what the decoder says was inserted (a literal with incremental indexing) goes in front.
            var position = 0
            let block = Array(output[0..<written])
            for field in expected where Self.isIndexedLiteral(block, &position) {
                model.insert((field.name, field.value), at: 0)
                var size = model.reduce(0) { $0 + $1.0.utf8.count + $1.1.utf8.count + 32 }
                while size > tableSize, let last = model.popLast() {
                    size -= last.0.utf8.count + last.1.utf8.count + 32
                }
            }
            #expect(tableEntries(decoder) == fields(model), "table \(tableSize)")
            #expect(encoder.tableSize == decoder.tableSize && encoder.tableCount == decoder.tableCount)
        }
    }

    /// Walks one representation of `block` at `position` (skipping size updates): whether it's a literal with
    /// incremental indexing.
    static func isIndexedLiteral(_ block: [UInt8], _ position: inout Int) -> Bool {
        func integer(_ mask: Int) -> Int {
            var value = Int(block[position]) & mask
            position += 1
            if value == mask {
                var shift = 0
                while true {
                    let byte = Int(block[position]); position += 1
                    value += (byte & 0x7F) << shift; shift += 7
                    if byte < 0x80 { break }
                }
            }
            return value
        }
        func string() { position += integer(0x7F) }
        while block[position] & 0xE0 == 0x20 {
            _ = integer(0x1F)
        }
        let first = block[position]
        if first & 0x80 != 0 { _ = integer(0x7F); return false }
        let indexing = first & 0x40 != 0
        if integer(indexing ? 0x3F : 0x0F) == 0 { string() }
        string()
        return indexing
    }
}

@Suite(.bulk) struct HPACKDecoderBulkTests {
    @Test(arguments: [0, 33, 64, 100, 150, 256, 512, 1_000, 4_096, 16_384])
    func modelTables(_ tableSize: Int) throws {
        for seed in 0..<20 {
            try HPACKDecoderTests.checkModel(tableSize: tableSize, blocks: 500, seed: UInt64(seed * 1_000 + tableSize))
        }
    }
}

/// One block of `store`'s fields.
func encodeBlock(_ encoder: inout HPACKEncoder, _ store: borrowing HTTPFieldStore) throws(HPACKError) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 1 << 16)
    let written = try output.withOutputRawSpan { span throws(HPACKError) -> Int in
        try encoder.encode(store, into: &span)
        return span.byteCount
    }
    return Array(output[0..<written])
}
