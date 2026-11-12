import Base64
import Benchmark
import Bytes
import Foundation

// MARK: - Fixtures

/// Input sizes: from short (a token, a header value) to beyond every cache (64 MB in, 85 MB out). The
/// powers of two from 64 B leave the block kernel 16 bytes at the end; 40, 47, 95, and 1000 B leave 40 or 47,
/// whose copies (bytes into the last block, 54 to 64 characters out) are longer than 32 bytes.
let sizes: [(label: String, count: Int)] = [
    ("40 B", 40), ("47 B", 47), ("64 B", 64), ("95 B", 95), ("1000 B", 1000), ("1 KB", 1 << 10),
    ("16 KB", 16 << 10), ("1 MB", 1 << 20), ("64 MB", 64 << 20),
]

/// Each measured iteration encodes (or decodes to) at least this many bytes, repeating short inputs, so
/// the clock resolves it.
let bytesPerIteration = 4 << 20

/// One size's input, its encoding, and output buffers for each direction: made once, before anything is
/// measured, so a benchmark's loop runs only the work. The outputs are raw buffers, shared by the
/// benchmarks of one size, so the loop takes no exclusive access of a captured variable either.
struct Fixture: @unchecked Sendable {
    let count: Int
    /// Calls per measured iteration: `count × repetitions` bytes, about 4 MB.
    let repetitions: Int
    let input: [UInt8]
    let inputData: Data
    let text: [UInt8]
    let textData: Data
    let encoded: UnsafeMutableBufferPointer<UInt8>
    let decoded: UnsafeMutableBufferPointer<UInt8>

    init(count: Int) {
        var generator = SystemRandomNumberGenerator()
        self.count = count
        repetitions = max(1, bytesPerIteration / count)
        let input = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let text = Array(Base64.encodedString(input.span.bytes).utf8)
        self.input = input
        inputData = Data(input)
        self.text = text
        textData = Data(text)
        encoded = .allocate(capacity: text.count)
        encoded.initialize(repeating: 0)
        decoded = .allocate(capacity: count)
        decoded.initialize(repeating: 0)
    }

    /// The encoded output, as an array.
    var encodedBytes: [UInt8] { Array(encoded) }
    /// The decoded output, as an array.
    var decodedBytes: [UInt8] { Array(decoded) }
}

let fixtures: [Int: Fixture] = Dictionary(uniqueKeysWithValues: sizes.map { ($0.count, Fixture(count: $0.count)) })

// MARK: - Encoders

/// Bytes: `BytesReader` → `Base64.encode` → `BytesWriter`, into a preallocated buffer.
func encodeWithBytes(_ fixture: Fixture) {
    for _ in 0..<fixture.repetitions {
        var span = unsafe MutableSpan(_unsafeElements: fixture.encoded)
        var writer = BytesWriter(&span)
        var reader = BytesReader(fixture.input.span)
        try! Base64.encode(&reader, into: &writer)
    }
}

/// The usual scalar encoder, for comparison: a 64-character table, one lookup per character. Each lookup
/// is a load from an index computed per character (a gather), so the loop doesn't vectorize.
func encodeScalar(_ input: Span<UInt8>, into output: inout MutableSpan<UInt8>) {
    let table: InlineArray<64, UInt8> = [
        65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90,
        97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117,
        118, 119, 120, 121, 122, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 43, 47,
    ]
    let groups = input.count / 3
    for group in 0..<groups {
        let b0 = input[3 * group], b1 = input[3 * group + 1], b2 = input[3 * group + 2]
        output[4 * group] = table[Int(b0 >> 2)]
        output[4 * group + 1] = table[Int((b0 & 3) << 4 | b1 >> 4)]
        output[4 * group + 2] = table[Int((b1 & 15) << 2 | b2 >> 6)]
        output[4 * group + 3] = table[Int(b2 & 63)]
    }
    let index = groups * 4
    switch input.count % 3 {
    case 1:
        let b0 = input[groups * 3]
        output[index] = table[Int(b0 >> 2)]
        output[index + 1] = table[Int((b0 & 3) << 4)]
        output[index + 2] = 61
        output[index + 3] = 61
    case 2:
        let b0 = input[groups * 3], b1 = input[groups * 3 + 1]
        output[index] = table[Int(b0 >> 2)]
        output[index + 1] = table[Int((b0 & 3) << 4 | b1 >> 4)]
        output[index + 2] = table[Int((b1 & 15) << 2)]
        output[index + 3] = 61
    default:
        break
    }
}

