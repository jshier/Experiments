public import Bytes
public import Disk

/// An error from reading, verifying, or extracting a zip archive.
///
/// The `String` payloads name the entry or the structure being read. Other modules' errors are composed, as they were
/// thrown: a decoder's `BytesError` (``decoding(_:_:)``), the directory parser's (``invalidRecord(_:_:)``), and Disk's
/// `DiskError` (``disk(_:)``) for opening the archive and writing what's in it. Cancellation, from any of them, is
/// ``cancelled``.
public enum ZipError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No end of central directory record was found: the file isn't a zip archive, or is truncated.
    case notAZipArchive
    /// The archive ended while reading the named structure.
    case truncated(String)
    /// A record didn't start with its expected signature; the payload names the record.
    case badSignature(String)
    /// A field of the named record couldn't be read: the parser's error (`BytesError`).
    case invalidRecord(BytesError, String)
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
    /// The named entry's contents aren't its recorded size: a stored entry's payload, or what a compressed entry
    /// decoded to (`actual`: as far as decoding went, past `expected` when it produced too much; for an LZMA stream
    /// with an end marker, `expected + 1`: its decoder stops at the first byte past).
    case sizeMismatch(String, expected: UInt64, actual: UInt64)
    /// The named entry's compressed data didn't decode: the decoder's error (`BytesError`: `invalidValue` for invalid
    /// data, `insufficientData` for a stream that ends before its end, `trailingData`, …).
    case decoding(BytesError, String)
    /// Opening the archive, or writing what's in it, failed: Disk's error as it threw it (the call, the path, and the
    /// `errno`; an item that exists; a path that leads out of the destination; …).
    case disk(DiskError)
    /// The task was cancelled: the operation stopped early. Never reported as damage.
    case cancelled

    public var description: String {
        switch self {
        case .notAZipArchive: "Not a zip archive (end of central directory not found)."
        case let .truncated(what): "Archive is truncated while reading \(what)."
        case let .badSignature(what): "Bad signature for \(what)."
        case let .invalidRecord(error, what): "Invalid \(what) (\(error))."
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
        case let .decoding(error, name): "Compressed data for '\(name)' is corrupt (\(error))."
        case let .disk(error): "\(error.description.prefix(1).uppercased())\(error.description.dropFirst())."
        case .cancelled: "Cancelled."
        }
    }

    /// Whether this is ``cancelled`` (or a cancellation another module reported).
    public var isCancellation: Bool {
        switch self {
        case .cancelled, .disk(.cancelled), .decoding(.cancelled, _): true
        default: false
        }
    }

    /// Disk's failure as the archive's: ``disk(_:)``, except cancellation (``cancelled``).
    public init(_ error: DiskError) {
        switch error {
        case .cancelled: self = .cancelled
        default: self = .disk(error)
        }
    }

    /// A decoder's failure on the named entry: ``decoding(_:_:)``, except cancellation (``cancelled``).
    init(decoding error: BytesError, _ name: String) {
        switch error {
        case .cancelled: self = .cancelled
        default: self = .decoding(error, name)
        }
    }
}

/// Why reading an entry with a `body` that throws its own errors failed (`ZipArchive.contents(of:using:password:_:)`):
/// the archive's error, or the `body`'s, each as it was thrown. (A `body` that throws nothing, or ``ZipError``, gets the
/// overload that throws ``ZipError``.)
public enum ZipContentsError<BodyFailure: Error>: Error, CustomStringConvertible {
    /// Reading the entry: its header, decryption, decoding, size, or CRC-32.
    case zip(ZipError)
    /// The caller's `body`.
    case body(BodyFailure)

    public var description: String {
        switch self {
        case let .zip(error): error.description
        case let .body(error): "\(error)"
        }
    }
}

extension ZipContentsError: Sendable where BodyFailure: Sendable {}
extension ZipContentsError: Equatable where BodyFailure: Equatable {}
