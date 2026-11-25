import Bytes
import BytesCompression

// The Apple Encrypted Archive container (`AEA1`), as Apple's libAppleArchive writes it. Apple doesn't publish
// the layout; it's documented here from the archive itself, and checked against `aea decrypt` (FORMAT.md in this
// package has the whole description).
//
// A file is a prologue, then clusters, then optional padding:
//
//     prologue  "AEA1" | profile u24 | scrypt strength u8 | auth data size u32 | auth data
//               | signature (128 bytes on profile 0) | key material (32 bytes on profile 0) | salt (32)
//               | root header HMAC (32) | root header (48) | first cluster header HMAC (32)
//     cluster   segment infos: per segment, raw size u32 | compressed size u32 | checksum
//               | next cluster header HMAC (32) | segment HMACs (32 per segment) | the segments' data
//
// Every integer is little-endian.

/// An archive's profile: how its keys are derived and whether it's encrypted and signed.
public enum AEAProfile: Int, Sendable, CaseIterable {
    /// No encryption, signed with ECDSA P-256 (Xcode's archives).
    case signed = 0
    /// AES-256-CTR with a symmetric key, not signed.
    case symmetric = 1
    /// AES-256-CTR with a symmetric key, signed.
    case symmetricSigned = 2
    /// AES-256-CTR with an ECDH P-256 key agreement, not signed.
    case ecdhe = 3
    /// AES-256-CTR with an ECDH P-256 key agreement, signed.
    case ecdheSigned = 4
    /// AES-256-CTR with a key derived from a password with scrypt.
    case scrypt = 5

    /// Whether the prologue carries a signature (0, 2, 4).
    public var isSigned: Bool { signatureByteCount > 0 }

    /// The bytes of the prologue's signature field: the DER signature padded to 128 bytes, then on encrypted
    /// profiles encrypted, with a 32-byte MAC after it.
    var signatureByteCount: Int {
        switch self {
        case .signed: 128
        case .symmetricSigned, .ecdheSigned: 160
        case .symmetric, .ecdhe, .scrypt: 0
        }
    }

    /// The bytes of the prologue's key material: the main key's input on profile 0, the sender's ephemeral
    /// public key on the ECDHE profiles.
    var keyMaterialByteCount: Int {
        switch self {
        case .signed: 32
        case .ecdhe, .ecdheSigned: 65
        case .symmetric, .symmetricSigned, .scrypt: 0
        }
    }

    /// The name `aea` uses for the profile.
    public var name: String {
        switch self {
        case .signed: "hkdf_sha256_hmac__none__ecdsa_p256"
        case .symmetric: "hkdf_sha256_aesctr_hmac__symmetric__none"
        case .symmetricSigned: "hkdf_sha256_aesctr_hmac__symmetric__ecdsa_p256"
        case .ecdhe: "hkdf_sha256_aesctr_hmac__ecdhe_p256__none"
        case .ecdheSigned: "hkdf_sha256_aesctr_hmac__ecdhe_p256__ecdsa_p256"
        case .scrypt: "hkdf_sha256_aesctr_hmac__scrypt__none"
        }
    }
}

/// The checksum kept for each segment's decompressed bytes.
public enum AEAChecksum: UInt8, Sendable {
    case none = 0
    case murmur64 = 1
    case sha256 = 2

    /// The checksum's size in a cluster header's segment info.
    public var byteCount: Int {
        switch self {
        case .none: 0
        case .murmur64: 8
        case .sha256: 32
        }
    }
}

/// The 48-byte root header: sizes and the segment format.
public struct AEARootHeader: Sendable, Equatable {
    /// The total decompressed size: the Apple Archive stream's.
    public var rawSize: Int
    /// The archive file's size, padding included.
    public var containerSize: Int
    /// The decompressed size of every segment but the last.
    public var segmentSize: Int
    /// Segments per cluster.
    public var segmentsPerCluster: Int
    /// How each segment is compressed: BytesCompression's letters, the ones `pbz` streams use.
    public var compression: AppleArchiveCompression
    public var checksum: AEAChecksum

    static var byteCount: Int { 48 }
    /// The largest segment `aea` writes, and this reader reads.
    static var maximumSegmentSize: Int { 256 << 20 }

