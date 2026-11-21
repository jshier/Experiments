internal import Bytes
internal import BytesFoundation
import Disk
import Foundation
import Synchronization
import System

// MARK: - Model

/// One entry of a zip archive's central directory.
public struct ZipEntry: Sendable {
    /// What an entry is, from its name and attributes.
    public enum Kind: Sendable {
        /// A regular file.
        case file
        /// A directory: a name ending in `/`, a Unix directory mode, or the MS-DOS directory attribute.
        case directory
        /// A symbolic link, whose contents are the link's destination.
        case symlink
    }

    /// The entry's name as stored, relative to the archive root. UTF-8 if it validates, otherwise code page 437.
    public let path: String
    /// What the entry is.
    public let kind: Kind
    /// The compression method: see ``ZipArchive/Method``.
    public let method: UInt16
    /// The general purpose bit flags.
    public let flags: UInt16
    /// The CRC-32 of the uncompressed contents.
    public let crc32: UInt32
    /// The size of the compressed data in bytes (ZIP64-aware).
    public let compressedSize: UInt64
    /// The size of the uncompressed contents in bytes (ZIP64-aware).
    public let uncompressedSize: UInt64
    /// The offset of the entry's local file header from the start of the archive (ZIP64-aware).
    public let localHeaderOffset: UInt64
    /// How the entry is encrypted, or `nil` if it isn't. For WinZip AES, ``method`` is the compression
    /// method recorded in the AES extra field, not 99.
    public let encryption: ZipEncryption?
    /// The Unix user ID from Info-ZIP's Unix extra fields, if recorded.
    public let ownerID: UInt32?
    /// The Unix group ID from Info-ZIP's Unix extra fields, if recorded.
    public let groupID: UInt32?
    /// The system that made the entry: the high byte of "version made by" (0 MS-DOS/FAT, 3 Unix, 10 NTFS
    /// as Windows writes it, 19 macOS).
    public let hostSystem: UInt8
    /// The raw MS-DOS time, which the traditional cipher checks when the entry has a data descriptor.
    let dosTime: UInt16
    /// The Unix permission bits; 0 for none.
    let permissionBits: UInt16
    /// The modification time in seconds since 1970; NaN for none.
    ///
    /// Stored as a `Double`, not a `Date?`: `Date` is a resilient Foundation type, so a struct holding one is
    /// copied, moved, and destroyed through value witnesses, and every entry is copied into the array as it's
    /// parsed (2,000 entries: 6.0 → … M instructions; see `Benchmarks/RESULTS.md`, 2026-11-18).
    let modificationTime: Double

    /// The Unix permission bits (including setuid, setgid, and sticky) when the archive was made on Unix and
    /// they're nonzero; `nil` otherwise.
    public var posixPermissions: Int? { permissionBits == 0 ? nil : Int(permissionBits) }

    /// The modification time: the extended timestamp field's UTC time if present, then the NTFS or old
    /// Info-ZIP Unix field's, otherwise the MS-DOS date and time read as local time. `nil` if no date can be
    /// built from the DOS fields.
    public var modificationDate: Date? { modificationTime.isNaN ? nil : Date(timeIntervalSince1970: modificationTime) }

    // Bit 0. (A mask, not `Bytes`' `flags[bit: 0]`: `Bytes` is imported `internal`, so inlinable public code
    // can't use it.)
    /// Whether the entry is encrypted (flag bit 0). See ``encryption`` for how.
    @inlinable public var isEncrypted: Bool { flags & 0x1 != 0 }
}

// MARK: - Packed fields

/// A central directory entry's packed fields, by name.
enum ZipAttributes {
    /// The high byte of "version made by": the host OS (3 is Unix).
    static var host: BitField<Int> { BitField(bits: 8...15) }
    /// Unix hosts' `st_mode`: the external attributes' high 16 bits.
    static var unixMode: BitField<Int> { BitField(bits: 16...31) }
    /// The MS-DOS directory attribute, in the external attributes' low byte.
    static var dosDirectory: BitFlag { BitFlag(bit: 4) }
}

// MARK: - Archive

