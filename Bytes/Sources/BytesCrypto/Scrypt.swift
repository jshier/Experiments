public import Bytes
internal import Dispatch
#if canImport(Darwin)
internal import Darwin
#endif

/// scrypt (RFC 7914): a key from a password, made expensive in memory as well as time. PBKDF2-HMAC-SHA256 spreads
/// the password and salt over `p` blocks of `128 × r` bytes, ROMix runs each through `N` steps of BlockMix (Salsa20/8)
/// that fill and then read back, in an order that depends on the data, a table of `N` of them, and PBKDF2 condenses the
/// result into the key.
///
/// ```swift
/// var key = [UInt8](repeating: 0, count: 32)
/// var span = key.mutableSpan
/// var bytes = MutableRawSpan(mutating: &span)
/// try Scrypt.deriveKey(password: password, salt: salt, cost: 1 << 14, blockSize: 8, parallelism: 1, into: &bytes)
/// ```
///
/// ROMix's table is `N × 128 × r` bytes (16 MiB for N = 2¹⁴, r = 8; 1 GiB for N = 2²⁰). Callers that derive keys
/// repeatedly pass that memory in (``deriveKey(password:salt:cost:blockSize:parallelism:lanes:scratch:into:)``, sized
/// by ``scratchByteCount(cost:blockSize:parallelism:lanes:)``) and nothing allocates; the other form allocates exactly
/// that one buffer per call.
///
/// Salsa20/8 is scalar: one block's rounds are a single dependent chain (each block of BlockMix starts from the
/// previous one's output), and 16 words in general-purpose registers run four quarter rounds side by side, two
/// instructions per step (an add and an `eor` with a rotated operand). The vector form with one `SIMD4<UInt32>` per
/// diagonal ran each step as four dependent vector instructions plus lane rotations: measured slower, see
/// `Benchmarks/RESULTS-scrypt-x509.md`. The `p` independent blocks run on up to `lanes` threads, each with its own
/// table.
///
/// Not constant-time, by design: ROMix's second loop reads the table at an index taken from the block, which depends on
/// the password, so an attacker sharing the CPU's caches can learn about the password from the access pattern (as with
/// every scrypt implementation; Argon2id's first half avoids this). The scratch memory this function allocates is
/// cleared before it's freed; memory passed in is the caller's to clear.
public enum Scrypt {
    /// The bytes of scratch memory ``deriveKey(password:salt:cost:blockSize:parallelism:lanes:scratch:into:)`` needs:
    /// `p × 128 × r` for the PBKDF2 output, then per lane a table of `N × 128 × r` and two blocks of `128 × r`.
    ///
    /// - Parameters:
    ///   - n: The cost: ROMix's table holds `n` blocks. A power of two, at least 2.
    ///   - r: The block size, in units of 128 bytes.
    ///   - p: The parallelism: the number of independent ROMix runs.
    ///   - lanes: How many of those run at once (each needs its own table). Clamped to `1...p`.
    /// - Returns: The byte count.
    /// - Throws: ``BytesError/invalidValue`` for parameters RFC 7914 rejects (`n` not a power of two above 1, `r` or
    ///   `p` below 1, `r × p` of 2³⁰ or more, `n` of 2^(16r) or more) or memory that doesn't fit in an `Int`.
    public static func scratchByteCount(cost n: Int, blockSize r: Int, parallelism p: Int, lanes: Int = 1) throws(BytesError) -> Int {
        try validate(n: n, r: r, p: p)
        let lanes = max(1, min(lanes, p))
        let block = 128 &* r // Can't overflow: r < 2^30, checked.
        let (perLaneBlocks, o1) = n.addingReportingOverflow(2)
        let (perLane, o2) = perLaneBlocks.multipliedReportingOverflow(by: block)
        let (tables, o3) = perLane.multipliedReportingOverflow(by: lanes)
        let (total, o4) = tables.addingReportingOverflow(p &* block) // p × r < 2^30, so p × 128 × r < 2^37.
        guard !(o1 || o2 || o3 || o4) else { throw .invalidValue }
        return total
    }

    /// Checks RFC 7914's limits on the parameters.
    static func validate(n: Int, r: Int, p: Int) throws(BytesError) {
        guard n >= 2, n & (n &- 1) == 0, r >= 1, p >= 1, r < 1 << 30, p < 1 << 30, r &* p < 1 << 30 else { throw .invalidValue }
        // N < 2^(128 × r / 8): only a limit below r = 4.
        if r < 4 { guard n.trailingZeroBitCount < 16 &* r else { throw .invalidValue } }
    }

