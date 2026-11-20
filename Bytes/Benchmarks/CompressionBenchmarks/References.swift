import CBrotli
import CLibDeflate
import CLZMA
import Compression
import Darwin
import zlib

// The reference codecs, each holding its state across iterations as the Bytes codecs do, so benchmarks
// measure coding, not setup. Inputs and outputs are preallocated arrays.

/// zlib's inflate, reset per stream, decoding a whole stream in one call.
final class ZlibInflater {
    private var stream = z_stream()

    /// - Parameter windowBits: -15 raw, 15 zlib, 31 gzip.
    init(windowBits: Int32) {
        precondition(inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    }

    deinit { inflateEnd(&stream) }

    /// Decodes `input` into `output`, returning the decoded size.
    func decompress(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        inflateReset(&stream)
        return input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                precondition(inflate(&stream, Z_FINISH) == Z_STREAM_END)
                return Int(stream.total_out)
            }
        }
    }
}

/// zlib's deflate at a level, reset per stream.
final class ZlibDeflater {
    private var stream = z_stream()

    init(level: Int32, windowBits: Int32) {
        precondition(deflateInit2_(&stream, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    }

    deinit { deflateEnd(&stream) }

    func compress(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        deflateReset(&stream)
        return input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                precondition(deflate(&stream, Z_FINISH) == Z_STREAM_END)
                return Int(stream.total_out)
            }
        }
    }
}

/// libdeflate: whole buffers only.
final class LibDeflate {
    enum Format { case raw, zlib, gzip }

    private let decompressor = libdeflate_alloc_decompressor()!
    private let compressor: OpaquePointer?
    let format: Format

    init(format: Format, level: Int32 = 6) {
        self.format = format
        compressor = libdeflate_alloc_compressor(level)
    }

    deinit {
        libdeflate_free_decompressor(decompressor)
        libdeflate_free_compressor(compressor)
    }

    func decompress(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        var actual = 0
        let result = input.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                switch format {
                case .raw: libdeflate_deflate_decompress(decompressor, input.baseAddress, input.count, output.baseAddress, output.count, &actual)
                case .zlib: libdeflate_zlib_decompress(decompressor, input.baseAddress, input.count, output.baseAddress, output.count, &actual)
                case .gzip: libdeflate_gzip_decompress(decompressor, input.baseAddress, input.count, output.baseAddress, output.count, &actual)
                }
            }
        }
        precondition(result == LIBDEFLATE_SUCCESS)
        return actual
    }

    func compress(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        let size = input.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                switch format {
                case .raw: libdeflate_deflate_compress(compressor, input.baseAddress, input.count, output.baseAddress, output.count)
                case .zlib: libdeflate_zlib_compress(compressor, input.baseAddress, input.count, output.baseAddress, output.count)
                case .gzip: libdeflate_gzip_compress(compressor, input.baseAddress, input.count, output.baseAddress, output.count)
                }
            }
        }
        precondition(size > 0)
        return size
    }
}

/// Apple's Compression framework, buffer API with a preallocated scratch buffer. `COMPRESSION_ZLIB` is raw
/// DEFLATE.
final class AppleCompression {
    private let algorithm: compression_algorithm
    private let decodeScratch: UnsafeMutableRawPointer
    private let encodeScratch: UnsafeMutableRawPointer

    init(algorithm: compression_algorithm) {
        self.algorithm = algorithm
        decodeScratch = .allocate(byteCount: max(1, compression_decode_scratch_buffer_size(algorithm)), alignment: 16)
        encodeScratch = .allocate(byteCount: max(1, compression_encode_scratch_buffer_size(algorithm)), alignment: 16)
    }

    deinit {
        decodeScratch.deallocate()
        encodeScratch.deallocate()
    }

    func decompress(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        let size = input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                compression_decode_buffer(output.baseAddress!, output.count, input.baseAddress!, input.count, decodeScratch, algorithm)
            }
        }
        precondition(size > 0)
        return size
    }

    func compress(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        let size = input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                compression_encode_buffer(output.baseAddress!, output.count, input.baseAddress!, input.count, encodeScratch, algorithm)
            }
        }
        precondition(size > 0)
        return size
    }
}

/// Google's brotli. Its decoder has no reset, so each stream gets a new state (allocations included, as
/// for any client of the library).
enum GoogleBrotli {
    static func decompress(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                var availableIn = input.count
                var nextIn = input.baseAddress
                var availableOut = output.count
                var nextOut = output.baseAddress
                let state = BrotliDecoderCreateInstance(nil, nil, nil)
                defer { BrotliDecoderDestroyInstance(state) }
                let result = BrotliDecoderDecompressStream(state, &availableIn, &nextIn, &availableOut, &nextOut, nil)
                precondition(result == BROTLI_DECODER_RESULT_SUCCESS)
                return output.count - availableOut
            }
        }
    }

    /// For checks: the decoded size, or -1 if the stream doesn't decode in one call into `output`.
    static func decompressIfValid(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                var size = output.count
                let result = BrotliDecoderDecompress(input.count, input.baseAddress, &size, output.baseAddress)
                return result == BROTLI_DECODER_RESULT_SUCCESS ? size : -1
            }
        }
    }

    static func compress(_ input: [UInt8], quality: Int32, into output: inout [UInt8]) -> Int {
        input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                var size = output.count
                let ok = BrotliEncoderCompress(quality, BROTLI_DEFAULT_WINDOW, BROTLI_MODE_GENERIC, input.count, input.baseAddress, &size, output.baseAddress)
                precondition(ok == BROTLI_TRUE)
                return size
            }
        }
    }
}

enum ZlibChecksums {
    static func adler32(_ bytes: [UInt8], continuing value: UInt32 = 1) -> UInt32 {
        bytes.withUnsafeBufferPointer { UInt32(zlib.adler32(uLong(value), $0.baseAddress, uInt($0.count))) }
    }

    static func crc32(_ bytes: [UInt8], continuing value: UInt32 = 0) -> UInt32 {
        bytes.withUnsafeBufferPointer { UInt32(zlib.crc32(uLong(value), $0.baseAddress, uInt($0.count))) }
    }
}

enum LibDeflateChecksums {
    static func adler32(_ bytes: [UInt8], continuing value: UInt32 = 1) -> UInt32 {
        bytes.withUnsafeBytes { libdeflate_adler32(value, $0.baseAddress, $0.count) }
    }

    static func crc32(_ bytes: [UInt8], continuing value: UInt32 = 0) -> UInt32 {
        bytes.withUnsafeBytes { libdeflate_crc32(value, $0.baseAddress, $0.count) }
    }
}

/// liblzma's CRC-64 (`.xz`'s), and libzstd's XXH64. libzstd exports `ZSTD_XXH64` (its bundled xxHash, namespaced) but
/// declares it in no public header, so it's looked up once by name.
enum ReferenceHashes {
    static func crc64(_ bytes: [UInt8], continuing value: UInt64 = 0) -> UInt64 {
        bytes.withUnsafeBufferPointer { lzma_crc64($0.baseAddress, $0.count, value) }
    }

    typealias XXH64Function = @convention(c) (UnsafeRawPointer?, Int, UInt64) -> UInt64

    /// `ZSTD_XXH64(input, length, seed)`, or `nil` if this libzstd doesn't export it.
    static let zstdXXH64: XXH64Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ZSTD_XXH64") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: XXH64Function.self)
    }()

    static func xxh64(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        bytes.withUnsafeBytes { zstdXXH64!($0.baseAddress, $0.count, seed) }
    }
}
