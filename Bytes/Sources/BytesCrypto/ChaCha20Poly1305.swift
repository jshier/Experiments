public import Bytes

/// ChaCha20-Poly1305 (RFC 8439), the AEAD of TLS 1.3's `TLS_CHACHA20_POLY1305_SHA256`: encrypts and
/// authenticates in place or between buffers, allocating nothing.
///
/// ```swift
/// let aead = ChaCha20Poly1305(key: key)                       // 32 bytes
/// let tag = aead.seal(&message, nonce: nonce, authenticating: header)   // encrypts `message` in place
/// try aead.open(&message, nonce: nonce, authenticating: header, tag: tag)  // throws `.mismatch` if forged
/// ```
///
/// ChaCha20 runs eight blocks (512 bytes) at a time, then four, one block per lane of 16 state words
/// (`SIMD8<UInt32>`, `SIMD4<UInt32>`), so each quarter round is vector adds, XORs, and rotates on every
/// block; a 4×4 transpose per group of words puts each block's keystream back in order. Poly1305 works in
/// radix 2^64 with 64 × 64 → 128-bit multiplies, as OpenSSL's 64-bit code.
///
/// Not audited, and not constant-time against every compiler transformation: an experiment in performance.
public struct ChaCha20Poly1305: Sendable {
    /// The key, as eight little-endian words.
    let key: InlineArray<8, UInt32>

    /// Creates an AEAD with a 32-byte key.
    ///
    /// - Precondition: `key` is 32 bytes.
    public init(key: RawSpan) {
        precondition(key.byteCount == 32, "ChaCha20-Poly1305 keys are 32 bytes")
        var words = InlineArray<8, UInt32>(repeating: 0)
        var reader = AlignedBytesReader(key)
        for index in 0..<8 {
            words[index] = try! reader.read(Byte4.self, .littleEndian) // Can't throw: 32 bytes, checked above.
        }
        self.key = words
    }

    /// The nonce's three little-endian words.
    ///
    /// - Precondition: `nonce` is 12 bytes.
    @inline(__always)
    static func nonceWords(_ nonce: RawSpan) -> (UInt32, UInt32, UInt32) {
        precondition(nonce.byteCount == 12, "ChaCha20-Poly1305 nonces are 12 bytes")
        var reader = AlignedBytesReader(nonce)
        // Can't throw: 12 bytes, checked above.
        return (try! reader.read(Byte4.self, .littleEndian), try! reader.read(Byte4.self, .littleEndian), try! reader.read(Byte4.self, .littleEndian))
    }

    /// Encrypts `message` in place and returns the tag authenticating it and `aad`.
    ///
    /// - Parameters:
    ///   - message: The plaintext, replaced by the ciphertext.
    ///   - nonce: 12 bytes, never reused with this key.
    ///   - aad: Additional data authenticated but not encrypted (a record header).
    /// - Returns: The 16-byte tag.
    public func seal(_ message: inout MutableRawSpan, nonce: RawSpan, authenticating aad: RawSpan) -> InlineArray<16, UInt8> {
        let (n0, n1, n2) = Self.nonceWords(nonce)
        let polyKey = ChaCha20.block(key: key, counter: 0, nonce: (n0, n1, n2))
        ChaCha20.xor(&message, key: key, counter: 1, nonce: (n0, n1, n2))
        var mac = Poly1305(key: polyKey)
        mac.authenticate(aad: aad, ciphertext: message.bytes)
        return mac.tag()
    }

