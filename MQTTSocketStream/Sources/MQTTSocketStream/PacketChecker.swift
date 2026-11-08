import Bytes
import MQTT

/// The receiving end: parses the complete packets at the start of the received bytes and checks that each
/// is the next one sent, a PUBLISH with the next packet identifier, topic, and payload size.
///
/// Nothing is allocated, retained, or copied per packet: packets are views of the received bytes, read as
/// frames and parsed as PUBLISH (`MQTTPublish(parsing:)`), and the topics expected are held here, end to
/// end in one array, so a check reads no global and compares 16 bytes at a time.
public struct PacketChecker {
    public let payloadSize: Int
    /// The packets checked so far.
    public private(set) var packets = 0

    private let topicBytes: [UInt8]
    /// Topic `i` is `topicBytes[topicEnds[i - 1]..<topicEnds[i]]` (from 0 for the first).
    private let topicEnds: [Int]
    private var topicIndex = 0
    private var identifier: UInt16 = 1

    /// A checker expecting packet 0 next. Takes references to the fixtures' topic table: no allocation.
    public init(payloadSize: Int) {
        self.payloadSize = payloadSize
        (topicBytes, topicEnds) = Fixtures.topicTable
    }

    /// Parses and checks the complete packets at the start of `bytes`, returning the bytes they took. A
    /// packet that hasn't fully arrived is left for the next call, with more bytes.
    ///
    /// Throws if a packet is malformed or isn't the one expected.
    public mutating func check(_ bytes: RawSpan) throws(TransferError) -> Int {
        var reader = BytesReader(bytes)
        var isExpected = true
        do throws(MQTTError) {
            // Frames, not `MQTTPacket.read(from:)`: dispatching on the type and parsing the PUBLISH directly
            // skips building `MQTTPacket`, a 153-byte enum, and testing its case.
            while let frame = try MQTTFrame.read(from: &reader) {
                guard frame.type == .publish, isNext(try MQTTPublish(parsing: frame)) else {
                    isExpected = false
                    break
                }
                advance()
            }
        } catch {
            throw TransferError(description: "Packet \(packets) is malformed: \(error)")
        }
        guard isExpected else { throw TransferError(description: "Packet \(packets) isn't the one sent") }
        return reader.byteOffset
    }

    private func isNext(_ publish: MQTTPublish) -> Bool {
        let start = topicIndex == 0 ? 0 : topicEnds[topicIndex - 1]
        return publish.packetIdentifier == identifier
            && publish.payload.byteCount == payloadSize
            && publish.topic.span.bytes.bytesEqual(topicBytes.span.bytes.extracting(start..<topicEnds[topicIndex]))
    }

    /// On to the next packet's identifier (1 through 65,535, then 1 again) and topic, without dividing.
    private mutating func advance() {
        packets += 1
        identifier = identifier == .max ? 1 : identifier + 1
        topicIndex = topicIndex == topicEnds.count - 1 ? 0 : topicIndex + 1
    }
}
