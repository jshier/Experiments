import CryptoKit
import Darwin
public import Foundation
import System

// Manifests of extracted trees: what an extraction made, item by item, as hashes rather than bytes, so a tree can be
// compared with one made long before (the archive-coverage set's expected output, made by Apple's extractors when the
// set is generated) or with one too large to keep beside it (an expanded Xcode). The format is the one
// `Disk/Fixtures/archive-coverage/manifest.py` writes: the generator makes the expected manifests in Python, tests
// make the actual ones here.

/// A tree, item by item: kind, mode, flags, modification time, size and SHA-256 of files, link targets, extended
/// attributes (sizes and SHA-256s), ACL text, and which names are one file.
public struct TreeManifest: Codable, Equatable, Sendable {
    /// An extended attribute's value, by size and digest.
    public struct Attribute: Codable, Hashable, Sendable, CustomStringConvertible {
        public var size: Int
        /// Lowercase hexadecimal.
        public var sha256: String

        public init(size: Int, sha256: String) {
            self.size = size
            self.sha256 = sha256
        }

        public var description: String { "\(size) bytes \(sha256.prefix(12))" }
    }

    /// One item under the root.
    public struct Item: Codable, Equatable, Sendable, CustomStringConvertible {
        /// Relative to the root, as the directory lists it (NFC and NFD as they are on disk: compare `path.utf8`, since
        /// Swift's `==` on strings treats the two forms as equal).
        public var path: String
        /// ``TreeItem/Kind``'s raw value: `directory`, `file`, `symbolicLink`, `fifo`, `other`.
        public var type: String
        /// The permission bits with setuid, setgid, and sticky, in octal (`0644`, `4755`).
        public var mode: String
        /// `st_flags`.
        public var flags: UInt32
        /// `SECONDS.NANOSECONDS` (nine digits), or `now` for a time at or after the manifest's ``nowAfter``.
        public var mtime: String
        /// A file's size.
        public var size: Int64?
        /// A file's contents' SHA-256, lowercase hexadecimal.
        public var sha256: String?
        /// A symbolic link's target.
        public var target: String?
        /// Extended attributes by name, less the manifest's ignored ones; `nil` when there are none.
        public var xattrs: [String: Attribute]?
        /// The ACL as `acl_to_text` writes it; `nil` when there's none.
        public var acl: String?
        /// For a file with more than one name in the tree: every name, sorted by their bytes.
        public var links: [String]?

        public init(
            path: String, type: String, mode: String, flags: UInt32, mtime: String, size: Int64? = nil, sha256: String? = nil,
            target: String? = nil, xattrs: [String: Attribute]? = nil, acl: String? = nil, links: [String]? = nil
        ) {
            self.path = path
            self.type = type
            self.mode = mode
            self.flags = flags
            self.mtime = mtime
            self.size = size
            self.sha256 = sha256
            self.target = target
            self.xattrs = xattrs
            self.acl = acl
            self.links = links
        }

        public var description: String {
            var parts = [type, mode]
            if flags != 0 { parts.append("flags \(String(flags, radix: 16))") }
            parts.append("mtime \(mtime)")
            if let size { parts.append("\(size) bytes") }
            if let sha256 { parts.append(String(sha256.prefix(12))) }
            if let target { parts.append("-> \(target)") }
            if let xattrs { parts.append("xattrs [\(xattrs.keys.sorted().joined(separator: ", "))]") }
            if let acl { parts.append("acl \(acl.debugDescription)") }
            if let links { parts.append("links \(links)") }
            return parts.joined(separator: " ")
        }
    }

    /// Extended attributes left out of every item.
    public var ignoredAttributes: [String]
    /// Seconds since 1970: times at or after it were set by the extraction, and read `now`. `nil`: every time as it is.
    public var nowAfter: Int?
    /// The items, sorted by their paths' bytes.
    public var items: [Item]

    /// What manifests leave out by default: `com.apple.provenance`, which the kernel puts on everything a tracked
    /// process makes (``SystemAttributes/provenance``), and `com.apple.quarantine`, which `aa extract` run from such a
    /// process writes fresh rather than copying.
    public static let ignoredByDefault: Set<String> = [SystemAttributes.provenance, "com.apple.quarantine"]

