import SocketStream
import Testing

/// Run with the PR toolchain and its Concurrency runtime (see README.md).
@Suite(.serialized) struct TransferTests {
    /// Every packet arrives, in order, checked, in every mode and placement.
    @Test(arguments: TransferMode.allCases, Placement.allCases)
    func transfers(mode: TransferMode, placement: Placement) async throws {
        let workload = Workload(payloadSize: 200, packetsPerConnection: 20_000, connections: 3)
        let result = try await Transfer.run(workload, mode: mode, placement: placement)
        #expect(result.bytes == workload.bytesPerConnection * 3)
        #expect(result.packets == 60_000)
    }

    /// Batches and buffers barely bigger than a packet: packets straddle writes and reads constantly, and the
    /// receiver carries partial packets forward.
    @Test(arguments: [64, 1_000, 5_000])
    func packetsSplitAcrossReads(payloadSize: Int) async throws {
        let packetSize = payloadSize + 100
        let workload = Workload(
            payloadSize: payloadSize, packetsPerConnection: 5_000, connections: 2,
            batchSize: packetSize * 3 / 2, receiveCapacity: packetSize + 7
        )
        let result = try await Transfer.run(workload, mode: .mqtt)
        #expect(result.packets == 10_000)
    }

    static let protections: [Protection] = [
        Protection(compression: .deflate), Protection(compression: .brotli), Protection(encrypted: true),
        Protection(encrypted: true, sealingLanes: 4),
        Protection(compression: .deflate, encrypted: true), Protection(compression: .brotli, encrypted: true),
    ]

    /// Compressed, encrypted, or both: every packet still arrives, in order, checked.
    @Test(arguments: Self.protections)
    func protectedTransfers(protection: Protection) async throws {
        let workload = Workload(payloadSize: 200, packetsPerConnection: 20_000, connections: 2)
        let result = try await Transfer.run(workload, mode: .mqtt, protection: protection)
        #expect(result.bytes == workload.bytesPerConnection * 2)
        #expect(result.packets == 40_000)
    }

    /// Small batches and buffers under protection: packets, records, and compressed blocks straddle reads.
    @Test(arguments: Self.protections)
    func protectedPacketsSplitAcrossReads(protection: Protection) async throws {
        let workload = Workload(payloadSize: 1_000, packetsPerConnection: 3_000, connections: 1, batchSize: 1_700, receiveCapacity: 33_000)
        let result = try await Transfer.run(workload, mode: .mqtt, protection: protection)
        #expect(result.packets == 3_000)
    }

    /// Packet identifiers wrap from 65,535 to 1, and the receiver follows.
    @Test func identifiersWrap() async throws {
        let workload = Workload(payloadSize: 16, packetsPerConnection: 70_000)
        let result = try await Transfer.run(workload, mode: .mqtt)
        #expect(result.packets == 70_000)
    }

    /// The checker catches a changed topic byte, packet identifier, or payload size, and leaves a partial
    /// packet for the next read.
    @Test func checkerCatchesDifferences() throws {
        let stream = Fixtures.stream(payloadSize: 32, count: 40)
        var checker = PacketChecker(payloadSize: 32)
        #expect(try checker.check(stream.span.bytes) == stream.count)
        #expect(checker.packets == 40)

        var partial = PacketChecker(payloadSize: 32)
        _ = try partial.check(stream.span.bytes.extracting(0..<(stream.count - 5)))
        #expect(partial.packets == 39)

        var wrongSize = PacketChecker(payloadSize: 33)
        #expect(throws: TransferError.self) { _ = try wrongSize.check(stream.span.bytes) }

        // Packet 20: a type byte, a 1-byte remaining length, the topic's 2-byte length and bytes, then the
        // 2-byte packet identifier. Change the topic's last byte, then the identifier's low byte.
        let start = Fixtures.stream(payloadSize: 32, count: 20).count
        let topicLength = Int(stream[start + 2]) << 8 | Int(stream[start + 3])
        for index in [start + 4 + topicLength - 1, start + 4 + topicLength + 1] {
            var corrupted = stream
            corrupted[index] ^= 0x01
            var check = PacketChecker(payloadSize: 32)
            #expect(throws: TransferError.self) { _ = try check.check(corrupted.span.bytes) }
            #expect(check.packets == 20)
        }
    }
}
