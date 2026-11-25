import BytesTestSupport
import Disk
import Foundation
import NativeZip
import System
import Testing

/// Errors arrive composed, as the module that found them threw them: a decoder's `BytesError` with the entry
/// (``ZipError/decoding(_:_:)``), Disk's `DiskError` (``ZipError/disk(_:)``), a reading body's own error
/// (``ZipContentsError/body(_:)``).
@Suite(.diskLifetimes) struct ErrorTests {
    /// Runs /usr/bin/zip in `directory`.
    private static func zip(_ arguments: [String], in directory: URL) throws {
        try ExternalTool.run("/usr/bin/zip", ["-q"] + arguments, in: directory)
    }

    /// An archive of one deflated entry `name` of `size` bytes of text whose stream starts with an invalid block type
    /// (`11`), in `directory`.
    private static func corruptDeflateArchive(_ name: String, size: Int, in directory: URL) throws -> URL {
        try Data(SampleBytes.text(size, seed: 5)).write(to: directory.appending(path: name))
        try zip(["-9", "deflated.zip", name], in: directory)
        var bytes = try [UInt8](Data(contentsOf: directory.appending(path: "deflated.zip")))
        // The payload: after the local header's 30 bytes, the name, and the extra field.
        let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        let extraLength = Int(bytes[28]) | Int(bytes[29]) << 8
        bytes[30 + nameLength + extraLength] = 0xFF // BFINAL 1, BTYPE 11: reserved
        let corrupt = directory.appending(path: "corrupt-\(size).zip")
        try Data(bytes).write(to: corrupt)
        return corrupt
    }

    /// A corrupt DEFLATE stream is the decoder's error with the entry's name: verified, read, and extracted (written
    /// whole, and from 4 MB decoded in a child task while it's written), never a size or CRC-32 mismatch.
    @Test(arguments: [20_000, 5 << 20])
    func corruptDeflateIsTheDecodersError(size: Int) async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipErrors")
        defer { temporary.remove() }
        let archive = try ZipArchive(url: Self.corruptDeflateArchive("text.txt", size: size, in: temporary.url))
        let entry = try #require(archive.entries.first)

        func isDecoding(_ error: ZipError?) -> Bool {
            if case .decoding(_, "text.txt")? = error { true } else { false }
        }
        let verified = await archive.verify()
        #expect(verified.count == 1 && isDecoding(verified.first?.error), "\(verified.map(\.error))")

        var decoder = ZipDecoder()
        let read = #expect(throws: ZipError.self) { try archive.contents(of: entry, using: &decoder) { _ in } }
        #expect(isDecoding(read), "\(String(describing: read))")

        let out = FilePath(temporary.url.appending(path: "out").path)
        let extracted = await #expect(throws: ZipError.self) { try await archive.extract(to: out) }
        #expect(isDecoding(extracted), "\(String(describing: extracted))")
        #expect(!FileManager.default.fileExists(atPath: out.appending("text.txt").string))

        let collected = try await ZipExtractor.extract(into: FilePath(temporary.url.appending(path: "collected").path)) {
            extractor async throws(ZipError) in try await extractor.add(archive)
        }
        #expect(collected.count == 1 && isDecoding(collected.first?.error), "\(collected)")
        #expect(collected.first?.path == "text.txt")
    }

    /// Disk's failures as Disk threw them: the destination can't be opened (a file where its directory goes), and a
    /// file entry where a directory is on disk, which Disk doesn't replace (collected, with the rest extracted).
    @Test func diskFailuresAreDisks() async throws {
        let temporary = try TemporaryDirectory(prefix: "NativeZipErrors")
        defer { temporary.remove() }
        let directory = temporary.url
        try FileManager.default.createDirectory(at: directory.appending(path: "tree/dir"), withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: directory.appending(path: "tree/dir/one.txt"))
        try Data("two\n".utf8).write(to: directory.appending(path: "tree/two.txt"))
        try Self.zip(["-r", "-D", "../tree.zip", "."], in: directory.appending(path: "tree"))
        let archive = try ZipArchive(url: directory.appending(path: "tree.zip"))

        // The destination's parent is a file.
        try Data().write(to: directory.appending(path: "file"))
        let unopened = await #expect(throws: ZipError.self) {
            try await archive.extract(to: FilePath(directory.appending(path: "file/out").path))
        }
        #expect(unopened == .disk(.notADirectory(directory.appending(path: "file/out").path)))

        // `two.txt` is a directory in the destination: the file can't replace it.
        let out = directory.appending(path: "out")
        try FileManager.default.createDirectory(at: out.appending(path: "two.txt/inside"), withIntermediateDirectories: true)
        let failures = try await ZipExtractor.extract(into: FilePath(out.path)) { extractor async throws(ZipError) in
            try await extractor.add(archive)
        }
        #expect(failures.count == 1, "\(failures)")
        #expect(failures.first?.error == .disk(.exists("two.txt")))
        #expect(failures.first?.path == "two.txt")
        #expect(try String(contentsOf: out.appending(path: "dir/one.txt"), encoding: .utf8) == "one\n")
    }

    /// The archive's error, or the reading body's own, each as thrown: ``ZipContentsError``.
    @Test func bodyErrorsAreComposed() throws {
        struct Stop: Error, Equatable {}
        let temporary = try TemporaryDirectory(prefix: "NativeZipErrors")
        defer { temporary.remove() }
        try Data("text\n".utf8).write(to: temporary.url.appending(path: "a.txt"))
        try Self.zip(["plain.zip", "a.txt"], in: temporary.url)
        let archive = try ZipArchive(url: temporary.url.appending(path: "plain.zip"))
        #expect(throws: ZipContentsError<Stop>.body(Stop())) {
            try archive.contents(of: archive.entries[0]) { _ throws(Stop) in throw Stop() }
        }

        let corrupt = try ZipArchive(url: Self.corruptDeflateArchive("text.txt", size: 20_000, in: temporary.url))
        let error = #expect(throws: ZipContentsError<Stop>.self) {
            try corrupt.contents(of: corrupt.entries[0]) { _ throws(Stop) in }
        }
        if case .zip(.decoding(_, "text.txt"))? = error {} else { Issue.record("\(String(describing: error))") }
    }
}