    public init(ignoredAttributes: [String], nowAfter: Int?, items: [Item]) {
        self.ignoredAttributes = ignoredAttributes
        self.nowAfter = nowAfter
        self.items = items
    }

    /// Reads a manifest (manifest.py's JSON, or ``write(to:)``'s).
    ///
    /// - Parameter url: The file.
    /// - Throws: What reading or decoding throws.
    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(TreeManifest.self, from: Data(contentsOf: url))
    }

    /// The manifest of the tree under `root`, not following symbolic links (the walk is ``treePaths(under:)``'s, so
    /// `._` files are listed).
    ///
    /// - Parameters:
    ///   - root: The directory; not itself listed.
    ///   - ignoringAttributes: Extended attributes to leave out.
    ///   - nowAfter: Seconds since 1970: times at or after it read `now` (an extraction's start, for the times it set
    ///     itself); `nil` to keep every time.
    /// - Throws: ``TestFailure`` if an item can't be read.
    public init(of root: URL, ignoringAttributes: Set<String> = ignoredByDefault, nowAfter: Int? = nil) throws {
        let rootPath = root.path(percentEncoded: false)
        var items: [Item] = []
        var inodes: [UInt64: [Int]] = [:]
        for relative in try treePaths(under: root).sorted(by: Self.byBytes) {
            let path = rootPath + "/" + relative
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
            let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            let mtime = nowAfter.map { nanoseconds >= Int64($0) * 1_000_000_000 } == true
                ? "now" : Self.time(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
            var item = Item(path: relative, type: kind.rawValue, mode: Self.octal(UInt16(info.st_mode & 0o7777)), flags: info.st_flags, mtime: mtime)
            if kind == .file {
                item.size = info.st_size
                item.sha256 = try Self.digest(ofFile: path)
                inodes[info.st_ino, default: []].append(items.count)
            }
            if kind == .symbolicLink {
                do {
                    item.target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                } catch {
                    throw TestFailure(description: "readlink \(path): \(error)")
                }
            }
            let attributes = extendedAttributes(of: path, ignoring: ignoringAttributes)
            if !attributes.isEmpty {
                item.xattrs = attributes.mapValues { Attribute(size: $0.count, sha256: Self.hex(SHA256.hash(data: $0))) }
            }
            item.acl = accessControlListText(of: path)
            items.append(item)
        }
        for group in inodes.values where group.count > 1 {
            let names = group.map { items[$0].path }.sorted(by: Self.byBytes)
            for index in group {
                items[index].links = names
            }
        }
        self.init(ignoredAttributes: ignoringAttributes.sorted(), nowAfter: nowAfter, items: items)
    }

    /// Writes the manifest as JSON.
    ///
    /// - Parameter url: The file, replaced.
    /// - Throws: What encoding or writing throws.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url)
    }

    /// The manifest of what's under `prefix` (a directory a ZIP archive kept its tree in, `tree/`): its items with the
    /// prefix taken off their paths and links, the directory itself left out.
    ///
    /// - Parameter prefix: A relative path ending in `/`.
    /// - Returns: The manifest of the subtree.
    public func subtree(_ prefix: String) -> TreeManifest {
        let bytes = Array(prefix.utf8)
        func strip(_ path: String) -> String? {
            let utf8 = Array(path.utf8)
            guard utf8.starts(with: bytes), utf8.count > bytes.count else { return nil }
            return String(decoding: utf8[bytes.count...], as: UTF8.self)
        }
        var result = self
        result.items = items.compactMap { item in
            guard let path = strip(item.path) else { return nil }
            var item = item
            item.path = path
            item.links = item.links.map { $0.compactMap(strip) }
            return item
        }
        return result
    }

    /// Every way this manifest differs from `expected`, item by item and field by field, in path order. Paths are
    /// matched by their bytes, so a name written in another normalization form is missing and unexpected.
    ///
    /// - Parameter expected: The manifest this one should match.
    /// - Returns: The differences; empty when they match.
    public func differences(from expected: TreeManifest) -> [ManifestDifference] {
        var actualItems: [[UInt8]: Item] = [:]
        for item in items {
            actualItems[Array(item.path.utf8)] = item
        }
        var expectedItems: [[UInt8]: Item] = [:]
        for item in expected.items {
            expectedItems[Array(item.path.utf8)] = item
        }
        var result: [ManifestDifference] = []
        for key in Set(actualItems.keys).union(expectedItems.keys).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            switch (expectedItems[key], actualItems[key]) {
            case let (expected?, actual?):
                result += Self.fieldDifferences(expected, actual)
            case let (expected?, nil):
                result.append(ManifestDifference(path: expected.path, field: .missing, expected: expected.description, actual: ""))
            case let (nil, actual?):
                result.append(ManifestDifference(path: actual.path, field: .unexpected, expected: "", actual: actual.description))
            case (nil, nil):
                break
            }
        }
        return result
    }

    private static func fieldDifferences(_ expected: Item, _ actual: Item) -> [ManifestDifference] {
        var result: [ManifestDifference] = []
        func compare(_ field: ManifestDifference.Field, _ a: String?, _ b: String?) {
            guard a.map({ Array($0.utf8) }) != b.map({ Array($0.utf8) }) else { return }
            result.append(ManifestDifference(path: expected.path, field: field, expected: a ?? "none", actual: b ?? "none"))
        }
        func attributes(_ value: [String: Attribute]?) -> String? {
            value.map { $0.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") }
        }
        compare(.type, expected.type, actual.type)
        compare(.mode, expected.mode, actual.mode)
        compare(.flags, String(expected.flags, radix: 16), String(actual.flags, radix: 16))
        compare(.mtime, expected.mtime, actual.mtime)
        compare(.size, expected.size.map(String.init), actual.size.map(String.init))
        compare(.sha256, expected.sha256, actual.sha256)
        compare(.target, expected.target, actual.target)
        compare(.xattrs, attributes(expected.xattrs), attributes(actual.xattrs))
        compare(.acl, expected.acl, actual.acl)
        compare(.links, expected.links?.joined(separator: ", "), actual.links?.joined(separator: ", "))
        return result
    }

    /// `SECONDS.NANOSECONDS`, nine digits after the point.
    public static func time(seconds: Int, nanoseconds: Int) -> String {
        let fraction = String(nanoseconds)
        return "\(seconds).\(String(repeating: "0", count: max(0, 9 - fraction.count)))\(fraction)"
    }

    private static func octal(_ mode: UInt16) -> String {
        let digits = String(mode, radix: 8)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    private static func byBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    private static func digest(ofFile path: String) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: URL(filePath: path))
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize())
        } catch {
            throw TestFailure(description: "reading \(path): \(error)")
        }
    }
}

