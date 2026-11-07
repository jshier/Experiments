import Foundation

// The original central directory parser, built on `ByteReader`, kept only so the benchmarks can compare
// it with the `Bytes`-based parser in ZipArchive.swift. Not used by the archive itself.

extension ZipArchive {
    /// Parses `url`'s central directory with the original `ByteReader` parser.
    @_spi(Benchmarking)
    public static func entriesUsingByteReader(of url: URL) throws -> [ZipEntry] {
        let file = try MappedFile(path: .init(url.path(percentEncoded: false)))
        return try ByteReaderParsing.readEntries(file.bytes)
    }

    /// Finds `entry`'s payload with the original `ByteReader` parser, returning its byte count.
    @_spi(Benchmarking)
    public func payloadCountUsingByteReader(of entry: ZipEntry) throws -> Int {
        try ByteReaderParsing.payload(of: entry, in: file.bytes).byteCount
    }

    /// Finds `entry`'s payload with the `Bytes`-based parser, returning its byte count.
    @_spi(Benchmarking)
    public func payloadCount(of entry: ZipEntry) throws -> Int {
        try Self.payload(of: entry, in: file.bytes).byteCount
    }
}

enum ByteReaderParsing {
    enum Signature {
        static let localFile: UInt32 = 0x0403_4B50
        static let centralDirectory: UInt32 = 0x0201_4B50
        static let endOfCentralDirectory: UInt32 = 0x0605_4B50
        static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4B50
        static let zip64Locator: UInt32 = 0x0706_4B50
    }

    private struct CentralDirectoryLocation {
        var entryCount: UInt64
        var size: UInt64
        var offset: UInt64

        var isSaturated: Bool { entryCount == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF }
    }

    static func readEntries(_ archive: RawSpan) throws(ZipError) -> [ZipEntry] {
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
        let name = ZipArchive.decodeName(Span(viewing: try directory.read(count: nameLength)))
        var extra = ByteReader(try directory.read(count: extraLength))
        try directory.skip(commentLength)

        var unixModificationTime: Date?
        while extra.count >= 4 {
            let id: UInt16 = try extra.read()
            let size = Int(try extra.read(UInt16.self))
            guard size <= extra.count else { break }
            var field = ByteReader(try extra.read(count: size))
            switch id {
            case 0x0001:
                if uncompressedSize == 0xFFFF_FFFF { uncompressedSize = try field.read() }
                if compressedSize == 0xFFFF_FFFF { compressedSize = try field.read() }
                if localHeaderOffset == 0xFFFF_FFFF { localHeaderOffset = try field.read() }
            case 0x5455:
                if size >= 5, try field.read(UInt8.self) & 0x1 != 0 {
                    unixModificationTime = Date(timeIntervalSince1970: TimeInterval(try field.read(Int32.self)))
                }
            default:
                break
            }
        }

        return ZipArchive.makeEntry(
            name: name,
            versionMadeBy: versionMadeBy,
            flags: flags,
            method: method,
            crc: crc,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            externalAttributes: externalAttributes,
            localHeaderOffset: localHeaderOffset,
            modificationDate: unixModificationTime ?? ZipArchive.date(dosDate: dosDate, dosTime: dosTime)
        )
    }

    @_lifetime(copy archive)
    static func payload(of entry: ZipEntry, in archive: RawSpan) throws(ZipError) -> RawSpan {
        var header = try ByteReader(archive, at: Int(clamping: entry.localHeaderOffset))
        try header.expect(Signature.localFile, "local file header for '\(entry.path)'")
        try header.skip(2 + 2 + 2 + 2 + 2 + 4 + 4 + 4)
        let nameLength = Int(try header.read(UInt16.self))
        let extraLength = Int(try header.read(UInt16.self))
        try header.skip(nameLength + extraLength)
        return try header.read(count: Int(clamping: entry.compressedSize))
    }
}
