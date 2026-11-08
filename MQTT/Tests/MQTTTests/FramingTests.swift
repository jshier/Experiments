import Bytes
import MQTT
import Testing

/// `MQTTFrame` and the packet types' own `init(parsing:)` and `write(to:)`: the path that skips `MQTTPacket`.
@Suite struct FramingTests {
    /// Parses `frame` as its type, without `MQTTPacket`, and writes it back the same way.
    func reencodedByType(_ frame: consuming MQTTFrame) throws -> [UInt8] {
        switch frame.type {
        case .connect:
            let packet = try MQTTConnect(parsing: frame)
            return try fieldBytes { (w) throws(BytesError) in try packet.write(to: &w) }
        case .connectAcknowledgement:
            let packet = try MQTTConnectAcknowledgement(parsing: frame)
            return try fieldBytes { (w) throws(BytesError) in try packet.write(to: &w) }
        case .publish:
            let packet = try MQTTPublish(parsing: frame)
            return try fieldBytes { (w) throws(BytesError) in try packet.write(to: &w) }
        case .publishAcknowledgement, .publishReceived, .publishRelease, .publishComplete:
            let type = frame.type
            let packet = try MQTTPublishResponse(parsing: frame)
            return try fieldBytes { (w) throws(BytesError) in try packet.write(to: &w, as: type) }
        case .subscribe:
            let packet = try MQTTSubscribe(parsing: frame)
            return try fieldBytes { (w) throws(BytesError) in try packet.write(to: &w) }
        case .subscribeAcknowledgement, .unsubscribeAcknowledgement:
            let type = frame.type
            let packet = try MQTTSubscribeAcknowledgement(parsing: frame)
            return try fieldBytes { (w) throws(BytesError) in try packet.write(to: &w, as: type) }
        case .unsubscribe:
            let packet = try MQTTUnsubscribe(parsing: frame)
            return try fieldBytes { (w) throws(BytesError) in try packet.write(to: &w) }
        case .disconnect:
            let packet = try MQTTDisconnect(parsing: frame)
            return try fieldBytes { (w) throws(BytesError) in try packet.write(to: &w) }
        case .authenticate:
            let packet = try MQTTAuthenticate(parsing: frame)
            return try fieldBytes { (w) throws(BytesError) in try packet.write(to: &w) }
        case .pingRequest, .pingResponse:
            return try encoded(MQTTPacket(parsing: frame))
        }
    }

    /// Every packet type: a frame takes the bytes `MQTTPacket.read` does, and each type's own parse and write
    /// reproduce them, as `MQTTPacket(parsing:)` does.
    @Test func everyTypeRoundTripsWithoutTheEnum() throws {
        for bytes in try corpus() {
            var reader = BytesReader(bytes.span)
            guard let frame = try MQTTFrame.read(from: &reader) else {
                Issue.record("No frame in \(bytes)")
                continue
            }
            #expect(reader.byteOffset == bytes.count)
            #expect(try reencodedByType(frame) == bytes)

            var again = BytesReader(bytes.span)
            guard let enumFrame = try MQTTFrame.read(from: &again) else { continue }
            #expect(try encoded(MQTTPacket(parsing: enumFrame)) == bytes)
        }
    }

    /// An incomplete packet is `nil`, consuming nothing, until a reserved type or flags in its fixed header
    /// throw, also consuming nothing: before the body arrives.
    @Test func headersAreCheckedBeforeTheBodyArrives() throws {
        func read(_ bytes: [UInt8]) throws(MQTTError) -> (MQTTPacketType?, Int) {
            var reader = BytesReader(bytes.span)
            defer { #expect(reader.byteOffset == 0 || reader.byteOffset == bytes.count) }
            let type = try MQTTFrame.read(from: &reader)?.type
            return (type, reader.byteOffset)
        }
        #expect(try read([]) == (nil, 0))
        #expect(try read([0x30]) == (nil, 0))
        #expect(try read([0x30, 0x05, 0x00]) == (nil, 0))
        #expect(try read([0x62, 0x02, 0x00, 0x01]) == (.publishRelease, 4))
        // PUBREL needs flags 0b0010; type 0 is reserved. Neither body has arrived.
        #expect(throws: MQTTError.self) { try read([0x60, 0x02, 0x00]) }
        #expect(throws: MQTTError.self) { try read([0x00, 0x05]) }
        // Too large for the maximum: as soon as the remaining length arrives.
        var reader = BytesReader([0x30, 0x7F].span)
        #expect(throws: MQTTError(.packetTooLarge, "packet larger than the maximum packet size")) {
            _ = try MQTTFrame.read(from: &reader, maximumPacketSize: 100)
        }
        #expect(reader.byteOffset == 0)
    }
}
