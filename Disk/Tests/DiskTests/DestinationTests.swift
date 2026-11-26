import BytesAsync
import BytesTesting
import BytesTestSupport
import Darwin
import Disk
import DiskTestSupport
import Foundation
import System
import Testing

/// Every entry kind and metadata item through the synchronous API (``Destination``, ``FileWriter``), and the call
/// ordering rules.
@Suite(.diskLifetimes) struct DestinationTests {
    @Test func writesFilesWithParentsModesAndTimes() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.permissions = .exact
        let destination = try Destination(directory.filePath("out"), options: options)
        defer { destination.close() }
        var writer = FileWriter(destination)
        let bytes = testBytes(10_000, seed: 1, compressible: true)
        let times = EntryTimes(modification: Timestamp(seconds: 1_000_000_000, nanoseconds: 123), creation: Timestamp(seconds: 900_000_000))
        try withPath("a/b/c.txt") { path in
            try writer.writeFile(path, contents: bytes.span.bytes, metadata: EntryMetadata(mode: 0o640, times: times))
        }
        let url = directory.path("out/a/b/c.txt")
        let item = try readItem(at: url)
        #expect(item.contents == bytes)
        #expect(item.mode == 0o640)
        let info = stat(url)!
        #expect(info.st_mtimespec.tv_sec == 1_000_000_000 && info.st_mtimespec.tv_nsec == 123)
        #expect(info.st_birthtimespec.tv_sec == 900_000_000)
    }

    @Test func appliesTheUmaskWithoutChangingIt() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let mask = getumask()
        let destination = try Destination(directory.filePath("out"))
        defer { destination.close() }
        var writer = FileWriter(destination)
        try withPath("f") { try writer.writeFile($0, contents: ([1, 2, 3] as [UInt8]).span.bytes, metadata: EntryMetadata(mode: 0o777)) }
        #expect(try readItem(at: directory.path("out/f")).mode == 0o777 & ~UInt16(mask))
        #expect(getumask() == mask)
    }

    @Test(arguments: [false, true])
    func stripsSpecialBitsUnlessKept(_ keep: Bool) throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.permissions = .exact
        options.keepsSpecialBits = keep
        let destination = try Destination(directory.filePath("out"), options: options)
        defer { destination.close() }
        var writer = FileWriter(destination)
        try withPath("setuid") { try writer.writeFile($0, contents: ([1] as [UInt8]).span.bytes, metadata: EntryMetadata(mode: 0o4755)) }
        try withPath("sticky-dir") { try destination.makeDirectory($0, metadata: EntryMetadata(mode: 0o1777)) }
        try withPath("sticky-dir") { try destination.finishDirectory($0, metadata: EntryMetadata(mode: 0o1777)) }
        #expect(try readItem(at: directory.path("out/setuid")).mode == (keep ? 0o4755 : 0o755))
        #expect(try readItem(at: directory.path("out/sticky-dir")).mode == (keep ? 0o1777 : 0o777))
    }

    @Test func ignoresOwnersUnlessRootAndAsked() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.restoresOwnership = true
        let destination = try Destination(directory.filePath("out"), options: options)
        defer { destination.close() }
        var writer = FileWriter(destination)
        // Root's own file: as a user, the owner isn't restored (and isn't an error).
        try withPath("owned") { try writer.writeFile($0, contents: ([1] as [UInt8]).span.bytes, metadata: EntryMetadata(owner: Owner(user: 0, group: 0))) }
        let info = stat(directory.path("out/owned"))!
        if geteuid() != 0 { #expect(info.st_uid == geteuid()) } else { #expect(info.st_uid == 0) }
    }

    /// `UF_COMPRESSED` sets the modification time to now when set by `fchflags`: in Disk's one `fsetattrlist` the
    /// archived time stays, for every codec and form; and locking flags don't stop the times.
    @Test(arguments: [StoragePolicy.appleArchive, .appleArchiveLZFSE, .lzvnForks, .zlibInline])
    func timesSurviveFlags(_ policy: StoragePolicy) throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let destination = try Destination(directory.filePath("out"))
        defer { destination.close() }
        var writer = FileWriter(destination)
        let times = EntryTimes(modification: Timestamp(seconds: 1_234_567_890, nanoseconds: 5))
        for (name, size) in [("small", 2_000), ("fork", 300_000), ("batches", 1_100_000)] {
            let bytes = testBytes(size, seed: UInt64(size), compressible: true)
            let form = try withPath(name) {
                try writer.writeFile($0, contents: bytes.span.bytes, metadata: EntryMetadata(times: times, flags: UInt32(UF_HIDDEN)), storage: .compressed(policy))
            }
            let url = directory.path("out/\(name)")
            let info = stat(url)!
            #expect(info.st_mtimespec.tv_sec == 1_234_567_890, "\(name) \(form)")
            #expect(info.st_flags & UInt32(UF_HIDDEN) != 0)
            #expect(try readItem(at: url).contents == bytes, "\(name)")
            if form != .plain { #expect(info.st_flags & UInt32(UF_COMPRESSED) != 0) }
        }
        try withPath("locked") {
            try writer.writeFile($0, contents: ([1, 2] as [UInt8]).span.bytes, metadata: EntryMetadata(times: times, flags: UInt32(UF_IMMUTABLE)))
        }
        let locked = stat(directory.path("out/locked"))!
        #expect(locked.st_mtimespec.tv_sec == 1_234_567_890)
        #expect(locked.st_flags & UInt32(UF_IMMUTABLE) != 0)
        // So the directory can be removed.
        #expect(chflags(directory.path("out/locked").path, 0) == 0)
    }

    /// Flags alone (a compressed file with no times) go through `fchflags`; with attachments, the writer sets only
    /// `UF_COMPRESSED` (alone: `fchflags`, which sets the modification time to now) and the pass after the writers sets
    /// the times afterwards, in one `fsetattrlist`: the archived time stays.
    @Test func flagsAloneThenTimes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let destination = try Destination(directory.filePath("out"))
        defer { destination.close() }
        var writer = FileWriter(destination)
        let bytes = testBytes(2_000, seed: 5, compressible: true)
        let form = try withPath("bare") { try writer.writeFile($0, contents: bytes.span.bytes, storage: .compressed(.appleArchive)) }
        #expect(form == .inline)
        #expect(stat(directory.path("out/bare"))!.st_flags & UInt32(UF_COMPRESSED) != 0)
        #expect(try readItem(at: directory.path("out/bare")).contents == bytes)

        var blob = ExtendedAttributeBlob()
        blob.append(name: "com.example.tag", value: ([7] as [UInt8]).span.bytes)
        let attributes = blob.bytes
        let source = ArraySource([bytes, testBytes(300_000, seed: 6, compressible: true)])
        let times = EntryTimes(modification: Timestamp(seconds: 1_234_567_890))
        try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
            for (index, name) in ["inline", "fork"].enumerated() {
                let token = try await planFile(&planner, name, index: index, size: source.files[index].count, metadata: EntryMetadata(times: times),
                                               storage: .compressed(.appleArchive), attachments: true)
                try planner.addExtendedAttributes(attributes.span.bytes, to: token)
            }
        }
        for (index, name) in ["inline", "fork"].enumerated() {
            let url = directory.path("out/\(name)")
            let info = stat(url)!
            #expect(info.st_mtimespec.tv_sec == 1_234_567_890, "\(name)")
            #expect(info.st_flags & UInt32(UF_COMPRESSED) != 0, "\(name)")
            #expect(extendedAttribute("com.example.tag", of: url) == [7])
            #expect(try readItem(at: url).contents == source.files[index])
        }
    }

    /// A file archived read-only still gets its extended attributes (set while it's owner-writable).
    @Test func extendedAttributesOnAReadOnlyFile() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.permissions = .exact
        let destination = try Destination(directory.filePath("out"), options: options)
        defer { destination.close() }
        // Through the scheduler: attachments wait for the writers, then the mode.
        var blob = ExtendedAttributeBlob()
        blob.append(name: "com.example.tag", value: ([7, 8, 9] as [UInt8]).span.bytes)
        blob.append(name: "com.example.empty", value: [UInt8]().span.bytes)
        let attributes = blob.bytes
        let arraySource = ArraySource([Array("read only".utf8)])
        try await Extraction.run(into: destination, source: arraySource) { (planner: inout Planner<ArraySource>) throws(DiskError) in
            let token = try await planFile(&planner, "ro", index: 0, size: 9, metadata: EntryMetadata(mode: 0o444), attachments: true)
            try planner.addExtendedAttributes(attributes.span.bytes, to: token)
        }
        let url = directory.path("out/ro")
        #expect(try readItem(at: url).mode == 0o444)
        #expect(extendedAttribute("com.example.tag", of: url) == [7, 8, 9])
        #expect(extendedAttribute("com.example.empty", of: url) == [])
    }

    @Test func makesLinksAndSpecialFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.permissions = .exact
        let destination = try Destination(directory.filePath("out"), options: options)
        defer { destination.close() }
        var writer = FileWriter(destination)
        try withPath("dir/file") { try writer.writeFile($0, contents: ([1, 2, 3] as [UInt8]).span.bytes) }
        let times = EntryTimes(modification: Timestamp(seconds: 1_111_111_111))
        try withPath("dir/link") { try destination.makeSymbolicLink($0, to: Array("file".utf8).span.bytes, metadata: EntryMetadata(mode: 0o644, times: times)) }
        try withPath("dir/second") { second in try withPath("dir/file") { try destination.makeHardLink(second, to: $0) } }
        try withPath("pipe") { try destination.makeSpecialFile($0, .fifo, metadata: EntryMetadata(mode: 0o640)) }
        let link = try readItem(at: directory.path("out/dir/link"), including: .modification)
        #expect(link.kind == .symbolicLink && link.linkTarget == "file" && link.mode == 0o644 && link.modification?.seconds == 1_111_111_111)
        #expect(stat(directory.path("out/dir/second"))!.st_ino == stat(directory.path("out/dir/file"))!.st_ino)
        let pipe = try readItem(at: directory.path("out/pipe"))
        #expect(pipe.kind == .fifo && pipe.mode == 0o640)
        // Devices: refused unless allowed.
        #expect(throws: DiskError.self) { try withPath("null") { try destination.makeSpecialFile($0, .characterDevice(0x0300_0002)) } }
    }

    @Test func quarantinesEverythingAsTheArchive() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let archive = directory.path("archive.aar")
        try Data([1, 2, 3]).write(to: archive)
        let value = Array("0081;6720ab00;Safari;".utf8)
        #expect(setxattr(archive.path, "com.apple.quarantine", value, value.count, 0, 0) == 0)
        var options = DestinationOptions()
        options.quarantine = Quarantine(copyingFrom: FilePath(archive.path))
        options.quarantinesDestination = true
        #expect(options.quarantine?.value == value)
        let destination = try Destination(directory.filePath("out"), options: options)
        defer { destination.close() }
        var writer = FileWriter(destination)
        try withPath("d/f") { try writer.writeFile($0, contents: ([1] as [UInt8]).span.bytes) }
        try withPath("d") { try destination.finishDirectory($0, metadata: EntryMetadata()) }
        try withPath("d/l") { try destination.makeSymbolicLink($0, to: Array("f".utf8).span.bytes) }
        for path in ["out", "out/d", "out/d/f", "out/d/l"] {
            #expect(extendedAttribute("com.apple.quarantine", of: directory.path(path)) == value, "\(path)")
        }
    }

    @Test func existingItemPolicies() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        for policy in [ExistingItemPolicy.fail, .replace, .skip] {
            var options = DestinationOptions()
            options.existingItems = policy
            let destination = try Destination(directory.filePath("\(policy)"), options: options)
            defer { destination.close() }
            var writer = FileWriter(destination)
            try withPath("f") { try writer.writeFile($0, contents: ([1] as [UInt8]).span.bytes) }
            let result = Result { try withPath("f") { try writer.writeFile($0, contents: ([2, 2] as [UInt8]).span.bytes) } }
            let contents = try readItem(at: directory.path("\(policy)/f")).contents
            switch policy {
            case .fail:
                #expect(throws: DiskError.self) { try result.get() }
                #expect(contents == [1])
            case .replace:
                #expect(try result.get() == .plain)
                #expect(contents == [2, 2])
            case .skip:
                #expect(try result.get() == .skipped)
                #expect(contents == [1])
            }
        }
    }

    @Test func stagesAndPublishesUniquely() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let final = directory.filePath("Archive")
        var published: [String] = []
        for round in 0..<3 {
            let staging = try Destination.staging(for: final)
            #expect(staging.path.lastComponent!.string.hasPrefix(".Archive.partial-"))
            var writer = FileWriter(staging)
            try withPath("file\(round)") { try writer.writeFile($0, contents: ([UInt8(round)] as [UInt8]).span.bytes) }
            try published.append(staging.publish(as: final).lastComponent!.string)
        }
        #expect(published == ["Archive", "Archive 2", "Archive 3"])
        #expect(try readItem(at: directory.path("Archive 3/file2")).contents == [2])
        // Discarding removes the staging tree, read-only parts included.
        let staging = try Destination.staging(for: final)
        try withPath("ro") { try staging.makeDirectory($0, metadata: EntryMetadata(mode: 0o500)) }
        try withPath("ro") { try staging.finishDirectory($0, metadata: EntryMetadata(mode: 0o500)) }
        staging.discard()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == ["Archive", "Archive 2", "Archive 3"])
    }
}

