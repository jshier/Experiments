public import Bytes

/// An MQTT 5.0 control packet: a view of the bytes it was parsed from.
///
/// Read packets from a stream as bytes arrive. A packet that isn't complete yet is left unread, so you can
/// append more data and try again:
///
/// ```swift
/// var reader = BytesReader(received.span)
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
///
/// In a hot loop, skip the enum where you can. It's 153 bytes, so it's built in memory and each case test
/// is a call. Dispatch on an ``MQTTFrame``'s type and parse the packet types you expect yourself
/// (`MQTTPublish(parsing: frame)`, 26% faster for PUBLISH streams), and write a packet you have as its
/// type (`publish.write(to:)`).
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
    /// A reserved packet type or reserved flags, like a packet larger than `maximumPacketSize`, throw as soon
    /// as the fixed header arrives (``MQTTFrame/read(from:maximumPacketSize:)``); the rest, once the whole
    /// packet has.
    ///
    /// - Parameter maximumPacketSize: The largest packet to accept, in bytes, such as the Maximum Packet
    ///   Size you advertised.
    @inlinable
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    public static func read(from reader: inout BytesReader, maximumPacketSize: Int = .max) throws(MQTTError) -> MQTTPacket? {
        let start = reader.byteOffset
        guard let frame = try MQTTFrame.read(from: &reader, maximumPacketSize: maximumPacketSize) else { return nil }
        do throws(MQTTError) {
            return try MQTTPacket(parsing: frame)
        } catch {
            try! reader.seek(toByteOffset: start)
            throw error
        }
    }

    /// Parses a frame's body as the packet its type says. The frame is consumed: if this throws, the stream's
    /// cursor is past the packet (``read(from:maximumPacketSize:)`` moves it back).
    ///
    /// Each case parses in its own function (the packet types' `init(parsing:)`), so this function only
    /// dispatches and wraps the result.
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        switch frame.type {
        case .connect: self = try .connect(MQTTConnect(parsing: frame))
        case .connectAcknowledgement: self = try .connectAcknowledgement(MQTTConnectAcknowledgement(parsing: frame))
        case .publish: self = try .publish(MQTTPublish(parsing: frame))
        case .publishAcknowledgement: self = try .publishAcknowledgement(MQTTPublishResponse(parsing: frame))
        case .publishReceived: self = try .publishReceived(MQTTPublishResponse(parsing: frame))
        case .publishRelease: self = try .publishRelease(MQTTPublishResponse(parsing: frame))
        case .publishComplete: self = try .publishComplete(MQTTPublishResponse(parsing: frame))
        case .subscribe: self = try .subscribe(MQTTSubscribe(parsing: frame))
        case .subscribeAcknowledgement: self = try .subscribeAcknowledgement(MQTTSubscribeAcknowledgement(parsing: frame))
        case .unsubscribe: self = try .unsubscribe(MQTTUnsubscribe(parsing: frame))
        case .unsubscribeAcknowledgement: self = try .unsubscribeAcknowledgement(MQTTSubscribeAcknowledgement(parsing: frame))
        case .pingRequest:
            try frame.body.expectMQTTEnd("ping request")
            self = .pingRequest
        case .pingResponse:
            try frame.body.expectMQTTEnd("ping response")
            self = .pingResponse
        case .disconnect: self = try .disconnect(MQTTDisconnect(parsing: frame))
        case .authenticate: self = try .authenticate(MQTTAuthenticate(parsing: frame))
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

    /// The size of everything after the fixed header.
    @inlinable
    public var remainingLength: Int {
        switch self {
        case let .connect(packet): packet.bodyByteCount
        case let .connectAcknowledgement(packet): packet.bodyByteCount
        case let .publish(packet): packet.bodyByteCount
        case let .publishAcknowledgement(packet), let .publishReceived(packet), let .publishRelease(packet),
             let .publishComplete(packet): packet.bodyByteCount
        case let .subscribe(packet): packet.bodyByteCount
        case let .subscribeAcknowledgement(packet), let .unsubscribeAcknowledgement(packet): packet.bodyByteCount
        case let .unsubscribe(packet): packet.bodyByteCount
        case .pingRequest, .pingResponse: 0
        case let .disconnect(packet): packet.bodyByteCount
        case let .authenticate(packet): packet.bodyByteCount
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
        case let .connect(packet): try packet.validate()
        case let .connectAcknowledgement(packet): try packet.validate()
        case let .publish(packet): try packet.validate()
        case let .publishAcknowledgement(packet), let .publishReceived(packet):
            try packet.validate(reasonCodes: .publishAcknowledgement)
        case let .publishRelease(packet), let .publishComplete(packet): try packet.validate(reasonCodes: .publishRelease)
        case let .subscribe(packet): try packet.validate()
        case let .subscribeAcknowledgement(packet): try packet.validate(reasonCodes: .subscribeAcknowledgement)
        case let .unsubscribe(packet): try packet.validate()
        case let .unsubscribeAcknowledgement(packet): try packet.validate(reasonCodes: .unsubscribeAcknowledgement)
        case .pingRequest, .pingResponse: break
        case let .disconnect(packet): try packet.validate()
        case let .authenticate(packet): try packet.validate()
        }
    }

    /// Writes the packet. It's checked and its size computed first, so nothing is written if it throws, and
    /// nothing is moved or copied twice.
    ///
    /// Throws ``BytesError/invalidValue`` if ``validate()`` throws (call it for the reason), and
    /// ``BytesError/insufficientCapacity`` if `writer` doesn't have ``encodedByteCount`` bytes left.
    ///
    /// Tests the packet's case once, then the packet type writes itself (`write(to:)`); with the packet in
    /// hand, call that directly.
    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        switch self {
        case let .connect(packet): try packet.write(to: &writer)
        case let .connectAcknowledgement(packet): try packet.write(to: &writer)
        case let .publish(packet): try packet.write(to: &writer)
        case let .publishAcknowledgement(packet): try packet.write(to: &writer, as: .publishAcknowledgement)
        case let .publishReceived(packet): try packet.write(to: &writer, as: .publishReceived)
        case let .publishRelease(packet): try packet.write(to: &writer, as: .publishRelease)
        case let .publishComplete(packet): try packet.write(to: &writer, as: .publishComplete)
        case let .subscribe(packet): try packet.write(to: &writer)
        case let .subscribeAcknowledgement(packet): try packet.write(to: &writer, as: .subscribeAcknowledgement)
        case let .unsubscribe(packet): try packet.write(to: &writer)
        case let .unsubscribeAcknowledgement(packet): try packet.write(to: &writer, as: .unsubscribeAcknowledgement)
        case .pingRequest: try writer.writeMQTTPacket(.pingRequest, flags: 0, bodyByteCount: 0, validate: {}, body: { _ in })
        case .pingResponse: try writer.writeMQTTPacket(.pingResponse, flags: 0, bodyByteCount: 0, validate: {}, body: { _ in })
        case let .disconnect(packet): try packet.write(to: &writer)
        case let .authenticate(packet): try packet.write(to: &writer)
        }
    }
}