func encodeWithScalarTable(_ fixture: Fixture) {
    for _ in 0..<fixture.repetitions {
        var span = unsafe MutableSpan(_unsafeElements: fixture.encoded)
        encodeScalar(fixture.input.span, into: &span)
    }
}

/// Foundation: `Data.base64EncodedData()`, which allocates its result.
func encodeWithFoundation(_ fixture: Fixture) {
    for _ in 0..<fixture.repetitions {
        blackHole(fixture.inputData.base64EncodedData())
    }
}

/// `Base64.encodedString`: one allocation, the `String`.
func encodeToString(_ fixture: Fixture) {
    for _ in 0..<fixture.repetitions {
        blackHole(Base64.encodedString(fixture.input.span.bytes))
    }
}

// MARK: - Decoders

/// Bytes: `BytesReader` → `Base64.decode` → `BytesWriter`, into a preallocated buffer.
func decodeWithBytes(_ fixture: Fixture) {
    for _ in 0..<fixture.repetitions {
        var span = unsafe MutableSpan(_unsafeElements: fixture.decoded)
        var writer = BytesWriter(&span)
        var reader = BytesReader(fixture.text.span)
        try! Base64.decode(&reader, into: &writer)
    }
}

/// The package's portable kernel alone (4-character groups with arithmetic, auto-vectorized), over the
/// text's whole groups: what the ARM64 block kernel replaces there.
func decodeWithGroups(_ fixture: Fixture) {
    for _ in 0..<fixture.repetitions {
        var span = unsafe MutableSpan(_unsafeElements: fixture.decoded)
        var writer = BytesWriter(&span)
        var reader = BytesReader(fixture.text.span)
        let groups = try! reader.read(InlineArray<4, UInt8>.self, count: fixture.count / 3)
        let valid = try! writer.write(InlineArray<3, UInt8>.self, count: groups.count, filling: { bytes in
            Base64.decode(groups, into: &bytes, alphabet: .standard)
        })
        blackHole(valid)
    }
}

/// The usual scalar decoder: a 256-entry table (0xFF for characters not in the alphabet), one lookup per
/// character, validity ORed. Each lookup is a gather, so the loop doesn't vectorize.
func decodeScalar(_ text: Span<UInt8>, into output: inout MutableSpan<UInt8>) -> Bool {
    let table = scalarDecodingTable
    var groups = text.count / 4
    var padding = 0
    if groups > 0, text[text.count - 1] == 61 { padding = text[text.count - 2] == 61 ? 2 : 1; groups -= 1 }
    var invalid: UInt8 = 0
    for group in 0..<groups {
        let a = table[Int(text[4 * group])], b = table[Int(text[4 * group + 1])]
        let c = table[Int(text[4 * group + 2])], d = table[Int(text[4 * group + 3])]
        invalid |= a | b | c | d
        output[3 * group] = a << 2 | b >> 4
        output[3 * group + 1] = b << 4 | c >> 2
        output[3 * group + 2] = c << 6 | d
    }
    if padding > 0 {
        let index = groups * 4
        let a = table[Int(text[index])], b = table[Int(text[index + 1])]
        invalid |= a | b
        output[3 * groups] = a << 2 | b >> 4
        if padding == 1 {
            let c = table[Int(text[index + 2])]
            invalid |= c
            output[3 * groups + 1] = b << 4 | c >> 2
        }
    }
    return invalid & 0x80 == 0
}

let scalarDecodingTable: InlineArray<256, UInt8> = {
    var table = InlineArray<256, UInt8>(repeating: 0xFF)
    for (value, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
        table[Int(character)] = UInt8(value)
    }
    return table
}()

func decodeWithScalarTable(_ fixture: Fixture) {
    for _ in 0..<fixture.repetitions {
        var span = unsafe MutableSpan(_unsafeElements: fixture.decoded)
        blackHole(decodeScalar(fixture.text.span, into: &span))
    }
}

