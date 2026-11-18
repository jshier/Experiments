public import Bytes
#if HardwareCrypto && arch(arm64) && !Portable
internal import CBytesCrypto
#endif

// AES-GCM (NIST SP 800-38D) with 96-bit nonces and 128-bit tags: TLS 1.3's `TLS_AES_128_GCM_SHA256` (the suite
// every implementation must support) and `TLS_AES_256_GCM_SHA384`.
//
// GHASH multiplies in GF(2¹²⁸). With `HardwareCrypto` (the default on Apple silicon) each product is three
// `pmull`s (Karatsuba) on the blocks byte-reversed into 128-bit integers, eight blocks are summed against H⁸…H¹
// before one reduction (shifts and XORs, as in Gueron and Kounavis's reflected method), and the reduction is
// written in scalar 64-bit operations. Elsewhere, the bit-serial multiply of SP 800-38D, on masks: constant-time,
// and slow. Both are tested against each other and against published vectors and CryptoKit.

/// An element of GCM's field as a 128-bit integer: a block's bytes read big-endian (byte 0 most significant), so
/// the coefficient of xⁱ is bit 127 − i.
@usableFromInline
struct FieldElement: Sendable, Equatable {
    @usableFromInline var low: UInt64
    @usableFromInline var high: UInt64

    @inlinable init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    /// A block's 16 bytes, at `offset` in `bytes`.
    @inlinable
    init(_ bytes: RawSpan, at offset: Int) {
        high = UInt64(bigEndian: bytes.load(fromByteOffset: offset, as: UInt64.self))
        low = UInt64(bigEndian: bytes.load(fromByteOffset: offset &+ 8, as: UInt64.self))
    }

    static var zero: FieldElement { FieldElement(low: 0, high: 0) }

    /// The bit-serial product (SP 800-38D, algorithm 1): constant-time, by masks.
    static func multiplyPortably(_ x: FieldElement, _ y: FieldElement) -> FieldElement {
        var z = FieldElement.zero
        var v = y
        for index in 0..<128 {
            // Bit `index` of X, most significant first.
            let bit = index < 64 ? (x.high &>> UInt64(63 &- index)) & 1 : (x.low &>> UInt64(127 &- index)) & 1
            let take = 0 &- bit
            z.high ^= v.high & take
            z.low ^= v.low & take
            // V × x: a shift toward the high coefficients (right, in this order), reduced by R = 0xE1 ‖ 0¹²⁰.
            let carry = v.low & 1
            v.low = v.low &>> 1 | v.high &<< 63
            v.high = v.high &>> 1 ^ (0xE100_0000_0000_0000 & (0 &- carry))
        }
        return z
    }
}

/// AES-GCM with a 128-, 192-, or 256-bit key, 96-bit nonces, and 128-bit tags: encrypts and authenticates in
/// place, allocating nothing.
///
/// ```swift
/// let aead = AESGCM(key: key)                                         // 16 or 32 bytes for TLS
/// let tag = aead.seal(&message, nonce: nonce, authenticating: header)  // encrypts `message` in place
/// try aead.open(&message, nonce: nonce, authenticating: header, tag: tag.span.bytes)  // throws `.mismatch` if forged
/// ```
///
/// Opening checks the tag over the ciphertext before decrypting anything: a forged message is never decrypted.
/// Nonces must never repeat under one key (TLS's record nonces don't: they're the sequence number XOR a
/// per-direction IV). A message is at most 2³⁶ − 32 bytes, SP 800-38D's limit.
public struct AESGCM: Sendable {
    @usableFromInline let aes: AES
    /// The hash key H = E(K, 0¹²⁸).
    @usableFromInline let hashKey: FieldElement
    #if HardwareCrypto && arch(arm64) && !Portable
    /// H¹…H⁸, for summing eight blocks' products before reducing once, and each one's halves XORed (Karatsuba's
    /// middle factor), in lane 0.
    let powers: InlineArray<8, SIMD2<UInt64>>
    let powerSums: InlineArray<8, SIMD2<UInt64>>
    #endif

    /// The longest message: 2³⁹ − 256 bits.
    public static var maximumMessageByteCount: Int { (1 << 36) &- 32 }

