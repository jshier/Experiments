public import HTTPBytes

/// What the head parsers accept and how much.
@frozen
public struct HTTP1ParserOptions: Sendable, Hashable {
    /// The most bytes a head may have, start line through the empty line (431 beyond it; 414 while in the target).
    public var maximumHeadByteCount: Int
    /// The most bytes a request target may have (414).
    public var maximumTargetByteCount: Int
    /// The most fields a head may have (431).
    public var maximumFieldCount: Int
    /// Whether a line may end in a bare LF (RFC 9112 §2.2 allows a recipient to; off by default, since parsers that
    /// disagree about line ends can be made to disagree about where a message ends).
    public var allowsBareLineFeed: Bool
    /// Whether empty lines before a start line are skipped (RFC 9112 §2.2: a server should ignore at least one before a
    /// request line; a client, those a server sends after a previous response).
    public var skipsLeadingEmptyLines: Bool
    /// Whether a request target's characters and form are checked (`HTTPRequestTarget.validate`; RFC 9112 §3.2: a server
    /// SHOULD respond 400 to an invalid one), beyond the parser's own rule (no controls, spaces, DEL, or bytes above
    /// 0x7F). Off by default: browsers send targets RFC 3986 doesn't allow (brackets in queries, `filter[0]=…`, were
    /// in 52 of 401 real requests in HTTPBytes' corpus; `|`, `^`, `{`, and bare `%` in 8 of 3,533 from the top 1,000
    /// sites), and the check costs 2–68% more cycles a head (HTTPBytes/RESULTS.md).
    public var validatesTargets: Bool

    @inlinable
    public init(
        maximumHeadByteCount: Int = 64 * 1024, maximumTargetByteCount: Int = 8 * 1024, maximumFieldCount: Int = 256,
        allowsBareLineFeed: Bool = false, skipsLeadingEmptyLines: Bool = true, validatesTargets: Bool = false
    ) {
        self.validatesTargets = validatesTargets
        self.maximumHeadByteCount = maximumHeadByteCount
        self.maximumTargetByteCount = maximumTargetByteCount
        self.maximumFieldCount = maximumFieldCount
        self.allowsBareLineFeed = allowsBareLineFeed
        self.skipsLeadingEmptyLines = skipsLeadingEmptyLines
    }
}

/// A request line, as parsed: views of the bytes.
@frozen
public struct HTTP1RequestLine: ~Escapable {
    /// The method's bytes: a token (case-sensitive).
    public let method: RawSpan
    /// The request target's bytes: no controls, spaces, or DEL (its form is checked by `HTTPRequestTarget`).
    public let target: RawSpan
    /// The version: 1.0 or 1.1.
    public let version: HTTPVersion

    @inlinable @inline(__always)
    @_lifetime(copy method, copy target)
    init(method: RawSpan, target: RawSpan, version: HTTPVersion) {
        self.method = method
        self.target = target
        self.version = version
    }

    /// The method as a value, `nil` if it's longer than 16 bytes.
    @inlinable
    public var knownMethod: HTTPMethod? { HTTPMethod(method) }
}

/// What ``HTTP1RequestParser/next(in:)`` found.
public enum HTTP1RequestEvent: ~Escapable {
    /// The request line: method, target, and version.
    case requestLine(HTTP1RequestLine)
    /// A field.
    case field(HTTPFieldView)
    /// The empty line: the head is `headByteCount` bytes long; a body (if any) follows.
    case end(headByteCount: Int)
    /// The bytes end before the next line does: call again with them and what follows.
    case needsMore
}

