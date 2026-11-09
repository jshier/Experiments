import Bytes
import MQTT
import Testing

// MARK: - Helpers

/// Encodes `packet` into a new array.
func encoded(_ packet: borrowing MQTTPacket) throws -> [UInt8] {
    try [UInt8](capacity: packet.encodedByteCount) { output in
        try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in try packet.write(to: &writer) }
    }
}

/// Builds encoded fields (a property list, a subscription list) in a new array.
func fieldBytes(_ body: (inout BytesWriter) throws(BytesError) -> Void) throws -> [UInt8] {
    try [UInt8](capacity: 512) { output in
        try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in try body(&writer) }
    }
}

func string(_ text: UTF8Span) -> String { String(copying: text) }
func array(_ bytes: RawSpan) -> [UInt8] { (0..<bytes.byteCount).map { bytes.load(fromByteOffset: $0, as: UInt8.self) } }

// `Optional.map`, `== nil`, and `#require` need `Escapable` values; views aren't.
func optionalString(_ text: UTF8Span?) -> String? {
    switch text {
    case let .some(text): string(text)
    case .none: nil
    }
}

func optionalArray(_ bytes: RawSpan?) -> [UInt8]? {
    switch bytes {
    case let .some(bytes): array(bytes)
    case .none: nil
    }
}

func isNil<T: ~Escapable>(_ value: T?) -> Bool {
    switch value {
    case .some: false
    case .none: true
    }
}

struct NoPacket: Error {}

/// Parses exactly one packet from `bytes`, checking it consumes them all, and passes it to `body`.
func parseOne(_ bytes: [UInt8], _ body: (borrowing MQTTPacket) throws -> Void) throws {
    var reader = BytesReader(bytes.span)
    guard let packet = try MQTTPacket.read(from: &reader) else { throw NoPacket() }
    #expect(reader.byteOffset == bytes.count)
    try body(packet)
}

func expectError(_ kind: MQTTError.Kind, _ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
    var reader = BytesReader(bytes.span)
    do {
        _ = try MQTTPacket.read(from: &reader)
        Issue.record("Expected \(kind), parsed a packet", sourceLocation: sourceLocation)
    } catch {
        #expect(error.kind == kind, "\(error)", sourceLocation: sourceLocation)
        #expect(reader.byteOffset == 0, "consumed bytes on error", sourceLocation: sourceLocation)
    }
}

// MARK: - Known bytes

@Suite struct KnownBytes {
    @Test func publishQoS0() throws {
        // Type 3, no flags; remaining length 13: topic "a/b/c", no properties, payload "hello".
        let bytes: [UInt8] = [0x30, 0x0D, 0x00, 0x05] + Array("a/b/c".utf8) + [0x00] + Array("hello".utf8)
        try parseOne(bytes) { packet in
            guard case let .publish(publish) = packet else { Issue.record("not a publish"); return }
            #expect(string(publish.topic) == "a/b/c" && publish.qos == .atMostOnce && publish.packetIdentifier == nil)
            #expect(!publish.duplicate && !publish.retain && publish.properties.isEmpty)
            #expect(array(publish.payload) == Array("hello".utf8))
            let reencoded = try encoded(packet)
            #expect(reencoded == bytes)
        }
    }

    @Test func connect() throws {
        // CONNECT, clean start, keep alive 60, no properties, client ID "c1", user name "u", password [1, 2].
        let body: [UInt8] = [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x05, 0b1100_0010, 0x00, 0x3C, 0x00]
            + [0x00, 0x02, 0x63, 0x31] + [0x00, 0x01, 0x75] + [0x00, 0x02, 0x01, 0x02]
        let bytes: [UInt8] = [0x10, UInt8(body.count)] + body
        try parseOne(bytes) { packet in
            guard case let .connect(connect) = packet else { Issue.record("not a connect"); return }
            #expect(connect.cleanStart && connect.keepAlive == 60 && string(connect.clientIdentifier) == "c1")
            let hasNoWill = isNil(connect.will) // `#expect` can't inspect a function call on a view.
            #expect(hasNoWill)
            #expect(optionalString(connect.userName) == "u")
            #expect(optionalArray(connect.password) == [1, 2])
            let reencoded = try encoded(packet)
            #expect(reencoded == bytes)
        }
    }

