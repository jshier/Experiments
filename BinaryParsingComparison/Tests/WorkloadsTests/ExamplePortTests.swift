import Bytes
import Foundation
import Testing
import Workloads

// Arrays read from files are bound to locals before taking their spans: `try f(g().span.bytes)`, with a
// throwing `g`, crashes Swift 6.4.4 at -Onone ("Instruction does not dominate all uses").

/// Every value in `value`, nested, as text: for comparing results whose types aren't `Equatable` (the examples'
/// own types, which both sides of these comparisons build). Not for dictionaries, whose order varies.
func structure(_ value: Any) -> String {
    var text = ""
    dump(value, to: &text)
    return text
}

/// Whether two property list objects are equal, dictionaries compared by key.
func equal(_ lhs: ExampleBPList.Object, _ rhs: ExampleBPList.Object) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): true
    case let (.boolean(a), .boolean(b)): a == b
    case let (.int(a), .int(b)): a == b
    case let (.real(a), .real(b)): a.bitPattern == b.bitPattern
    case let (.date(a), .date(b)): a == b
    case let (.data(a), .data(b)): a == b
    case let (.uid(a), .uid(b)): a == b
    case let (.string(a), .string(b)): a == b
    case let (.array(a), .array(b)): a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
    case let (.dictionary(a), .dictionary(b)):
        a.count == b.count && a.allSatisfy { key, value in b[key].map { equal(value, $0) } ?? false }
    default: false
    }
}

/// An ELF test file: helloworld as it is, swift-help decompressed from the LZ4 test file (the same bytes as
/// swift-binary-parsing's ELF/swift-help).
func elfFile(_ name: String) throws -> [UInt8] {
    guard name == "swift-help" else { return try dataFile(name) }
    let compressed = try dataFile("swift-help.lz4")
    return try LZ4.decodeWithBytes(compressed.span.bytes)
}

/// The Bytes ports of swift-binary-parsing's examples parse the examples' test files (and synthetic ones) to the
/// same results as the examples.
@Suite struct ExamplePortTests {
    @Test(arguments: ["helloworld", "swift-help"])
    func elf(file: String) throws {
        let data = try elfFile(file)
        let expected = try ExampleELF(parsing: data)
        let parsed = try ELF.parseWithBytes(data.span.bytes)
        #expect(structure(parsed) == structure(expected))
        let names = Data(data)
        let sectionNames = parsed.sectionHeaders.indices.map { ELF.sectionName(at: $0, of: parsed, in: data.span.bytes) }
        #expect(sectionNames == expected.sectionHeaders.indices.map { expected.sectionName(at: $0, data: names) })
        #expect(!sectionNames.contains(nil))
    }

    /// helloworld byte-swapped to big-endian, for the port's other byte order (the test files are little-endian).
    @Test func elfBigEndian() throws {
        var data = try elfFile("helloworld")
        let elf = try ExampleELF(parsing: data)
        func swap(_ offset: Int, _ width: Int) { data[offset..<(offset + width)].reverse() }
        data[5] = 2 // ELFDATA2MSB
        for (offset, width) in [(16, 2), (18, 2), (20, 4), (24, 4), (28, 4), (32, 4), (36, 4)] { swap(offset, width) }
        for offset in stride(from: 40, to: 52, by: 2) { swap(offset, 2) }
        for index in 0..<elf.programHeaders.count {
            for field in 0..<8 { swap(Int(elf.header.programHeaderTable) + 0x20 * index + 4 * field, 4) }
        }
        for index in 0..<elf.sectionHeaders.count {
            for field in 0..<10 { swap(Int(elf.header.sectionHeaderTable) + 0x28 * index + 4 * field, 4) }
        }
        let expected = try ExampleELF(parsing: data)
        #expect(expected.header.endian == .big)
        let parsed = try ELF.parseWithBytes(data.span.bytes)
        #expect(structure(parsed) == structure(expected))
        #expect(structure(parsed.sectionHeaders) == structure(elf.sectionHeaders))
    }

