public import Bytes

// Every packet is a view: strings, binary data, payloads, and lists refer to the bytes the packet was parsed
// from (or, when encoding, to the caller's values), so parsing allocates nothing. Each parses from its body
// (the section the fixed header's remaining length delimits) and computes its body's size before writing.

// MARK: - CONNECT

/// A will: the message the server publishes if the client disconnects abnormally.
public struct MQTTWill: ~Escapable {
    public var qos: MQTTQoS
    public var retain: Bool
    public var properties: MQTTProperties
    public var topic: UTF8Span
    public var payload: RawSpan

    @inlinable
    @_lifetime(copy properties, copy topic, copy payload)
    public init(qos: MQTTQoS, retain: Bool, properties: consuming MQTTProperties, topic: UTF8Span, payload: RawSpan) {
        self.qos = qos
        self.retain = retain
        self.properties = properties
        self.topic = topic
        self.payload = payload
    }
}

/// CONNECT: the first packet a client sends.
public struct MQTTConnect: ~Escapable {
    public var cleanStart: Bool
    /// Seconds; 0 turns keep-alive off.
    public var keepAlive: UInt16
    public var properties: MQTTProperties
    public var clientIdentifier: UTF8Span
    public var will: MQTTWill?
    public var userName: UTF8Span?
    public var password: RawSpan?

    @inlinable
    @_lifetime(copy properties, copy clientIdentifier, copy will, copy userName, copy password)
    public init(
        cleanStart: Bool, keepAlive: UInt16, properties: consuming MQTTProperties, clientIdentifier: UTF8Span,
        will: consuming MQTTWill?, userName: UTF8Span?, password: RawSpan?
    ) {
        self.cleanStart = cleanStart
        self.keepAlive = keepAlive
        self.properties = properties
        self.clientIdentifier = clientIdentifier
        self.will = will
        self.userName = userName
        self.password = password
    }

    /// "MQTT" as an MQTT string, then protocol version 5.
    @inlinable
    static var protocolNameAndVersion: Byte7 { [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x05] }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        // The protocol name and version, then the connect flags, field by field.
        let flags: (userName: Bool, password: Bool, willRetain: Bool, willQoS: MQTTQoS, will: Bool)
        do throws(BytesError) {
            try body.expect(Self.protocolNameAndVersion)
            flags.userName = try body.read(Bit.self).isSet
            flags.password = try body.read(Bit.self).isSet
            flags.willRetain = try body.read(Bit.self).isSet
            flags.willQoS = try body.read(MQTTQoS.self, as: Crumb.self)
            flags.will = try body.read(Bit.self).isSet
            cleanStart = try body.read(Bit.self).isSet
            try body.expect(Bit(0)) // Reserved.
            keepAlive = try body.read(Byte2.self, .bigEndian)
        } catch {
            throw error == .mismatch
                ? .protocolError("unsupported protocol name or version, or reserved flag set")
                : error.malformed("connect header")
        }
        guard flags.will || (flags.willQoS == .atMostOnce && !flags.willRetain) else {
            throw .malformed("will QoS or retain without a will")
        }
        properties = try MQTTProperties(reading: &body)
        clientIdentifier = try body.readMQTTString("client identifier")
        if flags.will {
            let willProperties = try MQTTProperties(reading: &body)
            will = MQTTWill(
                qos: flags.willQoS, retain: flags.willRetain, properties: willProperties,
                topic: try body.readMQTTString("will topic"), payload: try body.readMQTTBinary("will payload")
            )
        } else {
            will = nil
        }
        userName = flags.userName ? try body.readMQTTString("user name") : nil
        password = flags.password ? try body.readMQTTBinary("password") : nil
        try body.expectMQTTEnd("connect")
    }

    @inlinable
    var bodyByteCount: Int {
        var count = 7 &+ 1 &+ 2 &+ properties.encodedByteCount &+ Size.string(clientIdentifier)
        if let will {
            count &+= will.properties.encodedByteCount &+ Size.string(will.topic) &+ Size.binary(will.payload)
        }
        if let userName { count &+= Size.string(userName) }
        if let password { count &+= Size.binary(password) }
        return count
    }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(Self.protocolNameAndVersion)
        try writer.write(Bit(userName != nil))
        try writer.write(Bit(password != nil))
        try writer.write(Bit(will?.retain ?? false))
        try writer.write(will?.qos ?? .atMostOnce, as: Crumb.self)
        try writer.write(Bit(will != nil))
        try writer.write(Bit(cleanStart))
        try writer.write(Bit(0))
        try writer.write(keepAlive, as: Byte2.self, .bigEndian)
        try writer.write(properties)
        try writer.writeMQTTString(clientIdentifier)
        if let will {
            try writer.write(will.properties)
            try writer.writeMQTTString(will.topic)
            try writer.writeMQTTBinary(will.payload)
        }
        if let userName { try writer.writeMQTTString(userName) }
        if let password { try writer.writeMQTTBinary(password) }
    }
}