    /// Checks the tag of `message` (ciphertext) and `aad`, then decrypts `message` in place.
    ///
    /// - Parameters:
    ///   - message: The ciphertext, replaced by the plaintext.
    ///   - nonce: The 12 bytes it was sealed with.
    ///   - aad: The additional data it was sealed with.
    ///   - tag: The 16-byte tag.
    /// - Throws: ``BytesError/mismatch`` if the tag doesn't match; `message` is then unchanged.
    public func open(
        _ message: inout MutableRawSpan, nonce: RawSpan, authenticating aad: RawSpan, tag: RawSpan
    ) throws(BytesError) {
        precondition(tag.byteCount == 16, "Tags are 16 bytes")
        let (n0, n1, n2) = Self.nonceWords(nonce)
        let polyKey = ChaCha20.block(key: key, counter: 0, nonce: (n0, n1, n2))
        var mac = Poly1305(key: polyKey)
        mac.authenticate(aad: aad, ciphertext: message.bytes)
        let expected = mac.tag()
        // Compared without an early exit.
        var difference: UInt8 = 0
        for index in 0..<16 {
            difference |= expected[index] ^ tag.load(fromByteOffset: index, as: UInt8.self)
        }
        guard difference == 0 else { throw .mismatch }
        ChaCha20.xor(&message, key: key, counter: 1, nonce: (n0, n1, n2))
    }
}

/// The ChaCha20 stream cipher (RFC 8439, 2.3 and 2.4).
enum ChaCha20 {
    /// "expand 32-byte k".
    static var constants: (UInt32, UInt32, UInt32, UInt32) { (0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574) }

    /// One 64-byte keystream block.
    static func block(key: InlineArray<8, UInt32>, counter: UInt32, nonce: (UInt32, UInt32, UInt32)) -> InlineArray<64, UInt8> {
        var state = InlineArray<16, UInt32>(repeating: 0)
        let c = constants
        state[0] = c.0; state[1] = c.1; state[2] = c.2; state[3] = c.3
        for index in 0..<8 { state[4 &+ index] = key[index] }
        state[12] = counter; state[13] = nonce.0; state[14] = nonce.1; state[15] = nonce.2
        var x = state
        @inline(__always)
        func quarter(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[a] &+= x[b]; x[d] ^= x[a]; x[d] = x[d] &<< 16 | x[d] &>> 16
            x[c] &+= x[d]; x[b] ^= x[c]; x[b] = x[b] &<< 12 | x[b] &>> 20
            x[a] &+= x[b]; x[d] ^= x[a]; x[d] = x[d] &<< 8 | x[d] &>> 24
            x[c] &+= x[d]; x[b] ^= x[c]; x[b] = x[b] &<< 7 | x[b] &>> 25
        }
        for _ in 0..<10 {
            quarter(0, 4, 8, 12); quarter(1, 5, 9, 13); quarter(2, 6, 10, 14); quarter(3, 7, 11, 15)
            quarter(0, 5, 10, 15); quarter(1, 6, 11, 12); quarter(2, 7, 8, 13); quarter(3, 4, 9, 14)
        }
        var output = InlineArray<64, UInt8>(repeating: 0)
        for index in 0..<16 {
            let word = x[index] &+ state[index]
            output[index &* 4] = UInt8(truncatingIfNeeded: word)
            output[index &* 4 &+ 1] = UInt8(truncatingIfNeeded: word &>> 8)
            output[index &* 4 &+ 2] = UInt8(truncatingIfNeeded: word &>> 16)
            output[index &* 4 &+ 3] = UInt8(truncatingIfNeeded: word &>> 24)
        }
        return output
    }

    @inline(__always)
    static func rotate(_ x: SIMD4<UInt32>, _ n: UInt32) -> SIMD4<UInt32> {
        x &<< SIMD4(repeating: n) | x &>> SIMD4(repeating: 32 &- n)
    }

    @inline(__always)
    static func rotate(_ x: SIMD8<UInt32>, _ n: UInt32) -> SIMD8<UInt32> {
        x &<< SIMD8(repeating: n) | x &>> SIMD8(repeating: 32 &- n)
    }

