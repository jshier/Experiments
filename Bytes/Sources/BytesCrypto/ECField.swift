// Arithmetic modulo the primes of the NIST curves P-256 and P-384 (their fields, and their groups' orders), in
// Montgomery form: an element a is held as aR mod m, with R = 2^(64·limbs), so a product needs no division,
// only multiplications by the modulus (Montgomery's REDC, interleaved with the product: CIOS). One generic
// implementation over the limb count (4 or 6) and the modulus' constants, specialized for each.
//
// Constant time: every operation here takes the same instructions for any value. Carries and borrows are
// arithmetic, and the conditional subtraction after each operation picks its result with masks, not branches.
// The exponentiations (inversion, square root) branch only on bits of their exponent, a public constant.

/// The constants of a Montgomery modulus m: everything is little-endian 64-bit limbs, six of them, of which a
/// 4-limb modulus uses the first four.
protocol MontgomeryModulus: Sendable {
    /// m.
    static var modulus: InlineArray<6, UInt64> { get }
    /// −m⁻¹ mod 2⁶⁴: the multiplier that makes each reduction step's low limb vanish.
    static var negativeInverse: UInt64 { get }
    /// R² mod m: multiplying by it (Montgomery's way) takes a value into Montgomery form.
    static var rSquared: InlineArray<6, UInt64> { get }
    /// R mod m: one, in Montgomery form.
    static var one: InlineArray<6, UInt64> { get }
    /// m − 2: inverting is raising to this power (Fermat), as m is prime.
    static var inversionExponent: InlineArray<6, UInt64> { get }
}

/// a·b + c + d as a 128-bit result's halves; it can't overflow: (2⁶⁴ − 1)² + 2(2⁶⁴ − 1) = 2¹²⁸ − 1.
@inline(__always)
func multiplyAdd(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) -> (high: UInt64, low: UInt64) {
    let product = UInt128(a) &* UInt128(b) &+ UInt128(c) &+ UInt128(d)
    return (UInt64(truncatingIfNeeded: product &>> 64), UInt64(truncatingIfNeeded: product))
}

/// a + b + carry, and the carry out (0 or 1).
@inline(__always)
func addWithCarry(_ a: UInt64, _ b: UInt64, _ carry: UInt64) -> (sum: UInt64, carry: UInt64) {
    let sum = UInt128(a) &+ UInt128(b) &+ UInt128(carry)
    return (UInt64(truncatingIfNeeded: sum), UInt64(truncatingIfNeeded: sum &>> 64))
}

/// a − b − borrow, and the borrow out (0 or 1).
@inline(__always)
func subtractWithBorrow(_ a: UInt64, _ b: UInt64, _ borrow: UInt64) -> (difference: UInt64, borrow: UInt64) {
    let difference = UInt128(a) &- UInt128(b) &- UInt128(borrow)
    return (UInt64(truncatingIfNeeded: difference), UInt64(truncatingIfNeeded: difference &>> 64) & 1)
}

/// All ones if `value` is zero, else zero, without a branch.
@inline(__always)
func zeroMask(_ value: UInt64) -> UInt64 {
    // `value | −value` has its top bit set exactly when value ≠ 0.
    ((value | (0 &- value)) &>> 63) &- 1
}

/// What point arithmetic needs of a field (and ECDSA of the scalars): one protocol so that the curve code can be
/// generic, while every call is specialized to a `Residue` of known size.
protocol ModularArithmetic: Sendable {
    /// The size of a canonical big-endian encoding: 32 or 48.
    static var byteCount: Int { get }
    static var zero: Self { get }
    static var one: Self { get }

    static func +(a: Self, b: Self) -> Self
    static func -(a: Self, b: Self) -> Self
    static func *(a: Self, b: Self) -> Self
    /// self · self.
    var squared: Self { get }
    /// self + self.
    var doubled: Self { get }
    /// −self.
    var negated: Self { get }
    /// self⁻¹ (0 for 0), by Fermat's little theorem: constant-time.
    var inverted: Self { get }
    /// self⁻¹ (0 for 0) in variable time: for public values only.
    var invertedVariableTime: Self { get }
    /// All ones if self is 0, else 0: constant-time.
    var zeroMask: UInt64 { get }
    /// All ones if self equals `other`, else 0: constant-time.
    func equalMask(_ other: Self) -> UInt64
    /// `b` where `mask` is all ones, `a` where it is 0: constant-time.
    static func select(_ a: Self, _ b: Self, mask: UInt64) -> Self
    /// The value of `bytes`, big-endian, exactly ``byteCount`` of them; `nil` if it is m or more.
    init?(bigEndian bytes: RawSpan)
    /// The value of `bytes` (big-endian, exactly ``byteCount`` of them) mod m, for moduli above 2^(8·byteCount − 1):
    /// one conditional subtraction.
    init(reducingBigEndian bytes: RawSpan)
    /// Writes the canonical value big-endian at `offset` in `output`: ``byteCount`` bytes.
    func write(bigEndianTo output: inout MutableRawSpan, at offset: Int)
    /// The value of `words` (least significant first; limbs beyond the modulus' must be 0); `nil` if it is m or
    /// more.
    init?(canonicalWords words: InlineArray<6, UInt64>)
    /// The canonical value's limbs, least significant first, zero-extended to six.
    var canonicalWords: InlineArray<6, UInt64> { get }
    /// The value's lowest bit (its parity), canonically.
    var isOdd: Bool { get }
    /// self^exponent, the exponent public: branches on its bits.
    func power(_ exponent: InlineArray<6, UInt64>) -> Self
}

