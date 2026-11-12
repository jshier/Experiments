public import Bytes

// MARK: - Decoding

/// Decoding (RFC 4648), the counterpart of the encoder: strict, all or nothing, and vectorized.
///
/// - **Strict:** every character must be in the alphabet; padding, if expected, is `=` to a multiple of 4
///   characters, and nowhere else; the last character's unused bits must be zero (RFC 4648 section 3.5), so
///   each text has one decoding and each byte string one encoding. No whitespace or line breaks.
/// - **All or nothing:** on failure, the error says what was wrong and where (`LocatedBytesError`, at an
///   offset in the reader's span), the reader hasn't moved, and the writer is back where it started.
/// - **Kernels**, as for encoding:
///   - **ARM64** (`ByteLanes.isLookupVectorized`): 64-character blocks to 48 bytes, 49 instructions each,
///     with Bytes' NEON helpers. `ByteLanes.deinterleave` takes every fourth character, as `ld4` would (8
///     `uzp`s). Two `tbx` lookups in an 80-character window of the ASCII table map each to its value, 0xFF
///     for characters not in the alphabet. Shifts and ORs make the bytes, and `ByteLanes.interleave` puts
///     them in order, as `st3` would (3 `tbl`s). Validity is ORed across blocks and tested once, so the
///     loop has no branches. About 12.8 GB/s of bytes (17 GB/s of text) on an M3 Ultra, level with C
///     using `ld4` and `st3`. The last 1 to 64 characters are one more block: the last 64 as they are,
///     with the padding's lanes made `A` (the value 0), or, for text shorter than a block or not whole
///     groups, the rest moved to the front of a block of `A`s. The last group's unused bits are then the
///     byte after the last one written.
///   - **Elsewhere**, and for alphabets whose two characters don't fit the window: 4-character groups to
///     3 bytes with arithmetic, which LLVM vectorizes (`ld4`/`st3` on ARM64), then the last group on its
///     own.
extension Base64 {
    /// The most bytes `characterCount` characters decode to: 3 for every 4, and 1 or 2 for a last group of
    /// 2 or 3 (unpadded text). Padded text ending in `=` or `==` decodes to 1 or 2 fewer.
    ///
    /// - Parameter characterCount: The length of the text, padding included.
    /// - Returns: An upper bound for the decoded length, to size the output with.
    /// - Precondition: `characterCount` isn't negative.
    @inlinable
    public static func maximumDecodedByteCount(of characterCount: Int) -> Int {
        precondition(characterCount >= 0, "Negative character count")
        let (groups, remainder) = characterCount.quotientAndRemainder(dividingBy: 4)
        return groups &* 3 &+ (remainder == 0 ? 0 : remainder &- 1)
    }

    /// Decodes the rest of `reader` into `writer`.
    ///
    /// ```swift
    /// var reader = BytesReader(text.span)
    /// var output = [UInt8](repeating: 0, count: Base64.maximumDecodedByteCount(of: text.count))
    /// var span = output.mutableSpan
    /// var writer = BytesWriter(&span)
    /// try Base64.decode(&reader, into: &writer)
    /// let bytes = output.prefix(writer.byteCount)
    /// ```
    ///
    /// With `padding`, the text must be a multiple of 4 characters, the last group padded with `=`, as
    /// ``encode(_:into:alphabet:padding:)-(BytesReader,_,_,_)`` writes it; without, it must have no `=`, and its last
    /// group is 2 to 4 characters. Empty text decodes to nothing.
    ///
    /// - Parameters:
    ///   - reader: The text, from its position to the end of its span. Byte-aligned. Left at the end on
    ///     success, where it started on failure.
    ///   - writer: Where the bytes go. Byte-aligned. Back where it started on failure.
    ///   - alphabet: The characters for 62 and 63.
    ///   - padding: Whether the text is padded with `=` to a multiple of 4 characters.
    /// - Throws: `LocatedBytesError`, with an offset in `reader`'s span:
    ///   - `BytesError.invalidValue` at the first character that isn't in `alphabet` (a misplaced `=`
    ///     included), or, if all are, at the last character when its unused bits aren't zero;
    ///   - `BytesError.insufficientData` at the end of the text, if it isn't a whole number of groups (with
    ///     padding, not a multiple of 4 characters; without, a last group of 1 character);
    ///   - `BytesError.insufficientCapacity` at the start, if `writer` doesn't have room for the decoded
    ///     bytes; nothing has been decoded then.
    /// - Precondition: `reader` and `writer` are byte-aligned.
    @inlinable
    public static func decode(
        _ reader: inout BytesReader, into writer: inout BytesWriter, alphabet: Alphabet = .standard, padding: Bool = true
    ) throws(LocatedBytesError) {
        let start = reader.position
        let text = reader.readRemainingBytes()
        do throws(LocatedBytesError) {
            try _decode(text, at: start.byteOffset, into: &writer, alphabet: alphabet, padding: padding)
        } catch {
            reader.rewind(to: start)
            throw error
        }
    }

