public import Bytes
internal import BytesBase64

// DER for keys and signatures, on the aligned reader with X.509's header parser, tags, and integer and bit-string
// checks (`ASN1DER.swift`, `X509Layout`): one strict reading of DER for everything. And PEM (RFC 7468), the Base64
// text around DER, for keys and certificates alike.

public extension GenericBytesReader where Mode == ByteAligned {
    /// Reads one DER element, which must have tag `tag`, and returns its contents.
    ///
    /// ```swift
    /// var signature = AlignedBytesReader(der)
    /// var values = AlignedBytesReader(try signature.readASN1Contents(.sequence))
    /// ```
    ///
    /// A reader over the contents reads the element's children, at offsets from the contents' start.
    ///
    /// - Parameter tag: The expected tag.
    /// - Returns: The element's contents, borrowing the reader's memory.
    /// - Throws: What ``readASN1Element(_:)`` throws.
    @inlinable
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readASN1Contents(_ tag: ASN1Tag) throws(BytesError) -> RawSpan {
        let element = try readASN1Element(tag)
        return span.extracting(element.contents)
    }
}

extension GenericBytesReader where Mode == ByteAligned {
    /// Reads an `INTEGER` that must be non-negative and returns its magnitude: its bytes without the leading zero DER
    /// puts before a high bit (empty for zero).
    ///
    /// - Throws: ``BytesError/invalidValue`` for a negative, empty, or non-minimal encoding, and what
    ///   ``readASN1Element(_:)`` throws.
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readASN1UnsignedInteger() throws(BytesError) -> RawSpan {
        let element = try readASN1Element(.integer)
        try X509Layout.checkInteger(span, element)
        let contents = span.extracting(element.contents)
        let first = contents.byteOffsetLoad(0) // `checkInteger` requires a byte.
        guard first & 0x80 == 0 else { throw .invalidValue }
        return first == 0 ? contents.extracting(droppingFirst: 1) : contents
    }

    /// Reads a non-negative `INTEGER` that fits in 62 bits: a version number.
    ///
    /// - Throws: ``BytesError/invalidValue`` for a negative, non-minimal, or larger value, and what
    ///   ``readASN1Element(_:)`` throws.
    mutating func readASN1SmallInteger() throws(BytesError) -> Int {
        let value = try X509Layout.smallInteger(span, try readASN1Element(.integer))
        guard value >= 0 else { throw .invalidValue }
        return value
    }

    /// Reads a `BIT STRING` of whole bytes (no unused bits) and returns them.
    ///
    /// - Parameter tag: ``ASN1Tag/bitString``, or an implicit context-specific tag.
    /// - Throws: ``BytesError/invalidValue`` for unused bits, and what ``readASN1Element(_:)`` throws.
    @_lifetime(copy self)
    @_lifetime(self: copy self)
    mutating func readASN1BitString(_ tag: ASN1Tag = .bitString) throws(BytesError) -> RawSpan {
        let element = try readASN1Element(tag)
        return span.extracting(try X509Layout.bitString(span, element, allowingUnusedBits: false))
    }

    /// Throws unless every element has been read.
    ///
    /// - Throws: ``BytesError/trailingData`` if bytes remain.
    func expectASN1End() throws(BytesError) {
        guard isAtEnd else { throw .trailingData }
    }
}

/// Writes DER: what keys and signatures encode (a hundred bytes or so, so into an array).
struct DERWriter {
    var bytes: [UInt8] = []

    /// Appends an element with `contents`.
    mutating func append(_ tag: ASN1Tag, contents: RawSpan) {
        appendHeader(tag, length: contents.byteCount)
        for index in 0..<contents.byteCount { bytes.append(contents.byteOffsetLoad(index)) }
    }

    /// Appends a constructed element whose children `body` writes.
    mutating func append(_ tag: ASN1Tag, _ body: (inout DERWriter) -> Void) {
        var children = DERWriter()
        body(&children)
        let contents = children.bytes
        append(tag, contents: contents.span.bytes)
    }

