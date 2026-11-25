public import Bytes

// RSA public keys and PKCS #1 v1.5 signature verification (RFC 8017, 8.2.2 and 9.2), in Swift: what Apple's `.xip`
// archives and older certificate chains (Apple Root CA, the Software Update CA) are signed with.
//
// Verification computes s^e mod n with Montgomery multiplication on 64-bit limbs, by product scanning (a column of
// a·b + q·n at a time, in an accumulator of three limbs), with a dedicated squaring, specialized for 16, 24, 32, 48, and
// 64 limbs (1024 to 4096 bits; other sizes run in the next one up, their top limbs zero). Everything lives in fixed-size
// `InlineArray`s on the stack: nothing allocates. Then the encoding EMSA-PKCS1-v1_5 would produce for the digest is
// built and compared with the result: the decrypted block isn't parsed, so no BER variant, missing NULL, or trailing
// garbage can be accepted. (Versions and measurements: Benchmarks/RESULTS-rsa.md.)
//
// Variable time: verification handles only public values (the key, the signature, the digest), so the arithmetic
// branches on them freely (the exponent's bits, the final subtractions, comparisons). Don't use this code with
// secrets.

/// RSA: public keys and PKCS #1 v1.5 signature verification.
///
/// ```swift
/// let key = try RSA.PublicKey(derRepresentation: der)            // SubjectPublicKeyInfo or PKCS #1 RSAPublicKey
/// guard key.isValidSignature(signature, for: message, digestAlgorithm: .sha256) else { … }
/// // A precomputed digest, as Apple's archives sign their table of contents' SHA-1:
/// guard key.isValidSignature(signature, digest: checksum, digestAlgorithm: .sha1) else { … }
/// ```
///
/// Moduli of 1024 to 4096 bits, and public exponents that are odd, at least 3, and fit 64 bits (65537 nearly always).
/// 1024-bit keys and SHA-1 are accepted for verifying old signatures, but are weak: 1024-bit moduli are within reach
/// of factoring, and SHA-1 collisions are practical. Verification allocates nothing and isn't constant-time (it
/// handles only public values). Signing, encryption, and RSA-PSS aren't implemented. Certificates signed with RSA
/// verify through ``X509Certificate/isSigned(by:)``.
public enum RSA {
    /// The hash a PKCS #1 v1.5 signature's digest was made with: the DigestInfo the signature encodes.
    public enum DigestAlgorithm: Sendable, Hashable, CaseIterable {
        /// SHA-1 (20 bytes). Weak: accept it only for existing signatures.
        case sha1
        /// SHA-256 (32 bytes).
        case sha256
        /// SHA-384 (48 bytes).
        case sha384
        /// SHA-512 (64 bytes).
        case sha512

        /// The digest's size in bytes.
        public var digestByteCount: Int {
            switch self {
            case .sha1: 20
            case .sha256: 32
            case .sha384: 48
            case .sha512: 64
            }
        }

        /// The algorithm of an X.509 signature algorithm identifier (`sha1WithRSAEncryption`, `sha256WithRSAEncryption`,
        /// `sha384WithRSAEncryption`, `sha512WithRSAEncryption`), or nil for any other.
        ///
        /// - Parameter signatureAlgorithm: The identifier, such as ``X509Certificate/signatureAlgorithm``.
        public init?(signatureAlgorithm: ASN1ObjectIdentifier) {
            switch signatureAlgorithm {
            case .sha1WithRSAEncryption: self = .sha1
            case .sha256WithRSAEncryption: self = .sha256
            case .sha384WithRSAEncryption: self = .sha384
            case .sha512WithRSAEncryption: self = .sha512
            default: return nil
            }
        }

        /// Hashes `message` into the start of `digest`.
        @inline(__always)
        func hash(_ message: RawSpan, into digest: inout InlineArray<64, UInt8>) {
            var span = digest.mutableSpan
            var output = MutableRawSpan(mutating: &span)
            switch self {
            case .sha1:
                var hash = SHA1()
                hash.update(message)
                hash.finalize(into: &output)
            case .sha256:
                var hash = SHA256()
                hash.update(message)
                hash.finalize(into: &output)
            case .sha384:
                var hash = SHA384()
                hash.update(message)
                hash.finalize(into: &output)
            case .sha512:
                var hash = SHA512()
                hash.update(message)
                hash.finalize(into: &output)
            }
        }

