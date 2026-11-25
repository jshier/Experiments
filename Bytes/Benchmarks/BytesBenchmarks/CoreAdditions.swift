import Benchmark
import Bytes
import BytesTestSupport

// Single sub-byte writes in a loop (Writing.swift has the `Nibble` row): the widths that divide a byte, in both bit
// orders, and `Bits<3>`, which doesn't (its writes cross bytes, so it stays on the general path). Each writes the
// whole 4 MB buffer.

/// Writes `Bits<width>` values one at a time into all of `buffer`, in `order`.
@inline(__always)
func perValueBitsWrite<let width: Int>(_: Bits<width>.Type, _ buffer: UnsafeMutableRawBufferPointer, order: BitOrder) -> Int {
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer), bitOrder: order)
    for index in 0..<buffer.count * 8 / width {
        try! writer.write(Bits<width>(truncatingIfNeeded: mixed(index)))
    }
    return writer.byteCount
}

let perValueSubByteWorkloads: [WriteWorkload] = [
    WriteWorkload(name: "per-value write(_:) Bit", unit: 1, allCores: false) { perValueBitsWrite(Bits<1>.self, $0, order: .mostSignificantFirst) },
    WriteWorkload(name: "per-value write(_:) Crumb", unit: 1, allCores: false) { perValueBitsWrite(Bits<2>.self, $0, order: .mostSignificantFirst) },
    WriteWorkload(name: "per-value write(_:) Nibble, least significant first", unit: 1, allCores: false) {
        perValueBitsWrite(Bits<4>.self, $0, order: .leastSignificantFirst)
    },
    WriteWorkload(name: "per-value write(_:) Bits<3>", unit: 3, allCores: false) { perValueBitsWrite(Bits<3>.self, $0, order: .mostSignificantFirst) },
]

func registerCoreAdditionsBenchmarks() {
    let configuration = Benchmark.Configuration(
        metrics: [.wallClock, .instructions, .throughput], warmupIterations: 2, scalingFactor: .one,
        maxDuration: .milliseconds(150), maxIterations: 2_000
    )
    for workload in perValueSubByteWorkloads {
        Benchmark("Write: \(workload.name), in cache (4 MB)", configuration: configuration) { benchmark in
            let buffer = cachedWriteBuffer
            let target = UnsafeMutableRawBufferPointer(rebasing: buffer[..<(buffer.count / workload.unit * workload.unit)])
            for _ in benchmark.scaledIterations {
                blackHole(workload.write(target))
            }
        } setup: { _ = cachedWriteBuffer }
    }

    // Hexadecimal text: 32 bytes (a digest) and 1 KB, each way, 4,096 times per iteration.
    for count in [32, 1 << 10] {
        let bytes = Lazy { randomBuffer(byteCount: count) }
        let text = Lazy {
            let input = bytes.value // A span of `bytes.value` itself would be a temporary's.
            return Array(String(hexadecimal: input.span.bytes).utf8)
        }
        let label = count < 1 << 10 ? "\(count) B" : "\(count >> 10) KB"
        register("Hex: String(hexadecimal:), \(label) (×4 K)", bytes) { bytes in
            var total = 0
            for _ in 0..<4_096 {
                total &+= String(hexadecimal: bytes.span.bytes).utf8.count
            }
            return total
        }
        register("Hex: [UInt8](hexadecimal:), \(label) (×4 K)", text, check: { _, total in total == 4_096 * count }) { text in
            var total = 0
            for _ in 0..<4_096 {
                total &+= try [UInt8](hexadecimal: text.span.bytes).count
            }
            return total
        }
    }
}
