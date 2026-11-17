import Bytes
import BytesMacros

// ELF headers: swift-binary-parsing's ELFParser example (`ExampleELF`), ported to `Bytes`. It reads the file
// header, then the program and section header tables, into the example's own types, so both sides build the same
// result (two arrays, reserved to their counts) and only the parsing differs.
//
// - The 16 identification bytes, the same in every ELF file, are a `@BinaryRecord` of `@BitFields`: class, byte
//   order, version, and OS ABI by name, each enum checked as it's read.
// - Everything after them is in the byte order the identification names. That's decided once: the parser is
//   generic over the cursor's byte order (`LittleEndianBytesReader` or `BigEndianBytesReader`), so each order
//   compiles to its own code, with no test per field. (The example passes an `Endianness` value to every read.)
//   `@BinaryRecord` fixes its byte order when it's declared, so these headers are read by hand.
// - Each header (or the part of one that doesn't depend on the class) is a fixed-size section, so its fields'
//   bounds checks fold to one per section.
//
// Every value is read once.

/// The 4 identification bytes after the magic: the class, byte order, version, and OS ABI.
@BitFields(UInt32.self, .bigEndian)
struct ELFIdentity {
    @Field(bits: 24...31) var fileClass: ExampleELF.Header.Class
    @Field(bits: 16...23) var byteOrder: ExampleELF.Header.Endian
    @Field(bits: 8...15) var version: UInt8
    @Field(bits: 0...7) var osABI: ExampleELF.Header.OSABI
}

/// The identification's last 8 bytes: the ABI version, then 7 bytes of padding (not checked, as in the example).
@BitFields(UInt64.self, .bigEndian)
struct ELFABIVersion {
    @Field(bits: 56...63) var version: UInt8
}

/// `e_ident`: the 16 bytes every ELF file starts with, in either byte order (they're single bytes).
@BinaryRecord(.bigEndian)
struct ELFIdentification {
    @Field(Byte4.self, expecting: 0x7F45_4C46) var magic: UInt32 // "\x7FELF"
    var identity: ELFIdentity
    var abi: ELFABIVersion
}

public enum ELF {
    /// Parses an ELF file's headers with `Bytes`, as the example does.
    ///
    /// - Parameter data: The file.
    /// - Returns: The header, program headers, and section headers, as the example's types.
    /// - Throws: `BytesError.mismatch` for a bad magic, version, or header size; `BytesError.invalidValue` for
    ///   an unknown class, byte order, OS ABI, file type, segment type, or section type;
    ///   `BytesError.insufficientData` if a header or table is cut short or a table's offset is past the end.
    public static func parseWithBytes(_ data: RawSpan) throws(BytesError) -> ExampleELF {
        var reader = AlignedBytesReader(data)
        let identification = try reader.read(ELFIdentification.self)
        return switch identification.identity.byteOrder {
        case .little: try parse(data, identification, LittleEndianBytes.self)
        case .big: try parse(data, identification, BigEndianBytes.self)
        }
    }

