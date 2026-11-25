@testable import Disk
import BytesTestSupport
import Darwin
import DiskTestSupport
import Foundation
import System
import Testing

/// Each attack an archive (or what's already in the destination) can make: nothing is ever made or changed outside
/// the destination.
@Suite(.diskLifetimes) struct SecurityTests {
    /// A destination beside an `outside` directory holding a file that must survive.
    struct Setup {
        let directory: TemporaryDirectory
        let outside: URL
        let victim: URL

        init() throws {
            directory = try TemporaryDirectory()
            outside = directory.path("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            victim = outside.appending(path: "victim")
            try Data("keep me".utf8).write(to: victim)
        }

        /// Nothing outside changed.
        func checkOutside(sourceLocation: SourceLocation = #_sourceLocation) throws {
            #expect(try String(contentsOf: victim, encoding: .utf8) == "keep me", sourceLocation: sourceLocation)
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["victim"], sourceLocation: sourceLocation)
        }
    }

    /// An archive that makes `a -> outside` then writes `a/victim` (and `a/new`, a FIFO, a directory under it): the
    /// link is made last, so the writes make a real directory `a`, and the link then fails. Overwriting or not.
    @Test(arguments: [ExistingItemPolicy.fail, .replace, .skip])
    func symbolicLinkThenWriteThroughIt(_ policy: ExistingItemPolicy) async throws {
        let setup = try Setup()
        defer { setup.directory.remove() }
        var destinationOptions = DestinationOptions()
        destinationOptions.existingItems = policy
        let destination = try Destination(setup.directory.filePath("out"), options: destinationOptions)
        defer { destination.close() }
        let source = ArraySource([Array("planted".utf8), Array("new".utf8)])
        var options = ExtractionSettings()
        options.stopsOnFirstFailure = false
        let outside = setup.outside.path
        let report = try await Extraction.run(into: destination, source: source, settings: options) { (planner: inout Planner<ArraySource>) throws(DiskError) in
            try withPath("a") { path throws(DiskError) in try planner.symbolicLink(path, target: Array(outside.utf8).span.bytes) }
            _ = try await planFile(&planner, "a/victim", index: 0, size: 7)
            _ = try await planFile(&planner, "a/new", index: 1, size: 3)
            try withPath("a/fifo") { path throws(DiskError) in try planner.specialFile(path, .fifo) }
            try withPath("a/sub") { path throws(DiskError) in try planner.directory(path) }
        }
        try setup.checkOutside()
        // The link wasn't made: a directory is in its place.
        #expect(try readItem(at: setup.directory.path("out/a")).kind == .directory)
        #expect(report.symbolicLinks == 0)
    }

