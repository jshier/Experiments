import Bytes
import HTTP2
import HTTPBytes

/// Bytes from hex digits, ignoring spaces and newlines.
func hexBytes(_ text: String) -> [UInt8] {
    let digits = Array(text.utf8.filter { $0 != 0x20 && $0 != 0x0A })
    precondition(digits.count % 2 == 0, "an odd number of hex digits")
    func value(_ digit: UInt8) -> UInt8 {
        switch digit {
        case 0x30...0x39: digit - 0x30
        case 0x61...0x66: digit - 0x61 + 10
        case 0x41...0x46: digit - 0x41 + 10
        default: preconditionFailure("not a hex digit")
        }
    }
    return stride(from: 0, to: digits.count, by: 2).map { value(digits[$0]) << 4 | value(digits[$0 + 1]) }
}

/// A span's bytes as a string (Latin-1, so any byte survives).
func text(_ bytes: RawSpan) -> String {
    String((0..<bytes.byteCount).map { Character(Unicode.Scalar(bytes.load(fromByteOffset: $0, as: UInt8.self))) })
}

/// A decoded field as plain values.
struct DecodedField: Equatable, CustomStringConvertible {
    var name: String
    var value: String
    var neverIndexed = false
    var known: HTTPFieldName?

    var description: String { "\(name): \(value)\(neverIndexed ? " (never indexed)" : "")" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value && lhs.neverIndexed == rhs.neverIndexed
    }
}

/// Every field of `block`.
func decodeAll(_ decoder: inout HPACKDecoder, _ block: [UInt8]) throws(HPACKError) -> [DecodedField] {
    var fields: [DecodedField] = []
    let span = block.span.bytes
    while let field = try decoder.next(in: span) {
        fields.append(DecodedField(name: text(field.name), value: text(field.value), neverIndexed: field.isNeverIndexed, known: field.knownName))
    }
    return fields
}

/// The decoder's dynamic table, newest first.
func tableEntries(_ decoder: borrowing HPACKDecoder) -> [DecodedField] {
    (0..<decoder.tableCount).map { index in
        let entry = decoder.tableEntry(at: index + 1)
        return DecodedField(name: text(entry.name), value: text(entry.value))
    }
}

/// Fields from (name, value) pairs.
func fields(_ pairs: [(String, String)]) -> [DecodedField] {
    pairs.map { DecodedField(name: $0.0, value: $0.1) }
}

/// Latin-1 bytes of a string's characters (test data is ASCII).
func latin1(_ string: String) -> [UInt8] {
    string.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
}
