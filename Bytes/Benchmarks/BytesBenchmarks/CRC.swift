import Benchmark
@_spi(Benchmarking) import Bytes

/// CRC-32 implementations, and `forEach` with and without a byte order.
func registerCRCBenchmarks() {
    var rng = SystemRandomNumberGenerator()
    let large = (0..<(256 << 10)).map { _ in UInt8.random(in: 0...255, using: &rng) } // in cache
    let small = Array(large[..<64])
    let repeats = 128 // 32 MB per iteration for the large input, as for the small one below.

    // The portable path (other CPUs), measured here. See RESULTS.md for the variants it was chosen from.
    Benchmark("CRC-32 tables, 256 KB") { benchmark in
        for _ in benchmark.scaledIterations {
            for _ in 0..<repeats { blackHole(CRC32.tableChecksum(large.span.bytes)) }
        }
    }
    Benchmark("CRC-32 tables, 64 B") { benchmark in
        for _ in benchmark.scaledIterations {
            for _ in 0..<(repeats << 12) { blackHole(CRC32.tableChecksum(small.span.bytes)) }
        }
    }
    Benchmark("CRC-32 hardware, 256 KB") { benchmark in
        for _ in benchmark.scaledIterations {
            for _ in 0..<repeats { blackHole(CRC32.checksum(large.span.bytes)) }
        }
    }

    // `forEach(T.self, order)` against `forEach(T.self)` converting in the body: the same loop?
    let data = [UInt8](repeating: 0x5A, count: 4 << 20)
    func sum<T: ByteGroup>(_: T.Type, ordered: Bool) -> UInt64 {
        var reader = Bytes(data.span)
        var sum: UInt64 = 0
        if ordered {
            reader.forEach(T.self, .bigEndian) { sum &+= UInt64(truncatingIfNeeded: $0) }
        } else {
            reader.forEach(T.self) { sum &+= UInt64(truncatingIfNeeded: $0.bigEndian) }
        }
        return sum
    }
    func register<T: ByteGroup>(_: T.Type, _ name: String) {
        Benchmark("forEach(\(name).self) { $0.bigEndian }, 4 MB") { benchmark in
            for _ in benchmark.scaledIterations { blackHole(sum(T.self, ordered: false)) }
        }
        Benchmark("forEach(\(name).self, .bigEndian), 4 MB") { benchmark in
            for _ in benchmark.scaledIterations { blackHole(sum(T.self, ordered: true)) }
        }
    }
    register(Byte2.self, "Byte2")
    register(Byte3.self, "Byte3")
    register(Byte4.self, "Byte4")
    register(Byte6.self, "Byte6")
    register(Byte8.self, "Byte8")
}
