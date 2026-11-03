/// The lexical phase: scans borrowed UTF-8 bytes into ``RawComponents`` without allocating.
///
/// Grammar (extended or basic form; the time and offset may independently use either):
///
///     complete = YYYY-MM-DD | YYYYMMDD | YYYY-DDD | YYYYDDD | YYYY-Www-D | YYYYWwwD
///     reduced  = YYYY-MM | YYYY | YYY (decade) | YY (century) | YYYY-Www | YYYYWww
///     time     = hh[:mm[:ss]] | hh[mm[ss]]   with an optional [.,]fraction of the last field
///     offset   = Z | ±hh[[:]mm]
///     input    = reduced | complete [ (T|t|space) time [offset] ]
///
/// Years may be expanded with a leading sign (`+001985`, `-0001-01-01`). In extended format the
/// year runs to the `-` (4...9 digits); in basic format, where nothing delimits it, a signed year
/// has six digits (two beyond the usual four, the common agreement), so `+0019` is a century and
/// `+00198` a decade.
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

    /// - Parameter allowingFastPath: Tests turn this off to check the fast paths against the general one.
    @inline(always)
    consuming func lex(allowingFastPath: Bool = true) throws(ISO8601ParseError) -> RawComponents {
        if allowingFastPath {
            var raw = RawComponents()
            if lexExtendedDateTime(into: &raw) { return try finishFastPath(raw) }
            if lexBasicDateTime(into: &raw) { return try finishFastPath(raw) }
        }
        return try lexGeneral()
    }

    /// After a fast path took `YYYY-MM-DDThh:mm:ss` or `YYYYMMDDThhmmss`, only a fraction and an
    /// offset can follow. Inlined into each fast path so `raw` never escapes and stays in registers.
    @_lifetime(self: copy self)
    @inline(always)
    private mutating func finishFastPath(_ raw: consuming RawComponents) throws(ISO8601ParseError) -> RawComponents {
        raw.timePrecision = .second
        if peek() == UInt8(ascii: ".") || peek() == UInt8(ascii: ",") {
            position &+= 1
            (raw.fraction, raw.fractionDigits) = try fraction()
        }
        try lexOffset(into: &raw)
        guard isAtEnd else { throw failure() }
        return raw
    }

    /// Every other form. Kept out of line so the fast path's components don't have to live in memory.
    @inline(never)
    private mutating func lexGeneral() throws(ISO8601ParseError) -> RawComponents {
        var raw = RawComponents()
        try lexDate(into: &raw)
        if isAtEnd { return raw }
        // Only a complete date can carry a time of day.
        guard raw.dateForm.isComplete else { throw failure() }

        switch peek() {
        case UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: " "): position &+= 1
        default: throw failure()
        }
        try lexTime(into: &raw)
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

    /// The basic-format counterpart, `YYYYMMDDThhmmss` (as in iCalendar), with two overlapping
    /// 8-byte loads. Tried only after the extended form fails, so it costs that path nothing.
    @_lifetime(self: copy self)
    @inline(__always)
    private mutating func lexBasicDateTime(into raw: inout RawComponents) -> Bool {
        guard bytes.byteCount >= 15 else { return false }
        let date = bytes.load(fromByteOffset: 0, as: UInt64.self, .littleEndian) ^ 0x3030_3030_3030_3030 // YYYYMMDD
        let time = bytes.load(fromByteOffset: 7, as: UInt64.self, .littleEndian) ^ 0x3030_3030_3030_5430 // DThhmmss
        // Same validation as the extended form; byte 1 of `time` must be exactly 'T'.
        let invalid = ((date &+ 0x7676_7676_7676_7676) | date | (time &+ 0x7676_7676_7676_7F76) | time)
            & 0x8080_8080_8080_8080
        guard invalid == 0 else { return false }

        raw.year = Int32(truncatingIfNeeded: Self.pair(date, at: 0) &* 100 &+ Self.pair(date, at: 2))
        raw.month = UInt8(truncatingIfNeeded: Self.pair(date, at: 4))
        raw.day = UInt16(truncatingIfNeeded: Self.pair(date, at: 6))
        raw.hour = UInt8(truncatingIfNeeded: Self.pair(time, at: 2))
        raw.minute = UInt8(truncatingIfNeeded: Self.pair(time, at: 4))
        raw.second = UInt8(truncatingIfNeeded: Self.pair(time, at: 6))
        position = 15
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
    @inline(__always) // Into `lexGeneral`, which is itself out of line.
    private mutating func lexDate(into raw: inout RawComponents) throws(ISO8601ParseError) {
        let sign = peek()
        let isSigned = sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-")
        let isNegative = sign == UInt8(ascii: "-")
        if isSigned { position &+= 1 }
        let run = digitRun()
        let next = peek(run)

        if next == UInt8(ascii: "-") {
            // Extended format: the year runs to the hyphen. Unsigned years have exactly four digits.
            let maximum = isSigned ? 9 : 4
            guard run <= maximum, run >= 4 else {
                position &+= min(run, maximum) // The first byte that can't belong to the year.
                throw failure()
            }
            raw.year = year(digits: run, negative: isNegative)
            position &+= run &+ 1
            if peek() == UInt8(ascii: "W") {
                position &+= 1
                raw.month = UInt8(truncatingIfNeeded: try digits(2))
                if peek() == UInt8(ascii: "-") {
                    position &+= 1
                    raw.day = UInt16(truncatingIfNeeded: try digits(1))
                    raw.dateForm = .weekDate
                } else {
                    raw.dateForm = .week
                }
            } else if isDigit(at: 2) {
                raw.day = UInt16(truncatingIfNeeded: try digits(3))
                raw.dateForm = .ordinalDate
            } else {
                raw.month = UInt8(truncatingIfNeeded: try digits(2))
                if peek() == UInt8(ascii: "-") {
                    position &+= 1
                    raw.day = UInt16(truncatingIfNeeded: try digits(2))
                    raw.dateForm = .calendarDate
                } else {
                    raw.dateForm = .month
                }
            }
            return
        }

        // Basic format: nothing delimits the fields, so the length of the digit run decides.
        let yearDigits = isSigned ? 6 : 4
        if next == UInt8(ascii: "W") {
            guard run == yearDigits else {
                position &+= min(run, yearDigits)
                throw failure()
            }
            raw.year = year(digits: run, negative: isNegative)
            position &+= run &+ 1
            raw.month = UInt8(truncatingIfNeeded: try digits(2))
            if isDigit(at: 0) {
                raw.day = UInt16(truncatingIfNeeded: try digits(1))
                raw.dateForm = .weekDate
            } else {
                raw.dateForm = .week
            }
            return
        }

        switch run &- yearDigits {
        case 4:
            raw.year = year(digits: yearDigits, negative: isNegative)
            raw.month = UInt8(truncatingIfNeeded: number(at: yearDigits, digits: 2))
            raw.day = UInt16(truncatingIfNeeded: number(at: yearDigits &+ 2, digits: 2))
            raw.dateForm = .calendarDate
        case 3:
            raw.year = year(digits: yearDigits, negative: isNegative)
            raw.day = UInt16(truncatingIfNeeded: number(at: yearDigits, digits: 3))
            raw.dateForm = .ordinalDate
        case 0:
            raw.year = year(digits: run, negative: isNegative)
            raw.dateForm = .year
        case -1:
            raw.year = year(digits: run, negative: isNegative)
            raw.dateForm = .decade
        case -2:
            raw.year = year(digits: run, negative: isNegative)
            raw.dateForm = .century
        default:
            // No date form has this many digits (YYYYMM is deliberately excluded by ISO 8601).
            position &+= min(run, yearDigits &+ 4)
            throw failure()
        }
        position &+= run
    }

    @_lifetime(self: copy self)
    @inline(__always) // Into `lexGeneral`, which is itself out of line.
    private mutating func lexTime(into raw: inout RawComponents) throws(ISO8601ParseError) {
        raw.hour = UInt8(truncatingIfNeeded: try digits(2))
        raw.timePrecision = .hour
        if peek() == UInt8(ascii: ":") {
            position &+= 1
            raw.minute = UInt8(truncatingIfNeeded: try digits(2))
            raw.timePrecision = .minute
            if peek() == UInt8(ascii: ":") {
                position &+= 1
                raw.second = UInt8(truncatingIfNeeded: try digits(2))
                raw.timePrecision = .second
            }
        } else if isDigit(at: 0) {
            raw.minute = UInt8(truncatingIfNeeded: try digits(2))
            raw.timePrecision = .minute
            if isDigit(at: 0) {
                raw.second = UInt8(truncatingIfNeeded: try digits(2))
                raw.timePrecision = .second
            }
        }

        // A fraction belongs to the last field written: `23:20,5` is 23:20:30, `23,5` is 23:30.
        let separator = peek()
        guard separator == UInt8(ascii: ".") || separator == UInt8(ascii: ",") else { return }
        position &+= 1
        (raw.fraction, raw.fractionDigits) = try fraction()
    }

    @_lifetime(self: copy self)
    @inline(__always)
    private mutating func lexOffset(into raw: inout RawComponents) throws(ISO8601ParseError) {
        switch peek() {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            position &+= 1
            raw.offsetForm = .utc
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            raw.offsetIsNegative = peek() == UInt8(ascii: "-")
            position &+= 1
            raw.offsetHour = UInt8(truncatingIfNeeded: try digits(2))
            raw.offsetForm = .hours
            if peek() == UInt8(ascii: ":") {
                position &+= 1
                raw.offsetMinute = UInt8(truncatingIfNeeded: try digits(2))
                raw.offsetForm = .hoursMinutes
            } else if isDigit(at: 0) {
                raw.offsetMinute = UInt8(truncatingIfNeeded: try digits(2))
                raw.offsetForm = .hoursMinutes
            }
        default:
            return // No designator; `lex()` rejects anything left over.
        }
    }

    // MARK: Terminals

    /// Reads at least one fractional digit, returning the first nine as an integer and how many
    /// digits were kept. Further digits are consumed and truncated.
    @_lifetime(self: copy self)
    private mutating func fraction() throws(ISO8601ParseError) -> (value: UInt32, digits: UInt8) {
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
        return (value, UInt8(truncatingIfNeeded: kept))
    }

    /// The number of consecutive ASCII digits at the cursor (at most 18), without consuming them.
    private func digitRun() -> Int {
        var count = 0
        while count < 18, isDigit(at: count) { count &+= 1 }
        return count
    }

    /// The decimal value of `digits` (at most 9) digits starting `offset` bytes past the cursor,
    /// which the caller has already checked are digits.
    private func number(at offset: Int, digits: Int) -> Int {
        var value = 0
        for index in offset..<(offset &+ digits) {
            value = value &* 10 &+ Int(peek(index) &- UInt8(ascii: "0"))
        }
        return value
    }

    /// The year (or decade, or century) in the first `digits` (at most 9) digits at the cursor.
    private func year(digits: Int, negative: Bool) -> Int32 {
        let magnitude = Int32(truncatingIfNeeded: number(at: 0, digits: digits))
        return negative ? -magnitude : magnitude
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
}