    /// The parser after the identification, in one byte order: specialized for each.
    static func parse<Mode: ByteOrderedCursorMode>(
        _ data: RawSpan, _ identification: ELFIdentification, _: Mode.Type
    ) throws(BytesError) -> ExampleELF {
        var reader = try GenericBytesReader<Mode>(data, atByteOffset: ELFIdentification.byteCount)
        let identity = identification.identity
        let fileClass = identity.fileClass
        let is64 = fileClass == .class64Bit
        // The example checks the identification's version only for 32-bit files.
        guard is64 || identity.version == 1 else { throw .mismatch }

        var start = try reader.readSection(byteCount: 8)
        let fileType = try start.read(ExampleELF.Header.FileType.self, as: Byte2.self)
        let instructionSet = ExampleELF.Header.ISA(rawValue: try start.read(UInt16.self))
        try start.expect(1 as UInt32) // e_version

        // The entry point and the two tables' offsets: 4 or 8 bytes each.
        let entryPoint: UInt64, programHeaderTable: UInt64, sectionHeaderTable: UInt64
        if is64 {
            var addresses = try reader.readSection(byteCount: 24)
            entryPoint = try addresses.read(UInt64.self)
            programHeaderTable = try addresses.read(UInt64.self)
            sectionHeaderTable = try addresses.read(UInt64.self)
        } else {
            var addresses = try reader.readSection(byteCount: 12)
            entryPoint = UInt64(try addresses.read(UInt32.self))
            programHeaderTable = UInt64(try addresses.read(UInt32.self))
            sectionHeaderTable = UInt64(try addresses.read(UInt32.self))
        }

        var end = try reader.readSection(byteCount: 16)
        let architectureFlags = try end.read(UInt32.self)
        try end.expect(fileClass.headerSize)
        try end.expect(fileClass.programHeaderEntrySize)
        let programHeaderCount = try end.read(UInt16.self)
        try end.expect(fileClass.sectionHeaderEntrySize)
        let sectionHeaderCount = try end.read(UInt16.self)
        let sectionNameIndex = try end.read(UInt16.self)

        let header = ExampleELF.Header(
            class: fileClass, endian: identity.byteOrder, version: identity.version, osABI: identity.osABI,
            abiVersion: identification.abi.version, fileType: fileType, instructionSet: instructionSet,
            entryPoint: entryPoint, programHeaderTable: programHeaderTable, sectionHeaderTable: sectionHeaderTable,
            architectureFlags: architectureFlags, programHeaderEntryCount: programHeaderCount,
            sectionHeaderEntryCount: sectionHeaderCount, sectionNameIndex: sectionNameIndex
        )

        // Each table: seek to it (as the example does, even when it's empty), then an entry per fixed-size section.
        try reader.seek(toByteOffset: offset(programHeaderTable))
        var programHeaders: [ExampleELF.ProgramHeader] = []
        programHeaders.reserveCapacity(Int(programHeaderCount))
        if is64 {
            for _ in 0..<programHeaderCount { try programHeaders.append(programHeader64(&reader)) }
        } else {
            for _ in 0..<programHeaderCount { try programHeaders.append(programHeader32(&reader)) }
        }

        try reader.seek(toByteOffset: offset(sectionHeaderTable))
        var sectionHeaders: [ExampleELF.SectionHeader] = []
        sectionHeaders.reserveCapacity(Int(sectionHeaderCount))
        if is64 {
            for _ in 0..<sectionHeaderCount { try sectionHeaders.append(sectionHeader64(&reader)) }
        } else {
            for _ in 0..<sectionHeaderCount { try sectionHeaders.append(sectionHeader32(&reader)) }
        }

        return ExampleELF(header: header, programHeaders: programHeaders, sectionHeaders: sectionHeaders)
    }

    /// A file offset from the data as an `Int`.
    @inline(__always)
    static func offset(_ value: UInt64) throws(BytesError) -> Int {
        guard let offset = Int(exactly: value) else { throw .insufficientData }
        return offset
    }

    @inline(__always)
    static func programHeader64<Mode: ByteOrderedCursorMode>(
        _ reader: inout GenericBytesReader<Mode>
    ) throws(BytesError) -> ExampleELF.ProgramHeader {
        var entry = try reader.readSection(byteCount: 0x38)
        // Arguments are evaluated in order: the fields as they're stored.
        return try ExampleELF.ProgramHeader(
            type: entry.read(ExampleELF.ProgramHeader.SegmentType.self, as: Byte4.self),
            flags: ExampleELF.ProgramHeader.Flags(rawValue: entry.read(UInt32.self)),
            offset: entry.read(UInt64.self),
            virtualAddress: entry.read(UInt64.self),
            physicalAddress: entry.read(UInt64.self),
            fileSize: entry.read(UInt64.self),
            memorySize: entry.read(UInt64.self),
            alignment: entry.read(UInt64.self)
        )
    }