        /// The DER of DigestInfo up to the digest (RFC 8017, 9.2, note 1): SEQUENCE { SEQUENCE { the hash's OID,
        /// NULL }, OCTET STRING header }, in `prefix`'s first `count` bytes.
        @inline(__always)
        var digestInfoPrefix: (prefix: InlineArray<19, UInt8>, count: Int) {
            switch self {
            case .sha1:
                ([0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2B, 0x0E, 0x03, 0x02, 0x1A, 0x05, 0x00, 0x04, 0x14, 0, 0, 0, 0], 15)
            case .sha256:
                ([0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20], 19)
            case .sha384:
                ([0x30, 0x41, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30], 19)
            case .sha512:
                ([0x30, 0x51, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40], 19)
            }
        }
    }

    /// An RSA public key (n, e): a modulus of 1024 to 4096 bits and an odd exponent from 3 to 2⁶⁴ − 1.
    ///
    /// Making a key precomputes what verification needs (−n⁻¹ mod 2⁶⁴ and R² mod n, R = 2^(64·limbs)): about a third
    /// of a verification's work.
    public struct PublicKey: Sendable, Equatable {
        /// The smallest modulus accepted, in bits.
        public static var minimumModulusBitCount: Int { 1024 }
        /// The largest modulus accepted, in bits.
        public static var maximumModulusBitCount: Int { 4096 }

        /// n, least significant limb first; limbs from `limbCount` on are 0.
        let modulus: InlineArray<64, UInt64>
        /// R² mod n, R = 2^(64 · limbCount): a Montgomery product with it takes a value into Montgomery form.
        let rSquared: InlineArray<64, UInt64>
        /// −n⁻¹ mod 2⁶⁴.
        let negativeInverse: UInt64
        /// The limbs the arithmetic runs on: 16, 24, 32, 48, or 64.
        let limbCount: Int
        /// e.
        public let publicExponent: UInt64
        /// The modulus' size in bits (its highest set bit's position plus one): 2048 for a 2048-bit key.
        public let modulusBitCount: Int

        /// The size of a signature (and of the modulus) in bytes.
        public var modulusByteCount: Int { (modulusBitCount &+ 7) &>> 3 }

        /// A key from its modulus and exponent, big-endian magnitudes (leading zeros allowed).
        ///
        /// - Parameters:
        ///   - modulus: n: odd, 1024 to 4096 bits.
        ///   - publicExponent: e: odd, at least 3, at most 2⁶⁴ − 1.
        /// - Throws: ``BytesError/invalidValue`` for a modulus or exponent outside those ranges.
        public init(modulus: RawSpan, publicExponent: RawSpan) throws(BytesError) {
            var start = 0
            while start < modulus.byteCount, modulus.byteOffsetLoad(start) == 0 {
                start &+= 1
            }
            let n = modulus.extracting(droppingFirst: start)
            start = 0
            while start < publicExponent.byteCount, publicExponent.byteOffsetLoad(start) == 0 {
                start &+= 1
            }
            let e = publicExponent.extracting(droppingFirst: start)

            guard e.byteCount >= 1, e.byteCount <= 8 else { throw .invalidValue }
            var exponent: UInt64 = 0
            for index in 0..<e.byteCount {
                exponent = exponent &<< 8 | UInt64(e.byteOffsetLoad(index))
            }
            guard exponent >= 3, exponent & 1 == 1, n.byteCount >= 1 else { throw .invalidValue }
            let bits = n.byteCount &* 8 &- n.byteOffsetLoad(0).leadingZeroBitCount
            guard bits >= Self.minimumModulusBitCount, bits <= Self.maximumModulusBitCount,
                  n.byteOffsetLoad(n.byteCount &- 1) & 1 == 1 else { throw .invalidValue }

            let words: InlineArray<64, UInt64> = RSALimbs.read(bigEndian: n)
            let limbs = RSALimbs.arithmeticLimbCount(forBits: bits)
            let inverse = RSALimbs.negativeInverse(words[0])
            let rSquared: InlineArray<64, UInt64> = switch limbs {
            case 16: RSAModulus<16>.rSquared(words, inverse, bits: bits)
            case 24: RSAModulus<24>.rSquared(words, inverse, bits: bits)
            case 32: RSAModulus<32>.rSquared(words, inverse, bits: bits)
            case 48: RSAModulus<48>.rSquared(words, inverse, bits: bits)
            default: RSAModulus<64>.rSquared(words, inverse, bits: bits)
            }
            self.modulus = words
            self.rSquared = rSquared
            negativeInverse = inverse
            limbCount = limbs
            self.publicExponent = exponent
            modulusBitCount = bits
        }

