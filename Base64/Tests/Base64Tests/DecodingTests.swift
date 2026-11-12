import Base64
import Bytes
import Foundation
import Testing

/// Decodes `text` through a reader and writer into an array with room to spare.
func decoded(_ text: String, alphabet: Base64.Alphabet = .standard, padding: Bool = true) throws(LocatedBytesError) -> [UInt8] {
    let characters = Array(text.utf8)
    var output = [UInt8](repeating: 0xEE, count: Base64.maximumDecodedByteCount(of: characters.count) + 8)
    var span = output.mutableSpan
    var writer = BytesWriter(&span)
    var reader = BytesReader(characters.span)
    try Base64.decode(&reader, into: &writer, alphabet: alphabet, padding: padding)
    let written = writer.byteCount
    precondition(reader.isAtEnd)
    return Array(output.prefix(written))
}

/// The error decoding `text` throws, if any.
func decodingError(_ text: [UInt8], alphabet: Base64.Alphabet = .standard, padding: Bool = true) -> LocatedBytesError? {
    do throws(LocatedBytesError) {
        _ = try Base64.decodedBytes(text.span.bytes, alphabet: alphabet, padding: padding)
        return nil
    } catch {
        return error
    }
}

@Suite struct DecodingTests {
    @Test func rfc4648Vectors() throws {
        let vectors = [("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="),
                       ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy")]
        for (output, input) in vectors {
            #expect(try decoded(input) == Array(output.utf8), "\(input)")
            #expect(try Base64.decodedBytes(input) == Array(output.utf8), "\(input)")
            #expect(try decoded(input.replacing("=", with: ""), padding: false) == Array(output.utf8), "\(input)")
        }
    }

    /// Every length through several blocks (each tail length 0 to 60 after 0, 1, and 2 blocks, and each
    /// last group), in both alphabets, padded and not: round trips, and Foundation agrees.
    @Test(arguments: Array(0...200) + [1_000, 4_095, 4_096, 65_537])
    func roundTrips(count: Int) throws {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        for alphabet in [Base64.Alphabet.standard, .urlSafe] {
            for padding in [true, false] {
                let text = Base64.encodedString(bytes.span.bytes, alphabet: alphabet, padding: padding)
                #expect(try decoded(text, alphabet: alphabet, padding: padding) == bytes)
            }
        }
        let text = Base64.encodedString(bytes.span.bytes)
        #expect(try Base64.decodedBytes(text) == bytes)
        #expect(Data(base64Encoded: text).map(Array.init) == bytes)
    }

    /// Every character in every position of a group, through the block kernel and the last group.
    @Test func everyValueInEveryPosition() throws {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var text: [UInt8] = []
        for offset in 0..<4 {
            for value in 0..<64 {
                text.append(alphabet[(value + offset) % 64])
            }
        }
        let bytes = try Base64.decodedBytes(text.span.bytes)
        #expect(bytes == Array(Data(base64Encoded: Data(text))!))
    }

    /// A character that isn't in the alphabet, at every position of texts that take each path: the error
    /// is at that character, nothing is consumed, and the writer keeps nothing.
    @Test(arguments: [8, 64, 68, 100, 128, 132, 256, 300])
    func invalidCharacters(count: Int) throws {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<(count / 4 * 3)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let text = Array(Base64.encodedString(bytes.span.bytes).utf8)
        #expect(text.count == count)
        let wrong: [UInt8] = [UInt8(ascii: "*"), 0x00, 0x7F, 0x80, 0xC3, 0xFF, UInt8(ascii: "-"), UInt8(ascii: "_"),
                              UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "@"), UInt8(ascii: "[")]
        for position in 0..<count {
            var bad = text
            bad[position] = wrong[position % wrong.count]
            // The last two characters may be padding: "=" in their places is valid there.
            let error = try #require(decodingError(bad), "position \(position)")
            #expect(error == LocatedBytesError(.invalidValue, byteOffset: position), "position \(position)")
        }
        // "=" before the last two characters.
        for position in 0..<(count - 2) {
            var bad = text
            bad[position] = UInt8(ascii: "=")
            #expect(decodingError(bad)?.error == .invalidValue, "position \(position)")
        }
    }

