import Bytes
import BytesCompression
import BytesTestSupport
import HTTPPayload
import Testing

/// Content codings both ways, against BytesCompression's own encoders and the system's zlib-compatible output where it
/// matters (raw DEFLATE under `deflate`).
@Suite struct ContentCodingTests {
    static let body: [UInt8] = {
        var generator = SplitMix64(seed: 11)
        // Compressible: words from a small vocabulary.
        let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"].map { Array($0.utf8) + [0x20] }
        var bytes: [UInt8] = []
        while bytes.count < 300_000 {
            bytes += words[Int(generator.next() % 8)]
        }
        return bytes
    }()

    /// Encodes `body` with `coding` in 7,000-byte pieces into an output of `room`-byte steps.
    static func encode(_ body: [UInt8], _ coding: HTTPContentCoding) throws -> [UInt8] {
        var encoder = try HTTPContentEncoder(coding)
        var output = [UInt8](repeating: 0, count: body.count + 1_024)
        var written = 0, offset = 0
        while true {
            let piece = Array(body[offset..<min(body.count, offset + 7_000)])
            let flush: TransformFlush = offset + piece.count == body.count ? .finish : .none
            let progress = try output.withOutputRawSpan(overwritingFrom: written) { span throws(HTTPPayloadError) in
                try encoder.encode(piece.span.bytes, into: &span, flush: flush)
            }
            written += progress.produced
            offset += progress.consumed
            if progress.status == .finished || (flush == .finish && progress.consumed == piece.count && progress.status != .needsOutput) && coding == .identity { break }
            if progress.status == .finished { break }
        }
        return Array(output[..<written])
    }

    /// Decodes `coded` handed over `step` bytes at a time into 4,096-byte outputs.
    static func decode(_ coded: [UInt8], contentEncoding: String, step: Int, limit: Int = 1 << 30) throws -> [UInt8] {
        var decoder = try HTTPContentDecoder(contentEncoding: Array(contentEncoding.utf8).span.bytes, maximumDecodedByteCount: limit)
        var result: [UInt8] = []
        var pending: [UInt8] = []
        var offset = 0
        var out = [UInt8](repeating: 0, count: 4_096)
        var stalled = false
        while true {
            // More input when there's room under `step`, or whenever the last call made no progress (a decoder may hold
            // a partial unit until more arrives).
            if offset < coded.count, pending.count < step || stalled {
                let take = min(step, coded.count - offset)
                pending += coded[offset..<offset + take]
                offset += take
            }
            let input = pending
            let progress = try out.withOutputRawSpan { span throws(HTTPPayloadError) in try decoder.decode(input.span.bytes, into: &span) }
            result += out[..<progress.produced]
            pending.removeFirst(progress.consumed)
            if progress.status == .finished { break }
            stalled = progress.consumed == 0 && progress.produced == 0
            if stalled, offset == coded.count { break }
        }
        try decoder.finish()
        return result
    }

