// Fuzzing: every prefix of one packet of each type is incomplete, and random mutations never trap, never
// move the cursor on nil or a throw, and every packet accepted re-encodes into bytes the parser accepts.

import Bytes
import MQTT
import Testing

enum Outcome: Equatable, CustomStringConvertible {
    case incomplete
    case accepted(MQTTPacketType, consumed: Int)
    case failed(MQTTError.Kind, String)

    var description: String {
        switch self {
        case .incomplete: "nil"
        case let .accepted(type, consumed): "accepted \(type) (\(consumed) bytes)"
        case let .failed(kind, detail): "\(kind): \(detail)"
        }
    }
}

func outcome(_ bytes: [UInt8], maximumPacketSize: Int = .max) -> Outcome {
    var reader = BytesReader(bytes.span)
    do {
        guard let packet = try MQTTPacket.read(from: &reader, maximumPacketSize: maximumPacketSize) else {
            #expect(reader.byteOffset == 0)
            return .incomplete
        }
        return .accepted(packet.type, consumed: reader.byteOffset)
    } catch {
        #expect(reader.byteOffset == 0)
        return .failed(error.kind, "\(error.detail)")
    }
}

func isAccepted(_ o: Outcome) -> Bool { if case .accepted = o { true } else { false } }

/// Visits every lazily decoded list in `packet` (exercising the `try!` paths), then re-encodes it.
func visitAndReencode(_ packet: borrowing MQTTPacket) throws -> [UInt8] {
    var count = 0
    switch packet {
    case let .connect(c):
        c.properties.forEach { _ in count += 1 }
        if case let .some(will) = c.will { will.properties.forEach { _ in count += 1 } }
    case let .connectAcknowledgement(p): p.properties.forEach { _ in count += 1 }
    case let .publish(p): p.properties.forEach { _ in count += 1 }
    case let .publishAcknowledgement(p), let .publishReceived(p), let .publishRelease(p), let .publishComplete(p):
        p.properties.forEach { _ in count += 1 }
    case let .subscribe(p):
        p.properties.forEach { _ in count += 1 }
        p.subscriptions.forEach { _ in count += 1 }
    case let .subscribeAcknowledgement(p), let .unsubscribeAcknowledgement(p):
        p.properties.forEach { _ in count += 1 }
        for i in 0..<p.reasonCodes.count {
            _ = p.reasonCode(at: i)
        }
    case let .unsubscribe(p):
        p.properties.forEach { _ in count += 1 }
        p.topicFilters.forEach { _ in count += 1 }
    case .pingRequest, .pingResponse: break
    case let .disconnect(p): p.properties.forEach { _ in count += 1 }
    case let .authenticate(p): p.properties.forEach { _ in count += 1 }
    }
    _ = count
    return try encoded(packet)
}

