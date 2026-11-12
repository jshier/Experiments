import Base64
import Bytes
import Foundation
import Testing

/// Encodes `bytes` into an exactly sized array through a `BytesWriter`.
func encoded(_ bytes: [UInt8], alphabet: Base64.Alphabet = .standard, padding: Bool = true) throws -> String {
    var output = [UInt8](repeating: 0, count: Base64.encodedByteCount(of: bytes.count, padding: padding))
    var span = output.mutableSpan
    var writer = BytesWriter(&span)
    try Base64.encode(bytes.span.bytes, into: &writer, alphabet: alphabet, padding: padding)
    let written = writer.byteCount
    precondition(written == output.count)
    return String(decoding: output, as: UTF8.self)
}

/// Foundation's encoding, in either alphabet, with or without padding.
func reference(_ bytes: [UInt8], alphabet: Base64.Alphabet = .standard, padding: Bool = true) -> String {
    var text = Data(bytes).base64EncodedString()
    if alphabet == .urlSafe { text = text.replacing("+", with: "-").replacing("/", with: "_") }
    if !padding { text = text.replacing("=", with: "") }
    return text
}

@Suite struct Base64Tests {
    /// RFC 4648 section 10's test vectors.
    @Test func rfc4648Vectors() throws {
        let vectors = [("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="),
                       ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy")]
        for (input, output) in vectors {
            #expect(try encoded(Array(input.utf8)) == output, "\(input)")
            #expect(Base64.encodedString(Array(input.utf8).span.bytes) == output, "\(input)")
        }
    }

    /// Every length through several blocks (each last-block length, with 0, 1, or 2 trailing bytes), and
    /// some longer, in both alphabets, with and without padding, against Foundation.
    @Test(arguments: Array(0...200) + [1_000, 4_095, 4_096, 65_537])
    func matchesFoundation(count: Int) throws {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        for alphabet in [Base64.Alphabet.standard, .urlSafe] {
            for padding in [true, false] {
                #expect(try encoded(bytes, alphabet: alphabet, padding: padding) == reference(bytes, alphabet: alphabet, padding: padding))
            }
        }
        #expect(Base64.encodedString(bytes.span.bytes) == reference(bytes))
    }

    /// Every 6-bit value in every position of a group: all 64 characters in each of the four places.
    @Test func everyValueInEveryPosition() throws {
        // 0x00, 0x10, 0x83, 0x10, 0x51, 0x87, … : a stream whose 6-bit values count 0, 1, 2, … 63, 0, …
        var bytes: [UInt8] = []
        var bits: UInt32 = 0, bitCount = 0
        for index in 0..<(64 * 4 * 3) {
            bits = bits << 6 | UInt32(index % 64)
            bitCount += 6
            while bitCount >= 8 {
                bitCount -= 8; bytes.append(UInt8(truncatingIfNeeded: bits >> UInt32(bitCount)))
            }
        }
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        #expect(try encoded(bytes) == String(repeating: alphabet, count: 12))
    }

    /// Too little room throws before reading or writing anything.
    @Test func insufficientCapacityChangesNothing() throws {
        let bytes: [UInt8] = Array("foobar!".utf8)
        var output = [UInt8](repeating: 0xAA, count: 11) // needs 12
        var span = output.mutableSpan
        var writer = BytesWriter(&span)
        var reader = BytesReader(bytes.span)
        #expect(throws: BytesError.insufficientCapacity) { try Base64.encode(&reader, into: &writer) }
        let (read, written) = (reader.byteOffset, writer.byteCount)
        #expect(read == 0 && written == 0)
        #expect(output.allSatisfy { $0 == 0xAA })
    }

    /// Encoding starts at the reader's position and appends at the writer's.
    @Test func encodesFromAndToCurrentPositions() throws {
        let bytes: [UInt8] = Array("xxfoobar".utf8)
        var output = [UInt8](repeating: 0, count: 10)
        var span = output.mutableSpan
        var writer = BytesWriter(&span)
        try writer.write(0x3E_3E as Byte2) // ">>"
        var reader = BytesReader(bytes.span)
        try reader.skip(byteCount: 2)
        try Base64.encode(&reader, into: &writer)
        let atEnd = reader.isAtEnd
        #expect(atEnd)
        #expect(String(decoding: output, as: UTF8.self) == ">>Zm9vYmFy")
    }

    /// The same past a block, where the last block overlaps the one before (1 to 47 bytes after 48), and
    /// past the bytes before the reader's position.
    @Test(arguments: [49, 64, 95, 96, 143])
    func encodesFromAPositionPastABlock(count: Int) throws {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<(count + 5)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        var output = [UInt8](repeating: 0, count: Base64.encodedByteCount(of: count))
        var span = output.mutableSpan
        var writer = BytesWriter(&span)
        var reader = BytesReader(bytes.span)
        try reader.skip(byteCount: 5)
        try Base64.encode(&reader, into: &writer)
        let atEnd = reader.isAtEnd
        #expect(atEnd)
        #expect(String(decoding: output, as: UTF8.self) == reference(Array(bytes[5...])))
    }

    @Test func encodedByteCounts() {
        #expect((0...7).map { Base64.encodedByteCount(of: $0) } == [0, 4, 4, 4, 8, 8, 8, 12])
        #expect((0...7).map { Base64.encodedByteCount(of: $0, padding: false) } == [0, 2, 3, 4, 6, 7, 8, 10])
    }
}

/// The 3-byte-group kernel, which encodes on CPUs without vectorized table lookups. On ARM64 the block
/// kernel handles every length, so this one is tested directly.
@Suite struct GroupKernelTests {
    @Test(arguments: [0, 1, 2, 15, 16, 17, 31, 32, 33, 100, 1_000])
    func matchesFoundation(groupCount: Int) {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<(groupCount * 3)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        for alphabet in [Base64.Alphabet.standard, .urlSafe] {
            var output = [UInt8](repeating: 0, count: groupCount * 4)
            var span = output.mutableSpan
            var reader = BytesReader(bytes.span)
            let groups = try! reader.read(InlineArray<3, UInt8>.self, count: groupCount)
            var writer = BytesWriter(&span)
            try! writer.write(InlineArray<4, UInt8>.self, count: groupCount, filling: { characters in
                Base64.encode(groups, into: &characters, alphabet: alphabet)
            })
            #expect(String(decoding: output, as: UTF8.self) == reference(bytes, alphabet: alphabet))
        }
    }
}
