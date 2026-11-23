public import Bytes
public import HTTPBytes

/// Why an HTTP/2 field section is malformed (RFC 9113 §8.1.1, §8.2, §8.3): a stream error of type PROTOCOL_ERROR
/// (``HTTPBytes/HTTPFieldSectionError/http2Error(stream:)``). The core's ``HTTPFieldSectionError``, shared with HTTP/3.
public typealias HTTP2FieldError = HTTPFieldSectionError

/// Checks a field section as RFC 9113 §8.2–8.3 says: the core's ``HTTPFieldSectionValidator``, shared with HTTP/3, which
/// checks ``HPACKField``s with the decoder's verdict on their characters.
public typealias HTTP2FieldValidator = HTTPFieldSectionValidator

extension HTTPFieldSectionError {
    /// The stream error to answer with: PROTOCOL_ERROR (RFC 9113 §8.1.1).
    @inlinable
    public func http2Error(stream: HTTP2StreamID) -> HTTP2Error { .stream(stream, .protocolError) }
}

extension HTTPFieldSectionValidator {
    /// Checks a decoded field: its characters only if the decoder didn't (``HPACKField/hasValidCharacters``: it checks a
    /// literal once, and dynamic table entries keep the verdict), then its place.
    @inlinable
    public mutating func check(_ field: borrowing HPACKField) throws(HTTPFieldSectionError) {
        try check(name: field.name, value: field.value, knownName: field.knownName, charactersChecked: field.hasValidCharacters)
    }
}

/// HTTP/2 fields to HTTP/1.1's (RFC 9113 §8.2.3): a `cookie` split into crumbs (one field per cookie, for better
/// compression) must be joined with `; ` before it goes to HTTP/1.1 or a generic context.
public enum HTTP2Cookies {
    /// Copies `fields`' regular fields (not the pseudo-header fields) into `target`, the `cookie` crumbs joined into one
    /// field where the first was; `scratch` holds the joined value while it's built (reused: no allocation once it's
    /// grown). Never-indexed flags are kept (the joined cookie's if any crumb's was).
    @inlinable
    public static func copyJoiningCookies(_ fields: borrowing HTTPFieldStore, into target: inout HTTPFieldStore,
                                          scratch: inout [UInt8]) throws(HTTPFieldError) {
        scratch.removeAll(keepingCapacity: true)
        var crumbs = 0
        var flags: UInt8 = 0
        for index in 0..<fields.count where fields.field(at: index).knownName == .cookie {
            if crumbs > 0 {
                scratch.append(0x3B)
                scratch.append(0x20)
            }
            scratch.append(copying: fields.field(at: index).value)
            flags |= fields.flags(at: index)
            crumbs &+= 1
        }
        var wroteCookie = false
        for index in 0..<fields.count {
            let field = fields.field(at: index)
            if field.knownName?.isPseudoHeader == true { continue }
            if field.knownName == .cookie {
                if wroteCookie { continue }
                wroteCookie = true
                if crumbs > 1 {
                    try target.append(.cookie, value: scratch.span.bytes, flags: flags)
                    continue
                }
            }
            try target.append(field, flags: fields.flags(at: index))
        }
    }
}