/// An integer mod `M.modulus` in Montgomery form, `limbs` 64-bit limbs.
struct Residue<let limbs: Int, M: MontgomeryModulus>: ModularArithmetic {
    /// aR mod m, least significant limb first, always fully reduced (below m).
    var words: InlineArray<limbs, UInt64>

    @inline(__always)
    init(montgomeryWords words: InlineArray<limbs, UInt64>) {
        self.words = words
    }

    /// The first `limbs` of a six-limb constant.
    @inline(__always)
    static func constant(_ value: InlineArray<6, UInt64>) -> InlineArray<limbs, UInt64> {
        var words = InlineArray<limbs, UInt64>(repeating: 0)
        for index in 0..<limbs {
            words[index] = value[index]
        }
        return words
    }

    /// A constant already in Montgomery form (the curves' b and generator, computed offline).
    @inline(__always)
    init(montgomery value: InlineArray<6, UInt64>) {
        words = Self.constant(value)
    }

    static var byteCount: Int { @inline(__always) get { limbs &* 8 } }

    static var zero: Self { @inline(__always) get { Self(montgomeryWords: .init(repeating: 0)) } }

    static var one: Self { @inline(__always) get { Self(montgomery: M.one) } }

    /// t + top·R − m if that isn't negative, else t: the final step of each operation, for t + top·R < 2m.
    @inline(__always)
    static func subtractModulusIfAbove(_ t: InlineArray<limbs, UInt64>, top: UInt64) -> InlineArray<limbs, UInt64> {
        var difference = InlineArray<limbs, UInt64>(repeating: 0)
        var borrow: UInt64 = 0
        for index in 0..<limbs {
            (difference[index], borrow) = subtractWithBorrow(t[index], M.modulus[index], borrow)
        }
        // Negative exactly when the borrow out exceeds the top word (both 0 or 1).
        let keep = 0 &- (borrow & ~top & 1)
        var result = InlineArray<limbs, UInt64>(repeating: 0)
        for index in 0..<limbs {
            result[index] = (t[index] & keep) | (difference[index] & ~keep)
        }
        return result
    }

    @inline(__always)
    static func +(a: Self, b: Self) -> Self {
        var sum = InlineArray<limbs, UInt64>(repeating: 0)
        var carry: UInt64 = 0
        for index in 0..<limbs {
            (sum[index], carry) = addWithCarry(a.words[index], b.words[index], carry)
        }
        return Self(montgomeryWords: subtractModulusIfAbove(sum, top: carry))
    }

    @inline(__always)
    static func -(a: Self, b: Self) -> Self {
        var difference = InlineArray<limbs, UInt64>(repeating: 0)
        var borrow: UInt64 = 0
        for index in 0..<limbs {
            (difference[index], borrow) = subtractWithBorrow(a.words[index], b.words[index], borrow)
        }
        // Add m back where the difference went negative.
        let mask = 0 &- borrow
        var carry: UInt64 = 0
        for index in 0..<limbs {
            (difference[index], carry) = addWithCarry(difference[index], M.modulus[index] & mask, carry)
        }
        return Self(montgomeryWords: difference)
    }

    var doubled: Self { @inline(__always) get { self + self } }

    var negated: Self { @inline(__always) get { Self.zero - self } }

