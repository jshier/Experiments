import Bytes

// Reads the Bytes ports of swift-binary-parsing's examples need and Bytes doesn't have (yet): proposals, written
// here with Bytes' public API. See the ports' notes for each.

extension GenericBytesReader where Mode: ByteAlignedCursorMode {
    /// Reads UTF-8 up to the next NUL byte, and consumes the NUL: a C string, as swift-binary-parsing's
    /// `String(parsingNulTerminated:)` reads one.
    ///
    /// - Returns: A UTF-8 view of the text, not including the NUL.
    /// - Throws: `BytesError.insufficientData` if no NUL follows; `BytesError.invalidValue` if the text isn't
    ///   valid UTF-8. Nothing is consumed either way.
    @inline(__always)
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readNulTerminatedUTF8() throws(BytesError) -> UTF8Span {
        // Bytes has 16-byte scans for patterns of 2 bytes or more (`firstByteOffset(of:)`) but none for one byte,
        // so this finds the NUL as `String(parsingNulTerminated:)` does. Unsafe: the remaining bytes through a
        // buffer pointer. Safe: `firstIndex(of:)` only reads within the buffer, inside the closure.
        guard let length = remainingBytes.withUnsafeBytes({ buffer in unsafe buffer.firstIndex(of: 0) }) else {
            throw .insufficientData
        }
        let text = try readUTF8(byteCount: length)
        try skip(byteCount: 1) // Can't throw: the NUL is there.
        return text
    }
}

extension GenericBytesReader where Mode: ByteOrderedCursorMode {
    /// Reads an unsigned integer of `byteCount` bytes, 1 through 8, in the cursor's byte order: a width known
    /// only at run time, such as a binary property list's offset and reference sizes.
    ///
    /// - Parameter byteCount: The integer's width in bytes, 1 through 8.
    /// - Returns: The value.
    /// - Throws: `BytesError.insufficientData` if fewer bytes remain, consuming nothing.
    @inline(__always)
    @_lifetime(self: copy self)
    mutating func read(_ type: UInt64.Type, byteCount: Int) throws(BytesError) -> UInt64 {
        precondition(byteCount >= 1 && byteCount <= 8, "An integer of 1 through 8 bytes")
        let unusedBits = UInt64(64 &- 8 &* byteCount)
        if remainingByteCount >= 8 {
            // One 8-byte load, then keep the value's bytes: no loop over a width the compiler doesn't know.
            let wide = try peek(UInt64.self)
            try skip(byteCount: byteCount) // Can't throw: 8 bytes remain.
            return switch Mode.byteOrder {
            case .bigEndian: wide &>> unusedBits
            case .littleEndian: (wide &<< unusedBits) &>> unusedBits
            }
        }
        // Near the end of the input: a byte at a time.
        var field = try readSection(byteCount: byteCount)
        var value: UInt64 = 0
        for index in 0..<byteCount {
            let byte = UInt64(try field.read(UInt8.self))
            switch Mode.byteOrder {
            case .bigEndian: value = value &<< 8 | byte
            case .littleEndian: value |= byte &<< UInt64(8 &* index)
            }
        }
        return value
    }
}

extension FixedWidthInteger {
    /// The value rounded up to a multiple of 4, wrapping: PCAPNG's padding.
    @inline(__always)
    var roundedUpToMultipleOf4: Self { (self &+ 3) & ~3 }
}
