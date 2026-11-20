public import Bytes
#if HardwareCrypto && arch(arm64) && !Portable
internal import CBytesCrypto
#endif

// SHA-1, SHA-256, and SHA-512/384 (FIPS 180-4): streaming, allocation-free, one block function per hash with two
// implementations. On Apple silicon (the `HardwareCrypto` trait, the default) the block functions use ARM's
// SHA instructions through `CBytesCrypto` (four rounds per instruction for SHA-1 and SHA-256, two for SHA-512);
// elsewhere, and in `Portable` builds, plain Swift. Both are constant-time: no table is indexed by data.

/// A cryptographic hash function: SHA-1, SHA-256, SHA-384, SHA-512. Generic code (``HMAC``, ``PBKDF2``) works
/// with any of them.
///
/// ```swift
/// var hash = SHA256()
/// hash.update(header)
/// hash.update(body)
/// let digest = hash.finalize()          // InlineArray<32, UInt8>
/// ```
public protocol HashFunction: Sendable {
    /// The size of the blocks the function compresses, in bytes: 64 for SHA-1 and SHA-256, 128 for SHA-384
    /// and SHA-512. HMAC pads its key to this size.
    static var blockByteCount: Int { get }
    /// The size of the digest in bytes.
    static var digestByteCount: Int { get }

    /// A hash of nothing yet.
    init()

    /// Adds `bytes` to the message.
    ///
    /// - Parameter bytes: The next bytes of the message.
    mutating func update(_ bytes: RawSpan)

    /// Finishes the message and writes its digest to the start of `digest`.
    ///
    /// The hash is spent afterwards: start a new one (or copy one made before finishing) for another message.
    ///
    /// - Parameter digest: Room for at least ``digestByteCount`` bytes.
    mutating func finalize(into digest: inout MutableRawSpan)
}

/// Whether `a` and `b` hold the same bytes, taking the same time for any contents of equal length: for
/// comparing authentication tags and password verifiers, where an early exit would reveal how many leading
/// bytes an attacker guessed.
///
/// - Parameters:
///   - a: The first bytes.
///   - b: The second bytes.
/// - Returns: `true` if both have the same length and bytes.
@inlinable
public func constantTimeEquals(_ a: RawSpan, _ b: RawSpan) -> Bool {
    guard a.byteCount == b.byteCount else { return false }
    var difference: UInt8 = 0
    for offset in 0..<a.byteCount {
        difference |= a.load(fromByteOffset: offset, as: UInt8.self) ^ b.load(fromByteOffset: offset, as: UInt8.self)
    }
    return difference == 0
}

// MARK: - Shared message buffering

/// The part of a Merkle–Damgård hash every variant shares: a partial block, and the message length.
@usableFromInline
struct HashBuffer<let size: Int>: Sendable {
    @usableFromInline var block = InlineArray<size, UInt8>(repeating: 0)
    @usableFromInline var count = 0
    @usableFromInline var length: UInt64 = 0

    @inlinable init() {}

    /// Feeds `bytes` through: completes the partial block first, then whole blocks straight from `bytes`
    /// (no copy), then keeps the rest.
    @inlinable
    mutating func absorb(_ bytes: RawSpan, _ compress: (RawSpan) -> Void) {
        length &+= UInt64(bytes.byteCount)
        var rest = bytes
        if count > 0 {
            let take = min(size &- count, rest.byteCount)
            var span = block.mutableSpan
            span.copyBytes(from: rest.extracting(first: take), toByteOffset: count)
            count &+= take
            rest = rest.extracting(droppingFirst: take)
            guard count == size else { return }
            compress(block.span.bytes)
            count = 0
        }
        let whole = rest.byteCount / size * size
        if whole > 0 { compress(rest.extracting(first: whole)) }
        let tail = rest.byteCount &- whole
        if tail > 0 {
            var span = block.mutableSpan
            span.copyBytes(from: rest.extracting(droppingFirst: whole), toByteOffset: 0)
            count = tail
        }
    }

    /// Appends the padding: 0x80, zeros, and the message length in bits, big-endian, in the last
    /// `lengthByteCount` bytes (8 for SHA-1/SHA-256, 16 for SHA-384/512); compresses the last one or two blocks.
    @inlinable
    mutating func pad(lengthByteCount: Int, _ compress: (RawSpan) -> Void) {
        let bits = length &<< 3
        block[count] = 0x80
        count &+= 1
        if count > size &- lengthByteCount {
            for index in count..<size { block[index] = 0 }
            compress(block.span.bytes)
            count = 0
        }
        for index in count..<(size &- 8) { block[index] = 0 }
        for index in 0..<8 { block[size &- 1 &- index] = UInt8(truncatingIfNeeded: bits &>> UInt64(8 &* index)) }
        compress(block.span.bytes)
    }
}

/// Writes `words` big-endian to the start of `digest`, `count` of them.
@inlinable
func writeBigEndian<let n: Int>(_ words: InlineArray<n, UInt32>, count: Int, into digest: inout MutableRawSpan) {
    precondition(digest.byteCount >= 4 &* count, "The digest needs \(4 &* count) bytes")
    for index in 0..<count {
        digest.storeBytes(of: words[index].bigEndian, toByteOffset: 4 &* index, as: UInt32.self)
    }
}

// MARK: - SHA-1

/// SHA-1 (FIPS 180-4). Broken for collision resistance, but still what HMAC-SHA1 and PBKDF2-HMAC-SHA1 use where
/// formats require them (WinZip AES, TOTP); HMAC doesn't depend on collision resistance.
public struct SHA1: HashFunction {
    /// The state words H0…H4.
    @usableFromInline var state: InlineArray<5, UInt32> = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
    @usableFromInline var buffer = HashBuffer<64>()

