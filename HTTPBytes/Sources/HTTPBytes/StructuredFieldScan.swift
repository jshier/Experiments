public import Bytes
import BytesBase64

/// The Structured Fields parser's steps (RFC 9651 §4.2), each a static function over the field value's bytes and an
/// offset in them (taken and returned in locals, so a member's walk keeps its state in registers), validating as it
/// goes.
///
/// Strings, tokens, byte sequences, and display strings, which can be long, are scanned 16 bytes at a time
/// (`firstByteOffset(where:)` with a lane test for the bytes that end or can't be in each); keys, numbers, and
/// whitespace, which are short, a byte at a time.
@usableFromInline
enum StructuredFieldScan {
    // MARK: Bytes

    /// The byte at `offset`, unchecked.
    ///
    /// - Precondition: `0 <= offset < bytes.byteCount`: every caller compares `offset` with the count first.
    @inlinable @inline(__always)
    static func byte(_ bytes: RawSpan, _ offset: Int) -> UInt8 {
        assert(offset >= 0 && offset < bytes.byteCount, "byte offset out of bounds")
        // Unsafe: an unchecked load. Safe: the precondition above, which every caller establishes.
        return unsafe bytes.unsafeLoad(fromUncheckedByteOffset: offset, as: UInt8.self)
    }

    /// The offset of the first byte at or after `start` that isn't a space (SP), or the count.
    @inlinable @inline(__always)
    static func spacesEnd(_ bytes: RawSpan, from start: Int) -> Int {
        var position = start
        while position < bytes.byteCount, byte(bytes, position) == 0x20 {
            position &+= 1
        }
        return position
    }

    /// The offset of the first byte at or after `start` that isn't optional whitespace (SP or HTAB), or the count.
    @inlinable @inline(__always)
    static func whitespaceEnd(_ bytes: RawSpan, from start: Int) -> Int {
        var position = start
        while position < bytes.byteCount, case let byte = byte(bytes, position), byte == 0x20 || byte == 0x09 {
            position &+= 1
        }
        return position
    }

    // MARK: Lane tests

    /// Lanes outside printable ASCII (0x20–0x7E): one subtraction and one comparison (bytes below 0x20 wrap high).
    @inlinable @inline(__always)
    static func outsidePrintable(_ vector: SIMD16<UInt8>) -> SIMDMask<SIMD16<Int8>> {
        (vector &- SIMD16(repeating: 0x20)) .>= SIMD16(repeating: 0x5F)
    }

    /// Lanes outside printable ASCII.
    @inlinable @inline(__always)
    static func nonPrintable(_ lanes: ByteLanes) -> ByteMatches {
        ByteMatches(outsidePrintable(lanes.vector))
    }

    /// Lanes that end a String's run of plain bytes: `"`, `\`, and bytes outside printable ASCII.
    @inlinable @inline(__always)
    static func stringStop(_ lanes: ByteLanes) -> ByteMatches {
        let vector = lanes.vector
        return ByteMatches(outsidePrintable(vector) .| (vector .== SIMD16(repeating: 0x22))
            .| (vector .== SIMD16(repeating: 0x5C)))
    }

    /// Lanes that end a Display String's run of plain bytes: `"`, `%`, and bytes outside printable ASCII.
    @inlinable @inline(__always)
    static func displayStop(_ lanes: ByteLanes) -> ByteMatches {
        let vector = lanes.vector
        return ByteMatches(outsidePrintable(vector) .| (vector .== SIMD16(repeating: 0x22))
            .| (vector .== SIMD16(repeating: 0x25)))
    }

    /// Lanes that can't be in a Token after its first byte: not a token character (`tchar`), `:`, or `/`. Two
    /// one-register lookups, as `HTTPCharacters.nonToken`, with `:` and `/` added to its column table.
    @inlinable @inline(__always)
    static func tokenStop(_ lanes: ByteLanes) -> ByteMatches {
        // `HTTPCharacters.nonToken`'s tables with bit 1 set in column 0xA (`:`, row 3) and bit 0 in column 0xF (`/`,
        // row 2).
        let columns = SIMD16<UInt8>(0x3A, 0x3F, 0x3E, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3E, 0x3E, 0x3F, 0x15, 0x34, 0x15, 0x3D, 0x1D)
        let rows = SIMD16<UInt8>(0, 0, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0, 0, 0, 0, 0, 0, 0, 0)
        let column = ByteLanes(lanes.vector & SIMD16(repeating: 0x0F)).lookup(in: columns)
        let row = ByteLanes(lanes.vector &>> SIMD16(repeating: 4)).lookup(in: rows)
        return ByteMatches((column & row) .== SIMD16(repeating: 0))
    }

