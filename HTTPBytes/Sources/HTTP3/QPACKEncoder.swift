public import HTTPBytes

/// A QPACK encoder (RFC 9204): one per HTTP/3 connection, encoding this endpoint's field sections and writing its encoder
/// stream, and taking the peer's decoder stream.
///
/// ```swift
/// var encoder = QPACKEncoder()
/// encoder.setPeerSettings(maximumTableCapacity: settings.qpackMaxTableCapacity, blockedStreams: settings.qpackBlockedStreams)
/// try encoder.encode(fields, stream: streamID, into: &headersPayload, instructions: &encoderStreamOutput)
/// // The peer's decoder stream, as its bytes arrive (keep what isn't consumed):
/// let used = try encoder.processDecoderStream(decoderStreamBytes)
/// ```
///
/// **Static only** until ``setPeerSettings(maximumTableCapacity:blockedStreams:)`` gives a table (or when the encoder is
/// made with a capacity of 0): fields the static table has as an index, names it has as a name reference, the rest as
/// literals; the section's prefix is two zero bytes.
///
/// **With the dynamic table**, a field is an index when the static table or the dynamic table has it (a dynamic entry
/// only if the peer has acknowledged it, or the section may block); otherwise, if the indexing policy wants it (as
/// HPACK's: ``HTTPFieldIndexingStrategy``; the automatic one also waits until it has seen the field recently, since
/// unlike HPACK's an insertion costs its bytes again on the encoder stream) and room can be made by evicting entries that
/// are evictable (acknowledged and referenced by no unacknowledged section, RFC 9204 §2.1.1), it's inserted on the
/// encoder stream and, if the section may block, referenced right away with a post-base index (the section's Base is the
/// Insert Count when it began). A name the static table doesn't have, seen recently with other values, is inserted alone
/// for later fields' name references. A section may block while fewer sections that may block are unacknowledged than
/// the peer's SETTINGS_QPACK_BLOCKED_STREAMS. Entries are found through the same hash chains as HPACK's encoder
/// (``DynamicFieldIndex``).
///
/// **Draining** (RFC 9204 §2.1.1.1): the entries a quarter of the capacity's insertions would evict aren't name
/// references; a field one of them holds is duplicated to the table's front (Duplicate, §4.3.4) and the copy referred to
/// (or the old entry, acknowledged, if the section can't block), so the oldest entries stay free to evict and the
/// fields in use stay in the table. Against ls-qpack's encoder, which does the same, on http-corpus' 383 responses with
/// a 4,096-byte table: 53,137 B to its 53,087 (62,241 before).
///
/// **Acknowledgments.** ``processDecoderStream(_:)`` takes the peer's Section Acknowledgments, Stream Cancellations, and
/// Insert Count Increments. Each section that referred to the dynamic table is tracked until then, in a list made with
/// the encoder (``maximumUnacknowledgedSections``); while it's full, sections use the static table only.
///
/// **Strings** are Huffman-coded when that's shorter. Fields flagged ``HTTPFieldStore/neverIndexed`` are literals with
/// the N bit (their names may still be references). **Names** are written lowercase, as HTTP/3 requires (RFC 9114 §4.2)
/// whatever version a store's fields came from: a known name as ``HTTPFieldName/lowercaseBytes``, any other with its
/// ASCII letters lowercased, so an HTTP/1 spelling such as `X-Request-Id` goes out (and into the table) as `x-request-id`.
///
/// **Memory** is allocated when the encoder is made: the table (twice its capacity in bytes), the hash chains, each
/// entry's place among the insertions (for draining), the histories of fields and names seen, the unacknowledged
/// sections' list, and a scratch buffer for lowercasing names (grown only for a name longer than any before). Nothing
/// per section or field.
@safe
public struct QPACKEncoder: ~Copyable {
    @usableFromInline var table: DynamicFieldTable
    /// The static table, by address, and known names' static indexes.
    @usableFromInline let statics: StaticFieldEntries
    /// The dynamic table's hash chains.
    @usableFromInline let index: DynamicFieldIndex
    /// The peer's MaxEntries (its SETTINGS_QPACK_MAX_TABLE_CAPACITY / 32, RFC 9204 §4.5.1.1).
    @usableFromInline var peerMaximumEntries = 0
    /// The peer's SETTINGS_QPACK_BLOCKED_STREAMS.
    @usableFromInline var peerBlockedStreams = 0
    /// A Set Dynamic Table Capacity to send, or -1.
    @usableFromInline var pendingCapacity = -1
    /// The capacity the peer's settings allow (and this encoder's memory), restored by `reset()`.
    @usableFromInline var settledCapacity = 0
    /// The Known Received Count (RFC 9204 §2.1.4).
    @usableFromInline var knownReceivedCount = 0
    /// Unacknowledged sections that referred to the dynamic table, oldest first: stream, Required Insert Count, and the
    /// smallest absolute index referred to.
    @usableFromInline let sectionStreams: UnsafeMutablePointer<UInt64>
    @usableFromInline let sectionRequired: UnsafeMutablePointer<Int>
    @usableFromInline let sectionMinimum: UnsafeMutablePointer<Int>
    @usableFromInline var sectionCount = 0
    /// The automatic policy's memory of fields it has seen recently: their field hashes, in a direct-mapped table of about
    /// one slot per 64 bytes of capacity (as many as the table holds entries). A field is inserted the second time it's
    /// seen (ls-qpack's idea): inserting a value that never repeats costs its bytes on the encoder stream and evicts
    /// entries that would have been used.
    @usableFromInline let history: UnsafeMutablePointer<UInt64>
    /// The slots in use, less one: by the peer's capacity (the memory is for the encoder's).
    @usableFromInline var historyMask = 63
    /// Names seen recently in literals with a literal name (their name hashes), the same way: such a name is inserted
    /// alone (an empty value) the second time, and later fields refer to it.
    @usableFromInline let nameHistory: UnsafeMutablePointer<UInt64>
    /// Per table ring slot: the bytes inserted before the entry (its start among all insertions' bytes), which says how
    /// soon it will be evicted.
    @usableFromInline let entryStarts: UnsafeMutablePointer<Int>
    /// The bytes (entry sizes) inserted since the connection began.
    @usableFromInline var insertedBytes = 0
    /// How many bytes may be inserted after an entry's start before it's draining: three quarters of the capacity.
    @usableFromInline var drainingDistance = 0
    /// Entries numbered below this one are draining (RFC 9204 §2.1.1.1): a quarter of the capacity or less of insertions
    /// will evict them. New sections refer to a copy of a draining entry (Duplicate) when one can be made.
    @usableFromInline var drainingBelow = 0
    /// The most sections referring to the dynamic table that can be unacknowledged at once.
    public let maximumUnacknowledgedSections: Int
    /// Whether to Huffman-code strings (when shorter).
    public var usesHuffmanCoding = true
    /// Lowercased names (HTTP/1 spellings of names HTTPBytes doesn't know).
    @usableFromInline var lowercasing = FieldNameLowercasing()

