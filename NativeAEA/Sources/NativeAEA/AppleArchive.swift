import Bytes

// The Apple Archive stream inside the container (libAppleArchive's `aa` format, magic `AA01`; older archives
// use `YAA1`). Entries follow one another with no index:
//
//     "AA01" | header size u16 (whole header, magic included) | fields... | blobs...
//
// A field is a 3-letter key and a 1-character subtype that gives its value's size:
//
//     '*'                  flag, no value
//     '1' '2' '4' '8'      unsigned integer of that many bytes
//     'P'                  string: u16 size, bytes (no terminator)
//     'T'                  timespec: u64 seconds, u32 nanoseconds;  'S': u64 seconds
//     'F' 'G' 'H' 'I' 'J'  hash: CRC-32 (4), SHA-1 (20), SHA-256 (32), SHA-384 (48), SHA-512 (64)
//     'A' 'B' 'C'          blob of u16, u32, u64 size: the bytes follow the header, in field order
//
// Xcode's entries are `TYP1 PAT_P UID1 GID1 MOD2` (directories), plus `DATA|DATB FLG1 AFT1` for files and `LNKP`
// for links. `AFT` (not in Apple's headers) is the file's on-disk compression, a `decmpfs` type: 13 (LZBITMAP
// in the `decmpfs` attribute) or 14 (LZBITMAP chunks in the resource fork); `FLG` then has `UF_COMPRESSED`.

/// An entry's type: the `TYP` field, an ASCII letter.
public enum AAEntryType: UInt8, Sendable {
    case regularFile = 0x46 // "F"
    case directory = 0x44 // "D"
    case symbolicLink = 0x4C // "L"
    case fifo = 0x50 // "P"
    case characterDevice = 0x43 // "C"
    case blockDevice = 0x42 // "B"
    case socket = 0x53 // "S"
    case whiteout = 0x57 // "W"
    case door = 0x52 // "R"
    case port = 0x54 // "T"
    case metadata = 0x4D // "M"
}

/// A byte range inside a header, as offsets from its start.
public struct AAHeaderRange: Sendable, Equatable {
    public var offset: Int
    public var count: Int
}

/// One entry's header, parsed. Strings are ranges of the header's bytes, so parsing allocates nothing.
public struct AAEntryHeader: Sendable, Equatable {
    /// The header's size, magic included.
    public var byteCount = 0
    public var type: AAEntryType?
    public var path: AAHeaderRange?
    public var linkTarget: AAHeaderRange?
    public var uid: UInt32?
    public var gid: UInt32?
    /// Permissions: the low 12 bits of `st_mode`.
    public var mode: UInt16?
    /// `st_flags`.
    public var flags: UInt32?
    /// The on-disk compression to use: a `decmpfs` type (13, 14).
    public var diskCompression: UInt32?
    public var modificationTime: (seconds: Int64, nanoseconds: UInt32)?
    public var creationTime: (seconds: Int64, nanoseconds: UInt32)?
    /// Hard link, clone, and identical-data cluster ids.
    public var hardLinkCluster: UInt64?
    public var cloneCluster: UInt64?
    /// The file's contents: offset from the end of the header (after earlier blobs) and size.
    public var data: (offset: Int, count: Int)?
    /// Extended attributes (`XAT`): offset from the end of the header and size.
    public var extendedAttributes: (offset: Int, count: Int)?
    /// The access control list (`ACL`): offset from the end of the header and size.
    public var accessControlList: (offset: Int, count: Int)?
    /// A device's `st_rdev` (`DEV`), for character and block devices.
    public var device: UInt64?
    /// Every blob's bytes, together: what follows the header before the next entry.
    public var blobByteCount = 0

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.byteCount == b.byteCount && a.type == b.type && a.path == b.path && a.linkTarget == b.linkTarget
            && a.uid == b.uid && a.gid == b.gid && a.mode == b.mode && a.flags == b.flags
            && a.diskCompression == b.diskCompression && a.modificationTime?.seconds == b.modificationTime?.seconds
            && a.modificationTime?.nanoseconds == b.modificationTime?.nanoseconds
            && a.hardLinkCluster == b.hardLinkCluster && a.cloneCluster == b.cloneCluster
            && a.data?.offset == b.data?.offset && a.data?.count == b.data?.count
            && a.extendedAttributes?.offset == b.extendedAttributes?.offset
            && a.extendedAttributes?.count == b.extendedAttributes?.count
            && a.accessControlList?.offset == b.accessControlList?.offset
            && a.accessControlList?.count == b.accessControlList?.count && a.device == b.device
            && a.blobByteCount == b.blobByteCount
    }
}