// MARK: - CONNACK

/// CONNACK: the server's answer to CONNECT.
public struct MQTTConnectAcknowledgement: ~Escapable {
    public var sessionPresent: Bool
    public var reasonCode: MQTTReasonCode
    public var properties: MQTTProperties

    @inlinable
    @_lifetime(copy properties)
    public init(sessionPresent: Bool, reasonCode: MQTTReasonCode, properties: consuming MQTTProperties) {
        self.sessionPresent = sessionPresent
        self.reasonCode = reasonCode
        self.properties = properties
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        do throws(BytesError) {
            try body.expect(Bits<7>(0)) // Reserved.
            sessionPresent = try body.read(Bit.self).isSet
            reasonCode = MQTTReasonCode(rawValue: try body.read(Byte.self).rawValue)
        } catch {
            throw error.malformed("connect acknowledge flags")
        }
        properties = try MQTTProperties(reading: &body)
        try body.expectMQTTEnd("connect acknowledgement")
    }

    @inlinable
    var bodyByteCount: Int { 2 &+ properties.encodedByteCount }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(Bits<7>(0))
        try writer.write(Bit(sessionPresent))
        try writer.write(Byte(reasonCode.rawValue))
        try writer.write(properties)
    }
}

// MARK: - PUBLISH

/// PUBLISH: an application message.
public struct MQTTPublish: ~Escapable {
    public var duplicate: Bool
    public var qos: MQTTQoS
    public var retain: Bool
    public var topic: UTF8Span
    /// Present exactly when `qos` isn't `atMostOnce`.
    public var packetIdentifier: UInt16?
    public var properties: MQTTProperties
    public var payload: RawSpan

    @inlinable
    @_lifetime(copy topic, copy properties, copy payload)
    public init(
        duplicate: Bool = false, qos: MQTTQoS, retain: Bool = false, topic: UTF8Span, packetIdentifier: UInt16?,
        properties: consuming MQTTProperties, payload: RawSpan
    ) {
        precondition((qos == .atMostOnce) == (packetIdentifier == nil), "QoS 1 and 2 need a packet identifier; QoS 0 has none")
        self.duplicate = duplicate
        self.qos = qos
        self.retain = retain
        self.topic = topic
        self.packetIdentifier = packetIdentifier
        self.properties = properties
        self.payload = payload
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes, flags: Nibble) throws(MQTTError) {
        // The fixed header's flags: DUP, QoS (2 bits), RETAIN.
        duplicate = flags[bit: 3]
        guard let qos = MQTTQoS(rawValue: (flags >> 1).lowHalf.rawValue) else { throw .malformed("QoS 3") }
        self.qos = qos
        retain = flags[bit: 0]
        guard qos != .atMostOnce || !duplicate else { throw .malformed("DUP set on a QoS 0 message") }
        topic = try body.readMQTTString("topic name")
        guard !containsWildcard(topic) else { throw .malformed("wildcard in a topic name") }
        if qos == .atMostOnce {
            packetIdentifier = nil
        } else {
            let identifier = try body.readMQTTUInt16("packet identifier")
            guard identifier != 0 else { throw .protocolError("packet identifier 0") }
            packetIdentifier = identifier
        }
        properties = try MQTTProperties(reading: &body)
        // The payload is the rest of the packet.
        do throws(BytesError) { payload = try body.read(byteCount: body.remainingByteCount) } catch { throw error.malformed("payload") }
    }

    @inlinable
    var flags: Nibble {
        Nibble(UInt8(duplicate ? 0b1000 : 0) | qos.rawValue &<< 1 | (retain ? 1 : 0))
    }

    @inlinable
    var bodyByteCount: Int {
        Size.string(topic) &+ (packetIdentifier == nil ? 0 : 2) &+ properties.encodedByteCount &+ payload.byteCount
    }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTString(topic)
        if let packetIdentifier { try writer.write(packetIdentifier, as: Byte2.self, .bigEndian) }
        try writer.write(properties)
        try writer.write(payload)
    }
}

// MARK: - PUBACK, PUBREC, PUBREL, PUBCOMP

/// PUBACK, PUBREC, PUBREL, and PUBCOMP: the steps of QoS 1 and 2 delivery, which share a shape.
public struct MQTTPublishResponse: ~Escapable {
    public var packetIdentifier: UInt16
    public var reasonCode: MQTTReasonCode
    public var properties: MQTTProperties

