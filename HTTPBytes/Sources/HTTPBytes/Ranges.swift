public import Bytes

extension FieldGrammar {
    /// The decimal number of the digits from `start` (saturating at `Int.max`), and the offset after them; `nil` if
    /// there's no digit there.
    @inlinable
    static func saturatingNumber(_ bytes: RawSpan, from start: Int) -> (value: Int, end: Int)? {
        var position = start, value = 0
        while position < bytes.byteCount, case let digit = byte(bytes, position) &- 0x30, digit < 10 {
            let (times, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = times.addingReportingOverflow(Int(digit))
            value = overflow1 || overflow2 ? .max : sum
            position &+= 1
        }
        return position > start ? (value, position) : nil
    }
}

/// One range of a `Range` field's byte-range set (RFC 9110 §14.1.2).
@frozen
public enum HTTPByteRange: Sendable, Hashable {
    /// `first-last`: bytes `first` through `last`.
    case closed(first: Int, last: Int)
    /// `first-`: from `first` to the end.
    case from(Int)
    /// `-length`: the last `length` bytes.
    case suffix(Int)

    /// The bytes this range selects of a representation of `length` bytes, or `nil` if none (it's unsatisfiable):
    /// `last` beyond the end is clipped to it.
    @inlinable
    public func resolved(length: Int) -> Range<Int>? {
        switch self {
        case .closed(let first, let last): first < length ? first..<Swift.min(last, length &- 1) &+ 1 : nil
        case .from(let first): first < length ? first..<length : nil
        case .suffix(let count): count > 0 && length > 0 ? Swift.max(0, length &- count)..<length : nil
        }
    }
}

/// What a server does with a `Range` field (RFC 9110 §14.2).
@frozen
public enum HTTPRangeResolution: Sendable, Hashable {
    /// Ignore it and send the whole representation (200): the field is invalid, its unit isn't `bytes`, or its ranges
    /// are more than the caller allows after overlapping ones are merged (§14.2 lets a server ignore such a request).
    case ignore
    /// None of its ranges overlaps the representation: 416, with `Content-Range: bytes */length`.
    case unsatisfiable
    /// This many ranges, sorted and merged, were written to the caller's storage: 206 (one range: `Content-Range`;
    /// more: `multipart/byteranges`).
    case ranges(Int)
}

/// The ranges of a `Range` field, `bytes=` then a byte-range set (RFC 9110 §14.1.2).
///
/// ```swift
/// var storage = [Range<Int>](repeating: 0..<0, count: 8)
/// var span = storage.mutableSpan
/// switch HTTPRangeSet.resolve(rangeField, length: fileSize, into: &span) { … }
/// ```
@frozen
public struct HTTPRangeSet: ~Escapable {
    @usableFromInline var elements: HTTPListElements

    /// The ranges of `value`.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidRange`` if the unit isn't `bytes` (ignoring case) followed by `=`.
    @inlinable
    @_lifetime(copy value)
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        let value = FieldGrammar.trimmed(value)
        guard value.byteCount > 6, HTTPToken.equalsIgnoringCase(value.extracting(0..<6), "bytes="), case let rest = value.extracting(droppingFirst: 6),
              rest.byteCount > 0, !FieldGrammar.isWhitespace(FieldGrammar.byte(rest, 0)) else { throw .invalidRange }
        elements = HTTPListElements(rest)
    }

    /// The next range, or `nil` at the end.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidRange`` for a range that isn't `first-last` (first at most last),
    ///   `first-`, or `-length`.
    @inlinable
    public mutating func next() throws(HTTPFieldValueError) -> HTTPByteRange? {
        guard let element = try elements.next() else { return nil }
        let count = element.byteCount
        if FieldGrammar.byte(element, 0) == 0x2D {
            guard let (length, end) = FieldGrammar.saturatingNumber(element, from: 1), end == count else { throw .invalidRange }
            return .suffix(length)
        }
        guard let (first, dash) = FieldGrammar.saturatingNumber(element, from: 0), dash < count,
              FieldGrammar.byte(element, dash) == 0x2D else { throw .invalidRange }
        if dash &+ 1 == count { return .from(first) }
        guard let (last, end) = FieldGrammar.saturatingNumber(element, from: dash &+ 1), end == count, first <= last else { throw .invalidRange }
        return .closed(first: first, last: last)
    }

    /// The most ranges a set may name before ``resolve(_:length:into:)`` ignores it (RFC 9110 §14.2 lets a server ignore
    /// a set of many small or overlapping ranges: a denial-of-service shape).
    @inlinable
    public static var maximumRangeCount: Int { 256 }

