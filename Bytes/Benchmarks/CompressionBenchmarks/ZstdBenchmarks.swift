import Benchmark
import Bytes
import BytesCompression
import BytesTestSupport
import CZstd
import Foundation

// Zstandard decoding: Bytes' `ZstdDecoder` against libzstd 1.5.7 (Homebrew), single-threaded, on Silesia files
// compressed by the `zstd` CLI at levels 1, 3, and 19 (and `--long=27 -19`), and on 1–64 KB inputs. Frames have
// checksums, as the CLI writes them, and both decoders verify them.
//
// Fixtures are cached in the corpus directory under the names the CLI's output was saved with
// (`dickens-10192446.zstd-1.5.7-19`); when missing they're made with libzstd's API and the CLI's settings.

/// libzstd's decoder, its context reused across iterations as `ZstdDecoder` is.
final class LibZstd {
    private let context = ZSTD_createDCtx()!
    private let stream = ZSTD_createDStream()!

    deinit {
        ZSTD_freeDCtx(context)
        ZSTD_freeDStream(stream)
    }

    /// One call, whole input into whole output: `ZSTD_decompressDCtx`.
    func decompress(_ input: [UInt8], into output: inout [UInt8]) -> Int {
        let size = input.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                ZSTD_decompressDCtx(context, output.baseAddress, output.count, input.baseAddress, input.count)
            }
        }
        precondition(ZSTD_isError(size) == 0)
        return size
    }

    /// `ZSTD_decompressStream`, input in `chunk`-byte pieces, output into a 64 KB buffer reused for each piece.
    func decompressStreaming(_ input: [UInt8], chunk: Int, into output: inout [UInt8]) -> Int {
        ZSTD_DCtx_reset(stream, ZSTD_reset_session_only)
        var total = 0
        return input.withUnsafeBytes { all in
            output.withUnsafeMutableBytes { buffer in
                var offset = 0
                while true {
                    let end = min(offset + chunk, all.count)
                    var inBuffer = ZSTD_inBuffer(src: all.baseAddress! + offset, size: end - offset, pos: 0)
                    while true {
                        var outBuffer = ZSTD_outBuffer(dst: buffer.baseAddress, size: min(buffer.count, 1 << 16), pos: 0)
                        let remaining = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                        precondition(ZSTD_isError(remaining) == 0)
                        total += outBuffer.pos
                        if remaining == 0 { return total } // The frame is decoded and flushed.
                        if inBuffer.pos == inBuffer.size && outBuffer.pos < outBuffer.size { break }
                    }
                    offset = end
                }
            }
        }
    }
}

enum ZstdFixtures {
    static let files = ["dickens", "mozilla", "xml", "x-ray", "samba"]

    /// `zstd -LEVEL` (or `zstd --long=27 -LEVEL`) of `data`: checksum on, content size stated.
    static func compress(_ data: [UInt8], level: Int32, long: Bool = false) -> [UInt8] {
        let context = ZSTD_createCCtx()!
        defer { ZSTD_freeCCtx(context) }
        ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, level)
        ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, 1)
        if long {
            ZSTD_CCtx_setParameter(context, ZSTD_c_windowLog, 27)
            ZSTD_CCtx_setParameter(context, ZSTD_c_enableLongDistanceMatching, 1)
        }
        var output = [UInt8](repeating: 0, count: ZSTD_compressBound(data.count))
        let size = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                ZSTD_compress2(context, output.baseAddress, output.count, input.baseAddress, input.count)
            }
        }
        precondition(ZSTD_isError(size) == 0)
        return Array(output[..<size])
    }
}

