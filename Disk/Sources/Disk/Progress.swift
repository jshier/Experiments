import Darwin
import Synchronization

/// How far an extraction has got: entries and bytes written so far, against the totals the caller expects (an
/// archive's entry and byte counts, when it has them). A client (an app's progress bar) reads it whenever it likes, a
/// few times a second from a timer, say; the writers never publish anything.
///
/// Each worker counts in a slot of its own, one relaxed atomic add per entry (and per piece of a large file), on a
/// cache line of its own; reading sums the slots. Measured: no difference in instructions per entry with and without
/// it (Disk/RESULTS.md).
///
/// ```swift
/// let progress = ExtractionProgress(expectedEntries: archive.entryCount, expectedBytes: archive.uncompressedSize)
/// var options = ExtractionSettings()
/// options.progress = progress
/// // A timer: progressView.value = progress.fractionCompleted ?? 0
/// ```
public final class ExtractionProgress: Sendable {
    /// One counter pair per worker: two `Atomic<Int>`s padded to 128 bytes (Apple silicon's cache line), so workers
    /// don't share lines.
    final class Slot: Sendable {
        let entries = Atomic<Int>(0)
        let bytes = Atomic<Int>(0)
        // Padding: 14 words, so two slots' counters never share a line.
        private let padding: (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        @inline(__always)
        func add(entries count: Int, bytes byteCount: Int) {
            if count != 0 { entries.add(count, ordering: .relaxed) }
            if byteCount != 0 { bytes.add(byteCount, ordering: .relaxed) }
        }
    }

    /// Slots handed to workers by index (wrapping).
    let slots: [Slot]
    private let expected: Mutex<(entries: Int, bytes: Int)>

    /// Progress against `expectedEntries` and `expectedBytes` (0: unknown).
    public init(expectedEntries: Int = 0, expectedBytes: Int = 0) {
        slots = (0..<64).map { _ in Slot() }
        expected = Mutex((expectedEntries, expectedBytes))
    }

    /// Sets the totals, when they're learned after the extraction starts.
    public func setExpected(entries: Int, bytes: Int) {
        expected.withLock { $0 = (entries, bytes) }
    }

    /// Adds to the totals: a client learning them as it goes (archives added one at a time). Negative counts take
    /// entries back off (ones it then skipped).
    /// The totals saturate at `Int.max` (and `Int.min`) rather than overflow: they're the archives' claims, which a
    /// damaged or hostile archive makes as large as it likes.
    public func addExpected(entries: Int, bytes: Int) {
        expected.withLock { $0 = (Self.saturating($0.entries, entries), Self.saturating($0.bytes, bytes)) }
    }

    /// `a + b`, saturating.
    private static func saturating(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? .max : .min) : sum
    }

    /// Entries made so far: directories, files, links, and special files.
    public var entries: Int { slots.reduce(0) { $0 + $1.entries.load(ordering: .relaxed) } }

    /// Bytes of file contents written so far (before compression).
    public var bytes: Int { slots.reduce(0) { $0 + $1.bytes.load(ordering: .relaxed) } }

    public var expectedEntries: Int { expected.withLock { $0.entries } }
    public var expectedBytes: Int { expected.withLock { $0.bytes } }

    /// The furthest fraction any ``read(entryWeight:)`` has returned, as its bit pattern (non-negative doubles order as
    /// their bit patterns do), so readings never go back.
    private let furthest = Atomic<UInt64>(0)

    /// One reading of the counters and totals, with the fraction done.
    public struct Reading: Sendable, Equatable {
        /// Entries made so far.
        public var entries: Int
        /// Bytes of file contents written so far (before compression).
        public var bytes: Int
        /// The totals expected (0: not known).
        public var expectedEntries: Int
        public var expectedBytes: Int
        /// Done, from 0 to 1, by bytes and entries together; `nil` when neither total is known. Never less than an
        /// earlier reading's.
        public var fraction: Double?

        public init(entries: Int = 0, bytes: Int = 0, expectedEntries: Int = 0, expectedBytes: Int = 0, fraction: Double? = nil) {
            self.entries = entries
            self.bytes = bytes
            self.expectedEntries = expectedEntries
            self.expectedBytes = expectedBytes
            self.fraction = fraction
        }
    }

    /// What an entry weighs against bytes of contents in ``read(entryWeight:)``: 64 KiB. Roughly what making one costs
    /// (Xcode's archives on an M3 Ultra: about 30,000 entries a second where contents are written at 1.5 to 2.5 GB a
    /// second); it only has to keep a bar moving at a believable pace through both kinds of work.
    public static let defaultEntryWeight = 65_536