@Suite(.diskLifetimes) struct ClientHooksTests {
    /// `existingItem(at:)` sees what's there, never through a link (NativeZip's freshen and "replace?" questions).
    @Test func reportsExistingItems() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let out = directory.path("out")
        try FileManager.default.createDirectory(at: out.appending(path: "dir"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: out.appending(path: "dir/file"))
        try FileManager.default.createSymbolicLink(atPath: out.appending(path: "link").path, withDestinationPath: "dir")
        let destination = try Destination(FilePath(out.path))
        defer { destination.close() }
        #expect(try withPath("dir/file") { try destination.existingItem(at: $0) }?.kind == .file)
        #expect(try withPath("dir/file") { try destination.existingItem(at: $0) }?.size == 3)
        #expect(try withPath("dir") { try destination.existingItem(at: $0) }?.kind == .directory)
        #expect(try withPath("link") { try destination.existingItem(at: $0) }?.kind == .symbolicLink)
        #expect(try withPath("missing") { try destination.existingItem(at: $0) } == nil)
        #expect(throws: DiskError.self) { try withPath("link/file") { try destination.existingItem(at: $0) } }
    }

    /// Each file's source call knows its writer, for state kept per writer (a decoder each).
    @Test func tellsTheSourceItsWriter() async throws {
        final class IndexSource: ContentSource, @unchecked Sendable {
            let seen = RelaxedCounter()
            let writers: Int
            init(writers: Int) { self.writers = writers }
            func write(_ contents: Int, to output: inout FileOutput) async throws(EntryError<Never>) {
                if output.writerIndex >= 0, output.writerIndex < writers { seen.add() }
                try await EntryError<Never>.fromDisk { () async throws(DiskError) in
                    try await output.write(([UInt8(truncatingIfNeeded: contents)] as [UInt8]).span.bytes)
                }
            }

            func release(_ contents: Int) {}
        }
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = ExtractionSettings()
        options.writers = 3
        let source = IndexSource(writers: 3)
        let destination = try Destination(directory.filePath("out"))
        try await Extraction.run(into: destination, source: source, settings: options) { (planner: inout Planner<IndexSource>) throws(DiskError) in
            for index in 0..<100 {
                _ = try await planFile(&planner, "f\(index)", index: index, size: 1)
            }
        }
        destination.close()
        #expect(source.seen.value == 100)
    }
}