    @Test func shortForms() throws {
        // PUBACK with only a packet identifier; DISCONNECT and PINGREQ with no body.
        try parseOne([0x40, 0x02, 0x12, 0x34]) { packet in
            guard case let .publishAcknowledgement(ack) = packet else { Issue.record("not a puback"); return }
            #expect(ack.packetIdentifier == 0x1234 && ack.reasonCode == .success && ack.properties.isEmpty)
            let reencoded = try encoded(packet)
            #expect(reencoded == [0x40, 0x02, 0x12, 0x34])
        }
        try parseOne([0xE0, 0x00]) { packet in
            guard case let .disconnect(reason) = packet else { Issue.record("not a disconnect"); return }
            #expect(reason.reasonCode == .normalDisconnection)
        }
        try parseOne([0xC0, 0x00]) { packet in #expect(packet.type == .pingRequest) }
    }
}

// MARK: - Round trips

@Suite struct RoundTrips {
    @Test func everyPropertyType() throws {
        let correlation: [UInt8] = [9, 8, 7]
        let bytes = try fieldBytes { writer throws(BytesError) in
            try writer.write(MQTTProperty.payloadFormatIndicator(1))
            try writer.write(MQTTProperty.messageExpiryInterval(3_600))
            try writer.write(MQTTProperty.contentType("application/json".utf8Span))
            try writer.write(MQTTProperty.responseTopic("replies/1".utf8Span))
            try writer.write(MQTTProperty.correlationData(correlation.span.bytes))
            try writer.write(MQTTProperty.subscriptionIdentifier(268_435_455))
            try writer.write(MQTTProperty.sessionExpiryInterval(120))
            try writer.write(MQTTProperty.serverKeepAlive(30))
            try writer.write(MQTTProperty.topicAlias(7))
            try writer.write(MQTTProperty.userProperty(name: "region".utf8Span, value: "eu-west".utf8Span))
            try writer.write(MQTTProperty.maximumPacketSize(1 << 20))
            try writer.write(MQTTProperty.sharedSubscriptionAvailable(0))
        }
        let properties = try MQTTProperties(validating: bytes.span.bytes)
        var seen: [String] = []
        properties.forEach { property in
            switch property {
            case let .payloadFormatIndicator(value): seen.append("format \(value)")
            case let .messageExpiryInterval(value): seen.append("expiry \(value)")
            case let .contentType(value): seen.append("type \(string(value))")
            case let .responseTopic(value): seen.append("response \(string(value))")
            case let .correlationData(value): seen.append("correlation \(array(value))")
            case let .subscriptionIdentifier(value): seen.append("subscription \(value)")
            case let .sessionExpiryInterval(value): seen.append("session \(value)")
            case let .serverKeepAlive(value): seen.append("keep alive \(value)")
            case let .topicAlias(value): seen.append("alias \(value)")
            case let .userProperty(name, value): seen.append("\(string(name))=\(string(value))")
            case let .maximumPacketSize(value): seen.append("max \(value)")
            case let .sharedSubscriptionAvailable(value): seen.append("shared \(value)")
            default: seen.append("unexpected")
            }
        }
        #expect(seen == [
            "format 1", "expiry 3600", "type application/json", "response replies/1", "correlation [9, 8, 7]",
            "subscription 268435455", "session 120", "keep alive 30", "alias 7", "region=eu-west", "max 1048576", "shared 0",
        ])
    }

    @Test(arguments: [MQTTQoS.atMostOnce, .atLeastOnce, .exactlyOnce])
    func publish(qos: MQTTQoS) throws {
        let topic = "sensors/building-7/temperature"
        let payload: [UInt8] = Array(repeating: 0xAB, count: 300) // A 2-byte remaining length.
        let props = try fieldBytes { writer throws(BytesError) in
            try writer.write(MQTTProperty.messageExpiryInterval(60))
        }
        let packet = try MQTTPacket.publish(MQTTPublish(
            duplicate: qos != .atMostOnce, qos: qos, retain: true, topic: topic.utf8Span,
            packetIdentifier: qos == .atMostOnce ? nil : 42,
            properties: MQTTProperties(validating: props.span.bytes), payload: payload.span.bytes
        ))
        let bytes = try encoded(packet)
        #expect(bytes.count == packet.encodedByteCount)
        try parseOne(bytes) { parsed in
            guard case let .publish(publish) = parsed else { Issue.record("not a publish"); return }
            #expect(string(publish.topic) == topic && publish.qos == qos && publish.retain)
            #expect(publish.duplicate == (qos != .atMostOnce))
            #expect(publish.packetIdentifier == (qos == .atMostOnce ? nil : 42))
            #expect(array(publish.payload) == payload && array(publish.properties.bytes) == props)
            let reencoded = try encoded(parsed)
            #expect(reencoded == bytes)
        }
    }

    @Test func connectWithWill() throws {
        let willPayload: [UInt8] = Array("gone".utf8)
        let password: [UInt8] = [0xDE, 0xAD]
        let willProps = try fieldBytes { writer throws(BytesError) in try writer.write(MQTTProperty.willDelayInterval(5)) }
        let connectProps = try fieldBytes { writer throws(BytesError) in try writer.write(MQTTProperty.receiveMaximum(10)) }
        let will = try MQTTWill(
            qos: .exactlyOnce, retain: true, properties: MQTTProperties(validating: willProps.span.bytes),
            topic: "status/c42".utf8Span, payload: willPayload.span.bytes
        )
        let packet = try MQTTPacket.connect(MQTTConnect(
            cleanStart: false, keepAlive: 300, properties: MQTTProperties(validating: connectProps.span.bytes),
            clientIdentifier: "client-42".utf8Span, will: will, userName: "user".utf8Span, password: password.span.bytes
        ))
        let bytes = try encoded(packet)
        try parseOne(bytes) { parsed in
            guard case let .connect(connect) = parsed else { Issue.record("not a connect"); return }
            #expect(!connect.cleanStart && connect.keepAlive == 300 && string(connect.clientIdentifier) == "client-42")
            guard case let .some(will) = connect.will else { Issue.record("no will"); return }
            #expect(will.qos == .exactlyOnce && will.retain && string(will.topic) == "status/c42")
            #expect(array(will.payload) == willPayload && array(will.properties.bytes) == willProps)
            #expect(optionalString(connect.userName) == "user" && optionalArray(connect.password) == password)
            let reencoded = try encoded(parsed)
            #expect(reencoded == bytes)
        }
    }

    @Test func acknowledgementsAndReasons() throws {
        let reasonProps = try fieldBytes { writer throws(BytesError) in
            try writer.write(MQTTProperty.reasonString("quota".utf8Span))
        }
        let packets: [(MQTTPacketType, [UInt8])] = try [
            (.connectAcknowledgement, encoded(.connectAcknowledgement(MQTTConnectAcknowledgement(
                sessionPresent: true, reasonCode: .success, properties: MQTTProperties()
            )))),
            (.publishAcknowledgement, encoded(.publishAcknowledgement(MQTTPublishResponse(
                packetIdentifier: 1, reasonCode: .quotaExceeded, properties: MQTTProperties(validating: reasonProps.span.bytes)
            )))),
            (.publishReceived, encoded(.publishReceived(MQTTPublishResponse(packetIdentifier: 2, reasonCode: .noMatchingSubscribers, properties: MQTTProperties())))),
            (.publishRelease, encoded(.publishRelease(MQTTPublishResponse(packetIdentifier: 3, properties: MQTTProperties())))),
            (.publishComplete, encoded(.publishComplete(MQTTPublishResponse(packetIdentifier: 4, properties: MQTTProperties())))),
            (.pingResponse, encoded(.pingResponse)),
            (.disconnect, encoded(.disconnect(MQTTDisconnect(reasonCode: .serverBusy)))),
            (.authenticate, encoded(.authenticate(MQTTAuthenticate(
                reasonCode: .continueAuthentication, properties: MQTTProperties(validating: reasonProps.span.bytes)
            )))),
        ]
        for (type, bytes) in packets {
            try parseOne(bytes) { packet in
                #expect(packet.type == type)
                let reencoded = try encoded(packet)
                #expect(reencoded == bytes, "\(type)")
            }
        }
        // A reason code without properties: 3 bytes for a publish response.
        #expect(packets[2].1 == [0x50, 0x03, 0x00, 0x02, 0x10])
        #expect(packets[3].1 == [0x62, 0x02, 0x00, 0x03]) // PUBREL: flags 0b0010.
    }

    @Test func subscribeAndUnsubscribe() throws {
        let list = try fieldBytes { writer throws(BytesError) in
            try writer.write(MQTTSubscription(topicFilter: "sensors/+/temperature".utf8Span, options: MQTTSubscriptionOptions(maximumQoS: .atLeastOnce)))
            try writer.write(MQTTSubscription(topicFilter: "alerts/#".utf8Span, options: MQTTSubscriptionOptions(
                maximumQoS: .exactlyOnce, noLocal: true, retainAsPublished: true, retainHandling: .doNotSend
            )))
        }
        let subscribe = try MQTTPacket.subscribe(MQTTSubscribe(
            packetIdentifier: 10, properties: MQTTProperties(), subscriptions: MQTTSubscriptions(validating: list.span.bytes)
        ))
        let bytes = try encoded(subscribe)
        try parseOne(bytes) { packet in
            guard case let .subscribe(parsed) = packet else { Issue.record("not a subscribe"); return }
            var filters: [String] = []
            var options: [MQTTSubscriptionOptions] = []
            parsed.subscriptions.forEach { subscription in
                filters.append(string(subscription.topicFilter))
                options.append(subscription.options)
            }
            #expect(filters == ["sensors/+/temperature", "alerts/#"])
            #expect(options == [
                MQTTSubscriptionOptions(maximumQoS: .atLeastOnce),
                MQTTSubscriptionOptions(maximumQoS: .exactlyOnce, noLocal: true, retainAsPublished: true, retainHandling: .doNotSend),
            ])
            let reencoded = try encoded(packet)
            #expect(reencoded == bytes)
        }
        // The second options byte: reserved 00, retain handling 10, RAP 1, NL 1, QoS 10.
        #expect(bytes.last == 0b0010_1110)

        let codes: [UInt8] = [0x01, 0x02, 0x87]
        let suback = try encoded(.subscribeAcknowledgement(MQTTSubscribeAcknowledgement(
            packetIdentifier: 10, properties: MQTTProperties(), reasonCodes: codes.span
        )))
        try parseOne(suback) { packet in
            guard case let .subscribeAcknowledgement(ack) = packet else { Issue.record("not a suback"); return }
            #expect(ack.reasonCodes.count == 3 && ack.reasonCode(at: 2) == .notAuthorized && ack.reasonCode(at: 2).isFailure)
        }

        let filtersList = try fieldBytes { writer throws(BytesError) in
            try writer.write("a/b".utf8Span, prefixedBy: Byte2.self, .bigEndian)
            try writer.write("c/#".utf8Span, prefixedBy: Byte2.self, .bigEndian)
        }
        let unsubscribe = try encoded(.unsubscribe(MQTTUnsubscribe(
            packetIdentifier: 11, properties: MQTTProperties(), topicFilters: MQTTTopicFilters(validating: filtersList.span.bytes)
        )))
        try parseOne(unsubscribe) { packet in
            guard case let .unsubscribe(parsed) = packet else { Issue.record("not an unsubscribe"); return }
            var filters: [String] = []
            parsed.topicFilters.forEach { filters.append(string($0)) }
            #expect(filters == ["a/b", "c/#"] && parsed.packetIdentifier == 11)
        }
    }
}

