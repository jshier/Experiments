import Bytes
import BytesCompression
import BytesTestSupport
import Foundation
import Testing

/// `DecompressionFormat(detecting:)` (open item 24): every format with a magic recognized from its streams, made by
/// Bytes' encoders and the reference tools; prefixes never named wrongly; formats with no magic, and random bytes, not
/// recognized (but zlib's two-byte test, rarely).
@Suite struct FormatDetectionTests {
    /// What detecting `format`'s streams gives: its defaults for the formats with a magic, `nil` for the others.
    static func detected(_ format: DecompressionFormat) -> DecompressionFormat? {
        switch format {
        case .deflate(.gzip): .deflate(.gzip)
        case .deflate(.zlib): .deflate(.zlib)
        case .zstd: .zstd()
        case .bzip2: .bzip2
        case .xz: .xz()
        case .lzfse: .lzfse
        case .lz4(framed: true): .lz4(framed: true)
        case .lzbitmap: .lzbitmap
        case .lzraven: .lzraven
        default: nil
        }
    }

    @Test func everyFormatsStreams() {
        for (format, stream, _) in DecompressorTests.encodings {
            let expected = Self.detected(format)
            #expect(DecompressionFormat(detecting: stream.span.bytes) == expected, "\(format)")
            // Every prefix: `nil` (wait, or not recognized) or the format itself, never another; with
            // `detectionByteCount` bytes, decided.
            for count in 0...min(stream.count, DecompressionFormat.detectionByteCount) {
                let prefix = DecompressionFormat(detecting: stream.span.bytes.extracting(0..<count))
                #expect(prefix == nil || prefix == expected, "\(format), \(count) bytes")
                if count == DecompressionFormat.detectionByteCount {
                    #expect(prefix == expected, "\(format), \(count) bytes")
                }
            }
        }
    }

    /// More streams: zstd's skippable frames, empty LZFSE and framed LZ4 streams (their end markers alone), zlib with a
    /// preset dictionary (detected; its decoder says `unsupported`), every bzip2 level, and the standard LZ4 frame
    /// format and `.lzma` files (not recognized).
    @Test func edges() throws {
        let cases: [([UInt8], DecompressionFormat?)] = [
            ([0x50, 0x2A, 0x4D, 0x18, 0, 0, 0, 0], .zstd()),
            ([0x5F, 0x2A, 0x4D, 0x18, 4, 0, 0, 0, 1, 2, 3, 4], .zstd()),
            (Array("bvx$".utf8), .lzfse),
            (Array("bv4$".utf8), .lz4(framed: true)),
            ([0x78, 0x20, 0, 0, 0, 1], .deflate(.zlib)),
            ([0x04, 0x22, 0x4D, 0x18, 0x64, 0x40], nil), // The LZ4 frame format.
            ([0x5D, 0, 0, 0x80, 0, 0xFF], nil), // An `.lzma` file's properties and dictionary size.
            (Array("BZh0".utf8) + [0x31, 0x41], nil),
            (Array("ZBM\u{0A}".utf8) + [0, 0], nil),
        ]
        for level in 1...9 {
            #expect(DecompressionFormat(detecting: (Array("BZh".utf8) + [UInt8(0x30 + level), 0x31, 0x41]).span.bytes) == .bzip2)
        }
        for (bytes, expected) in cases {
            #expect(DecompressionFormat(detecting: bytes.span.bytes) == expected, "\(bytes.prefix(4))")
        }
        let header: [UInt8] = [0x78, 0x20, 0, 0, 0, 1]
        let format = DecompressionFormat(detecting: header.span.bytes) // `#require` doesn't take a span.
        var decompressor = try Decompressor(for: #require(format))
        var output = [UInt8](repeating: 0, count: 16)
        let stream: [UInt8] = [0x78, 0x20, 0, 0, 0, 1, 3, 0, 0, 0, 0, 1]
        #expect(throws: BytesError.unsupported) {
            _ = try output.withOutputRawSpan { span throws(BytesError) in try decompressor.decompressAll(stream.span.bytes, into: &span) }
        }
    }

    /// Random bytes: only zlib's test ever passes (about 1 in 1,000: method 8 is 1 in 16, a window of at most 32 KiB
    /// 1 in 2, the check bits 1 in 31; a preset dictionary is still zlib), and nothing else is named.
    @Test func randomBytes() {
        var rng = SplitMix64(seed: 2026)
        var zlib = 0
        let tries = 200_000
        for _ in 0..<tries {
            let value = rng.next()
            let bytes = (0..<6).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * $0)) }
            switch DecompressionFormat(detecting: bytes.span.bytes) {
            case nil: break
            case .deflate(.zlib)?: zlib += 1
            case let other?: Issue.record("\(bytes) read as \(other)")
            }
        }
        #expect(zlib > tries / 2000 && zlib < tries / 500, "\(zlib) of \(tries)")
    }
}

/// `GzipHeader` (open item 24): parsed from a member's first bytes with every optional field, written by the encoders
/// (sequential and parallel, whole and streamed into small pieces), round-tripped, read from the system `gzip`'s files,
/// and refused as each kind of bad header.
@Suite struct GzipHeaderTests {
    static let text = SampleBytes.text(100_000, seed: 24)
    static let full = GzipHeader(
        name: Array("notes, 2026.txt".utf8), comment: Array("for the record".utf8), modificationTime: 1_764_000_000,
        operatingSystem: 3, isText: true, extraField: [0x41, 0x70, 4, 0, 1, 2, 3, 4], hasHeaderCRC: true
    )

