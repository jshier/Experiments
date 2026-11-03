import Benchmark
import Foundation

// MARK: - Instant representation
//
// Mirrors Alamofire's Source/Core/Instant.swift fields. Only the description
// implementations differ between the variants below.

struct Instant {
    let seconds: Int
    let nanoseconds: Int
}

// MARK: - Candidates

// 1) Baseline: current implementation using Foundation's String(format:) and an
//    interpolated format string to vary the leading-zero width.
extension Instant {
    var descriptionBaseline: String {
        var nanos = nanoseconds
        var width = 9
        while width > 1 && nanos % 10 == 0 {
            nanos /= 10
            width -= 1
        }
        return String(format: "%d.%0\(width)d", seconds, nanos)
    }
}

// 2) Native: standard-library integer-to-string conversion plus a constant
//    leading-zero padding table. No Foundation, no format parser, no varargs.
private let leadingZeros: [String] = ["", "0", "00", "000", "0000",
                                      "00000", "000000", "0000000", "00000000"]

extension Instant {
    var descriptionNative: String {
        var nanos = nanoseconds
        var trailing = 0
        while trailing < 8 && nanos % 10 == 0 {
            nanos /= 10
            trailing += 1
        }
        let digits = String(nanos)
        let padding = leadingZeros[9 - trailing - digits.count]
        return "\(seconds).\(padding)\(digits)"
    }
}

extension Instant {
    var descriptionCountZeros: String {
        var nanos = nanoseconds
        var trailing = 0
        while trailing < 8 && nanos % 10 == 0 {
            nanos /= 10
            trailing += 1
        }
        let digits = String(nanos)
        let padding = String(repeating: "0", count: 9 - trailing - digits.count)
        return "\(seconds).\(padding)\(digits)"
    }
}

// 3) Stack buffer: write the entire string into a stack-allocated UTF-8 buffer
//    and construct a single String from that slice. Avoids every intermediate
//    allocation.
extension Instant {
    var descriptionStackBuffer: String {
        // Worst-case width: 20 (Int64.min digits + sign) + 1 (dot) + 9 (ns) = 30.
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
            var i = 0

            // --- Write seconds (signed). ---
            var s = seconds
            let negative = s < 0
            if negative { s = -s }
            // Write digits in reverse, then reverse the span.
            let secondsStart = i
            if s == 0 {
                buffer[i] = UInt8(ascii: "0"); i += 1
            } else {
                while s > 0 {
                    buffer[i] = UInt8(ascii: "0") &+ UInt8(s % 10)
                    s /= 10
                    i += 1
                }
            }
            // Reverse the seconds digits in place.
            var lo = secondsStart, hi = i - 1
            while lo < hi {
                let t = buffer[lo]; buffer[lo] = buffer[hi]; buffer[hi] = t
                lo &+= 1; hi &-= 1
            }
            if negative {
                // Shift right by one and insert '-'. Cheaper to write '-' first
                // by re-doing: but seconds is small, so just memmove one byte.
                // Instead, simpler: pre-emit '-' before writing seconds.
                // For clarity we do the simpler thing here — but the negative
                // path is exceedingly rare for monotonic clocks.
                for j in stride(from: i, through: secondsStart + 1, by: -1) {
                    buffer[j] = buffer[j - 1]
                }
                buffer[secondsStart] = UInt8(ascii: "-")
                i += 1
            }

            // --- Decimal point. ---
            buffer[i] = UInt8(ascii: "."); i += 1

            // --- Nanoseconds: trim trailing zeros, then write with leading zeros. ---
            var nanos = nanoseconds
            var trailing = 0
            while trailing < 8 && nanos % 10 == 0 {
                nanos /= 10
                trailing += 1
            }
            // Count remaining digits in nanos.
            var nDigits = 0
            var tmp = nanos
            if tmp == 0 {
                nDigits = 1
            } else {
                while tmp > 0 { nDigits += 1; tmp /= 10 }
            }
            let totalNanoWidth = 9 - trailing
            let leading = totalNanoWidth - nDigits
            for _ in 0..<leading {
                buffer[i] = UInt8(ascii: "0"); i += 1
            }
            // Write nanos digits, reverse the span.
            let nanosStart = i
            if nanos == 0 {
                buffer[i] = UInt8(ascii: "0"); i += 1
            } else {
                while nanos > 0 {
                    buffer[i] = UInt8(ascii: "0") &+ UInt8(nanos % 10)
                    nanos /= 10
                    i += 1
                }
            }
            var nlo = nanosStart, nhi = i - 1
            while nlo < nhi {
                let t = buffer[nlo]; buffer[nlo] = buffer[nhi]; buffer[nhi] = t
                nlo &+= 1; nhi &-= 1
            }

            return String(decoding: UnsafeBufferPointer(rebasing: buffer[0..<i]), as: UTF8.self)
        }
    }
}