public enum AppleArchive {
    /// The smallest header: magic and size.
    public static var minimumHeaderByteCount: Int { 6 }

    /// The size of the header starting at `bytes`, from its first 6 bytes.
    ///
    /// - Throws: ``AEAError/invalidArchive(_:)`` if the magic isn't `AA01` or `YAA1`, or the size is under 6.
    @inline(__always)
    public static func headerByteCount(_ bytes: RawSpan) throws(AEAError) -> Int {
        var reader = AlignedBytesReader(bytes)
        // Reads in typed `do`s, checks outside them: an untyped `do` boxes every error it rethrows.
        let magic: UInt32
        do throws(BytesError) {
            magic = try reader.read(Byte4.self, .bigEndian)
        } catch {
            throw .invalidArchive("truncated header")
        }
        guard magic == Byte4(ascii: "AA01").bigEndian || magic == Byte4(ascii: "YAA1").bigEndian else {
            throw .invalidArchive("no entry magic")
        }
        let count: Int
        do throws(BytesError) {
            count = try Int(reader.read(Byte2.self, .littleEndian))
        } catch {
            throw .invalidArchive("truncated header")
        }
        guard count >= minimumHeaderByteCount else { throw .invalidArchive("header size \(count)") }
        return count
    }

    /// Parses one entry's header.
    ///
    /// - Parameter header: Exactly the header's bytes (``headerByteCount(_:)`` of them).
    /// - Throws: ``AEAError/invalidArchive(_:)`` for an unknown subtype, a field running past the header, or a
    ///   repeated `DAT`.
    public static func parseHeader(_ header: RawSpan) throws(AEAError) -> AAEntryHeader {
        var entry = AAEntryHeader()
        entry.byteCount = header.byteCount
        var reader = AlignedBytesReader(header)
        // The fields' reads throw `BytesError` (a field running past the header); what they hold that's wrong comes back
        // as a value. Both typed: an untyped `do` boxes every error it rethrows.
        let problem: AEAError?
        do throws(BytesError) {
            problem = try parseFields(&reader, &entry)
        } catch {
            throw .invalidArchive("a field runs past its header")
        }
        if let problem { throw problem }
        return entry
    }

    /// The fields after the magic and size, into `entry`.
    ///
    /// - Returns: What's wrong with a field's value, or `nil`.
    /// - Throws: `BytesError` when a field runs past the header.
    @inline(__always)
    private static func parseFields(_ reader: inout AlignedBytesReader, _ entry: inout AAEntryHeader) throws(BytesError) -> AEAError? {
        try reader.skip(byteCount: minimumHeaderByteCount)
        while reader.remainingByteCount > 0 {
            let field = try reader.read(Byte4.self, .bigEndian)
            // The common fields by their whole 4 bytes, key and subtype.
            switch field {
            case Byte4(ascii: "TYP1").bigEndian:
                let raw = try UInt8(reader.read(Byte.self))
                guard let type = AAEntryType(rawValue: raw) else { return .invalidArchive("entry type \(raw)") }
                entry.type = type
            case Byte4(ascii: "PATP").bigEndian:
                entry.path = try string(&reader)
            case Byte4(ascii: "UID1").bigEndian:
                entry.uid = try UInt32(UInt8(reader.read(Byte.self)))
            case Byte4(ascii: "GID1").bigEndian:
                entry.gid = try UInt32(UInt8(reader.read(Byte.self)))
            case Byte4(ascii: "MOD2").bigEndian:
                entry.mode = try reader.read(Byte2.self, .littleEndian)
            case Byte4(ascii: "FLG1").bigEndian:
                entry.flags = try UInt32(UInt8(reader.read(Byte.self)))
            case Byte4(ascii: "AFT1").bigEndian:
                entry.diskCompression = try UInt32(UInt8(reader.read(Byte.self)))
            case Byte4(ascii: "LNKP").bigEndian:
                entry.linkTarget = try string(&reader)
            case Byte4(ascii: "DATA").bigEndian:
                if let problem = addData(&entry, count: try Int(reader.read(Byte2.self, .littleEndian))) { return problem }
            case Byte4(ascii: "DATB").bigEndian:
                if let problem = addData(&entry, count: try Int(reader.read(Byte4.self, .littleEndian))) { return problem }
            default:
                if let problem = try parseField(field, &reader, &entry) { return problem }
            }
        }
        return nil
    }

    @inline(__always)
    private static func string(_ reader: inout AlignedBytesReader) throws(BytesError) -> AAHeaderRange {
        let count = try Int(reader.read(Byte2.self, .littleEndian))
        let offset = reader.byteOffset
        try reader.skip(byteCount: count)
        return AAHeaderRange(offset: offset, count: count)
    }

