import BytesTestSupport
import Darwin
import DiskTestSupport
import Foundation
import Testing

/// DiskTestSupport's `TreeManifest`: what it records, that it reads back what it writes, and that differences match
/// names by their bytes. (Its agreement with the generator's Python manifests is checked wherever NativeAEA's and
/// NativeZip's coverage tests compare an extraction with one.)
@Suite(.diskLifetimes) struct TreeManifestTests {
    /// Writes `contents` at `path` through `open`, which takes the name's bytes as they are (Foundation's file APIs
    /// pass names through `fileSystemRepresentation`, which decomposes them).
    private static func write(_ contents: String, at path: String) throws {
        let descriptor = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw TestFailure(description: "open \(path): \(errno)") }
        defer { close(descriptor) }
        let bytes = Array(contents.utf8)
        guard Darwin.write(descriptor, bytes, bytes.count) == bytes.count else { throw TestFailure(description: "write \(path)") }
    }

    private static func makeTree(at root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appending(path: "nfc"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appending(path: "nfd"), withIntermediateDirectories: true)
        try write("one", at: root.path + "/nfc/caf\u{E9}")
        try write("two", at: root.path + "/nfd/cafe\u{301}")
        #expect(link(root.path + "/nfc/caf\u{E9}", root.path + "/second") == 0)
        try manager.createSymbolicLink(atPath: root.appending(path: "link").path, withDestinationPath: "second")
        let value = Array("value".utf8)
        #expect(setxattr(root.appending(path: "second").path, "com.example.test", value, value.count, 0, 0) == 0)
        try manager.setAttributes([.posixPermissions: 0o4755], ofItemAtPath: root.appending(path: "second").path)
    }

    @Test func recordsAndRoundTrips() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.path("tree")
        try Self.makeTree(at: root)
        let manifest = try TreeManifest(of: root)
        #expect(manifest.items.map(\.path) == ["link", "nfc", "nfc/caf\u{E9}", "nfd", "nfd/cafe\u{301}", "second"])
        let file = try #require(manifest.items.first { $0.path == "second" })
        #expect(file.mode == "4755" && file.size == 3 && file.links == ["nfc/caf\u{E9}", "second"])
        #expect(file.sha256 == "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed") // SHA-256 of "one".
        #expect(file.xattrs?["com.example.test"] == TreeManifest.Attribute(
            size: 5, sha256: "cd42404d52ad55ccfa9aca4adc828aa5800ad9d385a0671fbcbf724118320619"
        ))
        #expect(manifest.items.first { $0.path == "link" }?.target == "second")

        let saved = directory.path("manifest.json")
        try manifest.write(to: saved)
        #expect(try TreeManifest(contentsOf: saved) == manifest)
        #expect(try TreeManifest(of: root).differences(from: manifest).isEmpty)
    }

    /// A name in the other normalization form is a different item (Swift's `==` on strings would call them equal).
    @Test func matchesNamesByTheirBytes() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.path("tree")
        try Self.makeTree(at: root)
        let expected = try TreeManifest(of: root)
        // `rename` with the names' bytes as they are (see `write(_:at:)`).
        #expect(rename(root.path + "/nfd/cafe\u{301}", root.path + "/nfd/x") == 0)
        #expect(rename(root.path + "/nfd/x", root.path + "/nfd/caf\u{E9}") == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appending(path: "second").path)
        let differences = try TreeManifest(of: root).differences(from: expected)
        // In path order (by bytes: `e` before the NFC `é`'s lead byte).
        let renamed = differences.filter { $0.path.hasPrefix("nfd/") }
        #expect(renamed.map(\.field) == [.missing, .unexpected])
        #expect(renamed.first?.path.utf8.elementsEqual("nfd/cafe\u{301}".utf8) == true)
        // The mode, on both names of the file.
        #expect(differences.filter { $0.field == .mode }.map(\.path) == ["nfc/caf\u{E9}", "second"])
    }
}
