// Hexadecimal text: bytes as two ASCII hex digits each (digests, keys, test vectors, XAR checksums), both ways.
//
// Eight bytes at a time in a 64-bit word: each byte's nibbles spread into a byte each and turned into digits with
// masks and adds (no table, no branch per digit); decoding checks eight digits at once the same way, then packs
// their nibbles back into four bytes.

public extension [UInt8] {
    /// The bytes that hexadecimal `text` spells: two ASCII hex digits per byte, most significant first, in either
    /// case (`"00ff7F"` is `[0x00, 0xFF, 0x7F]`).
    ///
    /// ```swift
    /// let key = try [UInt8](hexadecimal: "000102030405060708090a0b0c0d0e0f".utf8Span.span.bytes)
    /// ```
    ///
    /// - Parameter text: The digits, with nothing between them.
    /// - Throws: ``BytesError/invalidValue`` if `text` has an odd number of bytes or one that isn't a hex digit.
    @inlinable
    init(hexadecimal text: RawSpan) throws(BytesError) {
        guard text.byteCount & 1 == 0 else { throw .invalidValue }
        try self.init(alignedByteCapacity: text.byteCount &>> 1) { writer throws(BytesError) in
            try writer._write(hexadecimalDigits: text)
        }
    }

    /// The bytes that hexadecimal `text` spells: see the `RawSpan` form.
    ///
    /// ```swift
    /// let digest = try [UInt8](hexadecimal: "e3b0c44298fc1c149afbf4c8996fb924")
    /// ```
    ///
    /// - Parameter text: The digits, with nothing between them.
    /// - Throws: ``BytesError/invalidValue`` if `text` has an odd number of characters or one that isn't a hex
    ///   digit.
    @inlinable
    init(hexadecimal text: some StringProtocol) throws(BytesError) {
        var string = String(text)
        string.makeContiguousUTF8() // `utf8Span` needs native, contiguous UTF-8.
        try self.init(hexadecimal: string.utf8Span.span.bytes)
    }
}

public extension String {
    /// `bytes` as hexadecimal text: two ASCII hex digits per byte, most significant first.
    ///
    /// ```swift
    /// String(hexadecimal: digest.span.bytes)   // "e3b0c442…"
    /// ```
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - uppercase: Whether the digits above 9 are `A`–`F` rather than `a`–`f`.
    @inlinable
    init(hexadecimal bytes: RawSpan, uppercase: Bool = false) {
        // Can't throw: the capacity is exactly the digits' count.
        self.init(utf8Capacity: bytes.byteCount &<< 1) { writer in
            try! writer.write(hexadecimal: bytes, uppercase: uppercase)
        }
    }
}

public extension GenericBytesWriter {
    /// Writes `bytes` as hexadecimal text: two ASCII hex digits per byte, most significant first. Requires byte
    /// alignment.
    ///
    /// ```swift
    /// try writer.write(hexadecimal: checksum.span.bytes)
    /// ```
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write as digits.
    ///   - uppercase: Whether the digits above 9 are `A`–`F` rather than `a`–`f`.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than twice `bytes.byteCount` bytes remain. Nothing
    ///   is written.
    /// - Precondition: The writer is byte-aligned.
    @inlinable
    @_lifetime(self: copy self)
    mutating func write(hexadecimal bytes: RawSpan, uppercase: Bool = false) throws(BytesError) {
        precondition(_bitOffset == 0, "Writing hexadecimal requires byte alignment: call alignToByte() first")
        _assumeInvariant()
        let count = bytes.byteCount &<< 1
        guard _bytes.byteCount &- _byteOffset >= count else { throw .insufficientCapacity }
        unsafe _Hexadecimal.encode(bytes, to: &_bytes, at: _byteOffset, uppercase: uppercase)
        _byteOffset &+= count
    }

