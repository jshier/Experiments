public import HTTPBytes

/// A field decoded from an HPACK field block: views of the block (literal strings sent as they are), of the decoder's
/// memory (Huffman-decoded strings, dynamic table entries), or of the static tables; and whether it was sent as a
/// never-indexed literal (RFC 7541 §6.2.3), which an intermediary must forward the same way.
@frozen
public struct HPACKField: ~Escapable {
    /// The name's bytes (lowercase if the peer follows RFC 9113 §8.2.1: ``HTTP2FieldValidator`` checks).
    public let name: RawSpan
    /// The value's bytes.
    public let value: RawSpan
    /// The name, if HTTPBytes knows it: from the static table's index, a dynamic table entry, or an exact lookup of a
    /// literal name (``HTTPFieldName/init(lowercase:)``). A known name is a valid lowercase name.
    public let knownName: HTTPFieldName?
    /// Whether it was a never-indexed literal.
    public let isNeverIndexed: Bool
    /// Whether the decoder found the name's and value's characters valid for HTTP/2 (RFC 9113 §8.2.1: a lowercase name
    /// without controls, spaces, or colons past the first byte; a value without NUL, CR, or LF, or whitespace at its ends).
    /// Checked once per literal and kept with dynamic table entries, so ``HTTP2FieldValidator`` needn't scan indexed
    /// fields again. `false` doesn't make a field malformed by itself: a pseudo-header field's name has a colon.
    public let hasValidCharacters: Bool

    @inlinable @inline(__always)
    @_lifetime(copy name, copy value)
    public init(name: RawSpan, value: RawSpan, knownName: HTTPFieldName?, isNeverIndexed: Bool, hasValidCharacters: Bool = false) {
        self.hasValidCharacters = hasValidCharacters
        self.name = name
        self.value = value
        self.knownName = knownName
        self.isNeverIndexed = isNeverIndexed
    }

    /// A decoded field's views, made from the decoder's addresses: depending on the block and on the decoder, as
    /// ``HPACKDecoder/next(in:)``'s result does.
    @inlinable @inline(__always)
    @_lifetime(copy block, &decoder)
    init(_ raw: HPACKDecodedField, block: RawSpan, decoder: inout HPACKDecoder) {
        let known = raw.knownName == 0xFF ? nil : HTTPFieldName(tableIndex: raw.knownName)
        // Unsafe: spans over decoded bytes (the block's, the decoder's scratch or table's, or the static tables' constant
        // data), `nameCount` and `valueCount` of them. Safe for as long as the result lives: it depends on the block and on
        // the decoder (this initializer's lifetime), which keep those bytes unchanged until the decoder is next used.
        name = unsafe _overrideLifetime(RawSpan(_unsafeStart: raw.name, byteCount: raw.nameCount), copying: block)
        value = unsafe _overrideLifetime(RawSpan(_unsafeStart: raw.value, byteCount: raw.valueCount), copying: block)
        knownName = known
        isNeverIndexed = raw.status == HPACKDecodedField.neverIndexedField
        hasValidCharacters = raw.characters == DynamicFieldTableEntry.nameIsValid | DynamicFieldTableEntry.valueIsValid
    }

    /// The field as a plain view (for ``HTTPFieldStore/append(_:flags:)``, with ``flags``).
    @inlinable
    public var view: HTTPFieldView {
        @_lifetime(copy self) get { HTTPFieldView(name: name, value: value, knownName: knownName) }
    }

    /// ``HTTPFieldStore/neverIndexed`` if it was a never-indexed literal, else 0.
    @inlinable
    public var flags: UInt8 { isNeverIndexed ? HTTPFieldStore.neverIndexed : 0 }
}

/// What the decoder's out-of-line step found: a field's addresses (placeholders for none), the
/// block's end, or an error.
@frozen @usableFromInline @safe
struct HPACKDecodedField {
    @usableFromInline var name: UnsafeRawPointer
    @usableFromInline var nameCount: Int
    @usableFromInline var value: UnsafeRawPointer
    @usableFromInline var valueCount: Int
    /// ``HTTPFieldName/index``, or 0xFF.
    @usableFromInline var knownName: UInt8
    /// `DynamicFieldTableEntry.nameIsValid | valueIsValid` when the characters are known to be valid (RFC 9113 §8.2.1).
    @usableFromInline var characters: UInt8
    /// `field`, `neverIndexedField`, `end`, or an error's code (`HPACKError(code:)`).
    @usableFromInline var status: UInt8

    @inlinable static var field: UInt8 { 0 }
    @inlinable static var neverIndexedField: UInt8 { 1 }
    @inlinable static var end: UInt8 { 2 }
    /// Internal to the decoder: a literal too large to decode, skipped in a block already past its limit; the decoder
    /// goes on to the next representation (never returned).
    @inlinable static var skipped: UInt8 { 3 }

