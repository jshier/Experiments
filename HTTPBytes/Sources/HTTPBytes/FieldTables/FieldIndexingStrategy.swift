/// How an HPACK or QPACK encoder may use the dynamic table for a field: swift-http-types'
/// `HTTPField.DynamicTableIndexingStrategy`. HTTP2 calls it `HPACKIndexingStrategy`, HTTP3 `QPACKIndexingStrategy`.
@frozen
public enum HTTPFieldIndexingStrategy: Sendable, Hashable {
    /// The encoder decides: it indexes a field unless it's large (over 3/4 of the table) or its value is likely to
    /// change every time (`:path`, `content-length`, `date`-like fields: nghttp2's list), and sends credentials
    /// (`authorization`, `proxy-authorization`, and `cookie` values under 20 bytes, which are guessable) never indexed.
    case automatic
    /// Index the field (add it to the dynamic table) whenever it fits.
    case prefer
    /// Don't add the field to the table (a literal without indexing; an entry already there may still be used).
    case avoid
    /// Never index: a never-indexed literal (RFC 7541 §6.2.3, RFC 9204 §4.5.4's N bit), which intermediaries must forward
    /// the same way, for values like credentials that compression could expose. Its name may still come from a table.
    case disable

    /// The automatic strategy's choice for a field: 0 to index (if it fits 3/4 of the table), 1 never-indexed, 2 not
    /// indexed (nghttp2's lists).
    @inlinable @inline(__always)
    package static func automaticPolicy(_ name: HTTPFieldName?, _ valueCount: Int) -> Int {
        guard let name else { return 0 }
        switch name {
        case .authorization, .proxyAuthorization: return 1
        case .cookie: return valueCount < 20 ? 1 : 0
        case .pseudoPath, .age, .contentLength, .eTag, .ifModifiedSince, .ifNoneMatch, .location, .setCookie: return 2
        default: return 0
        }
    }
}
