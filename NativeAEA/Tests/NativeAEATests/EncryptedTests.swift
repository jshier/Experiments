import Bytes
import BytesTestSupport
import Foundation
import NativeAEA
import System
import Testing

/// The encrypted profiles (1–5), on archives Apple's `aea` makes at test time: decrypted to a file and compared
/// with the input, partial ranges, wrong keys, and extraction from an encrypted Apple Archive.
@Suite(.diskLifetimes) struct EncryptedTests {
    /// Keys for every profile: a symmetric key, a recipient key pair (SEC1 PEM, as `aea` reads them), a password.
    struct Keys {
        let symmetric: [UInt8]
        let recipientPrivate: URL
        let recipientPublic: URL
        let password = "correct horse battery staple"
        let signing: SigningKeys

        init(in directory: TemporaryDirectory) throws {
            symmetric = testBytes(32, seed: 4242, compressible: false)
            signing = try SigningKeys(in: directory)
            recipientPrivate = directory.path("recipient.pem")
            recipientPublic = directory.path("recipient.pub.pem")
            // As for signing keys: `aea` rejects a scalar whose DER shortens.
            for _ in 0..<20 {
                try ExternalTool.run("/usr/bin/openssl", ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", recipientPrivate.path])
                let text = try String(decoding: ExternalTool.output("/usr/bin/openssl", ["ec", "-in", recipientPrivate.path, "-text", "-noout"]), as: UTF8.self)
                if !text.contains("priv:\n    00:") { break }
            }
            try ExternalTool.run("/usr/bin/openssl", ["ec", "-in", recipientPrivate.path, "-pubout", "-out", recipientPublic.path])
        }

        var hex: String { symmetric.map { String(format: "%02x", $0) }.joined() }

        /// `aea encrypt` arguments for a profile's keys.
        func encryptArguments(_ profile: Int) -> [String] {
            switch profile {
            case 1: ["-key-value", "hex:\(hex)"]
            case 2: ["-key-value", "hex:\(hex)", "-sign-priv", signing.privateKey.path]
            case 3: ["-recipient-pub", recipientPublic.path]
            case 4: ["-recipient-pub", recipientPublic.path, "-sign-priv", signing.privateKey.path]
            case 0: ["-sign-priv", signing.privateKey.path]
            default: ["-password-value", password]
            }
        }

        func decryptionKey(_ profile: Int) throws -> AEADecryptionKey {
            switch profile {
            case 1, 2: .symmetric(symmetric)
            case 3, 4: try AEADecryptionKey.recipientPrivateKey(contentsOf: recipientPrivate)
            default: .password(Array(password.utf8))
            }
        }
    }

