import Foundation

/// Size measurements of the library's compiled code, read from the release object file(s) that the
/// benchmark build links against. Reported as custom metrics so they're stored in baselines and
/// compared like any other.
struct BinarySize {
    /// Bytes of machine code: `__TEXT,__text`.
    var code = 0
    /// Bytes that end up in a linked binary: every section except linker-only `__LD` (compact unwind,
    /// which becomes the smaller `__unwind_info`), debug info (`__DWARF`), and zero-fill sections,
    /// which take no space in the file.
    var loadable = 0
    /// Bytes of each defined function in `__TEXT,__text`, keyed by (mangled) symbol name.
    var functions: [String: Int] = [:]

    init() {}

    /// The fully inlined hot path: `ISO8601.date(from: RawSpan)`.
    static let hotPathSymbol = "_$s13NativeISO86010B0O4date4from10Foundation4DateVs7RawSpanV_tAA0B10ParseErrorOYKFZ"

    /// Measures the NativeISO8601 objects built next to the running benchmark executable: the
    /// prelinked `NativeISO8601.o` (Swift Build), or the per-file objects in `NativeISO8601.build/`
    /// (the native build system). `nil` if neither is found.
    static func library() -> BinarySize? {
        guard let products = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let prelinked = products.appending(path: "NativeISO8601.o")
        let perFile = (try? FileManager.default.contentsOfDirectory(
            at: products.appending(path: "NativeISO8601.build"), includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "o" } ?? []
        let objects = FileManager.default.fileExists(atPath: prelinked.path) ? [prelinked] : perFile

        var total = BinarySize()
        for object in objects {
            guard let data = try? Data(contentsOf: object), let size = BinarySize(machO: data.bytes) else { return nil }
            total.code += size.code
            total.loadable += size.loadable
            total.functions.merge(size.functions) { $0 + $1 }
        }
        return objects.isEmpty ? nil : total
    }

    /// Parses a 64-bit little-endian Mach-O object's section and symbol tables. `nil` if it isn't one
    /// or is malformed; every read is bounds-checked.
    init?(machO bytes: RawSpan) {
        func u8(_ offset: Int) -> Int? {
            offset >= 0 && offset + 1 <= bytes.byteCount ? Int(bytes.load(fromByteOffset: offset, as: UInt8.self)) : nil
        }
        func u32(_ offset: Int) -> Int? {
            offset >= 0 && offset + 4 <= bytes.byteCount
                ? Int(bytes.load(fromByteOffset: offset, as: UInt32.self, .littleEndian)) : nil
        }
        func u64(_ offset: Int) -> Int? {
            offset >= 0 && offset + 8 <= bytes.byteCount
                ? Int(truncatingIfNeeded: bytes.load(fromByteOffset: offset, as: UInt64.self, .littleEndian)) : nil
        }
        /// A NUL-terminated string at `offset`, at most `limit` bytes.
        func string(_ offset: Int, limit: Int = .max) -> String? {
            var utf8: [UInt8] = []
            var index = offset
            while utf8.count < limit {
                guard let byte = u8(index) else { return nil }
                if byte == 0 { break }
                utf8.append(UInt8(byte))
                index += 1
            }
            return String(decoding: utf8, as: UTF8.self)
        }

        let mhMagic64 = 0xFEED_FACF, lcSegment64 = 0x19, lcSymtab = 0x2
        guard u32(0) == mhMagic64, let commandCount = u32(16) else { return nil }

        struct Section { var name: String, segment: String, address: Int, size: Int }
        var sections: [Section] = [] // In file order; symbols refer to them 1-based.
        var symbolTable: (offset: Int, count: Int, strings: Int)?

        var command = 32 // sizeof(mach_header_64)
        for _ in 0..<commandCount {
            guard let kind = u32(command), let commandSize = u32(command + 4), commandSize > 0 else { return nil }
            if kind == lcSegment64 {
                guard let sectionCount = u32(command + 64) else { return nil }
                for index in 0..<sectionCount {
                    let header = command + 72 + index * 80 // segment_command_64, then section_64s
                    guard let name = string(header, limit: 16), let segment = string(header + 16, limit: 16),
                          let address = u64(header + 32), let size = u64(header + 40), let flags = u32(header + 64)
                    else { return nil }
                    sections.append(Section(name: name, segment: segment, address: address, size: size))

                    // S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL occupy no file space.
                    let isZeroFill = [0x1, 0xC, 0x12].contains(flags & 0xFF)
                    if segment == "__TEXT", name == "__text" { code += size }
                    if segment != "__LD", segment != "__DWARF", !isZeroFill { loadable += size }
                }
            } else if kind == lcSymtab {
                guard let offset = u32(command + 8), let count = u32(command + 12), let strings = u32(command + 16)
                else { return nil }
                symbolTable = (offset, count, strings)
            }
            command += commandSize
        }

        // Function sizes: the distance from each defined symbol in __text to the next, or to the end
        // of the section.
        guard let textIndex = sections.firstIndex(where: { $0.segment == "__TEXT" && $0.name == "__text" }),
              let symbolTable
        else { return }
        let text = sections[textIndex]
        var starts: [(address: Int, name: String)] = []
        for index in 0..<symbolTable.count {
            let entry = symbolTable.offset + index * 16 // nlist_64
            guard let nameOffset = u32(entry), let type = u8(entry + 4), let section = u8(entry + 5),
                  let address = u64(entry + 8)
            else { return nil }
            // N_SECT symbols (not stabs) defined in __text.
            guard type & 0xE0 == 0, type & 0x0E == 0x0E, section == textIndex + 1,
                  let name = string(symbolTable.strings + nameOffset)
            else { continue }
            starts.append((address, name))
        }
        starts.sort { $0.address < $1.address }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].address : text.address + text.size
            functions[start.name, default: 0] += end - start.address
        }
    }
}
