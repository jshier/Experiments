import Bytes
import Darwin

// User and group lookups for ACL qualifiers: an explicit submodule.
import Darwin.membership
public import System

/// A point in time as the file system stores it: seconds since 1970 and nanoseconds.
public struct Timestamp: Sendable, Hashable {
    public var seconds: Int64
    public var nanoseconds: UInt32

    public init(seconds: Int64, nanoseconds: UInt32 = 0) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
}

/// An entry's times. Those left `nil` are left as the file system sets them (the time of extraction).
public struct EntryTimes: Sendable, Hashable {
    public var modification: Timestamp?
    public var creation: Timestamp?
    public var access: Timestamp?

    public init(modification: Timestamp? = nil, creation: Timestamp? = nil, access: Timestamp? = nil) {
        self.modification = modification
        self.creation = creation
        self.access = access
    }

    public var isEmpty: Bool { modification == nil && creation == nil && access == nil }
}

/// A user and group ID.
public struct Owner: Sendable, Hashable {
    public var user: UInt32
    public var group: UInt32

    public init(user: UInt32, group: UInt32) {
        self.user = user
        self.group = group
    }
}

/// What an entry carries besides its contents: permissions, owner, times, and BSD flags. Extended attributes and ACLs
/// are added to an entry separately (``Planner/addExtendedAttributes(_:to:)``), since archives carry them as blobs.
///
/// How each is applied is up to the ``DestinationOptions``: special bits, the umask, and owners are applied only as
/// they allow.
public struct EntryMetadata: Sendable, Hashable {
    /// Permission bits, setuid, setgid, and sticky (`0o7777`); `nil` for the default (0644 for files, 0755 for
    /// directories and symbolic links, before the umask).
    public var mode: UInt16?
    /// The owner, restored only with ``DestinationOptions/restoresOwnership`` and only by root.
    public var owner: Owner?
    public var times: EntryTimes
    /// BSD flags (`chflags`): `UF_HIDDEN`, `UF_IMMUTABLE`, … `UF_COMPRESSED` is ignored (Disk sets it when it writes a
    /// file compressed); `SF_` flags need root and are dropped otherwise.
    public var flags: UInt32

    public init(mode: UInt16? = nil, owner: Owner? = nil, times: EntryTimes = EntryTimes(), flags: UInt32 = 0) {
        self.mode = mode
        self.owner = owner
        self.times = times
        self.flags = flags
    }
}

// MARK: - Applying metadata in one call

/// The attributes `fsetattrlist` sets in one call: creation, modification, and access times, owner, group, mode, and
/// flags, packed in their bits' order (`ATTR_CMN_CRTIME` … `ATTR_CMN_FLAGS`).
///
/// One call replaces `fchown`, `fchmod`, `fchflags`, and `fsetattrlist` (times), and keeps their order right
/// (measured, Disk/RESULTS.md): setting `UF_COMPRESSED` with `fchflags` sets the modification time to now, and
/// `UF_IMMUTABLE` would stop later calls, but in one `fsetattrlist` the times given stick, whatever the flags.
struct AttributeList {
    var list = attrlist()
    /// Room for three `timespec`s, two IDs, the mode, and the flags.
    var values = InlineArray<64, UInt8>(repeating: 0)
    var count = 0

    init() {
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    }

    var isEmpty: Bool { list.commonattr == 0 }

    private mutating func append<T: BitwiseCopyable>(_ value: T) {
        var span = values.mutableSpan
        // Unsafe: stores `value` at offset `count` of the values' raw buffer (unchecked in release). Safe: the only
        // caller, `init(times:owner:mode:flags:)`, appends at most 3 × 16 + 4 × 4 = 64 bytes in total, the array's
        // size, so `count + size(T) <= 64`; the buffer is valid inside `withUnsafeMutableBytes`.
        span.withUnsafeMutableBytes { unsafe $0.storeBytes(of: value, toByteOffset: count, as: T.self) }
        count += MemoryLayout<T>.size
    }

