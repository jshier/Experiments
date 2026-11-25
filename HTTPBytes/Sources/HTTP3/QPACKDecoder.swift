public import HTTPBytes

/// A field decoded from a QPACK field section: views of the section (literal strings sent as they are), of the decoder's
/// memory (Huffman-decoded strings, dynamic table entries), or of the static table; and whether it was sent with the N
/// bit (RFC 9204 §4.5.4), which an intermediary must forward the same way.
@frozen
public struct QPACKField: ~Escapable {
    /// The name's bytes (lowercase if the peer follows RFC 9114 §4.2: ``HTTP3FieldValidator`` checks).
    public let name: RawSpan
    /// The value's bytes.
    public let value: RawSpan
    /// The name, if HTTPBytes knows it: from the static table's index, a dynamic table entry, or an exact lookup of a
    /// literal name (``HTTPFieldName/init(lowercase:)``). A known name is a valid lowercase name.
    public let knownName: HTTPFieldName?
    /// Whether it was a literal with the N bit set (never to be indexed).
    public let isNeverIndexed: Bool
    /// Whether the decoder found the name's and value's characters valid for HTTP/3 (RFC 9114 §4.2, as RFC 9113 §8.2.1:
    /// a lowercase name without controls, spaces, or colons past the first byte; a value without NUL, CR, or LF, or
    /// whitespace at its ends). Checked once per literal and kept with dynamic table entries, so
    /// ``HTTP3FieldValidator`` needn't scan indexed fields again. `false` doesn't make a field malformed by itself: a
    /// pseudo-header field's name has a colon.
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

    /// A decoded field's views, made from the decoder's addresses: depending on the section and on the decoder, as
    /// ``QPACKDecoder/next(in:)``'s result does.
    @inlinable @inline(__always)
    @_lifetime(copy section, &decoder)
    init(_ raw: QPACKDecodedField, section: RawSpan, decoder: inout QPACKDecoder) {
        let known = raw.knownName == 0xFF ? nil : HTTPFieldName(tableIndex: raw.knownName)
        // Unsafe: spans over decoded bytes (the section's, the decoder's scratch or table's, or the static table's
        // constant data), `nameCount` and `valueCount` of them. Safe for as long as the result lives: it depends on the
        // section and on the decoder (this initializer's lifetime), which keep those bytes unchanged until the decoder is
        // next used.
        name = unsafe _overrideLifetime(RawSpan(_unsafeStart: raw.name, byteCount: raw.nameCount), copying: section)
        value = unsafe _overrideLifetime(RawSpan(_unsafeStart: raw.value, byteCount: raw.valueCount), copying: section)
        knownName = known
        isNeverIndexed = raw.status == QPACKDecodedField.neverIndexedField
        hasValidCharacters = raw.characters == DynamicFieldTableEntry.nameIsValid | DynamicFieldTableEntry.valueIsValid
    }

    /// The field as a plain view (for ``HTTPFieldStore/append(_:flags:)``, with ``flags``).
    @inlinable
    public var view: HTTPFieldView {
        @_lifetime(copy self) get { HTTPFieldView(name: name, value: value, knownName: knownName) }
    }

    /// ``HTTPFieldStore/neverIndexed`` if it was sent with the N bit, else 0.
    @inlinable
    public var flags: UInt8 { isNeverIndexed ? HTTPFieldStore.neverIndexed : 0 }
}

public extension HTTPFieldSectionValidator {
    /// Checks a decoded QPACK field: its characters only if the decoder didn't (``QPACKField/hasValidCharacters``), then
    /// its place.
    @inlinable
    mutating func check(_ field: borrowing QPACKField) throws(HTTPFieldSectionError) {
        try check(name: field.name, value: field.value, knownName: field.knownName, charactersChecked: field.hasValidCharacters)
    }
}

/// What the decoder's out-of-line step found: a field's addresses (placeholders for none), the section's end, or an
/// error.
@frozen @usableFromInline @safe
struct QPACKDecodedField {
    @usableFromInline var name: UnsafeRawPointer
    @usableFromInline var nameCount: Int
    @usableFromInline var value: UnsafeRawPointer
    @usableFromInline var valueCount: Int
    /// ``HTTPFieldName/index``, or 0xFF.
    @usableFromInline var knownName: UInt8
    /// `DynamicFieldTableEntry.nameIsValid | valueIsValid` when the characters are known to be valid.
    @usableFromInline var characters: UInt8
    /// `field`, `neverIndexedField`, `end`, or an error's code (`QPACKError(code:)`).
    @usableFromInline var status: UInt8

    @inlinable static var field: UInt8 { 0 }
    @inlinable static var neverIndexedField: UInt8 { 1 }
    @inlinable static var end: UInt8 { 2 }

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
    init(error: QPACKError) {
        self.init(status: error.code)
    }
}

