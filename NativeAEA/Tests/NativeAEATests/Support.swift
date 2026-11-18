import Foundation
@testable import NativeAEA
import System

/// A temporary directory, removed on deinit.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "NativeAEATests-\(UUID().uuidString).noindex")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Removes the directory. (Explicit, not in `deinit`: Swift may end an object's life after its last use, before
    /// the files in it are.)
    func remove() {
        // Extracted files can be read-only, as can directories: make them writable before removing.
        _ = try? Tools.run("/bin/chmod", ["-R", "u+w", url.path])
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ name: String) -> URL { url.appending(path: name) }
}

enum Tools {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Runs a tool, throwing with its output if it fails.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(executable) \(arguments.joined(separator: " ")): \(output)")
        }
        return output
    }
}

/// A P-256 signing key pair as `aea` takes them: SEC1 PEM private key (made with openssl: `aea` doesn't read the
/// PKCS #8 PEM CryptoKit writes), PEM public key.
struct SigningKeys {
    let privateKey: URL
    let publicKey: URL
    let certificate: URL

    init(in directory: TemporaryDirectory) throws {
        privateKey = directory.path("signing.pem")
        publicKey = directory.path("signing.pub.pem")
        certificate = directory.path("signing.cert.pem")
        // `aea` rejects keys whose private scalar DER shortens (a leading zero byte, 1 in 256): make another.
        while true {
            try Tools.run("/usr/bin/openssl", ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", privateKey.path])
            let der = directory.path("signing.der")
            try Tools.run("/usr/bin/openssl", ["ec", "-in", privateKey.path, "-outform", "DER", "-out", der.path])
            // SEQUENCE { INTEGER 1, OCTET STRING (32 bytes) ...}: the octet string's length is at offset 6.
            let bytes = try Data(contentsOf: der)
            if bytes.count > 6, bytes[5] == 0x04, bytes[6] == 0x20 { break }
        }
        try Tools.run("/usr/bin/openssl", ["ec", "-in", privateKey.path, "-pubout", "-out", publicKey.path])
        try Tools.run("/usr/bin/openssl", [
            "req", "-new", "-x509", "-key", privateKey.path, "-subj", "/CN=NativeAEA tests", "-days", "2",
            "-out", certificate.path,
        ])
    }

    var signingKey: AEASigningKey {
        get throws { try AEASigningKey.publicKey(contentsOf: publicKey) }
    }
}

/// Wraps an Apple Archive stream in a signed profile 0 container with Apple's `aea`.
func makeAEA(
    _ stream: URL, keys: SigningKeys, in directory: TemporaryDirectory, compression: String = "lzma",
    blockSize: String = "64k", checksum: String = "sha256", withCertificateChain: Bool = false
) throws -> URL {
    let output = directory.path("\(stream.deletingPathExtension().lastPathComponent)-\(compression)-\(blockSize)-\(checksum).aea")
    var arguments = [
        "encrypt", "-profile", "0", "-i", stream.path, "-o", output.path, "-sign-priv", keys.privateKey.path,
        "-a", compression, "-b", blockSize, "-checksum", checksum,
    ]
    if withCertificateChain {
        arguments += ["-auth-data-key", AEASignature.certificateChainKey, "-auth-data", keys.certificate.path]
    }
    try Tools.run("/usr/bin/aea", arguments)
    return output
}

/// Writes Apple Archive streams entry by entry, with exactly the fields asked for: what `aa archive` can't make
/// (Xcode's `AFT` field, unsafe paths, hand-picked layouts).
struct ArchiveStreamWriter {
    private(set) var bytes: [UInt8] = []

