import Bytes
public import System
import Disk

/// The archive formats Apple's tools and Archive Utility expand, recognized by their first bytes (then by extension):
/// what the reader for a file is. NativeAEA reads all but `.zip` (NativeZip's).
public enum ArchiveKind: Sendable, Hashable, CaseIterable {
    /// `.zip`: a local file header, an empty archive's end record, or a spanned archive's marker (`PK` and 3 4, 5 6,
    /// or 7 8).
    case zip
    /// `.aea`: ``AEAArchive`` (`AEA1`).
    case appleEncryptedArchive
    /// `.aar`, `.yaa`, plain (`AA01`, `YAA1`) or `pbz`-compressed: ``AppleArchiveFile``.
    case appleArchive
    /// `.xip`: ``XIPArchive`` (a XAR archive, `xar!`).
    case xip

    /// The bytes ``init(magic:)`` looks at: a file's first 4.
    public static let magicCount = 4

    /// The kind of a file whose first bytes are `bytes`, or `nil` if they're no archive's.
    ///
    /// - Parameter bytes: The file's first bytes: ``magicCount`` of them, or the whole file if it's shorter.
    public init?(magic bytes: RawSpan) {
        let head = [UInt8](copying: bytes.extracting(0..<min(Self.magicCount, bytes.byteCount)))
        func starts(_ prefix: String) -> Bool { head.starts(with: prefix.utf8) }
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

    /// The kind of a file whose first bytes are `bytes`, or `nil` if they're no archive's.
    public init?(magic bytes: [UInt8]) {
        self.init(magic: bytes.span.bytes)
    }

    /// The kind of the file at `path`: by its first bytes, else by its extension (`zip`, `aea`, `aar`, `yaa`, `xip`,
    /// in any case).
    ///
    /// - Returns: `nil` if neither says.
    /// - Throws: ``AEAError/disk(_:)`` if the file can't be opened or read.
    public init?(detecting path: FilePath) throws(AEAError) {
        let head: [UInt8]
        do throws(DiskError) {
            let file = try InputFile(path)
            head = try file.read(at: 0, count: min(Self.magicCount, file.count))
        } catch {
            throw AEAError(error)
        }
        if let kind = ArchiveKind(magic: head) {
            self = kind
            return
        }
        switch path.extension?.lowercased() {
        case "zip": self = .zip
        case "aea": self = .appleEncryptedArchive
        case "aar", "yaa": self = .appleArchive
        case "xip": self = .xip
        default: return nil
        }
    }
}
