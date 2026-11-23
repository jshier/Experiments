import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTesting
import BytesTestSupport
import Foundation
import Testing
import zlib

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

    /// 512 KB in 16 independent stored chunks (level 0), one of them random bytes with a `00 00 FF FF` every 256
    /// bytes: stored data, so the markers appear as they are in the stream, where split points land on them. The
    /// segment before such a false split decodes on to the next real one, and only it: the rest still decode in
    /// parallel, and nothing is decoded again.
    static let falseSplitData: [UInt8] = {
        var rng = SplitMix64(seed: 11)
        let text = Array(largePrefix().prefix(512 << 10))
        var data: [UInt8] = []
        for chunk in 0..<16 {
            if chunk == 5 {
                for offset in 0..<(32 << 10) {
                    data.append(offset % 256 < 4 ? [0, 0, 0xFF, 0xFF][offset % 256] : UInt8.random(in: 0...255, using: &rng))
                }
            } else {
                data += text[(chunk * (32 << 10))..<((chunk + 1) * (32 << 10))]
            }
        }
        return data
    }()

    @Test func falseSplitCostsOnlyItsSegment() throws {
        let data = Self.falseSplitData
        for format: DeflateFormat in [.raw, .zlib, .gzip] {
            var encoder = ParallelDeflateEncoder(format: format, level: 0, chunkSize: 32 << 10, lanes: 4, independentChunks: true)
            let compressed = try parallelEncodeAll(&encoder, data)
            // Segments at least 16 KB apart: the 32 KB chunks' own ends, and a false split in the random one.
            var decoder = ParallelDeflateDecoder(format: format, lanes: 8)
            let result = parallelDecodeAll(&decoder, compressed, capacity: data.count)
            #expect(result.0 == .decoded(data), "\(format)")
            #expect(decoder.lastSplitCount > 12, "\(format): \(decoder.lastSplitCount) splits")
            #expect(result.segments > 1 && result.segments < decoder.lastSplitCount, "\(format): \(result.segments) of \(decoder.lastSplitCount)")
            #expect(decoder.lastRepairCount == 0, "\(format)")
        }
    }

    /// zlib's encoding with a flush every 32 KB of input, full flushes (history reset: what follows decodes alone)
    /// and sync flushes (history kept: matches reach back across them) in turn. Segments starting after a sync
    /// flush fail; their regions are decoded again after the real history, and the segments after full flushes are
    /// still accepted.
    @Test func failedSegmentsAreDecodedAgainInPlace() {
        let large = largePrefix()
        for format: DeflateFormat in [.raw, .zlib, .gzip] {
            let compressed = zlibCompressFlushing(large, format: format, every: 32 << 10, flushes: [Z_FULL_FLUSH, Z_SYNC_FLUSH])
            var decoder = ParallelDeflateDecoder(format: format, lanes: 4)
            let result = parallelDecodeAll(&decoder, compressed, capacity: large.count)
            #expect(result.0 == .decoded(large), "\(format)")
            #expect(decoder.lastRepairCount > 0, "\(format)")
            #expect(result.segments > 1, "\(format)")
            // Too little room fails in the repair as in a segment's copy.
            #expect(parallelDecodeAll(&decoder, compressed, capacity: large.count - 1).0 == .failed, "\(format)")
            // Sync flushes only: every segment after the first fails, and the rest is decoded in place.
            let synced = zlibCompressFlushing(large, format: format, every: 32 << 10, flushes: [Z_SYNC_FLUSH])
            let fromSynced = parallelDecodeAll(&decoder, synced, capacity: large.count)
            #expect(fromSynced.0 == .decoded(large), "\(format), sync flushes")
            #expect(fromSynced.segments == 1, "\(format), sync flushes")
        }
    }

    /// Data after the stream with `00 00 FF FF` in it: a split there is past the final block, and the segment
    /// holding the stream's end finishes it. The call reports the stream's length and leaves the rest. (zlib: in gzip,
    /// bytes after a member must start another.)
    @Test func splitsAfterTheStreamAreIgnored() throws {
        let large = largePrefix()
        var encoder = ParallelDeflateEncoder(format: .zlib, level: 1, chunkSize: 32 << 10, lanes: 4, independentChunks: true)
        let compressed = try parallelEncodeAll(&encoder, large)
        var trailing: [UInt8] = []
        while trailing.count < 256 << 10 { trailing += [0, 0, 0xFF, 0xFF, 1, 2, 3] }
        let input = compressed + trailing
        var decoder = ParallelDeflateDecoder(format: .zlib, lanes: 8)
        var output = [UInt8](repeating: 0, count: large.count)
        let consumed = try output.withOutputRawSpan { span throws(BytesError) in
            try decoder.decompressAll(input.span.bytes, into: &span)
        }
        #expect(consumed == compressed.count && output == large)
        #expect(decoder.lastSegmentCount > 1)
    }

    /// Every lane count from 1 to 32 on generated streams: independent level 1 chunks, and the false splits above
    /// (stored, level 0).
    @Test func everyLaneCount() throws {
        let text = Array(largePrefix().prefix(256 << 10))
        var encoder = ParallelDeflateEncoder(format: .zlib, level: 1, chunkSize: 32 << 10, lanes: 4, independentChunks: true)
        var stored = ParallelDeflateEncoder(format: .zlib, level: 0, chunkSize: 32 << 10, lanes: 4, independentChunks: true)
        let streams = try [
            (text, parallelEncodeAll(&encoder, text)),
            (Self.falseSplitData, parallelEncodeAll(&stored, Self.falseSplitData)),
        ]
        for lanes in 1...32 {
            var decoder = ParallelDeflateDecoder(format: .zlib, lanes: lanes)
            for (index, (data, compressed)) in streams.enumerated() {
                let result = parallelDecodeAll(&decoder, compressed, capacity: data.count)
                #expect(result.0 == .decoded(data), "stream \(index), \(lanes) lanes")
                #expect(lanes == 1 || result.segments > 1, "stream \(index), \(lanes) lanes")
            }
        }
    }

    /// Silesia (`Tools/corpus fetch`; files that are missing are skipped) in independent chunks at levels 1 and 6, as
    /// the benchmarks encode it, decoded at every lane count from 1 to 32. mozilla at level 1 has a `00 00 FF FF` in
    /// Huffman-coded data where splits land at 25, 28, and 32 lanes (and 11, 22, 29–31).
    static func checkCorpusAtEveryLaneCount() throws {
        for name in ["mozilla", "dickens", "samba", "x-ray", "ooffice"] {
            guard let url = Corpus.file("silesia/\(name)"), let contents = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
                continue
            }
            let data = [UInt8](contents)
            for level in [1, 6] {
                var encoder = ParallelDeflateEncoder(format: .raw, level: level, chunkSize: 256 << 10, lanes: 24, independentChunks: true)
                let compressed = try parallelEncodeAll(&encoder, data)
                for lanes in 1...32 {
                    var decoder = ParallelDeflateDecoder(format: .raw, lanes: lanes)
                    let result = parallelDecodeAll(&decoder, compressed, capacity: data.count)
                    #expect(result.0 == .decoded(data), "\(name) level \(level), \(lanes) lanes")
                    #expect(lanes == 1 || result.segments > 1, "\(name) level \(level), \(lanes) lanes")
                    #expect(decoder.lastRepairCount == 0, "\(name) level \(level), \(lanes) lanes")
                }
            }
        }
    }
}

@Suite(.bulk) struct ParallelInflateSegmentBulkTests {
    @Test func corpusAtEveryLaneCount() throws { try ParallelInflateSegmentTests.checkCorpusAtEveryLaneCount() }
}

/// zlib's encoding of `data` with a flush after every `every` bytes of input, taking `flushes` in turn
/// (`Z_FULL_FLUSH` resets the history, `Z_SYNC_FLUSH` keeps it), and `Z_FINISH` at the end.
func zlibCompressFlushing(_ data: [UInt8], format: DeflateFormat, every: Int, flushes: [Int32]) -> [UInt8] {
    Zlib.compress(data, windowBits: format.zlibWindowBits, flushingEvery: every, flushes: flushes)
}