// MARK: - Streaming

@Suite struct Streaming {
    @Test func packetsArriveInPieces() throws {
        let payload: [UInt8] = Array(repeating: 7, count: 200)
        var stream: [UInt8] = []
        stream += try encoded(.pingRequest)
        stream += try encoded(.publish(MQTTPublish(qos: .atLeastOnce, topic: "t".utf8Span, packetIdentifier: 1,
                                                   properties: MQTTProperties(), payload: payload.span.bytes)))
        stream += try encoded(.publishAcknowledgement(MQTTPublishResponse(packetIdentifier: 1, properties: MQTTProperties())))

        // Feed the stream a byte at a time: each packet appears exactly when its last byte arrives.
        var types: [MQTTPacketType] = []
        var consumed = 0
        for available in 1...stream.count {
            let received = Array(stream[consumed..<available])
            var reader = BytesReader(received.span)
            while let packet = try MQTTPacket.read(from: &reader) {
                types.append(packet.type)
            }
            consumed += reader.byteOffset
        }
        #expect(types == [.pingRequest, .publish, .publishAcknowledgement])
        #expect(consumed == stream.count)
    }
}

// MARK: - Malformed packets and protocol errors

@Suite struct Errors {
    @Test func malformed() {
        expectError(.malformedPacket, [0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]) // 5-byte remaining length
        expectError(.malformedPacket, [0x00, 0x00]) // reserved packet type 0
        expectError(.malformedPacket, [0x36, 0x03, 0x00, 0x01, 0x61]) // PUBLISH QoS 3
        expectError(.malformedPacket, [0x38, 0x04, 0x00, 0x01, 0x61, 0x00]) // DUP on QoS 0
        expectError(.malformedPacket, [0x60, 0x02, 0x00, 0x01]) // PUBREL without flags 0b0010
        expectError(.malformedPacket, [0x30, 0x04, 0x00, 0x01, 0xFF, 0x00]) // topic isn't UTF-8
        expectError(.malformedPacket, [0x30, 0x04, 0x00, 0x01, 0x23, 0x00]) // wildcard in a topic name
        expectError(.malformedPacket, [0x40, 0x05, 0x00, 0x01, 0x00, 0x00, 0x09]) // trailing byte in PUBACK
        expectError(.malformedPacket, [0x30, 0x06, 0x00, 0x01, 0x61, 0x02, 0x7F, 0x00]) // unknown property 0x7F
        expectError(.malformedPacket, [0x30, 0x04, 0x00, 0x01, 0x61, 0x05]) // property length past the end
        // SUBSCRIBE options with reserved bits set.
        expectError(.malformedPacket, [0x82, 0x07, 0x00, 0x01, 0x00, 0x00, 0x01, 0x61, 0b0100_0000])
        // Padded Variable Byte Integers [MQTT-1.5.5-1]: remaining length, property length, property identifier.
        expectError(.malformedPacket, [0xC0, 0x80, 0x00])
        expectError(.malformedPacket, [0x30, 0x05, 0x00, 0x01, 0x61, 0x80, 0x00])
        expectError(.malformedPacket, [0x30, 0x07, 0x00, 0x01, 0x61, 0x03, 0x81, 0x00, 0x01])
        // Properties not allowed in the packet: Session Expiry in PUBLISH, Will Delay in PUBACK.
        expectError(.malformedPacket, [0x30, 0x09, 0x00, 0x01, 0x61, 0x05, 0x11, 0x00, 0x00, 0x00, 0x01])
        expectError(.malformedPacket, [0x40, 0x09, 0x00, 0x01, 0x00, 0x05, 0x18, 0x00, 0x00, 0x00, 0x01])
        expectError(.malformedPacket, [0x30, 0x04, 0x00, 0x01, 0x00, 0x00]) // U+0000 in a topic
        // CONNECT with the reserved flag set.
        expectError(.malformedPacket, [0x10, 0x0D, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x05, 0x03, 0x00, 0x3C, 0x00, 0x00, 0x00])
    }

