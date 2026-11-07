/// A value made of `width` bits, where `width` is 1 through 8: the unit ``Bytes`` reads, and ``BytesWriter``
/// writes, below byte granularity.
///
/// Use the aliases for the common widths: ``Bit``, ``Crumb``, ``Nibble``, and ``Byte``. Any other width
/// works too, such as `Bits<3>` for a 3-bit field.
///
/// Write values as integer or binary string literals, and work with single bits and halves directly:
///
/// ```swift
/// var flags: Byte = 0b1010_0000
/// flags[bit: 0] = true                  // 0b1010_0001
/// flags.toggleBit(at: 7)                // 0b0010_0001
/// let type = flags.highHalf             // Nibble 0b0010
/// flags.lowHalf = 0b1111                // 0b0010_1111
/// let version: Nibble = "0100"
/// ```
///
/// Bits are numbered from the least significant, bit 0, regardless of the ``BitOrder`` they're read in.
/// Every operation compiles to a few instructions on a `UInt8`, and the range checks fold away for
/// constant indices.
public struct Bits<let width: Int>: RawRepresentable, BitwiseCopyable, Hashable, Comparable, Sendable {
    /// Storage, so in-module mutation can be inlined into clients (a setter can't be `@usableFromInline`).
    @usableFromInline var _rawValue: UInt8

    /// The bits, right-aligned. Bits above `width` are always zero.
    @inlinable
    public var rawValue: UInt8 { _rawValue }

    /// Creates a value without checking that `rawValue` fits in `width` bits.
    @inlinable @_transparent
    init(_unchecked rawValue: UInt8) {
        Self._checkWidth()
        _rawValue = rawValue
    }

    /// The number of bits in the value.
    @inlinable @_transparent
    public static var bitWidth: Int { width }

    /// A mask of the low `width` bits.
    @inlinable @_transparent
    static var mask: UInt8 { UInt8(truncatingIfNeeded: (1 &<< width) &- 1) }

    @inlinable @_transparent
    static func _checkWidth() {
        // Constant-folded away once `width` is known.
        precondition(width >= 1 && width <= 8, "Bits<\(width)> must be 1 through 8 bits wide")
    }

    /// Creates a value from `rawValue`, or `nil` if it doesn't fit in `width` bits.
    @inlinable
    public init?(rawValue: UInt8) {
        guard rawValue & ~Self.mask == 0 else { return nil }
        self.init(_unchecked: rawValue)
    }

    /// Creates a value from `source`, trapping if it doesn't fit in `width` bits.
    @inlinable
    public init(_ source: some BinaryInteger) {
        guard let value = Self(exactly: source) else {
            preconditionFailure("\(source) doesn't fit in \(width) bits")
        }
        self = value
    }

    /// Creates a value from `source`, or `nil` if it doesn't fit in `width` bits.
    @inlinable
    public init?(exactly source: some BinaryInteger) {
        guard source >= 0, source <= Self.mask else { return nil }
        self.init(_unchecked: UInt8(truncatingIfNeeded: source))
    }

    /// Creates a value from the low `width` bits of `source`, discarding the rest.
    @inlinable
    public init(truncatingIfNeeded source: some BinaryInteger) {
        self.init(_unchecked: UInt8(truncatingIfNeeded: source) & Self.mask)
    }

    /// Creates a value from bits of another width, trapping if they don't fit: `Byte(nibble)` always works,
    /// `Nibble(byte)` only for bytes below 16.
    @inlinable
    public init<let otherWidth: Int>(_ other: Bits<otherWidth>) {
        self.init(other.rawValue)
    }

    /// Creates a value from the low `width` bits of bits of another width.
    @inlinable
    public init<let otherWidth: Int>(truncatingIfNeeded other: Bits<otherWidth>) {
        self.init(truncatingIfNeeded: other.rawValue)
    }

    /// The value with every bit clear.
    @inlinable
    public static var zero: Self { Self(_unchecked: 0) }

    /// The value with every bit set.
    @inlinable
    public static var max: Self { Self(_unchecked: mask) }