        /// A key from DER: a SubjectPublicKeyInfo naming `rsaEncryption` (with its `NULL` parameters, as RFC 3279
        /// requires), or a PKCS #1 RSAPublicKey, SEQUENCE { INTEGER n, INTEGER e }.
        ///
        /// - Parameter derRepresentation: The DER, and nothing after it.
        /// - Throws: ``BytesError`` for malformed or non-minimal DER, another algorithm, or what
        ///   ``init(modulus:publicExponent:)`` throws.
        public init(derRepresentation: RawSpan) throws(BytesError) {
            var outer = AlignedBytesReader(derRepresentation)
            var sequence = try AlignedBytesReader(outer.readASN1Contents(.sequence))
            try outer.expectASN1End()
            if sequence.nextASN1Tag == .integer {
                let n = try sequence.readASN1UnsignedInteger()
                let e = try sequence.readASN1UnsignedInteger()
                try sequence.expectASN1End()
                try self.init(modulus: n, publicExponent: e)
                return
            }
            var algorithm = try AlignedBytesReader(sequence.readASN1Contents(.sequence))
            guard try ASN1ObjectIdentifier.rsaEncryption.matches(algorithm.readASN1Contents(.objectIdentifier)),
                  try algorithm.readASN1Contents(.null).byteCount == 0 else { throw .invalidValue }
            try algorithm.expectASN1End()
            var key = try AlignedBytesReader(sequence.readASN1BitString())
            try sequence.expectASN1End()
            var values = try AlignedBytesReader(key.readASN1Contents(.sequence))
            try key.expectASN1End()
            let n = try values.readASN1UnsignedInteger()
            let e = try values.readASN1UnsignedInteger()
            try values.expectASN1End()
            try self.init(modulus: n, publicExponent: e)
        }

        /// A key from PEM: a "PUBLIC KEY" block (SubjectPublicKeyInfo, as `openssl rsa -pubout` writes) or an "RSA
        /// PUBLIC KEY" block (PKCS #1).
        ///
        /// - Parameter pemRepresentation: The PEM text.
        /// - Throws: ``BytesError/insufficientData`` if there's neither block, and what ``PEM`` and
        ///   ``init(derRepresentation:)`` throw.
        public init(pemRepresentation: String) throws(BytesError) {
            // Bound to a local first: `.span` of a throwing call's result crashes the LLVM verifier at -Onone
            // (~/Scratch/swift-bugs/28).
            if let der = try PEM.decodeAll(pemRepresentation, label: "PUBLIC KEY").first {
                try self.init(derRepresentation: der.span.bytes)
            } else {
                let der = try PEM.decode(pemRepresentation, label: "RSA PUBLIC KEY")
                try self.init(derRepresentation: der.span.bytes)
            }
        }

        /// The key of a certificate whose ``X509Certificate/publicKeyAlgorithm`` is `rsaEncryption`.
        ///
        /// - Parameter certificate: The certificate.
        /// - Throws: ``BytesError/invalidValue`` for another kind of key, and what ``init(derRepresentation:)``
        ///   throws.
        public init(certificate: borrowing X509Certificate) throws(BytesError) {
            guard certificate.publicKeyAlgorithm == .rsaEncryption else { throw .invalidValue }
            try self.init(derRepresentation: certificate.subjectPublicKeyInfo)
        }

        /// n, big-endian, ``modulusByteCount`` bytes.
        public var modulusBytes: [UInt8] {
            var bytes = [UInt8](repeating: 0, count: modulusByteCount)
            for index in 0..<bytes.count {
                let fromEnd = bytes.count &- 1 &- index
                bytes[index] = UInt8(truncatingIfNeeded: modulus[fromEnd &>> 3] &>> UInt64((fromEnd & 7) &* 8))
            }
            return bytes
        }

        /// PKCS #1's RSAPublicKey DER: SEQUENCE { INTEGER n, INTEGER e }.
        public var pkcs1DERRepresentation: [UInt8] {
            let n = modulusBytes
            var e = InlineArray<8, UInt8>(repeating: 0)
            for index in 0..<8 {
                e[index] = UInt8(truncatingIfNeeded: publicExponent &>> UInt64(56 &- 8 &* index))
            }
            var writer = DERWriter()
            writer.append(.sequence) { values in
                values.appendUnsignedInteger(n.span.bytes)
                values.appendUnsignedInteger(e.span.bytes)
            }
            return writer.bytes
        }

        /// SubjectPublicKeyInfo DER (`rsaEncryption`, `NULL` parameters): what ``init(derRepresentation:)`` reads.
        public var derRepresentation: [UInt8] {
            let key = pkcs1DERRepresentation
            var writer = DERWriter()
            writer.append(.sequence) { info in
                info.append(.sequence) { algorithm in
                    algorithm.append(.rsaEncryption)
                    algorithm.append(.null, contents: [UInt8]().span.bytes)
                }
                info.appendBitString(key.span.bytes)
            }
            return writer.bytes
        }

        /// A "PUBLIC KEY" PEM block of ``derRepresentation``.
        public var pemRepresentation: String {
            let der = derRepresentation
            return PEM.encode(der.span.bytes, label: "PUBLIC KEY")
        }

