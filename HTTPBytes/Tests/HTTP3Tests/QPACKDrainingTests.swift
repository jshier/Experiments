import Bytes
import BytesTestSupport
import BytesTesting
import Foundation
import HTTP3
import HTTPBytes
import Testing

/// Two peers with the network between them: each section's encoder stream bytes reach the decoder
/// `encoderStreamLag` sections late, the section itself `sectionLag` sections late (so it's decoded after evictions made
/// since it was encoded, or before the inserts it refers to), and the decoder's stream goes back once it has written
/// it, whole or a byte at a time. Some sections are cancelled instead of decoded (Stream Cancellation), before they're
/// read or while they're blocked.
struct QPACKLink {
    var capacity = 4_096
    var blocked = 100
    var encoderStreamLag = 0
    var sectionLag = 0
    /// Every `cancelEvery`-th section is cancelled before it's read, and the one after it if it blocks (0: none).
    var cancelEvery = 0
    var bytewise = false

    struct Outcome {
        /// The decoded sections, by index; cancelled ones are missing.
        var decoded: [Int: [Field]] = [:]
        var cancelled: Set<Int> = []
        /// Section and encoder stream bytes.
        var bytes = 0
        /// Duplicate instructions on the encoder stream (first byte 000xxxxx).
        var duplicates = 0
        /// The most sections blocked at once at the decoder.
        var mostBlocked = 0
    }

    func run(_ sets: [[Field]]) throws -> Outcome {
        var encoder = QPACKEncoder(maximumTableCapacity: capacity)
        encoder.setPeerSettings(maximumTableCapacity: UInt64(capacity), blockedStreams: UInt64(blocked))
        var decoder = QPACKDecoder(maximumTableCapacity: capacity, maximumBlockedStreams: blocked, maximumFieldSectionSize: 1 << 20)
        var outcome = Outcome()
        var instructions: [[UInt8]] = [], sections: [[UInt8]] = []
        var instructionsDelivered = 0, sectionsDelivered = 0
        var held: [UInt64: Int] = [:]
        var carry: [UInt8] = []

        func decode(_ index: Int, _ decoder: inout QPACKDecoder) throws -> Bool {
            guard let fields = try decodeSection(&decoder, sections[index], stream: UInt64(index * 4)) else { return false }
            outcome.decoded[index] = fields
            return true
        }

        func step(through index: Int, _ encoder: inout QPACKEncoder, _ decoder: inout QPACKDecoder) throws {
            while instructionsDelivered < instructions.count, instructionsDelivered <= index - encoderStreamLag {
                try applyEncoderStream(&decoder, instructions[instructionsDelivered])
                outcome.duplicates += Self.duplicates(in: instructions[instructionsDelivered])
                instructionsDelivered += 1
                while let stream = decoder.nextUnblockedStream() {
                    let section = held.removeValue(forKey: stream)!
                    #expect(try decode(section, &decoder), "unblocked section \(section) blocks again")
                }
            }
            while sectionsDelivered < sections.count, sectionsDelivered <= index - sectionLag {
                let section = sectionsDelivered
                sectionsDelivered += 1
                if cancelEvery > 0, section % cancelEvery == cancelEvery - 1 {
                    try decoder.cancelStream(UInt64(section * 4))
                    outcome.cancelled.insert(section)
                } else if try !decode(section, &decoder) {
                    if cancelEvery > 0, section % cancelEvery == 0 {
                        try decoder.cancelStream(UInt64(section * 4))
                        outcome.cancelled.insert(section)
                    } else {
                        held[UInt64(section * 4)] = section
                        outcome.mostBlocked = max(outcome.mostBlocked, decoder.blockedStreamCount)
                    }
                }
            }
            carry += decoderInstructions(&decoder)
            if bytewise {
                // A byte at a time, keeping what the encoder didn't take (an instruction cut short).
                var pending: [UInt8] = []
                for byte in carry {
                    pending.append(byte)
                    let used = try encoder.processDecoderStream(pending.span.bytes)
                    pending.removeFirst(used)
                }
                carry = pending
            } else {
                carry.removeFirst(try encoder.processDecoderStream(carry.span.bytes))
            }
        }

        for (index, set) in sets.enumerated() {
            let encoded = try encodeSection(&encoder, store(set), stream: UInt64(index * 4))
            outcome.bytes += encoded.section.count + encoded.instructions.count
            instructions.append(encoded.instructions)
            sections.append(encoded.section)
            try step(through: index, &encoder, &decoder)
        }
        try step(through: Int.max / 2, &encoder, &decoder)
        #expect(held.isEmpty, "sections still blocked: \(held.values.sorted())")
        #expect(carry.isEmpty)
        return outcome
    }

