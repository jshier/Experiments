import BytesTestSupport
import DiskTestSupport
import Foundation
import NativeAEA
import System
import Testing

/// The third-party conformance check: Xcode's own archives (the user's downloads in ~/Scratch, read only), extracted by
/// NativeAEA and compared item by item with what Apple's tools make of them, `aa extract` for the `.aea` and `xip
/// --expand` for the `.xip`. Opt-in and local: set `NATIVEAEA_CONFORMANCE=1`, and build release (a debug build decodes
/// Xcode's 10 GB of xz tens of times slower: a debug run hadn't finished the `.xip` after 15 minutes).
///
///     NATIVEAEA_CONFORMANCE=1 swift test --package-path NativeAEA -c release --filter XcodeConformanceTests/
///
/// The two trees never exist at once: the reference tree is extracted once, reduced to a manifest cached in
/// `TestData/local-xcode-reference/` (named for the archive and its size; delete it to make it again), and removed;
/// then NativeAEA's tree is extracted, reduced to a manifest, and removed. An expanded Xcode is several gigabytes, so
/// every extraction first requires `Tools/disk-space --check 20` (20 GB available) and fails without it, deleting
/// nothing. Each test takes a few minutes (the reference's first run, `aa extract`, the longest).
///
/// The differences NativeAEA keeps from Apple's tools are each test's table, with their reasons; the comparison
/// requires exactly those.
@Suite(.diskLifetimes) struct XcodeConformanceTests {
    static let isEnabled = ProcessInfo.processInfo.environment["NATIVEAEA_CONFORMANCE"] == "1"
    static let scratch = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Scratch")
    static let aea = scratch.appending(path: "Xcode_27.3_beta_2.aea")
    static let xip = scratch.appending(path: "Xcode_27.3_beta_2.xip")
    static let cache = TestData.directory(set: "local-xcode-reference")

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Fails unless the data volume has 20 GB available (free plus purgeable, as Finder counts it).
    static func requireSpace() throws {
        let tool = TestData.root.deletingLastPathComponent().appending(path: "Tools/disk-space").path
        try ExternalTool.run(tool, ["--check", "20", FileManager.default.temporaryDirectory.path])
    }

    /// The reference tool's manifest of `archive`: cached, or made by extracting it once.
    static func referenceManifest(of archive: URL) throws -> TreeManifest {
        let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int ?? 0
        let cached = cache.appending(path: "\(archive.lastPathComponent)-\(size).json")
        if exists(cached) { return try TreeManifest(contentsOf: cached) }
        try requireSpace()
        let directory = try TemporaryDirectory(prefix: "XcodeReference")
        defer { directory.remove() }
        let root = directory.path("tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let started = Int(Date().timeIntervalSince1970)
        if archive.pathExtension == "xip" {
            try ExternalTool.run("/usr/bin/xip", ["--expand", archive.path], in: root)
        } else {
            // `aa` derives profile 0's keys from the signing key, which it doesn't take from the archive's certificate
            // chain itself ("Main key derivation failed"): give it the leaf's public key.
            let prologue = try AEAArchive.prologue(at: FilePath(archive.path))
            guard let chain = prologue.authDataEntries?.first(where: { $0.key == AEASignature.certificateChainKey }) else {
                throw TestFailure(description: "\(archive.lastPathComponent) has no certificate chain")
            }
            let chainFile = directory.path("chain.pem")
            try Data(chain.value).write(to: chainFile)
            let key = try ExternalTool.output("/usr/bin/openssl", ["x509", "-pubkey", "-noout", "-in", chainFile.path])
            let keyFile = directory.path("signing.pub.pem")
            try Data(key).write(to: keyFile)
            try ExternalTool.run("/usr/bin/aa", ["extract", "-i", archive.path, "-d", root.path, "-sign-pub", keyFile.path])
        }
        let manifest = try TreeManifest(of: root, nowAfter: started)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try manifest.write(to: cached)
        return manifest
    }

    /// NativeAEA's manifest of `archive`, with its default options (Apple's tools' behaviour).
    static func nativeManifest(of archive: URL) async throws -> TreeManifest {
        try requireSpace()
        let directory = try TemporaryDirectory(prefix: "XcodeNative")
        defer { directory.remove() }
        let root = directory.path("tree")
        let started = Int(Date().timeIntervalSince1970)
        if archive.pathExtension == "xip" {
            let opened = try XIPArchive(path: FilePath(archive.path))
            defer { opened.close() }
            try await opened.extract(to: FilePath(root.path))
        } else {
            let opened = try AEAArchive(url: archive)
            defer { opened.close() }
            try await opened.extract(to: FilePath(root.path))
        }
        return try TreeManifest(of: root, nowAfter: started)
    }

    /// Extracts `archive` with NativeAEA and requires exactly the differences `expected` lists for the reference.
    static func check(_ archive: URL, expected: (TreeManifest) -> Set<ManifestDifference>) async throws {
        let reference = try referenceManifest(of: archive)
        let native = try await nativeManifest(of: archive)
        let differences = native.differences(from: reference)
        let expected = expected(reference)
        #expect(Set(differences) == expected, """
        \(archive.lastPathComponent): \(reference.items.count) items, \(differences.count) differences:
        \(differences.prefix(200).map(\.description).joined(separator: "\n"))
        """)
        #expect(native.items.count == reference.items.count)
    }

    /// Against `aa extract`: no differences.
    @Test(.enabled(if: isEnabled, "set NATIVEAEA_CONFORMANCE=1: local and opt-in (several GB, minutes)"),
          .enabled(if: exists(aea), "no ~/Scratch/Xcode_27.3_beta_2.aea"))
    func matchesAaExtract() async throws {
        try await Self.check(Self.aea) { _ in [] }
    }

    /// Against `xip --expand`: directories' times, and nothing else.
    ///
    /// `xip --expand` sets a directory's time before it writes what the directory holds, so only directories holding
    /// nothing but directories keep their archived times (1,874 of Xcode 27.3 beta 2's; the rest read `now`), as Archive
    /// Utility does (AGENTS.md, 2026-11-21). NativeAEA leaves every directory at its extraction time by default
    /// (``AEAExtractionOptions/restoresXIPDirectoryTimes`` restores them all): the difference is each directory whose
    /// time `xip --expand` kept, computed from the reference.
    @Test(.enabled(if: isEnabled, "set NATIVEAEA_CONFORMANCE=1: local and opt-in (several GB, minutes)"),
          .enabled(if: exists(xip), "no ~/Scratch/Xcode_27.3_beta_2.xip"))
    func matchesXipExpand() async throws {
        try await Self.check(Self.xip) { reference in
            Set(reference.items.filter { $0.type == "directory" && $0.mtime != "now" }.map {
                ManifestDifference(path: $0.path, field: .mtime, expected: $0.mtime, actual: "now")
            })
        }
    }
}
