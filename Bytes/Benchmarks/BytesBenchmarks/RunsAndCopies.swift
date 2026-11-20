import Benchmark
import Bytes

// Runs (`write(repeating:…)`), literal copies from a reader (`write(from:byteCount:allowingOverrun:)`), short
// span copies (`write(_: RawSpan)` up to 64 bytes), and minimal LEB128 (`requiringMinimal:`). Each new form was
// measured next to the code it replaced, on the same data, until 2026-11-19; now setup checks it against that code.
// Every workload fills or reads 64 KB; divide by the operation count in its name for a per-operation cost.
//
// The workload functions are `@inline(never)`, taking widths and sizes as arguments, so those are run-time
// values, as in a decoder that reads them from a header. They take their lengths and buffers as arguments too:
// globals are lazily initialized, and a global read in the loop checks its `swift_once` token each time, which for
// tens of milliseconds after first use calls into `dispatch_once_f` (~36 instructions; the runs' rows were bimodal,
// 78 K against 104 K instructions, until 2026-11-19).

/// Deterministic pseudo-random lengths in `range`: a power-of-two count, so the workloads index with a mask.
func pseudoRandomLengths(in range: ClosedRange<Int>, seed: UInt64) -> [Int] {
    var state = seed
    return (0..<4096).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return range.lowerBound + Int((state >> 33) % UInt64(range.count))
    }
}

let runLengths = pseudoRandomLengths(in: 1...62, seed: 1) // QOI_OP_RUN's range
let literalLengths = pseudoRandomLengths(in: 0...15, seed: 2) // LZ4 literals without an extension byte
let longLiteralLengths = pseudoRandomLengths(in: 16...64, seed: 3)
nonisolated(unsafe) let runTarget = residentBuffer(byteCount: 64 << 10)
let copySource = randomBuffer(byteCount: 128 << 10)

// MARK: Runs

// Each workload below is one `@inline(__always)` body with a constant `filling`, compiled into two separate
// `@inline(never)` functions: in one function with a run-time flag, changes to the new path moved the
// reference path's register allocation (the `Byte3` generating write went from 70 K to 102 K instructions
// with no change to it).

@inline(never) func writeRunsFilling(width: Int, lengths: [Int], into buffer: UnsafeMutableRawBufferPointer) -> Int {
    writeRuns(width: width, lengths: lengths, filling: true, into: buffer)
}

@inline(never) func writeRunsPerElement(width: Int, lengths: [Int], into buffer: UnsafeMutableRawBufferPointer) -> Int {
    writeRuns(width: width, lengths: lengths, filling: false, into: buffer)
}

@inline(never) func writeGroupRunsFilling<T: ByteGroup>(_: T.Type, lengths: [Int], into buffer: UnsafeMutableRawBufferPointer) -> Int {
    writeGroupRuns(T.self, lengths: lengths, filling: true, into: buffer)
}

@inline(never) func writeGroupRunsGenerating<T: ByteGroup>(_: T.Type, lengths: [Int], into buffer: UnsafeMutableRawBufferPointer) -> Int {
    writeGroupRuns(T.self, lengths: lengths, filling: false, into: buffer)
}

@inline(never) func writeByteRunsFilling(length: Int, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    writeByteRuns(length: length, filling: true, into: buffer)
}

@inline(never) func writeByteRunsGenerating(length: Int, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    writeByteRuns(length: length, filling: false, into: buffer)
}

/// Runs of `width`-byte elements (a run-time width, like a QOI image's channel count), each run a different
/// element and `lengths[i]` long, until the next doesn't fit. Returns the bytes written.
@inline(__always)
func writeRuns(width: Int, lengths: [Int], filling: Bool, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    var index = 0
    while true {
        let count = lengths[index & 4095]
        guard writer.remainingByteCount >= count &* width else { break }
        let element = hashedWide(index)
        if filling {
            try! writer.write(repeating: element, byteCount: width, count: count)
        } else {
            // What QOI's decoder did: one 8-byte store per element, advancing by the width.
            for _ in 0..<count {
                try! writer.write(element, byteCount: width, allowingOverrun: true)
            }
        }
        index &+= 1
    }
    return writer.byteCount
}

