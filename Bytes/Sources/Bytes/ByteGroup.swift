/// A fixed run of 2 to 16 bytes, as they appear in memory, with no byte order applied yet.
///
/// ``Byte2`` through ``Byte16`` conform. Read one with `read(_:)`, then interpret it
/// with ``littleEndian`` or ``bigEndian``, or read the integer directly with
/// ``BytesReader/read(_:_:)``. Odd widths, such as the 24-bit lengths common in media and network formats,
/// work the same as the standard ones:
///
/// ```swift
/// let length = try reader.read(Byte3.self, .bigEndian) // UInt32
/// ```
///
/// Write constants, such as file signatures, as hexadecimal literals whose digits are the bytes in memory
/// order, as a hex dump shows them, or as array literals of the bytes:
///
/// ```swift
/// let signature: Byte4 = 0x50_4B_03_04         // the bytes 50 4B 03 04
/// let same: Byte4 = [0x50, 0x4B, 0x03, 0x04]
/// ```
///
/// To conform your own type, use 2 through 16 bytes, the narrowest `Integer` that holds them, and make
/// `init(littleEndian:)` keep only the low `byteCount` bytes. For fixed-size values that aren't integers,
/// conform to ``ByteRepresentable`` instead.
public protocol ByteGroup: BitwiseCopyable, Hashable, Sendable, ExpressibleByArrayLiteral, ExpressibleByIntegerLiteral,
    CustomStringConvertible
    where ArrayLiteralElement == UInt8, IntegerLiteralType == Integer {
    /// The narrowest standard unsigned integer that holds `byteCount` bytes.
    associatedtype Integer: FixedWidthInteger & UnsignedInteger & ConvertibleFromBytes

    /// The number of bytes, 2 through 16.
    static var byteCount: Int { get }

    /// The bytes read as a little-endian integer: the first byte is the least significant.
    var littleEndian: Integer { get }

    /// The bytes read as a big-endian integer: the first byte is the most significant.
    var bigEndian: Integer { get }

    /// Creates a value from the low `byteCount` bytes of `value`, least significant byte first.
    ///
    /// - Parameter value: The integer; bytes above `byteCount` are discarded.
    init(littleEndian value: Integer)
}

public extension ByteGroup {
    /// A mask of the low `byteCount` bytes of ``Integer``.
    @inlinable @_transparent
    internal static var _mask: Integer { Integer.max &>> (Integer.bitWidth &- 8 &* byteCount) }

    /// The bytes read as a big-endian integer: the first byte is the most significant.
    @inlinable
    var bigEndian: Integer {
        littleEndian.byteSwapped &>> (Integer.bitWidth &- 8 &* Self.byteCount)
    }

    /// Creates a value from the low `byteCount` bytes of `value`, most significant byte first.
    ///
    /// - Parameter value: The integer; bytes above `byteCount` are discarded.
    @inlinable
    init(bigEndian value: Integer) {
        // Byte-swapping moves the low `byteCount` bytes to the top; shifting brings them back down, reversed.
        self.init(littleEndian: value.byteSwapped &>> (Integer.bitWidth &- 8 &* Self.byteCount))
    }

    /// The bytes read as an integer in `byteOrder`.
    ///
    /// - Parameter byteOrder: Which end holds the most significant byte.
    /// - Returns: The integer, with the group's bytes in its low `byteCount` bytes.
    @inlinable @inline(__always)
    func integer(_ byteOrder: ByteOrder) -> Integer {
        switch byteOrder {
        case .littleEndian: littleEndian
        case .bigEndian: bigEndian
        }
    }

