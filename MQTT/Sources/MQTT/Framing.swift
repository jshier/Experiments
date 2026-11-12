public import Bytes

// Framing, apart from parsing, and each packet type written on its own: so hot paths can skip
// `MQTTPacket`, the enum of every packet type. It's 153 bytes (CONNECT's will makes it large), so it
// lives in memory, and every case test is an out-of-line "get tag" call; parsing also returns it in an
// `Optional`, and writing one tested its case five times.
//
// - Reading: `MQTTFrame.read(from:)` reads a fixed header and bounds the body; dispatch on the frame's
//   `type`, then parse it as that type: `MQTTPublish(parsing: frame)`. `MQTTPacket.read(from:)` does the
//   same for every type.
// - Writing: each packet type writes itself (`publish.write(to:)`), which is what `MQTTPacket.write(to:)`
//   calls, after testing its case once.

// MARK: - Frames

/// A packet's fixed header, checked, and its body, not yet parsed: for dispatching on the packet type
/// yourself, and parsing only the types you expect, without `MQTTPacket`.
///
/// ```swift
/// var reader = BytesReader(received.span)
/// while let frame = try MQTTFrame.read(from: &reader) {
///     switch frame.type {
///     case .publish:
///         let publish = try MQTTPublish(parsing: frame)
///         deliver(publish.topic, publish.payload)
///     default:
///         handle(try MQTTPacket(parsing: frame))
///     }
/// }
/// received.removeFirst(reader.byteOffset) // Keep the partial packet, if any.
/// ```
public struct MQTTFrame: ~Copyable, ~Escapable {
    /// The packet's type.
    public let type: MQTTPacketType
    /// The fixed header's flags: checked for every type but PUBLISH, which parses its own.
    public let flags: Nibble
    /// The rest of the packet, its remaining length: every read in it is bounded to the packet.
    public var body: BytesReader

    @inlinable
    @_lifetime(copy body)
    init(type: MQTTPacketType, flags: Nibble, body: consuming BytesReader) {
        self.type = type
        self.flags = flags
        self.body = body
    }

    /// Reads the next packet's fixed header and takes its body, or returns `nil` without consuming
    /// anything if the packet isn't all there yet.
    ///
    /// The header is checked as soon as it's complete, before the body arrives. Either way the reader is
    /// left where it was unless a frame is returned.
    ///
    /// - Parameters:
    ///   - reader: The stream to read from. The frame's body borrows its bytes.
    ///   - maximumPacketSize: The largest packet to accept, in bytes, fixed header included.
    /// - Returns: The frame, or `nil` if the packet isn't all there yet.
    /// - Throws: `MQTTError.malformed(_:)` for a reserved packet type, reserved flags, or a malformed
    ///   remaining length; ``MQTTError/Kind/packetTooLarge`` if the packet is larger than
    ///   `maximumPacketSize`.
    @inlinable
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    public static func read(from reader: inout BytesReader, maximumPacketSize: Int = .max) throws(MQTTError) -> MQTTFrame? {
        let start = reader.position
        // Type and flags (the high and low nibbles of a byte), then the remaining length.
        let header: Byte
        let remainingLength: Int
        do throws(BytesError) {
            header = try reader.read(Byte.self)
            remainingLength = try Int(reader.readMQTTVariableByteInteger())
        } catch {
            reader.rewind(to: start)
            if error == .insufficientData { return nil }
            throw .malformed("remaining length")
        }
        do throws(MQTTError) {
            let flags = header.lowHalf
            guard let type = MQTTPacketType(rawBits: header.highHalf) else { throw .malformed("reserved packet type") }
            // PUBLISH uses its flags; PUBREL, SUBSCRIBE, and UNSUBSCRIBE require 0b0010; the rest, 0.
            guard type == .publish || flags == type.requiredFlags else { throw .malformed("reserved flags") }
            guard reader.byteOffset &- start.byteOffset &+ remainingLength <= maximumPacketSize else {
                throw MQTTError(.packetTooLarge, "packet larger than the maximum packet size")
            }
            guard let body = try? reader.readSection(byteCount: remainingLength) else {
                reader.rewind(to: start)
                return nil
            }
            return MQTTFrame(type: type, flags: flags, body: body)
        } catch {
            reader.rewind(to: start)
            throw error
        }
    }

