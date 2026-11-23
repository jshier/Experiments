/// A response status code (RFC 9110 §15): three digits, 100 through 999. Classes 1xx through 5xx are HTTP's; a
/// recipient treats a code it doesn't know as its class's x00 (``kind`` gives the class), and 600–999 as invalid.
@frozen
public struct HTTPStatus: Sendable, Hashable, CustomStringConvertible {
    /// The code, 100 through 999.
    public let code: Int

    /// The status `code`, or `nil` outside 100–999.
    @inlinable
    public init?(code: Int) {
        guard code >= 100, code <= 999 else { return nil }
        self.code = code
    }

    /// A status from a code known to be 100–999 (the parsers' three digits, the constants).
    @inlinable @inline(__always)
    package init(uncheckedCode code: Int) { self.code = code }

    /// The status's class.
    @frozen
    public enum Kind: Sendable, Hashable {
        /// 1xx: the request was received; continuing.
        case informational
        /// 2xx.
        case successful
        /// 3xx.
        case redirection
        /// 4xx.
        case clientError
        /// 5xx.
        case serverError
        /// 600–999: outside HTTP's range (RFC 9110 §15 calls them invalid, and says a client should treat such a
        /// response as a 5xx).
        case invalid
    }

    /// The code's class.
    @inlinable
    public var kind: Kind {
        switch code / 100 {
        case 1: .informational
        case 2: .successful
        case 3: .redirection
        case 4: .clientError
        case 5: .serverError
        default: .invalid
        }
    }

    /// The reason phrase RFC 9110 gives the code (`"Not Found"`), or `""` for codes it doesn't define.
    public var reasonPhrase: StaticString {
        switch code {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 103: "Early Hints"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 203: "Non-Authoritative Information"
        case 204: "No Content"
        case 205: "Reset Content"
        case 206: "Partial Content"
        case 300: "Multiple Choices"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 402: "Payment Required"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 407: "Proxy Authentication Required"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Content Too Large"
        case 414: "URI Too Long"
        case 415: "Unsupported Media Type"
        case 416: "Range Not Satisfiable"
        case 417: "Expectation Failed"
        case 421: "Misdirected Request"
        case 422: "Unprocessable Content"
        case 425: "Too Early"
        case 426: "Upgrade Required"
        case 428: "Precondition Required"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 451: "Unavailable For Legal Reasons"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 505: "HTTP Version Not Supported"
        default: ""
        }
    }

    public var description: String { "\(code) \(reasonPhrase)" }

    /// 100 Continue.
    @inlinable public static var `continue`: Self { Self(uncheckedCode: 100) }
    /// 101 Switching Protocols.
    @inlinable public static var switchingProtocols: Self { Self(uncheckedCode: 101) }
    /// 103 Early Hints.
    @inlinable public static var earlyHints: Self { Self(uncheckedCode: 103) }
    /// 200 OK.
    @inlinable public static var ok: Self { Self(uncheckedCode: 200) }
    /// 201 Created.
    @inlinable public static var created: Self { Self(uncheckedCode: 201) }
    /// 204 No Content.
    @inlinable public static var noContent: Self { Self(uncheckedCode: 204) }
    /// 206 Partial Content.
    @inlinable public static var partialContent: Self { Self(uncheckedCode: 206) }
    /// 301 Moved Permanently.
    @inlinable public static var movedPermanently: Self { Self(uncheckedCode: 301) }
    /// 302 Found.
    @inlinable public static var found: Self { Self(uncheckedCode: 302) }
    /// 304 Not Modified.
    @inlinable public static var notModified: Self { Self(uncheckedCode: 304) }
    /// 400 Bad Request.
    @inlinable public static var badRequest: Self { Self(uncheckedCode: 400) }
    /// 404 Not Found.
    @inlinable public static var notFound: Self { Self(uncheckedCode: 404) }
    /// 414 URI Too Long.
    @inlinable public static var uriTooLong: Self { Self(uncheckedCode: 414) }
    /// 431 Request Header Fields Too Large.
    @inlinable public static var requestHeaderFieldsTooLarge: Self { Self(uncheckedCode: 431) }
    /// 500 Internal Server Error.
    @inlinable public static var internalServerError: Self { Self(uncheckedCode: 500) }
    /// 501 Not Implemented.
    @inlinable public static var notImplemented: Self { Self(uncheckedCode: 501) }
    /// 505 HTTP Version Not Supported.
    @inlinable public static var httpVersionNotSupported: Self { Self(uncheckedCode: 505) }
}

/// An HTTP version: 1.0, 1.1, 2, or 3.
@frozen
public struct HTTPVersion: Sendable, Hashable, CustomStringConvertible {
    /// The major version.
    public let major: UInt8
    /// The minor version (0 for HTTP/2 and HTTP/3).
    public let minor: UInt8

    @inlinable
    public init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    public var description: String { major >= 2 ? "HTTP/\(major)" : "HTTP/\(major).\(minor)" }

    /// HTTP/1.0.
    @inlinable public static var http1_0: Self { Self(major: 1, minor: 0) }
    /// HTTP/1.1.
    @inlinable public static var http1_1: Self { Self(major: 1, minor: 1) }
    /// HTTP/2.
    @inlinable public static var http2: Self { Self(major: 2, minor: 0) }
    /// HTTP/3.
    @inlinable public static var http3: Self { Self(major: 3, minor: 0) }
}
