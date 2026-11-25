import BytesTesting
import BytesTestSupport
import DiskTestSupport
import Foundation
import NativeZip
import System
import Testing

/// The archive-coverage set (`Tools/test-data fetch archive-coverage`, made by Disk/Fixtures/archive-coverage): one
/// deterministic tree with every case an extraction meets (many small files, large ones, 24 levels, long and Unicode
/// names, every kind of symbolic link, hard links, extended attributes and resource forks, ACLs, special modes, flags,
/// APFS-compressed files), zipped by `ditto -c -k --sequesterRsrc --keepParent` and by `zip -r -y`. NativeZip's
/// extraction of each is compared item by item with the manifest of `ditto -x -k`'s, made when the set was generated:
/// no Apple tool runs here.
enum ZipCoverage {
    static let set = "archive-coverage"

    static func file(_ name: String) throws -> URL {
        try TestData.file(set: set, name: name)
    }

    static func manifest(_ name: String) throws -> TreeManifest {
        try TreeManifest(contentsOf: file(name))
    }

    /// Extracts `name` into `destination` and returns the manifest of what NativeZip made.
    static func extract(_ name: String, to destination: URL, options: sending ZipExtractionOptions = .init()) async throws -> TreeManifest {
        let started = Int(Date().timeIntervalSince1970)
        try await ZipArchive(url: file(name)).extract(to: FilePath(destination.path), options: options)
        return try TreeManifest(of: destination, nowAfter: started)
    }

    /// The source tree's root's time (make-tree.py's `EPOCH`): source.json lists what's under the root, not the root.
    static let rootTime = "1600000000.000000000"

    /// Modification times NativeZip restores as archived where `ditto -x -k`'s tree has others: for each item of
    /// `reference` (not links: neither sets their times) whose time isn't the source's to the second (ZIP keeps seconds),
    /// the difference from `ditto`'s time to the source's.
    ///
    /// - tree-ditto.zip: `ditto -x -k` sets a directory's time before it writes the files in it, so only directories
    ///   holding nothing but directories keep theirs (the rest read `now`), as Archive Utility does (AGENTS.md,
    ///   2026-11-21). NativeZip sets directories' times after their contents.
    /// - tree-zip-y.zip: `ditto -x -k` reads Info-ZIP's times an hour late (the archived local time with today's
    ///   daylight-saving offset rather than the time's own: the tree's times are in September, the set was made in
    ///   November). NativeZip reads the UTC time in Info-ZIP's extended-timestamp field. (The offset depends on the
    ///   time zone and season zip-y.json was made in, so this is computed, not listed.)
    static func timeDifferences(from reference: TreeManifest) throws -> Set<ManifestDifference> {
        var sourceTimes: [[UInt8]: String] = [Array("tree".utf8): rootTime]
        for item in try manifest("source.json").items {
            sourceTimes[Array("tree/\(item.path)".utf8)] = String(item.mtime.prefix { $0 != "." }) + ".000000000"
        }
        var differences: Set<ManifestDifference> = []
        for item in reference.items where item.type != "symbolicLink" {
            guard let time = sourceTimes[Array(item.path.utf8)], time != item.mtime else { continue }
            differences.insert(ManifestDifference(path: item.path, field: .mtime, expected: item.mtime, actual: time))
        }
        return differences
    }

    /// What NativeZip keeps different from `ditto -x -k` on tree-ditto.zip, each with its reason (the test requires
    /// exactly these):
    ///
    /// - Directories' times (``timeDifferences(from:)``).
    /// - `ditto` writes an AppleDouble file for a symbolic link's extended attributes, and `ditto -x -k` drops it;
    ///   NativeZip restores them on the link itself (Disk sets them without following it).
    /// - Paths too long for a `._` name beside them (`._` + 255 bytes, or a path past `ditto`'s limit) leave their
    ///   AppleDouble directories under `__MACOSX` in `ditto`'s tree, which NativeZip never makes (directories under
    ///   `__MACOSX` aren't extracted; their entries merge into the items).
    static var dittoDifferences: Set<ManifestDifference> {
        get throws {
            let source = try manifest("source.json")
            let link = try #require(source.items.first { $0.path == "metadata/link-with-attributes" })
            let reference = try manifest("ditto.json")
            var differences = try timeDifferences(from: reference)
            differences.insert(ManifestDifference(
                path: "tree/metadata/link-with-attributes", field: .xattrs, expected: "none",
                actual: link.xattrs!.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            ))
            for item in reference.items where item.path.hasPrefix("__MACOSX") {
                differences.insert(ManifestDifference(path: item.path, field: .missing, expected: item.description, actual: ""))
            }
            return differences
        }
    }

    /// What NativeZip keeps different from `ditto -x -k` on tree-zip-y.zip: times (``timeDifferences(from:)``).
    static var infoZIPDifferences: Set<ManifestDifference> {
        get throws { try timeDifferences(from: manifest("zip-y.json")) }
    }

    static func check(_ name: String, against manifestName: String, expected: Set<ManifestDifference>,
                      options: sending ZipExtractionOptions = .init()) async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { directory.remove() }
        let actual = try await extract(name, to: directory.path("out"), options: options)
        let differences = try actual.differences(from: manifest(manifestName))
        #expect(Set(differences) == expected, "\(name):\n\(differences.map(\.description).joined(separator: "\n"))")
    }
}

@Suite(.diskLifetimes) struct ZipCoverageTests {
    /// `ditto`'s archive: AppleDouble entries under `__MACOSX` merged back (attributes, resource forks, ACLs, Finder
    /// info), Unicode names as stored, links, read-only directories.
    @Test func extractsDittosArchiveAsDittoDoes() async throws {
        try await ZipCoverage.check("tree-ditto.zip", against: "ditto.json", expected: ZipCoverage.dittoDifferences)
    }
}

@Suite(.bulk, .diskLifetimes) struct ZipCoverageBulkTests {
    /// Info-ZIP's archive (links as links, no metadata).
    @Test func extractsInfoZIPsArchive() async throws {
        try await ZipCoverage.check("tree-zip-y.zip", against: "zip-y.json", expected: ZipCoverage.infoZIPDifferences)
    }

    /// Names that differ only by case, zipped on a case-sensitive volume, extracted onto this case-insensitive one.
    /// `ditto -x -k` reports the collisions and carries on (exit status 1), leaving a tree that mixes both names'
    /// items and modes 0600/0700 (collisions-ditto.json, collisions-zip-y.json). NativeZip replaces files it may (the
    /// default overwrite policy) but stops at a file where a directory is (`Name` against `name/`): an error, rather
    /// than a tree that silently lacks entries.
    @Test(arguments: ["collisions-ditto.zip", "collisions-zip-y.zip"])
    func refusesCollidingNames(_ name: String) async throws {
        let directory = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { directory.remove() }
        do {
            _ = try await ZipCoverage.extract(name, to: directory.path("out"))
            Issue.record("\(name): extracted colliding names without an error")
        } catch let error as ZipError {
            #expect("\(error)".contains("Already exists: collisions/Name"), "\(name): \(error)")
        }
    }

    /// The same with one writer.
    @Test func extractsDittosArchiveWithOneWriter() async throws {
        var options = ZipExtractionOptions()
        options.maxConcurrency = 1
        try await ZipCoverage.check("tree-ditto.zip", against: "ditto.json", expected: ZipCoverage.dittoDifferences, options: options)
    }
}
