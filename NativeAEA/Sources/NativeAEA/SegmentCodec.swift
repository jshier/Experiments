import Bytes
import BytesCompression
import BytesCrypto

/// Decodes one segment's stored bytes, and checks its MAC and checksum. One per decoding thread: it owns the
/// decoder's state, made once, and only what its archive's compression uses (every decoder's tables are zeroed when
/// made, so unused ones would cost memory per thread). Every compression is BytesCompression's, in Swift.
struct SegmentCodec: ~Copyable {
    let compression: AEACompression
    /// BytesCompression's decoder, made for the archive's compression only: zlib (with the RFC 1950 wrapper, its
    /// Adler-32 checked), LZMA (an xz stream per segment), LZFSE, LZRAVEN, LZBITMAP, LZVN, or LZ4 (raw blocks in AEA
    /// segments, Compression's `bv41` frames in `pbz4` blocks). None for an uncompressed archive.
    private var decompressor: Decompressor

    init(compression: AEACompression, framedLZ4: Bool = false) {
        self.compression = compression
        let format: DecompressionFormat? = switch compression {
        case .none: nil
        case .zlib: .deflate(.zlib)
        case .lzma: .xz()
        case .lzfse: .lzfse
        case .lzvn: .lzvn
        case .lz4: .lz4(framed: framedLZ4)
        case .lzbitmap: .lzbitmap
        case .lzraven: .lzraven
        }
        decompressor = Decompressor()
        // Throws only for a negative size or hint, which none of these has.
        if let format { try? decompressor.reset(for: format) }
    }

    /// Decodes `input` (the segment as stored) into `output`.
    ///
    /// - Parameters:
    ///   - input: The stored bytes.
    ///   - output: Room for exactly the segment's raw size.
    /// - Throws: ``AEAError/decompressionFailed(segment:_:)`` if it doesn't decode to exactly `output`'s size.
    mutating func decode(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer, segment: Int) throws(AEAError) {
        if input.count == output.count {
            // Stored: segments that don't compress are kept as they are.
            unsafe output.copyMemory(from: input) // Both are `count` bytes: safe.
            return
        }
        // An uncompressed archive's segments are all stored (above).
        guard compression != .none else { throw .unsupportedCompression(compression.rawValue) }
        // `output` is the segment's room in a buffer this thread owns until it publishes the segment.
        var span = unsafe OutputRawSpan(buffer: output, initializedCount: 0)
        let consumed: Int
        do throws(BytesError) {
            // Exactly the segment's size (anything else throws); returns the input it took.
            consumed = try unsafe decompressor.decompressAll(RawSpan(_unsafeBytes: input), into: &span, decodedSize: output.count)
        } catch {
            throw .decompressionFailed(segment: segment, "\(error)")
        }
        let written = unsafe span.finalize(for: output)
        guard written == output.count, consumed == input.count else {
            throw .decompressionFailed(segment: segment, "decoded \(written) of \(output.count) bytes")
        }
    }
}

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
            let hash = Murmur64.hash(raw).littleEndian
            guard withUnsafeBytes(of: hash, { unsafe archive.checksumMatches(segment, RawSpan(_unsafeBytes: $0)) }) else {
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
        // Words loaded from the span directly, the loop bounded by the count: no per-word check or `try`.
        let words = bytes.byteCount / 8
        for index in 0..<words {
            // Word `index` of `words`, all within the span: safe.
            var k = UInt64(littleEndian: unsafe bytes.unsafeLoadUnaligned(fromByteOffset: index &* 8, as: UInt64.self))
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
                value |= UInt64(unsafe bytes.unsafeLoad(fromByteOffset: words &* 8 &+ index, as: UInt8.self)) << (8 &* index) // The tail's bytes: safe.
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