    /// The whole body in large steps; its first 3 KB a byte and 100 bytes at a time (debug-build codecs are slow, and
    /// small steps exercise the same resumption on less data).
    @Test(arguments: [HTTPContentCoding.gzip, .deflate, .brotli, .identity])
    func roundTrips(coding: HTTPContentCoding) throws {
        let coded = try Self.encode(Self.body, coding)
        if coding != .identity { #expect(coded.count < Self.body.count / 2) }
        #expect(try Self.decode(coded, contentEncoding: String(describing: coding.token), step: 65_536) == Self.body)
        let small = Array(Self.body.prefix(3_000))
        let smallCoded = try Self.encode(small, coding)
        for step in [1, 100] {
            #expect(try Self.decode(smallCoded, contentEncoding: String(describing: coding.token), step: step) == small, "step \(step)")
        }
    }

    @Test func rawDeflateUnderDeflate() throws {
        var encoder = DeflateEncoder(format: .raw, level: 6)
        var output = [UInt8](repeating: 0, count: Self.body.count)
        let written = try output.withOutputRawSpan { span throws(BytesError) in
            try encoder.compressAll(Self.body.span.bytes, into: &span)
            return span.byteCount
        }
        #expect(try Self.decode(Array(output[..<written]), contentEncoding: "deflate", step: 10_000) == Self.body)
    }

    @Test func stackedCodings() throws {
        // Applied gzip, then br: `Content-Encoding: gzip, br`.
        let coded = try Self.encode(Self.encode(Self.body, .gzip), .brotli)
        #expect(try Self.decode(coded, contentEncoding: "gzip, br", step: 3_000) == Self.body)
        #expect(try Self.decode(coded, contentEncoding: "identity, GZIP , br", step: 70_000) == Self.body)
    }

    @Test func zstdDecodes() throws {
        // `printf 'hello, zstd\n' | zstd -19 -c` (zstd 1.5, Homebrew): a frame with its checksum.
        let frame: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x68, 0x61, 0x00, 0x00, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x2C, 0x20,
                              0x7A, 0x73, 0x74, 0x64, 0x0A, 0x84, 0x58, 0x5C, 0xA0]
        for step in [1, 5, 100] {
            #expect(try Self.decode(frame, contentEncoding: "zstd", step: step) == Array("hello, zstd\n".utf8))
        }
    }