    /// Montgomery's product abR⁻¹ mod m, interleaving the multiplication with the reduction (CIOS): after
    /// each row, a multiple of m clears the lowest limb, which is dropped.
    @inline(__always)
    static func montgomeryProduct(_ a: InlineArray<limbs, UInt64>, _ b: InlineArray<limbs, UInt64>) -> InlineArray<limbs, UInt64> {
        var t = InlineArray<limbs, UInt64>(repeating: 0)
        var top: UInt64 = 0
        // LLVM leaves the row loop rolled, `t` in memory; written out for the curves' sizes, `t` stays in registers.
        if limbs == 4 {
            montgomeryRow(a, b[0], &t, &top)
            montgomeryRow(a, b[1], &t, &top)
            montgomeryRow(a, b[2], &t, &top)
            montgomeryRow(a, b[3], &t, &top)
        } else if limbs == 6 {
            montgomeryRow(a, b[0], &t, &top)
            montgomeryRow(a, b[1], &t, &top)
            montgomeryRow(a, b[2], &t, &top)
            montgomeryRow(a, b[3], &t, &top)
            montgomeryRow(a, b[4], &t, &top)
            montgomeryRow(a, b[5], &t, &top)
        } else {
            for row in 0..<limbs {
                montgomeryRow(a, b[row], &t, &top)
            }
        }
        return subtractModulusIfAbove(t, top: top)
    }

    /// One CIOS row: t += a·multiplier, then t = (t + m·modulus) / 2⁶⁴ with m chosen to clear the low limb.
    @inline(__always)
    static func montgomeryRow(_ a: InlineArray<limbs, UInt64>, _ multiplier: UInt64, _ t: inout InlineArray<limbs, UInt64>, _ top: inout UInt64) {
        var carry: UInt64 = 0
        for column in 0..<limbs {
            (carry, t[column]) = multiplyAdd(a[column], multiplier, t[column], carry)
        }
        let (sum, overflow) = addWithCarry(top, carry, 0)
        let m = t[0] &* M.negativeInverse
        var (reduction, _) = multiplyAdd(m, M.modulus[0], t[0], 0)
        for column in 1..<limbs {
            (reduction, t[column &- 1]) = multiplyAdd(m, M.modulus[column], t[column], reduction)
        }
        let last: UInt64
        (last, carry) = addWithCarry(sum, reduction, 0)
        t[limbs &- 1] = last
        top = overflow &+ carry
    }

    @inline(__always)
    static func *(a: Self, b: Self) -> Self {
        Self(montgomeryWords: montgomeryProduct(a.words, b.words))
    }

    /// a²R⁻¹ mod m: the square's cross products once, doubled, plus the diagonal (n(n + 1)/2 products instead of
    /// n²), then the reduction one limb at a time (SOS).
    @inline(__always)
    static func montgomerySquare(_ a: InlineArray<limbs, UInt64>) -> InlineArray<limbs, UInt64> {
        var t = InlineArray<12, UInt64>(repeating: 0) // 2 × limbs, at most 12.
        // Cross products aᵢaⱼ, i < j.
        for i in 0..<(limbs &- 1) {
            var carry: UInt64 = 0
            for j in (i &+ 1)..<limbs {
                (carry, t[i &+ j]) = multiplyAdd(a[i], a[j], t[i &+ j], carry)
            }
            t[i &+ limbs] = carry
        }
        // Doubled, plus the squares aᵢ² on the diagonal.
        var shiftedOut: UInt64 = 0
        var carry: UInt64 = 0
        for i in 0..<limbs {
            let (high, low) = a[i].multipliedFullWidth(by: a[i])
            let lowWord = t[2 &* i], highWord = t[2 &* i &+ 1]
            let doubledLow = lowWord &<< 1 | shiftedOut
            let doubledHigh = highWord &<< 1 | lowWord &>> 63
            shiftedOut = highWord &>> 63
            (t[2 &* i], carry) = addWithCarry(doubledLow, low, carry)
            (t[2 &* i &+ 1], carry) = addWithCarry(doubledHigh, high, carry)
        }
        // Reduction: each step clears limb i with a multiple of m; carries out of limb i + limbs go to the next.
        var extra: UInt64 = 0
        if limbs == 6 {
            // Written out, as the product's rows are: rolled, LLVM keeps `t` in memory.
            reductionStep(0, &t, &extra)
            reductionStep(1, &t, &extra)
            reductionStep(2, &t, &extra)
            reductionStep(3, &t, &extra)
            reductionStep(4, &t, &extra)
            reductionStep(5, &t, &extra)
        } else {
            for i in 0..<limbs {
                reductionStep(i, &t, &extra)
            }
        }
        var result = InlineArray<limbs, UInt64>(repeating: 0)
        for index in 0..<limbs {
            result[index] = t[limbs &+ index]
        }
        return subtractModulusIfAbove(result, top: extra)
    }