    @inlinable
    @_lifetime(copy properties)
    public init(packetIdentifier: UInt16, reasonCode: MQTTReasonCode = .success, properties: consuming MQTTProperties) {
        self.packetIdentifier = packetIdentifier
        self.reasonCode = reasonCode
        self.properties = properties
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        packetIdentifier = try body.readMQTTUInt16("packet identifier")
        // The reason code is omitted for success with no properties, and the properties when empty.
        reasonCode = body.isAtEnd ? .success : MQTTReasonCode(rawValue: try body.readMQTTByte("reason code"))
        properties = body.isAtEnd ? MQTTProperties() : try MQTTProperties(reading: &body)
        try body.expectMQTTEnd("publish response")
    }

    @inlinable
    var bodyByteCount: Int {
        if properties.isEmpty { return reasonCode == .success ? 2 : 3 }
        return 3 &+ properties.encodedByteCount
    }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(packetIdentifier, as: Byte2.self, .bigEndian)
        if properties.isEmpty, reasonCode == .success { return }
        try writer.write(Byte(reasonCode.rawValue))
        if !properties.isEmpty { try writer.write(properties) }
    }
}

// MARK: - SUBSCRIBE

/// One subscription in a SUBSCRIBE.
public struct MQTTSubscription: ~Escapable {
    public var topicFilter: UTF8Span
    public var options: MQTTSubscriptionOptions

    @inlinable
    @_lifetime(copy topicFilter)
    public init(topicFilter: UTF8Span, options: MQTTSubscriptionOptions) {
        self.topicFilter = topicFilter
        self.options = options
    }
}

/// A SUBSCRIBE's subscriptions: a view of the encoded list, checked once when parsed.
public struct MQTTSubscriptions: ~Escapable {
    /// The encoded subscriptions.
    public let bytes: RawSpan

    /// Views encoded subscriptions, checking that there's at least one and each is well-formed.
    @inlinable
    @_lifetime(copy bytes)
    public init(validating bytes: RawSpan) throws(MQTTError) {
        var reader = Bytes(bytes)
        guard !reader.isAtEnd else { throw .protocolError("no subscriptions") }
        while !reader.isAtEnd {
            _ = try reader.readMQTTString("topic filter")
            _ = try MQTTSubscriptionOptions(reading: &reader)
        }
        self.bytes = bytes
    }

    /// Calls `body` with each subscription, in order.
    @inlinable
    public func forEach<E: Error>(_ body: (borrowing MQTTSubscription) throws(E) -> Void) throws(E) {
        var reader = Bytes(bytes)
        while !reader.isAtEnd {
            // Checked when the list was created, so reading can't fail.
            let topicFilter = try! reader.readMQTTString("topic filter")
            try body(MQTTSubscription(topicFilter: topicFilter, options: try! MQTTSubscriptionOptions(reading: &reader)))
        }
    }
}

extension BytesWriter {
    /// Writes a subscription, for building a list to view with ``MQTTSubscriptions/init(validating:)``.
    @inlinable
    @_lifetime(self: copy self)
    public mutating func write(_ subscription: borrowing MQTTSubscription) throws(BytesError) {
        try writeMQTTString(subscription.topicFilter)
        try subscription.options.write(to: &self)
    }
}

/// SUBSCRIBE: a request for messages matching topic filters.
public struct MQTTSubscribe: ~Escapable {
    public var packetIdentifier: UInt16
    public var properties: MQTTProperties
    public var subscriptions: MQTTSubscriptions

    @inlinable
    @_lifetime(copy properties, copy subscriptions)
    public init(packetIdentifier: UInt16, properties: consuming MQTTProperties, subscriptions: consuming MQTTSubscriptions) {
        self.packetIdentifier = packetIdentifier
        self.properties = properties
        self.subscriptions = subscriptions
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        packetIdentifier = try body.readMQTTUInt16("packet identifier")
        properties = try MQTTProperties(reading: &body)
        let list: RawSpan
        do throws(BytesError) { list = try body.read(byteCount: body.remainingByteCount) } catch { throw error.malformed("subscriptions") }
        subscriptions = try MQTTSubscriptions(validating: list)
    }

    @inlinable
    var bodyByteCount: Int { 2 &+ properties.encodedByteCount &+ subscriptions.bytes.byteCount }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(packetIdentifier, as: Byte2.self, .bigEndian)
        try writer.write(properties)
        try writer.write(subscriptions.bytes)
    }
}

// MARK: - UNSUBSCRIBE

/// An UNSUBSCRIBE's topic filters: a view of the encoded list, checked once when parsed.
public struct MQTTTopicFilters: ~Escapable {
    /// The encoded topic filters.
    public let bytes: RawSpan