/// A zip archive, memory-mapped and indexed by its central directory.
///
/// Reads stored, deflated, Deflate64, bzip2, LZMA, and xz entries, ZIP64, traditional and WinZip AES
/// encryption, and archives with data before them (self-extracting archives). Multi-disk archives are
/// rejected. It's `Sendable`: the mapping is immutable, so entries can be read from several tasks at once.
public struct ZipArchive: Sendable {
    /// Record signatures, in file order. Computed, so each use folds to a 32-bit constant.
    enum Signature {
        static var localFile: Byte4 { 0x50_4B_03_04 }
        static var centralDirectory: Byte4 { 0x50_4B_01_02 }
        static var endOfCentralDirectory: Byte4 { 0x50_4B_05_06 }
        static var zip64EndOfCentralDirectory: Byte4 { 0x50_4B_06_06 }
        static var zip64Locator: Byte4 { 0x50_4B_06_07 }
    }

    /// The compression methods that can be read, as ``ZipEntry/method`` values.
    public enum Method {
        /// Method 0: no compression.
        public static let stored: UInt16 = 0
        /// Method 8: raw DEFLATE (RFC 1951).
        public static let deflated: UInt16 = 8
        /// Method 9: Deflate64 ("enhanced deflating"): a 64 KB window and matches up to 65,538 bytes.
        public static let deflate64: UInt16 = 9
        /// Method 12: bzip2.
        public static let bzip2: UInt16 = 12
        /// Method 14: LZMA (LZMA1), with a 4-byte zip header and its properties before the stream.
        public static let lzma: UInt16 = 14
        /// Method 93: Zstandard (RFC 8878), one or more frames.
        public static let zstd: UInt16 = 93
        /// Method 95: an xz stream.
        public static let xz: UInt16 = 95
        /// Method 99: WinZip AES. The real method is in the entry's AES extra field (``ZipEntry/method``
        /// reports that one).
        public static let aes: UInt16 = 99

        /// Whether entries with `method` can be decompressed.
        public static func isSupported(_ method: UInt16) -> Bool {
            [stored, deflated, deflate64, bzip2, lzma, zstd, xz].contains(method)
        }

        /// A short name for `method`, as listings show it.
        public static func name(_ method: UInt16) -> String {
            switch method {
            case stored: "Stored"
            case 1: "Shrunk"
            case 2...5: "Reduced"
            case 6: "Imploded"
            case deflated: "Deflated"
            case deflate64: "Deflate64"
            case bzip2: "BZip2"
            case lzma: "LZMA"
            case zstd: "Zstd"
            case xz: "XZ"
            case 98: "PPMd"
            default: "Unk:\(method)"
            }
        }
    }

    /// The archive's file URL.
    public let url: URL
    /// Every entry in the central directory, in archive order.
    public let entries: [ZipEntry]
    /// The archive comment, decoded like entry names.
    public let comment: String
    /// Bytes before the archive proper, which offsets don't count: a self-extractor's program, or data
    /// prepended later. Offsets in ``entries`` are already adjusted for them.
    public let leadingByteCount: UInt64
    @usableFromInline let file: MappedFile

    /// Opens and indexes an archive.
    ///
    /// Memory-maps the file and parses the central directory; entry contents aren't read until requested.
    ///
    /// - Parameter url: The archive's file URL.
    /// - Throws: `Errno` (such as `.noSuchFileOrDirectory`) if the file can't be opened or mapped;
    ///   ``ZipError/notAZipArchive`` if there's no end of central directory record;
    ///   ``ZipError/multiDiskUnsupported`` for a spanned archive; ``ZipError/truncated(_:)``,
    ///   ``ZipError/badSignature(_:)``, or ``ZipError/corruptData(_:)`` if the central directory is damaged.
    public init(url: URL) throws {
        self.url = url
        // Memory-map the archive (Disk's `MappedFile`) so large files aren't read into RAM up front. Everything
        // below parses `file.bytes` (a RawSpan) in place.
        let file = try MappedFile(path: FilePath(url.path(percentEncoded: false)))
        self.file = file
        (entries, comment, leadingByteCount) = try Self.readDirectory(file.bytes)
    }
}

// MARK: - Central directory


extension ZipArchive {
    private struct CentralDirectoryLocation {
        var entryCount: UInt64
        var size: UInt64
        var offset: UInt64
        /// Where the record after the directory starts (the ZIP64 or classic end record): the directory
        /// should end there, which reveals data prepended to the archive.
        var followingRecord: UInt64

