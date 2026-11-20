internal import Bytes

// Keys and ECDSA signatures, generic over the curve: parsing (X9.63, SEC 1, PKCS #8, SubjectPublicKeyInfo, PEM),
// ECDSA verification (SEC 1, 4.1.4), and ECDH (SEC 1, 3.3.1). `P256` and `P384` wrap these in concrete types.
//
// What runs in constant time: everything that touches a private key: deriving its public key and ECDH, which
// multiply by the secret scalar with `JacobianPoint.multiply` (fixed windows, masked table reads, the addition's
// special cases chosen by masks), then convert to affine coordinates with a Fermat inversion. Checked in the compiled
// code (Xcode 27.3, 2026-11-18): P-256's `multiply` has six conditional branches, on the table-building loop's
// counter and its index's parity, the select and window loops' counters, the first window, and the stack guard; the
// table reads are `csel`s; `doubled` and `affineX` branch only
// on the stack guard, and the inversion's `power` only on its public exponent. Parsing a private key checks its range
// with ordinary comparisons, and comparing an embedded public key with the derived one isn't constant-time
// either: both only say whether a key is well formed. Verification handles nothing secret and isn't constant-time.

/// Reads an AlgorithmIdentifier for an EC key on curve `C`: SEQUENCE { id-ecPublicKey, namedCurve }. Explicit curve
/// parameters (RFC 5480 forbids them) are rejected.
func readECAlgorithm<C: PrimeCurve>(_ reader: inout AlignedBytesReader, curve: C.Type) throws(BytesError) {
    var algorithm = AlignedBytesReader(try reader.readASN1Contents(.sequence))
    guard ASN1ObjectIdentifier.ecPublicKey.matches(try algorithm.readASN1Contents(.objectIdentifier)),
          C.objectIdentifier.matches(try algorithm.readASN1Contents(.objectIdentifier))
    else { throw .invalidValue }
    try algorithm.expectASN1End()
}

/// `magnitude` (big-endian, no more than `count` bytes once leading zeros are dropped) left-padded with zeros to
/// `count` bytes in `output`.
///
/// - Throws: ``BytesError/invalidValue`` if the value doesn't fit.
func leftPad(_ magnitude: RawSpan, to count: Int, into output: inout MutableRawSpan) throws(BytesError) {
    var start = 0
    while start < magnitude.byteCount, magnitude.byteOffsetLoad(start) == 0 { start &+= 1 }
    let significant = magnitude.byteCount &- start
    guard significant <= count else { throw .invalidValue }
    for index in 0..<(count &- significant) { output.storeBytes(of: 0, toByteOffset: index, as: UInt8.self) }
    output.copyBytes(from: magnitude.extracting(droppingFirst: start), toByteOffset: count &- significant)
}

// MARK: - Public keys

struct ECPublicKeyCore<C: PrimeCurve>: Sendable {
    let point: AffinePoint<C>

    init(point: AffinePoint<C>) {
        self.point = point
    }

    /// SubjectPublicKeyInfo (RFC 5480): SEQUENCE { AlgorithmIdentifier, BIT STRING (the X9.63 point) }.
    init(subjectPublicKeyInfo der: RawSpan) throws(BytesError) {
        var outer = AlignedBytesReader(der)
        var info = AlignedBytesReader(try outer.readASN1Contents(.sequence))
        try outer.expectASN1End()
        try readECAlgorithm(&info, curve: C.self)
        point = try AffinePoint(x963: try info.readASN1BitString())
        try info.expectASN1End()
    }

    init(pem: String) throws(BytesError) {
        let der = try PEM.decode(pem, label: "PUBLIC KEY")
        try self.init(subjectPublicKeyInfo: der.span.bytes)
    }

