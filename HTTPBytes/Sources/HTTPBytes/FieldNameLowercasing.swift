public import Bytes

// Lowercase names for HPACK's and QPACK's encoders: HTTP/2 and HTTP/3 require them (RFC 9113 §8.2.1, RFC 9114 §4.2), and
// a store's fields may be spelled as HTTP/1 sent them (`Host`, `X-Request-Id`).

package extension HTTPFieldName {
    /// What an encoder writes as the name of a field whose known name has table index `knownName` (0xFF: not known): the
    /// known name's ``lowercaseBytes``, else `name` itself. Matching ignores a known name's bytes (it's by index), so only
    /// the places that write or keep a name's bytes need this.
    @inlinable @inline(__always)
    static func lowercaseSpelling(_ knownName: UInt8, _ name: UnsafeRawPointer?, _ nameCount: Int) -> (UnsafeRawPointer?, Int) {
        guard knownName != 0xFF else { return unsafe (name, nameCount) }
        return HTTPFieldName(tableIndex: knownName).lowercaseBytes.withUnsafeBytes { bytes in
            // The address escapes the closure, which is safe here: it's the static table of names, a global constant that
            // lives as long as the program and never changes.
            (bytes.baseAddress, bytes.count)
        }
    }
}

/// Memory to lowercase names HTTPBytes doesn't know into before an encoder writes them, made once and grown only for a
/// name longer than any before: no allocation per field.
@usableFromInline
package struct FieldNameLowercasing: ~Copyable, Sendable {
    @usableFromInline var scratch: UniqueArray<UInt8>

    @usableFromInline
    package init(capacity: Int = 64) {
        scratch = UniqueArray(repeating: 0, count: Swift.max(capacity, 16))
    }

    /// Whether `name` has an ASCII uppercase letter: a scan of 16 bytes at a time.
    @inlinable @inline(__always)
    package static func hasUppercase(_ name: RawSpan) -> Bool {
        name.containsByte(where: uppercaseLetters)
    }

    /// Lanes that are ASCII uppercase letters.
    @inlinable @inline(__always)
    package static func uppercaseLetters(_ lanes: ByteLanes) -> ByteMatches {
        lanes.matching(in: 0x41...0x5A)
    }

    /// `name`'s bytes with ASCII letters lowercased, at the returned address (`name.byteCount` bytes), valid until this
    /// memory is next used.
    @usableFromInline
    package mutating func lowercase(_ name: RawSpan) -> UnsafeRawPointer {
        let count = name.byteCount
        if count > scratch.count {
            // Nothing holds the old memory between calls.
            scratch = UniqueArray(repeating: 0, count: Swift.max(count, scratch.count &* 2))
        }
        var output = scratch.mutableSpan
        for offset in 0..<count {
            let byte = name.load(fromByteOffset: offset, as: UInt8.self)
            output[offset] = byte &- 0x41 < 26 ? byte | 0x20 : byte
        }
        return scratch.span.withUnsafeBytes {
            // Unsafe: the scratch memory's address, kept past the closure. Safe: it stays where it is until the next
            // call (which is when the caller's use ends, as this method's contract says).
            unsafe UnsafeRawPointer($0.baseAddress.unsafelyUnwrapped)
        }
    }
}