        var isSaturated: Bool { entryCount == UInt16.max || size == UInt32.max || offset == UInt32.max }
    }

    private static func readDirectory(_ archive: RawSpan) throws(ZipError) -> (entries: [ZipEntry], comment: String, leading: UInt64) {
        let eocdOffset = try findEndOfCentralDirectory(archive)
        let (location, comment) = try readCentralDirectoryLocation(archive, eocdOffset: eocdOffset)

        // Data before the archive (a self-extractor's program) shifts everything: offsets count from the
        // archive's own start. The directory really starts `size` bytes before the record after it.
        var leading: UInt64 = 0
        if location.followingRecord >= location.size {
            let actual = location.followingRecord - location.size
            if actual > location.offset, location.entryCount == 0 || hasSignature(archive, Signature.centralDirectory, at: actual) {
                leading = actual - location.offset
            }
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(min(location.entryCount, 1 << 20)))
        do throws(BytesError) {
            var reader = try LittleEndianBytesReader(archive, atByteOffset: location.offset + leading)
            var directory = try reader.readSection(byteCount: location.size)
            for _ in 0..<location.entryCount {
                try entries.append(readCentralDirectoryEntry(&directory, leading: leading))
            }
            // More entries than recorded: a count that wrapped past 65,535 in an archive without ZIP64 records.
            while directory.remainingByteCount >= 46, try directory.peek(Byte4.self) == Signature.centralDirectory {
                try entries.append(readCentralDirectoryEntry(&directory, leading: leading))
            }
        } catch {
            throw error.zipError("central directory entry \(entries.count)")
        }
        return (entries, comment, leading)
    }

    private static func hasSignature(_ archive: RawSpan, _ signature: Byte4, at offset: UInt64) -> Bool {
        guard var reader = try? LittleEndianBytesReader(archive, atByteOffset: offset) else { return false }
        return (try? reader.read(Byte4.self)) == signature
    }

    private static func readCentralDirectoryLocation(
        _ archive: RawSpan, eocdOffset: Int
    ) throws(ZipError) -> (CentralDirectoryLocation, comment: String) {
        var location: CentralDirectoryLocation
        var spansDisks = false
        var comment = ""
        do throws(BytesError) {
            var eocd = try LittleEndianBytesReader(archive, atByteOffset: eocdOffset)
            var record = try eocd.readSection(byteCount: 22)
            try record.expect(Signature.endOfCentralDirectory)
            let diskNumber = try record.read(UInt16.self)
            let directoryDisk = try record.read(UInt16.self)
            try record.skip(byteCount: 2) // entries on this disk
            location = try CentralDirectoryLocation(
                entryCount: UInt64(record.read(UInt16.self)),
                size: UInt64(record.read(UInt32.self)),
                offset: UInt64(record.read(UInt32.self)),
                followingRecord: UInt64(eocdOffset)
            )
            // The comment, or as much of it as there is.
            let commentLength = try Int(record.read(UInt16.self))
            comment = try decodeName(Span(viewing: eocd.read(byteCount: min(commentLength, eocd.remainingByteCount))))

            // ZIP64: saturated fields mean the real values live in the ZIP64 EOCD record, which a
            // fixed-size locator immediately before the classic EOCD points to.
            if location.isSaturated, eocdOffset >= 20 {
                var locator = try LittleEndianBytesReader(archive, atByteOffset: eocdOffset - 20)
                if try locator.read(Byte4.self) == Signature.zip64Locator {
                    try locator.skip(byteCount: 4) // disk containing the ZIP64 EOCD
                    // The recorded offset doesn't count prepended data; the record usually sits right before
                    // the locator (56 bytes, without extensible data).
                    var recordOffset = try locator.read(UInt64.self)
                    let usual = UInt64(eocdOffset - 20) &- 56
                    if !hasSignature(archive, Signature.zip64EndOfCentralDirectory, at: recordOffset),
                       eocdOffset >= 76, hasSignature(archive, Signature.zip64EndOfCentralDirectory, at: usual) {
                        recordOffset = usual
                    }
                    var zip64 = try LittleEndianBytesReader(archive, atByteOffset: recordOffset)
                    try zip64.expect(Signature.zip64EndOfCentralDirectory)
                    try zip64.skip(byteCount: 8 + 2 + 2 + 4 + 4 + 8) // record size, versions, disks, entries on disk
                    location.entryCount = try zip64.read(UInt64.self)
                    location.size = try zip64.read(UInt64.self)
                    location.offset = try zip64.read(UInt64.self)
                    location.followingRecord = recordOffset
                    return (location, comment)
                }
            }
            spansDisks = diskNumber != 0 || directoryDisk != 0
        } catch {
            throw error.zipError("end of central directory")
        }
        guard !spansDisks else { throw .multiDiskUnsupported }
        return (location, comment)
    }

