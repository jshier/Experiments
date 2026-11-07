import Bytes
import Testing

/// Canonical Huffman codes (RFC 1951, 3.2.2) for `lengths`, and an encoder for messages in them.
struct ReferenceCode {
    let lengths: [UInt8]
    let codes: [Int]

    init(lengths: [UInt8]) {
        self.lengths = lengths
        var counts = [Int](repeating: 0, count: 17)
        for length in lengths where length > 0 { counts[Int(length)] += 1 }
        var next = [Int](repeating: 0, count: 17)
        var code = 0
        for length in 1...16 {
            code = (code + counts[length - 1]) << 1
            next[length] = code
        }
        var codes = [Int](repeating: 0, count: lengths.count)
        for symbol in lengths.indices where lengths[symbol] > 0 {
            codes[symbol] = next[Int(lengths[symbol])]
            next[Int(lengths[symbol])] += 1
        }
        self.codes = codes
    }

    /// `message`'s codes, each most significant bit first, packed into bytes in `order`, plus padding.
    func encode(_ message: [Int], order: BitOrder) -> [UInt8] {
        var bits: [Bool] = []
        for symbol in message {
            let length = Int(lengths[symbol])
            for index in stride(from: length - 1, through: 0, by: -1) { bits.append(codes[symbol] >> index & 1 == 1) }
        }
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8 + 8)
        for (index, bit) in bits.enumerated() where bit {
            let shift = order == .leastSignificantFirst ? index % 8 : 7 - index % 8
            bytes[index / 8] |= 1 << shift
        }
        return bytes
    }

    /// Random complete code lengths: `used` of `symbolCount` symbols, none longer than `maximumLength`.
    static func random(symbolCount: Int, used: Int, maximumLength: Int, using rng: inout some RandomNumberGenerator) -> [UInt8] {
        var leaves = [0] // Split random leaves of a code tree until there are enough.
        while leaves.count < used {
            let candidates = leaves.indices.filter { leaves[$0] < maximumLength }
            let leaf = candidates.randomElement(using: &rng)!
            leaves[leaf] += 1
            leaves.append(leaves[leaf])
        }
        var lengths = [UInt8](repeating: 0, count: symbolCount)
        for (symbol, length) in zip(Array(0..<symbolCount).shuffled(using: &rng), leaves) { lengths[symbol] = UInt8(length) }
        return lengths
    }
}

@Suite struct HuffmanTableTests {
    struct Shape: Sendable, CustomTestStringConvertible {
        let symbolCount, used, maximumLength, rootBits: Int
        var testDescription: String { "\(used)/\(symbolCount) symbols, ≤\(maximumLength) bits, root \(rootBits)" }
    }

    static let shapes = [
        Shape(symbolCount: 288, used: 288, maximumLength: 15, rootBits: 9),   // DEFLATE literal/length
        Shape(symbolCount: 30, used: 30, maximumLength: 15, rootBits: 6),     // DEFLATE distance
        Shape(symbolCount: 19, used: 19, maximumLength: 7, rootBits: 7),      // DEFLATE code length
        Shape(symbolCount: 256, used: 162, maximumLength: 16, rootBits: 9),   // JPEG AC
        Shape(symbolCount: 704, used: 600, maximumLength: 15, rootBits: 4),   // Brotli-sized, deep subtables
        Shape(symbolCount: 2, used: 2, maximumLength: 1, rootBits: 1),
    ]

    /// Random messages in random complete codes decode to themselves, in both bit orders.
    @Test(arguments: shapes)
    func decodesRandomCodes(shape: Shape) throws {
        var rng = SystemRandomNumberGenerator()
        for order in [BitOrder.leastSignificantFirst, .mostSignificantFirst] {
            var table = HuffmanTable(symbolCount: shape.symbolCount, maximumCodeLength: shape.maximumLength, rootBits: shape.rootBits)
            for _ in 0..<20 {
                let lengths = ReferenceCode.random(
                    symbolCount: shape.symbolCount, used: shape.used, maximumLength: shape.maximumLength, using: &rng
                )
                try table.build(codeLengths: lengths.span, bitOrder: order)
                let symbols = lengths.indices.filter { lengths[$0] > 0 }
                let message = (0..<500).map { _ in symbols.randomElement(using: &rng)! }
                let data = ReferenceCode(lengths: lengths).encode(message, order: order)
                var reader = Bytes(data.span, bitOrder: order)
                let decoded = try reader.withBitBuffer { (buffer) throws(BytesError) in
                    var decoded: [Int] = []
                    for _ in message.indices {
                        buffer.refill()
                        decoded.append(try table.decode(&buffer))
                    }
                    return decoded
                }
                #expect(decoded == message, "\(order)")
            }
        }
    }

    /// Codes all longer than the root: every root entry links to a subtable.
    @Test(arguments: [BitOrder.leastSignificantFirst, .mostSignificantFirst])
    func codesLongerThanTheRoot(order: BitOrder) throws {
        let lengths = [UInt8](repeating: 11, count: 2048)
        var table = HuffmanTable(symbolCount: 2048, maximumCodeLength: 11, rootBits: 8)
        try table.build(codeLengths: lengths.span, bitOrder: order)
        let message = [0, 2047, 1024, 7, 1500]
        let data = ReferenceCode(lengths: lengths).encode(message, order: order)
        var buffer = BitBuffer(Bytes(data.span, bitOrder: order))
        for symbol in message {
            buffer.refill()
            #expect(try table.decode(&buffer) == symbol)
        }
    }

