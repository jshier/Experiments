import BytesTestSupport
import Foundation
@testable import NativeAEA
import System
import Testing

/// What Nunarchiver asks for to match Archive Utility (off by default, as `aa extract` and `xip --expand` behave), and
/// the helpers it opens encrypted archives with. Measured against Archive Utility in NativeAEA/RESULTS.md, 2026-11-21.
@Suite struct ArchiveUtilityOptionsTests {
    /// `aa archive -d DIR` writes an entry for the root: with the option, the destination gets its mode and time.
    @Test(arguments: [false, true])
    func rootEntrySetsTheDestination(_ restores: Bool) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.path("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: source.appending(path: "one"))
        try Data("two".utf8).write(to: source.appending(path: "two"))
        try FileManager.default.setAttributes([.posixPermissions: 0o750, .modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: source.path)
        let archive = directory.path("tree.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-d", source.path, "-o", archive.path])

        // A destination that's there already, 0700, as an app's staging directory is.
        let output = directory.path("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var options = AEAExtractionOptions()
        options.restoresDestinationMetadata = restores
        try await AppleArchiveFile(path: FilePath(archive.path)).extract(to: FilePath(output.path), options: options)
        var info = stat()
        #expect(lstat(output.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == (restores ? 0o750 : 0o700))
        #expect((info.st_mtimespec.tv_sec == 1_600_000_000) == restores)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["one", "two"])
    }

    /// A `.xip`'s cpio stream records every directory's time; `xip --expand` applies none of them.
    @Test(arguments: [false, true])
    func xipDirectoriesGetTheirTimes(_ restores: Bool) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (cpio, _, _) = XIPTests.tree()
        let url = try makeXIP(pbzx(cpio, blockSize: 65_536), in: directory)
        var options = AEAExtractionOptions()
        options.restoresXIPDirectoryTimes = restores
        let output = directory.path("out")
        try await XIPArchive(path: FilePath(url.path), signature: .none).extract(to: FilePath(output.path), options: options)
        let metadata = try readMetadata(output)
        // Directories holding files, a link, and hard links (made after the directory's contents): all of them.
        for path in ["Xcode.app", "Xcode.app/Contents"] {
            #expect((metadata[path]?.modification.tv_sec == 1_700_000_000) == restores, "\(path)")
        }
        // Files' times either way; links never (as `xip --expand`, and Archive Utility).
        #expect(metadata["Xcode.app/Contents/small"]?.modification.tv_sec == 1_700_000_123)
        #expect(metadata["Xcode.app/Contents/link"]?.modification.tv_sec != 1_700_000_000)
    }

    @Test func readsTheProfileWithoutAKey() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let stream = directory.path("plain.aar")
        try Data("not really an archive, but `aea` encrypts any bytes".utf8).write(to: stream)
        func encrypt(_ name: String, _ arguments: [String]) throws -> FilePath {
            let output = directory.path(name)
            try ExternalTool.run("/usr/bin/aea", ["encrypt", "-i", stream.path, "-o", output.path] + arguments)
            return FilePath(output.path)
        }
        let key = String(repeating: "0123456789abcdef", count: 4)
        #expect(try AEAArchive.profile(at: encrypt("symmetric.aea", ["-profile", "1", "-key-value", "hex:\(key)"])) == .symmetric)
        #expect(try AEAArchive.profile(at: encrypt("password.aea", ["-profile", "5", "-password-value", "correct horse battery staple 42"])) == .scrypt)
        let keys = try SharedFixtures.keys.get()
        #expect(try AEAArchive.profile(at: FilePath(makeAEA(stream, keys: keys, in: directory).path)) == .signed)
        #expect(throws: AEAError.notAnAEAFile) { _ = try AEAArchive.profile(at: FilePath(stream.path)) }
    }

    /// A signer's public key as text: the PEM, the PEM as a one-line field leaves it, and the X9.63 point in hex.
    @Test func parsesPublicKeysFromText() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try SharedFixtures.keys.get()
        let publicKey = directory.path("public.pem")
        try ExternalTool.run("/usr/bin/openssl", ["ec", "-in", keys.privateKey.path, "-pubout", "-out", publicKey.path])
        let pem = try String(contentsOf: publicKey, encoding: .utf8)
        guard case .publicKey(let expected) = try AEASigningKey.publicKey(contentsOf: publicKey) else {
            Issue.record("not a public key")
            return
        }
        #expect(expected.count == 65)
        let hex = expected.map { String($0, radix: 16).leftPadded(to: 2) }.joined()
        for text in [pem, pem.replacing("\n", with: " "), "  \(pem)\n", hex, "hex:\(hex)"] {
            guard case .publicKey(let parsed) = try AEASigningKey.publicKey(text: text) else {
                Issue.record("not a public key: \(text)")
                continue
            }
            #expect(parsed == expected)
        }
        for text in ["", "nonsense", String(hex.dropLast(2)), "-----BEGIN PUBLIC KEY----- AAAA -----END PUBLIC KEY-----"] {
            #expect(throws: AEAError.self) { _ = try AEASigningKey.publicKey(text: text) }
        }
    }
}

extension String {
    fileprivate func leftPadded(to count: Int) -> String {
        String(repeating: "0", count: max(0, count - self.count)) + self
    }
}