    /// Decodes `text` into `writer`. Strict and all or nothing, as
    /// ``decode(_:into:alphabet:padding:)-(BytesReader,_,_,_)``, with errors' offsets in `text`.
    ///
    /// - Parameters:
    ///   - text: The Base64 text.
    ///   - writer: Where the bytes go. Byte-aligned. Back where it started on failure.
    ///   - alphabet: The characters for 62 and 63.
    ///   - padding: Whether the text is padded with `=` to a multiple of 4 characters.
    /// - Throws: `LocatedBytesError` with `BytesError.invalidValue`, `BytesError.insufficientData`, or
    ///   `BytesError.insufficientCapacity`, as for the reader overload.
    /// - Precondition: `writer` is byte-aligned.
    @inlinable
    public static func decode(
        _ text: RawSpan, into writer: inout BytesWriter, alphabet: Alphabet = .standard, padding: Bool = true
    ) throws(LocatedBytesError) {
        try _decode(text, at: 0, into: &writer, alphabet: alphabet, padding: padding)
    }

    /// `text` decoded into a new array: one allocation, the array's. Strict, as
    /// ``decode(_:into:alphabet:padding:)-(BytesReader,_,_,_)``, with errors' offsets in `text`.
    ///
    /// - Parameters:
    ///   - text: The Base64 text.
    ///   - alphabet: The characters for 62 and 63.
    ///   - padding: Whether the text is padded with `=` to a multiple of 4 characters.
    /// - Returns: The decoded bytes.
    /// - Throws: `LocatedBytesError` with `BytesError.invalidValue` or `BytesError.insufficientData`,
    ///   as for the reader overload. (Capacity is sized for the text, so `BytesError.insufficientCapacity`
    ///   doesn't occur.)
    @inlinable
    public static func decodedBytes(
        _ text: RawSpan, alphabet: Alphabet = .standard, padding: Bool = true
    ) throws(LocatedBytesError) -> [UInt8] {
        try [UInt8](byteCapacity: maximumDecodedByteCount(of: text.byteCount)) { (writer) throws(LocatedBytesError) in
            try _decode(text, at: 0, into: &writer, alphabet: alphabet, padding: padding)
        }
    }

    /// `text` decoded into a new array; errors' offsets are in its UTF-8.
    ///
    /// - Parameters:
    ///   - text: The Base64 text.
    ///   - alphabet: The characters for 62 and 63.
    ///   - padding: Whether the text is padded with `=` to a multiple of 4 characters.
    /// - Returns: The decoded bytes.
    /// - Throws: `LocatedBytesError`, as for the `RawSpan` overload of `decodedBytes`.
    @inlinable
    public static func decodedBytes(
        _ text: String, alphabet: Alphabet = .standard, padding: Bool = true
    ) throws(LocatedBytesError) -> [UInt8] {
        try decodedBytes(text.utf8Span.span.bytes, alphabet: alphabet, padding: padding)
    }

