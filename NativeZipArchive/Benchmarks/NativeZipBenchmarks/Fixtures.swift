import Bytes
import BytesTestSupport
import Foundation
@_spi(Benchmarking) import NativeZip
import zlib

/// Deterministic benchmark archives, generated once and cached in a fixed temporary directory.
enum Fixtures {
    static let version = 4
    static let root = URL(filePath: NSTemporaryDirectory()).appending(path: "NativeZipBenchmarkFixtures-v\(version)")

    static var smallFiles: URL { root.appending(path: "small.zip") } // 2,000 text files, ~4–16 KB each
    static var largeText: URL { root.appending(path: "text.zip") } // one 32 MB deflated text file
    static var largeRandom: URL { root.appending(path: "random.zip") } // one 32 MB stored (incompressible) file
    static var raster: URL { root.appending(path: "raster.zip") } // one 32 MB deflated file of pixel runs
    static var zstdText: URL { root.appending(path: "text-zstd.zip") } // the 32 MB text as Zstandard (method 93), level 3
    static var zstdRaster: URL { root.appending(path: "raster-zstd.zip") } // the 32 MB raster as Zstandard, level 3

    /// The other zip methods, each on the 32 MB text in an archive of its own (``methodArchive(_:)``).
    enum Method: String, CaseIterable, Sendable {
        case bzip2, lzma, xz, deflate64

        /// The method's name in benchmark names.
        var label: String {
            switch self {
            case .bzip2: "bzip2"
            case .lzma: "LZMA"
            case .xz: "xz"
            case .deflate64: "Deflate64"
            }
        }
    }

    /// The 32 MB text compressed with `method` (made by ``prepareMethod(_:)``, on first use).
    static func methodArchive(_ method: Method) -> URL { root.appending(path: "text-\(method.rawValue).zip") }

    /// The 32 MB text encrypted with the password ``password``, each way in an archive of its own
    /// (``encryptedArchive(_:)``).
    enum Encryption: String, CaseIterable, Sendable {
        /// ZipCrypto (the traditional cipher), deflated: Info-ZIP's `zip -P`.
        case zipCrypto
        /// ZipCrypto, stored (`zip -0 -P`): decryption and the CRC-32 alone.
        case zipCryptoStored
        /// WinZip AES-256, deflated: `bsdtar`'s.
        case aes256

        /// The row's name.
        var label: String {
            switch self {
            case .zipCrypto: "Inflate + CRC 32 MB text: ZipCrypto"
            case .zipCryptoStored: "Decrypt + CRC 32 MB text: ZipCrypto, stored"
            case .aes256: "Inflate + CRC 32 MB text: AES-256"
            }
        }
    }

    /// `small.zip`'s 2,000 files, each compressed on its own with `method` (LZMA or xz): every entry starts a stream
    /// (made by ``prepareSmallMethod(_:)``, on first use).
    static func smallMethodArchive(_ method: Method) -> URL { root.appending(path: "small-\(method.rawValue).zip") }

    /// The encrypted archives' password.
    static let password = "benchmark-secret"

    /// The 32 MB text encrypted as `encryption` says (made by ``prepareEncrypted(_:)``, on first use).
    static func encryptedArchive(_ encryption: Encryption) -> URL { root.appending(path: "text-\(encryption.rawValue).zip") }

    /// Makes `encryption`'s archive of the 32 MB text if it isn't there yet (about a second; then cached), from the text
    /// ``prepare()`` left in `source/text`: macOS's `zip` for ZipCrypto, its `bsdtar` for AES.
    static func prepareEncrypted(_ encryption: Encryption) throws {
        try prepare()
        let archive = encryptedArchive(encryption)
        if FileManager.default.fileExists(atPath: archive.path) { return }
        let partial = root.appending(path: "partial-\(encryption.rawValue).zip")
        try? FileManager.default.removeItem(at: partial)
        let directory = root.appending(path: "source/text")
        switch encryption {
        case .zipCrypto:
            try ExternalTool.run("/usr/bin/zip", ["-q", "-P", password, partial.path, "big.txt"], in: directory)
        case .zipCryptoStored:
            try ExternalTool.run("/usr/bin/zip", ["-q", "-0", "-P", password, partial.path, "big.txt"], in: directory)
        case .aes256:
            try ExternalTool.run("/usr/bin/bsdtar", ["--format", "zip", "--options", "zip:encryption=aes256", "--passphrase", password,
                                                     "-cf", partial.path, "big.txt"], in: directory)
        }
        try FileManager.default.moveItem(at: partial, to: archive)
    }