    /// An encoder that uses a dynamic table of up to `maximumTableCapacity` bytes (less if the peer allows less), tracking
    /// up to `maximumUnacknowledgedSections` sections that refer to it. It encodes with the static table only until
    /// ``setPeerSettings(maximumTableCapacity:blockedStreams:)``.
    public init(maximumTableCapacity: Int = 4_096, maximumUnacknowledgedSections: Int = 128) {
        precondition(maximumUnacknowledgedSections >= 1, "at least one unacknowledged section")
        table = DynamicFieldTable(capacity: maximumTableCapacity)
        table.maximumSize = 0
        statics = StaticFieldEntries.qpack()
        index = DynamicFieldIndex(slots: table.entryMask &+ 1)
        self.maximumUnacknowledgedSections = maximumUnacknowledgedSections
        // Unsafe: allocations owned by this encoder, freed in `deinit`.
        unsafe sectionStreams = UnsafeMutablePointer<UInt64>.allocate(capacity: maximumUnacknowledgedSections)
        unsafe sectionRequired = UnsafeMutablePointer<Int>.allocate(capacity: maximumUnacknowledgedSections)
        unsafe sectionMinimum = UnsafeMutablePointer<Int>.allocate(capacity: maximumUnacknowledgedSections)
        let slots = Self.historySlots(capacity: table.capacity)
        unsafe history = UnsafeMutablePointer<UInt64>.allocate(capacity: slots)
        unsafe history.initialize(repeating: 0, count: slots)
        unsafe nameHistory = UnsafeMutablePointer<UInt64>.allocate(capacity: slots)
        unsafe nameHistory.initialize(repeating: 0, count: slots)
        unsafe entryStarts = UnsafeMutablePointer<Int>.allocate(capacity: table.entryMask &+ 1)
        unsafe entryStarts.initialize(repeating: 0, count: table.entryMask &+ 1)
    }

    /// The history's slots for a table capacity: one per 64 bytes, a power of two, at least 64. A longer memory inserts
    /// fields that recur too rarely to be used before they're evicted, a shorter one misses fields that do (383 responses,
    /// 4,096 bytes: 55,110 B with one slot per 32 bytes, 53,137 with one per 64; 16,384 bytes: 45,506, 46,053, and with
    /// one per 128, 46,959).
    static func historySlots(capacity: Int) -> Int {
        var slots = 64
        while slots < capacity / 64 { slots &<<= 1 }
        return slots
    }

    deinit {
        // Unsafe: frees this encoder's own allocations, which nothing else holds (the encoder is noncopyable).
        unsafe sectionStreams.deallocate()
        unsafe sectionRequired.deallocate()
        unsafe sectionMinimum.deallocate()
        unsafe history.deallocate()
        unsafe nameHistory.deallocate()
        unsafe entryStarts.deallocate()
    }