    /// Creates an AEAD with a key of 16, 24, or 32 bytes.
    ///
    /// - Parameter key: The AES key.
    /// - Precondition: `key` is 16, 24, or 32 bytes.
    public init(key: RawSpan) {
        aes = AES(key: key)
        let h = aes.encrypt(.zero)
        var bytes = InlineArray<16, UInt8>(repeating: 0)
        for index in 0..<16 { bytes[index] = h[index] }
        let element = FieldElement(bytes.span.bytes, at: 0)
        hashKey = element
        #if HardwareCrypto && arch(arm64) && !Portable
        var powers = InlineArray<8, SIMD2<UInt64>>(repeating: .zero)
        var sums = InlineArray<8, SIMD2<UInt64>>(repeating: .zero)
        var power = element
        for index in 0..<8 {
            powers[index] = SIMD2(power.low, power.high)
            sums[index] = SIMD2(power.low ^ power.high, 0)
            power = AESGCM.multiply(power, element)
        }
        self.powers = powers
        self.powerSums = sums
        #endif
    }

    // MARK: Sealing and opening

    /// Encrypts `message` in place and returns the tag authenticating it and `aad`.
    ///
    /// - Parameters:
    ///   - message: The plaintext, replaced by the ciphertext.
    ///   - nonce: 12 bytes, never reused with this key.
    ///   - aad: Additional data authenticated but not encrypted (a record header).
    /// - Returns: The 16-byte tag.
    /// - Precondition: `nonce` is 12 bytes, and `message` is at most ``maximumMessageByteCount`` bytes.
    public func seal(_ message: inout MutableRawSpan, nonce: RawSpan, authenticating aad: RawSpan) -> InlineArray<16, UInt8> {
        precondition(message.byteCount <= Self.maximumMessageByteCount, "AES-GCM messages are at most 2^36 - 32 bytes")
        let (j0, counter) = Self.counterBlocks(nonce)
        var counterState = counter
        var hash = FieldElement.zero
        absorb(aad, into: &hash)
        var done = 0
        #if HardwareCrypto && arch(arm64) && !Portable
        // Whole groups of eight blocks encrypted and hashed in one pass (stitched), the rest in two.
        // Unsafe: the message's memory for the stitched loop. Safe: the loop stays within `byteCount`, and the
        // pointer doesn't outlive the closure.
        done = message.withUnsafeMutableBytes { buffer in
            unsafe sealBatches(buffer.baseAddress, count: buffer.count, counter: &counterState, hash: &hash)
        }
        #endif
        var rest = message._mutatingExtracting(done...)
        aes.counterMode(&rest, counter: &counterState)
        absorb(rest.bytes, into: &hash)
        return finishTag(hash, aadByteCount: aad.byteCount, ciphertextByteCount: message.byteCount, j0: j0)
    }

    /// Checks `tag` against `message` and `aad`, then decrypts `message` in place.
    ///
    /// - Parameters:
    ///   - message: The ciphertext, replaced by the plaintext if the tag matches; untouched otherwise.
    ///   - nonce: The 12-byte nonce it was sealed with.
    ///   - aad: The additional data it was sealed with.
    ///   - tag: The 16-byte tag.
    /// - Throws: ``BytesError/mismatch`` if the tag doesn't match (the message or data was altered, or the key or
    ///   nonce is wrong); ``BytesError/invalidValue`` if `tag` isn't 16 bytes or the message is too long.
    /// - Precondition: `nonce` is 12 bytes.
    public func open(_ message: inout MutableRawSpan, nonce: RawSpan, authenticating aad: RawSpan, tag: RawSpan) throws(BytesError) {
        guard tag.byteCount == 16, message.byteCount <= Self.maximumMessageByteCount else { throw .invalidValue }
        let (j0, counter) = Self.counterBlocks(nonce)
        let expected = self.tag(aad: aad, ciphertext: message.bytes, j0: j0)
        guard constantTimeEquals(expected.span.bytes, tag) else { throw .mismatch }
        var counterState = counter
        aes.counterMode(&message, counter: &counterState)
    }

    /// J₀ = nonce ‖ 0³¹ ‖ 1 as bytes, and the counter for the message, which starts at J₀ + 1.
    static func counterBlocks(_ nonce: RawSpan) -> (j0: InlineArray<16, UInt8>, counter: AES.Counter) {
        precondition(nonce.byteCount == 12, "AES-GCM nonces are 12 bytes here")
        var block = InlineArray<16, UInt8>(repeating: 0)
        for index in 0..<12 { block[index] = nonce.load(fromByteOffset: index, as: UInt8.self) }
        block[15] = 1
        var counter = AES.Counter(bigEndianCounterIn: block.span.bytes)
        _ = counter.next() // J₀ itself encrypts the tag, below.
        return (block, counter)
    }

