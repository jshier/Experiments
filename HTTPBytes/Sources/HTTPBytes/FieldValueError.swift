public import Bytes

/// Why a field value didn't parse as its field's grammar: the value parsers' error (dates, media types, ranges, entity
/// tags, lists, and the rest). Payload-free, as every error here: which field it was is the caller's to know.
@frozen
public enum HTTPFieldValueError: Error, Sendable, Hashable {
    /// Not an HTTP-date in any of its three formats (RFC 9110 §5.6.7), or not a real date and time.
    case invalidDate
    /// A token was expected (RFC 9110 §5.6.2).
    case invalidToken
    /// A quoted string isn't closed, or holds a byte it can't (RFC 9110 §5.6.4).
    case invalidQuotedString
    /// A parameter isn't `name=value` with a token name (RFC 9110 §5.6.6), or a name repeats where it can't.
    case invalidParameter
    /// A weight isn't `0` to `1` with at most three decimals (RFC 9110 §12.4.2).
    case invalidWeight
    /// A list's elements or separators don't follow the field's grammar (RFC 9110 §5.6.1).
    case invalidList
    /// A number is malformed or too large.
    case invalidNumber
    /// A media type isn't `type/subtype` followed by parameters (RFC 9110 §8.3.1).
    case invalidMediaType
    /// A range set or content range doesn't follow RFC 9110 §14.1–14.4.
    case invalidRange
    /// An entity tag isn't `[W/]"opaque"` (RFC 9110 §8.8.3).
    case invalidEntityTag
    /// A host isn't a reg-name, IPv4 address, or bracketed IPv6 address with an optional port (RFC 3986 §3.2.2).
    case invalidHost
    /// A cache directive or its argument doesn't follow RFC 9111 §5.2.
    case invalidDirective
    /// More elements than the parser's limit (ranges, list members).
    case tooManyElements
    /// A `%` not followed by two hexadecimal digits, or an extended value (RFC 8187) that isn't
    /// `charset'language'value` with a known charset.
    case invalidPercentEncoding
    /// Credentials or a challenge aren't `scheme [token68 / auth-params]` (RFC 9110 §11).
    case invalidCredentials
    /// A cookie's name, value, or attribute has a byte RFC 6265 doesn't allow there.
    case invalidCookie
    /// The writer given for decoded or written text ran out of room.
    case outputTooSmall
}

extension FieldGrammar {
    /// Writes `bytes`, a writer's lack of room as ``HTTPFieldValueError/outputTooSmall``.
    @inlinable @inline(__always)
    static func write(_ bytes: RawSpan, to writer: inout AlignedBytesWriter) throws(HTTPFieldValueError) {
        do throws(BytesError) { try writer.write(bytes) } catch { throw .outputTooSmall }
    }

    /// Writes `byte`, a writer's lack of room as ``HTTPFieldValueError/outputTooSmall``.
    @inlinable @inline(__always)
    static func write(_ byte: UInt8, to writer: inout AlignedBytesWriter) throws(HTTPFieldValueError) {
        do throws(BytesError) { try writer.write(byte) } catch { throw .outputTooSmall }
    }
}