    private static func timespec(_ time: Timestamp) -> Darwin.timespec {
        Darwin.timespec(tv_sec: Int(time.seconds), tv_nsec: Int(time.nanoseconds))
    }

    /// The attributes for `times`, `owner`, `mode` and `flags` (each `nil` to leave alone), in bit order.
    init(times: EntryTimes, owner: Owner?, mode: mode_t?, flags: UInt32?) {
        self.init()
        if let creation = times.creation {
            list.commonattr |= attrgroup_t(ATTR_CMN_CRTIME)
            append(Self.timespec(creation))
        }
        if let modification = times.modification {
            list.commonattr |= attrgroup_t(ATTR_CMN_MODTIME)
            append(Self.timespec(modification))
        }
        if let access = times.access {
            list.commonattr |= attrgroup_t(ATTR_CMN_ACCTIME)
            append(Self.timespec(access))
        }
        if let owner {
            list.commonattr |= attrgroup_t(ATTR_CMN_OWNERID) | attrgroup_t(ATTR_CMN_GRPID)
            append(owner.user)
            append(owner.group)
        }
        if let mode {
            list.commonattr |= attrgroup_t(ATTR_CMN_ACCESSMASK)
            append(UInt32(mode))
        }
        if let flags {
            list.commonattr |= attrgroup_t(ATTR_CMN_FLAGS)
            append(flags)
        }
    }

    /// Sets them on an open file or directory.
    ///
    /// Flags alone go through `fchflags`, which costs the kernel 62,000 instructions less than `fsetattrlist` with
    /// only `ATTR_CMN_FLAGS` (a C probe: 747,000 against 809,000 per inline-compressed file; NativeAEA/RESULTS.md,
    /// 2026-11-20). `fchflags(UF_COMPRESSED)` sets the modification time to now, which matters only when times are
    /// set too: then everything goes in the one `fsetattrlist`, which keeps the times given (Disk/RESULTS.md).
    mutating func apply(_ descriptor: Int32) -> Int32 {
        if isEmpty { return 0 }
        if list.commonattr == attrgroup_t(ATTR_CMN_FLAGS) {
            // Unsafe: an unchecked, unaligned `UInt32` load from the values' start. Safe: the array is 64 bytes, and
            // the only value is the flags: its first 4 bytes, a `UInt32` stored by `append`.
            return Sys.fchflags(descriptor, unsafe values.span.bytes.unsafeLoadUnaligned(as: UInt32.self))
        }
        let count = count
        var span = values.mutableSpan
        // Unsafe: pointers to the list and to the values, to `fsetattrlist`. Safe: both are this value's own (`self`
        // is `mutating`: exclusive), valid inside `withUnsafeMutableBytes`; the 64-byte buffer is never `nil`, and
        // `count`, the bytes `append` packed, is at most 64; the call only reads them.
        return span.withUnsafeMutableBytes { values in
            unsafe Sys.fsetattrlist(descriptor, &list, values.baseAddress!, count)
        }
    }

    /// Sets them on `name` in `directory` (one component, or a path resolved without following links), on a symbolic
    /// link itself.
    mutating func apply(_ directory: Int32, _ name: UnsafePointer<CChar>) -> Int32 {
        if isEmpty { return 0 }
        let count = count
        var span = values.mutableSpan
        // Unsafe: `name` and pointers to the list and to the values, to `setattrlistat`. Safe: `name` is the caller's
        // NUL-terminated string, valid for this call; the list and the 64-byte buffer (never `nil`) are this value's
        // own, valid inside `withUnsafeMutableBytes`, `count` at most 64; the call only reads them.
        return span.withUnsafeMutableBytes { values in
            unsafe Sys.setattrlistat(directory, name, &list, values.baseAddress!, count, UInt32(FSOPT_NOFOLLOW | FSOPT_NOFOLLOW_ANY))
        }
    }
}

// MARK: - Extended attributes and ACLs