    /// The uncompressed X9.63 form.
    var x963: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 1 &+ 2 &* C.byteCount)
        var span = bytes.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        point.writeX963(to: &raw)
        return bytes
    }

    /// SubjectPublicKeyInfo DER, the point uncompressed (as OpenSSL and CryptoKit write it).
    var subjectPublicKeyInfo: [UInt8] {
        let point = x963
        var writer = DERWriter()
        writer.append(.sequence) { info in
            info.append(.sequence) { algorithm in
                algorithm.append(.ecPublicKey)
                algorithm.append(C.objectIdentifier)
            }
            info.appendBitString(point.span.bytes)
        }
        return writer.bytes
    }

    /// Whether `other` is the same point (public values: not constant-time).
    func isEqual(to other: Self) -> Bool {
        point.x.equalMask(other.point.x) != 0 && point.y.equalMask(other.point.y) != 0
    }

    /// The compressed X9.63 form.
    var compressed: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 1 &+ C.byteCount)
        var span = bytes.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        point.writeCompressed(to: &raw)
        return bytes
    }

    /// ECDSA verification (SEC 1, 4.1.4) of a signature over a digest.
    func isValid(_ signature: ECSignatureCore<C>, digest: RawSpan) -> Bool {
        // e: the digest's leftmost bits, as many as n has (n's bit length is a whole number of bytes on both
        // curves), as an integer, reduced mod n (a digest of n's length is below 2n). A shorter digest is its value.
        let count = C.byteCount
        var padded = InlineArray<48, UInt8>(repeating: 0)
        do {
            let take = min(digest.byteCount, count)
            var span = padded.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            raw.copyBytes(from: digest.extracting(first: take), toByteOffset: count &- take)
        }
        let e = C.Scalar(reducingBigEndian: padded.span.bytes.extracting(first: count))
        let w = signature.s.invertedVariableTime // s is public.
        let u1 = (e * w).canonicalWords
        let u2 = (signature.r * w).canonicalWords
        return ECVerification<C>.combinationMatches(u1: u1, u2: u2, point: point, r: signature.r)
    }

    /// ECDSA verification of a signature over a message, hashed with the curve's hash.
    func isValid(_ signature: ECSignatureCore<C>, message: RawSpan) -> Bool {
        var hash = C.Hash()
        hash.update(message)
        var digest = InlineArray<64, UInt8>(repeating: 0)
        do {
            var span = digest.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            hash.finalize(into: &raw)
        }
        return isValid(signature, digest: digest.span.bytes.extracting(first: C.Hash.digestByteCount))
    }
}

// MARK: - Signatures

struct ECSignatureCore<C: PrimeCurve>: Sendable {
    /// r and s, both in [1, n − 1].
    let r: C.Scalar
    let s: C.Scalar

    /// A scalar in [1, n − 1] from a big-endian magnitude of at most ``PrimeCurve/byteCount`` significant bytes.
    static func scalar(_ magnitude: RawSpan) throws(BytesError) -> C.Scalar {
        var padded = InlineArray<48, UInt8>(repeating: 0)
        do {
            var span = padded.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            try leftPad(magnitude, to: C.byteCount, into: &raw)
        }
        guard let value = C.Scalar(bigEndian: padded.span.bytes.extracting(first: C.byteCount)), value.zeroMask == 0 else {
            throw .invalidValue
        }
        return value
    }

    /// An ECDSA-Sig-Value: SEQUENCE { INTEGER r, INTEGER s }, optionally followed by zero bytes.
    init(der: RawSpan, allowingZeroPadding: Bool) throws(BytesError) {
        var outer = AlignedBytesReader(der)
        var sequence = AlignedBytesReader(try outer.readASN1Contents(.sequence))
        if allowingZeroPadding {
            let rest = outer.remainingBytes
            for index in 0..<rest.byteCount where rest.byteOffsetLoad(index) != 0 {
                throw .trailingData
            }
        } else {
            try outer.expectASN1End()
        }
        r = try Self.scalar(try sequence.readASN1UnsignedInteger())
        s = try Self.scalar(try sequence.readASN1UnsignedInteger())
        try sequence.expectASN1End()
    }

    /// r ‖ s, each ``PrimeCurve/byteCount`` bytes (IEEE P1363).
    init(raw: RawSpan) throws(BytesError) {
        let count = C.byteCount
        guard raw.byteCount == 2 &* count else { throw .invalidValue }
        r = try Self.scalar(raw.extracting(0..<count))
        s = try Self.scalar(raw.extracting(count..<(2 &* count)))
    }