    /// The bytes as a two's-complement signed integer in `byteOrder`, sign-extended to `I`: for signed
    /// fields of odd widths, such as 24-bit audio samples.
    ///
    /// ```swift
    /// let sample = try reader.read(Byte3.self).signedInteger(.bigEndian, as: Int32.self) // FF FF FE → -2
    /// ```
    ///
    /// - Parameters:
    ///   - byteOrder: Which end holds the most significant byte.
    ///   - type: The signed integer type to return; defaults to `Int`.
    /// - Returns: The sign-extended value.
    /// - Precondition: `I` is at least as wide as the group.
    @inlinable @inline(__always)
    func signedInteger<I: FixedWidthInteger & SignedInteger>(_ byteOrder: ByteOrder, as _: I.Type = Int.self) -> I {
        precondition(I.bitWidth >= 8 &* Self.byteCount, "\(I.self) is narrower than \(Self.self)")
        // The group's bits at the top of `I`, then an arithmetic shift back down copies the sign bit.
        let shift = I.bitWidth &- 8 &* Self.byteCount
        return (I(truncatingIfNeeded: integer(byteOrder)) &<< shift) &>> shift
    }

    /// Creates a value from the low `byteCount` bytes of `value`, in `byteOrder`.
    ///
    /// - Parameters:
    ///   - value: The integer; bytes above `byteCount` are discarded.
    ///   - byteOrder: Which end of the group holds `value`'s most significant byte.
    @inlinable @inline(__always)
    init(_ value: Integer, _ byteOrder: ByteOrder) {
        switch byteOrder {
        case .littleEndian: self.init(littleEndian: value)
        case .bigEndian: self.init(bigEndian: value)
        }
    }

    /// The byte at `index`, in memory order.
    ///
    /// - Parameter index: The byte's position, 0 through `byteCount - 1`.
    /// - Precondition: `index` is in range.
    @inlinable
    subscript(index: Int) -> UInt8 {
        get {
            precondition(index >= 0 && index < Self.byteCount, "Byte index \(index) out of range")
            return UInt8(truncatingIfNeeded: littleEndian &>> (8 &* index))
        }
        set {
            precondition(index >= 0 && index < Self.byteCount, "Byte index \(index) out of range")
            let shift = 8 &* index
            self = Self(littleEndian: littleEndian & ~(Integer(0xFF) &<< shift) | Integer(newValue) &<< shift)
        }
    }

    // MARK: Bitwise operators

    // Byte by byte, in memory order: byte `i` of the result comes from byte `i` of each operand, so no byte
    // order is involved. For checksums, masks (a WebSocket frame's 4-byte key), and XOR-based formats.

    /// The bitwise XOR of each byte.
    ///
    /// ```swift
    /// let unmasked = payload ^ maskingKey      // Byte4s
    /// ```
    ///
    /// - Parameters:
    ///   - lhs: The first operand.
    ///   - rhs: The second operand.
    @inlinable @inline(__always)
    static func ^(lhs: Self, rhs: Self) -> Self { Self(littleEndian: lhs.littleEndian ^ rhs.littleEndian) }

    /// The bitwise AND of each byte.
    ///
    /// - Parameters:
    ///   - lhs: The first operand.
    ///   - rhs: The second operand.
    @inlinable @inline(__always)
    static func &(lhs: Self, rhs: Self) -> Self { Self(littleEndian: lhs.littleEndian & rhs.littleEndian) }

    /// The bitwise OR of each byte.
    ///
    /// - Parameters:
    ///   - lhs: The first operand.
    ///   - rhs: The second operand.
    @inlinable @inline(__always)
    static func |(lhs: Self, rhs: Self) -> Self { Self(littleEndian: lhs.littleEndian | rhs.littleEndian) }

    /// Each byte's bits inverted.
    ///
    /// - Parameter value: The operand.
    @inlinable @inline(__always)
    static prefix func ~(value: Self) -> Self { Self(littleEndian: ~value.littleEndian) }

    /// Whether the bits selected by `mask` equal `value`'s: a header's version and must-be-zero bits
    /// checked in one test. Both are in memory order, like any group literal.
    ///
    /// ```swift
    /// // Bytes 0–1: anything; byte 2: 0x01; byte 3: top bit clear.
    /// guard header.matches(0x00_00_01_00, mask: 0x00_00_FF_80) else { … }
    /// ```
    ///
    /// - Parameters:
    ///   - value: The expected bits, with every bit outside `mask` clear (checked by an assertion).
    ///   - mask: The bits to compare.
    /// - Returns: `true` if `self & mask == value`.
    @inlinable @inline(__always)
    func matches(_ value: Self, mask: Self) -> Bool {
        assert(value & ~mask == Self(littleEndian: 0), "The value has bits outside the mask")
        return self & mask == value
    }

