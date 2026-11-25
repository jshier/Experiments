import Bytes
import BytesTesting
import BytesTestSupport
import Foundation
import HTTP3
import HTTPBytes
import Testing

/// A connection's two coders, run as peers would: the encoder's sections and instructions go to the decoder, and the
/// decoder's instructions back to the encoder, with a choice of when.
struct QPACKPeers: ~Copyable {
    var encoder: QPACKEncoder
    var decoder: QPACKDecoder

    enum Delivery {
        /// Encoder stream bytes before each section, and acknowledgments right after it.
        case inOrder
        /// The section before its encoder stream bytes (it blocks, then unblocks), acknowledgments after.
        case instructionsLate
        /// Acknowledgments never sent back.
        case noAcknowledgments
    }

    init(capacity: Int, blocked: Int, huffman: Bool = true, sections: Int = 128) {
        encoder = QPACKEncoder(maximumTableCapacity: capacity, maximumUnacknowledgedSections: sections)
        encoder.setPeerSettings(maximumTableCapacity: UInt64(capacity), blockedStreams: UInt64(blocked))
        encoder.usesHuffmanCoding = huffman
        decoder = QPACKDecoder(maximumTableCapacity: capacity, maximumBlockedStreams: blocked, maximumFieldSectionSize: 1 << 20)
    }

