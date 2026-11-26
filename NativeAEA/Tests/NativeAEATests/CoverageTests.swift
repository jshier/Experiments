import BytesTesting
import BytesTestSupport
import DiskTestSupport
import Foundation
import NativeAEA
import System
import Testing

/// The archive-coverage set (`Tools/test-data fetch archive-coverage`, made by Disk/Fixtures/archive-coverage): one
/// deterministic tree with every case an extraction meets (many small files, large ones, 24 levels, long and Unicode
/// names, every kind of symbolic link, hard links across directories, extended attributes and resource forks, ACLs,
/// read-only and special modes, flags, APFS-compressed files), archived by `aa` with every codec and by `aea` with every
/// profile. NativeAEA's extraction of each is compared item by item with the manifest of `aa extract`'s, made when the
/// set was generated: no Apple tool runs here.
enum Coverage {
    static let set = "archive-coverage"

    /// `aa archive` of the tree: plain, and each codec at a block size.
    static let appleArchives = [
        "tree-raw.aar", "tree-lzfse-1m.aar", "tree-lzma-256k.aar", "tree-lz4-64k.aar", "tree-zlib-4m.aar",
        "tree-lzbitmap-16k.aar", "tree-lzraven-1m.aar",
    ]
    /// `aea encrypt` of tree-raw.aar, profiles 0–5.
    static let encryptedArchives = [
        "tree-p0-lzma-1m.aea", "tree-p1-lzfse-64k.aea", "tree-p2-lz4-1m.aea", "tree-p3-zlib-256k.aea",
        "tree-p4-lzbitmap-1m.aea", "tree-p5-none-4m.aea",
    ]

    static func file(_ name: String) throws -> URL {
        try TestData.file(set: set, name: name)
    }

    static func manifest(_ name: String) throws -> TreeManifest {
        try TreeManifest(contentsOf: file(name))
    }

    /// The archive, opened with the keys its profile needs (the set keeps them beside the archives).
    static func open(_ name: String) throws -> AEAArchive {
        guard let profile = name.split(separator: "-").dropFirst().first.flatMap({ Int($0.dropFirst()) }) else {
            throw TestFailure(description: "no profile in \(name)")
        }
        let signing: AEASigningKey = [0, 2, 4].contains(profile)
            ? try AEASigningKey.publicKey(contentsOf: file("signing.pub.pem")) : .certificateChain
        let decryption: AEADecryptionKey? = switch profile {
        case 1, 2: try AEADecryptionKey.symmetric(text: String(decoding: Data(contentsOf: file("symmetric.key")), as: UTF8.self))
        case 3, 4: try AEADecryptionKey.recipientPrivateKey(contentsOf: file("recipient.pem"))
        case 5: try .password(Array(Data(contentsOf: file("password.txt"))))
        default: nil
        }
        return try AEAArchive(url: file(name), signingKey: signing, decryptionKey: decryption)
    }

    /// Extracts `name` (an `.aar` or an `.aea`) into `destination` and returns the manifest of what it made.
    static func extract(_ name: String, to destination: URL, options: AEAExtractionOptions = .init()) async throws -> TreeManifest {
        let started = Int(Date().timeIntervalSince1970)
        if name.hasSuffix(".aea") {
            let archive = try open(name)
            defer { archive.close() }
            try await archive.extract(to: FilePath(destination.path), options: options)
        } else {
            let archive = try AppleArchiveFile(path: FilePath(file(name).path))
            defer { archive.close() }
            try await archive.extract(to: FilePath(destination.path), options: options)
        }
        return try TreeManifest(of: destination, nowAfter: started)
    }

