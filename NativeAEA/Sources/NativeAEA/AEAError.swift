public import Bytes
import BytesCompression
public import BytesCompressionAsync
public import Disk

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
    /// The key or password given doesn't open the archive: the first MAC it derives fails (the root header's, or an
    /// encrypted signature's), which is what a wrong key fails, and what a damaged header does too (the two can't be
    /// told apart). What it failed on. An app asks for the key again on this.
    case incorrectKey(String)
    /// An HMAC didn't match: a cluster header's, a segment's, or the padding's (and the root header's on a signed,
    /// unencrypted archive).
    case authenticationFailed(String)
    /// A segment's decompressed bytes don't match its checksum.
    case checksumMismatch(segment: Int)
    /// A segment didn't decompress to its recorded size: the decoder's error (`BytesError/mismatch` for another size,
    /// `trailingData` for a stream that ended before its stored bytes did, `checksumMismatch` for a check inside the
    /// compressed data that fails, `unsupported` for valid data this reader can't decode: an xz filter other than
    /// LZMA2).
    case decompressionFailed(segment: Int, BytesError)
    /// A `pbz` block (an `.aar`'s, a `.xip`'s content's, or one of a `pbz` stream inside an archive's segments) didn't
    /// decompress to its recorded size: the decoder's error, as for ``decompressionFailed(segment:_:)``.
    case blockDecompressionFailed(block: Int, BytesError)
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
        case let .unsupportedProfile(profile): "unknown profile \(profile)"
        case let .missingKey(what): "the archive is encrypted: it needs \(what)"
        case let .invalidHeader(what): "invalid header: \(what)"
        case .truncated: "the archive is truncated"
        case .invalidSignature: "the signature doesn't verify"
        case let .untrustedSigningKey(why): "untrusted signing key: \(why)"
        case let .incorrectKey(what): "the key or password doesn't open the archive (\(what))"
        case let .authenticationFailed(what): "authentication failed: \(what)"
        case let .checksumMismatch(segment): "segment \(segment) doesn't match its checksum"
        case let .decompressionFailed(segment, .unsupported):
            "segment \(segment) uses a feature of its compression this reader doesn't support"
        case let .blockDecompressionFailed(block, .unsupported):
            "block \(block) uses a feature of its compression this reader doesn't support"
        case let .decompressionFailed(segment, why): "segment \(segment) failed to decompress: \(why)"
        case let .blockDecompressionFailed(block, why): "block \(block) failed to decompress: \(why)"
        case let .unsupportedCompression(byte): "unsupported segment compression '\(Unicode.Scalar(byte))'"
        case let .invalidArchive(why): "invalid Apple Archive stream: \(why)"
        case let .unsafePath(path): "unsafe path: \(path)"
        case let .disk(error): error.description
        case .cancelled: "cancelled"
        }
    }

    /// Whether this is ``cancelled`` (or Disk's cancellation).
    public var isCancellation: Bool {
        switch self {
        case .cancelled, .disk(.cancelled): true
        default: false
        }
    }

    /// Disk's failure as the archive's: Disk's own as ``disk(_:)``, except what has a case here (an unsafe entry path,
    /// an archive file that ends early, cancellation).
    init(_ error: DiskError) {
        switch error {
        case let .unsafePath(path): self = .unsafePath(path)
        // `InputFile` reading the archive: it ends before its format says.
        case .endOfFile: self = .truncated
        case .cancelled: self = .cancelled
        default: self = .disk(error)
        }
    }
}

extension AEAError: BlockDecodingFailure {
    /// The decoding engine's failure (BytesCompressionAsync's, decoding segments and `pbz` blocks) as the archive's: a
    /// block that didn't decode as ``decompressionFailed(segment:_:)`` (an indexed stream's: the archive's segments) or
    /// ``blockDecompressionFailed(block:_:)`` (a `pbz` stream's), framing as ``invalidArchive(_:)``, a block of an
    /// uncompressed stream that isn't stored as ``unsupportedCompression(_:)`` (`-`), cancellation as ``cancelled``.
    public init(_ error: BlockDecodingError) {
        switch error {
        case .cancelled: self = .cancelled
        case let .decoding(error, block, .indexed): self = .decompressionFailed(segment: block, error)
        case let .decoding(error, block, .pbz), let .decoding(error, block, .slice): self = .blockDecompressionFailed(block: block, error)
        case .notCompressed: self = .unsupportedCompression(AppleArchiveCompression.none.rawValue)
        case let .framing(error): self = .invalidArchive(error.description)
        }
    }
}
