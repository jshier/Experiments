import Bytes
public import HTTPBytes

/// A status line, as parsed.
@frozen
public struct HTTP1StatusLine: ~Escapable {
    /// The version: 1.0 or 1.1.
    public let version: HTTPVersion
    /// The status.
    public let status: HTTPStatus
    /// The reason phrase's bytes (possibly empty; RFC 9112 §4: a client should ignore it).
    public let reasonPhrase: RawSpan

    @inlinable @inline(__always)
    @_lifetime(copy reasonPhrase)
    init(version: HTTPVersion, status: HTTPStatus, reasonPhrase: RawSpan) {
        self.version = version
        self.status = status
        self.reasonPhrase = reasonPhrase
    }
}

/// What ``HTTP1ResponseParser/next(in:)`` found.
public enum HTTP1ResponseEvent: ~Escapable {
    /// The status line.
    case statusLine(HTTP1StatusLine)
    /// A field.
    case field(HTTPFieldView)
    /// The empty line: the head is `headByteCount` bytes long.
    case end(headByteCount: Int)
    /// The bytes end before the next line does.
    case needsMore
}

/// An incremental, streaming response head parser: ``HTTP1RequestParser``'s counterpart for status lines, with the
/// same field rules, options, and use.
@frozen
public struct HTTP1ResponseParser: Sendable {
    /// The limits and leniencies (``HTTP1ParserOptions/maximumTargetByteCount`` and
    /// ``HTTP1ParserOptions/skipsLeadingEmptyLines`` don't apply).
    public var options: HTTP1ParserOptions
    @usableFromInline var scanner = HeadScanner()
    @usableFromInline var position = 0
    @usableFromInline var fieldCount = 0
    @usableFromInline var startLineDone = false
    @usableFromInline var headByteCount = 0

    /// A parser for one response head.
    @inlinable
    public init(options: HTTP1ParserOptions = HTTP1ParserOptions()) {
        self.options = options
    }

    /// Starts over, for the next response.
    @inlinable
    public mutating func reset() {
        self = Self(options: options)
    }

    /// The next part of the head in `bytes` (the head's bytes from its first, as received so far).
    /// Inlined (guaranteed) into the caller's loop, as ``HTTP1RequestParser/next(in:)`` is: out of line, each event went
    /// through memory and the scanner lived there (−17% cycles on the request corpus inlined).
    @inlinable @inline(always)
    @_lifetime(copy bytes)
    public mutating func next(in bytes: RawSpan) throws(HTTP1Error) -> HTTP1ResponseEvent {
        if headByteCount > 0 { return .end(headByteCount: headByteCount) }
        let event: HTTP1ResponseEvent
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
            event = try statusLine(bytes)
        }
        return event
    }

    /// `HTTP/1.x SP 3DIGIT SP reason CRLF` (RFC 9112 §4). A missing space after the code is accepted (older servers
    /// send `HTTP/1.1 200` with nothing after it), and empty lines before the status line are skipped when
    /// ``HTTP1ParserOptions/skipsLeadingEmptyLines`` (a server's stray CR LF after a previous body; llhttp skips them
    /// too).
    ///
    /// The usual line (`HTTP/1.1` or `HTTP/1.0`, a code, a space, a reason phrase without tabs, CR LF, within the limit)
    /// takes word compares and the walk's scan; anything else takes `exactStatusLine`, out of line, with the same results
    /// and errors. Keeping this inlined part small mattered: limit checks and resumption written here cost the response
    /// corpora 5% in cycles (fewer instructions, a worse loop).
    @inlinable @inline(always)
    @_lifetime(copy bytes)
    mutating func statusLine(_ bytes: RawSpan) throws(HTTP1Error) -> HTTP1ResponseEvent {
        let count = bytes.byteCount
        let start = position
        // Not for a line the bytes ended in before: its reason phrase would be scanned from its start again.
        if start &+ 13 <= count, scanner.partialLine != start,
           case let version = bytes.word(start, as: UInt64.self),
           version == 0x312E_312F_5054_5448 || version == 0x302E_312F_5054_5448 {
            // The space, three digits, and a space: one 32-bit load and a byte.
            let word = bytes.word(start &+ 8, as: UInt32.self)
            let first = (word &>> 8) & 0xFF &- 0x30, second = (word &>> 16) & 0xFF &- 0x30, third = (word &>> 24) &- 0x30
            if word & 0xFF == 0x20, first < 10, second < 10, third < 10, first > 0, bytes.byte(start &+ 12) == .space {
                let reasonStart = start &+ 13
                let stop = scanner.nextStop(bytes, from: reasonStart)
                if stop &+ 1 < count, bytes.word(stop, as: UInt16.self) == .crlf, stop &+ 2 <= options.maximumHeadByteCount {
                    position = stop &+ 2
                    startLineDone = true
                    return .statusLine(HTTP1StatusLine(
                        version: version == 0x312E_312F_5054_5448 ? .http1_1 : .http1_0,
                        status: HTTPStatus(uncheckedCode: Int(first &* 100 &+ second &* 10 &+ third)),
                        reasonPhrase: bytes.slice(reasonStart, stop)
                    ))
                }
            }
        }
        switch try exactStatusLine(bytes, at: start, checked: scanner.partialLine == start ? scanner.checked : 0, options: options) {
        case let .line(version, code, reasonStart, reasonEnd, next):
            position = next
            startLineDone = true
            return .statusLine(HTTP1StatusLine(version: version, status: HTTPStatus(uncheckedCode: code),
                                               reasonPhrase: bytes.slice(reasonStart, reasonEnd)))
        case let .needsMore(lineStart, checked):
            position = lineStart
            scanner.remember(line: lineStart, checked: checked, mark: 0)
            return .needsMore
        }
    }
}

