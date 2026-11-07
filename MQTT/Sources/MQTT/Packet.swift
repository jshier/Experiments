public import Bytes

/// An MQTT 5.0 control packet: a view of the bytes it was parsed from.
///
/// Read packets from a stream as bytes arrive. A packet that isn't complete yet is left unread, so you can
/// append more data and try again:
///
/// ```swift
/// var reader = Bytes(received.span)
/// while let packet = try MQTTPacket.read(from: &reader) {
///     switch packet {
///     case .publish(let publish): deliver(String(copying: publish.topic), publish.payload)
///     case .pingRequest: try send(.pingResponse)
///     default: break
///     }
/// }
/// received.removeFirst(reader.byteOffset) // Keep the partial packet, if any.
/// ```
///
/// Nothing is copied: topics and other strings are validated `UTF8Span`s, and payloads and binary fields are
/// spans of the input. Copy what you keep (`String(copying:)`, `Array(span)`).
public enum MQTTPacket: ~Escapable {
    case connect(MQTTConnect)
    case connectAcknowledgement(MQTTConnectAcknowledgement)
    case publish(MQTTPublish)
    case publishAcknowledgement(MQTTPublishResponse)
    case publishReceived(MQTTPublishResponse)
    case publishRelease(MQTTPublishResponse)
    case publishComplete(MQTTPublishResponse)
    case subscribe(MQTTSubscribe)
    case subscribeAcknowledgement(MQTTSubscribeAcknowledgement)
    case unsubscribe(MQTTUnsubscribe)
    case unsubscribeAcknowledgement(MQTTSubscribeAcknowledgement)
    case pingRequest
    case pingResponse
    case disconnect(MQTTReason)
    case authenticate(MQTTReason)

    /// The largest remaining length: 4 bytes of Variable Byte Integer.
    public static let maximumRemainingLength = 268_435_455

    /// Reads the next packet from `reader`, or returns `nil` without consuming anything if it isn't all there
    /// yet.
    ///
    /// Throws ``MQTTError`` for a malformed packet or a protocol error, leaving the cursor where it was. Both
    /// end the connection in MQTT, after sending a DISCONNECT with the matching reason code.
    ///
    /// - Parameter maximumPacketSize: The largest packet to accept, in bytes, such as the Maximum Packet
    ///   Size you advertised. A larger one throws a protocol error as soon as its header arrives.
    @inlinable
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    public static func read(from reader: inout Bytes, maximumPacketSize: Int = .max) throws(MQTTError) -> MQTTPacket? {
        let start = reader.byteOffset
        // The fixed header: type and flags (a nibble each), then the remaining length.
        let type: Nibble
        let flags: Nibble
        let remainingLength: Int
        do throws(BytesError) {
            type = try reader.read(Nibble.self)
            flags = try reader.read(Nibble.self)
            remainingLength = Int(try reader.read(LEB128.self, maxByteCount: 4))
        } catch {
            try! reader.seek(toByteOffset: start)
            if error == .insufficientData { return nil }
            throw .malformed("remaining length")
        }
        guard reader.byteOffset &- start &+ remainingLength <= maximumPacketSize else {
            try! reader.seek(toByteOffset: start)
            throw .protocolError("packet larger than the maximum packet size")
        }
        // The body, as its own cursor: every field read in it is bounded by the remaining length.
        guard var body = try? reader.read(section: remainingLength) else {
            try! reader.seek(toByteOffset: start)
            return nil
        }
        do throws(MQTTError) {
            return try parse(type: type, flags: flags, body: &body)
        } catch {
            try! reader.seek(toByteOffset: start)
            throw error
        }
    }