/// Mappings on a volume where a truncated mapping faults (an exFAT disk image: `hdiutil`, about 2 s).
@Suite(.bulk, .diskLifetimes) struct MappingBulkTests {
    /// On exFAT, `.automatic` maps a private copy: the file truncated under it, every page still reads its bytes (the
    /// file itself mapped would raise `SIGBUS` on 675 of 676 pages past the new end: RESULTS.md, 2026-11-23).
    @Test(.timeLimit(.minutes(1))) func mapsACopyWhereTruncationFaults() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let image = directory.path("volume.dmg").path, mount = directory.path("mount").path
        try ExternalTool.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "64m", "-fs", "ExFAT", "-volname", "DiskTest", "-o", image])
        try ExternalTool.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount, image])
        defer { _ = try? ExternalTool.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount]) }
        let bytes = testBytes(16 << 20, seed: 14, compressible: false)
        let file = URL(filePath: mount).appending(path: "archive")
        try Data(bytes).write(to: file)
        let mapped = try MappedFile(path: FilePath(file.path), access: .sequential)
        #expect(mapped.isCopy)
        #expect(truncate(file.path, 4_096) == 0)
        #expect(Array(mapped.buffer(0..<mapped.count)) == bytes)
    }
}

@Suite(.diskLifetimes) struct TreeRemovalTests {
    /// Removes read-only directories, locked files, and links (not what they point at).
    @Test func removesExtractedTrees() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let outside = directory.path("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appending(path: "keep"))
        let tree = directory.path("tree")
        try FileManager.default.createDirectory(at: tree.appending(path: "a/b"), withIntermediateDirectories: true)
        try Data([1]).write(to: tree.appending(path: "a/b/locked"))
        #expect(chflags(tree.appending(path: "a/b/locked").path, UInt32(UF_IMMUTABLE)) == 0)
        try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "a/out").path, withDestinationPath: outside.path)
        #expect(chmod(tree.appending(path: "a/b").path, 0o500) == 0)
        #expect(chmod(tree.appending(path: "a").path, 0o500) == 0)
        TreeRemoval.remove(tree.path)
        #expect(!FileManager.default.fileExists(atPath: tree.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep"])
    }
}

