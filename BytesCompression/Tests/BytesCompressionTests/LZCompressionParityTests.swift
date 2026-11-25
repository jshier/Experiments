import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Compression
import Foundation
import Testing

// LZVNEncoder's and LZFSEEncoder's default streams against Compression's own, byte for byte: raw LZVN
// (`compression_encode_buffer` with algorithm 0x900, as APFS `decmpfs` type 8 resource forks hold, in 64 KiB chunks)
// and `COMPRESSION_LZFSE`, failures included: where Compression returns 0 for a destination size, the encoders throw
// `insufficientCapacity` for an output of that free capacity, and nowhere else.

/// Inputs for the comparisons: every size from 0 to 2,000 of text, random bytes, runs, and mixes; periods 1 to 40;
/// and sizes up to 70,000 around 4 KiB and 64 KiB.
enum LZParitySamples {
    static let small: [(name: String, bytes: [UInt8])] = (0...2000).flatMap { size in
        [
            ("text \(size)", LZSamples.text(size, seed: UInt64(size) &+ 1)),
            ("random \(size)", LZSamples.random(size, seed: UInt64(size) &+ 2)),
            ("run \(size)", [UInt8](repeating: UInt8(truncatingIfNeeded: size), count: size)),
            ("mixed \(size)", LZSamples.mixed(size, seed: UInt64(size) &+ 3)),
        ]
    }

    static let larger: [(name: String, bytes: [UInt8])] = {
        var samples: [(String, [UInt8])] = []
        for period in 1...40 {
            for size in [17, 100, 1000, 5000, 65_536, 70_000] {
                samples.append(("period \(period) \(size)", LZSamples.periodic(size, period: period, seed: UInt64(period) &* 7)))
            }
        }
        var generator = SplitMix64(seed: 21)
        for size in [2047, 4095, 4096, 4097, 10_000, 32_768, 40_000, 65_535, 65_536, 65_537, 70_000]
            + (0..<12).map({ _ in Int(generator.next() % 70_000) }) {
            samples.append(("text \(size)", LZSamples.text(size, seed: UInt64(size))))
            samples.append(("random \(size)", LZSamples.random(size, seed: UInt64(size))))
            samples.append(("mixed \(size)", LZSamples.mixed(size, seed: UInt64(size))))
            samples.append(("zeros \(size)", [UInt8](repeating: 0, count: size)))
            // Random bytes then a run: a long literal, then long matches.
            samples.append(("random then run \(size)", LZSamples.random(size / 2, seed: 5) + [UInt8](repeating: 9, count: size - size / 2)))
        }
        return samples
    }()

    /// What the fast tests compare: every size to 300, then every 17th to 2,000; periods 1 to 40 to 5,000 bytes,
    /// and past 64 KiB for a few; every listed boundary size. ``bulk`` is the rest, with ``LZSamples/large``.
    static let fast: [(name: String, bytes: [UInt8])] = (small + larger).filter(isFast)
    static let bulk: [(name: String, bytes: [UInt8])] = (small + larger).filter { !isFast($0) } + LZSamples.large

    private static func isFast(_ sample: (name: String, bytes: [UInt8])) -> Bool {
        let size = sample.bytes.count
        if sample.name.hasPrefix("period ") {
            let period = Int(sample.name.split(separator: " ")[1])!
            return size <= 5000 || [1, 2, 3, 7, 16, 40].contains(period)
        }
        if size <= 2000 { return size <= 300 || size % 17 == 0 || size == 2000 }
        return [2047, 4095, 4096, 4097, 10_000, 32_768, 40_000, 65_535, 65_536, 65_537, 70_000].contains(size)
    }
}

@Suite struct LZVNCompressionParityTests {
    /// Compression's stream, or its failure, for `bytes` into `capacity` bytes, against `encoder`'s.
    static func compare(_ bytes: [UInt8], capacity: Int, encoder: inout LZVNEncoder, _ name: String) {
        let apple = appleEncode(bytes, COMPRESSION_LZVN_RAW, capacity: capacity)
        let ours = lzvnEncode(bytes, encoder: &encoder, capacity: capacity)
        if bytes.count < 8 {
            // Compression fails under 8 bytes, whatever the room; this writes a literal (the reference's stream),
            // 9 bytes longer than the input, where it fits.
            #expect(apple == nil, "\(name)")
            if case let .success(stream) = ours {
                #expect(stream.count == bytes.count + (bytes.isEmpty ? 8 : 9), "\(name)")
                #expect(lzvnDecode(stream, capacity: bytes.count) == .success(bytes), "\(name)")
            }
            return
        }
        switch (apple, ours) {
        case let (apple?, .success(stream)):
            #expect(stream == apple, "\(name) into \(capacity)")
        case (nil, let .failure(error)):
            #expect(error == .insufficientCapacity, "\(name) into \(capacity)")
        default:
            Issue.record("\(name) into \(capacity): Compression \(apple.map { "wrote \($0.count)" } ?? "failed"), Bytes \(ours)")
        }
    }

