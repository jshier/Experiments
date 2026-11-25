internal import Bytes

// The NIST prime curves P-256 (secp256r1) and P-384 (secp384r1), y² = x³ − 3x + b over the integers mod p, both of
// prime order n (no cofactor): any point on the curve other than the identity generates the whole group, so
// checking that a public key is on the curve is all the validation it needs.
//
// Points are Jacobian (X : Y : Z), x = X/Z², y = Y/Z³, for both kinds of scalar multiplication:
// - Constant time (ECDH, deriving public keys): a fixed 4-bit window, table entries read under masks, and the
//   addition formula's two possible special cases (an accumulator still at the identity, a zero window) resolved
//   by selection rather than branches (`JacobianPoint.multiply`).
// - Verification, where everything is public: width-w NAFs of both scalars, a static table of G's odd multiples
//   (affine, for mixed additions), and formulas that branch on their special cases.
// (The first version used Renes, Costello, and Batina's complete projective formulas, branch-free by construction:
// doubling costs 8 multiplications and 3 squarings there against Jacobian's 3 and 5, and ECDH took 28% more
// instructions. Benchmarks/RESULTS-ecc.md.)

// MARK: - Moduli

/// P-256's field prime, p = 2²⁵⁶ − 2²²⁴ + 2¹⁹² + 2⁹⁶ − 1.
enum P256FieldModulus: MontgomeryModulus {
    static var modulus: InlineArray<6, UInt64> {
        @inline(__always) get { [0xFFFF_FFFF_FFFF_FFFF, 0x0000_0000_FFFF_FFFF, 0, 0xFFFF_FFFF_0000_0001, 0, 0] }
    }

    static var negativeInverse: UInt64 { @inline(__always) get { 1 } }
    static var rSquared: InlineArray<6, UInt64> {
        @inline(__always) get { [0x0000_0000_0000_0003, 0xFFFF_FFFB_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFE, 0x0000_0004_FFFF_FFFD, 0, 0] }
    }

    static var one: InlineArray<6, UInt64> {
        @inline(__always) get { [0x0000_0000_0000_0001, 0xFFFF_FFFF_0000_0000, 0xFFFF_FFFF_FFFF_FFFF, 0x0000_0000_FFFF_FFFE, 0, 0] }
    }

    static var inversionExponent: InlineArray<6, UInt64> {
        @inline(__always) get { [0xFFFF_FFFF_FFFF_FFFD, 0x0000_0000_FFFF_FFFF, 0, 0xFFFF_FFFF_0000_0001, 0, 0] }
    }
}

/// P-256's group order n.
enum P256OrderModulus: MontgomeryModulus {
    static var modulus: InlineArray<6, UInt64> {
        @inline(__always) get { [0xF3B9_CAC2_FC63_2551, 0xBCE6_FAAD_A717_9E84, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_0000_0000, 0, 0] }
    }

    static var negativeInverse: UInt64 { @inline(__always) get { 0xCCD1_C8AA_EE00_BC4F } }
    static var rSquared: InlineArray<6, UInt64> {
        @inline(__always) get { [0x8324_4C95_BE79_EEA2, 0x4699_799C_49BD_6FA6, 0x2845_B239_2B6B_EC59, 0x66E1_2D94_F3D9_5620, 0, 0] }
    }

    static var one: InlineArray<6, UInt64> {
        @inline(__always) get { [0x0C46_353D_039C_DAAF, 0x4319_0552_58E8_617B, 0, 0x0000_0000_FFFF_FFFF, 0, 0] }
    }

    static var inversionExponent: InlineArray<6, UInt64> {
        @inline(__always) get { [0xF3B9_CAC2_FC63_254F, 0xBCE6_FAAD_A717_9E84, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_0000_0000, 0, 0] }
    }
}

/// P-384's field prime, p = 2³⁸⁴ − 2¹²⁸ − 2⁹⁶ + 2³² − 1.
enum P384FieldModulus: MontgomeryModulus {
    static var modulus: InlineArray<6, UInt64> {
        @inline(__always) get {
            [0x0000_0000_FFFF_FFFF, 0xFFFF_FFFF_0000_0000, 0xFFFF_FFFF_FFFF_FFFE,
             0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF]
        }
    }