    /// Every byte value in every position of a group, through the block kernel (a 68-character text) and
    /// through the last block alone (8 characters), in each alphabet, including one whose table is built at
    /// run time: valid exactly for the alphabet's characters, with their values.
    @Test func everyByteInEveryPosition() throws {
        // "." and "_": a window built at run time. "." and "~": too far apart for one, so the portable path.
        let windowed = Base64.Alphabet(character62: UInt8(ascii: "."), character63: UInt8(ascii: "_"))
        let unwindowed = Base64.Alphabet(character62: UInt8(ascii: "."), character63: UInt8(ascii: "~"))
        for alphabet in [Base64.Alphabet.standard, .urlSafe, windowed, unwindowed] {
            let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
                + [alphabet.character62, alphabet.character63]
            for length in [8, 68] {
                for position in 0..<4 {
                    for byte in 0...255 {
                        var text = [UInt8](repeating: UInt8(ascii: "A"), count: length)
                        text[position] = UInt8(byte)
                        let value = characters.firstIndex(of: UInt8(byte))
                        let error = decodingError(text, alphabet: alphabet)
                        guard let value else {
                            #expect(error == LocatedBytesError(.invalidValue, byteOffset: position), "\(byte) at \(position)")
                            continue
                        }
                        #expect(error == nil, "\(byte) at \(position)")
                        let bytes = try Base64.decodedBytes(text.span.bytes, alphabet: alphabet)
                        let bits = UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
                        #expect(bits == UInt32(value) << (18 - 6 * position), "\(byte) at \(position)")
                    }
                }
            }
        }
    }