    /// Checks the frame's type, as a packet type's `init(parsing:)` requires.
    ///
    /// - Parameter type: The type the frame must have.
    /// - Precondition: The frame is a `type`.
    @inlinable @inline(__always)
    func expect(_ type: MQTTPacketType) {
        precondition(self.type == type, "Parsing a frame as a different packet type: dispatch on `type` first")
    }
}

extension MQTTPacketType {
    /// The fixed header's flags for every type but PUBLISH: 0b0010 for PUBREL, SUBSCRIBE, and UNSUBSCRIBE,
    /// 0 for the rest.
    @inlinable @inline(__always)
    var requiredFlags: Nibble {
        switch self {
        case .publishRelease, .subscribe, .unsubscribe: 0b0010
        default: 0
        }
    }
}

// MARK: - Writing packets

extension BytesWriter {
    /// Writes a packet: checks it and its size first, so nothing is written if it throws, then writes the
    /// fixed header and the body.
    ///
    /// - Parameters:
    ///   - type: The packet type, for the fixed header.
    ///   - flags: The fixed header's flags.
    ///   - bodyByteCount: The body's size, which `body` must write exactly.
    ///   - validate: Checks the packet's fields.
    ///   - body: Writes the body.
    /// - Throws: `BytesError.invalidValue` if `validate` throws or the body is longer than
    ///   ``MQTTPacket/maximumRemainingLength``; `BytesError.insufficientCapacity` if the packet doesn't fit.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeMQTTPacket(
        _ type: MQTTPacketType, flags: Nibble, bodyByteCount: Int,
        validate: () throws(MQTTError) -> Void, body: (inout BytesWriter) throws(BytesError) -> Void
    ) throws(BytesError) {
        do throws(MQTTError) { try validate() } catch { throw .invalidValue }
        guard bodyByteCount <= MQTTPacket.maximumRemainingLength else { throw .invalidValue }
        guard remainingByteCount >= 1 &+ Size.lengthPrefixed(bodyByteCount) else { throw .insufficientCapacity }
        try write(Byte(highHalf: Nibble(rawBitsOf: type), lowHalf: flags))
        try write(UInt64(bodyByteCount), as: LEB128.self)
        try body(&self)
    }
}

// MARK: - Each packet type: parsing a frame, and writing

// Every `write(to:)` checks the packet first (the rules `MQTTPacket.validate()` names), so nothing is
// written if it throws: `BytesError.invalidValue` if it breaks one, `BytesError.insufficientCapacity`
// if it doesn't fit. Every `init(parsing:)` requires a frame of its type: dispatch on `frame.type` first.
// A frame is consumed when it's parsed, so if parsing throws, the stream's cursor is past the packet; MQTT
// ends the connection then anyway.

public extension MQTTConnect {
    /// Parses a CONNECT frame, consuming it.
    ///
    /// - Parameter frame: A frame of type ``MQTTPacketType/connect``.
    /// - Precondition: `frame.type` is ``MQTTPacketType/connect``.
    /// - Throws: ``MQTTError/Kind/unsupportedProtocolVersion`` if the protocol name or version isn't
    ///   MQTT 5.0; `MQTTError.malformed(_:)` if the body is truncated, has bytes left over, sets a reserved
    ///   connect flag, a will QoS of 3, or will QoS or retain without a will, or has an invalid string,
    ///   will topic, or property; `MQTTError.protocolError(_:)` for an empty will topic or a property
    ///   rule broken.
    @inlinable
    @_lifetime(copy frame)
    init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.connect)
        var body = frame.body
        try self.init(reading: &body)
    }

    /// Writes the packet, checked first so nothing is written if it throws.
    ///
    /// - Parameter writer: The writer to append to.
    /// - Throws: `BytesError.invalidValue` if it breaks a rule of ``MQTTPacket/validate()`` or its body is
    ///   too long for MQTT; `BytesError.insufficientCapacity` if it doesn't fit.
    @inlinable
    func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.connect, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { writer throws(BytesError) in try writeBody(to: &writer) })
    }
}

