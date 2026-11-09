import Bytes
import Testing

/// The 16-lane scans against byte-at-a-time answers, at every length that takes a different path (empty,
/// 1–3, 4–7, 8–15, whole and partial 16-byte blocks) and every position of the byte that decides it.
@Suite struct ByteScanTests {
    static let lengths = Array(0...48)

    /// Every byte value matches only itself, in every lane.
    @Test func matchingIsExactInEveryLane() {
        for target in 0...255 {
            for value in 0...255 {
                let lanes = ByteLanes(SIMD16(repeating: UInt8(value)))
                let matches = lanes.matching(UInt8(target))
                #expect(matches.any == (value == target), "\(value) matching \(target)")
            }
        }
        for value in 0...255 {
            #expect(ByteLanes(SIMD16(repeating: UInt8(value))).nonASCII.any == (value >= 0x80))
        }
    }

    @Test(arguments: lengths)
    func containsByteFindsAMatchAnywhere(count: Int) {
        let plain = [UInt8](repeating: UInt8(ascii: "a"), count: count)
        let none = plain.span.bytes.containsByte { $0.matching(0) | $0.matching(UInt8(ascii: "+")) }
        #expect(!none)
        for position in 0..<count {
            for special: UInt8 in [0, UInt8(ascii: "+"), 0x80, 0xFF] {
                var bytes = plain
                bytes[position] = special
                let expected = special == 0 || special == UInt8(ascii: "+")
                let found = bytes.span.bytes.containsByte { $0.matching(0) | $0.matching(UInt8(ascii: "+")) }
                let nonASCII = bytes.span.bytes.containsByte(where: \.nonASCII)
                #expect(found == expected, "\(special) at \(position) of \(count)")
                #expect(nonASCII == (special >= 0x80))
            }
        }
    }

    @Test(arguments: lengths)
    func bytesEqualFindsADifferenceAnywhere(count: Int) {
        let a = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let same = a.span.bytes.bytesEqual(a.span.bytes)
        let longer = a.span.bytes.bytesEqual((a + [0]).span.bytes)
        #expect(same && !longer)
        for position in 0..<count {
            var b = a
            b[position] ^= 0x01
            let equal = a.span.bytes.bytesEqual(b.span.bytes)
            #expect(!equal, "difference at \(position) of \(count)")
        }
    }

    /// The one-pass ASCII path and the full validation agree: ASCII, multi-byte UTF-8, invalid UTF-8, and
    /// an excluded byte in either kind of text.
    @Test func validatingExcluding() {
        func check(_ bytes: [UInt8]) -> String? {
            guard let text = UTF8Span(validating: bytes.span.bytes, excluding: { $0.matching(UInt8(ascii: "#")) }) else {
                return nil
            }
            return String(copying: text)
        }
        #expect(check(Array("sensors/building-1/floor-2/temp-3".utf8)) == "sensors/building-1/floor-2/temp-3")
        #expect(check(Array("capteurs/bâtiment-1/étage-2/température".utf8)) == "capteurs/bâtiment-1/étage-2/température")
        #expect(check(Array("sensors/#".utf8)) == nil)
        #expect(check(Array("bâtiment/#".utf8)) == nil)
        #expect(check([0x61, 0xC3]) == nil) // A truncated sequence.
        #expect(check([0x61, 0xC0, 0xAF]) == nil) // An overlong encoding.
        #expect(check([]) == "")

        // Known ASCII when it took the one-pass path.
        let ascii = Array("unit".utf8)
        let isKnownASCII = UTF8Span(validating: ascii.span.bytes, excluding: { _ in .none })?.isKnownASCII
        #expect(isKnownASCII == true)
    }

    @Test func readingExcludingConsumesNothingOnFailure() throws {
        let bytes: [UInt8] = [0x00, 0x03, 0x61, 0x23, 0x62, 0x00, 0x01, 0x61]
        var reader = BytesReader(bytes.span)
        #expect(throws: BytesError.invalidValue) {
            _ = try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian, excluding: { $0.matching(UInt8(ascii: "#")) })
        }
        #expect(reader.byteOffset == 0)
        let text = try reader.read(utf8PrefixedBy: Byte2.self, .bigEndian)
        #expect(String(copying: text) == "a#b")
        #expect(try String(copying: reader.read(utf8PrefixedBy: Byte2.self, .bigEndian, excluding: { $0.matching(0) })) == "a")
    }
}
