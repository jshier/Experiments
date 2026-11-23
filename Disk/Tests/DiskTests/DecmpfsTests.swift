import Bytes
import BytesTestSupport
import Darwin
@testable import Disk
import DiskTestSupport
import Foundation
import System
import Testing

/// APFS compression against Apple's tools: `aa extract` on the same files (LZBITMAP byte for byte; LZFSE form and
/// contents), and `xip --expand`'s rules (LZVN) checked rule by rule (a signed `.xip` can't be made in a test).
@Suite struct DecmpfsTests {
    /// Writes Apple Archive streams with exactly the fields asked for, including Xcode's `AFT` (what `aa archive` can't
    /// make).
    struct ArchiveStreamWriter {
        private(set) var bytes: [UInt8] = []

        private static func field(_ key: String, _ subtype: Character) -> [UInt8] {
            Array(key.utf8) + [UInt8(ascii: subtype.unicodeScalars.first!)]
        }

        /// `TYP`, then `PAT` with the path, then `MOD`.
        private static func fields(type: Character, path: String, mode: UInt16) -> [UInt8] {
            var fields = field("TYP", "1") + [UInt8(ascii: type.unicodeScalars.first!)] + field("PAT", "P")
            fields.append(UInt16(path.utf8.count), as: Byte2.self, .littleEndian)
            fields += Array(path.utf8) + field("MOD", "2")
            fields.append(mode, as: Byte2.self, .littleEndian)
            return fields
        }

        private mutating func append(_ fields: [UInt8], _ data: [UInt8] = []) {
            bytes += Array("AA01".utf8)
            bytes.append(UInt16(6 + fields.count), as: Byte2.self, .littleEndian)
            bytes += fields + data
        }

        mutating func directory(_ path: String) {
            append(Self.fields(type: "D", path: path, mode: 0o755))
        }

        mutating func file(_ path: String, _ data: [UInt8], diskCompression: UInt8) {
            var fields = Self.fields(type: "F", path: path, mode: 0o644)
            if data.count < 65_536 {
                fields += Self.field("DAT", "A")
                fields.append(UInt16(data.count), as: Byte2.self, .littleEndian)
            } else {
                fields += Self.field("DAT", "B")
                fields.append(UInt32(data.count), as: Byte4.self, .littleEndian)
            }
            fields += Self.field("FLG", "1") + [0x20] + Self.field("AFT", "1") + [diskCompression]
            append(fields, data)
        }
    }

    /// Small files at many sizes (where the room an encoder gets changes its output), and files whose last chunk is
    /// short, against `aa extract`.
    static var cases: [(String, [UInt8])] {
        var files: [(String, [UInt8])] = []
        let sizes = Array(stride(from: 20, through: 4_200, by: 167)) + [65_536 + 168, 131_072 + 280, 300_007]
        for (index, size) in sizes.enumerated() {
            for compressible in [true, false] where compressible || index % 6 == 0 {
                files.append(("\(compressible ? "text" : "random")-\(size)", testBytes(size, seed: UInt64(index * 2 + (compressible ? 0 : 1)), compressible: compressible)))
            }
        }
        return files
    }

    @Test(arguments: [(UInt8(14), StoragePolicy.appleArchive), (12, .appleArchiveLZFSE)])
    func compressesAsAaExtractDoes(_ type: UInt8, _ policy: StoragePolicy) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let files = Self.cases
        var writer = ArchiveStreamWriter()
        writer.directory("")
        for (path, bytes) in files { writer.file(path, bytes, diskCompression: type) }
        let stream = directory.path("files.aar")
        try Data(writer.bytes).write(to: stream)
        let reference = directory.path("reference")
        try ExternalTool.run("/usr/bin/aa", ["extract", "-i", stream.path, "-d", reference.path])

        let destination = try Destination(directory.filePath("out"))
        let (report, source) = try await extract(files.map { ($0.0, $0.1) }, into: destination, storage: .compressed(policy))
        #expect(source.releaseCount == files.count)
        #expect(report.files == files.count)
        var compressed = 0
        for (path, bytes) in files {
            let mine = directory.path("out/\(path)"), theirs = reference.appending(path: path)
            #expect(try readItem(at: mine).contents == bytes, "\(path)")
            let theirType = decmpfsType(theirs)
            #expect(decmpfsType(mine) == theirType, "\(path): Apple's \(theirType.map(String.init) ?? "plain")")
            if type == 14 { #expect(decmpfsStoredBytes(mine) == decmpfsStoredBytes(theirs), "\(path): stored bytes") }
            if theirType != nil { compressed += 1 }
        }
        #expect(compressed > files.count / 2)
        #expect(report.inlineFiles + report.forkFiles == compressed)
    }