    /// The decoder, for text at `offset` in a reader's span (for errors' offsets).
    ///
    /// - Parameters:
    ///   - text: The Base64 text.
    ///   - offset: Where `text` starts in the span that errors' offsets are in.
    ///   - writer: Where the bytes go. Rewound to where it started on failure.
    ///   - alphabet: The characters for 62 and 63.
    ///   - padding: Whether the text is padded with `=` to a multiple of 4 characters.
    /// - Throws: `LocatedBytesError`, as for ``decode(_:into:alphabet:padding:)-(BytesReader,_,_,_)``.
    /// - Precondition: `writer` is byte-aligned.
    @inlinable
    static func _decode(
        _ text: RawSpan, at offset: Int, into writer: inout BytesWriter, alphabet: Alphabet, padding: Bool
    ) throws(LocatedBytesError) {
        precondition(writer.isByteAligned, "Decoding requires a byte-aligned writer: call alignToByte() first")
        let count = text.byteCount
        guard count > 0 else { return }
        // The characters that carry data: all of them, less a trailing "=" or "==" with padding.
        let dataCount: Int
        if padding {
            guard count & 3 == 0 else { throw LocatedBytesError(.insufficientData, byteOffset: offset &+ count) }
            // Unsafe: an unchecked load. Safe: the text has at least 4 characters.
            let end = unsafe text.unsafeLoadUnaligned(fromUncheckedByteOffset: count &- 2, as: UInt16.self)
            dataCount = count &- (end == 0x3D3D ? 2 : end &>> 8 == 0x3D ? 1 : 0) // "==", "?="
        } else {
            guard count & 3 != 1 else { throw LocatedBytesError(.insufficientData, byteOffset: offset &+ count) }
            dataCount = count
        }
        let byteCount = (dataCount &* 3) &>> 2 // Parenthesized: shifts bind tighter than `&*` in Swift.
        guard writer.remainingByteCount >= byteCount else {
            throw LocatedBytesError(.insufficientCapacity, byteOffset: offset)
        }
        let writerStart = writer.position
        do throws(LocatedBytesError) {
            if ByteLanes.isLookupVectorized, let window = alphabet.decodingWindow {
                try _decodeBlocks(text, dataCount: dataCount, into: &writer, alphabet: alphabet, window: window, at: offset)
            } else {
                try _decodeGroups(text, padding: padding, into: &writer, alphabet: alphabet, at: offset)
            }
        } catch {
            writer.rewind(to: writerStart)
            throw error
        }
    }

    /// ARM64: 64-character blocks, then the rest of the data characters, 1 to 64, as one more block padded
    /// with "A"s (the value 0). The "A"s stand in for any padding too, so the last group, whole or not, is
    /// decoded with the rest, and its unused bits are the decoded byte after the last one written, which
    /// must be zero.
    ///
    /// - Parameters:
    ///   - text: The Base64 text, at least one data character.
    ///   - dataCount: The characters of `text` that aren't padding.
    ///   - writer: Where the bytes go. Capacity already checked.
    ///   - alphabet: Used to find the first bad character for an error.
    ///   - table: The alphabet's decoding window.
    ///   - offset: Where `text` starts, for errors' offsets.
    /// - Throws: `LocatedBytesError` with `BytesError.invalidValue` at the first character not in the
    ///   alphabet, or at the last data character if its unused bits aren't zero.
    @inlinable
    static func _decodeBlocks(
        _ text: RawSpan, dataCount: Int, into writer: inout BytesWriter, alphabet: Alphabet,
        window table: Alphabet.DecodingWindow, at offset: Int
    ) throws(LocatedBytesError) {
        var invalid: SIMD16<UInt8>
        var unusedBits: UInt8 = 0
        do throws(BytesError) {
            var reader = BytesReader(text)
            let blocks = try reader.read(InlineArray<64, UInt8>.self, count: (dataCount &- 1) &>> 6)
            invalid = try writer.write(InlineArray<48, UInt8>.self, count: blocks.count, filling: { bytes in
                decodeBlocks(blocks, into: &bytes, table: table)
            })
            let rest = dataCount &- blocks.count &<< 6
            let count = text.byteCount
            if count & 3 == 0, count >= 64 {
                // Whole groups (all padded text): the last 64 characters start at a group, so they decode
                // as they are, with no shift, the padding's lanes made "A"s. Their first groups may repeat
                // the last block's, and are left out of the write.
                let padCount = count &- dataCount
                var overlap = try BytesReader(text, atByteOffset: count &- 64)
                var last = try overlap.load(InlineArray<4, SIMD16<UInt8>>.self)
                let iota: Byte16 = 0x00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E_0F
                let padding = iota.vector .>= SIMD16(repeating: UInt8(truncatingIfNeeded: 16 &- padCount))
                last[3].replace(with: SIMD16(repeating: 0x41), where: padding)
                let (bytes, bad) = decodeBlock(bitCast(last, to: InlineArray<64, UInt8>.self), table: table)
                invalid |= bad
                let start = ((blocks.count &<< 6 &- (count &- 64)) &>> 2) &* 3
                try writer.write(bytes.span.bytes.extracting(start..<(48 &- padCount)))
                if padCount > 0 { unusedBits = bytes[48 &- padCount] }
            } else {
                try _decodeShiftedBlock(text, dataCount: dataCount, rest: rest, into: &writer, table: table,
                                        invalid: &invalid, unusedBits: &unusedBits)
            }
        } catch {
            // Capacity was checked, and the reads are within the text: neither throws.
            throw LocatedBytesError(error, byteOffset: offset)
        }
        guard !ByteLanes(invalid).nonASCII.any else {
            let index = firstInvalidCharacter(in: text.extracting(first: dataCount), alphabet: alphabet)
            throw LocatedBytesError(.invalidValue, byteOffset: offset &+ index)
        }
        // The last data character's unused bits.
        guard unusedBits == 0 else { throw LocatedBytesError(.invalidValue, byteOffset: offset &+ dataCount &- 1) }
    }