        /// Whether two keys have the same modulus and exponent.
        public static func ==(a: Self, b: Self) -> Bool {
            guard a.publicExponent == b.publicExponent, a.modulusBitCount == b.modulusBitCount else { return false }
            for index in 0..<a.limbCount where a.modulus[index] != b.modulus[index] {
                return false
            }
            return true
        }

        /// Whether `signature` is this key's RSASSA-PKCS1-v1_5 signature (RFC 8017, 8.2.2) of a message whose digest
        /// is `digest`.
        ///
        /// The signature must be exactly ``modulusByteCount`` bytes and below n; s^e mod n must equal, byte for byte,
        /// the encoding `00 01 FF … FF 00 ‖ DigestInfo(digestAlgorithm, digest)`, the DigestInfo DER with its `NULL`
        /// parameters. Allocates nothing.
        ///
        /// - Parameters:
        ///   - signature: The signature.
        ///   - digest: The message's digest: ``DigestAlgorithm/digestByteCount`` bytes.
        ///   - digestAlgorithm: The hash that made `digest`, which the signature names.
        /// - Returns: `true` if the signature is valid; `false` for any other signature, digest, or length.
        public func isValidSignature(_ signature: RawSpan, digest: RawSpan, digestAlgorithm: DigestAlgorithm) -> Bool {
            let k = modulusByteCount
            let (prefix, prefixCount) = digestAlgorithm.digestInfoPrefix
            let digestCount = digestAlgorithm.digestByteCount
            let encodedCount = prefixCount &+ digestCount
            guard digest.byteCount == digestCount, signature.byteCount == k, k >= encodedCount &+ 11 else { return false }
            // EM = 00 01 FF…FF 00 ‖ prefix ‖ digest, k bytes.
            var expected = InlineArray<512, UInt8>(repeating: 0xFF)
            expected[0] = 0
            expected[1] = 1
            let prefixStart = k &- encodedCount
            expected[prefixStart &- 1] = 0
            for index in 0..<prefixCount {
                expected[prefixStart &+ index] = prefix[index]
            }
            let digestStart = prefixStart &+ prefixCount
            for index in 0..<digestCount {
                expected[digestStart &+ index] = digest.byteOffsetLoad(index)
            }
            let encoded = expected.span.bytes.extracting(first: k)
            switch limbCount {
            case 16: return RSAModulus<16>.verify(signature, encoded, self)
            case 24: return RSAModulus<24>.verify(signature, encoded, self)
            case 32: return RSAModulus<32>.verify(signature, encoded, self)
            case 48: return RSAModulus<48>.verify(signature, encoded, self)
            default: return RSAModulus<64>.verify(signature, encoded, self)
            }
        }

        /// Whether `signature` is this key's RSASSA-PKCS1-v1_5 signature of `message`, hashed with
        /// `digestAlgorithm`.
        ///
        /// - Parameters:
        ///   - signature: The signature.
        ///   - message: The signed message.
        ///   - digestAlgorithm: The hash the signature was made with.
        /// - Returns: `true` if the signature is valid.
        public func isValidSignature(_ signature: RawSpan, for message: RawSpan, digestAlgorithm: DigestAlgorithm) -> Bool {
            var digest = InlineArray<64, UInt8>(repeating: 0)
            digestAlgorithm.hash(message, into: &digest)
            return isValidSignature(signature, digest: digest.span.bytes.extracting(first: digestAlgorithm.digestByteCount),
                                    digestAlgorithm: digestAlgorithm)
        }
    }
}

// MARK: - Arithmetic

/// Helpers on the 64-limb form keys store.
enum RSALimbs {
    /// The value of big-endian `bytes` (at most `8 × n` of them), least significant limb first: the keys' 64-limb
    /// form, or ``RSAModulus``' `limbs`.
    @inline(__always)
    static func read<let n: Int>(bigEndian bytes: RawSpan) -> InlineArray<n, UInt64> {
        var words = InlineArray<n, UInt64>(repeating: 0)
        var end = bytes.byteCount
        var index = 0
        while end >= 8 {
            words[index] = UInt64(bigEndian: bytes.load(fromByteOffset: end &- 8, as: UInt64.self))
            end &-= 8
            index &+= 1
        }
        if end > 0 {
            var word: UInt64 = 0
            for offset in 0..<end {
                word = word &<< 8 | UInt64(bytes.byteOffsetLoad(offset))
            }
            words[index] = word
        }
        return words
    }

    /// The limb count the arithmetic uses for a modulus of `bits` bits: the smallest specialization that holds it.
    static func arithmeticLimbCount(forBits bits: Int) -> Int {
        let needed = (bits &+ 63) &>> 6
        if needed <= 16 { return 16 }
        if needed <= 24 { return 24 }
        if needed <= 32 { return 32 }
        if needed <= 48 { return 48 }
        return 64
    }

