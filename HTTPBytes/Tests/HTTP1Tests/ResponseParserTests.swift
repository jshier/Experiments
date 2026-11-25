import Bytes
import BytesTestSupport
import Foundation
import HTTP1
import HTTPBytes
import Testing

struct ParsedResponse: Equatable, CustomStringConvertible {
    var version = "", status = 0, reason = ""
    var fields: [[String]] = []
    var byteCount = 0
    var description: String { "\(version) \(status) \(reason) \(fields) (\(byteCount) bytes)" }
}

func parseResponse(_ parser: inout HTTP1ResponseParser, _ bytes: RawSpan, into head: inout ParsedResponse) throws(HTTP1Error) -> Bool {
    while true {
        switch try parser.next(in: bytes) {
        case let .statusLine(line):
            head.version = "\(line.version)"
            head.status = line.status.code
            head.reason = string(line.reasonPhrase)
        case let .field(field):
            head.fields.append([string(field.name), string(field.value)])
        case let .end(headByteCount):
            head.byteCount = headByteCount
            return true
        case .needsMore:
            return false
        }
    }
}

func parseResponse(_ bytes: [UInt8]) throws(HTTP1Error) -> ParsedResponse? {
    var parser = HTTP1ResponseParser()
    var head = ParsedResponse()
    return try parseResponse(&parser, bytes.span.bytes, into: &head) ? head : nil
}

func referenceResponse(_ bytes: [UInt8]) -> ParsedResponse {
    let headText = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
    var lines = headText.components(separatedBy: "\r\n")
    let statusLine = lines.removeFirst()
    let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    var head = ParsedResponse(version: parts[0], status: Int(parts[1])!, reason: parts.count > 2 ? parts[2] : "")
    for line in lines {
        let colon = line.firstIndex(of: ":")!
        head.fields.append([String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))])
    }
    head.byteCount = headText.utf8.count + 4
    return head
}

let corpusResponses: [[UInt8]] = {
    guard let url = try? TestData.file(set: "http-corpus", name: "responses.http1"), let data = try? Data(contentsOf: url) else { return [] }
    let text = String(decoding: data, as: UTF8.self)
    return text.components(separatedBy: "\r\n\r\n").dropLast().map { Array(($0 + "\r\n\r\n").utf8) }
}()

@Suite struct ResponseParserTests {
    @Test func corpusResponsesMatchTheReference() throws {
        try #require(!corpusResponses.isEmpty, "run Tools/test-data fetch qifs http-corpus")
        for head in corpusResponses {
            #expect(try parseResponse(head + Array("<html>".utf8)) == referenceResponse(head))
        }
    }

    @Test func everyCutResumes() throws {
        for head in corpusResponses.prefix(20) + [Array("HTTP/1.1 204\r\n\r\n".utf8)] {
            let whole = try #require(try parseResponse(head))
            for cut in 0..<head.count {
                var parser = HTTP1ResponseParser()
                var parsed = ParsedResponse()
                #expect(try !parseResponse(&parser, Array(head[..<cut]).span.bytes, into: &parsed), "cut \(cut)")
                #expect(try parseResponse(&parser, head.span.bytes, into: &parsed))
                #expect(parsed == whole, "cut \(cut)")
            }
        }
    }

    @Test func statusLines() throws {
        #expect(try parseResponse(Array("HTTP/1.0 404 Not Found\r\n\r\n".utf8))
            == ParsedResponse(version: "HTTP/1.0", status: 404, reason: "Not Found", byteCount: 26))
        #expect(try parseResponse(Array("HTTP/1.1 200 \r\n\r\n".utf8))?.reason == "")
        #expect(try parseResponse(Array("HTTP/1.1 200\r\n\r\n".utf8))?.status == 200)
        #expect(try parseResponse(Array("HTTP/1.1 599 Ok\u{80}\r\n\r\n".utf8.dropLast(4)) + [0x80, 0x0D, 0x0A, 0x0D, 0x0A])?.status == 599)
    }

    @Test(arguments: [
        ("HTTP/1.1 20 OK\r\n\r\n", HTTP1Error.invalidStatus),
        ("HTTP/1.1 2000 OK\r\n\r\n", .invalidStatus),
        ("HTTP/1.1 099 OK\r\n\r\n", .invalidStatus),
        ("HTTP/1.1  200 OK\r\n\r\n", .invalidStatus),
        ("HTTP/1.1 200 O\u{01}K\r\n\r\n", .invalidStatus),
        ("HTTP/2 200 OK\r\n\r\n", .invalidVersion),
        ("HTTP/3.0 200 OK\r\n\r\n", .unsupportedVersion),
        ("HTTP/1.1 200 OK\r\nA b: c\r\n\r\n", .invalidFieldName),
    ])
    func malformedResponsesAreRejected(text: String, error: HTTP1Error) {
        #expect(throws: error) { _ = try parseResponse(Array(text.utf8)) }
    }
}