    /// Takes the peer's SETTINGS_QPACK_MAX_TABLE_CAPACITY and SETTINGS_QPACK_BLOCKED_STREAMS (once, before the table is
    /// used): the table's capacity becomes the smaller of the setting and what the encoder was made with, announced by a
    /// Set Dynamic Table Capacity at the start of the next encoder stream output.
    public mutating func setPeerSettings(maximumTableCapacity: UInt64, blockedStreams: UInt64) {
        precondition(table.inserted == 0, "the peer's settings come before the table is used")
        let capacity = Int(Swift.min(maximumTableCapacity, UInt64(table.capacity)))
        peerMaximumEntries = Int(Swift.min(maximumTableCapacity / 32, 1 << 40))
        peerBlockedStreams = Int(Swift.min(blockedStreams, 1 << 20))
        settledCapacity = capacity
        table.setMaximumSize(capacity)
        pendingCapacity = capacity > 0 ? capacity : -1
        drainingDistance = capacity &- capacity &>> 2
        historyMask = Self.historySlots(capacity: capacity) &- 1
    }

    /// Returns to a new connection's state with the same peer settings, keeping the memory: an empty table (its capacity
    /// announced again), nothing acknowledged or unacknowledged.
    public mutating func reset() {
        table.removeAllNumberingFromZero()
        index.removeAll()
        table.maximumSize = settledCapacity
        pendingCapacity = settledCapacity > 0 ? settledCapacity : -1
        knownReceivedCount = 0
        sectionCount = 0
        insertedBytes = 0
        drainingBelow = 0
        // Unsafe: writes the history's own `historyMask + 1` slots.
        unsafe history.update(repeating: 0, count: historyMask &+ 1)
        unsafe nameHistory.update(repeating: 0, count: historyMask &+ 1)
    }

    /// The dynamic table's size (RFC 9204 §3.2.1).
    @inlinable public var tableSize: Int { table.size }
    /// The dynamic table's capacity.
    @inlinable public var tableCapacity: Int { table.maximumSize }
    /// The number of dynamic table entries.
    @inlinable public var tableCount: Int { table.count }
    /// The Insert Count: entries inserted since the connection began.
    @inlinable public var insertCount: Int { table.inserted }
    /// The Known Received Count: entries the peer has acknowledged receiving.
    @inlinable public var acknowledgedInsertCount: Int { knownReceivedCount }
    /// Sections referring to the dynamic table that the peer hasn't acknowledged.
    @inlinable public var unacknowledgedSectionCount: Int { sectionCount }

    // MARK: - Encoding

    /// Encodes `fields` as stream `stream`'s field section, appending it to `section` (a HEADERS frame's payload), and
    /// any encoder stream instructions it needs to `instructions` (send them on the encoder stream: the section may refer
    /// to them). Each field is encoded with ``HTTPFieldIndexingStrategy/disable`` if it's flagged
    /// ``HTTPFieldStore/neverIndexed``, else `indexing`.
    ///
    /// - Throws: ``QPACKError/outputTooSmall`` if `section` fills: nothing is appended to it, but `instructions` keeps
    ///   what was written (send it; the table has those entries), and the section can be encoded again into more room.
    ///   When `instructions` fills, fields are sent as literals instead of being inserted; when it has no room for a
    ///   pending Set Dynamic Table Capacity, the section uses the static table only and the instruction stays pending.
    @inlinable
    public mutating func encode(_ fields: borrowing HTTPFieldStore, stream: UInt64, indexing: HTTPFieldIndexingStrategy = .automatic,
                                into section: inout OutputRawSpan, instructions: inout OutputRawSpan) throws(QPACKError) {
        let ok = unsafe section.withUnsafeMutableBytes { sectionTarget, sectionInitialized in
            unsafe instructions.withUnsafeMutableBytes { instructionTarget, instructionsInitialized in
                unsafe withFreeBytes(sectionTarget, from: sectionInitialized) { sectionBase, sectionCapacity in
                    unsafe withFreeBytes(instructionTarget, from: instructionsInitialized) { instructionBase, instructionCapacity in
                        // Unsafe: the outputs' free memory, written below their capacities by the cursors, which report
                        // their ends.
                        var lines = unsafe FieldEncoderOutput(sectionBase, sectionCapacity)
                        var encoderStream = unsafe FieldEncoderOutput(instructionBase, instructionCapacity)
                        // The table can be used once the peer has been told its capacity.
                        var state = beginSection(tableAnnounced: writePendingCapacity(&encoderStream))
                        var written = reservePrefix(&lines)
                        if written {
                            for position in 0..<fields.count {
                                let field = fields.field(at: position)
                                let strategy = fields.flags(at: position) & HTTPFieldStore.neverIndexed != 0 ? .disable : indexing
                                let ok = field.knownName == nil && FieldNameLowercasing.hasUppercase(field.name)
                                    ? encodeFieldLowercasing(field.name, field.value, strategy, &lines, &encoderStream, &state)
                                    // One call site: the field encoder is inlined once.
                                    : encodeField(field.name, field.value, field.knownName, strategy, &lines, &encoderStream, &state)
                                guard ok else {
                                    written = false
                                    break
                                }
                            }
                        }
                        instructionsInitialized &+= encoderStream.count
                        guard written, endSection(state, stream: stream, &lines) else { return -1 }
                        sectionInitialized &+= lines.count
                        return 0
                    }
                }
            }
        }
        if ok < 0 { throw .outputTooSmall }
    }