    /// The fast samples and the encoder samples, with room to spare: Compression's bytes, decoded back. The other
    /// sizes and the large inputs in LZCompressionParityBulkTests.
    @Test func samples() {
        Self.checkSamples(LZParitySamples.fast + LZEncoderSamples.all)
    }

    static func checkSamples(_ samples: [(name: String, bytes: [UInt8])]) {
        var encoder = LZVNEncoder()
        for (name, bytes) in samples {
            let capacity = LZVNEncoder.maximumCompressedSize(forByteCount: bytes.count)
            compare(bytes, capacity: capacity, encoder: &encoder, name)
            // `maximumCompressedSize` is always enough.
            guard case let .success(stream) = lzvnEncode(bytes, encoder: &encoder) else {
                Issue.record("\(name): didn't fit in maximumCompressedSize")
                continue
            }
            #expect(lzvnDecode(stream, capacity: bytes.count) == .success(bytes), "\(name)")
        }
    }

    /// The corpus whole (each file's first 16 MiB) and in 64 KiB chunks given 64 KiB of room, as `decmpfs` gives them
    /// (chunks that don't fit fail in both), and with room to spare.
    static func checkCorpus() {
        var encoder = LZVNEncoder()
        for (name, bytes) in LZEncoderSamples.corpus {
            compare(bytes, capacity: LZVNEncoder.maximumCompressedSize(forByteCount: bytes.count), encoder: &encoder, name)
            for start in stride(from: 0, to: min(bytes.count, 4 << 20), by: 65_536) {
                let chunk = Array(bytes[start..<min(start + 65_536, bytes.count)])
                compare(chunk, capacity: 65_536, encoder: &encoder, "\(name) at \(start)")
                compare(chunk, capacity: LZVNEncoder.maximumCompressedSize(forByteCount: chunk.count), encoder: &encoder, "\(name) at \(start)")
                if case let .success(stream) = lzvnEncode(chunk, encoder: &encoder, capacity: 65_536) {
                    #expect(lzvnDecode(stream, capacity: chunk.count) == .success(chunk), "\(name) at \(start)")
                }
            }
        }
    }

    static let roomSizes = [8, 9, 12, 15, 16, 17, 20, 31, 100, 271, 272, 287, 300, 1000, 4095, 5000, 65_536, 70_000]

    /// Room around what each stream needs: Compression's checks keep up to 18 bytes free, so a stream of its own size
    /// doesn't fit, and the smallest room that does is where Compression's is. Sizes to 5,000 and 40 random mixes;
    /// 64 KiB and 70,000 bytes in LZCompressionParityBulkTests.
    @Test func room() {
        var generator = SplitMix64(seed: 77)
        var samples: [(String, [UInt8])] = []
        for size in Self.roomSizes where size <= 5000 {
            samples += Self.roomSamples(size)
        }
        for _ in 0..<40 {
            let size = 8 + Int(generator.next() % 3000)
            samples.append(("mixed \(size)", LZSamples.mixed(size, seed: generator.next())))
        }
        Self.checkRoom(samples)
    }

    static func roomSamples(_ size: Int) -> [(String, [UInt8])] {
        [
            ("text \(size)", LZSamples.text(size, seed: 3)), ("random \(size)", LZSamples.random(size, seed: 3)),
            ("mixed \(size)", LZSamples.mixed(size, seed: 3)), ("run \(size)", [UInt8](repeating: 0x61, count: size)),
            ("period 3 \(size)", LZSamples.periodic(size, period: 3, seed: 3)),
        ]
    }