    /// Views encoded topic filters, checking that there's at least one and each is a valid string.
    @inlinable
    @_lifetime(copy bytes)
    public init(validating bytes: RawSpan) throws(MQTTError) {
        var reader = Bytes(bytes)
        guard !reader.isAtEnd else { throw .protocolError("no topic filters") }
        while !reader.isAtEnd { _ = try reader.readMQTTString("topic filter") }
        self.bytes = bytes
    }

    /// Calls `body` with each topic filter, in order.
    @inlinable
    public func forEach<E: Error>(_ body: (UTF8Span) throws(E) -> Void) throws(E) {
        var reader = Bytes(bytes)
        while !reader.isAtEnd {
            try body(try! reader.readMQTTString("topic filter"))
        }
    }
}

/// UNSUBSCRIBE: a request to remove subscriptions.
public struct MQTTUnsubscribe: ~Escapable {
    public var packetIdentifier: UInt16
    public var properties: MQTTProperties
    public var topicFilters: MQTTTopicFilters

    @inlinable
    @_lifetime(copy properties, copy topicFilters)
    public init(packetIdentifier: UInt16, properties: consuming MQTTProperties, topicFilters: consuming MQTTTopicFilters) {
        self.packetIdentifier = packetIdentifier
        self.properties = properties
        self.topicFilters = topicFilters
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        packetIdentifier = try body.readMQTTUInt16("packet identifier")
        properties = try MQTTProperties(reading: &body)
        let list: RawSpan
        do throws(BytesError) { list = try body.read(byteCount: body.remainingByteCount) } catch { throw error.malformed("topic filters") }
        topicFilters = try MQTTTopicFilters(validating: list)
    }

    @inlinable
    var bodyByteCount: Int { 2 &+ properties.encodedByteCount &+ topicFilters.bytes.byteCount }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(packetIdentifier, as: Byte2.self, .bigEndian)
        try writer.write(properties)
        try writer.write(topicFilters.bytes)
    }
}

// MARK: - SUBACK, UNSUBACK

/// SUBACK and UNSUBACK: one reason code per subscription or topic filter, in request order.
public struct MQTTSubscribeAcknowledgement: ~Escapable {
    public var packetIdentifier: UInt16
    public var properties: MQTTProperties
    /// The reason codes' raw values, viewing the packet.
    public var reasonCodes: Span<UInt8>

    @inlinable
    @_lifetime(copy properties, copy reasonCodes)
    public init(packetIdentifier: UInt16, properties: consuming MQTTProperties, reasonCodes: Span<UInt8>) {
        self.packetIdentifier = packetIdentifier
        self.properties = properties
        self.reasonCodes = reasonCodes
    }

    /// The reason code at `index`.
    @inlinable
    public func reasonCode(at index: Int) -> MQTTReasonCode {
        MQTTReasonCode(rawValue: reasonCodes[index])
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        packetIdentifier = try body.readMQTTUInt16("packet identifier")
        properties = try MQTTProperties(reading: &body)
        guard !body.isAtEnd else { throw .protocolError("no reason codes") }
        do throws(BytesError) {
            reasonCodes = Span(viewing: try body.read(byteCount: body.remainingByteCount))
        } catch {
            throw error.malformed("reason codes")
        }
    }

    @inlinable
    var bodyByteCount: Int { 2 &+ properties.encodedByteCount &+ reasonCodes.count }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(packetIdentifier, as: Byte2.self, .bigEndian)
        try writer.write(properties)
        try writer.write(reasonCodes)
    }
}

// MARK: - DISCONNECT, AUTH

/// DISCONNECT and AUTH: a reason code and properties, both omitted for the default.
public struct MQTTReason: ~Escapable {
    public var reasonCode: MQTTReasonCode
    public var properties: MQTTProperties

    @inlinable
    @_lifetime(copy properties)
    public init(reasonCode: MQTTReasonCode = .success, properties: consuming MQTTProperties) {
        self.reasonCode = reasonCode
        self.properties = properties
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        reasonCode = body.isAtEnd ? .success : MQTTReasonCode(rawValue: try body.readMQTTByte("reason code"))
        properties = body.isAtEnd ? MQTTProperties() : try MQTTProperties(reading: &body)
        try body.expectMQTTEnd("reason")
    }

    @inlinable
    var bodyByteCount: Int {
        if properties.isEmpty { return reasonCode == .success ? 0 : 1 }
        return 1 &+ properties.encodedByteCount
    }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        if properties.isEmpty, reasonCode == .success { return }
        try writer.write(Byte(reasonCode.rawValue))
        if !properties.isEmpty { try writer.write(properties) }
    }
}