    init(parsing bytes: RawSpan) throws(AEAError) {
        let record: RootHeaderRecord
        do {
            var reader = AlignedBytesReader(bytes)
            record = try reader.read(RootHeaderRecord.self)
        } catch {
            throw .invalidHeader("root header")
        }
        guard let compression = AppleArchiveCompression(rawValue: record.compression) else {
            throw .unsupportedCompression(record.compression)
        }
        guard let checksum = AEAChecksum(rawValue: record.checksum) else {
            throw .invalidHeader("checksum mode \(record.checksum)")
        }
        // Bounds that keep every later size computation in range: 64-bit sizes under 2^62, segments under 2^31 (their
        // sizes in cluster headers are 32-bit), clusters under 2^20 segments.
        guard record.rawSize < 1 << 62, record.containerSize < 1 << 62, record.segmentSize > 0, record.segmentSize < 1 << 31,
              record.segmentsPerCluster > 0, record.segmentsPerCluster < 1 << 20
        else { throw .invalidHeader("root header sizes") }
        // Segments of at most 256 MiB, `aea`'s largest (`aea encrypt -b 512m`, `1g`, `2g` all write 268,435,456): every
        // decoded segment takes a buffer that size (review 2026-11-23 §1.6).
        guard Int(record.segmentSize) <= Self.maximumSegmentSize else {
            throw .invalidHeader("segment size \(record.segmentSize), over 256 MiB")
        }
        rawSize = Int(record.rawSize)
        containerSize = Int(record.containerSize)
        segmentSize = Int(record.segmentSize)
        segmentsPerCluster = Int(record.segmentsPerCluster)
        self.compression = compression
        self.checksum = checksum
    }

    /// The bytes of a cluster header: per segment an info (8 bytes and the checksum) and a 32-byte HMAC, plus the
    /// next cluster header's HMAC.
    var clusterHeaderByteCount: Int {
        segmentsPerCluster * (8 + checksum.byteCount + 32) + 32
    }
}

/// An entry of the prologue's auth data, which archives use as a key-value store (Xcode's holds its signing
/// certificate chain).
public struct AEAAuthDataEntry: Sendable, Equatable {
    public var key: String
    public var value: [UInt8]
}

/// The prologue: everything before the first cluster.
public struct AEAPrologue: Sendable {
    public var profile: AEAProfile
    /// The scrypt cost (profile 5 only).
    public var scryptStrength: Int
    /// The auth data, as stored.
    public var authData: [UInt8]
    /// The signature field: a DER ECDSA signature, zero-padded.
    public var signature: [UInt8]
    /// The 32 bytes the main key is derived from (profile 0).
    public var keyMaterial: [UInt8]
    public var salt: [UInt8]
    public var rootHeaderMAC: [UInt8]
    /// The root header's 48 bytes (encrypted on profiles other than 0).
    public var rootHeaderBytes: [UInt8]
    public var firstClusterMAC: [UInt8]
    /// The header word with the profile and scrypt strength, as the main key's derivation uses it.
    var profileWord: UInt32
    /// The prologue's size: where the first cluster starts.
    public var byteCount: Int
    /// Where the signature field starts.
    var signatureOffset: Int

    /// The fixed part: magic, profile word, auth data size.
    static var fixedByteCount: Int { 12 }

    /// Parses a prologue from the start of a file.
    ///
    /// - Parameter bytes: The file's first bytes: at least ``byteCount(parsing:)`` of them.
    init(parsing bytes: RawSpan) throws(AEAError) {
        var reader = AlignedBytesReader(bytes)
        let head: PrologueHead
        do {
            head = try reader.read(PrologueHead.self)
        } catch {
            throw .notAnAEAFile
        }
        profileWord = head.profileWord
        let profileValue = Int(profileWord & 0xFF_FFFF)
        guard let profile = AEAProfile(rawValue: profileValue) else { throw .unsupportedProfile(profileValue) }
        self.profile = profile
        scryptStrength = Int(profileWord >> 24)
        // N = 2^(14 + 2 × strength): 0 through 3 (16 MiB to 1 GiB of scratch), what `aea` accepts ("Invalid hardness
        // parameter" above). A larger one from a hostile file would allocate 4 GiB to 1 TiB before any key check.
        if profile == .scrypt, scryptStrength > 3 { throw .invalidHeader("scrypt strength \(scryptStrength)") }
        do {
            authData = try Self.bytes(&reader, head.authDataCount)
            signatureOffset = reader.byteOffset
            signature = try Self.bytes(&reader, profile.signatureByteCount)
            keyMaterial = try Self.bytes(&reader, profile.keyMaterialByteCount)
            salt = try Self.bytes(&reader, 32)
            rootHeaderMAC = try Self.bytes(&reader, 32)
            rootHeaderBytes = try Self.bytes(&reader, AEARootHeader.byteCount)
            firstClusterMAC = try Self.bytes(&reader, 32)
            byteCount = reader.byteOffset
        } catch {
            throw .truncated
        }
    }