/// One way a tree differs from its manifest: an item missing or unexpected, or one field of an item.
///
/// Equal and hashed by the path's bytes (NFC and NFD forms of a name are different paths here), the field, and both
/// values, so a test can keep a table of the differences it expects and require exactly those.
public struct ManifestDifference: Hashable, Sendable, CustomStringConvertible {
    public enum Field: String, Sendable {
        /// In the expected manifest, not in the tree.
        case missing
        /// In the tree, not in the expected manifest.
        case unexpected
        case type, mode, flags, mtime, size, sha256, target, xattrs, acl, links
    }

    public var path: String
    public var field: Field
    /// The expected manifest's value (an item's description for ``Field/missing``; empty for ``Field/unexpected``).
    public var expected: String
    /// The tree's value (an item's description for ``Field/unexpected``; empty for ``Field/missing``).
    public var actual: String

    public init(path: String, field: Field, expected: String, actual: String) {
        self.path = path
        self.field = field
        self.expected = expected
        self.actual = actual
    }

    public static func ==(a: Self, b: Self) -> Bool {
        a.path.utf8.elementsEqual(b.path.utf8) && a.field == b.field && a.expected.utf8.elementsEqual(b.expected.utf8)
            && a.actual.utf8.elementsEqual(b.actual.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(path.utf8))
        hasher.combine(field)
        hasher.combine(Array(expected.utf8))
        hasher.combine(Array(actual.utf8))
    }

    public var description: String {
        switch field {
        case .missing: "\(path): missing (\(expected))"
        case .unexpected: "\(path): unexpected (\(actual))"
        default: "\(path): \(field.rawValue) \(expected) -> \(actual)"
        }
    }
}