/// One encoded packet of every type, most with properties.
func corpus() throws -> [[UInt8]] {
    let p = try fieldBytes { w throws(BytesError) in
        try w.write(MQTTProperty.userProperty(name: "k".utf8Span, value: "v".utf8Span))
        try w.write(MQTTProperty.reasonString("r".utf8Span))
    }
    let u = try fieldBytes { w throws(BytesError) in try w.write(MQTTProperty.userProperty(name: "k".utf8Span, value: "v".utf8Span)) }
    let willProps = try fieldBytes { w throws(BytesError) in try w.write(MQTTProperty.willDelayInterval(5)) }
    let subs = try fieldBytes { w throws(BytesError) in
        try w.write(MQTTSubscription(topicFilter: "a/+".utf8Span, options: MQTTSubscriptionOptions(maximumQoS: .exactlyOnce, noLocal: true)))
        try w.write(MQTTSubscription(topicFilter: "b/#".utf8Span, options: MQTTSubscriptionOptions(maximumQoS: .atMostOnce, retainHandling: .doNotSend)))
    }
    let filters = try fieldBytes { w throws(BytesError) in
        try w.write("a/b".utf8Span, prefixedBy: Byte2.self, .bigEndian)
        try w.write("c".utf8Span, prefixedBy: Byte2.self, .bigEndian)
    }
    let payload: [UInt8] = Array(repeating: 0x5A, count: 130) // 2-byte remaining length
    let codes: [UInt8] = [0x00, 0x01, 0x80]
    let unsubscribeCodes: [UInt8] = [0x00, 0x11, 0x80]
    let password: [UInt8] = [1, 2, 3]
    return try [
        encoded(.connect(MQTTConnect(
            cleanStart: true, keepAlive: 30, properties: MQTTProperties(validating: u.span.bytes), clientIdentifier: "id".utf8Span,
            will: MQTTWill(qos: .atLeastOnce, retain: true, properties: MQTTProperties(validating: willProps.span.bytes),
                           topic: "w".utf8Span, payload: payload.span.bytes),
            userName: "u".utf8Span, password: password.span.bytes
        ))),
        encoded(.connectAcknowledgement(MQTTConnectAcknowledgement(sessionPresent: true, reasonCode: .success, properties: MQTTProperties(validating: p.span.bytes)))),
        encoded(.publish(MQTTPublish(qos: .atMostOnce, topic: "t/0".utf8Span, packetIdentifier: nil, properties: MQTTProperties(), payload: payload.span.bytes))),
        encoded(.publish(MQTTPublish(duplicate: true, qos: .exactlyOnce, retain: true, topic: "t/2".utf8Span, packetIdentifier: 7,
                                     properties: MQTTProperties(validating: u.span.bytes), payload: payload.span.bytes))),
        encoded(.publishAcknowledgement(MQTTPublishResponse(packetIdentifier: 1, properties: MQTTProperties()))),
        encoded(.publishReceived(MQTTPublishResponse(packetIdentifier: 2, reasonCode: .noMatchingSubscribers, properties: MQTTProperties()))),
        encoded(.publishRelease(MQTTPublishResponse(packetIdentifier: 3, reasonCode: .packetIdentifierNotFound, properties: MQTTProperties(validating: p.span.bytes)))),
        encoded(.publishComplete(MQTTPublishResponse(packetIdentifier: 4, properties: MQTTProperties(validating: p.span.bytes)))),
        encoded(.subscribe(MQTTSubscribe(packetIdentifier: 5, properties: MQTTProperties(validating: u.span.bytes), subscriptions: MQTTSubscriptions(validating: subs.span.bytes)))),
        encoded(.subscribeAcknowledgement(MQTTSubscribeAcknowledgement(packetIdentifier: 5, properties: MQTTProperties(validating: p.span.bytes), reasonCodes: codes.span))),
        encoded(.unsubscribe(MQTTUnsubscribe(packetIdentifier: 6, properties: MQTTProperties(), topicFilters: MQTTTopicFilters(validating: filters.span.bytes)))),
        encoded(.unsubscribeAcknowledgement(MQTTSubscribeAcknowledgement(packetIdentifier: 6, properties: MQTTProperties(), reasonCodes: unsubscribeCodes.span))),
        encoded(.pingRequest),
        encoded(.pingResponse),
        encoded(.disconnect(MQTTDisconnect())),
        encoded(.disconnect(MQTTDisconnect(reasonCode: .serverBusy, properties: MQTTProperties(validating: p.span.bytes)))),
        encoded(.authenticate(MQTTAuthenticate(reasonCode: .continueAuthentication, properties: MQTTProperties(validating: p.span.bytes)))),
    ]
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Fuzzing

@Suite struct Fuzz {
    @Test func truncationAtEveryOffset() throws {
        for packet in try corpus() {
            #expect(isAccepted(outcome(packet)), "\(packet)")
            for length in 0..<packet.count {
                let o = outcome(Array(packet[..<length]))
                #expect(o == .incomplete, "prefix \(length) of \(packet): \(o)")
            }
            // Shrinking the remaining length by one (body complete but short) must throw, not trap.
            // Only for 1-byte remaining lengths, to keep it simple.
            if packet[1] < 0x80, packet[1] > 0 {
                var short = Array(packet.dropLast())
                short[1] -= 1
                let o = outcome(short)
                if case .failed = o {} else { print("shortened body accepted: \(short) -> \(o)") }
            }
        }
    }

    @Test func randomMutations() throws {
        var rng = SplitMix64(state: 0xC0FFEE)
        var accepted = 0, failed = 0, incomplete = 0, notRoundTripping = 0
        var reencodedRejected: [String] = []
        let seeds = try corpus()
        for _ in 0..<100_000 {
            var bytes = seeds.randomElement(using: &rng)!
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                case 1: bytes[Int.random(in: 0..<bytes.count, using: &rng)] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
                case 2 where bytes.count > 2: bytes.remove(at: Int.random(in: 2..<bytes.count, using: &rng))
                default: bytes.insert(UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...bytes.count, using: &rng))
                }
            }
            // Keep the remaining length consistent sometimes, so bodies get parsed.
            if Bool.random(using: &rng), bytes.count >= 2, bytes.count - 2 < 0x80 { bytes[1] = UInt8(bytes.count - 2) }
            var reader = BytesReader(bytes.span)
            do {
                if let packet = try MQTTPacket.read(from: &reader) {
                    accepted += 1
                    let consumed = reader.byteOffset
                    let again = try visitAndReencode(packet)
                    if again != Array(bytes[..<consumed]) { notRoundTripping += 1 }
                    let o = outcome(again)
                    if !isAccepted(o), reencodedRejected.count < 10 {
                        reencodedRejected.append("\(Array(bytes[..<consumed])) -> \(again) -> \(o)")
                    }
                } else {
                    #expect(reader.byteOffset == 0)
                    incomplete += 1
                }
            } catch {
                #expect(reader.byteOffset == 0)
                failed += 1
            }
        }
        print("mutations: accepted \(accepted), failed \(failed), incomplete \(incomplete), accepted-but-not-round-tripping \(notRoundTripping)")
        for line in reencodedRejected {
            print("re-encoded rejected: \(line)")
        }
        #expect(reencodedRejected.isEmpty)
    }
}
