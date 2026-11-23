/// `Cache-Control`'s directives (RFC 9111 §5.2), request and response ones together: what a cache or server acts on.
///
/// Parsing is lenient where RFC 9111 asks recipients to be: directive names ignore case; arguments may be tokens or
/// quoted strings (`max-age="5"`); delta-seconds past 2³¹ are 2³¹ (§1.2.2); a directive that repeats keeps its first
/// value (§4.2.1); unknown directives, known ones with an argument that isn't valid, and list elements that aren't
/// `name[=argument]` are ignored, never the whole field (a malformed element doesn't lose `no-store`: a cache that threw
/// the field away would store what it mustn't). An unclosed quoted string ends the field there: the directives before it
/// count. Several field lines: ``update(parsing:)`` with each in turn.
@frozen
public struct HTTPCacheControl: Sendable, Hashable {
    /// `max-age`: seconds.
    public var maxAge: Int?
    /// `s-maxage`: seconds, for shared caches.
    public var sharedMaxAge: Int?
    /// `max-stale` (requests): seconds, or `Int.max` without an argument (any staleness).
    public var maxStale: Int?
    /// `min-fresh` (requests): seconds.
    public var minFresh: Int?
    /// `stale-while-revalidate` (RFC 5861): seconds.
    public var staleWhileRevalidate: Int?
    /// `stale-if-error` (RFC 5861): seconds.
    public var staleIfError: Int?
    /// `no-cache` (with or without field names).
    public var noCache = false
    /// `no-cache` named fields (`no-cache="Set-Cookie"`): only those may not be reused without validation.
    public var noCacheHasFields = false
    /// `no-store`.
    public var noStore = false
    /// `no-transform`.
    public var noTransform = false
    /// `private` (with or without field names).
    public var isPrivate = false
    /// `public`.
    public var isPublic = false
    /// `must-revalidate`.
    public var mustRevalidate = false
    /// `proxy-revalidate`.
    public var proxyRevalidate = false
    /// `must-understand`.
    public var mustUnderstand = false
    /// `immutable` (RFC 8246).
    public var isImmutable = false
    /// `only-if-cached` (requests).
    public var onlyIfCached = false

    /// No directives.
    @inlinable
    public init() {}

    /// The directives of a `Cache-Control` value.
    @inlinable
    public init(parsing value: RawSpan) {
        update(parsing: value)
    }

    /// Adds the directives of another `Cache-Control` field line (a directive already seen keeps its value).
    @inlinable
    public mutating func update(parsing value: RawSpan) {
        var elements = HTTPListElements(value)
        while let element = try? elements.next() {
            let nameEnd = FieldGrammar.tokenEnd(element, from: 0)
            guard nameEnd > 0 else { continue }
            let name = element.extracting(0..<nameEnd)
            // The argument: a token or a quoted string's text after `=` (no whitespace around it).
            var argument: RawSpan? = nil
            var quotedEscapes = false
            if nameEnd < element.byteCount {
                guard FieldGrammar.byte(element, nameEnd) == 0x3D, nameEnd &+ 1 < element.byteCount else { continue }
                let start = nameEnd &+ 1
                if FieldGrammar.byte(element, start) == 0x22 {
                    guard let (end, escapes) = try? FieldGrammar.quotedStringEnd(element, from: start), end == element.byteCount else { continue }
                    argument = element.extracting(start &+ 1..<end &- 1)
                    quotedEscapes = escapes
                } else {
                    guard FieldGrammar.tokenEnd(element, from: start) == element.byteCount else { continue }
                    argument = element.extracting(droppingFirst: start)
                }
            }
            apply(name, argument, quotedEscapes)
        }
    }

    /// Delta-seconds (RFC 9111 §1.2.2): digits, at most 2³¹.
    @inlinable
    static func seconds(_ argument: RawSpan?) -> Int? {
        guard let argument, let (value, end) = FieldGrammar.saturatingNumber(argument, from: 0), end == argument.byteCount else { return nil }
        return Swift.min(value, 1 << 31)
    }

    @inlinable
    mutating func apply(_ name: RawSpan, _ argument: RawSpan?, _ escapes: Bool) {
        func named(_ text: StaticString) -> Bool { HTTPToken.equalsIgnoringCase(name, text) }
        switch name.byteCount {
        case 6:
            if named("public") { isPublic = true }
        case 7:
            if named("max-age") { if maxAge == nil, let value = Self.seconds(argument) { maxAge = value } }
            else if named("private") { isPrivate = true }
        case 8:
            if named("no-cache") {
                noCache = true
                if let argument, argument.byteCount > 0 { noCacheHasFields = true }
            } else if named("no-store") { noStore = true }
            else if named("s-maxage") { if sharedMaxAge == nil, let value = Self.seconds(argument) { sharedMaxAge = value } }
        case 9:
            if named("max-stale") { if maxStale == nil { maxStale = argument == nil ? .max : Self.seconds(argument) } }
            else if named("min-fresh") { if minFresh == nil, let value = Self.seconds(argument) { minFresh = value } }
            else if named("immutable") { isImmutable = true }
        case 12:
            if named("no-transform") { noTransform = true }
        case 14:
            if named("only-if-cached") { onlyIfCached = true }
            else if named("stale-if-error") { if staleIfError == nil, let value = Self.seconds(argument) { staleIfError = value } }
        case 15:
            if named("must-revalidate") { mustRevalidate = true }
            else if named("must-understand") { mustUnderstand = true }
        case 16:
            if named("proxy-revalidate") { proxyRevalidate = true }
        case 22:
            if named("stale-while-revalidate") {
                if staleWhileRevalidate == nil, let value = Self.seconds(argument) { staleWhileRevalidate = value }
            }
        default:
            break
        }
    }
}

/// `Age` (RFC 9111 §5.1), `Expires` (§5.3), and `Retry-After` (RFC 9110 §10.2.3).
public enum HTTPCacheFields {
    /// `Age`'s seconds (at most 2³¹), or `nil` if it isn't delta-seconds (a cache then ignores the field).
    @inlinable
    public static func age(_ value: RawSpan) -> Int? {
        HTTPCacheControl.seconds(FieldGrammar.trimmed(value))
    }

    /// `Expires`' date. A value that isn't an HTTP-date (`0` included) means "already expired" (§5.3): the earliest
    /// date there is.
    @inlinable
    public static func expires(_ value: RawSpan) -> HTTPDate {
        (try? HTTPDate(parsing: FieldGrammar.trimmed(value))) ?? HTTPDate(secondsSince1970: .min)
    }
}

/// `Retry-After` (RFC 9110 §10.2.3): a date, or a delay in seconds.
@frozen
public enum HTTPRetryAfter: Sendable, Hashable {
    /// Retry after this date.
    case date(HTTPDate)
    /// Retry after this many seconds.
    case seconds(Int)

    /// Parses an HTTP-date or delay-seconds.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidDate``.
    @inlinable
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        let value = FieldGrammar.trimmed(value)
        if let (seconds, end) = FieldGrammar.saturatingNumber(value, from: 0), end == value.byteCount {
            self = .seconds(seconds)
        } else {
            self = .date(try HTTPDate(parsing: value))
        }
    }

    /// When to retry, relative to `now` (a delay too large for the clock is the latest date there is).
    @inlinable
    public func date(after now: HTTPDate) -> HTTPDate {
        switch self {
        case .date(let date):
            return date
        case .seconds(let seconds):
            let (sum, overflow) = now.secondsSince1970.addingReportingOverflow(Int64(seconds))
            return HTTPDate(secondsSince1970: overflow ? .max : sum)
        }
    }
}