@Suite(.diskLifetimes) struct QuarantineTests {
    /// Parents an archive doesn't list are made on the way to its files: with a quarantine they get it too (files and
    /// listed directories always did), in both directory resolutions; the destination itself only when asked.
    @Test(arguments: [DirectoryResolution.paths, .descriptors])
    func quarantinesUnlistedParents(resolution: DirectoryResolution) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let value = Array("0083;673e3000;Safari;".utf8)
        var options = DestinationOptions()
        options.quarantine = Quarantine(value: value)
        options.directoryResolution = resolution
        let destination = try Destination(directory.filePath("out"), options: options)
        defer { destination.close() }
        let source = ArraySource([[1], [2], [3]])
        let report = try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
            _ = try await planFile(&planner, "a/b/c/one", index: 0, size: 1)
            // A directory listed after its contents made it: quarantined once more, harmlessly, with its metadata.
            try withPath("a/b") { path throws(DiskError) in _ = try planner.directory(path, metadata: EntryMetadata(mode: 0o750)) }
            _ = try await planFile(&planner, "a/two", index: 1, size: 1)
            try withPath("listed") { path throws(DiskError) in _ = try planner.directory(path) }
            _ = try await planFile(&planner, "top", index: 2, size: 1)
            try withPath("x/y/link") { path throws(DiskError) in _ = try planner.symbolicLink(path, target: Array("../../top".utf8).span.bytes) }
        }
        #expect(report.files == 3 && report.directories == 2)
        for path in ["out/a", "out/a/b", "out/a/b/c", "out/a/b/c/one", "out/a/two", "out/listed", "out/top", "out/x", "out/x/y", "out/x/y/link"] {
            #expect(extendedAttribute("com.apple.quarantine", of: directory.path(path)) == value, "\(path)")
        }
        #expect(extendedAttribute("com.apple.quarantine", of: directory.path("out")) == nil)
        #expect(stat(directory.path("out/a/b")).map { $0.st_mode & 0o777 } == 0o750)
        // An unlisted parent keeps the mode `mkdir` gave it.
        #expect(stat(directory.path("out/a/b/c")).map { $0.st_mode & 0o777 } == 0o755 & ~getumask())
    }

    #if DEBUG
    /// A volume that can't hold extended attributes (`ENOTSUP`, `EOPNOTSUPP`: some network and FAT volumes) gets no
    /// quarantine, and that isn't a failure: every item is counted in the report instead (files, listed and unlisted
    /// directories, links, the destination itself). Any other error still fails the item.
    @Test(arguments: [ENOTSUP, EOPNOTSUPP, EIO])
    func quarantineOnAVolumeWithoutExtendedAttributes(_ code: Int32) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.quarantine = Quarantine(value: Array("0083;673e3000;Safari;".utf8))
        let faults = SyscallFaults(failing: [.fsetxattr: code, .setxattr: code])
        let path = directory.filePath("out")
        let outcome: (Destination, ExtractionReport)? = try await faults.run { () async throws -> (Destination, ExtractionReport)? in
            let destination = try Destination(path, options: options)
            let source = ArraySource([[1], [2], [3]])
            var settings = ExtractionSettings()
            settings.stopsOnFirstFailure = false
            let report = try await Extraction.run(into: destination, source: source, settings: settings) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                _ = try await planFile(&planner, "a/b/one", index: 0, size: 1, tag: 0)
                try withPath("a") { path throws(DiskError) in _ = try planner.directory(path, metadata: EntryMetadata(mode: 0o750)) }
                _ = try await planFile(&planner, "two", index: 1, size: 1, tag: 1)
                _ = try await planFile(&planner, "three", index: 2, size: 1, tag: 2)
                try withPath("link") { path throws(DiskError) in _ = try planner.symbolicLink(path, target: Array("two".utf8).span.bytes) }
            }
            return (destination, report)
        }
        let (destination, report) = try #require(outcome)
        defer { destination.close() }
        if code == EIO {
            // Each item fails (the files and the link; directories fail in their pass).
            #expect(!report.failures.isEmpty && report.unquarantinedItems == 0)
            #expect(report.failures.allSatisfy { $0.error == .disk(.system("setxattr quarantine", path: $0.path, Errno(rawValue: EIO))) }, "\(report.failures)")
        } else {
            // one, two, three, link, a/b, and a twice (made as a parent, then listed: quarantined both times).
            #expect(report.failures.isEmpty, "\(report.failures)")
            #expect(report.files == 3 && report.symbolicLinks == 1)
            #expect(report.unquarantinedItems == 7 && destination.unquarantinedItems == 7, "\(report.unquarantinedItems)")
            #expect(extendedAttribute("com.apple.quarantine", of: directory.path("out/two")) == nil)
            #expect(try readItem(at: directory.path("out/three")).contents == [3])
        }
        #expect(faults.injected > 0)
    }

    /// The destination itself on such a volume: opened, counted, not failed.
    @Test func quarantinedDestinationOnAVolumeWithoutExtendedAttributes() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.quarantine = Quarantine(value: Array("0083;673e3000;Safari;".utf8))
        options.quarantinesDestination = true
        let path = directory.filePath("out")
        let faults = SyscallFaults(failing: [.fsetxattr: ENOTSUP, .setxattr: ENOTSUP])
        let destination = try faults.run { try Destination(path, options: options) }
        defer { destination.close() }
        #expect(destination.unquarantinedItems == 1)
        // A client's reopened destination counts into its caller's: the app reads its staging directory's count.
        let reopened = try destination.reopened(with: options)
        try faults.run {
            try withPath("dir") { try reopened.makeDirectory($0) }
            try withPath("dir") { try reopened.finishDirectory($0, metadata: EntryMetadata()) }
        }
        reopened.close()
        #expect(destination.unquarantinedItems == 2)
    }
    #endif

    /// Without a quarantine, unlisted parents cost nothing: no attribute, no call.
    @Test func leavesUnlistedParentsAloneWithoutOne() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let destination = try Destination(directory.filePath("out"))
        defer { destination.close() }
        try await extract([("a/b/one", [1])], into: destination)
        #expect(extendedAttribute("com.apple.quarantine", of: directory.path("out/a")) == nil)
        #expect(extendedAttribute("com.apple.quarantine", of: directory.path("out/a/b/one")) == nil)
    }
}