    /// Derives `key.byteCount` bytes from `password` and `salt`, in caller-provided scratch memory. Allocates nothing
    /// (with `lanes` above 1, Dispatch's threads may).
    ///
    /// - Parameters:
    ///   - password: The password's bytes (UTF-8, by convention).
    ///   - salt: The salt.
    ///   - n: The cost `N`: a power of two, at least 2.
    ///   - r: The block size `r`, at least 1.
    ///   - p: The parallelism `p`, at least 1.
    ///   - lanes: How many of the `p` ROMix runs to run at once, on separate threads (clamped to `1...p`). The scratch
    ///     memory grows by a table per lane.
    ///   - scratch: At least ``scratchByteCount(cost:blockSize:parallelism:lanes:)`` bytes, overwritten. Its contents
    ///     afterwards depend on the password: clear it if that matters.
    ///   - key: Where the derived key goes; its length is the key's (at most (2³² − 1) × 32 bytes).
    /// - Throws: ``BytesError/invalidValue`` for invalid parameters (see
    ///   ``scratchByteCount(cost:blockSize:parallelism:lanes:)``); ``BytesError/insufficientCapacity`` if `scratch` is
    ///   too small.
    public static func deriveKey(
        password: RawSpan, salt: RawSpan, cost n: Int, blockSize r: Int, parallelism p: Int, lanes: Int = 1,
        scratch: inout MutableRawSpan, into key: inout MutableRawSpan
    ) throws(BytesError) {
        let needed = try scratchByteCount(cost: n, blockSize: r, parallelism: p, lanes: lanes)
        guard scratch.byteCount >= needed else { throw .insufficientCapacity }
        guard key.byteCount <= Int(UInt32.max) &* 32 else { throw .invalidValue }
        let lanes = max(1, min(lanes, p))
        let block = 128 &* r
        let blocksByteCount = p &* block
        // B = PBKDF2-HMAC-SHA256(P, S, 1, p × 128 × r), at the start of the scratch memory.
        do {
            var blocks = scratch._mutatingExtracting(0..<blocksByteCount)
            PBKDF2.deriveKey(SHA256.self, password: password, salt: salt, iterations: 1, into: &blocks)
        }
        // Unsafe: the scratch memory lent to the lanes as a pointer. Safe: lane `l` reads and writes only block `i` of B
        // for `i ≡ l (mod lanes)` and its own table region (`(n + 2) × block` bytes from `blocksByteCount + l × (n + 2)
        // × block`), all within `needed` bytes (checked above), and the pointer doesn't outlive the closure:
        // `concurrentPerform` returns once every lane is done.
        unsafe scratch.withLentBytes { memory in
            let laneByteCount = (n &+ 2) &* block
            if lanes == 1 {
                let base = unsafe memory.buffer.baseAddress!
                for index in 0..<p {
                    unsafe romix(base + index &* block, table: base + blocksByteCount, n: n, r: r)
                }
            } else {
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    let base = unsafe memory.buffer.baseAddress!
                    var index = lane
                    while index < p {
                        unsafe romix(base + index &* block, table: base + (blocksByteCount &+ lane &* laneByteCount), n: n, r: r)
                        index &+= lanes
                    }
                }
            }
        }
        // DK = PBKDF2-HMAC-SHA256(P, B, 1, dkLen).
        PBKDF2.deriveKey(SHA256.self, password: password, salt: scratch.bytes.extracting(first: blocksByteCount), iterations: 1, into: &key)
    }

    /// Derives `key.byteCount` bytes from `password` and `salt`, allocating the scratch memory: one buffer of
    /// ``scratchByteCount(cost:blockSize:parallelism:lanes:)`` bytes, freed (after being cleared) before returning.
    ///
    /// - Parameters:
    ///   - password: The password's bytes (UTF-8, by convention).
    ///   - salt: The salt.
    ///   - n: The cost `N`: a power of two, at least 2.
    ///   - r: The block size `r`, at least 1.
    ///   - p: The parallelism `p`, at least 1.
    ///   - lanes: How many of the `p` ROMix runs to run at once, on separate threads (clamped to `1...p`).
    ///   - key: Where the derived key goes; its length is the key's.
    /// - Throws: ``BytesError/invalidValue`` for invalid parameters (see
    ///   ``scratchByteCount(cost:blockSize:parallelism:lanes:)``).
    public static func deriveKey(
        password: RawSpan, salt: RawSpan, cost n: Int, blockSize r: Int, parallelism p: Int, lanes: Int = 1,
        into key: inout MutableRawSpan
    ) throws(BytesError) {
        let count = try scratchByteCount(cost: n, blockSize: r, parallelism: p, lanes: lanes)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 64)
        // Unsafe: memory this function allocated, initialized as bytes before the span views it, cleared and freed at
        // the end; the span doesn't outlive this scope. The clearing before `deallocate` is a dead store the optimizer
        // may drop, so it goes through `memset_s`, which it may not (C11, K.3.7.4.1).
        defer {
            #if canImport(Darwin)
            _ = unsafe memset_s(buffer.baseAddress, count, 0, count)
            #else
            unsafe buffer.initializeMemory(as: UInt8.self, repeating: 0)
            #endif
            unsafe buffer.deallocate()
        }
        unsafe buffer.initializeMemory(as: UInt8.self, repeating: 0)
        var scratch = unsafe MutableRawSpan(_unsafeBytes: buffer)
        try deriveKey(password: password, salt: salt, cost: n, blockSize: r, parallelism: p, lanes: lanes, scratch: &scratch, into: &key)
    }

    /// ROMix (RFC 7914, 5) on one block of `128 × r` bytes in place, with `table` holding `(n + 2) × 128 × r` bytes:
    /// V's `n` blocks, then X and Y, which BlockMix alternates between.
    @unsafe @inline(never)
    static func romix(_ block: UnsafeMutableRawPointer, table: UnsafeMutableRawPointer, n: Int, r: Int) {
        let size = 128 &* r
        let x = unsafe table + n &* size
        let y = unsafe x + size
        // V[0] = B; V[i + 1] = BlockMix(V[i]); X = BlockMix(V[N − 1]).
        unsafe table.copyMemory(from: block, byteCount: size)
        for index in 0..<(n &- 1) {
            unsafe blockMix(table + index &* size, nil, into: table + (index &+ 1) &* size, r: r)
        }
        unsafe blockMix(table + (n &- 1) &* size, nil, into: x, r: r)
        // N times: j = Integerify(X) mod N; X = BlockMix(X ⊕ V[j]). N is even, so X ends where it started.
        let mask = UInt64(n &- 1)
        let last = 64 &* (2 &* r &- 1)
        var index = 0
        while index < n {
            var j = unsafe Int(truncatingIfNeeded: UInt64(littleEndian: (x + last).loadUnaligned(as: UInt64.self)) & mask)
            unsafe blockMix(x, table + j &* size, into: y, r: r)
            j = unsafe Int(truncatingIfNeeded: UInt64(littleEndian: (y + last).loadUnaligned(as: UInt64.self)) & mask)
            unsafe blockMix(y, table + j &* size, into: x, r: r)
            index &+= 2
        }
        unsafe block.copyMemory(from: x, byteCount: size)
    }

    /// BlockMix (RFC 7914, 4) of `input` (XORed with `other` first, when there is one) into `output`, which mustn't
    /// overlap either: `2 × r` Salsa20/8 blocks chained, even ones to the first half of the output, odd ones to the second.
    @unsafe @inline(__always)
    static func blockMix(_ input: UnsafeMutableRawPointer, _ other: UnsafeMutableRawPointer?, into output: UnsafeMutableRawPointer, r: Int) {
        let last = 64 &* (2 &* r &- 1)
        var state = unsafe SalsaState(input + last)
        if let other = unsafe other { unsafe state.xor(other + last) }
        for index in 0..<(2 &* r) {
            unsafe state.xor(input + 64 &* index)
            if let other = unsafe other { unsafe state.xor(other + 64 &* index) }
            state.salsa20_8()
            let destination = (index &>> 1) &+ (index & 1) &* r
            unsafe state.store(output + 64 &* destination)
        }
    }
}

