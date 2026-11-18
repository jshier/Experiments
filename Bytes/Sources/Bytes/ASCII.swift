// ASCII in binary formats: tags and signatures ("IHDR", "qoif", "PK\u{3}\u{4}"), character classes, and numbers
// written as digits (dates, tar headers, HTTP lengths).
//
// Each test is written the way that compiles best, so callers needn't know the tricks: a range test as one
// subtraction and an unsigned compare (`byte &- 0x30 < 10`, no branch), case folding as an OR with 0x20, digits
// as one 8-byte load combined in three multiplies. The lane forms are arithmetic on whole vectors, with no
// per-lane branches or comparisons against scalars (which Swift 6.4 compiles a lane at a time).

// MARK: - Bytes

public extension UInt8 {
    /// Whether this is an ASCII digit, `0` through `9`.
    @inlinable @inline(__always)
    var isASCIIDigit: Bool { self &- 0x30 < 10 }

    /// The value of an ASCII digit (`0` through `9`), or `nil` for any other byte.
    @inlinable @inline(__always)
    var asciiDigitValue: UInt8? {
        let value = self &- 0x30
        return value < 10 ? value : nil
    }

    /// Whether this is an ASCII hexadecimal digit: `0`–`9`, `a`–`f`, or `A`–`F`.
    @inlinable @inline(__always)
    var isASCIIHexDigit: Bool { asciiHexDigitValue != nil }

    /// The value of an ASCII hexadecimal digit (`0`–`9`, `a`–`f`, `A`–`F`), or `nil` for any other byte.
    @inlinable @inline(__always)
    var asciiHexDigitValue: UInt8? {
        let digit = self &- 0x30
        if digit < 10 { return digit }
        let letter = (self | 0x20) &- 0x61 // `A`–`F` folded to `a`–`f`
        return letter < 6 ? letter &+ 10 : nil
    }

    /// Whether this is an ASCII letter, `a`–`z` or `A`–`Z`.
    @inlinable @inline(__always)
    var isASCIILetter: Bool { (self | 0x20) &- 0x61 < 26 }

    /// Whether this is ASCII whitespace: space, tab, line feed, vertical tab, form feed, or carriage return.
    @inlinable @inline(__always)
    var isASCIIWhitespace: Bool { self == 0x20 || self &- 0x09 < 5 }

    /// The byte with an ASCII uppercase letter made lowercase; any other byte unchanged.
    @inlinable @inline(__always)
    var asciiLowercased: UInt8 { self &- 0x41 < 26 ? self | 0x20 : self }

    /// The byte with an ASCII lowercase letter made uppercase; any other byte unchanged.
    @inlinable @inline(__always)
    var asciiUppercased: UInt8 { self &- 0x61 < 26 ? self & 0xDF : self }
}

// MARK: - Tags and signatures

public extension Bits {
    /// The byte of an ASCII character: a separator or a one-byte tag.
    ///
    /// ```swift
    /// try reader.expect(Byte(ascii: "-"))
    /// ```
    ///
    /// - Parameter character: An ASCII character.
    /// - Precondition: This is a `Byte` (8 bits), and `character` is ASCII.
    @inlinable @inline(__always)
    init(ascii character: Unicode.Scalar) {
        precondition(width == 8, "An ASCII character is a Byte")
        precondition(character.isASCII, "Not an ASCII character")
        self.init(truncatingIfNeeded: character.value)
    }
}

