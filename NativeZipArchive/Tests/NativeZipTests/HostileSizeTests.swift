import BytesReferenceCodecs
import BytesTestSupport
import Disk
import Foundation
import NativeZip
import System
import Testing
import zlib

/// Sizes and offsets the directory claims, which the archive's maker chooses: ones no file can have are rejected where
/// the directory is parsed (below 2^62, as NativeAEA's root header bounds its sizes), so nothing after the parser sees
/// one; and the ones it accepts add up without overflowing.
@Suite(.diskLifetimes) struct HostileSizeTests {
    /// A stored entry, with the values its central directory gives in a ZIP64 extra field (each `nil` field is
    /// recorded in the header itself).
    struct Entry {
        var name: String
        var data: [UInt8]
        var uncompressedSize: UInt64?
        var compressedSize: UInt64?
        var localHeaderOffset: UInt64?
        /// The method, and the stored bytes when they aren't `data` (a compressed stream of it).
        var flags = 0
        var method = 0
        var payload: [UInt8]?
    }

    static func le16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }
    static func le32(_ value: UInt64) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) } }
    static func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) } }

    /// A stored archive of `entries` (CRC-32s of their data), after `leading` bytes that its offsets don't count (a
    /// self-extractor's program), written to `directory`.
    static func archive(_ entries: [Entry], leading: Int = 0, in directory: URL) throws -> URL {
        var output = [UInt8](repeating: 0x5A, count: leading)
        var central: [UInt8] = []
        for entry in entries {
            let offset = UInt64(output.count - leading)
            let name = Array(entry.name.utf8)
            let crc = UInt64(entry.data.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) })
            let count = UInt64(entry.data.count)
            let stored = entry.payload ?? entry.data
            let storedCount = UInt64(stored.count)
            output += le32(0x0403_4B50) + le16(20) + le16(entry.flags) + le16(entry.method) + le16(0) + le16(0x21) + le32(crc) + le32(storedCount)
                + le32(count) + le16(name.count) + le16(0) + name + stored
            // ZIP64's extra field holds only the saturated fields, in this order.
            var extra: [UInt8] = []
            for value in [entry.uncompressedSize, entry.compressedSize, entry.localHeaderOffset] {
                if let value { extra += le64(value) }
            }
            if !extra.isEmpty { extra = le16(1) + le16(extra.count) + extra }
            central += le32(0x0201_4B50) + le16(0x031E) + le16(45) + le16(entry.flags) + le16(entry.method) + le16(0) + le16(0x21) + le32(crc)
                + le32(entry.compressedSize == nil ? storedCount : 0xFFFF_FFFF) + le32(entry.uncompressedSize == nil ? count : 0xFFFF_FFFF)
                + le16(name.count) + le16(extra.count) + le16(0) + le16(0) + le16(0) + le32(0o100644 << 16)
                + le32(entry.localHeaderOffset == nil ? offset : 0xFFFF_FFFF) + name + extra
        }
        let directoryOffset = UInt64(output.count - leading)
        output += central + le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
            + le32(UInt64(central.count)) + le32(directoryOffset) + le16(0)
        let url = directory.appending(path: "hostile-\(UUID().uuidString).zip")
        try Data(output).write(to: url)
        return url
    }

    static let bound: UInt64 = 1 << 62

    /// The reproducer: `x`, then `._x` (merged into it as AppleDouble by default) whose ZIP64 size is 2^63, past
    /// `Int.max`. Extracting it trapped summing the expected bytes; the directory is now refused.
    @Test func sizePastIntMaxIsRefused() throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipHostile")
        defer { temporary.remove() }
        let url = try Self.archive([
            Entry(name: "x", data: Array("hello".utf8)),
            Entry(name: "._x", data: [0x41, 0x42], uncompressedSize: 1 << 63),
        ], in: temporary.url)
        #expect(throws: ZipError.invalidRecord(.invalidValue, "central directory entry 1")) { _ = try ZipArchive(url: url) }
    }

    /// Each ZIP64 field at 2^62 (the first refused) and 2^62 − 1 (the last accepted, read as given).
    @Test(arguments: [0, 1, 2])
    func fieldsAreBoundedAtTwoToThe62(field: Int) throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipHostile")
        defer { temporary.remove() }
        func entry(_ value: UInt64) -> Entry {
            var entry = Entry(name: "big", data: [1, 2, 3])
            switch field {
            case 0: entry.uncompressedSize = value
            case 1: entry.compressedSize = value
            default: entry.localHeaderOffset = value
            }
            return entry
        }
        let refused = try Self.archive([Entry(name: "a", data: [0]), entry(Self.bound)], in: temporary.url)
        #expect(throws: ZipError.invalidRecord(.invalidValue, "central directory entry 1")) { _ = try ZipArchive(url: refused) }
        let accepted = try ZipArchive(url: Self.archive([entry(Self.bound - 1)], in: temporary.url))
        let read = try #require(accepted.entries.first)
        #expect([read.uncompressedSize, read.compressedSize, read.localHeaderOffset][field] == Self.bound - 1)
    }

    /// An offset near 2^64 in an archive with data before it: adding the leading bytes overflowed (a trap) before the
    /// offset was bounded.
    @Test func offsetWithLeadingDataIsRefused() throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipHostile")
        defer { temporary.remove() }
        let url = try Self.archive([
            Entry(name: "a", data: [0]),
            Entry(name: "b", data: [1], localHeaderOffset: .max),
        ], leading: 16, in: temporary.url)
        #expect(throws: ZipError.invalidRecord(.invalidValue, "central directory entry 1")) { _ = try ZipArchive(url: url) }
    }

    /// Four entries claiming 2^62 − 1 bytes each (accepted: each is a size a file could have) and one real one: the
    /// totals saturate rather than overflow (within the archive, and in the progress's totals across two), the false
    /// ones fail as size mismatches, and the real one is written.
    @Test func largestAcceptedSizesExtractWithoutOverflow() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipHostile")
        defer { temporary.remove() }
        var entries = (0..<4).map { Entry(name: "big\($0)", data: [UInt8($0)], uncompressedSize: Self.bound - 1) }
        entries.append(Entry(name: "small", data: Array("small".utf8)))
        // And an AppleDouble entry claiming 64 MB (the most merged) for a real file: it holds 2 bytes, so it's left as a
        // file and fails; what's reserved for reading it is capped, not 64 MB.
        entries.append(Entry(name: "._small", data: [0x41, 0x42], uncompressedSize: 64 << 20))
        let archive = try ZipArchive(url: Self.archive(entries, in: temporary.url))
        let progress = ExtractionProgress()
        let output = temporary.url.appending(path: "out")
        let failures = try await ZipExtractor.extract(into: FilePath(output.path), progress: progress) { extractor async throws(ZipError) in
            try await extractor.add(archive, into: FilePath("1"))
            try await extractor.add(archive, into: FilePath("2"))
        }
        #expect(failures.count == 10)
        for failure in failures {
            guard case .sizeMismatch = failure.error else {
                Issue.record("\(failure.entry.path): \(failure.error)")
                continue
            }
        }
        #expect(progress.expectedBytes == Int.max)
        for directory in ["1", "2"] {
            let written = try Data(contentsOf: output.appending(path: directory).appending(path: "small"))
            #expect(written == Data("small".utf8))
        }
    }

    /// An entry recording 2 MiB whose DEFLATE stream decodes to 8 MiB of zeros: reading its contents stops at the first
    /// chunk past the recorded size, before the caller sees it. (Checked only after the last chunk, a 1 MB entry declaring
    /// 2 MiB streamed a gigabyte to the caller: `nunzip -p`.)
    @Test func contentsStopAtTheRecordedSize() throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipHostile")
        defer { temporary.remove() }
        let zeros = [UInt8](repeating: 0, count: 8 << 20)
        let url = try Self.archive([
            Entry(name: "bomb", data: zeros, uncompressedSize: 2 << 20, method: 8, payload: Zlib.compress(zeros)),
        ], in: temporary.url)
        let archive = try ZipArchive(url: url)
        let entry = try #require(archive.entries.first)
        // Both forms: the decoder's own loop (`ZipError` bodies) and `readContents` (bodies with their own errors).
        var seen = 0
        let error = #expect(throws: ZipError.self) {
            try archive.contents(of: entry) { chunk in seen += chunk.byteCount }
        }
        var seenGeneric = 0
        let genericError = #expect(throws: ZipContentsError<CancellationError>.self) {
            try archive.contents(of: entry) { chunk throws(CancellationError) in seenGeneric += chunk.byteCount }
        }
        // Chunks are at most 1 MiB: the error comes with the first one past the size, which the body never sees.
        for (error, seen) in [(error, seen), (genericError.flatMap { if case let .zip(e) = $0 { e } else { nil } }, seenGeneric)] {
            guard case let .sizeMismatch(path, expected, actual)? = error else {
                Issue.record("expected a size mismatch, got \(String(describing: error))")
                continue
            }
            #expect(path == "bomb" && expected == 2 << 20)
            #expect(actual > 2 << 20 && actual <= 3 << 20)
            #expect(seen <= 2 << 20)
        }
    }

    /// A stored entry whose compressed size (what's read) is larger than its recorded size: refused before the caller
    /// sees any of it, in both forms.
    @Test func storedEntryLargerThanItsSizeIsRefused() throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipHostile")
        defer { temporary.remove() }
        let data = [UInt8](repeating: 7, count: 10)
        let url = try Self.archive([
            Entry(name: "stored", data: data, uncompressedSize: 10, payload: [UInt8](repeating: 7, count: 4096)),
        ], in: temporary.url)
        let archive = try ZipArchive(url: url)
        let entry = try #require(archive.entries.first)
        var seen = 0
        #expect(throws: ZipError.sizeMismatch("stored", expected: 10, actual: 4096)) {
            try archive.contents(of: entry) { chunk in seen += chunk.byteCount }
        }
        let generic = #expect(throws: ZipContentsError<CancellationError>.self) {
            try archive.contents(of: entry) { chunk throws(CancellationError) in seen += chunk.byteCount }
        }
        guard case .zip(.sizeMismatch("stored", 10, 4096))? = generic else {
            Issue.record("expected a size mismatch, got \(String(describing: generic))")
            return
        }
        #expect(seen == 0)
    }
}
