import Benchmark
import Bytes
import BytesTestSupport

// Array builders (`[UInt8](byteCapacity:writing:)`) and prefixed sections (`read(sectionPrefixedBy:)`,
// `readSectionIfComplete(prefixedBy:_:)`), each checked against the code it replaced, on the same data (whose own rows
// were retired on 2026-11-19: their numbers are in the saved baselines). Every workload function is `@inline(never)`,
// one per form (see RunsAndCopies.swift).

// MARK: Array builders

/// 1,000 small arrays (a 2-byte header, a 4-byte field, 32 bytes of payload), as an encoder makes packets.
/// The builders take it as an argument: a global read in their loop checked its lazy initializer's `swift_once`
/// token per array (see RunsAndCopies.swift).
let builderPayload = (0..<32).map { UInt8($0) }

/// The closure's error type annotated, as the builder's documentation recommends for hot code.
@inline(never)
func buildArrays(_ payload: [UInt8]) -> Int {
    var total = 0
    for index in 0..<1_000 {
        let bytes = try! [UInt8](byteCapacity: 38) { (writer) throws(BytesError) in
            try writer.write(0x30_26 as Byte2)
            try writer.write(UInt32(truncatingIfNeeded: index), as: Byte4.self, .bigEndian)
            try writer.write(payload.span)
        }
        total &+= bytes.count
    }
    return total
}

/// Without the annotation: the closure throws `any Error`, by inference.
@inline(never)
func buildArraysUnannotated(_ payload: [UInt8]) -> Int {
    var total = 0
    for index in 0..<1_000 {
        let bytes = try! [UInt8](byteCapacity: 38) { writer in
            try writer.write(0x30_26 as Byte2)
            try writer.write(UInt32(truncatingIfNeeded: index), as: Byte4.self, .bigEndian)
            try writer.write(payload.span)
        }
        total &+= bytes.count
    }
    return total
}

@inline(never)
func buildArraysNested(_ payload: [UInt8]) -> Int {
    var total = 0
    for index in 0..<1_000 {
        let bytes = try! [UInt8](capacity: 38) { output in
            try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                try writer.write(0x30_26 as Byte2)
                try writer.write(UInt32(truncatingIfNeeded: index), as: Byte4.self, .bigEndian)
                try writer.write(payload.span)
            }
        }
        total &+= bytes.count
    }
    return total
}

// MARK: Prefixed sections

/// 64 KB of records: a 2-byte little-endian length, then 0 to 32 bytes.
let prefixedRecords: [UInt8] = {
    let lengths = pseudoRandomLengths(in: 0...32, seed: 6)
    var output = [UInt8](repeating: 0, count: 64 << 10)
    var span = output.mutableSpan
    var writer = BytesWriter(&span)
    var index = 0
    while writer.remainingByteCount >= 34 {
        let length = lengths[index & 4095]
        try! writer.write(UInt16(length), as: Byte2.self, .littleEndian)
        try! writer.write(Byte(truncatingIfNeeded: index), byteCount: length)
        index &+= 1
    }
    let written = writer.byteCount
    _ = consume writer
    _ = consume span
    return Array(output[..<written])
}()

extension BytesWriter {
    /// `byteCount` copies of `byte`, for the fixture (without the newer run API).
    mutating func write(_ byte: Byte, byteCount: Int) throws(BytesError) {
        for _ in 0..<byteCount {
            try write(byte)
        }
    }
}

/// Each record's first byte, summed: `read(sectionPrefixedBy:)`.
@inline(never)
func sumSections(_ bytes: RawSpan) -> Int {
    var reader = BytesReader(bytes)
    var sum = 0
    while !reader.isAtEnd {
        var section = try! reader.read(sectionPrefixedBy: Byte2.self, .littleEndian)
        if !section.isAtEnd { sum &+= Int(try! section.read(Byte.self).rawValue) }
    }
    return sum
}

/// The same with `readSectionIfComplete(prefixedBy:_:)`.
@inline(never)
func sumSectionsIfComplete(_ bytes: RawSpan) -> Int {
    var reader = BytesReader(bytes)
    var sum = 0
    while var section = reader.readSectionIfComplete(prefixedBy: Byte2.self, .littleEndian) {
        if !section.isAtEnd { sum &+= Int(try! section.read(Byte.self).rawValue) }
    }
    return sum
}

/// The same written out: read the length, check it, then `readSection(byteCount:)` (NativeZip's form before).
@inline(never)
func sumSectionsByHand(_ bytes: RawSpan) -> Int {
    var reader = BytesReader(bytes)
    var sum = 0
    while reader.remainingByteCount >= 2 {
        let length = try! Int(reader.read(Byte2.self, .littleEndian))
        guard length <= reader.remainingByteCount else { break }
        var section = try! reader.readSection(byteCount: length)
        if !section.isAtEnd { sum &+= Int(try! section.read(Byte.self).rawValue) }
    }
    return sum
}

// MARK: Registration

func registerBuildersAndSectionsBenchmarks() {
    // Under 0.1 ms an operation: up to 5,000 samples in 100 ms (at least 1,000). Allocations aren't counted in timed
    // runs (each array builder row makes 1,000 arrays).
    let configuration = Benchmark.Configuration(
        metrics: [.wallClock, .instructions], warmupIterations: 10, scalingFactor: .one,
        maxDuration: .milliseconds(100), maxIterations: 5_000
    )
    // Each workload, and the code it replaced (whose rows, "(before)", were retired on 2026-11-19): setup checks that
    // they agree.
    let records = Lazy { prefixedRecords }
    let payload = builderPayload
    let workloads: [(String, () -> Int, reference: () -> Int)] = [
        ("Array builder: 1,000 38-byte arrays, [UInt8](byteCapacity:writing:)", { buildArrays(payload) }, { buildArraysNested(payload) }),
        ("Array builder: 1,000 38-byte arrays, [UInt8](byteCapacity:writing:), closure not annotated",
         { buildArraysUnannotated(payload) }, { buildArraysNested(payload) }),
        ("Prefixed sections: 64 KB, read(sectionPrefixedBy:)", { records.value.withUnsafeBytes { sumSections(RawSpan(_unsafeBytes: $0)) } },
         { records.value.withUnsafeBytes { sumSectionsByHand(RawSpan(_unsafeBytes: $0)) } }),
        ("Prefixed sections: 64 KB, readSectionIfComplete(prefixedBy:_:)",
         { records.value.withUnsafeBytes { sumSectionsIfComplete(RawSpan(_unsafeBytes: $0)) } },
         { records.value.withUnsafeBytes { sumSectionsByHand(RawSpan(_unsafeBytes: $0)) } }),
    ]
    for (name, run, reference) in workloads {
        Benchmark(name, configuration: configuration) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(run())
            }
        } setup: {
            precondition(run() == reference(), "\(name): wrong result")
        }
    }
}