/// Extended attributes as Apple Archive's `XAT` blob holds them, the form Disk takes them in: for each, a 32-bit
/// little-endian size (of the whole entry, itself included), the name, a NUL, and the value (the rest of the entry).
///
/// ```swift
/// var attributes = ExtendedAttributeBlob()
/// attributes.append(name: "com.apple.FinderInfo", value: finderInfo.span.bytes)
/// try planner.addExtendedAttributes(attributes.bytes.span.bytes, to: token)
/// ```
public struct ExtendedAttributeBlob: Sendable {
    /// The encoded attributes.
    public private(set) var bytes: [UInt8] = []

    public init() {}

    /// Appends one attribute.
    public mutating func append(name: String, value: RawSpan) {
        let size = 4 + name.utf8.count + 1 + value.byteCount
        bytes.append(UInt32(size), as: Byte4.self, .littleEndian)
        bytes.append(contentsOf: name.utf8)
        bytes.append(0)
        bytes.append(copying: value)
    }
}

/// An ACL as Apple Archive's `ACL` blob holds it (the form Disk takes them in, see ``Planner/addAccessControlList(_:to:)``),
/// made from the text form (`acl_to_text`'s: `!#acl 1`, then a line per entry) that AppleDouble files carry as the
/// `com.apple.acl.text` attribute.
public struct AccessControlListBlob: Sendable {
    /// The encoded entries.
    public private(set) var bytes: [UInt8] = []

    /// Parses `text` (`acl_from_text`); `nil` if it isn't an ACL's text, or has no entries.
    public init?(text: RawSpan) {
        // Unsafe: `CString.with` hands the body a pointer. Safe: its NUL-terminated copy of the text's bytes, valid
        // inside the body, which keeps nothing.
        let parsed: [UInt8]? = unsafe CString.with(text) { string -> [UInt8]? in
            // Unsafe: `acl_from_text` reads `string` and returns a new ACL. Safe: NUL-terminated (above); the ACL is
            // checked for `nil`, owned here, and freed once by the `defer`.
            guard let acl = unsafe acl_from_text(string) else { return nil }
            // Unsafe: frees the ACL. Safe: the one just made, after the last use of it and of its entries.
            defer { unsafe acl_free(UnsafeMutableRawPointer(acl)) }
            var result: [UInt8] = []
            var entry: acl_entry_t?
            var which = ACL_FIRST_ENTRY.rawValue
            // Unsafe: `acl_get_entry` with the live ACL and a pointer to `entry`, then reads it. Safe: the entry, when
            // the call succeeds, is the ACL's, valid while it lives (this closure), used only in this iteration.
            while unsafe acl_get_entry(acl, which, &entry) == 0, let current = unsafe entry {
                which = ACL_NEXT_ENTRY.rawValue
                var tag = ACL_UNDEFINED_TAG
                var mask: acl_permset_mask_t = 0
                var flagSet: acl_flagset_t?
                // Unsafe (the next three): the live entry to `acl_get_tag_type`, `acl_get_permset_mask_np`, and
                // `acl_get_flagset_np`, each with a pointer to a local it fills. Safe: an entry of the live ACL.
                guard unsafe acl_get_tag_type(current, &tag) == 0, unsafe acl_get_permset_mask_np(current, &mask) == 0,
                      unsafe acl_get_flagset_np(UnsafeMutableRawPointer(current), &flagSet) == 0, let flagSet = unsafe flagSet,
                      tag == ACL_EXTENDED_ALLOW || tag == ACL_EXTENDED_DENY
                else { return nil }
                var flags: UInt64 = 0
                for flag in [ACL_ENTRY_INHERITED, ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_LIMIT_INHERIT, ACL_ENTRY_ONLY_INHERIT] {
                    // Unsafe: `acl_get_flag_np` on the entry's flag set. Safe: part of the live entry.
                    if unsafe acl_get_flag_np(flagSet, flag) == 1 { flags |= UInt64(flag.rawValue) }
                }
                // Unsafe: `acl_get_qualifier` returns a new copy of the entry's UUID. Safe: checked for `nil`, read
                // as the 16 bytes of a `guid_t` by `uuid_unparse_upper`, and freed once, below.
                guard let qualifier = unsafe acl_get_qualifier(current) else { return nil }
                var uuidText = [CChar](repeating: 0, count: 37)
                // Unsafe: the UUID's 16 bytes to `uuid_unparse_upper`, which writes 37 bytes of text. Safe: the
                // qualifier is a `guid_t` (16 bytes); the array has 37.
                unsafe uuid_unparse_upper(qualifier.assumingMemoryBound(to: UInt8.self), &uuidText)
                // Unsafe: frees the qualifier. Safe: `acl_get_qualifier`'s copy, freed once, not used after.
                unsafe acl_free(qualifier)
                result.append(UInt32(22 + 36), as: Byte4.self, .littleEndian)
                result.append(tag == ACL_EXTENDED_ALLOW ? 0x41 : 0x44)
                result.append(flags, as: Byte8.self, .littleEndian)
                result.append(UInt64(mask), as: Byte8.self, .littleEndian)
                result.append(0x49) // "I": a UUID
                result.append(contentsOf: uuidText.prefix(36).map { UInt8(bitPattern: $0) })
            }
            return result
        }
        guard let parsed, !parsed.isEmpty else { return nil }
        bytes = parsed
    }
}