    /// −n₀⁻¹ mod 2⁶⁴ for odd n₀, by Newton's iteration: n₀ is its own inverse mod 8, and each step doubles the bits.
    static func negativeInverse(_ n0: UInt64) -> UInt64 {
        var inverse = n0
        for _ in 0..<5 {
            inverse = inverse &* (2 &- n0 &* inverse)
        }
        return 0 &- inverse
    }
}

/// Montgomery arithmetic modulo an RSA modulus of `limbs` 64-bit limbs (its top limbs may be 0): a value a is held as
/// aR mod n, R = 2^(64 · limbs). Variable time.
///
/// The arithmetic works on limbs through pointers into a workspace on the stack (``withWorkspace(_:_:)``): with
/// `InlineArray` subscripts, LLVM couldn't prove the product loops' indices (j and i − j) in range, and their checks
/// were two compares and a branch on every product, a third of the inner loop. Every index below is in range by its
/// loop's bounds, stated where it's used.
enum RSAModulus<let limbs: Int> {
    typealias Limbs = InlineArray<limbs, UInt64>

    /// Runs `body` with a pointer to six blocks of `limbs` limbs, zeroed, in one stack array, block 0 holding n (the
    /// first `limbs` limbs of `modulus`). Block k starts at `words + k · limbs`.
    @inline(__always)
    static func withWorkspace<R>(_ modulus: borrowing InlineArray<64, UInt64>, _ body: (UnsafeMutablePointer<UInt64>) -> R) -> R {
        var blocks = InlineArray<6, Limbs>(repeating: Limbs(repeating: 0))
        for index in 0..<limbs {
            blocks[0][index] = modulus[index]
        }
        var span = blocks.mutableSpan
        // Unsafe: the blocks as one buffer of limbs (an InlineArray of UInt64 is laid out as its elements), for the
        // duration of `body`; the pointer doesn't escape it.
        return span.withUnsafeMutableBufferPointer { buffer in
            unsafe buffer.withMemoryRebound(to: UInt64.self) { words in
                // Unsafe: the buffer isn't empty (6 · limbs limbs).
                unsafe body(words.baseAddress.unsafelyUnwrapped)
            }
        }
    }

    /// Whether `value` is below n.
    @inline(__always)
    static func isBelow(_ value: UnsafePointer<UInt64>, _ modulus: UnsafePointer<UInt64>) -> Bool {
        var index = limbs &- 1
        while index >= 0 {
            // Unsafe: unchecked reads, index in 0..<limbs.
            let v = unsafe value[index], n = unsafe modulus[index]
            if v != n { return v < n }
            index &-= 1
        }
        return false
    }

    /// value −= n, ignoring the borrow out.
    @inline(__always)
    static func subtract(_ value: UnsafeMutablePointer<UInt64>, _ modulus: UnsafePointer<UInt64>) {
        var borrow: UInt64 = 0
        for index in 0..<limbs {
            // Unsafe: unchecked reads and write, index in 0..<limbs.
            unsafe (value[index], borrow) = subtractWithBorrow(unsafe value[index], unsafe modulus[index], borrow)
        }
    }

    /// One column's sum of products: two running sums of two limbs (t and u), so that consecutive products go to
    /// independent carry chains, and the carries out of both (`top`). With one chain, every product waited on the
    /// last one's `adcs`: two took 3–5% fewer cycles at 2048 bits and 8–10% at 4096, for 2–3% more instructions.
    struct Column {
        var t0: UInt64 = 0, t1: UInt64 = 0, u0: UInt64 = 0, u1: UInt64 = 0, top: UInt64 = 0

        /// t += a·b: a `mul`, a `umulh`, and `adds`, `adcs`, `cinc`.
        @inline(__always)
        mutating func add(_ a: UInt64, _ b: UInt64) {
            let (high, low) = a.multipliedFullWidth(by: b)
            var carry: UInt64
            (t0, carry) = addWithCarry(t0, low, 0)
            (t1, carry) = addWithCarry(t1, high, carry)
            top &+= carry
        }

        /// t += limb.
        @inline(__always)
        mutating func add(limb: UInt64) {
            var carry: UInt64
            (t0, carry) = addWithCarry(t0, limb, 0)
            (t1, carry) = addWithCarry(t1, 0, carry)
            top &+= carry
        }

        /// u += a·b.
        @inline(__always)
        mutating func addOther(_ a: UInt64, _ b: UInt64) {
            let (high, low) = a.multipliedFullWidth(by: b)
            var carry: UInt64
            (u0, carry) = addWithCarry(u0, low, 0)
            (u1, carry) = addWithCarry(u1, high, carry)
            top &+= carry
        }

