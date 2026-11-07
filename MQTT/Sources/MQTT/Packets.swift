public import Bytes

// Every packet is a view: strings, binary data, payloads, and lists refer to the bytes the packet was parsed
// from (or, when encoding, to the caller's values), so parsing allocates nothing. Each parses from its body
// (the section the fixed header's remaining length delimits), checks what MQTT 5.0 requires of a receiver,
// and, for encoding, checks the same rules (`validate()`) and computes its body's size before writing.

// MARK: - Checks shared by parsing and encoding

@usableFromInline
enum Check {
    /// A string an encoder is about to write: at most 65,535 bytes, no U+0000.
    @inlinable
    static func string(_ text: UTF8Span) throws(MQTTError) {
        guard !Text.isTooLong(text.count) else { throw .malformed("string longer than 65,535 bytes") }
        guard !Text.containsNull(text) else { throw .malformed("U+0000 in a string") }
    }

    /// Binary data an encoder is about to write: at most 65,535 bytes.
    @inlinable
    static func binary(_ bytes: RawSpan) throws(MQTTError) {
        guard !Text.isTooLong(bytes.byteCount) else { throw .malformed("binary data longer than 65,535 bytes") }
    }

    /// A topic name: no wildcards or U+0000, and at least one character unless a Topic Alias stands in for
    /// it [MQTT-3.3.2-2, MQTT-4.7.3-1, 3.3.2.1].
    @inlinable
    static func topicName(_ topic: UTF8Span, hasTopicAlias: Bool) throws(MQTTError) {
        guard !Text.containsWildcardOrNull(topic) else { throw .malformed("wildcard or U+0000 in a topic name") }
        guard topic.count > 0 || hasTopicAlias else { throw .protocolError("empty topic name without a topic alias") }
    }

    /// A reason code allowed in the packet.
    @inlinable
    static func reasonCode(_ code: MQTTReasonCode, in allowed: ReasonCodeSet) throws(MQTTError) {
        guard allowed.contains(code) else { throw .protocolError("reason code not allowed in this packet") }
    }

    /// A packet identifier for SUBSCRIBE, UNSUBSCRIBE, or PUBLISH with QoS 1 or 2 [MQTT-2.2.1-3].
    @inlinable
    static func packetIdentifier(_ identifier: UInt16) throws(MQTTError) {
        guard identifier != 0 else { throw .protocolError("packet identifier 0") }
    }
}

