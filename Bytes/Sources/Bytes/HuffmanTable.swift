/// A lookup table for decoding a canonical Huffman code (DEFLATE, PNG, JPEG, Brotli, …) from a
/// ``BitBuffer``: codes up to ``rootBits`` long take one lookup, longer ones two.
///
/// Build it from the code lengths a format transmits (0 for unused symbols), then decode symbols:
///
/// ```swift
/// var table = HuffmanTable(symbolCount: 19, maximumCodeLength: 7)
/// try table.build(codeLengths: lengths.span, bitOrder: .leastSignificantFirst)
/// buffer.refill()                     // at least `maximumCodeLength` bits
/// let symbol = try table.decode(&buffer)
/// ```
///
/// The table allocates once, enough for any code of its shape, and is rebuilt in place for each block.
/// Its entries hold a symbol and its code's length. For the fastest decoders, pack more into each entry
/// (DEFLATE's length bases and extra-bit counts, say) with the generic
/// ``build(codeLengths:bitOrder:rootBits:maximumCodeLength:allowingIncomplete:into:invalid:symbol:subtable:)``,
/// which this table uses.
public struct HuffmanTable: ~Copyable {
    @usableFromInline var entries: UniqueArray<UInt32>
    /// Codes up to this long decode with one lookup.
    public let rootBits: Int
    /// The most symbols a code can have.
    public let symbolCount: Int
    /// The longest code the table accepts.
    public let maximumCodeLength: Int
    /// The bit order of the codes, from the last build.
    public private(set) var bitOrder = BitOrder.leastSignificantFirst

    // Entries: bits 0–4, the code's length (for a subtable link, its index width); bits 5–6, the kind;
    // bits 8–31, the symbol (for a link, the subtable's offset).
    @usableFromInline static var symbolKind: UInt32 { 0 }
    @usableFromInline static var subtableKind: UInt32 { 1 }
    @usableFromInline static var invalidKind: UInt32 { 2 }

    /// Creates a table for codes of up to `symbolCount` symbols and `maximumCodeLength` bits (at most 16),
    /// decoding codes of up to `rootBits` (by default, up to 10) with one lookup.
    public init(symbolCount: Int, maximumCodeLength: Int = 15, rootBits: Int? = nil) {
        let rootBits = rootBits ?? min(maximumCodeLength, 10)
        precondition(rootBits >= 1 && rootBits <= maximumCodeLength && maximumCodeLength <= 16, "Invalid table shape")
        precondition(symbolCount > 0 && symbolCount <= 1 << 16, "Invalid symbol count")
        self.rootBits = rootBits
        self.symbolCount = symbolCount
        self.maximumCodeLength = maximumCodeLength
        // At most one subtable per root prefix and per symbol, each at most as wide as the longest code needs.
        let subtableSpace = min(1 << maximumCodeLength, symbolCount << (maximumCodeLength - rootBits))
        entries = UniqueArray(repeating: Self.invalidKind << 5, count: (1 << rootBits) + subtableSpace)
    }

    /// Builds the table for the canonical code with these code lengths: one per symbol, 0 if unused.
    /// See the generic `build` for the bit orders and the codes accepted.
    public mutating func build(
        codeLengths lengths: Span<UInt8>, bitOrder: BitOrder, allowingIncomplete: Bool = true
    ) throws(BytesError) {
        guard lengths.count <= symbolCount else { throw .invalidValue }
        self.bitOrder = bitOrder
        var table = entries.mutableSpan
        _ = try Self.build(
            codeLengths: lengths, bitOrder: bitOrder, rootBits: rootBits, maximumCodeLength: maximumCodeLength,
            allowingIncomplete: allowingIncomplete, into: &table, invalid: Self.invalidKind << 5,
            symbol: { symbol, length in UInt32(truncatingIfNeeded: length | symbol << 8) },
            subtable: { offset, bits in UInt32(truncatingIfNeeded: bits | offset << 8) | Self.subtableKind << 5 }
        )
    }