        /// t += u, u = 0: the column's sum in t0, t1, top.
        @inline(__always)
        mutating func merge() {
            var carry: UInt64
            (t0, carry) = addWithCarry(t0, u0, 0)
            (t1, carry) = addWithCarry(t1, u1, carry)
            top &+= carry
            (u0, u1) = (0, 0)
        }

        /// The next column, the carry out of this one (after ``merge()``): t0 dropped.
        @inline(__always)
        mutating func shift() {
            (t0, t1, top) = (t1, top, 0)
        }
    }

    /// Adds Σ x[k]·y[−k] for k in 0..<count to `column`: the products along one column, four per iteration,
    /// alternating between its two sums.
    @inline(__always)
    static func addProducts(_ x: UnsafePointer<UInt64>, _ y: UnsafePointer<UInt64>, _ count: Int, _ column: inout Column) {
        var k = 0
        while k &+ 3 < count {
            // Unsafe: unchecked reads at k to k + 3, below count, the callers' ranges.
            column.add(unsafe x[k], unsafe y[0 &- k])
            column.addOther(unsafe x[k &+ 1], unsafe y[-1 &- k])
            column.add(unsafe x[k &+ 2], unsafe y[-2 &- k])
            column.addOther(unsafe x[k &+ 3], unsafe y[-3 &- k])
            k &+= 4
        }
        while k < count {
            // Unsafe: an unchecked read at k below count.
            column.add(unsafe x[k], unsafe y[0 &- k])
            k &+= 1
        }
    }

    /// a·b·R⁻¹ mod n into `result`, for a and b below n, by product scanning (Koç, Acar, and Kaliski's FIPS): one
    /// column of the product a·b + q·n at a time, the reduction's multipliers q chosen column by column to clear the
    /// low limbs. Each product costs a `mul`, a `umulh`, and an `adds`/`adcs`/`cinc` chain, against operand scanning's
    /// two carry chains. The result is below 2n: a top bit and one conditional subtraction finish it. `result`
    /// mustn't be `a` or `b`; `q` is scratch.
    @inline(never)
    static func multiply(_ a: UnsafePointer<UInt64>, _ b: UnsafePointer<UInt64>, _ modulus: UnsafePointer<UInt64>,
                         _ inverse: UInt64, _ q: UnsafeMutablePointer<UInt64>, into result: UnsafeMutablePointer<UInt64>) {
        var column = Column()
        // Columns 0 to limbs − 1: each ends with q[i] chosen so that the column's low limb is 0, then shifted out.
        for i in 0..<limbs {
            // Unsafe: column i's products aⱼbᵢ₋ⱼ and qⱼnᵢ₋ⱼ, j in 0...i (q[i] last): indices in 0..<limbs.
            unsafe addProducts(a, b + i, i &+ 1, &column)
            unsafe addProducts(q, modulus + i, i, &column)
            column.merge()
            let multiplier = column.t0 &* inverse
            unsafe q[i] = multiplier
            column.add(multiplier, unsafe modulus[0])
            column.shift()
        }
        // Columns limbs to 2·limbs − 2: the result's limbs; what's left is the top bit.
        for i in limbs..<(2 &* limbs &- 1) {
            // Unsafe: column i's products, j in i − limbs + 1..<limbs, so j and i − j are in 0..<limbs; the write at
            // i − limbs, below limbs − 1.
            let start = i &- limbs &+ 1
            unsafe addProducts(a + start, b + (limbs &- 1), limbs &- start, &column)
            unsafe addProducts(q + start, modulus + (limbs &- 1), limbs &- start, &column)
            column.merge()
            unsafe result[i &- limbs] = column.t0
            column.shift()
        }
        // Unsafe: unchecked write of the last limb; then `limbs` limbs of `result` and the modulus compared, and
        // subtracted in place.
        unsafe result[limbs &- 1] = column.t0
        if unsafe column.t1 != 0 || !isBelow(result, modulus) { unsafe subtract(result, modulus) }
    }

