import Bytes
import BytesTestSupport
import BytesTesting
import HTTP3
import HTTPBytes
import Testing

// Defects an adversarial review found (2026-11-23), each with the probe that showed it.

/// A prefix integer (RFC 7541 §5.1) with `bits` of prefix after `flags`.
func prefixInteger(_ value: Int, bits: Int, flags: UInt8) -> [UInt8] {
    let mask = (1 << bits) - 1
    if value < mask { return [flags | UInt8(value)] }
    var bytes: [UInt8] = [flags | UInt8(mask)]
    var rest = value - mask
    while rest >= 128 {
        bytes.append(UInt8(rest & 0x7F) | 0x80)
        rest >>= 7
    }
    bytes.append(UInt8(rest))
    return bytes
}

/// `bytes` Huffman-coded.
func huffman(_ bytes: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: bytes.count * 4 + 16)
    let count = output.withOutputRawSpan { (span) -> Int in
        try! HPACKHuffman.encode(bytes.span.bytes, into: &span)
        return span.byteCount
    }
    return Array(output[0..<count])
}

/// The decoder's pending decoder stream bytes that fit `room`.
func decoderInstructions(_ decoder: inout QPACKDecoder, room: Int) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: room)
    let written = output.withOutputRawSpan { (span) -> Int in
        decoder.writeDecoderInstructions(into: &span)
        return span.byteCount
    }
    return Array(output[0..<written])
}

/// A decoder stream's instructions: the streams acknowledged and cancelled, and the increments.
func decoderStreamInstructions(_ bytes: [UInt8]) -> (acknowledged: [UInt64], cancelled: [UInt64], increments: [Int]) {
    var result: (acknowledged: [UInt64], cancelled: [UInt64], increments: [Int]) = ([], [], [])
    var offset = 0
    while offset < bytes.count {
        let first = bytes[offset]
        let mask = first >= 0x80 ? 0x7F : 0x3F
        var value = Int(first) & mask
        offset += 1
        if value == mask {
            var shift = 0
            while true {
                let byte = bytes[offset]
                offset += 1
                value += Int(byte & 0x7F) << shift
                shift += 7
                if byte < 0x80 { break }
            }
        }
        if first >= 0x80 { result.acknowledged.append(UInt64(value)) }
        else if first >= 0x40 { result.cancelled.append(UInt64(value)) }
        else { result.increments.append(value) }
    }
    return result
}

/// Whether `next(in:)` gave a field (`#expect` can't take the field itself).
func nextGivesField(_ decoder: inout QPACKDecoder, _ section: RawSpan) throws(QPACKError) -> Bool {
    try decoder.next(in: section) != nil
}

/// Encodes `fields` with no room at all for encoder stream instructions.
func encodeWithoutInstructionRoom(_ encoder: inout QPACKEncoder, _ fields: borrowing HTTPFieldStore, stream: UInt64) throws(QPACKError) -> [UInt8] {
    var section = [UInt8](repeating: 0, count: 4_096)
    var instructions: [UInt8] = []
    let count = try section.withOutputRawSpan { (sectionSpan) throws(QPACKError) -> Int in
        try instructions.withOutputRawSpan { (instructionSpan) throws(QPACKError) -> Int in
            try encoder.encode(fields, stream: stream, indexing: .prefer, into: &sectionSpan, instructions: &instructionSpan)
            return sectionSpan.byteCount
        }
    }
    return Array(section[0..<count])
}

