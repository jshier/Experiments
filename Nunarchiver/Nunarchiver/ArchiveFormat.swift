import Darwin
import Disk
import NativeAEA
import NativeZip
import System

/// The archive formats Nunarchiver expands, recognized by their first bytes (then by extension).
enum ArchiveFormat: Equatable {
    /// `.zip`: NativeZip.
    case zip
    /// `.aea`: NativeAEA's `AEAArchive`.
    case appleEncryptedArchive
    /// `.aar`, `.yaa`, plain or `pbz`-compressed: NativeAEA's `AppleArchiveFile`.
    case appleArchive
    /// `.xip`: NativeAEA's `XIPArchive`.
    case xip

    /// The format of the file at `archive`: by its first bytes, else by its extension.
    ///
    /// - Throws: ``ExpansionFailure/system(call:path:code:)`` if the file can't be read,
    ///   ``ExpansionFailure/unrecognizedFormat(_:)`` if neither says.
    init(detecting archive: FilePath) throws {
        if let format = try ArchiveFormat(magic: Self.head(of: archive)) {
            self = format
            return
        }
        switch archive.extension?.lowercased() {
        case "zip": self = .zip
        case "aea": self = .appleEncryptedArchive
        case "aar", "yaa": self = .appleArchive
        case "xip": self = .xip
        default: throw ExpansionFailure.unrecognizedFormat(archive.lastComponent?.string ?? archive.string)
        }
    }

    /// The format a file starting with `magic` is in, or `nil` if its first bytes are no archive's.
    init?(magic: [UInt8]) {
        func starts(_ prefix: String) -> Bool { magic.starts(with: prefix.utf8) }
        if starts("PK\u{3}\u{4}") || starts("PK\u{5}\u{6}") || starts("PK\u{7}\u{8}") {
            self = .zip
        } else if starts("AEA1") {
            self = .appleEncryptedArchive
        } else if starts("xar!") {
            self = .xip
        } else if starts("AA01") || starts("YAA1") || starts("pbz") {
            self = .appleArchive
        } else {
            return nil
        }
    }

    /// The first 8 bytes of `archive` (fewer, if it's shorter).
    private static func head(of archive: FilePath) throws -> [UInt8] {
        // Unsafe: `open` takes a C string. Safe: the path's own, bridged for the call and not kept.
        let descriptor = unsafe Darwin.open(archive.string, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExpansionFailure.system(call: "open", path: archive, code: errno) }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 8)
        // Unsafe: `read` writes through a pointer. Safe: it's the array's own storage, valid inside the closure, and
        // `read` writes at most the count it's given, the storage's.
        let count = bytes.withUnsafeMutableBytes { unsafe read(descriptor, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw ExpansionFailure.system(call: "read", path: archive, code: errno) }
        return Array(bytes.prefix(count))
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

    /// Extracts into the staging directory with the format's adapter. `quarantine` is the archive's, for the formats
    /// whose entries get it (not a `.xip`'s).
    func extract(into staging: Destination, quarantine: Quarantine?, progress: ExtractionProgress) async throws {
        switch self {
        case let .zip(zip, password):
            try await ZipAdapter.extract(zip, password: password, into: staging, quarantine: quarantine, progress: progress)
        case .appleEncryptedArchive(let archive):
            try await AppleArchiveAdapter.extract(archive, into: staging, progress: progress)
        case .appleArchive(let archive):
            try await AppleArchiveAdapter.extract(archive, into: staging, progress: progress)
        case .xip(let archive):
            try await AppleArchiveAdapter.extract(archive, into: staging, progress: progress)
        }
    }
}
