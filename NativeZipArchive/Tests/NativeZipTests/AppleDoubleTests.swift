import BytesTestSupport
import Foundation
import NativeZip
import System
import Testing

/// AppleDouble entries (`ditto -c -k`'s, the Finder's Compress) merged into their items, against `ditto -x -k`: the
/// same extended attributes, Finder info, resource forks, and ACLs, item for item, and no `__MACOSX` or `._` files.
/// (Archive Utility's results for the same archives are in NativeZipArchive/Benchmarks/RESULTS.md, 2026-11-21.)
@Suite struct AppleDoubleTests {
    /// A tree with attributes on files and a directory, a resource fork, Finder info, and an ACL.
    private static func makeTree(in directory: URL) throws -> URL {
        let tree = directory.appending(path: "Tree")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: tree.appending(path: "sub/deep"), withIntermediateDirectories: true)
        for (path, text) in [("plain.txt", "plain"), ("attrs.txt", "attrs"), ("fork.txt", "fork"), ("acl.txt", "acl"), ("sub/deep/inner.txt", "inner")] {
            try Data(text.utf8).write(to: tree.appending(path: path))
        }
        try fileManager.createSymbolicLink(atPath: tree.appending(path: "link").path, withDestinationPath: "plain.txt")
        func set(_ name: String, _ value: [UInt8], on path: String) throws {
            guard setxattr(tree.appending(path: path).path, name, value, value.count, 0, 0) == 0 else { throw Errno(rawValue: errno) }
        }
        try set("com.example.note", Array("a note".utf8), on: "attrs.txt")
        try set("com.apple.FinderInfo", Array("TEXTttxt".utf8) + [UInt8](repeating: 0, count: 24), on: "attrs.txt")
        try set("com.example.directory", Array("on a directory".utf8), on: "sub")
        try set("com.example.inner", [UInt8](repeating: 7, count: 5_000), on: "sub/deep/inner.txt")
        var generator = SplitMix64(seed: 3)
        try set("com.apple.ResourceFork", generator.bytes(70_000), on: "fork.txt")
        try ExternalTool.run("/bin/chmod", ["+a", "everyone deny delete", tree.appending(path: "acl.txt").path])
        return tree
    }

    struct Item: Equatable, CustomStringConvertible {
        var kind: String
        var contents: Data?
        var attributes: [String: [UInt8]]
        var accessControlList: String?

        var description: String {
            "\(kind) \(attributes.map { "\($0.key): \($0.value.count) bytes" }.sorted()) \(accessControlList ?? "")"
        }
    }

    private static func attributes(_ path: String) -> [String: [UInt8]] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return [:] }
        var result: [String: [UInt8]] = [:]
        for name in names.split(separator: 0).map({ String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }) {
            let count = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard count >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: count)
            _ = getxattr(path, name, &value, count, 0, XATTR_NOFOLLOW)
            result[name] = value
        }
        return result
    }

    private static func accessControlList(_ path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(text) }
        return String(cString: text)
    }

    /// Every name under `directory`, relative to it, by `readdir` (Foundation's enumerators leave `._` files out).
    private static func names(under directory: String, prefix: String = "") -> [String] {
        guard let stream = opendir(directory) else { return [] }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            guard name != ".", name != ".." else { continue }
            result.append(prefix + name)
            if entry.pointee.d_type == DT_DIR { result += names(under: directory + "/" + name, prefix: prefix + name + "/") }
        }
        return result
    }

    private static func tree(_ root: URL) throws -> [String: Item] {
        var result: [String: Item] = [:]
        for relative in names(under: root.path) {
            let path = root.path + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0 else { throw Errno(rawValue: errno) }
            let kind = switch info.st_mode & S_IFMT {
            case S_IFDIR: "directory"
            case S_IFLNK: "link"
            default: "file"
            }
            result[relative] = Item(
                kind: kind, contents: kind == "file" ? try Data(contentsOf: URL(filePath: path)) : nil, attributes: attributes(path),
                accessControlList: accessControlList(path)
            )
        }
        return result
    }

    /// `ditto`'s archives of the tree, AppleDouble files under `__MACOSX` or beside their items, with and without the
    /// parent: NativeZip's extraction is `ditto -x -k`'s.
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

        let expected = try Self.tree(reference), actual = try Self.tree(ours)
        #expect(actual.keys.sorted() == expected.keys.sorted())
        for (path, item) in expected {
            #expect(actual[path] == item, "\(path)")
        }
        // What the comparison stands on: the reference has the attributes, the fork, and the ACL.
        let prefix = flags.contains("--keepParent") ? "Tree/" : ""
        #expect(expected[prefix + "attrs.txt"]?.attributes.keys.sorted() == ["com.apple.FinderInfo", "com.example.note"])
        #expect(expected[prefix + "fork.txt"]?.attributes["com.apple.ResourceFork"]?.count == 70_000)
        #expect(expected[prefix + "sub"]?.attributes["com.example.directory"] != nil)
        #expect(expected[prefix + "acl.txt"]?.accessControlList?.contains("deny:delete") == true)
        #expect(!actual.keys.contains { $0.contains("__MACOSX") || $0.split(separator: "/").last!.hasPrefix("._") })
    }

    /// Off, the entries are files, as Info-ZIP's `unzip` extracts them.
    @Test func extractsThemAsFilesWhenOff() async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { directory.remove() }
        let source = try Self.makeTree(in: directory.url)
        let archive = directory.path("tree.zip")
        try ExternalTool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path])
        var options = ExtractionOptions()
        options.mergesAppleDouble = false
        try await ZipArchive(url: archive).extract(to: FilePath(directory.path("out").path), options: options)
        let tree = try Self.tree(directory.path("out"))
        #expect(tree["__MACOSX/Tree/._attrs.txt"]?.kind == "file")
        #expect(tree["Tree/attrs.txt"]?.attributes.isEmpty == true)
    }

    /// Names that only look like AppleDouble stay files: one that isn't an AppleDouble file, one whose item isn't in the
    /// archive (beside it or under `__MACOSX`), and one for a symbolic link. A plain file under `__MACOSX` is
    /// extracted there. (Archive Utility refuses such an archive outright, error 79; `ditto` and `unzip` extract.)
    @Test func leavesWhatItCannotMerge() async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { directory.remove() }
        // A real AppleDouble file's bytes: `ditto`'s, extracted unmerged.
        let source = try Self.makeTree(in: directory.url)
        try ExternalTool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, directory.path("tree.zip").path])
        var raw = ExtractionOptions()
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
        let tree = try Self.tree(directory.path("out"))
        #expect(tree.keys.sorted() == [
            "._bogus.txt", "._lnk", "._orphan.txt", "__MACOSX", "__MACOSX/._gone.txt", "__MACOSX/plain.txt", "bogus.txt", "d", "d/t.txt", "lnk",
        ])
        #expect(tree["d/t.txt"]?.attributes.keys.sorted() == ["com.apple.FinderInfo", "com.example.note"])
        #expect(tree["bogus.txt"]?.attributes.isEmpty == true)
        #expect(tree["d"]?.attributes.isEmpty == true)
        #expect(tree["._orphan.txt"]?.contents == appleDouble)
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
        var options = ExtractionOptions()
        options.restoreLinkTimestamps = restores
        try await ZipArchive(url: directory.path("links.zip")).extract(to: FilePath(directory.path("out").path), options: options)
        var info = stat(), original = stat()
        #expect(lstat(directory.path("out/link").path, &info) == 0)
        #expect(lstat(source.appending(path: "link").path, &original) == 0)
        #expect((info.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec) == restores)
    }
}
