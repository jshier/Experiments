public import Bytes

/// Base64 encoding (RFC 4648), from a ``BytesReader`` into a ``BytesWriter``: no allocation, and vectorized.
///
/// ```swift
/// var reader = BytesReader(bytes.span)
/// var output = [UInt8](repeating: 0, count: Base64.encodedByteCount(of: bytes.count))
/// var span = output.mutableSpan
/// var writer = BytesWriter(&span)
/// try Base64.encode(&reader, into: &writer)
/// ```
///
/// Input is read as typed spans of fixed-size blocks (`BytesReader.read(_:count:)`) and output written the same
/// way (`BytesWriter.write(_:count:filling:)`), so each kernel is a loop from one span to another, with its
/// bounds checks folded out of the loop. Two kernels:
/// - **ARM64** (`ByteLanes.isLookupVectorized`): 48-byte blocks, 29–32 instructions each, with Bytes' NEON
///   helpers. `deinterleave` splits a block into its groups' first, second, and third bytes (3 `tbl`), as
///   `ld3` would. Shifts and masks make the four 6-bit values per group. `lookup(in:)` maps them to the
///   alphabet (4 `tbl`). `interleave` puts the characters in order, as `st4` would (`zip`s). The last 0 to
///   47 bytes are one more block, zero-padded. About 21 GB/s on an M3 Ultra, 93% of a hand-written C kernel
///   that uses `ld3` and `st4`.
/// - **Elsewhere**: 3-byte groups to 4-character groups, mapped with arithmetic, which LLVM vectorizes
///   (on ARM64, to `ld3`, compares, and `st4`; 9 GB/s there). It's arithmetic, not a table: a table lookup
///   would be a gather, which stops the vectorizer.
public enum Base64 {
    /// The 64 characters: `A`–`Z`, `a`–`z`, `0`–`9`, then two that differ between alphabets.
    public struct Alphabet: Hashable, Sendable {
        /// The characters for 62 and 63.
        public let character62: UInt8
        public let character63: UInt8

        /// `+` and `/` (RFC 4648 section 4).
        public static let standard = Alphabet(character62: UInt8(ascii: "+"), character63: UInt8(ascii: "/"))
        /// `-` and `_`, safe in URLs and file names (RFC 4648 section 5).
        public static let urlSafe = Alphabet(character62: UInt8(ascii: "-"), character63: UInt8(ascii: "_"))

        @inlinable
        public init(character62: UInt8, character63: UInt8) {
            self.character62 = character62
            self.character63 = character63
        }

        /// The 64 characters as four vectors, for `ByteLanes.lookup(in:)`.
        @inlinable
        var table: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>) {
            // One initializer per vector: a constant, plus two inserts for the last. (An array literal changed
            // lane by lane compiled to 16 inserts.)
            ([65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80],                                // "A"–"P"
             [81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 97, 98, 99, 100, 101, 102],                            // "Q"–"Z", "a"–"f"
             [103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118],              // "g"–"v"
             SIMD16(119, 120, 121, 122, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, character62, character63)) // "w"–"z", "0"–"9"
        }