    /// Writes the bytes that `text`'s hex digits spell (an even count of them). Requires byte alignment.
    ///
    /// - Parameter text: Two hex digits per byte.
    /// - Throws: ``BytesError/insufficientCapacity`` if fewer than half `text.byteCount` bytes remain;
    ///   ``BytesError/invalidValue`` for a byte that isn't a hex digit. The cursor doesn't move either way (an
    ///   invalid digit leaves the bytes before it written).
    @inlinable
    @_lifetime(self: copy self)
    internal mutating func _write(hexadecimalDigits text: RawSpan) throws(BytesError) {
        precondition(_bitOffset == 0 && text.byteCount & 1 == 0)
        _assumeInvariant()
        let count = text.byteCount &>> 1
        guard _bytes.byteCount &- _byteOffset >= count else { throw .insufficientCapacity }
        guard unsafe _Hexadecimal.decode(text, to: &_bytes, at: _byteOffset) else { throw .invalidValue }
        _byteOffset &+= count
    }
}

/// The encoder and decoder behind the hexadecimal APIs: out of line, and not generic over the cursor's mode.
@usableFromInline
enum _Hexadecimal {
    /// Writes two digits per byte of `bytes` to `span` from `offset`.
    ///
    /// Unsafe: unchecked loads and stores. Safe when the caller has checked that `span` has twice
    /// `bytes.byteCount` bytes from `offset`: every load is inside `bytes`, every store inside that range.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write as digits.
    ///   - span: The memory written to.
    ///   - offset: Where the first digit goes.
    ///   - uppercase: Whether the digits above 9 are `A`–`F`.
    @unsafe @usableFromInline
    static func encode(_ bytes: RawSpan, to span: inout MutableRawSpan, at offset: Int, uppercase: Bool) {
        // Added to each digit above 9 after `0x30`: from `:` to `a` or `A`.
        let letterOffset: UInt64 = uppercase ? 0x07 : 0x27
        let count = bytes.byteCount
        var index = 0
        // Unsafe: unchecked loads and stores. Safe: 8 bytes remain from `index`, and their 16 digits fit (above).
        while count &- index >= 8 {
            let word = unsafe Load.little(UInt64.self, from: bytes, at: index)
            unsafe Store.little(digits(UInt32(truncatingIfNeeded: word), letterOffset), to: &span, at: offset &+ index &<< 1)
            unsafe Store.little(digits(UInt32(truncatingIfNeeded: word &>> 32), letterOffset), to: &span, at: offset &+ index &<< 1 &+ 8)
            index &+= 8
        }
        // Unsafe and safe as above, a byte at a time.
        while index < count {
            let byte = unsafe Load.native(UInt8.self, from: bytes, at: index)
            unsafe Store.little(UInt16(truncatingIfNeeded: digits(UInt32(byte), letterOffset)), to: &span, at: offset &+ index &<< 1)
            index &+= 1
        }
    }

    /// The digits of four bytes, first byte's high nibble in the low byte.
    ///
    /// - Parameters:
    ///   - four: The bytes, first in the low bits.
    ///   - letterOffset: What to add to a digit above 9 after `0x30`.
    /// - Returns: Eight ASCII digits, in memory order when stored little-endian.
    @inline(__always)
    static func digits(_ four: UInt32, _ letterOffset: UInt64) -> UInt64 {
        // Each byte into a 16-bit lane, then its high nibble in the lane's low byte and its low nibble above.
        var lanes = UInt64(four)
        lanes = (lanes | lanes &<< 16) & 0x0000_FFFF_0000_FFFF
        lanes = (lanes | lanes &<< 8) & 0x00FF_00FF_00FF_00FF
        let nibbles = (lanes &>> 4) & 0x000F_000F_000F_000F | (lanes & 0x000F_000F_000F_000F) &<< 8
        // 1 in each byte whose nibble is 10 or more: adding 0x76 carries it to bit 7 (no carry between bytes).
        let letters = ((nibbles &+ 0x7676_7676_7676_7676) &>> 7) & 0x0101_0101_0101_0101
        return nibbles &+ 0x3030_3030_3030_3030 &+ letters &* letterOffset
    }

