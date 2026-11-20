internal import Bytes

/// The 64-bit xxHash (XXH64) of bytes, in one call or as they arrive: Zstandard's content checksum (the low
/// 32 bits of the hash with seed 0), and a fast non-cryptographic hash generally.
///
/// ```swift
/// let hash = XXHash64.hash(bytes.span.bytes)          // all at once
///
/// var hasher = XXHash64()                              // or in pieces
/// hasher.update(first)
/// hasher.update(second)
/// let same = hasher.digest
/// ```
///
/// Four 64-bit lanes take 32 bytes per round, with unchecked 8-byte loads inside spans whose length is
/// checked once per call.
@safe
public struct XXHash64: Sendable {
    static var prime1: UInt64 { 0x9E37_79B1_85EB_CA87 }
    static var prime2: UInt64 { 0xC2B2_AE3D_27D4_EB4F }
    static var prime3: UInt64 { 0x1656_67B1_9E37_79F9 }
    static var prime4: UInt64 { 0x85EB_CA77_C2B2_AE63 }
    static var prime5: UInt64 { 0x27D4_EB2F_1656_67C5 }

    /// The seed the hash started from.
    public let seed: UInt64
    private var lane1: UInt64
    private var lane2: UInt64
    private var lane3: UInt64
    private var lane4: UInt64
    /// Bytes hashed so far.
    private var length: UInt64 = 0
    /// Up to 31 bytes not yet in a round, in the order they came.
    private var buffer = InlineArray<4, UInt64>(repeating: 0)
    private var bufferedCount = 0

    /// Creates a hasher.
    ///
    /// - Parameter seed: The seed; Zstandard uses 0.
    public init(seed: UInt64 = 0) {
        self.seed = seed
        lane1 = seed &+ Self.prime1 &+ Self.prime2
        lane2 = seed &+ Self.prime2
        lane3 = seed
        lane4 = seed &- Self.prime1
    }

