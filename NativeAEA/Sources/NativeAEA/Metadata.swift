import Bytes
import Darwin
// User and group lookups for ACL qualifiers: an explicit submodule.
import Darwin.membership
import System

/// Extended attributes and access control lists, applied from the archive's blobs, and the quarantine attribute
/// copied from the archive file.
enum EntryMetadata {
    static let quarantine = "com.apple.quarantine"

    /// `range` of an arena.
    @inline(__always)
    static func slice(_ arena: UnsafeRawBufferPointer, _ range: Range<Int>) -> UnsafeRawBufferPointer {
        unsafe UnsafeRawBufferPointer(rebasing: arena[range]) // Ranges the walker recorded in this arena: safe.
    }

    /// Sets every attribute in an `XAT` blob: entries of u32 size (the entry's, itself included), a NUL-terminated
    /// name, and the value (the rest of the entry).
    static func applyExtendedAttributes(_ descriptor: Int32, _ blob: UnsafeRawBufferPointer) -> AEAError? {
        // A view of the arena's blob, which outlives this call: safe.
        var reader = unsafe AlignedBytesReader(RawSpan(_unsafeBytes: blob))
        while !reader.isAtEnd {
            guard let size = try? Int(reader.read(Byte4.self, .littleEndian)), size >= 5,
                  let entry = try? reader.read(byteCount: size - 4)
            else { return .invalidArchive("extended attribute size") }
            let failure: AEAError? = entry.withUnsafeBytes { bytes in
                // The name runs to its NUL, which must be inside the entry; the value is the rest. `bytes` is the
                // entry, used only here, so the name is NUL-terminated within it and the value lies within it: safe.
                guard let name = bytes.baseAddress, let end = unsafe memchr(name, 0, bytes.count) else {
                    return .invalidArchive("extended attribute name")
                }
                let nameCount = unsafe UnsafeRawPointer(end) - name
                let value = unsafe name + nameCount + 1
                if unsafe fsetxattr(descriptor, name.assumingMemoryBound(to: CChar.self), value, bytes.count - nameCount - 1, 0, 0) != 0 {
                    return .fileSystem("setxattr \(unsafe Paths.string(name, count: nameCount))", Errno(rawValue: errno))
                }
                return nil
            }
            if let failure { return failure }
        }
        return nil
    }

    /// Sets the file's ACL from an `ACL` blob: entries of u32 size (22 + the qualifier's), type (`A` allow, `D`
    /// deny), u64 flags and u64 permissions (macOS's `acl_flag_t` and `acl_perm_t` bits), the qualifier's type (`U`
    /// user name, `G` group name, `I` UUID, `S` SID), and the qualifier.
    ///
    /// The `acl_*` functions allocate; only entries with an ACL get here.
    static func applyAccessControlList(_ descriptor: Int32, _ blob: UnsafeRawBufferPointer) -> AEAError? {
        var count = 0
        var offset = 0
        while offset < blob.count {
            guard blob.count - offset >= 22 else { return .invalidArchive("ACL") }
            let size = Int(UInt32(littleEndian: unsafe blob.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            guard size >= 22, size <= blob.count - offset else { return .invalidArchive("ACL entry size") }
            count += 1
            offset += size
        }
        var acl: acl_t? = unsafe acl_init(Int32(count))
        guard unsafe acl != nil else { return .fileSystem("acl_init", Errno(rawValue: errno)) }
        defer { unsafe acl_free(UnsafeMutableRawPointer(acl)) } // Made above, freed once.
        offset = 0
        while offset < blob.count {
            // Each entry's fixed part (sizes checked by the count above); the qualifier follows.
            var reader = unsafe AlignedBytesReader(RawSpan(_unsafeBytes: UnsafeRawBufferPointer(rebasing: blob[offset...]))) // Within the blob: safe.
            guard let head = try? reader.read(AccessControlEntryHead.self) else { return .invalidArchive("ACL entry") }
            let size = head.size, type = head.type, flags = head.flags, permissions = head.permissions
            let qualifierType = head.qualifierType
            let qualifier = unsafe blob.baseAddress! + offset + 22
            let qualifierCount = size - 22
            offset += size

            var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            // The qualifier, NUL-terminated on the stack (it lies within the entry).
            let resolved = unsafe Paths.withCString(qualifier, count: qualifierCount) { name -> Int32 in
                withUnsafeMutableBytes(of: &uuid) { raw in
                    let bytes = unsafe raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    switch qualifierType {
                    case 0x55: return unsafe mbr_identifier_to_uuid(ID_TYPE_USERNAME, name, strlen(name), bytes) // "U"
                    case 0x47: return unsafe mbr_identifier_to_uuid(ID_TYPE_GROUPNAME, name, strlen(name), bytes) // "G"
                    case 0x49: return unsafe uuid_parse(name, bytes) == 0 ? 0 : EINVAL // "I"
                    case 0x53: // "S"
                        var sid = nt_sid_t()
                        let parsed = unsafe mbr_string_to_sid(name, &sid)
                        return parsed == 0 ? unsafe mbr_sid_to_uuid(&sid, bytes) : parsed
                    default: return EINVAL
                    }
                }
            }
            guard resolved == 0 else {
                return .fileSystem("ACL qualifier \(unsafe Paths.string(qualifier, count: qualifierCount))", Errno(rawValue: resolved))
            }
            var entry: acl_entry_t?
            guard unsafe acl_create_entry(&acl, &entry) == 0, let entry = unsafe entry else { return .fileSystem("acl_create_entry", Errno(rawValue: errno)) }
            let tag: acl_tag_t
            switch type {
            case 0x41: tag = ACL_EXTENDED_ALLOW // "A"
            case 0x44: tag = ACL_EXTENDED_DENY // "D"
            default: return .invalidArchive("ACL entry type \(type)")
            }
            guard unsafe acl_set_tag_type(entry, tag) == 0, unsafe acl_set_qualifier(entry, &uuid) == 0 else {
                return .fileSystem("acl_set_qualifier", Errno(rawValue: errno))
            }
            var permissionSet: acl_permset_t?
            guard unsafe acl_get_permset(entry, &permissionSet) == 0, let permissionSet = unsafe permissionSet else { return .fileSystem("acl_get_permset", Errno(rawValue: errno)) }
            unsafe acl_clear_perms(permissionSet)
            var bits = permissions
            while bits != 0 {
                let bit = bits & (~bits &+ 1)
                bits &= bits - 1
                guard unsafe acl_add_perm(permissionSet, acl_perm_t(UInt32(truncatingIfNeeded: bit))) == 0 else {
                    return .invalidArchive("ACL permission \(bit)")
                }
            }
            guard unsafe acl_set_permset(entry, permissionSet) == 0 else { return .fileSystem("acl_set_permset", Errno(rawValue: errno)) }
            var flagSet: acl_flagset_t?
            guard unsafe acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flagSet) == 0, let flagSet = unsafe flagSet else {
                return .fileSystem("acl_get_flagset_np", Errno(rawValue: errno))
            }
            unsafe acl_clear_flags_np(flagSet)
            bits = flags
            while bits != 0 {
                let bit = bits & (~bits &+ 1)
                bits &= bits - 1
                guard unsafe acl_add_flag_np(flagSet, acl_flag_t(UInt32(truncatingIfNeeded: bit))) == 0 else {
                    return .invalidArchive("ACL flag \(bit)")
                }
            }
            guard unsafe acl_set_flagset_np(UnsafeMutableRawPointer(entry), flagSet) == 0 else {
                return .fileSystem("acl_set_flagset_np", Errno(rawValue: errno))
            }
        }
        if unsafe acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) != 0 { return .fileSystem("acl_set_fd", Errno(rawValue: errno)) }
        return nil
    }

