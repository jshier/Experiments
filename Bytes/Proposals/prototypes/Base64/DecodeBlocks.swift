import Base64
import Bytes

typealias Table4 = (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)

/// Character → value + 1 (0: not in the alphabet), for characters 0–63 and 64–127.
func decodeTables(c62: UInt8, c63: UInt8) -> (Table4, Table4) {
    var low = InlineArray<64, UInt8>(repeating: 0), high = InlineArray<64, UInt8>(repeating: 0)
    for v in 0..<64 {
        let c: UInt8 = v < 26 ? UInt8(65 + v) : v < 52 ? UInt8(71 + v) : v < 62 ? UInt8(v - 4) : v == 62 ? c62 : c63
        if c < 64 { low[Int(c)] = UInt8(v + 1) } else if c < 128 { high[Int(c) - 64] = UInt8(v + 1) }
    }
    let l = bitCast(low, to: InlineArray<4, SIMD16<UInt8>>.self), h = bitCast(high, to: InlineArray<4, SIMD16<UInt8>>.self)
    return ((l[0], l[1], l[2], l[3]), (h[0], h[1], h[2], h[3]))
}

@inline(never)
func decodeBlocks(_ blocks: Span<InlineArray<64, UInt8>>, into output: inout MutableSpan<InlineArray<48, UInt8>>,
                  low: Table4, high: Table4) -> Bool {
    precondition(output.count == blocks.count)
    var invalid = ByteMatches.none
    let every4th: SIMD16<UInt8> = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60]
    let st3: SIMD16<UInt8> = [0, 16, 32, 1, 17, 33, 2, 18, 34, 3, 19, 35, 4, 20, 36, 5]
    for index in blocks.indices {
        let v = bitCast(blocks[index], to: InlineArray<4, SIMD16<UInt8>>.self)
        let text = (v[0], v[1], v[2], v[3])
        let (a, ia) = decodeLane(text, every4th, low, high)
        let (b, ib) = decodeLane(text, every4th &+ 1, low, high)
        let (c, ic) = decodeLane(text, every4th &+ 2, low, high)
        let (d, id) = decodeLane(text, every4th &+ 3, low, high)
        invalid = invalid | ia | ib | ic | id
        let bytes = (a &<< 2 | b &>> 4, b &<< 4 | c &>> 2, c &<< 6 | d)
        let o0 = ByteLanes(st3).lookup(in: bytes)                                         // as st3
        let out: InlineArray<3, SIMD16<UInt8>> = [
            o0,
            ByteLanes([21, 37, 6, 22, 38, 7, 23, 39, 8, 24, 40, 9, 25, 41, 10, 26]).lookup(in: bytes),
            ByteLanes([42, 11, 27, 43, 12, 28, 44, 13, 29, 45, 14, 30, 46, 15, 31, 47]).lookup(in: bytes),
        ]
        output[index] = bitCast(out, to: InlineArray<48, UInt8>.self)
    }
    return !invalid.any
}

@inline(never)
func decodeBlocksPrototype(_ text: [UInt8], into output: inout [UInt8], tables: (Table4, Table4)) -> Bool {
    var reader = BytesReader(text.span)
    let blocks = try! reader.read(InlineArray<64, UInt8>.self, count: text.count / 64)
    var span = output.mutableSpan
    var writer = BytesWriter(&span)
    return try! writer.write(InlineArray<48, UInt8>.self, count: blocks.count, filling: { bytes in
        decodeBlocks(blocks, into: &bytes, low: tables.0, high: tables.1)
    })
}

func runDecodeBlocks(size: Int, totalMB: Int) {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<(size / 48 * 48)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let text = Array(Base64.encodedString(bytes.span.bytes).utf8)
    var output = [UInt8](repeating: 0, count: bytes.count)
    let tables = decodeTables(c62: 43, c63: 47)
    precondition(decodeBlocksPrototype(text, into: &output, tables: tables) && output == bytes, "decode mismatch")
    for bad in [UInt8(ascii: "*"), 0x80, 0xFF, 0x3D] {
        var wrong = text; wrong[wrong.count / 2 + 1] = bad
        precondition(!decodeBlocksPrototype(wrong, into: &output, tables: tables), "invalid accepted: \(bad)")
    }
    let calls = max(1, (totalMB << 20) / text.count)
    let clock = ContinuousClock()
    let start = clock.now
    var ok = true
    for _ in 0..<calls { ok = decodeBlocksPrototype(text, into: &output, tables: tables) && ok }
    let seconds: Double = (clock.now - start) / .seconds(1)
    print("decode blocks \(bytes.count) bytes\tGB/s of text \((Double(text.count * calls) / seconds / 1e8).rounded() / 10)\tok \(ok)")
}

/// Every 4th character from `indices` (as ld4), mapped to its value, and the lanes that aren't in the alphabet.
@inline(always)
func decodeLane(_ text: Table4, _ indices: SIMD16<UInt8>, _ low: Table4, _ high: Table4) -> (SIMD16<UInt8>, ByteMatches) {
    let c = ByteLanes(indices).lookup(in: text)
    let plusOne = ByteLanes(c).lookup(in: low) | ByteLanes(c &- 64).lookup(in: high)
    return (plusOne &- 1, ByteLanes(plusOne).matching(0))
}