        /// What to add from 62 on top of the digits' offset to get `character62`, then from 63 on top of that to
        /// get `character63` (wrapping).
        @inlinable @inline(__always)
        var deltas: (UInt8, UInt8) {
            let from62 = character62 &- 62 &- 252
            return (from62, character63 &- 63 &- 252 &- from62)
        }
    }

    /// The length of `byteCount` bytes encoded: 4 characters per 3 bytes, the last group padded with `=` to 4
    /// characters, or without padding, 2 or 3.
    @inlinable
    public static func encodedByteCount(of byteCount: Int, padding: Bool = true) -> Int {
        precondition(byteCount >= 0 && byteCount <= Int.max / 4 * 3, "Byte count out of range")
        let (groups, remainder) = byteCount.quotientAndRemainder(dividingBy: 3)
        guard remainder > 0 else { return groups &* 4 }
        return groups &* 4 &+ (padding ? 4 : remainder &+ 1)
    }

    /// Encodes the rest of `reader` into `writer`. Requires `reader` to be byte-aligned and `writer` too.
    ///
    /// Throws ``BytesError/insufficientCapacity`` if `writer` doesn't have room for
    /// ``encodedByteCount(of:padding:)`` bytes, before reading or writing anything.
    @inlinable
    public static func encode(
        _ reader: inout BytesReader, into writer: inout BytesWriter, alphabet: Alphabet = .standard, padding: Bool = true
    ) throws(BytesError) {
        let byteCount = reader.remainingByteCount
        guard writer.remainingByteCount >= encodedByteCount(of: byteCount, padding: padding) else {
            throw .insufficientCapacity
        }
        // Where table lookups are single instructions (ARM64): 48-byte blocks, then the last 0 to 47 bytes as
        // one more block, zero-padded. (Zeros after the last byte are what its group's last characters
        // encode; the characters past the end are dropped or replaced with "=".)
        if ByteLanes.isLookupVectorized {
            let table = alphabet.table
            let blocks = try reader.read(InlineArray<48, UInt8>.self, count: byteCount / 48)
            try writer.write(InlineArray<64, UInt8>.self, count: blocks.count, filling: { (characters) in
                encodeBlocks(blocks, into: &characters, table: table)
            })
            let rest = reader.remainingByteCount
            guard rest > 0 else { return }
            var block = InlineArray<48, UInt8>(repeating: 0)
            var blockBytes = block.mutableSpan
            var blockWriter = BytesWriter(&blockBytes)
            try blockWriter.write(try reader.read(byteCount: rest))
            let characters = encodeBlock(block, table: table)
            try writer.write(characters.span.bytes.extracting(0..<encodedByteCount(of: rest, padding: false)))
            if padding {
                for _ in 0..<((3 &- rest % 3) % 3) { try writer.write(0x3D as Byte) } // "="
            }
            return
        }
        // Elsewhere: 3-byte groups with arithmetic, then the last 1 or 2 bytes.
        let groups = try reader.read(InlineArray<3, UInt8>.self, count: byteCount / 3)
        try writer.write(InlineArray<4, UInt8>.self, count: groups.count, filling: { (characters) in
            encode(groups, into: &characters, alphabet: alphabet)
        })
        // The last 1 or 2 bytes: 2 or 3 characters, then padding.
        switch byteCount % 3 {
        case 1:
            let byte = try reader.read(Byte.self).rawValue
            try writer.write(Byte(character(byte &>> 2, alphabet.deltas)))
            try writer.write(Byte(character((byte & 0b11) &<< 4, alphabet.deltas)))
            if padding { try writer.write(0x3D_3D as Byte2) } // "=="
        case 2:
            let bytes = try reader.read(Byte2.self, .bigEndian)
            try writer.write(Byte(character(UInt8(truncatingIfNeeded: bytes &>> 10), alphabet.deltas)))
            try writer.write(Byte(character(UInt8(truncatingIfNeeded: bytes &>> 4) & 0b11_1111, alphabet.deltas)))
            try writer.write(Byte(character(UInt8(truncatingIfNeeded: bytes &<< 2) & 0b11_1100, alphabet.deltas)))
            if padding { try writer.write(0x3D as Byte) } // "="
        default:
            break
        }
    }

    /// Encodes `bytes` into `writer`.
    @inlinable
    public static func encode(
        _ bytes: RawSpan, into writer: inout BytesWriter, alphabet: Alphabet = .standard, padding: Bool = true
    ) throws(BytesError) {
        var reader = BytesReader(bytes)
        try encode(&reader, into: &writer, alphabet: alphabet, padding: padding)
    }

    /// `bytes` encoded as a `String`: one allocation, the string's (none for 15 characters or fewer).
    @inlinable
    public static func encodedString(_ bytes: RawSpan, alphabet: Alphabet = .standard, padding: Bool = true) -> String {
        let count = encodedByteCount(of: bytes.byteCount, padding: padding)
        // Unsafe: the string's uninitialized storage, which only this initializer exposes (no `OutputSpan`
        // initializer is public). Safe: the writer covers exactly `count` bytes of it, `encode` fills all
        // of them (it was given exactly the room it needs, so it can't throw), and the initializer gets that
        // count back.
        return String(unsafeUninitializedCapacity: count) { buffer in
            var writer = unsafe BytesWriter(MutableRawSpan(_unsafeBytes: UnsafeMutableRawBufferPointer(buffer)))
            try! encode(bytes, into: &writer, alphabet: alphabet, padding: padding)
            return writer.byteCount
        }
    }

    // MARK: - The kernels

    /// Encodes 48-byte blocks into 64 characters each, with Bytes' NEON helpers:
    /// - `ByteLanes.deinterleave` splits each block into its groups' first, second, and third bytes, as
    ///   `ld3` does when loading (three `tbl` lookups);
    /// - shifts and masks make each group's four 6-bit values;
    /// - `ByteLanes.lookup(in:)` maps them to characters in the 64-byte alphabet (four `tbl` lookups);
    /// - `ByteLanes.interleave` puts the characters in output order, as `st4` does when storing (eight
    ///   `zip`s).
    ///
    /// Blocks are elements of typed spans, a block of input and a block of output each, so a loop over the
    /// indices has one bounds check per span, which folds: offsets into raw spans (a check per load and
    /// store) took a third of the loop. Each block is bit-cast to and from vectors. Compiled once, here.
    @usableFromInline @inline(never)
    static func encodeBlocks(
        _ blocks: Span<InlineArray<48, UInt8>>, into output: inout MutableSpan<InlineArray<64, UInt8>>,
        table: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)
    ) {
        precondition(output.count == blocks.count)
        for block in blocks.indices {
            output[block] = encodeBlock(blocks[block], table: table)
        }
    }

    /// One block's 64 characters.
    @inlinable @inline(__always)
    static func encodeBlock(
        _ block: InlineArray<48, UInt8>, table: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)
    ) -> InlineArray<64, UInt8> {
        let source = bitCast(block, to: InlineArray<3, SIMD16<UInt8>>.self)
        let (first, second, third) = ByteLanes.deinterleave(source[0], source[1], source[2])
        let (c0, c1, c2, c3) = ByteLanes.interleave(
            ByteLanes(first &>> 2).lookup(in: table),
            ByteLanes((first &<< 4 | second &>> 4) & 0b11_1111).lookup(in: table),
            ByteLanes((second &<< 2 | third &>> 6) & 0b11_1111).lookup(in: table),
            ByteLanes(third & 0b11_1111).lookup(in: table)
        )
        return bitCast([c0, c1, c2, c3] as InlineArray<4, SIMD16<UInt8>>, to: InlineArray<64, UInt8>.self)
    }


    /// Encodes each 3-byte group into 4 characters. Compiled once, here, and checked to vectorize: a
    /// typed-span-to-typed-span loop with no table lookups (see the type's documentation).
    @usableFromInline @inline(never)
    static func encode(
        _ groups: Span<InlineArray<3, UInt8>>, into characters: inout MutableSpan<InlineArray<4, UInt8>>,
        alphabet: Alphabet
    ) {
        precondition(characters.count == groups.count)
        let deltas = alphabet.deltas
        for index in groups.indices {
            let group = groups[index]
            characters[index] = [
                character(group[0] &>> 2, deltas),
                character((group[0] & 0b11) &<< 4 | group[1] &>> 4, deltas),
                character((group[1] & 0b1111) &<< 2 | group[2] &>> 6, deltas),
                character(group[2] & 0b11_1111, deltas),
            ]
        }
    }

    /// The character for a 6-bit value: `A`–`Z` from 0, `a`–`z` from 26, `0`–`9` from 52, then the
    /// alphabet's two. The value plus an offset per range: 65 (`A` − 0), then 6 more from 26 (`a` − 26),
    /// 181 more from 52 (`0` − 52, wrapping), then the alphabet's deltas from 62 and from 63.
    ///
    /// No compares: written with `if`s or ternaries, the range tests are correlated (a value of at least
    /// 62 is at least 52), and LLVM threads them into branches instead of selects, depending on the pass
    /// pipeline, and branches stop the loop from vectorizing. Arithmetic can't become a branch.
    @inlinable @inline(__always)
    static func character(_ value: UInt8, _ deltas: (UInt8, UInt8)) -> UInt8 {
        let from26 = mask(value, atLeast: 26)
        let from52 = mask(value, atLeast: 52)
        let from62 = mask(value, atLeast: 62)
        let from63 = mask(value, atLeast: 63)
        return value &+ 65 &+ (from26 & 6) &+ (from52 & 181) &+ (from62 & deltas.0) &+ (from63 & deltas.1)
    }

    /// `0xFF` if `value` (below 64) is at least `bound` (1 through 64), otherwise 0: the high bit of
    /// `value + 128 - bound`, which doesn't wrap for these ranges, spread to the whole byte.
    @inlinable @inline(__always)
    static func mask(_ value: UInt8, atLeast bound: UInt8) -> UInt8 {
        0 &- ((value &+ (128 &- bound)) &>> 7)
    }
}
