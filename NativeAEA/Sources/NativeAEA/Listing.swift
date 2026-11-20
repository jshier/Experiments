import Foundation

/// An entry of the archive, for listing.
public struct AAEntry: Sendable {
    public var header: AAEntryHeader
    public var path: String
    public var linkTarget: String?
    /// The file's size.
    public var size: Int { header.data?.count ?? 0 }
}

/// Settings for reading segments: how many decode at once, with which decoder, and what's checked.
public struct AEAReadOptions: Sendable {
    public init() {}

    /// Segments (or blocks) decoded at once: one child task each.
    public var decodeThreads = ProcessInfo.processInfo.activeProcessorCount
    /// Decoded segments held at once beyond one per decoder: room for writing to lag decoding.
    public var extraBuffers = 8
    public var decoder = SegmentDecoderBackend.bytes
    public var input = SegmentInput.read
    /// Check each segment's MAC (over its stored bytes) before decoding it.
    public var verifyMACs = true
    /// Check each segment's checksum (over its decoded bytes).
    public var verifyChecksums = true
}

/// What a pass over an archive did.
public struct AEAStatistics: Sendable {
    public var entries = 0
    public var files = 0
    public var directories = 0
    public var symbolicLinks = 0
    public var otherEntries = 0
    public var fileBytes = 0
    /// Files by on-disk compression (`AFT`): 0 when there's none.
    public var filesByDiskCompression: [UInt32: Int] = [:]
    public var hardLinks = 0
    /// Of the later names of hard-linked files, those made after the writers (see
    /// ``AEAExtractionOptions/hardLinkThreads``).
    public var hardLinksAfterWriters = 0
    public var withExtendedAttributes = 0
    public var withAccessControlLists = 0
    /// FIFOs, devices, and sockets made (``otherEntries`` counts them too), and entries skipped: sockets, whiteouts,
    /// doors, ports, metadata entries, and devices without root.
    public var specialFiles = 0
    public var skippedEntries = 0
    /// Seconds from start to end.
    public var seconds = 0.0
    /// Seconds the decoders were busy, summed, and the part spent reading.
    public var decodeSeconds = 0.0
    public var readSeconds = 0.0
    /// Seconds the walker spent on its own (parsing, planning, creating directories), and waiting for segments.
    public var walkSeconds = 0.0
    /// Of ``walkSeconds``, the time it waited for decoded segments and for room in the writers' queue.
    public var walkWaitForSegments = 0.0
    public var walkWaitForWriters = 0.0
    public var writeSeconds = 0.0
    public var peakSegmentBuffers = 0
    /// Buffers still referenced after the pass, in every pool the decoding used: 0 unless something leaked (the tests
    /// check).
    public var unreleasedBuffers = 0
    /// Seconds per kind of writer work, summed across writers.
    public var writerWork: [String: Double] = [:]
    /// Seconds of each phase after the walk: the writers finishing, then hard links, special files, symbolic links,
    /// deferred metadata, and directories.
    public var phaseSeconds: [String: Double] = [:]
}

extension AEAArchive {
    /// Decodes every segment and calls `body` with each entry, in order.
    ///
    /// Runs off the caller's actor; decoders are child tasks, and `body` is called on the calling task, one entry at a
    /// time. Cancelling the task stops decoding and throws ``AEAError/cancelled``.
    ///
    /// - Returns: Counts and timings.
    @concurrent @discardableResult
    public func forEachEntry(options: AEAReadOptions = .init(), _ body: @escaping (AAEntry) -> Void) async throws(AEAError) -> AEAStatistics {
        try await list(options, body)
    }

    /// Decodes and checks every segment and parses every entry, as ``forEachEntry(options:_:)`` does, without making
    /// an ``AAEntry`` (and its strings) for each: verification alone.
    ///
    /// - Returns: Counts and timings.
    /// - Throws: ``AEAError``: a failed check, a malformed stream, or cancellation.
    @concurrent @discardableResult
    public func verify(options: AEAReadOptions = .init()) async throws(AEAError) -> AEAStatistics {
        try await list(options, nil)
    }