    /// Whether every section that wasn't cancelled decoded to its fields.
    static func check(_ outcome: Outcome, _ sets: [[Field]]) -> Bool {
        sets.indices.allSatisfy { outcome.cancelled.contains($0) || outcome.decoded[$0] == sets[$0] }
    }

    /// The Duplicate instructions in a section's encoder stream bytes (complete instructions).
    static func duplicates(in bytes: [UInt8]) -> Int {
        var count = 0, position = 0
        func integer(_ bits: Int) -> Int {
            let mask = (1 << bits) - 1
            var value = Int(bytes[position]) & mask
            position += 1
            guard value == mask else { return value }
            var shift = 0
            while true {
                let byte = Int(bytes[position])
                position += 1
                value += (byte & 0x7F) << shift
                shift += 7
                if byte & 0x80 == 0 { return value }
            }
        }
        func string(_ bits: Int) { position += integer(bits) }
        while position < bytes.count {
            let first = bytes[position]
            if first & 0x80 != 0 {
                _ = integer(6); string(7)
            } else if first & 0x40 != 0 {
                string(5); string(7)
            } else if first & 0x20 != 0 {
                _ = integer(5)
            } else {
                _ = integer(5)
                count += 1
            }
        }
        return count
    }
}

/// The settings both suites run: (capacity, blocked, encoder stream lag, section lag, cancel every, bytewise).
let qpackLinkSettings: [QPACKLink] = [
    QPACKLink(capacity: 4_096, blocked: 100),
    QPACKLink(capacity: 4_096, blocked: 0, sectionLag: 16),
    QPACKLink(capacity: 4_096, blocked: 100, sectionLag: 16, cancelEvery: 5),
    QPACKLink(capacity: 4_096, blocked: 3, encoderStreamLag: 4),
    QPACKLink(capacity: 4_096, blocked: 100, encoderStreamLag: 16, sectionLag: 4, cancelEvery: 7, bytewise: true),
    QPACKLink(capacity: 512, blocked: 2, encoderStreamLag: 2, sectionLag: 8, cancelEvery: 3),
    QPACKLink(capacity: 256, blocked: 0, sectionLag: 4),
    QPACKLink(capacity: 16_384, blocked: 100, encoderStreamLag: 16, sectionLag: 16),
]

@Suite struct QPACKDrainingTests {
    /// Fields of `count` sets, each one field: `name: value`.
    static func fields(_ pairs: [(String, String)]) -> [[Field]] { pairs.map { [Field($0.0, $0.1)] } }

    @Test func drainingEntryIsDuplicated() throws {
        // A 256-byte table: entries of 55 bytes; the first drains (a quarter of the capacity from eviction) once 193 bytes
        // have been inserted from its start on, here after the fourth. Using it then copies it to the front.
        var encoder = QPACKEncoder(maximumTableCapacity: 256)
        encoder.setPeerSettings(maximumTableCapacity: 256, blockedStreams: 100)
        var decoder = QPACKDecoder(maximumTableCapacity: 256)
        let value = String(repeating: "v", count: 20)
        let sets = Self.fields([("x-a", value), ("x-b", value), ("x-c", value), ("x-d", value), ("x-a", value)])
        var last = EncodedSection(section: [], instructions: [])
        for (index, set) in sets.enumerated() {
            last = try encodeSection(&encoder, store(set), stream: UInt64(index * 4), indexing: .prefer)
            try applyEncoderStream(&decoder, last.instructions)
            #expect(try decodeSection(&decoder, last.section, stream: UInt64(index * 4)) == set)
            #expect(try encoder.processDecoderStream(decoderInstructions(&decoder).span.bytes) >= 0)
        }
        // Duplicate of relative index 3 (entry 0, with 4 inserted), and the section refers to the copy (post-base 0).
        #expect(last.instructions == [0x03])
        #expect(last.section == [0x06, 0x80, 0x10])
        #expect(encoder.insertCount == 5)
        #expect(tableEntries(decoder).last == Field("x-a", value))
    }

