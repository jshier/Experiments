import Bytes
import BytesCompression
import Compression
import Testing

// The LZ decoders near the ends of small outputs: real streams decoded into exactly sized outputs of 0 to 80 bytes
// (and smaller ones), with guard bytes on both sides that must come back untouched. (The fast paths once clamped
// their limits to the output's start, so an empty literal near the end copied 16 bytes, and LZ4's shortcut wrote
// up to 46, past the output.) Under `--sanitize=address` the exact input allocations catch reads too.

/// Decodes with `body` into `capacity` bytes between two 64-byte guards.
///
/// - Returns: What `body` returned or threw, the bytes it appended, and whether the guards are untouched.
func guardedDecode(
    _ stream: [UInt8], capacity: Int, _ body: (RawSpan, inout OutputRawSpan) throws(BytesError) -> Int
) -> (result: Result<Int, BytesError>, output: [UInt8], guardsIntact: Bool) {
    let guardSize = 64
    let pattern: UInt8 = 0xA5
    let inputBytes = UnsafeMutableRawBufferPointer.allocate(byteCount: stream.count, alignment: 1)
    defer { inputBytes.deallocate() }
    stream.withUnsafeBytes { inputBytes.copyMemory(from: $0) }
    let whole = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity + 2 * guardSize, alignment: 16)
    defer { whole.deallocate() }
    whole.initializeMemory(as: UInt8.self, repeating: pattern)
    let outputBytes = UnsafeMutableRawBufferPointer(rebasing: whole[guardSize..<guardSize + capacity])
    var output = OutputRawSpan(buffer: outputBytes, initializedCount: 0)
    let result: Result<Int, BytesError>
    do throws(BytesError) {
        result = .success(try body(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(inputBytes)), &output))
    } catch {
        result = .failure(error)
    }
    let written = output.finalize(for: outputBytes)
    let intact = whole[..<guardSize].allSatisfy { $0 == pattern } && whole[(guardSize + capacity)...].allSatisfy { $0 == pattern }
    return (result, Array(outputBytes[..<written]), intact)
}

@Suite struct LZOutputBoundsTests {
    static let inputs: [(name: String, bytes: [UInt8])] = (0...80).flatMap { size in
        [
            ("text \(size)", LZSamples.text(size, seed: UInt64(size))),
            ("random \(size)", LZSamples.random(size, seed: UInt64(size))),
            ("run \(size)", [UInt8](repeating: 0x61, count: size)),
            ("mixed \(size)", LZSamples.mixed(size, seed: UInt64(size))),
            ("period 3 \(size)", LZSamples.periodic(size, period: 3, seed: 3)),
        ]
    }

    /// Exactly sized, one byte short, and half.
    static func capacities(_ size: Int) -> [Int] { Array(Set([size, max(size - 1, 0), size / 2])) }

