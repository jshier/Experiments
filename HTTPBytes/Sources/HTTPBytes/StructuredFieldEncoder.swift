public import Bytes

/// Serializes Structured Field values (RFC 9651 §4.1) in canonical form into an `AlignedBytesWriter`.
///
/// Two levels:
/// - **Values and structure**, for fields made from values: ``writeBareItem(_:to:)``, ``writeParameter(key:value:to:)``,
///   ``writeDictionaryMember(key:value:to:)``, and the separators and parentheses (``writeMemberSeparator(to:)``,
///   ``writeInnerListStart(to:)``, ``writeInnerListSeparator(to:)``, ``writeInnerListEnd(to:)``,
///   ``writeDictionaryKey(_:to:)`` before an inner list). The caller writes members in order; the functions check
///   each value and key.
/// - **Parsed views**, re-serialized canonically: ``write(_:to:)-(HTTPStructuredItem,_)``, members, inner lists,
///   parameters (repeated keys merged: the last value in the first one's place), ``writeList(_:to:)``, and
///   ``writeDictionary(_:to:)``.
///
/// ```swift
/// // u=5, i
/// try HTTPStructuredFieldEncoder.writeDictionaryMember(key: u, value: .integer(5), to: &writer)
/// try HTTPStructuredFieldEncoder.writeMemberSeparator(to: &writer)
/// try HTTPStructuredFieldEncoder.writeDictionaryMember(key: i, value: .boolean(true), to: &writer)
/// ```
///
/// Each function writes all or nothing: on a throw, the writer is back where it was.
public enum HTTPStructuredFieldEncoder {
    // MARK: Separators

    /// Writes `, `, between List or Dictionary members.
    @inlinable
    public static func writeMemberSeparator(to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try capacity { () throws(BytesError) in try writer.write(0x202C as UInt16, as: Byte2.self, .littleEndian) }
    }

    /// Writes `(`, which starts an inner list.
    @inlinable
    public static func writeInnerListStart(to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try capacity { () throws(BytesError) in try writer.write(0x28 as UInt8) }
    }

    /// Writes ` `, between an inner list's items.
    @inlinable
    public static func writeInnerListSeparator(to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try capacity { () throws(BytesError) in try writer.write(0x20 as UInt8) }
    }

    /// Writes `)`, which ends an inner list (its parameters follow).
    @inlinable
    public static func writeInnerListEnd(to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try capacity { () throws(BytesError) in try writer.write(0x29 as UInt8) }
    }

    // MARK: Values

    /// Writes a bare item.
    ///
    /// - Throws: ``HTTPStructuredFieldError/valueOutOfRange`` for an Integer or Date outside ±999,999,999,999,999,
    ///   ``HTTPStructuredFieldError/invalidToken`` for a token that isn't one, ``HTTPStructuredFieldError/insufficientCapacity``.
    @inlinable
    public static func writeBareItem(_ item: HTTPStructuredBareItem, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        let start = writer.position
        do throws(HTTPStructuredFieldError) {
            try bareItem(item, to: &writer)
        } catch {
            writer.rewind(to: start)
            throw error
        }
    }

    /// Writes `;key`, for a parameter whose value is `true`, or `;key=value`.
    ///
    /// - Throws: ``HTTPStructuredFieldError/invalidKey``, or what ``writeBareItem(_:to:)`` throws.
    @inlinable
    public static func writeParameter(key: RawSpan, value: HTTPStructuredBareItem, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try checkKey(key)
        let start = writer.position
        do throws(HTTPStructuredFieldError) {
            try capacity { () throws(BytesError) in try writer.write(0x3B as UInt8) }
            try keyAndValue(key, value, to: &writer)
        } catch {
            writer.rewind(to: start)
            throw error
        }
    }

    /// Writes a Dictionary member whose value is an item: `key`, for `true` (its parameters follow), or `key=value`.
    ///
    /// - Throws: ``HTTPStructuredFieldError/invalidKey``, or what ``writeBareItem(_:to:)`` throws.
    @inlinable
    public static func writeDictionaryMember(key: RawSpan, value: HTTPStructuredBareItem, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try checkKey(key)
        let start = writer.position
        do throws(HTTPStructuredFieldError) {
            try keyAndValue(key, value, to: &writer)
        } catch {
            writer.rewind(to: start)
            throw error
        }
    }

    /// Writes `key=`, before a Dictionary member's inner list.
    ///
    /// - Throws: ``HTTPStructuredFieldError/invalidKey``, ``HTTPStructuredFieldError/insufficientCapacity``.
    @inlinable
    public static func writeDictionaryKey(_ key: RawSpan, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try checkKey(key)
        let start = writer.position
        do throws(BytesError) {
            try writer.write(key)
            try writer.write(0x3D as UInt8)
        } catch {
            writer.rewind(to: start)
            throw .insufficientCapacity
        }
    }