    /// 64.
    @inlinable public static var blockByteCount: Int { 64 }
    /// 20.
    @inlinable public static var digestByteCount: Int { 20 }

    /// A hash of nothing yet.
    @inlinable public init() {}

    /// Adds `bytes` to the message.
    ///
    /// - Parameter bytes: The next bytes of the message.
    @inlinable
    public mutating func update(_ bytes: RawSpan) {
        var state = state
        buffer.absorb(bytes) { SHA1.compress(&state, blocks: $0) }
        self.state = state
    }

    /// Finishes the message and writes its 20-byte digest to the start of `digest`.
    ///
    /// - Parameter digest: Room for at least 20 bytes.
    @inlinable
    public mutating func finalize(into digest: inout MutableRawSpan) {
        var state = state
        buffer.pad(lengthByteCount: 8) { SHA1.compress(&state, blocks: $0) }
        writeBigEndian(state, count: 5, into: &digest)
    }

    /// Finishes the message and returns its digest.
    ///
    /// - Returns: The 20-byte digest.
    @inlinable
    public mutating func finalize() -> InlineArray<20, UInt8> {
        var digest = InlineArray<20, UInt8>(repeating: 0)
        var span = digest.mutableSpan
        var bytes = MutableRawSpan(mutating: &span)
        finalize(into: &bytes)
        return digest
    }

    /// The digest of `bytes`.
    ///
    /// - Parameter bytes: The whole message.
    /// - Returns: The 20-byte digest.
    @inlinable
    public static func hash(_ bytes: RawSpan) -> InlineArray<20, UInt8> {
        var hash = SHA1()
        hash.update(bytes)
        return hash.finalize()
    }

    /// Compresses whole 64-byte blocks into `state`.
    @usableFromInline
    static func compress(_ state: inout InlineArray<5, UInt32>, blocks: RawSpan) {
        #if HardwareCrypto && arch(arm64) && !Portable
        compressWithInstructions(&state, blocks: blocks)
        #else
        compressPortably(&state, blocks: blocks)
        #endif
    }

    #if HardwareCrypto && arch(arm64) && !Portable
    /// Four rounds per instruction: `sha1c`/`sha1p`/`sha1m` take ABCD, E, and four schedule words plus the
    /// round constant; `sha1su0`/`sha1su1` extend the schedule four words at a time.
    @inline(never)
    static func compressWithInstructions(_ state: inout InlineArray<5, UInt32>, blocks: RawSpan) {
        var abcd = SIMD4(state[0], state[1], state[2], state[3])
        var e = state[4]
        let k0 = SIMD4<UInt32>(repeating: 0x5A82_7999), k1 = SIMD4<UInt32>(repeating: 0x6ED9_EBA1)
        let k2 = SIMD4<UInt32>(repeating: 0x8F1B_BCDC), k3 = SIMD4<UInt32>(repeating: 0xCA62_C1D6)
        var offset = 0
        while offset < blocks.byteCount {
            let (savedABCD, savedE) = (abcd, e)
            // The block's sixteen big-endian words, as four vectors.
            var w0 = bytes_rev32(blocks.load(fromByteOffset: offset, as: SIMD16<UInt8>.self))
            var w1 = bytes_rev32(blocks.load(fromByteOffset: offset &+ 16, as: SIMD16<UInt8>.self))
            var w2 = bytes_rev32(blocks.load(fromByteOffset: offset &+ 32, as: SIMD16<UInt8>.self))
            var w3 = bytes_rev32(blocks.load(fromByteOffset: offset &+ 48, as: SIMD16<UInt8>.self))
            // 20 groups of four rounds; the function changes every 5. Written out: the compiler then keeps every
            // vector in a register and the constants hoisted.
            @inline(__always) func group(_ function: Int, _ k: SIMD4<UInt32>, _ w: SIMD4<UInt32>) {
                let next = bytes_sha1h(abcd[0])
                switch function {
                case 0: abcd = bytes_sha1c(abcd, e, w &+ k)
                case 1: abcd = bytes_sha1p(abcd, e, w &+ k)
                default: abcd = bytes_sha1m(abcd, e, w &+ k)
                }
                e = next
            }
            @inline(__always) func schedule() {
                let next = bytes_sha1su1(bytes_sha1su0(w0, w1, w2), w3)
                (w0, w1, w2, w3) = (w1, w2, w3, next)
            }
            group(0, k0, w0); schedule(); group(0, k0, w0); schedule(); group(0, k0, w0); schedule()
            group(0, k0, w0); schedule(); group(0, k0, w0); schedule()
            group(1, k1, w0); schedule(); group(1, k1, w0); schedule(); group(1, k1, w0); schedule()
            group(1, k1, w0); schedule(); group(1, k1, w0); schedule()
            group(2, k2, w0); schedule(); group(2, k2, w0); schedule(); group(2, k2, w0); schedule()
            group(2, k2, w0); schedule(); group(2, k2, w0); schedule()
            group(1, k3, w0); schedule(); group(1, k3, w0); schedule(); group(1, k3, w0); schedule()
            group(1, k3, w0); schedule(); group(1, k3, w0)
            abcd &+= savedABCD
            e &+= savedE
            offset &+= 64
        }
        (state[0], state[1], state[2], state[3], state[4]) = (abcd[0], abcd[1], abcd[2], abcd[3], e)
    }
    #endif

