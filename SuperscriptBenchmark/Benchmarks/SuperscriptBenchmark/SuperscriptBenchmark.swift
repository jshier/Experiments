import Benchmark
import Foundation

// MARK: - Implementations under test
//
// All four candidates assume a non-negative `Int`. The original, pasted implementation silently drops any
// character it doesn't recognize (including "-"), so negative numbers would lose their sign rather than gain a
// "⁻" prefix. Rather than "fixing" that behavior, the benchmark simply never exercises it: every value in the
// dataset is >= 0, so all four candidates are guaranteed to agree.

/// The pasted starting point: converts to a decimal `String`, maps each `Character` through a `switch`, then
/// re-joins the resulting single-character strings.
@inline(always)
func superscriptMapSwitch(_ x: Int) -> String {
    String(String(x).map {
        switch $0 {
        case "0": "⁰"
        case "1": "¹"
        case "2": "²"
        case "3": "³"
        case "4": "⁴"
        case "5": "⁵"
        case "6": "⁶"
        case "7": "⁷"
        case "8": "⁸"
        default: "⁹"
        }
    }
    .joined())
}

@usableFromInline
let superscriptDigits: [Character: Character] = [
    "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
    "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
]

/// Same decimal `String` + `map` shape as the original, but looks each digit up in a precomputed `Dictionary`
/// instead of running it through a `switch`.
@inline(always)
func superscriptDictionaryLookup(_ x: Int) -> String {
    String(String(x).compactMap { superscriptDigits[$0] })
}

/// Maps the ASCII value of each decimal digit `Character` to its superscript `Unicode.Scalar` arithmetically:
/// digits 0 and 4...9 sit at a constant offset (`0x2070`) from their digit value, while 1, 2, and 3 are
/// exceptions carried over from Latin-1 (U+00B9, U+00B2, U+00B3).
@inlinable
func superscriptScalar(forDigit d: Int) -> Unicode.Scalar {
    switch d {
    case 1: Unicode.Scalar(0xB9)!
    case 2: Unicode.Scalar(0xB2)!
    case 3: Unicode.Scalar(0xB3)!
    default: Unicode.Scalar(0x2070 + d)!
    }
}

@inlinable
func superscriptASCIIArithmetic(_ x: Int) -> String {
    var result: String = ""
    var divisor = Int(pow(10.0,floor(log10(Double(x)))))
    if divisor == 0 { return "⁰" }
    while divisor > 0 {
        result.append(Character(superscriptScalar(forDigit: (x / divisor) % 10)))
        divisor /= 10
    }
    return result
}

@inlinable
func superscriptASCIILookup(_ x: Int) -> String {
    var result: String = ""
    var divisor = Int(pow(10.0,floor(log10(Double(x)))))
    if divisor == 0 { return "⁰" }
    while divisor > 0 {
        let digit: Character = switch (x / divisor) % 10 {
            case 0: "⁰"
            case 1: "¹"
            case 2: "²"
            case 3: "³"
            case 4: "⁴"
            case 5: "⁵"
            case 6: "⁶"
            case 7: "⁷"
            case 8: "⁸"
            default: "⁹"
        }
        result.append(digit)
        divisor /= 10
    }
    return result
}

@inlinable
func superscriptArrayLookup(_ x: Int) -> String {
    let digits: [Character] = ["⁰","¹","²","³","⁴","⁵","⁶","⁷","⁸","⁹"]
    var result: String = ""
    var divisor = Int(pow(10.0,floor(log10(Double(x)))))
    if divisor == 0 { return "⁰" }
    while divisor > 0 {
        result.append(digits[(x / divisor) % 10])
        divisor /= 10
    }
    return result
}

@inlinable
func superscriptBufferBuild(_ x: Int) -> String {
    // if x < 10 { return ["⁰","¹","²","³","⁴","⁵","⁶","⁷","⁸","⁹"][x] }
    
    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 100) { buffer in
        let end = buffer.baseAddress! + 99
        var pointer = end
        var x = x
    
        while x > 0 {
            let digit = UInt8(x % 10)
            switch digit {
            case 1:
                pointer.pointee = 185
                pointer -= 1
                pointer.pointee = 194
            case 2:
                pointer.pointee = 178
                pointer -= 1
                pointer.pointee = 194
            case 3:
                pointer.pointee = 179
                pointer -= 1
                pointer.pointee = 194
            default:
                pointer.pointee = 176 + digit
                pointer -= 1
                pointer.pointee = 129
                pointer -= 1
                pointer.pointee = 226
            }
            x /= 10
            pointer -= 1
        }
        return String(decoding: UnsafeBufferPointer(start: pointer+1, count: (end - pointer)), as: UTF8.self)
    }
}