    /// `xip --expand`'s rules: plain at 16 KiB and under, PNGs plain, the fork kept at four fifths of the 4 KiB blocks
    /// and dropped past it, never inline, and short last chunks given only their own room (LZVN's raw marker 0x06).
    @Test func followsXipExpandsRules() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + testBytes(40_000, seed: 1, compressible: true)
        // Random bytes padded with text: the fork's share of the blocks crosses 4/5 between these.
        func mixed(_ size: Int, randomShare: Double) -> [UInt8] {
            let random = Int(Double(size) * randomShare)
            return testBytes(random, seed: 9, compressible: false) + testBytes(size - random, seed: 10, compressible: true)
        }
        let files: [(String, [UInt8])] = [
            ("small", testBytes(16_384, seed: 2, compressible: true)),
            ("over", testBytes(16_385, seed: 3, compressible: true)),
            ("image.png", png),
            ("mostly-random", mixed(400_000, randomShare: 0.85)),
            ("half-random", mixed(400_000, randomShare: 0.5)),
            ("short-tail", testBytes(65_536 * 2 + 30, seed: 4, compressible: true)),
        ]
        let destination = try Destination(directory.filePath("out"))
        let (report, _) = try await extract(files, into: destination, storage: .compressed(.xipExpand))
        #expect(report.inlineFiles == 0)
        let out = directory.path("out")
        #expect(decmpfsType(out.appending(path: "small")) == nil)
        #expect(decmpfsType(out.appending(path: "over")) == 8)
        #expect(decmpfsType(out.appending(path: "image.png")) == nil)
        #expect(decmpfsType(out.appending(path: "mostly-random")) == nil)
        #expect(decmpfsType(out.appending(path: "half-random")) == 8)
        for (path, bytes) in files { #expect(try readItem(at: out.appending(path: path)).contents == bytes, "\(path)") }
        // The short last chunk (30 bytes, under LZVN's room): stored raw behind 0x06.
        let stored = decmpfsStoredBytes(out.appending(path: "short-tail"))
        let fork = Array(stored.dropFirst(16))
        let lastStart = Int(UInt32(fork[8]) | UInt32(fork[9]) << 8 | UInt32(fork[10]) << 16 | UInt32(fork[11]) << 24)
        #expect(fork[lastStart] == 0x06)
        // The block rule exactly.
        let policy = StoragePolicy.xipExpand
        #expect(policy.pays(4096 * 4, 4096 * 5))
        #expect(!policy.pays(4096 * 4 + 1, 4096 * 5))
    }

    /// zlib (type 3) inline, read back through the kernel; files whose attribute wouldn't fit stay plain.
    @Test func zlibInline() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let destination = try Destination(directory.filePath("out"))
        var writer = FileWriter(destination)
        let small = [UInt8](repeating: 0x61, count: 20_000) + Array("end".utf8)
        let large = testBytes(200_000, seed: 6, compressible: true)
        #expect(try withPath("small") { try writer.writeFile($0, contents: small.span.bytes, storage: .compressed(.zlibInline)) } == .inline)
        #expect(try withPath("large") { try writer.writeFile($0, contents: large.span.bytes, storage: .compressed(.zlibInline)) } == .plain)
        #expect(decmpfsType(directory.path("out/small")) == 3)
        #expect(try readItem(at: directory.path("out/small")).contents == small)
        #expect(try readItem(at: directory.path("out/large")).contents == large)
    }

    /// A streamed file (written in several writes, bigger than the staging buffer) is stored as the same file written
    /// whole: the same fork bytes; and one whose fork doesn't pay is rewritten plain from the fork.
    @Test(arguments: [1, 7])
    func streamedFilesMatchWholeOnes(_ writes: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let files: [(String, [UInt8])] = [
            ("text", testBytes(3_000_000 + 13, seed: 7, compressible: true)),
            ("random", testBytes(1_500_000, seed: 8, compressible: false)),
        ]
        var options = ExtractionSettings()
        options.stagingCapacity = 64 << 10
        let destination = try Destination(directory.filePath("streamed-\(writes)"))
        let (report, source) = try await extract(files, into: destination, options: options, storage: .compressed(.appleArchive), writesPerFile: writes)
        #expect(source.releaseCount == 2)
        #expect(report.forkFiles == 1 && report.plainFiles == 1)
        let reference = try Destination(directory.filePath("whole"))
        var writer = FileWriter(reference)
        for (path, bytes) in files {
            try withPath(path) { try writer.writeFile($0, contents: bytes.span.bytes, storage: .compressed(.appleArchive)) }
            let mine = directory.path("streamed-\(writes)/\(path)")
            #expect(try readItem(at: mine).contents == bytes)
            #expect(decmpfsStoredBytes(mine) == decmpfsStoredBytes(directory.path("whole/\(path)")), "\(path)")
        }
    }
}
