public import Bytes

/// Why a field was rejected.
@frozen
public enum HTTPFieldError: Error, Sendable, Hashable {
    /// The name is empty or has a byte that isn't a token character (RFC 9110 §5.1).
    case invalidName
    /// The value has a control character other than tab, or DEL, or starts or ends with whitespace (RFC 9110 §5.5).
    case invalidValue
    /// The fields' bytes would pass 4 GiB.
    case tooLarge
}

/// Fields kept past the bytes they were parsed from: names and values copied into one byte array, one entry each in
/// another, and each field's known-name index in a third (so finding a known name is a 16-lanes-at-a-time scan).
///
/// Three allocations, made once and reused: ``removeAll(keepingCapacity:)`` keeps them, so a connection that keeps
/// one store allocates nothing per message once it has seen its largest head. Order and duplicates are kept as
/// received (RFC 9110 §5.3: a recipient may combine same-named fields, but `Set-Cookie` can't be).
///
/// ```swift
/// var fields = HTTPFieldStore()
/// … case .field(let field): try fields.append(field)
/// if let host = fields.firstValue(of: .host) { … }
/// ```
@frozen
public struct HTTPFieldStore: Sendable {
    /// One field's place in `bytes`: its name, then its value.
    @frozen @usableFromInline
    struct Entry: Sendable {
        @usableFromInline var start: UInt32
        @usableFromInline var valueCount: UInt32
        @usableFromInline var nameCount: UInt16
        /// ``HTTPFieldStore/neverIndexed`` and others to come.
        @usableFromInline var flags: UInt8

        @inlinable @inline(__always)
        init(start: UInt32, valueCount: UInt32, nameCount: UInt16, flags: UInt8) {
            self.start = start
            self.valueCount = valueCount
            self.nameCount = nameCount
            self.flags = flags
        }
    }

    @usableFromInline var bytes: [UInt8] = []
    @usableFromInline var entries: [Entry] = []
    /// Each field's ``HTTPFieldName/index``, or 0xFF for a name HTTPBytes doesn't know.
    @usableFromInline var knownNames: [UInt8] = []

    /// The flag for a field that must never be added to a compression table (HPACK's and QPACK's never-indexed
    /// literals, RFC 7541 §6.2.3: values like credentials, which an intermediary must forward the same way).
    @inlinable public static var neverIndexed: UInt8 { 1 }

    /// An empty store.
    @inlinable
    public init() {}

    /// An empty store with room for `byteCapacity` bytes of names and values and `fieldCapacity` fields.
    @inlinable
    public init(byteCapacity: Int, fieldCapacity: Int) {
        bytes.reserveCapacity(byteCapacity)
        entries.reserveCapacity(fieldCapacity)
        knownNames.reserveCapacity(fieldCapacity)
    }

    /// The number of fields.
    @inlinable
    public var count: Int { entries.count }

    /// Whether there are no fields.
    @inlinable
    public var isEmpty: Bool { entries.isEmpty }