    /// The last block when the text isn't whole groups, or is shorter than a block: its last `rest` data
    /// characters (1 to 64) moved to the front of a block of "A"s, decoded, and written.
    ///
    /// - Parameters:
    ///   - text: The Base64 text.
    ///   - dataCount: The characters of `text` that aren't padding.
    ///   - rest: How many data characters are left after the whole blocks, 1 through 64.
    ///   - writer: Where the bytes go.
    ///   - table: The alphabet's decoding window.
    ///   - invalid: ORed with the block's values: high bits set if a character isn't in the alphabet.
    ///   - unusedBits: Set to the byte after the last one written if `rest` isn't a multiple of 4, else left
    ///     alone.
    /// - Throws: `BytesError` only if the reads or the write fail, which capacity and bounds already checked
    ///   rule out.
    @inlinable @inline(__always)
    static func _decodeShiftedBlock(
        _ text: RawSpan, dataCount: Int, rest: Int, into writer: inout BytesWriter, table: Alphabet.DecodingWindow,
        invalid: inout SIMD16<UInt8>, unusedBits: inout UInt8
    ) throws(BytesError) {
        let block: InlineArray<64, UInt8>
        if dataCount >= 64 {
            // The last 64 data characters overlap the blocks before: load them, and move the last `rest` to
            // the front with "A"s after, in registers (as the encoder does). A new reader at that offset,
            // rather than `seek`: its bit offset is known to be 0, so the unaligned path of `load` folds
            // away (and `seek` wasn't inlined).
            var overlap = try BytesReader(text, atByteOffset: dataCount &- 64)
            let last = try overlap.load(InlineArray<4, SIMD16<UInt8>>.self)
            block = bitCast(shiftedDown(last, by: 64 &- rest), to: InlineArray<64, UInt8>.self)
        } else {
            var characters = InlineArray<64, UInt8>(repeating: 0x41) // "A"
            var span = characters.mutableSpan
            var blockWriter = BytesWriter(&span)
            try blockWriter.write(text.extracting(first: rest))
            block = characters
        }
        let (bytes, bad) = decodeBlock(block, table: table)
        invalid |= bad
        let restByteCount = (rest &* 3) &>> 2
        try writer.write(bytes.span.bytes.extracting(first: restByteCount))
        if rest & 3 != 0 { unusedBits = bytes[restByteCount] }
    }

    /// Elsewhere: 4-character groups with arithmetic, then the last group on its own. Capacity already
    /// checked, and `text` isn't empty. `package`, so the tests can run it on ARM64, which doesn't.
    ///
    /// - Parameters:
    ///   - text: The Base64 text: a multiple of 4 characters if `padding`, else not 1 more.
    ///   - padding: Whether the last group is padded with `=` to 4 characters.
    ///   - writer: Where the bytes go. Capacity already checked; not rewound here.
    ///   - alphabet: The characters for 62 and 63.
    ///   - offset: Where `text` starts, for errors' offsets.
    /// - Throws: `LocatedBytesError` with `BytesError.invalidValue` at the first character not in the
    ///   alphabet, or at the last data character if its unused bits aren't zero.
    @inlinable
    package static func _decodeGroups(
        _ text: RawSpan, padding: Bool, into writer: inout BytesWriter, alphabet: Alphabet, at offset: Int
    ) throws(LocatedBytesError) {
        let count = text.byteCount
        let bodyCount = count &- (padding || count & 3 == 0 ? 4 : count & 3)
        let valid: Bool
        do throws(BytesError) {
            var body = BytesReader(text.extracting(first: bodyCount))
            let groups = try body.read(InlineArray<4, UInt8>.self, count: bodyCount &>> 2)
            valid = try writer.write(InlineArray<3, UInt8>.self, count: groups.count, filling: { bytes in
                decode(groups, into: &bytes, alphabet: alphabet)
            })
        } catch {
            // Capacity was checked, and the body is whole groups: neither throws.
            throw LocatedBytesError(error, byteOffset: offset)
        }
        guard valid else {
            let index = firstInvalidCharacter(in: text.extracting(first: bodyCount), alphabet: alphabet)
            throw LocatedBytesError(.invalidValue, byteOffset: offset &+ index)
        }
        try _decodeLastGroup(text.extracting(droppingFirst: bodyCount), into: &writer,
                             alphabet: alphabet, padding: padding, at: offset &+ bodyCount)
    }