    // MARK: - The work, by pointer

    /// Writes a pending Set Dynamic Table Capacity.
    @inlinable @inline(__always)
    mutating func writePendingCapacity(_ output: inout FieldEncoderOutput) -> Bool {
        guard pendingCapacity >= 0 else { return true }
        guard output.integer(pendingCapacity, mask: 0x1F, flags: 0x20) else { return false }
        pendingCapacity = -1
        return true
    }

    /// Leaves room for the usual two-byte prefix (moved if the section's is longer).
    @inlinable @inline(__always)
    func reservePrefix(_ output: inout FieldEncoderOutput) -> Bool {
        guard output.capacity >= 2 else { return false }
        output.count = 2
        return true
    }

    /// A section's state: where it starts, what it may refer to (the dynamic table only once the peer knows its capacity:
    /// `tableAnnounced`).
    @inlinable @inline(__always)
    func beginSection(tableAnnounced: Bool) -> QPACKSectionState {
        let usesTable = tableAnnounced && table.maximumSize > 0 && sectionCount < maximumUnacknowledgedSections
        var blocking = 0
        if usesTable {
            for position in 0..<sectionCount where unsafe sectionRequired[position] > knownReceivedCount { blocking &+= 1 }
        }
        return QPACKSectionState(base: table.inserted, usesTable: usesTable, mayBlock: usesTable && blocking < peerBlockedStreams)
    }

    /// Writes the section's prefix (RFC 9204 §4.5.1) before its lines, and records it if it refers to the dynamic table.
    @usableFromInline
    mutating func endSection(_ state: QPACKSectionState, stream: UInt64, _ lines: inout FieldEncoderOutput) -> Bool {
        guard state.required > 0 else {
            // Unsafe: stores into the two bytes `reservePrefix` kept.
            unsafe lines.base[0] = 0
            unsafe lines.base[1] = 0
            return true
        }
        let encodedRequired = state.required % (2 &* peerMaximumEntries) &+ 1
        let signed = state.base < state.required
        let delta = signed ? state.required &- state.base &- 1 : state.base &- state.required
        let length = HPACKPrefixInteger.byteCount(of: encodedRequired, prefixBits: 8) &+ HPACKPrefixInteger.byteCount(of: delta, prefixBits: 7)
        if length != 2 {
            guard lines.count &- 2 &+ length <= lines.capacity else { return false }
            // Unsafe: moves the lines within the output, to end below its capacity (checked).
            unsafe (lines.base + length).update(from: lines.base + 2, count: lines.count &- 2)
            lines.count = lines.count &- 2 &+ length
        }
        // Unsafe: writes the prefix's `length` bytes at the start, room the lines were placed after.
        let first = unsafe writePrefixInteger(encodedRequired, mask: 0xFF, flags: 0, lines.base, length)
        _ = unsafe writePrefixInteger(delta, mask: 0x7F, flags: signed ? 0x80 : 0, lines.base + first, length &- first)
        // Unsafe: stores at sectionCount, below the lists' capacity (`beginSection` used the table only with room).
        unsafe sectionStreams[sectionCount] = stream
        unsafe sectionRequired[sectionCount] = state.required
        unsafe sectionMinimum[sectionCount] = state.minimum
        sectionCount &+= 1
        return true
    }

    /// Encodes a field whose name (one HTTPBytes doesn't know) has uppercase letters: lowercased into the scratch memory
    /// first. Out of line: HTTP/1 spellings of unknown names.
    @usableFromInline
    mutating func encodeFieldLowercasing(_ name: RawSpan, _ value: RawSpan, _ strategy: HTTPFieldIndexingStrategy,
                                         _ lines: inout FieldEncoderOutput, _ encoderStream: inout FieldEncoderOutput,
                                         _ state: inout QPACKSectionState) -> Bool {
        let lowered = unsafe lowercasing.lowercase(name)
        return value.withUnsafeBytes { value in
            // Unsafe: the lowercased name in the scratch memory (`name.byteCount` bytes, unchanged until the next field)
            // and the value's own bytes, read during the call; the table copies what it keeps.
            unsafe encodeField(name: lowered, nameCount: name.byteCount, value: value.baseAddress, valueCount: value.count,
                               knownName: 0xFF, strategy: strategy, &lines, &encoderStream, &state)
        }
    }

