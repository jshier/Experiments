internal import Bytes
#if HardwareCrypto && arch(arm64) && !Portable
internal import CBytesCrypto
#endif

// AES (FIPS 197) encryption with 128-, 192-, and 256-bit keys, and counter mode (NIST SP 800-38A) in both of
// the counter layouts formats use: a 128-bit little-endian counter (WinZip AES) and a 32-bit big-endian one in
// the last four bytes (GCM). Only encryption: counter mode and GCM never run the inverse cipher.
//
// On Apple silicon (the `HardwareCrypto` trait, the default) each round is one `aese` + `aesmc` pair through
// `CBytesCrypto`, eight blocks interleaved so the pipelined AES units stay busy. Elsewhere, and in `Portable`
// builds, the rounds are computed in plain Swift without tables: SubBytes is the field inversion and affine map
// evaluated on all sixteen bytes at once with vector arithmetic, so no memory access depends on the key or data
// (table-based AES leaks its key through cache timing). That path is correct and constant-time, and slow.

/// An AES key schedule, for encrypting blocks: counter mode and GCM. 128-, 192-, or 256-bit keys.
///
/// ```swift
/// let aes = AES(key: key)                                // 16, 24, or 32 bytes
/// var counter = AES.Counter(littleEndianFrom: 1)         // WinZip AES's
/// aes.counterMode(ciphertext, into: &plaintext, counter: &counter)
/// ```
public struct AES: Sendable {
    /// The round keys: one per round and one more, 11, 13, or 15.
    @usableFromInline var roundKeys: InlineArray<15, SIMD16<UInt8>>
    /// The number of rounds: 10, 12, or 14.
    public let rounds: Int

    /// A key schedule for `key`.
    ///
    /// - Parameter key: 16, 24, or 32 bytes.
    /// - Precondition: `key` is 16, 24, or 32 bytes.
    public init(key: RawSpan) {
        let wordCount = key.byteCount / 4
        precondition(key.byteCount == 16 || key.byteCount == 24 || key.byteCount == 32, "AES keys are 16, 24, or 32 bytes")
        rounds = wordCount &+ 6
        // FIPS 197, 5.2: words of the expanded key, little-endian in memory order (byte 0 lowest).
        var words = InlineArray<60, UInt32>(repeating: 0)
        for index in 0..<wordCount {
            words[index] = UInt32(littleEndian: key.load(fromByteOffset: 4 &* index, as: UInt32.self))
        }
        var roundConstant: UInt32 = 1
        for index in wordCount..<(4 &* (rounds &+ 1)) {
            var word = words[index &- 1]
            if index % wordCount == 0 {
                // RotWord, SubWord, then the round constant in the first byte.
                word = AES.subWord(word.rotatedRight(by: 8)) ^ roundConstant
                roundConstant = UInt32(AES.double(UInt8(truncatingIfNeeded: roundConstant)))
            } else if wordCount > 6 && index % wordCount == 4 {
                word = AES.subWord(word)
            }
            words[index] = words[index &- wordCount] ^ word
        }
        var keys = InlineArray<15, SIMD16<UInt8>>(repeating: .zero)
        for round in 0...rounds {
            let block = SIMD4(words[4 &* round], words[4 &* round &+ 1], words[4 &* round &+ 2], words[4 &* round &+ 3])
            keys[round] = SIMD16<UInt8>(truncatingIfNeeded: SIMD16<UInt32>(
                block[0], block[0] >> 8, block[0] >> 16, block[0] >> 24, block[1], block[1] >> 8, block[1] >> 16, block[1] >> 24,
                block[2], block[2] >> 8, block[2] >> 16, block[2] >> 24, block[3], block[3] >> 8, block[3] >> 16, block[3] >> 24
            ))
        }
        roundKeys = keys
    }