    @Test func protocolErrors() {
        expectError(.protocolError, [0x32, 0x06, 0x00, 0x01, 0x61, 0x00, 0x00, 0x00]) // packet identifier 0
        expectError(.protocolError, [0x82, 0x07, 0x00, 0x00, 0x00, 0x00, 0x01, 0x61, 0x00]) // SUBSCRIBE identifier 0
        expectError(.protocolError, [0xA2, 0x06, 0x00, 0x00, 0x00, 0x00, 0x01, 0x61]) // UNSUBSCRIBE identifier 0
        expectError(.protocolError, [0x82, 0x03, 0x00, 0x01, 0x00]) // SUBSCRIBE with no subscriptions
        expectError(.protocolError, [0x82, 0x06, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]) // empty topic filter
        expectError(.protocolError, [0xA2, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00]) // empty topic filter
        // SUBSCRIBE options: retain handling 3, maximum QoS 3.
        expectError(.protocolError, [0x82, 0x07, 0x00, 0x01, 0x00, 0x00, 0x01, 0x61, 0b0011_0000])
        expectError(.protocolError, [0x82, 0x07, 0x00, 0x01, 0x00, 0x00, 0x01, 0x61, 0b0000_0011])
        // No Local on a shared subscription, "$share/g/a".
        expectError(.protocolError, [0x82, 0x10, 0x00, 0x01, 0x00, 0x00, 0x0A, 0x24, 0x73, 0x68, 0x61, 0x72, 0x65, 0x2F, 0x67, 0x2F, 0x61, 0x04])
        // Message Expiry Interval twice.
        expectError(.protocolError, [0x30, 0x0E, 0x00, 0x01, 0x61, 0x0A, 0x02, 0x00, 0x00, 0x00, 0x01, 0x02, 0x00, 0x00, 0x00, 0x02])
        expectError(.protocolError, [0x30, 0x07, 0x00, 0x01, 0x61, 0x03, 0x23, 0x00, 0x00]) // Topic Alias 0
        expectError(.protocolError, [0x82, 0x09, 0x00, 0x01, 0x02, 0x0B, 0x00, 0x00, 0x01, 0x61, 0x00]) // Subscription Identifier 0
        expectError(.protocolError, [0x20, 0x06, 0x00, 0x00, 0x03, 0x21, 0x00, 0x00]) // Receive Maximum 0
        expectError(.protocolError, [0x20, 0x05, 0x00, 0x00, 0x02, 0x24, 0x02]) // Maximum QoS 2
        expectError(.protocolError, [0x30, 0x03, 0x00, 0x00, 0x00]) // empty topic, no alias
        // Reason codes the packet doesn't allow, and a session with a failed connection.
        expectError(.protocolError, [0x40, 0x03, 0x00, 0x01, 0x05])
        expectError(.protocolError, [0x90, 0x04, 0x00, 0x01, 0x00, 0x03])
        expectError(.protocolError, [0xF0, 0x02, 0x87, 0x00])
        expectError(.protocolError, [0x62, 0x03, 0x00, 0x01, 0x10])
        expectError(.protocolError, [0x20, 0x03, 0x01, 0x87, 0x00])
    }

