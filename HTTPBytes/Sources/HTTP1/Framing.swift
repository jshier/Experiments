public import HTTPBytes

/// How a message's body is delimited (RFC 9112 §6.3).
@frozen
public enum HTTP1BodyLength: Sendable, Hashable {
    /// No body (a request without either field; a response to HEAD; 1xx, 204, 304; a 2xx to CONNECT, after which the
    /// connection is a tunnel).
    case none
    /// `Content-Length` bytes.
    case length(Int)
    /// Chunked transfer coding: read with ``HTTP1ChunkedDecoder``.
    case chunked
    /// Everything until the connection closes (responses only).
    case untilClose
}

/// What a head's fields say about framing and the connection, gathered as the fields arrive: feed it each field
/// (``observe(_:)``), then ask for the body's length once the head ends.
///
/// ```swift
/// var framing = HTTP1Framing()
/// … case .field(let field): try framing.observe(field)
/// … case .end: let body = try framing.requestBody(version: line.version)
/// ```
///
/// Strict where RFC 9112 allows a choice that request smuggling exploits: a request with both `Content-Length` and
/// `Transfer-Encoding`, or `Transfer-Encoding` in HTTP/1.0, is rejected rather than framed by one of them.
@frozen
public struct HTTP1Framing: Sendable {
    /// The `Content-Length`, if given (equal values in several fields or a list are one value).
    public private(set) var contentLength: Int?
    /// Whether any `Transfer-Encoding` field was present.
    public private(set) var hasTransferEncoding = false
    /// Whether the last transfer coding is `chunked`.
    @usableFromInline var endsInChunked = false
    /// Whether `chunked` came before another coding.
    @usableFromInline var chunkedNotLast = false
    /// Whether a coding other than `chunked` was named.
    @usableFromInline var hasOtherCodings = false
    /// Whether a `Transfer-Encoding` field named no coding (`1#transfer-coding`, RFC 9112 §6.1: at least one).
    @usableFromInline var hasEmptyTransferEncoding = false
    /// How many `Host` fields there were.
    public private(set) var hostCount = 0
    /// `Connection: close`.
    public private(set) var requestsClose = false
    /// `Connection: keep-alive` (HTTP/1.0's opt-in).
    public private(set) var requestsKeepAlive = false
    /// `Connection: upgrade` (with an `Upgrade` field: RFC 9110 §7.8).
    public private(set) var requestsUpgrade = false
    /// Whether the head had `Expect: 100-continue`: a server answers 100 (Continue) before reading the body only when
    /// ``expectsContinue(version:)`` says so, which also checks the version.
    public private(set) var hasExpectContinue = false

    @inlinable
    public init() {}

    /// Takes note of `field` if it affects framing or the connection; ignores the rest.
    @inlinable
    public mutating func observe(_ field: HTTPFieldView) throws(HTTP1Error) {
        guard let name = field.knownName else { return }
        switch name {
        case .contentLength: try observeContentLength(field.value)
        case .transferEncoding: observeTransferEncoding(field.value)
        case .host: observeHost()
        case .connection: observeConnection(field.value)
        case .expect: observeExpect(field.value)
        default: break
        }
    }

    @usableFromInline
    mutating func observeHost() { hostCount &+= 1 }

    @usableFromInline
    mutating func observeExpect(_ value: RawSpan) {
        if HTTPToken.equalsIgnoringCase(value, "100-continue") { hasExpectContinue = true }
    }

    @usableFromInline
    mutating func observeContentLength(_ value: RawSpan) throws(HTTP1Error) {
        var failed = false
        var elements = 0
        HTTPList.forEachElement(of: value) { element in
            elements &+= 1
            guard let length = HTTPToken.decimal(element), contentLength == nil || contentLength == length else {
                failed = true
                return
            }
            contentLength = length
        }
        // A field with no number (`Content-Length: ,`) is invalid: ignoring it would let a request carry
        // `Transfer-Encoding` beside a `Content-Length` an intermediary might read differently.
        if failed || elements == 0 { throw .invalidContentLength }
    }