/// One Salsa20 block's 16 words, kept in locals so they live in registers.
struct SalsaState {
    var x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15: UInt32

    /// The 16 little-endian words at `pointer`.
    @unsafe @inline(__always)
    init(_ pointer: UnsafeRawPointer) {
        // In 64-bit pairs: as 16 consecutive 32-bit loads, LLVM's SLP vectorizer made the XORs before the rounds and
        // the additions after them vector operations, with each word moved between a general-purpose and a vector
        // register on the way (24 lane moves per block, on the chain from one block to the next): 5% slower.
        @inline(__always) func pair(_ index: Int) -> (UInt32, UInt32) {
            // Unsafe: an unchecked 8-byte load. Safe: callers pass a pointer to a whole 64-byte block (index below 8).
            let value = unsafe UInt64(littleEndian: pointer.loadUnaligned(fromByteOffset: 8 &* index, as: UInt64.self))
            return (UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value &>> 32))
        }
        (x0, x1) = pair(0); (x2, x3) = pair(1); (x4, x5) = pair(2); (x6, x7) = pair(3)
        (x8, x9) = pair(4); (x10, x11) = pair(5); (x12, x13) = pair(6); (x14, x15) = pair(7)
    }

    /// XORs in the 16 little-endian words at `pointer`.
    @unsafe @inline(__always)
    mutating func xor(_ pointer: UnsafeRawPointer) {
        // Unsafe: the 64 bytes at `pointer`, as `init(_:)` reads them; callers pass a whole block.
        let other = unsafe SalsaState(pointer)
        x0 ^= other.x0; x1 ^= other.x1; x2 ^= other.x2; x3 ^= other.x3
        x4 ^= other.x4; x5 ^= other.x5; x6 ^= other.x6; x7 ^= other.x7
        x8 ^= other.x8; x9 ^= other.x9; x10 ^= other.x10; x11 ^= other.x11
        x12 ^= other.x12; x13 ^= other.x13; x14 ^= other.x14; x15 ^= other.x15
    }

    /// Stores the words, little-endian, at `pointer`.
    @unsafe @inline(__always)
    func store(_ pointer: UnsafeMutableRawPointer) {
        @inline(__always) func put(_ low: UInt32, _ high: UInt32, _ index: Int) {
            let value = UInt64(low) | UInt64(high) &<< 32
            // Unsafe: an unchecked 8-byte store. Safe: callers pass room for a whole 64-byte block (index below 8).
            unsafe pointer.storeBytes(of: value.littleEndian, toByteOffset: 8 &* index, as: UInt64.self)
        }
        put(x0, x1, 0); put(x2, x3, 1); put(x4, x5, 2); put(x6, x7, 3)
        put(x8, x9, 4); put(x10, x11, 5); put(x12, x13, 6); put(x14, x15, 7)
    }

    @inline(__always)
    static func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { x &<< n | x &>> (32 &- n) }

    /// The Salsa20/8 core (RFC 7914, 3): four double rounds, then the input added back.
    @inline(__always)
    mutating func salsa20_8() {
        let input = self
        for _ in 0..<4 {
            // Columns.
            x4 ^= Self.rotate(x0 &+ x12, 7); x8 ^= Self.rotate(x4 &+ x0, 9)
            x12 ^= Self.rotate(x8 &+ x4, 13); x0 ^= Self.rotate(x12 &+ x8, 18)
            x9 ^= Self.rotate(x5 &+ x1, 7); x13 ^= Self.rotate(x9 &+ x5, 9)
            x1 ^= Self.rotate(x13 &+ x9, 13); x5 ^= Self.rotate(x1 &+ x13, 18)
            x14 ^= Self.rotate(x10 &+ x6, 7); x2 ^= Self.rotate(x14 &+ x10, 9)
            x6 ^= Self.rotate(x2 &+ x14, 13); x10 ^= Self.rotate(x6 &+ x2, 18)
            x3 ^= Self.rotate(x15 &+ x11, 7); x7 ^= Self.rotate(x3 &+ x15, 9)
            x11 ^= Self.rotate(x7 &+ x3, 13); x15 ^= Self.rotate(x11 &+ x7, 18)
            // Rows.
            x1 ^= Self.rotate(x0 &+ x3, 7); x2 ^= Self.rotate(x1 &+ x0, 9)
            x3 ^= Self.rotate(x2 &+ x1, 13); x0 ^= Self.rotate(x3 &+ x2, 18)
            x6 ^= Self.rotate(x5 &+ x4, 7); x7 ^= Self.rotate(x6 &+ x5, 9)
            x4 ^= Self.rotate(x7 &+ x6, 13); x5 ^= Self.rotate(x4 &+ x7, 18)
            x11 ^= Self.rotate(x10 &+ x9, 7); x8 ^= Self.rotate(x11 &+ x10, 9)
            x9 ^= Self.rotate(x8 &+ x11, 13); x10 ^= Self.rotate(x9 &+ x8, 18)
            x12 ^= Self.rotate(x15 &+ x14, 7); x13 ^= Self.rotate(x12 &+ x15, 9)
            x14 ^= Self.rotate(x13 &+ x12, 13); x15 ^= Self.rotate(x14 &+ x13, 18)
        }
        x0 &+= input.x0; x1 &+= input.x1; x2 &+= input.x2; x3 &+= input.x3
        x4 &+= input.x4; x5 &+= input.x5; x6 &+= input.x6; x7 &+= input.x7
        x8 &+= input.x8; x9 &+= input.x9; x10 &+= input.x10; x11 &+= input.x11
        x12 &+= input.x12; x13 &+= input.x13; x14 &+= input.x14; x15 &+= input.x15
    }
}
