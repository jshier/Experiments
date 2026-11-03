import Benchmark
import Foundation

// MARK: - Implementations under test

extension Span<UInt8> {
    /// Reduces every byte through bitwise OR; the result's high bit is set iff any element was non-ASCII.
    var isASCII: Bool {
        var result: UInt8 = 0
        for idx in self.indices {
            result |= self[unchecked: idx]
        }
        return result <= 127
    }

    /// Short-circuits on the first non-ASCII byte found.
    var isASCIIAll: Bool {
        allSatisfy { $0 <= 127 }
    }
}

extension Span {
    @inlinable
    func allSatisfy(predicate: (_ element: Element) -> Bool) -> Bool {
        for index in indices {
            if !predicate(self[unchecked: index]) {
                return false
            }
        }

        return true
    }
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

private func makeRandomBytes(count: Int, seed: UInt64, in range: ClosedRange<UInt8>) -> [UInt8] {
    var rng = SplitMix64(seed: seed)
    return (0..<count).map { _ in UInt8.random(in: range, using: &rng) }
}

// MARK: - Datasets
//
// Three shapes of input are benchmarked at every size:
//   - "mixed": bytes drawn from the full `UInt8` range, so both implementations typically scan the whole span
//     (a non-ASCII byte can appear anywhere, including never).
//   - "all-ASCII": every byte is in 0...127, the worst case for the short-circuiting `allSatisfy` implementation,
//     since it never finds a reason to stop early and must scan every element, just like the bitwise-OR version.
//   - "no-ASCII": every byte is in 128...255, the best case for `allSatisfy`, since it can return `false` after
//     inspecting only the first element, while the bitwise-OR version still scans the entire span regardless.

private enum DatasetKind: String, CaseIterable {
    case allASCII = "all-ASCII"
    case mixed
    case noASCII = "no-ASCII"

    var byteRange: ClosedRange<UInt8> {
        switch self {
        case .allASCII: 0...127
        case .mixed: .min ... .max
        case .noASCII: 128...255
        }
    }
}

/// Element counts to sweep, from empty up to ten million.
private let sizes = [0, 1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000]

private let datasets: [(kind: DatasetKind, size: Int, bytes: [UInt8])] =
    DatasetKind.allCases.flatMap { kind in
        sizes.map { size in
            (kind, size, makeRandomBytes(count: size, seed: UInt64(size) &+ 1, in: kind.byteRange))
        }
    }

/// Zero-padded so benchmark names sort in numeric, rather than lexicographic, order.
private let maxSizeDigits = String(sizes.max() ?? 0).count

private func paddedSizeLabel(_ size: Int) -> String {
    String(format: "%0\(maxSizeDigits)d", size)
}

// MARK: - Candidates

private let candidates: [(name: String, fn: @Sendable (Span<UInt8>) -> Bool)] = [
    ("bitwise OR", { $0.isASCII }),
    ("allSatisfy", { $0.isASCIIAll }),
]

// MARK: - Correctness check
//
// Both implementations must agree on every dataset before their timings are worth comparing at all.

private func verifyCandidatesAgree() {
    for dataset in datasets {
        let span = dataset.bytes.span
        let results = candidates.map { ($0.name, $0.fn(span)) }
        guard let expected = results.first?.1 else { continue }
        for (name, actual) in results {
            precondition(actual == expected,
                         "\(name) disagreed at \(dataset.kind.rawValue)/\(dataset.size): expected \(expected), got \(actual)")
        }

        // For the non-empty, fixed-content kinds, the outcome is known in advance regardless of candidate:
        // an "all-ASCII" span must report `true` and a "no-ASCII" span must report `false`.
        switch dataset.kind {
        case .allASCII:
            precondition(expected, "all-ASCII dataset of size \(dataset.size) should report isASCII == true")
        case .noASCII where dataset.size > 0:
            precondition(!expected, "no-ASCII dataset of size \(dataset.size) should report isASCII == false")
        case .mixed, .noASCII:
            break
        }
    }
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    verifyCandidatesAgree()

    let config = Benchmark.Configuration(
        metrics: [.cpuTotal, .wallClock, .throughput, .mallocCountTotal, .memoryLeaked],
        maxDuration: .seconds(2)
    )

    // Grouped by (padded) size, then kind, then candidate, so each combination sorts adjacently and is directly
    // comparable to its counterparts.
    for dataset in datasets {
        for candidate in candidates {
            Benchmark("\(paddedSizeLabel(dataset.size)) elements - \(dataset.kind.rawValue) - \(candidate.name)",
                      configuration: config) { benchmark in
                let span = dataset.bytes.span
                for _ in benchmark.scaledIterations {
                    blackHole(candidate.fn(span))
                }
            }
        }
    }
}
