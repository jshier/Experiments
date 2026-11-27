public import Bytes
public import HTTPBytes

/// HTTP/1.1 heads to bytes: start lines, fields, and the empty line that ends a head, written with Bytes' aligned
/// writer (into an array, a buffer, or a socket's send buffer). Values are written as given: they come from an
/// ``HTTPFieldStore`` (validated when appended) or from code that has checked them; targets and reason phrases are
/// checked here, since they're often built from user input.
public enum HTTP1HeadWriter {
    /// Writes `METHOD SP target SP HTTP/1.x CRLF`.
    ///
    /// - Throws: ``HTTP1Error/invalidTarget`` for an empty target or one with a control, space, DEL, or non-ASCII byte;
    ///   `BytesError` if the writer runs out of room (as an ``HTTP1HeadWriterError``).
    @inlinable
    public static func writeRequestLine(_ method: HTTPMethod, target: RawSpan, version: HTTPVersion = .http1_1,
                                        to writer: inout AlignedBytesWriter) throws(HTTP1HeadWriterError) {
        guard target.byteCount > 0, !target.containsByte(where: HTTPCharacters.targetStop) else { throw .invalidTarget }
        do {
            try method.withBytes { bytes throws(BytesError) in try writer.write(bytes) }
            try writer.write(0x20 as UInt8)
            try writer.write(target)
            try writer.write(0x20 as UInt8)
            try writeVersion(version, to: &writer)
            try writer.write(0x0A0D as UInt16, as: Byte2.self, .littleEndian)
        } catch { throw .outOfRoom }
    }

    /// Writes `HTTP/1.x SP code SP reason CRLF`, the reason being RFC 9110's for the code unless given.
    @inlinable
    public static func writeStatusLine(_ status: HTTPStatus, reasonPhrase: RawSpan? = nil, version: HTTPVersion = .http1_1,
                                       to writer: inout AlignedBytesWriter) throws(HTTP1HeadWriterError) {
        if let reasonPhrase, reasonPhrase.containsByte(where: HTTPCharacters.fieldValueStop) { throw .invalidReasonPhrase }
        do {
            try writeVersion(version, to: &writer)
            let code = status.code
            // Space and three digits: one 32-bit word.
            let digits = UInt32(0x20) | UInt32(0x30 &+ code / 100) &<< 8 | UInt32(0x30 &+ code / 10 % 10) &<< 16
                | UInt32(0x30 &+ code % 10) &<< 24
            try writer.write(digits, as: Byte4.self, .littleEndian)
            try writer.write(0x20 as UInt8)
            if let reasonPhrase {
                try writer.write(reasonPhrase)
            } else {
                let phrase = status.reasonPhrase
                try writer.write(phrase.bytes)
            }
            try writer.write(0x0A0D as UInt16, as: Byte2.self, .littleEndian)
        } catch { throw .outOfRoom }
    }

    /// Writes `name: value CRLF`.
    @inlinable
    public static func writeField(name: RawSpan, value: RawSpan, to writer: inout AlignedBytesWriter) throws(HTTP1HeadWriterError) {
        // Checked here whatever the fields came from (a store filled from HTTP/2 or HTTP/3, or code building fields):
        // a name with a non-token byte or a value with CR or LF would write fields of its own into the head.
        guard name.byteCount > 0, !name.containsByte(where: HTTPCharacters.nonToken) else { throw .invalidFieldName }
        guard !value.containsByte(where: HTTPCharacters.fieldValueStop) else { throw .invalidFieldValue }
        do {
            try writer.write(name)
            try writer.write(0x203A as UInt16, as: Byte2.self, .littleEndian)
            try writer.write(value)
            try writer.write(0x0A0D as UInt16, as: Byte2.self, .littleEndian)
        } catch { throw .outOfRoom }
    }

    /// Writes every field of `fields`: known names in their canonical spelling (`Content-Type`), others as stored.
    /// Pseudo-header fields (`:method`, `:path`, … from HTTP/2 or HTTP/3) aren't fields in HTTP/1 (their meaning goes in
    /// the start line) and are left out.
    @inlinable
    public static func writeFields(_ fields: borrowing HTTPFieldStore, to writer: inout AlignedBytesWriter) throws(HTTP1HeadWriterError) {
        for index in 0..<fields.count {
            let field = fields.field(at: index)
            if field.name.byteCount > 0, field.name.load(fromByteOffset: 0, as: UInt8.self) == 0x3A { continue }
            if let known = field.knownName {
                try writeField(name: known.canonicalBytes, value: field.value, to: &writer)
            } else {
                try writeField(name: field.name, value: field.value, to: &writer)
            }
        }
    }

    /// Writes the empty line that ends a head.
    @inlinable
    public static func writeEnd(to writer: inout AlignedBytesWriter) throws(HTTP1HeadWriterError) {
        do { try writer.write(0x0A0D as UInt16, as: Byte2.self, .littleEndian) } catch { throw .outOfRoom }
    }

    @inlinable
    static func writeVersion(_ version: HTTPVersion, to writer: inout AlignedBytesWriter) throws(BytesError) {
        // `HTTP/1.1` or `HTTP/1.0` as one little-endian word.
        try writer.write(version == .http1_0 ? 0x302E_312F_5054_5448 as UInt64 : 0x312E_312F_5054_5448, as: Byte8.self, .littleEndian)
    }
}

/// Why a head couldn't be written.
@frozen
public enum HTTP1HeadWriterError: Error, Sendable, Hashable {
    /// The target is empty or has a control character, space, DEL, or a byte above 0x7F.
    case invalidTarget
    /// The reason phrase has a control character other than tab, or DEL.
    case invalidReasonPhrase
    /// A field name is empty or has a byte that isn't a token character.
    case invalidFieldName
    /// A field value has a control character other than tab (CR or LF among them), or DEL.
    case invalidFieldValue
    /// The writer's buffer is full.
    case outOfRoom
}
