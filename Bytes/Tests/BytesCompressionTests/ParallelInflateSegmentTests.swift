import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Testing

@Suite struct ParallelInflateSegmentTests {
    /// More segments than lanes: a megabyte in 32 KB independent chunks on 2 and 3 lanes is cut into up to 4
    /// segments a lane, which the lanes take in turn. Every format decodes to the original, the checksums combined
    /// across all the segments, and decoding again with the same decoder (its segments' buffers kept) agrees.
    @Test(arguments: [2, 3])
    func decodesManySegmentsPerLane(lanes: Int) throws {
        let large = largePrefix()
        for format: DeflateFormat in [.raw, .zlib, .gzip] {
            var encoder = ParallelDeflateEncoder(format: format, level: 1, chunkSize: 32 << 10, lanes: 4, independentChunks: true)
            let compressed = try parallelEncodeAll(&encoder, large)
            var decoder = ParallelDeflateDecoder(format: format, lanes: lanes)
            for round in 0..<2 {
                let result = parallelDecodeAll(&decoder, compressed, capacity: large.count + 100)
                #expect(result.0 == .decoded(large), "\(format), \(lanes) lanes, round \(round)")
                #expect(result.segments > lanes, "\(format): more segments (\(result.segments)) than lanes")
                #expect(result.segments <= 4 * lanes)
            }
            // A corrupt trailer still fails, however many segments.
            var bad = compressed
            if format != .raw {
                bad[bad.count - 2] ^= 1
                #expect(parallelDecodeAll(&decoder, bad, capacity: large.count + 100).0 == .failed, "\(format)")
            }
        }
    }

    /// One lane: the segments decode one after another on it, the first with the container's header.
    @Test func decodesSegmentsOnOneLane() throws {
        let large = largePrefix()
        var encoder = ParallelDeflateEncoder(format: .gzip, level: 6, chunkSize: 64 << 10, lanes: 4, independentChunks: true)
        let compressed = try parallelEncodeAll(&encoder, large)
        var decoder = ParallelDeflateDecoder(format: .gzip, lanes: 1)
        let result = parallelDecodeAll(&decoder, compressed, capacity: large.count)
        #expect(result.0 == .decoded(large))
        #expect(result.segments == 4)
    }
}
