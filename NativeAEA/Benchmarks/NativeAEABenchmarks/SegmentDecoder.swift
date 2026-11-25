import Bytes
import BytesCompression
import BytesReferenceCodecs
import Compression
import NativeAEA

/// Which decoder a segment benchmark measures. The names are the rows' last component, as they were when NativeAEA
/// chose between the two (its `SegmentDecoderBackend`, removed 2026-11-22: it decodes with BytesCompression only).
enum SegmentDecoderKind: String, CaseIterable, CustomStringConvertible {
    /// BytesCompression's decoder, as NativeAEA's `SegmentCodec` runs it.
    case bytes
    /// Apple's Compression framework through its buffer API, with scratch memory made once: the reference.
    case system

    var description: String { rawValue }
}

/// Decodes single segments outside the extraction pipeline, for the benchmarks comparing decoders: BytesCompression's
/// `Decompressor`, made once for the archive's compression (`DecompressionFormat(aeaSegment:)`, as NativeAEA's
/// segment stage decodes), or Compression's scratch memory. Written against NativeAEA's public API only (`AEAArchive`,
/// `AppleArchiveCompression`, and the `storedBytes(of:)` SPI).
///
/// A class: the decoder's state is made once (in a benchmark's setup) and mutated by every decode.
final class SegmentDecoder {
    let kind: SegmentDecoderKind
    let compression: AppleArchiveCompression
    /// BytesCompression's decoder for the archive's segments (and for zlib's with either kind: Compression has no
    /// zlib to compare).
    private var decompressor: Decompressor?
    /// Compression's scratch memory, made once, for ``SegmentDecoderKind/system``.
    private let scratch: RawStorage?

    init(_ archive: AEAArchive, kind: SegmentDecoderKind) {
        self.kind = kind
        compression = archive.rootHeader.compression
        let bytes = kind == .bytes
        if bytes || compression == .zlib, let format = DecompressionFormat(aeaSegment: compression) {
            decompressor = try? Decompressor(for: format)
        } else {
            decompressor = nil
        }
        if !bytes, let algorithm = Self.algorithm(compression) {
            scratch = RawStorage(byteCount: compression_decode_scratch_buffer_size(algorithm))
        } else {
            scratch = nil
        }
    }

    /// Compression's algorithm for an AEA segment's compression (raw LZ4 blocks, not `bv41` frames), or `nil` where it
    /// has none (LZVN's is undocumented, zlib's is raw DEFLATE).
    static func algorithm(_ compression: AppleArchiveCompression) -> compression_algorithm? {
        switch compression {
        case .lzma: COMPRESSION_LZMA
        case .lzfse: COMPRESSION_LZFSE
        case .lzbitmap: COMPRESSION_LZBITMAP
        case .lzraven: COMPRESSION_LZRAVEN
        case .lz4: COMPRESSION_LZ4_RAW
        case .lzvn, .zlib, .none: nil
        }
    }

    /// Compression's decoding of a segment (BytesReferenceCodecs), or its stored bytes when it's stored as is: the
    /// reference the benchmarks' outputs are checked against.
    static func reference(_ stored: [UInt8], rawSize: Int, compression: AppleArchiveCompression) -> [UInt8] {
        if stored.count == rawSize { return stored }
        guard let algorithm = algorithm(compression) else {
            precondition(compression == .zlib, "no reference decoder for \(compression)")
            return Zlib.decompress(stored, windowBits: Zlib.Container.zlib.windowBits)!
        }
        return AppleCompression.decode(stored, capacity: rawSize, algorithm)
    }

    /// Decodes `stored` into `output`, which must be the segment's raw size.
    func decode(_ stored: [UInt8], into output: inout [UInt8]) throws(BytesError) {
        if stored.count == output.count {
            // Stored: segments that don't compress are kept as they are.
            stored.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { output in
                    // Both arrays are held for the call and have the same count.
                    unsafe output.copyMemory(from: input)
                }
            }
            return
        }
        if let scratch, compression != .zlib {
            try decodeWithCompression(stored, into: &output, scratch: scratch)
            return
        }
        guard decompressor != nil else { throw .invalidValue }
        let source = stored.span.bytes
        let rawSize = output.count
        let consumed = try output.withOutputRawSpan { span throws(BytesError) -> Int in
            try decompressor!.decompressAll(source, into: &span, decodedSize: rawSize)
        }
        guard consumed == stored.count else { throw .trailingData }
    }

    private func decodeWithCompression(_ stored: [UInt8], into output: inout [UInt8], scratch: RawStorage) throws(BytesError) {
        guard let algorithm = Self.algorithm(compression) else { throw .invalidValue }
        let written = stored.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                // Both arrays are held for the call, and Compression writes at most `output.count` bytes; the scratch
                // memory is `compression_decode_scratch_buffer_size(algorithm)` bytes, as Compression asks.
                unsafe compression_decode_buffer(
                    output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count,
                    input.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
                    scratch.base, algorithm
                )
            }
        }
        guard written == output.count else { throw .invalidValue }
    }
}
