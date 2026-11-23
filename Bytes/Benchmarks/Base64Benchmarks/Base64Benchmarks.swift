import BytesBase64
import Benchmark
import Bytes
import BytesTestSupport
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
        // Random bytes 8 at a time (a byte at a time took about a second for 64 MB).
        var input = [UInt8](repeating: 0, count: count)
        for offset in stride(from: 0, to: count, by: 8) {
            withUnsafeBytes(of: generator.next() as UInt64) { random in
                for index in 0..<min(8, count - offset) { input[offset + index] = random[index] }
            }
        }
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

/// Each size's fixture, made on first use (BytesTestSupport's `Lazy`): the benchmark tool starts this executable once
/// to list the benchmarks and again for each benchmark, so each process makes only the fixture its benchmark runs (a
/// 64 MB one took about a second, in every process), from the benchmark's setup, before anything is measured.
let fixtures: [Int: Lazy<Fixture>] = Dictionary(uniqueKeysWithValues: sizes.map { size in
    (size.count, Lazy { Fixture(count: size.count) })
})

// MARK: - Encoders

// The alphabets (and the scalar decoder's table) are lazily initialized globals: each workload reads them once,
// before its repetitions. A default `alphabet: .standard` checks its `swift_once` token on every call, and for tens of
// milliseconds after first use that calls into `dispatch_once_f` (~36 instructions; 100,000 calls an iteration at 40 B).

