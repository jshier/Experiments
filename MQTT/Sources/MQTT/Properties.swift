public import Bytes

/// A property: optional metadata most packets carry (MQTT 5.0 section 2.2.2). Strings and binary data view
/// the packet's bytes.
public enum MQTTProperty: ~Escapable {
    case payloadFormatIndicator(UInt8)
    case messageExpiryInterval(UInt32)
    case contentType(UTF8Span)
    case responseTopic(UTF8Span)
    case correlationData(RawSpan)
    case subscriptionIdentifier(UInt32)
    case sessionExpiryInterval(UInt32)
    case assignedClientIdentifier(UTF8Span)
    case serverKeepAlive(UInt16)
    case authenticationMethod(UTF8Span)
    case authenticationData(RawSpan)
    case requestProblemInformation(UInt8)
    case willDelayInterval(UInt32)
    case requestResponseInformation(UInt8)
    case responseInformation(UTF8Span)
    case serverReference(UTF8Span)
    case reasonString(UTF8Span)
    case receiveMaximum(UInt16)
    case topicAliasMaximum(UInt16)
    case topicAlias(UInt16)
    case maximumQoS(UInt8)
    case retainAvailable(UInt8)
    case userProperty(name: UTF8Span, value: UTF8Span)
    case maximumPacketSize(UInt32)
    case wildcardSubscriptionAvailable(UInt8)
    case subscriptionIdentifierAvailable(UInt8)
    case sharedSubscriptionAvailable(UInt8)

    /// Reads one property: its identifier (a Variable Byte Integer), then a value of that property's type.
    ///
    /// Checked, it validates the encoding: minimal Variable Byte Integers, UTF-8 without U+0000. Unchecked,
    /// it trusts a list that was checked before, which makes iterating cheaper.
    @inlinable @inline(__always)
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    static func read(from reader: inout Bytes, checked: Bool) throws(BytesError) -> MQTTProperty {
        let identifier = checked ? try reader.readMQTTVariableByteInteger() : try reader.read(LEB128.self, maxByteCount: 4)
        return try read(identifier, from: &reader, checked: checked)
    }

    /// Reads the value of the property `identifier`, which has been read.
    @inlinable @inline(__always)
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    static func read(_ identifier: UInt64, from reader: inout Bytes, checked: Bool) throws(BytesError) -> MQTTProperty {
        switch identifier {
        case 0x01: .payloadFormatIndicator(try reader.read(Byte.self).rawValue)
        case 0x02: .messageExpiryInterval(try reader.read(Byte4.self, .bigEndian))
        case 0x03: .contentType(try reader.readMQTTText(checked: checked))
        case 0x08: .responseTopic(try reader.readMQTTText(checked: checked))
        case 0x09: .correlationData(try reader.read(bytesPrefixedBy: Byte2.self, .bigEndian))
        case 0x0B:
            .subscriptionIdentifier(UInt32(
                checked ? try reader.readMQTTVariableByteInteger() : try reader.read(LEB128.self, maxByteCount: 4)
            ))
        case 0x11: .sessionExpiryInterval(try reader.read(Byte4.self, .bigEndian))
        case 0x12: .assignedClientIdentifier(try reader.readMQTTText(checked: checked))
        case 0x13: .serverKeepAlive(try reader.read(Byte2.self, .bigEndian))
        case 0x15: .authenticationMethod(try reader.readMQTTText(checked: checked))
        case 0x16: .authenticationData(try reader.read(bytesPrefixedBy: Byte2.self, .bigEndian))
        case 0x17: .requestProblemInformation(try reader.read(Byte.self).rawValue)
        case 0x18: .willDelayInterval(try reader.read(Byte4.self, .bigEndian))
        case 0x19: .requestResponseInformation(try reader.read(Byte.self).rawValue)
        case 0x1A: .responseInformation(try reader.readMQTTText(checked: checked))
        case 0x1C: .serverReference(try reader.readMQTTText(checked: checked))
        case 0x1F: .reasonString(try reader.readMQTTText(checked: checked))
        case 0x21: .receiveMaximum(try reader.read(Byte2.self, .bigEndian))
        case 0x22: .topicAliasMaximum(try reader.read(Byte2.self, .bigEndian))
        case 0x23: .topicAlias(try reader.read(Byte2.self, .bigEndian))
        case 0x24: .maximumQoS(try reader.read(Byte.self).rawValue)
        case 0x25: .retainAvailable(try reader.read(Byte.self).rawValue)
        case 0x26:
            .userProperty(name: try reader.readMQTTText(checked: checked), value: try reader.readMQTTText(checked: checked))
        case 0x27: .maximumPacketSize(try reader.read(Byte4.self, .bigEndian))
        case 0x28: .wildcardSubscriptionAvailable(try reader.read(Byte.self).rawValue)
        case 0x29: .subscriptionIdentifierAvailable(try reader.read(Byte.self).rawValue)
        case 0x2A: .sharedSubscriptionAvailable(try reader.read(Byte.self).rawValue)
        default: throw .invalidValue
        }
    }

