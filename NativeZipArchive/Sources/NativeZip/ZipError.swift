public enum ZipError: Error, CustomStringConvertible {
    case notAZipArchive
    case truncated(String)
    case badSignature(String)
    case multiDiskUnsupported
    case encryptedEntry(String)
    case unsupportedMethod(UInt16, String)
    case crcMismatch(String, expected: UInt32, actual: UInt32)
    case sizeMismatch(String, expected: UInt64, actual: UInt64)
    case unsafePath(String)
    case corruptData(String)

    public var description: String {
        switch self {
        case .notAZipArchive: "Not a zip archive (end of central directory not found)."
        case let .truncated(what): "Archive is truncated while reading \(what)."
        case let .badSignature(what): "Bad signature for \(what)."
        case .multiDiskUnsupported: "Multi-disk (spanned) archives are not supported."
        case let .encryptedEntry(name): "'\(name)' is encrypted; encryption is not supported."
        case let .unsupportedMethod(method, name): "'\(name)' uses unsupported compression method \(method)."
        case let .crcMismatch(name, expected, actual):
            "CRC mismatch for '\(name)': expected \(String(expected, radix: 16)), got \(String(actual, radix: 16))."
        case let .sizeMismatch(name, expected, actual):
            "Size mismatch for '\(name)': expected \(expected) bytes, got \(actual)."
        case let .unsafePath(name): "Refusing to extract unsafe path '\(name)'."
        case let .corruptData(name): "Compressed data for '\(name)' is corrupt."
        }
    }
}
