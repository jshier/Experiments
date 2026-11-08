public import Bytes

// MARK: - Errors

/// Why a packet couldn't be parsed or encoded, and the reason code to end the connection with: in a
/// CONNACK if the error is in a CONNECT, otherwise in a DISCONNECT.
public struct MQTTError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        /// The bytes don't follow the packet format (reason code 0x81).
        case malformedPacket
        /// The packet is well-formed but breaks a protocol rule (0x82).
        case protocolError
        /// The packet is larger than the maximum packet size (0x95).
        case packetTooLarge
        /// A CONNECT for a protocol other than MQTT 5.0 (0x84).
        case unsupportedProtocolVersion
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

    /// The reason code for `kind`.
    @inlinable
    public var reasonCode: MQTTReasonCode {
        switch kind {
        case .malformedPacket: .malformedPacket
        case .protocolError: .protocolError
        case .packetTooLarge: .packetTooLarge
        case .unsupportedProtocolVersion: .unsupportedProtocolVersion
        }
    }

    public var description: String {
        let kind = switch kind {
        case .malformedPacket: "Malformed packet"
        case .protocolError: "Protocol error"
        case .packetTooLarge: "Packet too large"
        case .unsupportedProtocolVersion: "Unsupported protocol version"
        }
        return "\(kind): \(detail)"
    }

    // By the detail's bytes, without building `String`s. Unsafe: `StaticString` exposes its bytes only as a
    // buffer pointer. Safe: they're immutable static data, read only within the closure.
    public static func ==(lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.detail.withUTF8Buffer { a in rhs.detail.withUTF8Buffer { b in unsafe a.elementsEqual(b) } }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        detail.withUTF8Buffer { unsafe hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
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

    public static func <(lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A reason code: the outcome of an operation, 0x80 and above for failures. Each packet type allows a
/// different subset, which parsing and encoding check.
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
    public static let serverShuttingDown = Self(rawValue: 0x8B)
    public static let badAuthenticationMethod = Self(rawValue: 0x8C)
    public static let keepAliveTimeout = Self(rawValue: 0x8D)
    public static let sessionTakenOver = Self(rawValue: 0x8E)
    public static let topicFilterInvalid = Self(rawValue: 0x8F)
    public static let topicNameInvalid = Self(rawValue: 0x90)
    public static let packetIdentifierInUse = Self(rawValue: 0x91)
    public static let packetIdentifierNotFound = Self(rawValue: 0x92)
    public static let receiveMaximumExceeded = Self(rawValue: 0x93)
    public static let topicAliasInvalid = Self(rawValue: 0x94)
    public static let packetTooLarge = Self(rawValue: 0x95)
    public static let messageRateTooHigh = Self(rawValue: 0x96)
    public static let quotaExceeded = Self(rawValue: 0x97)
    public static let administrativeAction = Self(rawValue: 0x98)
    public static let payloadFormatInvalid = Self(rawValue: 0x99)
    public static let retainNotSupported = Self(rawValue: 0x9A)
    public static let qosNotSupported = Self(rawValue: 0x9B)
    public static let useAnotherServer = Self(rawValue: 0x9C)
    public static let serverMoved = Self(rawValue: 0x9D)
    public static let sharedSubscriptionsNotSupported = Self(rawValue: 0x9E)
    public static let connectionRateExceeded = Self(rawValue: 0x9F)
    public static let maximumConnectTime = Self(rawValue: 0xA0)
    public static let subscriptionIdentifiersNotSupported = Self(rawValue: 0xA1)
    public static let wildcardSubscriptionsNotSupported = Self(rawValue: 0xA2)
}

/// The reason codes one packet type allows (the tables in each packet's section of the spec), as bits:
/// every code is below 0x40 or in 0x80..<0xC0.
@usableFromInline
struct ReasonCodeSet {
    @usableFromInline let low: UInt64
    @usableFromInline let high: UInt64

    @inlinable @inline(__always)
    init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    @inlinable @inline(__always)
    func contains(_ code: MQTTReasonCode) -> Bool {
        let raw = UInt64(code.rawValue)
        return switch raw {
        case 0..<0x40: low &>> raw & 1 != 0
        case 0x80..<0xC0: high &>> (raw & 0x3F) & 1 != 0
        default: false
        }
    }

    // Literal masks, so a check is a shift and an AND; the codes are listed for each.

    /// 0x00, 0x80–0x8A, 0x8C, 0x90, 0x95, 0x97, 0x99–0x9D, 0x9F.
    @inlinable static var connectAcknowledgement: Self { Self(low: 0x1, high: 0xBEA1_17FF) }
    /// PUBACK and PUBREC: 0x00, 0x10, 0x80, 0x83, 0x87, 0x90, 0x91, 0x97, 0x99.
    @inlinable static var publishAcknowledgement: Self { Self(low: 0x1_0001, high: 0x283_0089) }
    /// PUBREL and PUBCOMP: 0x00, 0x92.
    @inlinable static var publishRelease: Self { Self(low: 0x1, high: 0x4_0000) }
    /// 0x00, 0x01, 0x02, 0x80, 0x83, 0x87, 0x8F, 0x91, 0x97, 0x9E, 0xA1, 0xA2.
    @inlinable static var subscribeAcknowledgement: Self { Self(low: 0x7, high: 0x6_4082_8089) }
    /// 0x00, 0x11, 0x80, 0x83, 0x87, 0x8F, 0x91.
    @inlinable static var unsubscribeAcknowledgement: Self { Self(low: 0x2_0001, high: 0x2_8089) }
    /// 0x00, 0x04, 0x80–0x83, 0x87, 0x89, 0x8B–0x90, 0x93–0xA2. (0x8C is listed for DISCONNECT in the
    /// spec's summary table, 2-6, but not in section 3.14.2.1; accepted.)
    @inlinable static var disconnect: Self { Self(low: 0x11, high: 0x7_FFF9_FA8F) }
    /// 0x00, 0x18, 0x19.
    @inlinable static var authenticate: Self { Self(low: 0x300_0001, high: 0) }
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
    /// Don't send the subscriber its own publications. Not allowed on a shared subscription.
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

    /// Reads the options byte, field by field, most significant bit first: 2 reserved bits (nonzero is
    /// malformed), retain handling (3 is a protocol error), retain as published, no local, and maximum QoS
    /// (3 is a protocol error).
    @inlinable
    @_lifetime(reader: copy reader)
    init(reading reader: inout BytesReader) throws(MQTTError) {
        let reserved: Crumb
        let retainHandling: Crumb
        let maximumQoS: Crumb
        do throws(BytesError) {
            reserved = try reader.read(Crumb.self)
            retainHandling = try reader.read(Crumb.self)
            retainAsPublished = try reader.read(Bit.self).isSet
            noLocal = try reader.read(Bit.self).isSet
            maximumQoS = try reader.read(Crumb.self)
        } catch {
            throw .malformed("subscription options")
        }
        guard reserved == 0 else { throw .malformed("reserved subscription option bits") }
        guard let handling = MQTTRetainHandling(rawBits: retainHandling) else { throw .protocolError("retain handling 3") }
        guard let qos = MQTTQoS(rawBits: maximumQoS) else { throw .protocolError("maximum QoS 3") }
        self.retainHandling = handling
        self.maximumQoS = qos
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
extension BytesReader {
    /// A UTF-8 Encoded String: a 2-byte big-endian length, then UTF-8 without U+0000 [MQTT-1.5.4-2].
    /// Unchecked, it trusts that the string was checked before: for iterating validated lists.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readMQTTText(checked: Bool) throws(BytesError) -> UTF8Span {
        guard checked else {
            // Unsafe: skips UTF-8 validation, which is what makes iterating a validated packet's string lists
            // cheap. Safe enough: only called on packets whose `validate()` already checked these strings, and
            // validation is a precondition of the unchecked iterators. No safe construct skips the check.
            return unsafe try UTF8Span(unchecked: Span(viewing: read(bytesPrefixedBy: Byte2.self, .bigEndian)))
        }
        // One pass for ASCII: UTF-8 and U+0000 checked together, 16 bytes at a time.
        return try read(utf8PrefixedBy: Byte2.self, .bigEndian, excluding: Text.null)
    }

    /// A UTF-8 Encoded String, throwing a malformed-packet error with `detail`.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readMQTTString(_ detail: StaticString) throws(MQTTError) -> UTF8Span {
        do throws(BytesError) { return try readMQTTText(checked: true) } catch { throw .malformed(detail) }
    }

    /// Binary Data: a 2-byte big-endian length, then bytes.
    @inlinable @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readMQTTBinary(_ detail: StaticString) throws(MQTTError) -> RawSpan {
        do throws(BytesError) { return try read(bytesPrefixedBy: Byte2.self, .bigEndian) } catch { throw .malformed(detail) }
    }

    /// A Two Byte Integer.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readMQTTUInt16(_ detail: StaticString) throws(MQTTError) -> UInt16 {
        do throws(BytesError) { return try read(Byte2.self, .bigEndian) } catch { throw .malformed(detail) }
    }

    /// A non-zero packet identifier [MQTT-2.2.1-3].
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readMQTTPacketIdentifier() throws(MQTTError) -> UInt16 {
        let identifier = try readMQTTUInt16("packet identifier")
        guard identifier != 0 else { throw .protocolError("packet identifier 0") }
        return identifier
    }

    /// A Byte.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readMQTTByte(_ detail: StaticString) throws(MQTTError) -> Byte {
        do throws(BytesError) { return try read(Byte.self) } catch { throw .malformed(detail) }
    }

    /// A reason code: a Byte, every value of which is representable (validity depends on the packet).
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readMQTTReasonCode() throws(MQTTError) -> MQTTReasonCode {
        do throws(BytesError) { return try read(MQTTReasonCode.self, as: Byte.self) } catch { throw .malformed("reason code") }
    }

    /// A Variable Byte Integer: LEB128 of at most 4 bytes, in the fewest bytes [MQTT-1.5.5-1]. Throws
    /// ``BytesError/invalidValue`` for a longer or padded encoding; consumes nothing if it throws.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func readMQTTVariableByteInteger() throws(BytesError) -> UInt64 {
        let start = byteOffset
        let value = try read(LEB128.self, maxByteCount: 4)
        let byteCount = byteOffset &- start
        guard byteCount == 1 || byteCount == LEB128.byteCount(of: value) else {
            try! seek(toByteOffset: start)
            throw .invalidValue
        }
        return value
    }

    /// Throws a malformed-packet error if bytes are left over.
    @inlinable @inline(__always)
    func expectMQTTEnd(_ detail: StaticString) throws(MQTTError) {
        do throws(BytesError) { try expectEnd() } catch { throw .malformed(detail) }
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

/// Checks on strings' contents, 16 bytes at a time (Bytes' `containsByte(where:)`): a typical 32-byte topic
/// is two vector tests, with no branches. Parsing checks a string's bytes with its UTF-8, in the same pass
/// (`read(utf8PrefixedBy:_:excluding:)`).
@usableFromInline
enum Text {
    /// U+0000, which MQTT strings can't contain [MQTT-1.5.4-2].
    @inlinable @inline(__always)
    static func null(_ lanes: ByteLanes) -> ByteMatches { lanes.matching(0) }

    /// A wildcard (`+` or `#`) or U+0000, which topic names can't contain [MQTT-3.3.2-2, MQTT-4.7.3-2].
    @inlinable @inline(__always)
    static func wildcardOrNull(_ lanes: ByteLanes) -> ByteMatches {
        lanes.matching(0) | lanes.matching(UInt8(ascii: "+")) | lanes.matching(UInt8(ascii: "#"))
    }

    /// Whether `text` contains U+0000.
    @inlinable
    static func containsNull(_ text: UTF8Span) -> Bool { text.span.bytes.containsByte(where: null) }

    /// Whether `text` contains a wildcard or U+0000.
    @inlinable
    static func containsWildcardOrNull(_ text: UTF8Span) -> Bool { text.span.bytes.containsByte(where: wildcardOrNull) }

    /// Whether `text` is longer than a 2-byte length can describe.
    @inlinable @inline(__always)
    static func isTooLong(_ count: Int) -> Bool { count > UInt16.max }

    /// Whether a topic filter names a shared subscription (`$share/…`).
    @inlinable
    static func isShared(_ filter: UTF8Span) -> Bool {
        let reader = BytesReader(filter.span)
        return (try? reader.peek(Byte7.self)) == 0x24_73_68_61_72_65_2F // "$share/"
    }
}