    /// Throws a protocol error for a value the spec forbids: a zero Topic Alias, Subscription Identifier,
    /// Receive Maximum, or Maximum Packet Size, or a flag other than 0 or 1. Only these properties
    /// (``PropertySet/valueChecked``) need it.
    @inlinable
    func checkValue() throws(MQTTError) {
        switch self {
        case .topicAlias(let value), .receiveMaximum(let value):
            guard value != 0 else { throw .protocolError("property value 0") }
        case .subscriptionIdentifier(let value), .maximumPacketSize(let value):
            guard value != 0 else { throw .protocolError("property value 0") }
        case .maximumQoS(let value), .retainAvailable(let value), .wildcardSubscriptionAvailable(let value),
             .subscriptionIdentifierAvailable(let value), .sharedSubscriptionAvailable(let value),
             .requestProblemInformation(let value), .requestResponseInformation(let value):
            guard value <= 1 else { throw .protocolError("property flag other than 0 or 1") }
        default:
            break
        }
    }
}

/// A set of property identifiers, as bits: every identifier is below 64. Used for which properties a packet
/// may carry (the table in section 2.2.2.2), which ones a list has, and which may repeat. The constants are
/// literals, so checks against them are an AND each.
@usableFromInline
struct PropertySet {
    @usableFromInline var bits: UInt64

    @inlinable @inline(__always)
    init(bits: UInt64) { self.bits = bits }

    @inlinable @inline(__always)
    func contains(_ identifier: UInt64) -> Bool { identifier < 64 && bits &>> identifier & 1 != 0 }

    @inlinable @inline(__always)
    func isSubset(of other: Self) -> Bool { bits & ~other.bits == 0 }

    @inlinable static var none: Self { Self(bits: 0) }
    @inlinable static var all: Self { Self(bits: ~0) }
    /// 0x11, 0x15, 0x16, 0x17, 0x19, 0x21, 0x22, 0x26, 0x27.
    @inlinable static var connect: Self { Self(bits: 0xC6_02E2_0000) }
    /// 0x01, 0x02, 0x03, 0x08, 0x09, 0x18, 0x26.
    @inlinable static var will: Self { Self(bits: 0x40_0100_030E) }
    /// 0x11, 0x12, 0x13, 0x15, 0x16, 0x1A, 0x1C, 0x1F, 0x21, 0x22, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A.
    @inlinable static var connectAcknowledgement: Self { Self(bits: 0x7F6_946E_0000) }
    /// 0x01, 0x02, 0x03, 0x08, 0x09, 0x0B, 0x23, 0x26.
    @inlinable static var publish: Self { Self(bits: 0x48_0000_0B0E) }
    /// PUBACK through PUBCOMP, SUBACK, and UNSUBACK: 0x1F, 0x26.
    @inlinable static var acknowledgement: Self { Self(bits: 0x40_8000_0000) }
    /// 0x0B, 0x26.
    @inlinable static var subscribe: Self { Self(bits: 0x40_0000_0800) }
    /// 0x26.
    @inlinable static var unsubscribe: Self { Self(bits: 0x40_0000_0000) }
    /// 0x11, 0x1C, 0x1F, 0x26.
    @inlinable static var disconnect: Self { Self(bits: 0x40_9002_0000) }
    /// 0x15, 0x16, 0x1F, 0x26.
    @inlinable static var authenticate: Self { Self(bits: 0x40_8060_0000) }

