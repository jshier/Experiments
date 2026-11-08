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
    /// Throws ``MQTTError`` for a reserved packet type, reserved flags, a malformed remaining length, or a
    /// packet larger than `maximumPacketSize`, leaving the cursor where it was.
    @inlinable
    @_lifetime(copy reader)
    @_lifetime(reader: copy reader)
    public static func read(from reader: inout BytesReader, maximumPacketSize: Int = .max) throws(MQTTError) -> MQTTFrame? {
        let start = reader.byteOffset
        // Type and flags (a nibble each), then the remaining length.
        let typeBits: Nibble
        let flags: Nibble
        let remainingLength: Int
        do throws(BytesError) {
            typeBits = try reader.read(Nibble.self)
            flags = try reader.read(Nibble.self)
            remainingLength = Int(try reader.readMQTTVariableByteInteger())
        } catch {
            try! reader.seek(toByteOffset: start)
            if error == .insufficientData { return nil }
            throw .malformed("remaining length")
        }
        do throws(MQTTError) {
            guard let type = MQTTPacketType(rawBits: typeBits) else { throw .malformed("reserved packet type") }
            // PUBLISH uses its flags; PUBREL, SUBSCRIBE, and UNSUBSCRIBE require 0b0010; the rest, 0.
            guard type == .publish || flags == type.requiredFlags else { throw .malformed("reserved flags") }
            guard reader.byteOffset &- start &+ remainingLength <= maximumPacketSize else {
                throw MQTTError(.packetTooLarge, "packet larger than the maximum packet size")
            }
            guard let body = try? reader.readSection(byteCount: remainingLength) else {
                try! reader.seek(toByteOffset: start)
                return nil
            }
            return MQTTFrame(type: type, flags: flags, body: body)
        } catch {
            try! reader.seek(toByteOffset: start)
            throw error
        }
    }

    /// Precondition: the frame is a `type`, as a packet type's `init(parsing:)` requires.
    @inlinable @inline(__always)
    func expect(_ type: MQTTPacketType) {
        precondition(self.type == type, "Parsing a frame as a different packet type: dispatch on `type` first")
    }
}

extension MQTTPacketType {
    /// The fixed header's flags for every type but PUBLISH.
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
    /// Writes a packet: checks it (`validate`) and its size first, so nothing is written if it throws, then
    /// writes the fixed header and the body.
    ///
    /// Throws ``BytesError/invalidValue`` if `validate` throws or the body is too long for MQTT, and
    /// ``BytesError/insufficientCapacity`` if the packet doesn't fit.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func writeMQTTPacket(
        _ type: MQTTPacketType, flags: Nibble, bodyByteCount: Int,
        validate: () throws(MQTTError) -> Void, body: (inout BytesWriter) throws(BytesError) -> Void
    ) throws(BytesError) {
        do throws(MQTTError) { try validate() } catch { throw .invalidValue }
        guard bodyByteCount <= MQTTPacket.maximumRemainingLength else { throw .invalidValue }
        guard remainingByteCount >= 1 &+ Size.lengthPrefixed(bodyByteCount) else { throw .insufficientCapacity }
        try write(type, as: Nibble.self)
        try write(flags)
        try write(UInt64(bodyByteCount), as: LEB128.self)
        try body(&self)
    }
}

// MARK: - Each packet type: parsing a frame, and writing

// Every `write(to:)` checks the packet first (the rules `MQTTPacket.validate()` names), so nothing is
// written if it throws: ``BytesError/invalidValue`` if it breaks one, ``BytesError/insufficientCapacity``
// if it doesn't fit. Every `init(parsing:)` requires a frame of its type: dispatch on `frame.type` first.
// A frame is consumed when it's parsed, so if parsing throws, the stream's cursor is past the packet; MQTT
// ends the connection then anyway.

extension MQTTConnect {
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.connect)
        var body = frame.body
        try self.init(reading: &body)
    }

    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.connect, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { (writer) throws(BytesError) in try writeBody(to: &writer) })
    }
}

