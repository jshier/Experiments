import Foundation
import Testing
import Workloads

func dataFile(_ name: String) throws -> [UInt8] {
    let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Data/\(name)")
    return Array(try Data(contentsOf: url))
}

/// Every variant of a workload produces the same result, so the benchmarks compare equal work.
@Suite struct EquivalenceTests {
    @Test func centralDirectory() throws {
        let directory = makeCentralDirectory(count: 2_000)
        let span = directory.span.bytes
        let expected = try CentralDirectory.parseWithBytes(span)
        #expect(try CentralDirectory.parseWithBytesRecords(span) == expected)
        #expect(try CentralDirectory.parseWithParserSpan(span) == expected)
        #expect(try CentralDirectory.parseWithParserSpanRecords(span) == expected)
    }

    @Test func integers() throws {
        let data = (0..<(3 * 4 * 1_000)).map { UInt8(truncatingIfNeeded: $0 &* 37) }
        let span = data.span.bytes
        let sum32 = try Integers.sum32Bytes(span)
        #expect(Integers.sum32BytesForEach(span) == sum32)
        #expect(try Integers.sum32ParserSpan(span) == sum32)
        let sum24 = try Integers.sum24Bytes(span)
        #expect(Integers.sum24BytesForEach(span) == sum24)
        #expect(try Integers.sum24ParserSpan(span) == sum24)
    }

    @Test(arguments: ["tricolor.qoi", "antelope.qoi"])
    func qoi(file: String) throws {
        let data = try dataFile(file)
        let expected = try ExampleQOI(parsing: data).decodedImage
        #expect(expected.pixels.count == expected.width * expected.height * expected.channels)
        #expect(try QOI.decodeWithBytes(data.span.bytes) == expected)
        #expect(try QOI.decodeWithParserSpan(data.span.bytes) == expected)
    }

    @Test func lz4MatchesOriginal() throws {
        let original = try dataFile("tricolor.qoi")
        let compressed = try dataFile("tricolor.qoi.lz4")
        #expect([UInt8](try ExampleLZ4(parsing: compressed).data) == original)
        #expect(try LZ4.decodeWithBytes(compressed.span.bytes) == original)
        #expect(try LZ4.decodeWithParserSpan(compressed.span.bytes) == original)
    }

    @Test func lz4Large() throws {
        let compressed = try dataFile("swift-help.lz4")
        let expected = [UInt8](try ExampleLZ4(parsing: compressed).data)
        #expect(expected.count == 10_640_904)
        #expect(try LZ4.decodeWithBytes(compressed.span.bytes) == expected)
        #expect(try LZ4.decodeWithParserSpan(compressed.span.bytes) == expected)
    }
}