    @Test func lz4Raw() {
        for (name, bytes) in Self.inputs {
            let stream = appleEncode(bytes, COMPRESSION_LZ4_RAW)
            for capacity in Self.capacities(bytes.count) {
                let (result, output, intact) = guardedDecode(stream, capacity: capacity) { input, output throws(BytesError) in
                    try LZ4Decoder().decompressRaw(input, decodedSize: bytes.count, into: &output)
                    return output.byteCount
                }
                #expect(intact, "\(name) into \(capacity)")
                if capacity == bytes.count { #expect(result == .success(bytes.count) && output == bytes, "\(name)") }
            }
        }
    }

    /// A raw block told to decode to fewer bytes than it holds, into exactly that many: the fast paths must not run
    /// past the end before the decoder finds out. (Into 20 bytes, the shortcut wrote 5 past; into 8, 8.)
    @Test func lz4RawShortDecodedSize() {
        // Short sequences from the start (1 literal, a 4-byte match at offset 1, 20 times, then 5 literals): what the
        // shortcut takes, in a stream long enough for its input bound.
        let shortSequences = (0..<20).flatMap { _ in [0x10, 0x61, 0x01, 0x00] as [UInt8] } + [0x50] + Array("tail.".utf8)
        let streams = Self.inputs.map { ($0.name, appleEncode($0.bytes, COMPRESSION_LZ4_RAW), $0.bytes.count) }
            + [("short sequences", shortSequences, 105), ("text 300", appleEncode(LZSamples.text(300, seed: 1), COMPRESSION_LZ4_RAW), 300)]
        for (name, stream, size) in streams {
            for capacity in 0..<min(size, 80) {
                let (result, _, intact) = guardedDecode(stream, capacity: capacity) { input, output throws(BytesError) in
                    try LZ4Decoder().decompressRaw(input, decodedSize: capacity, into: &output)
                    return output.byteCount
                }
                #expect(intact, "\(name) into \(capacity)")
                #expect((try? result.get()) == nil, "\(name) into \(capacity)")
            }
        }
    }

    /// The last block of a stream ending a few bytes before the output's end: LZ4 framed and LZFSE streams of a
    /// 64 KiB block and a small one.
    @Test func smallLastBlocks() {
        var decoder = LZFSEDecoder()
        for extra in [0, 1, 5, 15, 16, 17, 40] {
            let bytes = LZSamples.text(65_536 + extra, seed: UInt64(extra))
            for (algorithm, label) in [(COMPRESSION_LZ4, "LZ4"), (COMPRESSION_LZFSE, "LZFSE")] {
                let stream = appleEncode(bytes, algorithm)
                let (result, output, intact) = guardedDecode(stream, capacity: bytes.count) { input, output throws(BytesError) in
                    algorithm == COMPRESSION_LZ4 ? try LZ4Decoder().decompressFramed(input, into: &output) : try decoder.decompressAll(input, into: &output)
                }
                #expect(intact, "\(label) 65536 + \(extra)")
                #expect(result == .success(stream.count) && output == bytes, "\(label) 65536 + \(extra)")
            }
        }
    }

    /// An LZFSE block whose one triple is empty (no literals, no match: valid, if pointless), decoded with no room
    /// left: an empty copy still moves 16 bytes on the fast path, so it must take the exact one.
    @Test func lzfseEmptyTripleAtTheEnd() {
        var stream = Array("bvx-".utf8) + [10, 0, 0, 0] + Array("0123456789".utf8)
        // A `bvx1` block: 0 bytes decoded, no literals, one triple (L 0, M 0, D 1) coded in 0 bits: each table gives
        // all its states to one symbol.
        var header = [UInt8](repeating: 0, count: 772)
        func store32(_ value: Int, at offset: Int) { for i in 0..<4 { header[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) } }
        func store16(_ value: Int, at offset: Int) { for i in 0..<2 { header[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) } }
        header.replaceSubrange(0..<4, with: Array("bvx1".utf8))
        store32(1, at: 16) // matches
        store32(8, at: 8) // payload bytes
        store32(8, at: 24) // L, M, D payload: 8 bytes of padding
        store16(64, at: 50) // L symbol 0: all 64 states
        store16(64, at: 50 + 2 * 20) // M symbol 0
        store16(256, at: 50 + 2 * (40 + 1)) // D symbol 1 (distance 1)
        stream += header + [UInt8](repeating: 0, count: 8) + Array("bvx$".utf8)
        var decoder = LZFSEDecoder()
        let (result, output, intact) = guardedDecode(stream, capacity: 10) { input, output throws(BytesError) in
            try decoder.decompressAll(input, into: &output)
        }
        #expect(intact)
        #expect(result == .success(stream.count) && output == Array("0123456789".utf8))
    }

    @Test func lz4Framed() {
        for (name, bytes) in Self.inputs {
            let stream = appleEncode(bytes, COMPRESSION_LZ4)
            for capacity in Self.capacities(bytes.count) {
                let (result, output, intact) = guardedDecode(stream, capacity: capacity) { input, output throws(BytesError) in
                    try LZ4Decoder().decompressFramed(input, into: &output)
                }
                #expect(intact, "\(name) into \(capacity)")
                if capacity == bytes.count { #expect(result == .success(stream.count) && output == bytes, "\(name)") }
            }
        }
    }

    @Test func lzfse() throws {
        var decoder = LZFSEDecoder()
        var encoder = LZFSEEncoder()
        for (name, bytes) in Self.inputs {
            let ours = try lzfseEncode(bytes, encoder: &encoder).get()
            for stream in [appleEncode(bytes, COMPRESSION_LZFSE), ours] {
                for capacity in Self.capacities(bytes.count) {
                    let (result, output, intact) = guardedDecode(stream, capacity: capacity) { input, output throws(BytesError) in
                        try decoder.decompressAll(input, into: &output)
                    }
                    #expect(intact, "\(name) into \(capacity)")
                    if capacity == bytes.count { #expect(result == .success(stream.count) && output == bytes, "\(name)") }
                }
            }
        }
    }

    @Test func lzvn() throws {
        var encoder = LZVNEncoder()
        for (name, bytes) in Self.inputs {
            let stream = try lzvnEncode(bytes, encoder: &encoder).get()
            for capacity in Self.capacities(bytes.count) {
                let (result, output, intact) = guardedDecode(stream, capacity: capacity) { input, output throws(BytesError) in
                    try LZVNDecoder().decompressAll(input, into: &output)
                }
                #expect(intact, "\(name) into \(capacity)")
                if capacity == bytes.count { #expect(result == .success(stream.count) && output == bytes, "\(name)") }
            }
        }
    }

    /// The encoders too: exactly sized and short outputs, guards untouched.
    @Test func encoders() throws {
        var lzfse = LZFSEEncoder()
        var lzvn = LZVNEncoder()
        for (name, bytes) in Self.inputs + [("text 5000", LZSamples.text(5000, seed: 1)), ("mixed 70000", LZSamples.mixed(70_000, seed: 1))] {
            let lzfseSize = try lzfseEncode(bytes, encoder: &lzfse).get().count
            let lzvnSize = try lzvnEncode(bytes, encoder: &lzvn).get().count
            for capacity in Set([lzfseSize, lzfseSize - 1, lzfseSize / 2, 0]) {
                let (_, _, intact) = guardedDecode(bytes, capacity: capacity) { input, output throws(BytesError) in
                    try lzfse.compressAll(input, into: &output)
                }
                #expect(intact, "LZFSE \(name) into \(capacity)")
            }
            for capacity in Set([lzvnSize, lzvnSize - 1, lzvnSize / 2, 0]) {
                let (_, _, intact) = guardedDecode(bytes, capacity: capacity) { input, output throws(BytesError) in
                    try lzvn.compressAll(input, into: &output)
                }
                #expect(intact, "LZVN \(name) into \(capacity)")
            }
        }
    }
}
