import Foundation
import System

// MARK: - Model

public struct ZipEntry: Sendable {
    public enum Kind: Sendable { case file, directory, symlink }

    public let path: String
    public let kind: Kind
    public let method: UInt16
    public let flags: UInt16
    public let crc32: UInt32
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let localHeaderOffset: UInt64
    public let posixPermissions: Int?
    public let modificationDate: Date?

    @inlinable public var isEncrypted: Bool { flags & 0x1 != 0 }
}

// MARK: - Archive

public struct ZipArchive: Sendable {
    enum Signature {
        static let localFile: UInt32 = 0x0403_4B50
        static let centralDirectory: UInt32 = 0x0201_4B50
        static let endOfCentralDirectory: UInt32 = 0x0605_4B50
        static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4B50
        static let zip64Locator: UInt32 = 0x0706_4B50
    }

    public enum Method {
        public static let stored: UInt16 = 0
        public static let deflated: UInt16 = 8
    }

    public let url: URL
    public let entries: [ZipEntry]
    @usableFromInline let file: MappedFile

    /// Opens and indexes an archive. Throws `Errno.noSuchFileOrDirectory` if it doesn't exist and
    /// ``ZipError/notAZipArchive`` if it isn't a zip file.
    public init(url: URL) throws {
        self.url = url
        // Memory-map the archive so large files aren't read into RAM up front. Everything below
        // parses `file.bytes` (a RawSpan) in place.
        let file = try MappedFile(path: FilePath(url.path(percentEncoded: false)))
        self.file = file
        entries = try Self.readEntries(file.bytes)
    }
}

// MARK: - Central directory

extension ZipArchive {
    private struct CentralDirectoryLocation {
        var entryCount: UInt64
        var size: UInt64
        var offset: UInt64

        var isSaturated: Bool { entryCount == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF }
    }

