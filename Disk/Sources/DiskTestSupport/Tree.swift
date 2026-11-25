import Darwin
public import Foundation
import System

// Reading what an extraction left on disk, for Disk's, NativeAEA's, and NativeZip's tests (and anything else that
// compares extracted trees): items by relative path, with as much of each as a test asks for. No Swift Testing, like
// Bytes' `BytesTestSupport`, so benchmarks and tools can use it too.
//
// Everything here reads without following symbolic links (`lstat`, `XATTR_NOFOLLOW`, `acl_get_link_np`): a link's own
// mode, attributes, and ACL are what an extraction set on it.

/// A check in a test helper that failed.
public struct TestFailure: Error, CustomStringConvertible {
    /// What failed.
    public var description: String

    /// A failure described by `description`.
    ///
    /// - Parameter description: What failed.
    public init(description: String) {
        self.description = description
    }
}

/// What an item looks like on disk: its kind and mode, and whatever else ``readTree(_:including:ignoringAttributes:)``
/// or ``readItem(at:including:ignoringAttributes:)`` was asked to read.
///
/// A field whose ``TreeParts`` member wasn't asked for is `nil`, so trees read with the same parts compare field for
/// field, and an expected item written by hand leaves out what isn't compared.
public struct TreeItem: Equatable, Sendable, CustomStringConvertible {
    /// The file type, from `lstat`.
    public enum Kind: String, Sendable {
        case directory
        case file
        case symbolicLink
        case fifo
        /// A socket or a device.
        case other
    }

    /// A time to the nanosecond (`st_mtimespec`).
    public struct Time: Hashable, Sendable, CustomStringConvertible {
        public var seconds: Int
        public var nanoseconds: Int

        /// - Parameters:
        ///   - seconds: Seconds since 1970.
        ///   - nanoseconds: And nanoseconds.
        public init(seconds: Int, nanoseconds: Int = 0) {
            self.seconds = seconds
            self.nanoseconds = nanoseconds
        }

        public var description: String { nanoseconds == 0 ? "\(seconds)" : "\(seconds).\(nanoseconds)" }
    }

    /// The file type.
    public var kind: Kind
    /// The permission bits, setuid, setgid, and sticky included (`st_mode & 0o7777`).
    public var mode: UInt16
    /// `st_flags` (``TreeParts/flags``): `UF_COMPRESSED` for APFS-compressed files, `UF_IMMUTABLE`, ….
    public var flags: UInt32?
    /// A file's size (``TreeParts/size``); `nil` for other kinds.
    public var size: Int64?
    /// The modification time (``TreeParts/modification``).
    public var modification: Time?
    /// A file's bytes (``TreeParts/contents``); `nil` for other kinds.
    public var contents: [UInt8]?
    /// A symbolic link's target, always read for links; `nil` for other kinds.
    public var linkTarget: String?
    /// The item's extended attributes by name (``TreeParts/attributes``), less the ones the read ignored.
    public var attributes: [String: [UInt8]]?
    /// The item's ACL as `acl_to_text` writes it (``TreeParts/accessControlList``); `nil` when it has none, too.
    public var accessControlList: String?
    /// For a file, the relative paths of every name it has in the tree, sorted, its own included
    /// (``TreeParts/hardLinks``, in ``readTree(_:including:ignoringAttributes:)`` only); empty for other kinds.
    /// Paths, not inode numbers, so two trees compare.
    public var hardLinks: [String]?

    /// An item; leave out what isn't compared.
    public init(
        kind: Kind, mode: UInt16, flags: UInt32? = nil, size: Int64? = nil, modification: Time? = nil,
        contents: [UInt8]? = nil, linkTarget: String? = nil, attributes: [String: [UInt8]]? = nil,
        accessControlList: String? = nil, hardLinks: [String]? = nil
    ) {
        self.kind = kind
        self.mode = mode
        self.flags = flags
        self.size = size
        self.modification = modification
        self.contents = contents
        self.linkTarget = linkTarget
        self.attributes = attributes
        self.accessControlList = accessControlList
        self.hardLinks = hardLinks
    }

    /// Whether the file is APFS-compressed (`UF_COMPRESSED`); `nil` if the flags weren't read.
    public var isCompressed: Bool? { flags.map { $0 & UInt32(UF_COMPRESSED) != 0 } }