    @Test func failuresConsumeAndKeepNothing() throws {
        let text = Array(("QUJD" + String(repeating: "QUJD", count: 40) + "QU*D").utf8)
        var output = [UInt8](repeating: 0, count: 200)
        var span = output.mutableSpan
        var writer = BytesWriter(&span)
        try writer.write(0x01_02 as Byte2)
        var reader = BytesReader(text.span)
        try reader.skip(byteCount: 4)
        #expect(throws: LocatedBytesError(.invalidValue, byteOffset: 4 + 160 + 2)) {
            try Base64.decode(&reader, into: &writer)
        }
        #expect(reader.byteOffset == 4)
        #expect(writer.byteCount == 2)
    }

    @Test func padding() throws {
        // Padding where it's expected, and only there.
        #expect(decodingError(Array("Zg=".utf8)) == LocatedBytesError(.insufficientData, byteOffset: 3))
        #expect(decodingError(Array("Zg".utf8)) == LocatedBytesError(.insufficientData, byteOffset: 2))
        #expect(decodingError(Array("Z===".utf8)) == LocatedBytesError(.invalidValue, byteOffset: 1))
        #expect(decodingError(Array("====".utf8)) == LocatedBytesError(.invalidValue, byteOffset: 0))
        #expect(decodingError(Array("Zg==Zg==".utf8)) == LocatedBytesError(.invalidValue, byteOffset: 2))
        #expect(decodingError(Array("Zm=v".utf8)) == LocatedBytesError(.invalidValue, byteOffset: 2))
        // Without padding: no "=", and no group of one character.
        #expect(try decoded("Zg", padding: false) == [0x66])
        #expect(try decoded("Zm8", padding: false) == [0x66, 0x6F])
        #expect(decodingError(Array("Zg==".utf8), padding: false) == LocatedBytesError(.invalidValue, byteOffset: 2))
        #expect(decodingError(Array("Zm9vY".utf8), padding: false) == LocatedBytesError(.insufficientData, byteOffset: 5))
    }

    @Test func unusedBitsMustBeZero() {
        // "Zg==" is canonical for 0x66; "Zh==" has a low bit set in the unused part of "h".
        #expect(decodingError(Array("Zh==".utf8)) == LocatedBytesError(.invalidValue, byteOffset: 1))
        #expect(decodingError(Array("Zm9=".utf8)) == LocatedBytesError(.invalidValue, byteOffset: 2))
        #expect(decodingError(Array("Zm8=".utf8)) == nil)
        #expect(decodingError(Array("Zh".utf8), padding: false) == LocatedBytesError(.invalidValue, byteOffset: 1))
    }

    @Test func capacity() throws {
        let text = Array("Zm9vYmFy".utf8)
        var output = [UInt8](repeating: 0, count: 5)
        var span = output.mutableSpan
        var writer = BytesWriter(&span)
        #expect(throws: LocatedBytesError(.insufficientCapacity, byteOffset: 0)) {
            try Base64.decode(text.span.bytes, into: &writer)
        }
        #expect(writer.byteCount == 0)
        // Padded text needs room only for the bytes it decodes to.
        var exact = [UInt8](repeating: 0, count: 4)
        var exactSpan = exact.mutableSpan
        var exactWriter = BytesWriter(&exactSpan)
        try Base64.decode(Array("Zm9vYg==".utf8).span.bytes, into: &exactWriter)
        #expect(exactWriter.byteCount == 4)
    }

    @Test func otherAlphabets() throws {
        let bytes: [UInt8] = [0xFB, 0xFF, 0xBF] // "+/+/" standard, "-_-_" URL-safe
        #expect(try decoded("-_-_", alphabet: .urlSafe) == bytes)
        #expect(try decoded("+/+/") == bytes)
        #expect(decodingError(Array("-_-_".utf8)) == LocatedBytesError(.invalidValue, byteOffset: 0))
        #expect(decodingError(Array("+/+/".utf8), alphabet: .urlSafe) == LocatedBytesError(.invalidValue, byteOffset: 0))
        let custom = Base64.Alphabet(character62: UInt8(ascii: "."), character63: UInt8(ascii: "!"))
        let text = Base64.encodedString(bytes.span.bytes, alphabet: custom)
        #expect(text == ".!.!")
        #expect(try decoded(text, alphabet: custom) == bytes)
    }

    /// The portable path, groups then the last group, which ARM64 builds don't otherwise use: every length
    /// and padding, and its errors.
    @Test func portablePath() throws {
        func decodePortably(_ text: [UInt8], alphabet: Base64.Alphabet = .standard, padding: Bool = true) throws(LocatedBytesError) -> [UInt8] {
            try [UInt8](byteCapacity: Base64.maximumDecodedByteCount(of: text.count)) { (writer) throws(LocatedBytesError) in
                try Base64._decodeGroups(text.span.bytes, padding: padding, into: &writer, alphabet: alphabet, at: 0)
            }
        }
        var generator = SystemRandomNumberGenerator()
        for count in 1...100 {
            let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            for alphabet in [Base64.Alphabet.standard, .urlSafe] {
                for padding in [true, false] {
                    let text = Array(Base64.encodedString(bytes.span.bytes, alphabet: alphabet, padding: padding).utf8)
                    #expect(try decodePortably(text, alphabet: alphabet, padding: padding) == bytes)
                }
            }
        }
        #expect(throws: LocatedBytesError(.invalidValue, byteOffset: 5)) { try decodePortably(Array("QUJDQ*JD".utf8)) }
        #expect(throws: LocatedBytesError(.invalidValue, byteOffset: 1)) { try decodePortably(Array("Zh==".utf8)) }
        #expect(throws: LocatedBytesError(.invalidValue, byteOffset: 2)) { try decodePortably(Array("Zm9=".utf8)) }
        // The last two "=" are padding; the first is a misplaced data character.
        #expect(throws: LocatedBytesError(.invalidValue, byteOffset: 5)) { try decodePortably(Array("QUJDZ===".utf8)) }
        #expect(decodingError(Array("QUJDZ===".utf8)) == LocatedBytesError(.invalidValue, byteOffset: 5))
        #expect(throws: LocatedBytesError(.invalidValue, byteOffset: 1)) { try decodePortably(Array("Zh".utf8), padding: false) }
    }

    /// The portable kernel, which ARM64 builds don't otherwise use.
    @Test func portableKernel() throws {
        var generator = SystemRandomNumberGenerator()
        for alphabet in [Base64.Alphabet.standard, .urlSafe] {
            let bytes = (0..<(3 * 100)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            let text = Array(Base64.encodedString(bytes.span.bytes, alphabet: alphabet).utf8)
            var reader = BytesReader(text.span)
            let groups = try reader.read(InlineArray<4, UInt8>.self, count: 100)
            var output = [UInt8](repeating: 0, count: 300)
            var span = output.mutableSpan
            var writer = BytesWriter(&span)
            let valid = try writer.write(InlineArray<3, UInt8>.self, count: 100, filling: { decodedGroups in
                Base64.decode(groups, into: &decodedGroups, alphabet: alphabet)
            })
            #expect(valid)
            #expect(output == bytes)

            var bad = text
            bad[123] = 0x80
            var badReader = BytesReader(bad.span)
            let badGroups = try badReader.read(InlineArray<4, UInt8>.self, count: 100)
            var badSpan = output.mutableSpan
            var badWriter = BytesWriter(&badSpan)
            let badValid = try badWriter.write(InlineArray<3, UInt8>.self, count: 100, filling: { decodedGroups in
                Base64.decode(badGroups, into: &decodedGroups, alphabet: alphabet)
            })
            #expect(!badValid)
        }
    }
}
