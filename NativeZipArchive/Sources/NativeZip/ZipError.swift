/// An error from reading, verifying, or extracting a zip archive.
///
/// The `String` payloads name the entry or the structure being read. Errors from the file system (for example
/// `Errno` from `System`) are thrown as themselves, not wrapped.
public enum ZipError: Error, CustomStringConvertible {
    /// No end of central directory record was found: the file isn't a zip archive, or is truncated.
    case notAZipArchive
    /// The archive ended while reading the named structure.
    case truncated(String)
    /// A record didn't start with its expected signature; the payload names the record.
    case badSignature(String)
    /// The archive is split across several disks, which isn't supported.
    case multiDiskUnsupported
    /// The named entry is encrypted and no password was given.
    case passwordRequired(String)
    /// The password doesn't decrypt the named entry.
    case incorrectPassword(String)
    /// The named AES-encrypted entry's authentication code doesn't match: it's corrupt or was altered.
    case authenticationFailed(String)
    /// The named entry uses an encryption scheme that can't be read (PKWARE's strong encryption).
    case unsupportedEncryption(String)
    /// The named entry uses a compression method that can't be read (see ``ZipArchive/Method``).
    case unsupportedMethod(UInt16, String)
    /// The named entry's decompressed data doesn't match its recorded CRC-32.
    case crcMismatch(String, expected: UInt32, actual: UInt32)
    /// The named stored entry's size doesn't match its recorded size. (A compressed entry reports
    /// ``corruptData(_:)`` instead.)
    case sizeMismatch(String, expected: UInt64, actual: UInt64)
    /// The named entry's path would be written outside the destination (absolute, or `..` traversal).
    case unsafePath(String)
    /// The named entry's compressed data is invalid, truncated, or decompresses to the wrong size.
    case corruptData(String)

    public var description: String {
        switch self {
        case .notAZipArchive: "Not a zip archive (end of central directory not found)."
        case let .truncated(what): "Archive is truncated while reading \(what)."
        case let .badSignature(what): "Bad signature for \(what)."
        case .multiDiskUnsupported: "Multi-disk (spanned) archives are not supported."
        case let .passwordRequired(name): "'\(name)' is encrypted; a password is required."
        case let .incorrectPassword(name): "Incorrect password for '\(name)'."
        case let .authenticationFailed(name): "Authentication failed for '\(name)': the data is corrupt or was altered."
        case let .unsupportedEncryption(name): "'\(name)' uses an unsupported encryption method."
        case let .unsupportedMethod(method, name):
            "'\(name)' uses unsupported compression method \(method) (\(ZipArchive.Method.name(method)))."
        case let .crcMismatch(name, expected, actual):
            "CRC mismatch for '\(name)': expected \(String(expected, radix: 16)), got \(String(actual, radix: 16))."
        case let .sizeMismatch(name, expected, actual):
            "Size mismatch for '\(name)': expected \(expected) bytes, got \(actual)."
        case let .unsafePath(name): "Refusing to extract unsafe path '\(name)'."
        case let .corruptData(name): "Compressed data for '\(name)' is corrupt."
        }
    }
}