enum EntryAttributes {
    static let quarantine = "com.apple.quarantine"

    /// Sets every attribute of an `XAT` blob on an open file.
    static func applyExtendedAttributes(_ descriptor: Int32, _ blob: RawSpan, path: PathRef) throws(DiskError) {
        var reader = AlignedBytesReader(blob)
        while !reader.isAtEnd {
            guard let entry = try? reader.read(bytesPrefixedBy: Byte4.self, .littleEndian, includingPrefix: true) else {
                throw .invalidMetadata("extended attribute size, \(path.string)")
            }
            // The name runs to a NUL inside the entry, the value is the rest.
            var fields = AlignedBytesReader(entry)
            let nameCount: Int
            do throws(BytesError) {
                nameCount = try fields.read(bytesTerminatedBy: 0).byteCount
            } catch {
                throw .invalidMetadata("extended attribute name, \(path.string)")
            }
            // The entry's bytes, used within the call.
            let result: Int32 = entry.withUnsafeBytes { bytes in
                // The entry holds at least the name's NUL, so it has an address.
                guard let name = bytes.baseAddress else { return -2 }
                // Unsafe: a pointer past the NUL. Safe: the NUL is at `nameCount < bytes.count`, so this is within the
                // entry or one past its end (then the value is empty, and nothing is read).
                let value = unsafe name + nameCount + 1
                // Unsafe: the name as a C string and the value's bytes to `fsetxattr`. Safe: the name ends at the NUL
                // found above; the value is the `bytes.count - nameCount - 1` bytes after it, the rest of the entry;
                // both valid inside this closure, read only during the call.
                return unsafe Sys.fsetxattr(descriptor, name.assumingMemoryBound(to: CChar.self), value, bytes.count - nameCount - 1, 0) == 0 ? 0 : errno
            }
            if result == -2 { throw .invalidMetadata("extended attribute name, \(path.string)") }
            if result != 0 { throw .system("setxattr", path: path, code: result) }
        }
    }

