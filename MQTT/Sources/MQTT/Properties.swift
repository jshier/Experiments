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
    @inlinable
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    static func read(from reader: inout Bytes) throws(BytesError) -> MQTTProperty {
        switch try reader.read(LEB128.self, maxByteCount: 4) {
        case 0x01: .payloadFormatIndicator(try reader.read(Byte.self).rawValue)
        case 0x02: .messageExpiryInterval(try reader.read(Byte4.self, .bigEndian))
        case 0x03: .contentType(try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian))
        case 0x08: .responseTopic(try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian))
        case 0x09: .correlationData(try reader.read(bytesPrefixedBy: Byte2.self, .bigEndian))
        case 0x0B: .subscriptionIdentifier(UInt32(try reader.read(LEB128.self, maxByteCount: 4)))
        case 0x11: .sessionExpiryInterval(try reader.read(Byte4.self, .bigEndian))
        case 0x12: .assignedClientIdentifier(try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian))
        case 0x13: .serverKeepAlive(try reader.read(Byte2.self, .bigEndian))
        case 0x15: .authenticationMethod(try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian))
        case 0x16: .authenticationData(try reader.read(bytesPrefixedBy: Byte2.self, .bigEndian))
        case 0x17: .requestProblemInformation(try reader.read(Byte.self).rawValue)
        case 0x18: .willDelayInterval(try reader.read(Byte4.self, .bigEndian))
        case 0x19: .requestResponseInformation(try reader.read(Byte.self).rawValue)
        case 0x1A: .responseInformation(try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian))
        case 0x1C: .serverReference(try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian))
        case 0x1F: .reasonString(try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian))
        case 0x21: .receiveMaximum(try reader.read(Byte2.self, .bigEndian))
        case 0x22: .topicAliasMaximum(try reader.read(Byte2.self, .bigEndian))
        case 0x23: .topicAlias(try reader.read(Byte2.self, .bigEndian))
        case 0x24: .maximumQoS(try reader.read(Byte.self).rawValue)
        case 0x25: .retainAvailable(try reader.read(Byte.self).rawValue)
        case 0x26:
            .userProperty(
                name: try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian),
                value: try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian)
            )
        case 0x27: .maximumPacketSize(try reader.read(Byte4.self, .bigEndian))
        case 0x28: .wildcardSubscriptionAvailable(try reader.read(Byte.self).rawValue)
        case 0x29: .subscriptionIdentifierAvailable(try reader.read(Byte.self).rawValue)
        case 0x2A: .sharedSubscriptionAvailable(try reader.read(Byte.self).rawValue)
        default: throw .invalidValue
        }
    }
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

    /// An empty list.
    @inlinable
    @_lifetime(immortal)
    public init() {
        bytes = RawSpan()
    }

    /// Views encoded properties (without a length prefix), checking that every property is well-formed.
    @inlinable
    @_lifetime(copy bytes)
    public init(validating bytes: RawSpan) throws(MQTTError) {
        var reader = Bytes(bytes)
        while !reader.isAtEnd {
            do throws(BytesError) { _ = try MQTTProperty.read(from: &reader) } catch { throw error.malformed("property") }
        }
        self.bytes = bytes
    }

    /// Reads a property list: its length (a Variable Byte Integer), then the properties.
    @inlinable
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    init(reading reader: inout Bytes) throws(MQTTError) {
        let bytes: RawSpan
        do throws(BytesError) {
            bytes = try reader.read(bytesPrefixedBy: LEB128.self, maxByteCount: 4)
        } catch {
            throw error.malformed("property length")
        }
        try self.init(validating: bytes)
    }

    /// Whether there are no properties.
    @inlinable
    public var isEmpty: Bool { bytes.byteCount == 0 }

    /// Calls `body` with each property, in order.
    @inlinable
    public func forEach<E: Error>(_ body: (borrowing MQTTProperty) throws(E) -> Void) throws(E) {
        var reader = Bytes(bytes)
        while !reader.isAtEnd {
            // Checked when the list was created, so reading can't fail.
            try body(try! MQTTProperty.read(from: &reader))
        }
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