/// Decodes a whole stream into `output` with `decompressAll`.
@inline(__always)
func zstdDecodeAll(_ decoder: inout ZstdDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        _ = try! decoder.decompressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

/// Decodes a stream arriving in `chunk`-byte pieces into a 64 KB buffer reused for each piece of output.
@inline(__always)
func zstdDecodeStreaming(_ decoder: inout ZstdDecoder, _ input: [UInt8], chunk: Int, into output: inout [UInt8]) -> Int {
    decoder.reset()
    var offset = 0
    var total = 0
    let span = input.span.bytes
    var bytes = output.mutableSpan
    var window = bytes._mutatingExtracting(..<min(bytes.count, 1 << 16))
    while true {
        let end = min(offset + chunk, span.byteCount)
        let progress = window.withOutputRawSpan { out in
            let progress = try! decoder.decompress(span.extracting(offset..<end), into: &out)
            total += out.byteCount
            return progress
        }
        offset += progress.consumed
        if progress.status == .finished { return total }
    }
}

/// Registers the comparisons: each Silesia file at levels 1, 3, 19 (and mozilla with `--long=27 -19`) in one call,
/// level 3 also streamed in 64 KB pieces; 1–64 KB inputs at level 3 (and 4 KB at 19), one call; and random bytes.
func registerZstdBenchmarks() {
    let libzstd = Lazy { LibZstd() }
    for name in ZstdFixtures.files {
        guard let sample = Fixtures.silesia(name) else { continue }
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        var variants: [(label: String, key: String, level: Int32, long: Bool)] = [1, 3, 19].map { level in
            ("L\(level)", "\(level)", Int32(level), false)
        }
        if name == "mozilla" { variants.append(("long=27 L19", "long27-19", 19, true)) }
        for variant in variants {
            let fixture = Lazy {
                let compressed = Fixtures.cached("\(name)-\(sample.byteCount).zstd-1.5.7-\(variant.key)") {
                    ZstdFixtures.compress(sample.bytes, level: variant.level, long: variant.long)
                }
                return DecodeFixture(original: sample.bytes, compressed: compressed, outputCount: sample.byteCount + 64, decoder: ZstdDecoder())
            }
            let label = "\(variant.label) \(sample.label)"
            register("Zstd decode \(label): Bytes", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
                zstdDecodeAll(&f.decoder, f.compressed, into: &f.output)
            }
            register("Zstd decode \(label): libzstd", configuration: configuration, fixture, check: { $0.decodedAll($1) }) { f in
                libzstd.value.decompress(f.compressed, into: &f.output)
            }
            // Streamed at the default level only: the window's cost doesn't depend on the level.
            guard variant.label == "L3" else { continue }
            register("Zstd decode \(label): Bytes, streaming 64 KB", configuration: configuration, fixture, check: { $0.decodedCount($1) }) { f in
                zstdDecodeStreaming(&f.decoder, f.compressed, chunk: 1 << 16, into: &f.output)
            }
            register("Zstd decode \(label): libzstd, streaming 64 KB", configuration: configuration, fixture, check: { $0.decodedCount($1) }) { f in
                libzstd.value.decompressStreaming(f.compressed, chunk: 1 << 16, into: &f.output)
            }
        }
    }

    // 1 MB of random bytes: raw blocks, the copy path.
    let random = Fixtures.random
    let randomFixture = Lazy {
        let compressed = ZstdFixtures.compress(random.bytes, level: 3)
        return DecodeFixture(original: random.bytes, compressed: compressed, outputCount: random.byteCount + 64, decoder: ZstdDecoder())
    }
    register("Zstd decode L3 \(random.label): Bytes", configuration: Fixtures.largeConfiguration, randomFixture, check: { $0.decodedAll($1) }) { f in
        zstdDecodeAll(&f.decoder, f.compressed, into: &f.output)
    }
    register("Zstd decode L3 \(random.label): libzstd", configuration: Fixtures.largeConfiguration, randomFixture, check: { $0.decodedAll($1) }) { f in
        libzstd.value.decompress(f.compressed, into: &f.output)
    }

    // Small inputs: the first 1 to 64 KB of text, XML, a binary, and JavaScript.
    let small: [(name: String, path: String)] = [
        ("dickens", "silesia/dickens"), ("xml", "silesia/xml"), ("mozilla", "silesia/mozilla"), ("Main.js", "web/Main.js"),
    ]
    for (name, path) in small {
        for kilobytes in [1, 4, 16, 64] {
            guard let content = Fixtures.Sample(name: name, corpusPath: path, limit: kilobytes << 10) else { continue }
            // Level 19's sequences differ from level 3's; one size shows it.
            for level: Int32 in kilobytes == 4 ? [3, 19] : [3] {
                let fixture = Lazy {
                    let compressed = Fixtures.cached("small/\(name)-\(kilobytes)k.zstd-1.5.7-\(level)") {
                        ZstdFixtures.compress(content.bytes, level: level)
                    }
                    return DecodeFixture(original: content.bytes, compressed: compressed, outputCount: content.byteCount + 64, decoder: ZstdDecoder())
                }
                register("Zstd decode L\(level) \(name) \(kilobytes) KB: Bytes", fixture, check: { $0.decodedAll($1) }) { f in
                    zstdDecodeAll(&f.decoder, f.compressed, into: &f.output)
                }
                register("Zstd decode L\(level) \(name) \(kilobytes) KB: libzstd", fixture, check: { $0.decodedAll($1) }) { f in
                    libzstd.value.decompress(f.compressed, into: &f.output)
                }
            }
        }
    }
}

/// Allocation checks: decoding allocates nothing once a decoder has decoded a frame of the same window size,
/// one call or streamed. Zero thresholds in `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:Zstd.*'
func registerZstdAllocationBenchmarks() {
    let content = Lazy { Array(Fixtures.json(count: 1_200)) + Array(Fixtures.json(count: 16)) }
    for level: Int32 in [1, 19] {
        let fixture = Lazy {
            DecodeFixture(
                original: content.value, compressed: ZstdFixtures.compress(content.value, level: level), outputCount: content.value.count + 64,
                decoder: ZstdDecoder()
            )
        }
        register("Allocations:Zstd_decode_L\(level)", configuration: Fixtures.allocationConfiguration, fixture, check: { $0.decodedAll($1) }) { f in
            zstdDecodeAll(&f.decoder, f.compressed, into: &f.output)
        }
        register("Allocations:Zstd_decode_L\(level)_streaming", configuration: Fixtures.allocationConfiguration, fixture, check: { $0.decodedCount($1) }) { f in
            zstdDecodeStreaming(&f.decoder, f.compressed, chunk: 1000, into: &f.output)
        }
    }
}