    static func checkRoom(_ samples: [(String, [UInt8])]) {
        var encoder = LZVNEncoder()
        var smallest: [Int: Int] = [:]
        for (name, bytes) in samples {
            let full = appleEncode(bytes, COMPRESSION_LZVN_RAW, capacity: LZVNEncoder.maximumCompressedSize(forByteCount: bytes.count))!
            let capacities = bytes.count <= 300
                ? Set(0...(full.count + 40)) : Set(Array(0...24) + Array(max(0, full.count - 40)...(full.count + 40)))
            for capacity in capacities.sorted() {
                compare(bytes, capacity: capacity, encoder: &encoder, name)
            }
            // The least room Compression's stream takes, past its own size.
            let least = (full.count...(full.count + 40)).first { appleEncode(bytes, COMPRESSION_LZVN_RAW, capacity: $0) != nil }!
            smallest[least - full.count, default: 0] += 1
        }
        // The extra room: at least 1 byte (after a match), at most 10 (after a literal's 1-byte-opcode piece: its
        // check keeps 10 bytes free besides the 8 the end-of-stream opcode takes).
        #expect(smallest.keys.allSatisfy { (1...10).contains($0) }, "\(smallest)")
    }

    /// The reference's parse checks room as Compression does (the stream with room to spare, or a failure, and
    /// failures only below some room), and writes inputs under 8 bytes as a literal. Every room to 40 past the
    /// stream for inputs to 100 bytes; for 5,000 bytes, every room within 40 of the stream's size and every 23rd
    /// below (every one in LZCompressionParityBulkTests).
    @Test func referenceRoom() throws {
        try Self.checkReferenceRoom { full, size in
            size <= 100 ? Array(0...(full + 40)) : Array(stride(from: 0, to: full - 40, by: 23)) + Array((full - 40)...(full + 40))
        }
    }

    static func checkReferenceRoom(capacities: (_ full: Int, _ size: Int) -> [Int]) throws {
        var reference = LZVNEncoder(parse: .reference)
        for size in [0, 1, 7, 8, 100, 5000] {
            for bytes in [LZSamples.random(size, seed: 9), LZSamples.text(size, seed: 9)] {
                let full = try lzvnEncode(bytes, encoder: &reference).get()
                var fitted = false
                for capacity in capacities(full.count, size) {
                    switch lzvnEncode(bytes, encoder: &reference, capacity: capacity) {
                    case let .success(stream):
                        #expect(stream == full, "\(size) into \(capacity)")
                        fitted = true
                    case let .failure(error):
                        #expect(error == .insufficientCapacity && !fitted, "\(size) into \(capacity)")
                    }
                }
                if size < 8 {
                    // A literal of `size` bytes leaves 10 free, then 8 for the end-of-stream opcode; nothing, 8.
                    #expect(full.count == (size == 0 ? 8 : size + 9))
                    let least = size == 0 ? 8 : size + 19
                    #expect(lzvnEncode(bytes, encoder: &reference, capacity: least) == .success(full))
                    #expect(lzvnEncode(bytes, encoder: &reference, capacity: least - 1) == .failure(.insufficientCapacity))
                }
            }
        }
    }
}

@Suite struct LZFSECompressionParityTests {
    static func compare(_ bytes: [UInt8], capacity: Int, encoder: inout LZFSEEncoder, _ name: String) {
        let apple = appleEncode(bytes, COMPRESSION_LZFSE, capacity: capacity)
        let ours = lzfseEncode(bytes, encoder: &encoder, capacity: capacity)
        switch (apple, ours) {
        case let (apple?, .success(stream)):
            #expect(stream == apple, "\(name) into \(capacity)")
        case (nil, let .failure(error)):
            #expect(error == .insufficientCapacity, "\(name) into \(capacity)")
        default:
            Issue.record("\(name) into \(capacity): Compression \(apple.map { "wrote \($0.count)" } ?? "failed"), Bytes \(ours)")
        }
    }

    /// The fast samples and the encoder samples: Compression's stream, `bvxn` blocks (its LZVN) and block boundaries
    /// included. The other sizes and the large inputs in LZCompressionParityBulkTests.
    @Test func samples() {
        Self.checkSamples(LZParitySamples.fast + LZEncoderSamples.all)
    }

    static func checkSamples(_ samples: [(name: String, bytes: [UInt8])]) {
        var encoder = LZFSEEncoder()
        var decoder = LZFSEDecoder()
        for (name, bytes) in samples {
            compare(bytes, capacity: LZFSEEncoder.maximumCompressedSize(forByteCount: bytes.count), encoder: &encoder, name)
            // `maximumCompressedSize` is always enough.
            guard case let .success(stream) = lzfseEncode(bytes, encoder: &encoder) else {
                Issue.record("\(name): didn't fit in maximumCompressedSize")
                continue
            }
            if bytes.count > 2000 {
                #expect(lzfseDecode(stream, capacity: bytes.count, decoder: &decoder) == .success(bytes), "\(name)")
            }
        }
    }

