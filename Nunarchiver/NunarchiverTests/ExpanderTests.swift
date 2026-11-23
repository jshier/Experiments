import BytesTestSupport
import Disk
import DiskTestSupport
import Foundation
import System
import Testing

@testable import Nunarchiver

/// The live expander on real archives (made here with `/usr/bin/zip`, `ditto`, and `aea`), in a temporary directory of
/// each test's own: naming, the folder Archive Utility makes, passwords, and cancellation. (The publishing itself is
/// Disk's `Destination.publishUnwrapped`, tested there; the comparison with Archive Utility's output, item by item, is
/// in Disk/RESULTS.md.)
@Suite struct ExpanderTests {
    @Test func `formats by their first bytes`() {
        #expect(ArchiveFormat(magic: Array("PK\u{3}\u{4}rest".utf8)) == .zip)
        // An empty ZIP is only its end record; a spanned one starts with a data descriptor's signature.
        #expect(ArchiveFormat(magic: Array("PK\u{5}\u{6}".utf8)) == .zip)
        #expect(ArchiveFormat(magic: Array("PK\u{7}\u{8}PK\u{3}\u{4}".utf8)) == .zip)
        #expect(ArchiveFormat(magic: Array("AEA1....".utf8)) == .appleEncryptedArchive)
        #expect(ArchiveFormat(magic: Array("xar!....".utf8)) == .xip)
        #expect(ArchiveFormat(magic: Array("AA01....".utf8)) == .appleArchive)
        #expect(ArchiveFormat(magic: Array("YAA1....".utf8)) == .appleArchive)
        #expect(ArchiveFormat(magic: Array("pbze....".utf8)) == .appleArchive)
        #expect(ArchiveFormat(magic: Array("%PDF-1.7".utf8)) == nil)
        // Too short to say, or nothing at all.
        #expect(ArchiveFormat(magic: Array("PK".utf8)) == nil)
        #expect(ArchiveFormat(magic: []) == nil)
    }

