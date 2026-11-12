public import Bytes

// Every packet is a view: strings, binary data, payloads, and lists refer to the bytes the packet was parsed
// from (or, when encoding, to the caller's values), so parsing allocates nothing. Each parses from its body
// (the section the fixed header's remaining length delimits), checks what MQTT 5.0 requires of a receiver,
// and, for encoding, checks the same rules (`validate()`) and computes its body's size before writing.

// MARK: - Checks shared by parsing and encoding

@usableFromInline
enum Check {
    /// Checks a string an encoder is about to write: at most 65,535 bytes, no U+0000.
    ///
    /// - Parameter text: The string.
    /// - Throws: `MQTTError.malformed(_:)` if it's too long or contains U+0000.
    @inlinable
    static func string(_ text: UTF8Span) throws(MQTTError) {
        guard !Text.isTooLong(text.count) else { throw .malformed("string longer than 65,535 bytes") }
        guard !Text.containsNull(text) else { throw .malformed("U+0000 in a string") }
    }

    /// Checks binary data an encoder is about to write: at most 65,535 bytes.
    ///
    /// - Parameter bytes: The data.
    /// - Throws: `MQTTError.malformed(_:)` if it's too long.
    @inlinable
    static func binary(_ bytes: RawSpan) throws(MQTTError) {
        guard !Text.isTooLong(bytes.byteCount) else { throw .malformed("binary data longer than 65,535 bytes") }
    }

    /// Checks a topic name: no wildcards or U+0000, and at least one character unless a Topic Alias stands in
    /// for it [MQTT-3.3.2-2, MQTT-4.7.3-1, 3.3.2.1].
    ///
    /// - Parameters:
    ///   - topic: The topic name.
    ///   - hasTopicAlias: Whether the packet has a Topic Alias property.
    /// - Throws: `MQTTError.malformed(_:)` for a wildcard or U+0000; `MQTTError.protocolError(_:)` if
    ///   it's empty without an alias.
    @inlinable
    static func topicName(_ topic: UTF8Span, hasTopicAlias: Bool) throws(MQTTError) {
        guard !Text.containsWildcardOrNull(topic) else { throw .malformed("wildcard or U+0000 in a topic name") }
        guard !topic.isEmpty || hasTopicAlias else { throw .protocolError("empty topic name without a topic alias") }
    }

    /// Checks that a reason code is one the packet type allows.
    ///
    /// - Parameters:
    ///   - code: The reason code.
    ///   - allowed: The packet type's codes.
    /// - Throws: `MQTTError.protocolError(_:)` if it isn't allowed.
    @inlinable
    static func reasonCode(_ code: MQTTReasonCode, in allowed: ReasonCodeSet) throws(MQTTError) {
        guard allowed.contains(code) else { throw .protocolError("reason code not allowed in this packet") }
    }

    /// Checks the packet identifier of a SUBSCRIBE, UNSUBSCRIBE, or PUBLISH with QoS 1 or 2 [MQTT-2.2.1-3].
    ///
    /// - Parameter identifier: The identifier.
    /// - Throws: `MQTTError.protocolError(_:)` if it's 0.
    @inlinable
    static func packetIdentifier(_ identifier: UInt16) throws(MQTTError) {
        guard identifier != 0 else { throw .protocolError("packet identifier 0") }
    }
}

extension BytesReader {
    /// Reads a topic name, checked as ``Check/topicName(_:hasTopicAlias:)`` does except for the empty case,
    /// which depends on the alias, later in the packet. One pass for an ASCII topic: its UTF-8, wildcards,
    /// and U+0000 together.
    ///
    /// - Parameter detail: The detail for an error other than a wildcard or U+0000.
    /// - Returns: The topic name, borrowing the reader's bytes.
    /// - Throws: `MQTTError.malformed(_:)` with "wildcard or U+0000 in a topic name" if the topic has
    ///   either, or with `detail` if it's truncated or isn't valid UTF-8. Nothing is consumed on failure.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readMQTTTopicName(_ detail: StaticString) throws(MQTTError) -> UTF8Span {
        do throws(BytesError) {
            return try read(utf8PrefixedBy: Byte2.self, .bigEndian, excluding: Text.wildcardOrNull)
        } catch {
            // Which rule it broke, now that it's an error (nothing was consumed): if it's valid UTF-8, a
            // wildcard or U+0000.
            let start = position
            guard error == .invalidValue, (try? read(utf8PrefixedBy: Byte2.self, .bigEndian)) != nil else {
                throw .malformed(detail)
            }
            rewind(to: start)
            throw .malformed("wildcard or U+0000 in a topic name")
        }
    }
}

