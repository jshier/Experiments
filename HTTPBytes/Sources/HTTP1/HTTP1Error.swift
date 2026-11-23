public import HTTPBytes

/// Why an HTTP/1 message was rejected. Each case says which response a server sends for it (``status``), as RFC 9112
/// and RFC 9110 prescribe; none carries a payload, so throwing one allocates nothing.
@frozen
public enum HTTP1Error: Error, Sendable, Hashable {
    /// The method isn't a token, or no single space follows it.
    case invalidMethod
    /// The request target is empty, has a control character, space, or DEL, or no single space follows it.
    case invalidTarget
    /// The version isn't `HTTP/` followed by a digit, `.`, and a digit.
    case invalidVersion
    /// The version is well formed but not 1.0 or 1.1 (505).
    case unsupportedVersion
    /// The status line's code isn't three digits followed by a space.
    case invalidStatus
    /// A field name is empty or has a character that isn't a token character, or whitespace comes before its colon
    /// (RFC 9112 §5.1: a server must reject it with 400).
    case invalidFieldName
    /// A field value has a control character other than horizontal tab, or DEL.
    case invalidFieldValue
    /// A field line starts with whitespace: obsolete line folding (RFC 9112 §5.2), rejected.
    case obsoleteLineFolding
    /// A carriage return isn't followed by a line feed, or a line ends in a bare line feed when that isn't allowed.
    case invalidLineEnding
    /// The head is larger than the parser's limit (431, or 414 while still in the request target).
    case headTooLarge
    /// The request target is longer than the parser's limit (414).
    case targetTooLong
    /// More fields than the parser's limit (431).
    case tooManyFields
    /// `Content-Length` isn't a decimal number, or its values differ (RFC 9112 §6.3).
    case invalidContentLength
    /// A request has both `Content-Length` and `Transfer-Encoding`, or `Transfer-Encoding` in HTTP/1.0: framing a
    /// recipient can't trust (RFC 9112 §6.1, §6.3; the request-smuggling vector).
    case conflictingFraming
    /// A request's `Transfer-Encoding` doesn't end in `chunked`, or names `chunked` twice (RFC 9112 §6.3).
    case invalidTransferEncoding
    /// A request's `Transfer-Encoding` names a coding other than `chunked` (501).
    case unsupportedTransferCoding
    /// An HTTP/1.1 request without `Host`, or with more than one (RFC 9112 §3.2).
    case invalidHost
    /// A chunk-size line isn't hexadecimal digits, optionally extensions, then CR LF; or the size overflows.
    case invalidChunkSize
    /// A chunk's data isn't followed by CR LF.
    case invalidChunkEnd
    /// Chunk extensions longer than the decoder's limit.
    case chunkExtensionsTooLong

    /// The response status a server sends for the error.
    public var status: HTTPStatus {
        switch self {
        case .unsupportedVersion: .httpVersionNotSupported
        case .targetTooLong: .uriTooLong
        case .headTooLarge, .tooManyFields: .requestHeaderFieldsTooLarge
        case .unsupportedTransferCoding: .notImplemented
        default: .badRequest
        }
    }
}