/// An incremental, streaming request head parser (RFC 9112 §2–5): each call to ``next(in:)`` returns the next part of
/// the head (the request line, then each field, then its end) as views of the bytes, so a server can act on the
/// method, the target, or a field as soon as it arrives, and stop reading when it has what it needs.
///
/// ```swift
/// var parser = HTTP1RequestParser()
/// loop: while true {
///     switch try parser.next(in: received) {
///     case .requestLine(let line): if line.knownMethod == .connect { … }
///     case .field(let field): if field.knownName == .host { … }
///     case .end(let headByteCount): body = received.extracting(droppingFirst: headByteCount); break loop
///     case .needsMore: received = await more(); continue  // the same bytes, with more after them
///     }
/// }
/// ```
///
/// Each call passes the head's bytes from its first byte: the same bytes as before, possibly with more after them.
/// The parser keeps offsets, not bytes, and resumes at the line it stopped in. It allocates nothing.
///
/// Strict by default (RFC 9112's requirements, and its "should"s that matter for request smuggling): a single space
/// between the request line's parts; CR LF line ends (``HTTP1ParserOptions/allowsBareLineFeed``); no whitespace before
/// a field's colon; no obsolete line folding; field values without controls other than tab.
@frozen
public struct HTTP1RequestParser: Sendable {
    /// The limits and leniencies.
    public var options: HTTP1ParserOptions
    @usableFromInline var scanner = HeadScanner()
    /// The offset of the next line to parse.
    @usableFromInline var position = 0
    /// Fields returned so far.
    @usableFromInline var fieldCount = 0
    /// Whether the request line has been returned.
    @usableFromInline var startLineDone = false
    /// The head's length, once its end has been returned.
    @usableFromInline var headByteCount = 0

    /// A parser for one request head.
    @inlinable
    public init(options: HTTP1ParserOptions = HTTP1ParserOptions()) {
        self.options = options
    }

    /// Starts over, for the next request (whose head the next call's bytes start with).
    @inlinable
    public mutating func reset() {
        self = Self(options: options)
    }

    /// The next part of the head in `bytes`.
    ///
    /// - Parameter bytes: The head's bytes from its first byte (or empty lines before it), as received so far.
    /// - Returns: The next part, or ``HTTP1RequestEvent/needsMore``. After ``HTTP1RequestEvent/end(headByteCount:)``,
    ///   every call returns it again until ``reset()``.
    /// - Throws: ``HTTP1Error`` for a malformed or too-large head.
    ///
    /// Inlined (guaranteed) into the caller's loop: out of line, each event went through memory and the scanner's state
    /// lived there for the whole parse (on the request corpus, 0.96 → 0.80 cycles a byte with the scanner's mask
    /// building also kept from holding it in memory; HTTPBytes/RESULTS.md).
    @inlinable @inline(always)
    @_lifetime(copy bytes)
    public mutating func next(in bytes: RawSpan) throws(HTTP1Error) -> HTTP1RequestEvent {
        if headByteCount > 0 { return .end(headByteCount: headByteCount) }
        let event: HTTP1RequestEvent
        if startLineDone {
            switch try scanner.fieldLine(bytes, at: position, allowsBareLineFeed: options.allowsBareLineFeed,
                                         limit: options.maximumHeadByteCount) {
            case let .field(nameEnd, valueStart, valueEnd, next):
                guard fieldCount < options.maximumFieldCount else { throw .tooManyFields }
                guard next <= options.maximumHeadByteCount else { throw .headTooLarge }
                event = .field(HTTPFieldView(name: bytes.slice(position, nameEnd), value: bytes.slice(valueStart, valueEnd)))
                fieldCount &+= 1
                position = next
            case let .end(next):
                guard next <= options.maximumHeadByteCount else { throw .headTooLarge }
                headByteCount = next
                event = .end(headByteCount: next)
            case .needsMore:
                guard bytes.byteCount < options.maximumHeadByteCount else { throw .headTooLarge }
                event = .needsMore
            }
        } else {
            event = try requestLine(bytes)
        }
        return event
    }


