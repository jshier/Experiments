import Bytes
import BytesCrypto

// (Decoding a segment is BytesCompressionAsync's `BlockContext.decompress`, with the decoder `ParallelBlockDecoder`
// makes per task for `DecompressionFormat(aeaSegment:)`; until 2026-11-23 it was this file's `SegmentCodec`.)

/// The segment checks: MAC over the stored bytes, checksum over the decoded ones.
enum SegmentChecks {
    static func verifyMAC(_ archive: AEAArchive, segment: Int, stored: RawSpan) throws(AEAError) {
        let mac = AEAKeys.segmentMAC(archive.segmentKeys[segment].mac, data: stored)
        guard archive.macMatches(segment, mac) else {
            throw .authenticationFailed("segment \(segment)")
        }
    }

    static func verifyChecksum(_ archive: AEAArchive, segment: Int, raw: RawSpan) throws(AEAError) {
        switch archive.rootHeader.checksum {
        case .none:
            return
        case .sha256:
            let digest = SHA256.hash(raw)
            guard archive.checksumMatches(segment, digest.span.bytes) else {
                throw .checksumMismatch(segment: segment)
            }
        case .murmur64:
            let hash = bitCast(Murmur64.hash(raw).littleEndian, to: InlineArray<8, UInt8>.self)
            guard archive.checksumMatches(segment, hash.span.bytes) else {
                throw .checksumMismatch(segment: segment)
            }
        }
    }
}

/// The archive's `murmur64` checksum: MurmurHash64A (MurmurHash2's 64-bit variant) with seed 0xE2236FDC26A5F6D2
/// (seed from blacktop/ipsw's reader; checked against `aea encrypt -checksum murmur64`).
enum Murmur64 {
    static func hash(_ bytes: RawSpan) -> UInt64 {
        let m: UInt64 = 0xC6A4_A793_5BD1_E995
        var h: UInt64 = 0xE223_6FDC_26A5_F6D2 ^ (UInt64(bytes.byteCount) &* m)
        // Words loaded from the span directly, the loop bounded by the count: the loads' checks fold (the same machine
        // code as unchecked loads, 2026-11-23).
        let words = bytes.byteCount / 8
        for index in 0..<words {
            var k = UInt64(littleEndian: bytes.load(fromByteOffset: index &* 8, as: UInt64.self))
            k &*= m
            k ^= k >> 47
            k &*= m
            h ^= k
            h &*= m
        }
        let tail = bytes.byteCount &- words &* 8
        if tail > 0 {
            var value: UInt64 = 0
            for index in 0..<tail {
                value |= UInt64(bytes.load(fromByteOffset: words &* 8 &+ index, as: UInt8.self)) << (8 &* index)
            }
            h ^= value
            h &*= m
        }
        h ^= h >> 47
        h &*= m
        h ^= h >> 47
        return h
    }
}