    /// The hash of `bytes`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to hash.
    ///   - seed: The seed; Zstandard uses 0.
    /// - Returns: The 64-bit hash.
    public static func hash(_ bytes: RawSpan, seed: UInt64 = 0) -> UInt64 {
        // One pass over the input, as libzstd's `XXH64()`: stripes straight from `bytes`, then the tail from its
        // end. (Through the streaming hasher, its buffer and lane fields cost a 64-byte message 230 instructions
        // against libzstd's 130.)
        let count = bytes.byteCount
        var index = 0
        var hash: UInt64
        if count >= 32 {
            var v1 = seed &+ prime1 &+ prime2
            var v2 = seed &+ prime2
            var v3 = seed
            var v4 = seed &- prime1
            let end = count &- 32
            repeat {
                // Unsafe: unchecked loads. Safe: `index <= count - 32`, so all 32 bytes are within `bytes`.
                v1 = round(v1, UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index, as: UInt64.self)))
                v2 = round(v2, UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index &+ 8, as: UInt64.self)))
                v3 = round(v3, UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index &+ 16, as: UInt64.self)))
                v4 = round(v4, UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index &+ 24, as: UInt64.self)))
                index &+= 32
            } while index <= end
            hash = converge(v1, v2, v3, v4)
        } else {
            hash = seed &+ prime5
        }
        return finish(hash &+ UInt64(truncatingIfNeeded: count), bytes, from: index)
    }

    /// The four lanes merged into one hash, once 32 bytes or more were hashed.
    @inline(__always)
    static func converge(_ v1: UInt64, _ v2: UInt64, _ v3: UInt64, _ v4: UInt64) -> UInt64 {
        var hash = v1.rotatedLeft(by: 1) &+ v2.rotatedLeft(by: 7) &+ v3.rotatedLeft(by: 12) &+ v4.rotatedLeft(by: 18)
        hash = merge(hash, v1)
        hash = merge(hash, v2)
        hash = merge(hash, v3)
        return merge(hash, v4)
    }

    /// The hash finished with `bytes[start...]` (fewer than 32 bytes) and avalanched.
    @inline(__always)
    static func finish(_ hash: UInt64, _ bytes: RawSpan, from start: Int) -> UInt64 {
        var hash = hash
        let count = bytes.byteCount
        var index = start
        // Unsafe: unchecked loads. Safe: each loop's condition keeps its load's bytes below `count`.
        while count &- index >= 8 {
            hash ^= round(0, UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index, as: UInt64.self)))
            hash = hash.rotatedLeft(by: 27) &* prime1 &+ prime4
            index &+= 8
        }
        if count &- index >= 4 {
            hash ^= UInt64(UInt32(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index, as: UInt32.self))) &* prime1
            hash = hash.rotatedLeft(by: 23) &* prime2 &+ prime3
            index &+= 4
        }
        while index < count {
            hash ^= UInt64(unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index, as: UInt8.self)) &* prime5
            hash = hash.rotatedLeft(by: 11) &* prime1
            index &+= 1
        }
        hash ^= hash &>> 33
        hash &*= prime2
        hash ^= hash &>> 29
        hash &*= prime3
        hash ^= hash &>> 32
        return hash
    }

    @inline(__always)
    static func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
        (accumulator &+ input &* prime2).rotatedLeft(by: 31) &* prime1
    }

    @inline(__always)
    static func merge(_ accumulator: UInt64, _ lane: UInt64) -> UInt64 {
        (accumulator ^ round(0, lane)) &* prime1 &+ prime4
    }

    /// Adds `bytes` to the hash.
    ///
    /// - Parameter bytes: The next bytes.
    public mutating func update(_ bytes: RawSpan) {
        let count = bytes.byteCount
        length &+= UInt64(truncatingIfNeeded: count)
        var index = 0
        if bufferedCount > 0 {
            // Top up the partial round, a byte at a time (at most 31 bytes).
            var stash = buffer.mutableSpan
            var raw = MutableRawSpan(mutating: &stash)
            while bufferedCount < 32, index < count {
                raw.storeBytes(of: bytes.load(fromByteOffset: index, as: UInt8.self), toByteOffset: bufferedCount, as: UInt8.self)
                bufferedCount &+= 1
                index &+= 1
            }
            guard bufferedCount == 32 else { return }
            lane1 = Self.round(lane1, UInt64(littleEndian: buffer[0]))
            lane2 = Self.round(lane2, UInt64(littleEndian: buffer[1]))
            lane3 = Self.round(lane3, UInt64(littleEndian: buffer[2]))
            lane4 = Self.round(lane4, UInt64(littleEndian: buffer[3]))
            bufferedCount = 0
        }
        if count &- index >= 32 {
            var (v1, v2, v3, v4) = (lane1, lane2, lane3, lane4)
            let end = count &- 32
            repeat {
                // Unsafe: unchecked loads. Safe: `index <= count - 32`, so all 32 bytes are within `bytes`.
                v1 = Self.round(v1, UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index, as: UInt64.self)))
                v2 = Self.round(v2, UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index &+ 8, as: UInt64.self)))
                v3 = Self.round(v3, UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index &+ 16, as: UInt64.self)))
                v4 = Self.round(v4, UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: index &+ 24, as: UInt64.self)))
                index &+= 32
            } while index <= end
            (lane1, lane2, lane3, lane4) = (v1, v2, v3, v4)
        }
        if index < count {
            var stash = buffer.mutableSpan
            var raw = MutableRawSpan(mutating: &stash)
            raw.copyBytes(from: bytes.extracting(index..<count), toByteOffset: 0)
            bufferedCount = count &- index
        }
    }

    /// Adds the `count` bytes at `start` to the hash.
    mutating func update(_ start: UnsafeRawPointer, count: Int) {
        guard count > 0 else { return }
        // Unsafe: a span over the caller's bytes, used only during the call.
        update(unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: start, count: count)))
    }

    /// The hash of everything added so far. Adding more afterwards continues the same hash.
    public var digest: UInt64 {
        let hash = length >= 32 ? Self.converge(lane1, lane2, lane3, lane4) : seed &+ Self.prime5
        return Self.finish(hash &+ length, buffer.span.bytes.extracting(0..<bufferedCount), from: 0)
    }
}

fileprivate extension UInt64 {
    @inline(__always)
    func rotatedLeft(by count: UInt64) -> UInt64 {
        (self &<< count) | (self &>> (64 &- count))
    }
}