    /// Encodes one field. Spans to pointers here, once per field; the rest is `encodeField(name:…)`.
    @inlinable @inline(__always)
    mutating func encodeField(_ name: RawSpan, _ value: RawSpan, _ knownName: HTTPFieldName?, _ strategy: HTTPFieldIndexingStrategy,
                              _ lines: inout FieldEncoderOutput, _ encoderStream: inout FieldEncoderOutput,
                              _ state: inout QPACKSectionState) -> Bool {
        name.withUnsafeBytes { name in
            value.withUnsafeBytes { value in
                // Unsafe: the spans' own bytes, read within their counts during the call.
                unsafe encodeField(
                    name: name.baseAddress, nameCount: name.count, value: value.baseAddress, valueCount: value.count,
                    knownName: knownName?.index ?? 0xFF, strategy: strategy, &lines, &encoderStream, &state)
            }
        }
    }

    /// Encodes one field: a static or dynamic match as an index; else, if the policy says, an insertion and a reference
    /// to it; else a literal (its name a reference if a table has it).
    @usableFromInline
    mutating func encodeField(name: UnsafeRawPointer?, nameCount: Int, value: UnsafeRawPointer?, valueCount: Int,
                              knownName: UInt8, strategy: HTTPFieldIndexingStrategy, _ lines: inout FieldEncoderOutput,
                              _ encoderStream: inout FieldEncoderOutput, _ state: inout QPACKSectionState) -> Bool {
        let none = Int(statics.noIndex)
        let staticIndex = statics.index(ofName: knownName)
        let policy: Int
        switch strategy {
        case .disable: policy = 1
        case .avoid: policy = 2
        case .prefer: policy = 3
        case .automatic:
            policy = knownName == 0xFF ? 0 : HTTPFieldIndexingStrategy.automaticPolicy(HTTPFieldName(tableIndex: knownName), valueCount)
        }
        let neverIndexed = policy == 1
        // A whole match in the static table: the name's entries, by their chain.
        if !neverIndexed, staticIndex != none {
            var position = staticIndex
            repeat {
                let entry = statics[position]
                if Int(entry.valueCount) == valueCount, unsafe equalBytes(entry.value, value, valueCount) {
                    return lines.integer(position, mask: 0x3F, flags: 0xC0)
                }
                position = statics.next(afterIndex: position)
            } while position != none
        }
        guard state.usesTable else {
            return unsafe literal(name, nameCount, knownName, value, valueCount, staticIndex: staticIndex, nameEntry: -1, neverIndexed: neverIndexed,
                                  &lines, &state)
        }
        let nameHash = unsafe DynamicFieldIndex.nameHash(name, nameCount, knownName)
        var inTable = false
        if !neverIndexed {
            let fieldHash = unsafe DynamicFieldIndex.fieldHash(nameHash, value, valueCount)
            let number = unsafe index.fieldMatch(fieldHash, in: table, name, nameCount, knownName, value, valueCount)
            if number >= 0 {
                let usable = state.mayUse(number, acknowledged: knownReceivedCount)
                var reference = -1
                if number >= drainingBelow {
                    if usable { reference = number }
                } else if policy == 0 || policy == 3, usable || state.mayBlock {
                    // Draining (RFC 9204 §2.1.1.1): a copy at the table's front (Duplicate, §4.3.4) keeps the field, and the
                    // old entry can go. A section that may block refers to the copy; one that can't, to the old entry,
                    // acknowledged (referred to first, so making room for the copy can't evict it), the copy left for
                    // later sections.
                    if state.mayBlock {
                        reference = duplicate(number, state, &encoderStream)
                    } else {
                        state.refer(to: number)
                        _ = duplicate(number, state, &encoderStream)
                    }
                }
                // A draining entry that couldn't be copied (no room without evicting entries still referred to) is still
                // referred to if it may be: a literal instead measured larger in every setting (383 responses, 4,096
                // bytes, 16 sections in flight that may block: 53,631 → 69,736 B).
                if reference < 0, usable { reference = number }
                if reference >= 0 {
                    state.refer(to: reference)
                    return reference < state.base
                        ? lines.integer(state.base &- 1 &- reference, mask: 0x3F, flags: 0x80)
                        : lines.integer(reference &- state.base, mask: 0x0F, flags: 0x10)
                }
                // Inserted already but not usable yet: not inserted twice.
                inTable = true
            }
            let entrySize = nameCount &+ valueCount &+ 32
            let indexes = switch policy {
            case 3: true
            case 0: entrySize &* 4 <= table.maximumSize &* 3 && seenBefore(fieldHash)
            default: false
            }
            if indexes, !inTable, roomFor(entrySize, state) {
                let number = unsafe insert(name, nameCount, knownName, value, valueCount, staticIndex: staticIndex, nameHash: nameHash,
                                           fieldHash: fieldHash, &encoderStream)
                if number >= 0, state.mayBlock {
                    state.refer(to: number)
                    return lines.integer(number &- state.base, mask: 0x0F, flags: 0x10)
                }
            }
        }
        var nameEntry = -1
        if staticIndex == none {
            // A name reference only to an entry that isn't draining (one that is would keep it from being evicted).
            let number = unsafe index.nameMatch(nameHash, in: table, name, nameCount, knownName)
            if number >= drainingBelow, state.mayUse(number, acknowledged: knownReceivedCount) {
                nameEntry = number
            } else if !neverIndexed, policy == 0 || policy == 3, number < drainingBelow, nameSeenBefore(nameHash),
                      roomFor(nameCount &+ 32, state) {
                // A name seen recently whose values vary: inserted alone (ls-qpack's idea), for this field to refer to if
                // the section may block, and for later ones (383 responses, 4,096 bytes: lines with literal names went
                // from 157 in 9,960 B to 14 in 485 B).
                let inserted = unsafe insert(name, nameCount, knownName, nil, 0, staticIndex: none, nameHash: nameHash,
                                             fieldHash: DynamicFieldIndex.fieldHash(nameHash, nil, 0), &encoderStream)
                if inserted >= 0, state.mayBlock { nameEntry = inserted }
            }
        }
        return unsafe literal(name, nameCount, knownName, value, valueCount, staticIndex: staticIndex, nameEntry: nameEntry, neverIndexed: neverIndexed,
                              &lines, &state)
    }