    /// The S-box applied to each byte of `word`, constant-time.
    static func subWord(_ word: UInt32) -> UInt32 {
        let lanes = SIMD16<UInt8>(truncatingIfNeeded: SIMD16<UInt32>(word, word >> 8, word >> 16, word >> 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let substituted = AES.substitute(lanes)
        return UInt32(substituted[0]) | UInt32(substituted[1]) << 8 | UInt32(substituted[2]) << 16 | UInt32(substituted[3]) << 24
    }

    /// `x × 2` in AES's field, GF(2⁸) modulo x⁸ + x⁴ + x³ + x + 1.
    @inline(__always)
    static func double(_ x: UInt8) -> UInt8 {
        (x &<< 1) ^ (0x1B & (0 &- (x &>> 7)))
    }

    // MARK: Encryption

    /// Encrypts one 16-byte block.
    ///
    /// - Parameter block: The plaintext block, byte 0 in lane 0.
    /// - Returns: The ciphertext block.
    public func encrypt(_ block: SIMD16<UInt8>) -> SIMD16<UInt8> {
        #if HardwareCrypto && arch(arm64) && !Portable
        var state = block
        for round in 0..<(rounds &- 1) {
            state = bytes_aes_round(state, roundKeys[round])
        }
        return bytes_aese(state, roundKeys[rounds &- 1]) ^ roundKeys[rounds]
        #else
        return encryptPortably(block)
        #endif
    }

    /// The portable cipher: SubBytes by field arithmetic on all lanes, ShiftRows as a constant shuffle,
    /// MixColumns with doublings and lane rotations.
    @usableFromInline
    package func encryptPortably(_ block: SIMD16<UInt8>) -> SIMD16<UInt8> {
        var state = block ^ roundKeys[0]
        for round in 1...rounds {
            state = AES.substitute(state)
            state = AES.shiftRows(state)
            if round < rounds { state = AES.mixColumns(state) }
            state ^= roundKeys[round]
        }
        return state
    }

    /// ShiftRows: row r (bytes r, r+4, r+8, r+12 of the column-major state) rotated left by r.
    @inline(__always)
    static func shiftRows(_ s: SIMD16<UInt8>) -> SIMD16<UInt8> {
        SIMD16(s[0], s[5], s[10], s[15], s[4], s[9], s[14], s[3], s[8], s[13], s[2], s[7], s[12], s[1], s[6], s[11])
    }

    /// MixColumns: each column times {02, 03, 01, 01} circulant, as `2a ⊕ 3b ⊕ c ⊕ d` per byte.
    @inline(__always)
    static func mixColumns(_ s: SIMD16<UInt8>) -> SIMD16<UInt8> {
        // Each byte's column neighbours: rotations by one, two, and three within each 4-byte column.
        let r1 = SIMD16(s[1], s[2], s[3], s[0], s[5], s[6], s[7], s[4], s[9], s[10], s[11], s[8], s[13], s[14], s[15], s[12])
        let r2 = SIMD16(s[2], s[3], s[0], s[1], s[6], s[7], s[4], s[5], s[10], s[11], s[8], s[9], s[14], s[15], s[12], s[13])
        let r3 = SIMD16(s[3], s[0], s[1], s[2], s[7], s[4], s[5], s[6], s[11], s[8], s[9], s[10], s[15], s[12], s[13], s[14])
        let sum = s ^ r1
        return doubled(sum) ^ r1 ^ r2 ^ r3
    }

    /// Each lane doubled in the field.
    @inline(__always)
    static func doubled(_ x: SIMD16<UInt8>) -> SIMD16<UInt8> {
        // The high bit spread to a mask (0 or 0xFF) by an arithmetic shift, without a branch or comparison.
        let high = SIMD16<UInt8>(truncatingIfNeeded: SIMD16<Int8>(truncatingIfNeeded: x) &>> 7)
        return (x &<< 1) ^ (high & 0x1B)
    }

    /// Each lane times each lane of `b` in the field, constant-time: eight shift-and-add steps on masks.
    @inline(__always)
    static func multiply(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>) -> SIMD16<UInt8> {
        var product = SIMD16<UInt8>.zero
        var a = a
        var b = b
        for _ in 0..<8 {
            let low = SIMD16<UInt8>(truncatingIfNeeded: SIMD16<Int8>(truncatingIfNeeded: b &<< 7) &>> 7)
            product ^= a & low
            a = doubled(a)
            b &>>= 1
        }
        return product
    }

    /// SubBytes on all lanes: the inverse (x²⁵⁴, which maps 0 to 0) then the affine map, by arithmetic alone.
    static func substitute(_ x: SIMD16<UInt8>) -> SIMD16<UInt8> {
        let x2 = multiply(x, x)
        let x3 = multiply(x2, x)
        let x6 = multiply(x3, x3)
        let x12 = multiply(x6, x6)
        let x15 = multiply(x12, x3)
        let x30 = multiply(x15, x15)
        let x60 = multiply(x30, x30)
        let x120 = multiply(x60, x60)
        let x126 = multiply(x120, x6)
        let x127 = multiply(x126, x)
        let inverse = multiply(x127, x127) // x²⁵⁴
        // The affine map: b ⊕ rotl(b, 1) ⊕ rotl(b, 2) ⊕ rotl(b, 3) ⊕ rotl(b, 4) ⊕ 0x63.
        @inline(__always) func rotl(_ v: SIMD16<UInt8>, _ n: UInt8) -> SIMD16<UInt8> { (v &<< n) | (v &>> (8 &- n)) }
        return inverse ^ rotl(inverse, 1) ^ rotl(inverse, 2) ^ rotl(inverse, 3) ^ rotl(inverse, 4) ^ 0x63
    }

    // MARK: Counter mode

    /// A counter block for ``counterMode(_:into:counter:)``: its next value, and how it counts.
    public struct Counter: Sendable {
        /// How the block counts.
        @usableFromInline enum Layout: Sendable {
            /// The whole block, a 128-bit little-endian counter (WinZip).
            case littleEndian128
            /// The last four bytes, big-endian, wrapping (GCM).
            case bigEndian32
            /// The last eight bytes, big-endian, wrapping without a carry into the first eight: CommonCrypto's CTR
            /// mode (`kCCModeOptionCTR_BE`; checked: a counter at 2⁶⁴ − 1 goes to 0 with the first half unchanged),
            /// which Apple Encrypted Archives use.
            case bigEndian64
        }

        /// The next counter block, in memory order.
        @usableFromInline var block: SIMD2<UInt64>
        @usableFromInline let layout: Layout
        /// Keystream bytes made but not yet used, from a call that ended mid-block.
        @usableFromInline var pending = SIMD16<UInt8>.zero
        @usableFromInline var pendingCount = 0

        /// A 128-bit little-endian counter starting at `value`: WinZip AES's (which starts at 1).
        ///
        /// - Parameter value: The first counter value.
        @inlinable
        public init(littleEndianFrom value: UInt64) {
            block = SIMD2(value.littleEndian, 0)
            layout = .littleEndian128
        }

        /// A block whose last four bytes count big-endian, wrapping: GCM's (`J0 + 1` onward).
        ///
        /// - Parameter block: The first counter block, 16 bytes.
        /// - Precondition: `block` is 16 bytes.
        @inlinable
        public init(bigEndian32BitCounterIn block: RawSpan) {
            precondition(block.byteCount == 16, "A counter block is 16 bytes")
            self.block = SIMD2(block.load(fromByteOffset: 0, as: UInt64.self), block.load(fromByteOffset: 8, as: UInt64.self))
            layout = .bigEndian32
        }

        /// A block whose last eight bytes count big-endian, wrapping without a carry into the first eight:
        /// CommonCrypto's CTR mode (`kCCModeOptionCTR_BE`), which Apple Encrypted Archives use from an IV their key
        /// derivation gives.
        ///
        /// - Parameter block: The first counter block, 16 bytes.
        /// - Precondition: `block` is 16 bytes.
        @inlinable
        public init(bigEndian64BitCounterIn block: RawSpan) {
            precondition(block.byteCount == 16, "A counter block is 16 bytes")
            self.block = SIMD2(block.load(fromByteOffset: 0, as: UInt64.self), block.load(fromByteOffset: 8, as: UInt64.self))
            layout = .bigEndian64
        }

        /// The current block as bytes, then advances by one.
        @inlinable @inline(__always)
        mutating func next() -> SIMD16<UInt8> {
            let current = bitCast(block, to: SIMD16<UInt8>.self)
            switch layout {
            case .littleEndian128:
                let low = UInt64(littleEndian: block[0]) &+ 1
                block[0] = low.littleEndian
                if low == 0 { block[1] = (UInt64(littleEndian: block[1]) &+ 1).littleEndian }
            case .bigEndian32:
                // The last four bytes: the high 32 bits of the second word, big-endian.
                let word = UInt32(bigEndian: UInt32(truncatingIfNeeded: block[1] &>> 32)) &+ 1
                block[1] = block[1] & 0xFFFF_FFFF | UInt64(word.bigEndian) &<< 32
            case .bigEndian64:
                // The second word, big-endian, wrapping.
                block[1] = (UInt64(bigEndian: block[1]) &+ 1).bigEndian
            }
            return current
        }
    }

    /// XORs `input` with the keystream from `counter` into `output`: counter-mode encryption and decryption
    /// (the same operation). The counter advances past the blocks used; a call that ends mid-block keeps the
    /// rest of that block's keystream for the next call, so a stream can be processed in pieces of any size.
    ///
    /// - Parameters:
    ///   - input: The bytes to encrypt or decrypt.
    ///   - output: Where the result goes, at least as long as `input` (it may be `input`'s own memory, read
    ///     through another span, only if they coincide exactly: each block is read before it's written).
    ///   - counter: The counter, advanced.
    /// - Precondition: `output` holds at least `input.byteCount` bytes.
    public func counterMode(_ input: RawSpan, into output: inout MutableRawSpan, counter: inout Counter) {
        precondition(output.byteCount >= input.byteCount, "The output is shorter than the input")
        // Unsafe: raw pointers for the loads and stores. Safe: every access is within `input.byteCount` bytes of
        // both (the output is at least as long, checked above), and the pointers don't outlive the closures.
        // (Checked, the 16 loads and stores per eight blocks were 27 compares and 24 branches of 400 instructions.)
        input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                unsafe counterMode(source.baseAddress, target.baseAddress, count: source.count, counter: &counter)
            }
        }
    }