    // MARK: Parsed views

    /// Writes an item and its parameters.
    @inlinable
    public static func write(_ item: HTTPStructuredItem, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        let start = writer.position
        do throws(HTTPStructuredFieldError) {
            try bareItem(item.bareItem, to: &writer)
            try parameters(item.parameters, to: &writer)
        } catch {
            writer.rewind(to: start)
            throw error
        }
    }

    /// Writes parameters: each key once, with its last value, in the place of its first.
    @inlinable
    public static func write(_ parameters: HTTPStructuredParameters, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        let start = writer.position
        do throws(HTTPStructuredFieldError) {
            try Self.parameters(parameters, to: &writer)
        } catch {
            writer.rewind(to: start)
            throw error
        }
    }

    /// Writes an inner list and its parameters.
    @inlinable
    public static func write(_ innerList: HTTPStructuredInnerList, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        let start = writer.position
        do throws(HTTPStructuredFieldError) {
            try Self.innerList(innerList, to: &writer)
        } catch {
            writer.rewind(to: start)
            throw error
        }
    }

    /// Writes a List member or Dictionary value: an item or an inner list.
    @inlinable
    public static func write(_ member: HTTPStructuredMember, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        switch member {
        case let .item(item): try write(item, to: &writer)
        case let .innerList(list): try write(list, to: &writer)
        }
    }

    /// Parses the rest of `list` and writes its members, canonically (an empty List writes nothing: RFC 9651 §4.1.1
    /// says to leave such a field out).
    ///
    /// - Throws: What parsing throws, or ``HTTPStructuredFieldError/insufficientCapacity``.
    @inlinable
    public static func writeList(_ list: HTTPStructuredList, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        let start = writer.position
        do throws(HTTPStructuredFieldError) {
            var list = list
            var first = true
            while let member = try list.next() {
                if !first { try writeMemberSeparator(to: &writer) }
                first = false
                switch member {
                case let .item(item):
                    try bareItem(item.bareItem, to: &writer)
                    try parameters(item.parameters, to: &writer)
                case let .innerList(innerList):
                    try Self.innerList(innerList, to: &writer)
                }
            }
        } catch {
            writer.rewind(to: start)
            throw error
        }
    }

    /// Parses the rest of `dictionary`'s field line and writes its members canonically: each key once, with its last
    /// value, in the place of its first (an empty Dictionary writes nothing).
    ///
    /// - Throws: What parsing throws, or ``HTTPStructuredFieldError/insufficientCapacity``.
    @inlinable
    public static func writeDictionary(_ dictionary: HTTPStructuredDictionary, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        let start = writer.position
        do throws(HTTPStructuredFieldError) {
            var members = dictionary
            var index = 0
            var first = true
            while let member = try members.next() {
                defer { index &+= 1 }
                // Written already, at its first place?
                var earlier = dictionary
                var seen = false
                for _ in 0..<index {
                    if let other = try earlier.next(), other.key.bytesEqual(member.key) { seen = true }
                }
                if seen { continue }
                if !first { try writeMemberSeparator(to: &writer) }
                first = false
                var later = members
                var last = member
                while let other = try later.next() {
                    if other.key.bytesEqual(member.key) { last = other }
                }
                try capacity { () throws(BytesError) in try writer.write(member.key) }
                switch last.value {
                case let .item(item):
                    try valueAfterKey(item.bareItem, to: &writer)
                    try parameters(item.parameters, to: &writer)
                case let .innerList(innerList):
                    try capacity { () throws(BytesError) in try writer.write(0x3D as UInt8) }
                    try Self.innerList(innerList, to: &writer)
                }
            }
        } catch {
            writer.rewind(to: start)
            throw error
        }
    }

    // MARK: Pieces (no rewinding: the public functions rewind)

    /// Runs `body`, turning `BytesError` (only `insufficientCapacity` from a writer) into this module's error.
    @inlinable @inline(__always)
    static func capacity(_ body: () throws(BytesError) -> Void) throws(HTTPStructuredFieldError) {
        do throws(BytesError) {
            try body()
        } catch {
            throw .insufficientCapacity
        }
    }

    /// Checks a key: a lowercase letter or `*`, then lowercase letters, digits, `_`, `-`, `.`, `*`.
    @inlinable
    static func checkKey(_ key: RawSpan) throws(HTTPStructuredFieldError) {
        guard try StructuredFieldScan.keyEnd(key, from: 0) == key.byteCount else { throw .invalidKey }
    }