    @inlinable @inline(__always)
    init(name: UnsafeRawPointer, nameCount: Int, value: UnsafeRawPointer, valueCount: Int, knownName: UInt8, characters: UInt8,
         status: UInt8) {
        self.characters = characters
        unsafe self.name = name
        self.nameCount = nameCount
        unsafe self.value = value
        self.valueCount = valueCount
        self.knownName = knownName
        self.status = status
    }

    @inlinable @inline(__always)
    init(status: UInt8) {
        // Unsafe: placeholder addresses, never read (a status has no field).
        let none = unsafe UnsafeRawPointer(bitPattern: 1).unsafelyUnwrapped
        unsafe self.init(name: none, nameCount: 0, value: none, valueCount: 0, knownName: 0xFF, characters: 0, status: status)
    }

    @inlinable @inline(__always)
    init(error: HPACKError) {
        self.init(status: error.code)
    }
}

extension HPACKError {
    /// A code for the decoder's step result: 16 and up.
    @inlinable
    var code: UInt8 {
        switch self {
        case .truncated: 16
        case .invalidIndex: 17
        case .integerOverflow: 18
        case .invalidHuffmanCode: 19
        case .tableSizeUpdateTooLarge: 20
        case .misplacedTableSizeUpdate: 21
        case .missingTableSizeUpdate: 22
        case .headerListTooLarge: 23
        case .outputTooSmall: 24
        case .malformedField: 25
        case .unfinishedBlock: 26
        }
    }

    @inlinable
    init(code: UInt8) {
        switch code {
        case 16: self = .truncated
        case 17: self = .invalidIndex
        case 18: self = .integerOverflow
        case 19: self = .invalidHuffmanCode
        case 20: self = .tableSizeUpdateTooLarge
        case 21: self = .misplacedTableSizeUpdate
        case 22: self = .missingTableSizeUpdate
        case 23: self = .headerListTooLarge
        case 25: self = .malformedField
        case 26: self = .unfinishedBlock
        default: self = .outputTooSmall
        }
    }
}

