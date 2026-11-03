/// The lexical phase: scans borrowed UTF-8 bytes into ``RawComponents`` without allocating.
///
/// Grammar (extended or basic form; the time and offset may independently use either):
///
///     date     = YYYY-MM-DD | YYYYMMDD | YYYY-DDD | YYYYDDD | YYYY-Www-D | YYYYWwwD
///     time     = hh:mm[:ss] | hhmm[ss]   with an optional [.,]fraction after the last field
///     offset   = Z | ±hh[[:]mm]
///     input    = date [ (T|t|space) time [offset] ]
///
/// The lexer is `~Escapable`, so it can't outlive the bytes it reads, and `~Copyable`, because it's a
/// one-shot cursor: ``lex()`` consumes it. It reads a `RawSpan` so that every input (`Span<UInt8>`,
/// `UTF8Span`, `Data.bytes`, `RawSpan`) reaches it without conversion.
struct Lexer: ~Copyable, ~Escapable {
    private let bytes: RawSpan
    private var position = 0

    @_lifetime(copy bytes)
    init(_ bytes: RawSpan) {
        self.bytes = bytes
    }

    @_lifetime(copy bytes)
    init(_ bytes: Span<UInt8>) {
        self.bytes = bytes.bytes
    }

    /// - Parameter allowingFastPath: Tests turn this off to check the fast path against the general one.
    @inline(__always)
    consuming func lex(allowingFastPath: Bool = true) throws(ISO8601ParseError) -> RawComponents {
        var raw = RawComponents()
        if allowingFastPath, lexExtendedDateTime(into: &raw) {
            // Fast path took `YYYY-MM-DDThh:mm:ss`; only a fraction and offset can follow.
            if peek() == UInt8(ascii: ".") || peek() == UInt8(ascii: ",") {
                position &+= 1
                raw.nanosecond = try fraction()
            }
        } else {
            try lexDate(into: &raw)
            if isAtEnd { return raw }

            switch peek() {
            case UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: " "): position &+= 1
            default: throw failure()
            }
            try lexTime(into: &raw)
        }
        try lexOffset(into: &raw)
        guard isAtEnd else { throw failure() }
        return raw
    }

    // MARK: Fast path

    /// Matches the overwhelmingly common RFC 3339 prefix `YYYY-MM-DDThh:mm:ss` with three 8-byte
    /// loads and SWAR checks instead of nineteen byte comparisons. Returns `false` without moving the
    /// cursor if the input has any other shape, leaving it (and its error reporting) to the general path.
    @_lifetime(self: copy self)
    @inline(__always)
    private mutating func lexExtendedDateTime(into raw: inout RawComponents) -> Bool {
        guard bytes.byteCount >= 19 else { return false }
        // Little-endian, so byte 0 of the text is the low byte of each word. XORing with a template
        // that has '0' at digit positions and the exact punctuation elsewhere leaves digit values
        // (0...9) at digit positions and zero at punctuation, for valid input.
        let date = bytes.load(fromByteOffset: 0, as: UInt64.self, .littleEndian) ^ 0x2D30_302D_3030_3030 // YYYY-MM-
        let day = bytes.load(fromByteOffset: 8, as: UInt16.self, .littleEndian) ^ 0x3030 // DD
        let time = bytes.load(fromByteOffset: 11, as: UInt64.self, .littleEndian) ^ 0x3030_3A30_303A_3030 // hh:mm:ss
        let separator = peek(10)

        // Adding 0x76 keeps a digit value (0...9) below 0x80 and pushes 10...0x7F to or above it;
        // adding 0x7F does the same for punctuation, where only 0 is valid. OR-ing in the original
        // catches bytes already at or above 0x80. A carry out of a byte only comes from a byte that
        // already fails, so it can't mask a failure.
        let dateBias: UInt64 = 0x7F76_767F_7676_7676, timeBias: UInt64 = 0x7676_7F76_767F_7676
        let invalid = ((date &+ dateBias) | date | (time &+ timeBias) | time
            | UInt64((day &+ 0x7676) | day)) & 0x8080_8080_8080_8080
        guard invalid == 0,
              separator | 0x20 == UInt8(ascii: "t") || separator == UInt8(ascii: " ") // T, t, or space
        else { return false }

        // Each pair is at most 99, so the narrowing conversions can't lose anything.
        raw.year = Int32(truncatingIfNeeded: Self.pair(date, at: 0) &* 100 &+ Self.pair(date, at: 2))
        raw.month = UInt8(truncatingIfNeeded: Self.pair(date, at: 5))
        raw.day = UInt16(truncatingIfNeeded: Self.pair(UInt64(day), at: 0))
        raw.hour = UInt8(truncatingIfNeeded: Self.pair(time, at: 0))
        raw.minute = UInt8(truncatingIfNeeded: Self.pair(time, at: 3))
        raw.second = UInt8(truncatingIfNeeded: Self.pair(time, at: 6))
        position = 19
        return true
    }

    /// The two-digit number at byte `offset` of a word of digit values (tens digit first).
    @inline(__always)
    private static func pair(_ digits: UInt64, at offset: Int) -> UInt32 {
        let tens = UInt32(truncatingIfNeeded: digits >> (offset &* 8)) & 0xFF
        let ones = UInt32(truncatingIfNeeded: digits >> (offset &* 8 &+ 8)) & 0xFF
        return tens &* 10 &+ ones
    }

    // MARK: Productions

    @_lifetime(self: copy self)
    private mutating func lexDate(into raw: inout RawComponents) throws(ISO8601ParseError) {
        raw.year = Int32(truncatingIfNeeded: try digits(4))
        switch peek() {
        case UInt8(ascii: "-"):
            position &+= 1
            if peek() == UInt8(ascii: "W") {
                position &+= 1
                raw.form = .week
                raw.month = UInt8(truncatingIfNeeded: try digits(2))
                try expect(UInt8(ascii: "-"))
                raw.day = UInt16(truncatingIfNeeded: try digits(1))
            } else if isDigit(at: 2) {
                raw.form = .ordinal
                raw.day = UInt16(truncatingIfNeeded: try digits(3))
            } else {
                raw.month = UInt8(truncatingIfNeeded: try digits(2))
                try expect(UInt8(ascii: "-"))
                raw.day = UInt16(truncatingIfNeeded: try digits(2))
            }
        case UInt8(ascii: "W"):
            position &+= 1
            raw.form = .week
            raw.month = UInt8(truncatingIfNeeded: try digits(2))
            raw.day = UInt16(truncatingIfNeeded: try digits(1))
        default:
            // Basic form: 8 digits is a calendar date, 7 an ordinal date.
            if isDigit(at: 3) {
                raw.month = UInt8(truncatingIfNeeded: try digits(2))
                raw.day = UInt16(truncatingIfNeeded: try digits(2))
            } else {
                raw.form = .ordinal
                raw.day = UInt16(truncatingIfNeeded: try digits(3))
            }
        }
    }

    @_lifetime(self: copy self)
    private mutating func lexTime(into raw: inout RawComponents) throws(ISO8601ParseError) {
        raw.hour = UInt8(truncatingIfNeeded: try digits(2))
        if peek() == UInt8(ascii: ":") {
            position &+= 1
            raw.minute = UInt8(truncatingIfNeeded: try digits(2))
            if peek() == UInt8(ascii: ":") {
                position &+= 1
                raw.second = UInt8(truncatingIfNeeded: try digits(2))
            }
        } else {
            raw.minute = UInt8(truncatingIfNeeded: try digits(2))
            if isDigit(at: 0) {
                raw.second = UInt8(truncatingIfNeeded: try digits(2))
            }
        }

        let separator = peek()
        guard separator == UInt8(ascii: ".") || separator == UInt8(ascii: ",") else { return }
        position &+= 1
        raw.nanosecond = try fraction()
    }

    @_lifetime(self: copy self)
    @inline(__always)
    private mutating func lexOffset(into raw: inout RawComponents) throws(ISO8601ParseError) {
        switch peek() {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            position &+= 1
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            raw.offsetIsNegative = peek() == UInt8(ascii: "-")
            position &+= 1
            raw.offsetHour = UInt8(truncatingIfNeeded: try digits(2))
            if peek() == UInt8(ascii: ":") {
                position &+= 1
                raw.offsetMinute = UInt8(truncatingIfNeeded: try digits(2))
            } else if isDigit(at: 0) {
                raw.offsetMinute = UInt8(truncatingIfNeeded: try digits(2))
            }
        default:
            return // No designator; `lex()` rejects anything left over.
        }
    }

    // MARK: Terminals

    /// Reads at least one fractional digit, keeping the first nine as nanoseconds.
    @_lifetime(self: copy self)
    private mutating func fraction() throws(ISO8601ParseError) -> UInt32 {
        guard isDigit(at: 0) else { throw failure() }
        var value: UInt32 = 0
        var kept = 0
        while true {
            let digit = peek() &- UInt8(ascii: "0")
            guard digit < 10 else { break }
            if kept < 9 {
                value = value &* 10 &+ UInt32(digit)
                kept &+= 1
            }
            position &+= 1
        }
        return value &* Self.nanosecondScale(forDigits: kept)
    }

    /// Reads exactly `count` (1...4) ASCII digits as a decimal number.
    @_lifetime(self: copy self)
    @inline(__always)
    private mutating func digits(_ count: Int) throws(ISO8601ParseError) -> Int {
        var value = 0
        for offset in 0..<count {
            let digit = peek(offset) &- UInt8(ascii: "0")
            guard digit < 10 else {
                position &+= offset
                throw failure()
            }
            value = value &* 10 &+ Int(digit)
        }
        position &+= count
        return value
    }

    @_lifetime(self: copy self)
    private mutating func expect(_ byte: UInt8) throws(ISO8601ParseError) {
        guard peek() == byte else { throw failure() }
        position &+= 1
    }

    // MARK: Cursor

    private var isAtEnd: Bool { position >= bytes.byteCount }

    /// The byte `offset` past the cursor, or NUL past the end. NUL never matches the grammar, so
    /// callers needn't bounds-check separately; ``failure()`` tells the two apart afterwards.
    @inline(__always)
    private func peek(_ offset: Int = 0) -> UInt8 {
        let index = position &+ offset
        // Safety: `index` is non-negative (position and offset both are) and checked against count.
        return index < bytes.byteCount ? unsafe bytes.unsafeLoad(fromByteOffset: index, as: UInt8.self) : 0
    }

    @inline(__always)
    private func isDigit(at offset: Int) -> Bool {
        peek(offset) &- UInt8(ascii: "0") < 10
    }

    /// The error for whatever is at the cursor. Kept out of line: it's only reached on failure.
    @inline(never)
    private func failure() -> ISO8601ParseError {
        isAtEnd ? .unexpectedEnd(offset: position) : .unexpectedByte(peek(), offset: position)
    }

    /// 10^(9 - digits), for scaling a fraction of `digits` digits to nanoseconds.
    @inline(__always)
    private static func nanosecondScale(forDigits digits: Int) -> UInt32 {
        switch digits {
        case 1: 100_000_000
        case 2: 10_000_000
        case 3: 1_000_000
        case 4: 100_000
        case 5: 10_000
        case 6: 1_000
        case 7: 100
        case 8: 10
        default: 1
        }
    }
}