    private func encrypt(_ input: URL, profile: Int, keys: Keys, in directory: TemporaryDirectory, compression: String = "lzfse", blockSize: String = "64k") throws -> URL {
        let output = directory.path("\(input.lastPathComponent)-p\(profile)-\(compression).aea")
        try ExternalTool.run("/usr/bin/aea", ["encrypt", "-profile", String(profile), "-i", input.path, "-o", output.path, "-a", compression, "-b", blockSize]
            + keys.encryptArguments(profile))
        return output
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func decryptsEveryProfile(_ profile: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try Keys(in: directory)
        // Compressible and not, over several segments, and a size that ends mid-segment.
        let contents = testBytes(300_001, seed: 1, compressible: true) + testBytes(200_000, seed: 2, compressible: false)
        let input = directory.path("contents.bin")
        try Data(contents).write(to: input)
        for compression in ["lzfse", "copy"] {
            let url = try encrypt(input, profile: profile, keys: keys, in: directory, compression: compression)
            let key = try keys.decryptionKey(profile)
            let givenKey = try AEASigningKey.publicKey(contentsOf: keys.signing.publicKey)
            let signed = [2, 4].contains(profile)
            if !signed {
                // A key given for an unsigned archive would verify nothing: an error, not silence.
                #expect(throws: AEAError.self) { _ = try AEAArchive(url: url, signingKey: givenKey, decryptionKey: key) }
            }
            let archive = try AEAArchive(url: url, signingKey: signed ? givenKey : .certificateChain, decryptionKey: key)
            defer { archive.close() }
            #expect(archive.isEncrypted)
            #expect(archive.prologue.profile.rawValue == profile)
            #expect((archive.signer != nil) == [2, 4].contains(profile))
            // The identifier is what `aea id` prints.
            let id = try String(decoding: ExternalTool.output("/usr/bin/aea", ["id", "-i", url.path]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = archive.identifier
            #expect(String(hexadecimal: identifier.span.bytes) == id)

            let output = directory.path("out-p\(profile)-\(compression).bin")
            for threads in [1, 4] {
                var options = AEAReadOptions()
                options.decodeThreads = threads
                let statistics = try await archive.decrypt(to: FilePath(output.path), overwrite: true, options: options)
                #expect(try Array(Data(contentsOf: output)) == contents, "\(compression), \(threads)")
                #expect(statistics.unreleasedBuffers == 0)
            }
            // Ranges: inside one segment, across segments, to the end, empty.
            for range in [10..<20, 65_000..<140_000, 450_000..<500_001, 7..<7] {
                try await archive.decrypt(to: FilePath(output.path), range: range, overwrite: true)
                #expect(try Array(Data(contentsOf: output)) == Array(contents[range]), "\(range)")
            }
        }
    }

    /// Segments stored as is (`-a copy`) are read straight into their output buffers, then MACed, decrypted in place,
    /// and checked there: signed (profile 0) and encrypted (1), from positioned reads and from a mapping. Damage in a
    /// stored segment is caught by its MAC, or without MACs by its checksum.
    @Test(arguments: [0, 1])
    func decodesStoredSegments(_ profile: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try Keys(in: directory)
        let contents = testBytes(300_001, seed: 5, compressible: true)
        let input = directory.path("contents.bin")
        try Data(contents).write(to: input)
        let url = directory.path("stored-p\(profile).aea")
        try ExternalTool.run("/usr/bin/aea", ["encrypt", "-profile", String(profile), "-i", input.path, "-o", url.path, "-a", "copy", "-b", "64k", "-checksum", "sha256"]
            + keys.encryptArguments(profile))
        let signingKey: AEASigningKey = profile == 0 ? try keys.signing.signingKey : .certificateChain
        let key: AEADecryptionKey? = profile == 0 ? nil : try keys.decryptionKey(profile)
        let archive = try AEAArchive(url: url, signingKey: signingKey, decryptionKey: key)
        defer { archive.close() }
        #expect(archive.segments.count == 5)
        let allStored = archive.segments.allSatisfy(\.isStored)
        #expect(allStored)
        let output = directory.path("out.bin")
        for input in SegmentInput.allCases {
            var options = AEAReadOptions()
            options.input = input
            options.decodeThreads = 3
            let statistics = try await archive.decrypt(to: FilePath(output.path), overwrite: true, options: options)
            #expect(try Array(Data(contentsOf: output)) == contents, "\(input)")
            #expect(statistics.unreleasedBuffers == 0)
        }

        var bytes = try Data(contentsOf: url)
        bytes[archive.segments[2].fileOffset + 10] ^= 0x40
        let damagedURL = directory.path("damaged-p\(profile).aea")
        try bytes.write(to: damagedURL)
        let damaged = try AEAArchive(url: damagedURL, signingKey: signingKey, decryptionKey: key)
        defer { damaged.close() }
        for input in SegmentInput.allCases {
            var options = AEAReadOptions()
            options.input = input
            await #expect(throws: AEAError.authenticationFailed("segment 2"), "\(input)") {
                _ = try await damaged.decrypt(to: FilePath(output.path), overwrite: true, options: options)
            }
            options.verifyMACs = false
            await #expect(throws: AEAError.checksumMismatch(segment: 2), "\(input)") {
                _ = try await damaged.decrypt(to: FilePath(output.path), overwrite: true, options: options)
            }
        }
    }

    /// `-key-value` text: hex, `hex:`, and `base64:` (BytesBase64's strict decoder) give the same key, around
    /// whitespace. Base64 that Foundation took but isn't canonical (nonzero unused bits in the last character) is
    /// rejected now; unpadded Base64 is rejected, as Foundation rejected it.
    @Test func symmetricKeyText() throws {
        let key = testBytes(32, seed: 77, compressible: false)
        let hex = key.map { String(format: "%02x", $0) }.joined()
        let base64 = Data(key).base64EncodedString()
        for text in [hex, "hex:\(hex)", "base64:\(base64)", " base64:\(base64)\n"] {
            guard case let .symmetric(decoded) = try AEADecryptionKey.symmetric(text: text) else {
                Issue.record("not a symmetric key: \(text)")
                continue
            }
            #expect(decoded == key, "\(text)")
        }
        // 32 bytes: 43 characters and one "=", the last character's low 2 bits unused. Setting one: Foundation
        // decodes it to the same key, BytesBase64 rejects it.
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var characters = Array(base64)
        characters[42] = try alphabet[#require(alphabet.firstIndex(of: characters[42])) + 1]
        let nonCanonical = String(characters)
        #expect(Data(base64Encoded: nonCanonical).map(Array.init) == key)
        #expect(throws: AEAError.self) { _ = try AEADecryptionKey.symmetric(text: "base64:\(nonCanonical)") }
        #expect(throws: AEAError.self) { _ = try AEADecryptionKey.symmetric(text: "base64:\(base64.dropLast())") }
    }

    @Test(arguments: [1, 3, 5])
    func rejectsWrongKeys(_ profile: Int) throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try Keys(in: directory)
        let input = directory.path("contents.bin")
        try Data(testBytes(10_000, seed: 3, compressible: true)).write(to: input)
        let url = try encrypt(input, profile: profile, keys: keys, in: directory)
        #expect(throws: AEAError.self) { _ = try AEAArchive(url: url) }
        let wrong: AEADecryptionKey = switch profile {
        case 1: .symmetric([UInt8](repeating: 1, count: 32))
        case 3: .recipientPrivateKey(Array(testBytes(32, seed: 9, compressible: false)))
        default: .password(Array("wrong".utf8))
        }
        if profile == 3 {
            // Random bytes needn't be a P-256 scalar: a key that doesn't parse fails before any MAC.
            #expect(throws: AEAError.self) { _ = try AEAArchive(url: url, decryptionKey: wrong) }
        } else {
            // What an app asks for the key again on: its own case, not a message to match.
            #expect(throws: AEAError.incorrectKey("root header")) { _ = try AEAArchive(url: url, decryptionKey: wrong) }
        }
    }

    @Test func extractsAnEncryptedAppleArchive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let keys = try Keys(in: directory)
        var writer = ArchiveStreamWriter()
        var files: [String: [UInt8]] = [:]
        writer.directory("")
        writer.directory("dir")
        for (index, size) in [0, 10, 70_000, 300_000].enumerated() {
            let bytes = testBytes(size, seed: UInt64(index), compressible: index % 2 == 0)
            writer.file("dir/f\(index)", bytes, diskCompression: 14, flags: 0x20)
            files["dir/f\(index)"] = bytes
        }
        let stream = directory.path("tree.aar")
        try writer.write(to: stream)
        let url = try encrypt(stream, profile: 1, keys: keys, in: directory, compression: "lzma")
        let destination = directory.path("out")
        let opened = try AEAArchive(url: url, decryptionKey: .symmetric(keys.symmetric))
        defer { opened.close() }
        let statistics = try await opened.extract(to: FilePath(destination.path))
        #expect(statistics.unreleasedBuffers == 0)
        for (path, bytes) in files {
            #expect(try Array(Data(contentsOf: destination.appending(path: path))) == bytes, "\(path)")
        }
    }
}
