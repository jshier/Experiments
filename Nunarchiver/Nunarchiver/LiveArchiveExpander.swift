import BytesAsync
import Darwin
import Disk
import Foundation
import OSLog
import Synchronization
import System

/// The expander the app runs: one ``ExtractionProgress`` per running expansion, polled by the UI.
final class LiveArchiveExpander: ArchiveExpander {
    /// The app's one expander: the features that start expansions (``Expansion``) and the one that polls them
    /// (``Archiver``) must reach the same registry of running expansions.
    static let shared = LiveArchiveExpander()

    /// An expansion in flight: its counters, and what the first-fraction log line needs.
    private struct Running {
        let name: String
        let progress: ExtractionProgress
        let started: ContinuousClock.Instant
        /// Whether a poll has yet read a fraction the bar can show.
        var hasShownFraction = false
    }

    private let running = Mutex<[UUID: Running]>([:])

    private static let log = Logger(subsystem: "com.jonshier.Nunarchiver", category: "expansion")

    /// The App Nap opt-out held while anything expands, and how many expansions hold it.
    private let activity = Mutex<(count: Int, token: (any NSObjectProtocol)?)>((0, nil))

    func expand(_ archive: URL, id: UUID, credentials: ArchiveCredentials) async -> ExpansionOutcome {
        let progress = ExtractionProgress()
        let started = ContinuousClock.now
        running.withLock { $0[id] = Running(name: archive.lastPathComponent, progress: progress, started: started) }
        beginActivity()
        defer {
            running.withLock { $0[id] = nil }
            endActivity()
        }
        // The work runs in a child task at user-initiated priority, whatever the caller's: a GUI app in the background
        // (no window yet, not frontmost) otherwise ran its writers at background QoS, every thread at priority 4 on the
        // efficiency cores (Xcode's xip: minutes instead of 10 s). A child task keeps the caller's cancellation.
        let outcome = await withPriority(.userInitiated) { () async -> ExpansionOutcome in
            do {
                return .expanded(try await Expander.expand(FilePath(archive.path), credentials: credentials, progress: progress))
            } catch let request as CredentialRequest {
                return .needsCredential(request)
            } catch {
                if Task.isCancelled || DiskError.isCancellation(error) { return .cancelled }
                // The failure as the package reported it (the call and the path, for file system errors), for
                // diagnosing from the system log: `log show --predicate 'subsystem == "com.jonshier.Nunarchiver"'`.
                Self.log.error(
                    "\(archive.path, privacy: .public): failed: \(String(describing: error), privacy: .public) [\(String(reflecting: type(of: error)), privacy: .public)]"
                )
                return .failed(ExpansionFailure.message(error))
            }
        }
        // One line per archive (for timing the app against the packages' command-line tools).
        let seconds = (ContinuousClock.now - started) / .seconds(1)
        Self.log.notice(
            "\(archive.lastPathComponent, privacy: .public): \(Self.summary(outcome), privacy: .public) in \(seconds, format: .fixed(precision: 3), privacy: .public) s, \(progress.entries, privacy: .public) entries, \(progress.bytes, privacy: .public) bytes"
        )
        return outcome
    }

    /// An outcome for the log.
    private static func summary(_ outcome: ExpansionOutcome) -> String {
        switch outcome {
        case .expanded(let url): "expanded to \(url.path)"
        case .failed(let message): "failed (\(message))"
        case .cancelled: "cancelled"
        case .needsCredential(let request): "needs \(request.kind)\(request.isRetry ? " (again)" : "")"
        }
    }

    /// Opts out of App Nap and idle sleep while the first expansion runs, until the last one ends.
    private func beginActivity() {
        activity.withLock { state in
            state.count += 1
            if state.count == 1 {
                state.token = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled], reason: "Expanding archives"
                )
            }
        }
    }

    private func endActivity() {
        activity.withLock { state in
            state.count -= 1
            if state.count == 0, let token = state.token {
                ProcessInfo.processInfo.endActivity(token)
                state.token = nil
            }
        }
    }

    func progress(of id: UUID) -> ExpansionProgress? {
        guard let expansion = running.withLock({ $0[id] }) else { return nil }
        // Disk's reading: bytes and entries together, and a fraction that never goes back while the totals change under
        // a running extraction (an estimate of the bytes, then exact counts once the archive has been walked).
        let counted = expansion.progress.read()
        let reading = ExpansionProgress(entries: counted.entries, bytes: counted.bytes, fraction: counted.fraction)
        // Debug level: kept only while someone streams it (`log stream --level debug`), to watch the window's polls.
        Self.log.debug(
            "poll: \(counted.entries, privacy: .public) of \(counted.expectedEntries, privacy: .public) entries, \(counted.bytes, privacy: .public) of \(counted.expectedBytes, privacy: .public) bytes, \(counted.fraction ?? -1, format: .fixed(precision: 3), privacy: .public)"
        )
        if !expansion.hasShownFraction, let fraction = reading.barFraction {
            // Once per expansion: when its row's bar stopped being indeterminate. (The window polls only once it's
            // up, ``Archiver/windowDelay`` after the first expansion starts, so that's the earliest this can be.)
            running.withLock { $0[id]?.hasShownFraction = true }
            let seconds = (ContinuousClock.now - expansion.started) / .seconds(1)
            Self.log.debug(
                "\(expansion.name, privacy: .public): bar determinate \(seconds, format: .fixed(precision: 3), privacy: .public) s after starting, at \(fraction, format: .fixed(precision: 3), privacy: .public)"
            )
        }
        return reading
    }
}