    /// The differences from `aa extract`'s tree NativeAEA keeps, each with its reason; the comparison requires exactly
    /// these, so one that goes away (or a new one) fails the test.
    ///
    /// - APFS-compressed files archived by `aa archive` carry `UF_COMPRESSED` in `FLG` but no `AFT` (the field Xcode's
    ///   archives name the codec with). `aa extract` compresses them again with its default codec; NativeAEA stores a
    ///   file compressed only as `AFT` asks (``DiskCompressionMode/archived``), so these are plain, contents equal.
    ///   (2026-11-24; NativeAEA/RESULTS.md.)
    static let expectedDifferences: Set<ManifestDifference> = Set(
        ["lzbitmap", "lzfse", "lzvn", "zlib"].flatMap { codec in
            ["fork.txt", "inline.txt", "multi-chunk.txt"].map {
                ManifestDifference(path: "compressed/\(codec)/\($0)", field: .flags, expected: "20", actual: "0")
            }
        }
    )

    /// Extracts `name` and requires exactly the expected differences from aa.json.
    static func check(_ name: String, options: AEAExtractionOptions = .init()) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let expected = try manifest("aa.json")
        let actual = try await extract(name, to: directory.path("out"), options: options)
        let differences = actual.differences(from: expected)
        #expect(Set(differences) == expectedDifferences, "\(name):\n\(differences.map(\.description).joined(separator: "\n"))")
        #expect(actual.items.count == expected.items.count, "\(name)")
    }
}

@Suite(.diskLifetimes) struct CoverageTests {
    /// One archive in the fast set: signed and encrypted (profile 2), LZ4 in 1 MiB segments.
    @Test func extractsTheCoverageTreeAsAaDoes() async throws {
        try await Coverage.check("tree-p2-lz4-1m.aea")
    }

    /// The source tree as made and `aa extract`'s tree of it are the same: everything the tree holds survives `aa`, so
    /// aa.json is the tree's whole content, not what `aa` happened to keep.
    @Test func aaKeepsEverythingTheTreeHolds() throws {
        #expect(try Coverage.manifest("aa.json") == Coverage.manifest("source.json"))
    }
}

@Suite(.bulk, .diskLifetimes) struct CoverageBulkTests {
    /// Every codec, from the plain `.aar`.
    @Test(arguments: Coverage.appleArchives)
    func extractsAppleArchives(_ name: String) async throws {
        try await Coverage.check(name)
    }

    /// Every profile.
    @Test(arguments: Coverage.encryptedArchives)
    func extractsEncryptedArchives(_ name: String) async throws {
        try await Coverage.check(name)
    }

    /// Names that differ only by case (archived on a case-sensitive volume), extracted onto this case-insensitive one.
    /// `aa extract` reports each collision and carries on (exit status 1), leaving one item per name
    /// (collisions-aa.json, made with one thread: `README.txt` with `readme.txt`'s contents, `docs/` merged into
    /// `Docs/`, the file `Name` and not the directory `name` or what's in it, the link `Link` and not the file `link`;
    /// with several threads which name wins varies). NativeAEA stops at the first collision it can't resolve, a file
    /// where a directory is (`Name` against `name/`), whether or not it may replace files: an error rather than a tree
    /// that silently lacks entries.
    @Test func refusesCollidingNames() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        for overwrite in [false, true] {
            var options = AEAExtractionOptions()
            options.overwrite = overwrite
            let destination = directory.path("out-\(overwrite)")
            do {
                _ = try await Coverage.extract("collisions.aar", to: destination, options: options)
                Issue.record("overwrite \(overwrite): extracted colliding names without an error")
            } catch let error as AEAError {
                #expect("\(error)".contains("already exists: Name"), "overwrite \(overwrite): \(error)")
            }
        }
    }

    /// One writer and one decoder, and entries made relative to opened parents.
    @Test func extractsWithOneThreadAndRelativeToParents() async throws {
        var options = AEAExtractionOptions()
        options.read.decodeThreads = 1
        options.disk.writers = 1
        options.disk.fileSystemWidth = 1
        options.relativeToParents = true
        try await Coverage.check("tree-lzma-256k.aar", options: options)
    }
}
