import Bytes
import Darwin

/// A path inside a destination, checked: relative, one canonical form, and short enough for the kernel. Made from the
/// caller's bytes without copying them (a view: `~Escapable`), so naming an entry allocates nothing.
///
/// A valid path is empty (the destination itself) or `component(/component)*`, where no component is empty, `.`, or
/// `..`, and no byte is NUL; it's under `PATH_MAX` (1,024) bytes. So it can't start at `/`, climb out with `..`, or
/// name one item two ways. That's checked once, here; the kernel checks again as every call resolves it
/// (`O_NOFOLLOW_ANY` and `O_RESOLVE_BENEATH`, see ``Destination``).
///
/// Formats whose names need cleaning first (ZIP's, as Info-ZIP unzip cleans them: a leading `/` and `..` components
/// dropped) use ``sanitize(_:into:)``.
public struct EntryPath: ~Escapable {
    /// The path's bytes: not NUL-terminated.
    public let bytes: RawSpan

    /// The longest path accepted, in bytes: one less than `PATH_MAX`, for the NUL calls need.
    public static let maximumByteCount = Int(PATH_MAX) - 1

    /// Checks `bytes` as a path inside the destination.
    ///
    /// - Parameter bytes: The path, without a NUL.
    /// - Throws: ``DiskError/unsafePath(_:)`` if it's absolute, has an empty, `.`, or `..` component, a NUL, or is
    ///   too long.
    @_lifetime(copy bytes)
    public init(validating bytes: RawSpan) throws(DiskError) {
        guard Self.isValid(bytes) else { throw .unsafePath(Self.string(bytes)) }
        self.bytes = bytes
    }

    /// Checks a string's UTF-8 as a path inside the destination.
    ///
    /// - Parameter utf8: The path (`string.utf8Span`).
    /// - Throws: ``DiskError/unsafePath(_:)``, as ``init(validating:)-(RawSpan)``.
    @_lifetime(copy utf8)
    public init(validating utf8: UTF8Span) throws(DiskError) {
        let bytes = utf8.span.bytes
        guard Self.isValid(bytes) else { throw .unsafePath(Self.string(bytes)) }
        self.bytes = bytes
    }

    /// The destination itself (the empty path): for its own metadata.
    @_lifetime(immortal)
    public init() {
        bytes = RawSpan()
    }

    /// Whether this is the destination itself.
    var isRoot: Bool { bytes.isEmpty }

    /// The path as a string, for messages (allocates).
    public var description: String { Self.string(bytes) }