    /// Sends every set through, returning what the decoder decoded per set, and the bytes sent (sections and
    /// instructions).
    mutating func run(_ sets: [[Field]], delivery: Delivery, indexing: QPACKIndexingStrategy = .automatic) throws -> (decoded: [[Field]], bytes: Int) {
        var decoded: [[Field]] = []
        var bytes = 0
        for (index, set) in sets.enumerated() {
            let stream = UInt64(index * 4)
            let encoded = try encodeSection(&encoder, store(set), stream: stream, indexing: indexing)
            bytes += encoded.section.count + encoded.instructions.count
            switch delivery {
            case .inOrder, .noAcknowledgments:
                try applyEncoderStream(&decoder, encoded.instructions)
                try decoded.append(#require(try decodeSection(&decoder, encoded.section, stream: stream)))
            case .instructionsLate:
                if let fields = try decodeSection(&decoder, encoded.section, stream: stream) {
                    decoded.append(fields)
                    try applyEncoderStream(&decoder, encoded.instructions)
                } else {
                    try applyEncoderStream(&decoder, encoded.instructions)
                    #expect(decoder.nextUnblockedStream() == stream)
                    try decoded.append(#require(try decodeSection(&decoder, encoded.section, stream: stream)))
                }
            }
            let feedback = decoderInstructions(&decoder)
            if delivery != .noAcknowledgments {
                #expect(try encoder.processDecoderStream(feedback.span.bytes) == feedback.count)
            }
        }
        return (decoded, bytes)
    }
}

/// http-corpus' QIF files (`Tools/test-data fetch http-corpus`): 401 request and 383 response field sets.
enum HTTPCorpus {
    static let requests = Lazy { load("requests.qif") }
    static let responses = Lazy { load("responses.qif") }

    static func load(_ name: String) -> [[Field]] {
        guard let url = try? TestData.file(set: "http-corpus", name: name), let text = try? String(contentsOf: url, encoding: .isoLatin1) else {
            return []
        }
        return QIFCorpus.parse(text)
    }
}

@Suite struct QPACKRoundTripTests {
    static let configurations: [(capacity: Int, blocked: Int)] = [(0, 0), (4_096, 100), (4_096, 0), (256, 0), (256, 10)]

    @Test(arguments: configurations)
    func requests(_ configuration: (capacity: Int, blocked: Int)) throws {
        let sets = HTTPCorpus.requests.value
        try #require(sets.count == 401, "Tools/test-data fetch http-corpus")
        var peers = QPACKPeers(capacity: configuration.capacity, blocked: configuration.blocked)
        #expect(try peers.run(sets, delivery: .inOrder).decoded == sets)
    }

    @Test(arguments: configurations)
    func responses(_ configuration: (capacity: Int, blocked: Int)) throws {
        let sets = HTTPCorpus.responses.value
        try #require(sets.count == 383, "Tools/test-data fetch http-corpus")
        var peers = QPACKPeers(capacity: configuration.capacity, blocked: configuration.blocked)
        #expect(try peers.run(sets, delivery: .inOrder).decoded == sets)
    }

    @Test func dynamicTableCompresses() throws {
        let sets = HTTPCorpus.requests.value
        var staticOnly = QPACKPeers(capacity: 0, blocked: 0)
        var dynamic = QPACKPeers(capacity: 4_096, blocked: 100)
        let staticBytes = try staticOnly.run(sets, delivery: .inOrder).bytes
        let dynamicBytes = try dynamic.run(sets, delivery: .inOrder).bytes
        #expect(dynamicBytes * 2 < staticBytes, "\(dynamicBytes) against \(staticBytes)")
    }

    @Test func blockedSectionsUnblock() throws {
        // Every section arrives before the instructions it needs.
        let sets = Array(HTTPCorpus.requests.value.prefix(60))
        var peers = QPACKPeers(capacity: 4_096, blocked: 100)
        #expect(try peers.run(sets, delivery: .instructionsLate).decoded == sets)
    }

    @Test func withoutAcknowledgments() throws {
        // The encoder never hears back: at most `blocked` sections may block, then it can't use new entries or evict.
        let sets = HTTPCorpus.responses.value
        for blocked in [0, 3] {
            var peers = QPACKPeers(capacity: 4_096, blocked: blocked)
            #expect(try peers.run(sets, delivery: .noAcknowledgments).decoded == sets)
        }
    }

    @Test func fewUnacknowledgedSections() throws {
        // With room to track 2 sections and no acknowledgments, the rest use the static table only.
        let sets = Array(HTTPCorpus.requests.value.prefix(50))
        var peers = QPACKPeers(capacity: 4_096, blocked: 100, sections: 2)
        #expect(try peers.run(sets, delivery: .noAcknowledgments).decoded == sets)
        #expect(peers.encoder.unacknowledgedSectionCount == 2)
    }

    @Test(arguments: [QPACKIndexingStrategy.prefer, .avoid, .disable])
    func strategies(_ strategy: QPACKIndexingStrategy) throws {
        let sets = Array(HTTPCorpus.responses.value.prefix(80))
        var peers = QPACKPeers(capacity: 4_096, blocked: 10, huffman: false)
        let decoded = try peers.run(sets, delivery: .inOrder, indexing: strategy).decoded
        let expected = strategy == .disable ? sets.map { $0.map { Field(name: $0.name, value: $0.value, neverIndexed: true) } } : sets
        #expect(decoded == expected)
        if strategy == .disable { #expect(decoded.allSatisfy { $0.allSatisfy(\.neverIndexed) }) }
    }

    @Test func neverIndexedFieldsKeepTheNBit() throws {
        // Static name, dynamic name, literal name: each with the N bit, and none inserted.
        let set = [
            Field(":method", "GET"), Field("authorization", "Bearer abc", neverIndexed: true), Field("x-secret", "1", neverIndexed: true),
            Field("cookie", "short"),
        ]
        var peers = QPACKPeers(capacity: 4_096, blocked: 10)
        let decoded = try peers.run([set, set], delivery: .inOrder).decoded
        // A short cookie is never indexed by the automatic policy too.
        let expected = set.map { Field(name: $0.name, value: $0.value, neverIndexed: $0.neverIndexed || $0.name == latin1("cookie")) }
        #expect(decoded.map { $0.map(\.neverIndexed) } == [expected.map(\.neverIndexed), expected.map(\.neverIndexed)])
        #expect(decoded == [expected, expected])
        #expect(peers.encoder.insertCount == 0)
    }

    @Test func outputTooSmallLeavesTheSection() throws {
        var encoder = QPACKEncoder()
        encoder.setPeerSettings(maximumTableCapacity: 4_096, blockedStreams: 10)
        let fields = store(HTTPCorpus.requests.value[0])
        var section = [UInt8](repeating: 0, count: 20)
        var instructions = [UInt8](repeating: 0, count: 4_096)
        var written = (section: -1, instructions: -1)
        section.withOutputRawSpan { sectionSpan in
            instructions.withOutputRawSpan { instructionSpan in
                #expect(throws: QPACKError.outputTooSmall) {
                    try encoder.encode(fields, stream: 0, into: &sectionSpan, instructions: &instructionSpan)
                }
                written = (sectionSpan.byteCount, instructionSpan.byteCount)
            }
        }
        #expect(written.section == 0)
        #expect(written.instructions > 0)
        // The instructions were kept: with them sent, the section encodes again into more room and decodes.
        var decoder = QPACKDecoder()
        try applyEncoderStream(&decoder, Array(instructions[0..<written.instructions]))
        let again = try encodeSection(&encoder, fields, stream: 0)
        try applyEncoderStream(&decoder, again.instructions)
        #expect(try decodeSection(&decoder, again.section, stream: 0) == HTTPCorpus.requests.value[0])
    }

    @Test func resetStartsANewConnection() throws {
        let sets = Array(HTTPCorpus.requests.value.prefix(30))
        var peers = QPACKPeers(capacity: 4_096, blocked: 10)
        _ = try peers.run(sets, delivery: .inOrder)
        peers.encoder.reset()
        peers.decoder.reset()
        #expect(try peers.run(sets, delivery: .inOrder).decoded == sets)
    }
}

@Suite(.bulk) struct QPACKRoundTripBulkTests {
    /// Every QIF file of the interop corpus, every configuration, every delivery.
    @Test func qifFiles() throws {
        for name in ["fb-req-hq", "fb-req", "fb-resp-hq", "fb-resp", "netbsd-hq", "netbsd"] {
            let sets = try QIFCorpus.sections(name)
            for (capacity, blocked) in QPACKRoundTripTests.configurations + [(512, 3), (1 << 16, 100)] {
                for delivery in [QPACKPeers.Delivery.inOrder, .instructionsLate, .noAcknowledgments] {
                    for huffman in [true, false] {
                        var peers = QPACKPeers(capacity: capacity, blocked: blocked, huffman: huffman)
                        #expect(try peers.run(sets, delivery: delivery).decoded == sets, "\(name) \(capacity) \(blocked) \(delivery) \(huffman)")
                    }
                }
            }
        }
    }
}
