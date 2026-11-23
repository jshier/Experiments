import Bytes
import BytesTestSupport
import BytesTesting
import HTTP3
import HTTPBytes
import Testing

/// Malformed sections and instruction streams, and the decoder's limits.
@Suite struct QPACKErrorTests {
    /// A decoder with RFC 9204 B.2's table: capacity 220 (MaxEntries 6), :authority=www.example.com at absolute index 0,
    /// :path=/sample/path at 1.
    static func decoder(maximumBlockedStreams: Int = 100) throws -> QPACKDecoder {
        var decoder = QPACKDecoder(maximumTableCapacity: 220, maximumBlockedStreams: maximumBlockedStreams)
        try applyEncoderStream(&decoder, QPACKExampleTests.capacityAndInserts)
        return decoder
    }

    /// The error decoding `section` throws, or `nil` if it decodes (or blocks).
    static func error(_ decoder: inout QPACKDecoder, _ section: String, stream: UInt64 = 4) -> QPACKError? {
        do throws(QPACKError) {
            _ = try decodeSection(&decoder, hexBytes(section), stream: stream)
            return nil
        } catch {
            return error
        }
    }

    @Test(arguments: [
        ("0d00", QPACKError.invalidRequiredInsertCount),     // encoded 13 > 2 × MaxEntries
        ("0381", .invalidRequiredInsertCount),                // Base 0, no lines: a larger Required Insert Count than needed
        ("0382", .invalidBase),                              // Delta Base ≥ Required Insert Count
        ("0081", .invalidBase),                              // Sign with a Required Insert Count of 0
        ("030081", .invalidRequiredInsertCount),             // needs only Required Insert Count 1
        ("020180", .invalidIndex),                           // Base 2: absolute index 1 ≥ Required Insert Count 1
        ("038112", .invalidIndex),                           // post-base index past the Required Insert Count
        ("030082", .invalidIndex),                           // relative index ≥ Base
        ("0000ff24", .invalidIndex),                         // static index 99
        ("00005f54", .invalidIndex),                         // static name index 99
        ("03004201", .invalidIndex),                         // dynamic name relative index 2 ≥ Base 2
        ("03", .truncated),
        ("0300", .invalidRequiredInsertCount),               // no lines: references nothing
        ("000051", .truncated),
        ("0000510b2f696e", .truncated),
        ("0000518100", .invalidHuffmanCode),                 // padding that isn't all ones
        ("00005184ffffffff", .invalidHuffmanCode),           // EOS
        ("0000ffffffffffffffffffff7f", .integerOverflow),
    ] as [(String, QPACKError)])
    func malformedSection(_ section: String, _ expected: QPACKError) throws {
        var decoder = try Self.decoder()
        #expect(Self.error(&decoder, section) == expected, "\(section)")
    }

    @Test func requiredInsertCountWithoutATable() throws {
        // MaxEntries 0: any nonzero Required Insert Count is invalid.
        var decoder = QPACKDecoder(maximumTableCapacity: 0)
        #expect(Self.error(&decoder, "0100") == .invalidRequiredInsertCount)
        #expect(Self.error(&decoder, "0000c0") == nil)
    }

    @Test func requiredInsertCountWraps() throws {
        // 20 insertions into a 64-byte table (MaxEntries 2, encoded counts wrap every 4): the newest entry, absolute
        // index 19, needs Required Insert Count 20, encoded 20 % 4 + 1 = 1.
        var decoder = QPACKDecoder(maximumTableCapacity: 64)
        try applyEncoderStream(&decoder, hexBytes("3f21") + Array(repeating: hexBytes("c000"), count: 20).flatMap { $0 })
        #expect(decoder.insertCount == 20)
        #expect(try decodeSection(&decoder, hexBytes("0100 80"), stream: 0) == [Field(":authority", "")])
        // Encoded 2 would be Required Insert Count 21: blocked, not an error.
        #expect(try decodeSection(&decoder, hexBytes("0200 80"), stream: 4) == nil)
    }

    @Test func evictedReference() throws {
        var decoder = try Self.decoder()
        try applyEncoderStream(&decoder, QPACKExampleTests.speculativeInsert + QPACKExampleTests.duplicate + QPACKExampleTests.insertEvicting)
        // Absolute index 0 was evicted by B.5's insertion.
        #expect(Self.error(&decoder, "020080") == .invalidIndex)
        #expect(Self.error(&decoder, "030080") == nil)
    }

    @Test func blockedBeyondTheLimit() throws {
        var decoder = try Self.decoder(maximumBlockedStreams: 1)
        #expect(Self.error(&decoder, "0400 80", stream: 4) == nil)
        #expect(decoder.blockedStreamCount == 1)
        #expect(Self.error(&decoder, "0400 80", stream: 8) == .tooManyBlockedStreams)
        var none = try Self.decoder(maximumBlockedStreams: 0)
        #expect(Self.error(&none, "0400 80", stream: 4) == .tooManyBlockedStreams)
    }