    @usableFromInline
    mutating func observeTransferEncoding(_ value: RawSpan) {
        hasTransferEncoding = true
        var codings = 0
        defer { if codings == 0 { hasEmptyTransferEncoding = true } }
        HTTPList.forEachElement(of: value) { element in
            codings &+= 1
            // A coding's name, before any parameters.
            let name = HTTPToken.prefix(element, upTo: 0x3B)
            if endsInChunked { chunkedNotLast = true }
            if HTTPToken.equalsIgnoringCase(name, "chunked") {
                endsInChunked = true
            } else {
                endsInChunked = false
                hasOtherCodings = true
            }
        }
    }

    @usableFromInline
    mutating func observeConnection(_ value: RawSpan) {
        HTTPList.forEachElement(of: value) { option in
            if HTTPToken.equalsIgnoringCase(option, "close") { requestsClose = true }
            else if HTTPToken.equalsIgnoringCase(option, "keep-alive") { requestsKeepAlive = true }
            else if HTTPToken.equalsIgnoringCase(option, "upgrade") { requestsUpgrade = true }
        }
    }

    /// Whether the client waits for 100 (Continue) before sending the body (RFC 9110 §10.1.1): `Expect: 100-continue`
    /// in an HTTP/1.1 request; a server must ignore it in HTTP/1.0.
    public func expectsContinue(version: HTTPVersion) -> Bool {
        hasExpectContinue && version != .http1_0
    }

    /// A request's body length (RFC 9112 §6.3, items 3–7), or why the request can't be framed.
    ///
    /// - Parameter method: The request's method, when known: a CONNECT request has no content (RFC 9110 §9.3.6), so the
    ///   bytes after its head belong to the tunnel. A CONNECT with a nonzero `Content-Length` or any `Transfer-Encoding` is
    ///   rejected: if the server refused the tunnel and kept the connection, a front end framing by `Content-Length`
    ///   would forward those bytes as a body while this parser read them as the next request.
    public func requestBody(version: HTTPVersion, method: HTTPMethod? = nil) throws(HTTP1Error) -> HTTP1BodyLength {
        if method == .connect {
            guard !hasTransferEncoding, (contentLength ?? 0) == 0 else { throw .conflictingFraming }
            return .none
        }
        if hasTransferEncoding {
            guard version != .http1_0, contentLength == nil else { throw .conflictingFraming }
            guard endsInChunked, !chunkedNotLast, !hasEmptyTransferEncoding else { throw .invalidTransferEncoding }
            guard !hasOtherCodings else { throw .unsupportedTransferCoding }
            return .chunked
        }
        if let contentLength { return contentLength == 0 ? .none : .length(contentLength) }
        return .none
    }

    /// Checks `Host` (RFC 9112 §3.2): exactly one in HTTP/1.1, at most one in HTTP/1.0.
    public func validateHost(version: HTTPVersion) throws(HTTP1Error) {
        guard hostCount == 1 || (hostCount == 0 && version == .http1_0) else { throw .invalidHost }
    }

    /// A response's body length (RFC 9112 §6.3): what the request's method and the status allow, then the fields.
    /// `Transfer-Encoding` wins over `Content-Length` (which a sender mustn't send with it); codings that don't end in
    /// `chunked` mean the body ends when the connection closes.
    public func responseBody(status: HTTPStatus, version: HTTPVersion, requestMethod: HTTPMethod) throws(HTTP1Error) -> HTTP1BodyLength {
        if requestMethod == .head || status.kind == .informational || status == .noContent || status == .notModified {
            return .none
        }
        if requestMethod == .connect, status.kind == .successful { return .none }
        if hasTransferEncoding {
            // A field with no codings: framing a recipient can't interpret (llhttp rejects it too).
            guard !hasEmptyTransferEncoding else { throw .invalidTransferEncoding }
            return version == .http1_1 && endsInChunked && !chunkedNotLast ? .chunked : .untilClose
        }
        if let contentLength { return .length(contentLength) }
        return .untilClose
    }

    /// Whether the connection stays open after this message (RFC 9112 §9.3): HTTP/1.1 unless `close`; HTTP/1.0 only
    /// with `keep-alive`; never after a message whose body ends with the connection, nor after one with both
    /// `Transfer-Encoding` and `Content-Length` (§6.3: framed by the coding, but the connection is closed after it, since
    /// an intermediary may have framed it the other way).
    public func isPersistent(version: HTTPVersion, body: HTTP1BodyLength) -> Bool {
        guard body != .untilClose, !requestsClose, !(hasTransferEncoding && contentLength != nil) else { return false }
        return version == .http1_1 || requestsKeepAlive
    }
}