public extension MQTTConnectAcknowledgement {
    /// Parses a CONNACK frame, consuming it.
    ///
    /// - Parameter frame: A frame of type ``MQTTPacketType/connectAcknowledgement``.
    /// - Precondition: `frame.type` is ``MQTTPacketType/connectAcknowledgement``.
    /// - Throws: `MQTTError.malformed(_:)` if the body is truncated, has bytes left over, sets a reserved
    ///   flag, or has an invalid property; `MQTTError.protocolError(_:)` for a reason code CONNACK doesn't
    ///   allow, Session Present with a failure code, or a property rule broken.
    @inlinable
    @_lifetime(copy frame)
    init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.connectAcknowledgement)
        var body = frame.body
        try self.init(reading: &body)
    }

    /// Writes the packet, checked first so nothing is written if it throws.
    ///
    /// - Parameter writer: The writer to append to.
    /// - Throws: `BytesError.invalidValue` if it breaks a rule of ``MQTTPacket/validate()`` or its body is
    ///   too long for MQTT; `BytesError.insufficientCapacity` if it doesn't fit.
    @inlinable
    func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.connectAcknowledgement, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { writer throws(BytesError) in try writeBody(to: &writer) })
    }
}

public extension MQTTPublish {
    /// Parses a PUBLISH frame, consuming it. The payload is the rest of the body.
    ///
    /// - Parameter frame: A frame of type ``MQTTPacketType/publish``.
    /// - Precondition: `frame.type` is ``MQTTPacketType/publish``.
    /// - Throws: `MQTTError.malformed(_:)` if the flags have QoS 3 or DUP with QoS 0, or the topic or a
    ///   property is invalid (a wildcard or U+0000 in the topic, bad UTF-8, truncation);
    ///   `MQTTError.protocolError(_:)` for a zero packet identifier, an empty topic without a Topic Alias,
    ///   or a property rule broken.
    @inlinable
    @_lifetime(copy frame)
    init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.publish)
        let flags = frame.flags
        var body = frame.body
        try self.init(reading: &body, flags: flags)
    }

    /// Writes the packet, checked first so nothing is written if it throws.
    ///
    /// - Parameter writer: The writer to append to.
    /// - Throws: `BytesError.invalidValue` if it breaks a rule of ``MQTTPacket/validate()`` or its body is
    ///   too long for MQTT; `BytesError.insufficientCapacity` if it doesn't fit.
    @inlinable
    func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.publish, flags: flags, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { writer throws(BytesError) in try writeBody(to: &writer) })
    }
}

public extension MQTTPublishResponse {
    /// Parses a PUBACK, PUBREC, PUBREL, or PUBCOMP frame, as its type says, consuming it.
    ///
    /// The reason code and properties may be omitted: success, and none.
    ///
    /// - Parameter frame: A frame of one of those four types.
    /// - Precondition: `frame.type` is one of those four types.
    /// - Throws: `MQTTError.malformed(_:)` if the body is truncated, has bytes left over, or has an
    ///   invalid property; `MQTTError.protocolError(_:)` for a reason code the type doesn't allow or a
    ///   property rule broken.
    @inlinable
    @_lifetime(copy frame)
    init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        let reasonCodes = Self.reasonCodes(for: frame.type)
        var body = frame.body
        try self.init(reading: &body, reasonCodes: reasonCodes)
    }

    /// Writes it as `type`: PUBACK, PUBREC, PUBREL, or PUBCOMP, checked first so nothing is written if it
    /// throws. The reason code and properties are omitted when they're success and empty.
    ///
    /// - Parameters:
    ///   - writer: The writer to append to.
    ///   - type: One of those four types.
    /// - Precondition: `type` is one of those four types.
    /// - Throws: `BytesError.invalidValue` if it breaks a rule of ``MQTTPacket/validate()`` (including a
    ///   reason code `type` doesn't allow); `BytesError.insufficientCapacity` if it doesn't fit.
    @inlinable
    func write(to writer: inout BytesWriter, as type: MQTTPacketType) throws(BytesError) {
        let reasonCodes = Self.reasonCodes(for: type)
        try writer.writeMQTTPacket(type, flags: type.requiredFlags, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate(reasonCodes: reasonCodes) },
                                   body: { writer throws(BytesError) in try writeBody(to: &writer) })
    }

    @inlinable @inline(__always)
    internal static func reasonCodes(for type: MQTTPacketType) -> ReasonCodeSet {
        switch type {
        case .publishAcknowledgement, .publishReceived: .publishAcknowledgement
        case .publishRelease, .publishComplete: .publishRelease
        default: preconditionFailure("Not PUBACK, PUBREC, PUBREL, or PUBCOMP: dispatch on `type` first")
        }
    }
}

