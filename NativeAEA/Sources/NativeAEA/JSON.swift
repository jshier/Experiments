import Bytes

/// A strict reader for the one JSON shape NativeAEA meets: an object whose values are all strings (WKMS's
/// `com.apple.wkms.fcs-response`, `{"enc-request": "…", "wrapped-key": "…"}`).
///
/// RFC 8259's grammar for that subset: whitespace (space, tab, line feed, carriage return) around the tokens; strings
/// of UTF-8 with no control characters, and every escape (`\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, and
/// `\uXXXX`, surrogates only in pairs). Anything else is rejected: values of other types, repeated names, a trailing
/// comma, bytes after the object.
public enum JSON {
    /// The members of the object `bytes` holds, by name.
    ///
    /// - Parameter bytes: The JSON text: one object, and nothing after it but whitespace.
    /// - Returns: Each member's value by its name.
    /// - Throws: ``BytesError/invalidValue`` for anything but an object of string members (another token, a
    ///   malformed escape, a lone surrogate, a control character or invalid UTF-8 in a string, a repeated name, bytes
    ///   after the object); ``BytesError/insufficientData`` if the text ends early.
    public static func stringMembers(_ bytes: RawSpan) throws(BytesError) -> [String: String] {
        var reader = AlignedBytesReader(bytes)
        var members: [String: String] = [:]
        try skipWhitespace(&reader)
        try expect(0x7B, &reader) // {
        try skipWhitespace(&reader)
        if try reader.peek(UInt8.self) == 0x7D { // }: an empty object
            _ = try reader.read(UInt8.self)
        } else {
            while true {
                let name = try string(&reader)
                try skipWhitespace(&reader)
                try expect(0x3A, &reader) // :
                try skipWhitespace(&reader)
                let value = try string(&reader)
                guard members.updateValue(value, forKey: name) == nil else { throw .invalidValue }
                try skipWhitespace(&reader)
                let next = try reader.read(UInt8.self)
                if next == 0x7D { break } // }
                guard next == 0x2C else { throw .invalidValue } // ,
                try skipWhitespace(&reader)
            }
        }
        try skipWhitespace(&reader)
        guard reader.isAtEnd else { throw .invalidValue }
        return members
    }

    /// Skips JSON's four whitespace bytes.
    private static func skipWhitespace(_ reader: inout AlignedBytesReader) throws(BytesError) {
        while !reader.isAtEnd {
            switch try reader.peek(UInt8.self) {
            case 0x20, 0x09, 0x0A, 0x0D: _ = try reader.read(UInt8.self)
            default: return
            }
        }
    }

    private static func expect(_ byte: UInt8, _ reader: inout AlignedBytesReader) throws(BytesError) {
        guard try reader.read(UInt8.self) == byte else { throw .invalidValue }
    }

    /// A string token, from its opening quote to its closing one, unescaped.
    private static func string(_ reader: inout AlignedBytesReader) throws(BytesError) -> String {
        try expect(0x22, &reader) // "
        var text: [UInt8] = []
        // Each run ends at the next quote, which closes the string unless the run ends in an escape (`\"`).
        while true {
            let run = try reader.read(bytesTerminatedBy: 0x22)
            text.reserveCapacity(text.count + run.byteCount)
            var bytes = AlignedBytesReader(run)
            var quoteEscaped = false
            while !bytes.isAtEnd {
                let byte = try bytes.read(UInt8.self)
                guard byte >= 0x20 else { throw .invalidValue } // Control characters must be escaped.
                guard byte == 0x5C else { // Not `\`.
                    text.append(byte)
                    continue
                }
                guard !bytes.isAtEnd else {
                    // `\"`: the quote that ended the run is the string's.
                    text.append(0x22)
                    quoteEscaped = true
                    break
                }
                switch try bytes.read(UInt8.self) {
                case 0x5C: text.append(0x5C) // \\
                case 0x2F: text.append(0x2F) // \/
                case 0x62: text.append(0x08) // \b
                case 0x66: text.append(0x0C) // \f
                case 0x6E: text.append(0x0A) // \n
                case 0x72: text.append(0x0D) // \r
                case 0x74: text.append(0x09) // \t
                case 0x75: try appendUTF8(scalar(&bytes), to: &text) // \uXXXX
                default: throw .invalidValue
                }
            }
            guard quoteEscaped else { break }
        }
        guard let string = String(validating: text, as: UTF8.self) else { throw .invalidValue }
        return string
    }

    /// The scalar a `\u` escape names (its `\u` read), with a high surrogate's low half from the `\uXXXX` after it.
    private static func scalar(_ reader: inout AlignedBytesReader) throws(BytesError) -> Unicode.Scalar {
        let unit = try hexUnit(&reader)
        switch unit {
        case 0xD800..<0xDC00:
            // A high surrogate: a low one must follow, as its own escape.
            guard try reader.read(UInt8.self) == 0x5C, try reader.read(UInt8.self) == 0x75 else { throw .invalidValue }
            let low = try hexUnit(&reader)
            guard (0xDC00..<0xE000).contains(low) else { throw .invalidValue }
            let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { throw .invalidValue }
            return scalar
        case 0xDC00..<0xE000:
            throw .invalidValue // A low surrogate on its own.
        default:
            guard let scalar = Unicode.Scalar(unit) else { throw .invalidValue }
            return scalar
        }
    }

    /// Four hexadecimal digits, either case.
    private static func hexUnit(_ reader: inout AlignedBytesReader) throws(BytesError) -> UInt16 {
        var unit: UInt16 = 0
        for _ in 0..<4 {
            guard let digit = try reader.read(UInt8.self).asciiHexDigitValue else { throw .invalidValue }
            unit = unit << 4 | UInt16(digit)
        }
        return unit
    }

    private static func appendUTF8(_ scalar: Unicode.Scalar, to text: inout [UInt8]) {
        UTF8.encode(scalar) { text.append($0) }
    }
}
