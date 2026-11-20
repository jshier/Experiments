import Benchmark
import BytesTestSupport
import SocketStream

// Run with the toolchain's Concurrency runtime: `../Tools/toolchain . -- swift package --disable-sandbox
// benchmark` (see README.md).

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
let payloads = Payloads.fixed(size: 64)
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

/// Encodes `packetCount` packets into `batch`, a batch at a time, returning the bytes encoded.
func encodeStream() -> Int {
    var next = 0
    var bytes = 0
    while next < packetCount {
        bytes += Transfer.encode(into: &batch, from: &next, until: packetCount, payloads: payloads)
    }
    return bytes
}

/// One protection's in-memory pipelines, built on first use (`Lazy`), with the stream they protect checked to
/// unprotect to every packet. The benchmark tool starts this executable once to list the benchmarks and again for
/// each benchmark, and every start runs the registration closure: building them there cost every process three
/// protected streams.
func lazyPipelines(_ protection: Protection) -> Lazy<InMemoryProtection> {
    Lazy {
        let bench = InMemoryProtection.make(protection, payloadSize: 64, packets: packetCount)
        precondition(bench.unprotect() == packetCount)
        return bench
    }
}

let benchmarks: @Sendable () -> Void = {
    // No allocation count for the transfers: the malloc interposer that counts them cost large-packet
    // transfers 10% of their bandwidth. The "Transfer allocations" benchmarks below count them.
    //
    // A transfer takes 0.1–0.8 s (512 MB plain at 3–7 GB/s, 256 MB protected at 0.35–1.5 GB/s): one warmup and
    // 3 measured, at most 3 s, where 10 (up to 10 s) took the suite past 5 minutes. Single transfers vary ±20%,
    // and the median of 3 doesn't remove that: compare transfers interleaved, A/B, as RESULTS.md does.
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuTotal, .bandwidth, .packetRate],
        units: [.bandwidth: .count, .packetRate: .count], // Unscaled, so MB/s and K packets/s read as labeled.
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: .seconds(3),
        maxIterations: 3
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

    // Compressed, encrypted, both: the same packets through Bytes pipelines on the way.
    let protections = [
        Protection(compression: .deflate), Protection(compression: .brotli), Protection(encrypted: true),
        Protection(encrypted: true, sealingLanes: 4),
        Protection(compression: .deflate, encrypted: true), Protection(compression: .brotli, encrypted: true),
    ]
    for protection in protections {
        for (label, size) in [("64 B", 64), ("1 KB", 1_024), ("16 KB", 16_384)] {
            Benchmark("MQTT \(label) payloads, \(protection), 1 connection") { benchmark in
                for _ in benchmark.scaledIterations {
                    let result = try await Transfer.run(workload(payloadSize: size, bytes: 256 << 20, connections: 1), mode: .mqtt, protection: protection)
                    benchmark.measurement(.bandwidth, Int(Double(result.bytes) / result.seconds / 1e6))
                    benchmark.measurement(.packetRate, Int(result.packetsPerSecond / 1e3))
                }
            }
        }
    }

    // Placement: one shared pool against a thread per sender and receiver.
    for placement in Placement.allCases {
        transfer("MQTT 1 KB payloads, 4 connections, \(placement)",
                 workload(payloadSize: 1_024, bytes: 256 << 20, connections: 4), placement: placement)
    }

    // Each end's per-packet work alone, in memory on one core: the most packets a connection could carry.
    // Only the work in the loop: packets per second are the framework's throughput (iterations per second)
    // times `packetCount`. Their results are checked once, in the setup of the benchmarks that run them.
    // 0.2–3 ms per iteration: 100 samples or half a second, medians within 1% of 1,000 samples.
    let inMemory = Benchmark.Configuration(
        metrics: [.wallClock, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .milliseconds(500),
        maxIterations: 100
    )
    let checkCodec: () async throws -> Void = {
        let checked = try checkStream()
        precondition(checked == packetCount)
        precondition(encodeStream() == stream.count)
    }
    Benchmark("Check 64 B payload packets in memory", configuration: inMemory, closure: { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(checkStream())
        }
    }, setup: checkCodec)
    Benchmark("Encode 64 B payload packets in memory", configuration: inMemory, closure: { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(encodeStream())
        }
    }, setup: checkCodec)

    // The pipelines' per-packet work alone: the same 10,000 packets encoded, compressed, and sealed (a flush
    // per 256 KB batch), or opened, decompressed, and checked, in memory. Each iteration is one whole stream,
    // through pipelines built once (in setup, by the process that runs the benchmark) and reset.
    let pipelineAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    for protection in [Protection(compression: .deflate, encrypted: true), Protection(compression: .brotli, encrypted: true), Protection(encrypted: true)] {
        let pipelines = lazyPipelines(protection)
        let prepare: () async throws -> Void = { _ = pipelines.value }
        let name = "\(protection)".replacingOccurrences(of: " ", with: "")
        Benchmark("Protect 64 B payload packets in memory, \(protection)", configuration: inMemory, closure: { benchmark in
            let bench = pipelines.value
            for _ in benchmark.scaledIterations {
                blackHole(bench.protect())
            }
        }, setup: prepare)
        Benchmark("Unprotect 64 B payload packets in memory, \(protection)", configuration: inMemory, closure: { benchmark in
            let bench = pipelines.value
            for _ in benchmark.scaledIterations {
                blackHole(bench.unprotect())
            }
        }, setup: prepare)
        Benchmark("Allocations:Protect_64_B_payload_packets_\(name)", configuration: pipelineAllocations, closure: { benchmark in
            let bench = pipelines.value
            for _ in benchmark.scaledIterations {
                blackHole(bench.protect())
            }
        }, setup: prepare)
        Benchmark("Allocations:Unprotect_64_B_payload_packets_\(name)", configuration: pipelineAllocations, closure: { benchmark in
            let bench = pipelines.value
            for _ in benchmark.scaledIterations {
                blackHole(bench.unprotect())
            }
        }, setup: prepare)
    }

    // A transfer's allocations, the whole process's: executors, sockets, buffers, and tasks. The same
    // number for 10 times the packets (and reads and writes), so none are per packet or per I/O.
    for packets in [100_000, 1_000_000] {
        Benchmark("Transfer allocations: \(packets) packets of 64 B payloads",
                  configuration: .init(metrics: [.mallocCountTotal], warmupIterations: 1, maxIterations: 3)) { benchmark in
            for _ in benchmark.scaledIterations {
                try await blackHole(Transfer.run(Workload(payloadSize: 64, packetsPerConnection: packets), mode: .mqtt))
            }
        }
    }

    // Allocation checks: each end's per-packet work must not allocate. Static thresholds of zero (in
    // `Thresholds/`), so `benchmark thresholds check --filter 'Allocations:.*'` (through `../Tools/toolchain .`)
    // fails if either does. Warmup runs the fixtures' lazy initializers.
    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    // No spaces: `thresholds update` writes "_" for them in file names, but `thresholds check` looks files
    // up by the unaltered name (benchmark 1.38.1, ordo-one/benchmark#373).
    Benchmark("Allocations:Check_64_B_payload_packets", configuration: zeroAllocations) { benchmark in
        for _ in benchmark.scaledIterations {
            try blackHole(checkStream())
        }
    }
    Benchmark("Allocations:Encode_64_B_payload_packets", configuration: zeroAllocations) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(encodeStream())
        }
    }
}
