// HPACK's prefix integers (RFC 7541 §5.1), which QPACK uses too (RFC 9204 §4.1.1): a value in the low N bits of a
// byte whose high bits are flags, continued in 7-bit groups, least significant first, when it doesn't fit.

/// Why a prefix integer couldn't be read.
@frozen
public enum HPACKPrefixIntegerError: Error, Equatable, Sendable {
    /// The bytes end inside the integer.
    case truncated
    /// The integer passes 2³² − 1 (this implementation's limit, as RFC 7541 §5.1 allows), or has more than 5
    /// continuation bytes.
    case overflow
}

/// Prefix integers (RFC 7541 §5.1): reading and writing.
///
/// ```swift
/// var offset = 0
/// let index = try HPACKPrefixInteger.read(from: block, at: &offset, prefixBits: 7)
/// try HPACKPrefixInteger.write(1337, prefixBits: 5, flags: 0x20, into: &output)
/// ```
public enum HPACKPrefixInteger {
    /// The largest value read: 2³² − 1.
    @inlinable public static var maximum: Int { 0xFFFF_FFFF }

    /// Reads the integer at `offset` with a `prefixBits`-bit prefix (1 through 8), ignoring the first byte's other
    /// bits, and moves `offset` past it.
    @inlinable
    public static func read(from bytes: RawSpan, at offset: inout Int, prefixBits: Int) throws(HPACKPrefixIntegerError) -> Int {
        precondition(prefixBits >= 1 && prefixBits <= 8, "a prefix has 1 to 8 bits")
        precondition(offset >= 0, "a negative offset")
        let value = bytes.withUnsafeBytes { buffer -> Int in
            guard offset < buffer.count else { return prefixIntegerTruncated }
            // Unsafe: the span's own bytes, read within its count by the reader (offset < count, checked above).
            let base = unsafe buffer.baseAddress.unsafelyUnwrapped.assumingMemoryBound(to: UInt8.self)
            let mask = (1 &<< prefixBits) &- 1
            let first = Int(unsafe base[offset]) & mask
            guard first == mask else {
                offset &+= 1
                return first
            }
            return unsafe readPrefixIntegerContinuation(base, buffer.count, &offset, mask)
        }
        if value == prefixIntegerTruncated { throw .truncated }
        if value == prefixIntegerOverflow { throw .overflow }
        return value
    }

    /// The number of bytes `value` takes with a `prefixBits`-bit prefix.
    @inlinable
    public static func byteCount(of value: Int, prefixBits: Int) -> Int {
        let mask = (1 &<< prefixBits) &- 1
        if value < mask { return 1 }
        var rest = value &- mask
        var count = 2
        while rest >= 128 { rest &>>= 7; count &+= 1 }
        return count
    }

    /// Appends `value` (0 through 2³² − 1) with a `prefixBits`-bit prefix (1 through 8), `flags` in the first byte's
    /// other bits.
    @inlinable
    public static func write(_ value: Int, prefixBits: Int, flags: UInt8 = 0, into output: inout OutputRawSpan) throws(HPACKPrefixIntegerError) {
        precondition(prefixBits >= 1 && prefixBits <= 8, "a prefix has 1 to 8 bits")
        precondition(value >= 0 && value <= maximum, "a prefix integer is 0 through 2³² − 1")
        let written = unsafe output.withUnsafeMutableBytes { target, initialized in
            // Unsafe: the output's free memory from `initialized`; the writer stores below the capacity it's given and
            // reports what it wrote.
            let n = unsafe withFreeBytes(target, from: initialized) { base, capacity in
                unsafe writePrefixInteger(value, mask: (1 &<< prefixBits) &- 1, flags: flags, base, capacity)
            }
            if n > 0 { initialized &+= n }
            return n
        }
        if written < 0 { throw .truncated }
    }
}

/// `readPrefixIntegerContinuation`'s result when the bytes end inside the integer.
@inlinable package var prefixIntegerTruncated: Int { -1 }
/// `readPrefixIntegerContinuation`'s result for an integer past the limit.
@inlinable package var prefixIntegerOverflow: Int { -2 }

