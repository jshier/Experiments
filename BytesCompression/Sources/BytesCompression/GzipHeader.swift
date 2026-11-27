public import Bytes

/// A gzip member's header (RFC 1952, 2.3.1), all of it: what ``parse(_:)`` reads from a `.gz` file's first bytes, and
/// what ``DeflateEncoder/init(gzipHeader:level:)`` writes.
///
/// ```swift
/// let (header, size) = try GzipHeader.parse(file)           // the name `gzip -N` restores, and the time
/// var encoder = DeflateEncoder(gzipHeader: GzipHeader(name: Array("notes.txt".utf8), modificationTime: seconds),
///                              level: 6)
/// ```
///
/// The name and comment are bytes as they are: RFC 1952 says ISO 8859-1, but tools write UTF-8 or the file system's
/// bytes, so they aren't converted. Neither may contain a zero byte (each ends with one). The encoder writes the extra
/// flags (XFL) its level calls for.
public struct GzipHeader: Hashable, Sendable {
    /// FTEXT: the data is probably text.
    public var isText: Bool
    /// MTIME: the original file's modification time in seconds since 1970 (UTC), or 0 for none.
    public var modificationTime: UInt32
    /// OS: the file system the member was made on (0 FAT, 3 Unix, 7 Macintosh, 255 unknown, …).
    public var operatingSystem: UInt8
    /// FNAME: the original file's name, without its terminating zero.
    public var name: [UInt8]?
    /// FCOMMENT: a comment, without its terminating zero.
    public var comment: [UInt8]?
    /// FEXTRA: the extra field's subfields, as they are (at most 65,535 bytes).
    public var extraField: [UInt8]?
    /// FHCRC: the header ends with the low 16 bits of its CRC-32 (``parse(_:)`` verifies it; an encoder writes it).
    public var hasHeaderCRC: Bool

    /// Creates a header; every field optional (the default is the 10 bytes `DeflateEncoder` writes for gzip: no time,
    /// unknown OS, no optional fields).
    ///
    /// - Precondition: `name` and `comment` hold no zero byte; `extraField` is at most 65,535 bytes (checked here, and
    ///   again by the encoders at each stream's start, since the fields can change after).
    public init(
        name: [UInt8]? = nil, comment: [UInt8]? = nil, modificationTime: UInt32 = 0, operatingSystem: UInt8 = 255,
        isText: Bool = false, extraField: [UInt8]? = nil, hasHeaderCRC: Bool = false
    ) {
        self.name = name
        self.comment = comment
        self.modificationTime = modificationTime
        self.operatingSystem = operatingSystem
        self.isText = isText
        self.extraField = extraField
        self.hasHeaderCRC = hasHeaderCRC
        checkFields()
    }

    /// Traps unless the fields can be written: a name or comment holding a zero byte would end early, and an extra
    /// field over 65,535 bytes doesn't fit XLEN. Checked when made and again by the encoders (the fields are `var`s).
    func checkFields() {
        precondition(!(name ?? []).contains(0) && !(comment ?? []).contains(0), "A gzip name or comment ends at its first zero byte")
        precondition((extraField?.count ?? 0) <= 0xFFFF, "A gzip extra field is at most 65,535 bytes")
    }

    /// Whether it's the header `DeflateEncoder` writes without one: 10 bytes, no time, unknown OS, nothing optional.
    var isDefault: Bool {
        self == GzipHeader()
    }

    /// The header's size when written.
    public var encodedByteCount: Int {
        10 &+ (extraField.map { 2 &+ $0.count } ?? 0) &+ (name.map { $0.count &+ 1 } ?? 0)
            &+ (comment.map { $0.count &+ 1 } ?? 0) &+ (hasHeaderCRC ? 2 : 0)
    }