    /// One step of the square's reduction: clears limb `i` of `t` with a multiple of m; the carry out of limb
    /// i + limbs goes on to the next step in `extra`.
    @inline(__always)
    static func reductionStep(_ i: Int, _ t: inout InlineArray<12, UInt64>, _ extra: inout UInt64) {
        let m = t[i] &* M.negativeInverse
        var reduction: UInt64 = 0
        for j in 0..<limbs {
            (reduction, t[i &+ j]) = multiplyAdd(m, M.modulus[j], t[i &+ j], reduction)
        }
        (t[i &+ limbs], extra) = addWithCarry(t[i &+ limbs], reduction, extra)
    }

    /// self · self. The dedicated square saved P-384 3–4% of its instructions and cost P-256 3–5%, even with its
    /// reduction written out (Benchmarks/RESULTS-ecc.md): only 6-limb moduli use it.
    var squared: Self {
        @inline(__always) get {
            limbs > 4 ? Self(montgomeryWords: Self.montgomerySquare(words)) : self * self
        }
    }

    var zeroMask: UInt64 {
        @inline(__always) get {
            var bits: UInt64 = 0
            for index in 0..<limbs {
                bits |= words[index]
            }
            return BytesCrypto.zeroMask(bits)
        }
    }

    @inline(__always)
    func equalMask(_ other: Self) -> UInt64 {
        var bits: UInt64 = 0
        for index in 0..<limbs {
            bits |= words[index] ^ other.words[index]
        }
        return BytesCrypto.zeroMask(bits)
    }

    @inline(__always)
    static func select(_ a: Self, _ b: Self, mask: UInt64) -> Self {
        var words = InlineArray<limbs, UInt64>(repeating: 0)
        for index in 0..<limbs {
            words[index] = (a.words[index] & ~mask) | (b.words[index] & mask)
        }
        return Self(montgomeryWords: words)
    }

    func power(_ exponent: InlineArray<6, UInt64>) -> Self {
        // A fixed 4-bit window: self⁰…self¹⁵, then four squarings and one multiplication per nibble.
        var table = InlineArray<16, Self>(repeating: .one)
        table[1] = self
        for index in 2..<16 {
            table[index] = table[index &- 1] * self
        }
        var result = Self.one
        var started = false
        for limb in (0..<limbs).reversed() {
            let word = exponent[limb]
            for shift in stride(from: 60, through: 0, by: -4) {
                if started { result = result.squared.squared.squared.squared }
                let nibble = Int(truncatingIfNeeded: (word &>> UInt64(shift)) & 0xF)
                // The exponent is public: skipping its zero nibbles reveals nothing.
                if nibble != 0 {
                    result = started ? result * table[nibble] : table[nibble]
                    started = true
                }
            }
        }
        return result
    }

    var inverted: Self { power(M.inversionExponent) }

    /// self⁻¹ (0 for 0) by the binary extended Euclidean algorithm. Variable-time, its branches following the
    /// value's bits: for public values only (ECDSA verification's s). A few hundred shifts and subtractions in place
    /// of Fermat's few hundred multiplications.
    var invertedVariableTime: Self {
        var u = canonical
        guard BytesCrypto.zeroMask(u.orAll) == 0 else { return .zero }
        var v = Self.constant(M.modulus)
        var x1 = InlineArray<limbs, UInt64>(repeating: 0)
        var x2 = InlineArray<limbs, UInt64>(repeating: 0)
        x1[0] = 1
        // Invariants: x1·a ≡ u and x2·a ≡ v (mod m), with u and v odd after the halving loops; gcd(u, v) = 1.
        while !u.isOne && !v.isOne {
            while u[0] & 1 == 0 {
                u.shiftRightOne(top: 0)
                Self.halve(&x1)
            }
            while v[0] & 1 == 0 {
                v.shiftRightOne(top: 0)
                Self.halve(&x2)
            }
            if u.isAtLeast(v) {
                _ = u.subtract(v)
                x1 = Self.subtractModular(x1, x2)
            } else {
                _ = v.subtract(u)
                x2 = Self.subtractModular(x2, x1)
            }
        }
        // Back into Montgomery form: x·R² · R⁻¹.
        return Self(montgomeryWords: Self.montgomeryProduct(u.isOne ? x1 : x2, Self.constant(M.rSquared)))
    }

    /// x/2 mod m, m odd: x or x + m, whichever is even, shifted down.
    @inline(__always)
    static func halve(_ x: inout InlineArray<limbs, UInt64>) {
        if x[0] & 1 == 0 {
            x.shiftRightOne(top: 0)
        } else {
            let carry = x.add(constant(M.modulus))
            x.shiftRightOne(top: carry)
        }
    }

