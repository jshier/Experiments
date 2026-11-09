internal import Bytes
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

    // Bit 0. (A mask, not `Bytes`' `flags[bit: 0]`: `Bytes` is imported `internal`, so inlinable public code
    // can't use it.)
    @inlinable public var isEncrypted: Bool { flags & 0x1 != 0 }
}

// MARK: - Archive

public struct ZipArchive: Sendable {
    /// Record signatures, in file order. Computed, so each use folds to a 32-bit constant.
    enum Signature {
        static var localFile: Byte4 { 0x50_4B_03_04 }
        static var centralDirectory: Byte4 { 0x50_4B_01_02 }
        static var endOfCentralDirectory: Byte4 { 0x50_4B_05_06 }
        static var zip64EndOfCentralDirectory: Byte4 { 0x50_4B_06_06 }
        static var zip64Locator: Byte4 { 0x50_4B_06_07 }
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

        var isSaturated: Bool { entryCount == UInt16.max || size == UInt32.max || offset == UInt32.max }
    }

    private static func readEntries(_ archive: RawSpan) throws(ZipError) -> [ZipEntry] {
        let location = try readCentralDirectoryLocation(archive)
        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(min(location.entryCount, 1 << 20)))
        do throws(BytesError) {
            var reader = BytesReader(archive)
            try reader.seek(toByteOffset: Int(clamping: location.offset))
            var directory = try reader.readSection(byteCount: Int(clamping: location.size))
            for _ in 0..<location.entryCount {
                try entries.append(readCentralDirectoryEntry(&directory))
            }
        } catch {
            throw error.zipError("central directory entry \(entries.count)")
        }
        return entries
    }

    private static func readCentralDirectoryLocation(_ archive: RawSpan) throws(ZipError) -> CentralDirectoryLocation {
        let eocdOffset = try findEndOfCentralDirectory(archive)
        var location: CentralDirectoryLocation
        var spansDisks = false
        do throws(BytesError) {
            var eocd = BytesReader(archive)
            try eocd.seek(toByteOffset: eocdOffset)
            var record = try eocd.readSection(byteCount: 22)
            try record.expect(Signature.endOfCentralDirectory)
            let diskNumber = try record.read(Byte2.self, .littleEndian)
            let directoryDisk = try record.read(Byte2.self, .littleEndian)
            try record.skip(byteCount: 2) // entries on this disk
            location = try CentralDirectoryLocation(
                entryCount: UInt64(record.read(Byte2.self, .littleEndian)),
                size: UInt64(record.read(Byte4.self, .littleEndian)),
                offset: UInt64(record.read(Byte4.self, .littleEndian))
            )

            // ZIP64: saturated fields mean the real values live in the ZIP64 EOCD record, which a
            // fixed-size locator immediately before the classic EOCD points to.
            if location.isSaturated, eocdOffset >= 20 {
                var locator = BytesReader(archive)
                try locator.seek(toByteOffset: eocdOffset - 20)
                if try locator.read(Byte4.self) == Signature.zip64Locator {
                    try locator.skip(byteCount: 4) // disk containing the ZIP64 EOCD
                    var zip64 = BytesReader(archive)
                    try zip64.seek(toByteOffset: Int(clamping: locator.read(Byte8.self, .littleEndian)))
                    try zip64.expect(Signature.zip64EndOfCentralDirectory)
                    try zip64.skip(byteCount: 8 + 2 + 2 + 4 + 4 + 8) // record size, versions, disks, entries on disk
                    location.entryCount = try zip64.read(Byte8.self, .littleEndian)
                    location.size = try zip64.read(Byte8.self, .littleEndian)
                    location.offset = try zip64.read(Byte8.self, .littleEndian)
                    return location
                }
            }
            spansDisks = diskNumber != 0 || directoryDisk != 0
        } catch {
            throw error.zipError("end of central directory")
        }
        guard !spansDisks else { throw .multiDiskUnsupported }
        return location
    }

    private static func findEndOfCentralDirectory(_ archive: RawSpan) throws(ZipError) -> Int {
        // The EOCD is 22 bytes plus a comment of up to 65,535 bytes, so it starts in that window before the
        // end. Search it backwards (16 offsets per SIMD step) for the last signature.
        let minimum = 22
        guard archive.byteCount >= minimum else { throw .notAZipArchive }
        let last = archive.byteCount - minimum
        let first = max(0, last - 0xFFFF)
        let window = BytesReader(archive.extracting(first..<last + 4))
        guard let offset = window.lastByteOffset(of: Signature.endOfCentralDirectory) else { throw .notAZipArchive }
        return first + offset
    }

    @_lifetime(directory: copy directory)
    private static func readCentralDirectoryEntry(_ directory: inout BytesReader) throws(BytesError) -> ZipEntry {
        // The fixed part as its own cursor: its length is a constant, so every field read is proven in bounds.
        var header = try directory.readSection(byteCount: 46)
        try header.expect(Signature.centralDirectory)
        let versionMadeBy = try header.read(Byte2.self, .littleEndian)
        try header.skip(byteCount: 2) // version needed to extract
        let flags = try header.read(Byte2.self, .littleEndian)
        let method = try header.read(Byte2.self, .littleEndian)
        let dosTime = try header.read(Byte2.self, .littleEndian)
        let dosDate = try header.read(Byte2.self, .littleEndian)
        let crc = try header.read(Byte4.self, .littleEndian)
        var compressedSize = try UInt64(header.read(Byte4.self, .littleEndian))
        var uncompressedSize = try UInt64(header.read(Byte4.self, .littleEndian))
        let nameLength = try Int(header.read(Byte2.self, .littleEndian))
        let extraLength = try Int(header.read(Byte2.self, .littleEndian))
        let commentLength = try Int(header.read(Byte2.self, .littleEndian))
        try header.skip(byteCount: 2 + 2) // disk number start, internal attributes
        let externalAttributes = try header.read(Byte4.self, .littleEndian)
        var localHeaderOffset = try UInt64(header.read(Byte4.self, .littleEndian))

        let name = try decodeName(Span(viewing: directory.read(byteCount: nameLength)))
        var extra = try directory.readSection(byteCount: extraLength)
        try directory.skip(byteCount: commentLength)

        var unixModificationTime: Date?
        while extra.remainingByteCount >= 4 {
            let id = try extra.read(Byte2.self, .littleEndian)
            let size = try Int(extra.read(Byte2.self, .littleEndian))
            // Tolerate malformed trailing padding. (Not `read(sectionPrefixedBy:)`, which would throw here:
            // with `try?` it measured 0.7% more instructions for the whole parse.)
            guard size <= extra.remainingByteCount else { break }
            var field = try extra.readSection(byteCount: size)
            switch id {
            case 0x0001: // ZIP64 extended information: only the saturated fields are present, in this order.
                if uncompressedSize == UInt32.max { uncompressedSize = try field.read(Byte8.self, .littleEndian) }
                if compressedSize == UInt32.max { compressedSize = try field.read(Byte8.self, .littleEndian) }
                if localHeaderOffset == UInt32.max { localHeaderOffset = try field.read(Byte8.self, .littleEndian) }
            case 0x5455: // Extended timestamp: a flags byte, then a UTC mtime if bit 0 is set.
                if size >= 5, try field.read(Byte.self)[bit: 0] {
                    let seconds = try Int32(bitPattern: field.read(Byte4.self, .littleEndian))
                    unixModificationTime = Date(timeIntervalSince1970: TimeInterval(seconds))
                }
            default:
                break
            }
        }

        return makeEntry(
            name: name,
            versionMadeBy: versionMadeBy,
            flags: flags,
            method: method,
            crc: crc,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            externalAttributes: externalAttributes,
            localHeaderOffset: localHeaderOffset,
            modificationDate: unixModificationTime ?? date(dosDate: dosDate, dosTime: dosTime)
        )
    }

    /// Builds an entry from central directory fields, deriving its kind and permissions.
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
        modificationDate: Date?
    ) -> ZipEntry {
        // The high byte of "version made by" is the host OS; 3 is Unix, whose st_mode is the high 16 bits.
        let mode = versionMadeBy[Byte.self, at: 8] == 3 ? Int(externalAttributes[bits: 16..<32]) : 0
        let fileType = mode & Int(S_IFMT)
        // Bit 4 of the low (MS-DOS) attributes: a directory.
        let kind: ZipEntry.Kind = if name.hasSuffix("/") || fileType == Int(S_IFDIR) || externalAttributes[bit: 4] {
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
            modificationDate: modificationDate
        )
    }

    /// Flag bit 11 means UTF-8; otherwise the spec says IBM code page 437. In practice many tools (Info-ZIP,
    /// ditto) write UTF-8 without setting the flag, so prefer UTF-8 whenever it validates.
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

    static func date(dosDate: UInt16, dosTime: UInt16) -> Date? {
        var components = DateComponents()
        components.year = 1980 + Int(dosDate[Bits<7>.self, at: 9])
        components.month = Int(dosDate[Nibble.self, at: 5])
        components.day = Int(dosDate[Bits<5>.self, at: 0])
        components.hour = Int(dosTime[Bits<5>.self, at: 11])
        components.minute = Int(dosTime[Bits<6>.self, at: 5])
        components.second = Int(dosTime[Bits<5>.self, at: 0]) * 2
        // DOS timestamps have no time zone; by convention they're local time.
        return Calendar.current.date(from: components)
    }
}