    @Test func fieldSectionTooLarge() throws {
        var decoder = QPACKDecoder(maximumTableCapacity: 0, maximumFieldSectionSize: 40)
        // :path=/index.html is 5 + 11 + 32 = 48.
        #expect(Self.error(&decoder, "0000510b2f696e6465782e68746d6c") == .fieldSectionTooLarge)
        #expect(Self.error(&decoder, "0000c1") == nil)
        var store = HTTPFieldStore()
        #expect(throws: QPACKError.fieldSectionTooLarge) {
            _ = try decoder.decode(hexBytes("0000510b2f696e6465782e68746d6c").span.bytes, stream: 0, into: &store)
        }
    }

    @Test(arguments: [
        ("3fbe01", QPACKError.tableCapacityTooLarge),        // capacity 221 > 220
        ("3fbd01c07f49", .entryTooLarge),                    // a 200-byte value with a 10-byte name: known from the length
        ("3fbd01c08100", .invalidEncoderInstruction),        // Huffman padding that isn't all ones
        ("3fbd0101", .invalidEncoderInstruction),            // Duplicate of an entry that isn't there
        ("3fbd0181", .invalidEncoderInstruction),            // dynamic name reference to an entry that isn't there
        ("3fbd01ff24", .invalidEncoderInstruction),          // static name index 99
        ("3fbd01ffffffffffffffffffff7f", .invalidEncoderInstruction),
        ("c000", .entryTooLarge),                            // capacity 0
    ] as [(String, QPACKError)])
    func malformedEncoderStream(_ stream: String, _ expected: QPACKError) {
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        #expect(throws: expected) { _ = try decoder.processEncoderStream(hexBytes(stream).span.bytes) }
    }

    @Test func incompleteEncoderInstructions() throws {
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        #expect(try decoder.processEncoderStream(hexBytes("3fbd01c00f7777").span.bytes) == 3)
        #expect(try decoder.processEncoderStream(hexBytes("3f").span.bytes) == 0)
        #expect(decoder.tableCapacity == 220)
        #expect(decoder.insertCount == 0)
    }

    @Test func errorCorpus() throws {
        // qifs' encoded/errors: under RFC 9204, err9 (static index 0) and err10 (static index 62) are valid; the rest
        // fail. Each is a field section on stream 1, or encoder stream bytes.
        for number in 1...12 {
            let records = try QIFCorpus.records("errors/err\(number)")
            var decoder = QPACKDecoder(maximumTableCapacity: 4_096)
            var failed = false
            for (stream, bytes) in records {
                do throws(QPACKError) {
                    if stream == 0 {
                        let used = try decoder.processEncoderStream(bytes.span.bytes)
                        if used < bytes.count { failed = true }
                    } else if try decodeSection(&decoder, bytes, stream: stream) == nil {
                        failed = true
                    }
                } catch {
                    failed = true
                }
            }
            #expect(failed == !(number == 9 || number == 10), "err\(number)")
        }
    }

    @Test func decoderStreamFull() throws {
        // A 32-byte buffer holds three 9-byte acknowledgments of large stream IDs; a fourth section must wait.
        var decoder = QPACKDecoder(maximumTableCapacity: 220, decoderStreamCapacity: 32)
        try applyEncoderStream(&decoder, QPACKExampleTests.capacityAndInserts)
        let section = hexBytes("0381 10 11")
        for stream in 0..<3 {
            #expect(try decodeSection(&decoder, section, stream: (1 << 50) + UInt64(stream) * 4)?.count == 2)
        }
        #expect(throws: QPACKError.decoderStreamFull) { _ = try decodeSection(&decoder, section, stream: 4) }
        #expect(throws: QPACKError.decoderStreamFull) { try decoder.cancelStream(1 << 50) }
        let written = decoderInstructions(&decoder)
        #expect(written.count == 27)
        #expect(try decodeSection(&decoder, section, stream: 4)?.count == 2)
        #expect(decoderInstructions(&decoder) == [0x84])
    }

    @Test func truncatedAtEveryByte() throws {
        // Each section of a dynamic-table connection, cut at every byte: an error, or a prefix of its fields (a cut at a
        // line's end), never anything else.
        let sets = Array(HTTPCorpus.requests.value.prefix(20))
        var encoder = QPACKEncoder()
        encoder.setPeerSettings(maximumTableCapacity: 4_096, blockedStreams: 10)
        var decoder = QPACKDecoder()
        for (index, set) in sets.enumerated() {
            let encoded = try encodeSection(&encoder, store(set), stream: UInt64(index * 4))
            try applyEncoderStream(&decoder, encoded.instructions)
            for cut in 0..<encoded.section.count {
                let section = Array(encoded.section[0..<cut])
                var fields: [Field] = []
                do throws(QPACKError) {
                    let span = section.span.bytes
                    if try decoder.begin(span, stream: 1) {
                        while let field = try decoder.next(in: span) {
                            fields.append(Field(name: Array(copying: field.name), value: Array(copying: field.value)))
                        }
                    }
                } catch {
                    continue
                }
                #expect(fields.count <= set.count && Array(set.prefix(fields.count)) == fields.map { Field(name: $0.name, value: $0.value) })
            }
            _ = decoderInstructions(&decoder)
            #expect(try decodeSection(&decoder, encoded.section, stream: UInt64(index * 4)) == set)
            let feedback = decoderInstructions(&decoder)
            _ = try encoder.processDecoderStream(feedback.span.bytes)
        }
    }

    @Test func validatesHTTP3Sections() throws {
        var decoder = QPACKDecoder(maximumTableCapacity: 0)
        func validate(_ fields: [Field], _ section: HTTP3FieldValidator.Section) throws -> HTTP3FieldValidator.PseudoHeaders {
            var encoder = QPACKEncoder(maximumTableCapacity: 0)
            return try validate(encoded: encodeSection(&encoder, store(fields), stream: 0).section, section)
        }
        func validate(encoded: [UInt8], _ section: HTTP3FieldValidator.Section) throws -> HTTP3FieldValidator.PseudoHeaders {
            var validator = HTTP3FieldValidator(section)
            let span = encoded.span.bytes
            _ = try decoder.begin(span, stream: 0)
            while let field = try decoder.next(in: span) { try validator.check(field) }
            return try validator.finish()
        }
        let request = [Field(":method", "GET"), Field(":scheme", "https"), Field(":path", "/"), Field(":authority", "a"), Field("accept", "*/*")]
        #expect(try validate(request, .request).contains(.pseudoPath))
        #expect(throws: HTTP3FieldError.connectionSpecificField) { _ = try validate(request + [Field("connection", "close")], .request) }
        #expect(throws: HTTP3FieldError.pseudoHeaderAfterRegularField) { _ = try validate([Field("accept", "*/*")] + request, .request) }
        // The encoder lowercases names (RFC 9114 §4.2); a peer that doesn't is caught: the request's pseudo-header
        // fields from the static table, then a literal name `Abc`.
        #expect(try validate(request + [Field("Accept", "x")], .request).contains(.pseudoPath))
        #expect(throws: HTTP3FieldError.invalidName) {
            _ = try validate(encoded: hexBytes("0000 d1 d7 c1 50 0161 23416263 0178"), .request)
        }
        #expect(throws: HTTP3FieldError.invalidValue) { _ = try validate(request + [Field("x", " y")], .request) }
        #expect(throws: HTTP3FieldError.missingPseudoHeader) { _ = try validate([Field(":method", "CONNECT"), Field(":path", "/")], .request) }
        #expect(try validate([Field(":status", "200")], .response).status == 200)
        #expect(HTTP3FieldError.invalidName.http3Error == .stream(.messageError))
    }
}

