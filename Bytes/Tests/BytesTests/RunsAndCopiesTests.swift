import Bytes
import Testing

/// Runs (`write(repeating:…)`), copies from a reader (`write(from:byteCount:allowingOverrun:)`), inline
/// copies of short spans, and minimal LEB128.
@Suite struct RunsAndCopiesTests {
    /// `count` copies of `element` written into a buffer of `capacity` bytes pre-filled with 0xEE, and the
    /// buffer afterwards, so tests can check nothing past the run was touched.
    func run(capacity: Int, _ write: (inout BytesWriter) throws(BytesError) -> Void) throws -> (written: Int, buffer: [UInt8]) {
        var buffer = [UInt8](repeating: 0xEE, count: capacity)
        var span = buffer.mutableSpan
        var writer = BytesWriter(&span)
        try write(&writer)
        let written = writer.byteCount
        _ = consume writer
        _ = consume span
        return (written, buffer)
    }

    @Test(arguments: 1...8)
    func repeatingRuntimeWidth(byteCount: Int) throws {
        let element: [UInt8] = Array([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88].prefix(byteCount))
        let low = element.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        let value = byteCount == 8 ? low : low | 0xAB << (8 * UInt64(byteCount)) // A byte above the width, ignored.
        for count in [0, 1, 2, 3, 5, 7, 15, 16, 17, 31, 33, 62, 63, 100, 300] {
            let total = count * byteCount
            let (written, buffer) = try run(capacity: total + 20) { writer throws(BytesError) in
                try writer.write(repeating: value, byteCount: byteCount, count: count)
            }
            #expect(written == total)
            #expect(Array(buffer[..<total]) == Array((0..<count).flatMap { _ in element }), "\(byteCount) × \(count)")
            #expect(buffer[total...].allSatisfy { $0 == 0xEE }, "wrote past \(byteCount) × \(count)")
        }
    }

    @Test func repeatingIgnoresBytesAboveTheWidth() throws {
        let (_, buffer) = try run(capacity: 9) { writer throws(BytesError) in
            try writer.write(repeating: 0xFFFF_FF01_0203, byteCount: 3, count: 3)
        }
        #expect(buffer == [0x03, 0x02, 0x01, 0x03, 0x02, 0x01, 0x03, 0x02, 0x01])
    }

    @Test func repeatingGroupsAndBytes() throws {
        for count in [0, 1, 4, 5, 6, 11, 40, 257, 1000] {
            let (written, buffer) = try run(capacity: count * 13 + 3) { writer throws(BytesError) in
                try writer.write(repeating: Byte(0x5A), count: count)
                try writer.write(repeating: 0x01_02_03 as Byte3, count: count)
                try writer.write(repeating: 0x01_02_03_04_05_06_07_08_09 as Byte9, count: count)
            }
            #expect(written == count * 13)
            let expected = Array(repeating: 0x5A as UInt8, count: count)
                + (0..<count).flatMap { _ in [0x01, 0x02, 0x03] as [UInt8] }
                + (0..<count).flatMap { _ in Array(1...9) as [UInt8] }
            #expect(Array(buffer[..<written]) == expected, "count \(count)")
            #expect(buffer[written...].allSatisfy { $0 == 0xEE })
        }
    }

    @Test func repeatingThrowsWithoutWriting() throws {
        let (written, buffer) = try run(capacity: 10) { writer throws(BytesError) in
            #expect(throws: BytesError.insufficientCapacity) { try writer.write(repeating: 0x01_02_03 as Byte3, count: 4) }
            #expect(throws: BytesError.insufficientCapacity) { try writer.write(repeating: 1, byteCount: 2, count: .max) }
            try writer.write(repeating: Byte(1), count: 10)
        }
        #expect(written == 10 && buffer == Array(repeating: 1, count: 10))
    }

