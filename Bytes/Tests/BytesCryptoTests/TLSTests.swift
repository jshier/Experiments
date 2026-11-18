import Bytes
@testable import BytesCrypto
import Foundation
import Testing

// TLS 1.3: RFC 8448's simple 1-RTT handshake trace replayed byte for byte (every secret of the key schedule, the
// traffic keys, and each protected record the trace sends, sealed and opened), then the record layer's rules:
// alerts, padding, malformed records, and key updates, for all three suites.

/// RFC 8448's text (from the repository's TestData/rfc8448, made by `Tools/test-data fetch rfc8448`), and its values
/// by heading and field.
struct RFC8448 {
    let lines: [Substring]

    init() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../TestData/rfc8448/rfc8448.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "rfc8448.txt is missing: run Tools/test-data fetch rfc8448"])
        }
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The bytes of `field` (as in `secret (32 octets):`) after the `occurrence`th line containing `heading`. Hex
    /// continues on the next lines; page breaks in between are skipped.
    func value(_ heading: String, _ field: String, occurrence: Int = 1) -> [UInt8] {
        var index = 0
        var found = 0
        while index < lines.count {
            if lines[index].contains(heading) {
                found += 1
                if found == occurrence { break }
            }
            index += 1
        }
        precondition(index < lines.count, "No \(heading) #\(occurrence)")
        while !lines[index].drop(while: { $0 == " " }).hasPrefix(field + " (") { index += 1 }
        let line = lines[index]
        let open = line.firstIndex(of: "(")!, close = line.firstIndex(of: ")")!
        let count = Int(line[line.index(after: open)..<close].split(separator: " ")[0])!
        var bytes: [UInt8] = []
        var rest = line[line.index(line.firstIndex(of: ":")!, offsetBy: 1)...]
        while bytes.count < count {
            let tokens = rest.split(separator: " ")
            if !tokens.isEmpty, tokens.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) {
                bytes += tokens.map { UInt8($0, radix: 16)! }
            }
            index += 1
            rest = lines[index]
        }
        precondition(bytes.count == count, "\(heading) \(field): \(bytes.count) of \(count) bytes")
        return bytes
    }
}

extension TLSSecret {
    var array: [UInt8] { Array(unsafeUninitializedCapacity: bytes.byteCount) { buffer, count in
        for index in 0..<bytes.byteCount { buffer[index] = bytes.load(fromByteOffset: index, as: UInt8.self) }
        count = bytes.byteCount
    } }
}

/// Seals `content` as one record with `protection`.
func sealRecord(_ protection: inout TLSRecordProtection, _ content: [UInt8], type: TLSContentType, padding: Int = 0) throws -> [UInt8] {
    var record = [UInt8](repeating: 0, count: TLSRecord.size(content: content.count, padding: padding))
    var span = record.mutableSpan
    var raw = MutableRawSpan(mutating: &span)
    _ = try protection.seal(content.span.bytes, type: type, padding: padding, into: &raw)
    return record
}

/// Opens one whole record with `protection`.
func openRecord(_ protection: inout TLSRecordProtection, _ record: [UInt8]) throws -> (TLSContentType, [UInt8]) {
    var plaintext = [UInt8](repeating: 0, count: record.count)
    var span = plaintext.mutableSpan
    var raw = MutableRawSpan(mutating: &span)
    let (type, count) = try protection.open(header: record.span.bytes.extracting(0..<5), body: record.span.bytes.extracting(5...), into: &raw)
    return (type, Array(plaintext.prefix(count)))
}