// MARK: - Test inputs
//
// Cover the major shape classes of (seconds, nanoseconds):
//   - zero-zero  (cheap path: shortest output)
//   - nonzero seconds, zero nanoseconds (loop runs to width=1)
//   - tiny nanoseconds (many leading zeros, no trailing)
//   - maximum nanoseconds (no leading zeros, no trailing)
//   - half-second (lots of trailing zeros)
//   - generic mixed (no leading, no trailing)
//   - large seconds with full-width nanoseconds (worst-case digit count)
private let inputs: [Instant] = [
    Instant(seconds: 0,           nanoseconds: 0),
    Instant(seconds: 5,           nanoseconds: 0),
    Instant(seconds: 0,           nanoseconds: 1),
    Instant(seconds: 0,           nanoseconds: 999_999_999),
    Instant(seconds: 1,           nanoseconds: 500_000_000),
    Instant(seconds: 1,           nanoseconds: 1),
    Instant(seconds: 123_456_789, nanoseconds: 123_456_789),
]

// MARK: - Correctness check
//
// Run before any benchmark so a typo in a candidate fails loudly instead of
// quietly producing the wrong answer at high throughput.
private func verifyCandidatesAgree() {
    for input in inputs {
        let a = input.descriptionBaseline
        let b = input.descriptionNative
        let c = input.descriptionStackBuffer
        precondition(a == b && b == c,
                     "Mismatch for \(input): baseline=\(a) native=\(b) stackBuffer=\(c)")
    }
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    verifyCandidatesAgree()

    // scalingFactor: .kilo means each iteration body runs the inner loop 1_000
    // times, so reported time is per-1000-formats. We loop over all inputs
    // inside that to get a representative mix in a single measurement.
    let config = Benchmark.Configuration(
        metrics: [.cpuTotal, .wallClock, .mallocCountTotal, .throughput],
        scalingFactor: .kilo,
        maxDuration: .seconds(3),
        maxIterations: 1_000_000,
        thresholds: [.throughput: .relaxed, .wallClock: .relaxed]
    )

    Benchmark("Baseline (String(format:))", configuration: config) { benchmark in
        for _ in benchmark.scaledIterations {
            for input in inputs {
                blackHole(input.descriptionBaseline)
            }
        }
    }

    Benchmark("Native (interpolation + table)", configuration: config) { benchmark in
        for _ in benchmark.scaledIterations {
            for input in inputs {
                blackHole(input.descriptionNative)
            }
        }
    }
    
    Benchmark("Native (interpolation + count)", configuration: config) { benchmark in
        for _ in benchmark.scaledIterations {
            for input in inputs {
                blackHole(input.descriptionCountZeros)
            }
        }
    }

    Benchmark("Stack buffer (UTF-8 write)", configuration: config) { benchmark in
        for _ in benchmark.scaledIterations {
            for input in inputs {
                blackHole(input.descriptionStackBuffer)
            }
        }
    }
}