    /// Decodes the next symbol from `buffer`, consuming its code. ``maximumCodeLength`` bits must be
    /// buffered (``BitBuffer/refill()`` first), in the bit order the table was built for.
    ///
    /// Throws ``BytesError/invalidValue`` for bits that aren't a code, possible only for an incomplete code.
    @inlinable @inline(always)
    public func decode(_ buffer: inout BitBuffer) throws(BytesError) -> Int {
        let bits = buffer.bits
        let entries = entries.span
        var entry: UInt32
        switch bitOrder {
        case .leastSignificantFirst:
            entry = entries[Int(truncatingIfNeeded: bits) & ((1 &<< rootBits) &- 1)]
            if entry >> 5 & 3 == Self.subtableKind {
                let index = Int(truncatingIfNeeded: bits &>> UInt64(truncatingIfNeeded: rootBits))
                    & ((1 &<< Int(entry & 0x1F)) &- 1)
                entry = entries[Int(entry >> 8) &+ index]
            }
        case .mostSignificantFirst:
            entry = entries[Int(truncatingIfNeeded: bits &>> UInt64(truncatingIfNeeded: 64 &- rootBits))]
            if entry >> 5 & 3 == Self.subtableKind {
                let index = Int(truncatingIfNeeded:
                    (bits &<< UInt64(truncatingIfNeeded: rootBits)) &>> UInt64(truncatingIfNeeded: 64 &- Int(entry & 0x1F)))
                entry = entries[Int(entry >> 8) &+ index]
            }
        }
        guard entry >> 5 & 3 == Self.symbolKind else { throw .invalidValue }
        buffer.consume(bitCount: Int(entry & 0x1F))
        return Int(entry >> 8)
    }
}

// MARK: - Building tables

extension HuffmanTable {
    /// Fills `table` with a lookup table for the canonical Huffman code with these code lengths (one per
    /// symbol, 0 if unused), its entries made by `symbol` and `subtable`. Returns how many entries it used.
    ///
    /// The table is indexed by the next `rootBits` bits of the stream: the low bits of
    /// ``BitBuffer/bits`` for ``BitOrder/leastSignificantFirst`` (codes are stored bit-reversed, as DEFLATE
    /// packs them), the high bits for ``BitOrder/mostSignificantFirst`` (JPEG). A code of up to `rootBits`
    /// bits fills every entry that starts with it, with `symbol(symbol, codeLength)`. Longer codes go in
    /// subtables after the root, one per root prefix: that prefix's entry is `subtable(offset, indexBits)`,
    /// and the subtable is indexed by the `indexBits` bits after the root's. Entries for bits that aren't a
    /// code are `invalid`.
    ///
    /// ```swift
    /// var entry = table[Int(bits & rootMask)]                  // least significant bit first
    /// if entry.isSubtable {
    ///     entry = table[entry.offset + Int(bits >> rootBits) & (1 << entry.indexBits - 1)]
    /// }
    /// buffer.consume(bitCount: entry.codeLength)
    /// ```
    ///
    /// Throws ``BytesError/invalidValue`` for an over-subscribed code, a code longer than
    /// `maximumCodeLength` (at most 16), a table too small for the code, or an incomplete code. With
    /// `allowingIncomplete`, two incomplete codes are accepted, as DEFLATE decoders do: none at all, and a
    /// single 1-bit code (code 0).
    ///
    /// libdeflate's algorithm: symbols are visited in canonical order, filling only the first `2^length`
    /// entries and doubling them with a copy at each longer length, so each root entry is written once.
    @inlinable
    public static func build<Entry: BitwiseCopyable>(
        codeLengths lengths: Span<UInt8>,
        bitOrder: BitOrder,
        rootBits: Int,
        maximumCodeLength: Int = 16,
        allowingIncomplete: Bool = true,
        into table: inout MutableSpan<Entry>,
        invalid: Entry,
        symbol makeSymbol: (_ symbol: Int, _ codeLength: Int) -> Entry,
        subtable makeLink: (_ offset: Int, _ indexBits: Int) -> Entry
    ) throws(BytesError) -> Int {
        precondition(rootBits >= 1 && rootBits <= 16 && maximumCodeLength <= 16, "Invalid table shape")
        precondition(table.count >= 1 << rootBits, "Table smaller than its root")
        guard lengths.count <= 1 << 16 else { throw .invalidValue }
        var counts = InlineArray<17, Int>(repeating: 0)
        for symbol in lengths.indices {
            let length = Int(lengths[symbol])
            guard length <= maximumCodeLength else { throw .invalidValue }
            counts[length] &+= 1
        }
        counts[0] = 0
        var longest = 0
        var unused = 1 // Codes still available at the current length.
        for length in 1...16 {
            unused = unused &<< 1 &- counts[length]
            guard unused >= 0 else { throw .invalidValue } // Over-subscribed.
            if counts[length] > 0 { longest = length }
        }
        let rootSize = 1 &<< rootBits

        if unused > 0 {
            // Incomplete: no codes, or a single 1-bit code. Everything else decodes as invalid.
            guard allowingIncomplete, longest <= 1 else { throw .invalidValue }
            for index in 0..<rootSize {
                table[index] = invalid
            }
            for symbol in lengths.indices where lengths[symbol] == 1 {
                let entry = makeSymbol(symbol, 1)
                switch bitOrder {
                case .leastSignificantFirst:
                    for index in stride(from: 0, to: rootSize, by: 2) {
                        table[index] = entry
                    }
                case .mostSignificantFirst:
                    for index in 0..<(rootSize &>> 1) {
                        table[index] = entry
                    }
                }
            }
            return rootSize
        }

        // Symbols sorted by code length, then value: the order canonical codes are assigned in. Scratch on
        // the stack: an `InlineArray` big enough for the common alphabets (DEFLATE's 288 literal/lengths,
        // JPEG's 256), and for bigger ones (Brotli's 704), the standard library's temporary allocation.
        if lengths.count <= 320 {
            var storage = InlineArray<320, UInt16>(repeating: 0)
            var sorted = storage.mutableSpan
            return try _sortAndBuild(lengths, &sorted, counts, bitOrder, rootBits, &table, makeSymbol, makeLink)
        }
        return try withUnsafeTemporaryAllocation(of: UInt16.self, capacity: lengths.count) { buffer throws(BytesError) -> Int in
            // Unsafe: a span over stack memory. Safe: initialized here, and it lives only for this call. No
            // safe stack storage has a size known only at run time.
            _ = unsafe buffer.initialize(repeating: 0)
            var sorted = unsafe MutableSpan(_unsafeElements: buffer)
            return try _sortAndBuild(lengths, &sorted, counts, bitOrder, rootBits, &table, makeSymbol, makeLink)
        }
    }