    /// The request line. The usual one (`GET` or another common method, a target, `HTTP/1.1` and CR LF) takes word
    /// compares and one block-mask scan for the target's end; anything else takes `exactRequestLine`, with the same
    /// results and errors. Inlined (guaranteed) with `next(in:)`: a `mutating` call left out of line kept the whole
    /// parser in memory for the caller's loop. The exact path takes and returns values.
    @inlinable @inline(always)
    @_lifetime(copy bytes)
    mutating func requestLine(_ bytes: RawSpan) throws(HTTP1Error) -> HTTP1RequestEvent {
        let count = bytes.byteCount
        let start = position
        // The method by its first four bytes: `GET `, `PUT `, or `POST`/`HEAD` and a space. (Leading empty lines start
        // with CR or LF, so these exclude them.) Not for a line the bytes ended in before: its target would be scanned from
        // its start again on every call.
        if start &+ 16 <= count, scanner.partialLine != start {
            let word = bytes.word(start, as: UInt32.self)
            var methodEnd = -1
            if word == 0x2054_4547 || word == 0x2054_5550 {
                methodEnd = start &+ 3
            } else if word == 0x5453_4F50 || word == 0x4441_4548, bytes.byte(start &+ 4) == .space {
                methodEnd = start &+ 4
            }
            if methodEnd > 0 {
                let targetStart = methodEnd &+ 1
                let (targetEnd, block, stops) = targetScan(bytes, from: targetStart)
                let versionStart = targetEnd &+ 1
                // A target, a space, `HTTP/1.1` or `HTTP/1.0`, CR LF, all within the limits.
                if UInt(bitPattern: targetEnd &- targetStart &- 1) < UInt(bitPattern: options.maximumTargetByteCount),
                   versionStart &+ 10 <= count, bytes.byte(targetEnd) == .space,
                   bytes.word(versionStart &+ 8, as: UInt16.self) == .crlf,
                   case let version = bytes.word(versionStart, as: UInt64.self),
                   version == 0x312E_312F_5054_5448 || version == 0x302E_312F_5054_5448,
                   versionStart &+ 10 <= options.maximumHeadByteCount {
                    // The method is one of four, known from its word.
                    let method: HTTPMethod = methodEnd == start &+ 3 ? (word == 0x2054_4547 ? .get : .put)
                        : (word == 0x5453_4F50 ? .post : .head)
                    if options.validatesTargets { try validateTarget(bytes.slice(targetStart, targetEnd), method: method) }
                    position = versionStart &+ 10
                    startLineDone = true
                    scanner.seed(block: block, stops: stops, count: count)
                    return .requestLine(HTTP1RequestLine(
                        method: bytes.slice(start, methodEnd), target: bytes.slice(targetStart, targetEnd),
                        version: version == 0x312E_312F_5054_5448 ? .http1_1 : .http1_0))
                }
            }
        }
        let resumes = scanner.partialLine == start
        switch try exactRequestLine(bytes, at: start, checked: resumes ? scanner.checked : start, mark: resumes ? scanner.mark : 0,
                                    options: options) {
        case let .line(methodStart, methodEnd, targetEnd, version, next):
            position = next
            startLineDone = true
            return .requestLine(HTTP1RequestLine(method: bytes.slice(methodStart, methodEnd),
                                                 target: bytes.slice(methodEnd &+ 1, targetEnd), version: version))
        case let .needsMore(lineStart, checked, mark):
            position = lineStart
            scanner.remember(line: lineStart, checked: checked, mark: mark)
            return .needsMore
        }
    }
}

/// A request line's parts, as offsets, or where it starts (after any empty lines) when it isn't all there, with where
/// its scans stopped (`checked`, and the method's end as `mark` once found) for the next call to resume.
@frozen @usableFromInline
enum RequestLineParts {
    case line(methodStart: Int, methodEnd: Int, targetEnd: Int, version: HTTPVersion, next: Int)
    case needsMore(lineStart: Int, checked: Int, mark: Int)
}