/// A QPACK decoder (RFC 9204): one per HTTP/3 connection, decoding the peer's field sections and applying its encoder
/// stream, and producing this endpoint's decoder stream.
///
/// ```swift
/// var decoder = QPACKDecoder(maximumTableCapacity: 4_096, maximumBlockedStreams: 100)
/// // The peer's encoder stream, as its bytes arrive (keep what isn't consumed: an instruction cut short):
/// let used = try decoder.processEncoderStream(encoderStreamBytes)
/// while let stream = decoder.nextUnblockedStream() { … decode that stream's held section now … }
/// // A HEADERS frame's payload:
/// if try decoder.begin(section, stream: streamID) {
///     while let field = try decoder.next(in: section) { … }
/// } else { /* blocked: keep the section's bytes until `nextUnblockedStream()` names the stream */ }
/// // Then, and after encoder stream bytes, send what the decoder stream needs:
/// decoder.writeDecoderInstructions(into: &decoderStreamOutput)
/// ```
///
/// **Sections.** ``begin(_:stream:)`` reads a whole section's prefix (RFC 9204 §4.5.1); ``next(in:)`` then yields its
/// fields one by one as views that borrow the section and the decoder until the next call, and `nil` at its end, when
/// the Section Acknowledgment is queued (for a section that used the dynamic table). ``decode(_:stream:into:)`` does both
/// into an ``HTTPFieldStore``.
///
/// **Blocked streams** (RFC 9204 §2.1.2): a section whose Required Insert Count is past the inserts received so far
/// can't be decoded yet. ``begin(_:stream:)`` returns `false` and records the stream (at most
/// SETTINGS_QPACK_BLOCKED_STREAMS of them: ``QPACKError/tooManyBlockedStreams`` past that); the caller keeps the
/// section's bytes, and after encoder stream bytes, ``nextUnblockedStream()`` names the streams that can go on. The
/// decoder copies nothing: a blocked request stream can't be read past its HEADERS frame anyway (§2.2.1 says not to
/// release its flow control), so the frame's bytes are already held in the stream's receive buffer, and a pool here
/// would be a second copy of them. The decoder's own memory for blocked streams is two words per stream the setting
/// allows, made with the decoder; the setting is at most 1,024, since finding a blocked stream is a scan of the list.
///
/// **The encoder stream** is applied as its bytes arrive: ``processEncoderStream(_:)`` applies every complete
/// instruction and returns the bytes it used; the caller keeps the rest (part of one instruction: at most about four
/// times the table's capacity, which a Huffman-coded insertion's strings can take) and passes it again with what
/// follows. An incomplete instruction costs only its lengths' reads per call: nothing is decoded until all of it is here.
///
/// **The decoder stream**: Section Acknowledgments and Stream Cancellations are queued in a buffer made with the decoder
/// (``QPACKError/decoderStreamFull`` when there's no room for one: write them and call again). A section that will need
/// an acknowledgment gets its room when it begins, so an acknowledgment is never lost. Insert Count Increments aren't
/// queued: ``writeDecoderInstructions(into:)`` writes one straight to the output, for the inserts not yet acknowledged,
/// once every queued instruction is written.
///
/// **Memory** is allocated when the decoder is made: the dynamic table (twice SETTINGS_QPACK_MAX_TABLE_CAPACITY in
/// bytes, entries contiguous), a scratch buffer for Huffman-decoded strings (the field section limit, or the table's
/// capacity if larger), the blocked streams' list, and the decoder stream's buffer. Nothing per section, field, or
/// instruction.
///
/// **Names.** Names from the static table, or a dynamic entry, arrive with their ``HTTPFieldName`` (no hashing); literal
/// names are looked up once, when decoded (``HTTPFieldName/init(lowercase:)``), and dynamic entries keep the result.
@safe
public struct QPACKDecoder: ~Copyable {
    @usableFromInline var table: DynamicFieldTable
    /// The static table, by address.
    @usableFromInline let statics: StaticFieldEntries
    /// Huffman-decoded strings of the current field line or instruction (name, then value).
    @usableFromInline let scratch: UnsafeMutableRawPointer
    /// The strings' limit in the scratch buffer (16 bytes past it are room for the Huffman decoder's wide stores).
    @usableFromInline let scratchLimit: Int
    /// The blocked streams and the Required Insert Count each waits for.
    @usableFromInline var blocked: UniqueArray<QPACKBlockedStream>
    /// Decoder stream bytes queued (Section Acknowledgments, Stream Cancellations).
    @usableFromInline let instructions: UnsafeMutablePointer<UInt8>
    @usableFromInline let instructionCapacity: Int
    @usableFromInline var instructionCount = 0
    /// The Insert Count the peer's encoder knows the decoder has (RFC 9204 §2.1.4), as this decoder has told it.
    @usableFromInline var knownReceivedCount = 0

    // The section being decoded.

    /// The next representation's offset in the section; 0 when no section is begun.
    @usableFromInline var offset = 0
    @usableFromInline var requiredInsertCount = 0
    @usableFromInline var base = 0
    /// The largest absolute index the section referred to, or -1.
    @usableFromInline var largestReference = -1
    @usableFromInline var stream: UInt64 = 0
    /// The section's size so far (name + value + 32 per field).
    @usableFromInline var sectionSize = 0

    /// SETTINGS_QPACK_MAX_TABLE_CAPACITY, as this endpoint advertises it.
    public let maximumTableCapacity: Int
    /// SETTINGS_QPACK_BLOCKED_STREAMS, as this endpoint advertises it.
    public let maximumBlockedStreams: Int
    /// The largest field section accepted (name + value + 32 per field): SETTINGS_MAX_FIELD_SECTION_SIZE.
    public let maximumFieldSectionSize: Int
    /// MaxEntries (RFC 9204 §4.5.1.1).
    @usableFromInline let maximumEntries: Int