    /// The tag: GHASH over the padded `aad` and `ciphertext` and their bit lengths, XOR E(K, J₀).
    func tag(aad: RawSpan, ciphertext: RawSpan, j0: InlineArray<16, UInt8>) -> InlineArray<16, UInt8> {
        var hash = FieldElement.zero
        absorb(aad, into: &hash)
        absorb(ciphertext, into: &hash)
        return finishTag(hash, aadByteCount: aad.byteCount, ciphertextByteCount: ciphertext.byteCount, j0: j0)
    }

    /// The tag from GHASH over the data so far: the bit lengths hashed in last, then XOR E(K, J₀).
    func finishTag(_ hash: FieldElement, aadByteCount: Int, ciphertextByteCount: Int, j0: InlineArray<16, UInt8>) -> InlineArray<16, UInt8> {
        var hash = hash
        let lengths = FieldElement(low: UInt64(ciphertextByteCount) &<< 3, high: UInt64(aadByteCount) &<< 3)
        hash = multiply(FieldElement(low: hash.low ^ lengths.low, high: hash.high ^ lengths.high), hashKey)
        var block = SIMD16<UInt8>.zero
        for index in 0..<16 { block[index] = j0[index] }
        let mask = aes.encrypt(block)
        var tag = InlineArray<16, UInt8>(repeating: 0)
        for index in 0..<8 {
            tag[index] = UInt8(truncatingIfNeeded: hash.high &>> UInt64(56 &- 8 &* index)) ^ mask[index]
            tag[8 &+ index] = UInt8(truncatingIfNeeded: hash.low &>> UInt64(56 &- 8 &* index)) ^ mask[8 &+ index]
        }
        return tag
    }

    // MARK: GHASH

    /// GHASH's update over `bytes`, the last block padded with zeros.
    func absorb(_ bytes: RawSpan, into hash: inout FieldElement) {
        var offset = 0
        #if HardwareCrypto && arch(arm64) && !Portable
        offset = absorbBatches(bytes, into: &hash)
        #endif
        while bytes.byteCount &- offset >= 16 {
            let block = FieldElement(bytes, at: offset)
            hash = multiply(FieldElement(low: hash.low ^ block.low, high: hash.high ^ block.high), hashKey)
            offset &+= 16
        }
        if offset < bytes.byteCount {
            var padded = InlineArray<16, UInt8>(repeating: 0)
            for index in 0..<(bytes.byteCount &- offset) { padded[index] = bytes.load(fromByteOffset: offset &+ index, as: UInt8.self) }
            let block = FieldElement(padded.span.bytes, at: 0)
            hash = multiply(FieldElement(low: hash.low ^ block.low, high: hash.high ^ block.high), hashKey)
        }
    }

    /// `x × y` in GCM's field.
    func multiply(_ x: FieldElement, _ y: FieldElement) -> FieldElement {
        AESGCM.multiply(x, y)
    }

    static func multiply(_ x: FieldElement, _ y: FieldElement) -> FieldElement {
        #if HardwareCrypto && arch(arm64) && !Portable
        let a = SIMD2(x.low, x.high), b = SIMD2(y.low, y.high)
        let product = reduceInVectors(
            low: bytes_pmull_low(a, b), middle: bytes_pmull_low(a ^ swapped(a), b ^ swapped(b)),
            high: bytes_pmull_high(a, b)
        )
        return FieldElement(low: product[0], high: product[1])
        #else
        return FieldElement.multiplyPortably(x, y)
        #endif
    }

    #if HardwareCrypto && arch(arm64) && !Portable
    /// The lanes of `x` swapped: one `ext`.
    @inline(__always)
    static func swapped(_ x: SIMD2<UInt64>) -> SIMD2<UInt64> { SIMD2(x[1], x[0]) }

    /// `reduce(low:middle:high:)` in vector instructions: the shift and the shift-XOR folds as two carry-less
    /// multiplications by 0xC200000000000000 (x⁶³ + x⁶² + x⁵⁷, the reflected polynomial's low terms).
    ///
    /// The scalar form's `(x₀ ≪ 63) ⊕ (x₀ ≪ 62) ⊕ (x₀ ≪ 57)` and `(x₀ ≫ 1) ⊕ (x₀ ≫ 2) ⊕ (x₀ ≫ 7)` are the low and
    /// high halves of x₀ × c; folding twice, swapping halves between: T = L × c, M = swap(L) ⊕ T, U = M × c, and
    /// the result is H ⊕ swap(M) ⊕ U.
    @inline(__always)
    static func reduceInVectors(low: SIMD2<UInt64>, middle: SIMD2<UInt64>, high: SIMD2<UInt64>) -> SIMD2<UInt64> {
        let middle = middle ^ low ^ high
        // The 256-bit product as two halves: L = (x₀, x₁), H = (x₂, x₃).
        var l = low ^ SIMD2(0, middle[0])
        var h = high ^ SIMD2(middle[1], 0)
        // Shifted left by one: the product of two reflected elements is the reflected product shifted right by one.
        h = h &<< 1 | SIMD2(l[1] &>> 63, h[0] &>> 63)
        l = l &<< 1 | SIMD2(0, l[0] &>> 63)
        let c = SIMD2<UInt64>(0xC200_0000_0000_0000, 0)
        let t = bytes_pmull_low(l, c)
        let m = swapped(l) ^ t
        let u = bytes_pmull_low(m, c)
        return h ^ swapped(m) ^ u
    }

