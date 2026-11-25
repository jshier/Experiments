import Bytes
import BytesMacros

// ELF headers: swift-binary-parsing's ELFParser example (`ExampleELF`), ported to `Bytes`. It reads the file
// header, then the program and section header tables, into the example's own types, so both sides build the same
// result (two arrays, reserved to their counts) and only the parsing differs.
//
// - The 16 identification bytes, the same in every ELF file, are a `@BinaryRecord` of single bytes: class, byte
//   order, version, and OS ABI by name, each enum checked as it's read, then 7 bytes of padding.
// - Everything after them is in the byte order the identification names. That's decided once: the parser is
//   generic over the cursor's byte order (`LittleEndianBytesReader` or `BigEndianBytesReader`), so each order
//   compiles to its own code, with no test per field. (The example passes an `Endianness` value to every read.)
//   The headers are `@BinaryRecord`s without a byte order, which read in the cursor's.
// - Each header (or the part of one that doesn't depend on the class) is a fixed-size record, so its fields'
//   bounds checks fold to one per record.
//
// Every value is read once.

/// `e_ident`: the 16 bytes every ELF file starts with, in either byte order (they're single bytes).
@BinaryRecord(.bigEndian)
struct ELFIdentification {
    @Field(Byte4.self, expecting: 0x7F45_4C46) var magic: UInt32 // "\x7FELF"
    @Field(Byte.self) var fileClass: ExampleELF.Header.Class
    @Field(Byte.self) var byteOrder: ExampleELF.Header.Endian
    @Field(Byte.self) var version: UInt8
    @Field(Byte.self) var osABI: ExampleELF.Header.OSABI
    @Field(Byte.self) var abiVersion: UInt8
    var padding: Padding<Byte7> // Not checked, as in the example.
}

/// The file header after the identification, up to the entry point: the same in both classes.
@BinaryRecord
struct ELFHeaderStart {
    @Field(Byte2.self) var fileType: ExampleELF.Header.FileType
    @Field(Byte2.self) var instructionSet: UInt16
    @Field(Byte4.self, expecting: 1) var version: UInt32 // e_version
}

/// The entry point and the two tables' offsets, in a 64-bit file.
@BinaryRecord
struct ELFAddresses64 {
    @Field(Byte8.self) var entryPoint: UInt64
    @Field(Byte8.self) var programHeaderTable: UInt64
    @Field(Byte8.self) var sectionHeaderTable: UInt64
}

/// The entry point and the two tables' offsets, in a 32-bit file.
@BinaryRecord
struct ELFAddresses32 {
    @Field(Byte4.self) var entryPoint: UInt64
    @Field(Byte4.self) var programHeaderTable: UInt64
    @Field(Byte4.self) var sectionHeaderTable: UInt64
}

/// The file header's last 16 bytes: flags, sizes, and counts.
@BinaryRecord
struct ELFHeaderEnd {
    @Field(Byte4.self) var architectureFlags: UInt32
    @Field(Byte2.self) var headerSize: UInt16
    @Field(Byte2.self) var programHeaderEntrySize: UInt16
    @Field(Byte2.self) var programHeaderCount: UInt16
    @Field(Byte2.self) var sectionHeaderEntrySize: UInt16
    @Field(Byte2.self) var sectionHeaderCount: UInt16
    @Field(Byte2.self) var sectionNameIndex: UInt16
}

/// A 64-bit program header (`Elf64_Phdr`).
@BinaryRecord
struct ELFProgramHeader64 {
    @Field(Byte4.self) var type: ExampleELF.ProgramHeader.SegmentType
    @Field(Byte4.self) var flags: ExampleELF.ProgramHeader.Flags
    @Field(Byte8.self) var offset: UInt64
    @Field(Byte8.self) var virtualAddress: UInt64
    @Field(Byte8.self) var physicalAddress: UInt64
    @Field(Byte8.self) var fileSize: UInt64
    @Field(Byte8.self) var memorySize: UInt64
    @Field(Byte8.self) var alignment: UInt64

    @inline(__always)
    var programHeader: ExampleELF.ProgramHeader {
        ExampleELF.ProgramHeader(
            type: type, flags: flags, offset: offset, virtualAddress: virtualAddress, physicalAddress: physicalAddress,
            fileSize: fileSize, memorySize: memorySize, alignment: alignment
        )
    }
}

/// A 32-bit program header (`Elf32_Phdr`): 4-byte fields, and the flags after the sizes.
@BinaryRecord
struct ELFProgramHeader32 {
    @Field(Byte4.self) var type: ExampleELF.ProgramHeader.SegmentType
    @Field(Byte4.self) var offset: UInt64
    @Field(Byte4.self) var virtualAddress: UInt64
    @Field(Byte4.self) var physicalAddress: UInt64
    @Field(Byte4.self) var fileSize: UInt64
    @Field(Byte4.self) var memorySize: UInt64
    @Field(Byte4.self) var flags: ExampleELF.ProgramHeader.Flags
    @Field(Byte4.self) var alignment: UInt64

    @inline(__always)
    var programHeader: ExampleELF.ProgramHeader {
        ExampleELF.ProgramHeader(
            type: type, flags: flags, offset: offset, virtualAddress: virtualAddress, physicalAddress: physicalAddress,
            fileSize: fileSize, memorySize: memorySize, alignment: alignment
        )
    }
}