    /// One decoder for several bodies, each coded differently (as on one connection), stacked and not, with a body cut
    /// short in between: a reset leaves nothing of the last body behind. gzip's and deflate's bodies (zlib, and raw
    /// DEFLATE under the name) share BytesCompression's one DEFLATE decoder, reset to each container.
    @Test func resetForEachBody() throws {
        let small = Array(Self.body.prefix(20_000))
        let gzip = try Self.encode(small, .gzip), brotli = try Self.encode(small, .brotli)
        let stacked = try Self.encode(gzip, .brotli)
        let zlib = try Self.encode(small, .deflate)
        var rawEncoder = DeflateEncoder(format: .raw, level: 6)
        var raw = [UInt8](repeating: 0, count: small.count + 1_024)
        let rawCount = try raw.withOutputRawSpan { span throws(BytesError) in
            try rawEncoder.compressAll(small.span.bytes, into: &span)
            return span.byteCount
        }
        raw.removeSubrange(rawCount...)
        var decoder = try HTTPContentDecoder(applied: .identity)
        var out = [UInt8](repeating: 0, count: 64 << 10)
        func decodeAll(_ coded: [UInt8], _ encoding: String, cut: Int = 0) throws -> [UInt8] {
            try decoder.reset(contentEncoding: Array(encoding.utf8).span.bytes)
            let input = Array(coded.dropLast(cut))
            let progress = try out.withOutputRawSpan { span throws(HTTPPayloadError) in try decoder.decode(input.span.bytes, into: &span) }
            return Array(out[..<progress.produced])
        }
        let bodies = [
            (gzip, "gzip"), (zlib, "deflate"), (brotli, "br"), (raw, "deflate"), (stacked, "gzip, br"), (zlib, "deflate"), (gzip, "gzip"),
            (raw, "deflate"), (small, "identity"),
        ]
        for (coded, encoding) in bodies {
            _ = try decodeAll(coded, encoding, cut: coded.count / 3)
            if encoding != "identity" { #expect(throws: HTTPPayloadError.malformed) { try decoder.finish() } }
            #expect(try decodeAll(coded, encoding) == small, "\(encoding)")
            try decoder.finish()
            #expect(decoder.decodedByteCount == small.count)
        }
        #expect(throws: HTTPPayloadError.unsupportedCoding) { try decoder.reset(contentEncoding: Array("compress".utf8).span.bytes) }
    }

    /// A stacked body fed in 7-byte pieces (through the carry and middle buffers) that turns to garbage halfway: the
    /// decode throws from inside the stacked decode, and after a reset the same decoder decodes a whole body in the same
    /// pieces. (`resetForEachBody` is the one that catches a reset leaving carried bytes behind.)
    @Test func resetAfterAThrowingDecode() throws {
        let small = Array(Self.body.prefix(20_000))
        let stacked = try Self.encode(Self.encode(small, .gzip), .brotli)
        var corrupted = stacked
        corrupted.replaceSubrange((stacked.count / 2)..., with: [UInt8](repeating: 0xFF, count: stacked.count - stacked.count / 2))
        var decoder = try HTTPContentDecoder(contentEncoding: Array("gzip, br".utf8).span.bytes)
        var out = [UInt8](repeating: 0, count: 64 << 10)
        /// Decodes `coded` in 7-byte pieces into `out`: the bytes produced, or the error.
        func decodePieces(_ coded: [UInt8]) -> Result<[UInt8], HTTPPayloadError> {
            var produced: [UInt8] = []
            var offset = 0
            while offset < coded.count {
                let piece = Array(coded[offset..<min(coded.count, offset + 7)])
                do throws(HTTPPayloadError) {
                    let progress = try out.withOutputRawSpan { span throws(HTTPPayloadError) in try decoder.decode(piece.span.bytes, into: &span) }
                    produced += out[..<progress.produced]
                    offset += progress.consumed
                    if progress.status == .finished { break }
                } catch {
                    return .failure(error)
                }
            }
            return .success(produced)
        }
        guard case .failure = decodePieces(corrupted) else {
            Issue.record("The corrupted body decoded")
            return
        }
        try decoder.reset(contentEncoding: Array("gzip, br".utf8).span.bytes)
        #expect(decodePieces(stacked) == .success(small))
        try decoder.finish()
    }

    @Test func limitsAndErrors() throws {
        let coded = try Self.encode(Self.body, .gzip)
        #expect(throws: HTTPPayloadError.tooLarge) { _ = try Self.decode(coded, contentEncoding: "gzip", step: 65_536, limit: 100_000) }
        #expect(throws: HTTPPayloadError.unsupportedCoding) { _ = try HTTPContentDecoder(contentEncoding: Array("compress".utf8).span.bytes) }
        #expect(throws: HTTPPayloadError.tooManyCodings) { _ = try HTTPContentDecoder(contentEncoding: Array("gzip, br, gzip".utf8).span.bytes) }
        #expect(throws: HTTPPayloadError.malformed) { _ = try Self.decode(Array(coded.prefix(coded.count / 2)), contentEncoding: "gzip", step: 4_096) }
        var corrupted = coded
        corrupted[corrupted.count / 2] ^= 0xFF
        corrupted[corrupted.count / 2 + 1] ^= 0x5A
        #expect(throws: (any Error).self) { _ = try Self.decode(corrupted, contentEncoding: "gzip", step: 65_536) }
    }

    /// Zstandard bodies (BytesCompression's encoder, the HTTP window): decoded by the content decoder, whole and in
    /// pieces, and by a decoder limited to RFC 9659's 8 MB window.
    @Test func zstdRoundTrips() throws {
        let coded = try Self.encode(Self.body, .zstd)
        #expect(coded.count < Self.body.count / 3)
        for step in [65_536, 1_000, 7] {
            #expect(try Self.decode(coded, contentEncoding: "zstd", step: step) == Self.body, "step \(step)")
        }
    }
}

/// Regressions from the adversarial review.
@Suite struct ContentCodingReviewTests {
    /// A zstd frame needing a 16 MiB window (over RFC 9659's 8 MB) is too large, not "out of room": a raw block of "hi"
    /// with Window_Descriptor 0x70 (2^24). The same frame with a 1 MiB window (0x50) decodes.
    @Test func zstdWindowOverTheLimit() throws {
        let large: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x70, 0x11, 0x00, 0x00, 0x68, 0x69]
        var small = large
        small[5] = 0x50
        #expect(try ContentCodingTests.decode(small, contentEncoding: "zstd", step: 100) == Array("hi".utf8))
        #expect(throws: HTTPPayloadError.tooLarge) { _ = try ContentCodingTests.decode(large, contentEncoding: "zstd", step: 100) }
    }

