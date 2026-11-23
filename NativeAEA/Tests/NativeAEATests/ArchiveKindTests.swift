import BytesTestSupport
import Foundation
import NativeAEA
import System
import Testing

/// Recognizing an archive's format: by its first bytes, then its extension.
@Suite struct ArchiveKindTests {
    @Test func kindsByTheirFirstBytes() {
        #expect(ArchiveKind(magic: Array("PK\u{3}\u{4}rest".utf8)) == .zip)
        // An empty ZIP is only its end record; a spanned one starts with a data descriptor's signature.
        #expect(ArchiveKind(magic: Array("PK\u{5}\u{6}".utf8)) == .zip)
        #expect(ArchiveKind(magic: Array("PK\u{7}\u{8}PK\u{3}\u{4}".utf8)) == .zip)
        #expect(ArchiveKind(magic: Array("AEA1....".utf8)) == .appleEncryptedArchive)
        #expect(ArchiveKind(magic: Array("xar!....".utf8)) == .xip)
        #expect(ArchiveKind(magic: Array("AA01....".utf8)) == .appleArchive)
        #expect(ArchiveKind(magic: Array("YAA1....".utf8)) == .appleArchive)
        #expect(ArchiveKind(magic: Array("pbze....".utf8)) == .appleArchive)
        // A 3-byte file can still be a `pbz` stream's start; nothing else is that short.
        #expect(ArchiveKind(magic: Array("pbz".utf8)) == .appleArchive)
        #expect(ArchiveKind(magic: Array("%PDF-1.7".utf8)) == nil)
        // Too short to say, or nothing at all.
        #expect(ArchiveKind(magic: Array("PK".utf8)) == nil)
        #expect(ArchiveKind(magic: []) == nil)
    }

    @Test func aFilesKindIsItsFirstBytesElseItsExtension() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        func kind(_ name: String, _ contents: String) throws -> ArchiveKind? {
            let file = directory.path(name)
            try Data(contents.utf8).write(to: file)
            return try ArchiveKind(detecting: FilePath(file.path))
        }
        let cases: [(name: String, contents: String, kind: ArchiveKind?)] = [
            // The contents win over a wrong extension, and need none.
            ("Renamed.xip", "PK\u{3}\u{4}....", .zip),
            ("NoExtension", "AEA1....", .appleEncryptedArchive),
            // Unrecognized contents (here, none; a file shorter than any magic): the extension, in any case.
            ("Empty.zip", "", .zip),
            ("Short.AEA", "AE", .appleEncryptedArchive),
            ("Old.yaa", "....", .appleArchive),
            ("Other.aar", "....", .appleArchive),
            ("Xcode.XIP", "....", .xip),
            // Neither says.
            ("Notes.pdf", "%PDF-1.7", nil),
        ]
        for (name, contents, expected) in cases {
            let detected = try kind(name, contents)
            #expect(detected == expected, "\(name)")
        }
        // A file that can't be read: Disk's error, with the call and the path.
        let missing = #expect(throws: AEAError.self) { _ = try ArchiveKind(detecting: FilePath(directory.path("Missing.zip").path)) }
        #expect(missing?.description.contains("open") == true)
        #expect(missing?.description.contains("Missing.zip") == true)
    }
}