// MARK: - CONNECT

/// A will: the message the server publishes if the client disconnects abnormally.
public struct MQTTWill: ~Escapable {
    /// The QoS to publish the will at.
    public var qos: MQTTQoS
    /// Whether the server retains the will.
    public var retain: Bool
    /// The will's properties, such as Will Delay Interval.
    public var properties: MQTTProperties
    /// The topic to publish to: no wildcards, not empty.
    public var topic: UTF8Span
    /// The message.
    public var payload: RawSpan

    /// Creates a will.
    ///
    /// - Parameters:
    ///   - qos: The QoS to publish at.
    ///   - retain: Whether the server retains the message.
    ///   - properties: The will's properties.
    ///   - topic: The topic to publish to.
    ///   - payload: The message.
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
    /// Whether to start a new session, discarding any existing one.
    public var cleanStart: Bool
    /// Seconds; 0 turns keep-alive off.
    public var keepAlive: UInt16
    /// The connection's properties, such as Session Expiry Interval.
    public var properties: MQTTProperties
    /// The client's identifier; may be empty, for the server to assign one.
    public var clientIdentifier: UTF8Span
    /// The will, if any.
    public var will: MQTTWill?
    /// The user name, if any.
    public var userName: UTF8Span?
    /// The password, if any.
    public var password: RawSpan?

