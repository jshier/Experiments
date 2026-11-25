/// A field as parsed: its name and value as spans of the bytes it was parsed from (HTTP/1) or of a decoder's memory
/// (HPACK, QPACK), and the name's table index when HTTPBytes knows it.
///
/// A view, not a copy: it lives as long as what it borrows (``HTTPFieldStore`` keeps fields past that).
@frozen
public struct HTTPFieldView: ~Escapable {
    /// The name's bytes, as sent (HTTP/1 keeps case; HTTP/2 and HTTP/3 names are lowercase).
    public let name: RawSpan
    /// The value's bytes, without leading or trailing whitespace.
    public let value: RawSpan
    /// The name's table index; 0xFF when it isn't one HTTPBytes knows; 0xFE when it hasn't been looked up (a field from an
    /// HTTP/1 parser: ``knownName`` looks it up when asked).
    @usableFromInline let knownIndex: UInt8

    @inlinable static var notKnown: UInt8 { 0xFF }
    @inlinable static var notLookedUp: UInt8 { 0xFE }

    /// A field of `name` and `value`, whose known name is `knownName` (which the caller has looked up, or knows).
    @inlinable @inline(__always)
    @_lifetime(copy name, copy value)
    public init(name: RawSpan, value: RawSpan, knownName: HTTPFieldName?) {
        self.name = name
        self.value = value
        knownIndex = knownName?.index ?? Self.notKnown
    }

    /// A field of `name` and `value` whose known name is looked up only when ``knownName`` is read: what the HTTP/1
    /// parsers make, so a head's fields cost nothing beyond finding them (as picohttpparser's do) unless their names
    /// are wanted.
    @inlinable @inline(__always)
    @_lifetime(copy name, copy value)
    public init(name: RawSpan, value: RawSpan) {
        self.name = name
        self.value = value
        knownIndex = Self.notLookedUp
    }

    /// The name, if it's one HTTPBytes knows.
    ///
    /// Stored for fields HPACK and QPACK decode (their tables give it); for fields from the HTTP/1 parsers, looked up
    /// from ``name`` on each read (``HTTPFieldName/init(caseInsensitive:)``: a hash, a table load, and a compare, about
    /// 40 instructions, out of line). Read it once per field: `if let known = field.knownName { switch known { … } }`.
    /// Measured on 401 real request heads (HTTPBytes/RESULTS.md): looking every name up while parsing cost about 300
    /// instructions a head, a fifth of the parse, for callers that never asked.
    @inlinable
    public var knownName: HTTPFieldName? {
        if knownIndex < Self.notLookedUp { return HTTPFieldName(uncheckedIndex: knownIndex) }
        if knownIndex == Self.notKnown { return nil }
        return HTTPFieldName(caseInsensitive: name)
    }
}