/// Runs of `T`, a width known at compile time: `write(repeating:count:)` or the generating write.
@inline(__always)
func writeGroupRuns<T: ByteGroup>(_: T.Type, lengths: [Int], filling: Bool, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    var index = 0
    while true {
        let count = lengths[index & 4095]
        guard writer.remainingByteCount >= count &* T.byteCount else { break }
        let element = T(T.Integer(truncatingIfNeeded: hashedWide(index)), .littleEndian)
        if filling {
            try! writer.write(repeating: element, count: count)
        } else {
            try! writer.write(T.self, .littleEndian, count: count) { _ in element.littleEndian }
        }
        index &+= 1
    }
    return writer.byteCount
}

/// Byte runs of `length` bytes each (long ones go to `memset`).
@inline(__always)
func writeByteRuns(length: Int, filling: Bool, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    var index = 0
    while writer.remainingByteCount >= length {
        let byte = UInt8(truncatingIfNeeded: index)
        if filling {
            try! writer.write(repeating: Byte(byte), count: length)
        } else {
            try! writer.write(Byte.self, count: length) { _ in Byte(byte) } // The generating write.
        }
        index &+= 1
    }
    return writer.byteCount
}

// MARK: Copies from a reader

/// Copies literal runs of `lengths` from `source`, as an LZ4 decoder does, until either side runs out.
@inline(__always)
func copyLiterals(_ lengths: [Int], overrun: Bool, from source: RawSpan, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    var reader = BytesReader(source)
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    var index = 0
    while true {
        let count = lengths[index & 4095]
        guard reader.remainingByteCount >= count, writer.remainingByteCount >= count else { break }
        if overrun {
            try! writer.write(from: &reader, byteCount: count, allowingOverrun: true)
        } else {
            try! writer.write(reader.read(byteCount: count))
        }
        index &+= 1
    }
    return writer.byteCount
}

@inline(never)
func copyLiteralsOverrunning(_ lengths: [Int], from source: RawSpan, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    copyLiterals(lengths, overrun: true, from: source, into: buffer)
}

@inline(never)
func copyLiteralsExactly(_ lengths: [Int], from source: RawSpan, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    copyLiterals(lengths, overrun: false, from: source, into: buffer)
}

// MARK: Back-references

let matchLengths = pseudoRandomLengths(in: 3...32, seed: 4) // DEFLATE's shortest and most common
let longMatchLengths = pseudoRandomLengths(in: 3...258, seed: 5) // DEFLATE's whole range

/// Back-references `distance` bytes back (a run-time value), each after one literal byte, as compressed
/// streams alternate them, with overrun allowed as NativeZip and LZ4 copy, until the buffer is nearly full.
@inline(never)
func copyBackReferences(distance: Int, lengths: [Int], into buffer: UnsafeMutableRawBufferPointer) -> Int {
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    try! writer.write(hashedWide(0), byteCount: 8, allowingOverrun: false)
    var index = 0
    while true {
        let count = lengths[index & 4095]
        guard writer.remainingByteCount >= count &+ 1 &+ 32 else { break }
        try! writer.write(Byte(truncatingIfNeeded: index))
        try! writer.copy(fromDistance: distance, count: count, allowingOverrun: true)
        index &+= 1
    }
    return writer.byteCount
}

// MARK: Short span copies