    /// Sorts the used symbols into `sorted` by code length, then builds the table. A function of its own
    /// rather than a nested one: capturing the entry closures kept them from being inlined (5% more
    /// instructions decoding small DEFLATE files).
    @inlinable @inline(__always)
    static func _sortAndBuild<Entry: BitwiseCopyable>(
        _ lengths: Span<UInt8>, _ sorted: inout MutableSpan<UInt16>, _ counts: InlineArray<17, Int>,
        _ bitOrder: BitOrder, _ rootBits: Int, _ table: inout MutableSpan<Entry>,
        _ makeSymbol: (Int, Int) -> Entry, _ makeLink: (Int, Int) -> Entry
    ) throws(BytesError) -> Int {
        var offsets = InlineArray<17, Int>(repeating: 0)
        for length in 1..<16 {
            offsets[length &+ 1] = offsets[length] &+ counts[length]
        }
        for symbol in lengths.indices where lengths[symbol] != 0 {
            let length = Int(lengths[symbol])
            sorted[offsets[length]] = UInt16(truncatingIfNeeded: symbol)
            offsets[length] &+= 1
        }
        switch bitOrder {
        case .leastSignificantFirst:
            return try _buildReversed(&table, sorted.span, counts, rootBits: rootBits, makeSymbol, makeLink)
        case .mostSignificantFirst:
            return try _buildForward(&table, sorted.span, counts, rootBits: rootBits, makeSymbol, makeLink)
        }
    }

    /// The index width of a subtable whose first code has `length` bits, `count` of them left at that
    /// length: wide enough for every code sharing its root prefix.
    @inlinable @inline(__always)
    static func _subtableBits(length: Int, count: Int, _ counts: InlineArray<17, Int>, rootBits: Int) -> Int {
        var bits = length &- rootBits
        var used = count
        while used < 1 &<< bits {
            bits &+= 1
            used = used &<< 1 &+ counts[rootBits &+ bits]
        }
        return bits
    }