    /// The portable block function: eighty rounds on a sixteen-word circular schedule.
    @inline(never)
    static func compressPortably(_ state: inout InlineArray<5, UInt32>, blocks: RawSpan) {
        var (h0, h1, h2, h3, h4) = (state[0], state[1], state[2], state[3], state[4])
        var w = InlineArray<16, UInt32>(repeating: 0)
        var offset = 0
        while offset < blocks.byteCount {
            for index in 0..<16 {
                w[index] = UInt32(bigEndian: blocks.load(fromByteOffset: offset &+ 4 &* index, as: UInt32.self))
            }
            var (a, b, c, d, e) = (h0, h1, h2, h3, h4)
            for round in 0..<80 {
                let index = round & 15
                if round >= 16 {
                    let mixed = w[(round &- 3) & 15] ^ w[(round &- 8) & 15] ^ w[(round &- 14) & 15] ^ w[index]
                    w[index] = mixed.rotatedLeft(by: 1)
                }
                let (f, k): (UInt32, UInt32) = switch round {
                case 0..<20: ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (b ^ c ^ d, 0xCA62_C1D6)
                }
                let temp = a.rotatedLeft(by: 5) &+ f &+ e &+ k &+ w[index]
                (e, d, c, b, a) = (d, c, b.rotatedLeft(by: 30), a, temp)
            }
            h0 &+= a; h1 &+= b; h2 &+= c; h3 &+= d; h4 &+= e
            offset &+= 64
        }
        (state[0], state[1], state[2], state[3], state[4]) = (h0, h1, h2, h3, h4)
    }
}

// MARK: - SHA-256

/// SHA-256 (FIPS 180-4): TLS 1.3's hash for its `…_SHA256` suites, and HKDF's.
public struct SHA256: HashFunction {
    /// The state words H0…H7.
    @usableFromInline var state: InlineArray<8, UInt32> = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    @usableFromInline var buffer = HashBuffer<64>()

    /// 64.
    @inlinable public static var blockByteCount: Int { 64 }
    /// 32.
    @inlinable public static var digestByteCount: Int { 32 }

    /// A hash of nothing yet.
    @inlinable public init() {}

    /// Adds `bytes` to the message.
    ///
    /// - Parameter bytes: The next bytes of the message.
    @inlinable
    public mutating func update(_ bytes: RawSpan) {
        var state = state
        buffer.absorb(bytes) { SHA256.compress(&state, blocks: $0) }
        self.state = state
    }

    /// Finishes the message and writes its 32-byte digest to the start of `digest`.
    ///
    /// - Parameter digest: Room for at least 32 bytes.
    @inlinable
    public mutating func finalize(into digest: inout MutableRawSpan) {
        var state = state
        buffer.pad(lengthByteCount: 8) { SHA256.compress(&state, blocks: $0) }
        writeBigEndian(state, count: 8, into: &digest)
    }

    /// Finishes the message and returns its digest.
    ///
    /// - Returns: The 32-byte digest.
    @inlinable
    public mutating func finalize() -> InlineArray<32, UInt8> {
        var digest = InlineArray<32, UInt8>(repeating: 0)
        var span = digest.mutableSpan
        var bytes = MutableRawSpan(mutating: &span)
        finalize(into: &bytes)
        return digest
    }

    /// The digest of `bytes`.
    ///
    /// - Parameter bytes: The whole message.
    /// - Returns: The 32-byte digest.
    @inlinable
    public static func hash(_ bytes: RawSpan) -> InlineArray<32, UInt8> {
        var hash = SHA256()
        hash.update(bytes)
        return hash.finalize()
    }

    /// The round constants: the first 32 bits of the fractional parts of the first 64 primes' cube roots.
    static let roundConstants: InlineArray<64, UInt32> = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    /// Compresses whole 64-byte blocks into `state`.
    @usableFromInline
    static func compress(_ state: inout InlineArray<8, UInt32>, blocks: RawSpan) {
        #if HardwareCrypto && arch(arm64) && !Portable
        compressWithInstructions(&state, blocks: blocks)
        #else
        compressPortably(&state, blocks: blocks)
        #endif
    }

