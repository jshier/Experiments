@testable import NativeAEA
import Bytes
import BytesTesting
import BytesTestSupport
import DiskTestSupport
import Foundation
import System
import Testing

// Temporary directories (`TemporaryDirectory`, removed with their read-only files and ACLs), running tools
// (`ExternalTool.run`), and `hex` are Bytes' `BytesTestSupport`; the bulk trait is `BytesTesting`'s. Reading extracted
// trees (`readTree`, attributes, ACLs, `decmpfs`) and `TestFailure` are Disk's `DiskTestSupport`.

extension TemporaryDirectory {
    /// A directory named for these tests.
    convenience init() throws {
        try self.init(prefix: "NativeAEATests")
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

    /// A field's key and subtype, then `value` (little-endian).
    private static func field<T: ByteGroup>(_ key: String, _ subtype: Character, _ value: T.Integer, as _: T.Type) -> [UInt8] {
        var bytes = field(key, subtype)
        bytes.append(value, as: T.self, .littleEndian)
        return bytes
    }

    private mutating func entry(_ fields: [UInt8], blobs: [UInt8] = []) {
        bytes += Array("AA01".utf8)
        bytes.append(UInt16(6 + fields.count), as: Byte2.self, .littleEndian)
        bytes += fields + blobs
    }

    private static func common(_ type: Character, _ path: String, mode: UInt16) -> [UInt8] {
        field("TYP", "1") + [UInt8(ascii: type.unicodeScalars.first!)]
            + field("PAT", "P", UInt16(path.utf8.count), as: Byte2.self) + Array(path.utf8)
            + field("UID", "1") + [0] + field("GID", "1") + [0] + field("MOD", "2", mode, as: Byte2.self)
    }

    mutating func directory(_ path: String, mode: UInt16 = 0o755) {
        entry(Self.common("D", path, mode: mode))
    }

    /// A file; `diskCompression` and `flags` as Xcode's archive has them (`AFT1` 14, `FLG1` 0x20).
    mutating func file(_ path: String, _ data: [UInt8], mode: UInt16 = 0o644, diskCompression: UInt8? = nil, flags: UInt8? = nil) {
        var fields = Self.common("F", path, mode: mode)
        if data.count < 65_536 {
            fields += Self.field("DAT", "A", UInt16(data.count), as: Byte2.self)
        } else {
            fields += Self.field("DAT", "B", UInt32(data.count), as: Byte4.self)
        }
        if let flags { fields += Self.field("FLG", "1") + [flags] }
        if let diskCompression { fields += Self.field("AFT", "1") + [diskCompression] }
        entry(fields, blobs: data)
    }

    mutating func link(_ path: String, to target: String, mode: UInt16 = 0o755) {
        entry(Self.common("L", path, mode: mode) + Self.field("LNK", "P", UInt16(target.utf8.count), as: Byte2.self) + Array(target.utf8))
    }

    /// A FIFO (`P`), character device (`C`), or block device (`B`, with `DEV`), or socket (`S`).
    mutating func special(_ path: String, type: Character, mode: UInt16 = 0o644, device: UInt32? = nil) {
        var fields = Self.common(type, path, mode: mode)
        if let device { fields += Self.field("DEV", "4", device, as: Byte4.self) }
        entry(fields)
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

extension TreeParts {
    /// What the extraction tests compare by default: kinds, modes, link targets, contents, and flags (APFS
    /// compression's `UF_COMPRESSED` among them).
    static let entries: TreeParts = [.contents, .flags]
}

extension Trait where Self == LifetimeChecks {
    /// Every test: nothing left open under its temporary directories, and no Disk descriptor closed at deinit.
    static var diskLifetimes: Self {
        .lifetimeChecked(audit: "descriptors closed at deinit") { try await DiskLifetimes.dropped(during: $0) }
    }
}