    /// A link already in the destination (`evil -> outside`): files, directories, links, FIFOs, and hard links through
    /// it all fail (`O_NOFOLLOW_ANY` and friends), with every API.
    @Test func preexistingLinkInTheDestination() async throws {
        let setup = try Setup()
        defer { setup.directory.remove() }
        let out = setup.directory.path("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: out.appending(path: "evil").path, withDestinationPath: setup.outside.path)
        try Data("inside".utf8).write(to: out.appending(path: "inside"))
        for policy in [ExistingItemPolicy.fail, .skip] {
            var destinationOptions = DestinationOptions()
            destinationOptions.existingItems = policy
            let destination = try Destination(FilePath(out.path), options: destinationOptions)
            defer { destination.close() }
            var writer = FileWriter(destination)
            #expect(throws: DiskError.self) { try withPath("evil/victim") { try writer.writeFile($0, contents: Array("x".utf8).span.bytes) } }
            #expect(throws: DiskError.self) { try withPath("evil/new") { try writer.writeFile($0, contents: Array("x".utf8).span.bytes) } }
            #expect(throws: DiskError.self) { try withPath("evil/dir") { try destination.makeDirectory($0) } }
            #expect(throws: DiskError.self) { try withPath("evil/link") { try destination.makeSymbolicLink($0, to: Array("x".utf8).span.bytes) } }
            #expect(throws: DiskError.self) { try withPath("evil/fifo") { try destination.makeSpecialFile($0, .fifo) } }
            #expect(throws: DiskError.self) {
                try withPath("evil/hard") { new in try withPath("inside") { try destination.makeHardLink(new, to: $0) } }
            }
            #expect(throws: DiskError.self) {
                try withPath("x") { new in try withPath("evil/victim") { try destination.makeHardLink(new, to: $0) } }
            }
            // Through the scheduler too.
            let source = ArraySource([Array("x".utf8)])
            var options = ExtractionSettings()
            options.stopsOnFirstFailure = false
            let report = try await Extraction.run(into: destination, source: source, settings: options) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                _ = try await planFile(&planner, "evil/sub/file", index: 0, size: 1)
                try withPath("evil/dir") { path throws(DiskError) in try planner.directory(path) }
            }
            #expect(report.failures.count == 2)
            try setup.checkOutside()
        }
        // With `.replace`, the link itself is replaced (by a directory, or a file), never followed.
        var options = DestinationOptions()
        options.existingItems = .replace
        let replacing = try Destination(FilePath(out.path), options: options)
        defer { replacing.close() }
        try withPath("evil/dir") { try replacing.makeDirectory($0) }
        #expect(try readItem(at: out.appending(path: "evil")).kind == .directory)
        try setup.checkOutside()
        try FileManager.default.createSymbolicLink(atPath: out.appending(path: "evil2").path, withDestinationPath: setup.outside.path)
        var writer = FileWriter(replacing)
        try withPath("evil2") { try writer.writeFile($0, contents: Array("replaced".utf8).span.bytes) }
        #expect(try readItem(at: out.appending(path: "evil2")).kind == .file)
        try setup.checkOutside()
    }

    /// A file entry where a link already is, with `.fail` and `.skip`: the link's target is never written.
    @Test(arguments: [ExistingItemPolicy.fail, .skip])
    func fileOverAnExistingLink(_ policy: ExistingItemPolicy) throws {
        let setup = try Setup()
        defer { setup.directory.remove() }
        let out = setup.directory.path("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: out.appending(path: "link").path, withDestinationPath: setup.victim.path)
        var options = DestinationOptions()
        options.existingItems = policy
        let destination = try Destination(FilePath(out.path), options: options)
        var writer = FileWriter(destination)
        _ = try? withPath("link") { try writer.writeFile($0, contents: Array("overwritten".utf8).span.bytes) }
        destination.close()
        try setup.checkOutside()
    }

    /// Paths that climb out never get as far as a call: `EntryPath` refuses them.
    @Test(arguments: ["../victim", "/etc/passwd", "a/../../victim", "a//b", "./a", "a/."])
    func refusesPathsThatClimbOut(_ path: String) {
        let bytes = Array(path.utf8)
        #expect(throws: DiskError.self) { _ = try EntryPath(validating: bytes.span.bytes) }
    }

    /// Hard links only to files this extraction wrote: a token from a file planned `hardLinked`.
    @Test func hardLinksOnlyToPlannedFiles() async throws {
        let setup = try Setup()
        defer { setup.directory.remove() }
        let destination = try Destination(setup.directory.filePath("out"))
        defer { destination.close() }
        let source = ArraySource([Array("x".utf8)])
        await #expect(throws: ExtractionError<DiskError, DecodingFailure>.self) {
            try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                let plain = try await planFile(&planner, "plain", index: 0, size: 1)
                try withPath("other") { path throws(DiskError) in try planner.hardLink(path, to: plain) }
            }
        }
    }

    /// Symbolic links pointing out of the destination, refused with `.withinDestination`.
    @Test func symbolicLinkTargetsWithinTheDestination() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.symbolicLinks = .withinDestination
        let destination = try Destination(directory.filePath("out"), options: options)
        defer { destination.close() }
        for (path, target, allowed) in [
            ("a/b/l1", "../c", true), ("a/l2", "../../x", false), ("l3", "/etc", false), ("a/l4", "./b/../c", true), ("l5", "..", false),
            ("a/l6", "b/../../../x", false),
        ] {
            let result = Result { try withPath(path) { try destination.makeSymbolicLink($0, to: Array(target.utf8).span.bytes) } }
            if allowed { #expect(throws: Never.self) { try result.get() } } else { #expect(throws: DiskError.self) { try result.get() } }
        }
    }

    /// Devices are refused unless allowed (and then made only by root).
    @Test func refusesDevices() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let destination = try Destination(directory.filePath("out"))
        defer { destination.close() }
        let source = ArraySource([])
        await #expect(throws: ExtractionError<DiskError, DecodingFailure>.self) {
            try await Extraction.run(into: destination, source: source) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                try withPath("null") { path throws(DiskError) in try planner.specialFile(path, .characterDevice(0x0300_0002)) }
            }
        }
        var options = DestinationOptions()
        options.allowsDevices = true
        let allowed = try Destination(directory.filePath("allowed"), options: options)
        defer { allowed.close() }
        let made = try withPath("null") { try allowed.makeSpecialFile($0, .characterDevice(0x0300_0002)) }
        #expect(made == (geteuid() == 0))
    }

    /// Concurrent extractions never change the process's umask (it's read with `getumask()`, never set).
    @Test func concurrentExtractionsKeepTheUmask() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let mask = getumask()
        try await withThrowingTaskGroup { group in
            for index in 0..<8 {
                group.addTask {
                    let destination = try Destination(directory.filePath("out\(index)"))
                    defer { destination.close() }
                    try await extract((0..<50).map { ("f\($0)", [UInt8(truncatingIfNeeded: $0)]) }, into: destination, metadata: EntryMetadata(mode: 0o666))
                }
            }
            try await group.waitForAll()
        }
        #expect(getumask() == mask)
        #expect(try readItem(at: directory.path("out3/f7")).mode == 0o666 & ~UInt16(mask))
    }
}
