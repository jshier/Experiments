import Bytes
@testable import Disk
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
    func acceptsCanonicalRelativePaths(_ path: String) throws {
        let bytes = Array(path.utf8)
        bytes.withUnsafeBytes { buffer in
            let valid = EntryPath.isValid(RawSpan(_unsafeBytes: buffer))
            #expect(valid, "\(path)")
        }
    }

    @Test(arguments: invalid)
    func rejectsUnsafePaths(_ path: String) throws {
        let bytes = Array(path.utf8)
        bytes.withUnsafeBytes { buffer in
            let valid = EntryPath.isValid(RawSpan(_unsafeBytes: buffer))
            #expect(!valid, "\(path.debugDescription)")
            #expect(throws: DiskError.self) { _ = try EntryPath(validating: RawSpan(_unsafeBytes: buffer)) }
        }
    }

    /// The vector screen and the exact check agree, for every placement of each unsafe pattern around block
    /// boundaries (paths of 1–48 bytes).
    @Test func screenAgreesWithTheExactCheck() {
        let patterns: [[UInt8]] = [[0x2F, 0x2F], [0x2F, 0x2E], [0], [0x2F, 0x2E, 0x2E, 0x2F], [0x2E, 0x2F]]
        for count in 1...48 {
            for pattern in patterns where pattern.count <= count {
                for position in 0...(count - pattern.count) {
                    var bytes = [UInt8](repeating: 0x61, count: count)
                    for (index, byte) in pattern.enumerated() { bytes[position + index] = byte }
                    bytes.withUnsafeBytes { buffer in
                        let base = buffer.baseAddress!
                        let screened = EntryPath.screen(base, count)
                        let exact = EntryPath.exactCheck(base, count)
                        // The screen may send valid paths to the exact check, never pass an invalid one.
                        #expect(!screened || exact, "\(bytes)")
                        let valid = EntryPath.isValid(RawSpan(_unsafeBytes: buffer))
                        #expect(valid == exact, "\(bytes)")
                    }
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
        let result = try bytes.withUnsafeBytes { buffer in
            try output.withUnsafeMutableBytes { outputBuffer in
                var span = OutputRawSpan(buffer: outputBuffer, initializedCount: 0)
                let result = try EntryPath.sanitize(RawSpan(_unsafeBytes: buffer), into: &span)
                _ = span.finalize(for: outputBuffer)
                return result
            }
        }
        #expect(String(decoding: output.prefix(result.count), as: UTF8.self) == expected)
        #expect(result.adjusted == adjusted)
    }
}
