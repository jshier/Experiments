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

    /// Creates a workload.
    ///
    /// - Parameters:
    ///   - payloadSize: Bytes of application payload per PUBLISH.
    ///   - packetsPerConnection: PUBLISH packets each connection carries.
    ///   - connections: Client/server connection pairs.
    ///   - batchSize: The sender's write size in bytes.
    ///   - receiveCapacity: The receiver's buffer size in bytes.
    ///   - poolSize: Threads in the shared executor pool (`nil`: one per core).
    /// - Precondition: `batchSize` holds the first packet, and `receiveCapacity` is larger than it.
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

    /// A short summary: connections, packets per connection, and payload size.
    public var description: String {
        "\(connections)×\(packetsPerConnection) PUBLISH, \(payloadSize) B payloads"
    }
}

/// The packets' contents, which the receiver checks: the same as the MQTT package's benchmarks (QoS 1, a
/// ~32-byte topic from a cycle of 16, a message expiry and a user property), with a payload of a chosen
/// size.
public enum Fixtures {
    /// The 16 topics the packets cycle through, in order.
    public static let topics: [String] = (0..<16).map { "sensors/building-\($0 % 8)/floor-\($0 % 4)/temp-\($0)" }

    /// The topics' bytes end to end, and where each ends: what `PacketChecker` compares against.
    static let topicTable: (bytes: [UInt8], ends: [Int]) = (
        topics.flatMap(\.utf8),
        topics.reduce(into: []) { ends, topic in ends.append((ends.last ?? 0) + topic.utf8.count) }
    )

    /// Packets `0..<count` with `payloadSize`-byte payloads, encoded end to end: a sender's stream, for
    /// measuring the receiving end without a socket.
    ///
    /// - Parameters:
    ///   - payloadSize: Bytes of payload per packet.
    ///   - count: How many packets to encode.
    /// - Returns: The encoded packets.
    public static func stream(payloadSize: Int, count: Int) -> [UInt8] {
        let payloads = Payloads.fixed(size: payloadSize)
        var stream: [UInt8] = []
        var batch = [UInt8](repeating: 0, count: 256 << 10)
        var next = 0
        while next < count {
            let byteCount = Transfer.encode(into: &batch, from: &next, until: count, payloads: payloads)
            stream += batch[..<byteCount]
        }
        return stream
    }

    /// Message expiry 60 s and a user property, encoded once.
    static let propertyBytes: [UInt8] = try! [UInt8](alignedByteCapacity: 64) { writer in
        try writer.write(MQTTProperty.messageExpiryInterval(60))
        try writer.write(MQTTProperty.userProperty(name: "unit".utf8Span, value: "celsius".utf8Span))
    }

    /// A payload whose byte `i` is a function of `i`, so corruption shows.
    ///
    /// - Parameter size: The payload's length in bytes.
    /// - Returns: The payload.
    public static func payload(size: Int) -> [UInt8] { (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) } }

    /// About 1 MB of JSON sensor readings, one per line: varied payloads for compressed transfers, which
    /// compress as telemetry does (the fixed payload, a 256-byte cycle, compresses to almost nothing).
    static let telemetry: [UInt8] = {
        var generator = SplitMix64(state: 42)
        var text = ""
        var time = 1_731_661_200_000
        while text.utf8.count < 1 << 20 {
            let sensor = generator.next() % 64
            time += Int(generator.next() % 900) + 100
            let value = Double(Int(generator.next() % 4_000)) / 100 - 5
            text += #"{"sensor":"building-\#(sensor % 8)/floor-\#(sensor % 4)/temp-\#(sensor)","time":\#(time),"#
            text += #""value":\#(value),"unit":"C","battery":\#(generator.next() % 100),"ok":\#(generator.next() % 16 != 0)}"#
            text += "\n"
        }
        return Array(text.utf8)
    }()
}

/// Where each packet's payload comes from: one fixed payload, or windows of ``Fixtures/telemetry`` at an
/// offset that varies by packet.
public struct Payloads: Sendable {
    /// The source bytes.
    public let bytes: [UInt8]
    /// Bytes of payload per packet.
    public let size: Int

    /// The fixed payload of `size` bytes (``Fixtures/payload(size:)``) for every packet.
    public static func fixed(size: Int) -> Payloads {
        Payloads(bytes: Fixtures.payload(size: size), size: size)
    }

    /// `size`-byte windows of telemetry, packet `i`'s at `977 i` modulo the possible starts: consecutive
    /// packets differ, and the same window doesn't come back for about a million packets. For a `size`
    /// larger than the telemetry, the fixed payload.
    public static func telemetry(size: Int) -> Payloads {
        Payloads(bytes: Fixtures.telemetry.count >= size ? Fixtures.telemetry : Fixtures.payload(size: size), size: size)
    }

    /// Packet `index`'s payload: its range of ``bytes``.
    @inline(__always)
    func range(_ index: Int) -> Range<Int> {
        guard bytes.count > size else { return 0..<size } // One payload: no division per packet.
        let start = (index &* 977) % (bytes.count &- size &+ 1)
        return start..<(start &+ size)
    }
}

/// SplitMix64: a small deterministic generator for fixtures.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Fixtures {

    /// Packet `index`'s identifier: 1 through 65,535, then 1 again.
    ///
    /// - Parameter index: The packet's position in the stream, from 0.
    /// - Returns: The identifier.
    public static func packetIdentifier(_ index: Int) -> UInt16 { UInt16(index % 65_535 + 1) }

    /// Packet `index`'s encoded size.
    ///
    /// - Parameters:
    ///   - payloadSize: Bytes of payload per packet.
    ///   - index: The packet's position in the stream, from 0; picks the topic.
    /// - Returns: The packet's size in bytes, header included.
    static func packetSize(payloadSize: Int, index: Int) -> Int {
        let payload = [UInt8](repeating: 0, count: payloadSize)
        let properties = try! MQTTProperties(validating: propertyBytes.span.bytes)
        return MQTTPacket.publish(MQTTPublish(
            qos: .atLeastOnce, topic: topics[index % topics.count].utf8Span, packetIdentifier: packetIdentifier(index),
            properties: properties, payload: payload.span.bytes
        )).encodedByteCount
    }
}