    var raw: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 2 &* C.byteCount)
        var span = bytes.mutableSpan
        var output = MutableRawSpan(mutating: &span)
        r.write(bigEndianTo: &output, at: 0)
        s.write(bigEndianTo: &output, at: C.byteCount)
        return bytes
    }

    /// The ECDSA-Sig-Value DER, SEQUENCE { INTEGER r, INTEGER s }.
    var der: [UInt8] {
        let values = raw
        let count = C.byteCount
        var writer = DERWriter()
        writer.append(.sequence) { sequence in
            sequence.appendUnsignedInteger(values.span.bytes.extracting(0..<count))
            sequence.appendUnsignedInteger(values.span.bytes.extracting(count..<(2 &* count)))
        }
        return writer.bytes
    }

    /// Whether `other` has the same r and s.
    func isEqual(to other: Self) -> Bool {
        r.equalMask(other.r) != 0 && s.equalMask(other.s) != 0
    }
}

// MARK: - Private keys

struct ECPrivateKeyCore<C: PrimeCurve>: Sendable {
    /// The secret scalar d in [1, n − 1], canonical limbs.
    let scalar: InlineArray<6, UInt64>
    let publicKey: ECPublicKeyCore<C>

    /// d from exactly ``PrimeCurve/byteCount`` big-endian bytes, and Q = dG.
    init(scalar bytes: RawSpan) throws(BytesError) {
        guard bytes.byteCount == C.byteCount, let value = C.Scalar(bigEndian: bytes), value.zeroMask == 0 else {
            throw .invalidValue
        }
        scalar = value.canonicalWords
        // dG for d in [1, n − 1] is never the identity.
        guard let point = JacobianPoint<C>.multiply(C.generator, by: scalar).affine else { throw .invalidValue }
        publicKey = ECPublicKeyCore(point: point)
    }

    /// A random key from `generator`, which must be cryptographically secure.
    init<G: RandomNumberGenerator>(using generator: inout G) {
        var bytes = InlineArray<48, UInt8>(repeating: 0)
        while true {
            // Rejection sampling: uniform in [1, n − 1] (n is close to 2^bits on both curves, so this rarely loops).
            for index in 0..<C.byteCount { bytes[index] = generator.next() }
            if let key = try? Self(scalar: bytes.span.bytes.extracting(first: C.byteCount)) {
                self = key
                return
            }
        }
    }

    /// X9.63's private form: the uncompressed public point, then d (CryptoKit's `x963Representation`). The point
    /// must be d's.
    init(x963: RawSpan) throws(BytesError) {
        let pointCount = 1 &+ 2 &* C.byteCount
        guard x963.byteCount == pointCount &+ C.byteCount else { throw .invalidValue }
        try self.init(scalar: x963.extracting(pointCount...))
        try checkPublicKey(x963.extracting(0..<pointCount))
    }

    /// Throws unless `encoded` (an X9.63 point) is this key's public key.
    func checkPublicKey(_ encoded: RawSpan) throws(BytesError) {
        let embedded = try AffinePoint<C>(x963: encoded)
        guard embedded.x.equalMask(publicKey.point.x) != 0, embedded.y.equalMask(publicKey.point.y) != 0 else {
            throw .invalidValue
        }
    }

    /// SEC 1's ECPrivateKey (RFC 5915): SEQUENCE { INTEGER 1, OCTET STRING d, [0] namedCurve OPTIONAL,
    /// [1] BIT STRING publicKey OPTIONAL }.
    init(sec1 der: RawSpan) throws(BytesError) {
        var outer = AlignedBytesReader(der)
        let contents = try outer.readASN1Contents(.sequence)
        try outer.expectASN1End()
        try self.init(ecPrivateKeyContents: contents)
    }

