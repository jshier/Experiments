import Bytes
import MQTT

/// What a transfer sends: how many PUBLISH packets of what size, over how many connections, in what
/// batches, and how many executor threads run it.
public struct Workload: Sendable, CustomStringConvertible {
    /// Bytes of application payload per PUBLISH.
    public var payloadSize: Int
    /// PUBLISH packets each connection carries.
    public var packetsPerConnection: Int
    /// Client/server connection pairs, all transferring at once.
    public var connections: Int
    /// The sender's write size: packets are encoded into a batch of this many bytes, then written at once.
    public var batchSize: Int
    /// The receiver's buffer: each read fills its free space, and complete packets are parsed out of it.
    public var receiveCapacity: Int
    /// Threads in the executor pool that runs the senders and receivers (`nil`: one per core).
    public var poolSize: Int?

    public init(
        payloadSize: Int, packetsPerConnection: Int, connections: Int = 1,
        batchSize: Int = 256 << 10, receiveCapacity: Int = 256 << 10, poolSize: Int? = nil
    ) {
        precondition(batchSize >= Fixtures.packetSize(payloadSize: payloadSize, index: 0), "A batch must hold a packet")
        precondition(receiveCapacity > Fixtures.packetSize(payloadSize: payloadSize, index: 0), "The buffer must hold a packet")
        self.payloadSize = payloadSize
        self.packetsPerConnection = packetsPerConnection
        self.connections = connections
        self.batchSize = batchSize
        self.receiveCapacity = receiveCapacity
        self.poolSize = poolSize
    }

    /// The bytes one connection carries: every packet, encoded.
    public var bytesPerConnection: Int {
        // Topics cycle through 16 lengths, so whole cycles plus the remainder.
        let cycle = (0..<Fixtures.topics.count).reduce(0) { $0 + Fixtures.packetSize(payloadSize: payloadSize, index: $1) }
        let whole = packetsPerConnection / Fixtures.topics.count
        let rest = (0..<(packetsPerConnection % Fixtures.topics.count))
            .reduce(0) { $0 + Fixtures.packetSize(payloadSize: payloadSize, index: $1) }
        return whole * cycle + rest
    }

    public var description: String {
        "\(connections)×\(packetsPerConnection) PUBLISH, \(payloadSize) B payloads"
    }
}

/// The packets' contents, which the receiver checks: the same as the MQTT package's benchmarks (QoS 1, a
/// ~32-byte topic from a cycle of 16, a message expiry and a user property), with a payload of a chosen
/// size.
public enum Fixtures {
    public static let topics: [String] = (0..<16).map { "sensors/building-\($0 % 8)/floor-\($0 % 4)/temp-\($0)" }

    /// The topics' bytes end to end, and where each ends: what `PacketChecker` compares against.
    static let topicTable: (bytes: [UInt8], ends: [Int]) = (
        topics.flatMap(\.utf8),
        topics.reduce(into: []) { ends, topic in ends.append((ends.last ?? 0) + topic.utf8.count) }
    )

    /// Packets `0..<count` with `payloadSize`-byte payloads, encoded end to end: a sender's stream, for
    /// measuring the receiving end without a socket.
    public static func stream(payloadSize: Int, count: Int) -> [UInt8] {
        let payload = payload(size: payloadSize)
        var stream: [UInt8] = []
        var batch = [UInt8](repeating: 0, count: 256 << 10)
        var next = 0
        while next < count {
            let byteCount = Transfer.encode(into: &batch, from: &next, until: count, payload: payload)
            stream += batch[..<byteCount]
        }
        return stream
    }

    /// Message expiry 60 s and a user property, encoded once.
    static let propertyBytes: [UInt8] = try! [UInt8](capacity: 64) { output in
        try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
            try writer.write(MQTTProperty.messageExpiryInterval(60))
            try writer.write(MQTTProperty.userProperty(name: "unit".utf8Span, value: "celsius".utf8Span))
        }
    }

    /// A payload of `size` bytes, its byte `i` a function of `i` so corruption shows.
    public static func payload(size: Int) -> [UInt8] { (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) } }

    /// Packet `index`'s identifier: 1 through 65,535, in order.
    public static func packetIdentifier(_ index: Int) -> UInt16 { UInt16(index % 65_535 + 1) }

    /// Packet `index`'s encoded size.
    static func packetSize(payloadSize: Int, index: Int) -> Int {
        let payload = [UInt8](repeating: 0, count: payloadSize)
        let properties = try! MQTTProperties(validating: propertyBytes.span.bytes)
        return MQTTPacket.publish(MQTTPublish(
            qos: .atLeastOnce, topic: topics[index % topics.count].utf8Span, packetIdentifier: packetIdentifier(index),
            properties: properties, payload: payload.span.bytes
        )).encodedByteCount
    }
}
