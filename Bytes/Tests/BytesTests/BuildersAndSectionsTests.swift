import Bytes
import Testing

/// `[UInt8](byteCapacity:writing:)`, `append(byteCapacity:writing:)`, and the prefixed-section reads.
@Suite struct BuildersAndSectionsTests {
    struct Stop: Error {}

    @Test func arrayBuilderKeepsWhatWasWritten() throws {
        let bytes = try [UInt8](byteCapacity: 16) { writer in
            try writer.write(0x01_02 as Byte2)
            try writer.write(Nibble(0xA))
        }
        #expect(bytes == [0x01, 0x02, 0xA0])

        let lsb = try [UInt8](byteCapacity: 1, bitOrder: .leastSignificantFirst) { writer in try writer.write(Nibble(0xA)) }
        #expect(lsb == [0x0A])

        #expect(throws: BytesError.insufficientCapacity) {
            try [UInt8](byteCapacity: 1) { writer in try writer.write(0x01_02 as Byte2) }
        }
    }

    @Test func appendingKeepsNothingWhenTheBodyThrows() throws {
        var bytes: [UInt8] = [9]
        try bytes.append(byteCapacity: 4) { writer in try writer.write(0x01_02_03 as Byte3) }
        #expect(bytes == [9, 1, 2, 3])
        #expect(throws: Stop.self) {
            try bytes.append(byteCapacity: 8) { writer throws(Stop) in
                try! writer.write(0x04_05 as Byte2)
                throw Stop()
            }
        }
        #expect(bytes == [9, 1, 2, 3])
    }

    @Test func prefixedBytesAreCheckedOnce() throws {
        let data: [UInt8] = [0x00, 0x03, 0xAA, 0xBB, 0xCC, 0x00, 0x05, 0x01]
        var reader = BytesReader(data.span)
        let first = try reader.read(bytesPrefixedBy: Byte2.self, .bigEndian)
        #expect(first.byteCount == 3 && [UInt8](copying: first) == [0xAA, 0xBB, 0xCC])
        // The second says 5 bytes and has 1: throws, consuming nothing.
        #expect(throws: BytesError.insufficientData) { _ = try reader.read(bytesPrefixedBy: Byte2.self, .bigEndian) }
        let offset = reader.byteOffset
        #expect(offset == 5)
        // A length that isn't there at all.
        let short: [UInt8] = [0x00]
        var shortReader = BytesReader(short.span)
        #expect(throws: BytesError.insufficientData) { _ = try shortReader.read(bytesPrefixedBy: Byte2.self, .bigEndian) }
        // LEB128 lengths.
        let leb: [UInt8] = [0x02, 0x10, 0x20, 0x05, 0x30]
        var lebReader = BytesReader(leb.span)
        let two = try lebReader.read(bytesPrefixedBy: LEB128.self)
        #expect([UInt8](copying: two) == [0x10, 0x20])
        #expect(throws: BytesError.insufficientData) { _ = try lebReader.read(bytesPrefixedBy: LEB128.self) }
        let lebOffset = lebReader.byteOffset
        #expect(lebOffset == 3)
    }

    @Test func sectionsIfComplete() throws {
        // A zip-like extra field block: id, size, data; the last one truncated.
        let data: [UInt8] = [0x55, 0x54, 0x02, 0x00, 0x07, 0x08, 0x01, 0x00, 0x09, 0x00, 0xFF]
        var extra = BytesReader(data.span)
        var ids: [UInt16] = []
        var payloads: [[UInt8]] = []
        while extra.remainingByteCount >= 4 {
            let id = try extra.read(Byte2.self, .littleEndian)
            guard var field = extra.readSectionIfComplete(prefixedBy: Byte2.self, .littleEndian) else { break }
            ids.append(id)
            payloads.append([UInt8](copying: field.readRemainingBytes()))
        }
        #expect(ids == [0x5455])
        #expect(payloads == [[0x07, 0x08]])
        // Stopped after the second id, with the truncated field's length unconsumed.
        let offset = extra.byteOffset
        #expect(offset == 8)

        let empty: [UInt8] = [0x00]
        var tooShort = BytesReader(empty.span)
        let missing = switch tooShort.readSectionIfComplete(prefixedBy: Byte2.self, .littleEndian) {
        case .none: true
        case .some: false
        }
        #expect(missing)
        let unmoved = tooShort.byteOffset
        #expect(unmoved == 0)
        let zero: [UInt8] = [0x00, 0x00]
        var zeroLength = BytesReader(zero.span)
        let emptySection = switch zeroLength.readSectionIfComplete(prefixedBy: Byte2.self, .bigEndian) {
        case .none: false
        case let .some(section): section.isAtEnd
        }
        #expect(emptySection)
    }
}
