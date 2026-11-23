import Bytes
import HTTP3
import HTTPBytes
import Testing

/// RFC 9204 Appendix B: an encoder's and a decoder's exchanges, with the dynamic table's state after each.
@Suite struct QPACKExampleTests {
    /// The examples' encoder stream instructions and field sections, in order.
    static let capacityAndInserts = hexBytes("3fbd01 c00f7777772e6578616d706c652e636f6d c10c2f73616d706c652f70617468")
    static let speculativeInsert = hexBytes("4a637573746f6d2d6b65790c637573746f6d2d76616c7565")
    static let duplicate = hexBytes("02")
    static let insertEvicting = hexBytes("810d637573746f6d2d76616c756532")

    @Test func literalWithNameReference() throws {
        // B.1: static name reference, raw value.
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        let section = hexBytes("0000 510b2f696e6465782e68746d6c")
        #expect(try decodeSection(&decoder, section, stream: 0) == [Field(":path", "/index.html")])
        #expect(decoderInstructions(&decoder).isEmpty)
        // The encoder writes the same bytes (static only, no Huffman: the example's value is raw).
        var encoder = QPACKEncoder(maximumTableCapacity: 0)
        encoder.usesHuffmanCoding = false
        let encoded = try encodeSection(&encoder, store([Field(":path", "/index.html")]), stream: 0)
        #expect(encoded.section == section)
        #expect(encoded.instructions.isEmpty)
    }

    @Test func dynamicTable() throws {
        // B.2: capacity 220, two insertions with static name references, then a section of two post-base indexes.
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        try applyEncoderStream(&decoder, Self.capacityAndInserts)
        #expect(decoder.tableCapacity == 220)
        #expect(tableEntries(decoder) == [Field(":authority", "www.example.com"), Field(":path", "/sample/path")])
        #expect(decoder.tableSize == 106)
        let fields = try decodeSection(&decoder, hexBytes("0381 10 11"), stream: 4)
        #expect(fields == [Field(":authority", "www.example.com"), Field(":path", "/sample/path")])
        // Section Acknowledgment for stream 4, which acknowledges both insertions (no Insert Count Increment).
        #expect(decoderInstructions(&decoder) == [0x84])
    }

    @Test func speculativeInsert() throws {
        // B.3: an insertion with a literal name, acknowledged by an Insert Count Increment.
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        try applyEncoderStream(&decoder, Self.capacityAndInserts)
        _ = try decodeSection(&decoder, hexBytes("0381 10 11"), stream: 4)
        #expect(decoderInstructions(&decoder) == [0x84])
        try applyEncoderStream(&decoder, Self.speculativeInsert)
        #expect(decoder.tableSize == 160)
        #expect(tableEntries(decoder).last == Field("custom-key", "custom-value"))
        #expect(decoderInstructions(&decoder) == [0x01])
    }