    /// Writes a literal field line: the name a static reference, a dynamic one (`nameEntry`, usable), or a literal.
    @inlinable @inline(__always)
    func literal(_ name: UnsafeRawPointer?, _ nameCount: Int, _ knownName: UInt8, _ value: UnsafeRawPointer?, _ valueCount: Int, staticIndex: Int,
                 nameEntry: Int, neverIndexed: Bool, _ lines: inout FieldEncoderOutput, _ state: inout QPACKSectionState) -> Bool {
        let wrote: Bool
        if staticIndex != Int(statics.noIndex) {
            // 01 N T=1 index(4).
            wrote = lines.integer(staticIndex, mask: 0x0F, flags: neverIndexed ? 0x70 : 0x50)
        } else if nameEntry >= 0 {
            state.refer(to: nameEntry)
            wrote = nameEntry < state.base
                // 01 N T=0 index(4).
                ? lines.integer(state.base &- 1 &- nameEntry, mask: 0x0F, flags: neverIndexed ? 0x60 : 0x40)
                // 0000 N index(3): post-base.
                : lines.integer(nameEntry &- state.base, mask: 0x07, flags: neverIndexed ? 0x08 : 0)
        } else {
            // 001 N H length(3): a known name as its lowercase bytes (a store may spell it as HTTP/1 did).
            let (name, nameCount) = unsafe HTTPFieldName.lowercaseSpelling(knownName, name, nameCount)
            wrote = unsafe lines.string(name, nameCount, huffman: usesHuffmanCoding, prefixMask: 0x07, flags: neverIndexed ? 0x30 : 0x20)
        }
        return unsafe wrote && lines.string(value, valueCount, huffman: usesHuffmanCoding, prefixMask: 0x7F, flags: 0)
    }

    /// Whether the automatic policy has seen this field (its hash) recently; remembers it if not.
    @inlinable @inline(__always)
    func seenBefore(_ fieldHash: UInt64) -> Bool {
        let slot = Int(truncatingIfNeeded: fieldHash &>> 40) & historyMask
        // Unsafe: unchecked reads and stores of the history. Safe: the slot is masked into it.
        if unsafe history[slot] == fieldHash { return true }
        unsafe history[slot] = fieldHash
        return false
    }

    /// Whether a name (its hash) was seen recently in a literal; remembers it if not.
    @inlinable @inline(__always)
    func nameSeenBefore(_ nameHash: UInt64) -> Bool {
        let slot = Int(truncatingIfNeeded: nameHash &>> 40) & historyMask
        // Unsafe: unchecked reads and stores of the name history. Safe: the slot is masked into it.
        if unsafe nameHistory[slot] == nameHash { return true }
        unsafe nameHistory[slot] = nameHash
        return false
    }

    /// Whether an entry of `entrySize` fits once evictable entries are evicted: the oldest ones, while acknowledged and
    /// older than every entry an unacknowledged section (this one included) refers to.
    @inlinable @inline(__always)
    func roomFor(_ entrySize: Int, _ state: QPACKSectionState) -> Bool {
        guard entrySize <= table.maximumSize else { return false }
        if table.size &+ entrySize <= table.maximumSize { return true }
        return roomByEvicting(entrySize, state)
    }

    @usableFromInline
    func roomByEvicting(_ entrySize: Int, _ state: QPACKSectionState) -> Bool {
        var limit = Swift.min(knownReceivedCount, state.minimum)
        for position in 0..<sectionCount { limit = Swift.min(limit, unsafe sectionMinimum[position]) }
        var size = table.size
        var number = table.oldest
        while size &+ entrySize > table.maximumSize {
            guard number < limit, number < table.inserted else { return false }
            size &-= table.entry(number: number).size
            number &+= 1
        }
        return true
    }