    @Test func drainingEntryIsDuplicatedForLaterSectionsWhenTheSectionCantBlock() throws {
        // With no blocked streams allowed, the section refers to the acknowledged old entry (so the copy can't evict it:
        // here the room is the space the evicted first entry, 80 bytes, left), and the copy is for later sections. A
        // 400-byte table, a quarter of it the draining zone: x-a (55 bytes, inserted at 80) drains once 410 bytes are in.
        var encoder = QPACKEncoder(maximumTableCapacity: 400)
        encoder.setPeerSettings(maximumTableCapacity: 400, blockedStreams: 0)
        var decoder = QPACKDecoder(maximumTableCapacity: 400, maximumBlockedStreams: 0)
        let value = String(repeating: "v", count: 20)
        let sets = Self.fields([("x-f", String(repeating: "f", count: 45)), ("x-a", value), ("x-b", value), ("x-c", value), ("x-d", value),
                                ("x-e", value), ("x-g", value), ("x-a", value), ("x-a", value)])
        var encoded: [EncodedSection] = []
        for (index, set) in sets.enumerated() {
            encoded.append(try encodeSection(&encoder, store(set), stream: UInt64(index * 4), indexing: .prefer))
            try applyEncoderStream(&decoder, encoded[index].instructions)
            #expect(try decodeSection(&decoder, encoded[index].section, stream: UInt64(index * 4)) == set)
            #expect(try encoder.processDecoderStream(decoderInstructions(&decoder).span.bytes) >= 0)
        }
        // Section 7: Duplicate of entry 1 (relative 5 with 7 inserted), and a reference to entry 1 (Required Insert Count
        // 2, encoded 3; Base 7, relative 5). Section 8: the copy, entry 7 (encoded 9, Base 8, relative 0).
        #expect(encoded[7].instructions == [0x05])
        #expect(encoded[7].section == [0x03, 0x05, 0x85])
        #expect(encoded[8].instructions.isEmpty)
        #expect(encoded[8].section == [0x09, 0x00, 0x80])
    }

    @Test func drainingEntryIsntANameReference() throws {
        // `.avoid` inserts nothing: the name of a draining entry is written as a literal rather than referred to.
        var encoder = QPACKEncoder(maximumTableCapacity: 256)
        encoder.setPeerSettings(maximumTableCapacity: 256, blockedStreams: 100)
        var decoder = QPACKDecoder(maximumTableCapacity: 256)
        let value = String(repeating: "v", count: 20)
        let sets = Self.fields([("x-a", value), ("x-b", value), ("x-c", value), ("x-d", value)])
        for (index, set) in sets.enumerated() {
            let encoded = try encodeSection(&encoder, store(set), stream: UInt64(index * 4), indexing: .prefer)
            try applyEncoderStream(&decoder, encoded.instructions)
            _ = try decodeSection(&decoder, encoded.section, stream: UInt64(index * 4))
            _ = try encoder.processDecoderStream(decoderInstructions(&decoder).span.bytes)
        }
        let draining = try encodeSection(&encoder, store([Field("x-a", "other")]), stream: 16, indexing: .avoid)
        #expect(draining.section[2] & 0xE0 == 0x20, "a literal name: \(draining.section)")
        let fresh = try encodeSection(&encoder, store([Field("x-d", "other")]), stream: 20, indexing: .avoid)
        #expect(fresh.section[2] & 0xF0 == 0x40, "a dynamic name reference: \(fresh.section)")
    }

    @Test func nameSeenTwiceIsInsertedAlone() throws {
        // An unknown name with a new value each time: a literal name, then the name inserted alone (an empty value) and
        // referred to post-base, then a name reference.
        var encoder = QPACKEncoder(maximumTableCapacity: 4_096)
        encoder.setPeerSettings(maximumTableCapacity: 4_096, blockedStreams: 100)
        var decoder = QPACKDecoder(maximumTableCapacity: 4_096)
        var encoded: [EncodedSection] = []
        for index in 0..<3 {
            let set = [Field("x-trace", "id-\(index)")]
            encoded.append(try encodeSection(&encoder, store(set), stream: UInt64(index * 4)))
            try applyEncoderStream(&decoder, encoded[index].instructions)
            #expect(try decodeSection(&decoder, encoded[index].section, stream: UInt64(index * 4)) == set)
            _ = try encoder.processDecoderStream(decoderInstructions(&decoder).span.bytes)
        }
        #expect(encoded[0].instructions.count <= 3, "only the capacity")
        #expect(encoded[0].section[2] & 0xE0 == 0x20)
        #expect(encoded[1].instructions.first.map { $0 & 0xC0 } == 0x40, "an insert with a literal name")
        #expect(encoded[1].instructions.last == 0x00, "an empty value")
        #expect(encoded[1].section[2] & 0xF0 == 0x00, "a post-base name reference")
        #expect(encoded[2].instructions.isEmpty)
        #expect(encoded[2].section[2] & 0xF0 == 0x40, "a name reference")
        #expect(tableEntries(decoder) == [Field("x-trace", "")])
    }