public extension ByteGroup {
    /// The group whose bytes are `text`'s, in order: a format's ASCII tag or signature, such as a PNG chunk
    /// type or a file's magic number.
    ///
    /// ```swift
    /// try reader.expect(Byte4(ascii: "qoif"))
    /// switch try reader.read(Byte4.self) {
    /// case Byte4(ascii: "IHDR"): …
    /// case Byte4(ascii: "IEND"): …
    /// default: …
    /// }
    /// ```
    ///
    /// Inlined, it folds to the integer constant you'd otherwise write by hand in hex (`0x49_48_44_52`). Use it
    /// where it's evaluated, or in a computed property: a `static let` initialized with it is lazily initialized,
    /// as any global the compiler can't evaluate at compile time.
    ///
    /// - Parameter text: Exactly ``byteCount`` ASCII characters; escapes such as `"\u{0}"` give other bytes.
    /// - Precondition: `text` is ``byteCount`` bytes of UTF-8, each below 0x80.
    @inlinable @inline(__always)
    init(ascii text: StaticString) {
        precondition(text.hasPointerRepresentation && text.utf8CodeUnitCount == Self.byteCount,
                     "An ASCII literal must have exactly as many characters as the group has bytes")
        var value: Integer = 0
        for index in 0..<Self.byteCount {
            // Unsafe: reads the literal's UTF-8. Safe: it has `byteCount` code units (checked above).
            let byte = unsafe text.utf8Start[index]
            precondition(byte < 0x80, "An ASCII literal must be ASCII")
            value |= Integer(truncatingIfNeeded: byte) &<< (8 &* index)
        }
        self.init(littleEndian: value)
    }
}

// MARK: - Lanes

public extension ByteLanes {
    /// Tests which lanes fall in `range`, as unsigned bytes: one subtraction and one vector comparison, with no
    /// per-lane work.
    ///
    /// - Parameter range: The bytes to look for.
    /// - Returns: The lanes in `range`.
    @inlinable @inline(__always)
    func matching(in range: ClosedRange<UInt8>) -> ByteMatches {
        // `v - lower` is at most `upper - lower` exactly for the lanes in range (lanes below wrap high).
        let offset = vector &- SIMD16(repeating: range.lowerBound)
        let width = SIMD16(repeating: range.upperBound &- range.lowerBound)
        // Two vectors compared: one instruction (`cmhs`). (`pointwiseMin` was a call.)
        return ByteMatches(highBits: SIMD16(repeating: 0).replacing(with: 0xFF, where: offset .<= width))
    }

    /// Tests which lanes equal an ASCII character.
    ///
    /// ```swift
    /// let separators = lanes.matching("/") | lanes.matching("+") | lanes.matching("#")
    /// ```
    ///
    /// - Parameter character: An ASCII character.
    /// - Returns: The lanes equal to `character`.
    /// - Precondition: `character` is ASCII.
    @inlinable @inline(__always)
    func matching(_ character: Unicode.Scalar) -> ByteMatches {
        precondition(character.isASCII, "Not an ASCII character")
        return matching(UInt8(truncatingIfNeeded: character.value))
    }

    /// The lanes holding ASCII digits, `0` through `9`.
    @inlinable @inline(__always)
    var asciiDigits: ByteMatches { matching(in: 0x30...0x39) }

    /// The lanes holding ASCII letters, `a`–`z` or `A`–`Z`.
    @inlinable @inline(__always)
    var asciiLetters: ByteMatches { ByteLanes(vector | SIMD16(repeating: 0x20)).matching(in: 0x61...0x7A) }

    /// The lanes holding ASCII whitespace: space, tab, line feed, vertical tab, form feed, or carriage return.
    @inlinable @inline(__always)
    var asciiWhitespace: ByteMatches { matching(0x20) | matching(in: 0x09...0x0D) }

    /// The lanes holding ASCII control characters (below 0x20, and 0x7F).
    @inlinable @inline(__always)
    var asciiControl: ByteMatches { matching(in: 0x00...0x1F) | matching(0x7F) }
}

// MARK: - Numbers written as digits