public extension MQTTSubscribe {
    /// Parses a SUBSCRIBE frame, consuming it.
    ///
    /// - Parameter frame: A frame of type ``MQTTPacketType/subscribe``.
    /// - Precondition: `frame.type` is ``MQTTPacketType/subscribe``.
    /// - Throws: `MQTTError.malformed(_:)` if the body is truncated or has an invalid property, filter,
    ///   or options byte; `MQTTError.protocolError(_:)` for a zero packet identifier, no subscriptions,
    ///   an empty filter, No Local on a shared subscription, a retain handling or maximum QoS of 3, or a
    ///   property rule broken.
    @inlinable
    @_lifetime(copy frame)
    init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.subscribe)
        var body = frame.body
        try self.init(reading: &body)
    }

    /// Writes the packet, checked first so nothing is written if it throws.
    ///
    /// - Parameter writer: The writer to append to.
    /// - Throws: `BytesError.invalidValue` if it breaks a rule of ``MQTTPacket/validate()`` or its body is
    ///   too long for MQTT; `BytesError.insufficientCapacity` if it doesn't fit.
    @inlinable
    func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.subscribe, flags: 0b0010, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { writer throws(BytesError) in try writeBody(to: &writer) })
    }
}

public extension MQTTUnsubscribe {
    /// Parses an UNSUBSCRIBE frame, consuming it.
    ///
    /// - Parameter frame: A frame of type ``MQTTPacketType/unsubscribe``.
    /// - Precondition: `frame.type` is ``MQTTPacketType/unsubscribe``.
    /// - Throws: `MQTTError.malformed(_:)` if the body is truncated or has an invalid property or filter;
    ///   `MQTTError.protocolError(_:)` for a zero packet identifier, no topic filters, an empty filter, or
    ///   a property rule broken.
    @inlinable
    @_lifetime(copy frame)
    init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.unsubscribe)
        var body = frame.body
        try self.init(reading: &body)
    }

    /// Writes the packet, checked first so nothing is written if it throws.
    ///
    /// - Parameter writer: The writer to append to.
    /// - Throws: `BytesError.invalidValue` if it breaks a rule of ``MQTTPacket/validate()`` or its body is
    ///   too long for MQTT; `BytesError.insufficientCapacity` if it doesn't fit.
    @inlinable
    func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.unsubscribe, flags: 0b0010, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { writer throws(BytesError) in try writeBody(to: &writer) })
    }
}