/// The rest of an integer whose prefix was all ones (`mask`), at `base[offset]`: reads the continuation bytes and moves
/// `offset` past them. Out of line: most integers fit their prefix, and the caller's loop shouldn't carry this one.
/// - Returns: The value, `prefixIntegerTruncated`, or `prefixIntegerOverflow`.
@usableFromInline @inline(never)
package func readPrefixIntegerContinuation(
    _ base: UnsafePointer<UInt8>, _ count: Int, _ offset: inout Int, _ mask: Int
) -> Int {
    var position = offset &+ 1
    var value = mask
    var shift = 0
    while true {
        guard position < count else { return prefixIntegerTruncated }
        // Unsafe: an unchecked read. Safe: position < count.
        let byte = Int(unsafe base[position])
        position &+= 1
        value &+= (byte & 0x7F) &<< shift
        if byte < 0x80 { break }
        shift &+= 7
        // Five continuation bytes hold 35 bits: enough for 2³² − 1 from any prefix.
        guard shift < 35 else { return prefixIntegerOverflow }
    }
    guard value <= 0xFFFF_FFFF else { return prefixIntegerOverflow }
    offset = position
    return value
}

/// `readPrefixIntegerContinuation` for QPACK, whose integers go to 62 bits (RFC 9204 §4.1.1: stream IDs and counts are
/// QUIC's): up to 9 continuation bytes, a value up to 2⁶² − 1. Out of line, as the 32-bit one.
/// - Returns: The value, `prefixIntegerTruncated`, or `prefixIntegerOverflow`.
@usableFromInline @inline(never)
package func readPrefixInteger62Continuation(
    _ base: UnsafePointer<UInt8>, _ count: Int, _ offset: inout Int, _ mask: Int
) -> Int {
    var position = offset &+ 1
    var value = mask
    var shift = 0
    while true {
        guard position < count else { return prefixIntegerTruncated }
        // Unsafe: an unchecked read. Safe: position < count.
        let byte = Int(unsafe base[position])
        position &+= 1
        // At shift 56 only 6 bits more fit 62; anything above is an overflow, caught below or by the next shift.
        if shift == 56, byte & 0x7F > 0x3F { return prefixIntegerOverflow }
        value &+= (byte & 0x7F) &<< shift
        if byte < 0x80 { break }
        shift &+= 7
        guard shift <= 56 else { return prefixIntegerOverflow }
    }
    guard value <= (1 &<< 62) &- 1 else { return prefixIntegerOverflow }
    offset = position
    return value
}

/// Writes `value` with the prefix `mask` (2^N − 1) and `flags` at `output`.
/// - Returns: Bytes written, or -1 if they don't fit `capacity`.
@inlinable @inline(__always)
package func writePrefixInteger(_ value: Int, mask: Int, flags: UInt8, _ output: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int {
    if value < mask, capacity >= 1 {
        // Unsafe: an unchecked store. Safe: capacity >= 1.
        unsafe output[0] = flags | UInt8(truncatingIfNeeded: value)
        return 1
    }
    return unsafe writePrefixIntegerContinued(value, mask: mask, flags: flags, output, capacity)
}

/// `writePrefixInteger` for values that don't fit the prefix (or no room at all).
@usableFromInline @inline(never)
package func writePrefixIntegerContinued(_ value: Int, mask: Int, flags: UInt8, _ output: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int {
    guard capacity >= 1 else { return -1 }
    if value < mask {
        // Unsafe: an unchecked store. Safe: capacity >= 1.
        unsafe output[0] = flags | UInt8(truncatingIfNeeded: value)
        return 1
    }
    // Unsafe: an unchecked store. Safe: capacity >= 1.
    unsafe output[0] = flags | UInt8(truncatingIfNeeded: mask)
    var rest = value &- mask
    var n = 1
    while rest >= 128 {
        guard n < capacity else { return -1 }
        // Unsafe: an unchecked store. Safe: n < capacity.
        unsafe output[n] = UInt8(truncatingIfNeeded: rest) | 0x80
        rest &>>= 7
        n &+= 1
    }
    guard n < capacity else { return -1 }
    // Unsafe: an unchecked store. Safe: n < capacity.
    unsafe output[n] = UInt8(truncatingIfNeeded: rest)
    return n &+ 1
}
