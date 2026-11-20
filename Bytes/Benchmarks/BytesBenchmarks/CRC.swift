import Benchmark
import BytesTestSupport
import Bytes

/// CRC-32 implementations, and `forEach` with and without a byte order.
func registerCRCBenchmarks() {
    // 256 KB (in cache) of pseudo-random bytes, and its first 64. Made by setup.
    let large = Lazy { randomBuffer(byteCount: 256 << 10) }
    let small = Lazy { Array(large.value[..<64]) }
    let repeats = 128 // 32 MB per iteration for the large input, as for the small one below.
    // The checksum `checksum(_:)` returns, on every build, for each input.
    let reference = { (bytes: [UInt8]) in CRC32.tableChecksum(bytes.span.bytes) }

    // The portable path (other CPUs), measured here. See RESULTS.md for the variants it was chosen from.
    register("CRC-32 tables, 256 KB", large, check: { $1 == reference($0) }) { large in
        var value: UInt32 = 0
        for _ in 0..<repeats {
            value = CRC32.tableChecksum(large.span.bytes)
            blackHole(value)
        }
        return value
    }
    register("CRC-32 tables, 64 B", small, check: { $1 == reference($0) }) { small in
        var value: UInt32 = 0
        for _ in 0..<(repeats << 12) {
            value = CRC32.tableChecksum(small.span.bytes)
            blackHole(value)
        }
        return value
    }
    // The public API: the hardware instructions on Apple silicon, the tables in portable builds. (Named "CRC-32
    // hardware, 256 KB" until 2026-11-19.)
    register("CRC-32 checksum(_:), 256 KB", large, check: { $1 == reference($0) }) { large in
        var value: UInt32 = 0
        for _ in 0..<repeats {
            value = CRC32.checksum(large.span.bytes)
            blackHole(value)
        }
        return value
    }

    // `forEach(T.self, order)` against `forEach(T.self)` converting in the body: the same loop? Byte3 and Byte6, whose
    // conversions aren't one instruction (Byte2, Byte4, and Byte8 compiled to the same loop both ways: retired
    // 2026-11-19).
    let data = Lazy { [UInt8](repeating: 0x5A, count: 4 << 20) }
    func sum<T: ByteGroup>(_: T.Type, _ data: [UInt8], ordered: Bool) -> UInt64 {
        var reader = BytesReader(data.span)
        var sum: UInt64 = 0
        if ordered {
            reader.forEach(T.self, .bigEndian) { sum &+= UInt64(truncatingIfNeeded: $0) }
        } else {
            reader.forEach(T.self) { sum &+= UInt64(truncatingIfNeeded: $0.bigEndian) }
        }
        return sum
    }
    func registerOrderPair<T: ByteGroup>(_: T.Type, _ name: String) {
        let same = { (data: [UInt8], value: UInt64) in value == sum(T.self, data, ordered: false) }
        register("forEach(\(name).self) { $0.bigEndian }, 4 MB", data, check: same) { sum(T.self, $0, ordered: false) }
        register("forEach(\(name).self, .bigEndian), 4 MB", data, check: same) { sum(T.self, $0, ordered: true) }
    }
    registerOrderPair(Byte3.self, "Byte3")
    registerOrderPair(Byte6.self, "Byte6")
}