    /// Decodes the last group: 2 to 4 characters, then padding to 4 if `padding`.
    ///
    /// - Parameters:
    ///   - group: The last group's characters, padding included.
    ///   - writer: Where the 1 to 3 bytes go. Capacity already checked.
    ///   - alphabet: The characters for 62 and 63.
    ///   - padding: Whether the group may end in `=` or `==`.
    ///   - offset: Where `group` starts, for errors' offsets.
    /// - Throws: `LocatedBytesError` with `BytesError.invalidValue` at the first data character not in the
    ///   alphabet, or at the last data character if its unused bits aren't zero.
    @inlinable
    static func _decodeLastGroup(
        _ group: RawSpan, into writer: inout BytesWriter, alphabet: Alphabet, padding: Bool, at offset: Int
    ) throws(LocatedBytesError) {
        // Four characters, with zeros (never valid) past the end of an unpadded group.
        var characters: UInt32 = 0
        for index in 0..<group.byteCount {
            characters |= UInt32(group.load(fromByteOffset: index, as: UInt8.self)) &<< (8 &* index)
        }
        // With padding, the characters before the trailing "=" or "==" (at most two); without, all of them.
        var dataCount = group.byteCount
        if padding, characters &>> 24 == 0x3D { dataCount = characters &>> 16 & 0xFF == 0x3D ? 2 : 3 }
        var bits: UInt32 = 0
        for index in 0..<dataCount {
            let (value, valid) = value(of: UInt8(truncatingIfNeeded: characters &>> (8 &* index)), alphabet)
            guard valid != 0 else { throw LocatedBytesError(.invalidValue, byteOffset: offset &+ index) }
            bits |= UInt32(value) &<< (18 &- 6 &* index)
        }
        do throws(BytesError) {
            switch dataCount {
            case 4: try writer.write(bits, as: Byte3.self, .bigEndian)
            case 3:
                // The last character's low 2 bits are unused, and must be zero.
                guard bits & 0xFF == 0 else { throw .invalidValue }
                try writer.write(UInt16(truncatingIfNeeded: bits &>> 8), as: Byte2.self, .bigEndian)
            default:
                // The second character's low 4 bits are unused, and must be zero.
                guard bits & 0xFFFF == 0 else { throw .invalidValue }
                try writer.write(Byte(truncatingIfNeeded: bits &>> 16))
            }
        } catch {
            // Capacity was checked, so only the unused bits throw: the last data character is at fault.
            throw LocatedBytesError(error, byteOffset: offset &+ dataCount &- 1)
        }
    }

    // MARK: - The decoding kernels

    /// Decodes 64-character blocks into 48 bytes each (see the type's documentation). Returns the OR of every
    /// value: its high bits are set if any character wasn't in the alphabet. Compiled once, here.
    ///
    /// - Parameters:
    ///   - blocks: The text, 64 characters per element.
    ///   - output: Receives 48 bytes per element.
    ///   - table: The alphabet's decoding window.
    /// - Returns: The OR of every value, per lane.
    /// - Precondition: `output` and `blocks` have the same count.
    @usableFromInline @inline(never)
    static func decodeBlocks(
        _ blocks: Span<InlineArray<64, UInt8>>, into output: inout MutableSpan<InlineArray<48, UInt8>>,
        table: Alphabet.DecodingWindow
    ) -> SIMD16<UInt8> {
        precondition(output.count == blocks.count)
        var invalid = SIMD16<UInt8>()
        for block in blocks.indices {
            let (bytes, bad) = decodeBlock(blocks[block], table: table)
            output[block] = bytes
            invalid |= bad
        }
        return invalid
    }