    /// Lanes that aren't Base64 characters (`=` included: padding ends the characters).
    @inlinable @inline(__always)
    static func base64Stop(_ lanes: ByteLanes) -> ByteMatches {
        let vector = lanes.vector
        let letter = ((vector | SIMD16(repeating: 0x20)) &- SIMD16(repeating: 0x61)) .< SIMD16(repeating: 26)
        let digit = (vector &- SIMD16(repeating: 0x30)) .< SIMD16(repeating: 10)
        let symbol = (vector .== SIMD16(repeating: 0x2B)) .| (vector .== SIMD16(repeating: 0x2F))
        return ByteMatches(.!(letter .| digit .| symbol))
    }

    // MARK: Small classes

    /// Whether `byte` can be in a key after its first byte: lowercase letters, digits, `_`, `-`, `.`, `*`. A 128-bit
    /// set in two words.
    @inlinable @inline(__always)
    static func isKeyCharacter(_ byte: UInt8) -> Bool {
        // `*` 42, `-` 45, `.` 46, digits 48–57; then (from 64) `_` 95, `a`–`z` 97–122.
        let low: UInt64 = 1 &<< 42 | 1 &<< 45 | 1 &<< 46 | 0x3FF &<< 48
        let high: UInt64 = 1 &<< 31 | 0x3FF_FFFF &<< 33
        return byte < 128 && ((byte < 64 ? low : high) &>> UInt64(byte & 63)) & 1 != 0
    }

    /// Whether `byte` can start a key: a lowercase letter or `*`.
    @inlinable @inline(__always)
    static func isKeyStart(_ byte: UInt8) -> Bool {
        byte &- 0x61 < 26 || byte == 0x2A
    }

    /// The value of a lowercase hexadecimal digit, or 0xFF.
    @inlinable @inline(__always)
    static func hexValue(_ byte: UInt8) -> UInt8 {
        if byte &- 0x30 < 10 { return byte &- 0x30 }
        if byte &- 0x61 < 6 { return byte &- 0x61 &+ 10 }
        return 0xFF
    }

    /// The value of a Base64 character (standard alphabet), which the caller has checked is one.
    @inlinable @inline(__always)
    static func base64Value(_ byte: UInt8) -> UInt8 {
        if byte &- 0x41 < 26 { return byte &- 0x41 }
        if byte &- 0x61 < 26 { return byte &- 0x61 &+ 26 }
        if byte &- 0x30 < 10 { return byte &- 0x30 &+ 52 }
        return byte == 0x2B ? 62 : 63
    }

    /// The Base64 character (standard alphabet) for a 6-bit value.
    @inlinable @inline(__always)
    static func base64Character(_ value: UInt8) -> UInt8 {
        if value < 26 { return 0x41 &+ value }
        if value < 52 { return 0x61 &+ value &- 26 }
        if value < 62 { return 0x30 &+ value &- 52 }
        return value == 62 ? 0x2B : 0x2F
    }

    /// Decodes whole groups of 4 Base64 characters, validated when parsed, into `writer`, which has room.
    @usableFromInline
    static func decodeBase64Groups(_ text: RawSpan, into writer: inout AlignedBytesWriter) {
        do throws(LocatedBytesError) {
            try Base64.decode(text, into: &writer, padding: false)
        } catch {
            preconditionFailure("byte sequences are validated when parsed, and the caller checked the room")
        }
    }

    /// Encodes `bytes` as padded Base64 into `writer`.
    @usableFromInline
    static func encodeBase64(_ bytes: RawSpan, into writer: inout AlignedBytesWriter) throws(BytesError) {
        try Base64.encode(bytes, into: &writer)
    }

    // MARK: Bare items

