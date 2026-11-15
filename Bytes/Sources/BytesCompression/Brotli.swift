internal import Bytes

/// Brotli's fixed tables (RFC 7932), shared by the decoder and encoder.
enum Brotli {
    /// The block count code's (26 symbols) base values and extra-bit counts.
    static var blockCountBases: InlineArray<26, UInt32> {
        [1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625]
    }

    static var blockCountExtraBits: InlineArray<26, UInt8> {
        [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24]
    }

    static var insertBases: InlineArray<24, UInt32> {
        [0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594]
    }

    static var insertExtraBits: InlineArray<24, UInt8> {
        [0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24]
    }

    static var copyBases: InlineArray<24, UInt32> {
        [2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118]
    }

    static var copyExtraBits: InlineArray<24, UInt8> {
        [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24]
    }

    /// The insert-and-copy alphabet's 11 cells of 64 symbols: each cell's first insert-length and copy-length
    /// codes. Cells 0 and 1 also mean "the last distance", with no distance code.
    static var cellInsertCodes: InlineArray<11, UInt8> { [0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16] }
    static var cellCopyCodes: InlineArray<11, UInt8> { [0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16] }

    /// The order the complex prefix code lists its code-length code's lengths in.
    static var codeLengthOrder: InlineArray<18, UInt8> { [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15] }

    /// The code-length code's lengths are themselves coded with a fixed variable-length code: indexed by the
    /// next 4 bits, its length and value (Google's `kCodeLengthPrefixLength` and `kCodeLengthPrefixValue`).
    static var codeLengthPrefixLengths: InlineArray<16, UInt8> { [2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4] }
    static var codeLengthPrefixValues: InlineArray<16, UInt8> { [0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5] }

    /// The static dictionary: for each word length (4 through 24), log2 of its word count and the offset of
    /// its words.
    static var dictionarySizeBits: InlineArray<25, UInt8> {
        [0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5]
    }

    static var dictionaryOffsets: InlineArray<25, UInt32> {
        [0, 0, 0, 0, 0, 4096, 9216, 21504, 35840, 44032, 53248, 63488, 74752, 87040, 93696, 100864, 104704,
         106752, 108928, 113536, 115968, 118528, 119872, 121280, 122016]
    }

    static var transformCount: Int { 121 }

    /// The largest table a prefix code over an alphabet can need with 8-bit roots, by `(size + 31) / 32`
    /// (Google's `kMaxHuffmanTableSize`, computed as zlib's `enough` does).
    static var maximumTableSizes: InlineArray<23, UInt16> {
        [256, 402, 436, 468, 500, 534, 566, 598, 630, 662, 694, 726, 758, 790, 822, 854, 886, 920, 952, 984, 1016, 1048, 1080]
    }

    static func maximumTableSize(alphabetSize: Int) -> Int {
        Int(maximumTableSizes[min((alphabetSize &+ 31) &>> 5, 22)])
    }

    /// The dictionary's bytes, viewed from the static words.
    @inline(__always)
    static func withDictionary<R>(_ body: (RawSpan) -> R) -> R {
        let words = brotliDictionaryWords // A local to borrow from: a span of the global can't outlive the access.
        return body(words.span.bytes)
    }

    /// Transforms dictionary word `word` (bytes of `dictionary`) with transform `transform` into `output`
    /// (RFC 7932, section 8): prefix, the word with its first or last bytes omitted or uppercased, suffix.
    ///
    /// - Returns: The transformed word's length (at most 38).
    static func transform(
        _ dictionary: RawSpan, word: Int, length: Int, transform: Int, into output: inout InlineArray<48, UInt8>
    ) -> Int {
        let packed = brotliTransforms[transform]
        let prefix = Int(truncatingIfNeeded: packed & 0xFFFF)
        let type = Int(truncatingIfNeeded: packed &>> 16 & 0xFF)
        let suffix = Int(truncatingIfNeeded: packed &>> 32 & 0xFFFF)
        var count = 0
        let prefixLength = Int(brotliTransformStrings[prefix])
        for index in 0..<prefixLength {
            output[count] = brotliTransformStrings[prefix &+ 1 &+ index]
            count &+= 1
        }
        var start = word
        var wordLength = length
        if type <= 9 {
            wordLength &-= type
        } else if type >= 12 {
            let skip = type &- 11
            start &+= skip
            wordLength &-= skip
        }
        let wordStart = count
        var index = 0
        while index < wordLength {
            output[count] = dictionary.load(fromByteOffset: start &+ index, as: UInt8.self)
            count &+= 1
            index &+= 1
        }
        if type == 10 || type == 11 {
            // RFC 7932's simplified UTF-8 uppercasing: ASCII letters flip case; a 2-byte character flips bit 5
            // of its second byte, a 3-byte one XORs its third byte with 5. It may touch up to 2 bytes past the
            // word, which the suffix then overwrites (`output` has the room).
            var position = wordStart
            var remaining = max(wordLength, 0)
            while remaining > 0 {
                let lead = output[position]
                let step: Int
                if lead < 0xC0 {
                    if lead >= 0x61 && lead <= 0x7A { output[position] = lead ^ 32 }
                    step = 1
                } else if lead < 0xE0 {
                    output[position &+ 1] ^= 32
                    step = 2
                } else {
                    output[position &+ 2] ^= 5
                    step = 3
                }
                if type == 10 { break }
                position &+= step
                remaining &-= step
            }
        }
        let suffixLength = Int(brotliTransformStrings[suffix])
        for index in 0..<suffixLength {
            output[count] = brotliTransformStrings[suffix &+ 1 &+ index]
            count &+= 1
        }
        return count
    }
}
