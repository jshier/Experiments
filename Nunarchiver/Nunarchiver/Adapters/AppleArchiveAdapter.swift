import Disk
import NativeAEA
import System

/// The one place Nunarchiver calls NativeAEA: `.aea`, `.aar`, and `.xip`.
///
/// Options are NativeAEA's defaults (the same as its `nunarchiver` command's), so the app expands as fast as the CLI,
/// plus what Archive Utility does that `aa extract` and `xip --expand` don't: the archive's entry for its root sets the
/// folder's mode and times, and a `.xip`'s directories get the times its cpio stream records. The extraction counts
/// into `progress` and sets its totals itself.
enum AppleArchiveAdapter {
    /// Opens an `.aar`.
    static func openArchive(_ archive: FilePath) throws(ExpansionError) -> AppleArchiveFile {
        do throws(AEAError) { return try AppleArchiveFile(path: archive) } catch { throw .appleArchive(error) }
    }

    /// Opens a `.xip`, verifying its signature.
    static func openXIP(_ archive: FilePath) throws(ExpansionError) -> XIPArchive {
        do throws(AEAError) { return try XIPArchive(path: archive) } catch { throw .appleArchive(error) }
    }

    /// Opens an `.aea`, verifying its signature and keys; one that needs a key the user hasn't entered (or entered
    /// wrongly) asks for it, before anything is staged.
    ///
    /// - Profile 0 (signed, Xcode's): no key. The signature is checked against the certificate chain in the archive,
    ///   up to Apple's root. Without a chain (`aea encrypt -sign-priv`'s own archives; Archive Utility fails on these
    ///   with "Error 22"), the signer's public key is asked for.
    /// - Profiles 1 and 2: the symmetric key. Profile 5: the password.
    /// - Profiles 3 and 4 (a recipient's private key): not asked for; reported as unsupported.
    static func openEncryptedArchive(_ archive: FilePath, credentials: ArchiveCredentials) throws(ExpansionError) -> AEAArchive {
        let profile: AEAProfile
        do throws(AEAError) { profile = try AEAArchive.profile(at: archive) } catch { throw .appleArchive(error) }
        var decryptionKey: AEADecryptionKey?
        var decryptionKind: CredentialKind?
        switch profile {
        case .signed:
            break
        case .symmetric, .symmetricSigned:
            guard let text = credentials[.key] else { throw .credential(CredentialRequest(kind: .key)) }
            // Text that isn't a 32-byte key in hex or base64: ask again.
            guard case let .symmetric(key)? = try? AEADecryptionKey.symmetric(text: text), key.count == 32 else {
                throw .credential(CredentialRequest(kind: .key, isRetry: true))
            }
            decryptionKey = .symmetric(key)
            decryptionKind = .key
        case .scrypt:
            guard let password = credentials[.password] else { throw .credential(CredentialRequest(kind: .password)) }
            decryptionKey = .password(Array(password.utf8))
            decryptionKind = .password
        case .ecdhe, .ecdheSigned:
            throw .failure(.unsupportedKey("a recipient’s private key"))
        }
        var signingKey = AEASigningKey.certificateChain
        if let text = credentials[.signingPublicKey] {
            guard let key = try? AEASigningKey.publicKey(text: text) else { throw .credential(CredentialRequest(kind: .signingPublicKey, isRetry: true)) }
            signingKey = key
        }
        do throws(AEAError) {
            return try AEAArchive(path: archive, signingKey: signingKey, decryptionKey: decryptionKey)
        } catch {
            switch error {
            case .untrustedSigningKey where profile.isSigned && credentials[.signingPublicKey] == nil:
                // No certificate chain to take the signer from (or one that doesn't lead to Apple's root).
                throw .credential(CredentialRequest(kind: .signingPublicKey))
            case .invalidSignature where credentials[.signingPublicKey] != nil:
                throw .credential(CredentialRequest(kind: .signingPublicKey, isRetry: true))
            case .incorrectKey:
                // The root header's MAC (or the encrypted signature's): the first thing a wrong key or password fails.
                if let decryptionKind { throw .credential(CredentialRequest(kind: decryptionKind, isRetry: true)) }
                throw .appleArchive(error)
            default:
                throw .appleArchive(error)
            }
        }
    }

    /// The options every Apple format is extracted with. What everything extracted is quarantined with is the staging
    /// directory's (its options', which NativeAEA's `extract(into:)` takes).
    static func options(progress: ExtractionProgress) -> AEAExtractionOptions {
        var options = AEAExtractionOptions()
        options.disk.progress = progress
        // Archive Utility's: the folder it makes has the archive's root entry's mode and times, and a `.xip`'s
        // directories the times recorded for them.
        options.restoresDestinationMetadata = true
        options.restoresXIPDirectoryTimes = true
        return options
    }
}