    /// XORs `message` with the keystream from block `counter` on: eight blocks at a time, then four, then the
    /// rest one block at a time.
    static func xor(_ message: inout MutableRawSpan, key: InlineArray<8, UInt32>, counter: UInt32, nonce: (UInt32, UInt32, UInt32)) {
        let c = constants
        let count = message.byteCount
        var offset = 0
        var blockCounter = counter
        let k0 = SIMD4(repeating: key[0]), k1 = SIMD4(repeating: key[1]), k2 = SIMD4(repeating: key[2]), k3 = SIMD4(repeating: key[3])
        let k4 = SIMD4(repeating: key[4]), k5 = SIMD4(repeating: key[5]), k6 = SIMD4(repeating: key[6]), k7 = SIMD4(repeating: key[7])
        let n0 = SIMD4(repeating: nonce.0), n1 = SIMD4(repeating: nonce.1), n2 = SIMD4(repeating: nonce.2)
        let c0 = SIMD4(repeating: c.0), c1 = SIMD4(repeating: c.1), c2 = SIMD4(repeating: c.2), c3 = SIMD4(repeating: c.3)
        let lanes = SIMD4<UInt32>(0, 1, 2, 3)
        // Eight blocks at a time, then four: each quarter round's steps depend on the one before, and four
        // blocks' worth (four chains) kept the vector pipes half busy. The 16 state words of 8 lanes are two
        // registers each: all 32, so the constants and key are splatted again at the end.
        let eightLanes = SIMD8<UInt32>(0, 1, 2, 3, 4, 5, 6, 7)
        while count &- offset >= 512 {
            let counters = SIMD8(repeating: blockCounter) &+ eightLanes
            var x0 = SIMD8(repeating: c.0), x1 = SIMD8(repeating: c.1), x2 = SIMD8(repeating: c.2), x3 = SIMD8(repeating: c.3)
            var x4 = SIMD8(repeating: key[0]), x5 = SIMD8(repeating: key[1]), x6 = SIMD8(repeating: key[2]), x7 = SIMD8(repeating: key[3])
            var x8 = SIMD8(repeating: key[4]), x9 = SIMD8(repeating: key[5]), x10 = SIMD8(repeating: key[6]), x11 = SIMD8(repeating: key[7])
            var x12 = counters, x13 = SIMD8(repeating: nonce.0), x14 = SIMD8(repeating: nonce.1), x15 = SIMD8(repeating: nonce.2)
            for _ in 0..<10 {
                x0 &+= x4; x12 ^= x0; x12 = rotate(x12, 16); x8 &+= x12; x4 ^= x8; x4 = rotate(x4, 12)
                x0 &+= x4; x12 ^= x0; x12 = rotate(x12, 8); x8 &+= x12; x4 ^= x8; x4 = rotate(x4, 7)
                x1 &+= x5; x13 ^= x1; x13 = rotate(x13, 16); x9 &+= x13; x5 ^= x9; x5 = rotate(x5, 12)
                x1 &+= x5; x13 ^= x1; x13 = rotate(x13, 8); x9 &+= x13; x5 ^= x9; x5 = rotate(x5, 7)
                x2 &+= x6; x14 ^= x2; x14 = rotate(x14, 16); x10 &+= x14; x6 ^= x10; x6 = rotate(x6, 12)
                x2 &+= x6; x14 ^= x2; x14 = rotate(x14, 8); x10 &+= x14; x6 ^= x10; x6 = rotate(x6, 7)
                x3 &+= x7; x15 ^= x3; x15 = rotate(x15, 16); x11 &+= x15; x7 ^= x11; x7 = rotate(x7, 12)
                x3 &+= x7; x15 ^= x3; x15 = rotate(x15, 8); x11 &+= x15; x7 ^= x11; x7 = rotate(x7, 7)
                x0 &+= x5; x15 ^= x0; x15 = rotate(x15, 16); x10 &+= x15; x5 ^= x10; x5 = rotate(x5, 12)
                x0 &+= x5; x15 ^= x0; x15 = rotate(x15, 8); x10 &+= x15; x5 ^= x10; x5 = rotate(x5, 7)
                x1 &+= x6; x12 ^= x1; x12 = rotate(x12, 16); x11 &+= x12; x6 ^= x11; x6 = rotate(x6, 12)
                x1 &+= x6; x12 ^= x1; x12 = rotate(x12, 8); x11 &+= x12; x6 ^= x11; x6 = rotate(x6, 7)
                x2 &+= x7; x13 ^= x2; x13 = rotate(x13, 16); x8 &+= x13; x7 ^= x8; x7 = rotate(x7, 12)
                x2 &+= x7; x13 ^= x2; x13 = rotate(x13, 8); x8 &+= x13; x7 ^= x8; x7 = rotate(x7, 7)
                x3 &+= x4; x14 ^= x3; x14 = rotate(x14, 16); x9 &+= x14; x4 ^= x9; x4 = rotate(x4, 12)
                x3 &+= x4; x14 ^= x3; x14 = rotate(x14, 8); x9 &+= x14; x4 ^= x9; x4 = rotate(x4, 7)
            }
            x0 &+= SIMD8(repeating: c.0); x1 &+= SIMD8(repeating: c.1); x2 &+= SIMD8(repeating: c.2); x3 &+= SIMD8(repeating: c.3)
            x4 &+= SIMD8(repeating: key[0]); x5 &+= SIMD8(repeating: key[1]); x6 &+= SIMD8(repeating: key[2]); x7 &+= SIMD8(repeating: key[3])
            x8 &+= SIMD8(repeating: key[4]); x9 &+= SIMD8(repeating: key[5]); x10 &+= SIMD8(repeating: key[6]); x11 &+= SIMD8(repeating: key[7])
            x12 &+= counters; x13 &+= SIMD8(repeating: nonce.0); x14 &+= SIMD8(repeating: nonce.1); x15 &+= SIMD8(repeating: nonce.2)
            // Blocks 0–3 in the low halves, 4–7 in the high halves.
            xorTransposed(&message, offset, x0.lowHalf, x1.lowHalf, x2.lowHalf, x3.lowHalf)
            xorTransposed(&message, offset &+ 16, x4.lowHalf, x5.lowHalf, x6.lowHalf, x7.lowHalf)
            xorTransposed(&message, offset &+ 32, x8.lowHalf, x9.lowHalf, x10.lowHalf, x11.lowHalf)
            xorTransposed(&message, offset &+ 48, x12.lowHalf, x13.lowHalf, x14.lowHalf, x15.lowHalf)
            xorTransposed(&message, offset &+ 256, x0.highHalf, x1.highHalf, x2.highHalf, x3.highHalf)
            xorTransposed(&message, offset &+ 272, x4.highHalf, x5.highHalf, x6.highHalf, x7.highHalf)
            xorTransposed(&message, offset &+ 288, x8.highHalf, x9.highHalf, x10.highHalf, x11.highHalf)
            xorTransposed(&message, offset &+ 304, x12.highHalf, x13.highHalf, x14.highHalf, x15.highHalf)
            offset &+= 512
            blockCounter &+= 8
        }
        while count &- offset >= 256 {
            let counters = SIMD4(repeating: blockCounter) &+ lanes
            var x0 = c0, x1 = c1, x2 = c2, x3 = c3
            var x4 = k0, x5 = k1, x6 = k2, x7 = k3, x8 = k4, x9 = k5, x10 = k6, x11 = k7
            var x12 = counters, x13 = n0, x14 = n1, x15 = n2
            for _ in 0..<10 {
                // Columns.
                x0 &+= x4; x12 ^= x0; x12 = rotate(x12, 16); x8 &+= x12; x4 ^= x8; x4 = rotate(x4, 12)
                x0 &+= x4; x12 ^= x0; x12 = rotate(x12, 8); x8 &+= x12; x4 ^= x8; x4 = rotate(x4, 7)
                x1 &+= x5; x13 ^= x1; x13 = rotate(x13, 16); x9 &+= x13; x5 ^= x9; x5 = rotate(x5, 12)
                x1 &+= x5; x13 ^= x1; x13 = rotate(x13, 8); x9 &+= x13; x5 ^= x9; x5 = rotate(x5, 7)
                x2 &+= x6; x14 ^= x2; x14 = rotate(x14, 16); x10 &+= x14; x6 ^= x10; x6 = rotate(x6, 12)
                x2 &+= x6; x14 ^= x2; x14 = rotate(x14, 8); x10 &+= x14; x6 ^= x10; x6 = rotate(x6, 7)
                x3 &+= x7; x15 ^= x3; x15 = rotate(x15, 16); x11 &+= x15; x7 ^= x11; x7 = rotate(x7, 12)
                x3 &+= x7; x15 ^= x3; x15 = rotate(x15, 8); x11 &+= x15; x7 ^= x11; x7 = rotate(x7, 7)
                // Diagonals.
                x0 &+= x5; x15 ^= x0; x15 = rotate(x15, 16); x10 &+= x15; x5 ^= x10; x5 = rotate(x5, 12)
                x0 &+= x5; x15 ^= x0; x15 = rotate(x15, 8); x10 &+= x15; x5 ^= x10; x5 = rotate(x5, 7)
                x1 &+= x6; x12 ^= x1; x12 = rotate(x12, 16); x11 &+= x12; x6 ^= x11; x6 = rotate(x6, 12)
                x1 &+= x6; x12 ^= x1; x12 = rotate(x12, 8); x11 &+= x12; x6 ^= x11; x6 = rotate(x6, 7)
                x2 &+= x7; x13 ^= x2; x13 = rotate(x13, 16); x8 &+= x13; x7 ^= x8; x7 = rotate(x7, 12)
                x2 &+= x7; x13 ^= x2; x13 = rotate(x13, 8); x8 &+= x13; x7 ^= x8; x7 = rotate(x7, 7)
                x3 &+= x4; x14 ^= x3; x14 = rotate(x14, 16); x9 &+= x14; x4 ^= x9; x4 = rotate(x4, 12)
                x3 &+= x4; x14 ^= x3; x14 = rotate(x14, 8); x9 &+= x14; x4 ^= x9; x4 = rotate(x4, 7)
            }
            x0 &+= c0; x1 &+= c1; x2 &+= c2; x3 &+= c3
            x4 &+= k0; x5 &+= k1; x6 &+= k2; x7 &+= k3; x8 &+= k4; x9 &+= k5; x10 &+= k6; x11 &+= k7
            x12 &+= counters; x13 &+= n0; x14 &+= n1; x15 &+= n2
            // Lane b of word w is word w of block b: transpose each group of four words so block b's words
            // w through w + 3 are one vector, and XOR it at block b's offset.
            xorTransposed(&message, offset, x0, x1, x2, x3)
            xorTransposed(&message, offset &+ 16, x4, x5, x6, x7)
            xorTransposed(&message, offset &+ 32, x8, x9, x10, x11)
            xorTransposed(&message, offset &+ 48, x12, x13, x14, x15)
            offset &+= 256
            blockCounter &+= 4
        }
        while offset < count {
            let keystream = block(key: key, counter: blockCounter, nonce: nonce)
            let length = min(64, count &- offset)
            for index in 0..<length {
                let value = message.bytes.load(fromByteOffset: offset &+ index, as: UInt8.self) ^ keystream[index]
                message.storeBytes(of: value, toByteOffset: offset &+ index, as: UInt8.self)
            }
            offset &+= length
            blockCounter &+= 1
        }
    }