    /// The corpus whole (first 16 MiB) and in 64 KiB chunks given 64 KiB of room, as `decmpfs` gives them.
    static func checkCorpus() {
        var encoder = LZFSEEncoder()
        for (name, bytes) in LZEncoderSamples.corpus {
            compare(bytes, capacity: LZFSEEncoder.maximumCompressedSize(forByteCount: bytes.count), encoder: &encoder, name)
            for start in stride(from: 0, to: min(bytes.count, 4 << 20), by: 65_536) {
                let chunk = Array(bytes[start..<min(start + 65_536, bytes.count)])
                compare(chunk, capacity: 65_536, encoder: &encoder, "\(name) at \(start)")
            }
        }
    }

    static let roomSizes = [0, 5, 8, 9, 100, 1000, 3000, 4095, 4096, 5000, 70_000]

    /// Room around what each stream needs, and the fallback to a stored block where Compression falls back.
    /// Compression checks room for a whole 752-byte block header at each block's start, and 16 bytes before each
    /// group of literals and each triple, so a compressed stream needs room well past its size. Inputs to 5,000
    /// bytes; 70,000 bytes and corpus chunks in LZCompressionParityBulkTests.
    @Test func room() {
        Self.checkRoom(Self.roomSizes.filter { $0 <= 5000 }.flatMap(Self.roomSamples))
    }

    static func roomSamples(_ size: Int) -> [(String, [UInt8])] {
        [("text \(size)", LZSamples.text(size, seed: 5)), ("random \(size)", LZSamples.random(size, seed: 5)), ("mixed \(size)", LZSamples.mixed(size, seed: 5))]
    }

    /// A chunk from the middle of each corpus file (the start of mozilla is mostly zeros).
    static var corpusRoomSamples: [(String, [UInt8])] {
        LZEncoderSamples.corpus.map { name, bytes in
            let start = min(bytes.count / 2, 1 << 20) & ~0xFFFF
            return ("\(name) at \(start)", Array(bytes[start..<min(start + 65_536, bytes.count)]))
        }
    }

    static func checkRoom(_ inputs: [(String, [UInt8])]) {
        var encoder = LZFSEEncoder()
        for (name, bytes) in inputs {
            let size = bytes.count
            let full = appleEncode(bytes, COMPRESSION_LZFSE, capacity: LZFSEEncoder.maximumCompressedSize(forByteCount: size))!
            // Every capacity near the stream's and the input's sizes, and every ninth up to 800 past the stream's.
            let around = Set(
                Array(0...40) + Array(max(0, full.count - 60)...(full.count + 60))
                    + Array(stride(from: full.count, through: full.count + 800, by: 9)) + Array(max(0, size - 20)...(size + 40))
            )
            for capacity in around.sorted() {
                compare(bytes, capacity: capacity, encoder: &encoder, name)
            }
        }
    }
}

/// The parity sweeps the fast tests sample: the other sizes and the large inputs, room around 64 KiB inputs and
/// corpus chunks, every room for the reference's parse, and the corpus (if present).
@Suite(.bulk) struct LZCompressionParityBulkTests {
    @Test func lzvnSamples() { LZVNCompressionParityTests.checkSamples(LZParitySamples.bulk) }

    @Test func lzvnCorpus() { LZVNCompressionParityTests.checkCorpus() }

    @Test func lzvnRoom() {
        LZVNCompressionParityTests.checkRoom(LZVNCompressionParityTests.roomSizes.filter { $0 > 5000 }.flatMap(LZVNCompressionParityTests.roomSamples))
    }

    @Test func lzvnReferenceRoom() throws {
        try LZVNCompressionParityTests.checkReferenceRoom { full, _ in Array(0...(full + 40)) }
    }

    @Test func lzfseSamples() { LZFSECompressionParityTests.checkSamples(LZParitySamples.bulk) }

    @Test func lzfseCorpus() { LZFSECompressionParityTests.checkCorpus() }

    @Test func lzfseRoom() {
        LZFSECompressionParityTests.checkRoom(
            LZFSECompressionParityTests.roomSizes.filter { $0 > 5000 }.flatMap(LZFSECompressionParityTests.roomSamples)
                + LZFSECompressionParityTests.corpusRoomSamples
        )
    }
}
