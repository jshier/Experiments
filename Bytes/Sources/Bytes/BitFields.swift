// Named fields inside a value already read: a format's flags and packed fields, declared once by name and
// read and written by name, instead of shifts, masks, and bit numbers at every use.
//
// ```swift
// enum ConnectFlags {
//     static var userName: BitFlag { BitFlag(bit: 7) }
//     static var willQoS: BitField<MQTTQoS> { BitField(bits: 3...4) }
//     static var reserved: BitFlag { BitFlag(bit: 0) }
// }
// let flags = try reader.read(Byte.self)
// try flags.requireClear(ConnectFlags.reserved)
// let qos = try flags.value(of: ConnectFlags.willQoS)   // throws for a raw value with no case
// let hasUserName = flags[ConnectFlags.userName]
// ```
//
// Declare descriptors as computed `static var`s, as above: each use then inlines to the same shift and mask
// written by hand. (A `static let` is a lazily initialized global, checked on every access.)

// MARK: - Descriptors

/// A one-bit flag at a fixed position in a value, read and written as a `Bool`.
///
/// Positions count from the least significant bit, 0, as `[bit:]` does; ``init(bitFromMostSignificant:of:)``
/// counts from the other end, as specifications that draw bit 0 on the left do.
@frozen
public struct BitFlag: Hashable, Sendable {
    /// The flag's bit, counting from the least significant (0).
    public let bit: Int

    /// A flag at `bit`, counting from the least significant bit (0).
    ///
    /// - Parameter bit: The bit, 0 through 63.
    @inlinable @inline(__always)
    public init(bit: Int) {
        precondition(bit >= 0 && bit < 64, "A flag's bit must be 0 through 63")
        self.bit = bit
    }

    /// A flag at `index`, counting from the most significant bit of a `width`-bit value: bit 0 is the
    /// leftmost in a specification's diagram.
    ///
    /// - Parameters:
    ///   - index: The bit, counting from the most significant (0).
    ///   - width: The width of the value the flag is in: 8 for a ``Byte``.
    @inlinable @inline(__always)
    public init(bitFromMostSignificant index: Int, of width: Int = 8) {
        self.init(bit: width &- 1 &- index)
    }
}

/// A field of adjacent bits at a fixed position in a value, read and written as a `Value`: an `Int`, a
/// ``Bits`` value, or a `RawRepresentable` type (an enum) whose raw value is an integer.
///
/// ```swift
/// static var willQoS: BitField<MQTTQoS> { BitField(bits: 3...4) }   // bits 3 and 4
/// static var year: BitField<Int> { BitField(bits: 9...15) }          // a DOS date's year, in a UInt16
/// ```
@frozen
public struct BitField<Value>: Hashable, Sendable {
    /// The field's lowest bit, counting from the least significant (0).
    public let offset: Int
    /// The number of bits in the field.
    public let width: Int

    /// A field of `width` bits starting at bit `offset`, counting from the least significant bit (0).
    ///
    /// - Parameters:
    ///   - offset: The field's lowest bit.
    ///   - width: The number of bits, 1 through 64 (`offset + width` at most 64).
    /// - Precondition: The field fits in 64 bits.
    @inlinable @inline(__always)
    public init(offset: Int, width: Int) {
        precondition(offset >= 0 && width >= 1 && offset &+ width <= 64, "A field must fit in 64 bits")
        self.offset = offset
        self.width = width
    }

    /// A field covering `bits`, counting from the least significant bit (0): `3...4` is the two bits above
    /// the low three.
    ///
    /// - Parameter bits: The field's lowest through highest bit.
    @inlinable @inline(__always)
    public init(bits: ClosedRange<Int>) {
        self.init(offset: bits.lowerBound, width: bits.count)
    }

    /// A field covering `bits`, counting from the most significant bit of a `width`-bit value: bit 0 is
    /// the leftmost in a specification's diagram, and `0...1` is the top two bits.
    ///
    /// - Parameters:
    ///   - bits: The field's bits, counting from the most significant (0).
    ///   - width: The width of the value the field is in: 8 for a ``Byte``.
    @inlinable @inline(__always)
    public init(bitsFromMostSignificant bits: ClosedRange<Int>, of width: Int = 8) {
        self.init(offset: width &- 1 &- bits.upperBound, width: bits.count)
    }

    /// The field's bits, right-aligned: `(1 << width) - 1`.
    @inlinable @inline(__always)
    var _mask: UInt64 { UInt64.max &>> UInt64(64 &- width) }
}

/// Fixed and free bits, written as a string: `0` and `1` must match, `?` matches either; `_` and spaces
/// separate groups. The first digit is the most significant bit.
///
/// ```swift
/// guard flags.matches("01??_??0?") else { throw .invalidValue }   // version 01, bit 1 reserved
/// ```
///
/// The string is parsed when the pattern is made: declare patterns as `static var`s whose string the
/// optimizer can see, or outside hot loops.
@frozen
public struct BitPattern: Hashable, Sendable, ExpressibleByStringLiteral {
    /// The bits that must be set, among those in ``mask``.
    public let value: UInt64
    /// The bits that must match.
    public let mask: UInt64
    /// The number of digits: the width of the values the pattern is for.
    public let bitCount: Int

    /// A pattern from a string of `0`, `1`, and `?`, most significant first; `_` and spaces are ignored.
    ///
    /// - Parameter pattern: The digits.
    /// - Precondition: Only `0`, `1`, `?`, `_`, and spaces, and 1 through 64 digits.
    @inlinable @inline(__always)
    public init(_ pattern: StaticString) {
        var value: UInt64 = 0
        var mask: UInt64 = 0
        var count = 0
        // A string literal has a pointer to its UTF-8 (one written as a single character may not).
        precondition(pattern.hasPointerRepresentation, "A bit pattern is a string of digits")
        let utf8 = unsafe pattern.utf8Start
        // unsafe: `utf8Start` points to the literal's static storage of `utf8CodeUnitCount` bytes, which
        // lives for the whole program; the loop reads only those. Reading the constant bytes directly (not
        // through `withUTF8Buffer`) lets the optimizer fold a literal pattern to its two masks.
        for index in 0..<pattern.utf8CodeUnitCount {
            let character = unsafe utf8[index]
            switch character {
            case UInt8(ascii: "0"), UInt8(ascii: "1"):
                value = value &<< 1 | UInt64(character &- UInt8(ascii: "0"))
                mask = mask &<< 1 | 1
                count &+= 1
            case UInt8(ascii: "?"):
                value &<<= 1
                mask &<<= 1
                count &+= 1
            case UInt8(ascii: "_"), UInt8(ascii: " "):
                continue
            default:
                preconditionFailure("A bit pattern has only 0, 1, ?, _, and spaces")
            }
        }
        precondition(count >= 1 && count <= 64, "A bit pattern has 1 through 64 digits")
        self.value = value
        self.mask = mask
        bitCount = count
    }

    /// A pattern from a string literal, as ``init(_:)``: `flags.matches("01??_??0?")`.
    ///
    /// - Parameter pattern: The digits.
    /// - Precondition: As for ``init(_:)``.
    @inlinable @inline(__always)
    public init(stringLiteral pattern: StaticString) {
        self.init(pattern)
    }
}
