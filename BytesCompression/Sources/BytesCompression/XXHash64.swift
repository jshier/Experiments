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
package struct XXHash64: Sendable {
    static var prime1: UInt64 { 0x9E37_79B1_85EB_CA87 }
    static var prime2: UInt64 { 0xC2B2_AE3D_27D4_EB4F }
    static var prime3: UInt64 { 0x1656_67B1_9E37_79F9 }
    static var prime4: UInt64 { 0x85EB_CA77_C2B2_AE63 }
    static var prime5: UInt64 { 0x27D4_EB2F_1656_67C5 }

    /// The seed the hash started from.
    package let seed: UInt64
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
    package init(seed: UInt64 = 0) {
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
    package static func hash(_ bytes: RawSpan, seed: UInt64 = 0) -> UInt64 {
        // One pass over the input, as libzstd's `XXH64()`: stripes straight from `bytes`, then the tail from its
        // end. (Through the streaming hasher, its buffer and lane fields cost a 64-byte message 230 instructions
        // against libzstd's 130.)
        let count = bytes.byteCount
        var hash: UInt64
        if count >= 32 {
            var lanes = (seed &+ prime1 &+ prime2, seed &+ prime2, seed, seed &- prime1)
            rounds(&lanes, stripes(bytes))
            hash = converge(lanes.0, lanes.1, lanes.2, lanes.3)
        } else {
            hash = seed &+ prime5
        }
        return finish(hash &+ UInt64(truncatingIfNeeded: count), bytes.extracting(droppingFirst: count & ~31))
    }

    /// The whole 32-byte stripes at the start of `bytes`, as elements: four words each, read by `bitCast` to
    /// `SIMD4<UInt64>` where they're used. (Through a helper taking the element, the stripe was loaded into vector
    /// registers and its lanes moved out: 3 more instructions a stripe.)
    @inline(__always)
    @_lifetime(copy bytes)
    static func stripes(_ bytes: RawSpan) -> Span<InlineArray<32, UInt8>> {
        bytes.chunks(of: InlineArray<32, UInt8>.self)
    }

    /// The four lanes' rounds over `stripes`.
    @inline(__always)
    static func rounds(_ lanes: inout (UInt64, UInt64, UInt64, UInt64), _ stripes: Span<InlineArray<32, UInt8>>) {
        var (v1, v2, v3, v4) = lanes
        for index in stripes.indices {
            let words = bitCast(stripes[index], to: SIMD4<UInt64>.self)
            v1 = round(v1, UInt64(littleEndian: words[0]))
            v2 = round(v2, UInt64(littleEndian: words[1]))
            v3 = round(v3, UInt64(littleEndian: words[2]))
            v4 = round(v4, UInt64(littleEndian: words[3]))
        }
        lanes = (v1, v2, v3, v4)
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

    /// The hash finished with `bytes` (fewer than 32) and avalanched.
    @inline(__always)
    static func finish(_ hash: UInt64, _ bytes: RawSpan) -> UInt64 {
        // Words and bytes as elements, as the stripes are.
        var hash = hash
        let count = bytes.byteCount
        let words = bytes.chunks(of: InlineArray<8, UInt8>.self)
        for index in words.indices {
            hash ^= round(0, UInt64(littleEndianBytes: words[index]))
            hash = hash.rotatedLeft(by: 27) &* prime1 &+ prime4
        }
        var rest = bytes.extracting(droppingFirst: count & ~7)
        if rest.byteCount >= 4 {
            hash ^= UInt64(UInt32(littleEndian: rest.load(fromByteOffset: 0, as: UInt32.self))) &* prime1
            hash = hash.rotatedLeft(by: 23) &* prime2 &+ prime3
            rest = rest.extracting(droppingFirst: 4)
        }
        let tail = Span<UInt8>(viewing: rest)
        for index in tail.indices {
            hash ^= UInt64(tail[index]) &* prime5
            hash = hash.rotatedLeft(by: 11) &* prime1
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
    package mutating func update(_ bytes: RawSpan) {
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
        var rest = bytes.extracting(droppingFirst: index)
        if rest.byteCount >= 32 {
            var lanes = (lane1, lane2, lane3, lane4)
            Self.rounds(&lanes, Self.stripes(rest))
            (lane1, lane2, lane3, lane4) = lanes
            rest = rest.extracting(droppingFirst: rest.byteCount & ~31)
        }
        if rest.byteCount > 0 {
            var stash = buffer.mutableSpan
            var raw = MutableRawSpan(mutating: &stash)
            raw.copyBytes(from: rest, toByteOffset: 0)
            bufferedCount = rest.byteCount
        }
    }

    /// Adds the `count` bytes at `start` to the hash.
    mutating func update(_ start: UnsafeRawPointer, count: Int) {
        guard count > 0 else { return }
        // Unsafe: a span over the caller's bytes, used only during the call.
        update(unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: start, count: count)))
    }

    /// Copies the `count` bytes at `source` to `destination` and adds them to the hash, in one pass: a raw block's
    /// bytes read once (copied, then read back for the hash, they cost a second pass: random input decoded no faster
    /// than libzstd's).
    @unsafe
    package mutating func copyAndUpdate(from source: UnsafeRawPointer, to destination: UnsafeMutableRawPointer, count: Int) {
        // Unsafe: reads below `count` at `source`, writes below `count` at `destination` (the caller's bounds).
        var done = 0
        if bufferedCount > 0 {
            // The head that completes the partial round.
            done = min(32 &- bufferedCount, count)
            unsafe destination.copyMemory(from: source, byteCount: done)
            unsafe update(source, count: done)
        }
        let stripes = (count &- done) & ~31
        if stripes > 0 {
            var v1 = lane1, v2 = lane2, v3 = lane3, v4 = lane4
            var offset = done
            let end = done &+ stripes
            while offset < end {
                let words = unsafe (source + offset).loadUnaligned(as: SIMD4<UInt64>.self)
                unsafe (destination + offset).storeBytes(of: words, as: SIMD4<UInt64>.self)
                v1 = Self.round(v1, UInt64(littleEndian: words[0]))
                v2 = Self.round(v2, UInt64(littleEndian: words[1]))
                v3 = Self.round(v3, UInt64(littleEndian: words[2]))
                v4 = Self.round(v4, UInt64(littleEndian: words[3]))
                offset &+= 32
            }
            lane1 = v1
            lane2 = v2
            lane3 = v3
            lane4 = v4
            length &+= UInt64(truncatingIfNeeded: stripes)
        }
        let rest = count &- done &- stripes
        if rest > 0 {
            let start = done &+ stripes
            unsafe (destination + start).copyMemory(from: source + start, byteCount: rest)
            unsafe update(source + start, count: rest)
        }
    }

    /// The hash of everything added so far. Adding more afterwards continues the same hash.
    package var digest: UInt64 {
        let hash = length >= 32 ? Self.converge(lane1, lane2, lane3, lane4) : seed &+ Self.prime5
        return Self.finish(hash &+ length, buffer.span.bytes.extracting(0..<bufferedCount))
    }
}

private extension UInt64 {
    @inline(__always)
    func rotatedLeft(by count: UInt64) -> UInt64 {
        (self &<< count) | (self &>> (64 &- count))
    }
}