    /// One block's 48 bytes, and the OR of its values (high bits set: a character not in the alphabet).
    ///
    /// - Parameters:
    ///   - block: 64 characters.
    ///   - table: The alphabet's decoding window.
    /// - Returns: The 48 bytes, and the OR of the values, per lane.
    @inlinable @inline(__always)
    static func decodeBlock(
        _ block: InlineArray<64, UInt8>, table: Alphabet.DecodingWindow
    ) -> (InlineArray<48, UInt8>, SIMD16<UInt8>) {
        let text = bitCast(block, to: InlineArray<4, SIMD16<UInt8>>.self)
        let (c0, c1, c2, c3) = ByteLanes.deinterleave(text[0], text[1], text[2], text[3])
        let v0 = values(of: c0, table), v1 = values(of: c1, table)
        let v2 = values(of: c2, table), v3 = values(of: c3, table)
        let bad = (v0 | v1) | (v2 | v3)
        let (b0, b1, b2) = ByteLanes.interleave(v0 &<< 2 | v1 &>> 4, v1 &<< 4 | v2 &>> 2, v2 &<< 6 | v3)
        return (bitCast([b0, b1, b2] as InlineArray<3, SIMD16<UInt8>>, to: InlineArray<48, UInt8>.self), bad)
    }

    /// Each character's value, or 0xFF if it isn't in the alphabet: the character's offset in the window,
    /// looked up in its first 64 bytes (`tbx`, 0xFF past them), then its last 16 (`tbx` again, keeping the
    /// first lookup past them). Characters below the window wrap to 176 and up, and 0x80 and up land past
    /// it, so both keep the 0xFF.
    ///
    /// - Parameters:
    ///   - characters: 16 characters.
    ///   - table: The alphabet's decoding window.
    /// - Returns: Their values, 0 through 63, or 0xFF.
    @inlinable @inline(__always)
    static func values(of characters: SIMD16<UInt8>, _ table: Alphabet.DecodingWindow) -> SIMD16<UInt8> {
        let index = characters &- table.base
        let low = ByteLanes(index).lookup(in: table.low, keepingOutOfRange: SIMD16(repeating: 0xFF))
        return ByteLanes(index &- SIMD16(repeating: 64)).lookup(in: table.high, keepingOutOfRange: low)
    }

    /// 64 characters moved down by `count` (0 through 63), with "A"s (the value 0) after: four 64-byte
    /// `tbx` lookups, whose indices past the end keep the "A".
    ///
    /// - Parameters:
    ///   - characters: The 64 characters.
    ///   - count: How far to move them toward the front.
    /// - Returns: `characters` without its first `count`, filled to 64 with "A"s.
    @inlinable @inline(__always)
    static func shiftedDown(_ characters: InlineArray<4, SIMD16<UInt8>>, by count: Int) -> InlineArray<4, SIMD16<UInt8>> {
        let table = (characters[0], characters[1], characters[2], characters[3])
        let iota: Byte16 = 0x00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E_0F
        let indices = SIMD16<UInt8>(repeating: UInt8(truncatingIfNeeded: count)) &+ iota.vector
        let filler = SIMD16<UInt8>(repeating: 0x41)
        return [ByteLanes(indices).lookup(in: table, keepingOutOfRange: filler),
                ByteLanes(indices &+ SIMD16(repeating: 16)).lookup(in: table, keepingOutOfRange: filler),
                ByteLanes(indices &+ SIMD16(repeating: 32)).lookup(in: table, keepingOutOfRange: filler),
                ByteLanes(indices &+ SIMD16(repeating: 48)).lookup(in: table, keepingOutOfRange: filler)]
    }

    /// Decodes each 4-character group into 3 bytes; `false` if any character isn't in the alphabet. Compiled
    /// once, here, and checked to vectorize: validity is ORed, with no early exit, and the values come from
    /// arithmetic masks, not a table (a gather) or comparisons (branches). `package`, for the tests.
    ///
    /// - Parameters:
    ///   - groups: The text, 4 characters per element.
    ///   - bytes: Receives 3 bytes per element.
    ///   - alphabet: The characters for 62 and 63.
    /// - Returns: Whether every character was in the alphabet.
    /// - Precondition: `bytes` and `groups` have the same count.
    @usableFromInline @inline(never)
    package static func decode(
        _ groups: Span<InlineArray<4, UInt8>>, into bytes: inout MutableSpan<InlineArray<3, UInt8>>, alphabet: Alphabet
    ) -> Bool {
        precondition(bytes.count == groups.count)
        var valid: UInt8 = 0xFF
        for index in groups.indices {
            let group = groups[index]
            let (a, validA) = value(of: group[0], alphabet)
            let (b, validB) = value(of: group[1], alphabet)
            let (c, validC) = value(of: group[2], alphabet)
            let (d, validD) = value(of: group[3], alphabet)
            valid &= validA & validB & validC & validD
            bytes[index] = [a &<< 2 | b &>> 4, b &<< 4 | c &>> 2, c &<< 6 | d]
        }
        return valid != 0
    }