    @inlinable
    @_lifetime(copy body)
    @_lifetime(body: copy body)
    static func parse(type: Nibble, flags: Nibble, body: inout Bytes) throws(MQTTError) -> MQTTPacket {
        guard let packetType = MQTTPacketType(rawValue: type.rawValue) else { throw .malformed("reserved packet type") }
        // PUBLISH uses its flags; PUBREL, SUBSCRIBE, and UNSUBSCRIBE require 0b0010; the rest, 0.
        switch packetType {
        case .publish: break
        case .publishRelease, .subscribe, .unsubscribe:
            guard flags == 0b0010 else { throw .malformed("reserved flags") }
        default:
            guard flags == 0 else { throw .malformed("reserved flags") }
        }
        switch packetType {
        case .connect: return .connect(try MQTTConnect(reading: &body))
        case .connectAcknowledgement: return .connectAcknowledgement(try MQTTConnectAcknowledgement(reading: &body))
        case .publish: return .publish(try MQTTPublish(reading: &body, flags: flags))
        case .publishAcknowledgement: return .publishAcknowledgement(try MQTTPublishResponse(reading: &body))
        case .publishReceived: return .publishReceived(try MQTTPublishResponse(reading: &body))
        case .publishRelease: return .publishRelease(try MQTTPublishResponse(reading: &body))
        case .publishComplete: return .publishComplete(try MQTTPublishResponse(reading: &body))
        case .subscribe: return .subscribe(try MQTTSubscribe(reading: &body))
        case .subscribeAcknowledgement: return .subscribeAcknowledgement(try MQTTSubscribeAcknowledgement(reading: &body))
        case .unsubscribe: return .unsubscribe(try MQTTUnsubscribe(reading: &body))
        case .unsubscribeAcknowledgement: return .unsubscribeAcknowledgement(try MQTTSubscribeAcknowledgement(reading: &body))
        case .pingRequest:
            try body.expectMQTTEnd("ping request")
            return .pingRequest
        case .pingResponse:
            try body.expectMQTTEnd("ping response")
            return .pingResponse
        case .disconnect: return .disconnect(try MQTTReason(reading: &body))
        case .authenticate: return .authenticate(try MQTTReason(reading: &body))
        }
    }

    /// The packet's type.
    @inlinable
    public var type: MQTTPacketType {
        switch self {
        case .connect: .connect
        case .connectAcknowledgement: .connectAcknowledgement
        case .publish: .publish
        case .publishAcknowledgement: .publishAcknowledgement
        case .publishReceived: .publishReceived
        case .publishRelease: .publishRelease
        case .publishComplete: .publishComplete
        case .subscribe: .subscribe
        case .subscribeAcknowledgement: .subscribeAcknowledgement
        case .unsubscribe: .unsubscribe
        case .unsubscribeAcknowledgement: .unsubscribeAcknowledgement
        case .pingRequest: .pingRequest
        case .pingResponse: .pingResponse
        case .disconnect: .disconnect
        case .authenticate: .authenticate
        }
    }

    /// The fixed header's flags.
    @inlinable
    var flags: Nibble {
        switch self {
        case .publish(let publish): publish.flags
        case .publishRelease, .subscribe, .unsubscribe: 0b0010
        default: 0
        }
    }

    /// The size of everything after the fixed header.
    @inlinable
    public var remainingLength: Int {
        switch self {
        case .connect(let packet): packet.bodyByteCount
        case .connectAcknowledgement(let packet): packet.bodyByteCount
        case .publish(let packet): packet.bodyByteCount
        case .publishAcknowledgement(let packet), .publishReceived(let packet), .publishRelease(let packet),
             .publishComplete(let packet): packet.bodyByteCount
        case .subscribe(let packet): packet.bodyByteCount
        case .subscribeAcknowledgement(let packet), .unsubscribeAcknowledgement(let packet): packet.bodyByteCount
        case .unsubscribe(let packet): packet.bodyByteCount
        case .pingRequest, .pingResponse: 0
        case .disconnect(let packet), .authenticate(let packet): packet.bodyByteCount
        }
    }

    /// The packet's encoded size, for sizing a buffer.
    @inlinable
    public var encodedByteCount: Int { 1 &+ Size.lengthPrefixed(remainingLength) }

    /// Writes the packet. Its size is computed first, so nothing is moved or copied twice.
    ///
    /// Throws ``BytesError/insufficientCapacity`` if `writer` doesn't have ``encodedByteCount`` bytes left,
    /// and ``BytesError/invalidValue`` if a string or the packet is too long for MQTT.
    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        let remainingLength = remainingLength
        guard remainingLength <= Self.maximumRemainingLength else { throw .invalidValue }
        guard writer.remainingByteCount >= 1 &+ Size.lengthPrefixed(remainingLength) else { throw .insufficientCapacity }
        try writer.write(Nibble(type.rawValue))
        try writer.write(flags)
        try writer.write(UInt64(remainingLength), as: LEB128.self)
        switch self {
        case .connect(let packet): try packet.writeBody(to: &writer)
        case .connectAcknowledgement(let packet): try packet.writeBody(to: &writer)
        case .publish(let packet): try packet.writeBody(to: &writer)
        case .publishAcknowledgement(let packet), .publishReceived(let packet), .publishRelease(let packet),
             .publishComplete(let packet): try packet.writeBody(to: &writer)
        case .subscribe(let packet): try packet.writeBody(to: &writer)
        case .subscribeAcknowledgement(let packet), .unsubscribeAcknowledgement(let packet): try packet.writeBody(to: &writer)
        case .unsubscribe(let packet): try packet.writeBody(to: &writer)
        case .pingRequest, .pingResponse: break
        case .disconnect(let packet), .authenticate(let packet): try packet.writeBody(to: &writer)
        }
    }
}