    nonisolated(nonsending) private func list(_ options: AEAReadOptions, _ body: ((AAEntry) -> Void)?) async throws(AEAError) -> AEAStatistics {
        let started = DispatchTime.now().uptimeNanoseconds
        var statistics = try await Lister.list(payload(options, heldBeyondDecoding: 0), body)
        statistics.seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        return statistics
    }
}

/// Files counted by on-disk compression type (`AFT`: small numbers) in a fixed table, made into
/// ``AEAStatistics/filesByDiskCompression`` at the end: no hashing per file.
struct DiskCompressionCounts {
    private var small = InlineArray<16, Int>(repeating: 0)
    private var others: [UInt32: Int] = [:]

    @inline(__always)
    mutating func count(_ type: UInt32?) {
        let type = type ?? 0
        if type < 16 { small[Int(type)] += 1 } else { others[type, default: 0] += 1 }
    }

    func add(to counts: inout [UInt32: Int]) {
        for type in 0..<16 where small[type] > 0 { counts[UInt32(type), default: 0] += small[type] }
        for (type, count) in others { counts[type, default: 0] += count }
    }
}

enum Lister {
    /// Walks the stream `source` decodes (not yet running), calling `body` with each entry (`nil`: only verifying, no
    /// entries made).
    nonisolated(nonsending) static func list(
        _ source: some ChunkSource, format: StreamFormat = .appleArchive, _ body: ((AAEntry) -> Void)?
    ) async throws(AEAError) -> AEAStatistics {
        let started = DispatchTime.now().uptimeNanoseconds
        var sink = ListingSink(body: body)
        let failure: AEAError? = await source.withDecoding { _ in
            do throws(AEAError) {
                try await source.prepare()
                try await format.walk(source, into: &sink)
                return nil
            } catch {
                return error
            }
        }
        if let failure { throw failure }
        var statistics = sink.statistics
        sink.diskCompression.add(to: &statistics.filesByDiskCompression)
        statistics.seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        statistics.decodeSeconds = Double(source.counters.busy.load(ordering: .relaxed)) / 1e9
        statistics.readSeconds = Double(source.counters.read.load(ordering: .relaxed)) / 1e9
        statistics.peakSegmentBuffers = source.pool.peakInUse.load(ordering: .relaxed)
        statistics.unreleasedBuffers = source.pools.reduce(0) { $0 + $1.buffersInUse }
        return statistics
    }
}

struct ListingSink: ArchiveSink, ~Copyable {
    /// Called with each entry; `nil` when only verifying (no ``AAEntry`` or strings are made).
    let body: ((AAEntry) -> Void)?
    var statistics = AEAStatistics()
    var diskCompression = DiskCompressionCounts()

    nonisolated(nonsending) mutating func entry(_ entry: AAEntryHeader, header: UnsafeRawPointer, buffer: Int) async throws(AEAError) {
        func string(_ range: AAHeaderRange?) -> String? {
            guard let range else { return nil }
            // Within the header the walker just parsed: safe.
            return unsafe String(decoding: UnsafeRawBufferPointer(start: header + range.offset, count: range.count), as: UTF8.self)
        }
        statistics.entries += 1
        switch entry.type {
        case .regularFile:
            statistics.files += 1
            statistics.fileBytes += entry.data?.count ?? 0
            diskCompression.count(entry.diskCompression)
        case .directory: statistics.directories += 1
        case .symbolicLink: statistics.symbolicLinks += 1
        default: statistics.otherEntries += 1
        }
        if entry.hardLinkCluster != nil { statistics.hardLinks += 1 }
        if entry.extendedAttributes != nil { statistics.withExtendedAttributes += 1 }
        if entry.accessControlList != nil { statistics.withAccessControlLists += 1 }
        if let body { body(AAEntry(header: entry, path: string(entry.path) ?? "", linkTarget: string(entry.linkTarget))) }
    }

    nonisolated(nonsending) mutating func data(_ bytes: UnsafeRawPointer, count: Int, fileOffset: Int, buffer: Int, segment: Int) async throws(AEAError) {}
    mutating func metadata(_ blob: AAMetadataBlob, _ bytes: UnsafeRawPointer, count: Int, offset: Int) throws(AEAError) {}
    nonisolated(nonsending) mutating func endEntry() async throws(AEAError) {}
}