    /// The checks of swift-binary-parsing's own ELF tests, on the port.
    @Test func elfMatchesExampleTests() throws {
        let hello = try elfFile("helloworld")
        let elf = try ELF.parseWithBytes(hello.span.bytes)
        #expect(elf.header.class == .class32Bit)
        #expect(elf.header.endian == .little)
        #expect(elf.header.osABI == .systemV)
        #expect(elf.header.instructionSet == .x86)
        let names = elf.sectionHeaders.indices.map { ELF.sectionName(at: $0, of: elf, in: hello.span.bytes) }
        #expect(names == ["", ".text", ".rodata", ".shstrtab"])
        let swiftHelp = try elfFile("swift-help")
        let help = try ELF.parseWithBytes(swiftHelp.span.bytes)
        #expect(help.header.class == .class64Bit)
        #expect(help.header.instructionSet == .amd64)
        #expect(help.header.sectionHeaderEntryCount == 56)
    }

    @Test(arguments: ["tiny.png", "tricolor.png", "antelope.png"])
    func png(file: String) throws {
        let data = try dataFile(file)
        let expected = try ExamplePNG(parsing: data)
        let parsed = try PNG.parseWithBytes(data.span.bytes)
        #expect(structure(parsed) == structure(expected))
    }

    /// The checks of swift-binary-parsing's own PNG test, on the port.
    @Test func pngMatchesExampleTests() throws {
        let data = try dataFile("tiny.png")
        let png = try PNG.parseWithBytes(data.span.bytes)
        #expect(png.header.width == 221)
        #expect(png.header.height == 217)
        #expect(png.header.interlaced == false)
        #expect(png.chunks.count == 6)
    }

    /// Both reject a truncated file and one with its chunks out of order.
    @Test(arguments: ["tiny-bad-truncated.png", "tiny-bad-chunkorder.png"])
    func pngRejects(file: String) throws {
        let data = try dataFile(file)
        #expect(throws: (any Error).self) { _ = try ExamplePNG(parsing: data) }
        #expect(throws: BytesError.self) { _ = try PNG.parseWithBytes(data.span.bytes) }
    }

    @Test func pcapng() throws {
        let data = try dataFile("sample.pcap")
        let expected = try ExamplePCAPNG(parsing: data)
        let parsed = try PCAPNG.parseWithBytes(data.span.bytes)
        #expect(structure(parsed) == structure(expected))
        // swift-binary-parsing's own checks.
        #expect(parsed.header.majorVersion == 1)
        #expect(parsed.header.minorVersion == 0)
        #expect(parsed.header.options[0] == .hardware("arm64"))
        #expect(parsed.blocks.count == 1)
    }

    /// Synthetic captures in both byte orders: enhanced packets with options, which the sample doesn't have.
    @Test(arguments: [false, true])
    func pcapngSynthetic(bigEndian: Bool) throws {
        let data = makePCAPNG(packetCount: 200, bigEndian: bigEndian)
        let expected = try ExamplePCAPNG(parsing: data)
        let parsed = try PCAPNG.parseWithBytes(data.span.bytes)
        #expect(parsed.blocks.count == 201)
        #expect(parsed.header.isBigEndian == bigEndian)
        #expect(structure(parsed) == structure(expected))
    }

    @Test func bplist() throws {
        let data = try dataFile("sample.plist")
        let expected = try ExampleBPList(parsing: data)
        let parsed = try BPList.parseWithBytes(data.span.bytes)
        #expect(parsed.trailer.offsetTable == expected.trailer.offsetTable)
        #expect(parsed.trailer.topObjectIndex == expected.trailer.topObjectIndex)
        #expect(parsed.trailer.objectReferenceSize == expected.trailer.objectReferenceSize)
        #expect(equal(parsed.topObject, expected.topObject))
        // swift-binary-parsing's own checks.
        #expect(parsed.trailer.offsetTable.count == 71)
        let top = try #require(parsed.topObject.asDictionary)
        #expect(top.count == 18)
        #expect(top["CFBundleExecutable"]?.asString == "BinaryParsing")
        #expect(top["NumberList"]?.asArray?.count == 17)
    }

    @Test func bplistSynthetic() throws {
        let data = makeBinaryPList(recordCount: 300)
        let expected = try ExampleBPList(parsing: data)
        let parsed = try BPList.parseWithBytes(data.span.bytes)
        #expect(parsed.trailer.offsetTable == expected.trailer.offsetTable)
        #expect(equal(parsed.topObject, expected.topObject))
        #expect(parsed.topObject.asDictionary?["records"]?.asArray?.count == 300)
    }
}