    private static func findEndOfCentralDirectory(_ archive: RawSpan) throws(ZipError) -> Int {
        // The EOCD is 22 bytes plus a comment of up to 65,535 bytes, so it starts in that window before the
        // end. Search it backwards (16 offsets per SIMD step) for the last signature.
        let minimum = 22
        guard archive.byteCount >= minimum else { throw .notAZipArchive }
        let last = archive.byteCount - minimum
        let first = max(0, last - 0xFFFF)
        let window = LittleEndianBytesReader(archive.extracting(first..<last + 4))
        guard let offset = window.lastByteOffset(of: Signature.endOfCentralDirectory) else { throw .notAZipArchive }
        return first + offset
    }

    @_lifetime(directory: copy directory)
    private static func readCentralDirectoryEntry(
        _ directory: inout LittleEndianBytesReader, leading: UInt64
    ) throws(BytesError) -> ZipEntry {
        // The fixed part in one read (`CentralDirectoryHeader`): one bounds check, each field read once.
        let header = try directory.read(CentralDirectoryHeader.self)
        var compressedSize = UInt64(header.compressedSize)
        var uncompressedSize = UInt64(header.uncompressedSize)
        var localHeaderOffset = UInt64(header.localHeaderOffset)

        let nameBytes = try directory.read(byteCount: header.nameLength)
        var name = decodeName(Span(viewing: nameBytes))
        var extra = try directory.readSection(byteCount: header.extraLength)
        try directory.skip(byteCount: header.commentLength)

        // Seconds since 1970, NaN for none (not `Date?`: see `ZipEntry.modificationTime`).
        var modificationTime = Double.nan
        var fallbackTime = Double.nan // From fields that the extended timestamp overrides.
        var method = header.method
        var encryption: ZipEncryption? = header.flags & 0x1 == 0 ? nil : header.flags & 0x40 != 0 ? .unsupported : .traditional
        var ownerID: UInt32?
        var groupID: UInt32?
        while extra.remainingByteCount >= 4 {
            let id = try extra.read(UInt16.self)
            // Tolerate malformed trailing padding: a field that isn't all there ends the list.
            guard var field = extra.readSectionIfComplete(prefixedBy: Byte2.self) else { break }
            switch id {
            case 0x0001: // ZIP64 extended information: only the saturated fields are present, in this order.
                if uncompressedSize == UInt32.max { uncompressedSize = try field.read(UInt64.self) }
                if compressedSize == UInt32.max { compressedSize = try field.read(UInt64.self) }
                if localHeaderOffset == UInt32.max { localHeaderOffset = try field.read(UInt64.self) }
            case 0x5455: // Extended timestamp: a flags byte, then a UTC mtime if bit 0 is set.
                if field.remainingByteCount >= 5, try field.read(ExtendedTimestampFlags.self).modification {
                    modificationTime = Double(try field.read(Int32.self, asSigned: Byte4.self))
                }
            case 0x000A: // NTFS: 4 reserved bytes, then tagged attributes; tag 1 holds three 64-bit FILETIMEs.
                try field.skip(byteCount: 4)
                while field.remainingByteCount >= 4 {
                    let tag = try field.read(UInt16.self)
                    guard var attribute = field.readSectionIfComplete(prefixedBy: Byte2.self) else { break }
                    if tag == 1, attribute.remainingByteCount >= 8 {
                        // 100-nanosecond intervals since 1601.
                        let ticks = try attribute.read(UInt64.self)
                        fallbackTime = Double(ticks) / 10_000_000 - 11_644_473_600
                    }
                }
            case 0x5855: // Info-ZIP Unix (old): atime, mtime, then optionally 16-bit UID and GID.
                if field.remainingByteCount >= 8 {
                    try field.skip(byteCount: 4)
                    fallbackTime = Double(try field.read(UInt32.self))
                    if field.remainingByteCount >= 4 {
                        ownerID = try UInt32(field.read(UInt16.self))
                        groupID = try UInt32(field.read(UInt16.self))
                    }
                }
            case 0x7875: // Info-ZIP Unix (new): version 1, then sized little-endian UID and GID.
                if try field.read(UInt8.self) == 1 {
                    ownerID = try readSizedID(&field)
                    groupID = try readSizedID(&field)
                }
            case 0x7075: // Info-ZIP Unicode path: version 1, the CRC-32 of the header's name, then UTF-8.
                if try field.read(UInt8.self) == 1,
                   try field.read(UInt32.self) == CRC32.checksum(nameBytes),
                   let utf8 = try? UTF8Span(validating: Span(viewing: field.read(byteCount: field.remainingByteCount))) {
                    name = String(copying: utf8)
                }
            case 0x9901: // WinZip AES: vendor version (1 or 2), "AE", key strength, the real method.
                if header.method == Method.aes, field.remainingByteCount >= 7 {
                    let version = try field.read(UInt16.self)
                    try field.skip(byteCount: 2)
                    let strength = try field.read(UInt8.self)
                    method = try field.read(UInt16.self)
                    encryption = (1...3).contains(strength) ? .aes(bits: 64 + 64 * Int(strength), authenticatesCRC: version == 1) : .unsupported
                }
            default:
                break
            }
        }

        return makeEntry(
            name: name,
            versionMadeBy: header.versionMadeBy,
            flags: header.flags,
            method: method,
            crc: header.crc32,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            externalAttributes: header.externalAttributes,
            localHeaderOffset: localHeaderOffset + leading,
            modificationTime: !modificationTime.isNaN ? modificationTime
                : !fallbackTime.isNaN ? fallbackTime : time(header.date, header.time),
            encryption: encryption,
            ownerID: ownerID,
            groupID: groupID,
            dosTime: header.time.rawValue
        )
    }