    /// a²·R⁻¹ mod n into `result`, for a below n: ``multiply(_:_:_:_:_:into:)`` with each cross product aᵢaⱼ (i ≠ j)
    /// computed once and doubled, about three quarters of the products. `result` mustn't be `a`; `q` is scratch.
    @inline(never)
    static func square(_ a: UnsafePointer<UInt64>, _ modulus: UnsafePointer<UInt64>, _ inverse: UInt64,
                       _ q: UnsafeMutablePointer<UInt64>, into result: UnsafeMutablePointer<UInt64>) {
        var column = Column()
        for i in 0..<limbs {
            // Unsafe: column i's products, indices in 0..<limbs (as in `multiply`).
            unsafe addSquareColumn(a, i, &column)
            unsafe addProducts(q, modulus + i, i, &column)
            column.merge()
            let multiplier = column.t0 &* inverse
            unsafe q[i] = multiplier
            column.add(multiplier, unsafe modulus[0])
            column.shift()
        }
        for i in limbs..<(2 &* limbs &- 1) {
            // Unsafe: column i's products and the write at i − limbs, indices in 0..<limbs (as in `multiply`).
            let start = i &- limbs &+ 1
            unsafe addSquareColumn(a, i, &column)
            unsafe addProducts(q + start, modulus + (limbs &- 1), limbs &- start, &column)
            column.merge()
            unsafe result[i &- limbs] = column.t0
            column.shift()
        }
        // Unsafe: unchecked write of the last limb; then `limbs` limbs of `result` and the modulus compared, and
        // subtracted in place.
        unsafe result[limbs &- 1] = column.t0
        if unsafe column.t1 != 0 || !isBelow(result, modulus) { unsafe subtract(result, modulus) }
    }

    /// Adds column `i` (below 2·limbs − 1) of a² to `column`'s t: twice the cross products aⱼaᵢ₋ⱼ (j < i − j), plus
    /// a²ᵢ/₂ for even i.
    @inline(__always)
    static func addSquareColumn(_ a: UnsafePointer<UInt64>, _ i: Int, _ column: inout Column) {
        var cross = Column()
        let start = i < limbs ? 0 : i &- limbs &+ 1
        // Unsafe: j from start while j < i − j, so j < i − j ≤ limbs − 1.
        unsafe addProducts(a + start, a + (i &- start), ((i &+ 1) &>> 1) &- start, &cross)
        cross.merge()
        // Doubled: the cross sum fits three limbs with room (a column has under 2⁶ products of under 2¹²⁸).
        var carry: UInt64
        (column.t0, carry) = addWithCarry(column.t0, cross.t0 &<< 1, 0)
        (column.t1, carry) = addWithCarry(column.t1, cross.t1 &<< 1 | cross.t0 &>> 63, carry)
        column.top = column.top &+ (cross.top &<< 1 | cross.t1 &>> 63) &+ carry
        if i & 1 == 0 {
            // Unsafe: an unchecked read at i / 2 < limbs.
            let middle = unsafe a[i &>> 1]
            column.addOther(middle, middle)
        }
    }

    /// y·R⁻¹ mod n into `result`, for y below n: Montgomery's reduction alone, out of Montgomery form. A product
    /// with 1, without its row of products.
    @inline(never)
    static func reduce(_ y: UnsafePointer<UInt64>, _ modulus: UnsafePointer<UInt64>, _ inverse: UInt64,
                       _ q: UnsafeMutablePointer<UInt64>, into result: UnsafeMutablePointer<UInt64>) {
        var column = Column()
        for i in 0..<limbs {
            // Unsafe: column i's limb of y and products qⱼnᵢ₋ⱼ, indices in 0..<limbs (as in `multiply`).
            column.add(limb: unsafe y[i])
            unsafe addProducts(q, modulus + i, i, &column)
            column.merge()
            let multiplier = column.t0 &* inverse
            unsafe q[i] = multiplier
            column.add(multiplier, unsafe modulus[0])
            column.shift()
        }
        for i in limbs..<(2 &* limbs &- 1) {
            // Unsafe: column i's products and the write at i − limbs, indices in 0..<limbs (as in `multiply`).
            let start = i &- limbs &+ 1
            unsafe addProducts(q + start, modulus + (limbs &- 1), limbs &- start, &column)
            column.merge()
            unsafe result[i &- limbs] = column.t0
            column.shift()
        }
        // Unsafe: unchecked write of the last limb; then `limbs` limbs of `result` and the modulus compared, and
        // subtracted in place.
        unsafe result[limbs &- 1] = column.t0
        if unsafe column.t1 != 0 || !isBelow(result, modulus) { unsafe subtract(result, modulus) }
    }