    /// Sets an open file's ACL from an Apple Archive `ACL` blob: entries of a 32-bit size (22 + the qualifier's), type
    /// (`A` allow, `D` deny), 64-bit flags and permissions (`acl_flag_t` and `acl_perm_t` bits), the qualifier's type
    /// (`U` user name, `G` group name, `I` UUID, `S` SID), and the qualifier. The `acl_*` functions allocate: only
    /// entries with an ACL get here.
    static func applyAccessControlList(_ descriptor: Int32, _ blob: RawSpan, path: PathRef) throws(DiskError) {
        // The first pass counts the entries, checking each one's size: at least the 22 bytes of its fixed fields.
        var count = 0
        var entries = LittleEndianBytesReader(blob)
        while !entries.isAtEnd {
            guard let entry = try? entries.read(bytesPrefixedBy: Byte4.self, includingPrefix: true), entry.byteCount >= 18 else {
                throw .invalidMetadata("ACL entry size, \(path.string)")
            }
            count += 1
        }
        // Unsafe: `acl_init` returns a pointer to a new ACL. Safe: checked for `nil` next; owned here, and freed
        // exactly once, by the `defer` below, on every way out.
        var acl: acl_t? = unsafe acl_init(Int32(count))
        // Unsafe: reads the pointer. Safe: only its value, compared with `nil`.
        guard unsafe acl != nil else { throw .system("acl_init", path: path, code: errno) }
        // Unsafe: frees the ACL. Safe: the one made above (or where `acl_create_entry` moved it: it updates
        // `acl`), freed once, after the last use of it and of its entries.
        defer { unsafe acl_free(UnsafeMutableRawPointer(acl)) }
        entries = LittleEndianBytesReader(blob)
        while !entries.isAtEnd {
            // The first pass checked every entry's size, so these reads don't fail.
            guard var fields = try? entries.read(sectionPrefixedBy: Byte4.self, includingPrefix: true) else {
                throw .invalidMetadata("ACL entry size, \(path.string)")
            }
            guard let type = try? fields.read(UInt8.self), let flags = try? fields.read(UInt64.self),
                  let permissions = try? fields.read(UInt64.self), let qualifierType = try? fields.read(UInt8.self)
            else { throw .invalidMetadata("ACL, \(path.string)") }
            let qualifier = fields.readRemainingBytes()

            var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            // Unsafe: `CString.with` hands the body a pointer. Safe: `name` is its NUL-terminated copy of the
            // qualifier (the rest of the entry), valid inside the body.
            let resolved = unsafe CString.with(qualifier) { name -> Int32 in
                withUnsafeMutableBytes(of: &uuid) { raw in
                    // Unsafe: the UUID's raw bytes as `UInt8`s. Safe: `uuid_t` is 16 `UInt8`s (so not `nil`),
                    // exclusively borrowed inside `withUnsafeMutableBytes`, which each call below returns within.
                    let bytes = unsafe raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    switch qualifierType {
                    // Unsafe (the next two): `name`, its `strlen`, and the UUID's bytes to
                    // `mbr_identifier_to_uuid`. Safe: `name` is NUL-terminated (above), read for that length;
                    // the call writes the 16 bytes of a UUID at `bytes`.
                    case 0x55: return unsafe mbr_identifier_to_uuid(ID_TYPE_USERNAME, name, strlen(name), bytes) // "U"
                    case 0x47: return unsafe mbr_identifier_to_uuid(ID_TYPE_GROUPNAME, name, strlen(name), bytes) // "G"
                    // Unsafe: `name` and the UUID's bytes to `uuid_parse`. Safe: NUL-terminated; it writes 16 bytes.
                    case 0x49: return unsafe uuid_parse(name, bytes) == 0 ? 0 : EINVAL // "I"
                    case 0x53: // "S"
                        var sid = nt_sid_t()
                        // Unsafe: `name` and a pointer to `sid` to `mbr_string_to_sid`. Safe: NUL-terminated; it
                        // fills one `nt_sid_t`, a local.
                        let parsed = unsafe mbr_string_to_sid(name, &sid)
                        // Unsafe: a pointer to `sid` and the UUID's bytes to `mbr_sid_to_uuid`. Safe: it reads the
                        // local `nt_sid_t` just filled and writes the 16 bytes of a UUID.
                        return parsed == 0 ? unsafe mbr_sid_to_uuid(&sid, bytes) : parsed
                    default: return EINVAL
                    }
                }
            }
            guard resolved == 0 else { throw .invalidMetadata("ACL qualifier, \(path.string)") }
            var entry: acl_entry_t?
            // Unsafe: `acl_create_entry` with pointers to `acl` and `entry`, then reads `entry`. Safe: `acl` is the
            // live ACL (the call may move it, and updates `acl`); `entry`, when it succeeds, is an entry of it,
            // valid while the ACL lives (to the end of this closure), and used only in this iteration.
            guard unsafe acl_create_entry(&acl, &entry) == 0, let entry = unsafe entry else { throw .system("acl_create_entry", path: path, code: errno) }
            let tag: acl_tag_t
            switch type {
            case 0x41: tag = ACL_EXTENDED_ALLOW // "A"
            case 0x44: tag = ACL_EXTENDED_DENY // "D"
            default: throw .invalidMetadata("ACL entry type \(type), \(path.string)")
            }
            // Unsafe (both): `entry` to `acl_set_tag_type` and, with a pointer to `uuid`, to `acl_set_qualifier`.
            // Safe: an entry of the live ACL; the qualifier call copies the 16 bytes of the local `uuid`.
            guard unsafe acl_set_tag_type(entry, tag) == 0, unsafe acl_set_qualifier(entry, &uuid) == 0 else {
                throw .system("acl_set_qualifier", path: path, code: errno)
            }
            var permissionSet: acl_permset_t?
            // Unsafe: `acl_get_permset` with `entry` and a pointer to `permissionSet`, then reads it. Safe: an
            // entry of the live ACL; the set, when the call succeeds, is part of that entry, valid as long.
            guard unsafe acl_get_permset(entry, &permissionSet) == 0, let permissionSet = unsafe permissionSet else { throw .system("acl_get_permset", path: path, code: errno) }
            // Unsafe: `acl_clear_perms` on the set. Safe: the live entry's permission set, just fetched.
            unsafe acl_clear_perms(permissionSet)
            var bits = permissions
            while bits != 0 {
                let bit = bits & (~bits &+ 1)
                bits &= bits - 1
                // Unsafe: `acl_add_perm` on the set. Safe: the live entry's permission set; a bit it doesn't
                // know is refused by the call (an error, thrown).
                guard unsafe acl_add_perm(permissionSet, acl_perm_t(UInt32(truncatingIfNeeded: bit))) == 0 else {
                    throw .invalidMetadata("ACL permission \(bit), \(path.string)")
                }
            }
            // Unsafe: `acl_set_permset` with `entry` and its set. Safe: both the live ACL's, as above.
            guard unsafe acl_set_permset(entry, permissionSet) == 0 else { throw .system("acl_set_permset", path: path, code: errno) }
            var flagSet: acl_flagset_t?
            // Unsafe: `acl_get_flagset_np` with `entry` (as the raw pointer it takes) and a pointer to `flagSet`,
            // then reads it. Safe: an entry of the live ACL, one of the objects the call accepts; the set, when
            // it succeeds, is part of that entry, valid as long.
            guard unsafe acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flagSet) == 0, let flagSet = unsafe flagSet else {
                throw .system("acl_get_flagset_np", path: path, code: errno)
            }
            // Unsafe: `acl_clear_flags_np` on the set. Safe: the live entry's flag set, just fetched.
            unsafe acl_clear_flags_np(flagSet)
            bits = flags
            while bits != 0 {
                let bit = bits & (~bits &+ 1)
                bits &= bits - 1
                // Unsafe: `acl_add_flag_np` on the set. Safe: the live entry's flag set; a bit it doesn't know is
                // refused by the call (an error, thrown).
                guard unsafe acl_add_flag_np(flagSet, acl_flag_t(UInt32(truncatingIfNeeded: bit))) == 0 else {
                    throw .invalidMetadata("ACL flag \(bit), \(path.string)")
                }
            }
            // Unsafe: `acl_set_flagset_np` with `entry` and its set. Safe: both the live ACL's, as above.
            guard unsafe acl_set_flagset_np(UnsafeMutableRawPointer(entry), flagSet) == 0 else {
                throw .system("acl_set_flagset_np", path: path, code: errno)
            }
        }
        // Unsafe: the ACL to `acl_set_fd_np`. Safe: not `nil` (checked after `acl_init`, and `acl_create_entry`
        // keeps it so), still live: the `defer` frees it only after this.
        if unsafe Sys.aclSet(descriptor, acl!) != 0 { throw .system("acl_set_fd", path: path, code: errno) }
    }
}

