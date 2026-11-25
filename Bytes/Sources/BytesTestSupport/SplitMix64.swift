// Deterministic pseudo-random data for tests and benchmarks. Recorded digests, thresholds, and benchmark inputs
// depend on these exact sequences: don't change the constants or how bytes are taken from each step.

/// SplitMix64: a small, fast, deterministic generator for fixtures (Steele, Lea, and Flood's constants).
///
/// Every copy this replaced (Bytes', MQTT's, NativeZipArchive's, NativeAEA's, SocketStream's) used these constants,
/// with `state` the seed and incremented before each output.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    /// The state: the seed, advanced by the golden-ratio increment at each step.
    public var state: UInt64

    /// A generator starting from `seed`.
    ///
    /// - Parameter seed: The initial state.
    @inlinable
    public init(seed: UInt64) {
        state = seed
    }

    /// The next 64 bits.
    @inlinable
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `count` bytes, one per step: each step's low byte (as `UInt8.random(in: 0...255, using:)` takes them).
    ///
    /// - Parameter count: How many bytes.
    /// - Returns: The bytes.
    @inlinable
    public mutating func bytes(_ count: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8(truncatingIfNeeded: next()))
        }
        return bytes
    }

    /// `count` bytes, eight per step: each step's 64 bits in little-endian order, the last step's truncated.
    ///
    /// - Parameter count: How many bytes.
    /// - Returns: The bytes.
    @inlinable
    public mutating func packedBytes(_ count: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            let word = next()
            for index in 0..<min(8, count &- bytes.count) {
                bytes.append(UInt8(truncatingIfNeeded: word >> (8 &* UInt64(index))))
            }
        }
        return bytes
    }
}