    static var negativeInverse: UInt64 { @inline(__always) get { 0x0000_0001_0000_0001 } }
    static var rSquared: InlineArray<6, UInt64> {
        @inline(__always) get {
            [0xFFFF_FFFE_0000_0001, 0x0000_0002_0000_0000, 0xFFFF_FFFE_0000_0000,
             0x0000_0002_0000_0000, 0x0000_0000_0000_0001, 0]
        }
    }

    static var one: InlineArray<6, UInt64> {
        @inline(__always) get { [0xFFFF_FFFF_0000_0001, 0x0000_0000_FFFF_FFFF, 0x0000_0000_0000_0001, 0, 0, 0] }
    }

    static var inversionExponent: InlineArray<6, UInt64> {
        @inline(__always) get {
            [0x0000_0000_FFFF_FFFD, 0xFFFF_FFFF_0000_0000, 0xFFFF_FFFF_FFFF_FFFE,
             0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF]
        }
    }
}

/// P-384's group order n.
enum P384OrderModulus: MontgomeryModulus {
    static var modulus: InlineArray<6, UInt64> {
        @inline(__always) get {
            [0xECEC_196A_CCC5_2973, 0x581A_0DB2_48B0_A77A, 0xC763_4D81_F437_2DDF,
             0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF]
        }
    }

    static var negativeInverse: UInt64 { @inline(__always) get { 0x6ED4_6089_E88F_DC45 } }
    static var rSquared: InlineArray<6, UInt64> {
        @inline(__always) get {
            [0x2D31_9B24_19B4_09A9, 0xFF3D_81E5_DF1A_A419, 0xBC3E_483A_FCB8_2947,
             0xD40D_4917_4AAB_1CC5, 0x3FB0_5B7A_2826_6895, 0x0C84_EE01_2B39_BF21]
        }
    }

    static var one: InlineArray<6, UInt64> {
        @inline(__always) get { [0x1313_E695_333A_D68D, 0xA7E5_F24D_B74F_5885, 0x389C_B27E_0BC8_D220, 0, 0, 0] }
    }

    static var inversionExponent: InlineArray<6, UInt64> {
        @inline(__always) get {
            [0xECEC_196A_CCC5_2971, 0x581A_0DB2_48B0_A77A, 0xC763_4D81_F437_2DDF,
             0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF]
        }
    }
}

// MARK: - Curves

/// A short Weierstrass curve with a = −3 and prime order: what the point arithmetic needs to know of one.
protocol PrimeCurve: Sendable {
    /// Integers mod p.
    associatedtype Field: ModularArithmetic
    /// Integers mod n.
    associatedtype Scalar: ModularArithmetic
    /// ECDSA's hash for the curve: SHA-256 for P-256, SHA-384 for P-384.
    associatedtype Hash: HashFunction

    /// The curve's b, in Montgomery form.
    static var b: Field { get }
    /// The generator's coordinates.
    static var generator: AffinePoint<Self> { get }
    /// (p + 1) / 4: a square root is a power (both primes are 3 mod 4).
    static var squareRootExponent: InlineArray<6, UInt64> { get }
    /// n's limbs (for ECDSA's x mod n).
    static var order: InlineArray<6, UInt64> { get }
    /// The curve's object identifier, as keys name it.
    static var objectIdentifier: ASN1ObjectIdentifier { get }
    /// G, 3G, 5G, …, 127G in affine coordinates, for verification's width-7 NAF of u₁. Computed on first use.
    static var generatorTable: [AffinePoint<Self>] { get }
}

extension PrimeCurve {
    /// The size of a coordinate or scalar in bytes.
    @inline(__always) static var byteCount: Int { Field.byteCount }
}

/// P-256 (secp256r1, prime256v1).
enum P256Curve: PrimeCurve {
    typealias Field = Residue<4, P256FieldModulus>
    typealias Scalar = Residue<4, P256OrderModulus>
    typealias Hash = SHA256

    static var b: Field {
        @inline(__always) get { Field(montgomery: [0xD89C_DF62_29C4_BDDF, 0xACF0_05CD_7884_3090, 0xE5A2_20AB_F721_2ED6, 0xDC30_061D_0487_4834, 0, 0]) }
    }

