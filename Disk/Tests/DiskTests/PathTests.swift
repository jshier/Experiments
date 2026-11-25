@testable import Disk
import Bytes
import Testing

@Suite(.diskLifetimes) struct PathTests {
    static let valid = [
        "", "a", "a/b", "a/b/c.txt", "Xcode.app/Contents/Info.plist", ".hidden", "a/.hidden", "a/..b", "a/b..", "...", "a/...",
        "a/.b/c", String(repeating: "x", count: 15), String(repeating: "x", count: 16), String(repeating: "y", count: 17),
        String(repeating: "abcdefghijklmno/", count: 20) + "end", String(repeating: "z", count: 1023),
    ]
    static let invalid = [
        "/", "/a", "a/", "a//b", ".", "..", "a/.", "a/..", "../a", "a/../b", "./a", "a/./b", "a\0b", "\0",
        String(repeating: "abcdefghijklmno/", count: 3) + "..", String(repeating: "abcdefghijklmn/", count: 3) + "/x",
        String(repeating: "z", count: 1024), String(repeating: "q", count: 40) + "\0",
    ]

    @Test(arguments: valid)
    func acceptsCanonicalRelativePaths(_ path: String) {
        let bytes = Array(path.utf8)
        let valid = EntryPath.isValid(bytes.span.bytes)
        #expect(valid, "\(path)")
    }

    @Test(arguments: invalid)
    func rejectsUnsafePaths(_ path: String) throws {
        let bytes = Array(path.utf8)
        let valid = EntryPath.isValid(bytes.span.bytes)
        #expect(!valid, "\(path.debugDescription)")
        #expect(throws: DiskError.self) { _ = try EntryPath(validating: bytes.span.bytes) }
    }

    /// The vector screen and the exact check agree, for every placement of each unsafe pattern around block
    /// boundaries (paths of 1–48 bytes).
    @Test func screenAgreesWithTheExactCheck() {
        let patterns: [[UInt8]] = [[0x2F, 0x2F], [0x2F, 0x2E], [0], [0x2F, 0x2E, 0x2E, 0x2F], [0x2E, 0x2F]]
        for count in 1...48 {
            for pattern in patterns where pattern.count <= count {
                for position in 0...(count - pattern.count) {
                    var bytes = [UInt8](repeating: 0x61, count: count)
                    for (index, byte) in pattern.enumerated() {
                        bytes[position + index] = byte
                    }
                    let screened = EntryPath.screen(bytes.span.bytes)
                    let exact = EntryPath.exactCheck(bytes.span.bytes)
                    // The screen may send valid paths to the exact check, never pass an invalid one.
                    #expect(!screened || exact, "\(bytes)")
                    let valid = EntryPath.isValid(bytes.span.bytes)
                    #expect(valid == exact, "\(bytes)")
                }
            }
        }
    }

    @Test(arguments: [
        ("/etc/passwd", "etc/passwd", true), ("../../x", "x", true), ("a/./b//c/", "a/b/c", false), ("a/../b", "a/b", true),
        ("..", "", true), ("plain/name", "plain/name", false), ("a\0hidden", "a", false),
    ])
    func sanitizesAsInfoZIPDoes(_ input: String, _ expected: String, _ adjusted: Bool) throws {
        var output = [UInt8](repeating: 0, count: 64)
        let bytes = Array(input.utf8)
        let result = try output.withOutputRawSpan { span throws(DiskError) in try EntryPath.sanitize(bytes.span.bytes, into: &span) }
        #expect(String(decoding: output.prefix(result.count), as: UTF8.self) == expected)
        #expect(result.adjusted == adjusted)
    }
}
