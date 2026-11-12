import Benchmark
import Bytes
import Dispatch
import Foundation

// Write bandwidth: how fast `BytesWriter` fills memory with each width, from 1 bit to 16 bytes, compared
// with the fastest raw writes of the same memory (`memset`, and a hand-written SIMD store loop). Values are
// generated from their index, so nothing is read from memory: the work is converting and storing them.
//
// Each workload creates its writer as a local. An earlier version passed it `inout` to an inner closure;
// the compiler then merged the near-identical outer closures into one thunk that calls the inner closure
// indirectly, so the writer's offsets went through memory on every write (0.6 GB/s for single bytes).

/// One way of filling a buffer: a name, the byte granularity it can be split at for parallel writes, and
/// the write itself, returning the bytes written.
struct WriteWorkload: Sendable {
    let name: String
    let unit: Int
    var allCores = true
    let write: @Sendable (UnsafeMutableRawBufferPointer) -> Int
}

/// Cheap pseudo-random values from an index: one 32-bit multiply (vectorizable), so values can't fold into
/// repeating patterns (with `index` itself, `Bit` writes became a constant fill).
@inline(__always)
func hashed(_ index: Int) -> UInt32 { UInt32(truncatingIfNeeded: index) &* 0x9E37_79B1 }

/// 64 bits from an index: the hash twice, with shifts (a 64-bit multiply doesn't vectorize on NEON, and
/// made `Byte8` look slow).
@inline(__always)
func hashedWide(_ index: Int) -> UInt64 { let hash = UInt64(hashed(index)); return hash | hash &<< 32 }

/// A cheap value for bit-sized writes, computed in bytes (16 lanes per vector instruction): a 32-bit hash
/// per value cost more than writing the value, for widths that pack 8 values into a byte.
@inline(__always)
func mixed(_ index: Int) -> UInt8 { let byte = UInt8(truncatingIfNeeded: index); return byte ^ byte &>> 3 }

func groupWriteWorkload<T: ByteGroup>(_: T.Type) -> WriteWorkload {
    WriteWorkload(name: "\(T.self)", unit: T.byteCount) { buffer in
        var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
        try! writer.write(T.self, .bigEndian, count: buffer.count / T.byteCount) { T.Integer(truncatingIfNeeded: hashedWide($0)) }
        return writer.byteCount
    }
}

func bitsWriteWorkload<let width: Int>(_: Bits<width>.Type, name: String) -> WriteWorkload {
    WriteWorkload(name: name, unit: width) { buffer in
        var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
        try! writer.write(Bits<width>.self, count: buffer.count * 8 / width) { Bits(truncatingIfNeeded: mixed($0)) }
        return writer.byteCount
    }
}

let rawStore = WriteWorkload(name: "Raw SIMD store (reference)", unit: 64) { buffer in
    let lanes = SIMD16<UInt32>(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
    let blocks = buffer.count / 64
    for block in 0..<blocks {
        let values = (lanes &+ UInt32(truncatingIfNeeded: block &* 16)) &* 0x9E37_79B1
        buffer.storeBytes(of: values, toByteOffset: block * 64, as: SIMD16<UInt32>.self)
    }
    return blocks * 64
}

let memsetStore = WriteWorkload(name: "memset (reference)", unit: 1) { buffer in
    buffer.initializeMemory(as: UInt8.self, repeating: 0xA5)
    return buffer.count
}

/// Single writes in a loop, for comparison with the generating bulk forms.
let perValueWriteWorkloads: [WriteWorkload] = [
    WriteWorkload(name: "per-value write(_:as:_:) Byte4", unit: 4, allCores: false) { buffer in
        var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
        for index in 0..<buffer.count / 4 {
            try! writer.write(hashed(index), as: Byte4.self, .bigEndian)
        }
        return writer.byteCount
    },
    WriteWorkload(name: "per-value write(_:as:_:) Byte3", unit: 3, allCores: false) { buffer in
        var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
        for index in 0..<buffer.count / 3 {
            try! writer.write(hashed(index), as: Byte3.self, .bigEndian)
        }
        return writer.byteCount
    },
    WriteWorkload(name: "per-value write(_:as:_:) Byte16", unit: 16, allCores: false) { buffer in
        var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
        for index in 0..<buffer.count / 16 {
            try! writer.write(UInt128(hashedWide(index)), as: Byte16.self, .bigEndian)
        }
        return writer.byteCount
    },
    WriteWorkload(name: "per-value write(_:) Byte", unit: 1, allCores: false) { buffer in
        var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
        for index in 0..<buffer.count {
            try! writer.write(Byte(truncatingIfNeeded: mixed(index)))
        }
        return writer.byteCount
    },
    WriteWorkload(name: "per-value write(_:) Nibble", unit: 1, allCores: false) { buffer in
        var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
        for index in 0..<buffer.count * 2 {
            try! writer.write(Nibble(truncatingIfNeeded: mixed(index)))
        }
        return writer.byteCount
    },
    WriteWorkload(name: "per-value write(_:) IPv4Address", unit: 4, allCores: false) { buffer in
        var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
        for index in 0..<buffer.count / 4 {
            try! writer.write(IPv4Address(rawBytes: bitCast(hashed(index), to: InlineArray<4, UInt8>.self)))
        }
        return writer.byteCount
    },
]

/// A zero-filled buffer that lives for the whole run, every page already touched.
func residentBuffer(byteCount: Int) -> UnsafeMutableRawBufferPointer {
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 1 << 14)
    buffer.initializeMemory(as: UInt8.self, repeating: 0)
    return buffer
}