    static var generator: AffinePoint<Self> {
        @inline(__always) get {
            AffinePoint(
                x: Field(montgomery: [0x79E7_30D4_18A9_143C, 0x75BA_95FC_5FED_B601, 0x79FB_732B_7762_2510, 0x1890_5F76_A537_55C6, 0, 0]),
                y: Field(montgomery: [0xDDF2_5357_CE95_560A, 0x8B4A_B8E4_BA19_E45C, 0xD2E8_8688_DD21_F325, 0x8571_FF18_2588_5D85, 0, 0])
            )
        }
    }

    static var squareRootExponent: InlineArray<6, UInt64> {
        @inline(__always) get { [0, 0x0000_0000_4000_0000, 0x4000_0000_0000_0000, 0x3FFF_FFFF_C000_0000, 0, 0] }
    }

    static var order: InlineArray<6, UInt64> { @inline(__always) get { P256OrderModulus.modulus } }
    static var objectIdentifier: ASN1ObjectIdentifier { .prime256v1 }
    static let generatorTable = JacobianPoint<P256Curve>.oddMultiples(of: generator, count: 64)
}

/// P-384 (secp384r1).
enum P384Curve: PrimeCurve {
    typealias Field = Residue<6, P384FieldModulus>
    typealias Scalar = Residue<6, P384OrderModulus>
    typealias Hash = SHA384

    static var b: Field {
        @inline(__always) get {
            Field(montgomery: [0x0811_8871_9D41_2DCC, 0xF729_ADD8_7A4C_32EC, 0x77F2_209B_1920_022E,
                               0xE337_4BEE_9493_8AE2, 0xB62B_21F4_1F02_2094, 0xCD08_114B_604F_BFF9])
        }
    }

    static var generator: AffinePoint<Self> {
        @inline(__always) get {
            AffinePoint(
                x: Field(montgomery: [0x3DD0_7566_49C0_B528, 0x20E3_78E2_A0D6_CE38, 0x879C_3AFC_541B_4D6E,
                                      0x6454_8684_59A3_0EFF, 0x812F_F723_614E_DE2B, 0x4D3A_ADC2_299E_1513]),
                y: Field(montgomery: [0x2304_3DAD_4B03_A4FE, 0xA1BF_A8BF_7BB4_A9AC, 0x8BAD_E756_2E83_B050,
                                      0xC6C3_5219_68F4_FFD9, 0xDD80_0226_3969_A840, 0x2B78_ABC2_5A15_C5E9])
            )
        }
    }

    static var squareRootExponent: InlineArray<6, UInt64> {
        @inline(__always) get {
            [0x0000_0000_4000_0000, 0xBFFF_FFFF_C000_0000, 0xFFFF_FFFF_FFFF_FFFF,
             0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0x3FFF_FFFF_FFFF_FFFF]
        }
    }

    static var order: InlineArray<6, UInt64> { @inline(__always) get { P384OrderModulus.modulus } }
    static var objectIdentifier: ASN1ObjectIdentifier { .secp384r1 }
    static let generatorTable = JacobianPoint<P384Curve>.oddMultiples(of: generator, count: 64)
}

// MARK: - Affine points

/// A point (x, y) on the curve, never the identity, coordinates in Montgomery form.
struct AffinePoint<C: PrimeCurve>: Sendable {
    var x: C.Field
    var y: C.Field

    @inline(__always)
    init(x: C.Field, y: C.Field) {
        self.x = x
        self.y = y
    }

    /// x³ − 3x + b: y², for a point on the curve.
    @inline(__always)
    static func rightHandSide(_ x: C.Field) -> C.Field {
        let three = C.Field.one.doubled + .one
        return (x.squared - three) * x + C.b
    }

    /// The point (x, y), or `nil` if it isn't on the curve.
    init?(validatingX x: C.Field, y: C.Field) {
        guard y.squared.equalMask(Self.rightHandSide(x)) != 0 else { return nil }
        self.init(x: x, y: y)
    }