    /// Writes an insertion on the encoder stream (RFC 9204 §4.3.2, §4.3.3) and inserts the field: its name a static
    /// reference, a dynamic one (any entry: the encoder stream never blocks), or a literal. Returns the entry's number, or
    /// -1 if the instruction didn't fit (nothing written then).
    @inlinable @inline(__always)
    mutating func insert(_ name: UnsafeRawPointer?, _ nameCount: Int, _ knownName: UInt8, _ value: UnsafeRawPointer?, _ valueCount: Int,
                         staticIndex: Int, nameHash: UInt64, fieldHash: UInt64, _ encoderStream: inout FieldEncoderOutput) -> Int {
        // A known name's lowercase bytes, for the encoder stream and the table (a store may spell it as HTTP/1 did).
        let (name, nameCount) = unsafe HTTPFieldName.lowercaseSpelling(knownName, name, nameCount)
        let mark = encoderStream.count
        var wrote: Bool
        if staticIndex != Int(statics.noIndex) {
            wrote = encoderStream.integer(staticIndex, mask: 0x3F, flags: 0xC0)
        } else {
            let number = unsafe index.nameMatch(nameHash, in: table, name, nameCount, knownName)
            wrote = number >= 0
                ? encoderStream.integer(table.inserted &- 1 &- number, mask: 0x3F, flags: 0x80)
                : unsafe encoderStream.string(name, nameCount, huffman: usesHuffmanCoding, prefixMask: 0x1F, flags: 0x40)
        }
        wrote = unsafe wrote && encoderStream.string(value, valueCount, huffman: usesHuffmanCoding, prefixMask: 0x7F, flags: 0)
        guard wrote else {
            encoderStream.count = mark
            return -1
        }
        let number = unsafe table.insert(name: name, nameCount: nameCount, knownName: knownName, value: value, valueCount: valueCount)
        index.add(number: number, entryMask: table.entryMask, nameHash: nameHash, fieldHash: fieldHash)
        noteInsertion(number, nameCount &+ valueCount &+ 32)
        return number
    }

    /// Writes a Duplicate of entry `number` (RFC 9204 §4.3.4) and inserts the copy, if room can be made for it. Returns
    /// the copy's number, or -1 (nothing written).
    @usableFromInline
    mutating func duplicate(_ number: Int, _ state: QPACKSectionState, _ encoderStream: inout FieldEncoderOutput) -> Int {
        let entry = table.entry(number: number)
        guard entry.nameCount > 0, roomFor(entry.size, state) else { return -1 }
        let mark = encoderStream.count
        guard encoderStream.integer(table.inserted &- 1 &- number, mask: 0x1F, flags: 0) else {
            encoderStream.count = mark
            return -1
        }
        let slot = number & table.entryMask
        // Unsafe: unchecked reads of the index's per-slot hashes. Safe: the slot is masked into them.
        let nameHash = unsafe index.nameHashes[slot], fieldHash = unsafe index.fieldHashes[slot]
        let name = unsafe table.address(Int(entry.offset))
        // Unsafe: the entry's own bytes, name then value (adjacent in the table's store), which the table moves together:
        // this insertion may evict the entry.
        let copy = unsafe table.insert(name: name, nameCount: Int(entry.nameCount), knownName: entry.knownName,
                                       value: name + Int(entry.nameCount), valueCount: Int(entry.valueCount))
        index.add(number: copy, entryMask: table.entryMask, nameHash: nameHash, fieldHash: fieldHash)
        noteInsertion(copy, entry.size)
        return copy
    }

    /// Records an insertion's place among all insertions' bytes, and moves the draining boundary past the entries it
    /// brought within a quarter of the capacity of eviction. An entry is evicted once the bytes inserted from its start
    /// on exceed the capacity (the table evicts only to insert, oldest first), so it's draining once they exceed
    /// `drainingDistance`.
    @inlinable @inline(__always)
    mutating func noteInsertion(_ number: Int, _ size: Int) {
        // Unsafe: an unchecked store. Safe: the slot is masked into the ring's `entryMask + 1` slots.
        unsafe entryStarts[number & table.entryMask] = insertedBytes
        insertedBytes &+= size
        let limit = insertedBytes &- drainingDistance
        var boundary = Swift.max(drainingBelow, table.oldest)
        // Unsafe: unchecked reads. Safe: masked slots of live entries (oldest ≤ boundary < inserted).
        while boundary < table.inserted, unsafe entryStarts[boundary & table.entryMask] < limit { boundary &+= 1 }
        drainingBelow = boundary
    }

    // MARK: - The decoder stream

