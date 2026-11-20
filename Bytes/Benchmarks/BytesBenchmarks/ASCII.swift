import Benchmark
import Bytes
import BytesTestSupport

// Text fields in a binary-style parser: fixed-width timestamps and numbers in a 20,000-line log
// ("2026-11-18T13:45:09 200 001532\n", 31 bytes a line), ASCII tags, and a digit scan. Each new API against what
// a careful user writes by hand: a digit at a time with the unsigned-compare check, hex constants for tags, a byte
// loop for the scan.

/// A log of `count` lines of fixed-width fields.
func makeASCIILog(count: Int) -> [UInt8] {
    var state: UInt64 = 7
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
    func digits(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: width - text.count) + text
    }
    var text = ""
    for _ in 0..<count {
        text += digits(2000 + next(100), 4) + "-" + digits(1 + next(12), 2) + "-" + digits(1 + next(28), 2) + "T"
        text += digits(next(24), 2) + ":" + digits(next(60), 2) + ":" + digits(next(60), 2) + " "
        text += digits([200, 304, 404, 500][next(4)], 3) + " " + digits(next(1_000_000), 6) + "\n"
    }
    return Array(text.utf8)
}

/// The fields' sum: each line's numbers through `read(_:asciiDigits:)`, separators through `expect`.
@inline(never)
func parseASCIILog(_ bytes: RawSpan) throws(BytesError) -> Int {
    var reader = AlignedBytesReader(bytes)
    var sum = 0
    while !reader.isAtEnd {
        sum &+= try reader.read(Int.self, asciiDigits: 4)
        try reader.expect(Byte(ascii: "-"))
        sum &+= try reader.read(Int.self, asciiDigits: 2)
        try reader.expect(Byte(ascii: "-"))
        sum &+= try reader.read(Int.self, asciiDigits: 2)
        try reader.expect(Byte(ascii: "T"))
        sum &+= try reader.read(Int.self, asciiDigits: 2)
        try reader.expect(Byte(ascii: ":"))
        sum &+= try reader.read(Int.self, asciiDigits: 2)
        try reader.expect(Byte(ascii: ":"))
        sum &+= try reader.read(Int.self, asciiDigits: 2)
        try reader.expect(Byte(ascii: " "))
        sum &+= try reader.read(Int.self, asciiDigits: 3)
        try reader.expect(Byte(ascii: " "))
        sum &+= try reader.read(Int.self, asciiDigits: 6)
        try reader.expect(Byte(ascii: "\n"))
    }
    return sum
}

/// The same, a digit at a time: what a user writes without the API (already with the cheap digit check).
@inline(never)
func parseASCIILogByDigit(_ bytes: RawSpan) throws(BytesError) -> Int {
    @inline(__always)
    @_lifetime(reader: copy reader)
    func digits(_ reader: inout AlignedBytesReader, _ count: Int) throws(BytesError) -> Int {
        var value = 0
        for _ in 0..<count {
            let digit = try reader.read(UInt8.self) &- 0x30
            guard digit < 10 else { throw .invalidValue }
            value = value &* 10 &+ Int(digit)
        }
        return value
    }
    @inline(__always)
    @_lifetime(reader: copy reader)
    func separator(_ reader: inout AlignedBytesReader, _ byte: UInt8) throws(BytesError) {
        guard try reader.read(UInt8.self) == byte else { throw .mismatch }
    }
    var reader = AlignedBytesReader(bytes)
    var sum = 0
    while !reader.isAtEnd {
        sum &+= try digits(&reader, 4)
        try separator(&reader, 0x2D)
        sum &+= try digits(&reader, 2)
        try separator(&reader, 0x2D)
        sum &+= try digits(&reader, 2)
        try separator(&reader, 0x54)
        sum &+= try digits(&reader, 2)
        try separator(&reader, 0x3A)
        sum &+= try digits(&reader, 2)
        try separator(&reader, 0x3A)
        sum &+= try digits(&reader, 2)
        try separator(&reader, 0x20)
        sum &+= try digits(&reader, 3)
        try separator(&reader, 0x20)
        sum &+= try digits(&reader, 6)
        try separator(&reader, 0x0A)
    }
    return sum
}