    /// A character's value, and 0xFF if it's in the alphabet (0 if not), with arithmetic masks: no
    /// branches, so loops of it vectorize.
    ///
    /// - Parameters:
    ///   - character: Any byte.
    ///   - alphabet: The characters for 62 and 63.
    /// - Returns: The value (meaningless if not valid) and `0xFF` if `character` is in the alphabet, else 0.
    @inlinable @inline(__always)
    static func value(of character: UInt8, _ alphabet: Alphabet) -> (value: UInt8, valid: UInt8) {
        let upper = mask(character, from: 65, count: 26) // "A"–"Z": 0–25
        let lower = mask(character, from: 97, count: 26) // "a"–"z": 26–51
        let digit = mask(character, from: 48, count: 10) // "0"–"9": 52–61
        let is62 = mask(character ^ alphabet.character62, from: 0, count: 1)
        let is63 = mask(character ^ alphabet.character63, from: 0, count: 1)
        let value = (upper & (character &- 65)) | (lower & (character &- 71)) | (digit & (character &+ 4))
            | (is62 & 62) | (is63 & 63)
        return (value, upper | lower | digit | is62 | is63)
    }

    /// `0xFF` if `character - low` (wrapping) is below `count` (1 through 128), otherwise 0, for any
    /// character: the high bit of the difference, or of it plus `128 - count`, is set when it isn't.
    ///
    /// - Parameters:
    ///   - character: Any byte.
    ///   - low: The first character of the range.
    ///   - count: The range's length, 1 through 128.
    /// - Returns: `0xFF` or 0.
    @inlinable @inline(__always)
    static func mask(_ character: UInt8, from low: UInt8, count: UInt8) -> UInt8 {
        let difference = character &- low
        return ((difference | (difference &+ (128 &- count))) &>> 7) &- 1
    }

    /// The offset of the first character in `text` that isn't in `alphabet`, or its length. For errors.
    ///
    /// - Parameters:
    ///   - text: The characters to search.
    ///   - alphabet: The characters for 62 and 63.
    /// - Returns: The offset in `text`.
    @usableFromInline @inline(never)
    static func firstInvalidCharacter(in text: RawSpan, alphabet: Alphabet) -> Int {
        for index in 0..<text.byteCount where value(of: text.load(fromByteOffset: index, as: UInt8.self), alphabet).valid == 0 {
            return index
        }
        return text.byteCount
    }
}

extension Base64.Alphabet {
    /// The values of 80 consecutive characters from `base`, 0xFF for those not in the alphabet: the
    /// block kernel's table, as five vectors for `ByteLanes.lookup(in:keepingOutOfRange:)`.
    ///
    /// 80 characters, not all 128 of ASCII: from `+` to `z` (standard) or `-` to `z` (URL-safe) holds every
    /// character of the alphabet, and five table registers instead of eight cut the kernel's lookups from 8
    /// to 5 vector operations per 16 characters, the kernel's limit (see `Benchmarks/RESULTS.md`).
    @usableFromInline
    struct DecodingWindow {
        @usableFromInline var low: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)
        @usableFromInline var high: SIMD16<UInt8>
        /// The window's first character, in every lane.
        @usableFromInline var base: SIMD16<UInt8>

