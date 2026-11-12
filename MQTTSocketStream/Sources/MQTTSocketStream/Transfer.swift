import Bytes
import MQTT
import PlatformExecutors

/// What a transfer moved, and how long it took.
public struct TransferResult: Sendable, CustomStringConvertible {
    /// Bytes received, across all connections.
    public var bytes: Int
    /// PUBLISH packets received, across all connections.
    public var packets: Int
    /// Wall-clock time from the first listener to the last receiver's end of stream.
    public var duration: Duration

    /// `duration` in seconds.
    public var seconds: Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    /// Payload-agnostic throughput in GB (10^9 bytes) per second: every byte of every packet, MQTT headers included.
    public var gigabytesPerSecond: Double { Double(bytes) / seconds / 1e9 }
    /// Packets received per second.
    public var packetsPerSecond: Double { Double(packets) / seconds }

    /// A one-line summary: volume, time, throughput, and packet rate.
    public var description: String {
        let gigabytes = Double(bytes) / 1e9
        return "\(rounded(gigabytes, 2)) GB, \(packets) packets in \(rounded(seconds * 1e3, 1)) ms: "
            + "\(rounded(gigabytesPerSecond, 2)) GB/s, \(rounded(packetsPerSecond / 1e6, 2)) M packets/s"
    }
}

func rounded(_ value: Double, _ places: Int) -> String {
    let scale = (0..<places).reduce(1.0) { result, _ in result * 10 }
    return String((value * scale).rounded() / scale)
}

/// A transfer that went wrong: a count mismatch, or a received packet that is malformed or isn't the next one sent.
public struct TransferError: Error, CustomStringConvertible {
    /// What went wrong.
    public var description: String
}

/// How the bytes are produced and consumed.
public enum TransferMode: String, Sendable, CaseIterable {
    /// MQTT PUBLISH packets: encoded with `BytesWriter`, parsed and checked with `BytesReader`.
    case mqtt
    /// The same number of bytes, unencoded and unparsed: the socket's own ceiling.
    case raw
}

/// Which executor threads run the senders and receivers.
public enum Placement: String, Sendable, CaseIterable {
    /// One `PThreadTaskExecutor` pool (`Workload.poolSize` threads, one per core by default) for every task.
    /// The pool hands each job to its next thread in turn, so a task resumes on a different thread after
    /// most reads and writes.
    case sharedPool
    /// A single-thread `PThreadTaskExecutor` for each sender and each receiver: a task, its socket's
    /// kqueue, and its buffers all stay on one thread.
    case threadPerTask
}

/// Every async function here is `nonisolated(nonsending)`, like swift-platform-executors' own: it runs on
/// its caller's executor. A task's work stays where its executor preference puts it, and calls between
/// these functions, and into the socket operations, make no executor checks (`swift_task_switch`): a plain
/// `nonisolated` async function checks on entry and after each call it makes. The only switches are where
/// tasks start, on the executors they prefer.
public enum Transfer {
    /// Runs `workload` over loopback TCP: `connections` sender/receiver pairs, concurrently, on
    /// `PThreadTaskExecutor`s (kqueue). Times from the first listener to the last receiver's end of stream.
    ///
    /// Each pair has its own listener, bound and accepted by its receiver: a connection keeps the scheduler
    /// it was created on, so accepting every connection in one task would put every receiver's I/O on that
    /// task's executor.
    ///
    /// - Parameters:
    ///   - workload: The packets, connections, and buffer sizes to transfer.
    ///   - mode: Whether to send MQTT packets or the same number of unencoded bytes.
    ///   - placement: Which executor threads run the senders and receivers.
    /// - Returns: The bytes and packets received, and the time taken.
    /// - Throws: `TransferError` if a receiver gets a packet that is malformed or isn't the next one expected,
    ///   the stream ends inside a packet, or the bytes sent or received (or, in `.mqtt`, the packets received)
    ///   differ from the workload's totals; socket errors from the transport.
    public nonisolated(nonsending) static func run(
        _ workload: Workload, mode: TransferMode, placement: Placement = .threadPerTask
    ) async throws -> TransferResult {
        let executorCount = placement == .sharedPool ? 1 : 2 * workload.connections
        return try await withExecutors(count: executorCount, poolSize: placement == .sharedPool ? workload.poolSize : 1) {
            executors in
            let receiverExecutor = { (pair: Int) in executors[placement == .sharedPool ? 0 : 2 * pair] }
            let senderExecutor = { (pair: Int) in executors[placement == .sharedPool ? 0 : 2 * pair + 1] }
            let clock = ContinuousClock()
            let start = clock.now
            let (sent, received, packets) = try await withThrowingTaskGroup(of: (Int, Int, Int).self) { group in
                for pair in 0..<workload.connections {
                    let sender = senderExecutor(pair)
                    group.addTask(executorPreference: receiverExecutor(pair)) {
                        try await runPair(workload, mode: mode, senderExecutor: sender)
                    }
                }
                var totals = (0, 0, 0)
                for try await (sent, received, packets) in group {
                    totals = (totals.0 + sent, totals.1 + received, totals.2 + packets)
                }
                return totals
            }
            let duration = start.duration(to: clock.now)

            let expectedBytes = workload.bytesPerConnection * workload.connections
            guard sent == expectedBytes, received == expectedBytes else {
                throw TransferError(description: "Sent \(sent) and received \(received) bytes, expected \(expectedBytes)")
            }
            if mode == .mqtt, packets != workload.packetsPerConnection * workload.connections {
                throw TransferError(description: "Received \(packets) packets")
            }
            return TransferResult(bytes: received, packets: workload.packetsPerConnection * workload.connections, duration: duration)
        }
    }