/// A status line's parts, or where it starts (after any empty lines) when it isn't all there, with how far its reason
/// phrase was scanned (`checked`, 0 before it) for the next call to resume.
@frozen @usableFromInline
enum StatusLineParts {
    case line(version: HTTPVersion, code: Int, reasonStart: Int, reasonEnd: Int, next: Int)
    case needsMore(lineStart: Int, checked: Int)
}

/// The status line at `start`, decided exactly: empty lines before it, every error. Out of line, taking and returning
/// values. Bytes past the head limit aren't looked at (`headPrefix`), and a line that isn't all there before it makes
/// the head too large, so the verdict doesn't depend on how the bytes arrived; the limit counts the empty lines (the
/// caller keeps them). A reason phrase scanned before (`checked` past its start) is scanned on from there.
@usableFromInline
func exactStatusLine(_ whole: RawSpan, at start: Int, checked: Int, options: HTTP1ParserOptions) throws(HTTP1Error) -> StatusLineParts {
    let parts = try exactStatusLineParts(headPrefix(whole, limit: options.maximumHeadByteCount), at: start, checked: checked,
                                         options: options)
    if case .needsMore = parts, whole.byteCount >= options.maximumHeadByteCount { throw .headTooLarge }
    return parts
}

@inline(__always)
func exactStatusLineParts(_ bytes: RawSpan, at start: Int, checked: Int, options: HTTP1ParserOptions) throws(HTTP1Error) -> StatusLineParts {
    let count = bytes.byteCount
    var start = start
    if options.skipsLeadingEmptyLines {
        while start < count, case let byte = bytes.byte(start), byte == .cr || byte == .lf {
            if byte == .cr {
                guard start &+ 1 < count else { return .needsMore(lineStart: start, checked: 0) }
                guard bytes.byte(start &+ 1) == .lf else { throw .invalidLineEnding }
                start &+= 2
            } else {
                guard options.allowsBareLineFeed else { throw .invalidLineEnding }
                start &+= 1
            }
        }
    }
    guard count &- start >= 13 else { return .needsMore(lineStart: start, checked: 0) }
    let version = try http1Version(bytes, at: start)
    // The space, three digits, and what follows them: one 32-bit load.
    let word = bytes.word(start &+ 8, as: UInt32.self)
    let first = (word &>> 8) & 0xFF &- 0x30, second = (word &>> 16) & 0xFF &- 0x30, third = (word &>> 24) &- 0x30
    guard word & 0xFF == 0x20, first < 10, second < 10, third < 10, first > 0 else {
        // A version with a second minor digit (`HTTP/1.32`): not a version (RFC 9112 §2.3).
        throw (word & 0xFF) &- 0x30 < 10 ? .invalidVersion : .invalidStatus
    }
    let code = Int(first &* 100 &+ second &* 10 &+ third)
    // A space, or the line's end right after the code (no reason phrase and no space).
    let after = bytes.byte(start &+ 12)
    guard after == .space || after == .cr || after == .lf else { throw .invalidStatus }
    let reasonStart = after == .space ? start &+ 13 : start &+ 12
    // The reason phrase's end: the first field-value stop (tabs are allowed), from where the last call's scan stopped.
    let from = Swift.max(checked, reasonStart)
    guard from < count,
          let offset = bytes.extracting(droppingFirst: from).firstByteOffset(where: HTTPCharacters.fieldValueStop)
    else { return .needsMore(lineStart: start, checked: Swift.max(from, count)) }
    let stop = from &+ offset
    guard let next = try lineEnd(bytes, at: stop, allowsBareLineFeed: options.allowsBareLineFeed, otherwise: .invalidStatus)
    else { return .needsMore(lineStart: start, checked: stop) }
    return .line(version: version, code: code, reasonStart: reasonStart, reasonEnd: stop, next: next)
}
