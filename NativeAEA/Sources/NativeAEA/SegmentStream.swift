import Bytes
import BytesAsync
import BytesCompression
import BytesCompressionAsync
import Disk
import Foundation
import System

// An archive's segments are decoded by BytesCompressionAsync's `ParallelBlockDecoder` (ARCHITECTURE.md §4): decoder
// tasks, the buffer pool, order, failure, and cancellation are the engine's, shared with `pbz` blocks; what's AEA's is
// this stage's hooks around the engine's reading and decoding: a segment's description, its MAC, decryption, and its
// checksum (and the mapping, when the archive is mapped).

/// How segments' stored bytes are read from the archive.
public enum SegmentInput: String, Sendable, CaseIterable {
    /// Positioned reads into one buffer per decoder: memory bounded by the decoders.
    case read
    /// The whole archive mapped, decoders reading the mapping: no copy, the kernel pages it in. If another process
    /// truncates the file while it's read, the process gets SIGBUS (positioned reads would get an error instead).
    case mapped
}

/// The decoded chunks NativeAEA's walkers and writers read: an AEA archive's segments, or a `pbz` stream's blocks,
/// each in a pool buffer, in order, failing with ``AEAError``.
typealias ChunkSource = OrderedBlockSource<AEAError>

/// An archive's segments, decoded in parallel and handed out in order.
typealias SegmentStream = ParallelBlockDecoder<AEASegmentStage>

extension AEAArchive {
    /// The archive's segments as a source (not yet running), decoded into a pool the engine sizes within the options'
    /// ``AEAReadOptions/bufferBudget``: a buffer per decoder, the options' extra ones, `heldBuffers` (writers'
    /// references), and one more; all of them, or `range` (a partial decryption's).
    ///
    /// - Parameters:
    ///   - consumerBuffers: What the consumer holds while it waits for its next segment (``ExtractionSink/walkBuffers(held:blockCapacity:)``).
    ///   - heldUntilActivated: What the consumer's side holds, beyond one buffer, until the pool's `activateAll()`, if
    ///     not `heldBuffers` and `consumerBuffers` from the start (``AEAPayload``).
    ///   - carryCapacity: The room before each segment's bytes for a header that starts in the segment before:
    ///     ``AppleArchive/headerCarryCapacity`` for the segments a walker reads, 0 for others.
    func segmentStream(
        _ options: AEAReadOptions, heldBuffers: Int = 0, consumerBuffers: Int = 1, heldUntilActivated: Int? = nil, segments range: Range<Int>? = nil,
        carryCapacity: Int
    ) throws(AEAError) -> SegmentStream {
        let stage = try AEASegmentStage(archive: self, verifyMACs: options.verifyMACs, verifyChecksums: options.verifyChecksums, input: options.input)
        // A decoder's read buffer: for positioned reads, and for decrypting (mapped input too).
        let scratch = options.input == .read || isEncrypted ? largestCompressedSegment + 64 : nil
        return SegmentStream(
            stage: stage, blocks: range ?? 0..<segments.count, format: DecompressionFormat(aeaSegment: rootHeader.compression),
            blockCapacity: rootHeader.segmentSize, decoders: options.decodeThreads, extraBuffers: options.extraBuffers,
            heldBuffers: heldBuffers, consumerBuffers: consumerBuffers, heldUntilActivated: heldUntilActivated, scratchCapacity: scratch,
            carryCapacity: carryCapacity, budget: options.bufferBudget
        )
    }
}

/// One segment's work on its decoder's task, as hooks around the engine's reading and decoding
/// (`BlockReadingStage`'s default `decode`): the engine reads the segment (a stored one straight into its output,
/// others into the read buffer) or takes it from the mapping; ``prepare(_:stored:into:)`` checks its MAC and decrypts
/// it (in place where it was read; from the mapping into the output or the read buffer); the engine decodes it (or
/// copies a stored one from the mapping); ``verify(_:raw:)`` checks its checksum.
struct AEASegmentStage: IndexedBlockStage, BlockReadingStage {
    typealias Failure = AEAError

    let archive: AEAArchive
    let verifyMACs: Bool
    let verifyChecksums: Bool
    /// The archive mapped read-only (Disk's `MappedFile`, read front to back), for ``SegmentInput/mapped``.
    let mapping: MappedFile?

    init(archive: AEAArchive, verifyMACs: Bool, verifyChecksums: Bool, input: SegmentInput) throws(AEAError) {
        self.archive = archive
        self.verifyMACs = verifyMACs
        self.verifyChecksums = verifyChecksums
        if input == .mapped {
            // The whole file: its size is the container's (checked when the archive opened).
            do throws(DiskError) {
                mapping = try archive.file.map(access: .sequential)
            } catch {
                throw AEAError(error)
            }
        } else {
            mapping = nil
        }
    }

    func block(_ index: Int) -> BlockJob {
        let segment = archive.segments[index]
        return BlockJob(
            index: index, rawOffset: segment.rawOffset, rawSize: segment.rawSize, storedSize: segment.compressedSize,
            fileOffset: segment.fileOffset
        )
    }

    @unsafe
    func read(at offset: Int, into destination: UnsafeMutableRawBufferPointer) throws(AEAError) {
        try unsafe AEAArchive.readFully(archive.file, at: offset, into: destination)
    }

    @unsafe
    func storedBytes(of job: BlockJob) -> UnsafeRawBufferPointer? {
        guard let mapping else { return nil }
        // Unsafe: a buffer into the mapping. Safe: within it (segment offsets are checked against the file's size when
        // the archive opens, and `buffer` checks again); the stage keeps the mapping while decoders run.
        return unsafe mapping.buffer(job.fileOffset..<(job.fileOffset + job.storedSize))
    }

    /// The segment's MAC over its stored bytes; then, for encrypted profiles, AES-CTR decryption into `destination`
    /// (in place when the engine read the segment there).
    @unsafe
    func prepare(_ job: BlockJob, stored: UnsafeRawBufferPointer, into destination: UnsafeMutableRawBufferPointer) throws(AEAError) -> Bool {
        if verifyMACs {
            try unsafe SegmentChecks.verifyMAC(archive, segment: job.index, stored: RawSpan(_unsafeBytes: stored)) // Valid for the call: safe.
        }
        guard archive.isEncrypted else { return false }
        // The engine gives the read buffer for compressed segments: `segmentStream` makes one whenever the archive is
        // encrypted.
        precondition(destination.count == stored.count, "an encrypted segment with nowhere to decrypt it")
        let key = archive.segmentKeys[job.index]
        // The output or the read buffer, this decoder's own, `storedSize` bytes: safe.
        var target = unsafe MutableRawSpan(_unsafeBytes: destination)
        if unsafe stored.baseAddress == UnsafeRawPointer(destination.baseAddress) {
            key.crypt(&target)
        } else {
            unsafe key.crypt(RawSpan(_unsafeBytes: stored), into: &target) // The mapping, valid for the call: safe.
        }
        return true
    }

    func verify(_ job: BlockJob, raw: RawSpan) throws(AEAError) {
        if verifyChecksums { try SegmentChecks.verifyChecksum(archive, segment: job.index, raw: raw) }
    }
}

/// A file read in `pbz` blocks or plain slices (an `.aar`, a `.xip`'s content): the engine's default reading, through
/// Disk's `InputFile`.
struct ArchiveFileStage: BlockReadingStage {
    typealias Failure = AEAError

    let file: InputFile

    @unsafe
    func read(at offset: Int, into destination: UnsafeMutableRawBufferPointer) throws(AEAError) {
        try unsafe AEAArchive.readFully(file, at: offset, into: destination)
    }
}