    #if HardwareCrypto && arch(arm64) && !Portable
    /// Four rounds per `sha256h`/`sha256h2` pair; `sha256su0`/`sha256su1` extend the schedule four words at a time.
    @inline(never)
    static func compressWithInstructions(_ state: inout InlineArray<8, UInt32>, blocks: RawSpan) {
        var abcd = SIMD4(state[0], state[1], state[2], state[3])
        var efgh = SIMD4(state[4], state[5], state[6], state[7])
        // The round constants as sixteen vectors, loaded once: in a loop over the groups, building each from the
        // table and the schedule's conditional kept the loop rolled (2.8x CryptoKit's instructions).
        let k = roundConstants
        @inline(__always) func constants(_ group: Int) -> SIMD4<UInt32> {
            SIMD4(k[4 &* group], k[4 &* group &+ 1], k[4 &* group &+ 2], k[4 &* group &+ 3])
        }
        let c0 = constants(0), c1 = constants(1), c2 = constants(2), c3 = constants(3)
        let c4 = constants(4), c5 = constants(5), c6 = constants(6), c7 = constants(7)
        let c8 = constants(8), c9 = constants(9), c10 = constants(10), c11 = constants(11)
        let c12 = constants(12), c13 = constants(13), c14 = constants(14), c15 = constants(15)
        var offset = 0
        while offset < blocks.byteCount {
            let (savedABCD, savedEFGH) = (abcd, efgh)
            var w0 = bytes_rev32(blocks.load(fromByteOffset: offset, as: SIMD16<UInt8>.self))
            var w1 = bytes_rev32(blocks.load(fromByteOffset: offset &+ 16, as: SIMD16<UInt8>.self))
            var w2 = bytes_rev32(blocks.load(fromByteOffset: offset &+ 32, as: SIMD16<UInt8>.self))
            var w3 = bytes_rev32(blocks.load(fromByteOffset: offset &+ 48, as: SIMD16<UInt8>.self))
            // Four rounds with the next schedule words `w`, then (while the schedule continues) the next four words.
            @inline(__always) func quad(_ w: SIMD4<UInt32>, _ c: SIMD4<UInt32>) {
                let wk = w &+ c
                let previous = abcd
                abcd = bytes_sha256h(abcd, efgh, wk)
                efgh = bytes_sha256h2(efgh, previous, wk)
            }
            quad(w0, c0); w0 = bytes_sha256su1(bytes_sha256su0(w0, w1), w2, w3)
            quad(w1, c1); w1 = bytes_sha256su1(bytes_sha256su0(w1, w2), w3, w0)
            quad(w2, c2); w2 = bytes_sha256su1(bytes_sha256su0(w2, w3), w0, w1)
            quad(w3, c3); w3 = bytes_sha256su1(bytes_sha256su0(w3, w0), w1, w2)
            quad(w0, c4); w0 = bytes_sha256su1(bytes_sha256su0(w0, w1), w2, w3)
            quad(w1, c5); w1 = bytes_sha256su1(bytes_sha256su0(w1, w2), w3, w0)
            quad(w2, c6); w2 = bytes_sha256su1(bytes_sha256su0(w2, w3), w0, w1)
            quad(w3, c7); w3 = bytes_sha256su1(bytes_sha256su0(w3, w0), w1, w2)
            quad(w0, c8); w0 = bytes_sha256su1(bytes_sha256su0(w0, w1), w2, w3)
            quad(w1, c9); w1 = bytes_sha256su1(bytes_sha256su0(w1, w2), w3, w0)
            quad(w2, c10); w2 = bytes_sha256su1(bytes_sha256su0(w2, w3), w0, w1)
            quad(w3, c11); w3 = bytes_sha256su1(bytes_sha256su0(w3, w0), w1, w2)
            quad(w0, c12)
            quad(w1, c13)
            quad(w2, c14)
            quad(w3, c15)
            abcd &+= savedABCD
            efgh &+= savedEFGH
            offset &+= 64
        }
        (state[0], state[1], state[2], state[3]) = (abcd[0], abcd[1], abcd[2], abcd[3])
        (state[4], state[5], state[6], state[7]) = (efgh[0], efgh[1], efgh[2], efgh[3])
    }
    #endif