    @inlinable
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A single bit.
public typealias Bit = Bits<1>
/// Two bits, conventionally called a crumb.
public typealias Crumb = Bits<2>
/// Four bits: half a byte.
public typealias Nibble = Bits<4>
/// Eight bits.
public typealias Byte = Bits<8>

// MARK: - Literals and strings

extension Bits: ExpressibleByIntegerLiteral {
    /// Creates a value from an integer literal, such as `0b1010`. Traps if it doesn't fit in `width` bits.
    @inlinable
    public init(integerLiteral value: UInt8) {
        self.init(value)
    }
}

extension Bits: LosslessStringConvertible, ExpressibleByStringLiteral {
    /// Parses binary digits, such as `"1010"`, `"0b1010"`, or `"1111_0000"`.
    ///
    /// Leading zeros and `_` separators are allowed. Returns `nil` if `description` has no digits,
    /// has any other character, or its value doesn't fit in `width` bits.
    @inlinable
    public init?(_ description: String) {
        var utf8 = Substring(description).utf8
        if utf8.starts(with: "0b".utf8) { utf8 = utf8.dropFirst(2) }
        var value: UInt16 = 0
        var digits = 0
        for unit in utf8 {
            switch unit {
            case UInt8(ascii: "0"), UInt8(ascii: "1"):
                value = value << 1 | UInt16(unit &- UInt8(ascii: "0"))
                digits += 1
                guard value <= Self.mask else { return nil }
            case UInt8(ascii: "_") where digits > 0:
                continue
            default:
                return nil
            }
        }
        guard digits > 0 else { return nil }
        self.init(_unchecked: UInt8(value))
    }

    /// Creates a value from binary digits, such as `"1010"`. Traps if the string isn't valid.
    ///
    /// `Nibble("1010")` with a literal argument is this initializer (literal coercion), so it traps on invalid
    /// input. Parse strings that aren't literals with ``init(_:)-(String)``, which returns `nil` instead.
    @inlinable
    public init(stringLiteral value: String) {
        guard let bits = Self(value) else {
            preconditionFailure("\"\(value)\" isn't a binary value that fits in \(width) bits")
        }
        self = bits
    }

    /// The value as exactly `width` binary digits, such as `"0101"`.
    public var description: String {
        var digits = ""
        digits.reserveCapacity(width)
        for index in (0..<width).reversed() {
            digits.append(rawValue >> index & 1 == 0 ? "0" : "1")
        }
        return digits
    }
}

extension BinaryInteger {
    /// Creates an integer from the value of `bits`.
    @inlinable
    public init<let width: Int>(_ bits: Bits<width>) {
        self.init(bits.rawValue)
    }
}

// MARK: - Bitwise operations

extension Bits {
    @inlinable
    public static prefix func ~ (value: Self) -> Self { Self(_unchecked: ~value.rawValue & mask) }

    @inlinable
    public static func & (lhs: Self, rhs: Self) -> Self { Self(_unchecked: lhs.rawValue & rhs.rawValue) }

    @inlinable
    public static func | (lhs: Self, rhs: Self) -> Self { Self(_unchecked: lhs.rawValue | rhs.rawValue) }

    @inlinable
    public static func ^ (lhs: Self, rhs: Self) -> Self { Self(_unchecked: lhs.rawValue ^ rhs.rawValue) }

    @inlinable
    public static func &= (lhs: inout Self, rhs: Self) { lhs._rawValue &= rhs.rawValue }

    @inlinable
    public static func |= (lhs: inout Self, rhs: Self) { lhs._rawValue |= rhs.rawValue }

    @inlinable
    public static func ^= (lhs: inout Self, rhs: Self) { lhs._rawValue ^= rhs.rawValue }

    /// Shifts left by `count` bits, dropping the bits shifted past the top.
    @inlinable
    public static func << (value: Self, count: Int) -> Self {
        Self(_unchecked: UInt8(truncatingIfNeeded: Int(value.rawValue) << count) & mask)
    }

    /// Shifts right by `count` bits, dropping the bits shifted past the bottom.
    @inlinable
    public static func >> (value: Self, count: Int) -> Self {
        Self(_unchecked: UInt8(truncatingIfNeeded: Int(value.rawValue) >> count))
    }
}

// MARK: - Single bits

extension Bits {
    @inlinable @inline(__always)
    static func _checkIndex(_ index: Int) {
        precondition(index >= 0 && index < width, "Bit index \(index) out of range for \(width) bits")
    }