    @Test func otherKinds() {
        // CONNECT for MQTT 3.1.1 (version 4).
        let v311: [UInt8] = [0x10, 0x0D, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x3C, 0x00, 0x00, 0x00]
        expectError(.unsupportedProtocolVersion, v311)
        let tooLarge: [UInt8] = [0x30, 0x7F]
        var reader = BytesReader(tooLarge.span)
        #expect(throws: MQTTError(.packetTooLarge, "packet larger than the maximum packet size")) {
            _ = try MQTTPacket.read(from: &reader, maximumPacketSize: 100)
        }
        #expect(MQTTError(.packetTooLarge, "x").reasonCode == .packetTooLarge)
    }

    /// Four continuation bytes can never become a valid remaining length: malformed, not incomplete.
    @Test func overlongRemainingLengthIsMalformed() {
        expectError(.malformedPacket, [0x30, 0xFF, 0xFF, 0xFF, 0xFF])
    }
}

// MARK: - Encoding checks

@Suite struct EncodingChecks {
    /// Packets the parser would reject aren't written, and nothing is written for them.
    @Test func invalidPacketsAreNotWritten() throws {
        func expectRejected(_ packet: borrowing MQTTPacket, sourceLocation: SourceLocation = #_sourceLocation) {
            var buffer = [UInt8](repeating: 0xEE, count: 128)
            var span = buffer.mutableSpan
            var writer = BytesWriter(&span)
            #expect(throws: BytesError.invalidValue, sourceLocation: sourceLocation) { try packet.write(to: &writer) }
            #expect(writer.byteCount == 0, sourceLocation: sourceLocation)
            #expect(throws: MQTTError.self, sourceLocation: sourceLocation) { try packet.validate() }
        }
        let payload: [UInt8] = [1]
        expectRejected(.publish(MQTTPublish(duplicate: true, topic: "a".utf8Span, payload: payload.span.bytes)))
        expectRejected(.publish(MQTTPublish(topic: "a/#".utf8Span, payload: payload.span.bytes)))
        expectRejected(.publish(MQTTPublish(qos: .atLeastOnce, topic: "a".utf8Span, packetIdentifier: 0, payload: payload.span.bytes)))
        expectRejected(.publish(MQTTPublish(qos: .atLeastOnce, topic: "a".utf8Span, payload: payload.span.bytes)))
        expectRejected(.publish(MQTTPublish(topic: "".utf8Span, payload: payload.span.bytes)))
        let longTopic = String(repeating: "a", count: 70_000)
        expectRejected(.publish(MQTTPublish(topic: longTopic.utf8Span, payload: payload.span.bytes)))
        let none: [UInt8] = []
        expectRejected(.subscribeAcknowledgement(MQTTSubscribeAcknowledgement(packetIdentifier: 1, reasonCodes: none.span)))
        let invalidCode: [UInt8] = [0x03]
        expectRejected(.subscribeAcknowledgement(MQTTSubscribeAcknowledgement(packetIdentifier: 1, reasonCodes: invalidCode.span)))
        expectRejected(.publishRelease(MQTTPublishResponse(packetIdentifier: 1, reasonCode: .quotaExceeded)))
        // A property PUBLISH can't carry.
        let sessionExpiry = try fieldBytes { writer throws(BytesError) in try writer.write(MQTTProperty.sessionExpiryInterval(5)) }
        try expectRejected(.publish(MQTTPublish(
            topic: "a".utf8Span, properties: MQTTProperties(validating: sessionExpiry.span.bytes), payload: payload.span.bytes
        )))
    }