    /// The portable block function: 64 rounds on a sixteen-word circular schedule.
    @inline(never)
    static func compressPortably(_ state: inout InlineArray<8, UInt32>, blocks: RawSpan) {
        let k = roundConstants
        var w = InlineArray<16, UInt32>(repeating: 0)
        var offset = 0
        while offset < blocks.byteCount {
            for index in 0..<16 {
                w[index] = UInt32(bigEndian: blocks.load(fromByteOffset: offset &+ 4 &* index, as: UInt32.self))
            }
            var (a, b, c, d) = (state[0], state[1], state[2], state[3])
            var (e, f, g, h) = (state[4], state[5], state[6], state[7])
            for round in 0..<64 {
                let index = round & 15
                if round >= 16 {
                    let w15 = w[(round &- 15) & 15], w2 = w[(round &- 2) & 15]
                    let s0 = w15.rotatedRight(by: 7) ^ w15.rotatedRight(by: 18) ^ (w15 &>> 3)
                    let s1 = w2.rotatedRight(by: 17) ^ w2.rotatedRight(by: 19) ^ (w2 &>> 10)
                    w[index] = w[index] &+ s0 &+ w[(round &- 7) & 15] &+ s1
                }
                let sum1 = e.rotatedRight(by: 6) ^ e.rotatedRight(by: 11) ^ e.rotatedRight(by: 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ sum1 &+ choice &+ k[round] &+ w[index]
                let sum0 = a.rotatedRight(by: 2) ^ a.rotatedRight(by: 13) ^ a.rotatedRight(by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ majority
                (h, g, f, e, d, c, b, a) = (g, f, e, d &+ temp1, c, b, a, temp1 &+ temp2)
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
            offset &+= 64
        }
    }
}

// MARK: - SHA-512 and SHA-384

/// The 128-byte-block hashes, SHA-512 and SHA-384 (FIPS 180-4): one block function and buffer, with different
/// initial values and digest lengths. On Apple silicon the block function uses ARM's SHA-512 instructions, two rounds
/// per `sha512h`/`sha512h2` pair; elsewhere, plain Swift.
@usableFromInline
struct SHA512Core: Sendable {
    @usableFromInline var state: InlineArray<8, UInt64>
    @usableFromInline var buffer = HashBuffer<128>()

    @inlinable init(state: InlineArray<8, UInt64>) { self.state = state }

    @inlinable
    mutating func update(_ bytes: RawSpan) {
        var state = state
        buffer.absorb(bytes) { SHA512Core.compress(&state, blocks: $0) }
        self.state = state
    }

    /// Pads, and writes the first `count` words big-endian.
    @inlinable
    mutating func finalize(words count: Int, into digest: inout MutableRawSpan) {
        var state = state
        buffer.pad(lengthByteCount: 16) { SHA512Core.compress(&state, blocks: $0) }
        precondition(digest.byteCount >= 8 &* count, "The digest needs \(8 &* count) bytes")
        for index in 0..<count {
            digest.storeBytes(of: state[index].bigEndian, toByteOffset: 8 &* index, as: UInt64.self)
        }
    }

    /// The round constants: the first 64 bits of the fractional parts of the first 80 primes' cube roots.
    static let roundConstants: InlineArray<80, UInt64> = [
        0x428A_2F98_D728_AE22, 0x7137_4491_23EF_65CD, 0xB5C0_FBCF_EC4D_3B2F, 0xE9B5_DBA5_8189_DBBC, 0x3956_C25B_F348_B538,
        0x59F1_11F1_B605_D019, 0x923F_82A4_AF19_4F9B, 0xAB1C_5ED5_DA6D_8118, 0xD807_AA98_A303_0242, 0x1283_5B01_4570_6FBE,
        0x2431_85BE_4EE4_B28C, 0x550C_7DC3_D5FF_B4E2, 0x72BE_5D74_F27B_896F, 0x80DE_B1FE_3B16_96B1, 0x9BDC_06A7_25C7_1235,
        0xC19B_F174_CF69_2694, 0xE49B_69C1_9EF1_4AD2, 0xEFBE_4786_384F_25E3, 0x0FC1_9DC6_8B8C_D5B5, 0x240C_A1CC_77AC_9C65,
        0x2DE9_2C6F_592B_0275, 0x4A74_84AA_6EA6_E483, 0x5CB0_A9DC_BD41_FBD4, 0x76F9_88DA_8311_53B5, 0x983E_5152_EE66_DFAB,
        0xA831_C66D_2DB4_3210, 0xB003_27C8_98FB_213F, 0xBF59_7FC7_BEEF_0EE4, 0xC6E0_0BF3_3DA8_8FC2, 0xD5A7_9147_930A_A725,
        0x06CA_6351_E003_826F, 0x1429_2967_0A0E_6E70, 0x27B7_0A85_46D2_2FFC, 0x2E1B_2138_5C26_C926, 0x4D2C_6DFC_5AC4_2AED,
        0x5338_0D13_9D95_B3DF, 0x650A_7354_8BAF_63DE, 0x766A_0ABB_3C77_B2A8, 0x81C2_C92E_47ED_AEE6, 0x9272_2C85_1482_353B,
        0xA2BF_E8A1_4CF1_0364, 0xA81A_664B_BC42_3001, 0xC24B_8B70_D0F8_9791, 0xC76C_51A3_0654_BE30, 0xD192_E819_D6EF_5218,
        0xD699_0624_5565_A910, 0xF40E_3585_5771_202A, 0x106A_A070_32BB_D1B8, 0x19A4_C116_B8D2_D0C8, 0x1E37_6C08_5141_AB53,
        0x2748_774C_DF8E_EB99, 0x34B0_BCB5_E19B_48A8, 0x391C_0CB3_C5C9_5A63, 0x4ED8_AA4A_E341_8ACB, 0x5B9C_CA4F_7763_E373,
        0x682E_6FF3_D6B2_B8A3, 0x748F_82EE_5DEF_B2FC, 0x78A5_636F_4317_2F60, 0x84C8_7814_A1F0_AB72, 0x8CC7_0208_1A64_39EC,
        0x90BE_FFFA_2363_1E28, 0xA450_6CEB_DE82_BDE9, 0xBEF9_A3F7_B2C6_7915, 0xC671_78F2_E372_532B, 0xCA27_3ECE_EA26_619C,
        0xD186_B8C7_21C0_C207, 0xEADA_7DD6_CDE0_EB1E, 0xF57D_4F7F_EE6E_D178, 0x06F0_67AA_7217_6FBA, 0x0A63_7DC5_A2C8_98A6,
        0x113F_9804_BEF9_0DAE, 0x1B71_0B35_131C_471B, 0x28DB_77F5_2304_7D84, 0x32CA_AB7B_40C7_2493, 0x3C9E_BE0A_15C9_BEBC,
        0x431D_67C4_9C10_0D4C, 0x4CC5_D4BE_CB3E_42B6, 0x597F_299C_FC65_7E2A, 0x5FCB_6FAB_3AD6_FAEC, 0x6C44_198C_4A47_5817,
    ]

    /// Compresses whole 128-byte blocks into `state`.
    @usableFromInline
    static func compress(_ state: inout InlineArray<8, UInt64>, blocks: RawSpan) {
        #if HardwareCrypto && arch(arm64) && !Portable
        if hasInstructions {
            compressWithInstructions(&state, blocks: blocks)
            return
        }
        #endif
        compressPortably(&state, blocks: blocks)
    }

    #if HardwareCrypto && arch(arm64) && !Portable
    /// Whether the C module was compiled with ARM's SHA-512 instructions (`__ARM_FEATURE_SHA512`: every Apple silicon
    /// Mac): a constant, so the test folds away.
    @inline(__always)
    static var hasInstructions: Bool { BYTES_HAS_SHA512_INSTRUCTIONS != 0 }

    /// Two rounds per `sha512h`/`sha512h2` pair, on the state as four pairs of words (AB, CD, EF, GH);
    /// `sha512su0`/`sha512su1` extend the schedule two words at a time, kept in eight vectors. Written out with the
    /// round constants as literals: a table in a `static let` is copied or loaded through a lazy initializer.
    @inline(never)
    static func compressWithInstructions(_ state: inout InlineArray<8, UInt64>, blocks: RawSpan) {
        // The state and the schedule in structs whose methods mutate them, not in variables that nested functions
        // capture: captured, the vectors lived in memory behind 12 `swift_beginAccess` calls a block.
        var s = SHA512Pairs(ab: SIMD2(state[0], state[1]), cd: SIMD2(state[2], state[3]),
                            ef: SIMD2(state[4], state[5]), gh: SIMD2(state[6], state[7]))
        var offset = 0
        while blocks.byteCount &- offset >= 128 { // Whole blocks only (all the buffer passes): fewer checks.
            let saved = s
            // The block's sixteen big-endian words, as eight pairs.
            let start = offset
            @inline(__always) func pair(_ index: Int) -> SIMD2<UInt64> {
                bytes_rev64_words(blocks.load(fromByteOffset: start &+ 16 &* index, as: SIMD16<UInt8>.self))
            }
            var m = SHA512Window(w0: pair(0), w1: pair(1), w2: pair(2), w3: pair(3),
                                 w4: pair(4), w5: pair(5), w6: pair(6), w7: pair(7))
            s.rounds(m.w0, 0x428A_2F98_D728_AE22, 0x7137_4491_23EF_65CD); m.advance()
            s.rounds(m.w0, 0xB5C0_FBCF_EC4D_3B2F, 0xE9B5_DBA5_8189_DBBC); m.advance()
            s.rounds(m.w0, 0x3956_C25B_F348_B538, 0x59F1_11F1_B605_D019); m.advance()
            s.rounds(m.w0, 0x923F_82A4_AF19_4F9B, 0xAB1C_5ED5_DA6D_8118); m.advance()
            s.rounds(m.w0, 0xD807_AA98_A303_0242, 0x1283_5B01_4570_6FBE); m.advance()
            s.rounds(m.w0, 0x2431_85BE_4EE4_B28C, 0x550C_7DC3_D5FF_B4E2); m.advance()
            s.rounds(m.w0, 0x72BE_5D74_F27B_896F, 0x80DE_B1FE_3B16_96B1); m.advance()
            s.rounds(m.w0, 0x9BDC_06A7_25C7_1235, 0xC19B_F174_CF69_2694); m.advance()
            s.rounds(m.w0, 0xE49B_69C1_9EF1_4AD2, 0xEFBE_4786_384F_25E3); m.advance()
            s.rounds(m.w0, 0x0FC1_9DC6_8B8C_D5B5, 0x240C_A1CC_77AC_9C65); m.advance()
            s.rounds(m.w0, 0x2DE9_2C6F_592B_0275, 0x4A74_84AA_6EA6_E483); m.advance()
            s.rounds(m.w0, 0x5CB0_A9DC_BD41_FBD4, 0x76F9_88DA_8311_53B5); m.advance()
            s.rounds(m.w0, 0x983E_5152_EE66_DFAB, 0xA831_C66D_2DB4_3210); m.advance()
            s.rounds(m.w0, 0xB003_27C8_98FB_213F, 0xBF59_7FC7_BEEF_0EE4); m.advance()
            s.rounds(m.w0, 0xC6E0_0BF3_3DA8_8FC2, 0xD5A7_9147_930A_A725); m.advance()
            s.rounds(m.w0, 0x06CA_6351_E003_826F, 0x1429_2967_0A0E_6E70); m.advance()
            s.rounds(m.w0, 0x27B7_0A85_46D2_2FFC, 0x2E1B_2138_5C26_C926); m.advance()
            s.rounds(m.w0, 0x4D2C_6DFC_5AC4_2AED, 0x5338_0D13_9D95_B3DF); m.advance()
            s.rounds(m.w0, 0x650A_7354_8BAF_63DE, 0x766A_0ABB_3C77_B2A8); m.advance()
            s.rounds(m.w0, 0x81C2_C92E_47ED_AEE6, 0x9272_2C85_1482_353B); m.advance()
            s.rounds(m.w0, 0xA2BF_E8A1_4CF1_0364, 0xA81A_664B_BC42_3001); m.advance()
            s.rounds(m.w0, 0xC24B_8B70_D0F8_9791, 0xC76C_51A3_0654_BE30); m.advance()
            s.rounds(m.w0, 0xD192_E819_D6EF_5218, 0xD699_0624_5565_A910); m.advance()
            s.rounds(m.w0, 0xF40E_3585_5771_202A, 0x106A_A070_32BB_D1B8); m.advance()
            s.rounds(m.w0, 0x19A4_C116_B8D2_D0C8, 0x1E37_6C08_5141_AB53); m.advance()
            s.rounds(m.w0, 0x2748_774C_DF8E_EB99, 0x34B0_BCB5_E19B_48A8); m.advance()
            s.rounds(m.w0, 0x391C_0CB3_C5C9_5A63, 0x4ED8_AA4A_E341_8ACB); m.advance()
            s.rounds(m.w0, 0x5B9C_CA4F_7763_E373, 0x682E_6FF3_D6B2_B8A3); m.advance()
            s.rounds(m.w0, 0x748F_82EE_5DEF_B2FC, 0x78A5_636F_4317_2F60); m.advance()
            s.rounds(m.w0, 0x84C8_7814_A1F0_AB72, 0x8CC7_0208_1A64_39EC); m.advance()
            s.rounds(m.w0, 0x90BE_FFFA_2363_1E28, 0xA450_6CEB_DE82_BDE9); m.advance()
            s.rounds(m.w0, 0xBEF9_A3F7_B2C6_7915, 0xC671_78F2_E372_532B); m.advance()
            s.rounds(m.w0, 0xCA27_3ECE_EA26_619C, 0xD186_B8C7_21C0_C207); m.shift()
            s.rounds(m.w0, 0xEADA_7DD6_CDE0_EB1E, 0xF57D_4F7F_EE6E_D178); m.shift()
            s.rounds(m.w0, 0x06F0_67AA_7217_6FBA, 0x0A63_7DC5_A2C8_98A6); m.shift()
            s.rounds(m.w0, 0x113F_9804_BEF9_0DAE, 0x1B71_0B35_131C_471B); m.shift()
            s.rounds(m.w0, 0x28DB_77F5_2304_7D84, 0x32CA_AB7B_40C7_2493); m.shift()
            s.rounds(m.w0, 0x3C9E_BE0A_15C9_BEBC, 0x431D_67C4_9C10_0D4C); m.shift()
            s.rounds(m.w0, 0x4CC5_D4BE_CB3E_42B6, 0x597F_299C_FC65_7E2A); m.shift()
            s.rounds(m.w0, 0x5FCB_6FAB_3AD6_FAEC, 0x6C44_198C_4A47_5817)
            s.ab &+= saved.ab; s.cd &+= saved.cd; s.ef &+= saved.ef; s.gh &+= saved.gh
            offset &+= 128
        }
        (state[0], state[1], state[2], state[3]) = (s.ab[0], s.ab[1], s.cd[0], s.cd[1])
        (state[4], state[5], state[6], state[7]) = (s.ef[0], s.ef[1], s.gh[0], s.gh[1])
    }
    #endif

    /// The portable block function: 80 rounds in five groups of sixteen, the first on the block's words and each
    /// later one after the schedule's next sixteen, all in locals. (A rolled loop over the rounds with the schedule
    /// in an array and a `round >= 16` test in each was 4,600 instructions a block.)
    @inline(never)
    static func compressPortably(_ state: inout InlineArray<8, UInt64>, blocks: RawSpan) {
        // State and schedule in structs with mutating methods, not variables captured by nested functions (which
        // can leave them in memory behind dynamic exclusivity checks).
        var s = SHA512Words(a: state[0], b: state[1], c: state[2], d: state[3],
                            e: state[4], f: state[5], g: state[6], h: state[7])
        var offset = 0
        while blocks.byteCount &- offset >= 128 { // Whole blocks only (all the buffer passes): fewer checks.
            let saved = s
            let start = offset
            @inline(__always) func word(_ index: Int) -> UInt64 {
                UInt64(bigEndian: blocks.load(fromByteOffset: start &+ 8 &* index, as: UInt64.self))
            }
            var m = SHA512Schedule(
                w0: word(0), w1: word(1), w2: word(2), w3: word(3), w4: word(4), w5: word(5), w6: word(6), w7: word(7),
                w8: word(8), w9: word(9), w10: word(10), w11: word(11), w12: word(12), w13: word(13), w14: word(14),
                w15: word(15)
            )
            s.sixteenRounds(m, from: 0)
            var base = 16
            while base < 80 {
                m.advance()
                s.sixteenRounds(m, from: base)
                base &+= 16
            }
            s.a &+= saved.a; s.b &+= saved.b; s.c &+= saved.c; s.d &+= saved.d
            s.e &+= saved.e; s.f &+= saved.f; s.g &+= saved.g; s.h &+= saved.h
            offset &+= 128
        }
        (state[0], state[1], state[2], state[3]) = (s.a, s.b, s.c, s.d)
        (state[4], state[5], state[6], state[7]) = (s.e, s.f, s.g, s.h)
    }
}

/// SHA-512's working variables, for the portable block function.
struct SHA512Words {
    var a, b, c, d, e, f, g, h: UInt64

    /// One round with the constant `k` and the schedule word `w`.
    @inline(__always)
    mutating func round(_ k: UInt64, _ w: UInt64) {
        let sum1 = e.rotatedRight(by: 14) ^ e.rotatedRight(by: 18) ^ e.rotatedRight(by: 41)
        let choice = g ^ (e & (f ^ g))
        let temp1 = h &+ sum1 &+ choice &+ k &+ w
        let sum0 = a.rotatedRight(by: 28) ^ a.rotatedRight(by: 34) ^ a.rotatedRight(by: 39)
        let majority = (a & b) | (c & (a | b))
        (h, g, f, e, d, c, b, a) = (g, f, e, d &+ temp1, c, b, a, temp1 &+ sum0 &+ majority)
    }

    /// Rounds `base` to `base + 15`, with the schedule's sixteen words for them.
    @inline(__always)
    mutating func sixteenRounds(_ m: SHA512Schedule, from base: Int) {
        let k = SHA512Core.roundConstants
        round(k[base], m.w0); round(k[base &+ 1], m.w1); round(k[base &+ 2], m.w2); round(k[base &+ 3], m.w3)
        round(k[base &+ 4], m.w4); round(k[base &+ 5], m.w5); round(k[base &+ 6], m.w6); round(k[base &+ 7], m.w7)
        round(k[base &+ 8], m.w8); round(k[base &+ 9], m.w9); round(k[base &+ 10], m.w10); round(k[base &+ 11], m.w11)
        round(k[base &+ 12], m.w12); round(k[base &+ 13], m.w13); round(k[base &+ 14], m.w14); round(k[base &+ 15], m.w15)
    }
}

/// Sixteen words of SHA-512's message schedule, for the portable block function.
struct SHA512Schedule {
    var w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15: UInt64

    /// W[j + 16] = W[j] + σ0(W[j + 1]) + W[j + 9] + σ1(W[j + 14]).
    @inline(__always)
    static func next(_ w: UInt64, _ w1: UInt64, _ w9: UInt64, _ w14: UInt64) -> UInt64 {
        let s0 = w1.rotatedRight(by: 1) ^ w1.rotatedRight(by: 8) ^ (w1 &>> 7)
        let s1 = w14.rotatedRight(by: 19) ^ w14.rotatedRight(by: 61) ^ (w14 &>> 6)
        return w &+ s0 &+ w9 &+ s1
    }

    /// The next sixteen words, in place: positions modulo 16, in order, so the later terms already hold the new
    /// words where the formula needs them.
    @inline(__always)
    mutating func advance() {
        w0 = Self.next(w0, w1, w9, w14); w1 = Self.next(w1, w2, w10, w15)
        w2 = Self.next(w2, w3, w11, w0); w3 = Self.next(w3, w4, w12, w1)
        w4 = Self.next(w4, w5, w13, w2); w5 = Self.next(w5, w6, w14, w3)
        w6 = Self.next(w6, w7, w15, w4); w7 = Self.next(w7, w8, w0, w5)
        w8 = Self.next(w8, w9, w1, w6); w9 = Self.next(w9, w10, w2, w7)
        w10 = Self.next(w10, w11, w3, w8); w11 = Self.next(w11, w12, w4, w9)
        w12 = Self.next(w12, w13, w5, w10); w13 = Self.next(w13, w14, w6, w11)
        w14 = Self.next(w14, w15, w7, w12); w15 = Self.next(w15, w0, w8, w13)
    }
}

#if HardwareCrypto && arch(arm64) && !Portable
/// SHA-512's working variables as four pairs, for the instructions.
struct SHA512Pairs {
    var ab, cd, ef, gh: SIMD2<UInt64>

    /// Rounds i and i + 1 with the schedule words `w` and the constants `k0`, `k1`. `sha512h` takes GH plus K + W
    /// with round i's in the high lane, and the pairs (F, G) and (D, E): each one `ext` of neighbouring vectors.
    /// Afterwards the state moves along: (AB, CD, EF, GH) becomes (new AB, AB, CD + T1, EF).
    @inline(__always)
    mutating func rounds(_ w: SIMD2<UInt64>, _ k0: UInt64, _ k1: UInt64) {
        let kw = w &+ SIMD2(k0, k1)
        let t1 = bytes_sha512h(gh &+ SIMD2(kw[1], kw[0]), SIMD2(ef[1], gh[0]), SIMD2(cd[1], ef[0]))
        (ab, cd, ef, gh) = (bytes_sha512h2(t1, cd, ab), ab, cd &+ t1, ef)
    }
}

/// Sixteen words of SHA-512's message schedule as eight pairs, W[j] and W[j + 1] first, for the instructions.
struct SHA512Window {
    var w0, w1, w2, w3, w4, w5, w6, w7: SIMD2<UInt64>

    /// W[j + 16] and W[j + 17] from the pairs at j, j + 2, j + 8 (its high word and the next pair's low: W[j + 9],
    /// W[j + 10]), and j + 14; then the window moves on by a pair.
    @inline(__always)
    mutating func advance() {
        let next = bytes_sha512su1(bytes_sha512su0(w0, w1), w7, SIMD2(w4[1], w5[0]))
        (w0, w1, w2, w3, w4, w5, w6, w7) = (w1, w2, w3, w4, w5, w6, w7, next)
    }

    /// The window moved on with nothing after it: the last eight pairs need no successors.
    @inline(__always)
    mutating func shift() {
        (w0, w1, w2, w3, w4, w5, w6) = (w1, w2, w3, w4, w5, w6, w7)
    }
}
#endif

/// SHA-512 (FIPS 180-4).
public struct SHA512: HashFunction {
    @usableFromInline var core = SHA512Core(state: [
        0x6A09_E667_F3BC_C908, 0xBB67_AE85_84CA_A73B, 0x3C6E_F372_FE94_F82B, 0xA54F_F53A_5F1D_36F1,
        0x510E_527F_ADE6_82D1, 0x9B05_688C_2B3E_6C1F, 0x1F83_D9AB_FB41_BD6B, 0x5BE0_CD19_137E_2179,
    ])

    /// 128.
    @inlinable public static var blockByteCount: Int { 128 }
    /// 64.
    @inlinable public static var digestByteCount: Int { 64 }

    /// A hash of nothing yet.
    @inlinable public init() {}

    /// Adds `bytes` to the message.
    ///
    /// - Parameter bytes: The next bytes of the message.
    @inlinable public mutating func update(_ bytes: RawSpan) { core.update(bytes) }

    /// Finishes the message and writes its 64-byte digest to the start of `digest`.
    ///
    /// - Parameter digest: Room for at least 64 bytes.
    @inlinable public mutating func finalize(into digest: inout MutableRawSpan) { core.finalize(words: 8, into: &digest) }
}

/// SHA-384 (FIPS 180-4): SHA-512 with other initial values, truncated to 48 bytes. TLS 1.3's hash for
/// `TLS_AES_256_GCM_SHA384`.
public struct SHA384: HashFunction {
    @usableFromInline var core = SHA512Core(state: [
        0xCBBB_9D5D_C105_9ED8, 0x629A_292A_367C_D507, 0x9159_015A_3070_DD17, 0x152F_ECD8_F70E_5939,
        0x6733_2667_FFC0_0B31, 0x8EB4_4A87_6858_1511, 0xDB0C_2E0D_64F9_8FA7, 0x47B5_481D_BEFA_4FA4,
    ])

    /// 128.
    @inlinable public static var blockByteCount: Int { 128 }
    /// 48.
    @inlinable public static var digestByteCount: Int { 48 }

    /// A hash of nothing yet.
    @inlinable public init() {}

    /// Adds `bytes` to the message.
    ///
    /// - Parameter bytes: The next bytes of the message.
    @inlinable public mutating func update(_ bytes: RawSpan) { core.update(bytes) }

    /// Finishes the message and writes its 48-byte digest to the start of `digest`.
    ///
    /// - Parameter digest: Room for at least 48 bytes.
    @inlinable public mutating func finalize(into digest: inout MutableRawSpan) { core.finalize(words: 6, into: &digest) }
}

extension FixedWidthInteger {
    /// The value rotated left by `count` bits.
    @inlinable @inline(__always)
    func rotatedLeft(by count: Int) -> Self { self &<< count | self &>> (Self.bitWidth &- count) }

    /// The value rotated right by `count` bits.
    @inlinable @inline(__always)
    func rotatedRight(by count: Int) -> Self { self &>> count | self &<< (Self.bitWidth &- count) }
}
