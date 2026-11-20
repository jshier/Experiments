import Bytes
import BytesCompression
import BytesTesting
import BytesTestSupport
import Compression
import Testing

// MARK: - References

/// Compression's LZBITMAP encoding of `data` (the only encoder: there is no other source of streams).
func lzbitmapCompress(_ data: [UInt8]) -> [UInt8] {
    if data.isEmpty { return [0x5A, 0x42, 0x4D, 0x09, 6, 0, 0, 0, 0, 0] } // Compression encodes nothing as nothing.
    var output = [UInt8](repeating: 0, count: data.count + data.count / 1024 + 64)
    let count = data.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { output in
            compression_encode_buffer(output.baseAddress!, output.count, input.baseAddress!, input.count, nil, COMPRESSION_LZBITMAP)
        }
    }
    precondition(count > 0)
    return Array(output[..<count])
}

/// Compression's decoding into `capacity` bytes: what it wrote (its buffer API returns 0 for corrupt input,
/// and what fits when the output is too small; its stream API doesn't support LZBITMAP).
func appleLZBitmapDecode(_ data: [UInt8], capacity: Int) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: max(capacity, 1))
    let count = data.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { output in
            input.isEmpty ? 0 : compression_decode_buffer(output.baseAddress!, capacity, input.baseAddress!, input.count, nil, COMPRESSION_LZBITMAP)
        }
    }
    return Array(output[..<count])
}

/// Bytes' decoding into exactly `capacity` bytes.
func lzbitmapDecode(
    _ data: [UInt8], capacity: Int, expectedSize: Int? = nil, decoder: inout LZBitmapDecoder
) -> Result<(output: [UInt8], consumed: Int), BytesError> {
    var output = [UInt8](repeating: 0xEE, count: capacity)
    var consumed = 0
    let result: Result<Int, BytesError> = output.withUnsafeMutableBytes { buffer in
        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
        do throws(BytesError) {
            consumed = try decoder.decompressAll(data.span.bytes, decodedSize: expectedSize, into: &span)
        } catch {
            _ = span.finalize(for: buffer)
            return .failure(error)
        }
        return .success(span.finalize(for: buffer))
    }
    return result.map { (Array(output[..<$0]), consumed) }
}

func lzbitmapDecode(_ data: [UInt8], capacity: Int, expectedSize: Int? = nil) -> Result<(output: [UInt8], consumed: Int), BytesError> {
    var decoder = LZBitmapDecoder()
    return lzbitmapDecode(data, capacity: capacity, expectedSize: expectedSize, decoder: &decoder)
}