extension Bytes {
    /// A topic name, checked as ``Check/topicName(_:hasTopicAlias:)`` does except for the alias, which comes
    /// later in the packet. One scan for wildcards and U+0000.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readMQTTTopicName(_ detail: StaticString) throws(MQTTError) -> UTF8Span {
        let topic: UTF8Span
        do throws(BytesError) { topic = try read(utf8PrefixedBy: Byte2.self, .bigEndian) } catch { throw .malformed(detail) }
        guard !Text.containsWildcardOrNull(topic) else { throw .malformed("wildcard or U+0000 in a topic name") }
        return topic
    }
}

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
    public init(
        qos: MQTTQoS, retain: Bool = false, properties: consuming MQTTProperties = MQTTProperties(), topic: UTF8Span,
        payload: RawSpan
    ) {
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
        cleanStart: Bool, keepAlive: UInt16, properties: consuming MQTTProperties = MQTTProperties(),
        clientIdentifier: UTF8Span, will: consuming MQTTWill? = nil, userName: UTF8Span? = nil, password: RawSpan? = nil
    ) {
        self.cleanStart = cleanStart
        self.keepAlive = keepAlive
        self.properties = properties
        self.clientIdentifier = clientIdentifier
        self.will = will
        self.userName = userName
        self.password = password
    }

    /// "MQTT" as an MQTT string.
    @inlinable
    static var protocolName: Byte6 { 0x00_04_4D_51_54_54 }

    @inlinable
    static var protocolVersion: Byte { 5 }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        // A server answers another protocol name or version with CONNACK 0x84 [MQTT-3.1.2-2].
        do throws(BytesError) { try body.expect(Self.protocolName) } catch {
            throw error == .mismatch ? MQTTError(.unsupportedProtocolVersion, "protocol name") : .malformed("protocol name")
        }
        guard try body.readMQTTByte("protocol version") == Self.protocolVersion else {
            throw MQTTError(.unsupportedProtocolVersion, "protocol version")
        }
        // The connect flags, field by field, then the keep-alive.
        let flags: (userName: Bool, password: Bool, willRetain: Bool, willQoS: Crumb, will: Bool, reserved: Bit)
        do throws(BytesError) {
            flags.userName = try body.read(Bit.self).isSet
            flags.password = try body.read(Bit.self).isSet
            flags.willRetain = try body.read(Bit.self).isSet
            flags.willQoS = try body.read(Crumb.self)
            flags.will = try body.read(Bit.self).isSet
            cleanStart = try body.read(Bit.self).isSet
            flags.reserved = try body.read(Bit.self)
            keepAlive = try body.read(Byte2.self, .bigEndian)
        } catch {
            throw .malformed("connect header")
        }
        guard flags.reserved == 0 else { throw .malformed("reserved connect flag") }
        guard let willQoS = MQTTQoS(rawBits: flags.willQoS) else { throw .malformed("will QoS 3") }
        guard flags.will || (willQoS == .atMostOnce && !flags.willRetain) else {
            throw .malformed("will QoS or retain without a will")
        }
        properties = try MQTTProperties(reading: &body, allowing: .connect)
        clientIdentifier = try body.readMQTTString("client identifier")
        if flags.will {
            let willProperties = try MQTTProperties(reading: &body, allowing: .will)
            let topic = try body.readMQTTTopicName("will topic")
            guard topic.count > 0 else { throw .protocolError("empty will topic") }
            will = MQTTWill(
                qos: willQoS, retain: flags.willRetain, properties: willProperties, topic: topic,
                payload: try body.readMQTTBinary("will payload")
            )
        } else {
            will = nil
        }
        userName = flags.userName ? try body.readMQTTString("user name") : nil
        password = flags.password ? try body.readMQTTBinary("password") : nil
        try body.expectMQTTEnd("connect")
    }

    @inlinable
    func validate() throws(MQTTError) {
        try properties.check(allowing: .connect)
        try Check.string(clientIdentifier)
        if let will {
            try will.properties.check(allowing: .will)
            try Check.string(will.topic)
            try Check.topicName(will.topic, hasTopicAlias: false)
            try Check.binary(will.payload)
        }
        if let userName { try Check.string(userName) }
        if let password { try Check.binary(password) }
    }

    @inlinable
    var bodyByteCount: Int {
        var count = 6 &+ 1 &+ 1 &+ 2 &+ properties.encodedByteCount &+ Size.string(clientIdentifier)
        if let will {
            count &+= will.properties.encodedByteCount &+ Size.string(will.topic) &+ Size.binary(will.payload)
        }
        if let userName { count &+= Size.string(userName) }
        if let password { count &+= Size.binary(password) }
        return count
    }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(Self.protocolName)
        try writer.write(Self.protocolVersion)
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
    /// Whether the server resumed a session. Only with a successful reason code.
    public var sessionPresent: Bool
    public var reasonCode: MQTTReasonCode
    public var properties: MQTTProperties

    @inlinable
    @_lifetime(copy properties)
    public init(sessionPresent: Bool = false, reasonCode: MQTTReasonCode = .success, properties: consuming MQTTProperties = MQTTProperties()) {
        self.sessionPresent = sessionPresent
        self.reasonCode = reasonCode
        self.properties = properties
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        let reserved: Bits<7>
        do throws(BytesError) {
            reserved = try body.read(Bits<7>.self)
            sessionPresent = try body.read(Bit.self).isSet
            reasonCode = try body.read(MQTTReasonCode.self, as: Byte.self)
        } catch {
            throw .malformed("connect acknowledge flags")
        }
        guard reserved == 0 else { throw .malformed("reserved connect acknowledge flags") }
        try Self.check(reasonCode, sessionPresent: sessionPresent)
        properties = try MQTTProperties(reading: &body, allowing: .connectAcknowledgement)
        try body.expectMQTTEnd("connect acknowledgement")
    }

    /// The reason code is one CONNACK allows, and a failure has no session [MQTT-3.2.2-6].
    @inlinable
    static func check(_ reasonCode: MQTTReasonCode, sessionPresent: Bool) throws(MQTTError) {
        try Check.reasonCode(reasonCode, in: .connectAcknowledgement)
        guard !(sessionPresent && reasonCode.isFailure) else { throw .protocolError("session present with a failure") }
    }

    @inlinable
    func validate() throws(MQTTError) {
        try Self.check(reasonCode, sessionPresent: sessionPresent)
        try properties.check(allowing: .connectAcknowledgement)
    }

    @inlinable
    var bodyByteCount: Int { 2 &+ properties.encodedByteCount }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(Bits<7>(0))
        try writer.write(Bit(sessionPresent))
        try writer.write(reasonCode, as: Byte.self)
        try writer.write(properties)
    }
}