    private static func readEntries(_ archive: RawSpan) throws(ZipError) -> [ZipEntry] {
        let location = try readCentralDirectoryLocation(archive)

        var reader = try ByteReader(archive, at: Int(clamping: location.offset))
        var directory = ByteReader(try reader.read(count: Int(clamping: location.size)))

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(min(location.entryCount, 1 << 20)))
        for _ in 0..<location.entryCount {
            entries.append(try readCentralDirectoryEntry(&directory))
        }
        return entries
    }

    private static func readCentralDirectoryLocation(_ archive: RawSpan) throws(ZipError) -> CentralDirectoryLocation {
        let eocdOffset = try findEndOfCentralDirectory(archive)
        var eocd = try ByteReader(archive, at: eocdOffset)
        try eocd.expect(Signature.endOfCentralDirectory, "end of central directory")
        let diskNumber: UInt16 = try eocd.read()
        let directoryDisk: UInt16 = try eocd.read()
        try eocd.skip(2) // entries on this disk
        var location = CentralDirectoryLocation(
            entryCount: UInt64(try eocd.read(UInt16.self)),
            size: UInt64(try eocd.read(UInt32.self)),
            offset: UInt64(try eocd.read(UInt32.self))
        )

        // ZIP64: saturated fields mean the real values live in the ZIP64 EOCD record, which a
        // fixed-size locator immediately before the classic EOCD points to.
        if location.isSaturated, eocdOffset >= 20 {
            var locator = try ByteReader(archive, at: eocdOffset - 20)
            if try locator.read(UInt32.self) == Signature.zip64Locator {
                try locator.skip(4) // disk containing the ZIP64 EOCD
                var zip64 = try ByteReader(archive, at: Int(clamping: try locator.read(UInt64.self)))
                try zip64.expect(Signature.zip64EndOfCentralDirectory, "ZIP64 end of central directory")
                try zip64.skip(8 + 2 + 2 + 4 + 4 + 8) // record size, versions, disk numbers, entries on disk
                location.entryCount = try zip64.read()
                location.size = try zip64.read()
                location.offset = try zip64.read()
                return location
            }
        }

        guard diskNumber == 0, directoryDisk == 0 else { throw .multiDiskUnsupported }
        return location
    }

    private static func findEndOfCentralDirectory(_ archive: RawSpan) throws(ZipError) -> Int {
        // The EOCD is 22 bytes plus a comment of up to 65,535 bytes, so scan backwards over that window.
        let minimum = 22
        guard archive.byteCount >= minimum else { throw .notAZipArchive }
        let last = archive.byteCount - minimum
        for offset in stride(from: last, through: max(0, last - 0xFFFF), by: -1)
            where archive.load(fromByteOffset: offset, as: UInt32.self, .littleEndian) == Signature.endOfCentralDirectory {
            return offset
        }
        throw .notAZipArchive
    }

    @_lifetime(directory: copy directory)
    private static func readCentralDirectoryEntry(_ directory: inout ByteReader) throws(ZipError) -> ZipEntry {
        try directory.expect(Signature.centralDirectory, "central directory entry")
        let versionMadeBy: UInt16 = try directory.read()
        try directory.skip(2) // version needed to extract
        let flags: UInt16 = try directory.read()
        let method: UInt16 = try directory.read()
        let dosTime: UInt16 = try directory.read()
        let dosDate: UInt16 = try directory.read()
        let crc: UInt32 = try directory.read()
        var compressedSize = UInt64(try directory.read(UInt32.self))
        var uncompressedSize = UInt64(try directory.read(UInt32.self))
        let nameLength = Int(try directory.read(UInt16.self))
        let extraLength = Int(try directory.read(UInt16.self))
        let commentLength = Int(try directory.read(UInt16.self))
        try directory.skip(2 + 2) // disk number start, internal attributes
        let externalAttributes: UInt32 = try directory.read()
        var localHeaderOffset = UInt64(try directory.read(UInt32.self))
        let name = decodeName(Span(viewing: try directory.read(count: nameLength)))
        var extra = ByteReader(try directory.read(count: extraLength))
        try directory.skip(commentLength)

        var unixModificationTime: Date?
        while extra.count >= 4 {
            let id: UInt16 = try extra.read()
            let size = Int(try extra.read(UInt16.self))
            guard size <= extra.count else { break } // Tolerate malformed trailing padding.
            var field = ByteReader(try extra.read(count: size))
            switch id {
            case 0x0001: // ZIP64 extended information: only the saturated fields are present, in this order.
                if uncompressedSize == 0xFFFF_FFFF { uncompressedSize = try field.read() }
                if compressedSize == 0xFFFF_FFFF { compressedSize = try field.read() }
                if localHeaderOffset == 0xFFFF_FFFF { localHeaderOffset = try field.read() }
            case 0x5455: // Extended timestamp: flags, then a UTC mtime if bit 0 is set.
                if size >= 5, try field.read(UInt8.self) & 0x1 != 0 {
                    unixModificationTime = Date(timeIntervalSince1970: TimeInterval(try field.read(Int32.self)))
                }
            default:
                break
            }
        }

        // The high byte of "version made by" is the host OS; 3 is Unix, whose st_mode is the high 16 bits.
        let mode = versionMadeBy >> 8 == 3 ? Int(externalAttributes >> 16) : 0
        let fileType = mode & Int(S_IFMT)
        let kind: ZipEntry.Kind = if name.hasSuffix("/") || fileType == Int(S_IFDIR) || externalAttributes & 0x10 != 0 {
            .directory
        } else if fileType == Int(S_IFLNK) {
            .symlink
        } else {
            .file
        }

        return ZipEntry(
            path: name,
            kind: kind,
            method: method,
            flags: flags,
            crc32: crc,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localHeaderOffset,
            posixPermissions: mode & 0o7777 != 0 ? mode & 0o7777 : nil,
            modificationDate: unixModificationTime ?? date(dosDate: dosDate, dosTime: dosTime)
        )
    }

    /// Flag bit 11 means UTF-8; otherwise the spec says IBM code page 437. In practice many tools (Info-ZIP,
    /// ditto) write UTF-8 without setting the flag, so prefer UTF-8 whenever it validates.
    private static func decodeName(_ bytes: Span<UInt8>) -> String {
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

    private static func date(dosDate: UInt16, dosTime: UInt16) -> Date? {
        var components = DateComponents()
        components.year = 1980 + Int(dosDate >> 9)
        components.month = Int((dosDate >> 5) & 0xF)
        components.day = Int(dosDate & 0x1F)
        components.hour = Int(dosTime >> 11)
        components.minute = Int((dosTime >> 5) & 0x3F)
        components.second = Int(dosTime & 0x1F) * 2
        // DOS timestamps have no time zone; by convention they're local time.
        return Calendar.current.date(from: components)
    }
}

// MARK: - Entry contents

