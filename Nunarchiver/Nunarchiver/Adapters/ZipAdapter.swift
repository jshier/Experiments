import Disk
import Foundation
import NativeZip
import System

/// The one place Nunarchiver calls NativeZip.
///
/// Options are NativeZip's defaults (the same as `nunzip`'s), so the app expands as fast as the CLI, plus what Archive
/// Utility does that Info-ZIP doesn't: AppleDouble entries merged into their items (NativeZip's default), symbolic
/// links given their archived times, and names written in the file system's decomposed form. The extraction counts
/// into `progress` and sets its totals from the central directory.
///
/// The archive's quarantine is the staging directory's (its options', which NativeZip's `extract(into:)` takes): Disk's
/// writers set it on each file while it's open, and its passes after them on directories (the ones the archive doesn't
/// list too) and links, as for Apple archives. (Until NativeZip took it, a single-threaded walk here set it afterwards:
/// +0.7 s on an archive of 8,060 entries that expanded in 0.65 s.)
enum ZipAdapter {
    /// Opens the archive; an encrypted one asks for a password, or for another one if it doesn't open the first
    /// encrypted entry (its check bytes, or AES's verification value: no decryption), all before anything is staged.
    ///
    /// - Returns: The archive, and the password to extract it with (`nil` for one that isn't encrypted).
    static func open(_ archive: FilePath, credentials: ArchiveCredentials) throws -> (ZipArchive, password: String?) {
        let zip = try ZipArchive(url: URL(filePath: archive.string))
        let password = credentials[.password]
        guard let encrypted = zip.entries.first(where: \.isEncrypted) else { return (zip, password) }
        guard let password else { throw CredentialRequest(kind: .password) }
        // As nunzip checks before it extracts. Entries may use different passwords: one that fails later still asks
        // again (`extract`), discarding what was staged.
        guard zip.passwordMatches(password, for: encrypted) else { throw CredentialRequest(kind: .password, isRetry: true) }
        return (zip, password)
    }

    static func extract(_ zip: ZipArchive, password: String?, into staging: Destination, progress: ExtractionProgress) async throws {
        var options = ZipExtractionOptions()
        options.password = password
        options.progress = progress
        options.restoresLinkTimestamps = true
        options.decomposesNames = true
        do {
            try await zip.extract(into: staging, options: options)
        } catch ZipError.incorrectPassword {
            // Found at the first encrypted entry (its check bytes, or AES's verification value): ask again. What was
            // staged before it is discarded with the rest.
            throw CredentialRequest(kind: .password, isRetry: true)
        }
    }
}