/// PNG-style chunks: a 4-byte length, a 4-byte ASCII type, the data, and a 4-byte CRC.
func makeASCIIChunks(count: Int) -> [UInt8] {
    let types: [[UInt8]] = ["IHDR", "PLTE", "IDAT", "tEXt", "IEND", "gAMA"].map { Array($0.utf8) }
    var bytes: [UInt8] = []
    for index in 0..<count {
        let length = index % 7
        bytes += [0, 0, 0, UInt8(length)] + types[index % types.count] + [UInt8](repeating: 0xA5, count: length) + [1, 2, 3, 4]
    }
    return bytes
}

/// Counts chunks by type, comparing with `Byte4(ascii:)`.
@inline(never)
func countASCIIChunks(_ bytes: RawSpan) throws(BytesError) -> Int {
    var reader = BigEndianBytesReader(bytes)
    var count = 0
    while !reader.isAtEnd {
        let length = try reader.read(Int.self, as: Byte4.self)
        switch try reader.read(Byte4.self) {
        case Byte4(ascii: "IHDR"): count &+= 1
        case Byte4(ascii: "IDAT"): count &+= 3
        case Byte4(ascii: "IEND"): count &+= 5
        case Byte4(ascii: "tEXt"): count &+= 7
        default: count &+= 11
        }
        try reader.skip(byteCount: length &+ 4)
    }
    return count
}

/// The same with the tags as hand-written hex, in memory order.
@inline(never)
func countHexChunks(_ bytes: RawSpan) throws(BytesError) -> Int {
    var reader = BigEndianBytesReader(bytes)
    var count = 0
    while !reader.isAtEnd {
        let length = try reader.read(Int.self, as: Byte4.self)
        switch try reader.read(Byte4.self) {
        case 0x49_48_44_52: count &+= 1 // "IHDR"
        case 0x49_44_41_54: count &+= 3 // "IDAT"
        case 0x49_45_4E_44: count &+= 5 // "IEND"
        case 0x74_45_58_74: count &+= 7 // "tEXt"
        default: count &+= 11
        }
        try reader.skip(byteCount: length &+ 4)
    }
    return count
}

/// Counts ASCII digits 16 bytes at a time with `ByteLanes.asciiDigits`.
@inline(never)
func countDigitsByLanes(_ bytes: RawSpan) -> Int {
    var count = 0
    var reader = AlignedBytesReader(bytes)
    reader.forEach(Byte16.self) { group in
        count &+= ByteLanes(group.vector).asciiDigits.bitmask.nonzeroBitCount
    }
    return count
}

/// Counts ASCII digits a byte at a time with `isASCIIDigit`.
@inline(never)
func countDigitsByByte(_ bytes: RawSpan) -> Int {
    var count = 0
    var reader = BytesReader(bytes)
    reader.forEach(Byte.self) { byte in
        if byte.rawValue.isASCIIDigit { count &+= 1 }
    }
    return count
}

func registerASCIIBenchmarks() {
    // Made by the setup of a benchmark that uses them; each setup checks its parser against the hand-written one.
    let log = Lazy { makeASCIILog(count: 20_000) }
    register("ASCII: 20,000 log lines, read(_:asciiDigits:)", log, check: { $1 == (try! parseASCIILogByDigit($0.span.bytes)) }) { log in
        try parseASCIILog(log.span.bytes)
    }
    register("ASCII: 20,000 log lines, a digit at a time", log) { log in
        try parseASCIILogByDigit(log.span.bytes)
    }

    // `Byte4(ascii:)` against hex literals: the two compiled to the same function (LLVM merged them), so the hex
    // literals' row was retired on 2026-11-19; setup still checks they agree.
    let chunks = Lazy { makeASCIIChunks(count: 20_000) }
    register("ASCII: 20,000 chunk types, Byte4(ascii:)", chunks, check: { $1 == (try! countHexChunks($0.span.bytes)) }) { chunks in
        try countASCIIChunks(chunks.span.bytes)
    }

    // The log is 620 KB; its length is a multiple of 16 here, and `forEach(Byte16.self)` would leave a tail
    // otherwise.
    let text = Lazy { Array(log.value.prefix(log.value.count & ~15)) }
    register("ASCII: digits in 620 KB, ByteLanes.asciiDigits", text, check: { $1 == countDigitsByByte($0.span.bytes) }) { text in
        countDigitsByLanes(text.span.bytes)
    }
    register("ASCII: digits in 620 KB, isASCIIDigit per byte", text) { text in
        countDigitsByByte(text.span.bytes)
    }
}