/// Copies of `byteCount` bytes from varying offsets of `source`, until the buffer is full. `split` copies
/// over 32 bytes as two writes of at most 32 (the workaround Base64 used); `memmove` copies with a call, as
/// `write(_: RawSpan)` did above 32 bytes.
@inline(never)
func copySpans(byteCount: Int, method: SpanCopy, from source: RawSpan, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    var offset = 0
    var copied = 0
    while writer.remainingByteCount >= byteCount {
        let bytes = source.extracting(offset..<(offset &+ byteCount))
        switch method {
        case .write:
            try! writer.write(bytes)
        case .split:
            if bytes.byteCount > 32 {
                try! writer.write(bytes.extracting(first: 32))
                try! writer.write(bytes.extracting(droppingFirst: 32))
            } else {
                try! writer.write(bytes)
            }
        case .memmove:
            bytes.withUnsafeBytes { from in
                UnsafeMutableRawBufferPointer(rebasing: buffer[copied...]).copyMemory(from: from)
            }
            try! writer.skip(byteCount: byteCount)
        }
        copied &+= byteCount
        offset = (offset &+ 7) & 1023
    }
    return writer.byteCount
}

enum SpanCopy { case write, split, memmove }

// MARK: LEB128

/// Minimal LEB128 values of 1 to 4 bytes (half 1, a quarter 2, then 3 and 4), MQTT's Variable Byte Integers.
let leb128Values: [UInt8] = {
    var output = [UInt8](repeating: 0, count: 64 << 10)
    var span = output.mutableSpan
    var writer = BytesWriter(&span)
    var index = 0
    while writer.remainingByteCount >= 4 {
        let size = [1, 1, 1, 1, 2, 2, 3, 4][Int(hashed(index) >> 29)]
        let value = UInt64(hashed(index &+ 1)) % LEB128.maxValue(byteCount: size)
        try! writer.write(max(value, size == 1 ? 0 : LEB128.maxValue(byteCount: size &- 1) &+ 1), as: LEB128.self)
        index &+= 1
    }
    let written = writer.byteCount
    _ = consume writer
    _ = consume span
    return Array(output[..<written])
}()

enum LEB128Read { case plain, minimal, checkedAfter }

@inline(never)
func sumLEB128(_ method: LEB128Read, in bytes: RawSpan) -> UInt64 {
    var reader = BytesReader(bytes)
    var sum: UInt64 = 0
    while !reader.isAtEnd {
        switch method {
        case .plain:
            sum &+= try! reader.read(LEB128.self, maxByteCount: 4)
        case .minimal:
            sum &+= try! reader.read(LEB128.self, maxByteCount: 4, requiringMinimal: true)
        case .checkedAfter:
            // MQTT's check before `requiringMinimal`: read, then compare the length with the shortest.
            sum &+= try! reader.atomically { reader throws(BytesError) in
                let start = reader.byteOffset
                let value = try reader.read(LEB128.self, maxByteCount: 4)
                let byteCount = reader.byteOffset &- start
                guard byteCount == 1 || byteCount == LEB128.byteCount(of: value) else { throw .invalidValue }
                return value
            }
        }
    }
    return sum
}

// MARK: Registration

/// A workload: a name, a closure returning something to keep (bytes written, a sum), and the code it replaced, which
/// must return the same and leave the same bytes in `runTarget` (setup checks; the replaced code's own rows, "(before)",
/// were retired on 2026-11-19: their numbers are in the saved baselines).
struct RunsWorkload {
    let name: String
    let run: () -> Int
    var reference: (() -> Int)?
}