    /// A UID or GID in Info-ZIP's new Unix field: a size byte, then that many little-endian bytes.
    private static func readSizedID(_ field: inout LittleEndianBytesReader) throws(BytesError) -> UInt32? {
        let size = try Int(field.read(UInt8.self))
        if size == 4 { return try field.read(UInt32.self) } // What Info-ZIP writes.
        var value: UInt64 = 0
        for index in 0..<size {
            let byte = try field.read(UInt8.self)
            if index < 8 { value |= UInt64(byte) << (8 * index) }
        }
        return value <= UInt32.max ? UInt32(value) : nil
    }

    /// Builds an entry from central directory fields, deriving its kind and permissions.
    ///
    /// The kind is a directory if the name ends in `/`, the Unix mode says so, or the MS-DOS directory bit is
    /// set; otherwise a symlink if the Unix mode says so; otherwise a file. The Unix mode is the high 16 bits
    /// of `externalAttributes`, used only when `versionMadeBy`'s host byte is 3 (Unix) or 19 (macOS). Names
    /// from MS-DOS, NTFS, and VFAT hosts have their backslashes turned into slashes, as Info-ZIP does.
    ///
    /// - Parameters:
    ///   - name: The decoded entry name.
    ///   - versionMadeBy: The "version made by" field; its high byte is the host system.
    ///   - flags: The general purpose bit flags.
    ///   - method: The compression method (for AES entries, the real one).
    ///   - crc: The CRC-32 of the uncompressed contents.
    ///   - compressedSize: The compressed size, after ZIP64 resolution.
    ///   - uncompressedSize: The uncompressed size, after ZIP64 resolution.
    ///   - externalAttributes: The external file attributes.
    ///   - localHeaderOffset: The local header's offset in the file, after ZIP64 resolution.
    ///   - modificationTime: The entry's modification time in seconds since 1970, or NaN if unknown.
    ///   - encryption: How the entry is encrypted, if it is.
    ///   - ownerID: The Unix UID, if recorded.
    ///   - groupID: The Unix GID, if recorded.
    ///   - dosTime: The raw MS-DOS time.
    /// - Returns: The entry.
    @inline(__always)
    static func makeEntry(
        name: String,
        versionMadeBy: UInt16,
        flags: UInt16,
        method: UInt16,
        crc: UInt32,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        externalAttributes: UInt32,
        localHeaderOffset: UInt64,
        modificationTime: Double,
        encryption: ZipEncryption? = nil,
        ownerID: UInt32? = nil,
        groupID: UInt32? = nil,
        dosTime: UInt16 = 0
    ) -> ZipEntry {
        // The high byte of "version made by" is the host OS; Unix's st_mode is the high 16 bits. The `S_IF…`
        // constants are written out: Darwin's are imported as getters, each an out-of-line call.
        let host = versionMadeBy[ZipAttributes.host]
        let mode = host == 3 || host == 19 ? externalAttributes[ZipAttributes.unixMode] : 0
        let fileType = mode & 0o170_000 // S_IFMT
        let fromDOS = switch host {
        case 0, 11, 14: true // MS-DOS (FAT), NTFS, VFAT
        default: false
        }
        let path = fromDOS && name.utf8.contains(UInt8(ascii: "\\")) ? name.replacing("\\", with: "/") : name
        let isDirectory = path.utf8.last == UInt8(ascii: "/") || fileType == 0o040_000 /* S_IFDIR */
            || externalAttributes[ZipAttributes.dosDirectory]
        let kind: ZipEntry.Kind = if isDirectory {
            .directory
        } else if fileType == 0o120_000 /* S_IFLNK */ {
            .symlink
        } else {
            .file
        }
        return ZipEntry(
            path: path,
            kind: kind,
            method: method,
            flags: flags,
            crc32: crc,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localHeaderOffset,
            encryption: encryption ?? (flags & 0x1 == 0 ? nil : .traditional),
            ownerID: ownerID,
            groupID: groupID,
            hostSystem: UInt8(host),
            dosTime: dosTime,
            permissionBits: UInt16(mode & 0o7777),
            modificationTime: modificationTime
        )
    }


