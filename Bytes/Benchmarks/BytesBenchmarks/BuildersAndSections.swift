import Benchmark
import Bytes

// Array builders (`[UInt8](byteCapacity:writing:)`) and prefixed sections (`read(sectionPrefixedBy:)`,
// `readSectionIfComplete(prefixedBy:_:)`), each next to the code it replaces, on the same data, so one run
// compares them. Every workload function is `@inline(never)`, one per form (see RunsAndCopies.swift).

// MARK: Array builders

/// 1,000 small arrays (a 2-byte header, a 4-byte field, 32 bytes of payload), as an encoder makes packets.
let builderPayload = (0..<32).map { UInt8($0) }

/// The closure's error type annotated, as the builder's documentation recommends for hot code.
@inline(never)
func buildArrays() -> Int {
    var total = 0
    for index in 0..<1_000 {
        let bytes = try! [UInt8](byteCapacity: 38) { (writer) throws(BytesError) in
            try writer.write(0x30_26 as Byte2)
            try writer.write(UInt32(truncatingIfNeeded: index), as: Byte4.self, .bigEndian)
            try writer.write(builderPayload.span)
        }
        total &+= bytes.count
    }
    return total
}

/// Without the annotation: the closure throws `any Error`, by inference.
@inline(never)
func buildArraysUnannotated() -> Int {
    var total = 0
    for index in 0..<1_000 {
        let bytes = try! [UInt8](byteCapacity: 38) { writer in
            try writer.write(0x30_26 as Byte2)
            try writer.write(UInt32(truncatingIfNeeded: index), as: Byte4.self, .bigEndian)
            try writer.write(builderPayload.span)
        }
        total &+= bytes.count
    }
    return total
}

@inline(never)
func buildArraysNested() -> Int {
    var total = 0
    for index in 0..<1_000 {
        let bytes = try! [UInt8](capacity: 38) { output in
            try output.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                try writer.write(0x30_26 as Byte2)
                try writer.write(UInt32(truncatingIfNeeded: index), as: Byte4.self, .bigEndian)
                try writer.write(builderPayload.span)
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
    precondition(buildArrays() == buildArraysNested() && buildArraysUnannotated() == buildArraysNested())
    let records = prefixedRecords
    let expected = records.withUnsafeBytes { sumSectionsByHand(RawSpan(_unsafeBytes: $0)) }
    precondition(records.withUnsafeBytes { sumSections(RawSpan(_unsafeBytes: $0)) } == expected)
    precondition(records.withUnsafeBytes { sumSectionsIfComplete(RawSpan(_unsafeBytes: $0)) } == expected)

    let configuration = Benchmark.Configuration(
        metrics: [.wallClock, .instructions, .mallocCountTotal], warmupIterations: 10, scalingFactor: .one,
        maxDuration: .milliseconds(500), maxIterations: 5_000
    )
    let workloads: [(String, () -> Int)] = [
        ("Array builder: 1,000 38-byte arrays, [UInt8](byteCapacity:writing:)", buildArrays),
        ("Array builder: 1,000 38-byte arrays, [UInt8](byteCapacity:writing:), closure not annotated", buildArraysUnannotated),
        ("Array builder: 1,000 38-byte arrays, [UInt8](capacity:) + withBytesWriter (before)", buildArraysNested),
        ("Prefixed sections: 64 KB, read(sectionPrefixedBy:)", { records.withUnsafeBytes { sumSections(RawSpan(_unsafeBytes: $0)) } }),
        ("Prefixed sections: 64 KB, readSectionIfComplete(prefixedBy:_:)", { records.withUnsafeBytes { sumSectionsIfComplete(RawSpan(_unsafeBytes: $0)) } }),
        ("Prefixed sections: 64 KB, length, check, readSection(byteCount:) (before)", { records.withUnsafeBytes { sumSectionsByHand(RawSpan(_unsafeBytes: $0)) } }),
    ]
    for (name, run) in workloads {
        Benchmark(name, configuration: configuration) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(run())
            }
        }
    }
}