    /// Records the contents' blob, or what's wrong: a second one.
    @inline(__always)
    private static func addData(_ entry: inout AAEntryHeader, count: Int) -> AEAError? {
        guard entry.data == nil else { return .invalidArchive("two DAT fields") }
        entry.data = (entry.blobByteCount, count)
        entry.blobByteCount += count
        return nil
    }

    /// Any other field, by its subtype: the values Xcode's archives don't use, or other widths.
    ///
    /// - Returns: What's wrong with the field's value, or `nil`.
    /// - Throws: `BytesError` when it runs past the header.
    @inline(never)
    private static func parseField(_ field: UInt32, _ reader: inout AlignedBytesReader, _ entry: inout AAEntryHeader) throws(BytesError) -> AEAError? {
        let key = field >> 8
        let subtype = UInt8(truncatingIfNeeded: field)
        func keyIs(_ name: Byte4) -> Bool { key == name.bigEndian >> 8 }
        switch subtype {
        case 0x2A: // "*": a flag
            break
        case 0x31, 0x32, 0x34, 0x38: // "1" "2" "4" "8"
            let width = Int(subtype - 0x30)
            var value: UInt64 = 0
            for index in 0..<width { value |= try UInt64(UInt8(reader.read(Byte.self))) << (8 * index) }
            if keyIs(Byte4(ascii: "TYP*")) {
                guard let type = AAEntryType(rawValue: UInt8(truncatingIfNeeded: value)) else {
                    return .invalidArchive("entry type \(value)")
                }
                entry.type = type
            } else if keyIs(Byte4(ascii: "UID*")) {
                entry.uid = UInt32(truncatingIfNeeded: value)
            } else if keyIs(Byte4(ascii: "GID*")) {
                entry.gid = UInt32(truncatingIfNeeded: value)
            } else if keyIs(Byte4(ascii: "MOD*")) {
                entry.mode = UInt16(truncatingIfNeeded: value)
            } else if keyIs(Byte4(ascii: "FLG*")) {
                entry.flags = UInt32(truncatingIfNeeded: value)
            } else if keyIs(Byte4(ascii: "AFT*")) {
                entry.diskCompression = UInt32(truncatingIfNeeded: value)
            } else if keyIs(Byte4(ascii: "HLC*")) {
                entry.hardLinkCluster = value
            } else if keyIs(Byte4(ascii: "CLC*")) {
                entry.cloneCluster = value
            } else if keyIs(Byte4(ascii: "DEV*")) {
                entry.device = value
            }
        case 0x50: // "P": a string
            let range = try string(&reader)
            if keyIs(Byte4(ascii: "PAT*")) { entry.path = range } else if keyIs(Byte4(ascii: "LNK*")) { entry.linkTarget = range }
        case 0x54, 0x53: // "T": seconds and nanoseconds; "S": seconds
            let seconds = Int64(bitPattern: try reader.read(Byte8.self, .littleEndian))
            let nanoseconds = subtype == 0x54 ? try reader.read(Byte4.self, .littleEndian) : 0
            if keyIs(Byte4(ascii: "MTM*")) {
                entry.modificationTime = (seconds, nanoseconds)
            } else if keyIs(Byte4(ascii: "CTM*")) {
                entry.creationTime = (seconds, nanoseconds)
            }
        case 0x46: try reader.skip(byteCount: 4) // "F": CRC-32
        case 0x47: try reader.skip(byteCount: 20) // "G": SHA-1
        case 0x48: try reader.skip(byteCount: 32) // "H": SHA-256
        case 0x49: try reader.skip(byteCount: 48) // "I": SHA-384
        case 0x4A: try reader.skip(byteCount: 64) // "J": SHA-512
        case 0x41, 0x42, 0x43: // "A" "B" "C": blobs of 16-, 32-, 64-bit size
            let count: Int
            switch subtype {
            case 0x41: count = try Int(reader.read(Byte2.self, .littleEndian))
            case 0x42: count = try Int(reader.read(Byte4.self, .littleEndian))
            default:
                let wide = try reader.read(Byte8.self, .littleEndian)
                guard wide < 1 << 62 else { return .invalidArchive("blob size") }
                count = Int(wide)
            }
            if keyIs(Byte4(ascii: "DAT*")) {
                return addData(&entry, count: count)
            }
            if keyIs(Byte4(ascii: "XAT*")) {
                entry.extendedAttributes = (entry.blobByteCount, count)
            } else if keyIs(Byte4(ascii: "ACL*")) {
                entry.accessControlList = (entry.blobByteCount, count)
            }
            entry.blobByteCount += count
        default:
            return .invalidArchive("field subtype \(subtype)")
        }
        return nil
    }
}
