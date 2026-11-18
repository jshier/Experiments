import Foundation

/// An entry of the archive, for listing.
public struct AAEntry: Sendable {
    public var header: AAEntryHeader
    public var path: String
    public var linkTarget: String?
    /// The file's size.
    public var size: Int { header.data?.count ?? 0 }
}

/// Settings for reading segments: how many threads decode, with which decoder, and what's checked.
public struct AEAReadOptions: Sendable {
    public init() {}

    /// Threads decoding segments.
    public var decodeThreads = ProcessInfo.processInfo.activeProcessorCount
    /// Decoded segments held at once beyond one per decoding thread: room for writing to lag decoding.
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
    public var withExtendedAttributes = 0
    /// Seconds from start to end.
    public var seconds = 0.0
    /// Seconds the decoding threads were busy, summed, and the part spent reading.
    public var decodeSeconds = 0.0
    public var readSeconds = 0.0
    /// Seconds the walker spent on its own (parsing, planning, creating directories), and waiting for segments.
    public var walkSeconds = 0.0
    /// Of ``walkSeconds``, the time it waited for decoded segments and for room in the writers' queue.
    public var walkWaitForSegments = 0.0
    public var walkWaitForWriters = 0.0
    public var writeSeconds = 0.0
    public var peakSegmentBuffers = 0
    /// Buffers still referenced after the pass: 0 unless something leaked (the tests check).
    public var unreleasedBuffers = 0
    /// Seconds per kind of writer work, summed across writers.
    public var writerWork: [String: Double] = [:]
}

extension AEAArchive {
    /// Decodes every segment and calls `body` with each entry, in order.
    ///
    /// - Returns: Counts and timings.
    @discardableResult
    public func forEachEntry(options: AEAReadOptions = .init(), _ body: @escaping (AAEntry) -> Void) throws(AEAError) -> AEAStatistics {
        let started = DispatchTime.now().uptimeNanoseconds
        let pool = SegmentBufferPool(count: options.decodeThreads + options.extraBuffers, segmentCapacity: rootHeader.segmentSize)
        let stream = try SegmentStream(
            archive: self, pool: pool, threads: options.decodeThreads, backend: options.decoder,
            verifyMACs: options.verifyMACs, verifyChecksums: options.verifyChecksums, input: options.input
        )
        stream.start()
        var sink = ListingSink(body: body)
        try ArchiveWalker.walk(stream, into: &sink)
        var statistics = sink.statistics
        statistics.seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        statistics.decodeSeconds = Double(stream.busyNanoseconds.load(ordering: .relaxed)) / 1e9
        statistics.readSeconds = Double(stream.readNanoseconds.load(ordering: .relaxed)) / 1e9
        statistics.peakSegmentBuffers = pool.peakInUse.load(ordering: .relaxed)
        statistics.unreleasedBuffers = pool.buffersInUse
        return statistics
    }
}

struct ListingSink: ArchiveSink, ~Copyable {
    let body: (AAEntry) -> Void
    var statistics = AEAStatistics()

    mutating func entry(_ entry: AAEntryHeader, header: UnsafeRawPointer, buffer: Int) throws(AEAError) {
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
            statistics.filesByDiskCompression[entry.diskCompression ?? 0, default: 0] += 1
        case .directory: statistics.directories += 1
        case .symbolicLink: statistics.symbolicLinks += 1
        default: statistics.otherEntries += 1
        }
        if entry.hardLinkCluster != nil { statistics.hardLinks += 1 }
        if entry.extendedAttributes != nil { statistics.withExtendedAttributes += 1 }
        body(AAEntry(header: entry, path: string(entry.path) ?? "", linkTarget: string(entry.linkTarget)))
    }

    mutating func data(_ bytes: UnsafeRawPointer, count: Int, fileOffset: Int, buffer: Int, segment: Int) throws(AEAError) {}
    mutating func extendedAttributes(_ bytes: UnsafeRawPointer, count: Int, offset: Int) throws(AEAError) {}
    mutating func endEntry() throws(AEAError) {}
}
