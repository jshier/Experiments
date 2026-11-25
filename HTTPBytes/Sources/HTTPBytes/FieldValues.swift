// Field-value grammar shared by every version (RFC 9110 §5.6): lists, tokens, numbers.

/// Comma-separated lists in field values (RFC 9110 §5.6.1): elements with optional whitespace around them; empty
/// elements skipped.
public enum HTTPList {
    /// Calls `body` with each element of `value`, trimmed of spaces and tabs.
    @inlinable
    public static func forEachElement(of value: RawSpan, _ body: (RawSpan) -> Void) {
        let count = value.byteCount
        var start = 0
        while start < count {
            // The element ends at a comma outside a quoted string (RFC 9110 §5.6.4: quoted strings may hold commas, and
            // a backslash escapes the next byte). Splitting inside quotes let `x;p=", chunked;q="` read as ending in
            // `chunked` to one parser and not to another.
            var end = start
            var quoted = false
            while end < count {
                let byte = value.load(fromByteOffset: end, as: UInt8.self)
                if quoted {
                    if byte == 0x5C { end &+= 1 } else if byte == 0x22 { quoted = false }
                } else if byte == 0x22 {
                    quoted = true
                } else if byte == 0x2C {
                    break
                }
                end &+= 1
            }
            end = Swift.min(end, count)
            var first = start, last = end
            while first < last, case let byte = value.load(fromByteOffset: first, as: UInt8.self), byte == 0x20 || byte == 0x09 {
                first &+= 1
            }
            while last > first, case let byte = value.load(fromByteOffset: last &- 1, as: UInt8.self), byte == 0x20 || byte == 0x09 {
                last &-= 1
            }
            if last > first { body(value.extracting(first..<last)) }
            start = end &+ 1
        }
    }
}

/// Tokens and numbers in field values.
public enum HTTPToken {
    /// Whether `bytes` spell `token` in any case (ASCII letters only fold). `token` must be lowercase: only `bytes` are
    /// folded (the overload taking two spans folds both).
    @inlinable
    public static func equalsIgnoringCase(_ bytes: RawSpan, _ token: StaticString) -> Bool {
        let expected = immortalSpan(token)
        assert((0..<expected.byteCount).allSatisfy { expected.load(fromByteOffset: $0, as: UInt8.self) &- 0x41 >= 26 },
               "a lowercase literal")
        guard bytes.byteCount == expected.byteCount else { return false }
        for offset in 0..<bytes.byteCount {
            let byte = bytes.load(fromByteOffset: offset, as: UInt8.self)
            let folded = byte &- 0x41 < 26 ? byte | 0x20 : byte
            guard folded == expected.load(fromByteOffset: offset, as: UInt8.self) else { return false }
        }
        return true
    }

    /// `bytes` up to the first `delimiter` (or all of them), trimmed of trailing spaces and tabs.
    @inlinable
    @_lifetime(copy bytes)
    public static func prefix(_ bytes: RawSpan, upTo delimiter: UInt8) -> RawSpan {
        var end = 0
        while end < bytes.byteCount, bytes.load(fromByteOffset: end, as: UInt8.self) != delimiter {
            end &+= 1
        }
        while end > 0, case let byte = bytes.load(fromByteOffset: end &- 1, as: UInt8.self), byte == 0x20 || byte == 0x09 {
            end &-= 1
        }
        return bytes.extracting(0..<end)
    }

    /// `bytes` as a non-negative decimal number (1 to 18 digits, so it can't overflow), or `nil`.
    @inlinable
    public static func decimal(_ bytes: RawSpan) -> Int? {
        let count = bytes.byteCount
        guard count > 0, count <= 18 else { return nil }
        var value = 0
        for offset in 0..<count {
            let digit = bytes.load(fromByteOffset: offset, as: UInt8.self) &- 0x30
            guard digit < 10 else { return nil }
            value = value &* 10 &+ Int(digit)
        }
        return value
    }
}