@Suite struct QPACKRegressionTests {
    @Test func acknowledgmentsAreNeverDropped() throws {
        // A 32-byte decoder stream buffer holding 22 bytes of acknowledgments: room for one more 10-byte one, which the
        // section begun next reserves. An Insert Count Increment written in between (into an output with no room) once
        // took that room, and the section's acknowledgment was lost while the decoder counted it as sent: the peer's
        // encoder would have kept its entries pinned for good (RFC 9204 §2.1.1).
        var decoder = QPACKDecoder(maximumTableCapacity: 4_096, maximumBlockedStreams: 10, decoderStreamCapacity: 32)
        try applyEncoderStream(&decoder, prefixInteger(4_096, bits: 5, flags: 0x20) + [0x41, 0x61, 0x01, 0x62])
        // Required Insert Count 1 (encoded 2), Base 1, the entry by relative index 0.
        let section: [UInt8] = [0x02, 0x00, 0x80]
        let large: UInt64 = (1 << 62) - 4
        for stream in [large, large - 4, 128] { #expect(try decodeSection(&decoder, section, stream: stream)?.count == 1) }
        try applyEncoderStream(&decoder, [0x41, 0x63, 0x01, 0x64])
        let span = section.span.bytes
        #expect(try decoder.begin(span, stream: large - 8))
        #expect(decoderInstructions(&decoder, room: 0).isEmpty)
        while try decoder.next(in: span) != nil {}
        // Written a few bytes at a time: the increment comes only after every queued byte.
        var stream: [UInt8] = []
        for _ in 0..<20 { stream += decoderInstructions(&decoder, room: 3) }
        let instructions = decoderStreamInstructions(stream)
        #expect(instructions.acknowledged == [large, large - 4, 128, large - 8])
        #expect(instructions.increments == [1])
        let pending = decoder.hasDecoderInstructions
        #expect(!pending)
    }

    @Test func incompleteLiteralNameInsertIsNotDecoded() throws {
        // An Insert with Literal Name whose Huffman name is invalid (padding of zeros) and whose value hasn't arrived: once,
        // the name was decoded on every call before the value was known to be complete (quadratic for an instruction fed
        // a byte at a time). Now nothing is decoded until the whole instruction is here.
        var decoder = QPACKDecoder(maximumTableCapacity: 220)
        try applyEncoderStream(&decoder, hexBytes("3fbd01"))
        let instruction = hexBytes("61 00") + prefixInteger(3, bits: 7, flags: 0) + Array("abc".utf8)
        for end in 1..<instruction.count {
            #expect(try decoder.processEncoderStream(Array(instruction[0..<end]).span.bytes) == 0, "\(end) bytes")
        }
        #expect(throws: QPACKError.invalidEncoderInstruction) { _ = try decoder.processEncoderStream(instruction.span.bytes) }
    }

    @Test func literalNameInsertFedAByteAtATime() throws {
        // A Huffman-coded name and value of 2,000 bytes each (30-bit codes: 7,500 bytes each on the wire), a byte at a time.
        let name = huffman([UInt8](repeating: 0x0A, count: 2_000)), value = huffman([UInt8](repeating: 0x0A, count: 2_000))
        let instruction = prefixInteger(name.count, bits: 5, flags: 0x60) + name + prefixInteger(value.count, bits: 7, flags: 0x80) + value
        var decoder = QPACKDecoder(maximumTableCapacity: 4_096)
        try applyEncoderStream(&decoder, prefixInteger(4_096, bits: 5, flags: 0x20))
        var start = 0
        for end in 1...instruction.count {
            start += try decoder.processEncoderStream(instruction.span.bytes.extracting(start..<end))
        }
        #expect(start == instruction.count)
        #expect(tableEntries(decoder) == [Field(name: [UInt8](repeating: 0x0A, count: 2_000), value: [UInt8](repeating: 0x0A, count: 2_000))])
    }

    @Test func hugeHuffmanLengthsAreTooLarge() {
        // A Huffman length near 2⁶²: its lower bound on the decoded size once overflowed to a negative number, so the
        // instruction was held as incomplete (its bytes buffered by the caller without end) instead of rejected.
        for instruction in [prefixInteger((1 << 62) - 1, bits: 5, flags: 0x60), hexBytes("c0") + prefixInteger((1 << 62) - 1, bits: 7, flags: 0x80)] {
            var decoder = QPACKDecoder(maximumTableCapacity: 220)
            #expect(throws: QPACKError.entryTooLarge) { _ = try decoder.processEncoderStream((hexBytes("3fbd01") + instruction).span.bytes) }
        }
    }

    @Test func pendingCapacityWithoutInstructionRoom() throws {
        // With no room for the pending Set Dynamic Table Capacity, every encode once threw outputTooSmall. Now the section
        // is static-only, and the instruction waits for room.
        var encoder = QPACKEncoder()
        encoder.setPeerSettings(maximumTableCapacity: 4_096, blockedStreams: 10)
        let fields = store([Field(":method", "GET"), Field("x-custom", "value")])
        var decoder = QPACKDecoder()
        for stream in [0, 4] as [UInt64] {
            let section = try encodeWithoutInstructionRoom(&encoder, fields, stream: stream)
            #expect(Array(section.prefix(2)) == [0, 0])
            #expect(try decodeSection(&decoder, section, stream: stream) == [Field(":method", "GET"), Field("x-custom", "value")])
        }
        #expect(encoder.insertCount == 0)
        let encoded = try encodeSection(&encoder, fields, stream: 8, indexing: .prefer)
        #expect(Array(encoded.instructions.prefix(3)) == prefixInteger(4_096, bits: 5, flags: 0x20))
        try applyEncoderStream(&decoder, encoded.instructions)
        #expect(decoder.tableCapacity == 4_096 && decoder.insertCount == 1)
        #expect(try decodeSection(&decoder, encoded.section, stream: 8) == [Field(":method", "GET"), Field("x-custom", "value")])
    }

    @Test(arguments: [0, 4_096])
    func namesAreLowercased(capacity: Int) throws {
        // HTTP/1 spellings from a store (known names and unknown ones) go out lowercase (RFC 9114 §4.2), and into the
        // table that way, so `X-Trace` and `x-trace` are one entry.
        var fields = HTTPFieldStore()
        for (name, value) in [("Host", "example.com"), ("X-Trace", "abc"), ("User-Agent", "probe"), ("Content-Type", "text/x")] {
            try fields.append(name: Array(name.utf8).span.bytes, value: Array(value.utf8).span.bytes)
        }
        var encoder = QPACKEncoder(maximumTableCapacity: capacity)
        encoder.setPeerSettings(maximumTableCapacity: UInt64(capacity), blockedStreams: 10)
        var decoder = QPACKDecoder(maximumTableCapacity: capacity)
        let expected = [Field("host", "example.com"), Field("x-trace", "abc"), Field("user-agent", "probe"), Field("content-type", "text/x")]
        for (stream, indexing) in [(0, QPACKIndexingStrategy.prefer), (4, .avoid), (8, .disable)] as [(UInt64, QPACKIndexingStrategy)] {
            let encoded = try encodeSection(&encoder, fields, stream: stream, indexing: indexing)
            try applyEncoderStream(&decoder, encoded.instructions)
            var validator = HTTP3FieldValidator(.trailers)
            let span = encoded.section.span.bytes
            var decoded: [Field] = []
            #expect(try decoder.begin(span, stream: stream))
            while let field = try decoder.next(in: span) {
                decoded.append(Field(name: Array(copying: field.name), value: Array(copying: field.value)))
                do throws(HTTPFieldSectionError) { try validator.check(field) } catch { Issue.record("\(error)") }
            }
            #expect(decoded == expected)
            #expect(tableEntries(decoder).allSatisfy { !$0.name.contains { $0 >= 0x41 && $0 <= 0x5A } })
        }
        if capacity > 0 {
            let inserted = encoder.insertCount
            #expect(inserted > 0)
            _ = try encodeSection(&encoder, store([Field("x-trace", "abc")]), stream: 12, indexing: .prefer)
            #expect(encoder.insertCount == inserted)
        }
    }

    @Test func decodeIntoChecksCharacters() throws {
        // `decode(_:stream:into:)` once called every store error H3_EXCESSIVE_LOAD. Now it follows the decoder's verdict
        // on characters (RFC 9114 §4.2), as `HTTP3FieldValidator` does: a malformed message, H3_MESSAGE_ERROR.
        let nulHuffman = huffman([0x61, 0x00])
        let cases: [(section: [UInt8], valid: Bool)] = [
            (hexBytes("0000 52 03 610162"), true),                          // age: "a\u{1}b": other controls are allowed
            (hexBytes("0000 24 3a666f6f 0178"), true),                      // ":foo": characters valid (its place is the validator's)
            (hexBytes("0000 52 03 610062"), false),                         // NUL
            (hexBytes("0000 52 03 610d62"), false),                         // CR
            (hexBytes("0000 52 03 206162"), false),                         // a leading space
            (hexBytes("0000 23 416263 0178"), false),                       // an uppercase name
            (hexBytes("0000 52") + [0x80 | UInt8(nulHuffman.count)] + nulHuffman, false), // NUL, Huffman-coded
        ]
        for (section, valid) in cases {
            var decoder = QPACKDecoder()
            var fields = HTTPFieldStore()
            if valid {
                #expect(try decoder.decode(section.span.bytes, stream: 0, into: &fields), "\(section)")
                #expect(fields.count == 1)
            } else {
                #expect(throws: QPACKError.malformedField, "\(section)") { _ = try decoder.decode(section.span.bytes, stream: 0, into: &fields) }
                #expect(fields.isEmpty)
                // The section is abandoned, and the decoder goes on.
                #expect(try decodeSection(&decoder, hexBytes("0000c1"), stream: 4) == [Field(":path", "/")])
            }
            // The validator agrees.
            var validator = HTTP3FieldValidator(.trailers)
            let span = section.span.bytes
            #expect(try decoder.begin(span, stream: 8))
            var accepted = true
            while let field = try decoder.next(in: span) {
                do throws(HTTPFieldSectionError) { try validator.check(field) } catch { accepted = error == .invalidPseudoHeader }
            }
            #expect(accepted == valid, "\(section)")
        }
        #expect(QPACKError.malformedField.http3Error == .stream(.messageError))
        #expect(QPACKError.fieldSectionTooLarge.http3Error == .stream(.excessiveLoad))
    }

    @Test func nextWithoutASectionThrows() throws {
        // `next(in:)` trapped when no section was begun: before `begin`, after the end, after an error or a blocked
        // `begin`, or after `begin` threw decoderStreamFull.
        var decoder = try QPACKErrorTests.decoder()
        let sectionBytes = hexBytes("0000c1"), section = sectionBytes.span.bytes
        #expect(throws: QPACKError.sectionNotBegun) { _ = try nextGivesField(&decoder, section) }
        #expect(try decoder.begin(section, stream: 0))
        while try decoder.next(in: section) != nil {}
        #expect(throws: QPACKError.sectionNotBegun) { _ = try nextGivesField(&decoder, section) }
        let invalidBytes = hexBytes("0000ff24"), invalid = invalidBytes.span.bytes
        #expect(try decoder.begin(invalid, stream: 0))
        #expect(throws: QPACKError.invalidIndex) { _ = try nextGivesField(&decoder, invalid) }
        #expect(throws: QPACKError.sectionNotBegun) { _ = try nextGivesField(&decoder, invalid) }
        let blockedBytes = hexBytes("0400 80"), blocked = blockedBytes.span.bytes
        #expect(try !decoder.begin(blocked, stream: 4))
        #expect(throws: QPACKError.sectionNotBegun) { _ = try nextGivesField(&decoder, blocked) }
        #expect(QPACKError.sectionNotBegun.http3Error == .connection(.internalError))
    }

    @Test func decoderStreamFullChangesNothing() throws {
        // A 32-byte buffer with three 9-byte acknowledgments: no room for a fourth.
        var decoder = QPACKDecoder(maximumTableCapacity: 220, decoderStreamCapacity: 32)
        try applyEncoderStream(&decoder, QPACKExampleTests.capacityAndInserts)
        let dynamic = hexBytes("0381 10 11")
        for stream in 0..<3 { #expect(try decodeSection(&decoder, dynamic, stream: (1 << 50) + UInt64(stream) * 4)?.count == 2) }
        // A section that needs no acknowledgment begins anyway (it once threw decoderStreamFull).
        let staticBytes = hexBytes("0000 c1 d1"), staticOnly = staticBytes.span.bytes
        #expect(try decoder.begin(staticOnly, stream: 100))
        #expect(try nextGivesField(&decoder, staticOnly))
        // One that needs one doesn't, and the section in progress goes on (it was once abandoned).
        #expect(throws: QPACKError.decoderStreamFull) { _ = try decoder.begin(dynamic.span.bytes, stream: 104) }
        #expect(try nextGivesField(&decoder, staticOnly))
        #expect(try !nextGivesField(&decoder, staticOnly))
        // A blocked stream stays blocked when its cancellation has no room (it was once forgotten first).
        let blockedBytes = hexBytes("0400 80")
        #expect(try !decoder.begin(blockedBytes.span.bytes, stream: 200))
        #expect(throws: QPACKError.decoderStreamFull) { try decoder.cancelStream(200) }
        let stillBlocked = decoder.blockedStreamCount
        #expect(stillBlocked == 1)
        #expect(decoderInstructions(&decoder).count == 27)
        try decoder.cancelStream(200)
        let unblocked = decoder.blockedStreamCount
        #expect(unblocked == 0)
        #expect(decoderStreamInstructions(decoderInstructions(&decoder)).cancelled == [200])
    }

    @Test func encoderForgetsAbandonedSections() throws {
        // A section for a stream reset before its HEADERS frame went out: never acknowledged or cancelled by the peer.
        var encoder = QPACKEncoder()
        encoder.setPeerSettings(maximumTableCapacity: 4_096, blockedStreams: 10)
        _ = try encodeSection(&encoder, store([Field("x-a", "1")]), stream: 4, indexing: .prefer)
        _ = try encodeSection(&encoder, store([Field("x-a", "1")]), stream: 8, indexing: .prefer)
        #expect(encoder.unacknowledgedSectionCount == 2)
        encoder.abandonSections(stream: 4)
        #expect(encoder.unacknowledgedSectionCount == 1)
        #expect(throws: QPACKError.invalidDecoderInstruction) { _ = try encoder.processDecoderStream(([0x84] as [UInt8]).span.bytes) }
        #expect(try encoder.processDecoderStream(([0x88] as [UInt8]).span.bytes) == 1)
        #expect(encoder.unacknowledgedSectionCount == 0)
    }

    @Test func tableMatchesAModel() {
        #expect(QPACKTableModel.run(seeds: 0..<12, operations: 200) == nil)
    }
}

@Suite(.bulk) struct QPACKRegressionBulkTests {
    @Test func tableMatchesAModel() {
        #expect(QPACKTableModel.run(seeds: 0..<400, operations: 300) == nil)
    }

    @Test func literalNameInsertFedAByteAtATimeIsLinear() throws {
        // At a 16 KiB capacity (about 62 KB of instruction), a byte at a time: 1.3 s when the name was decoded per call.
        let capacity = 16_384, half = (capacity - 32) / 2
        let name = huffman([UInt8](repeating: 0x0A, count: half)), value = huffman([UInt8](repeating: 0x0A, count: half))
        let instruction = prefixInteger(name.count, bits: 5, flags: 0x60) + name + prefixInteger(value.count, bits: 7, flags: 0x80) + value
        var decoder = QPACKDecoder(maximumTableCapacity: capacity)
        try applyEncoderStream(&decoder, prefixInteger(capacity, bits: 5, flags: 0x20))
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            var start = 0
            for end in 1...instruction.count {
                start += try decoder.processEncoderStream(instruction.span.bytes.extracting(start..<end))
            }
        }
        #expect(decoder.insertCount == 1)
        #expect(elapsed < .milliseconds(200), "\(elapsed)")
    }
}

/// The decoder's table against a model, through random instructions (capacity changes, duplicates, inserts with name
/// references and literal names), each split at a random point.
enum QPACKTableModel {
    static func run(seeds: Range<UInt64>, operations: Int) -> String? {
        for seed in seeds {
            for capacity in [32, 64, 100, 333, 1_000] {
                if let failure = run(seed: seed &* 7 &+ UInt64(capacity), maximumCapacity: capacity, operations: operations) { return failure }
            }
        }
        return nil
    }