    /// The point with coordinate x and y of the given parity, or `nil` if x³ − 3x + b isn't a square.
    init?(x: C.Field, yIsOdd: Bool) {
        let ySquared = Self.rightHandSide(x)
        let root = ySquared.power(C.squareRootExponent)
        guard root.squared.equalMask(ySquared) != 0 else { return nil }
        // A root of 0 (y = 0) has no odd form: −0 = 0, and the parity check below then fails, as it should.
        let y = root.isOdd == yIsOdd ? root : root.negated
        guard y.isOdd == yIsOdd else { return nil }
        self.init(x: x, y: y)
    }

    /// Parses X9.63's (SEC 1, 2.3.4) uncompressed form, 04 ‖ x ‖ y, or the compressed form, 02 or 03 (y's parity)
    /// ‖ x, and checks the point is on the curve. The identity's encoding (a single 00) is rejected.
    init(x963 bytes: RawSpan) throws(BytesError) {
        let count = C.byteCount
        guard bytes.byteCount > 0 else { throw .insufficientData }
        let prefix = bytes.load(fromByteOffset: 0, as: UInt8.self)
        switch prefix {
        case 0x04:
            guard bytes.byteCount == 1 &+ 2 &* count,
                  let x = C.Field(bigEndian: bytes.extracting(1..<(1 &+ count))),
                  let y = C.Field(bigEndian: bytes.extracting((1 &+ count)..<(1 &+ 2 &* count))),
                  let point = AffinePoint(validatingX: x, y: y)
            else { throw .invalidValue }
            self = point
        case 0x02, 0x03:
            guard bytes.byteCount == 1 &+ count,
                  let x = C.Field(bigEndian: bytes.extracting(1..<(1 &+ count))),
                  let point = AffinePoint(x: x, yIsOdd: prefix == 0x03)
            else { throw .invalidValue }
            self = point
        default:
            throw .invalidValue
        }
    }

    /// Writes 04 ‖ x ‖ y at the start of `output`: 1 + 2 × ``PrimeCurve/byteCount`` bytes.
    func writeX963(to output: inout MutableRawSpan) {
        output.storeBytes(of: 0x04, toByteOffset: 0, as: UInt8.self)
        x.write(bigEndianTo: &output, at: 1)
        y.write(bigEndianTo: &output, at: 1 &+ C.byteCount)
    }

    /// Writes 02 or 03 ‖ x at the start of `output`: 1 + ``PrimeCurve/byteCount`` bytes.
    func writeCompressed(to output: inout MutableRawSpan) {
        output.storeBytes(of: y.isOdd ? 0x03 : 0x02, toByteOffset: 0, as: UInt8.self)
        x.write(bigEndianTo: &output, at: 1)
    }
}

// MARK: - Jacobian points

/// A point (X : Y : Z) with x = X/Z² and y = Y/Z³; Z = 0 is the identity. `+` and `adding(_:)` branch on their
/// special cases (the identity, equal points), so they are for public values only (verification);
/// ``multiply(_:by:)`` uses `doubled` and `addingDistinct(_:)`, which don't branch, with selections around them.
struct JacobianPoint<C: PrimeCurve>: Sendable {
    var x: C.Field
    var y: C.Field
    var z: C.Field

    @inline(__always)
    init(x: C.Field, y: C.Field, z: C.Field) {
        self.x = x
        self.y = y
        self.z = z
    }

    @inline(__always)
    init(_ point: AffinePoint<C>) {
        self.init(x: point.x, y: point.y, z: .one)
    }

    static var identity: Self { @inline(__always) get { Self(x: .one, y: .one, z: .zero) } }

    var isIdentity: Bool { @inline(__always) get { z.zeroMask != 0 } }

    /// −P.
    var negated: Self { @inline(__always) get { Self(x: x, y: y.negated, z: z) } }

    /// 2P: "dbl-2001-b" for a = −3 (3 multiplications, 5 squarings). A prime-order curve has no point with y = 0,
    /// and the identity's Z stays 0, so there is no special case.
    var doubled: Self {
        let delta = z.squared
        let gamma = y.squared
        let beta = x * gamma
        let product = (x - delta) * (x + delta)
        let alpha = product.doubled + product
        let fourBeta = beta.doubled.doubled
        let x3 = alpha.squared - fourBeta.doubled
        let z3 = (y + z).squared - gamma - delta
        let y3 = alpha * (fourBeta - x3) - gamma.squared.doubled.doubled.doubled
        return Self(x: x3, y: y3, z: z3)
    }

