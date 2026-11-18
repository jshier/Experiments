import Bytes
import Foundation
import Synchronization
import System

/// How segments' stored bytes are read from the archive.
public enum SegmentInput: String, Sendable, CaseIterable {
    /// Positioned reads into one buffer per decoding thread: memory bounded by the threads.
    case read
    /// The whole archive mapped, decoders reading the mapping: no copy, the kernel pages it in.
    case mapped
}

/// Decodes an archive's segments on several threads and hands them out in order.
///
/// Each thread takes a free buffer from the pool, then the next segment (in that order, so the segment the
/// consumer waits for always has a buffer), reads and checks it, decodes it into the buffer, checks the
/// checksum, and publishes it. The consumer calls ``next(_:)`` for segments 0, 1, 2... and releases each buffer
/// through the pool when it's done with it.
final class SegmentStream: @unchecked Sendable {
    let archive: AEAArchive
    let pool: SegmentBufferPool
    private let threadCount: Int
    private let backend: SegmentDecoderBackend
    private let verifyMACs: Bool
    private let verifyChecksums: Bool
    private let input: SegmentInput
    private let mapping: RawMapping?

    private let nextSegment = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)
    private let ready = NSCondition()
    // Guarded by `ready`: each segment's buffer once decoded, and the first error.
    private var slots: [Int]
    private var failure: AEAError?
    private let group = DispatchGroup()

    /// Nanoseconds the threads spent reading, checking, and decoding, summed.
    let busyNanoseconds = Atomic<Int>(0)
    let readNanoseconds = Atomic<Int>(0)
    /// Nanoseconds the consumer waited for segments.
    let waitNanoseconds = Atomic<Int>(0)

    init(
        archive: AEAArchive, pool: SegmentBufferPool, threads: Int, backend: SegmentDecoderBackend,
        verifyMACs: Bool, verifyChecksums: Bool, input: SegmentInput
    ) throws(AEAError) {
        self.archive = archive
        self.pool = pool
        threadCount = max(1, min(threads, archive.segments.count))
        self.backend = backend
        self.verifyMACs = verifyMACs
        self.verifyChecksums = verifyChecksums
        self.input = input
        mapping = input == .mapped ? try RawMapping(archive.descriptor, count: archive.rootHeader.containerSize) : nil
        slots = Array(repeating: -1, count: archive.segments.count)
    }

    func start() {
        for _ in 0..<threadCount {
            group.enter()
            let thread = Thread { [self] in
                decodeLoop()
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// Waits for segment `index` and returns its buffer.
    func next(_ index: Int) throws(AEAError) -> Int {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { waitNanoseconds.add(Int(DispatchTime.now().uptimeNanoseconds - start), ordering: .relaxed) }
        ready.lock()
        defer { ready.unlock() }
        while slots[index] < 0 {
            if let failure { throw failure }
            ready.wait()
        }
        return slots[index]
    }

    /// Stops decoding and waits for the threads, releasing buffers decoded but not consumed from `consumed` on.
    func finish(consumedThrough consumed: Int) {
        cancelled.store(true, ordering: .relaxed)
        // Threads waiting for a buffer get one back as unconsumed segments are released.
        var released = consumed
        while group.wait(timeout: .now() + .milliseconds(5)) == .timedOut {
            released = releaseReady(from: released)
        }
        _ = releaseReady(from: released)
    }

    private func releaseReady(from start: Int) -> Int {
        ready.lock()
        var index = start
        var buffers: [Int] = []
        while index < slots.count, slots[index] >= 0 {
            buffers.append(slots[index])
            slots[index] = -2
            index += 1
        }
        // Skip segments no thread will decode.
        ready.unlock()
        for buffer in buffers { pool.release(buffer) }
        return index
    }

    private func decodeLoop() {
        var codec = SegmentCodec(compression: archive.rootHeader.compression, backend: backend)
        let readBuffer = input == .read ? RawStorage(byteCount: archive.largestCompressedSegment + 64) : nil
        while !cancelled.load(ordering: .relaxed) {
            let buffer = pool.acquire()
            let index = nextSegment.add(1, ordering: .relaxed).oldValue
            guard index < archive.segments.count, !cancelled.load(ordering: .relaxed) else {
                pool.release(buffer)
                return
            }
            let started = DispatchTime.now().uptimeNanoseconds
            do throws(AEAError) {
                try decode(index, into: buffer, codec: &codec, readBuffer: readBuffer)
            } catch {
                pool.release(buffer)
                ready.lock()
                if failure == nil { failure = error }
                ready.broadcast()
                ready.unlock()
                cancelled.store(true, ordering: .relaxed)
                return
            }
            busyNanoseconds.add(Int(DispatchTime.now().uptimeNanoseconds - started), ordering: .relaxed)
            ready.lock()
            slots[index] = buffer
            ready.broadcast()
            ready.unlock()
        }
    }

    private func decode(_ index: Int, into buffer: Int, codec: inout SegmentCodec, readBuffer: RawStorage?) throws(AEAError) {
        let segment = archive.segments[index]
        let stored: UnsafeRawBufferPointer
        if let mapping {
            unsafe stored = mapping.buffer(segment.fileOffset, segment.compressedSize)
        } else {
            let readBuffer = readBuffer!
            let readStart = DispatchTime.now().uptimeNanoseconds
            // The read buffer holds the largest segment: `compressedSize` fits.
            let destination = unsafe UnsafeMutableRawBufferPointer(start: readBuffer.base, count: segment.compressedSize)
            try unsafe AEAArchive.readFully(archive.descriptor, at: segment.fileOffset, into: destination).get()
            readNanoseconds.add(Int(DispatchTime.now().uptimeNanoseconds - readStart), ordering: .relaxed)
            unsafe stored = UnsafeRawBufferPointer(destination)
        }
        if verifyMACs {
            try unsafe SegmentChecks.verifyMAC(archive, segment: index, stored: RawSpan(_unsafeBytes: stored)) // `stored` outlives the call: safe.
        }
        // The buffer is this thread's until it's published: nothing else writes it.
        let output = unsafe UnsafeMutableRawBufferPointer(start: pool.segmentBase(buffer), count: segment.rawSize)
        try unsafe codec.decode(stored, into: output, segment: index)
        if verifyChecksums {
            try unsafe SegmentChecks.verifyChecksum(archive, segment: index, raw: RawSpan(_unsafeBytes: UnsafeRawBufferPointer(output))) // Same.
        }
    }
}

/// The archive mapped read-only, for ``SegmentInput/mapped``.
@safe
final class RawMapping: @unchecked Sendable {
    private let base: UnsafeRawPointer
    let count: Int

    init(_ descriptor: FileDescriptor, count: Int) throws(AEAError) {
        let mapping = unsafe mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor.rawValue, 0)
        guard unsafe mapping != MAP_FAILED, let mapping = unsafe mapping else {
            throw .fileSystem("mmap", Errno(rawValue: errno))
        }
        unsafe madvise(mapping, count, MADV_SEQUENTIAL)
        unsafe base = UnsafeRawPointer(mapping)
        self.count = count
    }

    deinit {
        unsafe munmap(UnsafeMutableRawPointer(mutating: base), count)
    }

    /// The mapped bytes at `offset`: valid while `self` lives.
    ///
    /// - Precondition: The range is within the file (segment offsets are checked against its size when the archive opens).
    func buffer(_ offset: Int, _ count: Int) -> UnsafeRawBufferPointer {
        precondition(offset >= 0 && offset + count <= self.count)
        return unsafe UnsafeRawBufferPointer(start: base + offset, count: count)
    }
}