    /// The bit at `index`, counting from the least significant bit (index 0), as a `Bool`.
    ///
    /// ```swift
    /// var flags: Byte = 0
    /// flags[bit: 1] = true // 0b0000_0010
    /// ```
    @inlinable
    public subscript(bit index: Int) -> Bool {
        @inline(__always) get {
            Self._checkIndex(index)
            return rawValue &>> index & 1 != 0
        }
        @inline(__always) set {
            Self._checkIndex(index)
            let bit = UInt8(1) &<< index
            _rawValue = newValue ? _rawValue | bit : _rawValue & ~bit
        }
    }

    /// Whether the bit at `index` is set, counting from the least significant bit (index 0).
    @inlinable
    public func isSet(at index: Int) -> Bool {
        self[bit: index]
    }

    /// Flips the bit at `index`, counting from the least significant bit (index 0).
    @inlinable
    public mutating func toggleBit(at index: Int) {
        Self._checkIndex(index)
        _rawValue ^= UInt8(1) &<< index
    }

    /// The number of set bits.
    @inlinable
    public var nonzeroBitCount: Int { rawValue.nonzeroBitCount }
}

// MARK: - Halves

extension Bits where width == 8 {
    /// The high four bits.
    @inlinable
    public var highHalf: Nibble {
        get { Nibble(_unchecked: rawValue &>> 4) }
        set { _rawValue = newValue.rawValue &<< 4 | _rawValue & 0x0F }
    }

    /// The low four bits.
    @inlinable
    public var lowHalf: Nibble {
        get { Nibble(_unchecked: rawValue & 0x0F) }
        set { _rawValue = _rawValue & 0xF0 | newValue.rawValue }
    }

    /// Creates a byte from its two nibbles.
    @inlinable
    public init(highHalf: Nibble, lowHalf: Nibble) {
        self.init(_unchecked: highHalf.rawValue &<< 4 | lowHalf.rawValue)
    }
}

extension Bits where width == 4 {
    /// The high two bits.
    @inlinable
    public var highHalf: Crumb {
        get { Crumb(_unchecked: rawValue &>> 2) }
        set { _rawValue = newValue.rawValue &<< 2 | _rawValue & 0b11 }
    }

    /// The low two bits.
    @inlinable
    public var lowHalf: Crumb {
        get { Crumb(_unchecked: rawValue & 0b11) }
        set { _rawValue = _rawValue & 0b1100 | newValue.rawValue }
    }

    /// Creates a nibble from its two crumbs.
    @inlinable
    public init(highHalf: Crumb, lowHalf: Crumb) {
        self.init(_unchecked: highHalf.rawValue &<< 2 | lowHalf.rawValue)
    }
}

extension Bits where width == 2 {
    /// The high bit.
    @inlinable
    public var highHalf: Bit {
        get { Bit(_unchecked: rawValue &>> 1) }
        set { _rawValue = newValue.rawValue &<< 1 | _rawValue & 1 }
    }

    /// The low bit.
    @inlinable
    public var lowHalf: Bit {
        get { Bit(_unchecked: rawValue & 1) }
        set { _rawValue = _rawValue & 0b10 | newValue.rawValue }
    }

    /// Creates a crumb from its two bits.
    @inlinable
    public init(highHalf: Bit, lowHalf: Bit) {
        self.init(_unchecked: highHalf.rawValue &<< 1 | lowHalf.rawValue)
    }
}

// MARK: - Bit and Bool

extension Bits where width == 1 {
    /// Creates `1` for `true` and `0` for `false`.
    @inlinable
    public init(_ value: Bool) {
        self.init(_unchecked: value ? 1 : 0)
    }

    /// Whether the bit is `1`.
    @inlinable
    public var isSet: Bool { rawValue != 0 }
}

extension Bool {
    /// Creates `true` for `1` and `false` for `0`.
    @inlinable
    public init(_ bit: Bit) {
        self = bit.rawValue != 0
    }
}
