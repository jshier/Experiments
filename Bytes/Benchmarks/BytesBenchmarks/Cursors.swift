import Benchmark
import Bytes
import BytesTestSupport

// Named bit fields against shifts and masks, and `ByteBuffer` streaming. (The byte-ordered cursors' per-value reads
// and writes are workloads in Bandwidth.swift's and Writing.swift's lists; the little-endian field parser is "Fields:
// LittleEndianBytesReader".)

// MARK: Bit fields

/// A flags byte, MQTT-style: bit 0 retain, bits 1–2 a QoS, bit 3 duplicate, bits 4–7 a packet type. Computed
/// `static var`s, as `BitFields.swift` recommends.
enum PacketFlags {
    static var retain: BitFlag { BitFlag(bit: 0) }
    static var qos: BitField<Int> { BitField(bits: 1...2) }
    static var duplicate: BitFlag { BitFlag(bit: 3) }
    static var kind: BitField<Int> { BitField(bits: 4...7) }
}

/// Every flags byte's fields by name, summed.
@inline(never)
func sumFlagsByName(_ bytes: Span<UInt8>) -> Int {
    var sum = 0
    for index in bytes.indices {
        let flags = bytes[index]
        sum &+= (flags[PacketFlags.retain] ? 1 : 0) &+ flags[PacketFlags.qos] &+ (flags[PacketFlags.duplicate] ? 4 : 0)
        sum &+= flags[PacketFlags.kind] &<< 3
    }
    return sum
}

/// The same with shifts and masks.
@inline(never)
func sumFlagsByHand(_ bytes: Span<UInt8>) -> Int {
    var sum = 0
    for index in bytes.indices {
        let flags = Int(bytes[index])
        sum &+= (flags & 1) &+ (flags &>> 1 & 3) &+ (flags &>> 3 & 1) &* 4
        sum &+= (flags &>> 4 & 15) &<< 3
    }
    return sum
}

// MARK: ByteBuffer

/// A 256 KB `ByteBuffer`, and 16 KB to fill it with.
final class ByteBufferFixture {
    var buffer = ByteBuffer(capacity: 256 << 10)
    let source = randomBuffer(byteCount: 16 << 10)
}

let byteBufferFixture = Lazy { ByteBufferFixture() }

/// 64 MB through the buffer, as a socket's reads through a parser: fill 16 KB, consume whole 12 KB units, a partial unit
/// left over each time (so fills compact). The sum of each unit's first byte, and what's left.
@inline(never)
func streamThroughByteBuffer(_ f: ByteBufferFixture) -> Int {
    f.buffer.removeAll()
    let source = f.source
    var filled = 0
    var sum = 0
    while filled < 64 << 20 {
        filled &+= f.buffer.fill { output in
            output.append(copying: source.span.bytes)
            return source.count
        }
        while f.buffer.unreadByteCount >= 12 << 10 {
            sum &+= Int(f.buffer.unread.load(fromByteOffset: 0, as: UInt8.self))
            f.buffer.consume(12 << 10)
        }
    }
    return sum &+ f.buffer.unreadByteCount
}

func registerTypedCursorBenchmarks() {
    // 64 KB of flags bytes, 16 times per iteration.
    let flags = Lazy { randomBuffer(byteCount: 64 << 10) }
    register("Bit fields: 64 KB of flags (x16), BitFlag and BitField", flags, check: { $1 == sumFlagsByHand($0.span) }) { flags in
        repeated { sumFlagsByName(flags.span) }
    }
    register("Bit fields: 64 KB of flags (x16), shifts and masks", flags) { flags in
        repeated { sumFlagsByHand(flags.span) }
    }

    // Each unit's first byte: units start every 12 KB of the stream; the source repeats every 16 KB.
    register("ByteBuffer: 64 MB through 256 KB, fill 16 KB, consume 12 KB", byteBufferFixture, check: { f, sum in
        let units = (64 << 20) / (12 << 10)
        let expected = (0..<units).reduce(0) { $0 &+ Int(f.source[($1 * (12 << 10)) % (16 << 10)]) }
        return sum == expected &+ (64 << 20) % (12 << 10)
    }) { f in
        streamThroughByteBuffer(f)
    }
}