    /// What to do with the `Range` field `value` for a representation of `length` bytes: the union of its satisfiable
    /// ranges, sorted, with overlapping or adjacent ranges merged, written to `ranges` (at most `ranges.count` of them;
    /// more is ``HTTPRangeResolution/ignore``).
    ///
    /// The union is found by sweeping the set rather than by inserting its ranges in order, so the storage only has to
    /// hold the answer: each range written starts at the lowest range not yet covered and grows while any range overlaps
    /// or touches it (the set re-read each time: no copy of it is kept). At most ``maximumRangeCount`` ranges.
    @inlinable
    public static func resolve(_ value: RawSpan, length: Int, into ranges: inout MutableSpan<Range<Int>>) -> HTTPRangeResolution {
        // Syntax, size, and whether anything is satisfiable.
        guard var set = try? HTTPRangeSet(parsing: value) else { return .ignore }
        var total = 0, satisfiable = 0
        do throws(HTTPFieldValueError) {
            while let range = try set.next() {
                total &+= 1
                if range.resolved(length: length) != nil { satisfiable &+= 1 }
            }
        } catch {
            return .ignore
        }
        guard total > 0, total <= maximumRangeCount else { return .ignore }
        guard satisfiable > 0 else { return .unsatisfiable }
        // `cursor`: the end of the last range written; every range of the set lies wholly before it or wholly after it
        // (anything overlapping or touching a written range was merged into it).
        var count = 0
        var cursor = Int.min
        // `try!` below: the first pass read the whole set without an error, and reading it again can't differ.
        while true {
            var start = Int.max, end = Int.min
            var pass = try! HTTPRangeSet(parsing: value)
            while let range = try! pass.next() {
                guard let bytes = range.resolved(length: length), cursor == .min || bytes.lowerBound > cursor else { continue }
                if bytes.lowerBound < start || bytes.lowerBound == start && bytes.upperBound > end {
                    (start, end) = (bytes.lowerBound, bytes.upperBound)
                }
            }
            guard start != .max else { return .ranges(count) }
            var grew = true
            while grew {
                grew = false
                var again = try! HTTPRangeSet(parsing: value)
                while let range = try! again.next() {
                    guard let bytes = range.resolved(length: length), bytes.lowerBound >= start, bytes.lowerBound <= end,
                          bytes.upperBound > end else { continue }
                    end = bytes.upperBound
                    grew = true
                }
            }
            guard count < ranges.count else { return .ignore }
            ranges[count] = start..<end
            count &+= 1
            cursor = end
        }
    }
}

/// A `Content-Range` field (RFC 9110 §14.4): a byte range and the representation's length, either of which may be
/// unknown (`*`).
@frozen
public struct HTTPContentRange: Sendable, Hashable {
    /// The range sent, or `nil` for `*` (a 416's `bytes */length`).
    public var range: ClosedRange<Int>?
    /// The representation's length, or `nil` if unknown (`*`).
    public var completeLength: Int?

    /// A content range.
    @inlinable
    public init(range: ClosedRange<Int>?, completeLength: Int?) {
        self.range = range
        self.completeLength = completeLength
    }

    /// Parses `bytes first-last/length`, `bytes first-last/*`, or `bytes */length`.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidRange``, including for a range past the length.
    @inlinable
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        let value = FieldGrammar.trimmed(value)
        let count = value.byteCount
        guard count > 6, HTTPToken.equalsIgnoringCase(value.extracting(0..<6), "bytes ") else { throw .invalidRange }
        var position = 6
        if FieldGrammar.byte(value, position) == 0x2A {
            range = nil
            position &+= 1
        } else {
            guard let (first, dash) = FieldGrammar.saturatingNumber(value, from: position), dash < count, FieldGrammar.byte(value, dash) == 0x2D,
                  let (last, end) = FieldGrammar.saturatingNumber(value, from: dash &+ 1), first <= last else { throw .invalidRange }
            range = first...last
            position = end
        }
        guard position < count, FieldGrammar.byte(value, position) == 0x2F, position &+ 1 < count else { throw .invalidRange }
        position &+= 1
        if FieldGrammar.byte(value, position) == 0x2A {
            guard range != nil, position &+ 1 == count else { throw .invalidRange }
            completeLength = nil
        } else {
            guard let (length, end) = FieldGrammar.saturatingNumber(value, from: position), end == count else { throw .invalidRange }
            if let range { guard range.upperBound < length else { throw .invalidRange } }
            completeLength = length
        }
    }

    /// Writes the field's value.
    ///
    /// - Precondition: The range's bounds and the length aren't negative.
    @inlinable
    public func write(to writer: inout AlignedBytesWriter) throws(BytesError) {
        precondition((range?.lowerBound ?? 0) >= 0 && (completeLength ?? 0) >= 0, "a content range with negative numbers")
        try writer.write(0x2073_6574_7962 as UInt64, byteCount: 6, allowingOverrun: false)
        if let range {
            try Self.writeNumber(range.lowerBound, to: &writer)
            try writer.write(0x2D as UInt8)
            try Self.writeNumber(range.upperBound, to: &writer)
        } else {
            try writer.write(0x2A as UInt8)
        }
        try writer.write(0x2F as UInt8)
        if let completeLength { try Self.writeNumber(completeLength, to: &writer) } else { try writer.write(0x2A as UInt8) }
    }

    @inlinable
    static func writeNumber(_ value: Int, to writer: inout AlignedBytesWriter) throws(BytesError) {
        var divisor = 1
        while divisor <= value / 10 { divisor &*= 10 }
        repeat {
            try writer.write(UInt8(truncatingIfNeeded: 0x30 &+ value / divisor % 10))
            divisor /= 10
        } while divisor > 0
    }
}