    @inlinable @inline(__always)
    static func ^=(lhs: inout Self, rhs: Self) { lhs = lhs ^ rhs }

    @inlinable @inline(__always)
    static func &=(lhs: inout Self, rhs: Self) { lhs = lhs & rhs }

    @inlinable @inline(__always)
    static func |=(lhs: inout Self, rhs: Self) { lhs = lhs | rhs }

    /// The first `H.byteCount` bytes, as `H`.
    @inlinable @inline(__always)
    internal func _lowHalf<H: ByteGroup>(_: H.Type) -> H {
        H(littleEndian: H.Integer(truncatingIfNeeded: littleEndian))
    }

    /// The last `H.byteCount` bytes, as `H`.
    @inlinable @inline(__always)
    internal func _highHalf<H: ByteGroup>(_: H.Type) -> H {
        H(littleEndian: H.Integer(truncatingIfNeeded: littleEndian &>> (8 &* H.byteCount)))
    }

    /// Replaces the first `H.byteCount` bytes.
    ///
    /// - Parameter half: The new first bytes.
    @inlinable @inline(__always)
    internal mutating func _setLowHalf<H: ByteGroup>(_ half: H) {
        let mask = Integer(truncatingIfNeeded: H._mask)
        self = Self(littleEndian: littleEndian & ~mask | Integer(truncatingIfNeeded: half.littleEndian))
    }

    /// Replaces the last `H.byteCount` bytes.
    ///
    /// - Parameter half: The new last bytes.
    @inlinable @inline(__always)
    internal mutating func _setHighHalf<H: ByteGroup>(_ half: H) {
        let shift = 8 &* H.byteCount
        let mask = Integer(truncatingIfNeeded: H._mask) &<< shift
        self = Self(littleEndian: littleEndian & ~mask | Integer(truncatingIfNeeded: half.littleEndian) &<< shift)
    }
}

// MARK: - Halves

// Each even-width group splits into two of the next size down, in memory order like SIMD vectors:
// `lowHalf` is the first bytes, `highHalf` the last. (Read as little-endian, the low half is also the
// numerically low part.)

public extension Byte2 {
    /// The first byte.
    @inlinable
    var lowHalf: Byte {
        get { Byte(_unchecked: UInt8(truncatingIfNeeded: littleEndian)) }
        set { self[0] = newValue.rawValue }
    }

    /// The second byte.
    @inlinable
    var highHalf: Byte {
        get { Byte(_unchecked: UInt8(truncatingIfNeeded: littleEndian &>> 8)) }
        set { self[1] = newValue.rawValue }
    }

    /// Creates a group from its two bytes, in memory order.
    ///
    /// - Parameters:
    ///   - lowHalf: The first byte.
    ///   - highHalf: The second byte.
    @inlinable
    init(lowHalf: Byte, highHalf: Byte) {
        self.init(littleEndian: UInt16(highHalf.rawValue) &<< 8 | UInt16(lowHalf.rawValue))
    }
}