/// Each workload. The globals (about 300 KB in all) are made here, while registering, and captured as locals: a
/// closure reading a global checks its `swift_once` token on every call (see the top of the file).
func runsAndCopiesWorkloads() -> [RunsWorkload] {
    let target = runTarget, source = copySource, runs = runLengths, leb128 = leb128Values
    var workloads: [RunsWorkload] = []
    for width in [3, 4] {
        workloads.append(RunsWorkload(
            name: "Runs: \(width)-byte elements, 1-62 each, write(repeating:byteCount:count:)",
            run: { writeRunsFilling(width: width, lengths: runs, into: target) },
            reference: { writeRunsPerElement(width: width, lengths: runs, into: target) }
        ))
    }
    workloads.append(RunsWorkload(
        name: "Runs: Byte3, 1-62 each, write(repeating:count:)", run: { writeGroupRunsFilling(Byte3.self, lengths: runs, into: target) },
        reference: { writeGroupRunsGenerating(Byte3.self, lengths: runs, into: target) }
    ))
    for length in [8, 40, 1_000] {
        workloads.append(RunsWorkload(
            name: "Runs: bytes, \(length) each, write(repeating:count:)", run: { writeByteRunsFilling(length: length, into: target) },
            reference: { writeByteRunsGenerating(length: length, into: target) }
        ))
    }
    for (label, lengths) in [("0-15", literalLengths), ("16-64", longLiteralLengths)] {
        workloads.append(RunsWorkload(
            name: "Literals: \(label) B, write(from:byteCount:allowingOverrun:)",
            run: { source.withUnsafeBytes { copyLiteralsOverrunning(lengths, from: RawSpan(_unsafeBytes: $0), into: target) } },
            reference: { source.withUnsafeBytes { copyLiteralsExactly(lengths, from: RawSpan(_unsafeBytes: $0), into: target) } }
        ))
    }
    for distance in [1, 2, 3, 4, 6, 7, 8] {
        for (label, lengths) in [("3-32", matchLengths), ("3-258", longMatchLengths)] {
            workloads.append(RunsWorkload(name: "Back-references: distance \(distance), \(label) B", run: {
                copyBackReferences(distance: distance, lengths: lengths, into: target)
            }))
        }
    }
    for byteCount in [24, 32, 40, 48, 63, 64] {
        workloads.append(RunsWorkload(
            name: "Span copies: \(byteCount) B, write(_: RawSpan)",
            run: { source.withUnsafeBytes { copySpans(byteCount: byteCount, method: .write, from: RawSpan(_unsafeBytes: $0), into: target) } },
            reference: { source.withUnsafeBytes { copySpans(byteCount: byteCount, method: .memmove, from: RawSpan(_unsafeBytes: $0), into: target) } }
        ))
    }
    for (label, method) in [("read", LEB128Read.plain), ("read(requiringMinimal: true)", .minimal)] {
        workloads.append(RunsWorkload(
            name: "LEB128: 1-4 B, \(label)",
            run: { leb128.withUnsafeBytes { Int(truncatingIfNeeded: sumLEB128(method, in: RawSpan(_unsafeBytes: $0))) } },
            reference: { leb128.withUnsafeBytes { Int(truncatingIfNeeded: sumLEB128(.checkedAfter, in: RawSpan(_unsafeBytes: $0))) } }
        ))
    }
    return workloads
}

/// What a workload leaves: its result, and the target's bytes up to it (writes that allow overrun leave bytes past
/// their end; a sum leaves the target as it was).
private func outcome(_ run: () -> Int) -> (Int, [UInt8]) {
    runTarget.initializeMemory(as: UInt8.self, repeating: 0)
    let result = run()
    return (result, Array(runTarget.prefix(result)))
}

func registerRunsAndCopiesBenchmarks() {
    // Under 0.12 ms an operation: up to 5,000 samples in 100 ms (at least 800).
    let configuration = Benchmark.Configuration(
        metrics: [.wallClock, .instructions], warmupIterations: 10, scalingFactor: .one,
        maxDuration: .milliseconds(100), maxIterations: 5_000
    )
    for workload in runsAndCopiesWorkloads() {
        Benchmark(workload.name, configuration: configuration) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(workload.run())
            }
        } setup: {
            guard let reference = workload.reference else { return }
            let (result, bytes) = outcome(workload.run)
            let (expected, expectedBytes) = outcome(reference)
            precondition(result == expected && bytes == expectedBytes, "\(workload.name): wrong result")
        }
    }
}
