public import Bytes
public import HTTPBytes

/// How the encoder may use the dynamic table for a field: the core's ``HTTPFieldIndexingStrategy``, shared with QPACK.
public typealias HPACKIndexingStrategy = HTTPFieldIndexingStrategy

/// An HPACK encoder (RFC 7541): one per HTTP/2 connection, encoding this endpoint's field blocks in the order they're
/// sent.
///
/// ```swift
/// var encoder = HPACKEncoder()
/// try encoder.encode(fields, into: &output)       // an HTTPFieldStore, as one block
/// // or field by field:
/// try encoder.encode(.pseudoStatus, value: status, into: &output)
/// ```
///
/// **Matching.** A field is sent as an index when the static table (by the name's first static index,
/// then the value) or the dynamic table (a hash of name and value, then a comparison) has it; otherwise as a literal
/// whose name is an index when either table has the name. Dynamic entries are found through two small hash tables of
/// chains (name and value; name only) linked by insertion number, so evicting an entry costs nothing: a chain ends at
/// the first entry older than the table's oldest.
///
/// **Strings** are Huffman-coded when that's shorter (encoded optimistically, and written raw once the code is as long
/// as the bytes).
///
/// **Table size.** ``setPeerMaximumTableSize(_:)`` takes the peer's SETTINGS_HEADER_TABLE_SIZE; the encoder uses at most
/// the size it was made with, and sends the size updates RFC 7541 §4.2 requires (the smallest size since the last
/// block, then the final one) at the start of the next block. Call it between blocks.
///
/// **Memory** is allocated when the encoder is made: the table (twice its size in bytes, entries contiguous), the hash
/// tables, and a scratch buffer for lowercasing HTTP/1 names (grown only for a name longer than any before). Nothing
/// per block or field.
@safe
public struct HPACKEncoder: ~Copyable {
    @usableFromInline var table: DynamicFieldTable
    /// The static table, by address, and known names' static indexes.
    @usableFromInline let statics: StaticFieldEntries
    /// The dynamic table's hash chains.
    @usableFromInline let index: DynamicFieldIndex
    /// The smallest maximum size set since the last block, and the latest, to send as size updates; -1 for none.
    @usableFromInline var pendingMinimumSize = -1
    @usableFromInline var pendingSize = -1
    /// Whether to Huffman-code strings (when shorter).
    public var usesHuffmanCoding = true
    /// Whether ``encode(_:indexing:into:)`` leaves connection-specific fields out (RFC 9113 §8.2.2): `true` unless a
    /// caller needs a store encoded exactly as it is (a benchmark comparing encoders on recorded traffic, say), knowing
    /// that a peer treats a message with one as malformed.
    public var removesConnectionSpecificFields = true
    /// Lowercased names (HTTP/1 spellings of names HTTPBytes doesn't know), grown to the longest seen.
    @usableFromInline var scratch: UnsafeMutableRawPointer
    @usableFromInline var scratchCapacity: Int