// MARK: - Quarantine

/// The `com.apple.quarantine` attribute extracted items get, so Gatekeeper treats them as it treats the archive they
/// came from (as Archive Utility and `aa extract` do).
public struct Quarantine: Sendable, Hashable {
    /// The attribute's value.
    public let value: [UInt8]

    /// A quarantine attribute with this value.
    public init(value: [UInt8]) {
        self.value = value
    }

    /// The quarantine attribute of the file at `path` (the archive), or `nil` if it has none.
    public init?(copyingFrom path: FilePath) {
        var value = [UInt8](repeating: 0, count: 1024)
        // Unsafe (the next two lines): the path's C string and the array's buffer to `getxattr`, which writes the value
        // there. Safe: `withPlatformString`'s NUL-terminated string and the array's 1,024 bytes (its `count` is the
        // size passed), each valid inside its closure, where the call is; the name is a string constant's C string.
        let count = unsafe path.withPlatformString { path in
            value.withUnsafeMutableBytes { unsafe getxattr(path, EntryAttributes.quarantine, $0.baseAddress, $0.count, 0, 0) }
        }
        guard count > 0 else { return nil }
        value.removeLast(value.count - count)
        self.value = value
    }

    /// Sets it on an open item.
    ///
    /// - Returns: `nil`, or the `errno` of a failure (the destination decides what a failure means:
    ///   `Destination.quarantine(_:path:)`).
    func apply(_ descriptor: Int32) -> Int32? {
        // Unsafe: the value's buffer to `fsetxattr`. Safe: the array's own `count` bytes (or `nil` and 0), valid inside
        // `withUnsafeBytes`, read only during the call; the name is a string constant's C string.
        let result = value.withUnsafeBytes { unsafe Sys.fsetxattr(descriptor, EntryAttributes.quarantine, $0.baseAddress, $0.count, 0) }
        return result == 0 ? nil : errno
    }
}