@Suite(.diskLifetimes) struct FilesTests {
    /// A mapped file's span and buffers are the file's bytes; an empty file maps to nothing; a missing one throws
    /// `open`'s error.
    @Test func mapsFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let bytes = testBytes(100_000, seed: 7, compressible: false)
        try Data(bytes).write(to: directory.path("file"))
        try Data().write(to: directory.path("empty"))
        for access in [MappedFile.Access.random, .sequential] {
            let mapped = try MappedFile(path: directory.filePath("file"), access: access)
            #expect(mapped.count == bytes.count)
            let whole = mapped.bytes.withUnsafeBytes { Array($0) }
            #expect(whole == bytes)
            #expect(Array(mapped.buffer(1_000..<1_010)) == Array(bytes[1_000..<1_010]))
            #expect(mapped.buffer(bytes.count..<bytes.count).isEmpty)
        }
        let empty = try MappedFile(path: directory.filePath("empty"))
        #expect(empty.isEmpty && empty.bytes.isEmpty && empty.buffer(0..<0).baseAddress == nil)
        let missing = directory.filePath("missing")
        #expect(throws: DiskError.system("open", path: missing.string, .noSuchFileOrDirectory)) { _ = try MappedFile(path: missing) }
        // A prefix of an open file, whose descriptor can go once it's mapped.
        let descriptor = try FileDescriptor.open(directory.filePath("file"), .readOnly)
        let prefix = try MappedFile(descriptor, count: 4_096, access: .sequential)
        try descriptor.close()
        #expect(Array(prefix.buffer(0..<4_096)) == Array(bytes[..<4_096]))
    }

    /// A private copy holds the file's bytes as they were: truncating the file afterwards changes nothing mapped, and
    /// the copy (unlinked when made) leaves nothing behind. On APFS, `.automatic` maps the file itself.
    @Test func mapsPrivateCopies() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let bytes = testBytes(300_000, seed: 12, compressible: false)
        try Data(bytes).write(to: directory.path("file"))
        let path = directory.filePath("file")
        let copy = try MappedFile(path: path, source: .copy)
        let direct = try MappedFile(path: path)
        #expect(copy.isCopy && !direct.isCopy)
        #expect(truncate(path.string, 10) == 0)
        #expect(Array(copy.buffer(0..<copy.count)) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["file"])
        let temporary = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
        #expect(!temporary.contains { $0.hasPrefix("Disk-mapped-") })
    }

    /// A range of a file maps from any offset (not just page boundaries); ranges past the end are refused.
    @Test func mapsRanges() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let bytes = testBytes(100_000, seed: 8, compressible: false)
        try Data(bytes).write(to: directory.path("file"))
        let file = try InputFile(directory.filePath("file"))
        defer { file.close() }
        for range in [0..<100_000, 1..<2, 4_095..<4_097, 16_384..<50_000, 99_999..<100_000, 70_000..<70_000] {
            let mapped = try file.map(range: range, access: .sequential)
            #expect(mapped.count == range.count)
            #expect(mapped.bytes.withUnsafeBytes { Array($0) } == Array(bytes[range]), "\(range)")
        }
        #expect(throws: DiskError.endOfFile(file.path.string)) { _ = try file.map(range: 99_000..<100_001) }
    }

    /// The unsafe read fills memory the caller manages, as the span form does, and reports a short file.
    @Test func readsIntoRawBuffers() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let bytes = testBytes(10_000, seed: 3, compressible: false)
        try Data(bytes).write(to: directory.path("file"))
        let file = try InputFile(directory.filePath("file"))
        defer { file.close() }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 5_000, alignment: 16)
        defer { unsafe buffer.deallocate() }
        try unsafe file.read(at: 4_000, into: buffer)
        #expect(unsafe Array(buffer) == Array(bytes[4_000..<9_000]))
        #expect(throws: DiskError.endOfFile(file.path.string)) { try unsafe file.read(at: 6_000, into: buffer) }
    }

    /// An output file takes writes at any offset, refuses to replace unless asked, and truncates when it does.
    @Test func writesPlainFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.filePath("out.bin")
        let bytes = testBytes(300_000, seed: 9, compressible: false)
        do {
            let output = try OutputFile(path, replacing: false)
            #expect(output.path == path)
            try output.write(bytes.span.bytes.extracting(200_000...), at: 200_000)
            try output.write(bytes.span.bytes.extracting(..<200_000), at: 0)
            try output.write(RawSpan(), at: 5)
            try output.close()
            // Closed: writes fail with `EBADF`, and closing again is nothing.
            #expect(throws: DiskError.self) { try output.write(([1] as [UInt8]).span.bytes, at: 0) }
            try output.close()
        }
        #expect(try [UInt8](Data(contentsOf: directory.path("out.bin"))) == bytes)
        #expect(stat(directory.path("out.bin")).map { $0.st_mode & 0o777 } == 0o644 & ~getumask())
        #expect(throws: DiskError.exists(path.string)) { _ = try OutputFile(path, replacing: false) }
        do {
            let output = try OutputFile(path, replacing: true, mode: [.ownerReadWrite])
            try output.write(([1, 2, 3] as [UInt8]).span.bytes, at: 0)
            try output.close()
        }
        #expect(try [UInt8](Data(contentsOf: directory.path("out.bin"))) == [1, 2, 3])
        #expect(throws: DiskError.self) { _ = try OutputFile(directory.filePath("no/such/dir/file"), replacing: true) }
    }

    /// The destination reports its volume's case sensitivity as `pathconf` does.
    @Test func reportsCaseSensitivity() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let destination = try Destination(directory.filePath("out"))
        defer { destination.close() }
        #expect(destination.isCaseSensitive == (pathconf(directory.path("out").path, _PC_CASE_SENSITIVE) == 1))
    }
}