    /// AUTH omits its reason code only together with its property length [3.15.2.1].
    @Test func authenticateWritesPropertyLengthWithReasonCode() throws {
        #expect(try encoded(.authenticate(MQTTAuthenticate(reasonCode: .continueAuthentication))) == [0xF0, 0x02, 0x18, 0x00])
        #expect(try encoded(.authenticate(MQTTAuthenticate())) == [0xF0, 0x00])
        #expect(try encoded(.disconnect(MQTTDisconnect(reasonCode: .serverBusy))) == [0xE0, 0x01, 0x89])
    }
}

// MARK: - README

/// The README's example, compiled and run.
@Suite struct ReadmeExample {
    @Test func parseAndEncode() throws {
        let reading: [UInt8] = [0x01, 0x02]
        let packet = MQTTPacket.publish(MQTTPublish(
            qos: .atLeastOnce, topic: "sensors/kitchen".utf8Span, packetIdentifier: 7, payload: reading.span.bytes
        ))
        let bytes = try [UInt8](capacity: packet.encodedByteCount) { output in
            try output.withBytesWriter { writer throws(BytesError) in try packet.write(to: &writer) }
        }

        var received = bytes + [0x30] // and the first byte of the next packet
        var delivered: [(String, [UInt8])] = []
        var reader = BytesReader(received.span)
        while let packet = try MQTTPacket.read(from: &reader, maximumPacketSize: 1 << 20) {
            switch packet {
            case let .publish(publish):
                delivered.append((String(copying: publish.topic), [UInt8](copying: publish.payload)))
                publish.properties.forEach { property in
                    if case .messageExpiryInterval = property { Issue.record("no properties") }
                }
            default:
                break
            }
        }
        let consumed = reader.byteOffset
        received.removeFirst(consumed)
        #expect(delivered.count == 1 && delivered[0].0 == "sensors/kitchen" && delivered[0].1 == reading)
        #expect(received == [0x30])
    }
}
