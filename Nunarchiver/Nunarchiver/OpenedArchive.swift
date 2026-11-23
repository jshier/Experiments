import Disk
import NativeAEA
import NativeZip
import System

/// The archive formats Nunarchiver expands: NativeAEA's `ArchiveKind` (`.zip` for NativeZip; `.aea`, `.aar`/`.yaa`, and
/// `.xip` for NativeAEA), recognized by their first bytes, then by extension.
extension ArchiveKind {
    /// The kind of the file at `archive`, for the app's alerts.
    ///
    /// - Throws: ``ExpansionFailure/system(call:path:code:)`` if the file can't be read,
    ///   ``ExpansionFailure/unrecognizedFormat(_:)`` if neither its first bytes nor its extension says.
    static func detect(_ archive: FilePath) throws -> ArchiveKind {
        let kind: ArchiveKind?
        do throws(AEAError) {
            kind = try ArchiveKind(detecting: archive)
        } catch {
            // Disk's call and `errno`, with the archive's own path (the alert names the file, not Disk's path).
            if case .disk(.system(let call, _, let code)) = error { throw ExpansionFailure.system(call: call, path: archive, code: code.rawValue) }
            throw error
        }
        guard let kind else { throw ExpansionFailure.unrecognizedFormat(archive.lastComponent?.string ?? archive.string) }
        return kind
    }

    /// Opens `archive` with the format's adapter and what the user has entered.
    ///
    /// - Throws: ``CredentialRequest`` if it needs a password or key that isn't there (or didn't work); the adapter's
    ///   errors for an archive that can't be read.
    func open(_ archive: FilePath, credentials: ArchiveCredentials) throws -> OpenedArchive {
        switch self {
        case .zip:
            let (zip, password) = try ZipAdapter.open(archive, credentials: credentials)
            return .zip(zip, password: password)
        case .appleEncryptedArchive:
            return .appleEncryptedArchive(try AppleArchiveAdapter.openEncryptedArchive(archive, credentials: credentials))
        case .appleArchive:
            return .appleArchive(try AppleArchiveAdapter.openArchive(archive))
        case .xip:
            return .xip(try AppleArchiveAdapter.openXIP(archive))
        }
    }
}

/// An archive opened and ready to extract: its directory or prologue read, its keys accepted.
enum OpenedArchive: Sendable {
    case zip(ZipArchive, password: String?)
    case appleEncryptedArchive(AEAArchive)
    case appleArchive(AppleArchiveFile)
    case xip(XIPArchive)

    /// Extracts into the staging directory: everything gets the staging directory's quarantine (its options').
    func extract(into staging: Destination, progress: ExtractionProgress) async throws {
        switch self {
        case let .zip(zip, password):
            try await ZipAdapter.extract(zip, password: password, into: staging, progress: progress)
        case .appleEncryptedArchive(let archive):
            try await archive.extract(into: staging, options: AppleArchiveAdapter.options(progress: progress))
        case .appleArchive(let archive):
            try await archive.extract(into: staging, options: AppleArchiveAdapter.options(progress: progress))
        case .xip(let archive):
            try await archive.extract(into: staging, options: AppleArchiveAdapter.options(progress: progress))
        }
    }
}