    /// The prologue's size, from its fixed part.
    ///
    /// - Parameter bytes: At least the first 12 bytes of the file.
    /// - Returns: The bytes to read before parsing.
    static func byteCount(parsing bytes: RawSpan) throws(AEAError) -> Int {
        let head: PrologueHead
        do {
            var reader = AlignedBytesReader(bytes)
            head = try reader.read(PrologueHead.self)
        } catch {
            throw .notAnAEAFile
        }
        guard let profile = AEAProfile(rawValue: Int(head.profileWord & 0xFF_FFFF)) else {
            throw .unsupportedProfile(Int(head.profileWord & 0xFF_FFFF))
        }
        return fixedByteCount + head.authDataCount + profile.signatureByteCount + profile.keyMaterialByteCount + 32 + 32
            + AEARootHeader.byteCount + 32
    }

    /// The profile in the prologue's first bytes.
    ///
    /// - Parameter bytes: At least the first 12 bytes of the file.
    static func profile(parsing bytes: RawSpan) throws(AEAError) -> AEAProfile {
        let head: PrologueHead
        do {
            var reader = AlignedBytesReader(bytes)
            head = try reader.read(PrologueHead.self)
        } catch {
            throw .notAnAEAFile
        }
        guard let profile = AEAProfile(rawValue: Int(head.profileWord & 0xFF_FFFF)) else {
            throw .unsupportedProfile(Int(head.profileWord & 0xFF_FFFF))
        }
        return profile
    }

    private static func bytes(_ reader: inout AlignedBytesReader, _ count: Int) throws(BytesError) -> [UInt8] {
        try [UInt8](copying: reader.read(byteCount: count))
    }

    /// The auth data as key-value entries, or `nil` when it isn't in that format.
    ///
    /// Each entry is a 32-bit size (including itself), a NUL-terminated key, then the value.
    public var authDataEntries: [AEAAuthDataEntry]? {
        var entries: [AEAAuthDataEntry] = []
        var reader = AlignedBytesReader(authData.span.bytes)
        do {
            while !reader.isAtEnd {
                var entry = try reader.read(sectionPrefixedBy: Byte4.self, .littleEndian, includingPrefix: true)
                let key = try String(copying: entry.read(utf8TerminatedBy: 0))
                entries.append(AEAAuthDataEntry(key: key, value: [UInt8](copying: entry.readRemainingBytes())))
            }
        } catch {
            return nil
        }
        return entries
    }

    /// The prologue as signed: its bytes with the signature field zeroed.
    ///
    /// - Parameter original: The prologue's bytes as stored.
    func signedBytes(_ original: [UInt8]) -> [UInt8] {
        var bytes = original
        for index in signatureOffset..<(signatureOffset + signature.count) {
            bytes[index] = 0
        }
        return bytes
    }
}

/// One segment: where its compressed bytes are and what they decompress to.
public struct AEASegment: Sendable, Equatable {
    /// The segment's position in the archive, counting from 0 across clusters.
    public var index: Int
    /// The cluster it's in, and its position there (the segment key's index).
    public var cluster: Int
    public var indexInCluster: Int
    /// Where its compressed bytes start in the file.
    public var fileOffset: Int
    public var compressedSize: Int
    /// Where its decompressed bytes start in the Apple Archive stream.
    public var rawOffset: Int
    public var rawSize: Int

    /// Whether the segment is stored without compression (its sizes are equal).
    public var isStored: Bool { compressedSize == rawSize }
}
