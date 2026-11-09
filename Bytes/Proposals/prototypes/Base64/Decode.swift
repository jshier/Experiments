import Base64
import Bytes

/// Prototype: Base64 decoding kernel, 4 characters to 3 bytes, with arithmetic (no table), validity
/// accumulated without an early exit so the loop can vectorize. Returns false if any character isn't in
/// the alphabet.
@inline(always)
func range(_ c: UInt8, _ low: UInt8, _ count: UInt8) -> UInt8 {
    // 0xFF if c - low (wrapping) < count (1...128): its high bit, or that of d + 128 - count, is set otherwise.
    let d = c &- low
    return ((d | (d &+ (128 &- count))) &>> 7) &- 1
}

@inline(always)
func value(_ c: UInt8, _ c62: UInt8, _ c63: UInt8) -> (value: UInt8, valid: UInt8) {
    let upper = range(c, 65, 26), lower = range(c, 97, 26), digit = range(c, 48, 10)
    let is62 = range(c ^ c62, 0, 1), is63 = range(c ^ c63, 0, 1)
    let v = (upper & (c &- 65)) | (lower & (c &- 71)) | (digit & (c &+ 4)) | (is62 & 62) | (is63 & 63)
    return (v, upper | lower | digit | is62 | is63)
}

@inline(never)
func decodeGroups(_ groups: Span<InlineArray<4, UInt8>>, into bytes: inout MutableSpan<InlineArray<3, UInt8>>, c62: UInt8, c63: UInt8) -> Bool {
    precondition(bytes.count == groups.count)
    var invalid: UInt8 = 0
    for index in groups.indices {
        let group = groups[index]
        let (a, va) = value(group[0], c62, c63)
        let (b, vb) = value(group[1], c62, c63)
        let (c, vc) = value(group[2], c62, c63)
        let (d, vd) = value(group[3], c62, c63)
        invalid |= ~(va & vb & vc & vd)
        bytes[index] = [a &<< 2 | b &>> 4, b &<< 4 | c &>> 2, c &<< 6 | d]
    }
    return invalid == 0
}

@inline(never)
func decodePrototype(_ text: [UInt8], into output: inout [UInt8]) -> Bool {
    var reader = BytesReader(text.span)
    let groups = try! reader.read(InlineArray<4, UInt8>.self, count: text.count / 4)
    var span = output.mutableSpan
    var writer = BytesWriter(&span)
    return try! writer.write(InlineArray<3, UInt8>.self, count: groups.count, filling: { bytes in
        decodeGroups(groups, into: &bytes, c62: 43, c63: 47)
    })
}

/// driver SIZE TOTAL_MB decode: decodes SIZE bytes' encoding (a multiple of 3 bytes) repeatedly.
func runDecode(size: Int, totalMB: Int) {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<(size / 3 * 3)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let text = Array(Base64.encodedString(bytes.span.bytes).utf8)
    var output = [UInt8](repeating: 0, count: bytes.count)
    precondition(decodePrototype(text, into: &output) && output == bytes, "decode mismatch")
    var bad = text; bad[bad.count / 2] = UInt8(ascii: "*")
    precondition(!decodePrototype(bad, into: &output), "invalid accepted")
    let calls = max(1, (totalMB << 20) / text.count)
    let clock = ContinuousClock()
    let start = clock.now
    var ok = true
    for _ in 0..<calls { ok = decodePrototype(text, into: &output) && ok }
    let seconds: Double = (clock.now - start) / .seconds(1)
    print("decode \(bytes.count) bytes\tGB/s of text \((Double(text.count * calls) / seconds / 1e8).rounded() / 10)\tok \(ok)")
}
