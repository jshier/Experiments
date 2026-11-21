import Disk

/// What an AppleDouble file (`._NAME`, or `__MACOSX/…/._NAME`) carries for the file or directory `NAME`: extended
/// attributes, Finder info, a resource fork, and an ACL, in the forms Disk's planner attaches to an entry.
///
/// `ditto -c -k` (the Finder's Compress, too) writes one for every item that has any of these: beside the item, or
/// under `__MACOSX` with `--sequesterRsrc`. Archive Utility, `ditto -x -k`, and macOS's `unzip` merge them back
/// instead of extracting them as files; so does ``ZipExtractor`` (``ExtractionOptions/mergesAppleDouble``).
///
/// The layout (big-endian), as `copyfile` writes it:
///
///     magic 0x00051607 | version 0x00020000 | 16 bytes of filler | entry count (16 bits)
///     per entry: id (32 bits) | offset | length          9: Finder info, 2: resource fork
///     Finder info: 32 bytes | 2 bytes of padding | then, when the entry is longer, the attribute header:
///         "ATTR" | debug tag | total size | data start | data length | 12 reserved bytes | flags (16) | count (16)
///         per attribute: value offset (32, from the file's start) | value length | flags (16) | name length (8) |
///                        the name and its NUL, padded so the next attribute starts on a multiple of 4
struct AppleDouble {
    /// The item's extended attributes: the file's own, `com.apple.FinderInfo` when it isn't all zeros, and
    /// `com.apple.ResourceFork`.
    var attributes = ExtendedAttributeBlob()
    /// The ACL (`com.apple.acl.text`, as an Apple Archive `ACL` blob), or empty.
    var accessControlList: [UInt8] = []

    static let magic: UInt32 = 0x0005_1607
    /// The first four bytes of every AppleDouble file.
    static var magicBytes: [UInt8] { [0x00, 0x05, 0x16, 0x07] }

    var isEmpty: Bool { attributes.bytes.isEmpty && accessControlList.isEmpty }

    /// Parses an AppleDouble file's bytes; `nil` if they aren't one (then it's extracted as the file it is).
    ///
    /// - Parameters:
    ///   - skippingQuarantine: Leave a `com.apple.quarantine` attribute out (the extraction sets its own).
    ///   - forDirectory: The item is a directory: a resource fork is left out (a directory can't have one: setting it
    ///     fails with `EPERM`; `ditto` warns and goes on, Archive Utility refuses the archive).
    init?(_ bytes: [UInt8], skippingQuarantine: Bool, forDirectory: Bool) {
        func word(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        func half(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        guard word(0) == Int(Self.magic), word(4) == 0x0002_0000, let count = half(24) else { return nil }
        for index in 0..<count {
            let record = 26 + index * 12
            guard let id = word(record), let offset = word(record + 4), let length = word(record + 8) else { return nil }
            // An entry reaching past the file's end: not an AppleDouble file this can merge.
            guard offset <= bytes.count, length <= bytes.count - offset else { return nil }
            switch id {
            case 9:
                guard length >= 32 else { continue }
                if bytes[offset..<offset + 32].contains(where: { $0 != 0 }) {
                    attributes.append(name: "com.apple.FinderInfo", value: bytes.span.bytes.extracting(offset..<offset + 32))
                }
                guard !readAttributes(bytes, header: offset + 34, skippingQuarantine: skippingQuarantine) else { continue }
                return nil
            case 2:
                if length > 0, !forDirectory {
                    attributes.append(name: "com.apple.ResourceFork", value: bytes.span.bytes.extracting(offset..<offset + length))
                }
            default:
                continue
            }
        }
    }

    /// Reads the attribute header at `header`, if there is one.
    ///
    /// - Returns: `false` for a header whose attributes don't fit in the file.
    private mutating func readAttributes(_ bytes: [UInt8], header: Int, skippingQuarantine: Bool) -> Bool {
        // No header (a Finder info entry of just 32 bytes, or other data after it): nothing more.
        guard header + 36 <= bytes.count, bytes[header..<header + 4].elementsEqual("ATTR".utf8) else { return true }
        let count = Int(bytes[header + 34]) << 8 | Int(bytes[header + 35])
        var entry = header + 36
        for _ in 0..<count {
            guard entry + 11 <= bytes.count else { return false }
            let offset = Int(bytes[entry]) << 24 | Int(bytes[entry + 1]) << 16 | Int(bytes[entry + 2]) << 8 | Int(bytes[entry + 3])
            let length = Int(bytes[entry + 4]) << 24 | Int(bytes[entry + 5]) << 16 | Int(bytes[entry + 6]) << 8 | Int(bytes[entry + 7])
            let nameLength = Int(bytes[entry + 10])
            guard nameLength > 0, entry + 11 + nameLength <= bytes.count, offset <= bytes.count, length <= bytes.count - offset else { return false }
            // The name's length counts its NUL.
            var nameBytes = bytes[entry + 11..<entry + 11 + nameLength]
            if nameBytes.last == 0 { nameBytes.removeLast() }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let value = bytes.span.bytes.extracting(offset..<offset + length)
            if name == "com.apple.acl.text" {
                // Without its trailing NUL.
                let text = length > 0 && bytes[offset + length - 1] == 0 ? value.extracting(0..<length - 1) : value
                if let blob = AccessControlListBlob(text: text) { accessControlList = blob.bytes }
            } else if !(skippingQuarantine && name == "com.apple.quarantine") {
                attributes.append(name: name, value: value)
            }
            entry = (entry + 11 + nameLength + 3) & ~3
        }
        return true
    }

    /// The path of the item an entry named `path` would describe, if the name is an AppleDouble file's: `a/._b` and
    /// `__MACOSX/a/._b` both name `a/b`.
    static func target(of path: String) -> String? {
        let directory: Substring, leaf: Substring
        if let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) {
            directory = path[..<slash]
            leaf = path[path.utf8.index(after: slash)...]
        } else {
            directory = ""
            leaf = path[...]
        }
        guard leaf.utf8.count > 2, leaf.utf8.starts(with: "._".utf8) else { return nil }
        let name = leaf.dropFirst(2)
        var parent = directory
        if parent == "__MACOSX" { parent = "" } else if parent.hasPrefix("__MACOSX/") { parent = parent.dropFirst(9) }
        return parent.isEmpty ? String(name) : "\(parent)/\(name)"
    }

    /// Whether `path` is the `__MACOSX` directory or one beneath it.
    static func isSequesterDirectory(_ path: String) -> Bool {
        path == "__MACOSX/" || path == "__MACOSX" || path.hasPrefix("__MACOSX/")
    }
}
