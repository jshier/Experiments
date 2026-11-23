public import Disk

/// Why an archive couldn't be read, verified, or extracted.
public enum AEAError: Error, Sendable, Equatable, CustomStringConvertible, CancellationReporting {
    /// The file doesn't start with `AEA1`.
    case notAnAEAFile
    /// The profile number isn't one of the six.
    case unsupportedProfile(Int)
    /// The archive is encrypted and no key, or the wrong kind, was given: what it needs.
    case missingKey(String)
    /// A field of the prologue, root header, or a cluster header is invalid or cut short.
    case invalidHeader(String)
    /// The archive ends before its last segment.
    case truncated
    /// The prologue's signature doesn't verify with the signing key.
    case invalidSignature
    /// The signing key couldn't be found or trusted: no certificate chain in the auth data, a chain that doesn't
    /// evaluate as trusted, or a key file that doesn't parse.
    case untrustedSigningKey(String)
    /// An HMAC didn't match: the root header's, a cluster header's, a segment's, or the padding's.
    case authenticationFailed(String)
    /// A segment's decompressed bytes don't match its checksum.
    case checksumMismatch(segment: Int)
    /// A segment didn't decompress to its recorded size.
    case decompressionFailed(segment: Int, String)
    /// The segment compression isn't one this reader decodes.
    case unsupportedCompression(UInt8)
    /// The Apple Archive stream inside is malformed.
    case invalidArchive(String)
    /// An entry's path is absolute, has `..` or empty components, or contains NUL.
    case unsafePath(String)
    /// Reading the archive or writing what's in it failed: Disk's error as it threw it (the call, the path, and the
    /// `errno`; an entry that exists; a path that leads out of the destination; …).
    case disk(DiskError)
    /// The task was cancelled: the operation stopped early.
    case cancelled

    public var description: String {
        switch self {
        case .notAnAEAFile: "not an Apple Encrypted Archive"
        case .unsupportedProfile(let profile): "unknown profile \(profile)"
        case .missingKey(let what): "the archive is encrypted: it needs \(what)"
        case .invalidHeader(let what): "invalid header: \(what)"
        case .truncated: "the archive is truncated"
        case .invalidSignature: "the signature doesn't verify"
        case .untrustedSigningKey(let why): "untrusted signing key: \(why)"
        case .authenticationFailed(let what): "authentication failed: \(what)"
        case .checksumMismatch(let segment): "segment \(segment) doesn't match its checksum"
        case .decompressionFailed(let segment, let why): "segment \(segment) failed to decompress: \(why)"
        case .unsupportedCompression(let byte): "unsupported segment compression '\(Unicode.Scalar(byte))'"
        case .invalidArchive(let why): "invalid Apple Archive stream: \(why)"
        case .unsafePath(let path): "unsafe path: \(path)"
        case .disk(let error): error.description
        case .cancelled: "cancelled"
        }
    }

    /// Whether this is ``cancelled`` (or Disk's cancellation): for `DiskError.isCancellation(_:)`.
    public var isCancellation: Bool {
        switch self {
        case .cancelled, .disk(.cancelled): true
        default: false
        }
    }

    /// Disk's failure as the archive's: Disk's own as ``disk(_:)``, except what has a case here (an unsafe entry path, a
    /// source's ``AEAError``, an archive file that ends early, cancellation).
    init(_ error: DiskError) {
        switch error {
        case .unsafePath(let path): self = .unsafePath(path)
        // `InputFile` reading the archive: it ends before its format says.
        case .endOfFile: self = .truncated
        case .source(let error as AEAError): self = error
        case .cancelled: self = .cancelled
        default: self = .disk(error)
        }
    }
}
