import Bytes
import BytesCompression
import zlib

// Shared helpers: reference streams from zlib, sample data, and drivers that run the codecs one-shot and in
// pieces.

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension DeflateFormat {
    /// zlib's `windowBits` for this container.
    var zlibWindowBits: Int32 {
        switch self {
        case .raw: -MAX_WBITS
        case .zlib: MAX_WBITS
        case .gzip: MAX_WBITS + 16
        }
    }
}

/// zlib's encoding of `data`.
func zlibCompress(
    _ data: [UInt8], format: DeflateFormat = .raw, level: Int32 = Z_DEFAULT_COMPRESSION, strategy: Int32 = Z_DEFAULT_STRATEGY
) -> [UInt8] {
    var stream = z_stream()
    precondition(deflateInit2_(&stream, level, Z_DEFLATED, format.zlibWindowBits, 8, strategy, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { deflateEnd(&stream) }
    var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))) + 64)
    var input = data
    let status = input.withUnsafeMutableBufferPointer { input in
        output.withUnsafeMutableBufferPointer { output in
            stream.next_in = input.baseAddress
            stream.avail_in = uInt(input.count)
            stream.next_out = output.baseAddress
            stream.avail_out = uInt(output.count)
            return deflate(&stream, Z_FINISH)
        }
    }
    precondition(status == Z_STREAM_END)
    return Array(output[..<Int(stream.total_out)])
}

enum Outcome: Equatable {
    case decoded([UInt8])
    case failed
}

/// zlib's decoding of `data`, which must be one whole stream with nothing after it.
func zlibDecompress(_ data: [UInt8], format: DeflateFormat = .raw) -> Outcome {
    var stream = z_stream()
    precondition(inflateInit2_(&stream, format.zlibWindowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }
    var result: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    var input = data
    return input.withUnsafeMutableBufferPointer { input in
        stream.next_in = input.baseAddress
        stream.avail_in = uInt(input.count)
        while true {
            let (status, produced) = chunk.withUnsafeMutableBufferPointer { output in
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                let status = inflate(&stream, Z_NO_FLUSH)
                return (status, output.count - Int(stream.avail_out))
            }
            result += chunk[..<produced]
            switch status {
            case Z_STREAM_END: return stream.avail_in == 0 ? .decoded(result) : .failed
            case Z_OK: continue
            default: return .failed // Including Z_BUF_ERROR: truncated.
            }
        }
    }
}

/// Inputs that exercise every block type and match shape.
func samples() -> [(name: String, bytes: [UInt8])] {
    var rng = SplitMix64(state: 7)
    let words = ["swift", "byte", "span", "inflate", "huffman", "window", " ", "\n", "the", "a"]
    var text: [UInt8] = []
    while text.count < 200_000 {
        text += Array(words.randomElement(using: &rng)!.utf8)
    }
    let random = (0..<100_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
    let runs = (0..<100_000).map { UInt8(($0 / 1000) % 3) } // Long runs: distance-1 matches.
    let periodic = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 % 7) } // Short distances.
    // Several megabytes, so output spans windows and back-references reach across them.
    var large: [UInt8] = []
    while large.count < 3 << 20 {
        large += text.prefix(Int.random(in: 1_000...50_000, using: &rng))
        large += random.prefix(500)
    }
    return [
        ("empty", []), ("one byte", [0x41]), ("text", text), ("random", random), ("runs", runs),
        ("periodic", periodic), ("large", large),
    ]
}

/// Decodes a whole stream with `decompressAll`, into exactly `capacity` bytes (by default, plenty).
func decodeAll(_ data: [UInt8], format: DeflateFormat, capacity: Int? = nil) -> Outcome {
    var decoder = DeflateDecoder(format: format)
    var output = [UInt8](repeating: 0, count: capacity ?? max(1 << 16, data.count * 1100))
    // Errors handled inside the closure: a typed-throws closure returning a tuple, passed to
    // `withUnsafeMutableBytes`, crashed Swift 6.4.2's SIL generation ("unsupported collection upcast kind").
    let produced: Int? = output.withUnsafeMutableBytes { buffer in
        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
        guard let consumed = try? decoder.decompressAll(data.span.bytes, into: &span), consumed == data.count else {
            return nil
        }
        return span.finalize(for: buffer)
    }
    guard let produced else { return .failed }
    return .decoded(Array(output[..<produced]))
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
            return pending.isEmpty && offset == data.count ? .decoded(result) : .failed
        case .needsInput:
            if offset == data.count { return .failed } // Truncated.
        case .needsOutput:
            continue
        }
    }
}
