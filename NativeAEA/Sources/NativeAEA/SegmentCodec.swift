import Bytes
import BytesCompression
import BytesCrypto
import Compression

/// Which implementation decodes LZMA (xz) segments.
public enum SegmentDecoderBackend: String, Sendable, CaseIterable {
    /// BytesCompression's decoder, in Swift.
    case bytes
    /// Apple's Compression framework (`COMPRESSION_LZMA`, which is liblzma).
    case system
}

/// Decodes one segment's stored bytes, and checks its MAC and checksum. One per decoding thread: it owns the
/// decoder's state and Compression's scratch memory, made once.
struct SegmentCodec: ~Copyable {
    let compression: AEACompression
    let backend: SegmentDecoderBackend
    private let scratch: RawStorage?
    /// zlib segments (with the RFC 1950 wrapper): BytesCompression's decoder, which checks the Adler-32 too.
    private var inflater = DeflateDecoder(format: .zlib)
    /// LZMA (xz) segments with ``SegmentDecoderBackend/bytes``: BytesCompression's decoder, its state made once.
    private var lzma = LZMA2Decoder()

    init(compression: AEACompression, backend: SegmentDecoderBackend) {
        self.compression = compression
        self.backend = backend
        let algorithm = Self.algorithm(compression)
        if let algorithm {
            scratch = RawStorage(byteCount: compression_decode_scratch_buffer_size(algorithm))
        } else {
            scratch = nil
        }
    }

    static func algorithm(_ compression: AEACompression) -> compression_algorithm? {
        switch compression {
        case .lzma: COMPRESSION_LZMA
        case .lzfse: COMPRESSION_LZFSE
        case .lzbitmap: COMPRESSION_LZBITMAP
        case .lzraven: COMPRESSION_LZRAVEN
        case .lz4: COMPRESSION_LZ4_RAW // Raw LZ4 blocks, not Compression's "bv41" frames.
        case .lzvn, .zlib, .none: nil
        }
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
        if compression == .zlib {
            try unsafe inflate(input, into: output, segment: segment)
            return
        }
        if compression == .lzma, backend == .bytes {
            try unsafe decodeXZ(input, into: output, segment: segment)
            return
        }
        guard let algorithm = Self.algorithm(compression), let scratch else {
            throw .unsupportedCompression(compression.rawValue)
        }
        let written = unsafe compression_decode_buffer(
            output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count + 1,
            input.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
            scratch.base, algorithm
        )
        // `output` has slack after it (``SegmentBufferPool`` allots 64 bytes), so asking for one byte more
        // detects a segment that decodes long.
        guard written == output.count else {
            throw .decompressionFailed(segment: segment, "decoded \(written) of \(output.count) bytes")
        }
    }

    private mutating func decodeXZ(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer, segment: Int) throws(AEAError) {
        // `output` is the segment's room in a buffer this thread owns until it publishes the segment; the decoder
        // writes nothing past what it decodes.
        var span = unsafe OutputRawSpan(buffer: output, initializedCount: 0)
        let consumed: Int
        do {
            consumed = try unsafe lzma.decompressXZ(RawSpan(_unsafeBytes: input), into: &span)
        } catch {
            throw .decompressionFailed(segment: segment, "\(error)")
        }
        let written = unsafe span.finalize(for: output)
        guard written == output.count, consumed == input.count else {
            throw .decompressionFailed(segment: segment, "decoded \(written) of \(output.count) bytes")
        }
    }

    private mutating func inflate(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer, segment: Int) throws(AEAError) {
        inflater.reset()
        // `output` is the segment's room in a buffer this thread owns until it publishes the segment.
        var span = unsafe OutputRawSpan(buffer: output, initializedCount: 0)
        let consumed: Int
        do {
            // Returns the input it took; what it wrote is the span's count.
            consumed = try unsafe inflater.decompressAll(RawSpan(_unsafeBytes: input), into: &span)
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
        let mac = AEAKeys.segmentMAC(archive.segmentKeys[segment], data: stored)
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
        var reader = AlignedBytesReader(bytes)
        while reader.remainingByteCount >= 8 {
            var k = (try? reader.read(Byte8.self, .littleEndian)) ?? 0
            k &*= m
            k ^= k >> 47
            k &*= m
            h ^= k
            h &*= m
        }
        let tail = reader.remainingByteCount
        if tail > 0 {
            var value: UInt64 = 0
            for index in 0..<tail { value |= UInt64(UInt8((try? reader.read(Byte.self)) ?? 0)) << (8 * index) }
            h ^= value
            h &*= m
        }
        h ^= h >> 47
        h &*= m
        h ^= h >> 47
        return h
    }
}
