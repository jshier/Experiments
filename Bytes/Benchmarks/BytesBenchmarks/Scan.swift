import Benchmark
import Bytes
import BytesTestSupport

// Scanning and comparing bytes 16 at a time (`ByteScan.swift`, `RawSpan`'s match length and pattern search), each
// against the loop a user writes without them. Each iteration repeats the operation 16 times, so a sample is well over
// 100 K instructions (one 64 KB scan is about 20 K): divide by 16 for one.

let scanRepeats = 16

/// 64 KB of bytes from 1 to 255 with one 0 at the end: a C string's NUL, found last.
let terminated = Lazy {
    var bytes = randomBuffer(byteCount: 64 << 10).map { $0 | 1 }
    bytes[bytes.count - 1] = 0
    return bytes
}

/// 1,000 strings of 64 bytes (MQTT topic names): none has a wildcard, so every byte is tested.
let topics = Lazy {
    (0..<1_000).map { index in Array(("sensors/building-\(index % 12)/floor-\(index % 30)/" + String(repeating: "a", count: 64)).utf8.prefix(64)) }
}

/// 1,000 pairs of equal 64-byte strings, in separate arrays (copied by `map`: `Array(array)` would share the storage,
/// and `==` returns at once for identical storage): the comparison reads every byte.
let equalPairs = Lazy { topics.value.map { ($0, $0.map { $0 }) } }

/// Match candidates as a compressor's match finder sees them: pairs of offsets in one buffer whose bytes agree for
/// 3 to 258 bytes, then differ (DEFLATE's lengths), each pair in its own 532 bytes.
struct MatchCandidates {
    var window: [UInt8]
    var pairs: [(first: Int, second: Int)] = []
    var lengths: [Int] = []

    init() {
        let lengths = pseudoRandomLengths(in: 3...258, seed: 7).prefix(1_000)
        window = randomBuffer(byteCount: lengths.count * 532 + 16)
        for (index, length) in lengths.enumerated() {
            let first = index * 532, second = first + 266
            for offset in 0..<length { window[second + offset] = window[first + offset] }
            window[second + length] = window[first + length] ^ 1
            pairs.append((first, second))
            self.lengths.append(length)
        }
    }
}

let matchCandidates = Lazy { MatchCandidates() }

/// 64 KB with a 4-byte marker only at its end.
let markerHaystack = Lazy {
    var bytes = randomBuffer(byteCount: 64 << 10).map { $0 & 0x7F }
    bytes.replaceSubrange((bytes.count - 4)..., with: [0xFF, 0xD8, 0xFF, 0xE0])
    return bytes
}

// The workloads, `@inline(never)` so each is one function to read with Tools/loops.

@inline(never)
func firstZeroByLanes(_ bytes: RawSpan) -> Int? {
    bytes.firstByteOffset { $0.matching(0) }
}

@inline(never)
func firstZeroByByte(_ bytes: RawSpan) -> Int? {
    for offset in 0..<bytes.byteCount where bytes.load(fromByteOffset: offset, as: UInt8.self) == 0 {
        return offset
    }
    return nil
}

@inline(never)
func countWildcardsByLanes(_ topics: [[UInt8]]) -> Int {
    var count = 0
    for topic in topics where topic.span.bytes.containsByte(where: { $0.matching(UInt8(ascii: "+")) | $0.matching(UInt8(ascii: "#")) }) {
        count &+= 1
    }
    return count
}

@inline(never)
func countWildcardsByByte(_ topics: [[UInt8]]) -> Int {
    var count = 0
    for topic in topics where topic.contains(where: { $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "#") }) {
        count &+= 1
    }
    return count
}

@inline(never)
func countEqualByLanes(_ pairs: [([UInt8], [UInt8])]) -> Int {
    var count = 0
    for (a, b) in pairs where a.span.bytes.bytesEqual(b.span.bytes) {
        count &+= 1
    }
    return count
}