    /// Decodes an entry name as UTF-8 if it validates, otherwise as code page 437.
    ///
    /// Flag bit 11 means UTF-8; otherwise the spec says IBM code page 437. In practice many tools (Info-ZIP,
    /// ditto) write UTF-8 without setting the flag, so this ignores the flag and prefers UTF-8 whenever it
    /// validates.
    ///
    /// - Parameter bytes: The raw name bytes.
    /// - Returns: The decoded name.
    static func decodeName(_ bytes: Span<UInt8>) -> String {
        if let utf8 = try? UTF8Span(validating: bytes) {
            return String(copying: utf8)
        }
        var scalars = String.UnicodeScalarView()
        for index in bytes.indices {
            let byte = bytes[index]
            scalars.append(byte < 0x80 ? Unicode.Scalar(byte) : codePage437High[Int(byte - 0x80)])
        }
        return String(scalars)
    }

    /// The high half of CP437 (the low half is ASCII), mapped by CoreFoundation.
    private static let codePage437High: [Unicode.Scalar] = {
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        )
        return (0x80...0xFF).map { byte in
            String(data: Data([UInt8(byte)]), encoding: encoding)?.unicodeScalars.first ?? "\u{FFFD}"
        }
    }()

    /// ``date(_:_:)`` from the raw fields (the `ByteReader` parser's form).
    static func date(dosDate: UInt16, dosTime: UInt16) -> Date? {
        // Can't throw: neither has reserved bits or enum fields.
        date(try! DOSDate(rawValue: dosDate), try! DOSTime(rawValue: dosTime))
    }

    /// ``date(_:_:)`` as seconds since 1970, NaN if there's no such date. Out of line: entries with an extended
    /// timestamp (most) never call it.
    @inline(never)
    static func time(_ date: DOSDate, _ time: DOSTime) -> Double {
        Self.date(date, time)?.timeIntervalSince1970 ?? .nan
    }

    static func date(_ date: DOSDate, _ time: DOSTime) -> Date? {
        var components = DateComponents()
        components.year = 1980 + date.yearsSince1980
        components.month = date.month
        components.day = date.day
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.halfSeconds * 2
        // DOS timestamps have no time zone; by convention they're local time.
        return Calendar.current.date(from: components)
    }
}