    public var description: String {
        var parts = [kind.rawValue, String(mode, radix: 8)]
        if let contents { parts.append("\(contents.count) bytes") } else if let size { parts.append("size \(size)") }
        if let linkTarget { parts.append("-> \(linkTarget)") }
        if let flags, flags != 0 { parts.append("flags \(String(flags, radix: 16))") }
        if let modification { parts.append("mtime \(modification)") }
        if let attributes, !attributes.isEmpty {
            parts.append("xattrs [\(attributes.map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", "))]")
        }
        if let accessControlList { parts.append("acl \(accessControlList.debugDescription)") }
        if let hardLinks, hardLinks.count > 1 { parts.append("links \(hardLinks)") }
        return parts.joined(separator: " ")
    }
}

/// What ``readTree(_:including:ignoringAttributes:)`` reads beyond every item's kind, mode, and link target.
public struct TreeParts: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Files' bytes.
    public static let contents = TreeParts(rawValue: 1 << 0)
    /// Files' sizes (`st_size`).
    public static let size = TreeParts(rawValue: 1 << 1)
    /// `st_flags`.
    public static let flags = TreeParts(rawValue: 1 << 2)
    /// Modification times, to the nanosecond.
    public static let modification = TreeParts(rawValue: 1 << 3)
    /// Extended attributes, less the ignored ones.
    public static let attributes = TreeParts(rawValue: 1 << 4)
    /// ACLs, as text.
    public static let accessControlList = TreeParts(rawValue: 1 << 5)
    /// Which names are one file.
    public static let hardLinks = TreeParts(rawValue: 1 << 6)

    /// Everything.
    public static let all: TreeParts = [.contents, .size, .flags, .modification, .attributes, .accessControlList, .hardLinks]
    /// Everything but contents and sizes: what an extraction restores besides the bytes.
    public static let metadata: TreeParts = [.flags, .modification, .attributes, .accessControlList, .hardLinks]
}

/// Extended attributes the system puts on items whatever wrote them.
public enum SystemAttributes {
    /// `com.apple.provenance`: in a process macOS tracks (one started from a quarantined app, such as a downloaded
    /// terminal), the kernel puts it on every file, directory, and symbolic link the process creates, and owns it:
    /// `setxattr` and `removexattr` succeed and change nothing. A reference tree made by `ditto` or `aa` has it as
    /// much as the tree under test, so comparisons leave it out unless a test asks for it.
    public static let provenance = "com.apple.provenance"

    /// The attributes reads leave out by default.
    public static let ignoredByDefault: Set<String> = [provenance]