    /// Appends an object identifier.
    mutating func append(_ identifier: ASN1ObjectIdentifier) {
        append(.objectIdentifier, contents: identifier.contents)
    }

    /// Appends a non-negative `INTEGER` from its big-endian magnitude (leading zeros dropped, one added before a high
    /// bit, as DER's shortest form requires).
    mutating func appendUnsignedInteger(_ magnitude: RawSpan) {
        var start = 0
        while start < magnitude.byteCount, magnitude.byteOffsetLoad(start) == 0 { start &+= 1 }
        let significant = magnitude.extracting(droppingFirst: start)
        let pad = significant.byteCount == 0 || significant.byteOffsetLoad(0) & 0x80 != 0
        appendHeader(.integer, length: significant.byteCount &+ (pad ? 1 : 0))
        if pad { bytes.append(0) }
        for index in 0..<significant.byteCount { bytes.append(significant.byteOffsetLoad(index)) }
    }

    /// Appends a `BIT STRING` of whole bytes.
    mutating func appendBitString(_ contents: RawSpan, tag: ASN1Tag = .bitString) {
        appendHeader(tag, length: contents.byteCount &+ 1)
        bytes.append(0) // No unused bits.
        for index in 0..<contents.byteCount { bytes.append(contents.byteOffsetLoad(index)) }
    }

    /// The identifier and the length in its shortest form.
    mutating func appendHeader(_ tag: ASN1Tag, length: Int) {
        bytes.append(tag.rawValue)
        guard length >= 0x80 else {
            bytes.append(UInt8(length))
            return
        }
        var lengthByteCount = 1
        while length >> (8 &* lengthByteCount) != 0 { lengthByteCount &+= 1 }
        bytes.append(0x80 | UInt8(lengthByteCount))
        for index in (0..<lengthByteCount).reversed() { bytes.append(UInt8(truncatingIfNeeded: length >> (8 &* index))) }
    }
}

/// PEM (RFC 7468): DER as Base64 between `-----BEGIN label-----` and `-----END label-----` lines.
///
/// ```swift
/// let certificates = try PEM.decodeAll(text, label: "CERTIFICATE")
/// let key = try PEM.decode(text, label: "PUBLIC KEY")
/// ```
///
/// Strict: every block, whatever its label, needs an end line with the same label, and its Base64 may hold only the
/// alphabet and whitespace, with the padding RFC 4648 requires and zero padding bits. Text between blocks is ignored.
public enum PEM {
    /// Each block labeled `label` in `text`, decoded, in order. Blocks with other labels are skipped (`openssl ecparam
    /// -genkey` writes an "EC PARAMETERS" block before the key).
    ///
    /// - Parameters:
    ///   - text: PEM text's bytes (ASCII).
    ///   - label: The blocks' label: "CERTIFICATE", "PUBLIC KEY", "EC PRIVATE KEY", "PRIVATE KEY".
    /// - Returns: Each block's bytes (its DER), in order; empty if there are none.
    /// - Throws: ``BytesError/invalidValue`` for a block (of any label) whose end line is missing or mislabeled, or
    ///   whose Base64 is malformed.
    public static func decodeAll(_ text: RawSpan, label: String) throws(BytesError) -> [[UInt8]] {
        let wanted = Array(label.utf8)
        var documents: [[UInt8]] = []
        var offset = 0
        while let begin = text.firstByteOffset(of: beginPrefix, from: offset) {
            // The label runs to the next "-----".
            let labelStart = begin &+ Byte11.byteCount
            guard let labelEnd = text.firstByteOffset(of: dashes, from: labelStart) else { throw .invalidValue }
            let bodyStart = labelEnd &+ Byte5.byteCount
            guard let end = text.firstByteOffset(of: endPrefix, from: bodyStart) else { throw .invalidValue }
            let endLabelStart = end &+ Byte9.byteCount
            let blockLabel = text.extracting(labelStart..<labelEnd)
            guard let endLabelEnd = text.firstByteOffset(of: dashes, from: endLabelStart),
                  blockLabel.equals(text.extracting(endLabelStart..<endLabelEnd)) else { throw .invalidValue }
            if blockLabel.equals(wanted.span.bytes) {
                documents.append(try decodeBase64(text.extracting(bodyStart..<end)))
            }
            offset = endLabelEnd &+ Byte5.byteCount
        }
        return documents
    }

