import Bytes
import BytesBase64
import BytesCompression
import BytesMacros

// XAR (the eXtensible ARchiver format), what `.xip` and `.pkg` files are: a big-endian header, a table of contents
// (XML, zlib-compressed), then the heap, which holds the TOC's checksum, its signature, and each member file's data.
//
//     "xar!" | header size u16 | version u16 (1) | TOC compressed size u64 | TOC size u64 | checksum algorithm u32
//     [header padding] | TOC (zlib) | heap
//
// Heap offsets in the TOC are from the heap's start: the header's size plus the compressed TOC's.

/// A XAR header's fixed fields (28 bytes; a header may be longer, holding a checksum algorithm's name).
@BinaryRecord(.bigEndian)
struct XARHeaderRecord {
    @Field(Byte4.self, expecting: 0x7861_7221) var magic: UInt32 // "xar!"
    @Field(Byte2.self) var headerSize: Int
    @Field(Byte2.self) var version: Int
    @Field(Byte8.self) var tocCompressedSize: Int
    @Field(Byte8.self) var tocSize: Int
    @Field(Byte4.self) var checksumAlgorithm: UInt32
}

/// A XAR archive's table of contents: what the readers here need of it.
public struct XARTableOfContents: Sendable {
    /// The TOC checksum's place in the heap and algorithm (`sha1`, `sha256`, …).
    public var checksum: (offset: Int, size: Int, style: String)?
    /// The signature's place in the heap, its style (`RSA`), and its certificate chain (DER, leaf first).
    public var signature: (offset: Int, size: Int, style: String, certificates: [[UInt8]])?
    /// The member files (at the TOC's top level).
    public var files: [XARFile] = []
    /// When the archive was made (`creation-time`, UTC), in seconds since 1970: the time its certificates must be valid at.
    public var creationTime: Int64?
}

/// A member file of a XAR archive.
public struct XARFile: Sendable {
    public var name = ""
    public var type = ""
    /// Its data in the heap: offset and stored length, its size once decoded, and how it's encoded
    /// (`application/octet-stream`, `application/x-gzip` for zlib, `application/x-bzip2`).
    public var offset = 0
    public var length = 0
    public var size = 0
    public var encoding = ""
    /// Hex digests of the stored and decoded data, with their algorithms.
    public var archivedChecksum: (style: String, hex: String)?
    public var extractedChecksum: (style: String, hex: String)?
}

public enum XAR {
    static let fixedHeaderSize = 28

    /// The TOC from its XML: the elements this reader uses, by their paths. Strict about the XML it reads (balanced
    /// tags, known entities) and silent about elements it doesn't use.
    public static func parseTableOfContents(_ xml: [UInt8]) throws(AEAError) -> XARTableOfContents {
        var toc = XARTableOfContents()
        var file: XARFile?
        var checksum: (offset: Int, size: Int, style: String) = (0, 0, "")
        var signature: (offset: Int, size: Int, style: String, certificates: [[UInt8]]) = (0, 0, "", [])
        var inChecksum = false, inSignature = false
        var scanner = XMLScanner(xml)
        while let event = try scanner.next() {
            switch event {
            case let .start(path, style):
                switch path {
                case "xar/toc/checksum":
                    inChecksum = true
                    checksum = (0, 0, style ?? "")
                case "xar/toc/signature":
                    inSignature = true
                    signature = (0, 0, style ?? "", [])
                case "xar/toc/file": file = XARFile()
                case "xar/toc/file/data/encoding": file?.encoding = style ?? ""
                default: break
                }
            case let .text(path, text, style):
                switch path {
                case "xar/toc/checksum/offset": checksum.offset = try integer(text)
                case "xar/toc/checksum/size": checksum.size = try integer(text)
                case "xar/toc/signature/offset": signature.offset = try integer(text)
                case "xar/toc/signature/size": signature.size = try integer(text)
                case "xar/toc/signature/KeyInfo/X509Data/X509Certificate":
                    // In 64-character lines; strict otherwise (BytesBase64's decoder).
                    guard let der = try? Base64.decodedBytes(ignoringWhitespaceIn: text) else { throw .invalidArchive("a XAR certificate's Base64") }
                    signature.certificates.append(der)
                case "xar/toc/creation-time": toc.creationTime = time(text)
                case "xar/toc/file/name": file?.name = text
                case "xar/toc/file/type": file?.type = text
                case "xar/toc/file/data/offset": file?.offset = try integer(text)
                case "xar/toc/file/data/length": file?.length = try integer(text)
                case "xar/toc/file/data/size": file?.size = try integer(text)
                case "xar/toc/file/data/archived-checksum": file?.archivedChecksum = (style ?? "", text)
                case "xar/toc/file/data/extracted-checksum": file?.extractedChecksum = (style ?? "", text)
                default: break
                }
            case let .end(path):
                switch path {
                case "xar/toc/checksum":
                    inChecksum = false
                    toc.checksum = checksum
                case "xar/toc/signature":
                    inSignature = false
                    toc.signature = signature
                case "xar/toc/file":
                    if let file { toc.files.append(file) }
                    file = nil
                default: break
                }
            }
        }
        guard !inChecksum, !inSignature, file == nil else { throw .invalidArchive("the XAR TOC ends inside an element") }
        return toc
    }

