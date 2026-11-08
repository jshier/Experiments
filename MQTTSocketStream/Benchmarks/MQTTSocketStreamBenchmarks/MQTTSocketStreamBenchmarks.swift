import Benchmark
import MQTTSocketStream

// Run with the toolchain's Concurrency runtime: Scripts/benchmark.sh (see README.md).

extension BenchmarkMetric {
    static let bandwidth = BenchmarkMetric.custom("Bandwidth (MB/s)", polarity: .prefersLarger, useScalingFactor: false)
    static let packetRate = BenchmarkMetric.custom("Packets (K/s)", polarity: .prefersLarger, useScalingFactor: false)
}

/// About `bytes` per connection of `payloadSize`-byte PUBLISH packets.
func workload(payloadSize: Int, bytes: Int = 512 << 20, connections: Int) -> Workload {
    Workload(payloadSize: payloadSize, packetsPerConnection: bytes / (payloadSize + 64), connections: connections)
}

// The receiving and sending ends without a socket: 10,000 64-byte-payload packets, checked as a receiver
// would get them (in 64 KB reads, partial packets carried over) or encoded into 256 KB batches.
let packetCount = 10_000
let stream = Fixtures.stream(payloadSize: 64, count: packetCount)
let payload = Fixtures.payload(size: 64)
nonisolated(unsafe) var batch = [UInt8](repeating: 0, count: 256 << 10)

/// Checks `stream` as 64 KB reads would deliver it, returning the packets checked.
func checkStream() throws -> Int {
    var checker = PacketChecker(payloadSize: 64)
    var start = 0
    while start < stream.count {
        start += try checker.check(stream.span.bytes.extracting(start..<min(start + (64 << 10), stream.count)))
    }
    return checker.packets
}

/// Encodes the same packets into `batch`, a batch at a time.
func encodeStream() -> Int {
    var next = 0
    var bytes = 0
    while next < packetCount {
        bytes += Transfer.encode(into: &batch, from: &next, until: packetCount, payload: payload)
    }
    return bytes
}

let benchmarks: @Sendable () -> Void = {
    // No allocation count for the transfers: the malloc interposer that counts them cost large-packet
    // transfers 10% of their bandwidth. The "Transfer allocations" benchmarks below count them.
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuTotal, .bandwidth, .packetRate],
        units: [.bandwidth: .count, .packetRate: .count], // Unscaled, so MB/s and K packets/s read as labeled.
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: .seconds(10),
        maxIterations: 10
    )

    /// One transfer per iteration. Bandwidth and packet rate come from the transfer's own timing, from the
    /// first listener to the last end of stream: executor threads are started before and stopped after.
    func transfer(_ name: String, _ workload: Workload, mode: TransferMode = .mqtt, placement: Placement = .threadPerTask) {
        Benchmark(name) { benchmark in
            for _ in benchmark.scaledIterations {
                let result = try await Transfer.run(workload, mode: mode, placement: placement)
                benchmark.measurement(.bandwidth, Int(Double(result.bytes) / result.seconds / 1e6))
                benchmark.measurement(.packetRate, Int(result.packetsPerSecond / 1e3))
            }
        }
    }

    // Payload sizes on one connection: from packet-rate bound (64 B) to bandwidth bound (16 KB and up).
    for (label, size) in [("64 B", 64), ("1 KB", 1_024), ("16 KB", 16_384), ("64 KB", 65_536)] {
        transfer("MQTT \(label) payloads, 1 connection", workload(payloadSize: size, connections: 1))
    }
    // The same bytes with no encoding or parsing: loopback TCP's own ceiling.
    transfer("Raw (1 KB-packet stream's bytes), 1 connection", workload(payloadSize: 1_024, connections: 1), mode: .raw)

    // Connections: small packets scale with cores; bandwidth is capped by loopback TCP, which doesn't.
    for connections in [2, 4, 8] {
        transfer("MQTT 64 B payloads, \(connections) connections",
                 workload(payloadSize: 64, bytes: 256 << 20, connections: connections))
    }
    for connections in [2, 4] {
        transfer("MQTT 16 KB payloads, \(connections) connections",
                 workload(payloadSize: 16_384, bytes: 256 << 20, connections: connections))
        transfer("Raw (16 KB-packet stream's bytes), \(connections) connections",
                 workload(payloadSize: 16_384, bytes: 256 << 20, connections: connections), mode: .raw)
    }

    // Placement: one shared pool against a thread per sender and receiver.
    for placement in Placement.allCases {
        transfer("MQTT 1 KB payloads, 4 connections, \(placement)",
                 workload(payloadSize: 1_024, bytes: 256 << 20, connections: 4), placement: placement)
    }

    // Each end's per-packet work alone, in memory on one core: the most packets a connection could carry.
    let inMemory = Benchmark.Configuration(
        metrics: [.wallClock, .instructions, .mallocCountTotal, .packetRate],
        units: [.packetRate: .count],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .seconds(1),
        maxIterations: 1_000
    )
    Benchmark("Check 64 B payload packets in memory", configuration: inMemory) { benchmark in
        for _ in benchmark.scaledIterations {
            let start = ContinuousClock.now
            let checked = try checkStream()
            precondition(checked == packetCount)
            let seconds = (ContinuousClock.now - start) / .seconds(1)
            benchmark.measurement(.packetRate, Int(Double(packetCount) / seconds / 1e3))
        }
    }
    Benchmark("Encode 64 B payload packets in memory", configuration: inMemory) { benchmark in
        for _ in benchmark.scaledIterations {
            let start = ContinuousClock.now
            precondition(encodeStream() == stream.count)
            let seconds = (ContinuousClock.now - start) / .seconds(1)
            benchmark.measurement(.packetRate, Int(Double(packetCount) / seconds / 1e3))
        }
    }

    // A transfer's allocations, the whole process's: executors, sockets, buffers, and tasks. The same
    // number for 10 times the packets (and reads and writes), so none are per packet or per I/O.
    for packets in [100_000, 1_000_000] {
        Benchmark("Transfer allocations: \(packets) packets of 64 B payloads",
                  configuration: .init(metrics: [.mallocCountTotal], warmupIterations: 1, maxIterations: 5)) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(try await Transfer.run(Workload(payloadSize: 64, packetsPerConnection: packets), mode: .mqtt))
            }
        }
    }

    // Allocation checks: each end's per-packet work must not allocate. Static thresholds of zero (in
    // `Thresholds/`), so `Scripts/benchmark.sh thresholds check --filter 'Allocations:.*'` fails if either
    // does. Warmup runs the fixtures' lazy initializers.
    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    // No spaces: `thresholds update` writes "_" for them in file names, but `thresholds check` looks files
    // up by the unaltered name (benchmark 1.38.1, ordo-one/benchmark#373).
    Benchmark("Allocations:Check_64_B_payload_packets", configuration: zeroAllocations) { benchmark in
        for _ in benchmark.scaledIterations { blackHole(try checkStream()) }
    }
    Benchmark("Allocations:Encode_64_B_payload_packets", configuration: zeroAllocations) { benchmark in
        for _ in benchmark.scaledIterations { blackHole(encodeStream()) }
    }
}