// MARK: - PUBLISH

/// PUBLISH: an application message.
public struct MQTTPublish: ~Escapable {
    /// Whether this is a redelivery. Only with QoS 1 or 2.
    public var duplicate: Bool
    public var qos: MQTTQoS
    public var retain: Bool
    /// Empty only with a Topic Alias property, which then stands in for it.
    public var topic: UTF8Span
    /// Non-zero, with QoS 1 or 2; `nil` with QoS 0.
    public var packetIdentifier: UInt16?
    public var properties: MQTTProperties
    public var payload: RawSpan

    @inlinable
    @_lifetime(copy topic, copy properties, copy payload)
    public init(
        duplicate: Bool = false, qos: MQTTQoS = .atMostOnce, retain: Bool = false, topic: UTF8Span,
        packetIdentifier: UInt16? = nil, properties: consuming MQTTProperties = MQTTProperties(), payload: RawSpan
    ) {
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
        guard let qos = MQTTQoS(rawBits: flags[Crumb.self, at: 1]) else { throw .malformed("QoS 3") }
        self.qos = qos
        retain = flags[bit: 0]
        guard qos != .atMostOnce || !duplicate else { throw .malformed("DUP set on a QoS 0 message") }
        topic = try body.readMQTTTopicName("topic name")
        packetIdentifier = qos == .atMostOnce ? nil : try body.readMQTTPacketIdentifier()
        properties = try MQTTProperties(reading: &body, allowing: .publish, repeatable: .repeatableInPublish)
        guard topic.count > 0 || properties.identifiers.contains(0x23) else {
            throw .protocolError("empty topic name without a topic alias")
        }
        // The payload is the rest of the packet.
        do throws(BytesError) { payload = try body.read(byteCount: body.remainingByteCount) } catch { throw .malformed("payload") }
    }

    @inlinable
    func validate() throws(MQTTError) {
        guard (qos == .atMostOnce) == (packetIdentifier == nil) else {
            throw .protocolError("QoS 1 and 2 need a packet identifier; QoS 0 has none")
        }
        if let packetIdentifier { try Check.packetIdentifier(packetIdentifier) }
        guard qos != .atMostOnce || !duplicate else { throw .malformed("DUP set on a QoS 0 message") }
        guard !Text.isTooLong(topic.count) else { throw .malformed("string longer than 65,535 bytes") }
        try Check.topicName(topic, hasTopicAlias: properties.identifiers.contains(0x23))
        try properties.check(allowing: .publish)
    }

    @inlinable
    var flags: Nibble {
        var flags = Nibble.zero
        flags[bit: 3] = duplicate
        flags[Crumb.self, at: 1] = Crumb(qos.rawValue)
        flags[bit: 0] = retain
        return flags
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
    public init(packetIdentifier: UInt16, reasonCode: MQTTReasonCode = .success, properties: consuming MQTTProperties = MQTTProperties()) {
        self.packetIdentifier = packetIdentifier
        self.reasonCode = reasonCode
        self.properties = properties
    }

    /// `reasonCodes` is the set the packet type allows.
    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes, reasonCodes: ReasonCodeSet) throws(MQTTError) {
        packetIdentifier = try body.readMQTTUInt16("packet identifier")
        // The reason code is omitted for success with no properties, and the properties when empty.
        reasonCode = body.isAtEnd ? .success : try body.readMQTTReasonCode()
        try Check.reasonCode(reasonCode, in: reasonCodes)
        properties = body.isAtEnd ? MQTTProperties() : try MQTTProperties(reading: &body, allowing: .acknowledgement)
        try body.expectMQTTEnd("publish response")
    }