    /// Reduces a 256-bit carry-less product, given as Karatsuba's three partial products (`middle` not yet
    /// corrected by the other two), to a field element, in the order of `FieldElement` (lane 0 low).
    ///
    /// The product of two bit-reflected elements is the reflected product shifted right by one, so it's shifted
    /// left by one first; then the reflected reduction modulo x¹²⁸ + x⁷ + x² + x + 1, in shifts and XORs.
    @inline(__always)
    static func reduce(low: SIMD2<UInt64>, middle: SIMD2<UInt64>, high: SIMD2<UInt64>) -> SIMD2<UInt64> {
        let middle = middle ^ low ^ high
        var x0 = low[0], x1 = low[1] ^ middle[0], x2 = high[0] ^ middle[1], x3 = high[1]
        x3 = x3 &<< 1 | x2 &>> 63
        x2 = x2 &<< 1 | x1 &>> 63
        x1 = x1 &<< 1 | x0 &>> 63
        x0 = x0 &<< 1
        let d = x1 ^ (x0 &<< 63) ^ (x0 &<< 62) ^ (x0 &<< 57)
        let e0 = x0 &>> 1 | d &<< 63, e1 = d &>> 1
        let f0 = x0 &>> 2 | d &<< 62, f1 = d &>> 2
        let g0 = x0 &>> 7 | d &<< 57, g1 = d &>> 7
        let h0 = x0 ^ e0 ^ f0 ^ g0, h1 = d ^ e1 ^ f1 ^ g1
        return SIMD2(x2 ^ h0, x3 ^ h1)
    }

