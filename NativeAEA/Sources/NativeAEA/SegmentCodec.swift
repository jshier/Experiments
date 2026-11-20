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
/// decoder's state and Compression's scratch memory, made once, and only what its archive's compression and backend
/// use (every decoder's tables are zeroed when made, so unused ones would cost memory per thread).
struct SegmentCodec: ~Copyable {
    let compression: AEACompression
    let backend: SegmentDecoderBackend
    /// Compression's scratch memory, only with ``SegmentDecoderBackend/system``.
    private let scratch: RawStorage?
    /// zlib segments (with the RFC 1950 wrapper): BytesCompression's decoder, which checks the Adler-32 too (a
    /// 160 KiB window and its tables), whatever the backend, only for zlib archives.
    private var inflater: DeflateDecoder?
    /// LZMA (xz) segments with ``SegmentDecoderBackend/bytes``: BytesCompression's decoder (a 28 KB probability
    /// model), only for LZMA archives.
    private var lzma: LZMA2Decoder?
    /// LZFSE segments: BytesCompression's decoder (its 48 KB of tables made once), only for LZFSE archives.
    private var lzfse: LZFSEDecoder?
    /// LZRAVEN segments: BytesCompression's decoder (a 38 KB workspace made once), only for LZRAVEN archives.
    private var lzraven: LZRAVENDecoder?
    /// LZBITMAP segments: BytesCompression's decoder (a 37 KB workspace), only for LZBITMAP archives.
    private var lzbitmap: LZBitmapDecoder?

    /// LZ4 as Compression's `bv41` frames (`pbz4` blocks), not raw blocks (AEA segments).
    let framedLZ4: Bool

    init(compression: AEACompression, backend: SegmentDecoderBackend, framedLZ4: Bool = false) {
        self.compression = compression
        self.backend = backend
        self.framedLZ4 = framedLZ4
        inflater = compression == .zlib ? DeflateDecoder(format: .zlib) : nil
        lzma = compression == .lzma && backend == .bytes ? LZMA2Decoder() : nil
        lzfse = compression == .lzfse && backend == .bytes ? LZFSEDecoder() : nil
        lzraven = compression == .lzraven && backend == .bytes ? LZRAVENDecoder() : nil
        lzbitmap = compression == .lzbitmap && backend == .bytes ? LZBitmapDecoder() : nil
        if backend == .system, let algorithm = Self.algorithm(compression, framedLZ4: framedLZ4) {
            scratch = RawStorage(byteCount: compression_decode_scratch_buffer_size(algorithm))
        } else {
            scratch = nil
        }
    }

    static func algorithm(_ compression: AEACompression, framedLZ4: Bool = false) -> compression_algorithm? {
        switch compression {
        case .lzma: COMPRESSION_LZMA
        case .lzfse: COMPRESSION_LZFSE
        case .lzbitmap: COMPRESSION_LZBITMAP
        case .lzraven: COMPRESSION_LZRAVEN
        // AEA segments are raw LZ4 blocks; `pbz4` blocks are Compression's "bv41" frames.
        case .lz4: framedLZ4 ? COMPRESSION_LZ4 : COMPRESSION_LZ4_RAW
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
        if backend == .bytes {
            switch compression {
            case .lzma:
                try unsafe decodeXZ(input, into: output, segment: segment)
                return
            case .lzfse, .lz4, .lzraven, .lzbitmap, .lzvn:
                try unsafe decodeLZ(input, into: output, segment: segment)
                return
            default:
                break
            }
        }
        guard let algorithm = Self.algorithm(compression, framedLZ4: framedLZ4), let scratch else {
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
        do throws(BytesError) {
            // Made in `init` for LZMA with this backend, the only case that gets here.
            consumed = try unsafe lzma!.decompressXZ(RawSpan(_unsafeBytes: input), into: &span)
        } catch {
            throw .decompressionFailed(segment: segment, "\(error)")
        }
        let written = unsafe span.finalize(for: output)
        guard written == output.count, consumed == input.count else {
            throw .decompressionFailed(segment: segment, "decoded \(written) of \(output.count) bytes")
        }
    }

    /// LZFSE, LZRAVEN, LZBITMAP, and LZ4 (raw blocks, or `bv41` frames) with BytesCompression's decoders.
    private mutating func decodeLZ(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer, segment: Int) throws(AEAError) {
        // `output` is the segment's room in a buffer this thread owns until it publishes the segment.
        var span = unsafe OutputRawSpan(buffer: output, initializedCount: 0)
        let source = unsafe RawSpan(_unsafeBytes: input)
        var consumed = input.count
        do throws(BytesError) {
            switch compression {
            case .lzfse:
                consumed = try lzfse!.decompressAll(source, into: &span)
            case .lzraven:
                // Exactly the segment's size (anything else throws), consuming the whole stream.
                consumed = try lzraven!.decompressAll(source, decodedSize: output.count, into: &span)
            case .lzbitmap:
                consumed = try lzbitmap!.decompressAll(source, decodedSize: output.count, into: &span)
            case .lzvn:
                consumed = try LZVNDecoder().decompressAll(source, into: &span)
            case .lz4 where framedLZ4:
                consumed = try LZ4Decoder().decompressFramed(source, into: &span)
            default:
                try LZ4Decoder().decompressRaw(source, decodedSize: output.count, into: &span)
            }
        } catch {
            throw .decompressionFailed(segment: segment, "\(error)")
        }
        let written = unsafe span.finalize(for: output)
        guard written == output.count, consumed == input.count else {
            throw .decompressionFailed(segment: segment, "decoded \(written) of \(output.count) bytes")
        }
    }

    private mutating func inflate(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer, segment: Int) throws(AEAError) {
        // Made in `init` for zlib, the only compression that gets here.
        inflater!.reset()
        // `output` is the segment's room in a buffer this thread owns until it publishes the segment.
        var span = unsafe OutputRawSpan(buffer: output, initializedCount: 0)
        let consumed: Int
        do throws(BytesError) {
            // Returns the input it took; what it wrote is the span's count.
            consumed = try unsafe inflater!.decompressAll(RawSpan(_unsafeBytes: input), into: &span)
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