    /// A non-negative decimal integer.
    static func integer(_ text: String) throws(AEAError) -> Int {
        let trimmed = text.utf8.drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        guard !trimmed.isEmpty, trimmed.count <= 18, trimmed.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            throw .invalidArchive("a XAR number: \(text)")
        }
        return trimmed.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }

    /// Seconds since 1970 of a `creation-time` (`2026-10-16T17:24:05`, UTC), or `nil` for another form or a date
    /// that doesn't exist (February 31st). A leap second (`:60`) is accepted, as XAR's writer may produce one.
    public static func time(_ text: String) -> Int64? {
        var string = text
        string.makeContiguousUTF8() // `utf8Span` needs native, contiguous UTF-8.
        var reader = AlignedBytesReader(string.utf8Span.span.bytes)
        do throws(BytesError) {
            let year = try reader.read(Int.self, asciiDigits: 4)
            try reader.expect(Byte(ascii: "-"))
            let month = try reader.read(Int.self, asciiDigits: 2)
            try reader.expect(Byte(ascii: "-"))
            let day = try reader.read(Int.self, asciiDigits: 2)
            try reader.expect(Byte(ascii: "T"))
            let hour = try reader.read(Int.self, asciiDigits: 2)
            try reader.expect(Byte(ascii: ":"))
            let minute = try reader.read(Int.self, asciiDigits: 2)
            try reader.expect(Byte(ascii: ":"))
            let second = try reader.read(Int.self, asciiDigits: 2)
            try reader.expectEnd()
            return try UTCDateTime(
                year: year, month: month, day: day, hour: hour, minute: minute, second: second, allowingLeapSecond: true
            ).secondsSince1970
        } catch {
            return nil
        }
    }
}

/// A minimal XML reader for XAR TOCs: elements (with their path from the root, slash-separated, and a `style`
/// attribute, the only one XAR's readers need), text, and the five predefined entities and character references.
/// Skips the declaration, comments, processing instructions, and DOCTYPE. Not a general XML parser: no namespaces
/// (a prefix stays in the name), CDATA is rejected.
///
/// The path is kept as bytes, a name appended when its element opens and cut back to its parent's length when it
/// closes, and made into a `String` only while it's at most ``maximumPathByteCount`` bytes (longer ones are reported as
/// `""`, which no reader matches): each event costs its own bytes and at most that much more. Built from the stack on
/// every event, a 511-byte TOC 40,000 elements deep took 42.8 s (review 2026-11-23 §1.8).
public struct XMLScanner {
    public enum Event {
        /// An element opened: its path, and its `style` attribute.
        case start(String, style: String?)
        /// An element's text (whitespace-only text between elements isn't reported), with its element's `style`.
        case text(String, String, style: String?)
        case end(String)
    }

    /// The longest path reported: the readers' deepest is 51 bytes (`xar/toc/signature/KeyInfo/X509Data/X509Certificate`).
    static var maximumPathByteCount: Int { 128 }

    private let bytes: [UInt8]
    private var offset = 0
    /// The open elements' path, slash-separated.
    private var pathBytes: [UInt8] = []
    /// Per open element: where its name starts in ``pathBytes`` (its parent's path ends before it, and a slash), and its
    /// `style`.
    private var stack: [(nameStart: Int, style: String?)] = []
    private var pendingEnd = false

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The current path, or `""` past ``maximumPathByteCount``.
    private var path: String {
        pathBytes.count <= Self.maximumPathByteCount ? String(decoding: pathBytes, as: UTF8.self) : ""
    }

    private func byte(_ index: Int) -> UInt8 { bytes[index] }

    /// Closes the innermost element: its path, then the path cut back to its parent's.
    private mutating func close() -> Event {
        let ended = path
        let top = stack.removeLast()
        pathBytes.removeSubrange(max(0, top.nameStart - 1)...)
        return .end(ended)
    }

