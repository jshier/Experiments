import BytesTestSupport
import Darwin
@_spi(Testing) @testable import Disk
import Foundation
import System
import Testing

/// The lifetime checks themselves, and descriptors on the paths a working volume rarely takes: every descriptor Disk
/// opens is closed exactly once, by an explicit close, whatever fails.
@Suite(.diskLifetimes) struct LifetimeTests {
    /// A destination dropped without `close()` is counted by the audit (and its descriptor still closed); closed, it
    /// isn't. Each test counts only its own (the audit's scope is task-local).
    @Test func theAuditCountsDroppedDescriptors() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.filePath("out")
        let dropped = try await DescriptorAudit.counting { _ = try Destination(path) }
        #expect(dropped == 1)
        #expect(OpenFiles.paths(under: directory.url).isEmpty)
        let closed = try await DescriptorAudit.counting { try Destination(path).close() }
        #expect(closed == 0)
        let file = directory.filePath("file")
        try Data([1]).write(to: directory.path("file"))
        #expect(try await DescriptorAudit.counting { _ = try InputFile(file) } == 1)
        #expect(try await DescriptorAudit.counting { _ = try OutputFile(file, replacing: true) } == 1)
    }

    /// What `OpenFiles` reports: the paths under a directory this process has open, gone once closed.
    @Test func openFilesSeesWhatIsOpen() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data([1, 2, 3]).write(to: directory.path("file"))
        let file = try InputFile(directory.filePath("file"))
        let open = OpenFiles.paths(under: directory.url)
        #expect(open.count == 1 && open.allSatisfy { $0.contains("/file (descriptor ") }, "\(open)")
        file.close()
        #expect(OpenFiles.paths(under: directory.url).isEmpty)
    }

    #if DEBUG
    /// The survey's double close: a destination whose quarantine can't be set closed its descriptor in the failure path
    /// and again in `deinit`. Now it's closed once, explicitly.
    @Test func aFailedQuarantineClosesTheDestinationOnce() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var options = DestinationOptions()
        options.quarantine = Quarantine(value: Array("0081;673e3000;Safari;".utf8))
        options.quarantinesDestination = true
        let faults = SyscallFaults(failing: [.fsetxattr: EPERM])
        let path = directory.filePath("out")
        let quarantined = options
        let dropped = try await DescriptorAudit.counting {
            faults.run {
                #expect(throws: DiskError.system("setxattr quarantine", path: path.string, .notPermitted)) {
                    _ = try Destination(path, options: quarantined)
                }
            }
        }
        #expect(dropped == 0)
        #expect(faults.opened.count == 1 && faults.closed == faults.opened)
        #expect(faults.doubleCloses.isEmpty && faults.leftOpen.isEmpty)
    }

    /// Each call an extraction makes, failed in turn, with failures recorded and the extraction going on: no
    /// descriptor is left open or closed twice, and none is closed late.
    @Test(arguments: [
        [SyscallKind.pwrite: ENOSPC], [.fsetattrlist: EIO], [.fsetxattr: EIO], [.mkdirat: EACCES], [.openat: EMFILE],
        [.linkat: EMLINK], [.symlinkat: EIO], [.fchflags: EPERM], [.pwrite: ENOSPC, .unlinkat: EBUSY],
    ])
    func everyDescriptorClosesOnceWhenACallFails(_ failing: [SyscallKind: Int32]) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let files = (0..<12).map { testBytes($0 == 5 ? 300_000 : 2_000 + $0, seed: UInt64($0), compressible: $0 % 2 == 0) }
        let faults = SyscallFaults(failing: failing)
        let kind = failing.keys.map { "\($0)" }.sorted().joined(separator: "+")
        var attributes = ExtendedAttributeBlob()
        attributes.append(name: "com.example.a", value: ([1] as [UInt8]).span.bytes)
        let blob = attributes.bytes
        let dropped = try await DescriptorAudit.counting {
            await faults.run {
                // The destination itself is made before the faults matter (`mkdirat`, `openat` fail it at once).
                let destination: Destination
                do {
                    destination = try Destination(directory.filePath("out"))
                } catch {
                    return
                }
                defer { destination.close() }
                let source = ArraySource(files)
                var settings = ExtractionSettings()
                settings.stopsOnFirstFailure = false
                settings.writers = 3
                _ = try? await Extraction.run(into: destination, source: source, settings: settings) { (planner: inout Planner<ArraySource>) throws(DiskError) in
                    var first: EntryToken?
                    for index in files.indices {
                        let token = try await planFile(&planner, "d\(index % 3)/f\(index)", index: index, size: files[index].count,
                                                       // File 6: compressed with no times, so its flags go alone (`fchflags`).
                                                       metadata: index == 6 ? EntryMetadata() : EntryMetadata(mode: 0o644, times: EntryTimes(modification: Timestamp(seconds: 1_500_000_000))),
                                                       storage: index % 2 == 0 ? .compressed(.appleArchive) : .plain, attachments: index == 3, hardLinked: index == 0)
                        if index == 0 { first = token }
                        if index == 3 { try planner.addExtendedAttributes(blob.span.bytes, to: token) }
                    }
                    if let first { try withPath("link") { (path) throws(DiskError) in try planner.hardLink(path, to: first) } }
                    try withPath("symbolic") { (path) throws(DiskError) in try planner.symbolicLink(path, target: Array("f0".utf8).span.bytes) }
                    try withPath("d0") { (path) throws(DiskError) in _ = try planner.directory(path, metadata: EntryMetadata(mode: 0o755)) }
                }
            }
        }
        #expect(dropped == 0, "\(kind)")
        #expect(faults.injected > 0, "\(kind): never called")
        #expect(faults.doubleCloses.isEmpty, "\(kind): \(faults.doubleCloses)")
        #expect(faults.leftOpen.isEmpty, "\(kind): \(faults.leftOpen)")
    }
    #endif
}