    /// Creates a CONNECT.
    ///
    /// - Parameters:
    ///   - cleanStart: Whether to start a new session.
    ///   - keepAlive: The keep-alive interval in seconds; 0 turns it off.
    ///   - properties: The connection's properties.
    ///   - clientIdentifier: The client's identifier.
    ///   - will: The will, if any.
    ///   - userName: The user name, if any.
    ///   - password: The password, if any.
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
    init(reading body: inout BytesReader) throws(MQTTError) {
        // A server answers another protocol name or version with CONNACK 0x84 [MQTT-3.1.2-2].
        do throws(BytesError) { try body.expect(Self.protocolName) } catch {
            throw error == .mismatch ? MQTTError(.unsupportedProtocolVersion, "protocol name") : .malformed("protocol name")
        }
        guard try body.readMQTTByte("protocol version") == Self.protocolVersion else {
            throw MQTTError(.unsupportedProtocolVersion, "protocol version")
        }
        // The connect flags, then the keep-alive. The flags, from the most significant bit: user name,
        // password, will retain, will QoS (2 bits), will, clean start, and a reserved bit.
        let connectFlags: Byte
        do throws(BytesError) {
            connectFlags = try body.read(Byte.self)
            keepAlive = try body.read(Byte2.self, .bigEndian)
        } catch {
            throw .malformed("connect header")
        }
        guard !connectFlags[bit: 0] else { throw .malformed("reserved connect flag") }
        cleanStart = connectFlags[bit: 1]
        let flags = (userName: connectFlags[bit: 7], password: connectFlags[bit: 6], willRetain: connectFlags[bit: 5],
                     will: connectFlags[bit: 2])
        guard let willQoS = MQTTQoS(rawBits: connectFlags[Crumb.self, at: 3]) else { throw .malformed("will QoS 3") }
        guard flags.will || (willQoS == .atMostOnce && !flags.willRetain) else {
            throw .malformed("will QoS or retain without a will")
        }
        properties = try MQTTProperties(reading: &body, allowing: .connect)
        clientIdentifier = try body.readMQTTString("client identifier")
        if flags.will {
            let willProperties = try MQTTProperties(reading: &body, allowing: .will)
            let topic = try body.readMQTTTopicName("will topic")
            guard !topic.isEmpty else { throw .protocolError("empty will topic") }
            will = try MQTTWill(
                qos: willQoS, retain: flags.willRetain, properties: willProperties, topic: topic,
                payload: body.readMQTTBinary("will payload")
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
        // The connect flags, packed first: one store.
        var flags = Byte.zero
        flags[bit: 7] = userName != nil
        flags[bit: 6] = password != nil
        flags[bit: 5] = will?.retain ?? false
        flags[Crumb.self, at: 3] = Crumb(rawBitsOf: will?.qos ?? .atMostOnce)
        flags[bit: 2] = will != nil
        flags[bit: 1] = cleanStart
        try writer.write(flags)
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
    /// The outcome: success, or why the connection was refused.
    public var reasonCode: MQTTReasonCode
    /// The server's properties, such as its limits and capabilities.
    public var properties: MQTTProperties

    /// Creates a CONNACK.
    ///
    /// - Parameters:
    ///   - sessionPresent: Whether the server resumed a session; only with a successful reason code.
    ///   - reasonCode: The outcome.
    ///   - properties: The server's properties.
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
    init(reading body: inout BytesReader) throws(MQTTError) {
        // The flags: 7 reserved bits, then Session Present.
        let flags: Byte
        do throws(BytesError) {
            flags = try body.read(Byte.self)
            reasonCode = try body.read(MQTTReasonCode.self, as: Byte.self)
        } catch {
            throw .malformed("connect acknowledge flags")
        }
        guard flags[Bits<7>.self, at: 1] == 0 else { throw .malformed("reserved connect acknowledge flags") }
        sessionPresent = flags[bit: 0]
        try Self.check(reasonCode, sessionPresent: sessionPresent)
        properties = try MQTTProperties(reading: &body, allowing: .connectAcknowledgement)
        try body.expectMQTTEnd("connect acknowledgement")
    }

    /// Checks that the reason code is one CONNACK allows, and that a failure has no session [MQTT-3.2.2-6].
    ///
    /// - Parameters:
    ///   - reasonCode: The reason code.
    ///   - sessionPresent: The Session Present flag.
    /// - Throws: `MQTTError.protocolError(_:)` if the code isn't allowed, or Session Present is set with a
    ///   failure.
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
        try writer.write(Byte(Bit(sessionPresent))) // 7 reserved bits, then Session Present
        try writer.write(reasonCode, as: Byte.self)
        try writer.write(properties)
    }
}

// MARK: - PUBLISH

/// PUBLISH: an application message.
public struct MQTTPublish: ~Escapable {
    /// Whether this is a redelivery. Only with QoS 1 or 2.
    public var duplicate: Bool
    /// The delivery guarantee.
    public var qos: MQTTQoS
    /// Whether the server retains the message for future subscribers.
    public var retain: Bool
    /// Empty only with a Topic Alias property, which then stands in for it.
    public var topic: UTF8Span
    /// Non-zero, with QoS 1 or 2; `nil` with QoS 0.
    public var packetIdentifier: UInt16?
    /// The message's properties, such as Message Expiry Interval.
    public var properties: MQTTProperties
    /// The application message.
    public var payload: RawSpan

    /// Creates a PUBLISH.
    ///
    /// - Parameters:
    ///   - duplicate: Whether this is a redelivery; only with QoS 1 or 2.
    ///   - qos: The delivery guarantee.
    ///   - retain: Whether the server retains the message.
    ///   - topic: The topic name; empty only with a Topic Alias property.
    ///   - packetIdentifier: Non-zero with QoS 1 or 2; `nil` with QoS 0.
    ///   - properties: The message's properties.
    ///   - payload: The application message.
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
    init(reading body: inout BytesReader, flags: Nibble) throws(MQTTError) {
        // The fixed header's flags: DUP, QoS (2 bits), RETAIN.
        duplicate = flags[bit: 3]
        guard let qos = MQTTQoS(rawBits: flags[Crumb.self, at: 1]) else { throw .malformed("QoS 3") }
        self.qos = qos
        retain = flags[bit: 0]
        guard qos != .atMostOnce || !duplicate else { throw .malformed("DUP set on a QoS 0 message") }
        topic = try body.readMQTTTopicName("topic name")
        packetIdentifier = qos == .atMostOnce ? nil : try body.readMQTTPacketIdentifier()
        properties = try MQTTProperties(reading: &body, allowing: .publish, repeatable: .repeatableInPublish)
        guard !topic.isEmpty || properties.identifiers.contains(0x23) else {
            throw .protocolError("empty topic name without a topic alias")
        }
        // The payload is the rest of the packet.
        payload = body.readRemainingBytes()
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
        // The checked `Crumb(_:)`, not `Crumb(rawBitsOf: qos)`: its range check lets the setter drop its
        // mask, where `rawBitsOf` truncates (an `and`): encoding PUBLISH took 3 instructions more per packet.
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
    /// The identifier of the PUBLISH this answers.
    public var packetIdentifier: UInt16
    /// The outcome; which codes are allowed depends on the packet type.
    public var reasonCode: MQTTReasonCode
    /// The response's properties: a Reason String and User Properties.
    public var properties: MQTTProperties

    /// Creates a response.
    ///
    /// - Parameters:
    ///   - packetIdentifier: The identifier of the PUBLISH it answers.
    ///   - reasonCode: The outcome.
    ///   - properties: The response's properties.
    @inlinable
    @_lifetime(copy properties)
    public init(packetIdentifier: UInt16, reasonCode: MQTTReasonCode = .success, properties: consuming MQTTProperties = MQTTProperties()) {
        self.packetIdentifier = packetIdentifier
        self.reasonCode = reasonCode
        self.properties = properties
    }

    /// Reads a response's body: the identifier, then the reason code and properties unless omitted.
    ///
    /// - Parameters:
    ///   - body: The packet's body.
    ///   - reasonCodes: The set the packet type allows.
    /// - Throws: `MQTTError.malformed(_:)` if the body is truncated, has bytes left over, or has an
    ///   invalid property; `MQTTError.protocolError(_:)` for a reason code not in `reasonCodes` or a
    ///   property rule broken.
    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout BytesReader, reasonCodes: ReasonCodeSet) throws(MQTTError) {
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
    /// The topic filter, possibly with wildcards.
    public var topicFilter: UTF8Span
    /// The subscription's options.
    public var options: MQTTSubscriptionOptions

    /// Creates a subscription.
    ///
    /// - Parameters:
    ///   - topicFilter: The topic filter.
    ///   - options: The subscription's options.
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
    /// non-empty topic filter, and doesn't set No Local on a shared subscription [MQTT-3.8.3-4].
    ///
    /// Wildcard placement isn't checked: a server answers an invalid filter with reason code 0x8F in its
    /// SUBACK. Build the bytes by writing each ``MQTTSubscription`` to a `BytesWriter`.
    ///
    /// - Parameter bytes: The encoded subscriptions: each a topic filter (a string) and an options byte.
    /// - Throws: `MQTTError.malformed(_:)` for an invalid topic filter or options byte, or a reserved
    ///   option bit; `MQTTError.protocolError(_:)` for no subscriptions, an empty filter, No Local on a
    ///   shared subscription, or a retain handling or maximum QoS of 3.
    @inlinable
    @_lifetime(copy bytes)
    public init(validating bytes: RawSpan) throws(MQTTError) {
        var reader = BytesReader(bytes)
        guard !reader.isAtEnd else { throw .protocolError("no subscriptions") }
        while !reader.isAtEnd {
            let filter = try reader.readMQTTString("topic filter")
            guard !filter.isEmpty else { throw .protocolError("empty topic filter") }
            let options = try MQTTSubscriptionOptions(reading: &reader)
            guard !(options.noLocal && Text.isShared(filter)) else { throw .protocolError("no local on a shared subscription") }
        }
        self.bytes = bytes
    }

    /// Calls `body` with each subscription, in order. The topic filters aren't validated again.
    ///
    /// - Parameter body: Called with each subscription; its error is rethrown.
    /// - Throws: Whatever `body` throws.
    @inlinable
    public func forEach<E: Error>(_ body: (borrowing MQTTSubscription) throws(E) -> Void) throws(E) {
        var reader = BytesReader(bytes)
        while !reader.isAtEnd {
            // Checked when the list was created, so reading can't fail, and needn't check again.
            let topicFilter = try! reader.readMQTTText(checked: false)
            try body(MQTTSubscription(topicFilter: topicFilter, options: try! MQTTSubscriptionOptions(reading: &reader)))
        }
    }
}

public extension BytesWriter {
    /// Writes a subscription, for building a list to view with ``MQTTSubscriptions/init(validating:)``.
    ///
    /// - Parameter subscription: The subscription.
    /// - Throws: `BytesError.invalidValue` if the topic filter is longer than 65,535 bytes;
    ///   `BytesError.insufficientCapacity` if there's no room.
    @inlinable
    @_lifetime(self: copy self)
    mutating func write(_ subscription: borrowing MQTTSubscription) throws(BytesError) {
        try writeMQTTString(subscription.topicFilter)
        try subscription.options.write(to: &self)
    }
}

/// SUBSCRIBE: a request for messages matching topic filters.
public struct MQTTSubscribe: ~Escapable {
    /// Non-zero.
    public var packetIdentifier: UInt16
    /// The request's properties: a Subscription Identifier and User Properties.
    public var properties: MQTTProperties
    /// The topic filters to subscribe to, with their options.
    public var subscriptions: MQTTSubscriptions

    /// Creates a SUBSCRIBE.
    ///
    /// - Parameters:
    ///   - packetIdentifier: A non-zero identifier.
    ///   - properties: The request's properties.
    ///   - subscriptions: The subscriptions.
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
    init(reading body: inout BytesReader) throws(MQTTError) {
        packetIdentifier = try body.readMQTTPacketIdentifier()
        properties = try MQTTProperties(reading: &body, allowing: .subscribe)
        subscriptions = try MQTTSubscriptions(validating: body.readRemainingBytes())
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
    ///
    /// - Parameter bytes: The encoded topic filters: each a string.
    /// - Throws: `MQTTError.malformed(_:)` for an invalid string; `MQTTError.protocolError(_:)` for no
    ///   topic filters or an empty one.
    @inlinable
    @_lifetime(copy bytes)
    public init(validating bytes: RawSpan) throws(MQTTError) {
        var reader = BytesReader(bytes)
        guard !reader.isAtEnd else { throw .protocolError("no topic filters") }
        while !reader.isAtEnd {
            guard try !reader.readMQTTString("topic filter").isEmpty else { throw .protocolError("empty topic filter") }
        }
        self.bytes = bytes
    }

    /// Calls `body` with each topic filter, in order. The strings aren't validated again.
    ///
    /// - Parameter body: Called with each topic filter; its error is rethrown.
    /// - Throws: Whatever `body` throws.
    @inlinable
    public func forEach<E: Error>(_ body: (UTF8Span) throws(E) -> Void) throws(E) {
        var reader = BytesReader(bytes)
        while !reader.isAtEnd {
            try body(try! reader.readMQTTText(checked: false))
        }
    }
}

/// UNSUBSCRIBE: a request to remove subscriptions.
public struct MQTTUnsubscribe: ~Escapable {
    /// Non-zero.
    public var packetIdentifier: UInt16
    /// The request's properties: User Properties.
    public var properties: MQTTProperties
    /// The topic filters to unsubscribe from.
    public var topicFilters: MQTTTopicFilters

    /// Creates an UNSUBSCRIBE.
    ///
    /// - Parameters:
    ///   - packetIdentifier: A non-zero identifier.
    ///   - properties: The request's properties.
    ///   - topicFilters: The topic filters.
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
    init(reading body: inout BytesReader) throws(MQTTError) {
        packetIdentifier = try body.readMQTTPacketIdentifier()
        properties = try MQTTProperties(reading: &body, allowing: .unsubscribe)
        topicFilters = try MQTTTopicFilters(validating: body.readRemainingBytes())
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
    /// The identifier of the request this answers.
    public var packetIdentifier: UInt16
    /// The acknowledgement's properties: a Reason String and User Properties.
    public var properties: MQTTProperties
    /// The reason codes' raw values, viewing the packet. At least one; see ``reasonCode(at:)``.
    public var reasonCodes: Span<UInt8>

    /// Creates a SUBACK or UNSUBACK.
    ///
    /// - Parameters:
    ///   - packetIdentifier: The identifier of the request it answers.
    ///   - properties: The acknowledgement's properties.
    ///   - reasonCodes: One raw reason code per subscription or topic filter, in request order.
    @inlinable
    @_lifetime(copy properties, copy reasonCodes)
    public init(packetIdentifier: UInt16, properties: consuming MQTTProperties = MQTTProperties(), reasonCodes: Span<UInt8>) {
        self.packetIdentifier = packetIdentifier
        self.properties = properties
        self.reasonCodes = reasonCodes
    }

    /// The reason code at `index`.
    ///
    /// - Parameter index: A position in ``reasonCodes``.
    /// - Returns: The code there.
    /// - Precondition: `index` is in bounds.
    @inlinable
    public func reasonCode(at index: Int) -> MQTTReasonCode {
        MQTTReasonCode(rawValue: reasonCodes[index])
    }

    /// Reads a SUBACK's or UNSUBACK's body: the identifier, the properties, and the rest as reason codes.
    ///
    /// - Parameters:
    ///   - body: The packet's body.
    ///   - allowed: The set the packet type allows.
    /// - Throws: `MQTTError.malformed(_:)` if the identifier is truncated or a property is invalid;
    ///   `MQTTError.protocolError(_:)` for no reason codes, a code not in `allowed`, or a property rule
    ///   broken.
    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout BytesReader, reasonCodes allowed: ReasonCodeSet) throws(MQTTError) {
        packetIdentifier = try body.readMQTTUInt16("packet identifier")
        properties = try MQTTProperties(reading: &body, allowing: .acknowledgement)
        reasonCodes = Span(viewing: body.readRemainingBytes())
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
    /// Why the connection is ending.
    public var reasonCode: MQTTReasonCode
    /// The packet's properties, such as a Reason String or Server Reference.
    public var properties: MQTTProperties

    /// Creates a DISCONNECT.
    ///
    /// - Parameters:
    ///   - reasonCode: Why the connection is ending.
    ///   - properties: The packet's properties.
    @inlinable
    @_lifetime(copy properties)
    public init(reasonCode: MQTTReasonCode = .normalDisconnection, properties: consuming MQTTProperties = MQTTProperties()) {
        self.reasonCode = reasonCode
        self.properties = properties
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout BytesReader) throws(MQTTError) {
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
    /// Success, Continue Authentication, or Re-authenticate.
    public var reasonCode: MQTTReasonCode
    /// The packet's properties: Authentication Method and Data, a Reason String, and User Properties.
    public var properties: MQTTProperties

    /// Creates an AUTH.
    ///
    /// - Parameters:
    ///   - reasonCode: The step's status.
    ///   - properties: The packet's properties.
    @inlinable
    @_lifetime(copy properties)
    public init(reasonCode: MQTTReasonCode = .success, properties: consuming MQTTProperties = MQTTProperties()) {
        self.reasonCode = reasonCode
        self.properties = properties
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    init(reading body: inout BytesReader) throws(MQTTError) {
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