/// An HPACK decoder (RFC 7541): one per HTTP/2 connection, decoding the peer's field blocks in the order they arrive.
///
/// ```swift
/// var decoder = HPACKDecoder(maximumTableSize: 4_096, maximumHeaderListSize: 16_384)
/// var validator = HTTP2FieldValidator(.request)
/// var malformed: HTTP2FieldError?
/// while let field = try decoder.next(in: block) {
///     // After a malformed field the block is still decoded to its end: the table must stay in step with the peer's.
///     if malformed != nil { continue }
///     do throws(HTTP2FieldError) { try validator.check(field) } catch { malformed = error; continue }
///     if field.knownName == .pseudoPath { … }
/// }
/// if let malformed { … }        // RST_STREAM (`malformed.http2Error(stream:)`); the decoder is ready for the next block
///
/// try decoder.decode(block, into: &fields)   // or a whole block into a store, its fields' characters checked
/// ```
///
/// **Blocks.** `next(in:)` takes a complete field block: a HEADERS or PUSH_PROMISE fragment with END_HEADERS, or the
/// fragments of one joined in an ``HTTP2FieldBlockBuffer`` (CONTINUATION frames carry the rest of a block, and a
/// string can straddle two of them: joining them is one copy, which only blocks over a frame pay). Call it until it
/// returns `nil`, the block's end; the decoder then expects the next block. Fields are views that borrow the block and
/// the decoder until the next call. The decoder keeps its place in the block between calls, so every call until the end
/// takes the same block: leaving the loop early (an error of the caller's own, a field it rejects) leaves the block
/// unfinished, and the next call with another block throws ``HPACKError/unfinishedBlock`` rather than decode it from the
/// wrong place. Finish the block (``skipRest(of:)`` keeps the table in step), or ``resetBlock()`` before the connection
/// ends.
///
/// **Memory.** The dynamic table (twice SETTINGS_HEADER_TABLE_SIZE of bytes, entries contiguous) and a scratch buffer
/// for Huffman-decoded strings (the header list limit, or the table size if larger) are allocated when the decoder is
/// made, and again only if the table setting grows: nothing per block.
///
/// **Names.** Names from the static table, or a dynamic entry, arrive with their ``HTTPFieldName`` (no hashing); literal
/// names are looked up exactly once, when decoded (``HTTPFieldName/init(lowercase:)``), and dynamic entries keep the
/// result.
///
/// **Errors** are ``HPACKError``s: COMPRESSION_ERROR for the connection, except ``HPACKError/headerListTooLarge``
/// (see ``skipRest(of:)``), ``HPACKError/malformedField`` (``decode(_:into:)``), and ``HPACKError/unfinishedBlock``.
/// After an error, `next(in:)` throws ``HPACKError/unfinishedBlock`` until the block is finished or reset: a field that
/// crossed the header list limit isn't silently skipped. `next(in:)` checks no field-section rules (RFC 9113
/// §8.2–8.3: ``HTTP2FieldValidator``'s, a separate step); ``decode(_:into:)`` checks characters and connection-specific
/// fields before storing.
@safe
public struct HPACKDecoder: ~Copyable {
    @usableFromInline var table: DynamicFieldTable
    /// The static table, by address.
    @usableFromInline let statics: StaticFieldEntries
    /// Huffman-decoded strings of the current field (name, then value).
    @usableFromInline var scratch: UnsafeMutableRawPointer
    /// The strings' limit in the scratch buffer (16 bytes past it are room for the Huffman decoder's wide stores).
    @usableFromInline var scratchLimit: Int
    /// The next representation's offset in the block; 0 between blocks.
    @usableFromInline var offset = 0
    /// The block's header list size so far (RFC 7541 §4.1).
    @usableFromInline var listSize = 0
    /// Whether the block has had a field (so a size update is misplaced).
    @usableFromInline var sawField = false
    /// Whether the block passed the header list limit (reported once).
    @usableFromInline var exceededLimit = false
    /// The block in progress (from its first call until it ends): its address and length, to catch calls given another.
    /// After ``HPACKError/headerListTooLarge``, the length's complement, so that `next(in:)` throws until
    /// `skipRest(of:)` restores it; after an error that lost the compression state, `offset` is -1 (and calls throw until
    /// a reset). One comparison of each per call, made anyway.
    @usableFromInline var blockBase: UnsafePointer<UInt8>?
    @usableFromInline var blockCount = 0
    /// The largest first size update the next block must start with (after a lowered setting), or -1.
    @usableFromInline var requiredUpdate = -1
    @usableFromInline var _maximumTableSizeSetting: Int
    /// The SETTINGS_HEADER_TABLE_SIZE this endpoint advertised and the peer acknowledged.
    @inlinable public var maximumTableSizeSetting: Int { _maximumTableSizeSetting }
    /// The largest header list accepted (RFC 7541 §4.1's size), usually the SETTINGS_MAX_HEADER_LIST_SIZE advertised.
    public let maximumHeaderListSize: Int