    /// Writes the header into `bytes` (replacing what's there, keeping its capacity), with `extraFlags` as XFL.
    func encode(into bytes: inout [UInt8], extraFlags: UInt8) {
        checkFields()
        bytes.removeAll(keepingCapacity: true)
        var flags: UInt8 = isText ? 1 : 0
        if hasHeaderCRC { flags |= 2 }
        if extraField != nil { flags |= 4 }
        if name != nil { flags |= 8 }
        if comment != nil { flags |= 16 }
        bytes += [0x1F, 0x8B, 8, flags]
        for index in 0..<4 {
            bytes.append(UInt8(truncatingIfNeeded: modificationTime &>> UInt32(8 &* index)))
        }
        bytes += [extraFlags, operatingSystem]
        // Appended piece by piece: `name + [0]` made a temporary array per stream.
        if let extraField {
            bytes.append(UInt8(truncatingIfNeeded: extraField.count))
            bytes.append(UInt8(truncatingIfNeeded: extraField.count &>> 8))
            bytes.append(contentsOf: extraField)
        }
        if let name {
            bytes.append(contentsOf: name)
            bytes.append(0)
        }
        if let comment {
            bytes.append(contentsOf: comment)
            bytes.append(0)
        }
        if hasHeaderCRC {
            let crc = CRC32.checksum(bytes.span.bytes)
            bytes += [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc &>> 8)]
        }
    }

    /// Reads the gzip member header at the start of `bytes`: a `.gz` file's first bytes (a buffer holding all of the
    /// header: its optional fields have no limit but the input).
    ///
    /// - Parameter bytes: The member's first bytes.
    /// - Returns: The header, and its size: where the DEFLATE data starts.
    /// - Throws: ``BytesError/insufficientData`` if the header runs past `bytes`; ``BytesError/invalidValue`` if they
    ///   don't start a gzip member (`1F 8B 08`); ``BytesError/unsupported`` for reserved flags (RFC 1952: they may mean
    ///   a field a later version adds); ``BytesError/checksumMismatch`` for a header CRC that doesn't match.
    public static func parse(_ bytes: RawSpan) throws(BytesError) -> (header: GzipHeader, byteCount: Int) {
        var reader = AlignedBytesReader(bytes)
        let magic = try reader.read(byteCount: 3)
        guard magic.load(fromByteOffset: 0, as: UInt8.self) == 0x1F, magic.load(fromByteOffset: 1, as: UInt8.self) == 0x8B,
              magic.load(fromByteOffset: 2, as: UInt8.self) == 8 else { throw .invalidValue }
        let flags = try Byte(reader.read(UInt8.self))
        guard flags.isZero(GzipFlags.reserved) else { throw .unsupported }
        let time = try reader.read(Byte4.self, .littleEndian)
        _ = try reader.read(UInt8.self) // XFL: the encoder's, not kept.
        let system = try reader.read(UInt8.self)
        var header = GzipHeader(modificationTime: time, operatingSystem: system, isText: flags[GzipFlags.text])
        if flags[GzipFlags.extra] {
            let length = try Int(reader.read(Byte2.self, .littleEndian))
            header.extraField = try Array(copying: reader.read(byteCount: length))
        }
        for isName in [true, false] where flags[isName ? GzipFlags.name : GzipFlags.comment] {
            let rest = reader.remainingBytes
            guard let zero = rest.firstByteOffset(where: { $0.matching(0) }) else { throw .insufficientData }
            let field = try Array(copying: reader.read(byteCount: zero))
            _ = try reader.read(UInt8.self) // The zero.
            if isName { header.name = field } else { header.comment = field }
        }
        if flags[GzipFlags.headerCRC] {
            header.hasHeaderCRC = true
            let crc = CRC32.checksum(bytes.extracting(0..<reader.byteOffset))
            guard try reader.read(Byte2.self, .littleEndian) == UInt16(truncatingIfNeeded: crc) else { throw .checksumMismatch }
        }
        return (header, reader.byteOffset)
    }
}
