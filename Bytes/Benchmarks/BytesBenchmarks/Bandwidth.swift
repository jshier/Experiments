import Benchmark
import Bytes
import Dispatch
import Foundation

// Read bandwidth: how fast `Bytes` iterates every value of each width, from 1 bit to 16 bytes, compared
// with the fastest raw read of the same memory (a hand-written 128-byte SIMD loop). Each workload adds
// every value into a wrapping sum of its own width (two 64-bit halves for 128-bit values), so nothing can
// be skipped and the consumer costs one add per value in the narrowest lanes; byte groups are converted
// from big-endian (a byte swap per value), so there's real per-value work.

extension BenchmarkMetric {
    static let bandwidth = BenchmarkMetric.custom("Bandwidth (MB/s)", polarity: .prefersLarger, useScalingFactor: false)
}

/// One way of reading a buffer: a name, the byte granularity it can be split at for parallel reads, and
/// the read itself, returning a checksum.
struct Workload: Sendable {
    let name: String
    let unit: Int
    var allCores = true
    let read: @Sendable (RawSpan) -> UInt64
}

func forInGroupWorkload<T: ByteGroup>(_: T.Type) -> Workload {
    Workload(name: "for-in \(T.self)", unit: T.byteCount, allCores: false) { span in
        let reader = BytesReader(span)
        let values = reader.values(of: T.self, .bigEndian)
        if T.Integer.bitWidth > 64 {
            var sum: UInt64 = 0
            for value in values {
                sum &+= fold(value)
            }
            return sum
        }
        var sum: T.Integer = 0
        for value in values {
            sum &+= value
        }
        return UInt64(truncatingIfNeeded: sum)
    }
}

func forInBitsWorkload<let width: Int>(_: Bits<width>.Type, name: String) -> Workload {
    Workload(name: "for-in \(name)", unit: width, allCores: false) { span in
        let reader = BytesReader(span)
        let values = reader.values(of: Bits<width>.self)
        var sum: UInt8 = 0
        for value in values {
            sum &+= value.rawValue
        }
        return UInt64(sum)
    }
}

/// Bulk reads into a preallocated output (`read(_:_:into:)`), big-endian: for 3- and 5–7-byte groups the
/// path that uses NEON table lookups with the `NEONShuffle` trait.
nonisolated(unsafe) let bulkReadDestination = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 30, alignment: 1 << 14)

func bulkReadWorkload<T: ByteGroup>(_: T.Type) -> Workload {
    Workload(name: "read(_:_:into:) \(T.self)", unit: T.byteCount, allCores: false) { span in
        var reader = BytesReader(span)
        let count = span.byteCount / T.byteCount
        let destination = bulkReadDestination.bindMemory(to: T.Integer.self)
        var output = OutputSpan(buffer: UnsafeMutableBufferPointer(rebasing: destination[..<count]), initializedCount: 0)
        try! reader.read(T.self, .bigEndian, into: &output)
        let written = output.finalize(for: UnsafeMutableBufferPointer(rebasing: destination[..<count]))
        return UInt64(written) &+ UInt64(truncatingIfNeeded: destination[written / 2])
    }
}

/// `for byte in reader`: `BytesReader`'s own conformance, one zero-copy span of the memory.
let forInBytes = Workload(name: "for-in Bytes (UInt8)", unit: 1, allCores: false) { span in
    let reader = BytesReader(span)
    var sum: UInt8 = 0
    for byte in reader {
        sum &+= byte
    }
    return UInt64(sum)
}

/// Every bit of `value`, folded into 64 bits.
@inline(__always)
func fold<I: FixedWidthInteger>(_ value: I) -> UInt64 {
    I.bitWidth > 64
        ? UInt64(truncatingIfNeeded: value) &+ UInt64(truncatingIfNeeded: value >> 64)
        : UInt64(truncatingIfNeeded: value)
}

func groupWorkload<T: ByteGroup>(_: T.Type) -> Workload {
    Workload(name: "\(T.self)", unit: T.byteCount) { span in
        var reader = BytesReader(span)
        if T.Integer.bitWidth > 64 {
            // 128-bit adds need a carry between halves and can't vectorize; sum the halves as 64-bit lanes.
            var sum: UInt64 = 0
            reader.forEach(T.self) { sum &+= fold($0.bigEndian) }
            return sum
        }
        var sum: T.Integer = 0
        reader.forEach(T.self) { sum &+= $0.bigEndian }
        return UInt64(truncatingIfNeeded: sum)
    }
}

func bitsWorkload<let width: Int>(_: Bits<width>.Type, name: String) -> Workload {
    // A block of `width` bytes holds exactly 8 values, so chunks split at multiples of `width`.
    Workload(name: name, unit: width) { span in
        var reader = BytesReader(span)
        var sum: UInt8 = 0
        reader.forEach(Bits<width>.self) { sum &+= $0.rawValue }
        return UInt64(sum)
    }
}

/// The reference: unchecked 128-byte SIMD loads, summed as 64-bit lanes. Close to the most a core can read.
let rawRead = Workload(name: "Raw SIMD read (reference)", unit: 128) { span in
    var accumulator = SIMD16<UInt64>()
    let blocks = span.byteCount / 128
    span.withUnsafeBytes { buffer in
        for block in 0..<blocks {
            accumulator &+= buffer.loadUnaligned(fromByteOffset: block * 128, as: SIMD16<UInt64>.self)
        }
    }
    return accumulator.wrappedSum()
}