extension ZipArchive {
    /// Calls `body` with successive chunks of the entry's decompressed contents, verifying size and CRC-32.
    ///
    /// The spans borrow `decoder`'s buffer (or, for stored entries, the mapped archive), so nothing is
    /// copied or allocated. Reuse one decoder across calls on the same thread.
    @inlinable
    public func contents(of entry: ZipEntry, using decoder: inout ZipDecoder, _ body: (RawSpan) throws -> Void) throws {
        guard !entry.isEncrypted else { throw ZipError.encryptedEntry(entry.path) }
        let archive = file.bytes
        let payload = try Self.payload(of: entry, in: archive)

        // Closure literals (not a local func passed as a value), so `crc` and `written` stay on the
        // stack instead of being boxed on the heap: measured 2 mallocs per entry before this.
        var crc: UInt = 0
        var written: UInt64 = 0
        switch entry.method {
        case Method.stored:
            crc = crc32(0, payload)
            written = UInt64(payload.byteCount)
            try body(payload)
        case Method.deflated:
            try decoder.inflate(payload, path: entry.path) { chunk in
                crc = crc32(crc, chunk)
                written += UInt64(chunk.byteCount)
                try body(chunk)
            }
        default:
            throw ZipError.unsupportedMethod(entry.method, entry.path)
        }

        guard written == entry.uncompressedSize else {
            throw entry.method == Method.deflated
                ? ZipError.corruptData(entry.path)
                : ZipError.sizeMismatch(entry.path, expected: entry.uncompressedSize, actual: written)
        }
        guard crc == UInt(entry.crc32) else {
            throw ZipError.crcMismatch(entry.path, expected: entry.crc32, actual: UInt32(truncatingIfNeeded: crc))
        }
    }

    /// Convenience that uses a temporary decoder. Prefer ``contents(of:using:_:)`` in loops.
    @inlinable
    public func contents(of entry: ZipEntry, _ body: (RawSpan) throws -> Void) throws {
        var decoder = ZipDecoder()
        try contents(of: entry, using: &decoder, body)
    }

    /// Like ``contents(of:using:_:)``, but `consume` runs in a child task, concurrently with decoding the
    /// next chunk. Chunks are consumed one at a time, in order. Only worth it for large deflated entries.
    func contentsPipelined(
        of entry: ZipEntry,
        using decoder: inout ZipDecoder,
        consume: @escaping @Sendable (ZipDecoder.Chunk) throws -> Void
    ) async throws {
        guard !entry.isEncrypted else { throw ZipError.encryptedEntry(entry.path) }
        guard entry.method == Method.deflated else { throw ZipError.unsupportedMethod(entry.method, entry.path) }
        let archive = file.bytes
        guard let range = archive.byteOffsets(of: try Self.payload(of: entry, in: archive)) else {
            throw ZipError.truncated("payload for '\(entry.path)'")
        }

        var crc: UInt = 0
        var written: UInt64 = 0
        // The mapping outlives this call (`self` holds it), so its address is stable across suspensions.
        try await unsafe decoder.inflatePipelined(file.stableBuffer(range), path: entry.path, observe: { chunk in
            crc = crc32(crc, chunk)
            written += UInt64(chunk.byteCount)
        }, consume: consume)

        guard written == entry.uncompressedSize else { throw ZipError.corruptData(entry.path) }
        guard crc == UInt(entry.crc32) else {
            throw ZipError.crcMismatch(entry.path, expected: entry.crc32, actual: UInt32(truncatingIfNeeded: crc))
        }
    }

    /// The entry's full decompressed contents.
    public func contents(of entry: ZipEntry) throws -> Data {
        var result = Data(capacity: Int(min(entry.uncompressedSize, 1 << 30)))
        try contents(of: entry) { chunk in
            chunk.withUnsafeBytes { unsafe result.append(contentsOf: $0) }
        }
        return result
    }

    /// Walks the entry's local file header to its payload and returns the payload's span.
    @usableFromInline
    @_lifetime(copy archive)
    static func payload(of entry: ZipEntry, in archive: RawSpan) throws(ZipError) -> RawSpan {
        var header = try ByteReader(archive, at: Int(clamping: entry.localHeaderOffset))
        try header.expect(Signature.localFile, "local file header for '\(entry.path)'")
        try header.skip(2 + 2 + 2 + 2 + 2 + 4 + 4 + 4) // version, flags, method, time, date, CRC, sizes
        // The local name/extra lengths can differ from the central directory's, so use these.
        let nameLength = Int(try header.read(UInt16.self))
        let extraLength = Int(try header.read(UInt16.self))
        try header.skip(nameLength + extraLength)
        return try header.read(count: Int(clamping: entry.compressedSize))
    }
}
