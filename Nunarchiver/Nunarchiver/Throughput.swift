import Foundation

/// How fast an expansion is writing, for its row: **bytes of file contents written to disk per second**.
///
/// The bytes are the extraction's polled counter (`ExtractionProgress.bytes`): each file's own bytes as its writer
/// finishes writing them, before any APFS compression, so a compressed archive reads faster than the archive file is
/// consumed, and a `.xip`'s LZVN-stored files count at full size. Entries without contents (directories, links, a
/// `.xip`'s hard links) add nothing: the rate falls to zero while they're made.
///
/// The time is the polling timer's: one sample per tick of ``Archiver/pollInterval``, so the rate over the last `n`
/// ticks is the bytes gained across them divided by `n` intervals. The window is ``windowTicks`` ticks (2 s): long
/// enough to smooth the writers' bursts (a large file lands all at once), short enough to follow a change.
enum Throughput {
    /// The ticks a rate is averaged over.
    static let windowTicks = 8

    /// `samples` with `bytes` appended, trimmed to the window (one more sample than ticks).
    static func recording(_ bytes: Int, in samples: [Int]) -> [Int] {
        var samples = samples
        samples.append(bytes)
        if samples.count > windowTicks + 1 { samples.removeFirst(samples.count - windowTicks - 1) }
        return samples
    }

    /// The rate over `samples` (the counter at successive ticks, oldest first, `interval` apart): `nil` with fewer than
    /// two samples (no tick has passed), or if the counter went backwards (an expansion started over).
    static func bytesPerSecond(samples: [Int], interval: Duration) -> Double? {
        guard samples.count >= 2, let first = samples.first, let last = samples.last, last >= first else { return nil }
        let seconds = Double(samples.count - 1) * (interval / .seconds(1))
        guard seconds > 0 else { return nil }
        return Double(last - first) / seconds
    }

    /// The rate as the row shows it, `1.25 GB/s` or `312.4 MB/s`: the bytes of one second as Foundation formats a
    /// file's size (`ByteCountFormatStyle`'s `.file` style: the Finder's decimal units, the unit and digits chosen and
    /// written for `locale`), then "per second" from a localizable format. Foundation has no format style for a data
    /// rate (checked against the macOS 27 SDK's documentation: `Measurement` has no information-per-time dimension).
    /// `nil` for nothing written in the window (under a byte a second), or a rate that isn't a number.
    static func label(bytesPerSecond: Double, locale: Locale = .current) -> LocalizedStringResource? {
        guard bytesPerSecond >= 1, let bytes = Int64(exactly: bytesPerSecond.rounded()) else { return nil }
        let amount = bytes.formatted(.byteCount(style: .file).locale(locale))
        return LocalizedStringResource(
            "\(amount)/s", locale: locale, comment: "A rate: an amount of data (such as “312 MB”) written per second."
        )
    }
}