    /// `key`, then `=value` unless `value` is `true`.
    @inlinable
    static func keyAndValue(_ key: RawSpan, _ value: HTTPStructuredBareItem, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try capacity { () throws(BytesError) in try writer.write(key) }
        try valueAfterKey(value, to: &writer)
    }

    /// Nothing for `true`, otherwise `=` and the value.
    @inlinable
    static func valueAfterKey(_ value: HTTPStructuredBareItem, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        if case .boolean(true) = value { return }
        try capacity { () throws(BytesError) in try writer.write(0x3D as UInt8) }
        try bareItem(value, to: &writer)
    }

    @inlinable
    static func parameters(_ parameters: HTTPStructuredParameters, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        guard !parameters.isEmpty else { return }
        var all = parameters
        all.position = 0
        var current = all
        var index = 0
        while let parameter = current.next() {
            defer { index &+= 1 }
            var earlier = all
            var seen = false
            for _ in 0..<index {
                if let other = earlier.next(), other.key.bytesEqual(parameter.key) { seen = true }
            }
            if seen { continue }
            var later = current
            var last = parameter
            while let other = later.next() {
                if other.key.bytesEqual(parameter.key) { last = other }
            }
            try capacity { () throws(BytesError) in try writer.write(0x3B as UInt8) }
            try keyAndValue(parameter.key, last.value, to: &writer)
        }
    }

    @inlinable
    static func innerList(_ innerList: HTTPStructuredInnerList, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try capacity { () throws(BytesError) in try writer.write(0x28 as UInt8) }
        var items = innerList
        items.position = 0
        var first = true
        while let item = items.next() {
            if !first { try capacity { () throws(BytesError) in try writer.write(0x20 as UInt8) } }
            first = false
            try bareItem(item.bareItem, to: &writer)
            try parameters(item.parameters, to: &writer)
        }
        try capacity { () throws(BytesError) in try writer.write(0x29 as UInt8) }
        try parameters(innerList.parameters, to: &writer)
    }

    @inlinable
    static func bareItem(_ item: HTTPStructuredBareItem, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        switch item {
        case let .integer(value):
            guard value >= -HTTPStructuredDecimal.limit, value <= HTTPStructuredDecimal.limit else { throw .valueOutOfRange }
            try capacity { () throws(BytesError) in try integer(value, to: &writer) }
        case let .decimal(value):
            try capacity { () throws(BytesError) in try decimal(value, to: &writer) }
        case let .string(value):
            try capacity { () throws(BytesError) in try string(value, to: &writer) }
        case let .token(value):
            guard value.byteCount > 0, case let first = value.load(fromByteOffset: 0, as: UInt8.self),
                  (first | 0x20) &- 0x61 < 26 || first == 0x2A,
                  !value.extracting(droppingFirst: 1).containsByte(where: StructuredFieldScan.tokenStop) else { throw .invalidToken }
            try capacity { () throws(BytesError) in try writer.write(value) }
        case let .byteSequence(value):
            try capacity { () throws(BytesError) in try byteSequence(value, to: &writer) }
        case let .boolean(value):
            try capacity { () throws(BytesError) in try writer.write(value ? 0x313F as UInt16 : 0x303F, as: Byte2.self, .littleEndian) }
        case let .date(value):
            guard value >= -HTTPStructuredDecimal.limit, value <= HTTPStructuredDecimal.limit else { throw .valueOutOfRange }
            try capacity { () throws(BytesError) in
                try writer.write(0x40 as UInt8)
                try integer(value, to: &writer)
            }
        case let .displayString(value):
            try capacity { () throws(BytesError) in try displayString(value, to: &writer) }
        }
    }

    /// An integer's digits, with `-` if it's negative.
    @inlinable
    static func integer(_ value: Int64, to writer: inout AlignedBytesWriter) throws(BytesError) {
        if value < 0 { try writer.write(0x2D as UInt8) }
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var index = 20
        var rest = value.magnitude
        repeat {
            index &-= 1
            digits[index] = 0x30 &+ UInt8(truncatingIfNeeded: rest % 10)
            rest /= 10
        } while rest != 0
        try writer.write(digits.span.bytes.extracting(index..<20))
    }

    /// A decimal's integer digits, `.`, and 1 to 3 fractional digits (trailing zeros dropped, one kept).
    @inlinable
    static func decimal(_ value: HTTPStructuredDecimal, to writer: inout AlignedBytesWriter) throws(BytesError) {
        let magnitude = value.thousandths.magnitude
        if value.thousandths < 0 { try writer.write(0x2D as UInt8) }
        try integer(Int64(magnitude / 1000), to: &writer)
        try writer.write(0x2E as UInt8)
        let fraction = magnitude % 1000
        if fraction % 100 == 0 {
            try writer.write(fraction / 100, asciiDigits: 1)
        } else if fraction % 10 == 0 {
            try writer.write(fraction / 10, asciiDigits: 2)
        } else {
            try writer.write(fraction, asciiDigits: 3)
        }
    }