    /// User Property may always repeat (0x26), and Subscription Identifier in a PUBLISH (0x0B).
    @inlinable static var repeatable: Self { Self(bits: 0x40_0000_0000) }
    @inlinable static var repeatableInPublish: Self { Self(bits: 0x40_0000_0800) }

    /// The properties with value rules (see ``MQTTProperty/checkValue()``): 0x0B, 0x17, 0x19, 0x21, 0x23,
    /// 0x24, 0x25, 0x27, 0x28, 0x29, 0x2A.
    @inlinable static var valueChecked: Self { Self(bits: 0x7BA_0280_0800) }
}

extension BytesWriter {
    /// Writes `property`: its identifier, then its value. Build a property list in a buffer this way, then
    /// view it with ``MQTTProperties/init(validating:)``.
    @inlinable
    @_lifetime(self: copy self)
    public mutating func write(_ property: borrowing MQTTProperty) throws(BytesError) {
        switch property {
        case .payloadFormatIndicator(let value): try writeProperty(0x01, byte: value)
        case .messageExpiryInterval(let value): try writeProperty(0x02, four: value)
        case .contentType(let value): try writeProperty(0x03, string: value)
        case .responseTopic(let value): try writeProperty(0x08, string: value)
        case .correlationData(let value): try writeProperty(0x09, binary: value)
        case .subscriptionIdentifier(let value):
            try write(UInt64(0x0B), as: LEB128.self)
            try write(UInt64(value), as: LEB128.self)
        case .sessionExpiryInterval(let value): try writeProperty(0x11, four: value)
        case .assignedClientIdentifier(let value): try writeProperty(0x12, string: value)
        case .serverKeepAlive(let value): try writeProperty(0x13, two: value)
        case .authenticationMethod(let value): try writeProperty(0x15, string: value)
        case .authenticationData(let value): try writeProperty(0x16, binary: value)
        case .requestProblemInformation(let value): try writeProperty(0x17, byte: value)
        case .willDelayInterval(let value): try writeProperty(0x18, four: value)
        case .requestResponseInformation(let value): try writeProperty(0x19, byte: value)
        case .responseInformation(let value): try writeProperty(0x1A, string: value)
        case .serverReference(let value): try writeProperty(0x1C, string: value)
        case .reasonString(let value): try writeProperty(0x1F, string: value)
        case .receiveMaximum(let value): try writeProperty(0x21, two: value)
        case .topicAliasMaximum(let value): try writeProperty(0x22, two: value)
        case .topicAlias(let value): try writeProperty(0x23, two: value)
        case .maximumQoS(let value): try writeProperty(0x24, byte: value)
        case .retainAvailable(let value): try writeProperty(0x25, byte: value)
        case .userProperty(let name, let value):
            try writeProperty(0x26, string: name)
            try writeMQTTString(value)
        case .maximumPacketSize(let value): try writeProperty(0x27, four: value)
        case .wildcardSubscriptionAvailable(let value): try writeProperty(0x28, byte: value)
        case .subscriptionIdentifierAvailable(let value): try writeProperty(0x29, byte: value)
        case .sharedSubscriptionAvailable(let value): try writeProperty(0x2A, byte: value)
        }
    }

    // Every defined identifier is below 128, so it's a one-byte Variable Byte Integer.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: UInt8, byte value: UInt8) throws(BytesError) {
        try write(Byte(identifier))
        try write(Byte(value))
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: UInt8, two value: UInt16) throws(BytesError) {
        try write(Byte(identifier))
        try write(value, as: Byte2.self, .bigEndian)
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: UInt8, four value: UInt32) throws(BytesError) {
        try write(Byte(identifier))
        try write(value, as: Byte4.self, .bigEndian)
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: UInt8, string value: UTF8Span) throws(BytesError) {
        try write(Byte(identifier))
        try writeMQTTString(value)
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: UInt8, binary value: RawSpan) throws(BytesError) {
        try write(Byte(identifier))
        try writeMQTTBinary(value)
    }
}

