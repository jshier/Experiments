public import Bytes

// MARK: - Errors

/// Why a packet couldn't be parsed. MQTT 5.0 distinguishes malformed packets (the bytes don't follow the
/// format) from protocol errors (well-formed, but not allowed), and a receiver closes the connection
/// with the matching reason code either way.
public struct MQTTError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        /// The bytes don't follow the packet format (reason code 0x81).
        case malformedPacket
        /// The packet is well-formed but breaks a protocol rule (reason code 0x82).
        case protocolError
    }

    public let kind: Kind
    /// What was wrong, for logs.
    public let detail: StaticString

    @inlinable
    public init(_ kind: Kind, _ detail: StaticString) {
        self.kind = kind
        self.detail = detail
    }

    @inlinable
    static func malformed(_ detail: StaticString) -> Self { Self(.malformedPacket, detail) }

    @inlinable
    static func protocolError(_ detail: StaticString) -> Self { Self(.protocolError, detail) }

    public var description: String {
        "\(kind == .malformedPacket ? "Malformed packet" : "Protocol error"): \(detail)"
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.detail.description == rhs.detail.description
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(detail.description)
    }
}

extension BytesError {
    /// Inside a complete packet, every read failure means the packet is malformed: a field runs past the
    /// packet's end, a string isn't UTF-8, a value is out of range, or bytes are left over.
    @inlinable
    func malformed(_ detail: StaticString) -> MQTTError { .malformed(detail) }
}

// MARK: - Packet types and fields

/// The control packet types, the high nibble of a packet's first byte.
public enum MQTTPacketType: UInt8, Sendable {
    case connect = 1
    case connectAcknowledgement
    case publish
    case publishAcknowledgement
    case publishReceived
    case publishRelease
    case publishComplete
    case subscribe
    case subscribeAcknowledgement
    case unsubscribe
    case unsubscribeAcknowledgement
    case pingRequest
    case pingResponse
    case disconnect
    case authenticate
}

/// A delivery guarantee.
public enum MQTTQoS: UInt8, Sendable, Comparable {
    case atMostOnce
    case atLeastOnce
    case exactlyOnce

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A reason code: the outcome of an operation, 0x80 and above for failures. Open-ended, since each packet
/// type allows a different subset.
public struct MQTTReasonCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Whether this is a failure (0x80 and above).
    @inlinable
    public var isFailure: Bool { rawValue >= 0x80 }

    public static let success = Self(rawValue: 0x00)
    public static let normalDisconnection = Self(rawValue: 0x00)
    public static let grantedQoS0 = Self(rawValue: 0x00)
    public static let grantedQoS1 = Self(rawValue: 0x01)
    public static let grantedQoS2 = Self(rawValue: 0x02)
    public static let disconnectWithWillMessage = Self(rawValue: 0x04)
    public static let noMatchingSubscribers = Self(rawValue: 0x10)
    public static let noSubscriptionExisted = Self(rawValue: 0x11)
    public static let continueAuthentication = Self(rawValue: 0x18)
    public static let reauthenticate = Self(rawValue: 0x19)
    public static let unspecifiedError = Self(rawValue: 0x80)
    public static let malformedPacket = Self(rawValue: 0x81)
    public static let protocolError = Self(rawValue: 0x82)
    public static let implementationSpecificError = Self(rawValue: 0x83)
    public static let unsupportedProtocolVersion = Self(rawValue: 0x84)
    public static let clientIdentifierNotValid = Self(rawValue: 0x85)
    public static let badUserNameOrPassword = Self(rawValue: 0x86)
    public static let notAuthorized = Self(rawValue: 0x87)
    public static let serverUnavailable = Self(rawValue: 0x88)
    public static let serverBusy = Self(rawValue: 0x89)
    public static let banned = Self(rawValue: 0x8A)
    public static let packetIdentifierInUse = Self(rawValue: 0x91)
    public static let packetIdentifierNotFound = Self(rawValue: 0x92)
    public static let packetTooLarge = Self(rawValue: 0x95)
    public static let quotaExceeded = Self(rawValue: 0x97)
    public static let topicNameInvalid = Self(rawValue: 0x90)
    public static let topicFilterInvalid = Self(rawValue: 0x8F)
}

/// When a server sends retained messages for a new subscription.
public enum MQTTRetainHandling: UInt8, Sendable {
    /// On every subscribe.
    case sendOnSubscribe
    /// Only when the subscription didn't already exist.
    case sendOnNewSubscribe
    /// Never.
    case doNotSend
}

