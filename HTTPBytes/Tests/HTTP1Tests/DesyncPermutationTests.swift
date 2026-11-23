import Foundation
import HTTP1
import HTTPBytes
import Testing

/// PortSwigger's HTTP Request Smuggler (http-request-smuggler at 3ecb1af, Apache-2.0; James Kettle): every way its
/// `DesyncBox.applyDesync` disguises a `Transfer-Encoding: chunked` or `Content-Length` field, reimplemented here over
/// three base requests (chunked only, `Content-Length` only, and the classic probe with both), each permuted request
/// read by HTTPBytes as a server would.
///
/// The rule: each permutation is rejected, or framed as RFC 9112 frames it, so no strict reader can disagree about where
/// the request ends. `expected` gives each technique's verdict on the chunked base and on the `Content-Length` base, with
/// the rule; the verdict on the probe with both follows from the chunked one (a request still chunked has both fields:
/// rejected, §6.1; one whose `Transfer-Encoding` became another field is framed by its `Content-Length`).
///
/// Bytes as Burp makes them: Java strings become one byte per character (ISO 8859-1, as Burp's helpers convert them),
/// so `\u0085` is the byte 0x85. `addOrReplaceHeader` (from Burp's utilities, not in the repository) replaces a field
/// with that exact name or, failing that, adds it after the request line.
@Suite struct DesyncPermutationTests {
    /// The techniques `DesyncBox` registers for HTTP/1 and for both protocols, then the `Content-Length` ones. The HTTP/2
    /// ones are included too: their `^~` (a line break in an HTTP/2 value) is two literal bytes in HTTP/1.
    static let shared = [
        "vanilla", "underjoin1", "spacejoin1", "space1", "nameprefix1", "nameprefix2", "valueprefix1", "vertwrap", "connection",
        "spjunk", "backslash", "spaceFF", "unispace", "commaCow", "cowComma", "contentEnc", "quoted", "aposed", "dualchunk",
        "lazygrep", "0dsuffix", "tabsuffix", "revdualchunk", "nested", "encode", "accentTE", "accentCH", "removed", "get",
        "options", "head", "range", "qencode", "qencodeutf", "nel", "nbsp", "shy", "shy2",
    ]
    static let http1 = [
        "nospace1", "linewrapped1", "doublewrapped", "gareth1", "badsetupCR", "badsetupLF", "multiCase", "tabwrap", "UPPERCASE",
        "0dwrap", "0dspam", "badwrap", "bodysplit", "h1case", "http1.0",
    ]
    static let http2 = ["http2hide", "h2colon", "h2auth", "h2path", "http2case", "h2scheme", "h2name", "h2method", "h2space", "h2prefix", "h2CL"]
    static let contentLength = [
        "CL-plus", "CL-minus", "CL-pad", "CL-bigpad", "CL-e", "CL-dec", "CL-commaprefix", "CL-commasuffix", "CL-expect",
        "CL-expect-obfs", "CL-error", "CL-spacepad", "CL-byteranges", "CL-multiform", "CL-deleteMaxforward", "CL-gzip10", "CL-dualCL",
    ]
    /// NUL, tab, vertical tab, form feed, CR, DEL.
    static let specialCharacters: [UInt8] = [0, 9, 11, 12, 13, 127]
    static var techniques: [String] {
        var all = shared + http1 + http2 + contentLength
        for prefix in ["spacefix1", "prefix1", "suffix1", "namesuffix1"] {
            all += specialCharacters.map { "\(prefix):\($0)" }
        }
        return all
    }