    @Test func rejectsInvalidCodes() {
        var table = HuffmanTable(symbolCount: 4, maximumCodeLength: 7)
        let invalid: [[UInt8]] = [
            [1, 1, 1],    // Over-subscribed.
            [1, 2],       // Incomplete, and not a single code.
            [1, 2, 3, 8], // Longer than the table's maximum.
            [2, 2, 2, 2, 0], // More symbols than the table holds.
        ]
        for lengths in invalid {
            #expect(throws: BytesError.invalidValue, "\(lengths)") {
                try table.build(codeLengths: lengths.span, bitOrder: .leastSignificantFirst)
            }
        }
    }

    /// A single 1-bit code and an empty code are accepted, decoding only what they define.
    @Test(arguments: [BitOrder.leastSignificantFirst, .mostSignificantFirst])
    func incompleteCodes(order: BitOrder) throws {
        var table = HuffmanTable(symbolCount: 3, maximumCodeLength: 7)
        try table.build(codeLengths: [0, 1, 0].span, bitOrder: order)
        let zero: [UInt8] = [0x00], one: [UInt8] = [0xFF]
        var buffer = BitBuffer(Bytes(zero.span, bitOrder: order))
        buffer.refill()
        #expect(try table.decode(&buffer) == 1)
        buffer = BitBuffer(Bytes(one.span, bitOrder: order))
        buffer.refill()
        #expect(throws: BytesError.invalidValue) { try table.decode(&buffer) }

        try table.build(codeLengths: [0, 0, 0].span, bitOrder: order)
        buffer = BitBuffer(Bytes(zero.span, bitOrder: order))
        buffer.refill()
        #expect(throws: BytesError.invalidValue) { try table.decode(&buffer) }

        var entries = [UInt16](repeating: 0, count: 1 << 7)
        var span = entries.mutableSpan
        #expect(throws: BytesError.invalidValue) {
            try HuffmanTable.build(
                codeLengths: [0, 1, 0].span, bitOrder: order, rootBits: 7, allowingIncomplete: false,
                into: &span, invalid: 0, symbol: { symbol, _ in UInt16(symbol) }, subtable: { _, _ in 0 }
            )
        }
    }

    /// The generic builder with a format's own entries: here, a DEFLATE-style length code that carries its
    /// base, so decoding a length is one lookup.
    @Test func buildsCustomEntries() throws {
        struct Entry: BitwiseCopyable, Equatable {
            var value: UInt16 = 0
            var codeLength: UInt8 = 0
            var isLink = false
        }
        let bases: [UInt16] = [3, 4, 5, 6, 7, 8, 9, 10]
        let lengths: [UInt8] = [2, 2, 3, 3, 3, 4, 5, 5]
        var entries = [Entry](repeating: Entry(), count: 16)
        var span = entries.mutableSpan
        let used = try HuffmanTable.build(
            codeLengths: lengths.span, bitOrder: .leastSignificantFirst, rootBits: 3, into: &span, invalid: Entry(),
            symbol: { symbol, length in Entry(value: bases[symbol], codeLength: UInt8(length)) },
            subtable: { offset, bits in Entry(value: UInt16(offset), codeLength: UInt8(bits), isLink: true) }
        )
        _ = consume span
        #expect(used <= entries.count)

        let message = [7, 0, 5, 2, 6, 1]
        let data = ReferenceCode(lengths: lengths).encode(message, order: .leastSignificantFirst)
        var buffer = BitBuffer(Bytes(data.span, bitOrder: .leastSignificantFirst))
        for symbol in message {
            buffer.refill()
            var entry = entries[Int(buffer.bits & 0b111)]
            if entry.isLink {
                entry = entries[Int(entry.value) + Int(buffer.bits >> 3) & (1 << entry.codeLength - 1)]
            }
            buffer.consume(bitCount: Int(entry.codeLength))
            #expect(entry.value == bases[symbol])
        }
    }
}

@Suite struct BitPositionTests {
    @Test func bitPositionRoundTrips() throws {
        let data = [UInt8](repeating: 0xA5, count: 4)
        var reader = Bytes(data.span)
        try reader.skip(bitCount: 13)
        let position = reader.bitPosition
        #expect(position == 13)
        var other = Bytes(data.span)
        try other.seek(toBitPosition: position)
        let (byte, bit) = (other.byteOffset, other.bitOffset)
        #expect(byte == 1 && bit == 5)
        try other.seek(toBitPosition: 32)
        let atEnd = other.isAtEnd
        #expect(atEnd)
        do { try other.seek(toBitPosition: 33); Issue.record("expected a throw") } catch { #expect(error == .insufficientData) }
        do { try other.seek(toBitPosition: -1); Issue.record("expected a throw") } catch { #expect(error == .invalidValue) }
        let buffer = BitBuffer(reader)
        let bufferPosition = buffer.bitPosition
        #expect(bufferPosition == 13)
    }
}
