/// A fixed run of 2 to 16 bytes, as they appear in memory, with no byte order applied yet.
///
/// ``Byte2`` through ``Byte16`` conform. Read one with ``Bytes/read(_:)-(T.Type)``, then interpret it
/// with ``littleEndian`` or ``bigEndian``, or read the integer directly with
/// ``Bytes/read(_:_:)``. Odd widths, such as the 24-bit lengths common in media and network formats,
/// work the same as the standard ones:
///
/// ```swift
/// let length = try reader.read(Byte3.self, .bigEndian) // UInt32
/// ```
///
/// Write constants, such as file signatures, as array literals in memory order:
///
/// ```swift
/// let signature: Byte4 = [0x50, 0x4B, 0x03, 0x04]
/// ```
public protocol ByteGroup: BitwiseCopyable, Hashable, Sendable, ExpressibleByArrayLiteral, CustomStringConvertible
where ArrayLiteralElement == UInt8 {
    /// The narrowest standard unsigned integer that holds `byteCount` bytes.
    associatedtype Integer: FixedWidthInteger & UnsignedInteger & ConvertibleFromBytes

    /// The number of bytes, 2 through 16.
    static var byteCount: Int { get }

    /// The bytes read as a little-endian integer: the first byte is the least significant.
    var littleEndian: Integer { get }

    /// The bytes read as a big-endian integer: the first byte is the most significant.
    var bigEndian: Integer { get }

    /// Creates a value from the low `byteCount` bytes of `value`, least significant byte first.
    /// Higher bytes are discarded.
    init(littleEndian value: Integer)
}

extension ByteGroup {
    /// A mask of the low `byteCount` bytes of ``Integer``.
    @inlinable @_transparent
    static var _mask: Integer { Integer.max &>> (Integer.bitWidth &- 8 &* byteCount) }

    /// The bytes read as a big-endian integer: the first byte is the most significant.
    @inlinable
    public var bigEndian: Integer {
        littleEndian.byteSwapped &>> (Integer.bitWidth &- 8 &* Self.byteCount)
    }

    /// Creates a value from the low `byteCount` bytes of `value`, most significant byte first.
    /// Higher bytes are discarded.
    @inlinable
    public init(bigEndian value: Integer) {
        // Byte-swapping moves the low `byteCount` bytes to the top; shifting brings them back down, reversed.
        self.init(littleEndian: value.byteSwapped &>> (Integer.bitWidth &- 8 &* Self.byteCount))
    }

    /// The bytes read as an integer in `byteOrder`.
    @inlinable @inline(__always)
    public func integer(_ byteOrder: ByteOrder) -> Integer {
        switch byteOrder {
        case .littleEndian: littleEndian
        case .bigEndian: bigEndian
        }
    }

    /// Creates a value from the low `byteCount` bytes of `value`, in `byteOrder`.
    @inlinable @inline(__always)
    public init(_ value: Integer, _ byteOrder: ByteOrder) {
        switch byteOrder {
        case .littleEndian: self.init(littleEndian: value)
        case .bigEndian: self.init(bigEndian: value)
        }
    }

    /// The byte at `index`, in memory order.
    @inlinable
    public subscript(index: Int) -> UInt8 {
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

    /// The first `H.byteCount` bytes, as `H`.
    @inlinable @inline(__always)
    func _lowHalf<H: ByteGroup>(_: H.Type) -> H {
        H(littleEndian: H.Integer(truncatingIfNeeded: littleEndian))
    }

    /// The last `H.byteCount` bytes, as `H`.
    @inlinable @inline(__always)
    func _highHalf<H: ByteGroup>(_: H.Type) -> H {
        H(littleEndian: H.Integer(truncatingIfNeeded: littleEndian &>> (8 &* H.byteCount)))
    }

    /// Replaces the first `H.byteCount` bytes.
    @inlinable @inline(__always)
    mutating func _setLowHalf<H: ByteGroup>(_ half: H) {
        let mask = Integer(truncatingIfNeeded: H._mask)
        self = Self(littleEndian: littleEndian & ~mask | Integer(truncatingIfNeeded: half.littleEndian))
    }

    /// Replaces the last `H.byteCount` bytes.
    @inlinable @inline(__always)
    mutating func _setHighHalf<H: ByteGroup>(_ half: H) {
        let shift = 8 &* H.byteCount
        let mask = Integer(truncatingIfNeeded: H._mask) &<< shift
        self = Self(littleEndian: littleEndian & ~mask | Integer(truncatingIfNeeded: half.littleEndian) &<< shift)
    }
}

// MARK: - Halves

// Each even-width group splits into two of the next size down, in memory order like SIMD vectors:
// `lowHalf` is the first bytes, `highHalf` the last. (Read as little-endian, the low half is also the
// numerically low part.)

extension Byte2 {
    /// The first byte.
    @inlinable
    public var lowHalf: Byte {
        get { Byte(_unchecked: UInt8(truncatingIfNeeded: littleEndian)) }
        set { self[0] = newValue.rawValue }
    }

    /// The second byte.
    @inlinable
    public var highHalf: Byte {
        get { Byte(_unchecked: UInt8(truncatingIfNeeded: littleEndian &>> 8)) }
        set { self[1] = newValue.rawValue }
    }