    /// Whether this process is provenance-tracked: a value set on a fresh scratch file doesn't read back. In such a
    /// process, a `com.apple.provenance` that an extraction restores is never seen.
    ///
    /// - Parameter directory: Where to make the scratch file (removed after).
    /// - Returns: `true` if the value didn't read back.
    public static func isProvenanceTracked(scratchDirectory directory: URL) -> Bool {
        let path = directory.appending(path: "provenance-probe-\(UUID().uuidString)").path(percentEncoded: false)
        guard FileManager.default.createFile(atPath: path, contents: nil) else { return true }
        // A Swift string passed as a C string, valid for the call.
        defer { unsafe unlink(path) }
        let probe: [UInt8] = [0x01, 0x02, 0x00, 0x50, 0x52, 0x4F, 0x42, 0x45, 0x00, 0x00, 0x01]
        // The value's bytes for the call.
        _ = probe.withUnsafeBytes { unsafe setxattr(path, provenance, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        return extendedAttribute(provenance, of: path) != probe
    }
}

/// Every item under `root`, by path relative to it, not following symbolic links.
///
/// The walk is `opendir`/`readdir`, so `._` files are listed (Foundation's directory enumerators leave them out).
///
/// - Parameters:
///   - root: The directory; not itself listed.
///   - parts: What to read beyond each item's kind, mode, and link target.
///   - ignoringAttributes: Extended attributes to leave out (with ``TreeParts/attributes``); empty to read every one.
/// - Returns: The items by relative path (`a/b`).
/// - Throws: ``TestFailure`` if a directory can't be listed or an item can't be read.
public func readTree(
    _ root: URL, including parts: TreeParts = .contents, ignoringAttributes: Set<String> = SystemAttributes.ignoredByDefault
) throws -> [String: TreeItem] {
    let rootPath = root.path(percentEncoded: false)
    var result: [String: TreeItem] = [:]
    var inodes: [UInt64: [String]] = [:]
    for relative in try treePaths(under: root) {
        let path = rootPath + "/" + relative
        let (item, info) = try readItem(path: path, including: parts, ignoringAttributes: ignoringAttributes)
        result[relative] = item
        if parts.contains(.hardLinks), item.kind == .file { inodes[info.st_ino, default: []].append(relative) }
    }
    if parts.contains(.hardLinks) {
        for path in result.keys {
            result[path]!.hardLinks = []
        }
        for group in inodes.values {
            let sorted = group.sorted()
            for path in group {
                result[path]!.hardLinks = sorted
            }
        }
    }
    return result
}

/// One item, not following a symbolic link. ``TreeParts/hardLinks`` needs a tree: here it's left `nil`.
///
/// - Parameters:
///   - url: The item.
///   - parts: What to read beyond its kind, mode, and link target.
///   - ignoringAttributes: Extended attributes to leave out.
/// - Returns: The item.
/// - Throws: ``TestFailure`` if it isn't there or can't be read.
public func readItem(
    at url: URL, including parts: TreeParts = .contents, ignoringAttributes: Set<String> = SystemAttributes.ignoredByDefault
) throws -> TreeItem {
    var parts = parts
    parts.remove(.hardLinks)
    return try readItem(path: url.path(percentEncoded: false), including: parts, ignoringAttributes: ignoringAttributes).item
}

/// Every path under `root`, relative to it, by `opendir`/`readdir` (`._` files included), parents before their
/// contents.
///
/// - Parameter root: The directory; not itself listed.
/// - Returns: The relative paths, in directory order.
/// - Throws: ``TestFailure`` if a directory can't be listed.
public func treePaths(under root: URL) throws -> [String] {
    var result: [String] = []
    try appendPaths(under: root.path(percentEncoded: false), prefix: "", to: &result)
    return result
}

private func appendPaths(under directory: String, prefix: String, to result: inout [String]) throws {
    guard let stream = unsafe opendir(directory) else {
        throw TestFailure(description: "opendir \(directory): \(Errno(rawValue: errno))")
    }
    defer { unsafe closedir(stream) }
    var subdirectories: [String] = []
    // `readdir`'s entry is valid until the next call on the stream, and only read before it; `d_name` is a
    // NUL-terminated name inside it.
    while let entry = unsafe readdir(stream) {
        let name = unsafe withUnsafePointer(to: entry.pointee.d_name) {
            unsafe String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        guard name != ".", name != ".." else { continue }
        result.append(prefix + name)
        var isDirectory = unsafe entry.pointee.d_type == DT_DIR
        if unsafe entry.pointee.d_type == DT_UNKNOWN {
            var info = stat()
            // The path as a C string and `info`, valid for the call.
            isDirectory = unsafe lstat(directory + "/" + name, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }
        if isDirectory { subdirectories.append(name) }
    }
    for name in subdirectories {
        try appendPaths(under: directory + "/" + name, prefix: prefix + name + "/", to: &result)
    }
}

private func readItem(path: String, including parts: TreeParts, ignoringAttributes: Set<String>) throws -> (item: TreeItem, info: stat) {
    var info = stat()
    // The path as a C string and `info`, valid for the call.
    guard unsafe lstat(path, &info) == 0 else { throw TestFailure(description: "lstat \(path): \(Errno(rawValue: errno))") }
    let kind: TreeItem.Kind = switch info.st_mode & S_IFMT {
    case S_IFDIR: .directory
    case S_IFREG: .file
    case S_IFLNK: .symbolicLink
    case S_IFIFO: .fifo
    default: .other
    }
    var item = TreeItem(kind: kind, mode: UInt16(info.st_mode & 0o7777))
    if parts.contains(.flags) { item.flags = info.st_flags }
    if parts.contains(.size), kind == .file { item.size = info.st_size }
    if parts.contains(.modification) {
        item.modification = TreeItem.Time(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
    if parts.contains(.contents), kind == .file {
        do {
            item.contents = try Array(Data(contentsOf: URL(filePath: path)))
        } catch {
            throw TestFailure(description: "reading \(path): \(error)")
        }
    }
    if kind == .symbolicLink {
        do {
            item.linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: path)
        } catch {
            throw TestFailure(description: "readlink \(path): \(error)")
        }
    }
    if parts.contains(.attributes) { item.attributes = extendedAttributes(of: path, ignoring: ignoringAttributes) }
    if parts.contains(.accessControlList) { item.accessControlList = accessControlListText(of: path) }
    return (item, info)
}

/// An item's extended attributes by name, not following a symbolic link.
///
/// - Parameters:
///   - path: The item.
///   - ignoring: Attributes to leave out; empty for every one.
/// - Returns: The attributes; empty if it has none or can't be read.
public func extendedAttributes(of path: String, ignoring: Set<String> = SystemAttributes.ignoredByDefault) -> [String: [UInt8]] {
    // The size passed is `nil`'s 0: the call only reports the names' total length.
    let size = unsafe listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return [:] }
    var names = [UInt8](repeating: 0, count: size)
    // The buffer and its size, valid for the call.
    let read = names.withUnsafeMutableBytes { unsafe listxattr(path, $0.baseAddress, $0.count, XATTR_NOFOLLOW) }
    guard read > 0 else { return [:] }
    var result: [String: [UInt8]] = [:]
    for name in names.prefix(read).split(separator: 0).map({ String(decoding: $0, as: UTF8.self) }) where !ignoring.contains(name) {
        if let value = extendedAttribute(name, of: path) { result[name] = value }
    }
    return result
}

/// An item's extended attributes by name, not following a symbolic link.
///
/// - Parameters:
///   - url: The item.
///   - ignoring: Attributes to leave out; empty for every one.
/// - Returns: The attributes; empty if it has none or can't be read.
public func extendedAttributes(of url: URL, ignoring: Set<String> = SystemAttributes.ignoredByDefault) -> [String: [UInt8]] {
    extendedAttributes(of: url.path(percentEncoded: false), ignoring: ignoring)
}

/// One extended attribute's value, not following a symbolic link.
///
/// - Parameters:
///   - name: The attribute.
///   - path: The item.
/// - Returns: Its value, or `nil` if the item doesn't have it.
public func extendedAttribute(_ name: String, of path: String) -> [UInt8]? {
    attributeValue(name, of: path, options: XATTR_NOFOLLOW)
}

/// One extended attribute's value, not following a symbolic link.
///
/// - Parameters:
///   - name: The attribute.
///   - url: The item.
/// - Returns: Its value, or `nil` if the item doesn't have it.
public func extendedAttribute(_ name: String, of url: URL) -> [UInt8]? {
    extendedAttribute(name, of: url.path(percentEncoded: false))
}

private func attributeValue(_ name: String, of path: String, options: Int32) -> [UInt8]? {
    // The size passed is `nil`'s 0: the call only reports the value's length.
    let size = unsafe getxattr(path, name, nil, 0, 0, options)
    guard size >= 0 else { return nil }
    var value = [UInt8](repeating: 0, count: size)
    // The buffer and its size, valid for the call.
    let read = value.withUnsafeMutableBytes { unsafe getxattr(path, name, $0.baseAddress, $0.count, 0, options) }
    guard read >= 0 else { return nil }
    return Array(value.prefix(read))
}

/// An item's ACL as `acl_to_text` writes it, not following a symbolic link.
///
/// - Parameter path: The item.
/// - Returns: The text, or `nil` if it has no ACL.
public func accessControlListText(of path: String) -> String? {
    // The ACL and its text are the library's allocations, freed once read; the text is NUL-terminated.
    guard let acl = unsafe acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
    defer { unsafe acl_free(UnsafeMutableRawPointer(acl)) }
    guard let text = unsafe acl_to_text(acl, nil) else { return nil }
    defer { unsafe acl_free(text) }
    return unsafe String(cString: text)
}

/// An item's ACL as `acl_to_text` writes it, not following a symbolic link.
///
/// - Parameter url: The item.
/// - Returns: The text, or `nil` if it has no ACL.
public func accessControlListText(of url: URL) -> String? {
    accessControlListText(of: url.path(percentEncoded: false))
}

/// The `decmpfs` compression type of an APFS-compressed file (3 and 4 zlib, 7 and 8 LZVN, 11 and 12 LZFSE, 13 and 14
/// LZBITMAP: odd inline, even in the resource fork), or `nil` for a plain file.
///
/// - Parameter url: The file.
/// - Returns: The type from its `com.apple.decmpfs` header.
public func decmpfsType(_ url: URL) -> UInt32? {
    // Room for inline data too: a smaller buffer gets `ERANGE`.
    guard let header = attributeValue("com.apple.decmpfs", of: url.path(percentEncoded: false), options: XATTR_SHOWCOMPRESSION | XATTR_NOFOLLOW),
          header.count >= 16
    else { return nil }
    return UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24
}

/// A file's stored APFS compression, as written: its `com.apple.decmpfs` attribute, then its resource fork. Empty for
/// a plain file.
///
/// - Parameter url: The file.
/// - Returns: The two values, concatenated.
public func decmpfsStoredBytes(_ url: URL) -> [UInt8] {
    let path = url.path(percentEncoded: false)
    var stored: [UInt8] = []
    for name in ["com.apple.decmpfs", "com.apple.ResourceFork"] {
        stored += attributeValue(name, of: path, options: XATTR_SHOWCOMPRESSION | XATTR_NOFOLLOW) ?? []
    }
    return stored
}