    /// P + Q for P ≠ ±Q, neither the identity: "add-2007-bl" without its special cases, so without branches.
    /// (The result is garbage with Z = 0 otherwise.)
    @inline(__always)
    func addingDistinct(_ q: Self) -> Self {
        let z1z1 = z.squared
        let z2z2 = q.z.squared
        let u1 = x * z2z2
        let u2 = q.x * z1z1
        let s1 = y * q.z * z2z2
        let s2 = q.y * z * z1z1
        let h = u2 - u1
        let r = (s2 - s1).doubled
        let i = h.doubled.squared
        let j = h * i
        let v = u1 * i
        let x3 = r.squared - j - v.doubled
        let y3 = r * (v - x3) - (s1 * j).doubled
        let z3 = ((z + q.z).squared - z1z1 - z2z2) * h
        return Self(x: x3, y: y3, z: z3)
    }

    /// `b` where `mask` is all ones, `a` where it's 0: constant-time.
    @inline(__always)
    static func select(_ a: Self, _ b: Self, mask: UInt64) -> Self {
        Self(x: .select(a.x, b.x, mask: mask), y: .select(a.y, b.y, mask: mask), z: .select(a.z, b.z, mask: mask))
    }

    /// k·P in constant time: a fixed 4-bit window from the top, each window's multiple of P read from the table
    /// of 1P…15P by visiting every entry under a mask, and the additions' special cases chosen with masks too.
    /// The same instructions run for every k: four doublings and one addition per window.
    ///
    /// The only special cases that can arise are an accumulator still at the identity (leading zero windows) and
    /// a zero window: for k < n, the accumulator before window j's addition is 16k'·P with 16k' < n, and the entry
    /// is d·P with 0 < d < 16, so 16k' = ±d (mod n) only when k' = 0. The addition formula's result is replaced in
    /// those cases, by selection. Doubling needs no case: the identity's Z stays 0.
    ///
    /// - Parameter scalar: k's limbs, least significant first: below n, the curve's order.
    static func multiply(_ point: AffinePoint<C>, by scalar: InlineArray<6, UInt64>) -> Self {
        var table = InlineArray<16, Self>(repeating: .identity)
        table[1] = Self(point)
        for index in 2..<16 {
            // Small multiples of a point of prime order n are distinct and never the identity.
            table[index] = index & 1 == 0 ? table[index &>> 1].doubled : table[index &- 1].addingDistinct(table[1])
        }
        var accumulator = Self.identity
        let windows = C.byteCount &* 2
        for window in (0..<windows).reversed() {
            if window != windows &- 1 {
                accumulator = accumulator.doubled.doubled.doubled.doubled
            }
            let nibble = (scalar[window &>> 4] &>> UInt64((window & 15) &* 4)) & 0xF
            var entry = Self.identity
            for index in 1..<16 {
                entry = select(entry, table[index], mask: zeroMask(UInt64(index) ^ nibble))
            }
            let sum = accumulator.addingDistinct(entry)
            let chosen = select(sum, entry, mask: accumulator.z.zeroMask)
            accumulator = select(chosen, accumulator, mask: zeroMask(nibble))
        }
        return accumulator
    }

    /// The affine x coordinate, X/Z², with a constant-time inversion. (0 for the identity.)
    var affineX: C.Field {
        x * z.inverted.squared
    }

    /// The affine point, or `nil` for the identity. Constant-time apart from that answer.
    var affine: AffinePoint<C>? {
        let inverse = z.inverted
        guard z.zeroMask == 0 else { return nil }
        let inverseSquared = inverse.squared
        return AffinePoint(x: x * inverseSquared, y: y * inverseSquared * inverse)
    }

