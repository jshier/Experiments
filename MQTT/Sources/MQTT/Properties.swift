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
    static func read(from reader: inout BytesReader, checked: Bool) throws(BytesError) -> MQTTProperty {
        let identifier = checked ? try reader.readMQTTVariableByteInteger() : try reader.read(LEB128.self, maxByteCount: 4)
        return try read(identifier, from: &reader, checked: checked)
    }

    /// Reads the value of the property `identifier`, which has been read.
    @inlinable @inline(__always)
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    static func read(_ identifier: UInt64, from reader: inout BytesReader, checked: Bool) throws(BytesError) -> MQTTProperty {
        switch identifier {
        case 0x01: try .payloadFormatIndicator(reader.read(Byte.self).rawValue)
        case 0x02: try .messageExpiryInterval(reader.read(Byte4.self, .bigEndian))
        case 0x03: try .contentType(reader.readMQTTText(checked: checked))
        case 0x08: try .responseTopic(reader.readMQTTText(checked: checked))
        case 0x09: try .correlationData(reader.read(bytesPrefixedBy: Byte2.self, .bigEndian))
        case 0x0B:
            try .subscriptionIdentifier(UInt32(
                checked ? reader.readMQTTVariableByteInteger() : reader.read(LEB128.self, maxByteCount: 4)
            ))
        case 0x11: try .sessionExpiryInterval(reader.read(Byte4.self, .bigEndian))
        case 0x12: try .assignedClientIdentifier(reader.readMQTTText(checked: checked))
        case 0x13: try .serverKeepAlive(reader.read(Byte2.self, .bigEndian))
        case 0x15: try .authenticationMethod(reader.readMQTTText(checked: checked))
        case 0x16: try .authenticationData(reader.read(bytesPrefixedBy: Byte2.self, .bigEndian))
        case 0x17: try .requestProblemInformation(reader.read(Byte.self).rawValue)
        case 0x18: try .willDelayInterval(reader.read(Byte4.self, .bigEndian))
        case 0x19: try .requestResponseInformation(reader.read(Byte.self).rawValue)
        case 0x1A: try .responseInformation(reader.readMQTTText(checked: checked))
        case 0x1C: try .serverReference(reader.readMQTTText(checked: checked))
        case 0x1F: try .reasonString(reader.readMQTTText(checked: checked))
        case 0x21: try .receiveMaximum(reader.read(Byte2.self, .bigEndian))
        case 0x22: try .topicAliasMaximum(reader.read(Byte2.self, .bigEndian))
        case 0x23: try .topicAlias(reader.read(Byte2.self, .bigEndian))
        case 0x24: try .maximumQoS(reader.read(Byte.self).rawValue)
        case 0x25: try .retainAvailable(reader.read(Byte.self).rawValue)
        case 0x26:
            try .userProperty(name: reader.readMQTTText(checked: checked), value: reader.readMQTTText(checked: checked))
        case 0x27: try .maximumPacketSize(reader.read(Byte4.self, .bigEndian))
        case 0x28: try .wildcardSubscriptionAvailable(reader.read(Byte.self).rawValue)
        case 0x29: try .subscriptionIdentifierAvailable(reader.read(Byte.self).rawValue)
        case 0x2A: try .sharedSubscriptionAvailable(reader.read(Byte.self).rawValue)
        default: throw .invalidValue
        }
    }

    /// Throws a protocol error for a value the spec forbids: a zero Topic Alias, Subscription Identifier,
    /// Receive Maximum, or Maximum Packet Size, or a flag other than 0 or 1. Only these properties
    /// (``PropertySet/valueChecked``) need it.
    @inlinable
    func checkValue() throws(MQTTError) {
        switch self {
        case let .topicAlias(value), let .receiveMaximum(value):
            guard value != 0 else { throw .protocolError("property value 0") }
        case let .subscriptionIdentifier(value), let .maximumPacketSize(value):
            guard value != 0 else { throw .protocolError("property value 0") }
        case let .maximumQoS(value), let .retainAvailable(value), let .wildcardSubscriptionAvailable(value),
             let .subscriptionIdentifierAvailable(value), let .sharedSubscriptionAvailable(value),
             let .requestProblemInformation(value), let .requestResponseInformation(value):
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
    func contains(_ identifier: UInt64) -> Bool { identifier < 64 && bits[bit: Int(identifier)] }

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
        case let .payloadFormatIndicator(value): try writeProperty(0x01, byte: value)
        case let .messageExpiryInterval(value): try writeProperty(0x02, four: value)
        case let .contentType(value): try writeProperty(0x03, string: value)
        case let .responseTopic(value): try writeProperty(0x08, string: value)
        case let .correlationData(value): try writeProperty(0x09, binary: value)
        case let .subscriptionIdentifier(value):
            try write(UInt64(0x0B), as: LEB128.self)
            try write(UInt64(value), as: LEB128.self)
        case let .sessionExpiryInterval(value): try writeProperty(0x11, four: value)
        case let .assignedClientIdentifier(value): try writeProperty(0x12, string: value)
        case let .serverKeepAlive(value): try writeProperty(0x13, two: value)
        case let .authenticationMethod(value): try writeProperty(0x15, string: value)
        case let .authenticationData(value): try writeProperty(0x16, binary: value)
        case let .requestProblemInformation(value): try writeProperty(0x17, byte: value)
        case let .willDelayInterval(value): try writeProperty(0x18, four: value)
        case let .requestResponseInformation(value): try writeProperty(0x19, byte: value)
        case let .responseInformation(value): try writeProperty(0x1A, string: value)
        case let .serverReference(value): try writeProperty(0x1C, string: value)
        case let .reasonString(value): try writeProperty(0x1F, string: value)
        case let .receiveMaximum(value): try writeProperty(0x21, two: value)
        case let .topicAliasMaximum(value): try writeProperty(0x22, two: value)
        case let .topicAlias(value): try writeProperty(0x23, two: value)
        case let .maximumQoS(value): try writeProperty(0x24, byte: value)
        case let .retainAvailable(value): try writeProperty(0x25, byte: value)
        case let .userProperty(name, value):
            try writeProperty(0x26, string: name)
            try writeMQTTString(value)
        case let .maximumPacketSize(value): try writeProperty(0x27, four: value)
        case let .wildcardSubscriptionAvailable(value): try writeProperty(0x28, byte: value)
        case let .subscriptionIdentifierAvailable(value): try writeProperty(0x29, byte: value)
        case let .sharedSubscriptionAvailable(value): try writeProperty(0x2A, byte: value)
        }
    }

    // Every defined identifier is below 128, so it's a one-byte Variable Byte Integer.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: Byte, byte value: UInt8) throws(BytesError) {
        try write(identifier)
        try write(Byte(value))
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: Byte, two value: UInt16) throws(BytesError) {
        try write(identifier)
        try write(value, as: Byte2.self, .bigEndian)
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: Byte, four value: UInt32) throws(BytesError) {
        try write(identifier)
        try write(value, as: Byte4.self, .bigEndian)
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: Byte, string value: UTF8Span) throws(BytesError) {
        try write(identifier)
        try writeMQTTString(value)
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeProperty(_ identifier: Byte, binary value: RawSpan) throws(BytesError) {
        try write(identifier)
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
        var reader = BytesReader(bytes)
        var seen = PropertySet.none
        while !reader.isAtEnd {
            let identifier: UInt64
            do throws(BytesError) { identifier = try reader.readMQTTVariableByteInteger() } catch { throw .malformed("property") }
            // An unknown identifier is in no packet's set, so it's malformed too.
            guard allowed.contains(identifier) else { throw .malformed("property not allowed in this packet") }
            guard !seen.contains(identifier) || repeatable.contains(identifier) else { throw .protocolError("duplicate property") }
            seen.bits[bit: Int(identifier)] = true
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
    init(reading reader: inout BytesReader, allowing allowed: PropertySet, repeatable: PropertySet = .repeatable) throws(MQTTError) {
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
        var reader = BytesReader(bytes)
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

public extension BytesWriter {
    /// Writes a property list: its length, then the properties.
    @inlinable
    @_lifetime(self: copy self)
    mutating func write(_ properties: borrowing MQTTProperties) throws(BytesError) {
        try write(properties.bytes, prefixedBy: LEB128.self)
    }
}
