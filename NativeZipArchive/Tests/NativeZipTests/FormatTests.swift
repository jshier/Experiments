import Foundation
import NativeZip
import System
import Testing

// Archives from other tools (TestData/nativezip-formats, made by Fixtures/formats/make-fixtures.sh through
// `Tools/test-data fetch`): every compression method and encryption scheme NativeZip reads, prepended data,
// and the names and paths extraction has to make safe. Every entry's CRC-32 was computed by the tool that made
// it, so `verify` checks the decoders against data that doesn't come from them.

private func fixture(_ name: String) throws -> ZipArchive {
    try ZipArchive(url: testDataFile("nativezip-formats", name))
}

/// A fresh directory for one test's output, removed by the caller.
private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "NativeZipTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func contents(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// Runs /usr/bin/zip in `directory` with `arguments`.
private func zip(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/zip")
    process.arguments = ["-q"] + arguments
    process.currentDirectoryURL = directory
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
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
        var bytes = try [UInt8](Data(contentsOf: testDataFile("nativezip-formats", "bsdtar-aes256.zip")))
        let archive = try fixture("bsdtar-aes256.zip")
        // Flip a byte of ciphertext: after the local header, its name, the 16-byte salt and 2-byte verifier.
        let header = Int(archive.entries[0].localHeaderOffset)
        let nameLength = Int(bytes[header + 26]) | Int(bytes[header + 27]) << 8
        let extraLength = Int(bytes[header + 28]) | Int(bytes[header + 29]) << 8
        bytes[header + 30 + nameLength + extraLength + 18 + 5] ^= 0x01
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
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
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failures = try await ZipExtractor.extract { extractor in
            for name in ["bzip2.zip", "xz.zip", "deflate64.zip", "symlink.zip"] {
                try extractor.add(fixture(name), to: FilePath(directory.path))
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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = ExtractionOptions()
        options.password = "secret"
        let names = ["large-zipcrypto-stored.zip", "large-zipcrypto-deflated.zip", "large-aes256-store.zip", "large-aes256-deflate.zip"]
        let failures = try await ZipExtractor.extract { extractor in
            for name in names {
                let destination = FilePath(directory.appending(path: name).path)
                _ = try extractor.add(fixture(name), to: destination, options: options)
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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failures = try await ZipExtractor.extract { extractor in
            try extractor.add(fixture("ppmd.zip"), to: FilePath(directory.appending(path: "ppmd").path))
            try extractor.add(fixture("zipcrypto.zip"), to: FilePath(directory.appending(path: "crypto").path))
            try extractor.add(fixture("bzip2.zip"), to: FilePath(directory.appending(path: "bzip2").path))
        }
        #expect(failures.count == 2)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "bzip2/sample.txt").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "ppmd/sample.txt").path))
    }

    /// A stored entry big enough to be copied in pieces, intact and then with one byte changed.
    @Test func copiesLargeStoredEntriesInPieces() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var rng = SplitMix64(state: 11)
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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var text = [UInt8]()
        var rng = SplitMix64(state: 3)
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
}