/// The format as Compression's decoder accepts it, a byte at a time (Benchmarks/RESULTS-lzbitmap.md): an
/// independent check of Bytes' decoder, written for clarity. Nil for a stream Compression rejects.
///
/// - Parameter lax: Decode corrupt streams as Compression's fast loop does (all but a chunk's last few groups),
///   where its careful loop rejects them or copies a byte at a time: copy a group from the output's start
///   when its period is under 8 or reaches before the start, and read bitmaps past their area, up to the
///   chunk's end.
func referenceLZBitmapDecode(_ stream: [UInt8], lax: Bool = false) -> [UInt8]? {
    // "ZBM" and 0x09, or 0x08 (the same); 0x0C or 0x0D allow only stored chunks.
    guard stream.count >= 4, stream.starts(with: [0x5A, 0x42, 0x4D]), [0x08, 0x09, 0x0C, 0x0D].contains(stream[3]) else { return nil }
    let storedOnly = stream[3] & 4 != 0
    func u24(_ index: Int) -> Int { Int(stream[index]) | Int(stream[index + 1]) << 8 | Int(stream[index + 2]) << 16 }
    var output: [UInt8] = []
    var position = 4
    while true {
        guard stream.count - position >= 6 else { return nil }
        let length = u24(position), size = u24(position + 3)
        if size == 0 { return length == 6 ? output : nil }
        guard size <= 0x8000, length <= stream.count - position else { return nil }
        if length == size + 6 { // Stored.
            output += stream[(position + 6)..<(position + length)]
            position += length
            continue
        }
        guard length < size + 6, length >= 32, !storedOnly else { return nil }
        let chunk = position
        let literalsEnd = chunk + u24(chunk + 6), periodsEnd = chunk + u24(chunk + 9), bitmapsEnd = chunk + u24(chunk + 12)
        let nibblesEnd = chunk + length - 17
        guard chunk + 15 <= literalsEnd, literalsEnd <= periodsEnd, periodsEnd <= bitmapsEnd, bitmapsEnd <= nibblesEnd,
              nibblesEnd - bitmapsEnd <= 2048 else { return nil }
        // Twelve 10-bit table entries: a bitmap and its period's byte count.
        var table: [(bitmap: UInt8, periodBytes: Int)] = []
        for entry in 0..<12 {
            var value = 0
            for bit in 0..<10 {
                let index = entry * 10 + bit
                value |= Int(stream[nibblesEnd + index / 8] >> (index % 8) & 1) << bit
            }
            guard value >> 8 <= 2 else { return nil }
            table.append((UInt8(value & 0xFF), value >> 8))
        }
        var literal = chunk + 15, period = literalsEnd, bitmapCursor = periodsEnd, nibbleIndex = 0
        let nibbleCount = (nibblesEnd - bitmapsEnd) * 2
        func nibble(at index: Int) -> Int { Int(index % 2 == 0 ? stream[bitmapsEnd + index / 2] & 15 : stream[bitmapsEnd + index / 2] >> 4) }
        var distance = 8
        let end = output.count + size
        while output.count < end {
            guard nibbleIndex < nibbleCount else { return nil }
            let code = nibble(at: nibbleIndex)
            nibbleIndex += 1
            guard code != 15 else { return nil }
            var repeats = 1
            if end - output.count > 8 {
                guard nibbleIndex < nibbleCount else { return nil }
                if nibble(at: nibbleIndex) == 15 {
                    nibbleIndex += 1
                    repeats = 4
                    while true {
                        guard nibbleIndex < nibbleCount else { return nil }
                        let value = nibble(at: nibbleIndex)
                        nibbleIndex += 1
                        repeats += value
                        if value != 15 { break }
                    }
                }
            }
            for _ in 0..<repeats where output.count < end {
                var bitmap: UInt8
                var periodBytes: Int
                if code < 3 {
                    guard bitmapCursor < (lax ? chunk + length : bitmapsEnd) else { return nil }
                    bitmap = stream[bitmapCursor]
                    bitmapCursor += 1
                    periodBytes = code
                } else {
                    (bitmap, periodBytes) = table[code - 3]
                }
                if periodBytes > 0 {
                    guard period + periodBytes <= periodsEnd else { return nil }
                    distance = Int(stream[period]) | (periodBytes == 2 ? Int(stream[period + 1]) << 8 : 0)
                    period += periodBytes
                }
                var source = output.count - distance
                if bitmap != 0xFF, lax, distance < 8 || source < 0 {
                    source = 0
                } else if bitmap != 0xFF {
                    guard distance > 0, source >= 0 else { return nil }
                }
                for lane in 0..<min(8, end - output.count) {
                    if bitmap >> lane & 1 == 1 {
                        guard literal < literalsEnd else { return nil }
                        output.append(stream[literal])
                        literal += 1
                    } else {
                        output.append(output[source + lane])
                    }
                }
            }
        }
        guard literal == literalsEnd, period == periodsEnd else { return nil }
        position += length
    }
}

// MARK: - Crafted chunks

/// One compressed chunk built field by field, to test the rules Compression's decoder enforces (Compression
/// is the reference: these streams' expected results are its results). It starts with padding, a literal
/// group then 19 matches at period 8 (160 bytes), so it's long enough to count as compressed.
struct CraftedChunk {
    var literals: [UInt8] = []
    var periods: [UInt8] = []
    var bitmaps: [UInt8] = []
    var nibbles: [UInt8] = []
    /// Table entry 0 is 0x00, entry 1 is 0xFF: nibbles 3 and 4.
    var trailer: [UInt8] = [0x00, 0xFC, 0x03] + [UInt8](repeating: 0, count: 14)
    var groups = 0
    var size: Int?

