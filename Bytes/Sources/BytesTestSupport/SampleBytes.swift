/// Generated sample inputs for codec tests and benchmarks: text, incompressible bytes, short periods, and mixes of
/// them, each a function of its size and seed (Bytes' LZ tests' generators).
public enum SampleBytes {
    /// The words ``text(_:seed:)`` strings together.
    public static let words = [
        "the", "decoder", "reads", "a", "block", "of", "literal", "bytes", "and", "matches", "from", "earlier",
        "output", "LZFSE", "entropy", "state", "table", "copy", "sixteen", "at", "time", "while", "room", "remains",
        "\n", "in", "buffer", "Apple", "archive", "segment", "compressed", "with", "finite",
    ]

    /// English-like words: compressible, with matches of every length and distance.
    ///
    /// - Parameters:
    ///   - count: How many bytes.
    ///   - seed: The generator's seed.
    /// - Returns: The bytes.
    public static func text(_ count: Int, seed: UInt64) -> [UInt8] {
        var generator = SplitMix64(seed: seed)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count + 16)
        while bytes.count < count {
            bytes += words[Int(generator.next() % UInt64(words.count))].utf8
            bytes.append(generator.next() % 7 == 0 ? UInt8(ascii: ",") : UInt8(ascii: " "))
        }
        return Array(bytes.prefix(count))
    }

    /// Incompressible bytes: one per step of ``SplitMix64`` from `seed`.
    ///
    /// - Parameters:
    ///   - count: How many bytes.
    ///   - seed: The generator's seed.
    /// - Returns: The bytes.
    public static func random(_ count: Int, seed: UInt64) -> [UInt8] {
        var generator = SplitMix64(seed: seed)
        return generator.bytes(count)
    }

    /// A random pattern of `period` bytes, repeated.
    ///
    /// - Parameters:
    ///   - count: How many bytes.
    ///   - period: The pattern's length.
    ///   - seed: The pattern's seed (as for ``random(_:seed:)``).
    /// - Returns: The bytes.
    public static func periodic(_ count: Int, period: Int, seed: UInt64) -> [UInt8] {
        let pattern = random(period, seed: seed)
        return (0..<count).map { pattern[$0 % period] }
    }

    /// Text, random bytes, runs, and periodic stretches, in pieces of random sizes.
    ///
    /// - Parameters:
    ///   - count: How many bytes.
    ///   - seed: The generator's seed.
    /// - Returns: The bytes.
    public static func mixed(_ count: Int, seed: UInt64) -> [UInt8] {
        var generator = SplitMix64(seed: seed)
        var bytes: [UInt8] = []
        while bytes.count < count {
            let size = Int(generator.next() % 3000) + 1
            switch generator.next() % 4 {
            case 0: bytes += text(size, seed: generator.next())
            case 1: bytes += random(size, seed: generator.next())
            case 2: bytes += [UInt8](repeating: UInt8(truncatingIfNeeded: generator.next()), count: size)
            default: bytes += periodic(size, period: Int(generator.next() % 16) + 1, seed: generator.next())
            }
        }
        return Array(bytes.prefix(count))
    }
}