    /// Encrypts whole groups of eight blocks of `base` in place and hashes the ciphertext, in one pass: each
    /// group's AES rounds interleaved with GHASH over the previous group's ciphertext (already in memory, in L1),
    /// one block per round, so the AES and carry-less multiply units work at once. Separately, counter mode and
    /// GHASH took 61 and 107 µs per MB.
    ///
    /// - Returns: The bytes done: a multiple of 128.
    @unsafe @inline(never)
    func sealBatches(_ base: UnsafeMutableRawPointer?, count: Int, counter: inout AES.Counter, hash: inout FieldElement) -> Int {
        let batches = count / 128
        guard batches > 0, let base = unsafe base else { return 0 }
        let keys = aes.roundKeys
        let k0 = keys[0], k1 = keys[1], k2 = keys[2], k3 = keys[3], k4 = keys[4], k5 = keys[5], k6 = keys[6], k7 = keys[7]
        let k8 = keys[8], k9 = keys[9], k10 = keys[10], k11 = keys[11], k12 = keys[12], k13 = keys[13], k14 = keys[14]
        let rounds = aes.rounds
        let p = powers, s = powerSums
        var y = SIMD2(hash.low, hash.high)
        // GCM's counter: the block's words byte-swapped to native, so the last is the counter.
        var native = bytes_rev32(bitCast(counter.block, to: SIMD16<UInt8>.self))
        var low = SIMD2<UInt64>.zero, middle = SIMD2<UInt64>.zero, high = SIMD2<UInt64>.zero

        /// One block of the previous group into the sums (`first` adds the running hash).
        @inline(__always) func accumulate(_ previous: UnsafeRawPointer, _ index: Int, _ first: Bool) {
            // Unsafe: an unchecked load. Safe: `previous` is a whole group already written, within `count`.
            var x = bytes_reverse16(unsafe previous.loadUnaligned(fromByteOffset: 16 &* index, as: SIMD16<UInt8>.self))
            if first { x ^= y }
            let power = 7 &- index
            low ^= bytes_pmull_low(x, p[power])
            high ^= bytes_pmull_high(x, p[power])
            middle ^= bytes_pmull_low(x ^ AESGCM.swapped(x), s[power])
        }

        for batch in 0...batches {
            let hashing = batch > 0
            // Unsafe: the previous group's start. Safe: it's within the buffer whenever `hashing`.
            let previous = unsafe UnsafeRawPointer(base + 128 &* (batch &- 1))
            low = .zero; middle = .zero; high = .zero
            if batch == batches {
                // The last group's hash, alone.
                for index in 0..<8 { unsafe accumulate(previous, index, index == 0) }
                y = AESGCM.reduceInVectors(low: low, middle: middle, high: high)
                break
            }
            var b0 = bytes_rev32_words(native)
            var b1 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 1))
            var b2 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 2))
            var b3 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 3))
            var b4 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 4))
            var b5 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 5))
            var b6 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 6))
            var b7 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 7))
            native &+= SIMD4(0, 0, 0, 8)
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k0); if hashing { unsafe accumulate(previous, 0, true) }
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k1); if hashing { unsafe accumulate(previous, 1, false) }
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k2); if hashing { unsafe accumulate(previous, 2, false) }
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k3); if hashing { unsafe accumulate(previous, 3, false) }
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k4); if hashing { unsafe accumulate(previous, 4, false) }
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k5); if hashing { unsafe accumulate(previous, 5, false) }
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k6); if hashing { unsafe accumulate(previous, 6, false) }
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k7); if hashing { unsafe accumulate(previous, 7, false) }
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k8)
            if hashing { y = AESGCM.reduceInVectors(low: low, middle: middle, high: high) }
            let lastKey: SIMD16<UInt8>, finalKey: SIMD16<UInt8>
            switch rounds {
            case 10:
                (lastKey, finalKey) = (k9, k10)
            case 12:
                AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k9)
                AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k10)
                (lastKey, finalKey) = (k11, k12)
            default:
                AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k9)
                AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k10)
                AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k11)
                AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k12)
                (lastKey, finalKey) = (k13, k14)
            }
            // Unsafe: in-place loads and stores of this group. Safe: `128 × (batch + 1) <= count`.
            let block = unsafe base + 128 &* batch
            unsafe AES.finish(b0, lastKey, finalKey, block, block)
            unsafe AES.finish(b1, lastKey, finalKey, block + 16, block + 16)
            unsafe AES.finish(b2, lastKey, finalKey, block + 32, block + 32)
            unsafe AES.finish(b3, lastKey, finalKey, block + 48, block + 48)
            unsafe AES.finish(b4, lastKey, finalKey, block + 64, block + 64)
            unsafe AES.finish(b5, lastKey, finalKey, block + 80, block + 80)
            unsafe AES.finish(b6, lastKey, finalKey, block + 96, block + 96)
            unsafe AES.finish(b7, lastKey, finalKey, block + 112, block + 112)
        }
        counter.block = bitCast(bytes_rev32_words(native), to: SIMD2<UInt64>.self)
        hash = FieldElement(low: y[0], high: y[1])
        return batches &* 128
    }

    /// GHASH over whole groups of eight blocks: each group's products against H⁸…H¹ summed, then reduced once.
    ///
    /// - Returns: Where it stopped: the start of the last fewer-than-128 bytes.
    func absorbBatches(_ bytes: RawSpan, into hash: inout FieldElement) -> Int {
        var offset = 0
        guard bytes.byteCount >= 128 else { return 0 }
        let p = powers, s = powerSums
        var y = SIMD2(hash.low, hash.high)
        while bytes.byteCount &- offset >= 128 {
            var low = SIMD2<UInt64>.zero, middle = SIMD2<UInt64>.zero, high = SIMD2<UInt64>.zero
            @inline(__always) func accumulate(_ x: SIMD2<UInt64>, _ power: Int) {
                low ^= bytes_pmull_low(x, p[power])
                high ^= bytes_pmull_high(x, p[power])
                // Lane 0 of x ⊕ swap(x) is x's halves XORed: Karatsuba's middle factor, with one `ext`.
                middle ^= bytes_pmull_low(x ^ AESGCM.swapped(x), s[power])
            }
            @inline(__always) func block(_ index: Int) -> SIMD2<UInt64> {
                bytes_reverse16(bytes.load(fromByteOffset: offset &+ 16 &* index, as: SIMD16<UInt8>.self))
            }
            accumulate(block(0) ^ y, 7)
            accumulate(block(1), 6)
            accumulate(block(2), 5)
            accumulate(block(3), 4)
            accumulate(block(4), 3)
            accumulate(block(5), 2)
            accumulate(block(6), 1)
            accumulate(block(7), 0)
            y = AESGCM.reduceInVectors(low: low, middle: middle, high: high)
            offset &+= 128
        }
        hash = FieldElement(low: y[0], high: y[1])
        return offset
    }
    #endif
}
