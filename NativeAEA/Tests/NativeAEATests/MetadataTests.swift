import BytesTestSupport
import Foundation
@testable import NativeAEA
import System
import Testing

/// What extraction restores besides contents and modes, checked against Apple's `aa extract` on the same stream:
/// extended attributes (large ones across segments), ACLs, hard links, attributes on links, the quarantine
/// attribute copied from the archive, and FIFOs and devices.
@Suite struct MetadataTests {
    private func makeSourceTree(at root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appending(path: "dir/inner"), withIntermediateDirectories: true)
        func write(_ path: String, _ size: Int, seed: UInt64) throws {
            try Data(testBytes(size, seed: seed, compressible: seed % 2 == 0)).write(to: root.appending(path: path))
        }
        func xattr(_ path: String, _ name: String, _ size: Int, link: Bool = false) throws {
            let value = testBytes(size, seed: UInt64(size), compressible: false)
            let result = setxattr(root.appending(path: path).path, name, value, value.count, 0, link ? XATTR_NOFOLLOW : 0)
            guard result == 0 else { throw TestFailure(description: "setxattr \(path) \(name): \(errno)") }
        }
        try write("plain", 1_000, seed: 1)
        try write("attributes", 5_000, seed: 2)
        try xattr("attributes", "com.example.small", 10)
        try xattr("attributes", "com.example.empty", 0)
        // Larger than the 16 KiB segments: the blob crosses segment boundaries.
        try xattr("attributes", "com.example.large", 50_000)
        try write("large-with-attributes", 300_000, seed: 3)
        try xattr("large-with-attributes", "com.example.tag", 100)
        try write("read-only", 2_000, seed: 4)
        try xattr("read-only", "com.example.tag", 7)
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root.appending(path: "read-only").path)
        try xattr("dir", "com.example.directory", 20)
        try write("dir/inner/original", 70_000, seed: 5)
        try manager.linkItem(at: root.appending(path: "dir/inner/original"), to: root.appending(path: "dir/second-name"))
        try manager.linkItem(at: root.appending(path: "dir/inner/original"), to: root.appending(path: "third-name"))
        try manager.createSymbolicLink(atPath: root.appending(path: "link").path, withDestinationPath: "plain")
        try xattr("link", "com.example.on-link", 12, link: true)
        try write("acl-file", 300, seed: 6)
        try ExternalTool.run("/bin/chmod", ["+a", "group:staff deny delete", root.appending(path: "acl-file").path])
        try ExternalTool.run("/bin/chmod", ["+a", "user:\(NSUserName()) allow read,write,append,readattr,writeextattr", root.appending(path: "acl-file").path])
        try ExternalTool.run("/bin/chmod", ["+a", "everyone allow list,add_file,file_inherit,directory_inherit", root.appending(path: "dir/inner").path])
    }

    @Test(arguments: [1, 4])
    func restoresMetadataAsAppleDoes(_ threads: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        let source = directory.path("source")
        try makeSourceTree(at: source)
        let stream = directory.path("tree.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", "raw", "-d", source.path, "-o", stream.path])
        let url = try makeAEA(stream, keys: keys, in: directory, compression: "lzfse", blockSize: "16k")
        // A downloaded archive: both extractors copy its quarantine onto everything.
        let quarantine = Array("0081;6720ab00;Safari;".utf8)
        for file in [stream, url] {
            #expect(setxattr(file.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)
        }

        let reference = directory.path("reference")
        try ExternalTool.run("/usr/bin/aa", ["extract", "-i", stream.path, "-d", reference.path])
        let destination = directory.path("out")
        var options = AEAExtractionOptions()
        options.read.decodeThreads = threads
        options.writerThreads = threads
        options.fileSystemWidth = min(threads, 2)
        let statistics = try await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(destination.path), options: options)
        #expect(statistics.unreleasedBuffers == 0)
        #expect(statistics.hardLinks == 3)
        #expect(statistics.withAccessControlLists == 2)

        #expect(try readTree(destination) == readTree(reference))
        let extracted = try readMetadata(destination), expected = try readMetadata(reference)
        #expect(extracted.keys.sorted() == expected.keys.sorted())
        for (path, metadata) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(extracted[path] == metadata, "\(path)")
        }
        // The source's own attributes came through (not only what both extractors add).
        #expect(extracted["attributes"]?.attributes["com.example.large"]?.count == 50_000)
        #expect(extracted["link"]?.attributes["com.example.on-link"]?.count == 12)
        #expect(extracted["third-name"]?.hardLinks == ["dir/inner/original", "dir/second-name", "third-name"])
        #expect(extracted["acl-file"]?.accessControlList != nil)
        // The destination itself: not for an `.aea` (as `aa extract` does with Xcode's), yes for a plain `.aar`.
        #expect(getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
        let fromStream = directory.path("from-stream")
        try await AppleArchiveFile(path: FilePath(stream.path)).extract(to: FilePath(fromStream.path), options: options)
        #expect(getxattr(fromStream.path, "com.apple.quarantine", nil, 0, 0, 0) == quarantine.count)
        #expect(getxattr(reference.path, "com.apple.quarantine", nil, 0, 0, 0) == quarantine.count)
        #expect(try readMetadata(fromStream) == readMetadata(reference))

        // Without quarantine copying.
        let bare = directory.path("bare")
        options.copyQuarantine = false
        try await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(bare.path), options: options)
        let bareMetadata = try readMetadata(bare)
        #expect(bareMetadata.values.allSatisfy { $0.attributes["com.apple.quarantine"] == nil })
        #expect(bareMetadata == (try readMetadata(destination, ignoring: ["com.apple.quarantine"])))
    }

    @Test func makesFIFOsAndSkipsWhatItCannot() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        var writer = ArchiveStreamWriter()
        writer.directory("")
        writer.directory("dev")
        writer.special("dev/pipe", type: "P", mode: 0o640)
        writer.special("dev/null-ish", type: "C", mode: 0o666, device: 0x0300_0002)
        writer.special("dev/socket", type: "S")
        writer.file("dev/after", Array("still here".utf8))
        let stream = directory.path("special.aar")
        try writer.write(to: stream)
        let url = try makeAEA(stream, keys: keys, in: directory)
        let destination = directory.path("out")
        let statistics = try await AEAArchive(url: url, signingKey: keys.signingKey).extract(to: FilePath(destination.path))

        var info = stat()
        #expect(lstat(destination.appending(path: "dev/pipe").path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFIFO)
        #expect(info.st_mode & 0o7777 == 0o640)
        #expect(lstat(destination.appending(path: "dev/socket").path, &info) != 0)
        #expect(try String(contentsOf: destination.appending(path: "dev/after"), encoding: .utf8) == "still here")
        if geteuid() == 0 {
            #expect(lstat(destination.appending(path: "dev/null-ish").path, &info) == 0)
            #expect(info.st_mode & S_IFMT == S_IFCHR)
            #expect(statistics.specialFiles == 2)
            #expect(statistics.skippedEntries == 1)
        } else {
            // Devices need root: skipped and counted, like the socket.
            #expect(lstat(destination.appending(path: "dev/null-ish").path, &info) != 0)
            #expect(statistics.specialFiles == 1)
            #expect(statistics.skippedEntries == 2)
        }
    }
}
