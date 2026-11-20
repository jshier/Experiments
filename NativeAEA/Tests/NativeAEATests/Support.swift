import BytesTestSupport
import Foundation
@testable import NativeAEA
import System

// Temporary directories (`TemporaryDirectory`, removed with their read-only files and ACLs), running tools
// (`ExternalTool.run`), and `hex` are Bytes' `BytesTestSupport`; the bulk trait is `BytesTesting`'s.

extension TemporaryDirectory {
    /// A directory named for these tests.
    convenience init() throws {
        try self.init(prefix: "NativeAEATests")
    }
}

/// A check in a test helper that failed.
struct TestFailure: Error, CustomStringConvertible {
    var description: String
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
            try ExternalTool.run("/usr/bin/openssl", ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", privateKey.path])
            let der = directory.path("signing.der")
            try ExternalTool.run("/usr/bin/openssl", ["ec", "-in", privateKey.path, "-outform", "DER", "-out", der.path])
            // SEQUENCE { INTEGER 1, OCTET STRING (32 bytes) ...}: the octet string's length is at offset 6.
            let bytes = try Data(contentsOf: der)
            if bytes.count > 6, bytes[5] == 0x04, bytes[6] == 0x20 { break }
        }
        try ExternalTool.run("/usr/bin/openssl", ["ec", "-in", privateKey.path, "-pubout", "-out", publicKey.path])
        try ExternalTool.run("/usr/bin/openssl", [
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
    try ExternalTool.run("/usr/bin/aea", arguments)
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

    /// A FIFO (`P`), character device (`C`), or block device (`B`, with `DEV`), or socket (`S`).
    mutating func special(_ path: String, type: Character, mode: UInt16 = 0o644, device: UInt32? = nil) {
        var fields = Self.common(type, path, mode: mode)
        if let device { fields += Self.field("DEV", "4") + Self.le(device) }
        entry(fields)
    }

    func write(to url: URL) throws {
        try Data(bytes).write(to: url)
    }
}

/// Everything about an item that extraction restores beyond `DiskEntry`: extended attributes, its ACL, and which
/// other paths are the same file.
struct ItemMetadata: Equatable, CustomStringConvertible {
    var attributes: [String: [UInt8]]
    var accessControlList: String?
    var hardLinks: [String]
    var modification: timespec

    static func == (a: Self, b: Self) -> Bool {
        a.attributes == b.attributes && a.accessControlList == b.accessControlList && a.hardLinks == b.hardLinks
            && a.modification.tv_sec == b.modification.tv_sec && a.modification.tv_nsec == b.modification.tv_nsec
    }

    var description: String {
        "xattrs \(attributes.mapValues(\.count)) acl \(accessControlList ?? "-") links \(hardLinks) mtime \(modification.tv_sec).\(modification.tv_nsec)"
    }
}

/// Extended attributes, ACLs (as text), hard-link groups, and modification times under `root`, by relative path,
/// not following links. `ignoring` attributes are left out.
func readMetadata(_ root: URL, ignoring: Set<String> = []) throws -> [String: ItemMetadata] {
    var inodes: [UInt64: [String]] = [:]
    var result: [String: ItemMetadata] = [:]
    let enumerator = FileManager.default.enumerator(atPath: root.path)!
    var paths: [String] = []
    while let relative = enumerator.nextObject() as? String { paths.append(relative) }
    for relative in paths {
        let path = root.appending(path: relative).path
        var info = stat()
        guard lstat(path, &info) == 0 else { throw TestFailure(description: "lstat \(path)") }
        if info.st_mode & S_IFMT == S_IFREG { inodes[info.st_ino, default: []].append(relative) }
        var attributes: [String: [UInt8]] = [:]
        var names = [CChar](repeating: 0, count: 65_536)
        let namesCount = listxattr(path, &names, names.count, XATTR_NOFOLLOW)
        if namesCount > 0 {
            for name in names[0..<namesCount].split(separator: 0).map({ String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) })
            where !ignoring.contains(name) {
                var value = [UInt8](repeating: 0, count: 1 << 20)
                let count = getxattr(path, name, &value, value.count, 0, XATTR_NOFOLLOW)
                attributes[name] = Array(value[0..<max(0, count)])
            }
        }
        var aclText: String?
        if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            if let text = acl_to_text(acl, nil) {
                aclText = String(cString: text)
                acl_free(UnsafeMutableRawPointer(text))
            }
            acl_free(UnsafeMutableRawPointer(acl))
        }
        result[relative] = ItemMetadata(attributes: attributes, accessControlList: aclText, hardLinks: [], modification: info.st_mtimespec)
        if info.st_mode & S_IFMT == S_IFREG { result[relative]!.hardLinks = [String(info.st_ino)] }
    }
    // Inode numbers differ between trees: replace each with the sorted paths sharing it.
    for (_, group) in inodes {
        for path in group { result[path]!.hardLinks = group.sorted() }
    }
    return result
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
        guard lstat(path, &info) == 0 else { throw TestFailure(description: "lstat \(path)") }
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

/// A file's stored APFS compression, as written: its `com.apple.decmpfs` attribute, then its resource fork (empty for
/// a plain file).
func decmpfsStoredBytes(_ url: URL) -> [UInt8] {
    var stored: [UInt8] = []
    for name in ["com.apple.decmpfs", "com.apple.ResourceFork"] {
        let options = XATTR_SHOWCOMPRESSION | XATTR_NOFOLLOW
        let size = getxattr(url.path, name, nil, 0, 0, options)
        guard size > 0 else { continue }
        var bytes = [UInt8](repeating: 0, count: size)
        let got = getxattr(url.path, name, &bytes, size, 0, options)
        stored += bytes.prefix(max(0, got))
    }
    return stored
}