extension MQTTConnectAcknowledgement {
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.connectAcknowledgement)
        var body = frame.body
        try self.init(reading: &body)
    }

    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.connectAcknowledgement, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { (writer) throws(BytesError) in try writeBody(to: &writer) })
    }
}

extension MQTTPublish {
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.publish)
        let flags = frame.flags
        var body = frame.body
        try self.init(reading: &body, flags: flags)
    }

    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.publish, flags: flags, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { (writer) throws(BytesError) in try writeBody(to: &writer) })
    }
}

extension MQTTPublishResponse {
    /// PUBACK, PUBREC, PUBREL, or PUBCOMP, as the frame's type says.
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        let reasonCodes = Self.reasonCodes(for: frame.type)
        var body = frame.body
        try self.init(reading: &body, reasonCodes: reasonCodes)
    }

    /// Writes it as `type`: PUBACK, PUBREC, PUBREL, or PUBCOMP.
    @inlinable
    public func write(to writer: inout BytesWriter, as type: MQTTPacketType) throws(BytesError) {
        let reasonCodes = Self.reasonCodes(for: type)
        try writer.writeMQTTPacket(type, flags: type.requiredFlags, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate(reasonCodes: reasonCodes) },
                                   body: { (writer) throws(BytesError) in try writeBody(to: &writer) })
    }

    @inlinable @inline(__always)
    static func reasonCodes(for type: MQTTPacketType) -> ReasonCodeSet {
        switch type {
        case .publishAcknowledgement, .publishReceived: .publishAcknowledgement
        case .publishRelease, .publishComplete: .publishRelease
        default: preconditionFailure("Not PUBACK, PUBREC, PUBREL, or PUBCOMP: dispatch on `type` first")
        }
    }
}

extension MQTTSubscribe {
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.subscribe)
        var body = frame.body
        try self.init(reading: &body)
    }

    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.subscribe, flags: 0b0010, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { (writer) throws(BytesError) in try writeBody(to: &writer) })
    }
}

extension MQTTUnsubscribe {
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.unsubscribe)
        var body = frame.body
        try self.init(reading: &body)
    }

    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.unsubscribe, flags: 0b0010, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { (writer) throws(BytesError) in try writeBody(to: &writer) })
    }
}

extension MQTTSubscribeAcknowledgement {
    /// SUBACK or UNSUBACK, as the frame's type says.
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        let reasonCodes = Self.reasonCodes(for: frame.type)
        var body = frame.body
        try self.init(reading: &body, reasonCodes: reasonCodes)
    }

    /// Writes it as `type`: SUBACK or UNSUBACK.
    @inlinable
    public func write(to writer: inout BytesWriter, as type: MQTTPacketType) throws(BytesError) {
        let allowed = Self.reasonCodes(for: type)
        try writer.writeMQTTPacket(type, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate(reasonCodes: allowed) },
                                   body: { (writer) throws(BytesError) in try writeBody(to: &writer) })
    }

    @inlinable @inline(__always)
    static func reasonCodes(for type: MQTTPacketType) -> ReasonCodeSet {
        switch type {
        case .subscribeAcknowledgement: .subscribeAcknowledgement
        case .unsubscribeAcknowledgement: .unsubscribeAcknowledgement
        default: preconditionFailure("Not SUBACK or UNSUBACK: dispatch on `type` first")
        }
    }
}

extension MQTTDisconnect {
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.disconnect)
        var body = frame.body
        try self.init(reading: &body)
    }

    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.disconnect, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { (writer) throws(BytesError) in try writeBody(to: &writer) })
    }
}

extension MQTTAuthenticate {
    @inlinable
    @_lifetime(copy frame)
    public init(parsing frame: consuming MQTTFrame) throws(MQTTError) {
        frame.expect(.authenticate)
        var body = frame.body
        try self.init(reading: &body)
    }

    @inlinable
    public func write(to writer: inout BytesWriter) throws(BytesError) {
        try writer.writeMQTTPacket(.authenticate, flags: 0, bodyByteCount: bodyByteCount,
                                   validate: { () throws(MQTTError) in try validate() },
                                   body: { (writer) throws(BytesError) in try writeBody(to: &writer) })
    }
}