    init(padded: Bool = true) {
        if padded {
            literalGroup(Array("abcdefgh".utf8))
            nibbles += [3, 15, 15, 0]
            groups += 19
        }
    }

    mutating func literalGroup(_ bytes: [UInt8]) {
        nibbles.append(4)
        literals += bytes
        groups += 1
    }

    /// A group with its bitmap from the bitmap area and `periodBytes` bytes of new period.
    mutating func group(_ bitmap: UInt8, periodBytes: Int = 0, period: Int = 0, literals bytes: [UInt8] = []) {
        nibbles.append(UInt8(periodBytes))
        bitmaps.append(bitmap)
        for index in 0..<periodBytes { periods.append(UInt8(truncatingIfNeeded: period >> (8 * index))) }
        literals += bytes
        groups += 1
    }

    /// The chunk, in a stream with its magic and end chunk.
    var stream: [UInt8] {
        var chunk = [UInt8](repeating: 0, count: 15)
        func put24(_ value: Int, at offset: Int) {
            chunk[offset] = UInt8(value & 0xFF)
            chunk[offset + 1] = UInt8(value >> 8 & 0xFF)
            chunk[offset + 2] = UInt8(value >> 16 & 0xFF)
        }
        chunk += literals
        put24(chunk.count, at: 6)
        chunk += periods
        put24(chunk.count, at: 9)
        chunk += bitmaps
        put24(chunk.count, at: 12)
        for index in stride(from: 0, to: nibbles.count, by: 2) {
            chunk.append(nibbles[index] | (index + 1 < nibbles.count ? nibbles[index + 1] << 4 : 0))
        }
        chunk += trailer
        put24(chunk.count, at: 0)
        put24(size ?? groups * 8, at: 3)
        return [0x5A, 0x42, 0x4D, 0x09] + chunk + [6, 0, 0, 0, 0, 0]
    }
}

// MARK: - Tests