    /// The encoders' output for `header`: sequential whole and streamed into 1-byte pieces, parallel whole and
    /// streamed.
    static func encodings(_ header: GzipHeader, level: Int = 6) throws -> [(String, [UInt8])] {
        var encoder = DeflateEncoder(gzipHeader: header, level: level)
        var whole = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: text.count))
        let count = try whole.withOutputRawSpan { span throws(BytesError) -> Int in
            try encoder.compressAll(text.span.bytes, into: &span)
            return span.byteCount
        }
        whole.removeSubrange(count...)
        encoder.reset()
        var pieces: [UInt8] = []
        var piece = [UInt8](repeating: 0, count: 1)
        var offset = 0
        while true {
            let progress = try piece.withOutputRawSpan { span throws(BytesError) in
                try encoder.compress(text.span.bytes.extracting(offset...), into: &span, flush: .finish)
            }
            pieces += piece.prefix(progress.produced)
            offset += progress.consumed
            if progress.status == .finished { break }
        }
        var parallel = ParallelDeflateEncoder(gzipHeader: header, level: level, chunkSize: 32 << 10, lanes: 3)
        var parallelWhole = [UInt8](repeating: 0, count: parallel.maximumCompressedSize(forByteCount: text.count))
        let parallelCount = try parallelWhole.withOutputRawSpan { span throws(BytesError) -> Int in
            try parallel.compressAll(text.span.bytes, into: &span)
            return span.byteCount
        }
        parallelWhole.removeSubrange(parallelCount...)
        parallel.reset()
        var parallelPieces: [UInt8] = []
        offset = 0
        var chunk = [UInt8](repeating: 0, count: 7)
        while true {
            let progress = try chunk.withOutputRawSpan { span throws(BytesError) in
                try parallel.compress(text.span.bytes.extracting(offset...), into: &span, flush: .finish)
            }
            parallelPieces += chunk.prefix(progress.produced)
            offset += progress.consumed
            if progress.status == .finished { break }
        }
        return [("whole", whole), ("1-byte pieces", pieces), ("parallel", parallelWhole), ("parallel pieces", parallelPieces)]
    }

    /// Every field written and read back; the streams decode (Bytes' decoder, whole and cut at every header byte, and
    /// the system's gzip).
    @Test(arguments: [GzipHeaderTests.full, GzipHeader(name: [0x80, 0xFF, 0x41]), GzipHeader(comment: []), GzipHeader(hasHeaderCRC: true),
                      GzipHeader(extraField: [])])
    func roundTrips(_ header: GzipHeader) throws {
        for (name, stream) in try Self.encodings(header) {
            let (parsed, size) = try GzipHeader.parse(stream.span.bytes)
            #expect(parsed == header, "\(name)")
            #expect(size == header.encodedByteCount, "\(name)")
            for (way, result) in gunzipEveryWay(stream, cuts: Array(1..<size)) {
                #expect(result == .success(Self.text), "\(name), \(way)")
            }
            #expect(try ExternalTool.output("/usr/bin/gzip", ["-dc"], input: stream) == Self.text, "\(name): gzip")
        }
    }

    /// The default header (`GzipHeader()`) writes exactly what `DeflateEncoder(format: .gzip)` does, at every level
    /// (XFL follows the level).
    @Test func defaultIsUnchanged() throws {
        for level in [0, 1, 6, 9] {
            let plain = encodeAll(Self.text, format: .gzip, level: level)
            let encodings = try Self.encodings(GzipHeader(), level: level)
            #expect(encodings[0].1 == plain, "level \(level)")
            let (header, size) = try GzipHeader.parse(plain.span.bytes)
            #expect(header == GzipHeader() && size == 10)
        }
    }

    /// The system's `gzip` stores the file's name and time (`-N`, its default): both read back.
    @Test func systemGzipsName() throws {
        let directory = try TemporaryDirectory()
        let file = directory.path("field notes.txt")
        try Data(Self.text).write(to: file)
        let time = Date(timeIntervalSince1970: 1_700_000_123)
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
        let stream = try ExternalTool.output("/usr/bin/gzip", ["-N", "-c", file.path])
        let (header, size) = try GzipHeader.parse(stream.span.bytes)
        #expect(header.name == Array("field notes.txt".utf8))
        #expect(header.modificationTime == 1_700_000_123)
        #expect(size == 10 + "field notes.txt".utf8.count + 1)
    }

    /// Each bad header: cut short anywhere (`insufficientData`), not gzip (`invalidValue`), reserved flags
    /// (`unsupported`), a wrong header CRC (`checksumMismatch`).
    @Test func refusals() throws {
        let stream = try Self.encodings(Self.full)[0].1
        let size = Self.full.encodedByteCount
        for cut in 0..<size {
            #expect(throws: BytesError.insufficientData, "\(cut) bytes") { _ = try GzipHeader.parse(stream.span.bytes.extracting(0..<cut)) }
        }
        var notGzip = stream
        notGzip[2] = 7
        #expect(throws: BytesError.invalidValue) { _ = try GzipHeader.parse(notGzip.span.bytes) }
        var reserved = stream
        reserved[3] |= 0x20
        #expect(throws: BytesError.unsupported) { _ = try GzipHeader.parse(reserved.span.bytes) }
        var badCRC = stream
        badCRC[size - 1] ^= 1
        #expect(throws: BytesError.checksumMismatch) { _ = try GzipHeader.parse(badCRC.span.bytes) }
        var badName = stream
        badName[12 + 8] ^= 1 // A byte of the name: the CRC no longer matches.
        #expect(throws: BytesError.checksumMismatch) { _ = try GzipHeader.parse(badName.span.bytes) }
    }
}