    /// A decoder that lets the peer use a dynamic table of up to `maximumTableCapacity` bytes and block up to
    /// `maximumBlockedStreams` streams (the SETTINGS_QPACK_MAX_TABLE_CAPACITY and SETTINGS_QPACK_BLOCKED_STREAMS this
    /// endpoint advertises), accepting field sections up to `maximumFieldSectionSize`, with room for
    /// `decoderStreamCapacity` bytes of acknowledgments and cancellations between writes.
    public init(maximumTableCapacity: Int = 4_096, maximumBlockedStreams: Int = 100, maximumFieldSectionSize: Int = 65_536,
                decoderStreamCapacity: Int = 1_024) {
        precondition(maximumTableCapacity >= 0 && maximumTableCapacity <= 1 << 30, "a table capacity is 0 through 2³⁰")
        precondition(maximumBlockedStreams >= 0 && maximumBlockedStreams <= 1 << 10, "blocked streams are 0 through 1,024")
        precondition(maximumFieldSectionSize >= 0 && maximumFieldSectionSize <= 1 << 30, "a field section limit is 0 through 2³⁰")
        precondition(decoderStreamCapacity >= 32, "the decoder stream's buffer holds at least 32 bytes")
        table = DynamicFieldTable(capacity: maximumTableCapacity)
        table.maximumSize = 0
        statics = StaticFieldEntries.qpack()
        self.maximumTableCapacity = maximumTableCapacity
        self.maximumBlockedStreams = maximumBlockedStreams
        self.maximumFieldSectionSize = maximumFieldSectionSize
        maximumEntries = maximumTableCapacity / 32
        scratchLimit = Swift.max(maximumFieldSectionSize, maximumTableCapacity)
        instructionCapacity = decoderStreamCapacity
        // Room for every stream that may be blocked: appending never grows it.
        blocked = UniqueArray(capacity: maximumBlockedStreams)
        // Unsafe: allocations owned by this decoder and freed in `deinit`.
        unsafe scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchLimit &+ 16, alignment: 16)
        unsafe instructions = UnsafeMutablePointer<UInt8>.allocate(capacity: decoderStreamCapacity)
    }

    deinit {
        // Unsafe: frees this decoder's own allocations, which nothing else holds (the decoder is noncopyable).
        unsafe scratch.deallocate()
        unsafe instructions.deallocate()
    }

    /// Returns to a new connection's state, keeping the memory: an empty table of capacity 0, no blocked streams, no
    /// instructions queued, no section begun.
    @inlinable
    public mutating func reset() {
        table.removeAllNumberingFromZero()
        table.maximumSize = 0
        blocked.removeAll()
        instructionCount = 0
        knownReceivedCount = 0
        offset = 0
    }

    /// The dynamic table's size (RFC 9204 §3.2.1).
    @inlinable public var tableSize: Int { table.size }
    /// The dynamic table's capacity, as the peer's encoder set it.
    @inlinable public var tableCapacity: Int { table.maximumSize }
    /// The number of dynamic table entries.
    @inlinable public var tableCount: Int { table.count }
    /// The Insert Count: entries inserted since the connection began.
    @inlinable public var insertCount: Int { table.inserted }
    /// The number of streams blocked.
    @inlinable public var blockedStreamCount: Int { blocked.count }
    /// Whether there are decoder stream instructions to write.
    @inlinable public var hasDecoderInstructions: Bool { instructionCount > 0 || table.inserted > knownReceivedCount }

    /// The dynamic table's entry with absolute index `index` (RFC 9204 §3.2.4), which must be in the table.
    @inlinable
    @_lifetime(borrow self)
    public func tableEntry(absoluteIndex index: Int) -> HTTPFieldView {
        precondition(table.contains(number: index), "an absolute index of an entry in the table")
        let entry = table.entry(number: index)
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

    // MARK: - Field sections

    /// Begins decoding `section`, the encoded field section (a HEADERS or PUSH_PROMISE frame's) of stream `stream`: reads
    /// its prefix (RFC 9204 §4.5.1).
    ///
    /// - Returns: `true` if its fields can be decoded now (call ``next(in:)`` until it returns `nil`; a section in
    ///   progress is abandoned); `false` if it's blocked on inserts not yet received: keep the bytes, and begin again once
    ///   ``nextUnblockedStream()`` returns `stream` (or when you like: it's blocked again if it still can't be decoded).
    ///   A section in progress is left as it was.
    /// - Throws: ``QPACKError``: a connection error (no section is in progress after it), or
    ///   ``QPACKError/decoderStreamFull``, only for a section that refers to the dynamic table and so needs an
    ///   acknowledgment (nothing changed, a section in progress included: write the decoder's instructions and call
    ///   again).
    @inlinable
    public mutating func begin(_ section: RawSpan, stream: UInt64) throws(QPACKError) -> Bool {
        let status = section.withUnsafeBytes { buffer in
            // Unsafe: the section's own bytes, read within its count.
            unsafe beginSection(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count, stream: stream)
        }
        if status > 1 { throw QPACKError(code: UInt8(truncatingIfNeeded: status)) }
        return status == 0
    }

    /// The section's next field, or `nil` at its end (after which a new section can begin).
    ///
    /// - Throws: ``QPACKError``. After any error the section is abandoned, except ``QPACKError/decoderStreamFull`` at
    ///   the end (not thrown when the section began with room, as ``begin(_:stream:)`` makes sure): write the decoder's
    ///   instructions and call again. ``QPACKError/sectionNotBegun`` if no section is in progress.
    @inlinable
    @_lifetime(copy section, &self)
    public mutating func next(in section: RawSpan) throws(QPACKError) -> QPACKField? {
        let raw = section.withUnsafeBytes { buffer in
            // Unsafe: the section's own bytes, read within its count.
            unsafe decodeNext(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count)
        }
        if raw.status >= QPACKDecodedField.end {
            if raw.status == QPACKDecodedField.end { return nil }
            throw QPACKError(code: raw.status)
        }
        return QPACKField(raw, section: section, decoder: &self)
    }

    /// Decodes a whole section into `fields` (appended; fields sent with the N bit flagged), checking each field's
    /// characters as HTTP/3 requires (RFC 9114 §4.2; the decoder's verdict, ``QPACKField/hasValidCharacters``, so only
    /// fields it didn't find valid, such as pseudo-header fields with literal names, are scanned again). The section's
    /// other rules (pseudo-header fields, connection-specific fields) are ``HTTP3FieldValidator``'s.
    ///
    /// - Returns: `false` if the section is blocked (nothing appended), as ``begin(_:stream:)``.
    /// - Throws: ``QPACKError``: as ``next(in:)``, and ``QPACKError/malformedField`` for a field with characters HTTP/3
    ///   forbids (H3_MESSAGE_ERROR), or ``QPACKError/fieldSectionTooLarge`` when the store is full (4 GiB). Both are the
    ///   stream's errors: the section is abandoned (reset the stream, and call ``cancelStream(_:)``), and `fields` keeps
    ///   the fields appended before.
    @inlinable
    public mutating func decode(_ section: RawSpan, stream: UInt64, into fields: inout HTTPFieldStore) throws(QPACKError) -> Bool {
        guard try begin(section, stream: stream) else { return false }
        var failure: QPACKError?
        while let field = try next(in: section) {
            if !field.hasValidCharacters, !Self.hasValidCharacters(field.name, field.value, isKnown: field.knownName != nil) {
                failure = .malformedField
                break
            }
            do throws(HTTPFieldError) {
                try fields.append(field.view, flags: field.flags)
            } catch {
                failure = error == .tooLarge ? .fieldSectionTooLarge : .malformedField
                break
            }
        }
        if let failure {
            offset = 0
            throw failure
        }
        return true
    }

    /// Whether a field's characters are valid for HTTP/3 (RFC 9114 §4.2): a known name, or a lowercase token (after a
    /// pseudo-header field's colon); a value without NUL, CR, or LF, or whitespace at its ends.
    @inlinable
    static func hasValidCharacters(_ name: RawSpan, _ value: RawSpan, isKnown: Bool) -> Bool {
        guard HTTPFieldSectionValidator.isValidValue(value) else { return false }
        if isKnown { return true }
        if name.byteCount > 1, name.load(fromByteOffset: 0, as: UInt8.self) == 0x3A {
            return HTTPFieldSectionValidator.isValidRegularName(name.extracting(droppingFirst: 1))
        }
        return HTTPFieldSectionValidator.isValidRegularName(name)
    }

    /// Abandons the section being decoded, if any (``next(in:)`` hasn't returned `nil`), queuing nothing: when its
    /// stream is reset, follow with ``cancelStream(_:)``.
    @inlinable
    public mutating func abandonSection() {
        offset = 0
    }

    /// The next stream whose blocked section can now be decoded (the inserts it needs have arrived), forgotten as blocked;
    /// `nil` if there's none.
    public mutating func nextUnblockedStream() -> UInt64? {
        for index in blocked.indices where blocked[index].required <= table.inserted {
            return blocked.remove(at: index).stream
        }
        return nil
    }

    /// Stops tracking a stream that was reset or abandoned (RFC 9204 §4.4.2): forgets it if it was blocked, abandons its
    /// section if it's being decoded, and queues a Stream Cancellation (unless the dynamic table can't be used: a
    /// maximum capacity of 0).
    ///
    /// - Throws: ``QPACKError/decoderStreamFull`` (nothing changed: write the decoder's instructions and call again).
    public mutating func cancelStream(_ stream: UInt64) throws(QPACKError) {
        let abandons = offset > 0 && self.stream == stream
        if maximumTableCapacity > 0 {
            // Room for this and for the acknowledgment a section in progress (another stream's) will need.
            let reserved = offset > 0 && !abandons && requiredInsertCount > 0 ? 10 : 0
            guard instructionCapacity &- instructionCount &- reserved >= 10 else { throw .decoderStreamFull }
        }
        if abandons { offset = 0 }
        for index in blocked.indices where blocked[index].stream == stream {
            _ = blocked.remove(at: index)
            break
        }
        guard maximumTableCapacity > 0 else { return }
        _ = queueInstruction(Int(truncatingIfNeeded: stream), mask: 0x3F, flags: 0x40)
    }

    /// Writes the decoder stream's pending instructions to `output` (as many bytes as fit; the rest stay queued): the
    /// queued Section Acknowledgments and Stream Cancellations, then, once all of those are written, an Insert Count
    /// Increment for inserts not yet acknowledged (RFC 9204 §4.4.3), if it fits.
    public mutating func writeDecoderInstructions(into output: inout OutputRawSpan) {
        let increment = table.inserted &- knownReceivedCount
        guard instructionCount > 0 || increment > 0 else { return }
        var incremented = false
        let written = unsafe output.withUnsafeMutableBytes { target, initialized in
            // Unsafe: copies queued bytes into the output's free memory, within its count, then writes the increment
            // within the rest, and reports what was written as initialized.
            let n = unsafe withFreeBytes(target, from: initialized) { base, capacity in
                let n = Swift.min(capacity, instructionCount)
                unsafe base.update(from: instructions, count: n)
                // After the queued acknowledgments, whose Required Insert Counts it counts on (`knownReceivedCount`).
                guard n == instructionCount, increment > 0 else { return n }
                let m = unsafe writePrefixInteger(increment, mask: 0x3F, flags: 0, base + n, capacity &- n)
                guard m > 0 else { return n }
                incremented = true
                return n &+ m
            }
            initialized &+= n
            return n
        }
        if incremented {
            // Every queued byte was written, then the increment.
            instructionCount = 0
            knownReceivedCount = table.inserted
        } else if written > 0 {
            // Unsafe: moves the unwritten rest to the front, within the buffer's `instructionCount` initialized bytes.
            unsafe instructions.update(from: instructions + written, count: instructionCount &- written)
            instructionCount &-= written
        }
    }

    /// Appends a prefix integer to the decoder stream's queue: whether it fit (10 bytes of room always do).
    @usableFromInline
    mutating func queueInstruction(_ value: Int, mask: Int, flags: UInt8) -> Bool {
        // Unsafe: writes at most the room past the queued ones, and reports what it wrote (0: nothing, it didn't fit).
        let n = unsafe writePrefixInteger(value, mask: mask, flags: flags, instructions + instructionCount, instructionCapacity &- instructionCount)
        guard n > 0 else { return false }
        instructionCount &+= n
        return true
    }

    // MARK: - The steps

    /// Reads a section's prefix: 0 ready, 1 blocked, or an error's code. A section in progress is untouched unless this
    /// one is ready, or the prefix is an error other than `decoderStreamFull` (a connection error: then none is).
    @usableFromInline
    mutating func beginSection(_ base: UnsafePointer<UInt8>?, _ count: Int, stream: UInt64) -> Int {
        let status = unsafe readSectionPrefix(base, count, stream: stream)
        if status > 1, status != Int(QPACKError.decoderStreamFull.code) { offset = 0 }
        return status
    }

    @inline(__always)
    mutating func readSectionPrefix(_ base: UnsafePointer<UInt8>?, _ count: Int, stream: UInt64) -> Int {
        guard count >= 2, let base = unsafe base else { return Int(QPACKError.truncated.code) }
        var position = 0
        // Required Insert Count (§4.5.1.1), an 8-bit prefix.
        var encoded = Int(unsafe base[0])
        if encoded == 0xFF {
            encoded = unsafe readPrefixInteger62Continuation(base, count, &position, 0xFF)
            if encoded < 0 { return Int((encoded == prefixIntegerTruncated ? QPACKError.truncated : .integerOverflow).code) }
        } else {
            position = 1
        }
        guard position < count else { return Int(QPACKError.truncated.code) }
        // Unsafe: an unchecked read. Safe: position < count.
        let signed = unsafe base[position] & 0x80 != 0
        var delta = Int(unsafe base[position] & 0x7F)
        if delta == 0x7F {
            delta = unsafe readPrefixInteger62Continuation(base, count, &position, 0x7F)
            if delta < 0 { return Int((delta == prefixIntegerTruncated ? QPACKError.truncated : .integerOverflow).code) }
        } else {
            position &+= 1
        }
        var required = 0
        if encoded != 0 {
            let fullRange = 2 &* maximumEntries
            guard encoded <= fullRange else { return Int(QPACKError.invalidRequiredInsertCount.code) }
            let maximumValue = table.inserted &+ maximumEntries
            let maximumWrapped = maximumValue / fullRange &* fullRange
            required = maximumWrapped &+ encoded &- 1
            if required > maximumValue {
                guard required > fullRange else { return Int(QPACKError.invalidRequiredInsertCount.code) }
                required &-= fullRange
            }
            guard required > 0 else { return Int(QPACKError.invalidRequiredInsertCount.code) }
        }
        // Base (§4.5.1.2).
        let sectionBase: Int
        if signed {
            guard delta < required else { return Int(QPACKError.invalidBase.code) }
            sectionBase = required &- delta &- 1
        } else {
            sectionBase = required &+ delta
        }
        if required > table.inserted {
            for index in blocked.indices where blocked[index].stream == stream {
                // Already blocked (begun again early): it waits for the same inserts.
                return 1
            }
            guard blocked.count < maximumBlockedStreams else { return Int(QPACKError.tooManyBlockedStreams.code) }
            // Within the list's capacity (checked just above).
            blocked.append(QPACKBlockedStream(stream: stream, required: required))
            return 1
        }
        // Room for the Section Acknowledgment `endSection` will queue (none needed without dynamic references).
        if required > 0, instructionCapacity &- instructionCount < 10 { return Int(QPACKError.decoderStreamFull.code) }
        if !blocked.isEmpty {
            for index in blocked.indices where blocked[index].stream == stream {
                _ = blocked.remove(at: index)
                break
            }
        }
        requiredInsertCount = required
        self.base = sectionBase
        largestReference = -1
        sectionSize = 0
        self.stream = stream
        // The offset is past the prefix, at least 2: nonzero means begun.
        offset = position
        return 0
    }

    /// Ends the section: checks its Required Insert Count was the one it needed, queues its acknowledgment.
    @inline(__always)
    mutating func endSection() -> QPACKDecodedField {
        if requiredInsertCount > 0 {
            guard largestReference &+ 1 == requiredInsertCount else { return fail(.invalidRequiredInsertCount) }
            // Section Acknowledgment (§4.4.1). `beginSection` made sure of the room, and nothing else queued takes it (an
            // Insert Count Increment isn't queued; `cancelStream` keeps it). Were it full anyway, the section stays at its
            // end, unacknowledged: the next call tries again.
            guard queueInstruction(Int(truncatingIfNeeded: stream), mask: 0x7F, flags: 0x80) else {
                return QPACKDecodedField(error: .decoderStreamFull)
            }
            if requiredInsertCount > knownReceivedCount { knownReceivedCount = requiredInsertCount }
        }
        offset = 0
        return QPACKDecodedField(status: QPACKDecodedField.end)
    }

    /// Fails: the section is abandoned.
    @inline(__always)
    mutating func fail(_ error: QPACKError) -> QPACKDecodedField {
        offset = 0
        return QPACKDecodedField(error: error)
    }

    /// The entry at absolute index `index` for a field line: it must be below the Required Insert Count and still in the
    /// table. Returns its number, or -1.
    @inline(__always)
    mutating func reference(_ index: Int) -> Int {
        guard index >= table.oldest, index < requiredInsertCount else { return -1 }
        if index > largestReference { largestReference = index }
        return index
    }

    /// Decodes the field line at `offset`.
    @usableFromInline
    mutating func decodeNext(_ base: UnsafePointer<UInt8>?, _ count: Int) -> QPACKDecodedField {
        let position = offset
        guard position > 0 else { return QPACKDecodedField(error: .sectionNotBegun) }
        guard position < count, let base = unsafe base else {
            return position == count ? endSection() : fail(.truncated)
        }
        // Unsafe: an unchecked read. Safe: position < count.
        let first = Int(unsafe base[position])
        if first >= 0x80 {
            // Indexed field line (§4.5.2): 1 T index(6).
            var index = first & 0x3F
            var next = position
            if index == 0x3F {
                index = unsafe readPrefixInteger62Continuation(base, count, &next, 0x3F)
                if index < 0 { return fail(index == prefixIntegerTruncated ? .truncated : .integerOverflow) }
            } else {
                next &+= 1
            }
            let field: QPACKDecodedField
            if first & 0x40 != 0 {
                guard index < 99 else { return fail(.invalidIndex) }
                let entry = statics[index]
                field = unsafe QPACKDecodedField(
                    name: entry.name, nameCount: Int(entry.nameCount), value: entry.value, valueCount: Int(entry.valueCount),
                    knownName: entry.knownName, characters: 3, status: QPACKDecodedField.field
                )
            } else {
                guard index < self.base else { return fail(.invalidIndex) }
                let number = reference(self.base &- 1 &- index)
                guard number >= 0 else { return fail(.invalidIndex) }
                field = dynamicField(number)
            }
            offset = next
            return account(field)
        }
        if first >= 0x40 {
            // Literal field line with name reference (§4.5.4): 01 N T index(4).
            return unsafe literal(base, count, position, first, nameReference: first & 0x10 != 0 ? 1 : 0, mask: 0x0F,
                                  neverIndexed: first & 0x20 != 0)
        }
        if first >= 0x20 {
            // Literal field line with literal name (§4.5.6): 001 N H length(3).
            return unsafe literal(base, count, position, first, nameReference: 3, mask: 0x07, neverIndexed: first & 0x10 != 0)
        }
        if first >= 0x10 {
            // Indexed field line with post-base index (§4.5.3): 0001 index(4).
            var index = first & 0x0F
            var next = position
            if index == 0x0F {
                index = unsafe readPrefixInteger62Continuation(base, count, &next, 0x0F)
                if index < 0 { return fail(index == prefixIntegerTruncated ? .truncated : .integerOverflow) }
            } else {
                next &+= 1
            }
            let number = reference(self.base &+ index)
            guard number >= 0 else { return fail(.invalidIndex) }
            offset = next
            return account(dynamicField(number))
        }
        // Literal field line with post-base name reference (§4.5.5): 0000 N index(3).
        return unsafe literal(base, count, position, first, nameReference: 2, mask: 0x07, neverIndexed: first & 0x08 != 0)
    }

    /// A dynamic entry as a field.
    @inline(__always)
    func dynamicField(_ number: Int) -> QPACKDecodedField {
        let entry = table.entry(number: number)
        return unsafe QPACKDecodedField(
            name: table.address(Int(entry.offset)), nameCount: Int(entry.nameCount),
            value: table.address(entry.valueOffset), valueCount: Int(entry.valueCount),
            knownName: entry.knownName, characters: entry.flags, status: QPACKDecodedField.field
        )
    }

    /// A literal field line at `start`, whose first byte is `first`: its name a static reference (`nameReference` 1), a
    /// dynamic one (0), a post-base one (2), or a literal (3) whose length has the 3-bit prefix and H at 0x08.
    @inline(always)
    mutating func literal(_ base: UnsafePointer<UInt8>, _ count: Int, _ start: Int, _ first: Int, nameReference: Int, mask: Int,
                          neverIndexed: Bool) -> QPACKDecodedField {
        var position = start
        // Constants set once on every path: a `var` assigned in branches and borrowed by a span was heap-boxed (a
        // `swift_allocObject` per literal; AGENTS.md).
        let name: UnsafeRawPointer
        let nameCount: Int
        let known: UInt8
        var characters: UInt8
        let used: Int
        if nameReference == 3 {
            let string = unsafe self.string(base, count, &position, mask: mask, scratchOffset: 0)
            if string.status != 0 { return fail(QPACKError(code: string.status)) }
            let address = unsafe string.address.unsafelyUnwrapped
            unsafe name = address
            nameCount = string.count
            used = string.coding == HPACKDecodedStringCoding.raw ? 0 : string.count
            // Unsafe: a span over the name just decoded, used only for the lookup.
            let span = unsafe RawSpan(_unsafeStart: address, byteCount: string.count)
            if let found = HTTPFieldName(lowercase: span) {
                known = found.index
                characters = DynamicFieldTableEntry.nameIsValid
            } else {
                known = 0xFF
                characters = HTTPFieldSectionValidator.isValidRegularName(span) ? DynamicFieldTableEntry.nameIsValid : 0
            }
        } else {
            used = 0
            var index = first & mask
            if index == mask {
                index = unsafe readPrefixInteger62Continuation(base, count, &position, mask)
                if index < 0 { return fail(index == prefixIntegerTruncated ? .truncated : .integerOverflow) }
            } else {
                position &+= 1
            }
            if nameReference == 1 {
                guard index < 99 else { return fail(.invalidIndex) }
                let entry = statics[index]
                known = entry.knownName
                unsafe name = entry.name
                nameCount = Int(entry.nameCount)
                characters = DynamicFieldTableEntry.nameIsValid
            } else {
                let number: Int
                if nameReference == 0 {
                    guard index < self.base else { return fail(.invalidIndex) }
                    number = reference(self.base &- 1 &- index)
                } else {
                    number = reference(self.base &+ index)
                }
                guard number >= 0 else { return fail(.invalidIndex) }
                let entry = table.entry(number: number)
                known = entry.knownName
                unsafe name = table.address(Int(entry.offset))
                nameCount = Int(entry.nameCount)
                characters = entry.flags & DynamicFieldTableEntry.nameIsValid
            }
        }
        let value = unsafe string(base, count, &position, mask: 0x7F, scratchOffset: used)
        if value.status != 0 { return fail(QPACKError(code: value.status)) }
        offset = position
        let address = unsafe value.address.unsafelyUnwrapped
        if unsafe Self.isValidValue(address, value.count, coding: value.coding) {
            characters |= DynamicFieldTableEntry.valueIsValid
        }
        return account(unsafe QPACKDecodedField(
            name: name, nameCount: nameCount, value: address, valueCount: value.count, knownName: known,
            characters: characters, status: neverIndexed ? QPACKDecodedField.neverIndexedField : QPACKDecodedField.field
        ))
    }

    /// Adds a field to the section's size, failing past the limit.
    @inline(__always)
    mutating func account(_ field: QPACKDecodedField) -> QPACKDecodedField {
        sectionSize &+= field.nameCount &+ field.valueCount &+ 32
        if sectionSize > maximumFieldSectionSize { return fail(.fieldSectionTooLarge) }
        return field
    }

    /// Whether a value's characters are valid (RFC 9114 §4.2): for a Huffman-coded one, the decoder said whether it had
    /// NUL, LF, or CR, so only its ends are checked; a raw one is scanned.
    @inline(__always)
    static func isValidValue(_ value: UnsafeRawPointer, _ count: Int, coding: UInt8) -> Bool {
        if coding == HPACKDecodedStringCoding.raw {
            // Unsafe: a span over the value (in the section or the stream), `count` bytes, used only for the check.
            return unsafe HTTPFieldSectionValidator.isValidValue(RawSpan(_unsafeStart: value, byteCount: count))
        }
        guard coding == HPACKDecodedStringCoding.huffman else { return false }
        guard count > 0 else { return true }
        // Unsafe: the value's first and last bytes. Safe: count > 0.
        let first = unsafe value.load(as: UInt8.self), last = unsafe value.load(fromByteOffset: count &- 1, as: UInt8.self)
        return first != 0x20 && first != 0x09 && last != 0x20 && last != 0x09
    }

    /// A string literal (RFC 9204 §4.1.2) at `position` with a `mask` length prefix (H at `mask + 1`), moved past: raw,
    /// its address in the bytes; Huffman-coded, decoded into the scratch buffer at `scratchOffset`. Status 0 or an error's
    /// code (``QPACKError/fieldSectionTooLarge`` past the scratch's limit; ``QPACKError/truncated`` when the bytes end).
    @inline(__always)
    func string(_ base: UnsafePointer<UInt8>, _ count: Int, _ position: inout Int, mask: Int, scratchOffset: Int)
        -> QPACKDecodedString {
        guard position < count else { return unsafe QPACKDecodedString(nil, 0, QPACKError.truncated.code) }
        // Unsafe: an unchecked read. Safe: position < count.
        let first = Int(unsafe base[position])
        var length = first & mask
        if length == mask {
            length = unsafe readPrefixInteger62Continuation(base, count, &position, mask)
            if length < 0 {
                return unsafe QPACKDecodedString(nil, 0, (length == prefixIntegerTruncated ? QPACKError.truncated : .integerOverflow).code)
            }
        } else {
            position &+= 1
        }
        guard length <= count &- position else { return unsafe QPACKDecodedString(nil, 0, QPACKError.truncated.code) }
        // Unsafe: the string's address in the bytes. Safe: `length` bytes from `position` are within them (checked).
        let start = unsafe UnsafeRawPointer(base + position)
        position &+= length
        if first & (mask &+ 1) == 0 {
            guard length <= scratchLimit else { return unsafe QPACKDecodedString(nil, 0, QPACKError.fieldSectionTooLarge.code) }
            return unsafe QPACKDecodedString(start, length, 0)
        }
        // Unsafe: decodes into the scratch buffer from `scratchOffset`, with its room (the limit and 16 bytes more,
        // allocated) as the capacity.
        let room = scratchLimit &+ 16 &- scratchOffset
        let output = unsafe (scratch + scratchOffset).assumingMemoryBound(to: UInt8.self)
        let result = unsafe huffmanDecode(input: start, inputCount: length, output: output, capacity: room)
        if result == huffmanInvalid { return unsafe QPACKDecodedString(nil, 0, QPACKError.invalidHuffmanCode.code) }
        let decoded = result & (huffmanForbiddenCharacters &- 1)
        if result < 0 || decoded > scratchLimit &- scratchOffset {
            return unsafe QPACKDecodedString(nil, 0, QPACKError.fieldSectionTooLarge.code)
        }
        var string = unsafe QPACKDecodedString(UnsafeRawPointer(output), decoded, 0)
        string.coding = result >= huffmanForbiddenCharacters ? HPACKDecodedStringCoding.huffmanWithForbidden : HPACKDecodedStringCoding.huffman
        return string
    }

    // MARK: - The encoder stream

    /// Applies the peer's encoder stream instructions in `bytes` (RFC 9204 §4.3), as many as are complete.
    ///
    /// - Returns: The bytes used: pass the rest again, followed by the stream's next bytes. Then
    ///   ``nextUnblockedStream()`` names streams whose sections can now be decoded.
    /// - Throws: ``QPACKError/invalidEncoderInstruction``, ``QPACKError/tableCapacityTooLarge``, or
    ///   ``QPACKError/entryTooLarge``: QPACK_ENCODER_STREAM_ERROR. Instructions before the bad one were applied.
    @inlinable
    public mutating func processEncoderStream(_ bytes: RawSpan) throws(QPACKError) -> Int {
        let result = bytes.withUnsafeBytes { buffer in
            // Unsafe: the stream's own bytes, read within their count.
            unsafe applyInstructions(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count)
        }
        if result < 0 { throw QPACKError(code: UInt8(truncatingIfNeeded: -result)) }
        return result
    }

    /// Applies complete instructions: the bytes used, or minus an error's code.
    @usableFromInline
    mutating func applyInstructions(_ base: UnsafePointer<UInt8>?, _ count: Int) -> Int {
        guard let base = unsafe base else { return 0 }
        var used = 0
        while used < count {
            let result = unsafe applyInstruction(base, count, used)
            if result <= 0 { return result < 0 ? result : used }
            used = result
        }
        return used
    }

    /// Applies the instruction at `start`: the offset past it, 0 if it's incomplete, or minus an error's code.
    @inline(__always)
    mutating func applyInstruction(_ base: UnsafePointer<UInt8>, _ count: Int, _ start: Int) -> Int {
        let invalid = -Int(QPACKError.invalidEncoderInstruction.code)
        // Unsafe: an unchecked read. Safe: the caller checked start < count.
        let first = Int(unsafe base[start])
        var position = start
        if first < 0x40 {
            let value = unsafe Self.integer(base, count, &position, first, mask: 0x1F)
            if value < 0 { return value == prefixIntegerTruncated ? 0 : invalid }
            if first >= 0x20 {
                // Set Dynamic Table Capacity (§4.3.1): 001 capacity(5).
                guard value <= maximumTableCapacity else { return -Int(QPACKError.tableCapacityTooLarge.code) }
                table.setMaximumSize(value)
                return position
            }
            // Duplicate (§4.3.4): 000 index(5).
            guard value < table.inserted, table.inserted &- 1 &- value >= table.oldest else { return invalid }
            let entry = table.entry(number: table.inserted &- 1 &- value)
            guard entry.size <= table.maximumSize else { return -Int(QPACKError.entryTooLarge.code) }
            // Unsafe: the entry's own bytes, name then value, which `insert` moves together.
            _ = unsafe table.insert(
                name: table.address(Int(entry.offset)), nameCount: Int(entry.nameCount), knownName: entry.knownName,
                value: table.address(entry.valueOffset), valueCount: Int(entry.valueCount), flags: entry.flags
            )
            return position
        }
        var name: UnsafeRawPointer?
        var nameCount: Int
        var known: UInt8
        var characters: UInt8
        var used = 0
        if first >= 0x80 {
            // Insert with name reference (§4.3.2): 1 T index(6), then the value.
            let index = unsafe Self.integer(base, count, &position, first, mask: 0x3F)
            if index < 0 { return index == prefixIntegerTruncated ? 0 : invalid }
            if first & 0x40 != 0 {
                guard index < 99 else { return invalid }
                let entry = statics[index]
                unsafe name = entry.name
                nameCount = Int(entry.nameCount)
                known = entry.knownName
                characters = DynamicFieldTableEntry.nameIsValid
            } else {
                guard index < table.inserted, table.inserted &- 1 &- index >= table.oldest else { return invalid }
                let entry = table.entry(number: table.inserted &- 1 &- index)
                unsafe name = table.address(Int(entry.offset))
                nameCount = Int(entry.nameCount)
                known = entry.knownName
                characters = entry.flags & DynamicFieldTableEntry.nameIsValid
            }
        } else {
            // Insert with literal name (§4.3.3): 01 H length(5) name, then the value. The whole instruction must be here
            // before the name is decoded and looked up: otherwise an instruction arriving a byte at a time would have its
            // name decoded again on every call (quadratic in its length).
            var end = position
            let leastName = unsafe Self.skipInstructionString(base, count, &end, mask: 0x1F, known: 0, capacity: table.maximumSize)
            if leastName < 0 { return leastName == -1 ? 0 : leastName }
            let leastValue = unsafe Self.skipInstructionString(base, count, &end, mask: 0x7F, known: leastName, capacity: table.maximumSize)
            if leastValue < 0 { return leastValue == -1 ? 0 : leastValue }
            let string = unsafe instructionString(base, count, &position, mask: 0x1F, scratchOffset: 0, known: 0)
            if string.status != 0 { return string.status == 1 ? 0 : -Int(string.status) }
            unsafe name = string.address
            nameCount = string.count
            used = string.coding == HPACKDecodedStringCoding.raw ? 0 : nameCount
            // Unsafe: a span over the name just decoded, used only for the lookup and check.
            let span = unsafe RawSpan(_unsafeStart: string.address.unsafelyUnwrapped, byteCount: nameCount)
            if let found = HTTPFieldName(lowercase: span) {
                known = found.index
                characters = DynamicFieldTableEntry.nameIsValid
            } else {
                known = 0xFF
                characters = HTTPFieldSectionValidator.isValidRegularName(span) ? DynamicFieldTableEntry.nameIsValid : 0
            }
        }
        let value = unsafe instructionString(base, count, &position, mask: 0x7F, scratchOffset: used, known: nameCount)
        if value.status != 0 { return value.status == 1 ? 0 : -Int(value.status) }
        guard nameCount &+ value.count &+ 32 <= table.maximumSize else { return -Int(QPACKError.entryTooLarge.code) }
        // Unsafe: the value's address (in the stream's bytes or the scratch buffer), `count` bytes.
        if unsafe Self.isValidValue(value.address.unsafelyUnwrapped, value.count, coding: value.coding) {
            characters |= DynamicFieldTableEntry.valueIsValid
        }
        _ = unsafe table.insert(name: name, nameCount: nameCount, knownName: known, value: value.address, valueCount: value.count,
                                flags: characters)
        return position
    }

    /// A prefix integer at `position`, whose first byte is `first`, moved past: its value, `prefixIntegerTruncated`, or
    /// `prefixIntegerOverflow`.
    @inline(__always)
    static func integer(_ base: UnsafePointer<UInt8>, _ count: Int, _ position: inout Int, _ first: Int, mask: Int) -> Int {
        let value = first & mask
        guard value == mask else {
            position &+= 1
            return value
        }
        return unsafe readPrefixInteger62Continuation(base, count, &position, mask)
    }

    /// An encoder instruction's string: as `string(_:_:_:mask:scratchOffset:)`, but status 1 when the bytes end first
    /// (the instruction is incomplete), and ``QPACKError/entryTooLarge`` as soon as the length (with `known` bytes of the
    /// entry already counted) shows the entry can't fit the table, so an incomplete instruction is never held longer than
    /// about four times the capacity.
    @inline(__always)
    func instructionString(_ base: UnsafePointer<UInt8>, _ count: Int, _ position: inout Int, mask: Int, scratchOffset: Int,
                           known: Int) -> QPACKDecodedString {
        guard position < count else { return unsafe QPACKDecodedString(nil, 0, 1) }
        // Unsafe: an unchecked read. Safe: position < count.
        let first = Int(unsafe base[position])
        var length = first & mask
        if length == mask {
            length = unsafe readPrefixInteger62Continuation(base, count, &position, mask)
            if length < 0 {
                return unsafe QPACKDecodedString(nil, 0, length == prefixIntegerTruncated ? 1 : QPACKError.invalidEncoderInstruction.code)
            }
        } else {
            position &+= 1
        }
        let huffman = first & (mask &+ 1) != 0
        let least = Self.leastDecodedCount(length, huffman: huffman)
        guard known &+ least &+ 32 <= table.maximumSize else { return unsafe QPACKDecodedString(nil, 0, QPACKError.entryTooLarge.code) }
        guard length <= count &- position else { return unsafe QPACKDecodedString(nil, 0, 1) }
        // Unsafe: the string's address in the bytes. Safe: `length` bytes from `position` are within them (checked).
        let start = unsafe UnsafeRawPointer(base + position)
        position &+= length
        if !huffman { return unsafe QPACKDecodedString(start, length, 0) }
        // Unsafe: decodes into the scratch buffer from `scratchOffset`, within its room (as in `string`).
        let room = scratchLimit &+ 16 &- scratchOffset
        let output = unsafe (scratch + scratchOffset).assumingMemoryBound(to: UInt8.self)
        let result = unsafe huffmanDecode(input: start, inputCount: length, output: output, capacity: room)
        if result == huffmanInvalid { return unsafe QPACKDecodedString(nil, 0, QPACKError.invalidEncoderInstruction.code) }
        let decoded = result & (huffmanForbiddenCharacters &- 1)
        if result < 0 || decoded > scratchLimit &- scratchOffset {
            return unsafe QPACKDecodedString(nil, 0, QPACKError.entryTooLarge.code)
        }
        var string = unsafe QPACKDecodedString(UnsafeRawPointer(output), decoded, 0)
        string.coding = result >= huffmanForbiddenCharacters ? HPACKDecodedStringCoding.huffmanWithForbidden : HPACKDecodedStringCoding.huffman
        return string
    }

    /// The fewest bytes a string of `length` bytes can decode to: all of them raw; Huffman-coded, at least a quarter
    /// less one (codes are at most 30 bits, and up to 7 bits are padding). No overflow for any 62-bit length.
    @inline(__always)
    static func leastDecodedCount(_ length: Int, huffman: Bool) -> Int {
        huffman ? Swift.max((length &>> 2) &- 1, 0) : length
    }

    /// Moves `position` past an encoder instruction's string without decoding it: the fewest bytes it can decode to
    /// (``leastDecodedCount(_:huffman:)``), -1 if the bytes end first, or minus an error's code (as
    /// `instructionString(_:_:_:mask:scratchOffset:known:)`: ``QPACKError/entryTooLarge`` as soon as the length shows
    /// the entry, with `known` bytes already counted, can't fit a table of `capacity`).
    @inline(__always)
    static func skipInstructionString(_ base: UnsafePointer<UInt8>, _ count: Int, _ position: inout Int, mask: Int, known: Int,
                                      capacity: Int) -> Int {
        guard position < count else { return -1 }
        // Unsafe: an unchecked read. Safe: position < count.
        let first = Int(unsafe base[position])
        var length = first & mask
        if length == mask {
            length = unsafe readPrefixInteger62Continuation(base, count, &position, mask)
            if length < 0 { return length == prefixIntegerTruncated ? -1 : -Int(QPACKError.invalidEncoderInstruction.code) }
        } else {
            position &+= 1
        }
        let least = leastDecodedCount(length, huffman: first & (mask &+ 1) != 0)
        guard known &+ least &+ 32 <= capacity else { return -Int(QPACKError.entryTooLarge.code) }
        guard length <= count &- position else { return -1 }
        position &+= length
        return least
    }
}