    @inline(__always)
    static func programHeader32<Mode: ByteOrderedCursorMode>(
        _ reader: inout GenericBytesReader<Mode>
    ) throws(BytesError) -> ExampleELF.ProgramHeader {
        var entry = try reader.readSection(byteCount: 0x20)
        let type = try entry.read(ExampleELF.ProgramHeader.SegmentType.self, as: Byte4.self)
        let offset = UInt64(try entry.read(UInt32.self))
        let virtualAddress = UInt64(try entry.read(UInt32.self))
        let physicalAddress = UInt64(try entry.read(UInt32.self))
        let fileSize = UInt64(try entry.read(UInt32.self))
        let memorySize = UInt64(try entry.read(UInt32.self))
        let flags = ExampleELF.ProgramHeader.Flags(rawValue: try entry.read(UInt32.self)) // after the sizes in 32-bit files
        let alignment = UInt64(try entry.read(UInt32.self))
        return ExampleELF.ProgramHeader(
            type: type, flags: flags, offset: offset, virtualAddress: virtualAddress, physicalAddress: physicalAddress,
            fileSize: fileSize, memorySize: memorySize, alignment: alignment
        )
    }

    @inline(__always)
    static func sectionHeader64<Mode: ByteOrderedCursorMode>(
        _ reader: inout GenericBytesReader<Mode>
    ) throws(BytesError) -> ExampleELF.SectionHeader {
        var entry = try reader.readSection(byteCount: 0x40)
        return try ExampleELF.SectionHeader(
            nameOffset: entry.read(UInt32.self),
            type: entry.read(ExampleELF.SectionHeader.HeaderType.self, as: Byte4.self),
            flags: ExampleELF.SectionHeader.Flags(rawValue: entry.read(UInt64.self)),
            virtualAddress: entry.read(UInt64.self),
            offset: entry.read(UInt64.self),
            size: entry.read(UInt64.self),
            associatedSectionIndex: entry.read(UInt32.self),
            infoSectionIndex: entry.read(UInt32.self),
            alignment: entry.read(UInt64.self),
            entrySize: entry.read(UInt64.self)
        )
    }

    @inline(__always)
    static func sectionHeader32<Mode: ByteOrderedCursorMode>(
        _ reader: inout GenericBytesReader<Mode>
    ) throws(BytesError) -> ExampleELF.SectionHeader {
        var entry = try reader.readSection(byteCount: 0x28)
        return try ExampleELF.SectionHeader(
            nameOffset: entry.read(UInt32.self),
            type: entry.read(ExampleELF.SectionHeader.HeaderType.self, as: Byte4.self),
            flags: ExampleELF.SectionHeader.Flags(rawValue: entry.read(UInt64.self, as: Byte4.self)),
            virtualAddress: entry.read(UInt64.self, as: Byte4.self),
            offset: entry.read(UInt64.self, as: Byte4.self),
            size: entry.read(UInt64.self, as: Byte4.self),
            associatedSectionIndex: entry.read(UInt32.self),
            infoSectionIndex: entry.read(UInt32.self),
            alignment: entry.read(UInt64.self, as: Byte4.self),
            entrySize: entry.read(UInt64.self, as: Byte4.self)
        )
    }

    /// The name of the section at `index`, from the section-name string table: the example's
    /// `sectionName(at:data:)` with `Bytes`.
    ///
    /// - Parameters:
    ///   - index: The section's index.
    ///   - elf: The parsed headers.
    ///   - data: The file.
    /// - Returns: The name, or `nil` if the section, the string table, or the name's NUL isn't there.
    public static func sectionName(at index: Int, of elf: ExampleELF, in data: RawSpan) -> String? {
        let namesIndex = Int(elf.header.sectionNameIndex)
        guard elf.sectionHeaders.indices.contains(index), elf.sectionHeaders.indices.contains(namesIndex) else { return nil }
        let names = elf.sectionHeaders[namesIndex]
        guard names.type == .stringTable, let namesOffset = Int(exactly: names.offset) else { return nil }
        do throws(BytesError) {
            // The name runs to the first NUL from its offset, not bounded by the table: as in the example.
            var reader = try AlignedBytesReader(data, atByteOffset: namesOffset)
            try reader.skip(byteCount: Int(elf.sectionHeaders[index].nameOffset))
            return String(copying: try reader.readNulTerminatedUTF8())
        } catch {
            return nil
        }
    }
}