    /// Encrypts or decrypts `bytes` in place with the keystream from `counter`, as
    /// ``counterMode(_:into:counter:)``.
    ///
    /// - Parameters:
    ///   - bytes: The bytes, replaced by the result.
    ///   - counter: The counter, advanced.
    public func counterMode(_ bytes: inout MutableRawSpan, counter: inout Counter) {
        // Unsafe: one raw buffer read and written in place. Safe: each block is loaded before it's stored, within
        // the buffer, and the pointer doesn't outlive the closure.
        bytes.withUnsafeMutableBytes { buffer in
            unsafe counterMode(UnsafeRawPointer(buffer.baseAddress), buffer.baseAddress, count: buffer.count, counter: &counter)
        }
    }

    /// Counter mode over `count` bytes of raw memory; `source` and `target` may be the same.
    @unsafe
    func counterMode(_ source: UnsafeRawPointer?, _ target: UnsafeMutableRawPointer?, count: Int, counter: inout Counter) {
        guard count > 0, let source = unsafe source, let target = unsafe target else { return }
        var offset = 0
        // Unsafe (throughout): the caller's `count` bytes at `source` and `target` (see the callers); every access
        // below is at an offset under `count`, a byte or a whole 16-byte block that fits.
        // Finish the keystream block a previous call started.
        while counter.pendingCount > 0 && offset < count {
            let byte = unsafe source.load(fromByteOffset: offset, as: UInt8.self) ^ counter.pending[16 &- counter.pendingCount]
            unsafe target.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
            counter.pendingCount &-= 1
            offset &+= 1
        }
        #if HardwareCrypto && arch(arm64) && !Portable
        // Unsafe: the same buffers, 128 bytes at a time while that many remain.
        offset = unsafe counterModeBatches(source, target, count: count, counter: &counter, from: offset)
        #endif
        while count &- offset >= 16 {
            let stream = encrypt(counter.next())
            let block = unsafe source.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self) ^ stream
            unsafe target.storeBytes(of: block, toByteOffset: offset, as: SIMD16<UInt8>.self)
            offset &+= 16
        }
        if offset < count {
            // A partial block: use what's needed, keep the rest.
            let stream = encrypt(counter.next())
            let used = count &- offset
            for index in 0..<used {
                let byte = unsafe source.load(fromByteOffset: offset &+ index, as: UInt8.self) ^ stream[index]
                unsafe target.storeBytes(of: byte, toByteOffset: offset &+ index, as: UInt8.self)
            }
            counter.pending = stream
            counter.pendingCount = 16 &- used
        }
    }

    #if HardwareCrypto && arch(arm64) && !Portable
    /// Counter mode eight blocks at a time from `start`, while 128 bytes remain; returns where it stopped.
    ///
    /// Eight independent `aese`/`aesmc` chains keep the AES units' pipelines full. The round keys are copied
    /// into locals and the rounds written out, so keys and states stay in vector registers (8 states and 15 keys
    /// of 32), and each counter block is one vector add from the batch's first: in a loop over `rounds` with
    /// keys read from the schedule, the states went to the stack every round, 7.5x slower than CommonCrypto.
    @unsafe @inline(never)
    func counterModeBatches(
        _ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer, count: Int, counter: inout Counter, from start: Int
    ) -> Int {
        var offset = start
        let keys = roundKeys
        let k0 = keys[0], k1 = keys[1], k2 = keys[2], k3 = keys[3], k4 = keys[4], k5 = keys[5], k6 = keys[6], k7 = keys[7]
        let k8 = keys[8], k9 = keys[9], k10 = keys[10], k11 = keys[11], k12 = keys[12], k13 = keys[13], k14 = keys[14]
        let rounds = rounds
        while count &- offset >= 128 {
            var b0, b1, b2, b3, b4, b5, b6, b7: SIMD16<UInt8>
            switch counter.layout {
            case .bigEndian64:
                // The second word counts, wrapping; each block is the first word and a byte-swapped sum (one `rev`).
                let low = UInt64(bigEndian: counter.block[1])
                let high = counter.block[0]
                b0 = bitCast(SIMD2(high, low.bigEndian), to: SIMD16<UInt8>.self)
                b1 = bitCast(SIMD2(high, (low &+ 1).bigEndian), to: SIMD16<UInt8>.self)
                b2 = bitCast(SIMD2(high, (low &+ 2).bigEndian), to: SIMD16<UInt8>.self)
                b3 = bitCast(SIMD2(high, (low &+ 3).bigEndian), to: SIMD16<UInt8>.self)
                b4 = bitCast(SIMD2(high, (low &+ 4).bigEndian), to: SIMD16<UInt8>.self)
                b5 = bitCast(SIMD2(high, (low &+ 5).bigEndian), to: SIMD16<UInt8>.self)
                b6 = bitCast(SIMD2(high, (low &+ 6).bigEndian), to: SIMD16<UInt8>.self)
                b7 = bitCast(SIMD2(high, (low &+ 7).bigEndian), to: SIMD16<UInt8>.self)
                counter.block[1] = (low &+ 8).bigEndian
            case .littleEndian128:
                let low = UInt64(littleEndian: counter.block[0])
                if low <= UInt64.max &- 8 {
                    // The 128-bit little-endian counter as two native words (arm64 is little-endian).
                    let base = SIMD2(low, UInt64(littleEndian: counter.block[1]))
                    b0 = bitCast(base, to: SIMD16<UInt8>.self)
                    b1 = bitCast(base &+ SIMD2(1, 0), to: SIMD16<UInt8>.self)
                    b2 = bitCast(base &+ SIMD2(2, 0), to: SIMD16<UInt8>.self)
                    b3 = bitCast(base &+ SIMD2(3, 0), to: SIMD16<UInt8>.self)
                    b4 = bitCast(base &+ SIMD2(4, 0), to: SIMD16<UInt8>.self)
                    b5 = bitCast(base &+ SIMD2(5, 0), to: SIMD16<UInt8>.self)
                    b6 = bitCast(base &+ SIMD2(6, 0), to: SIMD16<UInt8>.self)
                    b7 = bitCast(base &+ SIMD2(7, 0), to: SIMD16<UInt8>.self)
                    counter.block[0] = (low &+ 8).littleEndian
                } else {
                    // A carry into the high word within the batch: block by block.
                    b0 = counter.next(); b1 = counter.next(); b2 = counter.next(); b3 = counter.next()
                    b4 = counter.next(); b5 = counter.next(); b6 = counter.next(); b7 = counter.next()
                }
            case .bigEndian32:
                // GCM's: the block's words byte-swapped to native, so the last is the counter; add, swap back.
                let native = bytes_rev32(bitCast(counter.block, to: SIMD16<UInt8>.self))
                b0 = bytes_rev32_words(native)
                b1 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 1))
                b2 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 2))
                b3 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 3))
                b4 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 4))
                b5 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 5))
                b6 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 6))
                b7 = bytes_rev32_words(native &+ SIMD4(0, 0, 0, 7))
                counter.block = bitCast(bytes_rev32_words(native &+ SIMD4(0, 0, 0, 8)), to: SIMD2<UInt64>.self)
            }
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k0)
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k1)
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k2)
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k3)
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k4)
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k5)
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k6)
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k7)
            AES.round8(&b0, &b1, &b2, &b3, &b4, &b5, &b6, &b7, k8)
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
            // Unsafe: unchecked loads and stores. Safe: `offset + 128 <= count` (the loop's condition).
            let source = unsafe input + offset, target = unsafe output + offset
            unsafe AES.finish(b0, lastKey, finalKey, source, target)
            unsafe AES.finish(b1, lastKey, finalKey, source + 16, target + 16)
            unsafe AES.finish(b2, lastKey, finalKey, source + 32, target + 32)
            unsafe AES.finish(b3, lastKey, finalKey, source + 48, target + 48)
            unsafe AES.finish(b4, lastKey, finalKey, source + 64, target + 64)
            unsafe AES.finish(b5, lastKey, finalKey, source + 80, target + 80)
            unsafe AES.finish(b6, lastKey, finalKey, source + 96, target + 96)
            unsafe AES.finish(b7, lastKey, finalKey, source + 112, target + 112)
            offset &+= 128
        }
        return offset
    }

    /// One middle round on eight blocks.
    @inline(__always)
    static func round8(
        _ b0: inout SIMD16<UInt8>, _ b1: inout SIMD16<UInt8>, _ b2: inout SIMD16<UInt8>, _ b3: inout SIMD16<UInt8>,
        _ b4: inout SIMD16<UInt8>, _ b5: inout SIMD16<UInt8>, _ b6: inout SIMD16<UInt8>, _ b7: inout SIMD16<UInt8>,
        _ key: SIMD16<UInt8>
    ) {
        b0 = bytes_aes_round(b0, key); b1 = bytes_aes_round(b1, key); b2 = bytes_aes_round(b2, key); b3 = bytes_aes_round(b3, key)
        b4 = bytes_aes_round(b4, key); b5 = bytes_aes_round(b5, key); b6 = bytes_aes_round(b6, key); b7 = bytes_aes_round(b7, key)
    }

    /// The last round on one block, XORed with the 16 bytes at `input` into `output`.
    @unsafe @inline(__always)
    static func finish(
        _ state: SIMD16<UInt8>, _ lastKey: SIMD16<UInt8>, _ finalKey: SIMD16<UInt8>,
        _ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer
    ) {
        // Unsafe: an unchecked 16-byte load and store. Safe: callers pass a block within their buffers (`input` may
        // be `output`: the load comes first).
        let block = unsafe input.loadUnaligned(as: SIMD16<UInt8>.self) ^ bytes_aese(state, lastKey) ^ finalKey
        unsafe output.storeBytes(of: block, as: SIMD16<UInt8>.self)
    }
    #endif
}