    init(ecPrivateKeyContents contents: RawSpan) throws(BytesError) {
        var key = AlignedBytesReader(contents)
        guard try key.readASN1SmallInteger() == 1 else { throw .invalidValue }
        let secret = try key.readASN1Contents(.octetString)
        // SEC 1 pads d to n's length; some writers drop leading zeros.
        var padded = InlineArray<48, UInt8>(repeating: 0)
        do {
            var span = padded.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            guard secret.byteCount <= C.byteCount else { throw .invalidValue }
            try leftPad(secret, to: C.byteCount, into: &raw)
        }
        try self.init(scalar: padded.span.bytes.extracting(first: C.byteCount))
        let parametersTag = ASN1Tag.contextSpecific(0, constructed: true)
        if key.nextASN1Tag == parametersTag {
            var parameters = AlignedBytesReader(try key.readASN1Contents(parametersTag))
            guard C.objectIdentifier.matches(try parameters.readASN1Contents(.objectIdentifier)) else { throw .invalidValue }
            try parameters.expectASN1End()
        }
        let publicKeyTag = ASN1Tag.contextSpecific(1, constructed: true)
        if key.nextASN1Tag == publicKeyTag {
            var wrapper = AlignedBytesReader(try key.readASN1Contents(publicKeyTag))
            try checkPublicKey(try wrapper.readASN1BitString())
            try wrapper.expectASN1End()
        }
        try key.expectASN1End()
    }

    /// PKCS #8 (RFC 5208, 5958): SEQUENCE { INTEGER 0 or 1, AlgorithmIdentifier, OCTET STRING (an ECPrivateKey),
    /// [0] attributes OPTIONAL, [1] publicKey OPTIONAL }.
    init(pkcs8 der: RawSpan) throws(BytesError) {
        var outer = AlignedBytesReader(der)
        var info = AlignedBytesReader(try outer.readASN1Contents(.sequence))
        try outer.expectASN1End()
        let version = try info.readASN1SmallInteger()
        guard version == 0 || version == 1 else { throw .invalidValue }
        try readECAlgorithm(&info, curve: C.self)
        try self.init(sec1: try info.readASN1Contents(.octetString))
        let attributesTag = ASN1Tag.contextSpecific(0, constructed: true)
        if info.nextASN1Tag == attributesTag { _ = try info.readASN1Contents(attributesTag) }
        // OneAsymmetricKey's publicKey: [1] IMPLICIT BIT STRING, so primitive.
        let publicKeyTag = ASN1Tag.contextSpecific(1, constructed: false)
        if version == 1, info.nextASN1Tag == publicKeyTag { try checkPublicKey(try info.readASN1BitString(publicKeyTag)) }
        try info.expectASN1End()
    }

    /// SEC 1 or PKCS #8 DER, told apart by PKCS #8's AlgorithmIdentifier after the version.
    init(der: RawSpan) throws(BytesError) {
        var outer = AlignedBytesReader(der)
        var probe = AlignedBytesReader(try outer.readASN1Contents(.sequence))
        _ = try probe.readASN1SmallInteger()
        if probe.nextASN1Tag == .sequence {
            try self.init(pkcs8: der)
        } else {
            try self.init(sec1: der)
        }
    }

    /// "EC PRIVATE KEY" (SEC 1) or "PRIVATE KEY" (PKCS #8) PEM.
    init(pem: String) throws(BytesError) {
        // The DER bound to a local first: `.span` of a throwing call's result crashes the LLVM verifier at -Onone
        // (~/Scratch/swift-bugs/28).
        if let der = try PEM.decodeAll(pem, label: "EC PRIVATE KEY").first {
            try self.init(sec1: der.span.bytes)
        } else {
            let der = try PEM.decode(pem, label: "PRIVATE KEY")
            try self.init(pkcs8: der.span.bytes)
        }
    }

    /// SEC 1's ECPrivateKey DER, with the named curve and the public key (as `openssl ecparam -genkey` writes it).
    var sec1: [UInt8] {
        let secret = raw, point = publicKey.x963
        var writer = DERWriter()
        writer.append(.sequence) { key in
            key.appendUnsignedInteger([UInt8(1)].span.bytes)
            key.append(.octetString, contents: secret.span.bytes)
            key.append(.contextSpecific(0, constructed: true)) { $0.append(C.objectIdentifier) }
            key.append(.contextSpecific(1, constructed: true)) { $0.appendBitString(point.span.bytes) }
        }
        return writer.bytes
    }

