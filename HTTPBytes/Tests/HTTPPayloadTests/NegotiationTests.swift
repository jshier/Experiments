import HTTPPayload
import Testing

/// Choosing a response's coding: jshttp's negotiator encoding tests (MIT) with an offered list, as
/// `HTTPContentCoding.negotiated(acceptEncoding:available:)`. One deliberate difference: without `Accept-Encoding`,
/// negotiator offers only `identity`; RFC 9110 §12.5.3 makes every coding acceptable, so the first offered is chosen.
@Suite struct NegotiationTests {
    static func choose(_ accept: String?, _ available: [HTTPContentCoding]) -> HTTPContentCoding? {
        guard let accept else { return HTTPContentCoding.negotiated(acceptEncoding: nil, available: available) }
        let bytes = Array(accept.utf8)
        return HTTPContentCoding.negotiated(acceptEncoding: bytes.span.bytes, available: available)
    }

    @Test func negotiatorEncodings() {
        #expect(Self.choose("*", [.identity]) == .identity)
        #expect(Self.choose("*", [.gzip, .identity]) == .gzip)
        #expect(Self.choose("*, gzip", [.deflate, .gzip]) == .deflate, "ties go to the server's order")
        #expect(Self.choose("*, gzip;q=0", [.gzip]) == nil)
        #expect(Self.choose("*, gzip;q=0", [.gzip, .deflate]) == .deflate)
        #expect(Self.choose("*;q=0", [.identity]) == nil)
        #expect(Self.choose("*;q=0", [.gzip]) == nil)
        #expect(Self.choose("*;q=0, identity;q=1", [.identity]) == .identity)
        #expect(Self.choose("*;q=0, identity;q=1", [.gzip]) == nil)
        #expect(Self.choose("identity", [.identity]) == .identity)
        #expect(Self.choose("identity", [.gzip]) == nil)
        #expect(Self.choose("gzip", [.gzip, .identity]) == .gzip)
        #expect(Self.choose("gzip;q=0.8, deflate", [.gzip, .deflate]) == .deflate)
        #expect(Self.choose("gzip;q=0.8, identity;q=0.5, *;q=0.3", [.deflate, .gzip, .identity]) == .gzip)
        #expect(Self.choose("gzip, deflate, br, zstd", [.zstd, .brotli, .gzip]) == .zstd)
        #expect(Self.choose("", [.gzip, .identity]) == .identity, "an empty field accepts only identity")
        #expect(Self.choose(nil, [.brotli, .gzip]) == .brotli)
        #expect(Self.choose("gzip;q=2", [.gzip, .identity]) == .identity, "a malformed field: identity only")
    }
}
