import BytesCrypto
import BytesTestSupport
import Foundation
@testable import NativeAEA
import System
import Testing

/// The strict JSON reader WKMS's auth data is parsed with, and a WKMS request end to end: an archive `aea` encrypts
/// with the request in its auth data, opened with the key the request wraps.
@Suite(.diskLifetimes) struct WKMSTests {
    private func members(_ text: String) throws -> [String: String] {
        let bytes = Array(text.utf8)
        return try JSON.stringMembers(bytes.span.bytes)
    }

    /// The response's shape (`{"enc-request": "<base64>", "wrapped-key": "<base64>"}`), compact and spaced out.
    @Test func readsTheResponseShape() throws {
        let compact = #"{"enc-request":"BHJlcXVlc3Q=","wrapped-key":"a2V5"}"#
        #expect(try members(compact) == ["enc-request": "BHJlcXVlc3Q=", "wrapped-key": "a2V5"])
        let spaced = "\r\n\t{ \"enc-request\" :\n \"BHJlcXVlc3Q=\" ,\t\"wrapped-key\": \"a2V5\" }\n "
        #expect(try members(spaced) == ["enc-request": "BHJlcXVlc3Q=", "wrapped-key": "a2V5"])
        #expect(try members("{}") == [:])
        #expect(try members(" { } ") == [:])
        #expect(try members(#"{"":""}"#) == ["": ""])
    }

    @Test func unescapesStrings() throws {
        // Every short escape, and `\"` and `\\` at the ends of the runs between quotes.
        let text = #"{"a":"\"\\\/\b\f\n\r\t","b":"x\"","c":"\\","d":"\"\"","e":"\\\"\\"}"#
        #expect(try members(text) == ["a": "\"\\/\u{8}\u{C}\n\r\t", "b": "x\"", "c": "\\", "d": "\"\"", "e": "\\\"\\"])
        // `\u` escapes in either case, below and above U+0800, a surrogate pair, and UTF-8 as is.
        let unicode = #"{"u":"\u0041\u00e9\u20AC\ud83d\ude00\u0000","é":"€😀"}"#
        #expect(try members(unicode) == ["u": "Aé€😀\u{0}", "é": "€😀"])
        // Names are unescaped too.
        #expect(try members(#"{"enc\u002drequest":"x"}"#) == ["enc-request": "x"])
    }

    @Test(arguments: [
        "", " ", "[]", #""a""#, "{", "{ ", #"{"a""#, #"{"a":"#, #"{"a":"b""#, #"{"a":"b","#, #"{"a":"b",}"#,
        #"{"a":"b"} x"#, #"{"a":"b"}{}"#, #"{"a" "b"}"#, #"{"a":"b" "c":"d"}"#, #"{a:"b"}"#, #"{'a':'b'}"#,
        #"{"a":1}"#, #"{"a":null}"#, #"{"a":true}"#, #"{"a":["b"]}"#, #"{"a":{"b":"c"}}"#,
        #"{"a":"b","a":"c"}"#, // A repeated name.
        #"{"a":"\x"}"#, #"{"a":"\u12"}"#, #"{"a":"\u12G4"}"#, #"{"a":"\"}"#, #"{"a":"\u"}"#,
        #"{"a":"\ud800"}"#, #"{"a":"\ud800x"}"#, #"{"a":"\ud800\u0041"}"#, #"{"a":"\udc00"}"#, // Lone surrogates.
        "{\"a\":\"\t\"}", "{\"a\":\"\n\"}", "{\"a\":\"\u{0}\"}", // Control characters, unescaped.
        "\u{B}{}", "\u{C}{}", "\u{A0}{}", // Whitespace JSON doesn't have.
    ])
    func rejectsMalformedText(_ text: String) {
        #expect(throws: (any Error).self, "\(text.debugDescription)") { _ = try members(text) }
    }

    @Test func rejectsInvalidUTF8() {
        for bytes: [UInt8] in [[0xFF], [0xC3], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80]] {
            let text = Array(#"{"a":""#.utf8) + bytes + Array(#""}"#.utf8)
            #expect(throws: (any Error).self, "\(bytes)") { _ = try JSON.stringMembers(text.span.bytes) }
        }
    }