    /// d, big-endian.
    var raw: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: C.byteCount)
        var span = bytes.mutableSpan
        var output = MutableRawSpan(mutating: &span)
        for index in 0..<(C.byteCount / 8) {
            output.storeBytes(of: scalar[index].bigEndian, toByteOffset: C.byteCount &- 8 &* (index &+ 1), as: UInt64.self)
        }
        return bytes
    }

    /// ECDH: the x coordinate of dQ, big-endian, at the start of `output` (``PrimeCurve/byteCount`` bytes).
    /// Constant-time in d.
    func sharedSecret(with other: ECPublicKeyCore<C>, into output: inout MutableRawSpan) {
        let product = JacobianPoint<C>.multiply(other.point, by: scalar)
        // Q is a valid point (checked when parsed) of prime order n, and d is in [1, n − 1]: dQ isn't the identity.
        product.affineX.write(bigEndianTo: &output, at: 0)
    }
}

// MARK: - Verification's scalar multiplication

/// u₁G + u₂Q for ECDSA verification, and the comparison of its x coordinate with r. Nothing here is secret, so
/// it isn't constant-time.
enum ECVerification<C: PrimeCurve> {
    /// Whether u₁G + u₂Q isn't the identity and its x coordinate is r mod n.
    static func combinationMatches(u1: InlineArray<6, UInt64>, u2: InlineArray<6, UInt64>, point: AffinePoint<C>, r: C.Scalar) -> Bool {
        let sum = linearCombination(u1: u1, u2: u2, point: point)
        guard !sum.isIdentity else { return false }
        // x = X/Z², and x mod n = r means x = r or x = r + n (when that's below p): compare without inverting Z.
        let zSquared = sum.z.squared
        let rWords = r.canonicalWords
        guard let rField = C.Field(canonicalWords: rWords) else { return false }
        if (rField * zSquared).equalMask(sum.x) != 0 { return true }
        var rPlusN = InlineArray<6, UInt64>(repeating: 0)
        var carry: UInt64 = 0
        for index in 0..<6 { (rPlusN[index], carry) = addWithCarry(rWords[index], C.order[index], carry) }
        guard carry == 0, let wrapped = C.Field(canonicalWords: rPlusN) else { return false }
        return (wrapped * zSquared).equalMask(sum.x) != 0
    }

    /// The width of u₁'s NAF: digits below 2⁷ in magnitude, G's 64 odd multiples precomputed (``PrimeCurve/generatorTable``).
    static var generatorWidth: Int { 7 }
    /// The width of u₂'s NAF: digits below 2⁴, Q's 8 odd multiples made per verification.
    static var pointWidth: Int { 4 }

    /// u₁G + u₂Q by Shamir's trick on width-w NAFs: one chain of doublings, adding (or subtracting) an odd multiple
    /// of G (affine, from the static table) where u₁'s NAF has a digit, and of Q (Jacobian, made here) where u₂'s does.
    static func linearCombination(u1: InlineArray<6, UInt64>, u2: InlineArray<6, UInt64>, point: AffinePoint<C>) -> JacobianPoint<C> {
        typealias Point = JacobianPoint<C>
        let bits = C.byteCount &* 8
        let gDigits = nonAdjacentForm(u1, bits: bits, width: generatorWidth)
        let qDigits = nonAdjacentForm(u2, bits: bits, width: pointWidth)
        var qTable = InlineArray<8, Point>(repeating: .identity)
        qTable[0] = Point(point)
        let twice = qTable[0].doubled
        for index in 1..<8 { qTable[index] = qTable[index &- 1] + twice }
        let gTable = C.generatorTable
        var accumulator = Point.identity
        for index in (0...bits).reversed() {
            if !accumulator.isIdentity { accumulator = accumulator.doubled }
            let g = Int(gDigits[index])
            if g > 0 {
                accumulator = accumulator.adding(gTable[g &>> 1])
            } else if g < 0 {
                let multiple = gTable[(0 &- g) &>> 1]
                accumulator = accumulator.adding(AffinePoint(x: multiple.x, y: multiple.y.negated))
            }
            let q = Int(qDigits[index])
            if q > 0 {
                accumulator = accumulator + qTable[q &>> 1]
            } else if q < 0 {
                accumulator = accumulator + qTable[(0 &- q) &>> 1].negated
            }
        }
        return accumulator
    }
}