    /// XORs four words of four blocks into `message`: `a`, `b`, `c`, `d` hold words w to w + 3, lane b for
    /// block b; block b's 16 bytes go at `offset + 64b`. (The eight-block loop calls it once per half.)
    @inline(__always)
    static func xorTransposed(_ message: inout MutableRawSpan, _ offset: Int, _ a: SIMD4<UInt32>, _ b: SIMD4<UInt32>, _ c: SIMD4<UInt32>, _ d: SIMD4<UInt32>) {
        // A 4×4 transpose with constant lane picks, which compile to `zip`/`trn` shuffles.
        let ab01 = SIMD4(a[0], b[0], a[1], b[1])
        let cd01 = SIMD4(c[0], d[0], c[1], d[1])
        let ab23 = SIMD4(a[2], b[2], a[3], b[3])
        let cd23 = SIMD4(c[2], d[2], c[3], d[3])
        let block0 = SIMD4(ab01[0], ab01[1], cd01[0], cd01[1])
        let block1 = SIMD4(ab01[2], ab01[3], cd01[2], cd01[3])
        let block2 = SIMD4(ab23[0], ab23[1], cd23[0], cd23[1])
        let block3 = SIMD4(ab23[2], ab23[3], cd23[2], cd23[3])
        xor16(&message, offset, block0)
        xor16(&message, offset &+ 64, block1)
        xor16(&message, offset &+ 128, block2)
        xor16(&message, offset &+ 192, block3)
    }

