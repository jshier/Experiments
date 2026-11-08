import Benchmark
import Bytes

// A type backed by an `InlineArray` of its bytes, parsed through `ByteRepresentable`, against reading the
// same bytes as a raw `Byte4`. No actual IPv4 parsing: the point is that the wrapper type costs nothing.

struct IPv4Address: ByteRepresentable {
    var rawBytes: InlineArray<4, UInt8>
    /// The four bytes as one integer, in memory order, for checksums: a free reinterpretation.
    var memoryOrderValue: UInt32 { bitCast(rawBytes, to: UInt32.self) }
}

/// A 6-byte custom type (MAC-address shaped): an odd size, built from two overlapping loads.
struct MACAddress: ByteRepresentable {
    var rawBytes: InlineArray<6, UInt8>
    var memoryOrderValue: UInt64 {
        var value: UInt64 = 0
        for index in 0..<6 {
            value |= UInt64(rawBytes[index]) << (8 * index)
        }
        return value
    }
}

/// A 16-byte custom type (IPv6-address shaped).
struct IPv6Address: ByteRepresentable {
    var rawBytes: InlineArray<16, UInt8>
    var memoryOrderValue: UInt128 { bitCast(rawBytes, to: UInt128.self) }
}

/// A custom type of any size, for the odd sizes: the consumer reassembles its bytes into an integer, like
/// `MACAddress`.
struct CustomBytes<let n: Int>: ByteRepresentable {
    var rawBytes: InlineArray<n, UInt8>
    var memoryOrderValue: UInt128 {
        var value: UInt128 = 0
        for index in 0..<n {
            value |= UInt128(rawBytes[index]) << (8 * index)
        }
        return value
    }
}

func customWorkloads<T: ByteGroup, let n: Int>(_: T.Type, _: CustomBytes<n>.Type) -> [Workload] {
    [
        Workload(name: "Custom \(n) bytes: forEach(\(T.self).self), raw bytes (reference)", unit: n, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt64 = 0
            reader.forEach(T.self) { sum &+= fold($0.littleEndian) }
            return sum
        },
        Workload(name: "Custom \(n) bytes: forEach(CustomBytes<\(n)>.self)", unit: n, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt64 = 0
            reader.forEach(CustomBytes<n>.self) { sum &+= fold($0.memoryOrderValue) }
            return sum
        },
    ]
}

/// Zero-copy typed views of `ConvertibleFromBytes` types (`read(_:count:)`), looped over with `for`-`in`.
func zeroCopyWorkloads() -> [Workload] {
    [
        Workload(name: "Zero-copy: for-in Span<InlineArray<4, UInt8>>", unit: 4, allCores: false) { span in
            var reader = BytesReader(span)
            let addresses = try! reader.read(InlineArray<4, UInt8>.self, count: span.byteCount / 4)
            var sum: UInt32 = 0
            for address in addresses {
                sum &+= bitCast(address, to: UInt32.self)
            }
            return UInt64(sum)
        },
        Workload(name: "Zero-copy: for-in Span<RawBytes> → IPv4Address", unit: 4, allCores: false) { span in
            var reader = BytesReader(span)
            let addresses = try! reader.read(IPv4Address.RawBytes.self, count: span.byteCount / 4)
            var sum: UInt32 = 0
            for rawBytes in addresses {
                sum &+= IPv4Address(rawBytes: rawBytes).memoryOrderValue
            }
            return UInt64(sum)
        },
        Workload(name: "Zero-copy: for-in Span<UInt32> (aligned)", unit: 4, allCores: false) { span in
            var reader = BytesReader(span)
            let words = try! reader.read(UInt32.self, count: span.byteCount / 4)
            var sum: UInt32 = 0
            for word in words {
                sum &+= word
            }
            return UInt64(sum)
        },
        Workload(name: "Zero-copy: for-in Span<InlineArray<6, UInt8>> (MAC bytes)", unit: 6, allCores: false) { span in
            var reader = BytesReader(span)
            let addresses = try! reader.read(InlineArray<6, UInt8>.self, count: span.byteCount / 6)
            var sum: UInt64 = 0
            for address in addresses {
                sum &+= MACAddress(rawBytes: address).memoryOrderValue
            }
            return sum
        },
        Workload(name: "Zero-copy: for-in Span<InlineArray<16, UInt8>> (IPv6 bytes)", unit: 16, allCores: false) { span in
            var reader = BytesReader(span)
            let addresses = try! reader.read(InlineArray<16, UInt8>.self, count: span.byteCount / 16)
            var sum: UInt64 = 0
            for address in addresses {
                sum &+= fold(bitCast(address, to: UInt128.self))
            }
            return sum
        },
        Workload(name: "load(Float.self) per value", unit: 4, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt32 = 0
            while reader.remainingByteCount >= 4 {
                sum &+= try! reader.load(Float.self).bitPattern
            }
            return UInt64(sum)
        },
    ]
}

func ipv4Workloads() -> [Workload] {
    zeroCopyWorkloads() + customWorkloads(Byte3.self, CustomBytes<3>.self) + customWorkloads(Byte12.self, CustomBytes<12>.self) + [
        Workload(name: "MAC: forEach(Byte6.self), raw bytes (reference)", unit: 6, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt64 = 0
            reader.forEach(Byte6.self) { sum &+= $0.littleEndian }
            return sum
        },
        Workload(name: "MAC: forEach(MACAddress.self)", unit: 6, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt64 = 0
            reader.forEach(MACAddress.self) { sum &+= $0.memoryOrderValue }
            return sum
        },
        Workload(name: "IPv6: forEach(Byte16.self), raw bytes (reference)", unit: 16, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt64 = 0
            reader.forEach(Byte16.self) { sum &+= fold($0.littleEndian) }
            return sum
        },
        Workload(name: "IPv6: forEach(IPv6Address.self)", unit: 16, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt64 = 0
            reader.forEach(IPv6Address.self) { sum &+= fold($0.memoryOrderValue) }
            return sum
        },
        Workload(name: "IPv4: forEach(Byte4.self), raw bytes (reference)", unit: 4, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt32 = 0
            reader.forEach(Byte4.self) { sum &+= $0.littleEndian }
            return UInt64(sum)
        },
        Workload(name: "IPv4: forEach(IPv4Address.self)", unit: 4, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt32 = 0
            reader.forEach(IPv4Address.self) { sum &+= $0.memoryOrderValue }
            return UInt64(sum)
        },
        Workload(name: "IPv4: read(Byte4.self) per value, raw bytes (reference)", unit: 4, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt32 = 0
            while reader.remainingByteCount >= 4 {
                sum &+= try! reader.read(Byte4.self).littleEndian
            }
            return UInt64(sum)
        },
        Workload(name: "IPv4: read(IPv4Address.self) per value", unit: 4, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt32 = 0
            while reader.remainingByteCount >= 4 {
                sum &+= try! reader.read(IPv4Address.self).memoryOrderValue
            }
            return UInt64(sum)
        },
        // The obvious way without `ByteRepresentable`: four byte reads into an `InlineArray` literal.
        Workload(name: "IPv4: naive, 4 × read(Byte.self) per value", unit: 4, allCores: false) { span in
            var reader = BytesReader(span)
            var sum: UInt32 = 0
            while reader.remainingByteCount >= 4 {
                let address = IPv4Address(rawBytes: [
                    try! reader.read(Byte.self).rawValue, try! reader.read(Byte.self).rawValue,
                    try! reader.read(Byte.self).rawValue, try! reader.read(Byte.self).rawValue,
                ])
                sum &+= address.memoryOrderValue
            }
            return UInt64(sum)
        },
    ]
}
