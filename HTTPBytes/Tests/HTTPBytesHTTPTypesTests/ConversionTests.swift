import HTTPBytes
import HTTPBytesHTTPTypes
import HTTPTypes
import Testing

@Suite struct ConversionTests {
    @Test func methodsAndStatuses() {
        for method in [HTTPMethod.get, .post, .connect, HTTPMethod(Array("PROPFIND".utf8).span.bytes)!] {
            #expect(HTTPMethod(HTTPRequest.Method(method)) == method)
        }
        #expect(HTTPRequest.Method(HTTPMethod.patch) == .patch)
        #expect(HTTPStatus(HTTPResponse.Status.notFound) == .notFound)
        #expect(HTTPResponse.Status(HTTPStatus.notFound).reasonPhrase == "Not Found")
        #expect(HTTPResponse.Status(HTTPStatus(code: 299)!).code == 299)
    }

    @Test func fieldsRoundTrip() throws {
        var fields = HTTPFields()
        fields[.contentType] = "text/html"
        fields.append(HTTPField(name: .setCookie, value: "a=1"))
        fields.append(HTTPField(name: .setCookie, value: "b=2"))
        var secret = HTTPField(name: .authorization, value: "Bearer x")
        secret.indexingStrategy = .disallow
        fields.append(secret)
        fields.append(HTTPField(name: HTTPField.Name("X-Custom")!, value: "v"))
        let store = try HTTPFieldStore(fields)
        #expect(store.count == 5)
        #expect(store.firstIndex(of: .authorization).map { store.flags(at: $0) } == HTTPFieldStore.neverIndexed)
        let back = HTTPFields(store)
        #expect(back == fields)
        #expect(back[fields: .setCookie].count == 2)
        #expect(back[fields: .authorization].first?.indexingStrategy == .disallow)
    }
}