public extension GenericBytesReader {
    /// Reads a number written as exactly `digitCount` ASCII digits, `0` through `9`, most significant first: a
    /// fixed-width field such as a date's `2026`, a tar header's size, or an HTTP status code.
    ///
    /// ```swift
    /// let year = try reader.read(Int.self, asciiDigits: 4)
    /// try reader.expect(Byte(ascii: "-"))
    /// let month = try reader.read(Int.self, asciiDigits: 2)
    /// ```
    ///
    /// Up to 8 digits are one 8-byte load (while 8 bytes remain), checked and combined in a few word operations
    /// instead of a multiply-add per digit; up to 16, two.
    ///
    /// - Parameters:
    ///   - type: The integer type to read, such as `Int.self`.
    ///   - digitCount: How many digits, 1 through 19.
    /// - Returns: The number.
    /// - Throws: ``BytesError/insufficientData`` if fewer than `digitCount` bytes remain;
    ///   ``BytesError/invalidValue`` if one isn't a digit, `digitCount` isn't 1 through 19, or `I` can't
    ///   represent the number. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func read<I: FixedWidthInteger>(_ type: I.Type, asciiDigits digitCount: Int) throws(BytesError) -> I {
        let start = position
        let value = try _readASCIIDigits(digitCount)
        guard let result = I(exactly: value) else {
            rewind(to: start)
            throw .invalidValue
        }
        return result
    }

    /// The value of the next `digitCount` ASCII digits. Consumes nothing if it throws.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    internal mutating func _readASCIIDigits(_ digitCount: Int) throws(BytesError) -> UInt64 {
        guard digitCount >= 1 && digitCount <= 19 else { throw .invalidValue }
        _assumeInvariant()
        let remaining = span.byteCount &- _byteOffset
        if _bitOffset == 0 && digitCount <= 8 && likely(remaining >= 8) {
            // Unsafe: an unchecked load. Safe: 8 bytes remain (just checked).
            let word = UInt64(littleEndian: unsafe Load.rawBytes(UInt64.self, from: span, at: _byteOffset))
            // The digits' values, moved to the word's top: the bytes shifted in are leading zeros.
            let digits = (word ^ 0x3030_3030_3030_3030) &<< UInt64(64 &- 8 &* digitCount)
            guard Self._areASCIIDigitValues(digits) else { throw .invalidValue }
            _byteOffset &+= digitCount
            return Self._combineASCIIDigits(digits)
        }
        if _bitOffset == 0 && digitCount > 8 && digitCount <= 16 && likely(remaining >= digitCount) {
            // Two loads: the first `digitCount - 8` digits, then the last 8. Unsafe: unchecked loads. Safe:
            // `digitCount` (9 or more) bytes remain, so both 8-byte loads are inside the span.
            let first = UInt64(littleEndian: unsafe Load.rawBytes(UInt64.self, from: span, at: _byteOffset))
            let last = UInt64(littleEndian: unsafe Load.rawBytes(UInt64.self, from: span, at: _byteOffset &+ digitCount &- 8))
            let high = (first ^ 0x3030_3030_3030_3030) &<< UInt64(128 &- 8 &* digitCount)
            let low = last ^ 0x3030_3030_3030_3030
            // Each word checked on its own: ORing two digit values can exceed 9 (9 | 6 is 15).
            guard Self._areASCIIDigitValues(high), Self._areASCIIDigitValues(low) else { throw .invalidValue }
            _byteOffset &+= digitCount
            return Self._combineASCIIDigits(high) &* 100_000_000 &+ Self._combineASCIIDigits(low)
        }
        // Near the end of the data, or 17 to 19 digits: a digit at a time, out of line and not generic.
        let start = position
        if _bitOffset == 0 {
            let digits = try read(byteCount: digitCount)
            guard let value = _ASCIIDigits.value(of: digits) else {
                rewind(to: start)
                throw .invalidValue
            }
            return value
        }
        // Past a bit boundary (a bit cursor only; for byte cursors the offset is the constant 0).
        guard remainingByteCount >= digitCount else { throw .insufficientData }
        var value: UInt64 = 0
        for _ in 0..<digitCount {
            // Can't throw: `digitCount` bytes remain. 19 digits fit in a `UInt64`, so nothing overflows.
            let digit = try read(UInt8.self) &- 0x30
            guard digit < 10 else {
                rewind(to: start)
                throw .invalidValue
            }
            value = value &* 10 &+ UInt64(digit)
        }
        return value
    }

    /// Whether every byte of `values` is 0 through 9. Adding 0x76 keeps 0–9 below 0x80 and pushes 10–0x7F to or
    /// above it; ORing the original catches bytes already at 0x80 or above. A carry out of a byte comes only from
    /// a byte that already fails, so it can't hide one that does.
    @inlinable @inline(__always)
    internal static func _areASCIIDigitValues(_ values: UInt64) -> Bool {
        ((values &+ 0x7676_7676_7676_7676) | values) & 0x8080_8080_8080_8080 == 0
    }

    /// Eight digit values, most significant in the low byte, as a number: pairs, then fours, then all eight, each
    /// one multiply.
    @inlinable @inline(__always)
    internal static func _combineASCIIDigits(_ values: UInt64) -> UInt64 {
        let pairs = (values &* (10 &<< 8 &+ 1)) &>> 8 & 0x00FF_00FF_00FF_00FF
        let fours = (pairs &* (100 &<< 16 &+ 1)) &>> 16 & 0x0000_FFFF_0000_FFFF
        return (fours &* (10_000 &<< 32 &+ 1)) &>> 32
    }

    /// Consumes the next `T.byteCount` bytes if they're the integer `expected`, stored in `byteOrder`: a magic
    /// number as a format's specification writes it, with its byte order, rather than as bytes in memory order.
    ///
    /// ```swift
    /// try reader.expect(0x184D_2204 as UInt32, .littleEndian)   // LZ4's frame magic
    /// ```
    ///
    /// - Parameters:
    ///   - expected: The value that must come next.
    ///   - byteOrder: The byte order it's stored in.
    /// - Throws: ``BytesError/insufficientData`` if fewer bytes remain; ``BytesError/mismatch`` if the next
    ///   value differs. Nothing is consumed either way.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func expect<I: FixedWidthInteger & ConvertibleFromBytes>(_ expected: I, _ byteOrder: ByteOrder) throws(BytesError) {
        let raw = try peekLoad(I.self)
        let value = switch byteOrder { // A `switch`: the standard library's `ByteOrder.==` is a call.
        case .bigEndian: I(bigEndian: raw)
        case .littleEndian: I(littleEndian: raw)
        }
        guard value == expected else { throw .mismatch }
        try skip(byteCount: MemoryLayout<I>.size) // Can't throw: the bytes were just loaded.
    }
}