    /// An encoder that uses a dynamic table of up to `maximumTableSize` bytes (4,096: the peer's initial
    /// SETTINGS_HEADER_TABLE_SIZE). Its table starts at `min(maximumTableSize, 4,096)`, the size the peer assumes, and
    /// changes with ``setPeerMaximumTableSize(_:)``.
    public init(maximumTableSize: Int = 4_096) {
        table = DynamicFieldTable(capacity: maximumTableSize)
        statics = StaticFieldEntries.hpack()
        table.maximumSize = Swift.min(maximumTableSize, 4_096)
        if table.maximumSize != 4_096 {
            pendingMinimumSize = table.maximumSize
            pendingSize = table.maximumSize
        }
        index = DynamicFieldIndex(slots: table.entryMask &+ 1)
        scratchCapacity = 64
        // Unsafe: an allocation owned by this encoder and freed in `deinit`.
        unsafe scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchCapacity, alignment: 16)
    }

    deinit {
        // Unsafe: frees this encoder's own allocation, which nothing else holds (the encoder is noncopyable).
        unsafe scratch.deallocate()
    }

    /// The dynamic table's size (RFC 7541 §4.1).
    @inlinable public var tableSize: Int { table.size }
    /// The dynamic table's maximum size, as the peer will know it after the pending size updates.
    @inlinable public var tableMaximumSize: Int { table.maximumSize }
    /// The number of dynamic table entries.
    @inlinable public var tableCount: Int { table.count }

    /// Takes the peer's SETTINGS_HEADER_TABLE_SIZE: the table's maximum becomes the smaller of it and the size the
    /// encoder was made with, announced by size updates at the start of the next block.
    public mutating func setPeerMaximumTableSize(_ setting: Int) {
        precondition(setting >= 0, "a table size setting isn't negative")
        let size = Swift.min(setting, table.capacity)
        guard size != table.maximumSize || pendingSize >= 0 else { return }
        table.setMaximumSize(size)
        pendingMinimumSize = pendingMinimumSize < 0 ? size : Swift.min(pendingMinimumSize, size)
        pendingSize = size
    }

    /// Returns to a new connection's state, keeping the memory: an empty table at the size the peer assumes (4,096,
    /// or less if the encoder was made smaller), and the size update that needs.
    public mutating func reset() {
        table.removeAll()
        table.maximumSize = Swift.min(table.capacity, 4_096)
        pendingMinimumSize = table.maximumSize == 4_096 ? -1 : table.maximumSize
        pendingSize = pendingMinimumSize
    }

    // MARK: - Public encoding

    /// Encodes `fields` as one field block (after any pending size updates), appending to `output`: each field with
    /// ``HPACKIndexingStrategy/disable`` if it's flagged ``HTTPFieldStore/neverIndexed``, else `indexing`.
    ///
    /// Fields are written as HTTP/2 requires, whatever version the store's fields came from (RFC 9113 §8.2):
    /// - Names are lowercase: a known name as ``HTTPFieldName/lowercaseBytes``, any other with its ASCII letters
    ///   lowercased (in the encoder's scratch memory, which grows only for a name longer than any before), so an HTTP/1
    ///   spelling such as `X-Request-Id` goes out as `x-request-id`.
    /// - Connection-specific fields are left out (unless ``removesConnectionSpecificFields`` is `false`), as an
    ///   intermediary converting HTTP/1 to HTTP/2 must (§8.2.2):
    ///   `connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`, `upgrade`, and `te` unless its value is
    ///   `trailers`. (Fields that a `connection` field's value names are also connection-specific, RFC 9110 §7.6.1: an
    ///   intermediary removes those itself before encoding.)
    ///
    /// The single-field `encode` methods write names as given, for callers that already have HTTP/2 fields.
    ///
    /// - Throws: ``HPACKError/outputTooSmall`` if `output` fills (what was written stays; the table has the fields
    ///   encoded so far, so the connection can't go on without sending them).
    @inlinable
    public mutating func encode(_ fields: borrowing HTTPFieldStore, indexing: HPACKIndexingStrategy = .automatic,
                                into output: inout OutputRawSpan) throws(HPACKError) {
        let ok = unsafe output.withUnsafeMutableBytes { target, initialized in
            unsafe withFreeBytes(target, from: initialized) { base, capacity in
                // Unsafe: the output's free memory, written below `capacity` by the cursor, which reports its end.
                var cursor = unsafe FieldEncoderOutput(base, capacity)
                guard writeSizeUpdates(&cursor) else { return -1 }
                for index in 0..<fields.count {
                    let field = fields.field(at: index)
                    let strategy = fields.flags(at: index) & HTTPFieldStore.neverIndexed != 0 ? .disable : indexing
                    let known = field.knownName
                    let written: Bool
                    if let known, removesConnectionSpecificFields, Self.isConnectionSpecific(known, value: field.value) { continue }
                    // A known name's bytes are replaced by its lowercase ones if it's written as a literal (`spelling`).
                    if known == nil, field.name.containsByte(where: Self.uppercaseLetters) {
                        written = encodeFieldLowercasing(field.name, field.value, strategy, &cursor)
                    } else {
                        // One call site: the field encoder is inlined once.
                        written = encodeField(field.name, field.value, known, strategy, &cursor)
                    }
                    guard written else {
                        initialized &+= cursor.count
                        return -1
                    }
                }
                initialized &+= cursor.count
                return 0
            }
        }
        if ok < 0 { throw .outputTooSmall }
    }

    /// Whether a field is connection-specific (RFC 9113 §8.2.2): left out of a block encoded from a store.
    @inlinable @inline(__always)
    static func isConnectionSpecific(_ name: HTTPFieldName, value: RawSpan) -> Bool {
        // By index: `HTTPFieldName`'s derived `==`, from another module, can be a call per comparison.
        switch name.index {
        case HTTPFieldName.connection.index, HTTPFieldName.keepAlive.index, HTTPFieldName.proxyConnection.index,
             HTTPFieldName.transferEncoding.index, HTTPFieldName.upgrade.index: true
        case HTTPFieldName.te.index: !HTTPToken.equalsIgnoringCase(value, "trailers")
        default: false
        }
    }

    /// Lanes that are ASCII uppercase letters.
    @inlinable @inline(__always)
    static func uppercaseLetters(_ lanes: ByteLanes) -> ByteMatches {
        HTTPCharacters.matches(lanes.vector &- SIMD16(repeating: 0x41) .< SIMD16(repeating: 26))
    }

    /// Encodes a field whose name (one HTTPBytes doesn't know) has uppercase letters: lowercased into the scratch
    /// memory, grown first if the name is longer than any before. Out of line: HTTP/1 spellings of unknown names.
    @usableFromInline
    mutating func encodeFieldLowercasing(_ name: RawSpan, _ value: RawSpan, _ strategy: HPACKIndexingStrategy,
                                         _ output: inout FieldEncoderOutput) -> Bool {
        let count = name.byteCount
        if count > scratchCapacity {
            // Unsafe: replaces this encoder's own scratch allocation; nothing borrows it between calls.
            unsafe scratch.deallocate()
            scratchCapacity = Swift.max(count, scratchCapacity &* 2)
            unsafe scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchCapacity, alignment: 16)
        }
        for offset in 0..<count {
            let byte = name.load(fromByteOffset: offset, as: UInt8.self)
            // Unsafe: a store into the scratch memory. Safe: `offset < count <= scratchCapacity`.
            unsafe scratch.storeBytes(of: byte &- 0x41 < 26 ? byte | 0x20 : byte, toByteOffset: offset, as: UInt8.self)
        }
        let lowered = unsafe UnsafeRawPointer(scratch)
        return value.withUnsafeBytes { value in
            // Unsafe: the lowercased name in the scratch memory (`count` bytes) and the value's own bytes, read during the
            // call; the table copies what it keeps.
            unsafe encodeField(name: lowered, nameCount: count, value: value.baseAddress, valueCount: value.count,
                               knownName: 0xFF, strategy: strategy, &output)
        }
    }

    /// Encodes one field with a known name, appending to `output` (after any pending size updates: call it for a
    /// block's fields in order, and start each block after ``setPeerMaximumTableSize(_:)`` with a field or with
    /// ``writePendingSizeUpdates(into:)``).
    @inlinable
    public mutating func encode(_ name: HTTPFieldName, value: RawSpan, indexing: HPACKIndexingStrategy = .automatic,
                                into output: inout OutputRawSpan) throws(HPACKError) {
        try encode(name: name.lowercaseBytes, knownName: name, value: value, indexing: indexing, into: &output)
    }

    /// Encodes one field, appending to `output`: the name must be lowercase (RFC 9113 §8.2.1), and is looked up among the
    /// known names.
    @inlinable
    public mutating func encode(name: RawSpan, value: RawSpan, indexing: HPACKIndexingStrategy = .automatic,
                                into output: inout OutputRawSpan) throws(HPACKError) {
        try encode(name: name, knownName: HTTPFieldName(lowercase: name), value: value, indexing: indexing, into: &output)
    }

    @inlinable
    mutating func encode(name: RawSpan, knownName: HTTPFieldName?, value: RawSpan, indexing: HPACKIndexingStrategy,
                         into output: inout OutputRawSpan) throws(HPACKError) {
        let ok = unsafe output.withUnsafeMutableBytes { target, initialized in
            unsafe withFreeBytes(target, from: initialized) { base, capacity in
                // Unsafe: as in `encode(_:indexing:into:)`.
                var cursor = unsafe FieldEncoderOutput(base, capacity)
                let written = writeSizeUpdates(&cursor) && encodeField(name, value, knownName, indexing, &cursor)
                initialized &+= cursor.count
                return written ? 0 : -1
            }
        }
        if ok < 0 { throw .outputTooSmall }
    }

    /// Writes the pending size updates, if any (for a block with no fields; `encode` writes them before a block's
    /// first field).
    @inlinable
    public mutating func writePendingSizeUpdates(into output: inout OutputRawSpan) throws(HPACKError) {
        let ok = unsafe output.withUnsafeMutableBytes { target, initialized in
            unsafe withFreeBytes(target, from: initialized) { base, capacity in
                // Unsafe: as in `encode(_:indexing:into:)`.
                var cursor = unsafe FieldEncoderOutput(base, capacity)
                let written = writeSizeUpdates(&cursor)
                initialized &+= cursor.count
                return written ? 0 : -1
            }
        }
        if ok < 0 { throw .outputTooSmall }
    }

    // MARK: - The work, by pointer

    /// Writes pending size updates: the smallest since the last block, then the latest if it differs.
    @inlinable @inline(__always)
    mutating func writeSizeUpdates(_ output: inout FieldEncoderOutput) -> Bool {
        guard pendingSize >= 0 else { return true }
        return writeSizeUpdatesSlowly(&output)
    }

    @usableFromInline
    mutating func writeSizeUpdatesSlowly(_ output: inout FieldEncoderOutput) -> Bool {
        guard output.integer(pendingMinimumSize, mask: 0x1F, flags: 0x20) else { return false }
        if pendingSize != pendingMinimumSize {
            guard output.integer(pendingSize, mask: 0x1F, flags: 0x20) else { return false }
        }
        pendingSize = -1
        pendingMinimumSize = -1
        return true
    }

    /// Encodes one field. Spans to pointers here, once per field; the rest is `encodeField(name:…)`.
    @inlinable @inline(__always)
    mutating func encodeField(_ name: RawSpan, _ value: RawSpan, _ knownName: HTTPFieldName?, _ strategy: HPACKIndexingStrategy,
                              _ output: inout FieldEncoderOutput) -> Bool {
        name.withUnsafeBytes { name in
            value.withUnsafeBytes { value in
                // Unsafe: the spans' own bytes, read within their counts during the call.
                unsafe encodeField(
                    name: name.baseAddress, nameCount: name.count, value: value.baseAddress, valueCount: value.count,
                    knownName: knownName?.index ?? 0xFF, strategy: strategy, &output)
            }
        }
    }

    /// Encodes one field: a static or dynamic match as an index, else a literal (its name an index if a table has it),
    /// indexed or not as `strategy` and the policy say.
    @usableFromInline
    mutating func encodeField(name: UnsafeRawPointer?, nameCount: Int, value: UnsafeRawPointer?, valueCount: Int,
                              knownName: UInt8, strategy: HPACKIndexingStrategy, _ output: inout FieldEncoderOutput) -> Bool {
        let known = knownName == 0xFF ? nil : HTTPFieldName(tableIndex: knownName)
        let staticIndex = statics.index(ofName: knownName)
        if strategy == .disable {
            let nameIndex = staticIndex > 0 ? staticIndex : unsafe dynamicNameIndex(name, nameCount, knownName)
            return unsafe literal(nameIndex: nameIndex, name, nameCount, knownName, value, valueCount, flags: 0x10, mask: 0x0F, &output)
        }
        // A whole match: the static table's entries for the name, then the dynamic table.
        if staticIndex > 0 {
            var index = staticIndex
            while index <= 61, case let entry = statics[index], entry.knownName == knownName {
                if Int(entry.valueCount) == valueCount, unsafe equalBytes(entry.value, value, valueCount) {
                    return output.integer(index, mask: 0x7F, flags: 0x80)
                }
                index &+= 1
            }
        }
        let nameHash = unsafe DynamicFieldIndex.nameHash(name, nameCount, knownName)
        let fieldHash = unsafe DynamicFieldIndex.fieldHash(nameHash, value, valueCount)
        let entryNumber = unsafe index.fieldMatch(fieldHash, in: table, name, nameCount, knownName, value, valueCount)
        if entryNumber >= 0 {
            return output.integer(61 &+ table.inserted &- entryNumber, mask: 0x7F, flags: 0x80)
        }
        let entrySize = nameCount &+ valueCount &+ 32
        let indexes: Bool
        switch strategy {
        case .prefer: indexes = entrySize <= table.maximumSize
        case .avoid, .disable: indexes = false
        case .automatic:
            switch HTTPFieldIndexingStrategy.automaticPolicy(known, valueCount) {
            case 1:
                let nameIndex = staticIndex > 0 ? staticIndex : unsafe dynamicNameIndex(name, nameCount, knownName, hash: nameHash)
                return unsafe literal(nameIndex: nameIndex, name, nameCount, knownName, value, valueCount, flags: 0x10, mask: 0x0F, &output)
            case 2: indexes = false
            default: indexes = entrySize &* 4 <= table.maximumSize &* 3
            }
        }
        let nameIndex = staticIndex > 0 ? staticIndex : unsafe dynamicNameIndex(name, nameCount, knownName, hash: nameHash)
        guard indexes else {
            return unsafe literal(nameIndex: nameIndex, name, nameCount, knownName, value, valueCount, flags: 0, mask: 0x0F, &output)
        }
        guard unsafe literal(nameIndex: nameIndex, name, nameCount, knownName, value, valueCount, flags: 0x40, mask: 0x3F, &output) else {
            return false
        }
        unsafe insert(name, nameCount, knownName, value, valueCount, nameHash: nameHash, fieldHash: fieldHash)
        return true
    }

    /// A known name's lowercase bytes (``HTTPFieldName/lowercaseBytes``), or `name` if it isn't known: what a literal
    /// writes as its name. (A store's known name may be spelled as HTTP/1 sent it; matching ignores a known name's
    /// bytes, and the encoder's own table entries are matched by known name too, so only this write needs them.) Out of
    /// the way: a known name is written as a string only when neither table has it.
    @inlinable @inline(__always)
    static func spelling(_ knownName: UInt8, _ name: UnsafeRawPointer?, _ nameCount: Int) -> (UnsafeRawPointer?, Int) {
        guard knownName != 0xFF else { return unsafe (name, nameCount) }
        return HTTPFieldName(tableIndex: knownName).lowercaseBytes.withUnsafeBytes { bytes in
            // The address escapes the closure, which is safe here: it's the static table of names, a global constant that
            // lives as long as the program and never changes.
            (bytes.baseAddress, bytes.count)
        }
    }

    /// Writes a literal: the first byte's `flags` and the name index in `mask`'s prefix, the name as a string if the
    /// index is 0, then the value.
    @inlinable @inline(__always)
    func literal(nameIndex: Int, _ name: UnsafeRawPointer?, _ nameCount: Int, _ knownName: UInt8, _ value: UnsafeRawPointer?,
                 _ valueCount: Int, flags: UInt8, mask: Int, _ output: inout FieldEncoderOutput) -> Bool {
        guard output.integer(nameIndex, mask: mask, flags: flags) else { return false }
        if nameIndex == 0 {
            let (name, nameCount) = unsafe Self.spelling(knownName, name, nameCount)
            guard unsafe output.string(name, nameCount, huffman: usesHuffmanCoding) else { return false }
        }
        return unsafe output.string(value, valueCount, huffman: usesHuffmanCoding)
    }

    // MARK: - Matching

    /// The dynamic index (62 and up) of an entry with this name, or 0.
    @inlinable @inline(__always)
    func dynamicNameIndex(_ name: UnsafeRawPointer?, _ nameCount: Int, _ knownName: UInt8, hash: UInt64? = nil) -> Int {
        let hash = unsafe hash ?? DynamicFieldIndex.nameHash(name, nameCount, knownName)
        let number = unsafe index.nameMatch(hash, in: table, name, nameCount, knownName)
        return number >= 0 ? 61 &+ table.inserted &- number : 0
    }

    /// Inserts a field into the table and its two chains.
    @inlinable @inline(__always)
    mutating func insert(_ name: UnsafeRawPointer?, _ nameCount: Int, _ knownName: UInt8, _ value: UnsafeRawPointer?, _ valueCount: Int,
                         nameHash: UInt64, fieldHash: UInt64) {
        let number = unsafe table.insert(name: name, nameCount: nameCount, knownName: knownName, value: value, valueCount: valueCount)
        guard number >= 0 else { return }
        index.add(number: number, entryMask: table.entryMask, nameHash: nameHash, fieldHash: fieldHash)
    }
}

// An encoder owns its memory alone (it's noncopyable), so moving it to another task is safe.
extension HPACKEncoder: @unchecked Sendable {}