    /// Creates a group from its two bytes, in memory order.
    @inlinable
    public init(lowHalf: Byte, highHalf: Byte) {
        self.init(littleEndian: UInt16(highHalf.rawValue) &<< 8 | UInt16(lowHalf.rawValue))
    }
}

extension Byte4 {
    /// The first two bytes.
    @inlinable public var lowHalf: Byte2 { get { _lowHalf(Byte2.self) } set { _setLowHalf(newValue) } }
    /// The last two bytes.
    @inlinable public var highHalf: Byte2 { get { _highHalf(Byte2.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    @inlinable public init(lowHalf: Byte2, highHalf: Byte2) {
        self.init(littleEndian: UInt32(highHalf.littleEndian) &<< 16 | UInt32(lowHalf.littleEndian))
    }
}

extension Byte6 {
    /// The first three bytes.
    @inlinable public var lowHalf: Byte3 { get { _lowHalf(Byte3.self) } set { _setLowHalf(newValue) } }
    /// The last three bytes.
    @inlinable public var highHalf: Byte3 { get { _highHalf(Byte3.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    @inlinable public init(lowHalf: Byte3, highHalf: Byte3) {
        self.init(littleEndian: UInt64(highHalf.littleEndian) &<< 24 | UInt64(lowHalf.littleEndian))
    }
}

extension Byte8 {
    /// The first four bytes.
    @inlinable public var lowHalf: Byte4 { get { _lowHalf(Byte4.self) } set { _setLowHalf(newValue) } }
    /// The last four bytes.
    @inlinable public var highHalf: Byte4 { get { _highHalf(Byte4.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    @inlinable public init(lowHalf: Byte4, highHalf: Byte4) {
        self.init(littleEndian: UInt64(highHalf.littleEndian) &<< 32 | UInt64(lowHalf.littleEndian))
    }
}

extension Byte10 {
    /// The first five bytes.
    @inlinable public var lowHalf: Byte5 { get { _lowHalf(Byte5.self) } set { _setLowHalf(newValue) } }
    /// The last five bytes.
    @inlinable public var highHalf: Byte5 { get { _highHalf(Byte5.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    @inlinable public init(lowHalf: Byte5, highHalf: Byte5) {
        self.init(littleEndian: UInt128(highHalf.littleEndian) &<< 40 | UInt128(lowHalf.littleEndian))
    }
}

extension Byte12 {
    /// The first six bytes.
    @inlinable public var lowHalf: Byte6 { get { _lowHalf(Byte6.self) } set { _setLowHalf(newValue) } }
    /// The last six bytes.
    @inlinable public var highHalf: Byte6 { get { _highHalf(Byte6.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    @inlinable public init(lowHalf: Byte6, highHalf: Byte6) {
        self.init(littleEndian: UInt128(highHalf.littleEndian) &<< 48 | UInt128(lowHalf.littleEndian))
    }
}

extension Byte14 {
    /// The first seven bytes.
    @inlinable public var lowHalf: Byte7 { get { _lowHalf(Byte7.self) } set { _setLowHalf(newValue) } }
    /// The last seven bytes.
    @inlinable public var highHalf: Byte7 { get { _highHalf(Byte7.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    @inlinable public init(lowHalf: Byte7, highHalf: Byte7) {
        self.init(littleEndian: UInt128(highHalf.littleEndian) &<< 56 | UInt128(lowHalf.littleEndian))
    }
}

extension Byte16 {
    /// The first eight bytes.
    @inlinable public var lowHalf: Byte8 { get { _lowHalf(Byte8.self) } set { _setLowHalf(newValue) } }
    /// The last eight bytes.
    @inlinable public var highHalf: Byte8 { get { _highHalf(Byte8.self) } set { _setHighHalf(newValue) } }
    /// Creates a group from its two halves, in memory order.
    @inlinable public init(lowHalf: Byte8, highHalf: Byte8) {
        self.init(littleEndian: UInt128(highHalf.littleEndian) &<< 64 | UInt128(lowHalf.littleEndian))
    }
}

extension ByteGroup {

    /// Creates a value from exactly `byteCount` bytes, in memory order.
    @inlinable
    public init(arrayLiteral elements: UInt8...) {
        precondition(elements.count == Self.byteCount, "\(Self.self) needs exactly \(Self.byteCount) bytes")
        var value: Integer = 0
        for (index, byte) in elements.enumerated() {
            value |= Integer(byte) &<< (8 &* index)
        }
        self.init(littleEndian: value)
    }

    /// The bytes in memory order, in hexadecimal, such as `"50 4B 03 04"`.
    public var description: String {
        (0..<Self.byteCount).map { index in
            let byte = self[index]
            return (byte < 0x10 ? "0" : "") + String(byte, radix: 16, uppercase: true)
        }.joined(separator: " ")
    }
}

extension ByteGroup where Integer == UInt128 {
    /// The bytes read as a big-endian integer: the first byte is the most significant.
    ///
    /// Computed on 64-bit halves rather than with a 128-bit byte swap and shift, so loops over
    /// ``Byte9`` through ``Byte16`` vectorize: LLVM won't vectorize 128-bit arithmetic.
    @inlinable
    public var bigEndian: UInt128 {
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