/// The request line at `start`, decided exactly: empty lines before it, any method, every error. Out of line, taking
/// and returning values.
///
/// The head limit is checked against offsets from the bytes' start, empty lines included (they're part of what the
/// caller must keep), and bytes past it aren't looked at (`headPrefix`): `bytes` may hold much more than this head
/// (pipelined requests, a body). A line resumed (`checked` past `start`) continues its method's scan, or with the
/// method's end at `mark`, its target's, where the last call stopped.
@usableFromInline
func exactRequestLine(_ whole: RawSpan, at start: Int, checked: Int, mark: Int, options: HTTP1ParserOptions)
    throws(HTTP1Error) -> RequestLineParts {
    let parts = try exactRequestLineParts(headPrefix(whole, limit: options.maximumHeadByteCount), at: start, checked: checked,
                                          mark: mark, options: options)
    // A line that isn't all there in the bytes up to the limit would end past it.
    if case .needsMore = parts, whole.byteCount >= options.maximumHeadByteCount { throw .headTooLarge }
    return parts
}

@inline(__always)
func exactRequestLineParts(_ bytes: RawSpan, at start: Int, checked: Int, mark: Int, options: HTTP1ParserOptions)
    throws(HTTP1Error) -> RequestLineParts {
    let count = bytes.byteCount
    var start = start
    if options.skipsLeadingEmptyLines {
        while start < count, case let byte = bytes.byte(start), byte == .cr || byte == .lf {
            if byte == .cr {
                guard start &+ 1 < count else { return .needsMore(lineStart: start, checked: start, mark: 0) }
                guard bytes.byte(start &+ 1) == .lf else { throw .invalidLineEnding }
                start &+= 2
            } else {
                guard options.allowsBareLineFeed else { throw .invalidLineEnding }
                start &+= 1
            }
        }
    }
    var methodEnd = mark
    var scanFrom = Swift.max(start, checked)
    if methodEnd == 0 {
        // The method's bytes before `scanFrom` are token characters (checked by an earlier call).
        methodEnd = tokenEnd(bytes, from: scanFrom)
        guard methodEnd < count else { return .needsMore(lineStart: start, checked: methodEnd, mark: 0) }
        guard methodEnd > start, bytes.byte(methodEnd) == .space else { throw .invalidMethod }
        scanFrom = methodEnd &+ 1
    }
    let targetStart = methodEnd &+ 1
    let targetEnd = scanFrom < count ? targetEnd(bytes, from: scanFrom) : Swift.max(scanFrom, count)
    let targetCount = targetEnd &- targetStart
    guard targetCount <= options.maximumTargetByteCount else { throw .targetTooLong }
    guard targetEnd < count else { return .needsMore(lineStart: start, checked: targetEnd, mark: methodEnd) }
    guard targetCount > 0, bytes.byte(targetEnd) == .space else { throw .invalidTarget }
    if options.validatesTargets {
        try validateTarget(bytes.slice(targetStart, targetEnd), method: HTTPMethod(bytes.slice(start, methodEnd)))
    }
    let versionStart = targetEnd &+ 1
    guard versionStart &+ 8 <= count else { return .needsMore(lineStart: start, checked: targetEnd, mark: methodEnd) }
    let version = try http1Version(bytes, at: versionStart)
    guard let next = try lineEnd(bytes, at: versionStart &+ 8, allowsBareLineFeed: options.allowsBareLineFeed,
                                 otherwise: .invalidVersion) else {
        return .needsMore(lineStart: start, checked: targetEnd, mark: methodEnd)
    }
    guard next <= options.maximumHeadByteCount else { throw .headTooLarge }
    return .line(methodStart: start, methodEnd: methodEnd, targetEnd: targetEnd, version: version, next: next)
}

/// The target's characters and form for `method` (RFC 9112 §3.2, `HTTPRequestTarget.validate`): `invalidTarget` (400)
/// if it isn't a request target. Out of line, with the scans it makes: inlined, they'd grow the parse loop (see
/// `targetEnd`).
@usableFromInline
func validateTarget(_ target: RawSpan, method: HTTPMethod?) throws(HTTP1Error) {
    do throws(HTTPRequestTargetError) {
        _ = try HTTPRequestTarget.validate(target, method: method)
    } catch {
        throw .invalidTarget
    }
}