    @Test func copyFromReader() throws {
        let source = (0..<200).map { UInt8($0) }
        for overrun in [false, true] {
            for count in [0, 1, 7, 15, 16, 17, 31, 32, 33, 64, 100] {
                // Room for the copy only, for the copy plus some overrun, and for plenty.
                for extra in [0, 8, 40] {
                    var reader = BytesReader(source.span)
                    try reader.skip(byteCount: 3)
                    let (written, buffer) = try run(capacity: count + extra) { writer throws(BytesError) in
                        try writer.write(from: &reader, byteCount: count, allowingOverrun: overrun)
                    }
                    let consumed = reader.byteOffset
                    #expect(consumed == 3 + count)
                    #expect(written == count)
                    #expect(Array(buffer[..<count]) == Array(source[3..<(3 + count)]), "\(count), overrun \(overrun)")
                    if !overrun { #expect(buffer[count...].allSatisfy { $0 == 0xEE }) }
                }
            }
        }
    }

    @Test func copyFromReaderNearTheEnds() throws {
        // A reader with fewer than 16 bytes left takes the exact path, even with overrun allowed.
        let source = (0..<20).map { UInt8($0) }
        var reader = BytesReader(source.span)
        try reader.skip(byteCount: 10)
        let (written, buffer) = try run(capacity: 64) { writer throws(BytesError) in
            try writer.write(from: &reader, byteCount: 10, allowingOverrun: true)
        }
        #expect(written == 10 && Array(buffer[..<10]) == Array(10..<20) && buffer[10...].allSatisfy { $0 == 0xEE })

        var short = BytesReader(source.span)
        _ = try run(capacity: 64) { writer throws(BytesError) in
            #expect(throws: BytesError.insufficientData) { try writer.write(from: &short, byteCount: 21, allowingOverrun: true) }
        }
        let unmoved = short.byteOffset
        #expect(unmoved == 0)
        _ = try run(capacity: 4) { writer throws(BytesError) in
            #expect(throws: BytesError.insufficientCapacity) { try writer.write(from: &short, byteCount: 5, allowingOverrun: true) }
            #expect(writer.byteCount == 0)
        }
        let stillUnmoved = short.byteOffset
        #expect(stillUnmoved == 0)
    }

    /// Short-distance back-references (now runs) right after the only bytes written, into a buffer with no
    /// room after the copy, with and without overrun allowed.
    @Test func shortDistanceCopiesAtTheStart() throws {
        for distance in 1...7 {
            for count in [1, 2, 3, 5, 8, 9, 15, 16, 17, 31, 32, 33, 100, 258, 300] {
                let seed = (0..<distance).map { UInt8(0x41 + $0) }
                var expected = seed
                for _ in 0..<count {
                    expected.append(expected[expected.count - distance])
                }
                for overrun in [false, true] {
                    let (written, buffer) = try run(capacity: distance + count) { writer throws(BytesError) in
                        try writer.write(seed.span)
                        try writer.copy(fromDistance: distance, count: count, allowingOverrun: overrun)
                    }
                    #expect(written == expected.count && buffer == expected, "distance \(distance) count \(count)")
                }
            }
        }
    }

    @Test func shortSpanCopies() throws {
        let source = (0..<100).map { UInt8($0) }
        for count in 0...80 {
            let (written, buffer) = try run(capacity: count + 5) { writer throws(BytesError) in
                try writer.write(Byte(0xAA))
                try writer.write(source.span.bytes.extracting(first: count))
            }
            #expect(written == count + 1)
            #expect(buffer[0] == 0xAA && Array(buffer[1..<(count + 1)]) == Array(source[..<count]), "\(count)")
            #expect(buffer[(count + 1)...].allSatisfy { $0 == 0xEE })
        }
    }

    @Test func minimalLEB128() throws {
        let cases: [([UInt8], UInt64?)] = [
            ([0x00], 0), ([0x7F], 127), ([0x80, 0x01], 128), ([0xFF, 0x7F], 16_383),
            ([0x80, 0x00], nil), ([0xFF, 0x00], nil), ([0x80, 0x80, 0x00], nil), ([0x81, 0x80, 0x80, 0x00], nil),
            ([0x80, 0x80, 0x80, 0x01], 1 << 21),
        ]
        for (bytes, minimal) in cases {
            var plain = BytesReader(bytes.span)
            let value = try plain.read(LEB128.self, maxByteCount: 4)
            var checked = BytesReader(bytes.span)
            if let minimal {
                #expect(try checked.read(LEB128.self, maxByteCount: 4, requiringMinimal: true) == minimal)
                #expect(value == minimal)
            } else {
                #expect(throws: BytesError.invalidValue) { try checked.read(LEB128.self, maxByteCount: 4, requiringMinimal: true) }
                let unmoved = checked.byteOffset
                #expect(unmoved == 0, "\(bytes)")
            }
        }

        // Prefixed: a padded length throws, consuming nothing; a minimal one reads the section.
        let padded: [UInt8] = [0x82, 0x00, 0xAA, 0xBB]
        var reader = BytesReader(padded.span)
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(bytesPrefixedBy: LEB128.self, maxByteCount: 4, requiringMinimal: true) }
        let unmoved = reader.byteOffset
        #expect(unmoved == 0)
        #expect(try reader.read(bytesPrefixedBy: LEB128.self, maxByteCount: 4).byteCount == 2)
        let minimal: [UInt8] = [0x02, 0xAA, 0xBB]
        var sectionReader = BytesReader(minimal.span)
        var section = try sectionReader.read(sectionPrefixedBy: LEB128.self, maxByteCount: 4, requiringMinimal: true)
        #expect(try section.read(Byte2.self, .bigEndian) == 0xAABB)
    }
}