@inline(never)
func countEqualByArray(_ pairs: [([UInt8], [UInt8])]) -> Int {
    var count = 0
    for (a, b) in pairs where a == b {
        count &+= 1
    }
    return count
}

@inline(never)
func sumMatchLengths(_ candidates: MatchCandidates) -> Int {
    let window = candidates.window.span.bytes
    var sum = 0
    for (first, second) in candidates.pairs {
        sum &+= window.commonPrefixLength(at: first, and: second, maxLength: 258)
    }
    return sum
}

@inline(never)
func sumMatchLengthsUnchecked(_ candidates: MatchCandidates) -> Int {
    let window = candidates.window.span.bytes
    var sum = 0
    for (first, second) in candidates.pairs {
        // Unsafe: unchecked loads. Safe: each pair's offsets have 266 bytes after them in the window (at least 258,
        // the longest match), by construction.
        sum &+= unsafe window.unsafeCommonPrefixLength(at: first, and: second, maxLength: 258)
    }
    return sum
}

@inline(never)
func findMarker(_ bytes: RawSpan) -> Int? {
    bytes.firstByteOffset(of: 0xFF_D8_FF_E0 as Byte4)
}

@inline(never)
func findMarkerByLoad(_ bytes: RawSpan) -> Int? {
    for offset in 0...(bytes.byteCount - 4) where bytes.load(fromByteOffset: offset, as: UInt32.self, .bigEndian) == 0xFFD8_FFE0 {
        return offset
    }
    return nil
}

/// `body` 16 times, keeping each result.
@inline(__always)
func repeated<R>(_ body: () -> R) -> R {
    var result = body()
    for _ in 1..<scanRepeats {
        result = body()
        blackHole(result)
    }
    return result
}

func registerScanBenchmarks() {
    let end = (64 << 10) - 1
    register("Scan: first NUL in 64 KB (x16), firstByteOffset(where:)", terminated, check: { $1 == end }) { bytes in
        repeated { firstZeroByLanes(bytes.span.bytes) }
    }
    register("Scan: first NUL in 64 KB (x16), byte loop", terminated, check: { $1 == end }) { bytes in
        repeated { firstZeroByByte(bytes.span.bytes) }
    }
    register("Scan: wildcards in 1,000 × 64 B (x16), containsByte(where:)", topics, check: { $1 == 0 }) { topics in
        repeated { countWildcardsByLanes(topics) }
    }
    register("Scan: wildcards in 1,000 × 64 B (x16), byte loop", topics, check: { $1 == 0 }) { topics in
        repeated { countWildcardsByByte(topics) }
    }
    register("Scan: 1,000 × 64 B equal (x16), bytesEqual", equalPairs, check: { $1 == 1_000 }) { pairs in
        repeated { countEqualByLanes(pairs) }
    }
    register("Scan: 1,000 × 64 B equal (x16), Array ==", equalPairs, check: { $1 == 1_000 }) { pairs in
        repeated { countEqualByArray(pairs) }
    }
    let lengths = { (candidates: MatchCandidates, sum: Int) in sum == candidates.lengths.reduce(0, +) }
    register("Scan: 1,000 match lengths 3-258 B (x16), commonPrefixLength", matchCandidates, check: lengths) { candidates in
        repeated { sumMatchLengths(candidates) }
    }
    register("Scan: 1,000 match lengths 3-258 B (x16), unsafeCommonPrefixLength", matchCandidates, check: lengths) { candidates in
        repeated { sumMatchLengthsUnchecked(candidates) }
    }
    let markerEnd = (64 << 10) - 4
    register("Scan: 4-byte marker in 64 KB (x16), firstByteOffset(of:)", markerHaystack, check: { $1 == markerEnd }) { bytes in
        repeated { findMarker(bytes.span.bytes) }
    }
    register("Scan: 4-byte marker in 64 KB (x16), RawSpan.load per offset", markerHaystack, check: { $1 == markerEnd }) { bytes in
        repeated { findMarkerByLoad(bytes.span.bytes) }
    }
}