    /// base^exponent in Montgomery form, left to right a bit at a time, alternating between `accumulator` and
    /// `other`; returns the one holding it. For base = xR, that's x^exponent·R. `q` is scratch.
    @inline(__always)
    static func power(_ base: UnsafePointer<UInt64>, _ exponent: UInt64, _ modulus: UnsafePointer<UInt64>, _ inverse: UInt64,
                      _ q: UnsafeMutablePointer<UInt64>, _ accumulator: UnsafeMutablePointer<UInt64>,
                      _ other: UnsafeMutablePointer<UInt64>) -> UnsafeMutablePointer<UInt64> {
        // Unsafe (throughout): the pointers are distinct workspace blocks of `limbs` limbs (`q` too); the squaring and
        // multiplication read and write only those, and the swap exchanges which block is which.
        var accumulator = unsafe accumulator, other = unsafe other
        // Unsafe: copies `limbs` limbs between distinct blocks of a workspace.
        unsafe accumulator.update(from: base, count: limbs)
        var bit = 62 &- exponent.leadingZeroBitCount
        while bit >= 0 {
            unsafe square(accumulator, modulus, inverse, q, into: other)
            if (exponent &>> UInt64(bit)) & 1 == 1 {
                unsafe multiply(other, base, modulus, inverse, q, into: accumulator)
            } else {
                unsafe swap(&accumulator, &other)
            }
            bit &-= 1
        }
        return unsafe accumulator
    }

    /// R² mod n, for a modulus of `bits` bits (its first `limbs` limbs in `modulus`): what takes values into
    /// Montgomery form.
    static func rSquared(_ modulus: borrowing InlineArray<64, UInt64>, _ inverse: UInt64, bits: Int) -> InlineArray<64, UInt64> {
        var words = InlineArray<64, UInt64>(repeating: 0)
        // Unsafe: a workspace of six blocks of `limbs` limbs, for the closure only (the pointer doesn't escape it).
        let result = unsafe withWorkspace(modulus) { workspace in
            // Unsafe (throughout): blocks of the workspace, indices below `limbs`.
            let n = unsafe UnsafePointer(workspace)
            let x = unsafe workspace + limbs, y = unsafe workspace + 2 &* limbs, q = unsafe workspace + 5 &* limbs
            // 2^(bits − 1) is below n (n is odd, its top bit bits − 1), so doubling mod n from it reaches
            // 2^(64·limbs + limbs) mod n: the Montgomery form of 2^limbs. Six Montgomery squarings raise that to
            // 2^(64·limbs) = R: R·R mod n, R's Montgomery form.
            unsafe x[(bits &- 1) &>> 6] = 1 &<< UInt64((bits &- 1) & 63)
            for _ in 0..<(64 &* limbs &- bits &+ 1 &+ limbs) {
                var carry: UInt64 = 0
                for index in 0..<limbs {
                    let word = unsafe x[index]
                    unsafe x[index] = word &<< 1 | carry
                    carry = word &>> 63
                }
                if unsafe carry != 0 || !isBelow(x, n) { unsafe subtract(x, n) }
            }
            for _ in 0..<3 {
                unsafe square(x, n, inverse, q, into: y)
                unsafe square(y, n, inverse, q, into: x)
            }
            var value = Limbs(repeating: 0)
            for index in 0..<limbs {
                value[index] = unsafe x[index]
            }
            return value
        }
        for index in 0..<limbs {
            words[index] = result[index]
        }
        return words
    }

    /// Whether s^e mod n, for the signature s (big-endian, below n), equals `encoded` (big-endian, as long).
    @inline(never)
    static func verify(_ signature: RawSpan, _ encoded: RawSpan, _ key: borrowing RSA.PublicKey) -> Bool {
        let s: Limbs = RSALimbs.read(bigEndian: signature)
        let expected: Limbs = RSALimbs.read(bigEndian: encoded)
        let exponent = key.publicExponent, inverse = key.negativeInverse
        var rSquared = Limbs(repeating: 0)
        for index in 0..<limbs {
            rSquared[index] = key.rSquared[index]
        }
        // Unsafe: a workspace of six blocks of `limbs` limbs, for the closure only (the pointer doesn't escape it).
        let result: Limbs? = unsafe withWorkspace(key.modulus) { workspace in
            // Unsafe (throughout): blocks of the workspace, indices below `limbs`.
            let n = unsafe UnsafePointer(workspace)
            let base = unsafe workspace + limbs, x = unsafe workspace + 2 &* limbs, y = unsafe workspace + 3 &* limbs
            let factor = unsafe workspace + 4 &* limbs, q = unsafe workspace + 5 &* limbs
            for index in 0..<limbs {
                unsafe x[index] = s[index]
                unsafe factor[index] = rSquared[index]
            }
            guard unsafe isBelow(x, n) else { return nil }
            // sR (s·R²·R⁻¹), then (sR)^e = s^e·R, then s^e.
            unsafe multiply(x, factor, n, inverse, q, into: base)
            let raised = unsafe power(base, exponent, n, inverse, q, x, y)
            unsafe reduce(raised, n, inverse, q, into: factor)
            var value = Limbs(repeating: 0)
            for index in 0..<limbs {
                value[index] = unsafe factor[index]
            }
            return value
        }
        guard let result else { return false }
        for index in 0..<limbs where result[index] != expected[index] {
            return false
        }
        return true
    }
}