    /// The counters and totals, and the fraction done by both together.
    ///
    /// Bytes alone leave out the work that writes none: a `.xip`'s hard links (a third of Xcode's expansion, during
    /// which a bar by bytes sat full), symbolic links, and directories. Entries alone would stall on a large file. So
    /// each entry counts as `entryWeight` bytes on both sides of the ratio (``fraction(entries:of:bytes:of:entryWeight:)``).
    ///
    /// The totals change under a running extraction (an estimate of the bytes, then exact counts once an archive has
    /// been walked; more as archives are added), and the fraction with them: a reading's fraction is never less than
    /// an earlier one's (kept in an atomic, whatever the weight), so a bar never goes back. Several clients may read.
    public func read(entryWeight: Int = ExtractionProgress.defaultEntryWeight) -> Reading {
        let (entryTotal, byteTotal) = expected.withLock { $0 }
        var reading = Reading(entries: entries, bytes: bytes, expectedEntries: entryTotal, expectedBytes: byteTotal)
        if let fraction = Self.fraction(entries: reading.entries, of: entryTotal, bytes: reading.bytes, of: byteTotal, entryWeight: entryWeight) {
            let (_, kept) = furthest.max(fraction.bitPattern, ordering: .relaxed)
            reading.fraction = Double(bitPattern: kept)
        }
        return reading
    }

    /// How far along an extraction is, from 0 to 1, by its bytes and its entries together: `nil` when neither total is
    /// known, by whichever is when only one is. Counts past a total (counters run ahead of an estimate) count as the
    /// total; negative ones as none.
    ///
    /// - Parameters:
    ///   - entries: Entries made so far.
    ///   - expectedEntries: The entries in all (0: not known).
    ///   - bytes: Bytes of contents written so far.
    ///   - expectedBytes: The bytes in all (0: not known).
    ///   - entryWeight: What an entry counts as, in bytes.
    public static func fraction(
        entries: Int, of expectedEntries: Int, bytes: Int, of expectedBytes: Int, entryWeight: Int = defaultEntryWeight
    ) -> Double? {
        guard expectedEntries > 0 || expectedBytes > 0 else { return nil }
        let weight = Double(max(0, entryWeight))
        let done = (expectedBytes > 0 ? Double(max(0, min(bytes, expectedBytes))) : 0)
            + (expectedEntries > 0 ? Double(max(0, min(entries, expectedEntries))) * weight : 0)
        let total = Double(max(0, expectedBytes)) + Double(max(0, expectedEntries)) * weight
        guard total > 0 else { return nil }
        return min(1, max(0, done / total))
    }

    /// The fraction done, as ``read(entryWeight:)`` reads it (bytes and entries, entries weighing 64 KiB; never going
    /// back); `nil` with no totals.
    public var fractionCompleted: Double? { read().fraction }

    /// Worker `index`'s slot.
    @inline(__always)
    func slot(_ index: Int) -> Slot { slots[index & 63] }
}

/// Defaults derived from the machine.
public enum DiskDefaults {
    /// Performance cores (`hw.perflevel0.physicalcpu`; all cores where there are no levels).
    static let performanceCores: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Unsafe: `sysctlbyname` writes through pointers to `count` and `size`. Safe: locals that outlive the call;
        // `size` is `count`'s size, so at most an `Int32` is written (both of these integer values are `Int32`s).
        if unsafe sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        // Unsafe: `sysctlbyname` again, the same pointers. Safe: as above (`size` is still at most 4).
        if unsafe sysctlbyname("hw.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return 4
    }()

    /// Writers: one per performance core (compression is CPU work; queue-fed workers gain from more).
    public static var writers: Int { performanceCores }

    /// Writers in file system calls at once: a quarter of the performance cores, from 2 to 6. Measured on the M3 Ultra
    /// (24 performance cores): APFS creation peaked at 4 threads in a microbenchmark and an Xcode extraction at 6 (4: 11.2
    /// s, 6: 9.9 s, 8: 10.5 s, 12: 11.3 s); Disk's sweeps are in Disk/RESULTS.md. Other machines aren't measured: set
    /// ``ExtractionSettings/fileSystemWidth`` to tune.
    public static var fileSystemWidth: Int { min(6, max(2, performanceCores / 4)) }

    /// Raises the process's soft descriptor limit as far as the system allows (directory descriptors).
    static func raiseDescriptorLimit() {
        var limit = rlimit()
        // Unsafe: `getrlimit` writes through a pointer to `limit`. Safe: a local `rlimit`, the type the call fills.
        guard unsafe getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        var perProcess: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Unsafe: `sysctlbyname` writes through pointers to `perProcess` and `size`. Safe: locals that outlive the
        // call; `size` is `perProcess`'s size, so at most an `Int32` (this value's type) is written.
        let maximum = unsafe sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0 ? rlim_t(perProcess) : limit.rlim_max
        let wanted = min(limit.rlim_max, maximum)
        if limit.rlim_cur < wanted {
            limit.rlim_cur = wanted
            // Unsafe: `setrlimit` reads through a pointer to `limit`. Safe: the local `rlimit`, read during the call.
            _ = unsafe setrlimit(RLIMIT_NOFILE, &limit)
        }
    }
}