    /// 20,000 text files of 1–8 KB in 200 directories: RESULTS.md's step15 small-file job.
    static var smallFiles20k: URL { root.appending(path: "small-20k.zip") }
    /// Eight archives of one 64 MB text file each (`text0.txt` … `text7.txt`): step15's several-archives job.
    static var textArchives: [URL] { (0..<8).map { root.appending(path: "text64-\($0).zip") } }

    /// Where extraction benchmarks write: `.noindex`, so Spotlight doesn't index what they extract.
    static var output: URL { root.appending(path: "output.noindex") }

    /// A new directory (not yet created) for one sample's extraction output, inside `output`.
    static func outputDirectory() -> URL {
        output.appending(path: UUID().uuidString)
    }

    /// Removes a directory returned by `outputDirectory()`, refusing anything else.
    ///
    /// The 2,000-file benchmarks call this after every sample, outside the measurement. Leaving their files until
    /// teardown was tried: extraction then ran 1–23% slower (instructions +4–15%) as the files piled up, and deleting
    /// them all at the end (unlinked on 8 threads) took longer than deleting as it went. One 32 MB file is kept
    /// until teardown instead: deleted after every sample, some samples of `Extract 32 MB random` took 2–9x as long (the
    /// p50 went from 3.9 to 9 ms in one run); kept, one run's samples were all within 15% of the fastest (a single
    /// observation: another run, under other agents' load, still spread from 3.9 to 16 ms).
    static func remove(_ directory: URL) {
        let parent = output.standardizedFileURL.path + "/"
        guard directory.standardizedFileURL.path.hasPrefix(parent) else { fatalError("Refusing to remove \(directory.path)") }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes every sample's directory under `output` (a benchmark's teardown).
    static func removeOutput() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [] {
            remove(output.appending(path: name))
        }
    }

    /// `count` pseudo-random bytes (SplitMix64, eight bytes a step, so made quickly).
    static func randomBytes(count: Int) -> [UInt8] {
        var rng = SplitMix64(seed: UInt64(count))
        return rng.packedBytes(count)
    }

    /// Checks the `Bytes` central-directory parser against the original `ByteReader` one: the same entries and payload
    /// ranges in every fixture archive.
    static func checkParsersAgree() throws {
        for url in [smallFiles, largeText, largeRandom] {
            let archive = try ZipArchive(url: url)
            let original = try ZipArchive.entriesUsingByteReader(of: url)
            precondition(archive.entries.count == original.count)
            for (new, old) in Swift.zip(archive.entries, original) {
                let sameHeader = new.path == old.path && new.kind == old.kind && new.method == old.method && new.flags == old.flags
                let sameSizes = new.crc32 == old.crc32 && new.compressedSize == old.compressedSize
                    && new.uncompressedSize == old.uncompressedSize && new.localHeaderOffset == old.localHeaderOffset
                let sameAttributes = new.posixPermissions == old.posixPermissions && new.modificationDate == old.modificationDate
                precondition(sameHeader && sameSizes && sameAttributes, "Parsers disagree on \(new.path)")
                let payload = try archive.payloadCount(of: new)
                let originalPayload = try archive.payloadCountUsingByteReader(of: old)
                precondition(payload == originalPayload, "Payloads disagree on \(new.path)")
            }
        }
    }

    /// Makes the fixture archives if they aren't there yet (about 20 s; then cached in `root`), and the output
    /// directory. Called from `Benchmark.setup`, so only before a benchmark runs, not when they're listed.
    static func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: largeRandom.path) { return }
        try prepareOriginal()
    }

    /// Makes `method`'s archive of the 32 MB text if it isn't there yet (a few seconds for bzip2, 10–20 s for LZMA and
    /// xz; then cached), from the text ``prepare()`` left in `source/text`. No macOS tool writes these methods into zip
    /// archives: each is the compressed file stored by `zip`, its headers then patched to name the method, with the
    /// original's CRC-32 and size.
    ///
    /// - bzip2: `/usr/bin/bzip2 -9`, a whole `.bz2` stream (what method 12 stores).
    /// - LZMA: `xz --format=lzma -6` (Homebrew's xz), its 13-byte `.lzma` header replaced by the zip method's 4-byte
    ///   header and the 5 property bytes; flag bit 1 (an end marker) when the header doesn't record the size.
    /// - xz: `xz -6`, the whole `.xz` stream (method 95).
    /// - Deflate64: the DEFLATE row's own stream (`text.zip`'s), recorded as method 9. The two read a stream alike but
    ///   for length symbol 285 (258 in DEFLATE, 3 plus 16 extra bits in Deflate64) and distance codes 30 and 31 (which
    ///   DEFLATE never uses), so a stream with no match of length 258 is the same stream in both. That's checked here:
    ///   the archive is decoded through NativeZip as Deflate64 and must match the text's CRC-32 and size, or this
    ///   throws (no Deflate64 encoder is installed to make one otherwise).
    static func prepareMethod(_ method: Method) throws {
        try prepare()
        let fileManager = FileManager.default
        let archive = methodArchive(method)
        if fileManager.fileExists(atPath: archive.path) { return }
        let partial = root.appending(path: "partial-\(method.rawValue).zip")
        try? fileManager.removeItem(at: partial)
        let source = root.appending(path: "source/text/big.txt")
        if method == .deflate64 {
            try fileManager.copyItem(at: largeText, to: partial)
            try patchHeaders(of: partial, method: 9)
            var decoder = ZipDecoder()
            let check = try ZipArchive(url: partial)
            do {
                try check.contents(of: check.entries.first { $0.kind == .file }!, using: &decoder) { _ in }
            } catch {
                throw ExternalTool.Failure(description: "The text's DEFLATE stream doesn't decode as Deflate64 (a match of length 258?): \(error)")
            }
            try fileManager.moveItem(at: partial, to: archive)
            return
        }
        let work = root.appending(path: "method-work")
        try? fileManager.removeItem(at: work)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        let original = try Data(contentsOf: source)
        try original.write(to: work.appending(path: "big.txt"))
        let payload: Data
        var flags: UInt16 = 0
        switch method {
        case .bzip2:
            try ExternalTool.run("/usr/bin/bzip2", ["-9", "-k", "-f", "big.txt"], in: work)
            payload = try Data(contentsOf: work.appending(path: "big.txt.bz2"))
        case .lzma:
            try ExternalTool.run("/usr/bin/env", ["xz", "--format=lzma", "-6", "-k", "-f", "big.txt"], in: work)
            let alone = try Data(contentsOf: work.appending(path: "big.txt.lzma"))
            // `.lzma`: 5 property bytes, the size in 8 bytes (all ones: unknown, so the stream ends with a marker),
            // the stream. Zip's: LZMA SDK version 9.20, a 2-byte properties size (5), the properties, the stream.
            payload = Data([9, 20, 5, 0]) + alone.prefix(5) + alone.dropFirst(13)
            if alone[5..<13].allSatisfy({ $0 == 0xFF }) { flags = 0x2 }
        case .xz:
            try ExternalTool.run("/usr/bin/env", ["xz", "-6", "-k", "-f", "big.txt"], in: work)
            payload = try Data(contentsOf: work.appending(path: "big.txt.xz"))
        case .deflate64:
            preconditionFailure("made above")
        }
        // Stored under the original's name, then patched.
        try payload.write(to: work.appending(path: "big.txt"))
        try ExternalTool.run("/usr/bin/zip", ["-q0j", partial.path, "big.txt"], in: work)
        let crc = original.withUnsafeBytes { UInt32(crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count))) }
        try patchHeaders(of: partial, method: method == .bzip2 ? 12 : method == .lzma ? 14 : 95, flags: flags,
                         crc: crc, size: UInt32(original.count))
        try fileManager.moveItem(at: partial, to: archive)
    }

    /// Makes ``smallMethodArchive(_:)`` for `method` (LZMA or xz) if it isn't there yet (a few seconds; then cached):
    /// the small files ``prepare()`` left in `source/small`, compressed by one `xz -6` run (Homebrew's xz;
    /// `--format=lzma` for LZMA, its 13-byte header replaced by the zip method's as in ``prepareMethod(_:)``), written
    /// into a zip archive here (no macOS tool writes these methods).
    static func prepareSmallMethod(_ method: Method) throws {
        precondition(method == .lzma || method == .xz)
        try prepare()
        let fileManager = FileManager.default
        let archive = smallMethodArchive(method)
        if fileManager.fileExists(atPath: archive.path) { return }
        let source = root.appending(path: "source")
        let names = try fileManager.subpathsOfDirectory(atPath: source.appending(path: "small").path)
            .filter { $0.hasSuffix(".txt") }.sorted().map { "small/\($0)" }
        let work = root.appending(path: "small-\(method.rawValue)-work")
        try? fileManager.removeItem(at: work)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        for (index, name) in names.enumerated() {
            try fileManager.copyItem(at: source.appending(path: name), to: work.appending(path: "f\(index)"))
        }
        let format = method == .lzma ? ["--format=lzma"] : []
        try ExternalTool.run("/usr/bin/env", ["xz"] + format + ["-6", "-k", "-f"] + names.indices.map { "f\($0)" }, in: work)
        var output: [UInt8] = []
        var central: [UInt8] = []
        func le16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        for (index, name) in names.enumerated() {
            let original = try [UInt8](Data(contentsOf: work.appending(path: "f\(index)")))
            let compressed = try [UInt8](Data(contentsOf: work.appending(path: "f\(index).\(method == .lzma ? "lzma" : "xz")")))
            var payload = compressed
            var flags = 0
            if method == .lzma {
                payload = [9, 20, 5, 0] + compressed.prefix(5) + compressed.dropFirst(13)
                if compressed[5..<13].allSatisfy({ $0 == 0xFF }) { flags = 0x2 }
            }
            let crc = Int(CRC32.checksum(original.span.bytes))
            let nameBytes = Array(name.utf8)
            let fields = le16(63) + le16(flags) + le16(method == .lzma ? 14 : 95) + le16(0) + le16(0x21) + le32(crc)
                + le32(payload.count) + le32(original.count) + le16(nameBytes.count) + le16(0)
            central += le32(0x0201_4B50) + le16(0x031E) + fields + le16(0) + le16(0) + le16(0) + le32(0o100644 << 16)
                + le32(output.count) + nameBytes
            output += le32(0x0403_4B50) + fields + nameBytes + payload
        }
        let directoryOffset = output.count
        output += central + le32(0x0605_4B50) + le16(0) + le16(0) + le16(names.count) + le16(names.count)
            + le32(central.count) + le32(directoryOffset) + le16(0)
        try Data(output).write(to: archive)
    }

    /// Rewrites the last entry's method (and, if given, its CRC-32 and uncompressed size), and ORs `flags` into its
    /// general-purpose flags, in both its central directory header and its local header.
    private static func patchHeaders(of archive: URL, method: UInt16, flags: UInt16 = 0, crc: UInt32? = nil, size: UInt32? = nil) throws {
        var raw = try [UInt8](Data(contentsOf: archive))
        func load16(_ offset: Int) -> UInt16 { UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8 }
        func store<T: ByteGroup>(_ value: T.Integer, as _: T.Type, at offset: Int) {
            T(value, .littleEndian).withBytes { bytes in
                var span = raw.mutableSpan
                span.copyBytes(from: bytes, toByteOffset: offset)
            }
        }
        let central = (0..<(raw.count - 4)).last { raw[$0] == 0x50 && raw[$0 + 1] == 0x4B && raw[$0 + 2] == 1 && raw[$0 + 3] == 2 }!
        let local = Int(raw[central + 42]) | Int(raw[central + 43]) << 8 | Int(raw[central + 44]) << 16 | Int(raw[central + 45]) << 24
        precondition(raw[local] == 0x50 && raw[local + 1] == 0x4B && raw[local + 2] == 3 && raw[local + 3] == 4)
        // Local header: flags at 6, method at 8, CRC at 14, uncompressed size at 22. Central header: 8, 10, 16, 24.
        for (base, flagsOffset, methodOffset, crcOffset, sizeOffset) in [(local, 6, 8, 14, 22), (central, 8, 10, 16, 24)] {
            store(load16(base + flagsOffset) | flags, as: Byte2.self, at: base + flagsOffset)
            store(method, as: Byte2.self, at: base + methodOffset)
            if let crc { store(crc, as: Byte4.self, at: base + crcOffset) }
            if let size { store(size, as: Byte4.self, at: base + sizeOffset) }
        }
        try Data(raw).write(to: archive)
    }

    /// The step15 jobs' archives (made on first use, about 30 s, then cached): a separate seed, so the fixtures above
    /// stay as they were.
    static func prepareLarge() throws {
        let fileManager = FileManager.default
        try prepare()
        if fileManager.fileExists(atPath: textArchives.last!.path) { return }
        let source = root.appending(path: "source-large")
        try? fileManager.removeItem(at: source)
        var rng = SplitMix64(seed: 0x20_000)
        let small = source.appending(path: "small20k")
        for index in 0..<20_000 {
            let directory = small.appending(path: "dir\(index % 200)")
            if index < 200 { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
            let size = 1024 + Int(rng.next() % 7168)
            try text(byteCount: size, using: &rng).write(to: directory.appending(path: "file\(index).txt"))
        }
        try zip("small20k", into: smallFiles20k, from: source)
        let text64 = text(byteCount: 64 << 20, using: &rng)
        for (index, archive) in textArchives.enumerated() {
            let directory = source.appending(path: "text64-\(index)")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try text64.write(to: directory.appending(path: "text\(index).txt"))
            try ExternalTool.run("/usr/bin/zip", ["-qj", archive.path, "text\(index).txt"], in: directory)
            try fileManager.removeItem(at: directory)
        }
        try fileManager.removeItem(at: source)
    }

    private static func prepareOriginal() throws {
        let fileManager = FileManager.default

        let source = root.appending(path: "source")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        var rng = SplitMix64(seed: 0x5EED)

        // Many small files in nested directories.
        let small = source.appending(path: "small")
        for index in 0..<2000 {
            let directory = small.appending(path: "dir\(index % 40)/sub\(index % 7)")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = 4096 + Int(rng.next() % 12288)
            try text(byteCount: size, using: &rng).write(to: directory.appending(path: "file\(index).txt"))
        }

        let largeTextDirectory = source.appending(path: "text")
        try fileManager.createDirectory(at: largeTextDirectory, withIntermediateDirectories: true)
        try text(byteCount: 32 << 20, using: &rng).write(to: largeTextDirectory.appending(path: "big.txt"))

        let largeRandomDirectory = source.appending(path: "random")
        try fileManager.createDirectory(at: largeRandomDirectory, withIntermediateDirectories: true)
        var random = Data(count: 32 << 20)
        random.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 8) {
                buffer.storeBytes(of: rng.next(), toByteOffset: index, as: UInt64.self)
            }
        }
        try random.write(to: largeRandomDirectory.appending(path: "big.bin"))

        let rasterDirectory = source.appending(path: "raster")
        try fileManager.createDirectory(at: rasterDirectory, withIntermediateDirectories: true)
        try rasterData(byteCount: 32 << 20, using: &rng).write(to: rasterDirectory.appending(path: "big.raw"))

        try zip("small", into: smallFiles, from: source)
        try zip("text", into: largeText, from: source)
        try zip("raster", into: raster, from: source)
        try zstdZip("text", file: "big.txt", into: zstdText, from: source)
        try zstdZip("raster", file: "big.raw", into: zstdRaster, from: source)
        // Last: `prepare` checks for it to tell whether the fixtures are complete.
        try zip("random", into: largeRandom, from: source)
    }

    /// Raster-like data: runs of 1 to 40 identical pixels of 2 to 7 bytes (the width changes every 4 KB),
    /// each run a random pixel. Deflate codes a run as one pixel of literals, then a match one pixel back:
    /// the short distances that repeat a pattern, which text rarely has.
    private static func rasterData(byteCount: Int, using rng: inout SplitMix64) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(byteCount + 4096 + 300)
        while output.count < byteCount {
            let width = 2 + Int(rng.next() % 6)
            let segmentEnd = output.count + 4096
            while output.count < segmentEnd {
                let pixel = rng.next()
                for _ in 0...(rng.next() % 40) {
                    for byte in 0..<width {
                        output.append(UInt8(truncatingIfNeeded: pixel >> (8 * UInt64(byte))))
                    }
                }
            }
        }
        return Data(output.prefix(byteCount))
    }

    /// Word-salad text that compresses roughly like source code (~3–4x).
    private static func text(byteCount: Int, using rng: inout SplitMix64) -> Data {
        let words = ["func", "let", "var", "return", "struct", "import", "Foundation", "self", "init", "throws",
                     "public", "private", "extension", "guard", "else", "case", "switch", "for", "in", "while",
                     "archive", "entry", "offset", "count", "buffer", "stream", "data", "error", "value", "index"]
        var output = Data(capacity: byteCount + 32)
        while output.count < byteCount {
            let word = words[Int(rng.next() % UInt64(words.count))]
            output.append(contentsOf: word.utf8)
            output.append(rng.next() % 12 == 0 ? 0x0A : 0x20)
            if rng.next() % 50 == 0 { output.append(contentsOf: String(rng.next() % 100_000).utf8) }
        }
        return output.prefix(byteCount)
    }

    private static func zip(_ directory: String, into archive: URL, from source: URL) throws {
        try ExternalTool.run("/usr/bin/zip", ["-qr", archive.path, directory], in: source)
    }

    /// A one-entry archive of `directory/file` compressed by the `zstd` command (`brew install zstd`) at level 3:
    /// zip stores the compressed file, then its headers are patched to say method 93 with the original's CRC-32 and
    /// size (no macOS tool writes Zstandard entries).
    private static func zstdZip(_ directory: String, file: String, into archive: URL, from source: URL) throws {
        let original = try Data(contentsOf: source.appending(path: directory).appending(path: file))
        let work = root.appending(path: "zstd-work")
        try FileManager.default.createDirectory(at: work.appending(path: directory), withIntermediateDirectories: true)
        let compressed = work.appending(path: directory).appending(path: file)
        try ExternalTool.run("/usr/bin/env", ["zstd", "-q", "-3", "-f", source.appending(path: directory).appending(path: file).path, "-o", compressed.path], in: work)
        try ExternalTool.run("/usr/bin/zip", ["-q0r", archive.path, directory], in: work)
        var raw = try [UInt8](Data(contentsOf: archive))
        let crc = original.withUnsafeBytes { UInt32(crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count))) }
        func store<T: ByteGroup>(_ value: T.Integer, as _: T.Type, at offset: Int) {
            T(value, .littleEndian).withBytes { bytes in
                var span = raw.mutableSpan
                span.copyBytes(from: bytes, toByteOffset: offset)
            }
        }
        // Local header: method at 8, CRC at 14, uncompressed size at 22. Central header: 10, 16, 24.
        let central = (0..<(raw.count - 4)).last { raw[$0] == 0x50 && raw[$0 + 1] == 0x4B && raw[$0 + 2] == 1 && raw[$0 + 3] == 2 }!
        for (base, method, crcOffset, size) in [(0, 8, 14, 22), (central, 10, 16, 24)] {
            store(93, as: Byte2.self, at: base + method)
            store(crc, as: Byte4.self, at: base + crcOffset)
            store(UInt32(original.count), as: Byte4.self, at: base + size)
        }
        try Data(raw).write(to: archive)
    }
}
