import HTTPBytes
import Testing

@Suite struct RequestTargetTests {
    func validate(_ target: String, _ method: HTTPMethod? = .get) throws(HTTPRequestTargetError) -> HTTPRequestTargetForm {
        let bytes = Array(target.utf8)
        return try HTTPRequestTarget.validate(bytes.span.bytes, method: method)
    }

    @Test func acceptedTargets() throws {
        #expect(try validate("/") == .origin)
        #expect(try validate("/a/b;c=d/%7Efoo?x=1&y=%20&z=/?:@!$'()*+,;=") == .origin)
        #expect(try validate("//double//slashes") == .origin)
        #expect(try validate("http://example.com:8080/path?q") == .absolute)
        #expect(try validate("http://[::1]:80/") == .absolute)
        #expect(try validate("urn:isbn:0451450523") == .absolute)
        #expect(try validate("*", .options) == .asterisk)
        #expect(try validate("example.com:443", .connect) == .authority)
        #expect(try validate("[2001:db8::1]:443", .connect) == .authority)
        #expect(try validate("192.0.2.1:8443", .connect) == .authority)
    }

    @Test(arguments: [
        ("/a b", HTTPMethod.get, HTTPRequestTargetError.invalidCharacter),
        ("/a\"b", .get, .invalidCharacter), ("/a#frag", .get, .invalidCharacter), ("/a<b>", .get, .invalidCharacter),
        ("/a\\b", .get, .invalidCharacter), ("/{x}", .get, .invalidCharacter), ("/a|b", .get, .invalidCharacter),
        ("/a^b", .get, .invalidCharacter), ("/`", .get, .invalidCharacter), ("/[x]", .get, .invalidCharacter),
        ("/foo%2zbar", .get, .invalidPercentEncoding), ("/foo%2", .get, .invalidPercentEncoding), ("/%", .get, .invalidPercentEncoding),
        ("!", .get, .invalidForm), ("?x", .get, .invalidForm), (":", .post, .invalidForm),
        ("../../etc/passwd", .get, .invalidForm), ("1http://x/", .get, .invalidForm),
        ("*", .get, .invalidForm),
        ("example.com", .connect, .invalidForm), ("example.com:", .connect, .invalidForm), ("/path", .connect, .invalidForm),
        ("a@b:80", .connect, .invalidForm), ("[]:80", .connect, .invalidForm), ("[::1:80", .connect, .invalidForm),
        ("http://x/[y]", .get, .invalidCharacter),
    ])
    func rejectedTargets(target: String, method: HTTPMethod, error: HTTPRequestTargetError) {
        #expect(throws: error) { _ = try validate(target, method) }
    }

    /// The vector test against a byte-at-a-time definition of RFC 3986's characters.
    @Test func characterClass() {
        let allowed = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?%[]".utf8))
        for value in 0...255 {
            let byte = UInt8(value)
            let target = Array("/aaaaaaaaaaaaaaaaaaa".utf8) + [byte] + Array("bbbb".utf8)
            let rejected = (try? HTTPRequestTarget.validate(target.span.bytes, method: nil)) == nil
            // `%` needs digits after it and brackets need an authority: checked apart above.
            if byte == 0x25 || byte == 0x5B || byte == 0x5D { continue }
            #expect(rejected == !allowed.contains(byte), "byte \(value)")
        }
    }
}