    @Test func duplicateAndStreamCancellation() throws {
        // B.4: the section arrives before the Duplicate it needs: blocked, then the stream is cancelled.
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        try applyEncoderStream(&decoder, Self.capacityAndInserts)
        _ = try decodeSection(&decoder, hexBytes("0381 10 11"), stream: 4)
        try applyEncoderStream(&decoder, Self.speculativeInsert)
        _ = decoderInstructions(&decoder)
        let section = hexBytes("0500 80 c1 81")
        #expect(try decodeSection(&decoder, section, stream: 8) == nil)
        #expect(decoder.blockedStreamCount == 1)
        try decoder.cancelStream(8)
        #expect(decoder.blockedStreamCount == 0)
        #expect(decoderInstructions(&decoder) == [0x48])
        try applyEncoderStream(&decoder, Self.duplicate)
        #expect(decoder.tableSize == 217)
        #expect(tableEntries(decoder) == [
            Field(":authority", "www.example.com"), Field(":path", "/sample/path"), Field("custom-key", "custom-value"),
            Field(":authority", "www.example.com"),
        ])
        #expect(decoder.nextUnblockedStream() == nil)
        // Had it not been cancelled, the section decodes once the Duplicate arrives.
        #expect(try decodeSection(&decoder, section, stream: 8) == [
            Field(":authority", "www.example.com"), Field(":path", "/"), Field("custom-key", "custom-value"),
        ])
    }

    @Test func blockedSectionUnblocks() throws {
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        try applyEncoderStream(&decoder, Self.capacityAndInserts + Self.speculativeInsert)
        let section = hexBytes("0500 80 c1 81")
        #expect(try decodeSection(&decoder, section, stream: 8) == nil)
        // Begun again while still blocked: still one blocked stream.
        #expect(try decodeSection(&decoder, section, stream: 8) == nil)
        #expect(decoder.blockedStreamCount == 1)
        #expect(decoder.nextUnblockedStream() == nil)
        try applyEncoderStream(&decoder, Self.duplicate)
        #expect(decoder.nextUnblockedStream() == 8)
        #expect(decoder.nextUnblockedStream() == nil)
        #expect(try decodeSection(&decoder, section, stream: 8)?.count == 3)
        // The acknowledgment, then an increment for the insertions it didn't cover (none: it needed all four).
        #expect(decoderInstructions(&decoder) == [0x88])
    }

    @Test func insertEvicting() throws {
        // B.5: an insertion with a dynamic name reference, evicting the oldest entry.
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        try applyEncoderStream(&decoder, Self.capacityAndInserts + Self.speculativeInsert + Self.duplicate + Self.insertEvicting)
        #expect(decoder.tableSize == 215)
        #expect(decoder.insertCount == 5)
        #expect(tableEntries(decoder) == [
            Field(":path", "/sample/path"), Field("custom-key", "custom-value"), Field(":authority", "www.example.com"),
            Field("custom-key", "custom-value2"),
        ])
    }

    @Test func encoderStreamSplitAtEveryByte() throws {
        // The examples' encoder stream fed one byte at a time, keeping what isn't consumed, as a stream reader would.
        let stream = Self.capacityAndInserts + Self.speculativeInsert + Self.duplicate + Self.insertEvicting
        for split in 1...stream.count {
            var decoder = QPACKDecoder(maximumTableCapacity: 220)
            var pending: [UInt8] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + split, stream.count)
                pending += stream[offset..<end]
                offset = end
                let used = try decoder.processEncoderStream(pending.span.bytes)
                pending.removeFirst(used)
            }
            #expect(pending.isEmpty)
            #expect(decoder.tableSize == 215, "split \(split)")
            #expect(decoder.insertCount == 5)
        }
    }

    @Test func encoderAcknowledgments() throws {
        // The encoder's side: Section Acknowledgment raises the Known Received Count to the section's Required Insert
        // Count; Insert Count Increment adds; Stream Cancellation forgets the stream's sections.
        var encoder = QPACKEncoder(maximumTableCapacity: 220)
        encoder.setPeerSettings(maximumTableCapacity: 220, blockedStreams: 1)
        let fields = store([Field(":authority", "www.example.com"), Field(":path", "/sample/path")])
        let first = try encodeSection(&encoder, fields, stream: 4, indexing: .prefer)
        #expect(encoder.insertCount == 2)
        #expect(encoder.unacknowledgedSectionCount == 1)
        // Decodes as the RFC's section does.
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        try applyEncoderStream(&decoder, first.instructions)
        #expect(try decodeSection(&decoder, first.section, stream: 4) == [Field(":authority", "www.example.com"), Field(":path", "/sample/path")])
        let feedback = decoderInstructions(&decoder)
        #expect(feedback == [0x84])
        #expect(try encoder.processDecoderStream(feedback.span.bytes) == 1)
        #expect(encoder.acknowledgedInsertCount == 2)
        #expect(encoder.unacknowledgedSectionCount == 0)
        // An acknowledgment for a stream with nothing outstanding, and an increment past the inserts, are errors.
        #expect(throws: QPACKError.invalidDecoderInstruction) { _ = try encoder.processDecoderStream(([0x84] as [UInt8]).span.bytes) }
        #expect(throws: QPACKError.invalidDecoderInstruction) { _ = try encoder.processDecoderStream(([0x01] as [UInt8]).span.bytes) }
        #expect(throws: QPACKError.invalidDecoderInstruction) { _ = try encoder.processDecoderStream(([0x00] as [UInt8]).span.bytes) }
        // A cut-off instruction is left for later.
        #expect(try encoder.processDecoderStream(([0xFF] as [UInt8]).span.bytes) == 0)
    }
}