/// Archive Utility's expansion, on Disk's staging directories.
enum Expander {
    /// Expands `archive` next to itself and returns what was published.
    ///
    /// 1. The archive is opened with what the user has entered (``CredentialRequest`` is thrown here, before anything
    ///    is made, if it needs more).
    /// 2. A staging directory, `.NAME.partial-XXXXXX`, is made beside the archive (`Destination.staging`).
    /// 3. The format's adapter extracts into it, counting into `progress`.
    /// 4. Disk publishes it as Archive Utility does (`Destination.publishUnwrapped`): one top-level item is moved out
    ///    under its own name; several are published together as a folder named after the archive (0700 and
    ///    quarantined, unless the archive's own entry for its root says otherwise). Taken names become `NAME 2`,
    ///    `NAME 3`.
    ///
    /// On failure or cancellation the staging directory is removed: nothing appears beside the archive.
    @concurrent
    static func expand(_ archive: FilePath, credentials: ArchiveCredentials, progress: ExtractionProgress) async throws -> URL {
        let format = try ArchiveFormat(detecting: archive)
        let folder = archive.removingLastComponent().appending(folderName(for: archive))
        let opened = try format.open(archive, credentials: credentials)
        // The archive's quarantine on everything expanded, the folder included, as Archive Utility leaves them; a
        // `.xip`'s contents get none (Archive Utility's, and `xip --expand`'s). Stated once, here: the staging
        // directory gets it now, and the packages give every entry their destination's.
        var options = DestinationOptions()
        options.quarantine = format == .xip ? nil : Quarantine(copyingFrom: archive)
        options.quarantinesDestination = true
        let staging = try Destination.staging(for: folder, options: options)
        do {
            try await opened.extract(into: staging, progress: progress)
            try Task.checkCancellation()
            return URL(filePath: try staging.publishUnwrapped(as: folder).string)
        } catch {
            staging.discard()
            throw error
        }
    }

    /// The archive's name without its extension: `Archive.zip` → `Archive`.
    static func folderName(for archive: FilePath) -> String {
        guard let name = archive.lastComponent else { return "Archive" }
        let stem = name.stem
        return stem.isEmpty ? name.string : stem
    }
}

/// Errors the app makes, and messages for every error the expanders throw.
enum ExpansionFailure: Error, CustomStringConvertible {
    /// A system call on the archive file failed with this `errno`.
    case system(call: String, path: FilePath, code: Int32)
    /// Neither the file's first bytes nor its extension (the name given) is an archive's.
    case unrecognizedFormat(String)
    /// The archive is encrypted for something the app has no prompt for (described here).
    case unsupportedKey(String)

    var description: String {
        switch self {
        case let .system(call, path, code):
            "\(call) “\(path.lastComponent?.string ?? path.string)”: \(Errno(rawValue: code).description)"
        case let .unrecognizedFormat(name):
            "“\(name)” isn’t a ZIP, Apple Archive, Apple Encrypted Archive, or XIP archive."
        case let .unsupportedKey(what):
            "The archive is encrypted for \(what), which Nunarchiver can’t ask for."
        }
    }

    /// The alert's message for any error the expansion throws: its description as a sentence. Every package's errors
    /// describe themselves (NativeAEA's and Disk's in lowercase without a period, ZipError's as sentences).
    static func message(_ error: any Error) -> String {
        // Cocoa's errors (an `NSError`'s `description` is its domain and code) by their localized description.
        if type(of: error) is NSError.Type { return (error as NSError).localizedDescription }
        let description = String(describing: error)
        let sentence = description.prefix(1).uppercased() + description.dropFirst()
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }
}