    @Test(arguments: qpackLinkSettings.indices)
    func linkDecodesEverySection(_ setting: Int) throws {
        let link = qpackLinkSettings[setting]
        for sets in [HTTPCorpus.requests.value, HTTPCorpus.responses.value] {
            try #require(sets.count > 300, "Tools/test-data fetch http-corpus")
            let outcome = try link.run(sets)
            #expect(QPACKLink.check(outcome, sets))
            #expect(outcome.mostBlocked <= link.blocked)
        }
    }

    @Test func responsesUseDuplicates() throws {
        // With a 4,096-byte table, http-corpus' responses keep their fields by Duplicates.
        let outcome = try QPACKLink(capacity: 4_096, blocked: 100).run(HTTPCorpus.responses.value)
        #expect(outcome.duplicates > 50)
        #expect(outcome.bytes < 55_000, "\(outcome.bytes) B")
    }

    @Test(.timeLimit(.minutes(1)))
    func decoderStreamAByteAtATimeIsLinear() throws {
        // http-corpus twice, 1,568 sections on large stream numbers (instructions of 7 bytes) that nothing acknowledges as
        // they're encoded (767 of them refer to the dynamic table), then the decoder's whole stream for them (Section
        // Acknowledgments, every third a Stream Cancellation instead, Insert Count Increments; 7,249 bytes) a byte at a
        // time: the state the stream whole gives, in time linear in its bytes.
        let corpus = HTTPCorpus.requests.value + HTTPCorpus.responses.value
        try #require(corpus.count > 700, "Tools/test-data fetch http-corpus")
        let sets = corpus + corpus
        var encoder = QPACKEncoder(maximumTableCapacity: 4_096, maximumUnacknowledgedSections: 1_024)
        encoder.setPeerSettings(maximumTableCapacity: 4_096, blockedStreams: 1_000)
        var whole = QPACKEncoder(maximumTableCapacity: 4_096, maximumUnacknowledgedSections: 1_024)
        whole.setPeerSettings(maximumTableCapacity: 4_096, blockedStreams: 1_000)
        var decoder = QPACKDecoder(maximumTableCapacity: 4_096, maximumBlockedStreams: 1_000)
        var stream: [UInt8] = []
        for (index, set) in sets.enumerated() {
            let id = UInt64(index) * 4 + 1 << 40
            let encoded = try encodeSection(&encoder, store(set), stream: id)
            #expect(try encodeSection(&whole, store(set), stream: id).section == encoded.section)
            try applyEncoderStream(&decoder, encoded.instructions)
            if index % 3 == 0 {
                try decoder.cancelStream(id)
            } else {
                #expect(try decodeSection(&decoder, encoded.section, stream: id) == set)
            }
            stream += decoderInstructions(&decoder)
        }
        #expect(encoder.unacknowledgedSectionCount > 700, "\(encoder.unacknowledgedSectionCount) sections, \(stream.count) B")
        #expect(try whole.processDecoderStream(stream.span.bytes) == stream.count)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            var start = 0
            for end in 1...stream.count {
                start += try encoder.processDecoderStream(stream.span.bytes.extracting(start..<end))
            }
            #expect(start == stream.count)
        }
        #expect(encoder.unacknowledgedSectionCount == 0)
        #expect(whole.unacknowledgedSectionCount == 0)
        #expect(encoder.acknowledgedInsertCount == whole.acknowledgedInsertCount)
        #expect(encoder.acknowledgedInsertCount == encoder.insertCount)
        #expect(elapsed < .milliseconds(500), "\(elapsed) for \(stream.count) bytes")
    }
}

@Suite(.bulk) struct QPACKDrainingBulkTests {
    @Test func everyLinkDecodesEverySection() throws {
        let corpora = [HTTPCorpus.requests.value, HTTPCorpus.responses.value] + ["fb-req-hq", "fb-resp-hq", "netbsd-hq"].map {
            (try? QIFCorpus.sections($0)) ?? []
        }
        for capacity in [64, 256, 1_024, 4_096, 16_384] {
            for blocked in [0, 2, 100] {
                for (encoderStreamLag, sectionLag) in [(0, 0), (0, 4), (0, 16), (4, 0), (16, 0), (4, 16), (16, 4)] {
                    for cancelEvery in [0, 5] {
                        let link = QPACKLink(capacity: capacity, blocked: blocked, encoderStreamLag: encoderStreamLag,
                                             sectionLag: sectionLag, cancelEvery: cancelEvery, bytewise: cancelEvery > 0 && capacity == 1_024)
                        for sets in corpora where !sets.isEmpty {
                            let outcome = try link.run(sets)
                            #expect(QPACKLink.check(outcome, sets), "\(link)")
                            #expect(outcome.mostBlocked <= blocked, "\(link)")
                        }
                    }
                }
            }
        }
    }
}
