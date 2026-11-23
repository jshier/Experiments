import BytesTestSupport
import Disk
import DiskTestSupport
import Foundation
@testable import NativeAEA
import System
import Testing

/// What extraction restores besides contents and modes, checked against Apple's `aa extract` on the same stream:
/// extended attributes (large ones across segments), ACLs, hard links, attributes on links, the quarantine
/// attribute copied from the archive, and FIFOs and devices.
@Suite(.diskLifetimes) struct MetadataTests {
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
        options.disk.writers = threads
        options.disk.fileSystemWidth = min(threads, 2)
        let opened = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { opened.close() }
        let statistics = try await opened.extract(to: FilePath(destination.path), options: options)
        #expect(statistics.unreleasedBuffers == 0)
        #expect(statistics.hardLinks == 3)
        #expect(statistics.withAccessControlLists == 2)

        // Item for item against `aa`'s tree, without the quarantine: in a process macOS tracks for provenance (this
        // session's: every item it makes gets `com.apple.provenance`), `aa extract` writes a fresh `0081;<now>;;`
        // instead of copying the archive's. (Provenance is left out by default: both trees have the kernel's.) The
        // quarantine is checked against the archive's own value after.
        let parts = TreeParts.entries.union(.metadata)
        let ignored: Set<String> = ["com.apple.quarantine", SystemAttributes.provenance]
        let extracted = try readTree(destination, including: parts, ignoringAttributes: ignored)
        let expected = try readTree(reference, including: parts, ignoringAttributes: ignored)
        #expect(extracted.keys.sorted() == expected.keys.sorted())
        for (path, item) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(extracted[path] == item, "\(path)")
        }
        // The source's own attributes came through (not only what both extractors add).
        #expect(extracted["attributes"]?.attributes?["com.example.large"]?.count == 50_000)
        #expect(extracted["link"]?.attributes?["com.example.on-link"]?.count == 12)
        #expect(extracted["third-name"]?.hardLinks == ["dir/inner/original", "dir/second-name", "third-name"])
        #expect(extracted["acl-file"]?.accessControlList != nil)
        // The archive's quarantine, copied onto everything: its bytes, not a fresh one.
        for path in extracted.keys.sorted() {
            #expect(extendedAttribute("com.apple.quarantine", of: destination.appending(path: path)) == quarantine, "\(path)")
        }
        // The destination itself: not for an `.aea` (as `aa extract` does with Xcode's), yes for a plain `.aar`.
        #expect(extendedAttribute("com.apple.quarantine", of: destination) == nil)
        let fromStream = directory.path("from-stream")
        let streamFile = try AppleArchiveFile(path: FilePath(stream.path))
        defer { streamFile.close() }
        try await streamFile.extract(to: FilePath(fromStream.path), options: options)
        #expect(extendedAttribute("com.apple.quarantine", of: fromStream) == quarantine)
        #expect(extendedAttribute("com.apple.quarantine", of: reference) != nil)
        #expect(try readTree(fromStream, including: parts, ignoringAttributes: ignored) == expected)
        #expect(try readTree(fromStream, including: .attributes).values.allSatisfy { $0.attributes?["com.apple.quarantine"] == quarantine })

        // Without quarantine copying.
        let bare = directory.path("bare")
        options.copiesQuarantine = false
        let bareArchive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { bareArchive.close() }
        try await bareArchive.extract(to: FilePath(bare.path), options: options)
        let bareMetadata = try readTree(bare, including: parts)
        #expect(bareMetadata.values.allSatisfy { $0.attributes?["com.apple.quarantine"] == nil })
        #expect(bareMetadata == extracted)

        // Into a destination the caller opened (an app's staging directory): everything gets the destination's
        // quarantine, not the archive's, whatever `copyQuarantine` says; the directory itself is as its caller made it.
        let own = Quarantine(value: Array("0083;673e3000;Nunarchiver;".utf8))
        var stagingOptions = DestinationOptions()
        stagingOptions.quarantine = own
        let final = FilePath(directory.path("Staged").path)
        let staging = try Destination.staging(for: final, options: stagingOptions)
        options.copiesQuarantine = true
        let stagedArchive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { stagedArchive.close() }
        try await stagedArchive.extract(into: staging, options: options)
        let published = URL(filePath: try staging.publish(as: final).string)
        #expect(try readTree(published, including: parts, ignoringAttributes: ignored) == extracted)
        for path in extracted.keys.sorted() {
            #expect(extendedAttribute("com.apple.quarantine", of: published.appending(path: path)) == own.value, "\(path)")
        }
        #expect(extendedAttribute("com.apple.quarantine", of: published) == nil)
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
        let opened = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { opened.close() }
        let statistics = try await opened.extract(to: FilePath(destination.path))

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
