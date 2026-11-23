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
    static func detect(_ archive: FilePath) throws(ExpansionError) -> ArchiveKind {
        let kind: ArchiveKind?
        do throws(AEAError) {
            kind = try ArchiveKind(detecting: archive)
        } catch {
            // Disk's call and `errno`, with the archive's own path (the alert names the file, not Disk's path).
            if case .disk(.system(let call, _, let code)) = error { throw .failure(.system(call: call, path: archive, code: code.rawValue)) }
            throw .appleArchive(error)
        }
        guard let kind else { throw .failure(.unrecognizedFormat(archive.lastComponent?.string ?? archive.string)) }
        return kind
    }

    /// Opens `archive` with the format's adapter and what the user has entered.
    ///
    /// - Throws: ``ExpansionError/credential(_:)`` if it needs a password or key that isn't there (or didn't work); the
    ///   adapter's errors for an archive that can't be read.
    func open(_ archive: FilePath, credentials: ArchiveCredentials) throws(ExpansionError) -> OpenedArchive {
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
    func extract(into staging: Destination, progress: ExtractionProgress) async throws(ExpansionError) {
        let options = AppleArchiveAdapter.options(progress: progress)
        switch self {
        case let .zip(zip, password):
            try await ZipAdapter.extract(zip, password: password, into: staging, progress: progress)
        case .appleEncryptedArchive(let archive):
            try await Self.apple { () async throws(AEAError) in try await archive.extract(into: staging, options: options) }
        case .appleArchive(let archive):
            try await Self.apple { () async throws(AEAError) in try await archive.extract(into: staging, options: options) }
        case .xip(let archive):
            try await Self.apple { () async throws(AEAError) in try await archive.extract(into: staging, options: options) }
        }
    }

    /// NativeAEA's errors as the expansion's.
    private static func apple(_ body: () async throws(AEAError) -> AEAStatistics) async throws(ExpansionError) {
        do throws(AEAError) {
            _ = try await body()
        } catch {
            throw .appleArchive(error)
        }
    }

    /// Closes the archive's file once it's read: the Apple formats keep a descriptor open from opening to here (a ZIP
    /// is a mapping, which needs none). Safe to call more than once.
    func close() {
        switch self {
        case .zip: break
        case .appleEncryptedArchive(let archive): archive.close()
        case .appleArchive(let archive): archive.close()
        case .xip(let archive): archive.close()
        }
    }
}
