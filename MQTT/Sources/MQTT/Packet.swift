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
/// spans of the input. Copy what you keep (`String(copying:)`, `[UInt8](copying:)`).
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
    case unsubscribeAcknowledgement(MQTTUnsubscribeAcknowledgement)
    case pingRequest
    case pingResponse
    case disconnect(MQTTDisconnect)
    case authenticate(MQTTAuthenticate)

    /// The largest remaining length: 4 bytes of Variable Byte Integer.
    public static let maximumRemainingLength = 268_435_455

    /// Reads the next packet from `reader`, or returns `nil` without consuming anything if it isn't all there
    /// yet.
    ///
    /// Throws ``MQTTError`` if the packet breaks a rule of MQTT 5.0, leaving the cursor where it was. MQTT then
    /// ends the connection, sending the error's ``MQTTError/reasonCode`` in a DISCONNECT (or, for a CONNECT, a
    /// CONNACK).
    ///
    /// - Parameter maximumPacketSize: The largest packet to accept, in bytes, such as the Maximum Packet
    ///   Size you advertised. A larger one throws ``MQTTError/Kind/packetTooLarge`` as soon as its header
    ///   arrives.
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
            remainingLength = Int(try reader.readMQTTVariableByteInteger())
        } catch {
            try! reader.seek(toByteOffset: start)
            if error == .insufficientData { return nil }
            throw .malformed("remaining length")
        }
        guard reader.byteOffset &- start &+ remainingLength <= maximumPacketSize else {
            try! reader.seek(toByteOffset: start)
            throw MQTTError(.packetTooLarge, "packet larger than the maximum packet size")
        }
        // The body, as its own cursor: every field read in it is bounded by the remaining length.
        guard var body = try? reader.readSection(byteCount: remainingLength) else {
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
        guard let packetType = MQTTPacketType(rawBits: type) else { throw .malformed("reserved packet type") }
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
        case .publishAcknowledgement:
            return .publishAcknowledgement(try MQTTPublishResponse(reading: &body, reasonCodes: .publishAcknowledgement))
        case .publishReceived:
            return .publishReceived(try MQTTPublishResponse(reading: &body, reasonCodes: .publishAcknowledgement))
        case .publishRelease:
            return .publishRelease(try MQTTPublishResponse(reading: &body, reasonCodes: .publishRelease))
        case .publishComplete:
            return .publishComplete(try MQTTPublishResponse(reading: &body, reasonCodes: .publishRelease))
        case .subscribe: return .subscribe(try MQTTSubscribe(reading: &body))
        case .subscribeAcknowledgement:
            return .subscribeAcknowledgement(try MQTTSubscribeAcknowledgement(reading: &body, reasonCodes: .subscribeAcknowledgement))
        case .unsubscribe: return .unsubscribe(try MQTTUnsubscribe(reading: &body))
        case .unsubscribeAcknowledgement:
            return .unsubscribeAcknowledgement(try MQTTSubscribeAcknowledgement(reading: &body, reasonCodes: .unsubscribeAcknowledgement))
        case .pingRequest:
            try body.expectMQTTEnd("ping request")
            return .pingRequest
        case .pingResponse:
            try body.expectMQTTEnd("ping response")
            return .pingResponse
        case .disconnect: return .disconnect(try MQTTDisconnect(reading: &body))
        case .authenticate: return .authenticate(try MQTTAuthenticate(reading: &body))
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
        case .disconnect(let packet): packet.bodyByteCount
        case .authenticate(let packet): packet.bodyByteCount
        }
    }

    /// The packet's encoded size, for sizing a buffer.
    @inlinable
    public var encodedByteCount: Int { 1 &+ Size.lengthPrefixed(remainingLength) }

    /// Checks the rules a receiver enforces: everything ``read(from:maximumPacketSize:)`` would throw for,
    /// except that properties and lists are checked when created (``MQTTProperties/init(validating:)``).
    @inlinable
    public func validate() throws(MQTTError) {
        try validateFields()
        guard remainingLength <= Self.maximumRemainingLength else { throw .malformed("packet too long for MQTT") }
    }

    /// ``validate()`` without the size check, which `write(to:)` makes with the size it computes anyway.
    @inlinable
    func validateFields() throws(MQTTError) {
        switch self {
        case .connect(let packet): try packet.validate()
        case .connectAcknowledgement(let packet): try packet.validate()
        case .publish(let packet): try packet.validate()
        case .publishAcknowledgement(let packet), .publishReceived(let packet):
            try packet.validate(reasonCodes: .publishAcknowledgement)
        case .publishRelease(let packet), .publishComplete(let packet): try packet.validate(reasonCodes: .publishRelease)
        case .subscribe(let packet): try packet.validate()
        case .subscribeAcknowledgement(let packet): try packet.validate(reasonCodes: .subscribeAcknowledgement)
        case .unsubscribe(let packet): try packet.validate()
        case .unsubscribeAcknowledgement(let packet): try packet.validate(reasonCodes: .unsubscribeAcknowledgement)
        case .pingRequest, .pingResponse: break
        case .disconnect(let packet): try packet.validate()
        case .authenticate(let packet): try packet.validate()
        }
    }

    /// Writes the packet. It's checked and its size computed first, so nothing is written if it throws, and
    /// nothing is moved or copied twice.
    ///
    /// Throws ``BytesError/invalidValue`` if ``validate()`` throws (call it for the reason), and
    /// ``BytesError/insufficientCapacity`` if `writer` doesn't have ``encodedByteCount`` bytes left.
    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        do throws(MQTTError) { try validateFields() } catch { throw .invalidValue }
        let remainingLength = remainingLength
        guard remainingLength <= Self.maximumRemainingLength else { throw .invalidValue }
        guard writer.remainingByteCount >= 1 &+ Size.lengthPrefixed(remainingLength) else { throw .insufficientCapacity }
        try writer.write(type, as: Nibble.self)
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
        case .disconnect(let packet): try packet.writeBody(to: &writer)
        case .authenticate(let packet): try packet.writeBody(to: &writer)
        }
    }
}