    /// The archive file's quarantine attribute, to copy onto everything extracted (as Apple's `aa extract` does), or
    /// `nil` if it has none.
    static func quarantine(of path: String) -> [UInt8]? {
        var value = [UInt8](repeating: 0, count: 1024)
        let count = value.withUnsafeMutableBytes { unsafe getxattr(path, quarantine, $0.baseAddress, $0.count, 0, 0) }
        guard count > 0 else { return nil }
        value.removeLast(value.count - count)
        return value
    }

    /// Sets the quarantine attribute by path, in one call (no open and close), following no symbolic link anywhere in
    /// the path (`XATTR_NOFOLLOW_ANY`); on a link itself with `link`.
    ///
    /// - Parameters:
    ///   - root: The destination's absolute path, without a trailing slash.
    ///   - path: The entry's path from the destination.
    static func setQuarantine(root: [UInt8], path: UnsafeRawPointer, count: Int, _ value: [UInt8], link: Bool) -> AEAError? {
        let total = root.count + 1 + count
        let result = withUnsafeTemporaryAllocation(byteCount: total + 1, alignment: 1) { buffer -> Int32 in
            // root | "/" | path | NUL, all within the `total + 1` bytes: safe.
            root.withUnsafeBytes { unsafe buffer.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: root.count) }
            unsafe buffer.storeBytes(of: 0x2F, toByteOffset: root.count, as: UInt8.self)
            unsafe (buffer.baseAddress! + root.count + 1).copyMemory(from: path, byteCount: count)
            unsafe buffer.storeBytes(of: 0, toByteOffset: total, as: UInt8.self)
            let options = XATTR_NOFOLLOW_ANY | (link ? XATTR_NOFOLLOW : 0)
            return value.withUnsafeBytes {
                unsafe setxattr(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), quarantine, $0.baseAddress, $0.count, 0, Int32(options))
            }
        }
        return result == 0 ? nil : .fileSystem("setxattr \(quarantine)", Errno(rawValue: errno))
    }

    /// Sets the quarantine attribute on an open file or directory.
    static func setQuarantine(_ descriptor: Int32, _ value: [UInt8]) -> AEAError? {
        let result = value.withUnsafeBytes { unsafe fsetxattr(descriptor, quarantine, $0.baseAddress, $0.count, 0, 0) }
        return result == 0 ? nil : .fileSystem("setxattr \(quarantine)", Errno(rawValue: errno))
    }
}