    /// A profile 1 archive with a WKMS request in its auth data, as an IPSW's disk image has: the request read from the
    /// prologue, its wrapped key opened with the private key's PEM, and the archive opened with that key.
    @Test func opensAWKMSRequest() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let symmetric = testBytes(32, seed: 77, compressible: false)
        let recipient = P256.PrivateKey()
        var sender = HPKE.Sender(recipientKey: recipient.publicKey, aead: .aes256GCM, info: RawSpan())
        let wrapped = sender.seal(symmetric.span.bytes, authenticating: RawSpan())
        let encapsulated = sender.encapsulatedKey
        // Foundation's Base64 here: an encoder independent of the library's decoder.
        let response = """
            {"enc-request": "\(Data(encapsulated).base64EncodedString())", "wrapped-key": "\(Data(wrapped).base64EncodedString())"}
            """
        let responseFile = directory.path("response.json")
        try Data(response.utf8).write(to: responseFile)
        let keyURL = "https://example.com/keys/the-key.pem"

        let contents = testBytes(100_000, seed: 78, compressible: true)
        let input = directory.path("image.dmg")
        try Data(contents).write(to: input)
        let url = directory.path("image.dmg.aea")
        try ExternalTool.run("/usr/bin/aea", [
            "encrypt", "-profile", "1", "-i", input.path, "-o", url.path, "-a", "lzfse",
            "-key-value", "hex:" + symmetric.map { String(format: "%02x", $0) }.joined(),
            "-auth-data-key", "com.apple.wkms.fcs-response", "-auth-data", responseFile.path,
            "-auth-data-key", "com.apple.wkms.fcs-key-url", "-auth-data-value", "base64:" + Data(keyURL.utf8).base64EncodedString(),
        ])

        let prologue = try AEAArchive.prologue(at: FilePath(url.path))
        let request = try #require(try WKMS.request(in: prologue))
        #expect(request.keyURL == URL(string: keyURL))
        #expect(request.encapsulatedKey == encapsulated)
        #expect(request.wrappedKey == wrapped)
        let key = try WKMS.key(request, privateKeyPEM: recipient.pemRepresentation)
        guard case .symmetric(let opened) = key else {
            Issue.record("not a symmetric key: \(key)")
            return
        }
        #expect(opened == symmetric)

        let archive = try AEAArchive(url: url, decryptionKey: key)
        defer { archive.close() }
        let output = directory.path("image.dmg.out")
        try await archive.decrypt(to: FilePath(output.path))
        #expect(Array(try Data(contentsOf: output)) == contents)

        // A wrong private key doesn't open the request.
        #expect(throws: AEAError.self) { _ = try WKMS.key(request, privateKeyPEM: P256.PrivateKey().pemRepresentation) }
    }

    /// Malformed responses in the auth data are the archive's error, not a crash or a silent `nil`.
    @Test func rejectsAMalformedResponse() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let input = directory.path("image.dmg")
        try Data(testBytes(1_000, seed: 79, compressible: true)).write(to: input)
        for response in [#"{"enc-request": "AAAA"}"#, #"{"enc-request": "AAAA", "wrapped-key": 7}"#, #"{"enc-request": "AAA", "wrapped-key": "AAAA"}"#] {
            let responseFile = directory.path("response.json")
            try Data(response.utf8).write(to: responseFile)
            let url = directory.path("image.dmg.aea")
            try ExternalTool.run("/usr/bin/aea", [
                "encrypt", "-profile", "1", "-i", input.path, "-o", url.path, "-key-value", "hex:" + String(repeating: "11", count: 32),
                "-auth-data-key", "com.apple.wkms.fcs-response", "-auth-data", responseFile.path,
            ])
            let prologue = try AEAArchive.prologue(at: FilePath(url.path))
            #expect(throws: AEAError.invalidHeader("com.apple.wkms.fcs-response"), "\(response)") { _ = try WKMS.request(in: prologue) }
            try FileManager.default.removeItem(at: url)
        }
    }
}