/// Deterministic pseudo-random bytes (SplitMix64), written in full so every page is resident.
func randomBuffer(byteCount: Int) -> [UInt8] {
    [UInt8](unsafeUninitializedCapacity: byteCount) { buffer, initializedCount in
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let words = UnsafeMutableRawBufferPointer(buffer)
        for offset in stride(from: 0, to: byteCount - 7, by: 8) {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            words.storeBytes(of: z ^ (z >> 31), toByteOffset: offset, as: UInt64.self)
        }
        for offset in (byteCount & ~7)..<byteCount {
            buffer[offset] = 0xA5
        }
        initializedCount = byteCount
    }
}

/// Every read workload: the bandwidth benchmarks, and their allocation counts (`Allocations.swift`).
func readWorkloads() -> [Workload] {
    [
        rawRead,
        bitsWorkload(Bits<1>.self, name: "Bit"),
        bitsWorkload(Bits<2>.self, name: "Crumb"),
        bitsWorkload(Bits<3>.self, name: "Bits<3>"),
        bitsWorkload(Bits<4>.self, name: "Nibble"),
        bitsWorkload(Bits<5>.self, name: "Bits<5>"),
        bitsWorkload(Bits<6>.self, name: "Bits<6>"),
        bitsWorkload(Bits<7>.self, name: "Bits<7>"),
        bitsWorkload(Bits<8>.self, name: "Byte"),
        groupWorkload(Byte2.self), groupWorkload(Byte3.self), groupWorkload(Byte4.self),
        groupWorkload(Byte5.self), groupWorkload(Byte6.self), groupWorkload(Byte7.self),
        groupWorkload(Byte8.self), groupWorkload(Byte9.self), groupWorkload(Byte10.self),
        groupWorkload(Byte11.self), groupWorkload(Byte12.self), groupWorkload(Byte13.self),
        groupWorkload(Byte14.self), groupWorkload(Byte15.self), groupWorkload(Byte16.self),
        // The same widths through `for`-`in` (`Iterable`), one core only.
        forInBytes,
        forInBitsWorkload(Bits<1>.self, name: "Bit"),
        forInBitsWorkload(Bits<2>.self, name: "Crumb"),
        forInBitsWorkload(Bits<3>.self, name: "Bits<3>"),
        forInBitsWorkload(Bits<4>.self, name: "Nibble"),
        forInBitsWorkload(Bits<5>.self, name: "Bits<5>"),
        forInBitsWorkload(Bits<6>.self, name: "Bits<6>"),
        forInBitsWorkload(Bits<7>.self, name: "Bits<7>"),
        forInBitsWorkload(Bits<8>.self, name: "Byte"),
        forInGroupWorkload(Byte2.self), forInGroupWorkload(Byte3.self), forInGroupWorkload(Byte4.self),
        forInGroupWorkload(Byte5.self), forInGroupWorkload(Byte6.self), forInGroupWorkload(Byte7.self),
        forInGroupWorkload(Byte8.self), forInGroupWorkload(Byte9.self), forInGroupWorkload(Byte10.self),
        forInGroupWorkload(Byte11.self), forInGroupWorkload(Byte12.self), forInGroupWorkload(Byte13.self),
        forInGroupWorkload(Byte14.self), forInGroupWorkload(Byte15.self), forInGroupWorkload(Byte16.self),
        bulkReadWorkload(Byte3.self), bulkReadWorkload(Byte5.self), bulkReadWorkload(Byte6.self), bulkReadWorkload(Byte7.self),
    ] + ipv4Workloads()
}

func registerBandwidthBenchmarks() {
    let workloads = readWorkloads()

    // 4 MB stays in a performance core's L2 (16 MB per cluster): the code's own ceiling.
    // 512 MB is far beyond every cache, so it measures reading DRAM.
    let cached = randomBuffer(byteCount: 4 << 20)
    let memory = randomBuffer(byteCount: 512 << 20)
    let cores = ProcessInfo.processInfo.activeProcessorCount

    func configuration(maxDuration: Duration) -> Benchmark.Configuration {
        .init(
            metrics: [.wallClock, .instructions, .bandwidth],
            warmupIterations: 2,
            scalingFactor: .one,
            maxDuration: maxDuration,
            maxIterations: 2_000
        )
    }

    for workload in workloads {
        // One core, from cache and from memory.
        for (label, buffer, duration) in [
            ("in cache (4 MB)", cached, Duration.milliseconds(500)),
            ("memory (512 MB), 1 core", memory, Duration.seconds(1)),
        ] {
            let byteCount = buffer.count / workload.unit * workload.unit
            Benchmark("Bandwidth: \(workload.name), \(label)", configuration: configuration(maxDuration: duration)) { benchmark in
                let clock = ContinuousClock()
                for _ in benchmark.scaledIterations {
                    let start = clock.now
                    blackHole(workload.read(buffer.span.bytes.extracting(first: byteCount)))
                    benchmark.measurement(.bandwidth, megabytesPerSecond(byteCount, clock.now - start))
                }
            }
        }

        // Every core, each chunk read with its own cursor. 16 chunks per core (1 MB each), handed out as
        // cores free up, so the efficiency cores take fewer and don't hold up the rest.
        guard workload.allCores else { continue }
        let chunks = cores * 16
        let chunk = memory.count / chunks / workload.unit * workload.unit
        Benchmark("Bandwidth: \(workload.name), memory (512 MB), \(cores) cores", configuration: configuration(maxDuration: .seconds(1))) { benchmark in
            let clock = ContinuousClock()
            for _ in benchmark.scaledIterations {
                let start = clock.now
                DispatchQueue.concurrentPerform(iterations: chunks) { index in
                    blackHole(workload.read(memory.span.bytes.extracting(index * chunk..<(index + 1) * chunk)))
                }
                benchmark.measurement(.bandwidth, megabytesPerSecond(chunk * chunks, clock.now - start))
            }
        }
    }
}

func megabytesPerSecond(_ byteCount: Int, _ elapsed: Duration) -> Int {
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    return Int(Double(byteCount) / seconds / 1e6)
}