    public mutating func next() throws(AEAError) -> Event? {
        if pendingEnd {
            pendingEnd = false
            return close()
        }
        while offset < bytes.count {
            if byte(offset) != 0x3C { // Text up to the next tag.
                let start = offset
                while offset < bytes.count, byte(offset) != 0x3C {
                    offset += 1
                }
                let raw = bytes[start..<offset]
                guard raw.contains(where: { !Self.isSpace($0) }) else { continue }
                guard let top = stack.last else { throw .invalidArchive("XML text outside the root") }
                return try .text(path, Self.unescape(raw), style: top.style)
            }
            // A tag.
            guard offset + 1 < bytes.count else { throw .invalidArchive("XML ends inside a tag") }
            let kind = byte(offset + 1)
            if kind == 0x3F { // <?…?>
                try skip(past: [0x3F, 0x3E])
                continue
            }
            if kind == 0x21 { // <!-- … -->, <!DOCTYPE …>, <![CDATA[ (rejected)
                if offset + 3 < bytes.count, byte(offset + 2) == 0x2D, byte(offset + 3) == 0x2D {
                    try skip(past: [0x2D, 0x2D, 0x3E])
                } else if offset + 2 < bytes.count, byte(offset + 2) == 0x5B {
                    throw .invalidArchive("XML CDATA")
                } else {
                    try skip(past: [0x3E])
                }
                continue
            }
            let start = offset
            try skip(past: [0x3E])
            let tag = Array(bytes[(start + 1)..<(offset - 1)]) // Without < and >.
            return try element(tag)
        }
        guard stack.isEmpty else { throw .invalidArchive("XML ends inside an element") }
        return nil
    }

    private mutating func element(_ tag: [UInt8]) throws(AEAError) -> Event {
        var bytes = tag
        if bytes.first == 0x2F { // </name>
            let name = bytes.dropFirst().prefix { !Self.isSpace($0) }
            guard let top = stack.last, pathBytes[top.nameStart...].elementsEqual(name) else {
                // A name too long to be one the readers know is cut short in the message.
                throw .invalidArchive("XML end tag \(String(decoding: name.prefix(Self.maximumPathByteCount), as: UTF8.self)) doesn't match")
            }
            return close()
        }
        let selfClosing = bytes.last == 0x2F
        if selfClosing { bytes.removeLast() }
        let nameEnd = bytes.firstIndex(where: Self.isSpace) ?? bytes.count
        guard nameEnd > 0 else { throw .invalidArchive("an XML element without a name") }
        let style = try Self.attribute("style", in: bytes[nameEnd...])
        if !stack.isEmpty { pathBytes.append(0x2F) }
        stack.append((pathBytes.count, style))
        pathBytes.append(contentsOf: bytes[..<nameEnd])
        pendingEnd = selfClosing
        return .start(path, style: style)
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }

    /// The value of attribute `name`, unescaped, if the tag has it.
    private static func attribute(_ name: String, in bytes: ArraySlice<UInt8>) throws(AEAError) -> String? {
        var index = bytes.startIndex
        let wanted = Array(name.utf8)
        while index < bytes.endIndex {
            while index < bytes.endIndex, isSpace(bytes[index]) {
                index += 1
            }
            let nameStart = index
            while index < bytes.endIndex, bytes[index] != 0x3D, !isSpace(bytes[index]) {
                index += 1
            }
            let attributeName = bytes[nameStart..<index]
            while index < bytes.endIndex, isSpace(bytes[index]) || bytes[index] == 0x3D {
                index += 1
            }
            guard index < bytes.endIndex else { break }
            let quote = bytes[index]
            guard quote == 0x22 || quote == 0x27 else { throw .invalidArchive("an XML attribute without quotes") }
            index += 1
            let valueStart = index
            while index < bytes.endIndex, bytes[index] != quote {
                index += 1
            }
            guard index < bytes.endIndex else { throw .invalidArchive("an XML attribute without its closing quote") }
            let value = bytes[valueStart..<index]
            index += 1
            if attributeName.elementsEqual(wanted) { return try unescape(value) }
        }
        return nil
    }

    private mutating func skip(past terminator: [UInt8]) throws(AEAError) {
        while offset + terminator.count <= bytes.count {
            var match = true
            for (index, expected) in terminator.enumerated() where byte(offset + index) != expected {
                match = false
                break
            }
            if match {
                offset += terminator.count
                return
            }
            offset += 1
        }
        throw .invalidArchive("XML ends inside markup")
    }

    /// Text with entity and character references replaced.
    private static func unescape(_ raw: ArraySlice<UInt8>) throws(AEAError) -> String {
        let bytes = Array(raw)
        guard bytes.contains(0x26) else { return String(decoding: bytes, as: UTF8.self) }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x26 else {
                output.append(bytes[index])
                index += 1
                continue
            }
            guard let end = bytes[index...].firstIndex(of: 0x3B) else { throw .invalidArchive("an XML reference without ;") }
            let entity = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
            switch entity {
            case "amp": output.append(0x26)
            case "lt": output.append(0x3C)
            case "gt": output.append(0x3E)
            case "quot": output.append(0x22)
            case "apos": output.append(0x27)
            default:
                let scalarValue: UInt32? = if entity.hasPrefix("#x") { UInt32(entity.dropFirst(2), radix: 16) }
                else if entity.hasPrefix("#") { UInt32(entity.dropFirst(), radix: 10) } else { nil }
                guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { throw .invalidArchive("an XML reference &\(entity);") }
                output.append(contentsOf: Array(String(Character(scalar)).utf8))
            }
            index = end + 1
        }
        return String(decoding: output, as: UTF8.self)
    }
}