    private static func field(_ key: String, _ subtype: Character) -> [UInt8] {
        Array(key.utf8) + [UInt8(ascii: subtype.unicodeScalars.first!)]
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private mutating func entry(_ fields: [UInt8], blobs: [UInt8] = []) {
        let size = 6 + fields.count
        bytes += Array("AA01".utf8) + Self.le(UInt16(size)) + fields + blobs
    }

    private static func common(_ type: Character, _ path: String, mode: UInt16) -> [UInt8] {
        field("TYP", "1") + [UInt8(ascii: type.unicodeScalars.first!)]
            + field("PAT", "P") + le(UInt16(path.utf8.count)) + Array(path.utf8)
            + field("UID", "1") + [0] + field("GID", "1") + [0] + field("MOD", "2") + le(mode)
    }

    mutating func directory(_ path: String, mode: UInt16 = 0o755) {
        entry(Self.common("D", path, mode: mode))
    }

    /// A file; `diskCompression` and `flags` as Xcode's archive has them (`AFT1` 14, `FLG1` 0x20).
    mutating func file(_ path: String, _ data: [UInt8], mode: UInt16 = 0o644, diskCompression: UInt8? = nil, flags: UInt8? = nil) {
        var fields = Self.common("F", path, mode: mode)
        if data.count < 65_536 {
            fields += Self.field("DAT", "A") + Self.le(UInt16(data.count))
        } else {
            fields += Self.field("DAT", "B") + Self.le(UInt32(data.count))
        }
        if let flags { fields += Self.field("FLG", "1") + [flags] }
        if let diskCompression { fields += Self.field("AFT", "1") + [diskCompression] }
        entry(fields, blobs: data)
    }

    mutating func link(_ path: String, to target: String, mode: UInt16 = 0o755) {
        entry(Self.common("L", path, mode: mode) + Self.field("LNK", "P") + Self.le(UInt16(target.utf8.count)) + Array(target.utf8))
    }

    func write(to url: URL) throws {
        try Data(bytes).write(to: url)
    }
}

/// Deterministic test bytes: `compressible` repeats text; otherwise a xorshift stream (incompressible).
func testBytes(_ count: Int, seed: UInt64, compressible: Bool) -> [UInt8] {
    if compressible {
        let line = Array("line \(seed): the quick brown fox jumps over the lazy dog\n".utf8)
        return (0..<count).map { line[$0 % line.count] }
    }
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0..<count {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        bytes[index] = UInt8(truncatingIfNeeded: state)
    }
    return bytes
}

/// What a file looks like on disk after extraction.
struct DiskEntry: Equatable, CustomStringConvertible {
    var type: String
    var mode: UInt16
    var contents: [UInt8]?
    var linkTarget: String?
    var compressed: Bool

    var description: String {
        "\(type) \(String(mode, radix: 8)) \(contents.map { "\($0.count) bytes" } ?? "") \(linkTarget ?? "")\(compressed ? " compressed" : "")"
    }
}

/// Every item under `root` (not following links), by relative path.
func readTree(_ root: URL) throws -> [String: DiskEntry] {
    var result: [String: DiskEntry] = [:]
    let enumerator = FileManager.default.enumerator(atPath: root.path)!
    while let relative = enumerator.nextObject() as? String {
        let path = root.appending(path: relative).path
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Tools.Failure(description: "lstat \(path)") }
        let mode = UInt16(info.st_mode & 0o7777)
        let compressed = info.st_flags & UInt32(UF_COMPRESSED) != 0
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            result[relative] = DiskEntry(type: "directory", mode: mode, compressed: compressed)
        case S_IFLNK:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            result[relative] = DiskEntry(type: "link", mode: mode, linkTarget: target, compressed: compressed)
        default:
            result[relative] = DiskEntry(type: "file", mode: mode, contents: Array(try Data(contentsOf: URL(fileURLWithPath: path))), compressed: compressed)
        }
    }
    return result
}

/// The `decmpfs` type of a compressed file (13 inline, 14 in the resource fork), or `nil`.
func decmpfsType(_ url: URL) -> UInt32? {
    // Room for inline data too: a smaller buffer gets ERANGE.
    var header = [UInt8](repeating: 0, count: 4096)
    let count = getxattr(url.path, "com.apple.decmpfs", &header, header.count, 0, XATTR_SHOWCOMPRESSION | XATTR_NOFOLLOW)
    guard count >= 16 else { return nil }
    return UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24
}