// MARK: - Entry contents

extension ZipEntry {
    /// Whether the recorded CRC-32 is checked: AE-2 AES entries record 0 and rely on their HMAC.
    @inlinable var checksCRC: Bool {
        if case .aes(_, authenticatesCRC: false) = encryption { false } else { true }
    }
}

public extension ZipArchive {
    /// Calls `body` with successive chunks of the entry's decompressed contents, verifying size and CRC-32.
    ///
    /// The spans borrow `decoder`'s buffer (or, for unencrypted stored entries, the mapped archive), so
    /// nothing is copied or allocated, and they're valid only during each call to `body`. Reuse one decoder
    /// for many entries; a decoder serves one call at a time. `body` may already have run for some chunks when
    /// an integrity error is thrown: the size and CRC-32 checks come after the last chunk. (An AES entry's
    /// authentication code is checked before any.)
    ///
    /// - Parameters:
    ///   - entry: The entry to read.
    ///   - decoder: The decoder to use. Its ``ZipDecoder/backend`` picks the DEFLATE and CRC-32 implementations.
    ///   - password: The password, for encrypted entries.
    ///   - body: Called with each chunk, in order. Chunks are at most about 1 MB for compressed entries; a stored
    ///     entry arrives as one chunk.
    /// - Throws: ``ZipError/unsupportedMethod(_:_:)`` for a method ``ZipArchive/Method`` can't read;
    ///   ``ZipError/passwordRequired(_:)``, ``ZipError/incorrectPassword(_:)``,
    ///   ``ZipError/authenticationFailed(_:)``, or ``ZipError/unsupportedEncryption(_:)`` for encrypted
    ///   entries; ``ZipError/truncated(_:)`` or ``ZipError/badSignature(_:)`` if the local header is damaged or
    ///   the payload runs past the archive's end; ``ZipError/corruptData(_:)`` if compressed data is invalid
    ///   or its output isn't `uncompressedSize` bytes; ``ZipError/sizeMismatch(_:expected:actual:)`` if a
    ///   stored entry's size is wrong; ``ZipError/crcMismatch(_:expected:actual:)`` if the CRC-32 doesn't
    ///   match; and whatever `body` throws.
    @inlinable
    func contents(of entry: ZipEntry, using decoder: inout ZipDecoder, password: String? = nil, _ body: (RawSpan) throws -> Void) throws {
        let archive = file.bytes
        let payload = try Self.payload(of: entry, in: archive)

        // Closure literals (not a local func passed as a value), so `crc` and `written` stay on the
        // stack instead of being boxed on the heap: measured 2 mallocs per entry before this. The CRC is the
        // backend's own (`Bytes`' or zlib's), so each backend is measured whole.
        let backend = decoder.backend
        var crc: UInt = 0
        var written: UInt64 = 0
        if entry.method == Method.stored, !entry.isEncrypted {
            crc = ZipDecoder.crc32(0, payload, backend: backend)
            written = UInt64(payload.byteCount)
            try body(payload)
        } else {
            try decoder.decode(payload, entry: entry, password: password) { chunk in
                crc = ZipDecoder.crc32(crc, chunk, backend: backend)
                written += UInt64(chunk.byteCount)
                try body(chunk)
            }
        }
        try Self.check(entry, written: written, crc: crc)
    }

    /// Like ``contents(of:using:password:_:)``, with a temporary decoder.
    ///
    /// Creating a decoder allocates its buffers, so prefer ``contents(of:using:password:_:)`` in loops.
    ///
    /// - Parameters:
    ///   - entry: The entry to read.
    ///   - backend: Which DEFLATE and CRC-32 implementation to use.
    ///   - password: The password, for encrypted entries.
    ///   - body: Called with each chunk of decompressed contents, in order.
    /// - Throws: The errors of ``contents(of:using:password:_:)``.
    @inlinable
    func contents(of entry: ZipEntry, backend: ZipDecoder.Backend = .bytes, password: String? = nil, _ body: (RawSpan) throws -> Void) throws {
        var decoder = ZipDecoder(backend: backend)
        try contents(of: entry, using: &decoder, password: password, body)
    }

