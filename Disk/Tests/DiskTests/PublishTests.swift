import BytesTestSupport
import Darwin
@testable import Disk
import Foundation
import System
import Testing

/// Publishing a staging destination as Archive Utility publishes an expansion (``Destination/publishUnwrapped(as:)``),
/// and what the folder it makes looks like: measured against Archive Utility, 2026-11-21 (Disk/RESULTS.md).
@Suite struct PublishTests {
    static let quarantine = Quarantine(value: Array("0081;673e3000;Safari;11111111-2222-3333-4444-555555555555".utf8))

    private func staging(for final: FilePath, quarantined: Bool = true) throws -> Destination {
        var options = DestinationOptions()
        if quarantined {
            options.quarantine = Self.quarantine
            options.quarantinesDestination = true
        }
        return try Destination.staging(for: final, options: options)
    }

    @Test func movesOutASingleItemUniquelyNamed() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var published: [String] = []
        for round in 0..<3 {
            let staging = try staging(for: directory.filePath("Archive"))
            var writer = FileWriter(staging)
            try withPath("hello.txt") { try writer.writeFile($0, contents: ([UInt8(round)] as [UInt8]).span.bytes, metadata: EntryMetadata(mode: 0o640)) }
            published.append(try staging.publishUnwrapped(as: directory.filePath("Archive")).lastComponent!.string)
        }
        #expect(published == ["hello.txt", "hello 2.txt", "hello 3.txt"])
        // Nothing else is left: no folder, no staging directory.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == ["hello 2.txt", "hello 3.txt", "hello.txt"])
        #expect(try item(directory.path("hello 3.txt")).contents == [2])
        #expect(try item(directory.path("hello 3.txt")).mode == 0o640 & ~UInt16(getumask()))
        #expect(extendedAttribute(directory.path("hello.txt"), "com.apple.quarantine") == Self.quarantine.value)
    }

    /// A read-only directory can't be renamed into another parent (its `..` changes): it's lent the owner's write bit
    /// for the rename, and has its own mode again after.
    @Test func movesOutAReadOnlyDirectory() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        for expected in ["Tree", "Tree 2"] {
            let staging = try staging(for: directory.filePath("Archive"), quarantined: false)
            try withPath("Tree/inner") { try staging.makeDirectory($0) }
            try withPath("Tree") { try staging.finishDirectory($0, metadata: EntryMetadata(mode: 0o555, times: EntryTimes(modification: Timestamp(seconds: 1_500_000_000)))) }
            let published = try staging.publishUnwrapped(as: directory.filePath("Archive"))
            #expect(published == directory.filePath(expected))
            let info = try #require(stat(directory.path(expected)))
            #expect(info.st_mode & 0o7777 == 0o555)
            #expect(info.st_mtimespec.tv_sec == 1_500_000_000)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == ["Tree", "Tree 2"])
    }

    /// Several items go in a folder named after the archive: 0700 and quarantined, as Archive Utility's.
    @Test func publishesSeveralItemsAsAFolder() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        for expected in ["Archive", "Archive 2"] {
            let staging = try staging(for: directory.filePath("Archive"))
            var writer = FileWriter(staging)
            for name in ["a.txt", "b.txt"] {
                try withPath(name) { try writer.writeFile($0, contents: ([1] as [UInt8]).span.bytes) }
            }
            let published = try staging.publishUnwrapped(as: directory.filePath("Archive"))
            #expect(published == directory.filePath(expected))
            #expect(stat(directory.path(expected)).map { $0.st_mode & 0o7777 } == 0o700)
            #expect(extendedAttribute(directory.path(expected), "com.apple.quarantine") == Self.quarantine.value)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(expected).path).sorted() == ["a.txt", "b.txt"])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == ["Archive", "Archive 2"])
    }

    /// An archive with nothing in it still makes its (empty) folder, and a plain destination can't be published.
    @Test func publishesNothingAsAnEmptyFolder() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let staging = try staging(for: directory.filePath("Empty"), quarantined: false)
        #expect(try staging.publishUnwrapped(as: directory.filePath("Empty")) == directory.filePath("Empty"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path("Empty").path).isEmpty)
        let plain = try Destination(directory.filePath("plain"))
        #expect(throws: DiskError.self) { _ = try plain.publishUnwrapped(as: directory.filePath("other")) }
    }

    /// An entry for the archive's root (`aa archive -d DIR` writes one) sets the staging directory's mode and times, so
    /// the published folder has them (Archive Utility's 0755 folders for such archives, against 0700 otherwise).
    @Test func aRootEntrySetsTheFoldersModeAndTimes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.permissions = .exact
        let staging = try Destination.staging(for: directory.filePath("Archive"), options: options)
        let source = ArraySource([[1], [2]])
        let time = EntryTimes(modification: Timestamp(seconds: 1_600_000_000))
        _ = try await Extraction.run(into: staging, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
            try withPath("") { (path) throws(DiskError) in _ = try planner.directory(path, metadata: EntryMetadata(mode: 0o755, times: time)) }
            _ = try await planFile(&planner, "one", index: 0, size: 1)
            _ = try await planFile(&planner, "two", index: 1, size: 1)
        }
        let published = try staging.publishUnwrapped(as: directory.filePath("Archive"))
        let info = try #require(stat(URL(filePath: published.string)))
        #expect(info.st_mode & 0o7777 == 0o755)
        #expect(info.st_mtimespec.tv_sec == 1_600_000_000)
    }

    /// AppleDouble's `com.apple.acl.text` becomes the blob the planner takes, and the file gets the ACL.
    @Test func setsAnACLFromItsText() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let text = "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000:root:0:allow,file_inherit:read,write\n"
        let textBytes = Array(text.utf8), otherBytes = Array("not an acl".utf8)
        let parsed = AccessControlListBlob(text: textBytes.span.bytes), other = AccessControlListBlob(text: otherBytes.span.bytes)
        let blob = try #require(parsed)
        #expect(other == nil)
        let destination = try Destination(directory.filePath("out"))
        let source = ArraySource([[1]])
        _ = try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
            try withPath("d") { (path) throws(DiskError) in
                let token = try planner.directory(path, attachments: true)
                try planner.addAccessControlList(blob.bytes.span.bytes, to: token)
            }
            let file = try await planFile(&planner, "f", index: 0, size: 1, attachments: true)
            try planner.addAccessControlList(blob.bytes.span.bytes, to: file)
        }
        for name in ["out/f", "out/d"] {
            let read = try #require(aclText(directory.path(name)), "\(name)")
            #expect(read.contains("everyone:12:deny:delete"), "\(name): \(read)")
            #expect(read.contains("root:0:allow,file_inherit:read,write"), "\(name): \(read)")
        }
    }

    private func aclText(_ url: URL) -> String? {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(text) }
        return String(cString: text)
    }
}