public extension Byte4 {
    /// The first two bytes.
    @inlinable var lowHalf: Byte2 { get { _lowHalf(Byte2.self) } set { _setLowHalf(newValue) } }
    /// The last two bytes.
    @inlinable var highHalf: Byte2 { get { _highHalf(Byte2.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    ///
    /// - Parameters:
    ///   - lowHalf: The first two bytes.
    ///   - highHalf: The last two bytes.
    @inlinable init(lowHalf: Byte2, highHalf: Byte2) {
        self.init(littleEndian: UInt32(highHalf.littleEndian) &<< 16 | UInt32(lowHalf.littleEndian))
    }
}

public extension Byte6 {
    /// The first three bytes.
    @inlinable var lowHalf: Byte3 { get { _lowHalf(Byte3.self) } set { _setLowHalf(newValue) } }
    /// The last three bytes.
    @inlinable var highHalf: Byte3 { get { _highHalf(Byte3.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    ///
    /// - Parameters:
    ///   - lowHalf: The first three bytes.
    ///   - highHalf: The last three bytes.
    @inlinable init(lowHalf: Byte3, highHalf: Byte3) {
        self.init(littleEndian: UInt64(highHalf.littleEndian) &<< 24 | UInt64(lowHalf.littleEndian))
    }
}

public extension Byte8 {
    /// The first four bytes.
    @inlinable var lowHalf: Byte4 { get { _lowHalf(Byte4.self) } set { _setLowHalf(newValue) } }
    /// The last four bytes.
    @inlinable var highHalf: Byte4 { get { _highHalf(Byte4.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    ///
    /// - Parameters:
    ///   - lowHalf: The first four bytes.
    ///   - highHalf: The last four bytes.
    @inlinable init(lowHalf: Byte4, highHalf: Byte4) {
        self.init(littleEndian: UInt64(highHalf.littleEndian) &<< 32 | UInt64(lowHalf.littleEndian))
    }
}

public extension Byte10 {
    /// The first five bytes.
    @inlinable var lowHalf: Byte5 { get { _lowHalf(Byte5.self) } set { _setLowHalf(newValue) } }
    /// The last five bytes.
    @inlinable var highHalf: Byte5 { get { _highHalf(Byte5.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    ///
    /// - Parameters:
    ///   - lowHalf: The first five bytes.
    ///   - highHalf: The last five bytes.
    @inlinable init(lowHalf: Byte5, highHalf: Byte5) {
        self.init(littleEndian: UInt128(highHalf.littleEndian) &<< 40 | UInt128(lowHalf.littleEndian))
    }
}

public extension Byte12 {
    /// The first six bytes.
    @inlinable var lowHalf: Byte6 { get { _lowHalf(Byte6.self) } set { _setLowHalf(newValue) } }
    /// The last six bytes.
    @inlinable var highHalf: Byte6 { get { _highHalf(Byte6.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    ///
    /// - Parameters:
    ///   - lowHalf: The first six bytes.
    ///   - highHalf: The last six bytes.
    @inlinable init(lowHalf: Byte6, highHalf: Byte6) {
        self.init(littleEndian: UInt128(highHalf.littleEndian) &<< 48 | UInt128(lowHalf.littleEndian))
    }
}

public extension Byte14 {
    /// The first seven bytes.
    @inlinable var lowHalf: Byte7 { get { _lowHalf(Byte7.self) } set { _setLowHalf(newValue) } }
    /// The last seven bytes.
    @inlinable var highHalf: Byte7 { get { _highHalf(Byte7.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    ///
    /// - Parameters:
    ///   - lowHalf: The first seven bytes.
    ///   - highHalf: The last seven bytes.
    @inlinable init(lowHalf: Byte7, highHalf: Byte7) {
        self.init(littleEndian: UInt128(highHalf.littleEndian) &<< 56 | UInt128(lowHalf.littleEndian))
    }
}

public extension Byte16 {
    /// The first eight bytes.
    @inlinable var lowHalf: Byte8 { get { _lowHalf(Byte8.self) } set { _setLowHalf(newValue) } }
    /// The last eight bytes.
    @inlinable var highHalf: Byte8 { get { _highHalf(Byte8.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    ///
    /// - Parameters:
    ///   - lowHalf: The first eight bytes.
    ///   - highHalf: The last eight bytes.
    @inlinable init(lowHalf: Byte8, highHalf: Byte8) {
        self.init(littleEndian: UInt128(highHalf.littleEndian) &<< 64 | UInt128(lowHalf.littleEndian))
    }

    /// The bytes as a vector, in memory order: lane `i` is byte `i`. A bit cast, no instructions.
    ///
    /// Building a constant vector with a few lanes that vary at run time is cheaper this way than
    /// with `SIMD16`'s lane initializer or subscript, which Swift 6.4 compiles to one lane insert each:
    ///
    /// ```swift
    /// var last: Byte16 = 0x77_78_79_7A_30_31_32_33_34_35_36_37_38_39_00_00
    /// last[14] = character62
    /// last[15] = character63
    /// let table = last.vector   // 12 scalar instructions and a move, against 16 inserts
    /// ```
    @inlinable @inline(__always)
    var vector: SIMD16<UInt8> {
        #if _endian(little)
        bitCast(littleEndian, to: SIMD16<UInt8>.self)
        #else
        bitCast(littleEndian.byteSwapped, to: SIMD16<UInt8>.self)
        #endif
    }

    /// Creates a group from a vector's lanes, in memory order: byte `i` is lane `i`.
    ///
    /// - Parameter vector: The 16 bytes.
    @inlinable @inline(__always)
    init(_ vector: SIMD16<UInt8>) {
        #if _endian(little)
        self.init(littleEndian: bitCast(vector, to: UInt128.self))
        #else
        self.init(littleEndian: bitCast(vector, to: UInt128.self).byteSwapped)
        #endif
    }
}

public extension ByteGroup {
    /// Creates a value from exactly `byteCount` bytes, in memory order.
    ///
    /// - Parameter elements: The bytes.
    /// - Precondition: `elements.count == byteCount`.
    @inlinable
    init(arrayLiteral elements: UInt8...) {
        precondition(elements.count == Self.byteCount, "\(Self.self) needs exactly \(Self.byteCount) bytes")
        var value: Integer = 0
        for (index, byte) in elements.enumerated() {
            value |= Integer(byte) &<< (8 &* index)
        }
        self.init(littleEndian: value)
    }

    /// Creates a value from a literal whose digits are the bytes in memory order: `0x50_4B_03_04` is the
    /// bytes 50 4B 03 04, as a hex dump shows them, and `0x00_04` as a ``Byte2`` is 00 04. That is, the
    /// literal is the group's big-endian value (``init(bigEndian:)``), whatever byte order the data uses:
    /// a signature or magic number reads the same in the source as in the file.
    ///
    /// A literal with more than `byteCount` bytes is an error: at compile time for ``Byte2``, ``Byte4``,
    /// ``Byte8``, and ``Byte16``, whose integers are exactly their width; a trap for the others.
    ///
    /// - Parameter value: The literal's value.
    /// - Precondition: `value` fits in `byteCount` bytes.
    @inlinable @inline(__always)
    init(integerLiteral value: Integer) {
        precondition(value <= Self._mask, "\(Self.self) literals have at most \(Self.byteCount) bytes")
        // The bytes reversed with shifts, not `init(bigEndian:)`'s byte swap: the compiler evaluates a
        // global's initializer at compile time only if it can fold every operation, and it can't fold a
        // byte swap (an LLVM intrinsic). With the swap, `static let signature: Byte4 = 0x50_4B_01_02` was
        // a lazily initialized global, checked on every use: 41% more instructions parsing zip headers.
        var littleEndian: Integer = 0
        for index in 0..<Self.byteCount {
            littleEndian |= (value &>> (8 &* index) & 0xFF) &<< (8 &* (Self.byteCount &- 1 &- index))
        }
        self.init(littleEndian: littleEndian)
    }

    /// The bytes in memory order, in hexadecimal, such as `"50 4B 03 04"`.
    var description: String {
        (0..<Self.byteCount).map { index in
            let byte = self[index]
            return (byte < 0x10 ? "0" : "") + String(byte, radix: 16, uppercase: true)
        }.joined(separator: " ")
    }
}

public extension ByteGroup where Integer == UInt128 {
    /// The bytes read as a big-endian integer: the first byte is the most significant.
    ///
    /// Computed on 64-bit halves rather than with a 128-bit byte swap and shift, so loops over
    /// ``Byte9`` through ``Byte16`` vectorize: LLVM won't vectorize 128-bit arithmetic.
    @inlinable
    var bigEndian: UInt128 {
        // Byte-swapping 128 bits swaps the halves and byte-swaps each.
        let top = UInt64(truncatingIfNeeded: littleEndian).byteSwapped
        let bottom = UInt64(truncatingIfNeeded: littleEndian &>> 64).byteSwapped
        let shift = 128 &- 8 &* Self.byteCount // 0 through 56: drops the bytes beyond `byteCount`.
        guard shift > 0 else { return UInt128(top) &<< 64 | UInt128(bottom) }
        let high = top &>> shift
        let low = bottom &>> shift | top &<< (64 &- shift)
        return UInt128(high) &<< 64 | UInt128(low)
    }
}

// MARK: - Byte2 through Byte16

/// 2 bytes, as they appear in memory.
public struct Byte2: ByteGroup {
    public let littleEndian: UInt16
    @inlinable public static var byteCount: Int { 2 }
    @inlinable public init(littleEndian value: UInt16) { littleEndian = value }
}

/// 3 bytes, as they appear in memory.
public struct Byte3: ByteGroup {
    public let littleEndian: UInt32
    @inlinable public static var byteCount: Int { 3 }
    @inlinable public init(littleEndian value: UInt32) { littleEndian = value & Self._mask }
}

/// 4 bytes, as they appear in memory.
public struct Byte4: ByteGroup {
    public let littleEndian: UInt32
    @inlinable public static var byteCount: Int { 4 }
    @inlinable public init(littleEndian value: UInt32) { littleEndian = value }
}

/// 5 bytes, as they appear in memory.
public struct Byte5: ByteGroup {
    public let littleEndian: UInt64
    @inlinable public static var byteCount: Int { 5 }
    @inlinable public init(littleEndian value: UInt64) { littleEndian = value & Self._mask }
}

/// 6 bytes, as they appear in memory.
public struct Byte6: ByteGroup {
    public let littleEndian: UInt64
    @inlinable public static var byteCount: Int { 6 }
    @inlinable public init(littleEndian value: UInt64) { littleEndian = value & Self._mask }
}

/// 7 bytes, as they appear in memory.
public struct Byte7: ByteGroup {
    public let littleEndian: UInt64
    @inlinable public static var byteCount: Int { 7 }
    @inlinable public init(littleEndian value: UInt64) { littleEndian = value & Self._mask }
}

/// 8 bytes, as they appear in memory.
public struct Byte8: ByteGroup {
    public let littleEndian: UInt64
    @inlinable public static var byteCount: Int { 8 }
    @inlinable public init(littleEndian value: UInt64) { littleEndian = value }
}

/// 9 bytes, as they appear in memory.
public struct Byte9: ByteGroup {
    public let littleEndian: UInt128
    @inlinable public static var byteCount: Int { 9 }
    @inlinable public init(littleEndian value: UInt128) { littleEndian = value & Self._mask }
}

/// 10 bytes, as they appear in memory.
public struct Byte10: ByteGroup {
    public let littleEndian: UInt128
    @inlinable public static var byteCount: Int { 10 }
    @inlinable public init(littleEndian value: UInt128) { littleEndian = value & Self._mask }
}

/// 11 bytes, as they appear in memory.
public struct Byte11: ByteGroup {
    public let littleEndian: UInt128
    @inlinable public static var byteCount: Int { 11 }
    @inlinable public init(littleEndian value: UInt128) { littleEndian = value & Self._mask }
}

/// 12 bytes, as they appear in memory.
public struct Byte12: ByteGroup {
    public let littleEndian: UInt128
    @inlinable public static var byteCount: Int { 12 }
    @inlinable public init(littleEndian value: UInt128) { littleEndian = value & Self._mask }
}

/// 13 bytes, as they appear in memory.
public struct Byte13: ByteGroup {
    public let littleEndian: UInt128
    @inlinable public static var byteCount: Int { 13 }
    @inlinable public init(littleEndian value: UInt128) { littleEndian = value & Self._mask }
}

/// 14 bytes, as they appear in memory.
public struct Byte14: ByteGroup {
    public let littleEndian: UInt128
    @inlinable public static var byteCount: Int { 14 }
    @inlinable public init(littleEndian value: UInt128) { littleEndian = value & Self._mask }
}

/// 15 bytes, as they appear in memory.
public struct Byte15: ByteGroup {
    public let littleEndian: UInt128
    @inlinable public static var byteCount: Int { 15 }
    @inlinable public init(littleEndian value: UInt128) { littleEndian = value & Self._mask }
}

/// 16 bytes, as they appear in memory.
public struct Byte16: ByteGroup {
    public let littleEndian: UInt128
    @inlinable public static var byteCount: Int { 16 }
    @inlinable public init(littleEndian value: UInt128) { littleEndian = value }
}