/// Bytes: `AlignedBytesReader` → `Base64.encode` → `AlignedBytesWriter`, into a preallocated buffer.
func encodeWithBytes(_ fixture: Fixture) {
    let alphabet = Base64.Alphabet.standard
    for _ in 0..<fixture.repetitions {
        var span = unsafe MutableSpan(_unsafeElements: fixture.encoded)
        var writer = AlignedBytesWriter(&span)
        var reader = AlignedBytesReader(fixture.input.span)
        try! Base64.encode(&reader, into: &writer, alphabet: alphabet)
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

/// Bytes: `AlignedBytesReader` → `Base64.decode` → `AlignedBytesWriter`, into a preallocated buffer.
func decodeWithBytes(_ fixture: Fixture) {
    let alphabet = Base64.Alphabet.standard
    for _ in 0..<fixture.repetitions {
        var span = unsafe MutableSpan(_unsafeElements: fixture.decoded)
        var writer = AlignedBytesWriter(&span)
        var reader = AlignedBytesReader(fixture.text.span)
        try! Base64.decode(&reader, into: &writer, alphabet: alphabet)
    }
}

/// The package's portable kernel alone (4-character groups with arithmetic, auto-vectorized), over the
/// text's whole groups: what the ARM64 block kernel replaces there.
func decodeWithGroups(_ fixture: Fixture) {
    let alphabet = Base64.Alphabet.standard
    for _ in 0..<fixture.repetitions {
        var span = unsafe MutableSpan(_unsafeElements: fixture.decoded)
        var writer = AlignedBytesWriter(&span)
        var reader = AlignedBytesReader(fixture.text.span)
        let groups = try! reader.read(InlineArray<4, UInt8>.self, count: fixture.count / 3)
        let valid = try! writer.write(InlineArray<3, UInt8>.self, count: groups.count, filling: { bytes in
            Base64.decode(groups, into: &bytes, alphabet: alphabet)
        })
        blackHole(valid)
    }
}

/// The usual scalar decoder: a 256-entry table (0xFF for characters not in the alphabet), one lookup per
/// character, validity ORed. Each lookup is a gather, so the loop doesn't vectorize.
func decodeScalar(_ text: Span<UInt8>, into output: inout MutableSpan<UInt8>, table: InlineArray<256, UInt8>) -> Bool {
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
    let table = scalarDecodingTable
    for _ in 0..<fixture.repetitions {
        var span = unsafe MutableSpan(_unsafeElements: fixture.decoded)
        blackHole(decodeScalar(fixture.text.span, into: &span, table: table))
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
    // This runs in every process the benchmark tool starts (one to list, then one per benchmark): it only
    // registers. Each benchmark's setup makes its fixture and checks its codec's output once.
    //
    // An iteration is about 4 MB of work: 0.3–20 ms below 64 MB. 50 samples, at most half a second: against
    // 1,000 (2026-11-19), instruction medians within the printed resolution, except `encodedString` below 1 KB,
    // which allocates per call: 1.3–1.7% lower, the same in two runs.
    Benchmark.defaultConfiguration = .init(
        // Only the work runs inside `scaledIterations`: no clocks or custom measurements there. Throughput
        // is the framework's, iterations per second; each iteration encodes or decodes `count × repetitions`
        // bytes (about 4 MB, `Fixture`), so bytes per second is that times the throughput.
        metrics: [.wallClock, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .milliseconds(500),
        maxIterations: 50
    )
    // 64 MB, from memory: 6–150 ms per iteration, 20 samples within a second or two.
    var large = Benchmark.defaultConfiguration
    large.warmupIterations = 1
    large.maxDuration = .seconds(1)
    large.maxIterations = 20

    // Each codec with the check its benchmark's setup runs: the encoders' output is the fixture's text, the
    // decoders' its input (not at 64 MB, as before; the portable groups decode only whole groups, and
    // `encodedString` made the text).
    typealias Codec = (name: String, run: (Fixture) -> Void, check: ((Fixture) -> Bool)?)
    let encoders: [Codec] = [
        ("Bytes (BytesReader → BytesWriter)", encodeWithBytes, { encodeWithBytes($0); return $0.encodedBytes == $0.text }),
        ("Scalar table", encodeWithScalarTable, { encodeWithScalarTable($0); return $0.encodedBytes == $0.text }),
        ("Foundation base64EncodedData", encodeWithFoundation, { Array($0.inputData.base64EncodedData()) == $0.text }),
        ("Bytes encodedString", encodeToString, nil),
    ]
    let decoders: [Codec] = [
        ("Bytes (BytesReader → BytesWriter)", decodeWithBytes, { decodeWithBytes($0); return $0.decodedBytes == $0.input }),
        ("Bytes portable groups", decodeWithGroups, nil),
        ("Scalar table", decodeWithScalarTable, { decodeWithScalarTable($0); return $0.decodedBytes == $0.input }),
        ("Foundation Data(base64Encoded:)", decodeWithFoundation, { Data(base64Encoded: $0.textData).map(Array.init) == $0.input }),
        ("Bytes decodedBytes", decodeToArray, { try! Base64.decodedBytes($0.text.span.bytes) == $0.input }),
    ]
    for (label, count) in sizes {
        let lazyFixture = fixtures[count]!
        let configuration = count < 64 << 20 ? Benchmark.defaultConfiguration : large
        for (direction, codecs) in [("Encode", encoders), ("Decode", decoders)] {
            for (name, run, check) in codecs {
                let benchmarkName = "\(direction) \(label): \(name)"
                Benchmark(benchmarkName, configuration: configuration, closure: { (benchmark: Benchmark) in
                    let fixture = lazyFixture.value
                    for _ in benchmark.scaledIterations {
                        run(fixture)
                    }
                }, setup: {
                    let fixture = lazyFixture.value
                    if let check, count < 64 << 20 {
                        precondition(check(fixture), "\(benchmarkName): the output differs")
                    }
                })
            }
        }
    }

    // 16 KB as MIME and PEM hold it: lines of 76 characters, CRLF after each (a line break inside the first 16
    // characters of most blocks), decoded skipping the whitespace; and encoded with the URL-safe alphabet, unpadded.
    let lined = Lazy { LinedText(fixtures[16 << 10]!.value) }
    Benchmark("Decode 16 KB, 76-column lines: Bytes ignoringWhitespace", closure: { (benchmark: Benchmark) in
        let fixture = lined.value
        for _ in benchmark.scaledIterations {
            decodeLinesWithBytes(fixture)
        }
    }, setup: {
        let fixture = lined.value
        decodeLinesWithBytes(fixture)
        precondition(fixture.base.decodedBytes == fixture.base.input, "Decode 16 KB, 76-column lines: the output differs")
    })
    Benchmark("Decode 16 KB, 76-column lines: Foundation Data(base64Encoded:options: .ignoreUnknownCharacters)", closure: { (benchmark: Benchmark) in
        let fixture = lined.value
        for _ in benchmark.scaledIterations {
            decodeLinesWithFoundation(fixture)
        }
    }, setup: {
        let fixture = lined.value
        precondition(Data(base64Encoded: fixture.linesData, options: .ignoreUnknownCharacters).map(Array.init) == fixture.base.input)
    })
    let urlSafe = fixtures[16 << 10]!
    Benchmark("Encode 16 KB: Bytes, URL-safe unpadded", closure: { (benchmark: Benchmark) in
        let fixture = urlSafe.value
        for _ in benchmark.scaledIterations {
            encodeURLSafeWithBytes(fixture)
        }
    }, setup: {
        let fixture = urlSafe.value
        encodeURLSafeWithBytes(fixture)
        // The standard text with `-` and `_` for `+` and `/`, and no `=`.
        let expected = fixture.text.filter { $0 != UInt8(ascii: "=") }.map { $0 == UInt8(ascii: "+") ? UInt8(ascii: "-") : $0 == UInt8(ascii: "/") ? UInt8(ascii: "_") : $0 }
        precondition(Array(fixture.encoded.prefix(expected.count)) == expected, "Encode 16 KB, URL-safe: the output differs")
    })

    // Allocation checks: encoding and decoding into a buffer must not allocate, at any size. Static
    // thresholds of zero (`Thresholds/`), so `swift package benchmark thresholds check --filter
    // 'Allocations:.*'` fails if either does.
    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    // One gate per direction over every size (a gate's count is the sum of its sizes', so it fails if any size
    // allocates): until 2026-11-19 a gate per size, 18 processes. No spaces: `thresholds update` writes "_" for them
    // in file names, but `thresholds check` looks files up by the unaltered name (benchmark 1.38.1,
    // ordo-one/benchmark#373).
    // Each size's fixture is made in setup (the fixtures' array too: made in the measured closure, it was a malloc).
    let lazyFixtures = sizes.map { fixtures[$0.count]! }
    nonisolated(unsafe) var all: [Fixture] = []
    Benchmark("Allocations:Encode_all_sizes", configuration: zeroAllocations, closure: { (benchmark: Benchmark) in
        for _ in benchmark.scaledIterations {
            for fixture in all {
                encodeWithBytes(fixture)
            }
        }
    }, setup: { all = lazyFixtures.map(\.value) })
    Benchmark("Allocations:Decode_all_sizes", configuration: zeroAllocations, closure: { (benchmark: Benchmark) in
        for _ in benchmark.scaledIterations {
            for fixture in all {
                decodeWithBytes(fixture)
            }
        }
    }, setup: { all = lazyFixtures.map(\.value) })
    Benchmark("Allocations:Decode_16KB_lines", configuration: zeroAllocations, closure: { (benchmark: Benchmark) in
        let fixture = lined.value
        for _ in benchmark.scaledIterations {
            decodeLinesWithBytes(fixture)
        }
    }, setup: { _ = lined.value })
}

// MARK: - Lines and URL-safe

/// A size's fixture with its text in 76-character lines, each followed by CRLF (MIME's form, RFC 2045).
struct LinedText: @unchecked Sendable {
    let base: Fixture
    let lines: [UInt8]
    let linesData: Data

    init(_ base: Fixture) {
        self.base = base
        var lines: [UInt8] = []
        lines.reserveCapacity(base.text.count + base.text.count / 38 + 2)
        for start in stride(from: 0, to: base.text.count, by: 76) {
            lines += base.text[start..<min(start + 76, base.text.count)]
            lines += [0x0D, 0x0A]
        }
        self.lines = lines
        linesData = Data(lines)
    }
}

/// `Base64.decode(ignoringWhitespaceIn:into:)` into the preallocated buffer.
func decodeLinesWithBytes(_ fixture: LinedText) {
    let alphabet = Base64.Alphabet.standard
    for _ in 0..<fixture.base.repetitions {
        // Unsafe: a span over the fixture's buffer. Safe: allocated for the process's life, used by one thread.
        var span = unsafe MutableSpan(_unsafeElements: fixture.base.decoded)
        var writer = AlignedBytesWriter(&span)
        try! Base64.decode(ignoringWhitespaceIn: fixture.lines.span.bytes, into: &writer, alphabet: alphabet)
    }
}

/// Foundation: `Data(base64Encoded:options: .ignoreUnknownCharacters)`, which allocates its result.
func decodeLinesWithFoundation(_ fixture: LinedText) {
    for _ in 0..<fixture.base.repetitions {
        blackHole(Data(base64Encoded: fixture.linesData, options: .ignoreUnknownCharacters))
    }
}

/// `Base64.encode` with the URL-safe alphabet and no padding, into the preallocated buffer.
func encodeURLSafeWithBytes(_ fixture: Fixture) {
    let alphabet = Base64.Alphabet.urlSafe
    for _ in 0..<fixture.repetitions {
        // Unsafe: a span over the fixture's buffer. Safe: allocated for the process's life, used by one thread.
        var span = unsafe MutableSpan(_unsafeElements: fixture.encoded)
        var writer = AlignedBytesWriter(&span)
        try! Base64.encode(fixture.input.span.bytes, into: &writer, alphabet: alphabet, padding: false)
    }
}