// MARK: - Entry contents

public extension ZipArchive {
    /// Calls `body` with successive chunks of the entry's decompressed contents, verifying size and CRC-32.
    ///
    /// The spans borrow `decoder`'s buffer (or, for stored entries, the mapped archive), so nothing is
    /// copied or allocated. Reuse one decoder across calls on the same thread.
    @inlinable
    func contents(of entry: ZipEntry, using decoder: inout ZipDecoder, _ body: (RawSpan) throws -> Void) throws {
        guard !entry.isEncrypted else { throw ZipError.encryptedEntry(entry.path) }
        let archive = file.bytes
        let payload = try Self.payload(of: entry, in: archive)

        // Closure literals (not a local func passed as a value), so `crc` and `written` stay on the
        // stack instead of being boxed on the heap: measured 2 mallocs per entry before this. The CRC is the
        // backend's own (`Bytes`' or zlib's), so each backend is measured whole.
        let backend = decoder.backend
        var crc: UInt = 0
        var written: UInt64 = 0
        switch entry.method {
        case Method.stored:
            crc = ZipDecoder.crc32(0, payload, backend: backend)
            written = UInt64(payload.byteCount)
            try body(payload)
        case Method.deflated:
            try decoder.inflate(payload, path: entry.path) { chunk in
                crc = ZipDecoder.crc32(crc, chunk, backend: backend)
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
    func contents(of entry: ZipEntry, backend: ZipDecoder.Backend = .bytes, _ body: (RawSpan) throws -> Void) throws {
        var decoder = ZipDecoder(backend: backend)
        try contents(of: entry, using: &decoder, body)
    }

    /// Like ``contents(of:using:_:)``, but `consume` runs in a child task, concurrently with decoding the
    /// next chunk. Chunks are consumed one at a time, in order. Only worth it for large deflated entries.
    internal func contentsPipelined(
        of entry: ZipEntry,
        using decoder: inout ZipDecoder,
        consume: @escaping @Sendable (ZipDecoder.Chunk) throws -> Void
    ) async throws {
        guard !entry.isEncrypted else { throw ZipError.encryptedEntry(entry.path) }
        guard entry.method == Method.deflated else { throw ZipError.unsupportedMethod(entry.method, entry.path) }
        let archive = file.bytes
        guard let range = try archive.byteOffsets(of: Self.payload(of: entry, in: archive)) else {
            throw ZipError.truncated("payload for '\(entry.path)'")
        }

        var crc: UInt = 0
        var written: UInt64 = 0
        let backend = decoder.backend
        // The mapping outlives this call (`self` holds it), so its address is stable across suspensions.
        try await unsafe decoder.inflatePipelined(file.stableBuffer(range), path: entry.path, observe: { chunk in
            crc = ZipDecoder.crc32(crc, chunk, backend: backend)
            written += UInt64(chunk.byteCount)
        }, consume: consume)

        guard written == entry.uncompressedSize else { throw ZipError.corruptData(entry.path) }
        guard crc == UInt(entry.crc32) else {
            throw ZipError.crcMismatch(entry.path, expected: entry.crc32, actual: UInt32(truncatingIfNeeded: crc))
        }
    }

    /// The entry's full decompressed contents.
    func contents(of entry: ZipEntry, backend: ZipDecoder.Backend = .bytes) throws -> Data {
        var result = Data(capacity: Int(min(entry.uncompressedSize, 1 << 30)))
        try contents(of: entry, backend: backend) { chunk in
            // Unsafe: `Data` has no `RawSpan` append. Safe: the buffer is only read, within the closure.
            chunk.withUnsafeBytes { unsafe result.append(contentsOf: $0) }
        }
        return result
    }

    /// Walks the entry's local file header to its payload and returns the payload's span.
    @usableFromInline
    @_lifetime(copy archive)
    internal static func payload(of entry: ZipEntry, in archive: RawSpan) throws(ZipError) -> RawSpan {
        do throws(BytesError) {
            var reader = BytesReader(archive)
            try reader.seek(toByteOffset: Int(clamping: entry.localHeaderOffset))
            var header = try reader.readSection(byteCount: 30)
            try header.expect(Signature.localFile)
            try header.skip(byteCount: 2 + 2 + 2 + 2 + 2 + 4 + 4 + 4) // version, flags, method, time, date, CRC, sizes
            // The local name/extra lengths can differ from the central directory's, so use these.
            let nameLength = try Int(header.read(Byte2.self, .littleEndian))
            let extraLength = try Int(header.read(Byte2.self, .littleEndian))
            try reader.skip(byteCount: nameLength + extraLength)
            return try reader.read(byteCount: Int(clamping: entry.compressedSize))
        } catch {
            throw error.zipError("local file header for '\(entry.path)'")
        }
    }
}

extension BytesError {
    /// The archive error for failing to read `what`.
    func zipError(_ what: String) -> ZipError {
        switch self {
        case .insufficientData: .truncated(what)
        case .mismatch: .badSignature(what)
        // The parser doesn't use typed views, writing, or raw-value fields, which throw these.
        case .misaligned, .insufficientCapacity, .invalidValue, .trailingData: .corruptData(what)
        }
    }
}