    @inline(__always)
    static func xor16(_ message: inout MutableRawSpan, _ offset: Int, _ keystream: SIMD4<UInt32>) {
        // Unsafe: unchecked 16-byte load and store. Safe: callers stay within the 256 or 512 bytes checked by the loop.
        let words = unsafe message.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD4<UInt32>.self)
        #if _endian(little)
        let value = words ^ keystream
        #else
        let value = words ^ keystream.byteSwapped
        #endif
        unsafe message.storeBytes(of: value, toUncheckedByteOffset: offset, as: SIMD4<UInt32>.self)
    }
}

extension SIMD4 where Scalar == UInt32 {
    var byteSwapped: Self { Self(self[0].byteSwapped, self[1].byteSwapped, self[2].byteSwapped, self[3].byteSwapped) }
}

/// Poly1305 (RFC 8439, 2.5) in radix 2^64, as OpenSSL's 64-bit code: h in two 64-bit limbs and a few bits
/// more, so a block is four 64 × 64 → 128-bit products and two 64-bit ones. (44-bit limbs, poly1305-donna-64,
/// took nine 128-bit products.)
struct Poly1305 {
    /// r, clamped, and `s1` = r1 × 5/4: r1's low 2 bits are clamped to zero, so the products that pass 2^130
    /// fold back as r1 + r1 >> 2.
    var r0: UInt64, r1: UInt64, s1: UInt64
    /// The accumulator: h0 + h1 × 2^64 + h2 × 2^128, h2 small.
    var h0: UInt64 = 0, h1: UInt64 = 0, h2: UInt64 = 0
    var pad0: UInt64, pad1: UInt64