        @inlinable
        init(low: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>), high: SIMD16<UInt8>, base: SIMD16<UInt8>) {
            self.low = low
            self.high = high
            self.base = base
        }
    }

    /// The block kernel's table, or `nil` if the alphabet's characters for 62 and 63 don't fit in 80
    /// characters with the letters and digits (below `+` or past `z`): such alphabets decode with the
    /// portable kernel.
    @inlinable @inline(__always)
    var decodingWindow: DecodingWindow? {
        // The two standard alphabets' windows as constants: building one costs about 60 instructions per
        // call (a 128-byte table stored, two characters set, five vectors loaded back). Compared by their
        // characters, not with `== .standard`, which would check the static's initialization each time.
        if character62 == 0x2B, character63 == 0x2F { // "+", "/": characters 43–122
            return DecodingWindow(
                low: ((0x3E_FF_FF_FF_3F_34_35_36_37_38_39_3A_3B_3C_3D_FF as Byte16).vector, // "+" … "9", ":"
                      (0xFF_FF_FF_FF_FF_FF_00_01_02_03_04_05_06_07_08_09 as Byte16).vector, // ";" … "@", "A"–"J"
                      (0x0A_0B_0C_0D_0E_0F_10_11_12_13_14_15_16_17_18_19 as Byte16).vector, // "K"–"Z"
                      (0xFF_FF_FF_FF_FF_FF_1A_1B_1C_1D_1E_1F_20_21_22_23 as Byte16).vector), // "[" … "`", "a"–"j"
                high: (0x24_25_26_27_28_29_2A_2B_2C_2D_2E_2F_30_31_32_33 as Byte16).vector, // "k"–"z"
                base: SIMD16(repeating: 0x2B)
            )
        }
        if character62 == 0x2D, character63 == 0x5F { // "-", "_": characters 45–124
            return DecodingWindow(
                low: ((0x3E_FF_FF_34_35_36_37_38_39_3A_3B_3C_3D_FF_FF_FF as Byte16).vector, // "-" … "9", ":" … "<"
                      (0xFF_FF_FF_FF_00_01_02_03_04_05_06_07_08_09_0A_0B as Byte16).vector, // "=" … "@", "A"–"L"
                      (0x0C_0D_0E_0F_10_11_12_13_14_15_16_17_18_19_FF_FF as Byte16).vector, // "M"–"Z", "[", "\"
                      (0xFF_FF_3F_FF_1A_1B_1C_1D_1E_1F_20_21_22_23_24_25 as Byte16).vector), // "]" … "`", "a"–"l"
                high: (0x26_27_28_29_2A_2B_2C_2D_2E_2F_30_31_32_33_FF_FF as Byte16).vector, // "m"–"z", "{", "|"
                base: SIMD16(repeating: 0x2D)
            )
        }
        return customDecodingWindow
    }

    /// ``decodingWindow`` for other alphabets, built at run time: out of line, so the standard alphabets'
    /// constants inline without it.
    @usableFromInline @inline(never)
    var customDecodingWindow: DecodingWindow? {
        let base = min(character62, character63, 48) // "0"
        guard base >= 43, max(character62, character63) &- base < 80 else { return nil }
        let table = decodingTable
        // Can't throw: `base` is 43 through 48, so the 80 bytes from it are within the table's 128.
        var reader = try! BytesReader(table.span.bytes, atByteOffset: Int(base))
        let vectors = try! reader.load(InlineArray<5, SIMD16<UInt8>>.self)
        return DecodingWindow(low: (vectors[0], vectors[1], vectors[2], vectors[3]), high: vectors[4],
                              base: SIMD16(repeating: base))
    }

    /// Each ASCII character's value, or 0xFF if it isn't in the alphabet. Constants, with the alphabet's two
    /// characters stored into them.
    @inlinable
    var decodingTable: InlineArray<128, UInt8> {
        precondition(character62 < 128 && character63 < 128, "Decoding needs ASCII characters for 62 and 63")
        // `Byte16` literals (bytes in memory order), which fold to constants: `SIMD16` array literals here
        // compiled to calls to `SIMD.init(_:)`, about 1,200 instructions per call to `decode`.
        let none = Byte16(littleEndian: .max) // 0–47
        let digits: Byte16 = 0x34_35_36_37_38_39_3A_3B_3C_3D_FF_FF_FF_FF_FF_FF // "0"–"9": 52–61
        let upper1: Byte16 = 0xFF_00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E // "A"–"O": 0–14
        let upper2: Byte16 = 0x0F_10_11_12_13_14_15_16_17_18_19_FF_FF_FF_FF_FF // "P"–"Z": 15–25
        let lower1: Byte16 = 0xFF_1A_1B_1C_1D_1E_1F_20_21_22_23_24_25_26_27_28 // "a"–"o": 26–40
        let lower2: Byte16 = 0x29_2A_2B_2C_2D_2E_2F_30_31_32_33_FF_FF_FF_FF_FF // "p"–"z": 41–51
        let vectors: InlineArray<8, SIMD16<UInt8>> = [
            none.vector, none.vector, none.vector, digits.vector,
            upper1.vector, upper2.vector, lower1.vector, lower2.vector,
        ]
        // The alphabet's two characters stored into the table in memory, then loaded back as vectors.
        var table = bitCast(vectors, to: InlineArray<128, UInt8>.self)
        table[Int(character62)] = 62
        table[Int(character63)] = 63
        return table
    }
}