@Suite struct TLSTests {
    /// RFC 8448, section 3: the key schedule from the shared secret and transcript hashes.
    @Test func rfc8448KeySchedule() throws {
        let rfc = try RFC8448()
        var schedule = TLSKeySchedule(suite: .aes128GCMSHA256)
        #expect(schedule.current.array == rfc.value("{server}  extract secret \"early\"", "secret"))

        schedule.addSharedSecret(rfc.value("{server}  extract secret \"handshake\"", "IKM").span.bytes)
        #expect(schedule.current.array == rfc.value("{server}  extract secret \"handshake\"", "secret"))

        let helloHash = rfc.value("{server}  derive secret \"tls13 c hs traffic\"", "hash")
        let clientHandshake = schedule.secret("c hs traffic", transcriptHash: helloHash.span.bytes)
        let serverHandshake = schedule.secret("s hs traffic", transcriptHash: helloHash.span.bytes)
        #expect(clientHandshake.array == rfc.value("{server}  derive secret \"tls13 c hs traffic\"", "expanded"))
        #expect(serverHandshake.array == rfc.value("{server}  derive secret \"tls13 s hs traffic\"", "expanded"))

        let keys = TLSTrafficKeys(secret: serverHandshake)
        #expect(Array(keys.key.array.prefix(16)) == rfc.value("{server}  derive write traffic keys for handshake data", "key expanded"))
        #expect(keys.iv.array == rfc.value("{server}  derive write traffic keys for handshake data", "iv expanded"))

        schedule.finishHandshakeSecrets()
        #expect(schedule.current.array == rfc.value("{server}  extract secret \"master\"", "secret"))

        let finishedHash = rfc.value("{server}  derive secret \"tls13 c ap traffic\"", "hash")
        #expect(schedule.secret("c ap traffic", transcriptHash: finishedHash.span.bytes).array
            == rfc.value("{server}  derive secret \"tls13 c ap traffic\"", "expanded"))
        #expect(schedule.secret("s ap traffic", transcriptHash: finishedHash.span.bytes).array
            == rfc.value("{server}  derive secret \"tls13 s ap traffic\"", "expanded"))
        #expect(schedule.secret("exp master", transcriptHash: finishedHash.span.bytes).array
            == rfc.value("{server}  derive secret \"tls13 exp master\"", "expanded"))
        let resumptionHash = rfc.value("{client}  derive secret \"tls13 res master\"", "hash")
        #expect(schedule.secret("res master", transcriptHash: resumptionHash.span.bytes).array
            == rfc.value("{client}  derive secret \"tls13 res master\"", "expanded"))
    }

    /// RFC 8448, section 3: every protected record of the trace, sealed to its bytes and opened back.
    @Test func rfc8448Records() throws {
        let rfc = try RFC8448()
        var schedule = TLSKeySchedule(suite: .aes128GCMSHA256)
        schedule.addSharedSecret(rfc.value("{server}  extract secret \"handshake\"", "IKM").span.bytes)
        let helloHash = rfc.value("{server}  derive secret \"tls13 c hs traffic\"", "hash").span.bytes
        let clientHandshake = schedule.secret("c hs traffic", transcriptHash: helloHash)
        let serverHandshake = schedule.secret("s hs traffic", transcriptHash: helloHash)
        schedule.finishHandshakeSecrets()
        let finishedHash = rfc.value("{server}  derive secret \"tls13 c ap traffic\"", "hash").span.bytes
        let clientApplication = schedule.secret("c ap traffic", transcriptHash: finishedHash)
        let serverApplication = schedule.secret("s ap traffic", transcriptHash: finishedHash)

        // (heading, occurrence, secret, content type, sequence number)
        let records: [(String, Int, TLSSecret, TLSContentType, UInt64)] = [
            ("{server}  send handshake record", 2, serverHandshake, .handshake, 0),          // EncryptedExtensions … Finished
            ("{client}  send handshake record", 2, clientHandshake, .handshake, 0),          // client Finished
            ("{server}  send handshake record", 3, serverApplication, .handshake, 0),        // NewSessionTicket
            ("{client}  send application_data record", 1, clientApplication, .applicationData, 0),
            ("{server}  send application_data record", 1, serverApplication, .applicationData, 1),
            ("{client}  send alert record", 1, clientApplication, .alert, 1),               // close_notify
            ("{server}  send alert record", 1, serverApplication, .alert, 2),
        ]
        for (heading, occurrence, secret, type, sequence) in records {
            let payload = rfc.value(heading, "payload", occurrence: occurrence)
            let complete = rfc.value(heading, "complete record", occurrence: occurrence)
            var sealer = TLSRecordProtection(secret: secret)
            sealer.reset(sequence: sequence)
            #expect(try sealRecord(&sealer, payload, type: type) == complete, "\(heading) #\(occurrence)")
            var opener = TLSRecordProtection(secret: secret)
            opener.reset(sequence: sequence)
            let (openedType, content) = try openRecord(&opener, complete)
            #expect(openedType == type && content == payload, "\(heading) #\(occurrence)")
        }

        // The server's Finished: its finished_key, and its verify data over the transcript of ClientHello, ServerHello,
        // and the server's flight up to Finished (the last 36 bytes of that record's payload are the Finished message).
        let section = "{server}  calculate finished \"tls13 finished\""
        #expect(serverHandshake.finishedKey.array == rfc.value(section, "expanded"))
        var transcript = TLSTranscript(suite: .aes128GCMSHA256)
        transcript.add(rfc.value("{client}  send handshake record", "payload", occurrence: 1).span.bytes)
        transcript.add(rfc.value("{server}  send handshake record", "payload", occurrence: 1).span.bytes)
        let flight = rfc.value("{server}  send handshake record", "payload", occurrence: 2)
        transcript.add(flight.span.bytes.extracting(0..<(flight.count - 36)))
        let verifyData = serverHandshake.finishedKey.verifyData(transcriptHash: transcript.hash.bytes)
        #expect(verifyData.array == rfc.value(section, "finished"))
        #expect(verifyData.array == Array(flight.suffix(32)))
        // And with the Finished message, the transcript hash the application secrets were derived from.
        transcript.add(flight.span.bytes.extracting((flight.count - 36)...))
        #expect(transcript.hash.array == rfc.value("{server}  derive secret \"tls13 c ap traffic\"", "hash"))
    }

    /// Records and their tampering, alerts, and limits, through the stages.
    @Test(arguments: TLSCipherSuite.allCases)
    func recordStagesRoundTrip(suite: TLSCipherSuite) throws {
        let secret = TLSSecret([UInt8](repeating: 7, count: suite.hashByteCount).span.bytes, suite: suite)
        var sealer = TLSRecordSealer(secret: secret)
        var opener = TLSRecordOpener(secret: secret)
        var rng = SplitMix64(state: UInt64(suite.rawValue))
        let message = randomBytes(40_000, using: &rng)
        var wire: [UInt8] = []
        _ = try sealer.transform(message.span.bytes.extracting(0..<10), appending: &wire, flush: .flush)
        _ = try sealer.transform(message.span.bytes.extracting(10...), appending: &wire, flush: .flush)
        sealer.send(.closeNotify)
        _ = try sealer.transform(RawSpan(), appending: &wire, flush: .none)
        var plaintext: [UInt8] = []
        let progress = try opener.transform(wire.span.bytes, appending: &plaintext, flush: .none)
        #expect(plaintext == message)
        #expect(progress.status == .finished && opener.isClosed && opener.alert == .closeNotify && opener.receivedAlert)

        // Any altered byte fails authentication: bad_record_mac.
        for index in [0, 5, 100, wire.count - 30] {
            var altered = wire
            altered[index] ^= 0x40
            var fresh = TLSRecordOpener(secret: secret)
            var output: [UInt8] = []
            #expect(throws: BytesError.self) { _ = try fresh.transform(altered.span.bytes, appending: &output, flush: .none) }
            #expect(fresh.alert != nil && !fresh.receivedAlert, "byte \(index)")
            if index >= 5 { #expect(fresh.alert == .badRecordMAC, "byte \(index)") }
        }
    }

    /// Sealing on several lanes gives the same stream as one: record order, sequence numbers, and key updates.
    @Test(arguments: [nil, 7] as [UInt64?])
    func parallelSealingMatchesSerial(recordLimit: UInt64?) throws {
        let secret = TLSSecret([UInt8](repeating: 9, count: 32).span.bytes, suite: .aes128GCMSHA256)
        var rng = SplitMix64(state: 17)
        // 20 full records and a partial one, in pieces that end mid-record, then a flush.
        let message = randomBytes(20 * TLSRecord.maximumPlaintext + 1_000, using: &rng)
        func seal(lanes: Int) throws -> [UInt8] {
            var sealer = TLSRecordSealer(secret: secret, recordLimit: recordLimit)
            sealer.sealingLanes = lanes
            var wire: [UInt8] = []
            let bytes = message.span.bytes
            for range in [0..<5_000, 5_000..<(12 * TLSRecord.maximumPlaintext + 3), (12 * TLSRecord.maximumPlaintext + 3)..<message.count] {
                _ = try sealer.transform(bytes.extracting(range), appending: &wire, flush: range.upperBound == message.count ? .flush : .none, growth: 1 << 20)
            }
            return wire
        }
        let serial = try seal(lanes: 1)
        #expect(try seal(lanes: 4) == serial)
        var opener = TLSRecordOpener(secret: secret)
        var plaintext: [UInt8] = []
        _ = try opener.transform(serial.span.bytes, appending: &plaintext, flush: .none)
        #expect(plaintext == message)
    }

    @Test func keyUpdates() throws {
        let suite = TLSCipherSuite.aes128GCMSHA256
        let secret = TLSSecret([UInt8](repeating: 3, count: 32).span.bytes, suite: suite)
        // A limit of 3 records per key: the sealer updates its keys itself, sending a KeyUpdate, and the opener follows.
        var sealer = TLSRecordSealer(secret: secret, recordLimit: 3)
        var opener = TLSRecordOpener(secret: secret)
        var wire: [UInt8] = []
        var sent: [UInt8] = []
        for index in 0..<10 {
            let piece = [UInt8](repeating: UInt8(index), count: 100)
            sent += piece
            _ = try sealer.transform(piece.span.bytes, appending: &wire, flush: .flush)
        }
        #expect(sealer.recordProtection.sequence < 3)
        var received: [UInt8] = []
        _ = try opener.transform(wire.span.bytes, appending: &received, flush: .none)
        #expect(received == sent)
        #expect(opener.recordProtection.secret?.array == sealer.recordProtection.secret?.array)

        // Requested by the peer: the opener reports it, and the sealer updates on request.
        var requester = TLSRecordSealer(secret: secret)
        try requester.updateKeys(requestingPeerUpdate: true)
        var update: [UInt8] = []
        _ = try requester.transform(RawSpan(), appending: &update, flush: .none)
        var follower = TLSRecordOpener(secret: secret)
        var nothing: [UInt8] = []
        _ = try follower.transform(update.span.bytes, appending: &nothing, flush: .none)
        #expect(follower.takePeerKeyUpdateRequest() && !follower.peerRequestedKeyUpdate)

        // Without the secret, the keys can't follow: unexpected_message.
        var keysOnly = TLSRecordOpener(keys: TLSTrafficKeys(secret: secret))
        #expect(throws: BytesError.self) { _ = try keysOnly.transform(update.span.bytes, appending: &nothing, flush: .none) }
        #expect(keysOnly.alert == .unexpectedMessage)
    }

    @Test func malformedRecords() throws {
        let secret = TLSSecret([UInt8](repeating: 5, count: 32).span.bytes, suite: .chaCha20Poly1305SHA256)
        func open(_ records: [UInt8]) -> TLSAlert? {
            var opener = TLSRecordOpener(secret: secret)
            var output: [UInt8] = []
            _ = try? opener.transform(records.span.bytes, appending: &output, flush: .finish)
            return opener.alert
        }
        var protection = TLSRecordProtection(secret: secret)
        // Padding is stripped; a record of only zeros has no content type.
        var padded = TLSRecordOpener(secret: secret)
        var output: [UInt8] = []
        // A local first: `.span` of a throwing call's temporary crashes LLVM's verifier at -Onone (swift-bugs #28).
        let paddedRecord = try sealRecord(&protection, [1, 2, 3], type: .applicationData, padding: 50)
        _ = try padded.transform(paddedRecord.span.bytes, appending: &output, flush: .none)
        #expect(output == [1, 2, 3])

        // An over-long record: record_overflow.
        #expect(open([23, 3, 3, 0x41, 0x01] + [UInt8](repeating: 0, count: 16_641)) == .recordOverflow)
        // A protected record must be application_data outside: unexpected_message.
        #expect(open([22, 3, 3, 0, 20] + [UInt8](repeating: 0, count: 20)) == .unexpectedMessage)
        // Too short for a tag: bad_record_mac.
        #expect(open([23, 3, 3, 0, 4, 1, 2, 3, 4]) == .badRecordMAC)
        // An alert of the wrong length: decode_error.
        var fresh = TLSRecordProtection(secret: secret)
        #expect(open(try sealRecord(&fresh, [1, 0, 0], type: .alert)) == .decodeError)
        // A zero-length handshake record: unexpected_message.
        fresh = TLSRecordProtection(secret: secret)
        #expect(open(try sealRecord(&fresh, [], type: .handshake)) == .unexpectedMessage)
        // A record cut short at the end of the stream.
        fresh = TLSRecordProtection(secret: secret)
        let whole = try sealRecord(&fresh, [9, 9, 9], type: .applicationData)
        #expect(open(Array(whole.dropLast())) == .decodeError)
        // A fatal alert from the peer is reported as received.
        fresh = TLSRecordProtection(secret: secret)
        let fatal = try sealRecord(&fresh, [2, TLSAlert.handshakeFailure.rawValue], type: .alert)
        var opener = TLSRecordOpener(secret: secret)
        var ignored: [UInt8] = []
        #expect(throws: BytesError.self) { _ = try opener.transform(fatal.span.bytes, appending: &ignored, flush: .none) }
        #expect(opener.alert == .handshakeFailure && opener.receivedAlert)
        // Change cipher spec, tolerated only when asked.
        let ccs: [UInt8] = [20, 3, 3, 0, 1, 1]
        #expect(open(ccs) == .unexpectedMessage)
        var tolerant = TLSRecordOpener(secret: secret)
        tolerant.allowsChangeCipherSpec = true
        _ = try tolerant.transform(ccs.span.bytes, appending: &ignored, flush: .finish)
    }

    /// The keys without a handshake, as the benchmarks and SocketStream use them, are the empty transcript's.
    @Test func applicationKeysWithoutAHandshake() {
        let shared = [UInt8](repeating: 3, count: 32)
        for suite in TLSCipherSuite.allCases {
            let (client, server) = TLSKeySchedule.applicationKeys(sharedSecret: shared.span.bytes, suite: suite)
            #expect(client.suite == suite && client.key.array != server.key.array)
        }
    }
}
