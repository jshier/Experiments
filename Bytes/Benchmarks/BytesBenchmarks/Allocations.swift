import Benchmark
import Bytes

// Allocation checks: every workload that shouldn't allocate, registered again as "Allocations:<name>",
// measuring only allocations over a small buffer, with a static threshold of zero (in `Thresholds/`).
//
//     swift package benchmark thresholds check --filter 'Allocations:.*'
//
// fails (nonzero exit) if any of them allocates. After adding a workload, record its zero threshold with
// `swift package --allow-writing-to-package-directory benchmark thresholds update --filter 'Allocations:.*'`.

/// Writes `count` LEB128-prefixed sections, each holding a length-prefixed string and a LEB128, then reads
/// them back: the variable-size section APIs, both directions.
func sectionsRoundTrip(into buffer: UnsafeMutableRawBufferPointer, count: Int) -> UInt64 {
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    let text = "sensors/building-1/floor-2"
    for index in 0..<count {
        try! writer.write(sectionPrefixedBy: LEB128.self, maxByteCount: 2) { (section: inout BytesWriter) throws(BytesError) in
            try section.write(text.utf8Span, prefixedBy: Byte2.self, .bigEndian)
            try section.write(UInt64(index), as: LEB128.self)
        }
    }
    var reader = BytesReader(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: buffer[..<writer.byteCount])))
    var sum: UInt64 = 0
    while !reader.isAtEnd {
        var section = try! reader.read(sectionPrefixedBy: LEB128.self, maxByteCount: 2)
        sum &+= UInt64(try! section.read(utf8PrefixedBy: Byte2.self, .bigEndian).count)
        sum &+= try! section.read(LEB128.self)
        try! section.expectEnd()
    }
    return sum
}

/// Registers the allocation checks: every read and write workload, the sections round trip, and `others`.
func registerAllocationBenchmarks(_ others: [(name: String, run: () -> Void)]) {
    // Allocation counts are deterministic, so a few iterations are enough. Warmup runs lazy initializers
    // outside the measurement.
    let configuration = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )

    func register(_ name: String, _ run: @escaping () -> Void) {
        // `thresholds update` writes "_" for spaces and slashes in the file name, but `thresholds check` looks
        // the file up by the unaltered name (benchmark 1.38.1), so the names have neither.
        let name = name.replacing(" ", with: "_").replacing("/", with: "_")
        Benchmark("Allocations:\(name)", configuration: configuration) { benchmark in
            for _ in benchmark.scaledIterations { run() }
        }
    }

    let source = randomBuffer(byteCount: 64 << 10)
    for workload in readWorkloads() {
        let byteCount = source.count / workload.unit * workload.unit
        register("Read: \(workload.name)") { blackHole(workload.read(source.span.bytes.extracting(first: byteCount))) }
    }
    // "for-in Bytes (UInt8)" above, `let reader = BytesReader(span); for byte in reader`, allocates once per loop
    // (Swift 6.4.2): a `~Copyable` `let` is boxed, and the iterator's borrow dependence on the box keeps the
    // optimizer from moving it to the stack. Its threshold is 1, so the check reports the fix as an
    // improvement. A `var` reader isn't boxed:
    register("Read: for-in Bytes (UInt8), var reader") {
        var reader = BytesReader(source.span)
        var sum: UInt8 = 0
        for byte in reader { sum &+= byte }
        try! reader.skip(byteCount: reader.remainingByteCount)
        blackHole(sum)
    }

    let target = residentBuffer(byteCount: 64 << 10)
    for workload in writeWorkloads() {
        let slice = UnsafeMutableRawBufferPointer(rebasing: target[..<(target.count / workload.unit * workload.unit)])
        register("Write: \(workload.name)") { blackHole(workload.write(slice)) }
    }

    register("Sections: LEB128-prefixed write and read") { blackHole(sectionsRoundTrip(into: target, count: 1_000)) }

    for (name, run) in others { register(name, run) }
}
