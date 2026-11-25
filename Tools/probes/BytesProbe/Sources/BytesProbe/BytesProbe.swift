// Bytes' kernels on this Mac, for Tools/probe: checksum throughput by size (one thread), and the parallel DEFLATE
// encoder and decoder by lane count (the corpus from `Tools/corpus path`). Each subcommand prints one TSV table.
import ArgumentParser
import Bytes
import BytesCompression
import Darwin

@main
struct BytesProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bytes-probe",
        abstract: "Bytes' kernels on this Mac: checksums by size, parallel DEFLATE by lane count.",
        subcommands: [Checksums.self, Lanes.self, Segments.self]
    )
}

/// Comma-separated positive integers ("1,2,4,8").
struct IntList: ExpressibleByArgument {
    var values: [Int]
    init?(argument: String) {
        let parts = argument.split(separator: ",").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? 0) > 0 }) else { return nil }
        values = parts.map { $0! }
    }
}

struct Checksums: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "CRC-32 and Adler-32 throughput (GB/s) by input size, one thread, best of N."
    )

    @Option(help: "Best of this many timings per size.")
    var reps = 9

    @Option(help: "Bytes checksummed per timing, in MB (each size repeats to about this much).")
    var megabytes = 512

    func run() {
        setUserInteractive()
        print("size_bytes\tCRC32_GBs\tAdler32_GBs")
        let sizes = [64, 1 << 10, 16 << 10, 256 << 10, 1 << 20, 4 << 20, 8 << 20, 32 << 20, 128 << 20]
        var sink: UInt32 = 0
        for size in sizes {
            let data = randomBytes(size)
            let rounds = max(4, (megabytes << 20) / size)
            var best = (crc: Double.infinity, adler: Double.infinity)
            let span = data.span.bytes
            for _ in 0..<reps {
                var t = now()
                sink ^= crcLoop(span, rounds)
                best.crc = min(best.crc, Double(now() - t))
                t = now()
                sink ^= adlerLoop(span, rounds)
                best.adler = min(best.adler, Double(now() - t))
            }
            let total = Double(size * rounds)
            print("\(size)\t\(fmt(total / best.crc))\t\(fmt(total / best.adler))")
            fflush(stdout)
        }
        if sink == 0x1234_5678 { print("") }
    }
}

struct Lanes: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "ParallelDeflateEncoder/Decoder time (ms, medians) by lane count: 256 KB chunks, raw format."
    )

    @Option(help: "The corpus directory (Tools/corpus path); reads silesia/FILE.")
    var corpus: String

    @Option(help: "Lane counts, comma-separated.")
    var lanes: IntList

    @Option(help: "Silesia files, comma-separated.")
    var files = "dickens,mozilla"

    @Option(help: "Timed encodes per lane count (median).")
    var encodes = 7

    @Option(help: "Timed decodes per lane count (median).")
    var decodes = 9

    func run() throws {
        setUserInteractive()
        print("file\tlevel\tdirection\tlanes\tms")
        for name in files.split(separator: ",").map(String.init) {
            let input = try readCorpusFile(corpus, name)
            for level in [1, 6] {
                let compressed = independentStream(input, level: level)
                var encodeRows: [String] = [], decodeRows: [String] = []
                for lanes in lanes.values {
                    var encoder = ParallelDeflateEncoder(format: .raw, level: level, chunkSize: 256 << 10, lanes: lanes)
                    var output = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: input.count))
                    _ = encodeAll(&encoder, input, into: &output) // warm-up
                    var times: [Double] = []
                    for _ in 0..<encodes {
                        let t = now(); _ = encodeAll(&encoder, input, into: &output); times.append(Double(now() - t) / 1e6)
                    }
                    encodeRows.append("\(name)\t\(level)\tencode\t\(lanes)\t\(fmt(median(times)))")
                    var decoder = ParallelDeflateDecoder(format: .raw, lanes: lanes)
                    var decoded = [UInt8](repeating: 0, count: input.count + 64)
                    guard decodeAll(&decoder, compressed, into: &decoded) == input.count,
                          decoded.prefix(input.count).elementsEqual(input) else {
                        throw ValidationError("\(name) level \(level) at \(lanes) lanes didn't round-trip")
                    }
                    times = []
                    for _ in 0..<decodes {
                        let t = now(); _ = decodeAll(&decoder, compressed, into: &decoded); times.append(Double(now() - t) / 1e6)
                    }
                    decodeRows.append("\(name)\t\(level)\tdecode\t\(lanes)\t\(fmt(median(times)))")
                }
                for row in encodeRows + decodeRows {
                    print(row)
                }
                fflush(stdout)
            }
        }
    }
}