    /// Two codings: the outer stream cut short after the inner one ended is malformed, not finished.
    @Test func stackedFinishChecksEveryStage() throws {
        let coded = try ContentCodingTests.encode(ContentCodingTests.encode(Array(ContentCodingTests.body.prefix(5_000)), .gzip), .brotli)
        #expect(throws: HTTPPayloadError.malformed) {
            _ = try ContentCodingTests.decode(Array(coded.dropLast(2)), contentEncoding: "gzip, br", step: 100_000)
        }
    }
}

/// Bodies arrive in pieces that aren't contiguous (chunk data between size lines): each piece is passed once, never
/// again with more after it, so the decoder must keep what a codec leaves unconsumed.
@Suite struct ContentCodingPieceTests {
    /// Decodes `coded` in pieces of 1 to 300 bytes chosen by `seed`, or of `pieceSize` bytes.
    static func decodePieces(_ coded: [UInt8], contentEncoding: String, seed: UInt64, pieceSize: Int? = nil) throws -> [UInt8] {
        var decoder = try HTTPContentDecoder(contentEncoding: Array(contentEncoding.utf8).span.bytes)
        var generator = SplitMix64(seed: seed)
        var result: [UInt8] = []
        var out = [UInt8](repeating: 0, count: 1_000)
        var offset = 0
        while offset < coded.count {
            let size = min(pieceSize ?? Int(generator.next() % 300) + 1, coded.count - offset)
            // A fresh array per piece: nothing contiguous with what came before.
            var piece = Array(coded[offset..<offset + size])
            offset += size
            while !piece.isEmpty {
                let input = piece
                let progress = try out.withOutputRawSpan { span throws(HTTPPayloadError) in try decoder.decode(input.span.bytes, into: &span) }
                result += out[..<progress.produced]
                piece.removeFirst(progress.consumed)
                if progress.consumed == 0, progress.produced == 0 { break }
            }
        }
        // Drain what's still buffered.
        while !decoder.isFinished {
            let progress = try out.withOutputRawSpan { span throws(HTTPPayloadError) in try decoder.decode(RawSpan(), into: &span) }
            result += out[..<progress.produced]
            if progress.produced == 0 { break }
        }
        try decoder.finish()
        return result
    }

    @Test(arguments: ["gzip", "br", "deflate", "gzip, br"])
    func piecesNeverPassedAgain(contentEncoding: String) throws {
        let body = Array(ContentCodingTests.body.prefix(60_000))
        let codings = contentEncoding.split(separator: ",").map { String($0.filter { $0 != " " }) }
        var coded = body
        for coding in codings {
            coded = try ContentCodingTests.encode(coded, HTTPContentCoding(token: Array(coding.utf8).span.bytes)!)
        }
        for seed in 0..<5 as Range<UInt64> {
            #expect(try Self.decodePieces(coded, contentEncoding: contentEncoding, seed: seed) == body, "seed \(seed)")
        }
    }

    /// Pieces of one byte, each passed once: what a codec holds back (a DEFLATE block's header, a Brotli prefix code, a
    /// partial symbol) waits in the carry buffer, sized from the codecs' units (`DecompressionFormat.maximumUnitByteCount`:
    /// 902 bytes, twice Brotli's, where it was 132 KiB; Brotli's largest headers are checked against its unit in
    /// BytesCompression's StreamingUnitTests).
    @Test(arguments: ["gzip", "br", "deflate", "zstd", "gzip, br"])
    func aByteAtATime(contentEncoding: String) throws {
        let body = Array(ContentCodingTests.body.prefix(20_000))
        let codings = contentEncoding.split(separator: ",").map { String($0.filter { $0 != " " }) }
        var coded = body
        for coding in codings {
            coded = try ContentCodingTests.encode(coded, HTTPContentCoding(token: Array(coding.utf8).span.bytes)!)
        }
        #expect(try Self.decodePieces(coded, contentEncoding: contentEncoding, seed: 0, pieceSize: 1) == body)
    }
}