    /// P + Q: "add-2007-bl" (11 multiplications, 5 squarings), doubling when P = Q.
    static func +(p: Self, q: Self) -> Self {
        if p.isIdentity { return q }
        if q.isIdentity { return p }
        let z1z1 = p.z.squared
        let z2z2 = q.z.squared
        let u1 = p.x * z2z2
        let u2 = q.x * z1z1
        let s1 = p.y * q.z * z2z2
        let s2 = q.y * p.z * z1z1
        let h = u2 - u1
        let r = (s2 - s1).doubled
        if h.zeroMask != 0 {
            return r.zeroMask != 0 ? p.doubled : .identity
        }
        let i = h.doubled.squared
        let j = h * i
        let v = u1 * i
        let x3 = r.squared - j - v.doubled
        let y3 = r * (v - x3) - (s1 * j).doubled
        let z3 = ((p.z + q.z).squared - z1z1 - z2z2) * h
        return Self(x: x3, y: y3, z: z3)
    }

    /// P + Q with Q affine: "madd-2007-bl" (7 multiplications, 4 squarings), doubling when P = Q.
    func adding(_ q: AffinePoint<C>) -> Self {
        if isIdentity { return Self(q) }
        let z1z1 = z.squared
        let u2 = q.x * z1z1
        let s2 = q.y * z * z1z1
        let h = u2 - x
        let r = (s2 - y).doubled
        if h.zeroMask != 0 {
            return r.zeroMask != 0 ? doubled : .identity
        }
        let hh = h.squared
        let i = hh.doubled.doubled
        let j = h * i
        let v = x * i
        let x3 = r.squared - j - v.doubled
        let y3 = r * (v - x3) - (y * j).doubled
        let z3 = (z + h).squared - z1z1 - hh
        return Self(x: x3, y: y3, z: z3)
    }

    /// P, 3P, 5P, …, (2·count − 1)P in affine coordinates, with one inversion for all (Montgomery's trick).
    static func oddMultiples(of point: AffinePoint<C>, count: Int) -> [AffinePoint<C>] {
        var multiples = [Self(point)]
        multiples.reserveCapacity(count)
        let twice = Self(point).doubled
        for index in 1..<count {
            multiples.append(multiples[index &- 1] + twice)
        }
        // prefix[i] = Z₀⋯Zᵢ; then walk back with the inverse of the whole product.
        var prefix = [C.Field](repeating: .one, count: count)
        var running = C.Field.one
        for index in 0..<count {
            running = running * multiples[index].z
            prefix[index] = running
        }
        var inverse = running.inverted
        var result = [AffinePoint<C>](repeating: point, count: count)
        for index in (0..<count).reversed() {
            let zInverse = index > 0 ? inverse * prefix[index &- 1] : inverse
            inverse = inverse * multiples[index].z
            let zInverseSquared = zInverse.squared
            result[index] = AffinePoint(x: multiples[index].x * zInverseSquared, y: multiples[index].y * zInverseSquared * zInverse)
        }
        return result
    }
}

/// The width-w NAF of a scalar (`bits` bits at most): digits in (−2ʷ, 2ʷ), each odd or 0, `bits` + 1 of them, least
/// significant first. (BoringSSL's `ec_compute_wNAF`, with its modification that keeps the top digits positive so
/// no digit goes past `bits`.)
func nonAdjacentForm(_ scalar: InlineArray<6, UInt64>, bits: Int, width w: Int) -> InlineArray<385, Int8> {
    var digits = InlineArray<385, Int8>(repeating: 0)
    let bit = 1 &<< w, nextBit = bit &<< 1, mask = nextBit &- 1
    func bitAt(_ index: Int) -> Int {
        index < bits ? Int(truncatingIfNeeded: (scalar[index &>> 6] &>> UInt64(index & 63)) & 1) : 0
    }
    var window = Int(truncatingIfNeeded: scalar[0]) & mask
    for index in 0...bits {
        var digit = 0
        if window & 1 != 0 {
            if window & bit != 0 {
                digit = index &+ w &+ 1 >= bits ? window & (mask &>> 1) : window &- nextBit
            } else {
                digit = window
            }
            window &-= digit
        }
        digits[index] = Int8(truncatingIfNeeded: digit)
        window &>>= 1
        window &+= bit &* bitAt(index &+ w &+ 1)
    }
    return digits
}