public extension MQTTSubscribeAcknowledgement {
    /// Parses a SUBACK or UNSUBACK frame, as its type says, consuming it. The reason codes are the rest of
    /// the body.
    ///
    /// - Parameter frame: A frame of type ``MQTTPacketType/subscribeAcknowledgement`` or
    ///   ``MQTTPacketType/unsubscribeAcknowledgement``.
    /// - Precondition: `frame.type` is one of those two types.
    /// - Throws: `MQTTError.malformed(_:)` if the body is truncated or has an invalid property;
    ///   `MQTTError.protocolError(_:)` for no reason codes, a reason code the type doesn't allow, or a
    ///   property rule broken.
    @inlinable
    @_lifetime(copy frame)
    init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        let reasonCodes = Self.reasonCodes(for: frame.type)
        var body = frame.body
        try self.init(reading: &body, reasonCodes: reasonCodes)
    }

    /// Writes it as `type`: SUBACK or UNSUBACK, checked first so nothing is written if it throws.
    ///
    /// - Parameters:
    ///   - writer: The writer to append to.
    ///   - type: ``MQTTPacketType/subscribeAcknowledgement`` or ``MQTTPacketType/unsubscribeAcknowledgement``.
    /// - Precondition: `type` is one of those two types.
    /// - Throws: `BytesError.invalidValue` if it breaks a rule of ``MQTTPacket/validate()`` (including a
    ///   reason code `type` doesn't allow) or its body is too long for MQTT;
    ///   `BytesError.insufficientCapacity` if it doesn't fit.
    @inlinable
    func write(to writer: inout BytesWriter, as type: MQTTPacketType) throws(BytesError) {
        let allowed = Self.reasonCodes(for: type)
        try writer.writeMQTTPacket(type, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate(reasonCodes: allowed) },
                                   body: { writer throws(BytesError) in try writeBody(to: &writer) })
    }

    @inlinable @inline(__always)
    internal static func reasonCodes(for type: MQTTPacketType) -> ReasonCodeSet {
        switch type {
        case .subscribeAcknowledgement: .subscribeAcknowledgement
        case .unsubscribeAcknowledgement: .unsubscribeAcknowledgement
        default: preconditionFailure("Not SUBACK or UNSUBACK: dispatch on `type` first")
        }
    }
}

public extension MQTTDisconnect {
    /// Parses a DISCONNECT frame, consuming it. An empty body is a normal disconnection.
    ///
    /// - Parameter frame: A frame of type ``MQTTPacketType/disconnect``.
    /// - Precondition: `frame.type` is ``MQTTPacketType/disconnect``.
    /// - Throws: `MQTTError.malformed(_:)` if the body is truncated, has bytes left over, or has an
    ///   invalid property; `MQTTError.protocolError(_:)` for a reason code DISCONNECT doesn't allow or a
    ///   property rule broken.
    @inlinable
    @_lifetime(copy frame)
    init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.disconnect)
        var body = frame.body
        try self.init(reading: &body)
    }

    /// Writes the packet, checked first so nothing is written if it throws. The reason code and properties
    /// are omitted for a normal disconnection without properties.
    ///
    /// - Parameter writer: The writer to append to.
    /// - Throws: `BytesError.invalidValue` if it breaks a rule of ``MQTTPacket/validate()`` or its body is
    ///   too long for MQTT; `BytesError.insufficientCapacity` if it doesn't fit.
    @inlinable
    func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.disconnect, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { writer throws(BytesError) in try writeBody(to: &writer) })
    }
}

public extension MQTTAuthenticate {
    /// Parses an AUTH frame, consuming it. An empty body is success without properties.
    ///
    /// - Parameter frame: A frame of type ``MQTTPacketType/authenticate``.
    /// - Precondition: `frame.type` is ``MQTTPacketType/authenticate``.
    /// - Throws: `MQTTError.malformed(_:)` if the body is truncated, has bytes left over, or has an
    ///   invalid property; `MQTTError.protocolError(_:)` for a reason code AUTH doesn't allow or a
    ///   property rule broken.
    @inlinable
    @_lifetime(copy frame)
    init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.authenticate)
        var body = frame.body
        try self.init(reading: &body)
    }

    /// Writes the packet, checked first so nothing is written if it throws. The reason code and properties
    /// are omitted for success without properties.
    ///
    /// - Parameter writer: The writer to append to.
    /// - Throws: `BytesError.invalidValue` if it breaks a rule of ``MQTTPacket/validate()`` or its body is
    ///   too long for MQTT; `BytesError.insufficientCapacity` if it doesn't fit.
    @inlinable
    func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.authenticate, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { writer throws(BytesError) in try writeBody(to: &writer) })
    }
}
