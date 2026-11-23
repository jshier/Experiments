import Bytes
import BytesCompression
import BytesReferenceCodecs
import BytesTestSupport
import zlib

// Shared helpers: reference streams from zlib (BytesReferenceCodecs), sample data, and drivers that run the codecs
// one-shot and in pieces.

extension DeflateFormat {
    /// zlib's `windowBits` for this container.
    var zlibWindowBits: Int32 {
        switch self {
        case .raw: Zlib.Container.raw.windowBits
        case .zlib: Zlib.Container.zlib.windowBits
        case .gzip: Zlib.Container.gzip.windowBits
        }
    }
}

/// zlib's encoding of `data`.
func zlibCompress(
    _ data: [UInt8], format: DeflateFormat = .raw, level: Int32 = Z_DEFAULT_COMPRESSION, strategy: Int32 = Z_DEFAULT_STRATEGY
) -> [UInt8] {
    Zlib.compress(data, windowBits: format.zlibWindowBits, level: level, strategy: strategy)
}

enum Outcome: Equatable {
    case decoded([UInt8])
    case failed
}

/// zlib's decoding of `data`, which must be one whole stream with nothing after it.
func zlibDecompress(_ data: [UInt8], format: DeflateFormat = .raw) -> Outcome {
    Zlib.decompress(data, windowBits: format.zlibWindowBits).map { .decoded($0) } ?? .failed
}

/// Inputs that exercise every block type and match shape: BytesTestSupport's `SampleBytes.deflateSamples` (empty,
/// one byte, text, random, runs, periodic, and large, last).
func samples() -> [(name: String, bytes: [UInt8])] { SampleBytes.deflateSamples }

/// ``samples()`` without the large one: what the fast tests loop over (bulk tests take the large one).
func smallSamples() -> [(name: String, bytes: [UInt8])] { SampleBytes.deflateSamples.dropLast() }

/// The large sample: several megabytes, so output spans windows and back-references reach across them.
func largeSample() -> [UInt8] { SampleBytes.deflateSamples.last!.bytes }

/// Decodes a whole stream with `decompressAll`, into exactly `capacity` bytes (by default, plenty).
func decodeAll(_ data: [UInt8], format: DeflateFormat, capacity: Int? = nil) -> Outcome {
    var decoder = DeflateDecoder(format: format)
    // Uninitialized: the default room is up to DEFLATE's 1032:1 expansion (a gigabyte for a megabyte stream), which
    // zero-filling would write in full; untouched pages of a large allocation are never mapped.
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity ?? max(1 << 16, data.count * 1100), alignment: 1)
    defer { buffer.deallocate() }
    var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
    guard let consumed = try? decoder.decompressAll(data.span.bytes, into: &span), consumed == data.count else {
        _ = span.finalize(for: buffer)
        return .failed
    }
    let produced = span.finalize(for: buffer)
    return .decoded(Array(UnsafeRawBufferPointer(rebasing: buffer[..<produced])))
}

/// Decodes a stream fed in pieces of up to `chunk` bytes, into an output buffer of `outputChunk` bytes
/// emptied after each call, as a network reader would.
func decodeStreaming(_ data: [UInt8], format: DeflateFormat, chunk: Int, outputChunk: Int) -> Outcome {
    var decoder = DeflateDecoder(format: format)
    var result: [UInt8] = []
    var pending: [UInt8] = []
    var offset = 0
    var buffer = [UInt8](repeating: 0, count: outputChunk)
    while true {
        let take = min(chunk, data.count - offset)
        pending += data[offset..<(offset + take)]
        offset += take
        let progress: TransformProgress? = buffer.withUnsafeMutableBytes { raw in
            var span = OutputRawSpan(buffer: raw, initializedCount: 0)
            let progress = try? decoder.decompress(pending.span.bytes, into: &span)
            let produced = span.finalize(for: raw)
            result += raw[..<produced]
            return progress
        }
        guard let progress else { return .failed }
        pending.removeFirst(progress.consumed)
        switch progress.status {
        case .finished:
            // A gzip member's end: another may follow in the input still to come.
            if pending.isEmpty && offset < data.count { continue }
            return pending.isEmpty && offset == data.count ? .decoded(result) : .failed
        case .needsInput:
            if offset == data.count { return .failed } // Truncated.
        case .needsOutput:
            continue
        }
    }
}