    /// An Integer or Decimal at `position` (its first byte, a digit or `-`, is there): its value (thousandths for a
    /// Decimal) and whether it's a Decimal.
    @inlinable
    static func number(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> (value: Int64, isDecimal: Bool) {
        let count = bytes.byteCount
        var offset = position
        let negative = byte(bytes, offset) == 0x2D
        if negative { offset &+= 1 }
        let start = offset
        var value: Int64 = 0
        while offset < count {
            let digit = byte(bytes, offset) &- 0x30
            guard digit < 10 else { break }
            guard offset &- start < 15 else { throw .invalidInteger }
            value = value &* 10 &+ Int64(digit)
            offset &+= 1
        }
        let integerDigits = offset &- start
        guard integerDigits > 0 else { throw .invalidInteger }
        guard offset < count, byte(bytes, offset) == 0x2E else {
            position = offset
            return (negative ? -value : value, false)
        }
        guard integerDigits <= 12 else { throw .invalidDecimal }
        offset &+= 1
        let fractionStart = offset
        var fraction: Int64 = 0
        while offset < count {
            let digit = byte(bytes, offset) &- 0x30
            guard digit < 10 else { break }
            guard offset &- fractionStart < 3 else { throw .invalidDecimal }
            fraction = fraction &* 10 &+ Int64(digit)
            offset &+= 1
        }
        let thousandths: Int64
        switch offset &- fractionStart {
        case 1: thousandths = value &* 1000 &+ fraction &* 100
        case 2: thousandths = value &* 1000 &+ fraction &* 10
        case 3: thousandths = value &* 1000 &+ fraction
        default: throw .invalidDecimal
        }
        position = offset
        return (negative ? -thousandths : thousandths, true)
    }

    /// A String at `position` (its opening quote).
    @inlinable
    @_lifetime(copy bytes)
    static func string(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> HTTPStructuredString {
        let count = bytes.byteCount
        let start = position &+ 1
        var offset = start
        var isEscaped = false
        while true {
            guard offset < count, let found = bytes.extracting(droppingFirst: offset).firstByteOffset(where: stringStop) else {
                throw .invalidString
            }
            offset &+= found
            let stop = byte(bytes, offset)
            if stop == 0x22 {
                position = offset &+ 1
                return HTTPStructuredString(uncheckedBytes: bytes.extracting(start..<offset), isEscaped: isEscaped)
            }
            // A backslash, then `"` or `\`.
            guard stop == 0x5C, offset &+ 1 < count, case let escaped = byte(bytes, offset &+ 1), escaped == 0x22 || escaped == 0x5C else {
                throw .invalidString
            }
            isEscaped = true
            offset &+= 2
        }
    }

    /// The end of the Token at `position` (its first byte, a letter or `*`, is there).
    @inlinable
    static func tokenEnd(_ bytes: RawSpan, from position: Int) -> Int {
        let next = position &+ 1
        guard let found = bytes.extracting(droppingFirst: next).firstByteOffset(where: tokenStop) else { return bytes.byteCount }
        return next &+ found
    }

    /// A Byte Sequence at `position` (its opening colon).
    ///
    /// Lenient as RFC 9651 §4.2.7 asks: padding may be missing (or longer than needed, up to 2), and the last
    /// character's unused bits needn't be zero. A last group of one character, which no Base64 encoder writes, fails.
    @inlinable
    @_lifetime(copy bytes)
    static func byteSequence(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> HTTPStructuredByteSequence {
        let count = bytes.byteCount
        let start = position &+ 1
        let end = bytes.extracting(droppingFirst: start).firstByteOffset(where: base64Stop).map { start &+ $0 } ?? count
        var offset = end
        while offset < count, byte(bytes, offset) == 0x3D {
            offset &+= 1
        }
        guard offset < count, byte(bytes, offset) == 0x3A, offset &- end <= 2, (end &- start) & 3 != 1 else {
            throw .invalidByteSequence
        }
        position = offset &+ 1
        return HTTPStructuredByteSequence(uncheckedBase64: bytes.extracting(start..<end))
    }

    /// A Display String at `position` (its `%`), its escapes checked to be UTF-8.
    @inlinable
    @_lifetime(copy bytes)
    static func displayString(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> HTTPStructuredDisplayString {
        let count = bytes.byteCount
        guard position &+ 1 < count, byte(bytes, position &+ 1) == 0x22 else { throw .invalidDisplayString }
        let start = position &+ 2
        var offset = start
        var isPercentEncoded = false
        // UTF-8 validation of the decoded bytes: how many continuation bytes are still expected, and the range the
        // next must be in (narrower after E0, ED, F0, F4: no overlong forms, surrogates, or code points past U+10FFFF).
        var pending = 0
        var lower: UInt8 = 0x80, upper: UInt8 = 0xBF
        while true {
            guard offset < count, let found = bytes.extracting(droppingFirst: offset).firstByteOffset(where: displayStop) else {
                throw .invalidDisplayString
            }
            // Plain bytes are ASCII: none can continue a sequence.
            guard found == 0 || pending == 0 else { throw .invalidDisplayString }
            offset &+= found
            let stop = byte(bytes, offset)
            if stop == 0x22 {
                guard pending == 0 else { throw .invalidDisplayString }
                position = offset &+ 1
                return HTTPStructuredDisplayString(uncheckedBytes: bytes.extracting(start..<offset), isPercentEncoded: isPercentEncoded)
            }
            guard stop == 0x25, offset &+ 2 < count else { throw .invalidDisplayString }
            let high = hexValue(byte(bytes, offset &+ 1)), low = hexValue(byte(bytes, offset &+ 2))
            guard high | low < 16 else { throw .invalidDisplayString }
            let decoded = high &<< 4 | low
            if pending == 0 {
                switch decoded {
                case 0x00...0x7F: break
                case 0xC2...0xDF: pending = 1
                case 0xE0: pending = 2; lower = 0xA0
                case 0xE1...0xEC, 0xEE, 0xEF: pending = 2
                case 0xED: pending = 2; upper = 0x9F
                case 0xF0: pending = 3; lower = 0x90
                case 0xF1...0xF3: pending = 3
                case 0xF4: pending = 3; upper = 0x8F
                default: throw .invalidDisplayString
                }
            } else {
                guard decoded >= lower, decoded <= upper else { throw .invalidDisplayString }
                pending &-= 1
                lower = 0x80
                upper = 0xBF
            }
            isPercentEncoded = true
            offset &+= 3
        }
    }

    /// A bare item at `position`, by its first byte.
    @inlinable
    @_lifetime(copy bytes)
    static func bareItem(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> HTTPStructuredBareItem {
        guard position < bytes.byteCount else { throw .invalidBareItem }
        let first = byte(bytes, position)
        switch first {
        case 0x30...0x39, 0x2D:
            let number = try Self.number(bytes, &position)
            return number.isDecimal ? .decimal(HTTPStructuredDecimal(uncheckedThousandths: number.value)) : .integer(number.value)
        case 0x22:
            return try .string(string(bytes, &position))
        case 0x41...0x5A, 0x61...0x7A, 0x2A:
            let start = position
            position = tokenEnd(bytes, from: start)
            return .token(bytes.extracting(start..<position))
        case 0x3A:
            return try .byteSequence(byteSequence(bytes, &position))
        case 0x3F:
            guard position &+ 1 < bytes.byteCount, case let value = byte(bytes, position &+ 1), value | 1 == 0x31 else {
                throw .invalidBoolean
            }
            position &+= 2
            return .boolean(value == 0x31)
        case 0x40:
            position &+= 1
            guard position < bytes.byteCount, case let next = byte(bytes, position), next &- 0x30 < 10 || next == 0x2D else {
                throw .invalidInteger
            }
            let number = try Self.number(bytes, &position)
            guard !number.isDecimal else { throw .invalidDate }
            return .date(number.value)
        case 0x25:
            return try .displayString(displayString(bytes, &position))
        default:
            throw .invalidBareItem
        }
    }

    // MARK: Keys and parameters

    /// The end of the key at `start`.
    @inlinable @inline(__always)
    static func keyEnd(_ bytes: RawSpan, from start: Int) throws(HTTPStructuredFieldError) -> Int {
        let count = bytes.byteCount
        guard start < count, isKeyStart(byte(bytes, start)) else { throw .invalidKey }
        var offset = start &+ 1
        while offset < count, isKeyCharacter(byte(bytes, offset)) {
            offset &+= 1
        }
        return offset
    }

    /// The parameter whose `;` is at `position`.
    @inlinable
    @_lifetime(copy bytes)
    static func parameter(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> HTTPStructuredParameter {
        let keyStart = spacesEnd(bytes, from: position &+ 1)
        var offset = try keyEnd(bytes, from: keyStart)
        let key = bytes.extracting(keyStart..<offset)
        guard offset < bytes.byteCount, byte(bytes, offset) == 0x3D else {
            position = offset
            return HTTPStructuredParameter(key: key, value: .boolean(true))
        }
        offset &+= 1
        let value = try bareItem(bytes, &offset)
        position = offset
        return HTTPStructuredParameter(key: key, value: value)
    }

    /// The end of the parameters at `start` (none if no `;` is there), each validated.
    @inlinable
    static func parametersEnd(_ bytes: RawSpan, from start: Int) throws(HTTPStructuredFieldError) -> Int {
        var position = start
        while position < bytes.byteCount, byte(bytes, position) == 0x3B {
            _ = try parameter(bytes, &position)
        }
        return position
    }

    // MARK: Items, inner lists, members

    /// The item at `position`: a bare item and its parameters.
    @inlinable
    @_lifetime(copy bytes)
    static func item(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> HTTPStructuredItem {
        var offset = position
        let bareItem = try bareItem(bytes, &offset)
        let end = try parametersEnd(bytes, from: offset)
        let parameters = HTTPStructuredParameters(validated: bytes.extracting(offset..<end))
        position = end
        return HTTPStructuredItem(bareItem: bareItem, parameters: parameters)
    }

    /// The inner list whose `(` is at `position`, and its parameters.
    @inlinable
    @_lifetime(copy bytes)
    static func innerList(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> HTTPStructuredInnerList {
        let count = bytes.byteCount
        let start = position &+ 1
        var offset = start
        while true {
            offset = spacesEnd(bytes, from: offset)
            guard offset < count else { throw .invalidInnerList }
            if byte(bytes, offset) == 0x29 { break }
            _ = try item(bytes, &offset)
            guard offset < count, case let next = byte(bytes, offset), next == 0x20 || next == 0x29 else { throw .invalidInnerList }
        }
        let items = bytes.extracting(start..<offset)
        let parametersStart = offset &+ 1
        let end = try parametersEnd(bytes, from: parametersStart)
        position = end
        return HTTPStructuredInnerList(validated: items, parameters: HTTPStructuredParameters(validated: bytes.extracting(parametersStart..<end)))
    }

    /// The List member, or Dictionary value, at `position`: an inner list if it starts with `(`, otherwise an item.
    @inlinable
    @_lifetime(copy bytes)
    static func member(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> HTTPStructuredMember {
        if position < bytes.byteCount, byte(bytes, position) == 0x28 {
            return try .innerList(innerList(bytes, &position))
        }
        return try .item(item(bytes, &position))
    }

    /// The Dictionary member at `position`: a key, then `=` and a value, or parameters (the value is `true`).
    @inlinable
    @_lifetime(copy bytes)
    static func dictionaryMember(_ bytes: RawSpan, _ position: inout Int) throws(HTTPStructuredFieldError) -> HTTPStructuredDictionaryMember {
        let keyEnd = try keyEnd(bytes, from: position)
        let key = bytes.extracting(position..<keyEnd)
        var offset = keyEnd
        if offset < bytes.byteCount, byte(bytes, offset) == 0x3D {
            offset &+= 1
            let value = try member(bytes, &offset)
            position = offset
            return HTTPStructuredDictionaryMember(key: key, value: value)
        }
        let end = try parametersEnd(bytes, from: offset)
        let item = HTTPStructuredItem(bareItem: .boolean(true), parameters: HTTPStructuredParameters(validated: bytes.extracting(offset..<end)))
        position = end
        return HTTPStructuredDictionaryMember(key: key, value: .item(item))
    }

    // MARK: Lists and dictionaries

    /// Moves past what comes before the next List or Dictionary member (a comma and whitespace after a member), and
    /// returns whether one follows; `false` at the end of the field line.
    @inlinable @inline(__always)
    static func memberFollows(_ bytes: RawSpan, _ position: inout Int, _ state: inout StructuredFieldListState) throws(HTTPStructuredFieldError) -> Bool {
        let count = bytes.byteCount
        switch state {
        case .start:
            guard position < count else {
                state = .endEmpty
                return false
            }
        case .needsMember:
            guard position < count else { throw .missingMember }
        case .afterMember:
            var offset = whitespaceEnd(bytes, from: position)
            guard offset < count else {
                position = offset
                state = .endAfterMember
                return false
            }
            guard byte(bytes, offset) == 0x2C else { throw .missingSeparator }
            offset = whitespaceEnd(bytes, from: offset &+ 1)
            guard offset < count else { throw .missingMember }
            position = offset
        case .endEmpty, .endAfterMember:
            return false
        }
        return true
    }

    /// The state for the next field line of a List or Dictionary.
    @inlinable
    static func continueState(_ state: inout StructuredFieldListState) throws(HTTPStructuredFieldError) {
        switch state {
        case .endAfterMember: state = .needsMember
        case .endEmpty: throw .missingMember
        default: preconditionFailure("appending a field line before the one before it has ended")
        }
    }
}
