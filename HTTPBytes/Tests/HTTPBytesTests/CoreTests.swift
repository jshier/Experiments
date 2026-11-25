import Bytes
import BytesTestSupport
import HTTPBytes
import Testing

func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

func text(_ span: RawSpan) -> String {
    String(decoding: (0..<span.byteCount).map { span.load(fromByteOffset: $0, as: UInt8.self) }, as: UTF8.self)
}

@Suite struct FieldNameTests {
    /// Every known name is found from its lowercase, canonical, and uppercase spellings, and spells itself back.
    @Test func everyNameIsFoundInAnyCase() {
        for index in 0..<HTTPFieldName.knownCount {
            let name = HTTPFieldName(index: index)!
            let lower = text(name.lowercaseBytes), canonical = text(name.canonicalBytes)
            #expect(lower == canonical.lowercased())
            for spelling in [lower, canonical, canonical.uppercased()] {
                #expect(HTTPFieldName(caseInsensitive: bytes(spelling).span.bytes) == name, "\(spelling)")
            }
            #expect(name.description == canonical)
        }
        #expect(HTTPFieldName.contentType.description == "Content-Type")
        #expect(HTTPFieldName.eTag.description == "ETag")
        #expect(HTTPFieldName.pseudoPath.isPseudoHeader && !HTTPFieldName.host.isPseudoHeader)
    }

    /// Names one edit away from a known name, and random tokens, aren't taken for known names.
    @Test func nearMissesAreUnknown() {
        for index in 0..<HTTPFieldName.knownCount {
            let name = Array(text(HTTPFieldName(index: index)!.lowercaseBytes).utf8)
            var longer = name; longer.append(0x78)
            var shorter = name; shorter.removeLast()
            var changed = name; changed[changed.count / 2] = changed[changed.count / 2] == 0x7A ? 0x79 : 0x7A
            for variant in [longer, shorter, changed] where !variant.isEmpty {
                let found = HTTPFieldName(caseInsensitive: variant.span.bytes)
                #expect(found == nil || text(found!.lowercaseBytes) == String(decoding: variant, as: UTF8.self))
            }
        }
        var generator = SplitMix64(seed: 9)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz-0123456789".utf8)
        for _ in 0..<20_000 {
            let length = Int(generator.next() % 30) + 1
            let token = (0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }
            if let found = HTTPFieldName(caseInsensitive: token.span.bytes) {
                #expect(text(found.lowercaseBytes) == String(decoding: token, as: UTF8.self))
            }
        }
    }

    @Test func staticTableIndexes() {
        #expect(HTTPFieldName.pseudoAuthority.hpackStaticIndex == 1 && HTTPFieldName.pseudoAuthority.qpackStaticIndex == 0)
        #expect(HTTPFieldName.wwwAuthenticate.hpackStaticIndex == 61)
        #expect(HTTPFieldName.xFrameOptions.qpackStaticIndex == 97 && HTTPFieldName.xFrameOptions.hpackStaticIndex == nil)
        #expect(HTTPFieldName.connection.hpackStaticIndex == nil && HTTPFieldName.connection.qpackStaticIndex == nil)
    }
}

@Suite struct MethodTests {
    @Test func methods() {
        for (method, spelling) in [(HTTPMethod.get, "GET"), (.head, "HEAD"), (.post, "POST"), (.put, "PUT"), (.delete, "DELETE"),
                                   (.connect, "CONNECT"), (.options, "OPTIONS"), (.trace, "TRACE"), (.patch, "PATCH")] {
            #expect(HTTPMethod(bytes(spelling).span.bytes) == method)
            #expect(method.description == spelling && method.byteCount == spelling.utf8.count)
        }
        #expect(HTTPMethod(bytes("get").span.bytes) != .get)
        let long = HTTPMethod(bytes("VERSION-CONTROL!").span.bytes)
        #expect(long?.description == "VERSION-CONTROL!" && long?.byteCount == 16)
        #expect(HTTPMethod(bytes("UPDATEREDIRECTREF").span.bytes) == nil)
        #expect(HTTPMethod(bytes("").span.bytes) == nil)
        #expect(HTTPMethod(bytes("GE T").span.bytes) == nil)
    }
}

@Suite struct FieldStoreTests {
    @Test func appendFindAndReuse() throws {
        var store = HTTPFieldStore()
        for round in 0..<3 {
            try store.append(.host, value: bytes("example.com").span.bytes)
            try store.append(name: bytes("X-Custom").span.bytes, value: bytes("one").span.bytes)
            try store.append(name: bytes("content-TYPE").span.bytes, value: bytes("text/plain").span.bytes, flags: HTTPFieldStore.neverIndexed)
            for index in 0..<20 {
                try store.append(name: bytes("X-\(index)").span.bytes, value: bytes("\(index)").span.bytes)
            }
            try store.append(.setCookie, value: bytes("a=1").span.bytes)
            try store.append(.setCookie, value: bytes("b=2").span.bytes)
            #expect(store.count == 25)
            // `Optional.map` doesn't take `~Escapable` values: unwrap with `if let`.
            if let host = store.firstValue(of: .host) { #expect(text(host) == "example.com") } else { Issue.record("no host") }
            if let type = store.firstValue(of: .contentType) { #expect(text(type) == "text/plain") } else { Issue.record("no type") }
            #expect(store.firstIndex(of: .setCookie) == 23 && store.firstIndex(of: .setCookie, from: 24) == 24)
            #expect(store.firstIndex(of: .age) == nil)
            do {
                // `#expect` can't capture a view: compare first.
                let custom = store.field(at: 1)
                // (Nor can `&&`'s autoclosure.)
                let name = text(custom.name), value = text(custom.value), known = custom.knownName
                #expect(name == "X-Custom" && value == "one" && known == nil)
            }
            #expect(store.field(at: 2).knownName == .contentType && store.flags(at: 2) == HTTPFieldStore.neverIndexed)
            if round < 2 { store.removeAll() }
        }
    }

    @Test func invalidFieldsAreRejected() {
        var store = HTTPFieldStore()
        #expect(throws: HTTPFieldError.invalidName) { try store.append(name: bytes("").span.bytes, value: bytes("a").span.bytes) }
        #expect(throws: HTTPFieldError.invalidName) { try store.append(name: bytes("a b").span.bytes, value: bytes("a").span.bytes) }
        #expect(throws: HTTPFieldError.invalidValue) { try store.append(.host, value: bytes(" a").span.bytes) }
        #expect(throws: HTTPFieldError.invalidValue) { try store.append(.host, value: bytes("a\r\nb").span.bytes) }
        #expect(throws: HTTPFieldError.invalidValue) { try store.append(.host, value: bytes("a\u{7F}").span.bytes) }
        #expect(store.isEmpty)
    }
}
