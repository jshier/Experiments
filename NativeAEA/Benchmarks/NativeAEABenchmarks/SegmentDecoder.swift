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
/// decoders made once for the archive's compression, as NativeAEA's `SegmentCodec` makes them, or Compression's
/// scratch memory. Written against NativeAEA's public API only (`AEAArchive`, `AEACompression`, and the
/// `storedBytes(of:)` SPI), so it builds against the library before and after the backend's removal.
///
/// A class: the decoders' state is made once (in a benchmark's setup) and mutated by every decode.
final class SegmentDecoder {
    let kind: SegmentDecoderKind
    let compression: AEACompression
    private var inflater: DeflateDecoder?
    private var lzma: LZMA2Decoder?
    private var lzfse: LZFSEDecoder?
    private var lzraven: LZRAVENDecoder?
    private var lzbitmap: LZBitmapDecoder?
    /// Compression's scratch memory, made once, for ``SegmentDecoderKind/system``.
    private let scratch: RawStorage?

    init(_ archive: AEAArchive, kind: SegmentDecoderKind) {
        self.kind = kind
        compression = archive.rootHeader.compression
        let bytes = kind == .bytes
        // zlib went through BytesCompression with either backend.
        inflater = compression == .zlib ? DeflateDecoder(format: .zlib) : nil
        lzma = bytes && compression == .lzma ? LZMA2Decoder() : nil
        lzfse = bytes && compression == .lzfse ? LZFSEDecoder() : nil
        lzraven = bytes && compression == .lzraven ? LZRAVENDecoder() : nil
        lzbitmap = bytes && compression == .lzbitmap ? LZBitmapDecoder() : nil
        if !bytes, let algorithm = Self.algorithm(compression) {
            scratch = RawStorage(byteCount: compression_decode_scratch_buffer_size(algorithm))
        } else {
            scratch = nil
        }
    }

    /// Compression's algorithm for an AEA segment's compression (raw LZ4 blocks, not `bv41` frames), or `nil` where it
    /// has none (LZVN's is undocumented, zlib's is raw DEFLATE).
    static func algorithm(_ compression: AEACompression) -> compression_algorithm? {
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
    static func reference(_ stored: [UInt8], rawSize: Int, compression: AEACompression) -> [UInt8] {
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
        let source = stored.span.bytes
        let rawSize = output.count
        let consumed = try output.withOutputRawSpan { (span) throws(BytesError) -> Int in
            let consumed: Int
            switch compression {
            case .zlib:
                inflater!.reset()
                consumed = try inflater!.decompressAll(source, into: &span)
            case .lzma: consumed = try lzma!.decompressXZ(source, into: &span)
            case .lzfse: consumed = try lzfse!.decompressAll(source, into: &span)
            case .lzraven: consumed = try lzraven!.decompressAll(source, decodedSize: rawSize, into: &span)
            case .lzbitmap: consumed = try lzbitmap!.decompressAll(source, decodedSize: rawSize, into: &span)
            case .lzvn: consumed = try LZVNDecoder().decompressAll(source, into: &span)
            case .lz4:
                try LZ4Decoder().decompressRaw(source, decodedSize: rawSize, into: &span)
                consumed = source.byteCount
            case .none: throw .invalidValue
            }
            guard span.byteCount == rawSize else { throw .invalidValue }
            return consumed
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