@Suite(.bulk) struct QPACKErrorBulkTests {
    /// Every section of the http-corpus connections, cut at every byte, as `truncatedAtEveryByte`.
    @Test func mutatedSections() throws {
        // Each section with one byte changed at every offset, every value: an error, blocked, or fields (whatever they
        // are), never a crash or a read out of bounds.
        let sets = Array(HTTPCorpus.responses.value.prefix(40))
        var encoder = QPACKEncoder()
        encoder.setPeerSettings(maximumTableCapacity: 4_096, blockedStreams: 10)
        var decoder = QPACKDecoder()
        var outcomes = 0
        for (index, set) in sets.enumerated() {
            let encoded = try encodeSection(&encoder, store(set), stream: UInt64(index * 4))
            try applyEncoderStream(&decoder, encoded.instructions)
            for offset in 0..<encoded.section.count {
                for value in [0x00, 0x01, 0x3F, 0x40, 0x7F, 0x80, 0xBF, 0xC0, 0xFF] as [UInt8] {
                    var section = encoded.section
                    section[offset] = value
                    do throws(QPACKError) {
                        _ = try decodeSection(&decoder, section, stream: 1)
                    } catch {}
                    _ = decoder.nextUnblockedStream()
                    try? decoder.cancelStream(1)
                    _ = decoderInstructions(&decoder)
                    outcomes += 1
                }
            }
            #expect(try decodeSection(&decoder, encoded.section, stream: UInt64(index * 4)) == set)
            let feedback = decoderInstructions(&decoder)
            _ = try encoder.processDecoderStream(feedback.span.bytes)
        }
        #expect(outcomes > 10_000)
    }
}