    /// Least significant bit first: codes bit-reversed, so a code's root entries are every `2^length`th.
    /// Requires a complete code with at least one symbol.
    @inlinable
    static func _buildReversed<Entry: BitwiseCopyable>(
        _ table: inout MutableSpan<Entry>, _ sorted: Span<UInt16>,
        _ counts: InlineArray<17, Int>, rootBits: Int,
        _ makeSymbol: (Int, Int) -> Entry, _ makeLink: (Int, Int) -> Entry
    ) throws(BytesError) -> Int {
        let rootSize = 1 &<< rootBits
        /// The reversed code after `code` among codes of `length` bits (`code` isn't all ones): add one to
        /// the reversed value by clearing the trailing ones and setting the bit above them.
        @inline(__always)
        func next(after code: Int, length: Int) -> Int {
            let differing = UInt32(truncatingIfNeeded: code ^ ((1 &<< length) &- 1))
            let bit = 1 &<< (31 &- differing.leadingZeroBitCount)
            return code & (bit &- 1) | bit
        }
        /// Doubles the filled entries: copies the first `end` to the next `end`. (Measured as fast as
        /// `memcpy` here: the tables are small.)
        @inline(__always)
        func double(_ end: Int) {
            for index in 0..<end {
                table[end &+ index] = table[index]
            }
        }
        var index = 0
        var length = 1
        while counts[length] == 0 {
            length &+= 1
        }
        var count = counts[length]
        var code = 0
        // Entries filled so far, for codes up to `length` bits. If even the shortest codes are longer than
        // the root, every root entry is a subtable link.
        var end = 1 &<< min(length, rootBits)

        // Codes that fit in the root.
        while length <= rootBits {
            repeat {
                table[code] = makeSymbol(Int(sorted[index]), length)
                index &+= 1
                if code == end &- 1 {
                    // The last code (all ones): replicate up to the root's width.
                    while end < rootSize {
                        double(end)
                        end &<<= 1
                    }
                    return rootSize
                }
                code = next(after: code, length: length)
                count &-= 1
            } while count > 0
            repeat {
                length &+= 1
                if length <= rootBits {
                    double(end)
                    end &<<= 1
                }
            } while counts[length] == 0
            count = counts[length]
        }

        // Longer codes: a subtable per root prefix.
        var prefix = -1
        var start = 0
        while true {
            if code & (rootSize &- 1) != prefix {
                prefix = code & (rootSize &- 1)
                start = end
                let bits = _subtableBits(length: length, count: count, counts, rootBits: rootBits)
                end = start &+ (1 &<< bits)
                guard end <= table.count else { throw .invalidValue }
                table[prefix] = makeLink(start, bits)
            }
            let entry = makeSymbol(Int(sorted[index]), length)
            index &+= 1
            var slot = start &+ (code &>> rootBits)
            repeat {
                table[slot] = entry
                slot &+= 1 &<< (length &- rootBits)
            } while slot < end
            if code == (1 &<< length) &- 1 {
                return end
            } // The last code.
            code = next(after: code, length: length)
            count &-= 1
            while count == 0 {
                length &+= 1
                count = counts[length]
            }
        }
    }

    /// Most significant bit first: codes as they are, so a code's entries are a contiguous run.
    /// Requires a complete code with at least one symbol.
    @inlinable
    static func _buildForward<Entry: BitwiseCopyable>(
        _ table: inout MutableSpan<Entry>, _ sorted: Span<UInt16>,
        _ counts: InlineArray<17, Int>, rootBits: Int,
        _ makeSymbol: (Int, Int) -> Entry, _ makeLink: (Int, Int) -> Entry
    ) throws(BytesError) -> Int {
        var code = 0
        var index = 0
        var end = 1 &<< rootBits
        var prefix = -1
        var start = 0
        var width = 0
        for length in 1...16 {
            var count = counts[length]
            while count > 0 {
                let entry = makeSymbol(Int(sorted[index]), length)
                let first: Int
                let run: Int
                if length <= rootBits {
                    run = 1 &<< (rootBits &- length)
                    first = code &* run
                } else {
                    let tail = length &- rootBits
                    if code &>> tail != prefix {
                        prefix = code &>> tail
                        start = end
                        width = _subtableBits(length: length, count: count, counts, rootBits: rootBits)
                        end = start &+ (1 &<< width)
                        guard end <= table.count else { throw .invalidValue }
                        table[prefix] = makeLink(start, width)
                    }
                    run = 1 &<< (width &- tail)
                    first = start &+ (code & ((1 &<< tail) &- 1)) &* run
                }
                for slot in first..<(first &+ run) {
                    table[slot] = entry
                }
                index &+= 1
                code &+= 1
                count &-= 1
            }
            code &<<= 1
        }
        return end
    }
}