/// A packet's property list: a view of the encoded properties, checked once when parsed and decoded on
/// each iteration, without allocating.
///
/// ```swift
/// publish.properties.forEach { property in
///     if case .messageExpiryInterval(let seconds) = property { … }
/// }
/// ```
public struct MQTTProperties: ~Escapable {
    /// The encoded properties, without their length.
    public let bytes: RawSpan
    /// The identifiers present.
    @usableFromInline let identifiers: PropertySet

    /// An empty list.
    @inlinable
    @_lifetime(immortal)
    public init() {
        bytes = RawSpan()
        identifiers = .none
    }

    /// Views encoded properties (without a length prefix), checking that each is well-formed and has a valid
    /// value, and that only User Property and Subscription Identifier repeat. Writing a packet checks that
    /// it may carry them.
    @inlinable
    @_lifetime(copy bytes)
    public init(validating bytes: RawSpan) throws(MQTTError) {
        try self.init(validating: bytes, allowing: .all, repeatable: .repeatableInPublish)
    }

    /// Views encoded properties, checking them as ``init(validating:)`` does, and that each is `allowed`
    /// (malformed otherwise) and appears once unless `repeatable` (a protocol error otherwise).
    @inlinable
    @_lifetime(copy bytes)
    init(validating bytes: RawSpan, allowing allowed: PropertySet, repeatable: PropertySet) throws(MQTTError) {
        var reader = Bytes(bytes)
        var seen = PropertySet.none
        while !reader.isAtEnd {
            let identifier: UInt64
            do throws(BytesError) { identifier = try reader.readMQTTVariableByteInteger() } catch { throw .malformed("property") }
            // An unknown identifier is in no packet's set, so it's malformed too.
            guard allowed.contains(identifier) else { throw .malformed("property not allowed in this packet") }
            guard !seen.contains(identifier) || repeatable.contains(identifier) else { throw .protocolError("duplicate property") }
            seen.bits |= 1 &<< identifier
            let property: MQTTProperty
            do throws(BytesError) {
                property = try MQTTProperty.read(identifier, from: &reader, checked: true)
            } catch {
                throw .malformed("property")
            }
            if PropertySet.valueChecked.contains(identifier) { try property.checkValue() }
        }
        // Authentication Data needs an Authentication Method.
        guard !seen.contains(0x16) || seen.contains(0x15) else { throw .protocolError("authentication data without a method") }
        self.bytes = bytes
        identifiers = seen
    }

    /// Reads a property list for a packet: its length (a minimal Variable Byte Integer), then properties
    /// checked as ``init(validating:allowing:repeatable:)`` does.
    @inlinable
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    init(reading reader: inout Bytes, allowing allowed: PropertySet, repeatable: PropertySet = .repeatable) throws(MQTTError) {
        let bytes: RawSpan
        do throws(BytesError) {
            let length = try reader.readMQTTVariableByteInteger()
            bytes = try reader.read(byteCount: Int(length))
        } catch {
            throw .malformed("property length")
        }
        try self.init(validating: bytes, allowing: allowed, repeatable: repeatable)
    }

    /// Whether there are no properties.
    @inlinable
    public var isEmpty: Bool { bytes.byteCount == 0 }

    /// Calls `body` with each property, in order.
    @inlinable
    public func forEach<E: Error>(_ body: (borrowing MQTTProperty) throws(E) -> Void) throws(E) {
        var reader = Bytes(bytes)
        while !reader.isAtEnd {
            // Checked when the list was created, so reading can't fail, and needn't check again.
            try body(try! MQTTProperty.read(from: &reader, checked: false))
        }
    }

    /// Throws ``MQTTError`` unless every property is allowed in a packet that allows `allowed`.
    @inlinable
    func check(allowing allowed: PropertySet) throws(MQTTError) {
        guard identifiers.isSubset(of: allowed) else { throw .malformed("property not allowed in this packet") }
    }

    /// The encoded size, including the length.
    @inlinable
    var encodedByteCount: Int { Size.lengthPrefixed(bytes.byteCount) }
}

extension BytesWriter {
    /// Writes a property list: its length, then the properties.
    @inlinable
    @_lifetime(self: copy self)
    public mutating func write(_ properties: borrowing MQTTProperties) throws(BytesError) {
        try write(properties.bytes, prefixedBy: LEB128.self)
    }
}