/// Foundation: `Data(base64Encoded:)`, which allocates its result.
func decodeWithFoundation(_ fixture: Fixture) {
    for _ in 0..<fixture.repetitions {
        blackHole(Data(base64Encoded: fixture.textData))
    }
}

/// `Base64.decodedBytes`: one allocation, the array.
func decodeToArray(_ fixture: Fixture) {
    for _ in 0..<fixture.repetitions {
        blackHole(try! Base64.decodedBytes(fixture.text.span.bytes))
    }
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = { registerBenchmarks() }

func registerBenchmarks() {
    Benchmark.defaultConfiguration = .init(
        // Only the work runs inside `scaledIterations`: no clocks or custom measurements there. Throughput
        // is the framework's, iterations per second; each iteration encodes or decodes `count × repetitions`
        // bytes (about 4 MB, `Fixture`), so bytes per second is that times the throughput.
        metrics: [.wallClock, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .seconds(1),
        maxIterations: 1_000
    )

    // The encoders and decoders agree, once, before anything is measured.
    for (_, count) in sizes where count < 64 << 20 {
        let fixture = fixtures[count]!
        encodeWithBytes(fixture)
        precondition(fixture.encodedBytes == fixture.text, "the encoder differs at \(count)")
        encodeWithScalarTable(fixture)
        precondition(fixture.encodedBytes == fixture.text, "the scalar encoder differs at \(count)")
        precondition(Array(fixture.inputData.base64EncodedData()) == fixture.text, "Foundation differs at \(count)")
        for decode in [decodeWithBytes, decodeWithScalarTable] {
            decode(fixture)
            precondition(fixture.decodedBytes == fixture.input, "a decoder differs at \(count)")
        }
        precondition(Data(base64Encoded: fixture.textData).map(Array.init) == fixture.input, "Foundation differs at \(count)")
        precondition(try! Base64.decodedBytes(fixture.text.span.bytes) == fixture.input, "decodedBytes differs at \(count)")
    }

    let encoders: [(name: String, run: (Fixture) -> Void)] = [
        ("Bytes (BytesReader → BytesWriter)", encodeWithBytes),
        ("Scalar table", encodeWithScalarTable),
        ("Foundation base64EncodedData", encodeWithFoundation),
        ("Bytes encodedString", encodeToString),
    ]
    let decoders: [(name: String, run: (Fixture) -> Void)] = [
        ("Bytes (BytesReader → BytesWriter)", decodeWithBytes),
        ("Bytes portable groups", decodeWithGroups),
        ("Scalar table", decodeWithScalarTable),
        ("Foundation Data(base64Encoded:)", decodeWithFoundation),
        ("Bytes decodedBytes", decodeToArray),
    ]
    for (label, count) in sizes {
        let fixture = fixtures[count]!
        for (name, run) in encoders {
            Benchmark("Encode \(label): \(name)") { (benchmark: Benchmark) in
                for _ in benchmark.scaledIterations {
                    run(fixture)
                }
            }
        }
        for (name, run) in decoders {
            Benchmark("Decode \(label): \(name)") { (benchmark: Benchmark) in
                for _ in benchmark.scaledIterations {
                    run(fixture)
                }
            }
        }
    }

    // Allocation checks: encoding and decoding into a buffer must not allocate, at any size. Static
    // thresholds of zero (`Thresholds/`), so `swift package benchmark thresholds check --filter
    // 'Allocations:.*'` fails if either does.
    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    // No spaces: `thresholds update` writes "_" for them in file names, but `thresholds check` looks files
    // up by the unaltered name (benchmark 1.38.1, ordo-one/benchmark#373).
    for (label, count) in sizes {
        let fixture = fixtures[count]!
        Benchmark("Allocations:Encode_\(label.replacing(" ", with: "_"))", configuration: zeroAllocations) { (benchmark: Benchmark) in
            for _ in benchmark.scaledIterations {
                encodeWithBytes(fixture)
            }
        }
        Benchmark("Allocations:Decode_\(label.replacing(" ", with: "_"))", configuration: zeroAllocations) { (benchmark: Benchmark) in
            for _ in benchmark.scaledIterations {
                decodeWithBytes(fixture)
            }
        }
    }
}