    /// A decoder whose peer may use a dynamic table of up to `maximumTableSize` bytes (SETTINGS_HEADER_TABLE_SIZE, 4,096
    /// unless this endpoint advertises otherwise), accepting header lists up to `maximumHeaderListSize`.
    @inlinable
    public init(maximumTableSize: Int = 4_096, maximumHeaderListSize: Int = 65_536) {
        precondition(maximumHeaderListSize >= 0 && maximumHeaderListSize <= 1 << 30, "a header list limit is 0 through 2³⁰")
        table = DynamicFieldTable(capacity: maximumTableSize)
        statics = StaticFieldEntries.hpack()
        _maximumTableSizeSetting = maximumTableSize
        self.maximumHeaderListSize = maximumHeaderListSize
        scratchLimit = Swift.max(maximumHeaderListSize, maximumTableSize)
        // Unsafe: an allocation owned by this decoder and freed in `deinit`.
        unsafe scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchLimit &+ 16, alignment: 16)
    }

    deinit {
        // Unsafe: frees this decoder's own allocation, which nothing else holds (the decoder is noncopyable).
        unsafe scratch.deallocate()
    }

    /// Changes the table size setting, once the peer has acknowledged the SETTINGS frame carrying it (RFC 7541 §4.2):
    /// a lower one requires the peer's next block to start with a size update at or below it; a higher one is allowed
    /// from now on (and makes new memory, the entries moved over, if it's above what the decoder has).
    public mutating func setMaximumTableSize(_ newValue: Int) {
        precondition(newValue >= 0 && newValue <= 1 << 30, "a table size is 0 through 2³⁰")
        if newValue < table.maximumSize {
            requiredUpdate = requiredUpdate < 0 ? newValue : Swift.min(requiredUpdate, newValue)
        }
        _maximumTableSizeSetting = newValue
        if newValue > table.capacity {
            table = Self.moved(table, capacity: newValue)
            if newValue > scratchLimit {
                // Unsafe: replaces this decoder's own scratch allocation; nothing borrows it between calls.
                unsafe scratch.deallocate()
                scratchLimit = newValue
                unsafe scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchLimit &+ 16, alignment: 16)
            }
        }
    }

    /// A table with more memory holding `table`'s entries.
    static func moved(_ table: borrowing DynamicFieldTable, capacity: Int) -> DynamicFieldTable {
        var larger = DynamicFieldTable(capacity: capacity)
        larger.maximumSize = table.maximumSize
        for number in table.oldest..<table.inserted {
            let entry = table.entry(number: number)
            // Unsafe: addresses of the old table's entries, read while it lives (copied into the new one).
            _ = unsafe larger.insert(
                name: table.address(Int(entry.offset)), nameCount: Int(entry.nameCount), knownName: entry.knownName,
                value: table.address(entry.valueOffset), valueCount: Int(entry.valueCount), flags: entry.flags
            )
        }
        return larger
    }

    /// The dynamic table's size (RFC 7541 §4.1).
    @inlinable public var tableSize: Int { table.size }
    /// The dynamic table's current maximum size (from the peer's size updates).
    @inlinable public var tableMaximumSize: Int { table.maximumSize }
    /// The number of dynamic table entries.
    @inlinable public var tableCount: Int { table.count }

    /// The dynamic table's entry at `index` (1 is the newest; up to ``tableCount``).
    @inlinable
    @_lifetime(borrow self)
    public func tableEntry(at index: Int) -> HTTPFieldView {
        precondition(index >= 1 && index <= table.count, "a dynamic table index is 1 through the entry count")
        let entry = table.entry(at: index)
        let known = entry.knownName == 0xFF ? nil : HTTPFieldName(tableIndex: entry.knownName)
        // Unsafe: spans over the entry's bytes in the table. Safe: they depend on the decoder (borrowed), which can't
        // change the table while they live.
        let value = unsafe _overrideLifetime(
            RawSpan(_unsafeStart: table.address(entry.valueOffset), byteCount: Int(entry.valueCount)), borrowing: self
        )
        // Unsafe and safe as for the value.
        let name = unsafe _overrideLifetime(
            RawSpan(_unsafeStart: table.address(Int(entry.offset)), byteCount: Int(entry.nameCount)), borrowing: self
        )
        return HTTPFieldView(name: name, value: value, knownName: known)
    }

    /// The block's next field, or `nil` at its end (after which the decoder expects a new block).
    ///
    /// Pass the same block (its bytes at the same address) to every call until it returns `nil`: the decoder keeps its
    /// place in the block between calls, and throws ``HPACKError/unfinishedBlock`` if it's given another one in the
    /// middle (the table would miss the rest of the first).
    ///
    /// - Throws: ``HPACKError``. After ``HPACKError/headerListTooLarge`` the block must be finished with
    ///   ``skipRest(of:)`` (the field that crossed the limit isn't returned, and calling `next(in:)` again throws
    ///   ``HPACKError/unfinishedBlock``); after any other error, the connection's compression state is lost, and calls
    ///   throw ``HPACKError/unfinishedBlock`` until ``resetBlock()`` or ``reset()``.
    @inlinable
    @_lifetime(copy block, &self)
    public mutating func next(in block: RawSpan) throws(HPACKError) -> HPACKField? {
        let raw = block.withUnsafeBytes { buffer in
            // Unsafe: the block's own bytes, read within its count.
            unsafe decodeNext(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count)
        }
        if raw.status >= HPACKDecodedField.end {
            if raw.status == HPACKDecodedField.end { return nil }
            throw HPACKError(code: raw.status)
        }
        return HPACKField(raw, block: block, decoder: &self)
    }

    /// Decodes the rest of the block, discarding its fields but applying their changes to the table: after
    /// ``HPACKError/headerListTooLarge``, to keep the table in step with the peer's (RFC 9113 §10.5.1). The decoder then
    /// expects a new block.
    ///
    /// - Throws: ``HPACKError/unfinishedBlock`` for another block than the one in progress, or after an error that lost
    ///   the compression state; any error decoding the rest.
    public mutating func skipRest(of block: RawSpan) throws(HPACKError) {
        // Checked before anything changes: another block mid-block leaves the one in progress as it was.
        guard offset >= 0 else { throw .unfinishedBlock }
        if offset > 0 {
            let length = blockCount < 0 ? ~blockCount : blockCount
            let sameBlock = block.withUnsafeBytes { buffer in
                // Unsafe: the block's address, compared, not read.
                unsafe buffer.baseAddress == UnsafeRawPointer(blockBase) && buffer.count == length
            }
            guard sameBlock else { throw .unfinishedBlock }
            blockCount = length
        }
        exceededLimit = true
        while true {
            let raw = block.withUnsafeBytes { buffer in
                // Unsafe: as in `next(in:)`.
                unsafe decodeNext(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count)
            }
            if raw.status == HPACKDecodedField.end { return }
            if raw.status > HPACKDecodedField.end { throw HPACKError(code: raw.status) }
        }
    }

    /// Decodes a whole block into `fields` (appended; never-indexed fields flagged), checking each field as HTTP/2
    /// requires before it's stored: its characters (RFC 9113 §8.2.1: what ``HPACKField/hasValidCharacters`` says, so an
    /// unknown pseudo-header field, an uppercase name, or a value with CR or LF isn't stored), and that it isn't
    /// connection-specific (§8.2.2). Pseudo-header fields' order and set are ``HTTP2FieldValidator``'s.
    ///
    /// The block is always decoded to its end, so the table stays in step with the peer's and the decoder is ready for
    /// the next block, whichever error is thrown (except those that lose the compression state).
    ///
    /// - Throws: ``HPACKError/malformedField`` (a stream's PROTOCOL_ERROR: `fields` has the fields before the first
    ///   malformed one), ``HPACKError/headerListTooLarge`` (the block passed the decoder's limit, or `fields` couldn't
    ///   take a field), or a connection error.
    @inlinable
    public mutating func decode(_ block: RawSpan, into fields: inout HTTPFieldStore) throws(HPACKError) {
        // The fields stored until the first problem; then the rest decoded only for the table. The step's results are
        // read directly (no throw per field, and none to catch for the list limit).
        var failure: UInt8 = 0
        while true {
            let raw = block.withUnsafeBytes { buffer in
                // Unsafe: the block's own bytes, read within its count.
                unsafe decodeNext(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count)
            }
            if raw.status >= HPACKDecodedField.end {
                if raw.status == HPACKDecodedField.end { break }
                let error = HPACKError(code: raw.status)
                guard error == .headerListTooLarge else { throw error }
                try skipRest(of: block)
                throw .headerListTooLarge
            }
            guard failure == 0 else { continue }
            let field = HPACKField(raw, block: block, decoder: &self)
            guard Self.isWellFormed(field) else {
                failure = HPACKError.malformedField.code
                continue
            }
            do throws(HTTPFieldError) {
                try fields.append(field.view, flags: field.flags)
            } catch {
                failure = HPACKError.headerListTooLarge.code
            }
        }
        if failure != 0 { throw HPACKError(code: failure) }
    }

    /// Whether a decoded field may be stored as an HTTP/2 field: valid characters (a name that isn't a known one, which
    /// includes every defined pseudo-header field, must be a valid regular name), and not connection-specific.
    @inlinable @inline(__always)
    static func isWellFormed(_ field: borrowing HPACKField) -> Bool {
        guard field.hasValidCharacters else { return false }
        guard let index = field.knownName?.index else { return true }
        // By index: `HTTPFieldName`'s derived `==`, from another module, can be a call per comparison.
        switch index {
        case HTTPFieldName.connection.index, HTTPFieldName.keepAlive.index, HTTPFieldName.proxyConnection.index,
             HTTPFieldName.transferEncoding.index, HTTPFieldName.upgrade.index: return false
        case HTTPFieldName.te.index: return HTTPToken.equalsIgnoringCase(field.value, "trailers")
        default: return true
        }
    }

    /// Returns to a new connection's state, keeping the memory: an empty table at the setting's size, no block begun.
    @inlinable
    public mutating func reset() {
        table.removeAll()
        table.maximumSize = _maximumTableSizeSetting
        requiredUpdate = -1
        resetBlock()
    }

    /// Forgets a block left unfinished (after an error, or a block abandoned on purpose), so the next call starts a new
    /// one. After an error that lost the compression state, the table can't be trusted: the connection should end.
    @inlinable
    public mutating func resetBlock() {
        offset = 0
        listSize = 0
        sawField = false
        exceededLimit = false
    }

    // MARK: - The step

    /// After ``HPACKError/headerListTooLarge``: `next(in:)` throws until `skipRest(of:)` (or `resetBlock()`).
    @inline(__always)
    mutating func stallForSkip() {
        blockCount = ~blockCount
    }

    /// After an error that lost the compression state: every call throws until `resetBlock()` or `reset()`. A count no
    /// block has, so `decodeNext` never reads at the offset -1.
    @inline(__always)
    mutating func loseState() {
        offset = -1
        blockCount = -1
    }

    /// Ends the block: checks a required size update came, and resets for the next.
    @inline(__always)
    mutating func endBlock() -> HPACKDecodedField {
        resetBlock()
        if requiredUpdate >= 0 {
            loseState()
            return HPACKDecodedField(error: .missingTableSizeUpdate)
        }
        return HPACKDecodedField(status: HPACKDecodedField.end)
    }

    /// Fails: the connection's compression state is lost; calls throw until the block or decoder is reset.
    @inline(__always)
    mutating func fail(_ error: HPACKError) -> HPACKDecodedField {
        resetBlock()
        loseState()
        return HPACKDecodedField(error: error)
    }

    /// Decodes representations from `offset` until one yields a field, or the block ends.
    @usableFromInline
    mutating func decodeNext(_ base: UnsafePointer<UInt8>?, _ count: Int) -> HPACKDecodedField {
        var position = offset
        // The same block until it ends: the place kept is in it. (Its address and length: a block refilled in place isn't
        // caught.) Nothing after an error but what the error allows (`blockCount`, `offset`).
        if position != 0 {
            guard unsafe base == blockBase, count == blockCount else {
                return HPACKDecodedField(error: .unfinishedBlock)
            }
        } else {
            unsafe blockBase = base
            blockCount = count
        }
        guard position < count, let base = unsafe base else {
            return position == count || count == 0 ? endBlock() : fail(.truncated)
        }
        while true {
            // Unsafe: an unchecked read. Safe: position < count (checked on entry and before each loop).
            let first = Int(unsafe base[position])
            if first >= 0x80 {
                // Indexed field (RFC 7541 §6.1).
                var index = first & 0x7F
                if index == 0x7F {
                    index = unsafe readPrefixIntegerContinuation(base, count, &position, 0x7F)
                    if index < 0 { return fail(index == prefixIntegerTruncated ? .truncated : .integerOverflow) }
                } else {
                    position &+= 1
                }
                if requiredUpdate >= 0 { return fail(.missingTableSizeUpdate) }
                sawField = true
                var field: HPACKDecodedField
                if index <= 61 {
                    guard index > 0 else { return fail(.invalidIndex) }
                    let entry = statics[index]
                    field = unsafe HPACKDecodedField(
                        name: entry.name, nameCount: Int(entry.nameCount), value: entry.value, valueCount: Int(entry.valueCount),
                        knownName: entry.knownName, characters: 3, status: HPACKDecodedField.field
                    )
                } else {
                    let dynamic = index &- 61
                    guard dynamic <= table.count else { return fail(.invalidIndex) }
                    let entry = table.entry(at: dynamic)
                    field = unsafe HPACKDecodedField(
                        name: table.address(Int(entry.offset)), nameCount: Int(entry.nameCount),
                        value: table.address(entry.valueOffset), valueCount: Int(entry.valueCount),
                        knownName: entry.knownName, characters: entry.flags, status: HPACKDecodedField.field
                    )
                }
                offset = position
                return account(field)
            }
            if first & 0xE0 == 0x20 {
                // Dynamic table size update (RFC 7541 §6.3).
                guard !sawField else { return fail(.misplacedTableSizeUpdate) }
                var size = first & 0x1F
                if size == 0x1F {
                    size = unsafe readPrefixIntegerContinuation(base, count, &position, 0x1F)
                    if size < 0 { return fail(size == prefixIntegerTruncated ? .truncated : .integerOverflow) }
                } else {
                    position &+= 1
                }
                guard size <= maximumTableSizeSetting else { return fail(.tableSizeUpdateTooLarge) }
                if requiredUpdate >= 0 {
                    guard size <= requiredUpdate else { return fail(.missingTableSizeUpdate) }
                    requiredUpdate = -1
                }
                table.setMaximumSize(size)
                offset = position
                guard position < count else { return endBlock() }
                continue
            }
            // Literal (RFC 7541 §6.2): with incremental indexing (01), without indexing (0000), never indexed (0001).
            let field = unsafe literal(base, count, position, first)
            guard field.status == HPACKDecodedField.skipped else { return field }
            // Skipped past the limit: on to the next representation in this loop. (It recursed once per skipped
            // literal: with both limits 0, a 1 MiB block of them could overflow a task's stack.)
            position = offset
            guard position < count else { return endBlock() }
        }
    }

    /// A literal field representation at `position`, whose first byte is `first`.
    @inline(__always)
    mutating func literal(_ base: UnsafePointer<UInt8>, _ count: Int, _ start: Int, _ first: Int) -> HPACKDecodedField {
        var position = start
        let indexing = first & 0x40 != 0
        let mask = indexing ? 0x3F : 0x0F
        var nameIndex = first & mask
        if nameIndex == mask {
            nameIndex = unsafe readPrefixIntegerContinuation(base, count, &position, mask)
            if nameIndex < 0 { return fail(nameIndex == prefixIntegerTruncated ? .truncated : .integerOverflow) }
        } else {
            position &+= 1
        }
        if requiredUpdate >= 0 { return fail(.missingTableSizeUpdate) }
        sawField = true
        var name: UnsafeRawPointer?
        var nameCount: Int
        var known: UInt8
        var characters: UInt8
        var used = 0
        var tooLarge = false
        if nameIndex == 0 {
            let string = unsafe self.string(base, count, &position, scratchOffset: 0)
            if string.status != 0 {
                if string.status != tooLargeStatus { return fail(HPACKError(code: string.status)) }
                tooLarge = true
            }
            unsafe name = string.address
            nameCount = string.count
            // Only a Huffman-decoded name is in the scratch buffer (at most its limit: longer is too large), so the
            // value's room there, `scratchLimit + 16 - used`, is at least 16 bytes. A raw name stays in the block and
            // takes none, however long.
            used = string.coding == HPACKDecodedString.raw ? 0 : string.count
            known = 0xFF
            if !tooLarge, let address = unsafe name {
                // Unsafe: a span over the name just decoded, used only for the lookup.
                let span = unsafe RawSpan(_unsafeStart: address, byteCount: nameCount)
                if let found = HTTPFieldName(lowercase: span) { known = found.index }
                // Checked once: a dynamic entry keeps the verdict.
                characters = known != 0xFF || HTTP2FieldValidator.isValidRegularName(span) ? DynamicFieldTableEntry.nameIsValid : 0
            } else {
                characters = 0
            }
        } else if nameIndex <= 61 {
            let entry = statics[nameIndex]
            known = entry.knownName
            unsafe name = entry.name
            nameCount = Int(entry.nameCount)
            characters = DynamicFieldTableEntry.nameIsValid
        } else {
            let dynamic = nameIndex &- 61
            guard dynamic <= table.count else { return fail(.invalidIndex) }
            let entry = table.entry(at: dynamic)
            known = entry.knownName
            unsafe name = table.address(Int(entry.offset))
            nameCount = Int(entry.nameCount)
            characters = entry.flags & DynamicFieldTableEntry.nameIsValid
        }
        let valueString = unsafe string(base, count, &position, scratchOffset: used, skips: tooLarge)
        if valueString.status != 0 {
            if valueString.status != tooLargeStatus { return fail(HPACKError(code: valueString.status)) }
            tooLarge = true
        }
        var value = unsafe valueString.address
        let valueCount = valueString.count
        offset = position
        if tooLarge {
            // Larger than the scratch, which is at least the table's setting: an entry would empty the table.
            if indexing { table.removeAll() }
            listSize = Int.max / 2
            if exceededLimit { return HPACKDecodedField(status: HPACKDecodedField.skipped) }
            exceededLimit = true
            stallForSkip()
            return HPACKDecodedField(error: .headerListTooLarge)
        }
        if unsafe Self.isValidValue(value.unsafelyUnwrapped, valueCount, coding: valueString.coding) {
            characters |= DynamicFieldTableEntry.valueIsValid
        }
        if indexing {
            let number = unsafe table.insert(name: name, nameCount: nameCount, knownName: known, value: value, valueCount: valueCount,
                                             flags: characters)
            if number >= 0 {
                // The entry's own bytes: the name it was given may have been an evicted entry's, now overwritten.
                let entry = table.entry(number: number)
                unsafe name = table.address(Int(entry.offset))
                unsafe value = table.address(entry.valueOffset)
            }
        }
        let status = first & 0xF0 == 0x10 ? HPACKDecodedField.neverIndexedField : HPACKDecodedField.field
        // Unsafe: unchecked unwraps. Safe: past the too-large case, both strings have addresses (decoded or in the block).
        return account(unsafe HPACKDecodedField(
            name: name.unsafelyUnwrapped, nameCount: nameCount, value: value.unsafelyUnwrapped, valueCount: valueCount,
            knownName: known, characters: characters, status: status
        ))
    }

    /// Whether a value's characters are valid (RFC 9113 §8.2.1): for a Huffman-coded one, the decoder said whether it had
    /// NUL, LF, or CR, so only its ends are checked; a raw one is scanned.
    @inline(__always)
    static func isValidValue(_ value: UnsafeRawPointer, _ count: Int, coding: UInt8) -> Bool {
        if coding == HPACKDecodedString.raw {
            // Unsafe: a span over the value (in the block), `count` bytes, used only for the check.
            return unsafe HTTP2FieldValidator.isValidValue(RawSpan(_unsafeStart: value, byteCount: count))
        }
        guard coding == HPACKDecodedString.huffman else { return false }
        guard count > 0 else { return true }
        // Unsafe: the value's first and last bytes. Safe: count > 0.
        let first = unsafe value.load(as: UInt8.self), last = unsafe value.load(fromByteOffset: count &- 1, as: UInt8.self)
        return first != 0x20 && first != 0x09 && last != 0x20 && last != 0x09
    }

    /// Adds a field to the block's header list size, failing (once per block) past the limit.
    @inline(__always)
    mutating func account(_ field: HPACKDecodedField) -> HPACKDecodedField {
        listSize &+= field.nameCount &+ field.valueCount &+ 32
        if listSize > maximumHeaderListSize, !exceededLimit {
            exceededLimit = true
            stallForSkip()
            return HPACKDecodedField(error: .headerListTooLarge)
        }
        return field
    }

    @inline(__always) var tooLargeStatus: UInt8 { 1 }

    /// A string literal (RFC 7541 §5.2) at `position`, moved past: raw, its address in the block; Huffman-coded, decoded
    /// into the scratch buffer at `scratchOffset`. Status 0, `tooLargeStatus` (past the scratch's limit, or `skips`:
    /// not decoded), or an error's code.
    @inline(__always)
    func string(_ base: UnsafePointer<UInt8>, _ count: Int, _ position: inout Int, scratchOffset: Int, skips: Bool = false)
        -> HPACKDecodedString {
        guard position < count else { return unsafe HPACKDecodedString(nil, 0, HPACKError.truncated.code) }
        // Unsafe: an unchecked read. Safe: position < count.
        let first = Int(unsafe base[position])
        var length = first & 0x7F
        if length == 0x7F {
            length = unsafe readPrefixIntegerContinuation(base, count, &position, 0x7F)
            if length < 0 { return unsafe HPACKDecodedString(nil, 0, length == prefixIntegerTruncated ? HPACKError.truncated.code : HPACKError.integerOverflow.code) }
        } else {
            position &+= 1
        }
        guard length <= count &- position else { return unsafe HPACKDecodedString(nil, 0, HPACKError.truncated.code) }
        // Unsafe: the string's address in the block. Safe: `length` bytes from `position` are within it (checked).
        let start = unsafe UnsafeRawPointer(base + position)
        position &+= length
        if first & 0x80 == 0 { return unsafe HPACKDecodedString(start, length, 0) }
        if skips { return unsafe HPACKDecodedString(nil, 0, tooLargeStatus) }
        // Unsafe: decodes into the scratch buffer from `scratchOffset`, with its room (the limit and 16 bytes more,
        // allocated) as the capacity. Safe: `scratchOffset` is 0 or a Huffman-decoded name's length, which is at most
        // `scratchLimit` (longer is too large), so the room is at least 16 bytes and the start is inside the buffer.
        assert(scratchOffset >= 0 && scratchOffset <= scratchLimit, "a value decodes after a name in the scratch buffer")
        let room = scratchLimit &+ 16 &- scratchOffset
        let output = unsafe (scratch + scratchOffset).assumingMemoryBound(to: UInt8.self)
        let result = unsafe huffmanDecode(input: start, inputCount: length, output: output, capacity: room)
        if result == huffmanInvalid { return unsafe HPACKDecodedString(nil, 0, HPACKError.invalidHuffmanCode.code) }
        let decoded = result & (huffmanForbiddenCharacters &- 1)
        if result < 0 || decoded > scratchLimit &- scratchOffset { return unsafe HPACKDecodedString(nil, 0, tooLargeStatus) }
        var string = unsafe HPACKDecodedString(UnsafeRawPointer(output), decoded, 0)
        string.coding = result >= huffmanForbiddenCharacters ? HPACKDecodedString.huffmanWithForbidden : HPACKDecodedString.huffman
        return string
    }
}

/// A string literal as the decoder's step found it: its address (in the block, or the scratch buffer) and length, and a
/// status (0, too large, or an error's code).
@frozen @usableFromInline @safe
struct HPACKDecodedString {
    @usableFromInline var address: UnsafeRawPointer?
    @usableFromInline var count: Int
    @usableFromInline var status: UInt8
    /// `raw`, `huffman`, or `huffmanWithForbidden` (the decoded bytes have NUL, LF, or CR: the Huffman decoder says).
    @usableFromInline var coding: UInt8 = 0

    @inlinable static var raw: UInt8 { 0 }
    @inlinable static var huffman: UInt8 { 1 }
    @inlinable static var huffmanWithForbidden: UInt8 { 2 }

    @inlinable @inline(__always)
    init(_ address: UnsafeRawPointer?, _ count: Int, _ status: UInt8) {
        unsafe self.address = address
        self.count = count
        self.status = status
    }
}

// A decoder owns its memory alone (it's noncopyable), so moving it to another task is safe.
extension HPACKDecoder: @unchecked Sendable {}