    static let chunkedBase = latin1("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
    static let lengthBase = latin1("POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\n\r\nabc")
    static let probeBase = latin1("POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nX")

    // MARK: DesyncBox.applyDesync, transcribed

    static func latin1(_ string: String) -> [UInt8] { string.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }

    static func replace(_ bytes: [UInt8], _ target: [UInt8], _ replacement: [UInt8], all: Bool = true) -> [UInt8] {
        var output: [UInt8] = [], index = 0, replaced = false
        while index < bytes.count {
            if !(replaced && !all), index + target.count <= bytes.count, Array(bytes[index..<index + target.count]) == target {
                output += replacement
                index += target.count
                replaced = true
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }
    static func replace(_ bytes: [UInt8], _ target: String, _ replacement: String, all: Bool = true) -> [UInt8] {
        replace(bytes, latin1(target), latin1(replacement), all: all)
    }

    /// The value of the first field named exactly `name`.
    static func fieldValue(_ request: [UInt8], _ name: String) -> String {
        let text = String(decoding: request, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") where line.hasPrefix(name + ": ") {
            return String(line.dropFirst(name.count + 2))
        }
        return ""
    }

    static func setMethod(_ request: [UInt8], _ method: String) -> [UInt8] {
        latin1(method) + request[request.firstIndex(of: 0x20)!...]
    }

    static func addOrReplaceHeader(_ request: [UInt8], _ name: String, _ value: String) -> [UInt8] {
        let existing = fieldValue(request, name)
        if request.count != replace(request, "\r\n\(name): ", "").count {
            return replace(request, "\r\n\(name): \(existing)\r\n", "\r\n\(name): \(value)\r\n", all: false)
        }
        return replace(request, "\r\n", "\r\n\(name): \(value)\r\n", all: false)
    }

    /// `DesyncBox.applyDesync(request, header, technique)`: the permuted request, or `nil` when the technique doesn't
    /// change a `Content-Length` request (DesyncBox skips those).
    static func applyDesync(_ request: [UInt8], header name: String, technique: String) -> [UInt8]? {
        var request = request
        let headerValue = fieldValue(request, name)
        let header = name + ": "
        let value = name == "Content-Length" ? fieldValue(request, "Content-Length") : "chunked"
        var permuted: String?
        switch technique {
        case "underjoin1": permuted = header.replacingOccurrences(of: "-", with: "_")
        case "spacejoin1": permuted = header.replacingOccurrences(of: "-", with: " ")
        case "space1": permuted = header.replacingOccurrences(of: ":", with: " :")
        case "nameprefix1": permuted = "Foo: bar\r\n " + header
        case "nameprefix2": permuted = "Foo: bar\r\n\t" + header
        case "valueprefix1": permuted = header + " "
        case "nospace1": permuted = header.replacingOccurrences(of: " ", with: "")
        case "linewrapped1": permuted = header.replacingOccurrences(of: " ", with: "\n ")
        case "doublewrapped": permuted = header.replacingOccurrences(of: " ", with: "\r\n \r\n ")
        case "gareth1": permuted = header.replacingOccurrences(of: ":", with: "\n :")
        case "badsetupCR": permuted = "Foo: bar\r" + header
        case "badsetupLF": permuted = "Foo: bar\n" + header
        case "vertwrap": permuted = header + "\n\u{0B}"
        case "tabwrap": permuted = header + "\r\n\t"
        case "multiCase": permuted = header.prefix(1).lowercased() + header.dropFirst().uppercased()
        case "UPPERCASE": permuted = header.uppercased()
        case "0dwrap": permuted = "Foo: bar\r\n\r" + header
        case "0dspam": permuted = header.prefix(3) + "\r" + header.dropFirst(3)
        case "connection": permuted = "Connection: \(name)\r\n" + header
        case "spjunk": permuted = header.replacingOccurrences(of: ":", with: " x:")
        case "backslash": permuted = header.replacingOccurrences(of: "-", with: "\\")
        case "nel": permuted = header.replacingOccurrences(of: ":", with: "\u{85}:")
        case "nbsp": permuted = header.replacingOccurrences(of: ":", with: "\u{A0}:")
        case "shy2": permuted = header.replacingOccurrences(of: ":", with: "\u{AD}:")
        case "shy": permuted = header.replacingOccurrences(of: "-", with: "\u{AD}")
        default: break
        }
        for character in specialCharacters {
            let scalar = String(Unicode.Scalar(character))
            if technique == "spacefix1:\(character)" { permuted = header.replacingOccurrences(of: " ", with: "") + scalar }
            if technique == "prefix1:\(character)" { permuted = header + scalar }
            if technique == "namesuffix1:\(character)" { permuted = header.replacingOccurrences(of: ":", with: scalar + ":") }
        }
        let original = request
        var transformed = request
        if let permuted { transformed = replace(request, header, permuted) }
        if technique == "badwrap" {
            transformed = replace(request, header, "X-Blah-Ignore: ")
            transformed = replace(transformed, "\r\n", "\r\n " + header + headerValue + "\r\n", all: false)
        }
        if technique == "spaceFF" { transformed = replace(request, latin1(header), latin1(String(header.dropLast())) + [0xFF]) }
        if technique == "unispace" { transformed = replace(request, latin1(header), latin1(String(header.dropLast())) + [0xA0]) }
        if technique == "http1.0" {
            transformed = replace(transformed, "HTTP/1.1", "HTTP/1.0", all: false)
            transformed = replace(transformed, "HTTP/2", "HTTP/1.0", all: false)
        }
        switch technique {
        case "0dsuffix": transformed = replace(request, header + value, header + value + "\r")
        case "tabsuffix": transformed = replace(request, header + value, header + value + "\t")
        case "h2auth": transformed = replace(request, header + value, ":authority: example.com:443^~" + header + value + "^~x: x")
        case "h2path": transformed = replace(request, header + value, ":path: / HTTP/1.1^~" + header + value + "^~x: x")
        case "h2scheme": transformed = replace(request, header + value, ":scheme: https://example.com/ HTTP/1.1^~" + header + value + "^~x: x")
        case "h2method": transformed = replace(request, header + value, ":method: POST / HTTP/1.1^~" + header + value + "^~x: x")
        case "removed": transformed = replace(request, header + value, "Nothing-interesting: 1")
        case "get": transformed = setMethod(request, "GET")
        case "options": transformed = setMethod(request, "OPTIONS")
        case "head": transformed = setMethod(request, "HEAD")
        case "range": transformed = addOrReplaceHeader(request, "Range", "bytes=0-0")
        case "CL-byteranges": transformed = addOrReplaceHeader(request, "Content-Type", "multipart/byteranges; boundary=canary")
        case "CL-multiform": transformed = addOrReplaceHeader(request, "Content-Type", "multipart/form-data; boundary=canary")
        case "CL-deleteMaxforward":
            transformed = setMethod(request, "DELETE")
            transformed = addOrReplaceHeader(transformed, "Max-Forwards", "0")
        case "CL-gzip10":
            transformed = replace(request, "HTTP/1.1", "HTTP/1.0", all: false)
            transformed = replace(transformed, "HTTP/2", "HTTP/1.0", all: false)
            transformed = addOrReplaceHeader(transformed, "Transfer-Encoding", "gzip")
        case "h2CL":
            return addOrReplaceHeader(request, "Content-Length", "0")
        default: break
        }
        for character in specialCharacters where technique == "suffix1:\(character)" {
            transformed = replace(request, latin1(header + value), latin1(header + value) + [character])
        }
        if name == "Transfer-Encoding" {
            switch technique {
            case "commaCow": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-Encoding: chunked, identity")
            case "cowComma": transformed = replace(request, "Transfer-Encoding: ", "Transfer-Encoding: identity, ")
            case "contentEnc": transformed = replace(request, "Transfer-Encoding: ", "Content-Encoding: ")
            case "quoted": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-Encoding: \"chunked\"")
            case "aposed": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-Encoding: 'chunked'")
            case "dualchunk": transformed = addOrReplaceHeader(request, "Transfer-encoding", "identity")
            case "lazygrep": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-Encoding: chunk")
            case "revdualchunk": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-Encoding: identity\r\nTransfer-Encoding: chunked")
            case "bodysplit":
                transformed = replace(request, "Transfer-Encoding: chunked", "X: y")
                transformed = addOrReplaceHeader(transformed, "Foo", "barzxaazz")
                transformed = replace(transformed, "barzxaazz", "barn\n\nTransfer-Encoding: chunked")
            case "nested": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-Encoding: identity, chunked, identity")
            case "http2hide": transformed = replace(request, "Transfer-Encoding: chunked", "Foo: b^~Transfer-Encoding: chunked^~x: x")
            case "encode": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-%45ncoding: chunked")
            case "h2colon": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-Encoding`chunked : chunked")
            case "http2case":
                request = latin1(String(decoding: request, as: UTF8.self).lowercased())
                transformed = replace(request, header + value, "x-reject: 1\r\ntransfer-Encoding: chunked")
            case "h2name": transformed = replace(request, header + value, "Transfer-Encoding`chunked^~xz: x")
            case "h2space": transformed = replace(request, header + value, "Transfer-Encoding chunked : chunked")
            case "h1case": transformed = replace(request, header + value, header.uppercased() + value)
            case "h2prefix": transformed = replace(request, header + value, ":transfer-encoding: chunked")
            case "qencode": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-Encoding: =?iso-8859-1?B?Y2h1bmtlZA==?=")
            case "qencodeutf": transformed = replace(request, "Transfer-Encoding: chunked", "Transfer-Encoding: =?UTF-8?B?Y2h1bmtlZA==?=")
            case "accentTE": transformed = replace(request, latin1(header), latin1("Transf") + [0x82] + latin1("r-Encoding: "))
            case "accentCH": transformed = replace(request, latin1("Transfer-Encoding: chu"), latin1("Transfer-Encoding: ch") + [0x96])
            default: break
            }
        }
        if name == "Content-Length" {
            switch technique {
            case "CL-dualCL": transformed = replace(request, "Content-Length: " + value, "Content-Length: \(value)\r\nContent-Length: \(value)")
            case "CL-plus": transformed = replace(request, "Content-Length: ", "Content-Length: +")
            case "CL-minus": transformed = replace(request, "Content-Length: ", "Content-Length: -")
            case "CL-pad": transformed = replace(request, "Content-Length: ", "Content-Length: 0")
            case "CL-bigpad": transformed = replace(request, "Content-Length: ", "Content-Length: 00000000000")
            case "CL-spacepad": transformed = replace(request, "Content-Length: ", "Content-Length: 0 ")
            case "CL-e": transformed = replace(request, "Content-Length: " + value, "Content-Length: \(value)e0")
            case "CL-dec": transformed = replace(request, "Content-Length: " + value, "Content-Length: \(value).0")
            case "CL-commaprefix": transformed = replace(request, "Content-Length: ", "Content-Length: 0, ")
            case "CL-commasuffix": transformed = replace(request, "Content-Length: " + value, "Content-Length: \(value), 0")
            case "CL-expect": transformed = addOrReplaceHeader(request, "Expect", "100-continue")
            case "CL-expect-obfs": transformed = addOrReplaceHeader(request, "Expect", "x 100-continue")
            case "CL-error": transformed = replace(request, "Content-Length: " + value, "X-Invalid Y: \r\nContent-Length: " + value)
            default: break
            }
        }
        if transformed == original, technique != "vanilla", name == "Content-Length" { return nil }
        return transformed
    }

    // MARK: Verdicts

    /// What HTTPBytes made of a request: rejected, or framed (and how).
    static func verdict(_ request: [UInt8]) -> String {
        switch Conformance.parse(request) {
        case .accept(let message):
            switch message.framing {
            case .none: "none"
            case .length(let length): "length \(length)"
            case .chunked: "chunked"
            case .untilClose: "until close"
            }
        case .reject: "reject"
        case .partial: "partial"
        }
    }

    /// Each technique's verdict on the chunked base and on the `Content-Length` base (`-` where DesyncBox skips it: the
    /// technique doesn't change a `Content-Length` request), with the rule. The rules cite RFC 9112 unless noted.
    static let expected: [String: (chunked: String, length: String, rule: String)] = [
        "vanilla": ("chunked", "length 3", "the base requests"),
        "underjoin1": ("none", "none", "`Transfer_Encoding`/`Content_Length` are other (valid) field names: no framing field"),
        "spacejoin1": ("reject", "reject", "a space in a field name (§5.1: no whitespace before the colon)"),
        "space1": ("reject", "reject", "whitespace before the colon: a server MUST reject (§5.1)"),
        "nameprefix1": ("reject", "reject", "obsolete line folding (§5.2: reject, or replace with SP)"),
        "nameprefix2": ("reject", "reject", "obsolete line folding"),
        "valueprefix1": ("chunked", "length 3", "leading whitespace in a value is OWS, removed (§5.1)"),
        "vertwrap": ("reject", "reject", "a bare LF in a field line (§2.2), then VT"),
        "connection": ("chunked", "length 3", "`Connection` naming the field doesn't remove it for the recipient (RFC 9110 §7.6.1 is for proxies)"),
        "spjunk": ("reject", "reject", "`Transfer-Encoding x` isn't a token"),
        "backslash": ("reject", "reject", "a backslash in a field name isn't a token character (RFC 9110 §5.6.2)"),
        "spaceFF": ("reject", "reject", "0xFF in place of SP: `Transfer-Encoding:\\xFFchunked` is a value starting with obs-text, not `chunked`"),
        "unispace": ("reject", "reject", "0xA0 in place of SP: a value that isn't `chunked` (or a number)"),
        "commaCow": ("reject", "-", "`chunked, identity`: chunked isn't the final coding (§6.3: 400)"),
        "cowComma": ("reject", "-", "`identity, chunked`: a coding besides chunked (identity isn't a transfer coding: 501)"),
        "contentEnc": ("none", "-", "`Content-Encoding: chunked` is a content coding, not framing"),
        "quoted": ("reject", "-", "`\"chunked\"` isn't the token chunked"),
        "aposed": ("reject", "-", "`'chunked'` isn't the token chunked"),
        "dualchunk": ("reject", "-", "`chunked`, then `identity`: chunked isn't final"),
        "lazygrep": ("reject", "-", "`chunk` isn't chunked: the final coding isn't chunked"),
        "0dsuffix": ("reject", "reject", "a bare CR after the value (§2.2)"),
        "tabsuffix": ("chunked", "length 3", "trailing tab is OWS (§5.1)"),
        "revdualchunk": ("reject", "-", "`identity, chunked`: a coding besides chunked"),
        "nested": ("reject", "-", "`identity, chunked, identity`: chunked isn't final"),
        "encode": ("none", "-", "`Transfer-%45ncoding` is another (valid) field name: no percent-decoding of names"),
        "accentTE": ("reject", "-", "0x82 in a field name isn't a token character"),
        "accentCH": ("reject", "-", "`ch\\x96ked` isn't chunked"),
        "removed": ("none", "none", "the field is replaced by an unrelated one"),
        "get": ("chunked", "length 3", "a GET may have a body: framing is by the fields (§6.3)"),
        "options": ("chunked", "length 3", "an OPTIONS may have a body"),
        "head": ("chunked", "length 3", "a HEAD request's body is framed like any other"),
        "range": ("chunked", "length 3", "`Range` doesn't affect a request's framing"),
        "qencode": ("reject", "-", "an encoded word isn't the token chunked"),
        "qencodeutf": ("reject", "-", "an encoded word isn't the token chunked"),
        "nel": ("reject", "reject", "0x85 before the colon isn't a token character"),
        "nbsp": ("reject", "reject", "0xA0 before the colon isn't a token character"),
        "shy": ("reject", "reject", "0xAD in a field name isn't a token character"),
        "shy2": ("reject", "reject", "0xAD before the colon isn't a token character"),
        "nospace1": ("chunked", "length 3", "no OWS after the colon is fine (§5.1)"),
        "linewrapped1": ("reject", "reject", "bare LFs (§2.2), then obsolete folding"),
        "doublewrapped": ("reject", "reject", "obsolete line folding"),
        "gareth1": ("reject", "reject", "a bare LF ends the name's line without a colon"),
        "badsetupCR": ("reject", "reject", "a bare CR (§2.2)"),
        "badsetupLF": ("reject", "reject", "a bare LF (§2.2; HTTPBytes takes no bare LF by default)"),
        "multiCase": ("chunked", "length 3", "field names are case-insensitive (RFC 9110 §5.1), so is the coding (§7)"),
        "tabwrap": ("reject", "reject", "an empty value, then obsolete line folding"),
        "UPPERCASE": ("chunked", "length 3", "field names are case-insensitive"),
        "0dwrap": ("reject", "reject", "a bare CR at a line's start (§2.2)"),
        "0dspam": ("reject", "reject", "a bare CR in a field name"),
        "badwrap": ("reject", "reject", "obsolete line folding after the request line (§2.2)"),
        "bodysplit": ("reject", "-", "bare LFs in a field value"),
        "h1case": ("chunked", "-", "field names are case-insensitive"),
        "http1.0": ("reject", "length 3", "Transfer-Encoding in an HTTP/1.0 request: rejected (§6.1: the framing is faulty); Content-Length is fine"),
        "http2hide": ("none", "-", "one field `Foo` whose value happens to contain `Transfer-Encoding: chunked`"),
        "h2colon": ("reject", "-", "`` ` `` is a token character, but the name `Transfer-Encoding`chunked ` has a space before its colon"),
        "h2auth": ("reject", "reject", "`:authority` is an empty field name"),
        "h2path": ("reject", "reject", "`:path` is an empty field name"),
        "http2case": ("reject", "-", "the whole request lower-cased: `http/1.1` isn't a version (HTTP-name is case-sensitive, §2.3)"),
        "h2scheme": ("reject", "reject", "`:scheme` is an empty field name"),
        "h2name": ("none", "-", "`Transfer-Encoding`chunked^~xz` is another (valid) field name"),
        "h2space": ("reject", "-", "a space in a field name"),
        "h2prefix": ("reject", "-", "`:transfer-encoding` is an empty field name"),
        "h2CL": ("reject", "none", "`Content-Length: 0` added: with Transfer-Encoding, both fields (§6.1); in place of the length, no body (`abc` is the next request's problem)"),
        "h2method": ("reject", "reject", "`:method` is an empty field name"),
        "CL-plus": ("-", "reject", "Content-Length = 1*DIGIT (RFC 9110 §8.6): no sign"),
        "CL-minus": ("-", "reject", "no sign"),
        "CL-pad": ("-", "length 3", "`03` is 1*DIGIT: three"),
        "CL-bigpad": ("-", "length 3", "`000000000003` is 1*DIGIT: three"),
        "CL-e": ("-", "reject", "`3e0` isn't 1*DIGIT"),
        "CL-dec": ("-", "reject", "`3.0` isn't 1*DIGIT"),
        "CL-commaprefix": ("-", "reject", "`0, 3`: differing values (§6.3: 400)"),
        "CL-commasuffix": ("-", "reject", "`3, 0`: differing values"),
        "CL-expect": ("-", "length 3", "`Expect: 100-continue` doesn't change framing"),
        "CL-expect-obfs": ("-", "length 3", "an unknown expectation doesn't change framing (417 is the server's to send)"),
        "CL-error": ("-", "reject", "`X-Invalid Y` has a space in its name"),
        "CL-spacepad": ("-", "reject", "`0 3` isn't 1*DIGIT"),
        "CL-byteranges": ("-", "length 3", "the content type doesn't frame a request"),
        "CL-multiform": ("-", "length 3", "the content type doesn't frame a request"),
        "CL-deleteMaxforward": ("-", "length 3", "a DELETE with Max-Forwards: 0 is framed by its fields"),
        "CL-gzip10": ("-", "reject", "Transfer-Encoding in HTTP/1.0 (and with Content-Length)"),
        "CL-dualCL": ("-", "length 3", "equal values in two fields are one value (§6.3)"),
    ]

    /// The special-character loops: `spacefix1` (no space, then the byte), `prefix1` (the byte after `: `), `suffix1`
    /// (the byte after the value), `namesuffix1` (the byte before the colon).
    static func expectedSpecial(_ technique: String) -> (chunked: String, length: String, rule: String) {
        let parts = technique.split(separator: ":")
        let kind = parts[0], character = UInt8(parts[1])!
        let whitespace = character == 0x09
        switch kind {
        case "spacefix1", "prefix1":
            return whitespace ? ("chunked", "length 3", "a tab is OWS") : ("reject", "reject", "a control character in a value (RFC 9110 §5.5)")
        case "suffix1":
            return whitespace ? ("chunked", "length 3", "a tab is OWS") : ("reject", "reject", "a control character in a value (bare CR: §2.2)")
        default:
            return ("reject", "reject", "a byte that isn't a token character (or whitespace) before the colon (§5.1)")
        }
    }

    static func expectation(_ technique: String) -> (chunked: String, length: String, rule: String)? {
        technique.contains(":") ? expectedSpecial(technique) : expected[technique]
    }

    /// The probe with both fields: a request still chunked is rejected (§6.1, §6.3), one whose `Transfer-Encoding` is gone
    /// is framed by its `Content-Length` (5), and a rejected one stays rejected.
    static func probeExpectation(_ chunked: String) -> String {
        switch chunked {
        case "chunked": "reject"
        case "none": "length 5"
        default: chunked
        }
    }

    @Test func everyPermutationIsRejectedOrFramedAsTheRFCSays() {
        var report: [String] = []
        var count = 0
        for technique in Self.techniques {
            guard let expectation = Self.expectation(technique) else {
                report.append("\(technique): no verdict recorded")
                continue
            }
            let runs: [(String, [UInt8], String, String)] = [
                ("chunked", Self.chunkedBase, "Transfer-Encoding", expectation.chunked),
                ("probe", Self.probeBase, "Transfer-Encoding", Self.probeExpectation(expectation.chunked)),
                ("length", Self.lengthBase, "Content-Length", expectation.length),
            ]
            for (base, request, header, expected) in runs where expected != "-" {
                guard let permuted = Self.applyDesync(request, header: header, technique: technique) else {
                    report.append("\(technique) on the \(base) base: DesyncBox skips it, but a verdict is recorded")
                    continue
                }
                count += 1
                let ours = Self.verdict(permuted)
                if ours != expected {
                    report.append("\(technique) on the \(base) base: ours \(ours); expected \(expected) (\(expectation.rule)) [\(Conformance.escaped(permuted))]")
                }
            }
        }
        #expect(count > 200)
        #expect(report.isEmpty, "\(report.count):\n\(report.joined(separator: "\n"))")
    }

    /// Techniques whose `-` says DesyncBox skips them on the `Content-Length` base really do no-op there.
    @Test func skippedTechniquesDontChangeTheLengthBase() {
        for technique in Self.techniques where Self.expectation(technique)?.length == "-" {
            #expect(Self.applyDesync(Self.lengthBase, header: "Content-Length", technique: technique) == nil, "\(technique)")
        }
    }

    /// Every accepted permutation ends where its framing says, also when it arrives a byte at a time.
    @Test func acceptedPermutationsFrameTheSameInPieces() {
        for technique in Self.techniques {
            for (request, header) in [(Self.chunkedBase, "Transfer-Encoding"), (Self.probeBase, "Transfer-Encoding"), (Self.lengthBase, "Content-Length")] {
                guard let permuted = Self.applyDesync(request, header: header, technique: technique) else { continue }
                let whole = Conformance.parse(permuted)
                #expect(Conformance.parse(permuted, splits: Array(1..<permuted.count)) == whole, "\(technique)")
            }
        }
    }
}