/// How a string literal was sent: `raw`, `huffman`, or `huffmanWithForbidden` (the decoded bytes have NUL, LF, or CR: the
/// Huffman decoder says).
@usableFromInline
enum HPACKDecodedStringCoding {
    @inlinable static var raw: UInt8 { 0 }
    @inlinable static var huffman: UInt8 { 1 }
    @inlinable static var huffmanWithForbidden: UInt8 { 2 }
}

/// A string literal as the decoder's step found it: its address (in the bytes, or the scratch buffer) and length, a
/// status (0, or an error's code), and its coding.
@frozen @usableFromInline @safe
struct QPACKDecodedString {
    @usableFromInline var address: UnsafeRawPointer?
    @usableFromInline var count: Int
    @usableFromInline var status: UInt8
    @usableFromInline var coding: UInt8 = 0

    @inlinable @inline(__always)
    init(_ address: UnsafeRawPointer?, _ count: Int, _ status: UInt8) {
        unsafe self.address = address
        self.count = count
        self.status = status
    }
}

/// A stream whose field section is blocked, and the Required Insert Count it waits for.
@frozen @usableFromInline
struct QPACKBlockedStream: Sendable {
    @usableFromInline let stream: UInt64
    @usableFromInline let required: Int

    @inlinable @inline(__always)
    init(stream: UInt64, required: Int) {
        self.stream = stream
        self.required = required
    }
}

// A decoder owns its memory alone (it's noncopyable), so moving it to another task is safe. (`@unchecked` for the
// scratch and decoder stream buffers, which the pointer decoders write through.)
extension QPACKDecoder: @unchecked Sendable {}