    @inlinable
    func validate(reasonCodes: ReasonCodeSet) throws(MQTTError) {
        try Check.reasonCode(reasonCode, in: reasonCodes)
        try properties.check(allowing: .acknowledgement)
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
        try writer.write(reasonCode, as: Byte.self)
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

    /// Views encoded subscriptions, checking that there's at least one, and that each is well-formed, has a
    /// non-empty topic filter, and doesn't set No Local on a shared subscription [MQTT-3.8.3-4]. Wildcard
    /// placement isn't checked: a server answers an invalid filter with reason code 0x8F in its SUBACK.
    @inlinable
    @_lifetime(copy bytes)
    public init(validating bytes: RawSpan) throws(MQTTError) {
        var reader = Bytes(bytes)
        guard !reader.isAtEnd else { throw .protocolError("no subscriptions") }
        while !reader.isAtEnd {
            let filter = try reader.readMQTTString("topic filter")
            guard filter.count > 0 else { throw .protocolError("empty topic filter") }
            let options = try MQTTSubscriptionOptions(reading: &reader)
            guard !(options.noLocal && Text.isShared(filter)) else { throw .protocolError("no local on a shared subscription") }
        }
        self.bytes = bytes
    }

    /// Calls `body` with each subscription, in order.
    @inlinable
    public func forEach<E: Error>(_ body: (borrowing MQTTSubscription) throws(E) -> Void) throws(E) {
        var reader = Bytes(bytes)
        while !reader.isAtEnd {
            // Checked when the list was created, so reading can't fail, and needn't check again.
            let topicFilter = try! reader.readMQTTText(checked: false)
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
    /// Non-zero.
    public var packetIdentifier: UInt16
    public var properties: MQTTProperties
    public var subscriptions: MQTTSubscriptions

    @inlinable
    @_lifetime(copy properties, copy subscriptions)
    public init(
        packetIdentifier: UInt16, properties: consuming MQTTProperties = MQTTProperties(), subscriptions: consuming MQTTSubscriptions
    ) {
        self.packetIdentifier = packetIdentifier
        self.properties = properties
        self.subscriptions = subscriptions
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        packetIdentifier = try body.readMQTTPacketIdentifier()
        properties = try MQTTProperties(reading: &body, allowing: .subscribe)
        let list: RawSpan
        do throws(BytesError) { list = try body.read(byteCount: body.remainingByteCount) } catch { throw .malformed("subscriptions") }
        subscriptions = try MQTTSubscriptions(validating: list)
    }

    @inlinable
    func validate() throws(MQTTError) {
        try Check.packetIdentifier(packetIdentifier)
        try properties.check(allowing: .subscribe)
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

    /// Views encoded topic filters, checking that there's at least one and each is a non-empty string.
    @inlinable
    @_lifetime(copy bytes)
    public init(validating bytes: RawSpan) throws(MQTTError) {
        var reader = Bytes(bytes)
        guard !reader.isAtEnd else { throw .protocolError("no topic filters") }
        while !reader.isAtEnd {
            guard try reader.readMQTTString("topic filter").count > 0 else { throw .protocolError("empty topic filter") }
        }
        self.bytes = bytes
    }

    /// Calls `body` with each topic filter, in order.
    @inlinable
    public func forEach<E: Error>(_ body: (UTF8Span) throws(E) -> Void) throws(E) {
        var reader = Bytes(bytes)
        while !reader.isAtEnd {
            try body(try! reader.readMQTTText(checked: false))
        }
    }
}

/// UNSUBSCRIBE: a request to remove subscriptions.
public struct MQTTUnsubscribe: ~Escapable {
    /// Non-zero.
    public var packetIdentifier: UInt16
    public var properties: MQTTProperties
    public var topicFilters: MQTTTopicFilters

    @inlinable
    @_lifetime(copy properties, copy topicFilters)
    public init(
        packetIdentifier: UInt16, properties: consuming MQTTProperties = MQTTProperties(), topicFilters: consuming MQTTTopicFilters
    ) {
        self.packetIdentifier = packetIdentifier
        self.properties = properties
        self.topicFilters = topicFilters
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        packetIdentifier = try body.readMQTTPacketIdentifier()
        properties = try MQTTProperties(reading: &body, allowing: .unsubscribe)
        let list: RawSpan
        do throws(BytesError) { list = try body.read(byteCount: body.remainingByteCount) } catch { throw .malformed("topic filters") }
        topicFilters = try MQTTTopicFilters(validating: list)
    }

    @inlinable
    func validate() throws(MQTTError) {
        try Check.packetIdentifier(packetIdentifier)
        try properties.check(allowing: .unsubscribe)
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
    /// The reason codes' raw values, viewing the packet. At least one; see ``reasonCode(at:)``.
    public var reasonCodes: Span<UInt8>

    @inlinable
    @_lifetime(copy properties, copy reasonCodes)
    public init(packetIdentifier: UInt16, properties: consuming MQTTProperties = MQTTProperties(), reasonCodes: Span<UInt8>) {
        self.packetIdentifier = packetIdentifier
        self.properties = properties
        self.reasonCodes = reasonCodes
    }

    /// The reason code at `index`.
    @inlinable
    public func reasonCode(at index: Int) -> MQTTReasonCode {
        MQTTReasonCode(rawValue: reasonCodes[index])
    }

    /// `allowed` is the set the packet type allows.
    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes, reasonCodes allowed: ReasonCodeSet) throws(MQTTError) {
        packetIdentifier = try body.readMQTTUInt16("packet identifier")
        properties = try MQTTProperties(reading: &body, allowing: .acknowledgement)
        do throws(BytesError) {
            reasonCodes = Span(viewing: try body.read(byteCount: body.remainingByteCount))
        } catch {
            throw .malformed("reason codes")
        }
        try Self.check(reasonCodes, allowed)
    }

    @inlinable
    static func check(_ reasonCodes: Span<UInt8>, _ allowed: ReasonCodeSet) throws(MQTTError) {
        guard !reasonCodes.isEmpty else { throw .protocolError("no reason codes") }
        for index in reasonCodes.indices {
            try Check.reasonCode(MQTTReasonCode(rawValue: reasonCodes[index]), in: allowed)
        }
    }

    @inlinable
    func validate(reasonCodes allowed: ReasonCodeSet) throws(MQTTError) {
        try Self.check(reasonCodes, allowed)
        try properties.check(allowing: .acknowledgement)
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

/// UNSUBACK has SUBACK's shape, with its own reason codes.
public typealias MQTTUnsubscribeAcknowledgement = MQTTSubscribeAcknowledgement

// MARK: - DISCONNECT

/// DISCONNECT: the last packet either side sends, with why.
public struct MQTTDisconnect: ~Escapable {
    public var reasonCode: MQTTReasonCode
    public var properties: MQTTProperties

    @inlinable
    @_lifetime(copy properties)
    public init(reasonCode: MQTTReasonCode = .normalDisconnection, properties: consuming MQTTProperties = MQTTProperties()) {
        self.reasonCode = reasonCode
        self.properties = properties
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        // Remaining length 0: normal disconnection; 1: a reason code without properties [3.14.2.2.1].
        reasonCode = body.isAtEnd ? .normalDisconnection : try body.readMQTTReasonCode()
        try Check.reasonCode(reasonCode, in: .disconnect)
        properties = body.isAtEnd ? MQTTProperties() : try MQTTProperties(reading: &body, allowing: .disconnect)
        try body.expectMQTTEnd("disconnect")
    }

    @inlinable
    func validate() throws(MQTTError) {
        try Check.reasonCode(reasonCode, in: .disconnect)
        try properties.check(allowing: .disconnect)
    }

    @inlinable
    var bodyByteCount: Int {
        if properties.isEmpty { return reasonCode == .normalDisconnection ? 0 : 1 }
        return 1 &+ properties.encodedByteCount
    }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        if properties.isEmpty, reasonCode == .normalDisconnection { return }
        try writer.write(reasonCode, as: Byte.self)
        if !properties.isEmpty { try writer.write(properties) }
    }
}

// MARK: - AUTH

/// AUTH: a step of extended (challenge/response) authentication.
public struct MQTTAuthenticate: ~Escapable {
    public var reasonCode: MQTTReasonCode
    public var properties: MQTTProperties

    @inlinable
    @_lifetime(copy properties)
    public init(reasonCode: MQTTReasonCode = .success, properties: consuming MQTTProperties = MQTTProperties()) {
        self.reasonCode = reasonCode
        self.properties = properties
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout Bytes) throws(MQTTError) {
        // Remaining length 0: success without properties [3.15.2.1]. (A lone reason code is accepted too.)
        reasonCode = body.isAtEnd ? .success : try body.readMQTTReasonCode()
        try Check.reasonCode(reasonCode, in: .authenticate)
        properties = body.isAtEnd ? MQTTProperties() : try MQTTProperties(reading: &body, allowing: .authenticate)
        try body.expectMQTTEnd("authenticate")
    }

    @inlinable
    func validate() throws(MQTTError) {
        try Check.reasonCode(reasonCode, in: .authenticate)
        try properties.check(allowing: .authenticate)
    }

    /// The reason code and property length are omitted only together, for success without properties.
    @inlinable
    var bodyByteCount: Int {
        properties.isEmpty && reasonCode == .success ? 0 : 1 &+ properties.encodedByteCount
    }

    @inlinable
    func writeBody(to writer: inout BytesWriter) throws(BytesError) {
        if properties.isEmpty, reasonCode == .success { return }
        try writer.write(reasonCode, as: Byte.self)
        try writer.write(properties)
    }
}