    /// Removes every field, keeping the memory by default (for the next message).
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = true) {
        bytes.removeAll(keepingCapacity: keepingCapacity)
        entries.removeAll(keepingCapacity: keepingCapacity)
        knownNames.removeAll(keepingCapacity: keepingCapacity)
    }

    /// Appends a parsed field. Its value is checked for NUL, CR, and LF whatever parsed it: a view from an HPACK or QPACK
    /// decoder can carry them (the decoders flag them, but a caller may not have looked), and a value with CR LF written
    /// into an HTTP/1 head would add fields of the sender's choosing. Other controls are allowed here, as HTTP/2 and
    /// HTTP/3 allow them (RFC 9113 §8.2.1, RFC 9114 §4.2); `HTTP1HeadWriter` refuses them when writing HTTP/1. One
    /// 16-byte-at-a-time scan.
    @inlinable
    public mutating func append(_ field: HTTPFieldView, flags: UInt8 = 0) throws(HTTPFieldError) {
        guard !field.value.containsByte(where: { $0.matching(0x00) | $0.matching(0x0A) | $0.matching(0x0D) }) else {
            throw .invalidValue
        }
        try appendUnchecked(name: field.name, value: field.value, knownName: field.knownName, flags: flags)
    }

    /// Appends a field with a known name, checking its value.
    @inlinable
    public mutating func append(_ name: HTTPFieldName, value: RawSpan, flags: UInt8 = 0) throws(HTTPFieldError) {
        try Self.validate(value: value)
        try appendUnchecked(name: name.lowercaseBytes, value: value, knownName: name, flags: flags)
    }

    /// Appends a field, checking its name and value.
    @inlinable
    public mutating func append(name: RawSpan, value: RawSpan, flags: UInt8 = 0) throws(HTTPFieldError) {
        guard name.byteCount > 0, !name.containsByte(where: HTTPCharacters.nonToken) else { throw .invalidName }
        try Self.validate(value: value)
        try appendUnchecked(name: name, value: value, knownName: HTTPFieldName(caseInsensitive: name), flags: flags)
    }

    @inlinable
    static func validate(value: RawSpan) throws(HTTPFieldError) {
        let count = value.byteCount
        guard count > 0 else { return }
        let first = value.load(fromByteOffset: 0, as: UInt8.self), last = value.load(fromByteOffset: count &- 1, as: UInt8.self)
        guard first != 0x20, first != 0x09, last != 0x20, last != 0x09,
              !value.containsByte(where: HTTPCharacters.fieldValueStop) else { throw .invalidValue }
    }

    @inlinable
    mutating func appendUnchecked(name: RawSpan, value: RawSpan, knownName: HTTPFieldName?, flags: UInt8) throws(HTTPFieldError) {
        let start = bytes.count
        guard name.byteCount <= Int(UInt16.max), start &+ name.byteCount &+ value.byteCount <= Int(UInt32.max) else { throw .tooLarge }
        bytes.append(copying: name)
        bytes.append(copying: value)
        entries.append(Entry(start: UInt32(truncatingIfNeeded: start), valueCount: UInt32(truncatingIfNeeded: value.byteCount),
                             nameCount: UInt16(truncatingIfNeeded: name.byteCount), flags: flags))
        knownNames.append(knownName?.index ?? 0xFF)
    }

    /// The field at `index` (in the order appended).
    @inlinable
    @_lifetime(borrow self)
    public func field(at index: Int) -> HTTPFieldView {
        let entry = entries[index]
        let start = Int(entry.start), nameEnd = start &+ Int(entry.nameCount)
        let all = bytes.span.bytes
        let known = knownNames[index]
        return HTTPFieldView(name: all.extracting(start..<nameEnd), value: all.extracting(nameEnd..<nameEnd &+ Int(entry.valueCount)),
                             knownName: known == 0xFF ? nil : HTTPFieldName(index: Int(known)))
    }

    /// The flags of the field at `index`.
    @inlinable
    public func flags(at index: Int) -> UInt8 { entries[index].flags }

    /// The index of the first field named `name` at or after `start`, or `nil`: 16 fields' names compared at once.
    @inlinable
    public func firstIndex(of name: HTTPFieldName, from start: Int = 0) -> Int? {
        let names = knownNames.span.bytes
        guard start < names.byteCount else { return nil }
        let target = name.index
        return names.extracting(droppingFirst: start).firstByteOffset { $0.matching(target) }.map { $0 &+ start }
    }

    /// The value of the first field named `name`, or `nil`.
    @inlinable
    @_lifetime(borrow self)
    public func firstValue(of name: HTTPFieldName) -> RawSpan? {
        guard let index = firstIndex(of: name) else { return nil }
        let entry = entries[index]
        let valueStart = Int(entry.start) &+ Int(entry.nameCount)
        return bytes.span.bytes.extracting(valueStart..<valueStart &+ Int(entry.valueCount))
    }
}