struct Segments: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "ParallelDeflateDecoder's segment count and time (ms, median) by lane count: where it falls back to one segment."
    )

    @Option(help: "The corpus directory (Tools/corpus path); reads silesia/FILE.")
    var corpus: String

    @Option(help: "Lane counts, comma-separated.")
    var lanes: IntList

    @Option(help: "Silesia files, comma-separated.")
    var files = "mozilla,dickens,samba,x-ray,ooffice"

    @Option(help: "Timed decodes per lane count (median).")
    var decodes = 5

    func run() throws {
        setUserInteractive()
        print("file\tlevel\tlanes\tsegments\tms")
        for name in files.split(separator: ",").map(String.init) {
            let input = try readCorpusFile(corpus, name)
            for level in [1, 6] {
                let compressed = independentStream(input, level: level)
                for lanes in lanes.values {
                    var decoder = ParallelDeflateDecoder(format: .raw, lanes: lanes)
                    var decoded = [UInt8](repeating: 0, count: input.count + 64)
                    var times: [Double] = []
                    for _ in 0..<decodes {
                        let t = now(); _ = decodeAll(&decoder, compressed, into: &decoded); times.append(Double(now() - t) / 1e6)
                    }
                    print("\(name)\t\(level)\t\(lanes)\t\(decoder.lastSegmentCount)\t\(fmt(median(times)))")
                }
                fflush(stdout)
            }
        }
    }
}

// MARK: - Helpers

func setUserInteractive() { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) }

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func randomBytes(_ count: Int) -> [UInt8] {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        bytes[i] = UInt8(truncatingIfNeeded: state)
    }
    return bytes
}

@inline(never) func crcLoop(_ bytes: RawSpan, _ rounds: Int) -> UInt32 {
    var acc: UInt32 = 0
    for _ in 0..<rounds {
        acc ^= CRC32.checksum(bytes)
    }
    return acc
}

@inline(never) func adlerLoop(_ bytes: RawSpan, _ rounds: Int) -> UInt32 {
    var acc: UInt32 = 0
    for _ in 0..<rounds {
        acc ^= Adler32.checksum(bytes)
    }
    return acc
}

func fmt(_ value: Double) -> String { "\((value * 10).rounded() / 10)" }

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

func readCorpusFile(_ corpus: String, _ name: String) throws -> [UInt8] {
    let path = "\(corpus)/silesia/\(name)"
    guard let file = fopen(path, "rb") else { throw ValidationError("missing \(path) (Tools/corpus fetch)") }
    defer { fclose(file) }
    fseek(file, 0, SEEK_END)
    let count = ftell(file)
    fseek(file, 0, SEEK_SET)
    var input = [UInt8](repeating: 0, count: count)
    let read = input.withUnsafeMutableBytes { fread($0.baseAddress, 1, count, file) }
    guard read == count else { throw ValidationError("short read of \(path)") }
    return input
}

/// The stream the decoders read: independent chunks, so the decoder can split it (as the benchmarks' fixture).
func independentStream(_ input: [UInt8], level: Int) -> [UInt8] {
    var encoder = ParallelDeflateEncoder(format: .raw, level: level, chunkSize: 256 << 10, lanes: 24, independentChunks: true)
    var scratch = [UInt8](repeating: 0, count: encoder.maximumCompressedSize(forByteCount: input.count))
    let count = encodeAll(&encoder, input, into: &scratch)
    return Array(scratch.prefix(count))
}

func encodeAll(_ encoder: inout ParallelDeflateEncoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        try! encoder.compressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}

func decodeAll(_ decoder: inout ParallelDeflateDecoder, _ input: [UInt8], into output: inout [UInt8]) -> Int {
    output.withOutputRawSpan { span in
        _ = try! decoder.decompressAll(input.span.bytes, into: &span)
        return span.byteCount
    }
}
