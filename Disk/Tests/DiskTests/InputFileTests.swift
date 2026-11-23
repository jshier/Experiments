import Bytes
import BytesTestSupport
@testable import Disk
import Foundation
import System
import Testing

@Suite struct InputFileTests {
    /// Positioned reads fill the span from the offset, in any order; a read past the end throws `endOfFile`.
    @Test func readsAtOffsets() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let bytes = testBytes(100_003, seed: 11, compressible: false)
        try Data(bytes).write(to: directory.path("file"))
        let path = directory.filePath("file")
        let file = try InputFile(path)
        #expect(file.count == bytes.count && file.path == path)

        for (offset, count) in [(0, 16), (99_000, 1_003), (4_096, 65_536), (17, 0), (bytes.count, 0), (0, bytes.count)] {
            var buffer = [UInt8](repeating: 0xEE, count: count)
            var span = buffer.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            try file.read(at: offset, into: &raw)
            #expect(buffer == Array(bytes[offset..<offset + count]), "\(offset), \(count)")
            #expect(try file.read(at: offset, count: count) == Array(bytes[offset..<offset + count]), "\(offset), \(count)")
        }

        // Into an output span: appended after what's there.
        var appended = [UInt8](repeating: 0, count: 40)
        let written = try appended.withOutputRawSpan { (output) throws(DiskError) -> Int in
            output.append(copying: ([9, 9] as [UInt8]).span)
            try file.read(at: 50, count: 30, into: &output)
            return output.byteCount
        }
        #expect(written == 32 && Array(appended[..<32]) == [9, 9] + Array(bytes[50..<80]))

        // Crossing the end: the bytes the file has are read, then the end is reported. The array form checks first.
        var tail = [UInt8](repeating: 0, count: 10)
        var tailSpan = tail.mutableSpan
        var tailBytes = MutableRawSpan(mutating: &tailSpan)
        #expect(throws: DiskError.endOfFile(path.string)) { try file.read(at: bytes.count - 4, into: &tailBytes) }
        #expect(Array(tail[..<4]) == Array(bytes[(bytes.count - 4)...]))
        #expect(throws: DiskError.endOfFile(path.string)) { _ = try file.read(at: bytes.count - 4, count: 10) }
        #expect(throws: DiskError.endOfFile(path.string)) { _ = try file.read(at: bytes.count + 1, count: 0) }
        #expect(throws: DiskError.endOfFile(path.string)) { _ = try file.read(at: 0, count: Int.max) }
    }

    /// An empty file has no bytes to read; a missing one throws `open`'s error; a directory opens and fails to read.
    @Test func emptyAndMissingFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data().write(to: directory.path("empty"))
        let empty = try InputFile(directory.filePath("empty"))
        #expect(empty.count == 0)
        #expect(try empty.read(at: 0, count: 0) == [])
        #expect(throws: DiskError.endOfFile(empty.path.string)) { _ = try empty.read(at: 0, count: 1) }
        #expect(try InputFile.contents(of: empty.path, maximumCount: 10) == [])
        #expect(try empty.map().count == 0)

        let missing = directory.filePath("missing")
        #expect(throws: DiskError.system("open", path: missing.string, .noSuchFileOrDirectory)) { _ = try InputFile(missing) }
        #expect(throws: DiskError.system("open", path: missing.string, .noSuchFileOrDirectory)) {
            _ = try InputFile.contents(of: missing, maximumCount: 10)
        }
        let folder = directory.filePath("")
        #expect(throws: DiskError.system("read", path: folder.string, .isDirectory)) { _ = try InputFile.contents(of: folder, maximumCount: 1 << 20) }
    }

    /// A whole small file, up to the cap; one byte more is refused. A pipe (no size until it ends) reads to its end.
    @Test func readsWholeFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        for count in [1, 32, 4_095, 4_096, 4_097, 70_000] {
            let bytes = testBytes(count, seed: UInt64(count), compressible: false)
            try Data(bytes).write(to: directory.path("key"))
            let path = directory.filePath("key")
            #expect(try InputFile.contents(of: path, maximumCount: count) == bytes, "\(count)")
            #expect(try InputFile.contents(of: path, maximumCount: 1 << 20) == bytes, "\(count)")
            #expect(throws: DiskError.tooLarge(path.string, limit: count - 1)) { _ = try InputFile.contents(of: path, maximumCount: count - 1) }
        }

        // A FIFO: its size is 0 until a writer closes it.
        let fifo = directory.filePath("fifo")
        #expect(mkfifo(fifo.string, 0o600) == 0)
        let bytes = testBytes(10_000, seed: 3, compressible: true)
        let writer = Thread {
            let handle = FileHandle(forWritingAtPath: fifo.string)!
            handle.write(Data(bytes))
            try? handle.close()
        }
        writer.start()
        #expect(try InputFile.contents(of: fifo, maximumCount: 1 << 20) == bytes)
    }

    /// The mapping is the file's bytes and outlives the input file.
    @Test func maps() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let bytes = testBytes(50_000, seed: 5, compressible: false)
        try Data(bytes).write(to: directory.path("file"))
        var mapped: MappedFile?
        do {
            let file = try InputFile(directory.filePath("file"))
            mapped = try file.map(access: .sequential)
        }
        let mapping = try #require(mapped)
        #expect(mapping.count == bytes.count)
        #expect(Array(mapping.buffer(0..<bytes.count)) == bytes)
    }

    /// Several tasks read one file at once (`pread` keeps no position).
    @Test func readsConcurrently() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let bytes = testBytes(1 << 20, seed: 13, compressible: false)
        try Data(bytes).write(to: directory.path("file"))
        let file = try InputFile(directory.filePath("file"))
        let matches = await withTaskGroup(of: Bool.self) { group in
            for piece in 0..<16 {
                group.addTask {
                    (try? file.read(at: piece << 16, count: 1 << 16)) == Array(bytes[(piece << 16)..<((piece + 1) << 16)])
                }
            }
            return await group.reduce(true) { $0 && $1 }
        }
        #expect(matches)
    }
}
