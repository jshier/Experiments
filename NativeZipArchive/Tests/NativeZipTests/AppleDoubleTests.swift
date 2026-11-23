import BytesTestSupport
import DiskTestSupport
import Foundation
import NativeZip
import System
import Testing

/// AppleDouble entries (`ditto -c -k`'s, the Finder's Compress) merged into their items, against `ditto -x -k`: the
/// same extended attributes, Finder info, resource forks, and ACLs, item for item, and no `__MACOSX` or `._` files.
/// (Archive Utility's results for the same archives are in NativeZipArchive/Benchmarks/RESULTS.md, 2026-11-21.)
///
/// Trees are read with DiskTestSupport's `readTree` (`readdir`, so `._` files show) without `com.apple.provenance`: in a
/// session macOS tracks, the kernel puts it on everything made, `ditto`'s reference trees included.
@Suite(.diskLifetimes) struct AppleDoubleTests {
    /// A tree with attributes on files, a directory, and a symbolic link, a resource fork, Finder info, and an ACL.
    private static func makeTree(in directory: URL) throws -> URL {
        let tree = directory.appending(path: "Tree")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: tree.appending(path: "sub/deep"), withIntermediateDirectories: true)
        for (path, text) in [("plain.txt", "plain"), ("attrs.txt", "attrs"), ("fork.txt", "fork"), ("acl.txt", "acl"), ("sub/deep/inner.txt", "inner")] {
            try Data(text.utf8).write(to: tree.appending(path: path))
        }
        try fileManager.createSymbolicLink(atPath: tree.appending(path: "link").path, withDestinationPath: "plain.txt")
        func set(_ name: String, _ value: [UInt8], on path: String) throws {
            guard setxattr(tree.appending(path: path).path, name, value, value.count, 0, XATTR_NOFOLLOW) == 0 else { throw Errno(rawValue: errno) }
        }
        try set("com.example.note", Array("a note".utf8), on: "attrs.txt")
        try set("com.apple.FinderInfo", Array("TEXTttxt".utf8) + [UInt8](repeating: 0, count: 24), on: "attrs.txt")
        try set("com.example.directory", Array("on a directory".utf8), on: "sub")
        try set("com.example.inner", [UInt8](repeating: 7, count: 5_000), on: "sub/deep/inner.txt")
        try set("com.example.link", Array("on a link".utf8), on: "link")
        var generator = SplitMix64(seed: 3)
        try set("com.apple.ResourceFork", generator.bytes(70_000), on: "fork.txt")
        try ExternalTool.run("/bin/chmod", ["+a", "everyone deny delete", tree.appending(path: "acl.txt").path])
        return tree
    }

    /// What the comparisons read beyond kinds, modes, and link targets.
    private static let parts: TreeParts = [.contents, .attributes, .accessControlList]

    /// `ditto`'s archives of the tree, AppleDouble files under `__MACOSX` or beside their items, with and without the
    /// parent: NativeZip's extraction is `ditto -x -k`'s, but for a symbolic link's own attributes.
    @Test(arguments: [["--sequesterRsrc", "--keepParent"], ["--sequesterRsrc"], ["--keepParent"], [String]()])
    func matchesDitto(_ flags: [String]) async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { directory.remove() }
        let source = try Self.makeTree(in: directory.url)
        let archive = directory.path("tree.zip")
        try ExternalTool.run("/usr/bin/ditto", ["-c", "-k"] + flags + [source.path, archive.path])
        let reference = directory.path("reference"), ours = directory.path("ours")
        try ExternalTool.run("/usr/bin/ditto", ["-x", "-k", archive.path, reference.path])
        try await ZipArchive(url: archive).extract(to: FilePath(ours.path))

        let expected = try readTree(reference, including: Self.parts), actual = try readTree(ours, including: Self.parts)
        let original = try readTree(source, including: Self.parts)
        let prefix = flags.contains("--keepParent") ? "Tree/" : ""
        #expect(actual.keys.sorted() == expected.keys.sorted())
        for (path, item) in expected {
            var item = item
            // `ditto -x` drops a symbolic link's own attributes, which NativeZip restores (on the link) from the link's
            // AppleDouble entry: a link's are compared with the archive's, the source link's that `ditto -c` archived.
            if item.kind == .symbolicLink {
                #expect(item.attributes?.isEmpty == true, "\(path): ditto")
                item.attributes = original[String(path.dropFirst(prefix.count))]?.attributes
            }
            #expect(actual[path] == item, "\(path)")
        }
        // What the comparison stands on: the reference has the attributes, the fork, and the ACL; the link has its own.
        #expect(expected[prefix + "attrs.txt"]?.attributes?.keys.sorted() == ["com.apple.FinderInfo", "com.example.note"])
        #expect(expected[prefix + "fork.txt"]?.attributes?["com.apple.ResourceFork"]?.count == 70_000)
        #expect(expected[prefix + "sub"]?.attributes?["com.example.directory"] != nil)
        #expect(expected[prefix + "acl.txt"]?.accessControlList?.contains("deny:delete") == true)
        #expect(actual[prefix + "link"]?.attributes == ["com.example.link": Array("on a link".utf8)])
        #expect(!actual.keys.contains { $0.contains("__MACOSX") || $0.split(separator: "/").last!.hasPrefix("._") })
    }

    /// Off, the entries are files, as Info-ZIP's `unzip` extracts them.
    @Test func extractsThemAsFilesWhenOff() async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { directory.remove() }
        let source = try Self.makeTree(in: directory.url)
        let archive = directory.path("tree.zip")
        try ExternalTool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path])
        var options = ZipExtractionOptions()
        options.mergesAppleDouble = false
        try await ZipArchive(url: archive).extract(to: FilePath(directory.path("out").path), options: options)
        let tree = try readTree(directory.path("out"), including: Self.parts)
        #expect(tree["__MACOSX/Tree/._attrs.txt"]?.kind == .file)
        #expect(tree["__MACOSX/Tree/._link"]?.kind == .file)
        #expect(tree["Tree/attrs.txt"]?.attributes?.isEmpty == true)
        #expect(tree["Tree/link"]?.attributes?.isEmpty == true)
    }

    /// Names that only look like AppleDouble stay files: one that isn't an AppleDouble file, and one whose item isn't in
    /// the archive (beside it or under `__MACOSX`). A symbolic link's is merged into the link itself. A plain file under
    /// `__MACOSX` is extracted there. (Archive Utility refuses such an archive outright, error 79; `ditto` and `unzip`
    /// extract.)
    @Test func leavesWhatItCannotMerge() async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { directory.remove() }
        // A real AppleDouble file's bytes: `ditto`'s, extracted unmerged.
        let source = try Self.makeTree(in: directory.url)
        try ExternalTool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, directory.path("tree.zip").path])
        var raw = ZipExtractionOptions()
        raw.mergesAppleDouble = false
        try await ZipArchive(url: directory.path("tree.zip")).extract(to: FilePath(directory.path("raw").path), options: raw)
        let appleDouble = try Data(contentsOf: directory.path("raw/__MACOSX/Tree/._attrs.txt"))

        let edge = directory.path("edge")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: edge.appending(path: "__MACOSX/d"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: edge.appending(path: "d"), withIntermediateDirectories: true)
        try appleDouble.write(to: edge.appending(path: "._orphan.txt"))
        try appleDouble.write(to: edge.appending(path: "__MACOSX/._gone.txt"))
        try Data("not AppleDouble, but long enough to be read\n".utf8).write(to: edge.appending(path: "._bogus.txt"))
        try Data("bogus's item\n".utf8).write(to: edge.appending(path: "bogus.txt"))
        try Data("plain\n".utf8).write(to: edge.appending(path: "__MACOSX/plain.txt"))
        try Data("target\n".utf8).write(to: edge.appending(path: "d/t.txt"))
        try appleDouble.write(to: edge.appending(path: "__MACOSX/d/._t.txt"))
        try fileManager.createSymbolicLink(atPath: edge.appending(path: "lnk").path, withDestinationPath: "d/t.txt")
        try appleDouble.write(to: edge.appending(path: "._lnk"))
        // A resource fork for a directory (it can't have one): its other attributes are set, the fork left out.
        try Data(contentsOf: directory.path("raw/__MACOSX/Tree/._fork.txt")).write(to: edge.appending(path: "__MACOSX/._d"))
        try ExternalTool.run("/usr/bin/zip", ["-qry", directory.path("edge.zip").path, "."], in: edge)

        try await ZipArchive(url: directory.path("edge.zip")).extract(to: FilePath(directory.path("out").path))
        let tree = try readTree(directory.path("out"), including: Self.parts)
        #expect(tree.keys.sorted() == [
            "._bogus.txt", "._orphan.txt", "__MACOSX", "__MACOSX/._gone.txt", "__MACOSX/plain.txt", "bogus.txt", "d", "d/t.txt", "lnk",
        ])
        #expect(tree["d/t.txt"]?.attributes?.keys.sorted() == ["com.apple.FinderInfo", "com.example.note"])
        // The link's AppleDouble, on the link (read without following it), its target unchanged.
        #expect(tree["lnk"]?.kind == .symbolicLink && tree["lnk"]?.linkTarget == "d/t.txt")
        #expect(tree["lnk"]?.attributes?.keys.sorted() == ["com.apple.FinderInfo", "com.example.note"])
        #expect(tree["lnk"]?.attributes?["com.example.note"] == Array("a note".utf8))
        #expect(tree["bogus.txt"]?.attributes?.isEmpty == true)
        #expect(tree["d"]?.attributes?.isEmpty == true)
        #expect(tree["._orphan.txt"]?.contents == Array(appleDouble))
    }

    /// An AppleDouble file holding `attributes` (no Finder info, no resource fork), laid out as `copyfile` writes one:
    /// a Finder info entry of 32 zero bytes and 2 of padding, then the attribute header, the entries, and the values.
    private static func appleDouble(_ attributes: [(name: String, value: [UInt8])]) -> [UInt8] {
        func word(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func half(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        let finderInfo = 26 + 12
        let header = finderInfo + 34
        // Each entry's name with its NUL; entries padded to multiples of 4 (the header ends on one).
        let names = attributes.map { Array($0.name.utf8) + [0] }
        let entrySizes = names.map { (11 + $0.count + 3) & ~3 }
        let dataStart = header + 36 + entrySizes.reduce(0, +)
        var entries: [UInt8] = [], data: [UInt8] = []
        for (index, attribute) in attributes.enumerated() {
            var entry = word(dataStart + data.count) + word(attribute.value.count) + half(0) + [UInt8(names[index].count)] + names[index]
            entry += [UInt8](repeating: 0, count: entrySizes[index] - entry.count)
            entries += entry
            data += attribute.value
        }
        let total = dataStart + data.count
        var bytes = word(0x0005_1607) + word(0x0002_0000) + [UInt8](repeating: 0, count: 16) + half(1)
        bytes += word(9) + word(finderInfo) + word(total - finderInfo)
        bytes += [UInt8](repeating: 0, count: 34)
        bytes += Array("ATTR".utf8) + word(0) + word(total) + word(dataStart) + word(data.count) + [UInt8](repeating: 0, count: 12)
        bytes += half(0) + half(attributes.count)
        return bytes + entries + data
    }

    /// A link's own AppleDouble entry restores its attributes on the link, not its target, `com.apple.provenance`
    /// included (as `aa extract` restores it). Provenance reads back only in a process macOS doesn't track: in a tracked
    /// one the kernel owns the attribute, and setting it changes nothing.
    @Test func restoresALinksAttributes() async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { directory.remove() }
        let source = directory.path("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("target\n".utf8).write(to: source.appending(path: "t.txt"))
        try FileManager.default.createSymbolicLink(atPath: source.appending(path: "l").path, withDestinationPath: "t.txt")
        let custom = Array("on the link".utf8)
        // Shaped as the kernel's values are: 01 02 00 and 8 bytes.
        let provenance: [UInt8] = [0x01, 0x02, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
        let entry = Self.appleDouble([("com.example.l", custom), (SystemAttributes.provenance, provenance)])
        try Data(entry).write(to: source.appending(path: "._l"))
        try ExternalTool.run("/usr/bin/zip", ["-qry", directory.path("link.zip").path, "."], in: source)
        try await ZipArchive(url: directory.path("link.zip")).extract(to: FilePath(directory.path("out").path))

        let tree = try readTree(directory.path("out"), including: .attributes, ignoringAttributes: [])
        #expect(tree.keys.sorted() == ["l", "t.txt"])
        #expect(tree["l"]?.kind == .symbolicLink && tree["l"]?.linkTarget == "t.txt")
        #expect(tree["l"]?.attributes?["com.example.l"] == custom)
        #expect(tree["t.txt"]?.attributes?["com.example.l"] == nil)
        // In a tracked process (a terminal's) the kernel owns the attribute and the value can't be read back: run the
        // test with `Tools/untracked` to check it. Which branch ran is printed.
        if SystemAttributes.isProvenanceTracked(scratchDirectory: directory.url) {
            print("restoresALinksAttributes: provenance-tracked process, provenance read-back not checked")
        } else {
            print("restoresALinksAttributes: untracked process, provenance read-back checked")
            #expect(tree["l"]?.attributes?[SystemAttributes.provenance] == provenance)
        }
    }

    /// Links get the archive's times only when asked (Archive Utility sets them; Info-ZIP's `unzip` doesn't).
    @Test(arguments: [false, true])
    func restoresLinkTimes(_ restores: Bool) async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { directory.remove() }
        let source = directory.path("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appending(path: "file"))
        try FileManager.default.createSymbolicLink(atPath: source.appending(path: "link").path, withDestinationPath: "file")
        // 2019-12-11: the link's own time (`-h`), not its target's.
        try ExternalTool.run("/usr/bin/touch", ["-h", "-t", "201912111009.08", source.appending(path: "link").path])
        try ExternalTool.run("/usr/bin/zip", ["-qry", directory.path("links.zip").path, "."], in: source)
        var options = ZipExtractionOptions()
        options.restoresLinkTimestamps = restores
        try await ZipArchive(url: directory.path("links.zip")).extract(to: FilePath(directory.path("out").path), options: options)
        let extracted = try readItem(at: directory.path("out/link"), including: .modification)
        let original = try readItem(at: source.appending(path: "link"), including: .modification)
        #expect((extracted.modification?.seconds == original.modification?.seconds) == restores)
    }
}