    static func run(seed: UInt64, maximumCapacity: Int, operations: Int) -> String? {
        var generator = SplitMix64(seed: seed)
        func random(_ n: Int) -> Int { Int(generator.next() % UInt64(n)) }
        var decoder = QPACKDecoder(maximumTableCapacity: maximumCapacity)
        var model: [Field] = []
        var inserted = 0, capacity = 0
        func size() -> Int { model.reduce(0) { $0 + $1.name.count + $1.value.count + 32 } }
        func evict(to limit: Int) { while size() > limit { model.removeFirst() } }
        for operation in 0..<operations {
            var bytes: [UInt8] = []
            let kind = random(10)
            if kind == 0 {
                capacity = random(maximumCapacity + 1)
                bytes = prefixInteger(capacity, bits: 5, flags: 0x20)
                evict(to: capacity)
            } else {
                let live = model.count
                var entry: Field
                if kind == 1, live > 0 {
                    let relative = random(live)
                    entry = model[live - 1 - relative]
                    if entry.name.count + entry.value.count + 32 > capacity { continue }
                    bytes = prefixInteger(relative, bits: 5, flags: 0x00)
                } else {
                    guard capacity >= 32 else { continue }
                    let total = random(capacity - 32 + 1)
                    if kind <= 4, live > 0 {
                        let relative = random(live)
                        let name = model[live - 1 - relative].name
                        if name.count > total { continue }
                        let value = (0..<(total - name.count)).map { _ in UInt8(97 + random(26)) }
                        entry = Field(name: name, value: value)
                        bytes = prefixInteger(relative, bits: 6, flags: 0x80) + prefixInteger(value.count, bits: 7, flags: 0) + value
                    } else {
                        let count = random(total + 1)
                        let name = (0..<count).map { _ in UInt8(97 + random(26)) }
                        let value = (0..<(total - count)).map { _ in UInt8(65 + random(26)) }
                        entry = Field(name: name, value: value)
                        bytes = prefixInteger(count, bits: 5, flags: 0x40) + name + prefixInteger(value.count, bits: 7, flags: 0) + value
                    }
                }
                model.append(entry)
                inserted += 1
                evict(to: capacity)
            }
            do throws(QPACKError) {
                let cut = bytes.isEmpty ? 0 : random(bytes.count)
                let first = try decoder.processEncoderStream(Array(bytes[0..<cut]).span.bytes)
                let rest = Array(bytes[first...])
                let second = try decoder.processEncoderStream(rest.span.bytes)
                if second != rest.count { return "seed \(seed) operation \(operation): used \(first) + \(second) of \(bytes.count)" }
            } catch {
                return "seed \(seed) operation \(operation): \(error)"
            }
            if decoder.insertCount != inserted || decoder.tableSize != size() || tableEntries(decoder) != model {
                return "seed \(seed) operation \(operation): the table differs"
            }
        }
        return nil
    }
}
