import BytesTestSupport
import Disk
import Foundation
import NativeZip
import System
import Testing

// Archives from other tools (TestData/nativezip-formats, made by Fixtures/formats/make-fixtures.sh through
// `Tools/test-data fetch`): every compression method and encryption scheme NativeZip reads, prepended data,
// and the names and paths extraction has to make safe. Every entry's CRC-32 was computed by the tool that made
// it, so `verify` checks the decoders against data that doesn't come from them.

private func fixture(_ name: String) throws -> ZipArchive {
    try ZipArchive(url: TestData.file(set: "nativezip-formats", name: name))
}

private func contents(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// Runs /usr/bin/zip in `directory` with `arguments`.
private func zip(_ arguments: [String], in directory: URL) throws {
    try ExternalTool.run("/usr/bin/zip", ["-q"] + arguments, in: directory)
}

@Suite struct FormatTests {
    @Test(arguments: ["bzip2.zip", "bzip2-large.zip", "lzma.zip", "xz.zip", "deflate64.zip", "zipcrypto.zip", "bsdtar-traditional.zip",
                      "bsdtar-aes128.zip", "bsdtar-aes256.zip", "prefixed.zip", "prefixed-adjusted.zip",
                      "large-zipcrypto-stored.zip", "large-zipcrypto-deflated.zip", "large-aes256-store.zip", "large-aes256-deflate.zip",
                      "zstd.zip", "zstd-large.zip", "zstd-zipcrypto.zip"])
    func decodesAndVerifies(name: String) async throws {
        let archive = try fixture(name)
        for backend in [ZipDecoder.Backend.bytes, .zlib] {
            let failures = await archive.verify(backend: backend, password: "secret")
            #expect(failures.isEmpty, "\(name): \(failures.map(\.error))")
        }
    }

    @Test func recognizesMethodsAndEncryption() throws {
        #expect(try fixture("deflate64.zip").entries[0].method == ZipArchive.Method.deflate64)
        #expect(try fixture("bzip2.zip").entries[0].method == ZipArchive.Method.bzip2)
        #expect(try fixture("xz.zip").entries[0].method == ZipArchive.Method.xz)
        #expect(try fixture("zstd.zip").entries[0].method == ZipArchive.Method.zstd)
        #expect(try fixture("zipcrypto.zip").entries[0].encryption == .traditional)
        // AES entries report the real method, not 99. bsdtar writes AE-2 (no CRC) for small entries.
        let aes = try fixture("bsdtar-aes256.zip").entries[0]
        #expect(aes.method == ZipArchive.Method.deflated)
        if case let .aes(bits, _) = aes.encryption { #expect(bits == 256) } else { Issue.record("not AES: \(String(describing: aes.encryption))") }
    }

    @Test func rejectsUnsupportedMethods() async throws {
        let failures = try await fixture("ppmd.zip").verify()
        guard case ZipError.unsupportedMethod(98, _)? = failures.first?.error as? ZipError else {
            Issue.record("expected unsupportedMethod(98): \(failures)")
            return
        }
    }

    @Test(arguments: ["zipcrypto.zip", "bsdtar-traditional.zip", "bsdtar-aes128.zip", "bsdtar-aes256.zip"])
    func checksPasswords(name: String) async throws {
        let archive = try fixture(name)
        let entry = archive.entries[0]
        #expect(archive.passwordMatches("secret", for: entry))
        #expect(!archive.passwordMatches("wrong!", for: entry))

        let missing = await archive.verify()
        #expect(missing.count == 1)
        if case ZipError.passwordRequired? = missing.first?.error as? ZipError {} else { Issue.record("\(missing)") }
        // A wrong password fails its check (or, once in 256 tries for the traditional cipher, the CRC-32).
        let wrong = await archive.verify(password: "wrong!")
        #expect(wrong.count == 1)
    }

    @Test func detectsTamperedAESData() async throws {
        var bytes = try [UInt8](Data(contentsOf: TestData.file(set: "nativezip-formats", name: "bsdtar-aes256.zip")))
        let archive = try fixture("bsdtar-aes256.zip")
        // Flip a byte of ciphertext: after the local header, its name, the 16-byte salt and 2-byte verifier.
        let header = Int(archive.entries[0].localHeaderOffset)
        let nameLength = Int(bytes[header + 26]) | Int(bytes[header + 27]) << 8
        let extraLength = Int(bytes[header + 28]) | Int(bytes[header + 29]) << 8
        bytes[header + 30 + nameLength + extraLength + 18 + 5] ^= 0x01
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let directory = temporary.url
        let tampered = directory.appending(path: "tampered.zip")
        try Data(bytes).write(to: tampered)

        let failures = try await ZipArchive(url: tampered).verify(password: "secret")
        if case ZipError.authenticationFailed? = failures.first?.error as? ZipError {} else { Issue.record("\(failures)") }
    }

    @Test func findsPrependedData() throws {
        #expect(try fixture("prefixed.zip").leadingByteCount == 5000)
        #expect(try fixture("prefixed-adjusted.zip").leadingByteCount == 0)
    }

    @Test func decodesNames() throws {
        #expect(try fixture("unicode-path.zip").entries.map(\.path) == ["café.txt"])
        #expect(try fixture("dos-backslash.zip").entries.map(\.path) == ["dir/sub/dos.txt"])
    }
}

@Suite struct ExtractionTests {
    @Test func makesUnsafePathsSafe() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let directory = temporary.url
        var adjusted: [String] = []
        var options = ExtractionOptions()
        options.onEvent = { event in
            if case let .pathAdjusted(_, path) = event { adjusted.append(path.string) }
        }
        try await fixture("unsafe-paths.zip").extract(to: FilePath(directory.path), options: options)

        #expect(adjusted == ["abs/root.txt", "escape.txt", "a/b/inner.txt"])
        #expect(try contents(directory.appending(path: "abs/root.txt")) == "absolute\n")
        #expect(try contents(directory.appending(path: "escape.txt")) == "escape\n")
        #expect(try contents(directory.appending(path: "a/b/inner.txt")) == "inner\n")
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appending(path: "escape.txt").path))
    }

    @Test func resolvesDuplicateNames() async throws {
        for (policy, expected) in [(OverwritePolicy.always, "second\n"), (.never, "first\n")] {
            let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
            defer { temporary.remove() }
            let directory = temporary.url
            var options = ExtractionOptions()
            options.overwrite = policy
            var skipped = 0
            options.onEvent = { if case .skipped = $0 { skipped += 1 } }
            try await fixture("duplicates.zip").extract(to: FilePath(directory.path), options: options)
            #expect(try contents(directory.appending(path: "same.txt")) == expected)
            #expect(skipped == (expected == "first\n" ? 2 : 0))
        }
    }

    @Test func extractsSeveralArchivesTogether() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let directory = temporary.url
        let failures = try await ZipExtractor.extract(into: FilePath(directory.path)) { extractor in
            for name in ["bzip2.zip", "xz.zip", "deflate64.zip", "symlink.zip"] {
                try await extractor.add(fixture(name))
            }
        }
        #expect(failures.isEmpty, "\(failures)")
        // bzip2.zip and xz.zip both hold sample.txt: the later archive's is kept.
        #expect(try Data(contentsOf: directory.appending(path: "sample.txt")).count == 300_000)
        #expect(try Data(contentsOf: directory.appending(path: "deflate64.bin")).count > 2_000_000)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: directory.appending(path: "link").path) == "dir/target.txt")
    }

    /// Large encrypted entries, decrypted in pieces as they're extracted (the 5 MB entries take the pipelined path).
    @Test func extractsLargeEncryptedEntries() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let directory = temporary.url
        var options = ExtractionOptions()
        options.password = "secret"
        let names = ["large-zipcrypto-stored.zip", "large-zipcrypto-deflated.zip", "large-aes256-store.zip", "large-aes256-deflate.zip"]
        let failures = try await ZipExtractor.extract(into: FilePath(directory.path)) { extractor in
            for name in names {
                _ = try await extractor.add(fixture(name), into: FilePath(name), options: options)
            }
        }
        #expect(failures.isEmpty, "\(failures)")
        let expected = try Data(contentsOf: directory.appending(path: names[0]).appending(path: "large.txt"))
        #expect(expected.count == 17 * 300_000)
        for name in names.dropFirst() {
            #expect(try Data(contentsOf: directory.appending(path: name).appending(path: "large.txt")) == expected, "\(name)")
        }
    }

    @Test func collectsFailuresAndExtractsTheRest() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let directory = temporary.url
        let failures = try await ZipExtractor.extract(into: FilePath(directory.path)) { extractor in
            try await extractor.add(fixture("ppmd.zip"), into: "ppmd")
            try await extractor.add(fixture("zipcrypto.zip"), into: "crypto")
            try await extractor.add(fixture("bzip2.zip"), into: "bzip2")
        }
        #expect(failures.count == 2)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "bzip2/sample.txt").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "ppmd/sample.txt").path))
    }

    /// Small entries (written whole, in one write) whose recorded CRC-32 is wrong: the check after the last write fails
    /// the file, which is removed, and the error is the decoder's own (thrown, and in the failures).
    @Test(arguments: [["-0"], ["-9"]])
    func failsSmallEntriesAfterTheirLastWrite(_ method: [String]) async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let directory = temporary.url
        try Data(SampleBytes.text(20_000, seed: 3)).write(to: directory.appending(path: "small.txt"))
        try zip(method + ["small.zip", "small.txt"], in: directory)
        var bytes = try [UInt8](Data(contentsOf: directory.appending(path: "small.zip")))
        // The central directory's CRC-32 (what the extractor checks): 16 bytes into its header.
        let central = try #require(bytes.indices.dropLast(4).last { bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 1 && bytes[$0 + 3] == 2 })
        bytes[central + 16] ^= 0xFF
        let damaged = directory.appending(path: "damaged.zip")
        try Data(bytes).write(to: damaged)

        let out = directory.appending(path: "out")
        do {
            try await ZipArchive(url: damaged).extract(to: FilePath(out.path))
            Issue.record("no error")
        } catch {
            if case ZipError.crcMismatch? = error as? ZipError {} else { Issue.record("\(error)") }
        }
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "small.txt").path))

        let collected = directory.appending(path: "collected")
        let failures = try await ZipExtractor.extract(into: FilePath(collected.path)) { extractor in
            try await extractor.add(ZipArchive(url: damaged))
        }
        #expect(failures.count == 1)
        if case ZipError.crcMismatch? = failures.first?.error as? ZipError {} else { Issue.record("\(failures)") }
        #expect(!FileManager.default.fileExists(atPath: collected.appending(path: "small.txt").path))
    }

    /// A stored entry big enough to be copied in pieces, intact and then with one byte changed.
    @Test func copiesLargeStoredEntriesInPieces() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let directory = temporary.url
        var rng = SplitMix64(seed: 11)
        var data = [UInt8](repeating: 0, count: 40 << 20 | 12_345)
        for index in stride(from: 0, to: data.count - 8, by: 8) {
            data.withUnsafeMutableBytes { $0.storeBytes(of: rng.next(), toByteOffset: index, as: UInt64.self) }
        }
        try Data(data).write(to: directory.appending(path: "big.bin"))
        try zip(["-0", "stored.zip", "big.bin"], in: directory)

        let out = directory.appending(path: "out")
        try await ZipArchive(url: directory.appending(path: "stored.zip")).extract(to: FilePath(out.path))
        #expect(try Data(contentsOf: out.appending(path: "big.bin")) == Data(data))

        // Corrupt one byte in the last piece: the combined CRC-32 must catch it, and the file is removed.
        var archive = try [UInt8](Data(contentsOf: directory.appending(path: "stored.zip")))
        archive[archive.count - 200] ^= 0xFF
        try Data(archive).write(to: directory.appending(path: "corrupt.zip"))
        let corruptOut = directory.appending(path: "corrupt")
        await #expect(throws: ZipError.self) {
            try await ZipArchive(url: directory.appending(path: "corrupt.zip")).extract(to: FilePath(corruptOut.path))
        }
        #expect(!FileManager.default.fileExists(atPath: corruptOut.appending(path: "big.bin").path))
    }

    /// Entries over the pipelining threshold (DEFLATE and bzip2): decoded in one task, written and checksummed
    /// in another.
    @Test func pipelinesLargeEntries() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let directory = temporary.url
        var text = [UInt8]()
        var rng = SplitMix64(seed: 3)
        let words = ["zip", "entry", "pipeline", "chunk", "deflate", " ", "\n"]
        while text.count < 6 << 20 { text += Array(words.randomElement(using: &rng)!.utf8) }
        try Data(text).write(to: directory.appending(path: "text.txt"))
        try zip(["deflated.zip", "text.txt"], in: directory)

        let out = directory.appending(path: "out")
        try await ZipArchive(url: directory.appending(path: "deflated.zip")).extract(to: FilePath(out.path))
        #expect(try Data(contentsOf: out.appending(path: "text.txt")) == Data(text))

        try await fixture("bzip2-large.zip").extract(to: FilePath(out.path))
        #expect(try Data(contentsOf: out.appending(path: "large.txt")).count == 6_000_000)
    }

    /// With a quarantine, everything extracted gets the attribute (files, read-only ones too; listed directories;
    /// parents the archive doesn't list; symbolic links themselves), the destination doesn't, and contents and modes
    /// are as without one. Through `ZipArchive.extract`'s option and `ZipExtractor`'s parameter.
    @Test(arguments: [false, true]) func quarantinesWhatItExtracts(listsDirectories: Bool) async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipTests")
        defer { temporary.remove() }
        let directory = temporary.url
        let tree = directory.appending(path: "tree")
        try FileManager.default.createDirectory(at: tree.appending(path: "a/b"), withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: tree.appending(path: "a/b/one.txt"))
        try Data("read only\n".utf8).write(to: tree.appending(path: "a/locked.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tree.appending(path: "a/locked.txt").path)
        try Data("top\n".utf8).write(to: tree.appending(path: "top.txt"))
        try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "a/link").path, withDestinationPath: "b/one.txt")
        // `-y`: links as links; `-D`: no directory entries, so `a` and `a/b` are made only as their files' parents.
        try zip(["-r", "-y"] + (listsDirectories ? [] : ["-D"]) + ["../q.zip", "."], in: tree)
        let archive = try ZipArchive(url: directory.appending(path: "q.zip"))
        #expect(archive.entries.contains { $0.kind == .directory } == listsDirectories)

        let quarantine = Quarantine(value: Array("0083;673e3000;Safari;".utf8))
        func attribute(_ url: URL) -> [UInt8]? {
            let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return nil }
            var value = [UInt8](repeating: 0, count: size)
            _ = getxattr(url.path, "com.apple.quarantine", &value, size, 0, XATTR_NOFOLLOW)
            return value
        }
        func mode(_ url: URL) -> mode_t {
            var info = stat()
            return lstat(url.path, &info) == 0 ? info.st_mode & 0o7777 : 0
        }
        let items = ["a", "a/b", "a/b/one.txt", "a/locked.txt", "a/link", "top.txt"]

        let plain = directory.appending(path: "plain")
        try await archive.extract(to: FilePath(plain.path))
        for item in items { #expect(attribute(plain.appending(path: item)) == nil, "\(item)") }

        var options = ExtractionOptions()
        options.quarantine = quarantine
        let single = directory.appending(path: "single")
        try await archive.extract(to: FilePath(single.path), options: options)
        let pooled = directory.appending(path: "pooled")
        let failures = try await ZipExtractor.extract(into: FilePath(pooled.path), quarantine: quarantine) { extractor in
            try await extractor.add(archive, into: "x/y")
        }
        #expect(failures.isEmpty)
        for (root, prefix) in [(single, ""), (pooled, "x/y/")] {
            for item in items {
                let url = root.appending(path: prefix + item)
                #expect(attribute(url) == quarantine.value, "\(prefix)\(item)")
                #expect(mode(url) == mode(plain.appending(path: item)), "\(prefix)\(item)")
            }
            #expect(attribute(root) == nil)
            #expect(try contents(root.appending(path: prefix + "a/locked.txt")) == "read only\n")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(path: prefix + "a/link").path) == "b/one.txt")
        }
        // The subdirectory the archive went into was made on the way too.
        #expect(attribute(pooled.appending(path: "x")) == quarantine.value && attribute(pooled.appending(path: "x/y")) == quarantine.value)
    }
}