/// NUL-terminated copies of byte runs, on the stack.
enum CString {
    /// Calls `body` with a NUL-terminated copy of `count` bytes at `bytes`.
    @inline(__always)
    static func with<R, E: Error>(_ bytes: UnsafeRawPointer, count: Int, _ body: (UnsafePointer<CChar>) throws(E) -> R) throws(E) -> R {
        // `count + 1` bytes of stack: the caller's `count` bytes, then the NUL.
        try withUnsafeTemporaryAllocation(byteCount: count + 1, alignment: 1) { buffer throws(E) -> R in
            // Unsafe (the next two): copies the caller's bytes into the temporary buffer and stores a NUL after them.
            // Safe: the caller keeps `count` readable bytes at `bytes` for the call (the contract; with a count of 0
            // nothing is read); the buffer is `count + 1` bytes (at least 1, so not `nil`), valid inside this closure.
            unsafe buffer.baseAddress!.copyMemory(from: bytes, byteCount: count)
            unsafe buffer.storeBytes(of: 0, toByteOffset: count, as: UInt8.self)
            // Unsafe: the buffer as a C string to `body`. Safe: NUL-terminated just above, bytes `CChar`-compatible,
            // valid until this closure returns, which `body` (non-escaping) does first.
            return try unsafe body(buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Calls `body` with a NUL-terminated copy of a span's bytes.
    @inline(__always)
    static func with<R, E: Error>(_ span: RawSpan, _ body: (UnsafePointer<CChar>) throws(E) -> R) throws(E) -> R {
        // Unsafe (the line after next): the span's buffer, as a pointer and a count, to `with(_:count:_:)`. Safe: the
        // span's own bytes, valid inside `withUnsafeBytes`, copied there; for an empty span with no address, a
        // made-up non-null one (1) that's never read, its count being 0.
        try span.withUnsafeBytes { bytes throws(E) -> R in
            try unsafe with(bytes.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, count: bytes.count, body)
        }
    }
}