    /// A String: quoted, with `"` and `\` escaped. (A parsed string's escapes are already the canonical ones.)
    @inlinable
    static func string(_ value: HTTPStructuredString, to writer: inout AlignedBytesWriter) throws(BytesError) {
        try writer.write(0x22 as UInt8)
        let bytes = value.bytes
        if value.isEscaped {
            try writer.write(bytes)
        } else {
            var position = 0
            while position < bytes.byteCount {
                let rest = bytes.extracting(droppingFirst: position)
                guard let found = rest.firstByteOffset(where: { $0.matching(0x22) | $0.matching(0x5C) }) else {
                    try writer.write(rest)
                    break
                }
                try writer.write(rest.extracting(0..<found))
                try writer.write(0x5C as UInt8)
                try writer.write(rest.load(fromByteOffset: found, as: UInt8.self))
                position &+= found &+ 1
            }
        }
        try writer.write(0x22 as UInt8)
    }

    /// A Byte Sequence: padded Base64 between colons. Parsed Base64 is copied in whole groups, and its last group made
    /// canonical (padded, unused bits zero).
    @inlinable
    static func byteSequence(_ value: HTTPStructuredByteSequence, to writer: inout AlignedBytesWriter) throws(BytesError) {
        try writer.write(0x3A as UInt8)
        let bytes = value.bytes
        if !value.isBase64 {
            try StructuredFieldScan.encodeBase64(bytes, into: &writer)
        } else {
            let count = bytes.byteCount, whole = count & ~3
            try writer.write(bytes.extracting(0..<whole))
            if count &- whole >= 2 {
                try writer.write(bytes.load(fromByteOffset: whole, as: UInt8.self))
                let second = StructuredFieldScan.base64Value(bytes.load(fromByteOffset: whole &+ 1, as: UInt8.self))
                if count &- whole == 2 {
                    try writer.write(StructuredFieldScan.base64Character(second & 0x30))
                    try writer.write(0x3D3D as UInt16, as: Byte2.self, .littleEndian)
                } else {
                    try writer.write(bytes.load(fromByteOffset: whole &+ 1, as: UInt8.self))
                    let third = StructuredFieldScan.base64Value(bytes.load(fromByteOffset: whole &+ 2, as: UInt8.self))
                    try writer.write(StructuredFieldScan.base64Character(third & 0x3C))
                    try writer.write(0x3D as UInt8)
                }
            }
        }
        try writer.write(0x3A as UInt8)
    }

    /// A Display String: `%"`, printable ASCII other than `%` and `"` as it is, every other byte of UTF-8 as `%` and
    /// two lowercase hexadecimal digits, `"`. A parsed one's escapes of bytes that needn't be escaped are undone.
    @inlinable
    static func displayString(_ value: HTTPStructuredDisplayString, to writer: inout AlignedBytesWriter) throws(BytesError) {
        try writer.write(0x2225 as UInt16, as: Byte2.self, .littleEndian)
        let bytes = value.bytes
        let isPercentEncoded = value.isPercentEncoded
        var position = 0
        while position < bytes.byteCount {
            let rest = bytes.extracting(droppingFirst: position)
            guard let found = rest.firstByteOffset(where: StructuredFieldScan.displayStop) else {
                try writer.write(rest)
                break
            }
            try writer.write(rest.extracting(0..<found))
            var byte = rest.load(fromByteOffset: found, as: UInt8.self)
            position &+= found &+ 1
            if isPercentEncoded {
                // Parsed: every stop is a `%` and two lowercase digits (checked when parsed).
                byte = StructuredFieldScan.hexValue(rest.load(fromByteOffset: found &+ 1, as: UInt8.self)) &<< 4
                    | StructuredFieldScan.hexValue(rest.load(fromByteOffset: found &+ 2, as: UInt8.self))
                position &+= 2
                if byte &- 0x20 < 0x5F, byte != 0x25, byte != 0x22 {
                    try writer.write(byte)
                    continue
                }
            }
            let digits = (byte &>> 4, byte & 0xF)
            try writer.write(0x25 as UInt8)
            try writer.write(digits.0 < 10 ? 0x30 &+ digits.0 : 0x57 &+ digits.0)
            try writer.write(digits.1 < 10 ? 0x30 &+ digits.1 : 0x57 &+ digits.1)
        }
        try writer.write(0x22 as UInt8)
    }
}