    init(key: InlineArray<64, UInt8>) {
        func word(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(key[offset &+ index]) &<< UInt64(8 &* index) }
            return value
        }
        r0 = word(0) & 0x0FFF_FFFC_0FFF_FFFF
        r1 = word(8) & 0x0FFF_FFFC_0FFF_FFFC
        s1 = r1 &+ (r1 &>> 2)
        pad0 = word(16)
        pad1 = word(24)
    }

    /// Adds full 16-byte blocks of `data`, and a last partial block zero-padded (RFC 8439, 2.8).
    @inline(__always)
    mutating func blocks(_ data: RawSpan) {
        var offset = 0
        let count = data.byteCount
        var h0 = h0, h1 = h1, h2 = h2
        let r0 = r0, r1 = r1, s1 = s1
        @inline(__always)
        func process(_ t0: UInt64, _ t1: UInt64) {
            // h += the block, with 2^128 for its padding bit.
            let (a0, c0) = h0.addingReportingOverflow(t0)
            let (a1, c1) = h1.addingReportingOverflow(t1)
            let (b1, c2) = a1.addingReportingOverflow(c0 ? 1 : 0)
            h2 &+= 1 &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            // h × r, folding the products past 2^130 back (2^130 ≡ 5).
            let d0 = UInt128(a0) &* UInt128(r0) &+ UInt128(b1) &* UInt128(s1)
            let d1 = UInt128(a0) &* UInt128(r1) &+ UInt128(b1) &* UInt128(r0) &+ UInt128(h2 &* s1) &+ (d0 &>> 64)
            let top = h2 &* r0 &+ UInt64(truncatingIfNeeded: d1 &>> 64)
            // Partial reduction: top × 2^128 = (top >> 2) × 2^130 + (top & 3) × 2^128, and 2^130 ≡ 5.
            let fold = (top &>> 2) &+ (top & ~3)
            h2 = top & 3
            let (e0, c3) = UInt64(truncatingIfNeeded: d0).addingReportingOverflow(fold)
            let (e1, c4) = UInt64(truncatingIfNeeded: d1).addingReportingOverflow(c3 ? 1 : 0)
            h0 = e0
            h1 = e1
            h2 &+= c4 ? 1 : 0
        }
        while count &- offset >= 16 {
            // Unsafe: unchecked loads. Safe: 16 bytes remain, checked by the loop.
            let t0 = UInt64(littleEndian: unsafe data.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt64.self))
            let t1 = UInt64(littleEndian: unsafe data.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 8, as: UInt64.self))
            process(t0, t1)
            offset &+= 16
        }
        if offset < count {
            var block = InlineArray<16, UInt8>(repeating: 0)
            for index in 0..<(count &- offset) { block[index] = data.load(fromByteOffset: offset &+ index, as: UInt8.self) }
            var t0: UInt64 = 0, t1: UInt64 = 0
            for index in 0..<8 {
                t0 |= UInt64(block[index]) &<< UInt64(8 &* index)
                t1 |= UInt64(block[8 &+ index]) &<< UInt64(8 &* index)
            }
            process(t0, t1)
        }
        self.h0 = h0
        self.h1 = h1
        self.h2 = h2
    }

    /// The AEAD construction's MAC input: the additional data, the ciphertext, each zero-padded to 16 bytes,
    /// then both lengths.
    mutating func authenticate(aad: RawSpan, ciphertext: RawSpan) {
        blocks(aad)
        blocks(ciphertext)
        var lengths = InlineArray<16, UInt8>(repeating: 0)
        for index in 0..<8 {
            lengths[index] = UInt8(truncatingIfNeeded: UInt64(aad.byteCount) &>> UInt64(8 &* index))
            lengths[8 &+ index] = UInt8(truncatingIfNeeded: UInt64(ciphertext.byteCount) &>> UInt64(8 &* index))
        }
        blocks(lengths.span.bytes)
    }

    /// The tag: h reduced modulo 2^130 - 5, plus the pad, modulo 2^128.
    func tag() -> InlineArray<16, UInt8> {
        // h is below 2^130 + a little (h2 ≤ 4); h - p = h + 5 - 2^130: if that reaches 2^130, take it.
        let (g0, c0) = h0.addingReportingOverflow(5)
        let (g1, c1) = h1.addingReportingOverflow(c0 ? 1 : 0)
        let g2 = h2 &+ (c1 ? 1 : 0)
        // All ones if g2 reached 4 (h ≥ p), else zero; selects without branching.
        let mask = 0 &- (g2 &>> 2)
        let low = (h0 & ~mask) | (g0 & mask)
        let high = (h1 & ~mask) | (g1 & mask)
        let (sum0, overflow) = low.addingReportingOverflow(pad0)
        let sum1 = high &+ pad1 &+ (overflow ? 1 : 0)
        var tag = InlineArray<16, UInt8>(repeating: 0)
        for index in 0..<8 {
            tag[index] = UInt8(truncatingIfNeeded: sum0 &>> UInt64(8 &* index))
            tag[8 &+ index] = UInt8(truncatingIfNeeded: sum1 &>> UInt64(8 &* index))
        }
        return tag
    }
}
