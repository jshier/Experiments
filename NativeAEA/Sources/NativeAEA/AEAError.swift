public import System

/// Why an archive couldn't be read, verified, or extracted.
public enum AEAError: Error, Sendable, Equatable, CustomStringConvertible {
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
    /// A file system call failed.
    case fileSystem(String, Errno)
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
        case .fileSystem(let what, let errno): "\(what): \(errno)"
        case .cancelled: "cancelled"
        }
    }

    /// A file system error with the path it happened at; other errors as they are.
    func at(_ path: String) -> AEAError {
        if case .fileSystem(let what, let code) = self { return .fileSystem("\(what) \(path)", code) }
        return self
    }
}