    /// Forgets the unacknowledged sections of stream `stream`, for a stream this endpoint reset or abandoned before the
    /// peer could see its section (it was never sent): the peer will never acknowledge or cancel it, and its references
    /// would keep entries from being evicted (RFC 9204 §2.1.1) and count against the blocked streams for good. Only for
    /// such streams: a peer that did see the section may still acknowledge it, and a Section Acknowledgment for a stream
    /// with none outstanding is a connection error.
    public mutating func abandonSections(stream: UInt64) {
        var position = 0
        while position < sectionCount {
            // Unsafe: an unchecked read. Safe: position < sectionCount, below the list's capacity.
            if unsafe sectionStreams[position] == stream { removeSection(at: position) } else { position &+= 1 }
        }
    }

    /// Takes the peer's decoder stream instructions in `bytes` (RFC 9204 §4.4), as many as are complete.
    ///
    /// - Returns: The bytes used: pass the rest again, followed by the stream's next bytes.
    /// - Throws: ``QPACKError/invalidDecoderInstruction``: QPACK_DECODER_STREAM_ERROR. Instructions before the bad one
    ///   were taken.
    @inlinable
    public mutating func processDecoderStream(_ bytes: RawSpan) throws(QPACKError) -> Int {
        let result = bytes.withUnsafeBytes { buffer in
            // Unsafe: the stream's own bytes, read within their count.
            unsafe takeInstructions(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count)
        }
        if result < 0 { throw .invalidDecoderInstruction }
        return result
    }

    /// Takes complete instructions: the bytes used, or -1.
    @usableFromInline
    mutating func takeInstructions(_ base: UnsafePointer<UInt8>?, _ count: Int) -> Int {
        guard let base = unsafe base else { return 0 }
        var used = 0
        while used < count {
            var position = used
            // Unsafe: an unchecked read. Safe: used < count.
            let first = Int(unsafe base[used])
            let mask = first >= 0x80 ? 0x7F : 0x3F
            var value = first & mask
            if value == mask {
                value = unsafe readPrefixInteger62Continuation(base, count, &position, mask)
                if value == prefixIntegerTruncated { return used }
                if value < 0 { return -1 }
            } else {
                position &+= 1
            }
            if first >= 0x80 {
                // Section Acknowledgment (§4.4.1): the stream's oldest unacknowledged section.
                var found = -1
                for section in 0..<sectionCount where unsafe sectionStreams[section] == UInt64(value) {
                    found = section
                    break
                }
                guard found >= 0 else { return -1 }
                knownReceivedCount = Swift.max(knownReceivedCount, unsafe sectionRequired[found])
                removeSection(at: found)
            } else if first >= 0x40 {
                // Stream Cancellation (§4.4.2): its sections are no longer outstanding.
                var section = 0
                while section < sectionCount {
                    if unsafe sectionStreams[section] == UInt64(value) { removeSection(at: section) } else { section &+= 1 }
                }
            } else {
                // Insert Count Increment (§4.4.3).
                guard value > 0, value <= table.inserted &- knownReceivedCount else { return -1 }
                knownReceivedCount &+= value
            }
            used = position
        }
        return used
    }

    /// Removes unacknowledged section `position`, keeping the others' order.
    @usableFromInline
    mutating func removeSection(at position: Int) {
        let after = sectionCount &- position &- 1
        if after > 0 {
            // Unsafe: moves entries within the lists' initialized `sectionCount` slots.
            unsafe (sectionStreams + position).update(from: sectionStreams + (position &+ 1), count: after)
            unsafe (sectionRequired + position).update(from: sectionRequired + (position &+ 1), count: after)
            unsafe (sectionMinimum + position).update(from: sectionMinimum + (position &+ 1), count: after)
        }
        sectionCount &-= 1
    }
}

/// A section being encoded: its Base, what it refers to, and whether it may use unacknowledged entries.
@frozen @usableFromInline
struct QPACKSectionState {
    /// The Base: the Insert Count when the section began.
    @usableFromInline let base: Int
    /// The Required Insert Count so far: one past the largest absolute index referred to.
    @usableFromInline var required = 0
    /// The smallest absolute index referred to.
    @usableFromInline var minimum = Int.max
    /// Whether the section may refer to the dynamic table.
    @usableFromInline let usesTable: Bool
    /// Whether it may refer to entries the peer hasn't acknowledged (it may block).
    @usableFromInline let mayBlock: Bool

    @inlinable @inline(__always)
    init(base: Int, usesTable: Bool, mayBlock: Bool) {
        self.base = base
        self.usesTable = usesTable
        self.mayBlock = mayBlock
    }

    /// Whether the section may refer to entry `number`.
    @inlinable @inline(__always)
    func mayUse(_ number: Int, acknowledged: Int) -> Bool {
        usesTable && (number < acknowledged || mayBlock)
    }

    @inlinable @inline(__always)
    mutating func refer(to number: Int) {
        if number &+ 1 > required { required = number &+ 1 }
        if number < minimum { minimum = number }
    }
}

// An encoder owns its memory alone (it's noncopyable), so moving it to another task is safe.
extension QPACKEncoder: @unchecked Sendable {}