    /// Writes the bytes that `text`'s digit pairs spell to `span` from `offset`.
    ///
    /// Unsafe: unchecked loads and stores. Safe when `text.byteCount` is even and the caller has checked that
    /// `span` has half of it from `offset`: every load is inside `text`, every store inside that range.
    ///
    /// - Parameters:
    ///   - text: Two hex digits per byte.
    ///   - span: The memory written to.
    ///   - offset: Where the first byte goes.
    /// - Returns: Whether every byte of `text` was a hex digit. If not, the bytes before the first bad digit's
    ///   group are written.
    @unsafe @usableFromInline
    static func decode(_ text: RawSpan, to span: inout MutableRawSpan, at offset: Int) -> Bool {
        let count = text.byteCount
        var index = 0
        // Unsafe: unchecked loads and stores. Safe: 16 digits remain from `index`, and their 8 bytes fit (above).
        while count &- index >= 16 {
            let first = unsafe Load.little(UInt64.self, from: text, at: index)
            let second = unsafe Load.little(UInt64.self, from: text, at: index &+ 8)
            guard let low = value(first), let high = value(second) else { return false }
            unsafe Store.little(UInt64(low) | UInt64(high) &<< 32, to: &span, at: offset &+ index &>> 1)
            index &+= 16
        }
        // Unsafe and safe as above, a pair at a time (`count` is even).
        while index < count {
            let high = unsafe Load.native(UInt8.self, from: text, at: index).asciiHexDigitValue
            let low = unsafe Load.native(UInt8.self, from: text, at: index &+ 1).asciiHexDigitValue
            guard let high, let low else { return false }
            unsafe Store.little(high &<< 4 | low, to: &span, at: offset &+ index &>> 1)
            index &+= 2
        }
        return true
    }

    /// The four bytes that eight hex digits spell, or `nil` if one isn't a hex digit.
    ///
    /// - Parameter digits: The digits, first in the low byte.
    /// - Returns: The bytes, first in the low byte.
    @inline(__always)
    static func value(_ digits: UInt64) -> UInt32? {
        // With every byte below 0x80, adding to a byte can't carry into the next: each test is bit 7 of a sum.
        guard digits & 0x8080_8080_8080_8080 == 0 else { return nil }
        // `0`–`9`: at least 0x30 (sum reaches 0x80) and below 0x3A (the second sum doesn't).
        let isDigit = (digits &+ 0x5050_5050_5050_5050) & ~(digits &+ 0x4646_4646_4646_4646)
        // `a`–`f` once folded to lowercase: at least 0x61 and below 0x67.
        let folded = digits | 0x2020_2020_2020_2020
        let isLetter = (folded &+ 0x1F1F_1F1F_1F1F_1F1F) & ~(folded &+ 0x1919_1919_1919_1919)
        guard (isDigit | isLetter) & 0x8080_8080_8080_8080 == 0x8080_8080_8080_8080 else { return nil }
        // A digit's value is its low nibble; a letter's (bit 6 set) its low nibble plus 9.
        let nibbles = (digits & 0x0F0F_0F0F_0F0F_0F0F) &+ ((digits &>> 6) & 0x0101_0101_0101_0101) &* 9
        // Each 16-bit lane's two nibbles into a byte (the first is the high nibble), then the lanes packed.
        var lanes = (nibbles & 0x00FF_00FF_00FF_00FF) &<< 4 | (nibbles &>> 8) & 0x00FF_00FF_00FF_00FF
        lanes = (lanes | lanes &>> 8) & 0x0000_FFFF_0000_FFFF
        lanes = (lanes | lanes &>> 16) & 0xFFFF_FFFF
        return UInt32(truncatingIfNeeded: lanes)
    }
}
