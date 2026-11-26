import ComposableArchitecture
import Foundation
import IssueReporting

/// Expands archives: the boundary between the features and the file system, so tests control it.
///
/// ``expand(_:id:credentials:)`` does the whole job (staging, extraction, naming, publishing or discarding) and never
/// throws: cancellation of the calling task is reported as ``ExpansionOutcome/cancelled`` after the staging directory
/// is removed, and an archive that can't be opened without a password or key as
/// ``ExpansionOutcome/needsCredential(_:)`` (nothing staged), for the feature to ask and call again.
/// ``progress(of:)`` is polled by the app feature a few times a second while the progress window is up; it reads the
/// extraction's counters and nothing is ever pushed to the UI.
public protocol ArchiveExpander: Sendable {
    /// Expands `archive` next to itself. `id` names it for ``progress(of:)`` while it runs.
    func expand(_ archive: URL, id: UUID, credentials: ArchiveCredentials) async -> ExpansionOutcome
    /// Where the expansion `id` has got, or `nil` if it isn't running (not started yet, or finished).
    func progress(of id: UUID) -> ExpansionProgress?
}

/// What an archive can need from the user before it opens.
public enum CredentialKind: Hashable, Sendable {
    /// A password: an encrypted ZIP (ZipCrypto, WinZip AES), or an `.aea` of the password profile.
    case password
    /// An `.aea`'s 32-byte symmetric key, as `aea -key-value` takes it (hex or `base64:…`).
    case key
    /// The public key of whoever signed an `.aea` that carries no certificate chain (a PEM, or the X9.63 point in hex
    /// or `base64:…`). Not a secret, but the archive can't be verified or read without it.
    case signingPublicKey
}

/// What the user has entered for an archive so far, by kind.
public struct ArchiveCredentials: Equatable, Sendable {
    public var values: [CredentialKind: String] = [:]

    public init(values: [CredentialKind: String] = [:]) {
        self.values = values
    }

    public subscript(kind: CredentialKind) -> String? {
        get { values[kind] }
        set { values[kind] = newValue }
    }
}

/// An archive can't be opened without `kind`. `isRetry`: one was given and didn't work.
public struct CredentialRequest: Equatable, Error, Sendable {
    public var kind: CredentialKind
    public var isRetry = false

    public init(kind: CredentialKind, isRetry: Bool = false) {
        self.kind = kind
        self.isRetry = isRetry
    }
}

/// How an expansion ended.
public enum ExpansionOutcome: Equatable, Sendable {
    /// Published at this URL (the single top-level item, or the folder holding several).
    case expanded(URL)
    /// Failed with this message; nothing was left behind.
    case failed(String)
    /// Cancelled; nothing was left behind.
    case cancelled
    /// Not expanded: the archive needs this first. Nothing was left behind.
    case needsCredential(CredentialRequest)
}

/// A progress reading: the extraction's relaxed counters, summed.
public struct ExpansionProgress: Equatable, Sendable {
    /// Entries written so far.
    public var entries = 0
    /// Bytes of file contents written to disk so far (the files' own sizes, before any APFS compression).
    public var bytes = 0
    /// Done, from 0 to 1, when the totals are known: Disk's `ExtractionProgress.read()`, by bytes and entries together
    /// (each entry as 64 KiB, so a `.xip`'s hard links, which write no bytes, move the bar), never going back.
    public var fraction: Double?

    public init(entries: Int = 0, bytes: Int = 0, fraction: Double? = nil) {
        self.entries = entries
        self.bytes = bytes
        self.fraction = fraction
    }

    /// Everything counted is written and the expansion hasn't ended: what's left is counted by nothing (directories'
    /// permissions and times, moving the result into place). The row says so instead of showing a full bar.
    public var isFinishing: Bool {
        (fraction ?? 0) >= 1
    }

    /// The percent a row reports (VoiceOver's value, the first-fraction log line): `nil` until the extraction has
    /// counted anything, and again for the moment it's finishing. The bar itself is always determinate, drawn from
    /// ``fraction`` (empty without one).
    public var barFraction: Double? {
        guard !isFinishing else { return nil }
        return entries > 0 || (fraction ?? 0) > 0 ? fraction : nil
    }
}

/// Archive Utility-like conveniences around a finished expansion.
public protocol Workspace: Sendable {
    /// Whether finished expansions are revealed (the Settings toggle).
    var revealsExpandedItems: Bool { get }
    /// Selects `url` in the Finder.
    func reveal(_ url: URL) async
}

public extension FeatureEnvironmentValues {
    @FeatureEnvironmentEntry(
        liveValue: LiveArchiveExpander.shared,
        previewValue: PreviewArchiveExpander()
    )
    var archiveExpander: any ArchiveExpander = UnimplementedArchiveExpander()

    @FeatureEnvironmentEntry(
        liveValue: LiveWorkspace(),
        previewValue: PreviewWorkspace()
    )
    var workspace: any Workspace = UnimplementedWorkspace()
}

// MARK: Test and preview values

struct UnimplementedArchiveExpander: ArchiveExpander {
    func expand(_ archive: URL, id: UUID, credentials: ArchiveCredentials) async -> ExpansionOutcome {
        reportIssue("UnimplementedArchiveExpander.\(#function)")
        return .failed("unimplemented")
    }

    func progress(of id: UUID) -> ExpansionProgress? {
        reportIssue("UnimplementedArchiveExpander.\(#function)")
        return nil
    }
}

/// Never finishes, always half done: for SwiftUI previews.
struct PreviewArchiveExpander: ArchiveExpander {
    func expand(_ archive: URL, id: UUID, credentials: ArchiveCredentials) async -> ExpansionOutcome {
        try? await Task.sleep(for: .seconds(1_000_000))
        return .cancelled
    }

    func progress(of id: UUID) -> ExpansionProgress? {
        ExpansionProgress(entries: 1_234, bytes: 1_234_000_000, fraction: 0.5)
    }
}

struct UnimplementedWorkspace: Workspace {
    var revealsExpandedItems: Bool {
        reportIssue("UnimplementedWorkspace.\(#function)")
        return false
    }

    func reveal(_ url: URL) async {
        reportIssue("UnimplementedWorkspace.\(#function)")
    }
}

struct PreviewWorkspace: Workspace {
    var revealsExpandedItems: Bool { false }
    func reveal(_ url: URL) async {}
}