    static func string(_ bytes: RawSpan) -> String {
        // Unsafe: decodes the closure's raw buffer. Safe: the span's own bytes, valid inside `withUnsafeBytes`; the
        // string copies them before the closure returns.
        bytes.withUnsafeBytes { unsafe String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Checking

    /// Whether `bytes` is a valid path (see ``EntryPath``).
    ///
    /// Most paths pass a vector screen: no NUL, no `/` or `.` first, no `/` last, and no `/` followed by `/` or `.`,
    /// tested 16 bytes at a time with `ByteLanes` (then no component is empty or starts with a dot, so none is `.` or
    /// `..`). A path that fails the screen (a dot file, a `.` component) is checked a component at a time.
    static func isValid(_ bytes: RawSpan) -> Bool {
        let count = bytes.byteCount
        if count == 0 { return true }
        guard count <= maximumByteCount else { return false }
        return screen(bytes) || exactCheck(bytes)
    }

    /// The vector screen: `true` means valid; `false` means "check exactly". `bytes` isn't empty.
    static func screen(_ bytes: RawSpan) -> Bool {
        let count = bytes.byteCount
        let first = bytes.load(fromByteOffset: 0, as: UInt8.self)
        let last = bytes.load(fromByteOffset: count - 1, as: UInt8.self)
        if first == 0x2F || first == 0x2E || last == 0x2F || last == 0 { return false }
        guard count >= 17 else {
            // Short paths: one pass over the pairs.
            let bytes = Span<UInt8>(viewing: bytes)
            for index in 1..<count {
                let byte = bytes[index - 1], next = bytes[index]
                if byte == 0 || (byte == 0x2F && (next == 0x2F || next == 0x2E)) { return false }
            }
            return true
        }
        // Each block tests 16 bytes and their successors, at the front of what's left: whole blocks, then the last 16
        // pairs (overlapping), all ORed and tested once. (Loads at constant offsets of a span that has at least 17
        // bytes: their checks fold.)
        var found = ByteMatches.none
        @inline(__always)
        func test(_ block: RawSpan) -> ByteMatches {
            let lanes = ByteLanes(block.load(fromByteOffset: 0, as: SIMD16<UInt8>.self))
            let next = ByteLanes(block.load(fromByteOffset: 1, as: SIMD16<UInt8>.self))
            return lanes.matching(0) | (lanes.matching(0x2F) & (next.matching(0x2F) | next.matching(0x2E)))
        }
        var rest = bytes
        while rest.byteCount >= 17 {
            found = found | test(rest)
            rest = rest.extracting(droppingFirst: 16)
        }
        found = found | test(bytes.extracting(last: 17))
        return !found.any
    }

    /// The exact check, a component at a time.
    static func exactCheck(_ bytes: RawSpan) -> Bool {
        let bytes = Span<UInt8>(viewing: bytes)
        let count = bytes.count
        var start = 0
        for index in 0...count {
            let byte: UInt8 = index < count ? bytes[index] : 0x2F
            if byte == 0 { return false }
            guard byte == 0x2F else { continue }
            let length = index - start
            if length == 0 { return false }
            if bytes[start] == 0x2E {
                if length == 1 { return false }
                if length == 2, bytes[start + 1] == 0x2E { return false }
            }
            start = index + 1
        }
        return true
    }

    // MARK: Cleaning

    /// What ``sanitize(_:into:)`` did.
    public struct Sanitized: Sendable, Equatable {
        /// Bytes written to the output.
        public var count: Int
        /// Whether anything was removed (a leading `/`, a `..` component).
        public var adjusted: Bool
    }

    /// Cleans an archive's name as Info-ZIP unzip does: empty and `.` components are dropped silently, and a leading
    /// `/` and `..` components are dropped and reported. The result, appended to `output`, is a valid path (empty if
    /// nothing is left). A NUL ends the name (C tools never see past it).
    ///
    /// - Parameters:
    ///   - bytes: The name.
    ///   - output: Where the cleaned path goes: room for `bytes.byteCount` more bytes.
    /// - Returns: The bytes written, and whether anything unsafe was removed.
    /// - Throws: ``DiskError/unsafePath(_:)`` if `output` has too little room, or the result is too long.
    public static func sanitize(_ bytes: RawSpan, into output: inout OutputRawSpan) throws(DiskError) -> Sanitized {
        guard output.freeCapacity >= bytes.byteCount else { throw .unsafePath(string(bytes)) }
        let initial = output.byteCount
        var adjusted = false
        let count = bytes.byteCount
        // Every index below is under `count`: 0 after `count > 0`; `end` after `end < count`; `index` and `index + 1`
        // only for a component of 1 or 2 bytes, which ends at `end <= count`.
        let name = Span<UInt8>(viewing: bytes)
        @inline(__always) func byte(_ index: Int) -> UInt8 { name[index] }
        if count > 0, byte(0) == 0x2F { adjusted = true }
        var index = 0
        while index < count {
            // One component: `index..<end`.
            var end = index
            while end < count, byte(end) != 0x2F, byte(end) != 0 { end += 1 }
            let length = end - index
            let isDot = length == 1 && byte(index) == 0x2E
            let isDotDot = length == 2 && byte(index) == 0x2E && byte(index + 1) == 0x2E
            if isDotDot { adjusted = true }
            if length > 0, !isDot, !isDotDot {
                if output.byteCount > initial { output.append(UInt8(0x2F)) }
                output.append(copying: bytes.extracting(index..<end))
            }
            if end < count, byte(end) == 0 { break }
            index = end + 1
        }
        let written = output.byteCount - initial
        guard written <= maximumByteCount else { throw .unsafePath(string(bytes)) }
        return Sanitized(count: written, adjusted: adjusted)
    }
}