    @Test func `a file's format is its first bytes', else its extension's`() async throws {
        try await withTemporaryDirectory { directory in
            func format(_ name: String, _ contents: String) throws -> ArchiveFormat {
                let file = directory.appending(path: name)
                try Data(contents.utf8).write(to: file)
                return try ArchiveFormat(detecting: FilePath(file.path))
            }
            let cases: [(name: String, contents: String, format: ArchiveFormat)] = [
                // The contents win over a wrong extension, and need none.
                ("Renamed.xip", "PK\u{3}\u{4}....", .zip),
                ("NoExtension", "AEA1....", .appleEncryptedArchive),
                // Unrecognized contents (here, none; a file shorter than any magic): the extension, in any case.
                ("Empty.zip", "", .zip),
                ("Short.AEA", "AE", .appleEncryptedArchive),
                ("Old.yaa", "....", .appleArchive),
                ("Other.aar", "....", .appleArchive),
                ("Xcode.XIP", "....", .xip),
            ]
            for (name, contents, expected) in cases {
                let detected = try format(name, contents)
                #expect(detected == expected, "\(name)")
            }

            // Neither says: a failure naming the file.
            let failure = #expect(throws: ExpansionFailure.self) { _ = try format("Notes.pdf", "%PDF-1.7") }
            #expect(failure?.description == "“Notes.pdf” isn’t a ZIP, Apple Archive, Apple Encrypted Archive, or XIP archive.")
            // A file that can't be read: the call and the system's reason.
            let missing = #expect(throws: ExpansionFailure.self) {
                _ = try ArchiveFormat(detecting: FilePath(directory.appending(path: "Missing.zip").path))
            }
            #expect(missing?.description == "open “Missing.zip”: No such file or directory")
        }
    }

    /// A file that's no archive fails with a message for the alert, and leaves nothing beside it.
    @Test func `a file that's no archive fails and leaves nothing`() async throws {
        try await withTemporaryDirectory { directory in
            let file = directory.appending(path: "Notes.txt")
            try Data("just text\n".utf8).write(to: file)
            let expander = LiveArchiveExpander()
            let id = UUID()
            #expect(expander.progress(of: id) == nil)
            let outcome = await expander.expand(file, id: id, credentials: ArchiveCredentials())
            #expect(outcome == .failed("“Notes.txt” isn’t a ZIP, Apple Archive, Apple Encrypted Archive, or XIP archive."))
            #expect(expander.progress(of: id) == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Notes.txt"])
        }
    }

    @Test func `folders are named after the archive without its extension`() {
        #expect(Expander.folderName(for: "/a/Photos.zip") == "Photos")
        #expect(Expander.folderName(for: "/a/Xcode_27.3_beta.xip") == "Xcode_27.3_beta")
        #expect(Expander.folderName(for: "/a/backup.tar.zip") == "backup.tar")
        #expect(Expander.folderName(for: "/a/README") == "README")
    }

    @Test func `one top-level item is moved out, uniquely named, and the archive stays`() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "source/Project")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("hello\n".utf8).write(to: source.appending(path: "hello.txt"))
            let archive = directory.appending(path: "Archive.zip")
            try ExternalTool.run("/usr/bin/zip", ["-qr", archive.path, "Project"], in: directory.appending(path: "source"))
            try FileManager.default.removeItem(at: directory.appending(path: "source"))

            for expected in ["Project", "Project 2", "Project 3"] {
                let outcome = await LiveArchiveExpander().expand(archive, id: UUID(), credentials: ArchiveCredentials())
                #expect(outcome == .expanded(directory.appending(path: expected)))
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(names == ["Archive.zip", "Project", "Project 2", "Project 3"])
            #expect(try Data(contentsOf: directory.appending(path: "Project 3/hello.txt")) == Data("hello\n".utf8))
        }
    }

    /// Archive Utility's folder (measured): named after the archive, 0700, with the archive's quarantine, like
    /// everything in it; AppleDouble entries are merged into their files, not extracted.
    @Test func `several top-level items go in a private, quarantined folder`() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            for name in ["a.txt", "b.txt"] {
                try Data(name.utf8).write(to: source.appending(path: name))
            }
            let note = Array("a note".utf8)
            // Unsafe (here and for the quarantine below): `setxattr` reads through a pointer. Safe: the array's own
            // storage, passed for the call with its own count.
            #expect(setxattr(source.appending(path: "a.txt").path, "com.example.note", note, note.count, 0, 0) == 0)
            let archive = directory.appending(path: "Archive.zip")
            // The folder's contents, with `__MACOSX/._a.txt` for the attribute.
            try ExternalTool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", source.path, archive.path])
            try FileManager.default.removeItem(at: source)
            let quarantine = Array("0081;673e3000;Safari;11111111-2222-3333-4444-555555555555".utf8)
            #expect(setxattr(archive.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)

            for expected in ["Archive", "Archive 2"] {
                let outcome = await LiveArchiveExpander().expand(archive, id: UUID(), credentials: ArchiveCredentials())
                let folder = directory.appending(path: expected)
                #expect(outcome == .expanded(folder))
                let item = try readItem(at: folder, including: .attributes)
                #expect(item.mode == 0o700)
                #expect(item.attributes?["com.apple.quarantine"] == quarantine)
                // Listed with `readdir`, so a `._a.txt` left behind would show.
                let tree = try readTree(folder, including: [.contents, .attributes])
                #expect(tree.keys.sorted() == ["a.txt", "b.txt"])
                #expect(tree["a.txt"]?.attributes == ["com.apple.quarantine": quarantine, "com.example.note": note])
                #expect(tree["b.txt"]?.contents == Array("b.txt".utf8))
            }
            // No staging directory is left behind.
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(names == ["Archive", "Archive 2", "Archive.zip"])
        }
    }

    @Test func `an encrypted zip asks for its password, and again for a wrong one`() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("secret\n".utf8).write(to: source.appending(path: "secret.txt"))
            let archive = directory.appending(path: "Secret.zip")
            try ExternalTool.run("/usr/bin/zip", ["-q", "-P", "sesame", archive.path, "secret.txt"], in: source)
            try FileManager.default.removeItem(at: source)
            let expander = LiveArchiveExpander()

            #expect(await expander.expand(archive, id: UUID(), credentials: ArchiveCredentials()) == .needsCredential(CredentialRequest(kind: .password)))
            let wrong = ArchiveCredentials(values: [.password: "guess"])
            #expect(await expander.expand(archive, id: UUID(), credentials: wrong) == .needsCredential(CredentialRequest(kind: .password, isRetry: true)))
            // Neither attempt left anything beside the archive.
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Secret.zip"])

            let right = ArchiveCredentials(values: [.password: "sesame"])
            #expect(await expander.expand(archive, id: UUID(), credentials: right) == .expanded(directory.appending(path: "secret.txt")))
            #expect(try Data(contentsOf: directory.appending(path: "secret.txt")) == Data("secret\n".utf8))
        }
    }

    /// `aea`'s archives: a password (profile 5), a symmetric key (profile 1), and one signed by a key of its own with
    /// no certificate chain (profile 0: the signer's public key is asked for; Archive Utility fails with "Error 22").
    @Test func `encrypted Apple archives ask for what their profile needs`() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("contents\n".utf8).write(to: source.appending(path: "file.txt"))
            let plain = directory.appending(path: "plain.aar")
            try ExternalTool.run("/usr/bin/aa", ["archive", "-d", source.path, "-o", plain.path, "-include-path", "file.txt"])
            try FileManager.default.removeItem(at: source)
            let expander = LiveArchiveExpander()
            let expanded = directory.appending(path: "file.txt")
            func expand(_ archive: URL, _ values: [CredentialKind: String]) async -> ExpansionOutcome {
                await expander.expand(archive, id: UUID(), credentials: ArchiveCredentials(values: values))
            }

            let password = directory.appending(path: "password.aea")
            try ExternalTool.run("/usr/bin/aea", ["encrypt", "-profile", "5", "-password-value", "correct horse battery staple 42", "-i", plain.path, "-o", password.path])
            #expect(await expand(password, [:]) == .needsCredential(CredentialRequest(kind: .password)))
            #expect(await expand(password, [.password: "wrong"]) == .needsCredential(CredentialRequest(kind: .password, isRetry: true)))
            #expect(await expand(password, [.password: "correct horse battery staple 42"]) == .expanded(expanded))
            try FileManager.default.removeItem(at: expanded)

            let key = String(repeating: "0123456789abcdef", count: 4)
            let symmetric = directory.appending(path: "symmetric.aea")
            try ExternalTool.run("/usr/bin/aea", ["encrypt", "-profile", "1", "-key-value", "hex:\(key)", "-i", plain.path, "-o", symmetric.path])
            #expect(await expand(symmetric, [:]) == .needsCredential(CredentialRequest(kind: .key)))
            #expect(await expand(symmetric, [.key: "not a key"]) == .needsCredential(CredentialRequest(kind: .key, isRetry: true)))
            #expect(await expand(symmetric, [.key: String(key.reversed())]) == .needsCredential(CredentialRequest(kind: .key, isRetry: true)))
            #expect(await expand(symmetric, [.key: key]) == .expanded(expanded))
            try FileManager.default.removeItem(at: expanded)

            let privateKey = directory.appending(path: "sign.pem"), publicKey = directory.appending(path: "sign.pub.pem")
            let otherKey = directory.appending(path: "other.pem"), otherPublicKey = directory.appending(path: "other.pub.pem")
            for (secret, open) in [(privateKey, publicKey), (otherKey, otherPublicKey)] {
                // A scalar with a leading zero byte makes a PEM `aea` can't parse (1 in 256): make another.
                var signed = false
                for _ in 0..<8 where !signed {
                    try ExternalTool.run("/usr/bin/openssl", ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", secret.path])
                    try ExternalTool.run("/usr/bin/openssl", ["ec", "-in", secret.path, "-pubout", "-out", open.path])
                    signed = (try? ExternalTool.run("/usr/bin/aea", ["encrypt", "-profile", "0", "-sign-priv", secret.path, "-i", plain.path, "-o", directory.appending(path: "probe.aea").path])) != nil
                }
                try #require(signed)
                try FileManager.default.removeItem(at: directory.appending(path: "probe.aea"))
            }
            let signed = directory.appending(path: "signed.aea")
            try ExternalTool.run("/usr/bin/aea", ["encrypt", "-profile", "0", "-sign-priv", privateKey.path, "-i", plain.path, "-o", signed.path])
            #expect(await expand(signed, [:]) == .needsCredential(CredentialRequest(kind: .signingPublicKey)))
            #expect(await expand(signed, [.signingPublicKey: "nonsense"]) == .needsCredential(CredentialRequest(kind: .signingPublicKey, isRetry: true)))
            let other = try String(contentsOf: otherPublicKey, encoding: .utf8)
            #expect(await expand(signed, [.signingPublicKey: other]) == .needsCredential(CredentialRequest(kind: .signingPublicKey, isRetry: true)))
            // As a one-line text field leaves a pasted PEM: its line breaks as spaces.
            let pem = try String(contentsOf: publicKey, encoding: .utf8).replacing("\n", with: " ")
            #expect(await expand(signed, [.signingPublicKey: pem]) == .expanded(expanded))

            // Nothing but the archives, the keys, and the one expansion: no staging directories.
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(names == ["file.txt", "other.pem", "other.pub.pem", "password.aea", "plain.aar", "sign.pem", "sign.pub.pem", "signed.aea", "symmetric.aea"])
        }
    }

    /// Cancelling the expansion's task (what the row's cancel button and quitting do) stops it and removes what it
    /// staged: only the archive is left.
    @Test func `cancelling stops the expansion and discards what was staged`() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            // 6,000 small files: long enough to cancel in the middle of.
            let contents = Data(repeating: 0x61, count: 2_000)
            for index in 0..<6_000 {
                try contents.write(to: source.appending(path: "file-\(index).txt"))
            }
            let archive = directory.appending(path: "Many.zip")
            try ExternalTool.run("/usr/bin/zip", ["-q", "-r", "-1", archive.path, "."], in: source)
            try FileManager.default.removeItem(at: source)

            let expander = LiveArchiveExpander()
            let id = UUID()
            let expansion = Task { await expander.expand(archive, id: id, credentials: ArchiveCredentials()) }
            // Once it's writing: cancel.
            var atCancel = ExpansionProgress()
            for _ in 0..<20_000 {
                atCancel = expander.progress(of: id) ?? ExpansionProgress()
                if atCancel.entries > 0 { break }
                try await Task.sleep(for: .microseconds(200))
            }
            expansion.cancel()
            let outcome = await expansion.value
            let entriesAtCancel = atCancel.entries
            #expect(entriesAtCancel > 0 && entriesAtCancel < 6_000, "cancelled after \(entriesAtCancel) entries")
            // A ZIP's totals come from its directory before anything is written, so the first reading with an entry
            // already has a fraction: the row's bar is determinate from then.
            #expect(atCancel.barFraction != nil, "no fraction with \(entriesAtCancel) entries written")
            #expect(outcome == .cancelled)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Many.zip"])
            #expect(expander.progress(of: id) == nil)
        }
    }

    /// A directory of the test's own, removed when `body` returns.
    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        // Resolved (`/private/var/…`): the expander reports where things went from the descriptor's own path.
        let directory = try TemporaryDirectory(prefix: "NunarchiverTests", resolvingSymbolicLinks: true)
        defer { directory.remove() }
        try await body(directory.url)
    }
}