    /// a − b mod m, for a and b below m.
    @inline(__always)
    static func subtractModular(_ a: InlineArray<limbs, UInt64>, _ b: InlineArray<limbs, UInt64>) -> InlineArray<limbs, UInt64> {
        var result = a
        if result.subtract(b) != 0 { _ = result.add(constant(M.modulus)) }
        return result
    }

    init?(bigEndian bytes: RawSpan) {
        guard bytes.byteCount == limbs &* 8 else { return nil }
        var value = InlineArray<6, UInt64>(repeating: 0)
        for index in 0..<limbs {
            value[index] = UInt64(bigEndian: bytes.load(fromByteOffset: (limbs &- 1 &- index) &* 8, as: UInt64.self))
        }
        self.init(canonicalWords: value)
    }

    init?(canonicalWords canonical: InlineArray<6, UInt64>) {
        var high: UInt64 = 0
        for index in limbs..<6 {
            high |= canonical[index]
        }
        guard high == 0 else { return nil }
        let value = Self.constant(canonical)
        var borrow: UInt64 = 0
        for index in 0..<limbs {
            (_, borrow) = subtractWithBorrow(value[index], M.modulus[index], borrow)
        }
        guard borrow == 1 else { return nil }
        words = Self.montgomeryProduct(value, Self.constant(M.rSquared))
    }

    init(reducingBigEndian bytes: RawSpan) {
        precondition(bytes.byteCount == limbs &* 8, "A scalar is \(limbs &* 8) bytes")
        var value = InlineArray<limbs, UInt64>(repeating: 0)
        for index in 0..<limbs {
            value[index] = UInt64(bigEndian: bytes.load(fromByteOffset: (limbs &- 1 &- index) &* 8, as: UInt64.self))
        }
        words = Self.montgomeryProduct(Self.subtractModulusIfAbove(value, top: 0), Self.constant(M.rSquared))
    }

    /// The value out of Montgomery form: aR · 1 · R⁻¹.
    var canonical: InlineArray<limbs, UInt64> {
        @inline(__always) get {
            var one = InlineArray<limbs, UInt64>(repeating: 0)
            one[0] = 1
            return Self.montgomeryProduct(words, one)
        }
    }

    var canonicalWords: InlineArray<6, UInt64> {
        let value = canonical
        var words = InlineArray<6, UInt64>(repeating: 0)
        for index in 0..<limbs {
            words[index] = value[index]
        }
        return words
    }

    var isOdd: Bool { canonical[0] & 1 == 1 }

    func write(bigEndianTo output: inout MutableRawSpan, at offset: Int) {
        let value = canonical
        for index in 0..<limbs {
            output.storeBytes(of: value[index].bigEndian, toByteOffset: offset &+ (limbs &- 1 &- index) &* 8, as: UInt64.self)
        }
    }
}

/// Multi-limb integer steps for the binary inversion (least significant limb first).
extension InlineArray where Element == UInt64 {
    /// The OR of every limb: zero exactly when the value is.
    var orAll: UInt64 {
        @inline(__always) get {
            var bits: UInt64 = 0
            for index in 0..<count {
                bits |= self[index]
            }
            return bits
        }
    }

    /// Whether the value is 1.
    var isOne: Bool {
        @inline(__always) get {
            var high: UInt64 = 0
            for index in 1..<count {
                high |= self[index]
            }
            return self[0] == 1 && high == 0
        }
    }

    /// Whether the value is at least `other`'s.
    @inline(__always)
    func isAtLeast(_ other: Self) -> Bool {
        var borrow: UInt64 = 0
        for index in 0..<count {
            (_, borrow) = subtractWithBorrow(self[index], other[index], borrow)
        }
        return borrow == 0
    }

    /// self −= other; returns the borrow out (1 if it wrapped).
    @inline(__always)
    mutating func subtract(_ other: Self) -> UInt64 {
        var borrow: UInt64 = 0
        for index in 0..<count {
            (self[index], borrow) = subtractWithBorrow(self[index], other[index], borrow)
        }
        return borrow
    }

    /// self += other; returns the carry out.
    @inline(__always)
    mutating func add(_ other: Self) -> UInt64 {
        var carry: UInt64 = 0
        for index in 0..<count {
            (self[index], carry) = addWithCarry(self[index], other[index], carry)
        }
        return carry
    }

    /// self >>= 1, with `top` (0 or 1) shifted in at the most significant bit.
    @inline(__always)
    mutating func shiftRightOne(top: UInt64) {
        for index in 0..<(count &- 1) {
            self[index] = self[index] &>> 1 | self[index &+ 1] &<< 63
        }
        self[count &- 1] = self[count &- 1] &>> 1 | top &<< 63
    }
}
