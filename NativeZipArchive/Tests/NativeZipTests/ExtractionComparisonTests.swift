import BytesTestSupport
// Only what's needed: Disk has an `ZipExtractionOptions` of its own.
import class Disk.ExtractionProgress
import enum Disk.DiskError
import DiskTestSupport
import Foundation
import NativeZip
import System
import Testing

/// Extraction against Info-ZIP's `unzip` (`/usr/bin/unzip`): the same tree, item for item (type, mode, size, contents,
/// modification time of files and directories, link target), from an archive `/usr/bin/zip` makes of a tree with
/// nested and read-only directories, setuid and private modes, symbolic links, a large compressible file (decoded in a
/// child task while it's written), and a stored file over 8 MiB (checksummed and written in pieces).
@Suite(.diskLifetimes) struct InfoZIPComparisonTests {
    /// The archive, made once per test in `directory`.
    private static func makeArchive(in directory: URL) throws -> URL {
        let source = directory.appending(path: "source")
        let fileManager = FileManager.default
        for path in ["a/b/c", "empty", "ro", "x"] {
            try fileManager.createDirectory(at: source.appending(path: path), withIntermediateDirectories: true)
        }
        func write(_ path: String, _ bytes: [UInt8], mode: Int = 0o644) throws {
            let url = source.appending(path: path)
            try Data(bytes).write(to: url)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try write("a/one.txt", Array("hello\n".utf8))
        try write("a/UPPER.TXT", Array("UPPER\n".utf8))
        try write("a/b/two.txt", Array("two\n".utf8))
        try write("a/text.txt", SampleBytes.text(5 << 20, seed: 7))
        var generator = SplitMix64(seed: 9)
        try write("a/b/c/big.bin", generator.bytes(9 << 20 | 4321))
        try write("x/suid.sh", Array("#!/bin/sh\n".utf8), mode: 0o4755)
        try write("x/private.txt", Array("private\n".utf8), mode: 0o600)
        try write("ro/file.txt", Array("ro\n".utf8), mode: 0o444)
        try fileManager.createSymbolicLink(atPath: source.appending(path: "link").path, withDestinationPath: "a/one.txt")
        try fileManager.createSymbolicLink(atPath: source.appending(path: "a/b/c/rel").path, withDestinationPath: "../two.txt")
        let old = Date(timeIntervalSince1970: 1_577_934_245)
        for path in ["a/one.txt", "a/text.txt", "a/b", "empty", "x"] {
            try fileManager.setAttributes([.modificationDate: old], ofItemAtPath: source.appending(path: path).path)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.appending(path: "a/b").path)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.appending(path: "ro").path)
        let archive = directory.appending(path: "tree.zip")
        // `-y`: links as links; `-n .bin`: the random file stored.
        try ExternalTool.run("/usr/bin/zip", ["-qry", "-n", ".bin", archive.path, "."], in: source)
        return archive
    }

    /// Every item under `root` by relative path, not following links: type, mode, size, contents, modification time
    /// (to the second), link target. Links' times aren't compared (neither tool sets them).
    private static func tree(_ root: URL) throws -> [String: TreeItem] {
        try readTree(root, including: [.contents, .size, .modification]).mapValues { item in
            var item = item
            item.modification = item.kind == .symbolicLink ? nil : item.modification.map { TreeItem.Time(seconds: $0.seconds) }
            return item
        }
    }

    @Test(arguments: [[String](), ["-K"], ["-LL"], ["-X"]])
    func matchesUnzip(_ flags: [String]) async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let archive = try Self.makeArchive(in: temporary.url)
        let reference = temporary.url.appending(path: "unzip")
        try ExternalTool.run("/usr/bin/unzip", ["-q"] + flags + [archive.path, "-d", reference.path], in: temporary.url)

        var options = ZipExtractionOptions()
        options.keepsSpecialBits = flags.contains("-K")
        options.lowercaseNames = flags.contains("-LL") ? .all : .none
        options.restoresOwnership = flags.contains("-X")
        let output = temporary.url.appending(path: "native")
        try await ZipArchive(url: archive).extract(to: FilePath(output.path), options: options)

        let expected = try Self.tree(reference)
        let actual = try Self.tree(output)
        #expect(expected.count == 16)
        #expect(Set(actual.keys) == Set(expected.keys))
        for (path, item) in expected {
            #expect(actual[path] == item, "\(path): unzip \(item), NativeZip \(actual[path].map(\.description) ?? "missing")")
        }
    }
}

@Suite(.diskLifetimes) struct ExtractionProgressTests {
    private static func fixture(_ name: String) throws -> ZipArchive {
        try ZipArchive(url: TestData.file(set: "nativezip-formats", name: name))
    }

    /// The totals come from the central directories as archives are added; every entry and byte is counted once.
    @Test func countsEveryEntryAndByte() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let progress = ExtractionProgress()
        let archives = try ["symlink.zip", "zstd-large.zip", "bzip2-large.zip"].map(Self.fixture)
        let failures = try await ZipExtractor.extract(into: FilePath(temporary.url.path), progress: progress) { (extractor) async throws(ZipError) in
            for (index, archive) in archives.enumerated() {
                try await extractor.add(archive, into: FilePath("\(index)"))
            }
        }
        #expect(failures.isEmpty)
        let entries = archives.reduce(0) { $0 + $1.entries.count }
        let bytes = archives.reduce(0) { $0 + $1.entries.filter { $0.kind == .file }.reduce(0) { $0 + Int($1.uncompressedSize) } }
        #expect(progress.expectedEntries == entries)
        #expect(progress.expectedBytes == bytes)
        #expect(progress.entries == entries)
        #expect(progress.bytes == bytes)
        #expect(progress.fractionCompleted == 1)
    }

    /// Entries planning skips come off the totals, so a finished extraction reads complete.
    @Test func skippedEntriesLeaveTheTotals() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let progress = ExtractionProgress()
        var options = ZipExtractionOptions()
        options.overwrite = .never
        options.progress = progress
        try await Self.fixture("duplicates.zip").extract(to: FilePath(temporary.url.path), options: options)
        #expect(progress.entries == progress.expectedEntries)
        #expect(progress.bytes == progress.expectedBytes)
        #expect(progress.fractionCompleted == 1)
    }

    /// An archive's subdirectory is a path inside the destination, checked like an entry's.
    @Test func refusesSubdirectoriesOutside() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let archive = try Self.fixture("symlink.zip")
        for subdirectory in ["../out", "/tmp/out", "a/../../out"] {
            // Disk's refusal, as Disk threw it.
            let error = await #expect(throws: ZipError.self) {
                _ = try await ZipExtractor.extract(into: FilePath(temporary.url.path)) { (extractor) async throws(ZipError) in
                    try await extractor.add(archive, into: FilePath(subdirectory))
                }
            }
            if case .disk(.unsafePath)? = error {} else { Issue.record("\(subdirectory): \(String(describing: error))") }
        }
    }
}