/// A subscription's options byte.
public struct MQTTSubscriptionOptions: Hashable, Sendable {
    public var maximumQoS: MQTTQoS
    /// Don't send the subscriber its own publications.
    public var noLocal: Bool
    /// Keep the retain flag of forwarded messages as published.
    public var retainAsPublished: Bool
    public var retainHandling: MQTTRetainHandling

    @inlinable
    public init(
        maximumQoS: MQTTQoS, noLocal: Bool = false, retainAsPublished: Bool = false,
        retainHandling: MQTTRetainHandling = .sendOnSubscribe
    ) {
        self.maximumQoS = maximumQoS
        self.noLocal = noLocal
        self.retainAsPublished = retainAsPublished
        self.retainHandling = retainHandling
    }

    /// Reads the options byte, field by field, most significant bit first: 2 reserved bits (zero), retain
    /// handling (2 bits, 3 is invalid), retain as published, no local, maximum QoS (2 bits, 3 is invalid).
    @inlinable
    @_lifetime(reader: copy reader)
    init(reading reader: inout Bytes) throws(MQTTError) {
        do throws(BytesError) {
            try reader.expect(Crumb(0))
            retainHandling = try reader.read(MQTTRetainHandling.self, as: Crumb.self)
            retainAsPublished = try reader.read(Bit.self).isSet
            noLocal = try reader.read(Bit.self).isSet
            maximumQoS = try reader.read(MQTTQoS.self, as: Crumb.self)
        } catch {
            throw error.malformed("subscription options")
        }
    }

    @inlinable
    func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.write(Crumb(0))
        try writer.write(retainHandling, as: Crumb.self)
        try writer.write(Bit(retainAsPublished))
        try writer.write(Bit(noLocal))
        try writer.write(maximumQoS, as: Crumb.self)
    }
}

// MARK: - Field encodings

/// MQTT's data representations (section 1.5), on top of `Bytes`.
extension Bytes {
    /// A UTF-8 Encoded String: 2-byte big-endian length, then UTF-8.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readMQTTString(_ detail: StaticString) throws(MQTTError) -> UTF8Span {
        do throws(BytesError) { return try read(utf8PrefixedBy: Byte2.self, .bigEndian) } catch { throw error.malformed(detail) }
    }

    /// Binary Data: 2-byte big-endian length, then bytes.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readMQTTBinary(_ detail: StaticString) throws(MQTTError) -> RawSpan {
        do throws(BytesError) { return try read(bytesPrefixedBy: Byte2.self, .bigEndian) } catch { throw error.malformed(detail) }
    }

    /// A Two Byte Integer.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readMQTTUInt16(_ detail: StaticString) throws(MQTTError) -> UInt16 {
        do throws(BytesError) { return try read(Byte2.self, .bigEndian) } catch { throw error.malformed(detail) }
    }

    /// A single byte.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readMQTTByte(_ detail: StaticString) throws(MQTTError) -> UInt8 {
        do throws(BytesError) { return try read(Byte.self).rawValue } catch { throw error.malformed(detail) }
    }

    /// Throws a malformed-packet error if bytes are left over.
    @inlinable @inline(__always)
    func expectMQTTEnd(_ detail: StaticString) throws(MQTTError) {
        do throws(BytesError) { try expectEnd() } catch { throw error.malformed(detail) }
    }
}

extension BytesWriter {
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeMQTTString(_ text: UTF8Span) throws(BytesError) {
        try write(text, prefixedBy: Byte2.self, .bigEndian)
    }

    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeMQTTBinary(_ bytes: RawSpan) throws(BytesError) {
        try write(bytes, prefixedBy: Byte2.self, .bigEndian)
    }
}

/// Encoded sizes, for computing a packet's remaining length before writing it.
@usableFromInline
enum Size {
    @inlinable @inline(__always)
    static func string(_ text: UTF8Span) -> Int { 2 &+ text.count }

    @inlinable @inline(__always)
    static func binary(_ bytes: RawSpan) -> Int { 2 &+ bytes.byteCount }

    @inlinable @inline(__always)
    static func lengthPrefixed(_ count: Int) -> Int { LEB128.byteCount(of: UInt64(count)) &+ count }
}

/// Topic names can't contain the wildcards `+` and `#` (MQTT-3.3.2-2).
@inlinable
func containsWildcard(_ topic: UTF8Span) -> Bool {
    let bytes = topic.span
    for index in bytes.indices where bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "#") {
        return true
    }
    return false
}