    /// Each block labeled `label` in `text`, decoded, as ``decodeAll(_:label:)-(RawSpan,_)``.
    ///
    /// - Parameters:
    ///   - text: PEM text.
    ///   - label: The blocks' label.
    /// - Returns: Each block's bytes, in order.
    /// - Throws: As ``decodeAll(_:label:)-(RawSpan,_)``.
    public static func decodeAll(_ text: String, label: String) throws(BytesError) -> [[UInt8]] {
        var contiguous = text
        contiguous.makeContiguousUTF8()
        let utf8 = contiguous.utf8
        return try decodeAll(utf8.span.bytes, label: label)
    }

    /// The first block labeled `label` in `text`, decoded.
    ///
    /// - Parameters:
    ///   - text: PEM text.
    ///   - label: The block's label.
    /// - Returns: The block's bytes (its DER).
    /// - Throws: ``BytesError/insufficientData`` if there's no block with that label, and what
    ///   ``decodeAll(_:label:)-(RawSpan,_)`` throws.
    public static func decode(_ text: String, label: String) throws(BytesError) -> [UInt8] {
        guard let first = try decodeAll(text, label: label).first else { throw .insufficientData }
        return first
    }

    /// `der` as a PEM block: Base64 in lines of 64 characters between the boundary lines, each line ending in a
    /// newline (RFC 7468's strict form, as OpenSSL writes it).
    ///
    /// - Parameters:
    ///   - der: The bytes.
    ///   - label: The block's label, such as "PUBLIC KEY".
    /// - Returns: The PEM text.
    public static func encode(_ der: RawSpan, label: String) -> String {
        // Interpolated, so native and contiguous: `utf8Span` needs that.
        let begin = "-----BEGIN \(label)-----\n", end = "-----END \(label)-----\n"
        // 48 bytes are a line's 64 characters.
        let lineCount = (der.byteCount &+ 47) / 48
        let capacity = begin.utf8.count &+ Base64.encodedByteCount(of: der.byteCount) &+ lineCount &+ end.utf8.count
        return String(utf8Capacity: capacity) { writer in
            // Can't throw: the capacity is the text's exact length.
            try! writer.write(begin.utf8Span.span.bytes)
            var start = 0
            while start < der.byteCount {
                let lineEnd = min(der.byteCount, start &+ 48)
                try! Base64.encode(der.extracting(start..<lineEnd), into: &writer)
                try! writer.write(0x0A as Byte) // "\n"
                start = lineEnd
            }
            try! writer.write(end.utf8Span.span.bytes)
        }
    }

    // The boundary lines' fixed parts, as byte groups (constants once inlined), found with Bytes' SIMD search.
    static var beginPrefix: Byte11 { Byte11(ascii: "-----BEGIN ") }
    static var endPrefix: Byte9 { Byte9(ascii: "-----END ") }
    static var dashes: Byte5 { Byte5(ascii: "-----") }

    /// Strict Base64 (RFC 4648, 4, the standard alphabet) with whitespace ignored: padding only at the end and only
    /// as much as the last group needs, and the padding bits zero. BytesBase64's decoder; every way the text can be
    /// wrong is ``BytesError/invalidValue`` here, as PEM's errors say.
    static func decodeBase64(_ text: RawSpan) throws(BytesError) -> [UInt8] {
        do throws(LocatedBytesError) {
            return try Base64.decodedBytes(ignoringWhitespaceIn: text)
        } catch {
            throw .invalidValue
        }
    }
}
