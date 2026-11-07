import Benchmark
import Bytes

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .seconds(1),
        maxIterations: 1_000
    )

    registerBandwidthBenchmarks()
    registerWriteBenchmarks()

    // MARK: Field parsing: a 2,000-entry zip central directory (~170 KB)

    let directory = makeCentralDirectory(count: 2_000)
    let expected = try! CentralDirectory.parseWithOffsets(directory.span.bytes)
    precondition(try! CentralDirectory.parseWithBytes(directory.span.bytes) == expected)
    precondition(try! CentralDirectory.parseWithByteReader(directory.span.bytes) == expected)
    precondition(try! CentralDirectory.parseWithBytesRecords(directory.span.bytes) == expected)

    Benchmark("Fields: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try CentralDirectory.parseWithBytes(directory.span.bytes))
        }
    }
    Benchmark("Fields: Bytes, fixed-size records") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try CentralDirectory.parseWithBytesRecords(directory.span.bytes))
        }
    }
    Benchmark("Fields: original ByteReader") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try CentralDirectory.parseWithByteReader(directory.span.bytes))
        }
    }
    Benchmark("Fields: hand-written offsets") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try CentralDirectory.parseWithOffsets(directory.span.bytes))
        }
    }

    // MARK: Bit fields: 8 fields of 1 to 32 bits per 64-bit record, 128 KB

    let bitStream = (0..<(128 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }
    precondition(try! BitFields.parseWithBytes(bitStream.span) == (try! BitFields.parseWithBitBuffer(bitStream.span)))

    Benchmark("Bits: Bytes") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try BitFields.parseWithBytes(bitStream.span))
        }
    }
    Benchmark("Bits: 64-bit buffer reader") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try BitFields.parseWithBitBuffer(bitStream.span))
        }
    }

    // MARK: Bulk: 1 MB of big-endian UInt32s (256 K values)

    let words = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let wordCount = words.count / 4

    Benchmark("Bulk BE32: read(_:_:into:)") { benchmark in
        for _ in benchmark.scaledIterations {
            var reader = Bytes(words.span)
            let values = try [UInt32](capacity: wordCount) { try reader.read(Byte4.self, .bigEndian, into: &$0) }
            blackHole(values)
        }
    }
    Benchmark("Bulk BE32: read(_:_:) per value") { benchmark in
        for _ in benchmark.scaledIterations {
            var reader = Bytes(words.span)
            let values = try [UInt32](capacity: wordCount) { output in
                while !output.isFull { output.append(try reader.read(Byte4.self, .bigEndian)) }
            }
            blackHole(values)
        }
    }
    Benchmark("Bulk BE32: RawSpan.load per value") { benchmark in
        for _ in benchmark.scaledIterations {
            let span = words.span.bytes
            let values = [UInt32](capacity: wordCount) { output in
                for index in 0..<wordCount {
                    output.append(span.load(fromByteOffset: index * 4, as: UInt32.self, .bigEndian))
                }
            }
            blackHole(values)
        }
    }
    Benchmark("Bulk BE24: read(_:_:into:)") { benchmark in
        for _ in benchmark.scaledIterations {
            var reader = Bytes(words.span)
            let values = try [UInt32](capacity: words.count / 3) { try reader.read(Byte3.self, .bigEndian, into: &$0) }
            blackHole(values)
        }
    }

    // MARK: Search: a 4-byte signature at the start of 64 KB (the zip EOCD worst case: a max-length comment)

    var tail = (0..<65_557).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
    tail.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x05, 0x06])
    let haystack = tail
    let signature: Byte4 = [0x50, 0x4B, 0x05, 0x06]

    Benchmark("Search 64 KB backwards: lastByteOffset(of:)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Bytes(haystack.span).lastByteOffset(of: signature))
        }
    }
    Benchmark("Search 64 KB backwards: RawSpan.load per offset") { benchmark in
        for _ in benchmark.scaledIterations {
            let span = haystack.span.bytes
            var found: Int?
            for offset in stride(from: span.byteCount - 4, through: 0, by: -1)
                where span.load(fromByteOffset: offset, as: UInt32.self, .littleEndian) == 0x0605_4B50 {
                found = offset
                break
            }
            blackHole(found)
        }
    }
}