    /// Runs one pair as its receiver: binds a listener, starts the sender on its executor, accepts, and
    /// receives.
    ///
    /// - Parameters:
    ///   - workload: The transfer to run.
    ///   - mode: Whether to send MQTT packets or unencoded bytes.
    ///   - senderExecutor: The executor the sender task prefers.
    /// - Returns: The bytes sent, the bytes received, and the packets received (0 in `.raw`).
    /// - Throws: Socket errors, or `TransferError` from the receiver.
    nonisolated(nonsending) static func runPair(
        _ workload: Workload, mode: TransferMode, senderExecutor: PThreadTaskExecutor
    ) async throws -> (Int, Int, Int) {
        let listener = try await TCPListener.bind(to: .v4(SocketAddress.V4(address: .loopback, port: 0)))
        let address = try listener.localAddress
        let result = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask(executorPreference: senderExecutor) {
                switch mode {
                case .mqtt: try await sendPackets(workload, to: address)
                case .raw: try await sendRaw(workload, to: address)
                }
            }
            let connection = try await listener.accept()
            let (received, packets) = switch mode {
            case .mqtt: try await receivePackets(workload, on: connection)
            case .raw: try await (receiveRaw(workload, on: connection), 0)
            }
            let sent = try await group.next()!
            return (sent, received, packets)
        }
        try await listener.close()
        return result
    }

    /// Runs `body` with `count` executors of `poolSize` threads each, all stopped when it returns.
    ///
    /// - Parameters:
    ///   - count: How many executors to start.
    ///   - poolSize: Threads in each executor (`nil`: one per core).
    ///   - body: Runs on the caller's executor with the started executors, in creation order.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws, or an error from starting an executor.
    nonisolated(nonsending) static func withExecutors<Return>(
        count: Int, poolSize: Int?, _ body: nonisolated(nonsending) ([PThreadTaskExecutor]) async throws -> Return
    ) async throws -> Return {
        var executors: [PThreadTaskExecutor] = []
        nonisolated(nonsending) func nest(_ remaining: Int) async throws -> Return {
            guard remaining > 0 else { return try await body(executors) }
            return try await PThreadTaskExecutor.withExecutor(
                name: "MQTTSocketStream-\(executors.count)", poolSize: poolSize, ioBackend: .kqueue
            ) { executor in
                executors.append(executor)
                return try await nest(remaining - 1)
            }
        }
        return try await nest(count)
    }

    // MARK: MQTT

    /// Connects, then encodes the packets into batches and writes each.
    ///
    /// - Parameters:
    ///   - workload: The packets to send and the batch size.
    ///   - address: The listener to connect to.
    /// - Returns: The bytes written.
    /// - Throws: Socket errors from connecting, writing, or closing.
    nonisolated(nonsending) static func sendPackets(_ workload: Workload, to address: SocketAddress) async throws -> Int {
        var connection = try await TCPConnection.connect(to: address)
        let payload = Fixtures.payload(size: workload.payloadSize)
        var batch = [UInt8](repeating: 0, count: workload.batchSize)
        var next = 0
        var sent = 0
        while next < workload.packetsPerConnection {
            let count = encode(into: &batch, from: &next, until: workload.packetsPerConnection, payload: payload)
            try await connection.write(from: batch.span.bytes.extracting(0..<count))
            sent += count
        }
        try await connection.close()
        return sent
    }

    /// Encodes packets `next..<end` into `batch` until it can't hold the next one or they're all done.
    ///
    /// A packet that doesn't fit makes the writer report `insufficientCapacity` without writing anything;
    /// encoding stops there and the packet is left for the next batch.
    ///
    /// Each topic is a view of the fixtures' topic table, not of a `String`: `String.utf8Span` isn't
    /// inlinable, so even a borrowed `String` is retained and released around the call. Viewing the table's
    /// bytes as UTF-8 is the one-pass ASCII check, two vector tests per topic.
    ///
    /// - Parameters:
    ///   - batch: The buffer to encode into, overwritten from its start.
    ///   - next: The index of the next packet to encode; advanced past each packet encoded.
    ///   - end: The index after the last packet to encode.
    ///   - payload: The payload of every packet.
    /// - Returns: The bytes encoded into `batch`.
    /// - Precondition: `batch` can hold at least one packet, and encoding fails only for lack of capacity.
    public static func encode(into batch: inout [UInt8], from next: inout Int, until end: Int, payload: [UInt8]) -> Int {
        var span = batch.mutableSpan
        var writer = BytesWriter(&span)
        // Bound to a local first: a span of another file's global is rejected ("lifetime-dependent value
        // escapes its scope") when files compile separately (debug builds), though not with whole-module
        // optimization (release builds). Once per batch, not per packet.
        let propertyBytes = Fixtures.propertyBytes
        let properties = try! MQTTProperties(validating: propertyBytes.span.bytes)
        let (topicBytes, topicEnds) = Fixtures.topicTable
        while next < end {
            let index = next % topicEnds.count
            let topic = UTF8Span(
                validating: topicBytes.span.bytes.extracting((index == 0 ? 0 : topicEnds[index - 1])..<topicEnds[index]),
                excluding: { _ in .none }
            )!
            do throws(BytesError) {
                try MQTTPublish(
                    qos: .atLeastOnce, topic: topic,
                    packetIdentifier: Fixtures.packetIdentifier(next), properties: properties, payload: payload.span.bytes
                ).write(to: &writer)
            } catch {
                precondition(error == .insufficientCapacity && writer.byteCount > 0, "Encoding failed: \(error)")
                break
            }
            next += 1
        }
        return writer.byteCount
    }

    /// Reads until the end of the stream, parsing and checking every packet, then closes the connection.
    ///
    /// - Parameters:
    ///   - workload: Supplies the payload size to expect and the receive buffer's capacity.
    ///   - connection: The accepted connection, consumed.
    /// - Returns: The bytes and packets received.
    /// - Throws: `TransferError` if a packet is malformed or isn't the next one, or the stream ends inside
    ///   a packet; socket errors from reading or closing.
    nonisolated(nonsending) static func receivePackets(
        _ workload: Workload, on connection: consuming TCPConnection
    ) async throws -> (Int, Int) {
        var connection = connection
        var buffer = ReceiveBuffer(capacity: workload.receiveCapacity)
        var checker = PacketChecker(payloadSize: workload.payloadSize)
        var bytes = 0
        while true {
            let count = try await buffer.read(from: &connection)
            if count == 0 { break }
            bytes += count
            try buffer.consume(checker.check(buffer.unread))
        }
        try await connection.close()
        guard buffer.isEmpty else { throw TransferError(description: "The stream ended inside a packet") }
        return (bytes, checker.packets)
    }

    // MARK: Raw

    /// Connects, then writes the same number of bytes as the MQTT stream, in batches of unencoded bytes.
    ///
    /// - Parameters:
    ///   - workload: Supplies the byte count and the batch size.
    ///   - address: The listener to connect to.
    /// - Returns: The bytes written.
    /// - Throws: Socket errors from connecting, writing, or closing.
    nonisolated(nonsending) static func sendRaw(_ workload: Workload, to address: SocketAddress) async throws -> Int {
        var connection = try await TCPConnection.connect(to: address)
        let batch = [UInt8](repeating: 0x5A, count: workload.batchSize)
        var remaining = workload.bytesPerConnection
        while remaining > 0 {
            let count = min(remaining, batch.count)
            try await connection.write(from: batch.span.bytes.extracting(0..<count))
            remaining -= count
        }
        try await connection.close()
        return workload.bytesPerConnection
    }

    /// Reads until the end of the stream, discarding the bytes, then closes the connection.
    ///
    /// - Parameters:
    ///   - workload: Supplies the receive buffer's capacity.
    ///   - connection: The accepted connection, consumed.
    /// - Returns: The bytes received.
    /// - Throws: Socket errors from reading or closing.
    nonisolated(nonsending) static func receiveRaw(_ workload: Workload, on connection: consuming TCPConnection) async throws -> Int {
        var connection = connection
        var buffer = ReceiveBuffer(capacity: workload.receiveCapacity)
        var bytes = 0
        while true {
            let count = try await buffer.read(from: &connection)
            if count == 0 { break }
            bytes += count
            buffer.consume(count)
        }
        try await connection.close()
        return bytes
    }
}