@Suite("LZBITMAP decoder")
struct LZBitmapDecoderTests {
    /// Inputs: text, random bytes, runs, short periods, and mixes, cut to `size`.
    static func content(_ kind: Int, size: Int) -> [UInt8] {
        var rng = SplitMix64(seed: UInt64(size &* 31 &+ kind))
        let words = ["swift", "byte", "span", "bitmap", "period", "chunk", "nibble", " ", "\n", "the", "a"]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size + 16)
        switch kind {
        case 0: // Text.
            while bytes.count < size { bytes += Array(words.randomElement(using: &rng)!.utf8) }
        case 1: // Random: stored chunks.
            while bytes.count < size { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
        case 2: // Zeros: long repetitions.
            bytes = [UInt8](repeating: 0, count: size)
        case 3: // Period 3, with sparse changes.
            while bytes.count < size {
                let byte = UInt8.random(in: 0...255, using: &rng)
                bytes.append(byte < 8 || bytes.count < 3 ? byte : bytes[bytes.count - 3])
            }
        default: // Text and random blocks, so chunks alternate between stored and compressed.
            while bytes.count < size {
                if Bool.random(using: &rng) {
                    for _ in 0..<Int.random(in: 1...3000, using: &rng) { bytes += Array(words.randomElement(using: &rng)!.utf8) }
                } else {
                    for _ in 0..<Int.random(in: 1...40000, using: &rng) { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
                }
            }
        }
        return Array(bytes.prefix(size))
    }

    static let sizes = [0, 1, 7, 8, 9, 26, 27, 31, 32, 33, 39, 40, 41, 63, 64, 65, 100, 1000, 4095, 4096, 4097,
                        32767, 32768, 32769, 32775, 40000, 65535, 65536, 65537, 98_304, 100_003]

    @Test("Compression's streams round-trip, agreeing with Compression", arguments: 0..<5)
    func roundTrips(kind: Int) throws {
        var decoder = LZBitmapDecoder()
        for size in Self.sizes {
            let data = Self.content(kind, size: size)
            let compressed = lzbitmapCompress(data)
            #expect(appleLZBitmapDecode(compressed, capacity: size + 64) == data)
            #expect(try LZBitmapDecoder.decompressedSize(of: compressed.span.bytes) == size)
            // Exactly the room needed, with and without the size stated.
            for expected in [nil, size] as [Int?] {
                switch lzbitmapDecode(compressed, capacity: size, expectedSize: expected, decoder: &decoder) {
                case let .success((output, consumed)):
                    #expect(output == data, "kind \(kind), size \(size)")
                    #expect(consumed == compressed.count)
                case let .failure(error):
                    Issue.record("kind \(kind), size \(size): \(error)")
                }
            }
        }
    }

    /// Half a megabyte here; 7 MB in LZBitmapDecoderBulkTests.
    @Test("Hundreds of kilobytes, the window reaching across chunks")
    func large() {
        Self.checkLarge(samples()[2].bytes + Self.content(4, size: 200_000) + Self.content(3, size: 100_013))
    }

    static func checkLarge(_ data: [UInt8]) {
        let compressed = lzbitmapCompress(data)
        var decoder = LZBitmapDecoder()
        guard case let .success((output, _)) = lzbitmapDecode(compressed, capacity: data.count, decoder: &decoder) else {
            Issue.record("failed")
            return
        }
        #expect(output == data)
        #expect(appleLZBitmapDecode(compressed, capacity: data.count) == data)
    }

    @Test("Output too small, too large, or not the stated size")
    func sizes() {
        let data = Self.content(0, size: 70_000)
        let compressed = lzbitmapCompress(data)
        #expect(throws: BytesError.insufficientCapacity) { _ = try lzbitmapDecode(compressed, capacity: data.count - 1).get() }
        #expect(throws: BytesError.insufficientCapacity) {
            _ = try lzbitmapDecode(compressed, capacity: data.count - 1, expectedSize: data.count).get()
        }
        #expect(throws: BytesError.mismatch) {
            _ = try lzbitmapDecode(compressed, capacity: data.count + 10, expectedSize: data.count + 1).get()
        }
        #expect(throws: BytesError.mismatch) {
            _ = try lzbitmapDecode(compressed, capacity: data.count, expectedSize: data.count - 1).get()
        }
        #expect(throws: BytesError.invalidValue) {
            _ = try lzbitmapDecode(compressed, capacity: data.count, expectedSize: -1).get()
        }
        // More room than needed: the rest of the buffer isn't touched.
        let roomy = lzbitmapDecode(compressed, capacity: data.count + 100)
        #expect((try? roomy.get().output) == data)
    }

    @Test("Appending to output that has bytes: copies can't reach them")
    func appending() throws {
        let data = Self.content(4, size: 100_000)
        let compressed = lzbitmapCompress(data)
        var tooFar = CraftedChunk()
        tooFar.group(0x00, periodBytes: 2, period: 161)
        var decoder = LZBitmapDecoder()
        var buffer = [UInt8](repeating: 0x55, count: 300 + data.count + 1000)
        try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) throws -> Void in
            var span = OutputRawSpan(buffer: raw, initializedCount: 0)
            for _ in 0..<300 { span.append(UInt8(0x55)) }
            #expect(try decoder.decompressAll(compressed.span.bytes, into: &span) == compressed.count)
            #expect(span.byteCount == 300 + data.count)
            #expect(throws: BytesError.invalidValue) { _ = try decoder.decompressAll(tooFar.stream.span.bytes, into: &span) }
            #expect(span.byteCount == 300 + data.count)
            _ = span.finalize(for: raw)
        }
        #expect(Array(buffer[300..<(300 + data.count)]) == data)
    }

    @Test("Bytes after the end chunk are left alone")
    func trailingBytes() throws {
        let data = Self.content(0, size: 5000)
        let compressed = lzbitmapCompress(data)
        let (output, consumed) = try lzbitmapDecode(compressed + [1, 2, 3], capacity: data.count).get()
        #expect(output == data)
        #expect(consumed == compressed.count)
        #expect(try LZBitmapDecoder.decompressedSize(of: (compressed + [1, 2, 3]).span.bytes) == data.count)
    }

    @Test("Every truncation throws", arguments: [0, 1, 4])
    func truncation(kind: Int) {
        var decoder = LZBitmapDecoder()
        for size in [0, 5, 100, 3000] {
            let data = Self.content(kind, size: size)
            let compressed = lzbitmapCompress(data)
            for cut in 0..<compressed.count {
                let prefix = Array(compressed[..<cut])
                if case .success = lzbitmapDecode(prefix, capacity: size, decoder: &decoder) {
                    Issue.record("kind \(kind), size \(size): a prefix of \(cut) bytes decoded")
                }
                // (Compression's buffer API stops once the output is full, so with exactly the room needed it
                // returns all of it for a stream missing its end chunk, or more.)
            }
        }
    }

    /// Random corruptions of real streams: never a crash; Bytes decodes exactly as the reference decoder; what
    /// Compression rejects, Bytes rejects; and what both decode, they decode alike.
    ///
    /// Compression's fast loop (all but a chunk's last few groups) checks less than its careful loop, whose
    /// rules Bytes follows everywhere: it accepts periods under 8 or reaching before the output's start
    /// (copying from the start instead), bitmaps read past their area, and some compressed chunks under the
    /// magic's 0x0D variant. Streams Bytes rejects for those, Compression may decode: 151 of the bulk run's 3,600
    /// trials. Where both decode them differently, the reference's `lax` mode reproduces Compression. 50 trials per
    /// stream here, 400 in LZBitmapDecoderBulkTests.
    @Test("Corrupted streams agree with Compression", arguments: [0, 3, 4])
    func corruption(kind: Int) {
        Self.checkCorruption(kind: kind, trials: 50)
    }

    static func checkCorruption(kind: Int, trials: Int) {
        var rng = SplitMix64(seed: UInt64(kind) + 99)
        var decoder = LZBitmapDecoder()
        for size in [300, 5000, 40000] {
            let data = Self.content(kind, size: size)
            let compressed = lzbitmapCompress(data)
            for trial in 0..<trials {
                var corrupt = compressed
                var changed: [Int] = []
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let index = Int.random(in: 0..<corrupt.count, using: &rng)
                    changed.append(index)
                    switch trial % 3 {
                    case 0: corrupt[index] ^= UInt8(1) << UInt8.random(in: 0...7, using: &rng)
                    case 1: corrupt[index] = UInt8.random(in: 0...255, using: &rng)
                    default: corrupt[index] &+= 1
                    }
                }
                let capacity = size + 70_000
                let ours = try? lzbitmapDecode(corrupt, capacity: capacity, decoder: &decoder).get().output
                let apple = appleLZBitmapDecode(corrupt, capacity: capacity)
                let label = "kind \(kind), size \(size), trial \(trial), changed \(changed): Bytes \(ours?.count ?? -1), Compression \(apple.count)"
                // Bytes is the reference decoder, exactly.
                let same = ours == referenceLZBitmapDecode(corrupt)
                #expect(same, "\(label): the reference disagrees")
                if apple.isEmpty {
                    #expect(ours == nil, "\(label): Compression rejects")
                } else if let ours, apple != ours {
                    let lax = apple == referenceLZBitmapDecode(corrupt, lax: true)
                    #expect(lax, "\(label): both decode, differently, and not as Compression's fast loop's laxness explains")
                }
            }
        }
    }

    // MARK: Format rules, with Compression as the reference

    /// Decodes a crafted stream with Bytes and Compression, expecting both to produce `expected` (nil: reject).
    func check(_ chunk: CraftedChunk, _ expected: [UInt8]?, sourceLocation: SourceLocation = #_sourceLocation) {
        let stream = chunk.stream
        let apple = appleLZBitmapDecode(stream, capacity: 1 << 16)
        #expect(apple == (expected ?? []), "Compression", sourceLocation: sourceLocation)
        let ours = try? lzbitmapDecode(stream, capacity: 1 << 16).get().output
        #expect(ours == expected, "Bytes", sourceLocation: sourceLocation)
    }

    /// The padding's 160 bytes.
    static let padding = [UInt8](repeating: 0, count: 20).indices.flatMap { _ in Array("abcdefgh".utf8) }

    @Test("Periods under 8 copy a byte at a time")
    func shortPeriods() {
        for period in 1...9 {
            var chunk = CraftedChunk()
            chunk.literalGroup(Array("IJKLMNOP".utf8))
            chunk.group(0x00, periodBytes: 1, period: period)
            var expected = Self.padding + Array("IJKLMNOP".utf8)
            for _ in 0..<8 { expected.append(expected[expected.count - period]) }
            check(chunk, expected)
        }
        var mixed = CraftedChunk()
        mixed.literalGroup(Array("IJKLMNOP".utf8))
        mixed.group(0xF0, periodBytes: 1, period: 3, literals: Array("wxyz".utf8))
        check(mixed, Self.padding + Array("IJKLMNOPNOPNwxyz".utf8))
    }

    @Test("A period must be 1 through the bytes written, unless the group is all literals")
    func periodBounds() {
        var zero = CraftedChunk()
        zero.group(0x00, periodBytes: 1, period: 0)
        check(zero, nil)
        var all = CraftedChunk()
        all.group(0x00, periodBytes: 2, period: 160)
        check(all, Self.padding + Array("abcdefgh".utf8))
        var tooFar = CraftedChunk()
        tooFar.group(0x00, periodBytes: 2, period: 161)
        check(tooFar, nil)
        // Lane 1 would reach the first byte, but the group's check is on the bytes before it.
        var perLane = CraftedChunk()
        perLane.group(0x01, periodBytes: 2, period: 161, literals: [0x49])
        check(perLane, nil)
        // All literals: no period is needed, not even a valid one, and a later group may set one.
        var literalsOnly = CraftedChunk()
        literalsOnly.group(0xFF, periodBytes: 1, period: 0, literals: Array("IJKLMNOP".utf8))
        literalsOnly.group(0x00, periodBytes: 1, period: 8)
        check(literalsOnly, Self.padding + Array("IJKLMNOPIJKLMNOP".utf8))
        var farLiterals = CraftedChunk()
        farLiterals.group(0xFF, periodBytes: 2, period: 5000, literals: Array("IJKLMNOP".utf8))
        farLiterals.group(0x7F, literals: Array("QRSTUVW".utf8))
        check(farLiterals, nil)
        // The first group of a stream can't copy.
        var first = CraftedChunk(padded: false)
        first.nibbles = [3, 4, 3, 15, 15, 0]
        first.literals = Array("abcdefgh".utf8)
        first.groups = 21
        check(first, nil)
    }

    @Test("The last group: bits past the end are ignored, but the period check is the whole group's")
    func partialGroups() {
        func partial(_ bitmap: UInt8, periodBytes: Int = 0, period: Int = 0, _ literals: String) -> CraftedChunk {
            var chunk = CraftedChunk()
            chunk.group(bitmap, periodBytes: periodBytes, period: period, literals: Array(literals.utf8))
            chunk.size = chunk.groups * 8 - 3
            return chunk
        }
        check(partial(0x1F, "IJKLM"), Self.padding + Array("IJKLM".utf8))
        check(partial(0x3F, "IJKLM"), Self.padding + Array("IJKLM".utf8))
        check(partial(0x3F, "IJKLMN"), nil) // A literal left over.
        check(partial(0x80, ""), Self.padding + Array("abcde".utf8))
        check(partial(0x07, periodBytes: 1, period: 3, "IJK"), Self.padding + Array("IJKIJ".utf8))
        check(partial(0x07, periodBytes: 2, period: 5000, "IJK"), nil)
        check(partial(0x07, periodBytes: 1, period: 0, "IJK"), nil)
    }

    @Test("Repetitions: counted from 4, and cut off at the chunk's end without reading their fields")
    func repetitions() {
        var three = CraftedChunk()
        three.nibbles += [3, 3, 3]
        three.groups += 3
        check(three, Self.padding + [UInt8](Self.padding.prefix(24)))
        // A count with a 15 in it: 4 + 15 + 2 = 21 groups.
        var long = CraftedChunk()
        long.literalGroup(Array("IJKLMNOP".utf8))
        long.nibbles += [3, 15, 15, 2]
        long.groups += 21
        check(long, Self.padding + (0..<22).flatMap { _ in Array("IJKLMNOP".utf8) })
        // Past the end: the padding's 19 asks for more groups than a smaller chunk has.
        var past = CraftedChunk()
        past.size = 100
        check(past, Array(Self.padding.prefix(100)))
        // Bitmap-area groups past the end read nothing: 2 of 4 given.
        for given in 2...4 {
            var chunk = CraftedChunk()
            chunk.nibbles += [1, 15, 0]
            for _ in 0..<given {
                chunk.bitmaps.append(0)
                chunk.periods.append(16)
            }
            chunk.groups += 2
            check(chunk, given == 2 ? Self.padding + [UInt8](Self.padding.prefix(16)) : nil)
        }
        // With 8 bytes or fewer left, a 15 isn't a count.
        var last = CraftedChunk()
        last.literalGroup(Array("IJKLMNOP".utf8))
        last.nibbles += [15, 0]
        check(last, Self.padding + Array("IJKLMNOP".utf8))
        // A 15 as a group's nibble.
        var fifteen = CraftedChunk(padded: false)
        fifteen.nibbles = [15]
        fifteen.size = 160
        check(fifteen, nil)
    }

    @Test("Areas: literals and periods used up exactly, bitmaps and nibbles may be left over")
    func areas() {
        var literal = CraftedChunk()
        literal.literals.append(0x51)
        check(literal, nil)
        var period = CraftedChunk()
        period.periods.append(9)
        check(period, nil)
        var bitmap = CraftedChunk()
        bitmap.bitmaps.append(0)
        check(bitmap, Self.padding)
        var nibbles = CraftedChunk()
        nibbles.nibbles += [3, 0]
        check(nibbles, Self.padding)
        // Running out of each.
        var noLiteral = CraftedChunk()
        noLiteral.literalGroup(Array("IJKLMNOP".utf8))
        noLiteral.literals.removeLast()
        check(noLiteral, nil)
        var noPeriod = CraftedChunk()
        noPeriod.group(0x00, periodBytes: 1, period: 16)
        noPeriod.periods.removeAll()
        check(noPeriod, nil)
        var noBitmap = CraftedChunk()
        noBitmap.group(0x00)
        noBitmap.bitmaps.removeAll()
        check(noBitmap, nil)
        var noNibble = CraftedChunk()
        noNibble.groups += 1
        check(noNibble, nil)
        // The nibble area holds at most 2,048 bytes.
        for extra in [0, 1] {
            var chunk = CraftedChunk(padded: false)
            chunk.literalGroup(Array("IJKLMNOP".utf8))
            chunk.nibbles += [3, 15] + [UInt8](repeating: 15, count: 4092) + [0] + [UInt8](repeating: 0, count: extra * 2)
            chunk.size = 4000
            check(chunk, extra == 0 ? (0..<500).flatMap { _ in Array("IJKLMNOP".utf8) } : nil)
        }
    }

    @Test("Table bitmaps: any period byte count of 3 is rejected; the last 2 bytes are ignored")
    func trailer() {
        var unused = CraftedChunk()
        unused.trailer[14] = 0xF0 // Entry 11's period bits.
        check(unused, nil)
        var ignored = CraftedChunk()
        ignored.trailer[15] = 0xAA
        ignored.trailer[16] = 0x55
        check(ignored, Self.padding)
        var last = CraftedChunk()
        last.trailer[13] = 0xC0 // Entry 11 (nibble 14): 0xFF.
        last.trailer[14] = 0x3F
        last.nibbles.append(14)
        last.literals += Array("IJKLMNOP".utf8)
        last.groups += 1
        check(last, Self.padding + Array("IJKLMNOP".utf8))
    }

    @Test("Chunk headers: stored, compressed, the end, and the limits")
    func headers() {
        let magic: [UInt8] = [0x5A, 0x42, 0x4D, 0x09]
        let end: [UInt8] = [6, 0, 0, 0, 0, 0]
        func decode(_ stream: [UInt8]) -> [UInt8]? {
            let apple = appleLZBitmapDecode(stream, capacity: 1 << 16)
            let ours = try? lzbitmapDecode(stream, capacity: 1 << 16).get().output
            #expect(ours == (apple.isEmpty ? nil : apple))
            return ours
        }
        #expect(decode(magic + [11, 0, 0, 5, 0, 0] + Array("hello".utf8) + end) == Array("hello".utf8))
        // An empty stream (Compression's buffer API can't say "0 bytes": 0 means failure).
        #expect((try? lzbitmapDecode(magic + end, capacity: 0).get().output) == [])
        #expect(decode(magic + [11, 0, 0, 5, 0, 0] + Array("hello".utf8)) == nil) // No end chunk.
        #expect(decode([0x5A, 0x42, 0x4D, 0x0A] + [11, 0, 0, 5, 0, 0] + Array("hello".utf8) + end) == nil)
        // The magic's last byte: 0x08 reads as 0x09; 0x0C and 0x0D allow stored chunks (and compressed ones of
        // some other format: Compression rejects its own under them).
        let text = Self.content(0, size: 5000)
        var compressed = lzbitmapCompress(text)
        for variant: UInt8 in [0x08, 0x0C, 0x0D, 0x0B, 0x19, 0x89] {
            compressed[3] = variant
            #expect(decode(compressed) == (variant == 0x08 ? text : nil))
            #expect(decode([0x5A, 0x42, 0x4D, variant] + [11, 0, 0, 5, 0, 0] + Array("hello".utf8) + end)
                == ([0x08, 0x0C, 0x0D].contains(variant) ? Array("hello".utf8) : nil))
        }
        #expect(decode(magic + [7, 0, 0, 0, 0, 0, 0]) == nil) // An end chunk of 7 bytes.
        // A compressed chunk can't be longer than its stored form.
        var long = CraftedChunk()
        long.size = 32
        long.nibbles = [4, 3, 3, 3]
        long.groups = 4
        #expect(decode(long.stream) == nil)
        long.size = 39 // 42 bytes, under 39 + 6.
        long.nibbles = [4, 3, 3, 3, 3]
        long.groups = 5
        #expect(decode(long.stream) == Array(Self.padding.prefix(39)))
        // 32 KiB at most.
        let big = [UInt8](repeating: 0x71, count: 0x8001)
        #expect(decode(magic + [0x07, 0x80, 0, 0x01, 0x80, 0] + big + end) == nil)
        #expect(throws: BytesError.invalidValue) {
            _ = try LZBitmapDecoder.decompressedSize(of: (magic + [0x07, 0x80, 0, 0x01, 0x80, 0] + big + end).span.bytes)
        }
        #expect(throws: BytesError.insufficientData) { _ = try LZBitmapDecoder.decompressedSize(of: magic.span.bytes) }
    }
}

/// 3,600 corruption trials and 7 MB through one decoder.
@Suite(.bulk) struct LZBitmapDecoderBulkTests {
    @Test(arguments: [0, 3, 4])
    func corruption(kind: Int) { LZBitmapDecoderTests.checkCorruption(kind: kind, trials: 400) }

    @Test("Several megabytes, the window reaching across chunks")
    func large() {
        LZBitmapDecoderTests.checkLarge(
            largeSample() + LZBitmapDecoderTests.content(4, size: 3 << 20) + LZBitmapDecoderTests.content(3, size: (1 << 20) + 13)
        )
    }
}