    /// Checks an entry's output size and CRC-32 after its last chunk.
    ///
    /// - Throws: ``ZipError/sizeMismatch(_:expected:actual:)`` for a stored entry of the wrong size,
    ///   ``ZipError/corruptData(_:)`` for a compressed one; ``ZipError/crcMismatch(_:expected:actual:)``.
    @inlinable
    internal static func check(_ entry: ZipEntry, written: UInt64, crc: UInt) throws {
        guard written == entry.uncompressedSize else {
            throw entry.method == Method.stored
                ? ZipError.sizeMismatch(entry.path, expected: entry.uncompressedSize, actual: written)
                : ZipError.corruptData(entry.path)
        }
        guard crc == UInt(entry.crc32) || !entry.checksCRC else {
            throw ZipError.crcMismatch(entry.path, expected: entry.crc32, actual: UInt32(truncatingIfNeeded: crc))
        }
    }

    /// The entry's full decompressed contents, verified.
    ///
    /// Holds the whole entry in memory; use ``contents(of:using:password:_:)`` to stream large entries.
    ///
    /// - Parameters:
    ///   - entry: The entry to read.
    ///   - backend: Which DEFLATE and CRC-32 implementation to use.
    ///   - password: The password, for encrypted entries.
    /// - Returns: The decompressed bytes.
    /// - Throws: The errors of ``contents(of:using:password:_:)``.
    func contents(of entry: ZipEntry, backend: ZipDecoder.Backend = .bytes, password: String? = nil) throws -> Data {
        var result = Data(capacity: Int(min(entry.uncompressedSize, 1 << 30)))
        try contents(of: entry, backend: backend, password: password) { chunk in
            result.append(chunk)
        }
        return result
    }

    /// The range of the entry's payload (compressed, possibly encrypted) in the archive file.
    internal func payloadRange(of entry: ZipEntry) throws -> Range<Int> {
        let archive = file.bytes
        guard let range = try archive.byteOffsets(of: Self.payload(of: entry, in: archive)) else {
            throw ZipError.truncated("payload for '\(entry.path)'")
        }
        return range
    }

    /// Walks the entry's local file header to its payload and returns the payload's span.
    ///
    /// - Parameters:
    ///   - entry: The entry whose payload to find.
    ///   - archive: The whole archive.
    /// - Returns: The `entry.compressedSize` bytes after the local header, borrowing `archive`.
    /// - Throws: ``ZipError/truncated(_:)`` if the header or payload runs past the archive's end;
    ///   ``ZipError/badSignature(_:)`` if there's no local file header at the entry's offset.
    @usableFromInline
    @_lifetime(copy archive)
    internal static func payload(of entry: ZipEntry, in archive: RawSpan) throws(ZipError) -> RawSpan {
        do throws(BytesError) {
            var reader = try LittleEndianBytesReader(archive, atByteOffset: entry.localHeaderOffset)
            var header = try reader.readSection(byteCount: 30)
            try header.expect(Signature.localFile)
            try header.skip(byteCount: 2 + 2 + 2 + 2 + 2 + 4 + 4 + 4) // version, flags, method, time, date, CRC, sizes
            // The local name/extra lengths can differ from the central directory's, so use these.
            let nameLength = try Int(header.read(UInt16.self))
            let extraLength = try Int(header.read(UInt16.self))
            try reader.skip(byteCount: nameLength + extraLength)
            return try reader.read(byteCount: entry.compressedSize)
        } catch {
            throw error.zipError("local file header for '\(entry.path)'")
        }
    }
}

extension BytesError {
    /// The archive error for failing to read `what`: truncation, a signature mismatch, or otherwise corrupt data.
    ///
    /// - Parameter what: The structure being read, for the error's message.
    /// - Returns: ``ZipError/truncated(_:)`` for `insufficientData`, ``ZipError/badSignature(_:)`` for
    ///   `mismatch`, and ``ZipError/corruptData(_:)`` for the rest.
    func zipError(_ what: String) -> ZipError {
        switch self {
        case .insufficientData: .truncated(what)
        case .mismatch: .badSignature(what)
        // The parser doesn't use typed views, writing, or raw-value fields, which throw these.
        case .misaligned, .insufficientCapacity, .invalidValue, .trailingData, .cancelled: .corruptData(what)
        }
    }
}