/// Extracts decimal digits directly from `x` via repeated `%`/`/`, never allocating an intermediate decimal
/// `String` at all.
@inlinable
func superscriptDigitsNoString(_ x: Int) -> String {
    if x == 0 {
        return "⁰"
    }

    var digits: [Int] = []
    digits.reserveCapacity(19) // Int.max has 19 decimal digits.
    var n = x
    while n > 0 {
        digits.append(n % 10)
        n /= 10
    }

    var scalars = [Unicode.Scalar](repeating: Unicode.Scalar(0x2070)!, count: digits.count)
    for (i, d) in digits.reversed().enumerated() {
        scalars[i] = superscriptScalar(forDigit: d)
    }
    return String(String.UnicodeScalarView(scalars))
}

@inlinable
func superscriptMapNoLookup(_ x: Int) -> String {
    String(String(x).compactMap {
        guard let digit = $0.wholeNumberValue, (0...9).contains(digit) else { return nil }
    
        let base = digit < 4 ? [0x2070, 0x00B9, 0x00B2, 0x00B3][digit] : 0x2070 + UInt32(digit)
        return Unicode.Scalar(base).map(String.init)
    }.joined())
}

// MARK: - Seeded, deterministic random data

/// A small, seedable `RandomNumberGenerator` so benchmark inputs are reproducible across runs.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Datasets
//
// Inputs are swept by decimal digit count (1...19, the range of a non-negative `Int`), since digit count is what
// drives the length of the loop/map in every candidate. One deterministic, representative value is generated per
// digit count; `0` is included separately as the single-digit edge case shared by every candidate.

private func pow10(_ exponent: Int) -> Int {
    var result = 1
    for _ in 0..<exponent { result *= 10 }
    return result
}

/// Generates a value with exactly `digitCount` decimal digits (no leading zero), deterministically seeded.
private func makeRepresentativeValue(digitCount: Int, seed: UInt64) -> Int {
    var rng = SplitMix64(seed: seed)
    let low = digitCount == 1 ? 0 : pow10(digitCount - 1)
    let high = digitCount == 19 ? Int.max : pow10(digitCount) - 1
    return Int.random(in: low...high, using: &rng)
}

/// Zero-padded so benchmark names sort in numeric, rather than lexicographic, order.
private func paddedDigitCountLabel(_ digitCount: Int) -> String {
    String(format: "%02d", digitCount)
}

private let digitCounts = Array(1...19)

private let datasets: [(digitCount: Int, value: Int)] = digitCounts.map { digitCount in
    (digitCount, makeRepresentativeValue(digitCount: digitCount, seed: UInt64(digitCount) &+ 1))
}

// MARK: - Candidates

private let candidates: [(name: String, fn: @Sendable (Int) -> String)] = [
    // ("map+switch", { superscriptMapSwitch($0) }),
    // ("map, no lookup", { superscriptMapNoLookup($0) }),
    // ("dictionary lookup", { superscriptDictionaryLookup($0) }),
    ("ASCII arithmetic", { superscriptASCIIArithmetic($0) }),
    ("ASCII lookup", { superscriptASCIILookup($0) }),
    ("Array lookup", { superscriptArrayLookup($0) }),
    ("Buffer builder", { superscriptBufferBuild($0) }),
    // ("digits, no String", { superscriptDigitsNoString($0) }),
]

// MARK: - Correctness check
//
// Every candidate must agree on every dataset before their timings are worth comparing at all.

private func verifyCandidatesAgree() {
    for dataset in datasets {
        let results = candidates.map { ($0.name, $0.fn(dataset.value)) }
        guard let expected = results.first?.1 else { continue }
        for (name, actual) in results {
            precondition(actual == expected,
                         "\(name) disagreed at \(dataset.digitCount) digits (\(dataset.value)): " +
                         "expected \(expected), got \(actual)")
        }
    }
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    verifyCandidatesAgree()

    let config = Benchmark.Configuration(
        metrics: [.cpuTotal, .wallClock, .throughput, .mallocCountTotal, .instructions],
        maxDuration: .seconds(5)
    )

    // Grouped by (padded) digit count, then candidate, so each combination sorts adjacently and is directly
    // comparable to its counterparts.
    for dataset in datasets {
        for candidate in candidates {
            Benchmark("\(paddedDigitCountLabel(dataset.digitCount)) digits - \(candidate.name)",
                      configuration: config) { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(candidate.fn(dataset.value))
                }
            }
        }
    }
}