/// The slow path of ``GenericBytesReader/read(_:asciiDigits:)``, apart from the cursor so it isn't generic.
@usableFromInline
enum _ASCIIDigits {
    /// The number `digits` spell, or `nil` if one isn't an ASCII digit. At most 19 digits, so it can't overflow.
    @usableFromInline @inline(never)
    static func value(of digits: RawSpan) -> UInt64? {
        var value: UInt64 = 0
        for index in 0..<digits.byteCount {
            let digit = digits.load(fromByteOffset: index, as: UInt8.self) &- 0x30
            guard digit < 10 else { return nil }
            value = value &* 10 &+ UInt64(digit)
        }
        return value
    }
}

public extension GenericBytesWriter {
    /// Writes `value` as exactly `digitCount` ASCII digits, most significant first, with leading zeros: the
    /// counterpart of ``GenericBytesReader/read(_:asciiDigits:)``.
    ///
    /// - Parameters:
    ///   - value: A number from 0 to 10^`digitCount` − 1.
    ///   - digitCount: How many digits, 1 through 19.
    /// - Throws: ``BytesError/invalidValue`` if `value` is negative or needs more digits, or `digitCount` isn't 1
    ///   through 19; ``BytesError/insufficientCapacity`` if fewer than `digitCount` bytes are free. Nothing is
    ///   written either way.
    @inlinable
    @_lifetime(self: copy self)
    mutating func write<I: BinaryInteger>(_ value: I, asciiDigits digitCount: Int) throws(BytesError) {
        guard digitCount >= 1 && digitCount <= 19, value >= 0, let number = UInt64(exactly: value) else { throw .invalidValue }
        var digits = InlineArray<19, UInt8>(repeating: 0x30)
        var remaining = number
        var index = digitCount
        while index > 0 {
            index &-= 1
            digits[index] = 0x30 &+ UInt8(truncatingIfNeeded: remaining % 10)
            remaining /= 10
        }
        guard remaining == 0 else { throw .invalidValue }
        try write(digits.span.bytes.extracting(first: digitCount))
    }
}