nonisolated(unsafe) let cachedWriteBuffer = residentBuffer(byteCount: 4 << 20)
nonisolated(unsafe) let memoryWriteBuffer = residentBuffer(byteCount: 512 << 20)

/// Every write workload: the bandwidth benchmarks, and their allocation counts (`Allocations.swift`).
func writeWorkloads() -> [WriteWorkload] {
    [
        rawStore,
        memsetStore,
        bitsWriteWorkload(Bits<1>.self, name: "Bit"),
        bitsWriteWorkload(Bits<2>.self, name: "Crumb"),
        bitsWriteWorkload(Bits<3>.self, name: "Bits<3>"),
        bitsWriteWorkload(Bits<4>.self, name: "Nibble"),
        bitsWriteWorkload(Bits<5>.self, name: "Bits<5>"),
        bitsWriteWorkload(Bits<6>.self, name: "Bits<6>"),
        bitsWriteWorkload(Bits<7>.self, name: "Bits<7>"),
        bitsWriteWorkload(Bits<8>.self, name: "Byte"),
        groupWriteWorkload(Byte2.self), groupWriteWorkload(Byte3.self), groupWriteWorkload(Byte4.self),
        groupWriteWorkload(Byte5.self), groupWriteWorkload(Byte6.self), groupWriteWorkload(Byte7.self),
        groupWriteWorkload(Byte8.self), groupWriteWorkload(Byte9.self), groupWriteWorkload(Byte10.self),
        groupWriteWorkload(Byte11.self), groupWriteWorkload(Byte12.self), groupWriteWorkload(Byte13.self),
        groupWriteWorkload(Byte14.self), groupWriteWorkload(Byte15.self), groupWriteWorkload(Byte16.self),
        WriteWorkload(name: "IPv4Address", unit: 4) { buffer in
            var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
            try! writer.write(IPv4Address.self, count: buffer.count / 4) {
                IPv4Address(rawBytes: bitCast(hashed($0), to: InlineArray<4, UInt8>.self))
            }
            return writer.byteCount
        },
    ] + perValueWriteWorkloads
}

func registerWriteBenchmarks() {
    let workloads = writeWorkloads()
    let cores = ProcessInfo.processInfo.activeProcessorCount

    func configuration(maxDuration: Duration) -> Benchmark.Configuration {
        // Bandwidth: throughput (iterations per second, the framework's) times the bytes per iteration
        // (4 MB or 512 MB, in the name). Only the writes run inside `scaledIterations`.
        .init(metrics: [.wallClock, .instructions, .throughput], warmupIterations: 2, scalingFactor: .one,
              maxDuration: maxDuration, maxIterations: 2_000)
    }

    for workload in workloads {
        for (label, buffer, duration) in [
            ("in cache (4 MB)", cachedWriteBuffer, Duration.milliseconds(500)),
            ("memory (512 MB), 1 core", memoryWriteBuffer, Duration.seconds(1)),
        ] {
            let target = UnsafeMutableRawBufferPointer(rebasing: buffer[..<(buffer.count / workload.unit * workload.unit)])
            Benchmark("Write: \(workload.name), \(label)", configuration: configuration(maxDuration: duration)) { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(workload.write(target))
                }
            }
        }

        guard workload.allCores else { continue }
        let chunks = cores * 16
        let chunk = memoryWriteBuffer.count / chunks / workload.unit * workload.unit
        Benchmark("Write: \(workload.name), memory (512 MB), \(cores) cores", configuration: configuration(maxDuration: .seconds(1))) { benchmark in
            for _ in benchmark.scaledIterations {
                DispatchQueue.concurrentPerform(iterations: chunks) { index in
                    let slice = UnsafeMutableRawBufferPointer(rebasing: memoryWriteBuffer[index * chunk..<(index + 1) * chunk])
                    blackHole(workload.write(slice))
                }
            }
        }
    }
}