/// A 64-bit section header (`Elf64_Shdr`).
@BinaryRecord
struct ELFSectionHeader64 {
    @Field(Byte4.self) var nameOffset: UInt32
    @Field(Byte4.self) var type: ExampleELF.SectionHeader.HeaderType
    @Field(Byte8.self) var flags: ExampleELF.SectionHeader.Flags
    @Field(Byte8.self) var virtualAddress: UInt64
    @Field(Byte8.self) var offset: UInt64
    @Field(Byte8.self) var size: UInt64
    @Field(Byte4.self) var associatedSectionIndex: UInt32
    @Field(Byte4.self) var infoSectionIndex: UInt32
    @Field(Byte8.self) var alignment: UInt64
    @Field(Byte8.self) var entrySize: UInt64

    @inline(__always)
    var sectionHeader: ExampleELF.SectionHeader {
        ExampleELF.SectionHeader(
            nameOffset: nameOffset, type: type, flags: flags, virtualAddress: virtualAddress, offset: offset, size: size,
            associatedSectionIndex: associatedSectionIndex, infoSectionIndex: infoSectionIndex, alignment: alignment,
            entrySize: entrySize
        )
    }
}

/// A 32-bit section header (`Elf32_Shdr`): every field 4 bytes.
@BinaryRecord
struct ELFSectionHeader32 {
    @Field(Byte4.self) var nameOffset: UInt32
    @Field(Byte4.self) var type: ExampleELF.SectionHeader.HeaderType
    @Field(Byte4.self) var flags: ExampleELF.SectionHeader.Flags
    @Field(Byte4.self) var virtualAddress: UInt64
    @Field(Byte4.self) var offset: UInt64
    @Field(Byte4.self) var size: UInt64
    @Field(Byte4.self) var associatedSectionIndex: UInt32
    @Field(Byte4.self) var infoSectionIndex: UInt32
    @Field(Byte4.self) var alignment: UInt64
    @Field(Byte4.self) var entrySize: UInt64

    @inline(__always)
    var sectionHeader: ExampleELF.SectionHeader {
        ExampleELF.SectionHeader(
            nameOffset: nameOffset, type: type, flags: flags, virtualAddress: virtualAddress, offset: offset, size: size,
            associatedSectionIndex: associatedSectionIndex, infoSectionIndex: infoSectionIndex, alignment: alignment,
            entrySize: entrySize
        )
    }
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
        return switch identification.byteOrder {
        case .little: try parse(data, identification, LittleEndianBytes.self)
        case .big: try parse(data, identification, BigEndianBytes.self)
        }
    }

    /// The parser after the identification, in one byte order: specialized for each.
    static func parse<Mode: ByteOrderedCursorMode>(
        _ data: RawSpan, _ identification: ELFIdentification, _: Mode.Type
    ) throws(BytesError) -> ExampleELF {
        var reader = try GenericBytesReader<Mode>(data, atByteOffset: ELFIdentification.byteCount)
        let fileClass = identification.fileClass
        let is64 = fileClass == .class64Bit
        // The example checks the identification's version only for 32-bit files.
        guard is64 || identification.version == 1 else { throw .mismatch }

        let start = try reader.read(ELFHeaderStart.self)
        let addresses = is64 ? try reader.read(ELFAddresses64.self) : try reader.read(ELFAddresses32.self).wide
        let end = try reader.read(ELFHeaderEnd.self)
        guard end.headerSize == fileClass.headerSize, end.programHeaderEntrySize == fileClass.programHeaderEntrySize,
              end.sectionHeaderEntrySize == fileClass.sectionHeaderEntrySize else { throw .mismatch }

        let header = ExampleELF.Header(
            class: fileClass, endian: identification.byteOrder, version: identification.version, osABI: identification.osABI,
            abiVersion: identification.abiVersion, fileType: start.fileType,
            instructionSet: ExampleELF.Header.ISA(rawValue: start.instructionSet),
            entryPoint: addresses.entryPoint, programHeaderTable: addresses.programHeaderTable,
            sectionHeaderTable: addresses.sectionHeaderTable, architectureFlags: end.architectureFlags,
            programHeaderEntryCount: end.programHeaderCount, sectionHeaderEntryCount: end.sectionHeaderCount,
            sectionNameIndex: end.sectionNameIndex
        )

        // Each table: seek to it (as the example does, even when it's empty), then a record per entry.
        try reader.seek(toByteOffset: addresses.programHeaderTable)
        var programHeaders: [ExampleELF.ProgramHeader] = []
        programHeaders.reserveCapacity(Int(end.programHeaderCount))
        if is64 {
            for _ in 0..<end.programHeaderCount {
                try programHeaders.append(reader.read(ELFProgramHeader64.self).programHeader)
            }
        } else {
            for _ in 0..<end.programHeaderCount {
                try programHeaders.append(reader.read(ELFProgramHeader32.self).programHeader)
            }
        }

        try reader.seek(toByteOffset: addresses.sectionHeaderTable)
        var sectionHeaders: [ExampleELF.SectionHeader] = []
        sectionHeaders.reserveCapacity(Int(end.sectionHeaderCount))
        if is64 {
            for _ in 0..<end.sectionHeaderCount {
                try sectionHeaders.append(reader.read(ELFSectionHeader64.self).sectionHeader)
            }
        } else {
            for _ in 0..<end.sectionHeaderCount {
                try sectionHeaders.append(reader.read(ELFSectionHeader32.self).sectionHeader)
            }
        }

        return ExampleELF(header: header, programHeaders: programHeaders, sectionHeaders: sectionHeaders)
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
            return try String(copying: reader.read(utf8TerminatedBy: 0))
        } catch {
            return nil
        }
    }
}

extension ELFAddresses32 {
    /// The same addresses as a 64-bit file's.
    @inline(__always)
    var wide: ELFAddresses64 {
        ELFAddresses64(entryPoint: entryPoint, programHeaderTable: programHeaderTable, sectionHeaderTable: sectionHeaderTable)
    }
}
