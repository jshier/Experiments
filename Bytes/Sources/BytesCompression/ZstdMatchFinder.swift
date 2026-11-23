internal import Builtin
internal import Bytes

// Zstandard's fast match finders: libzstd 1.5.7's `fast` (one hash table, two positions searched in a pipeline,
// a repeat offset checked ahead) and `dfast` (a table of 8-byte hashes and one of short ones), without dictionaries.
// Their loops are libzstd's, position for position, so the sequences found are the same; the tests compare frames.
//
// Positions are offsets into `source` (the caller's input, or the streaming window); the tables hold 32-bit indices,
// `position + indexBase`, which keep growing from frame to frame so the tables never need clearing: an index below
// the block's `prefixStart` is from an earlier frame, or out of the window, and is never followed.

/// What a block's match finder reads: the bytes, the block, and how far back matches may reach.
@safe
struct ZstdMatchInput {
    /// The buffer holding the block and the history before it.
    let source: UnsafeRawPointer
    /// The index of `source[0]`.
    let indexBase: Int
    /// The block: `start..<end` in `source`.
    let start: Int
    let end: Int
    /// The earliest position a match may start at: the frame's start, or the window's from the block's end.
    let prefixStart: Int
    /// The frame's first position (negative once it has left the streaming window).
    let frameStart: Int
    /// The window's size: how far back a repeat offset may reach from where it's used.
    let windowSize: Int

    /// The largest repeat offset usable at `position` (`curr - ZSTD_getLowestPrefixIndex(curr)`): the window from
    /// there, or back to the frame's start.
    @inline(__always)
    func maximumRepeat(at position: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: min(position &- frameStart, windowSize))
    }

    @inline(__always)
    func index(_ position: Int) -> UInt32 { UInt32(truncatingIfNeeded: position &+ indexBase) }

    @inline(__always)
    func position(_ index: UInt32) -> Int { Int(index) &- indexBase }

    @inline(__always)
    func load32(_ position: Int) -> UInt32 {
        // Unsafe: an unchecked load. Safe: callers read only positions with 4 bytes before `end`.
        UInt32(littleEndian: unsafe source.loadUnaligned(fromByteOffset: position, as: UInt32.self))
    }

    @inline(__always)
    func load64(_ position: Int) -> UInt64 {
        // Unsafe: an unchecked load. Safe: callers read only positions with 8 bytes before `end`.
        UInt64(littleEndian: unsafe source.loadUnaligned(fromByteOffset: position, as: UInt64.self))
    }

    /// Asks for the cache line at `position` (`PREFETCH_L1`): libzstd's hint where the search skips ahead faster than
    /// the hardware prefetcher follows.
    @inline(__always)
    func prefetch(_ position: Int) {
        // Unsafe: an address computed, not accessed (a prefetch never faults, even past the buffer).
        let address = unsafe source + position
        Builtin.int_prefetch_RawPointer(address._rawValue, Int32(0)._value, Int32(3)._value, Int32(1)._value)
    }

    @inline(__always)
    func byte(_ position: Int) -> UInt8 {
        // Unsafe: an unchecked load. Safe: callers read positions within the buffer, below `end`.
        unsafe source.load(fromByteOffset: position, as: UInt8.self)
    }

    /// The hash of the `length` bytes at `position` in `bits` bits (`ZSTD_hashPtr`, lengths 4 through 8).
    @inline(__always)
    func hash(_ position: Int, bits: Int, length: Int) -> Int {
        switch length {
        case 5:
            return Int(truncatingIfNeeded: ((load64(position) &<< 24) &* 889_523_592_379) &>> UInt64(64 &- bits))
        case 6:
            return Int(truncatingIfNeeded: ((load64(position) &<< 16) &* 227_718_039_650_203) &>> UInt64(64 &- bits))
        case 7:
            return Int(truncatingIfNeeded: ((load64(position) &<< 8) &* 58_295_818_150_454_627) &>> UInt64(64 &- bits))
        case 8:
            return Int(truncatingIfNeeded: (load64(position) &* 0xCF1B_BCDC_B7A5_6463) &>> UInt64(64 &- bits))
        default:
            return Int(truncatingIfNeeded: (load32(position) &* 2_654_435_761) &>> UInt32(32 &- bits))
        }
    }

    /// How many bytes from `position` equal those from `match`, stopping at `limit` (`ZSTD_count`).
    @inline(__always)
    func commonLength(_ position: Int, _ match: Int, limit: Int) -> Int {
        var current = position
        var other = match
        let loopLimit = limit &- 7
        if current < loopLimit {
            let difference = load64(other) ^ load64(current)
            if difference != 0 { return difference.trailingZeroBitCount &>> 3 }
            current &+= 8
            other &+= 8
            while current < loopLimit {
                let difference = load64(other) ^ load64(current)
                if difference != 0 { return current &+ (difference.trailingZeroBitCount &>> 3) &- position }
                current &+= 8
                other &+= 8
            }
        }
        if current < limit &- 3 && load32(other) == load32(current) {
            current &+= 4
            other &+= 4
        }
        if current < limit &- 1 {
            // Unsafe: 2-byte loads, 2 bytes before `limit`.
            let a = unsafe source.loadUnaligned(fromByteOffset: other, as: UInt16.self)
            let b = unsafe source.loadUnaligned(fromByteOffset: current, as: UInt16.self)
            if a == b {
                current &+= 2
                other &+= 2
            }
        }
        if current < limit && byte(other) == byte(current) { current &+= 1 }
        return current &- position
    }
}

/// A block's sequences and literals as the match finder stores them (libzstd's `SeqStore_t`), in the encoder's
/// workspace: each sequence a `UInt64` of its offset code (`offBase`: the offset plus 3, or a repeat code 1–3), its
/// literal length (bits 32–47), and its match length less 3 (bits 48–63). A length over 65,535 (at most one in a
/// 128 KB block) keeps its low 16 bits, and ``longLengthPosition`` marks it.
@safe
struct ZstdSequenceStore {
    let sequences: UnsafeMutablePointer<UInt64>
    let literals: UnsafeMutableRawPointer
    var count = 0
    var literalCount = 0
    /// The sequence with a long length, or -1.
    var longLengthPosition = -1
    /// Whether that length is its match length (else its literal length).
    var longLengthIsMatch = false

    @unsafe
    init(sequences: UnsafeMutablePointer<UInt64>, literals: UnsafeMutableRawPointer) {
        unsafe self.sequences = sequences
        unsafe self.literals = literals
    }

    /// Appends a sequence: `literalLength` literals copied from `anchor`, then a match (`ZSTD_storeSeq`).
    ///
    /// - Parameter wildLimit: Where 32-byte wild copies of literals may still read to: the block's end less 32.
    @inline(__always)
    mutating func store(
        _ input: ZstdMatchInput, anchor: Int, literalLength: Int, wildLimit: Int, offBase: UInt32, matchLength: Int
    ) {
        copyLiterals(input, anchor: anchor, count: literalLength, wildLimit: wildLimit)
        let matchBase = matchLength &- 3
        if literalLength > 0xFFFF || matchBase > 0xFFFF {
            longLengthPosition = count
            longLengthIsMatch = matchBase > 0xFFFF
        }
        // Unsafe: a store below the store's capacity: a block of `n` bytes has at most `n / 4` sequences (every
        // match is at least 4 bytes), and the region holds that many.
        unsafe sequences[count] = UInt64(offBase) | UInt64(UInt16(truncatingIfNeeded: literalLength)) &<< 32
            | UInt64(UInt16(truncatingIfNeeded: matchBase)) &<< 48
        count &+= 1
    }

    /// Copies `count` literals from `anchor`: 16 bytes at a time while the source has 32 bytes of slack.
    @inline(__always)
    mutating func copyLiterals(_ input: ZstdMatchInput, anchor: Int, count: Int, wildLimit: Int) {
        // Unsafe: copies into the literal buffer, which holds a block and 32 bytes of slack for the wild copies'
        // overrun, from the block, which has 32 bytes after `anchor + count` when it's at most `wildLimit`.
        let destination = unsafe literals + literalCount
        let source = unsafe input.source + anchor
        if anchor &+ count <= wildLimit {
            unsafe destination.storeBytes(of: source.loadUnaligned(as: SIMD16<UInt8>.self), as: SIMD16<UInt8>.self)
            if count > 16 {
                var offset = 16
                repeat {
                    unsafe (destination + offset).storeBytes(of: (source + offset).loadUnaligned(as: SIMD16<UInt8>.self), as: SIMD16<UInt8>.self)
                    unsafe (destination + (offset &+ 16)).storeBytes(of: (source + (offset &+ 16)).loadUnaligned(as: SIMD16<UInt8>.self), as: SIMD16<UInt8>.self)
                    offset &+= 32
                } while offset < count
            }
        } else {
            unsafe destination.copyMemory(from: source, byteCount: count)
        }
        literalCount &+= count
    }
}

/// The repeat offsets the match finders track: the decoder's first two (the third isn't searched), 0 when not usable.
typealias ZstdRepeats = (UInt32, UInt32)

enum ZstdMatchFinder {
    /// `kSearchStrength`: the step grows after `1 << (kSearchStrength - 1)` positions (fast) or `1 << kSearchStrength`
    /// (dfast) without a match.
    static var searchStrength: Int { 8 }

    /// The repeat offsets usable from the block's first position, and the ones set aside (`offsetSaved1/2`).
    @inline(__always)
    static func usableRepeats(_ repeats: ZstdRepeats, maximum: UInt32) -> (usable: ZstdRepeats, saved: ZstdRepeats) {
        var usable = repeats
        var saved: ZstdRepeats = (0, 0)
        if usable.1 > maximum {
            saved.1 = usable.1
            usable.1 = 0
        }
        if usable.0 > maximum {
            saved.0 = usable.0
            usable.0 = 0
        }
        return (usable, saved)
    }

    /// The repeat offsets to carry to the next block: those set aside come back where they're still unused.
    @inline(__always)
    static func restoredRepeats(_ repeats: ZstdRepeats, saved: ZstdRepeats) -> ZstdRepeats {
        let saved1 = saved.0 != 0 && repeats.0 != 0 ? saved.0 : saved.1
        return (repeats.0 != 0 ? repeats.0 : saved.0, repeats.1 != 0 ? repeats.1 : saved1)
    }

    // MARK: - fast

    /// libzstd's `ZSTD_compressBlock_fast_noDict_generic`: positions searched two at a time, the table written as it
    /// goes, the repeat offset checked two positions ahead, and the step growing every 128 positions without a match.
    ///
    /// - Returns: The literals after the last sequence.
    @inline(__always)
    static func fastBody(
        _ input: ZstdMatchInput, table: UnsafeMutablePointer<UInt32>, hashLog: Int, targetLength: Int,
        store: inout ZstdSequenceStore, repeats: inout ZstdRepeats, length: Int, select: Bool
    ) -> Int {
        // Unsafe: table loads and stores at hashes below `1 << hashLog`, the table's size. Positions read stay below
        // `end` (8-byte hash reads at or below `ilimit`); match positions are at or after `prefixStart`, validated
        // before they're read (or, for the select form, a valid position is read instead).
        let stepSize = targetLength &+ (targetLength == 0 ? 1 : 0) &+ 1
        let prefixStart = input.prefixStart
        let prefixStartIndex = input.index(prefixStart)
        let end = input.end
        let ilimit = end &- 8
        let wildLimit = end &- 32
        let stepIncrement = 1 &<< (searchStrength &- 1)
        // The store in a local for the loop (an `inout` parameter's fields would be reloaded after every call).
        var sequences = store
        var anchor = input.start
        var ip0 = input.start
        if ip0 == prefixStart { ip0 &+= 1 }
        let (current, saved) = usableRepeats(repeats, maximum: input.maximumRepeat(at: ip0))
        var rep1 = current.0
        var rep2 = current.1

        @inline(__always)
        func found(_ position: Int, _ matchIndex: UInt32) -> Bool {
            if select {
                // libzstd's `ZSTD_match4Found_cmov`: an invalid candidate reads a valid position instead, and the
                // comparison comes first, so the one branch is on a match (rare), not on whether the candidate is in
                // range (unpredictable in small windows). Marked unlikely, LLVM keeps that order (a conditional
                // compare); as one condition, or two of equal weight, it branched on validity first to skip the load.
                // (libzstd keeps them apart with an empty `asm`.)
                let invalid = matchIndex < prefixStartIndex
                let address = invalid ? prefixStart : input.position(matchIndex)
                return unlikely(input.load32(position) == input.load32(address)) && !invalid
            }
            guard matchIndex >= prefixStartIndex else { return false }
            return input.load32(position) == input.load32(input.position(matchIndex))
        }

        search: while true {
            var step = stepSize
            var nextStep = ip0 &+ stepIncrement
            var ip1 = ip0 &+ 1
            var ip2 = ip0 &+ step
            var ip3 = ip2 &+ 1
            if ip3 >= ilimit { break search }
            var hash0 = input.hash(ip0, bits: hashLog, length: length)
            var hash1 = input.hash(ip1, bits: hashLog, length: length)
            var matchIndex = unsafe table[hash0]
            var current0: UInt32 = 0
            var match0 = 0
            var matchLength = 0
            var offBase: UInt32 = 0
            var isRepeat = false

            pipeline: repeat {
                // The repeat offset at ip2.
                let repeatValue = input.load32(ip2 &- Int(rep1))
                current0 = input.index(ip0)
                unsafe table[hash0] = current0
                if input.load32(ip2) == repeatValue && rep1 > 0 {
                    ip0 = ip2
                    match0 = ip0 &- Int(rep1)
                    matchLength = input.byte(ip0 &- 1) == input.byte(match0 &- 1) ? 1 : 0
                    ip0 &-= matchLength
                    match0 &-= matchLength
                    offBase = 1
                    matchLength &+= 4
                    unsafe table[hash1] = input.index(ip1)
                    isRepeat = true
                    break pipeline
                }
                if found(ip0, matchIndex) {
                    unsafe table[hash1] = input.index(ip1)
                    break pipeline
                }
                matchIndex = unsafe table[hash1]
                hash0 = hash1
                hash1 = input.hash(ip2, bits: hashLog, length: length)
                ip0 = ip1
                ip1 = ip2
                ip2 = ip3

                current0 = input.index(ip0)
                unsafe table[hash0] = current0
                if found(ip0, matchIndex) {
                    if step <= 4 { unsafe table[hash1] = input.index(ip1) }
                    break pipeline
                }
                matchIndex = unsafe table[hash1]
                hash0 = hash1
                hash1 = input.hash(ip2, bits: hashLog, length: length)
                ip0 = ip1
                ip1 = ip2
                ip2 = ip0 &+ step
                ip3 = ip1 &+ step
                if ip2 >= nextStep {
                    step &+= 1
                    input.prefetch(ip1 &+ 64)
                    input.prefetch(ip1 &+ 128)
                    nextStep &+= stepIncrement
                }
                if ip3 >= ilimit { break search }
            } while true

            if !isRepeat {
                // A new offset.
                match0 = input.position(matchIndex)
                rep2 = rep1
                rep1 = UInt32(truncatingIfNeeded: ip0 &- match0)
                offBase = rep1 &+ 3
                matchLength = 4
                while ip0 > anchor && match0 > prefixStart && input.byte(ip0 &- 1) == input.byte(match0 &- 1) {
                    ip0 &-= 1
                    match0 &-= 1
                    matchLength &+= 1
                }
            }

            matchLength &+= input.commonLength(ip0 &+ matchLength, match0 &+ matchLength, limit: end)
            sequences.store(input, anchor: anchor, literalLength: ip0 &- anchor, wildLimit: wildLimit, offBase: offBase, matchLength: matchLength)
            ip0 &+= matchLength
            anchor = ip0

            if ip0 <= ilimit {
                // Fill the table, and take any immediate repeats of the second offset.
                let after = input.position(current0) &+ 2
                unsafe table[input.hash(after, bits: hashLog, length: length)] = current0 &+ 2
                unsafe table[input.hash(ip0 &- 2, bits: hashLog, length: length)] = input.index(ip0 &- 2)
                if rep2 > 0 {
                    while ip0 <= ilimit && input.load32(ip0) == input.load32(ip0 &- Int(rep2)) {
                        let repeatLength = input.commonLength(ip0 &+ 4, ip0 &+ 4 &- Int(rep2), limit: end) &+ 4
                        swap(&rep1, &rep2)
                        unsafe table[input.hash(ip0, bits: hashLog, length: length)] = input.index(ip0)
                        ip0 &+= repeatLength
                        sequences.store(input, anchor: anchor, literalLength: 0, wildLimit: wildLimit, offBase: 1, matchLength: repeatLength)
                        anchor = ip0
                    }
                }
            }
        }

        repeats = restoredRepeats((rep1, rep2), saved: saved)
        store = sequences
        return end &- anchor
    }

    // MARK: - dfast

    /// libzstd's `ZSTD_compressBlock_doubleFast_noDict_generic`: an 8-byte hash table (`hashLog` bits) and a
    /// `length`-byte one (`chainLog` bits) checked at each position, the long match first; a short match is
    /// replaced by a longer one at the next position when there is one.
    ///
    /// - Returns: The literals after the last sequence.
    @inline(__always)
    static func doubleFastBody(
        _ input: ZstdMatchInput, long: UnsafeMutablePointer<UInt32>, hashLog: Int, short: UnsafeMutablePointer<UInt32>,
        chainLog: Int, store: inout ZstdSequenceStore, repeats: inout ZstdRepeats, length: Int
    ) -> Int {
        // Unsafe: table loads and stores at hashes below each table's size. Positions read stay below `end` (8-byte
        // reads at or below `ilimit`); match positions are validated against `prefixStart` before they're read (an
        // invalid one reads `prefixStart` instead, and is then rejected).
        let prefixStart = input.prefixStart
        let prefixStartIndex = input.index(prefixStart)
        let end = input.end
        let ilimit = end &- 8
        let wildLimit = end &- 32
        let stepIncrement = 1 &<< searchStrength
        // The store stays in its `inout` parameter, in memory: it's touched once a match, and its six fields in
        // registers pushed the search loop's hash constants out (rematerialized every position).
        var anchor = input.start
        var ip = input.start
        if ip == prefixStart { ip &+= 1 }
        let (current, saved) = usableRepeats(repeats, maximum: input.maximumRepeat(at: ip))
        var rep1 = current.0
        var rep2 = current.1

        @inline(__always)
        func longHash(_ position: Int) -> Int { input.hash(position, bits: hashLog, length: 8) }
        @inline(__always)
        func shortHash(_ position: Int) -> Int { input.hash(position, bits: chainLog, length: length) }

        search: while true {
            var step = 1
            var nextStep = ip &+ stepIncrement
            var ip1 = ip &+ step
            if ip1 > ilimit { break search }
            var longHash0 = longHash(ip)
            var longIndex0 = unsafe long[longHash0]
            var longHash1 = 0
            var longIndex1: UInt32 = 0
            var currentIndex: UInt32 = 0
            var matchLength = 0
            var offset = 0
            var shortMatch = 0
            // What the positions loop found: 0 nothing (the block's end), 1 the repeat offset, 2 a long match, 3 a
            // short one.
            var found = 0

            positions: repeat {
                let shortHash0 = shortHash(ip)
                let shortIndex0 = unsafe short[shortHash0]
                currentIndex = input.index(ip)
                unsafe long[longHash0] = currentIndex
                unsafe short[shortHash0] = currentIndex

                // The repeat offset at the next position.
                if rep1 > 0 && input.load32(ip &+ 1 &- Int(rep1)) == input.load32(ip &+ 1) {
                    matchLength = input.commonLength(ip &+ 5, ip &+ 5 &- Int(rep1), limit: end) &+ 4
                    ip &+= 1
                    found = 1
                    break positions
                }

                longHash1 = longHash(ip1)
                // A long match here. Validity joins the comparison as a bit, so the branch is on a match, not on
                // whether the candidate is in the window (libzstd's `ZSTD_selectAddr`; see `fastBody`).
                let longInvalid = longIndex0 < prefixStartIndex
                let longMatch = longInvalid ? prefixStart : input.position(longIndex0)
                if unlikely(input.load64(longMatch) == input.load64(ip)), !longInvalid {
                    matchLength = input.commonLength(ip &+ 8, longMatch &+ 8, limit: end) &+ 8
                    offset = ip &- longMatch
                    var match = longMatch
                    while ip > anchor && match > prefixStart && input.byte(ip &- 1) == input.byte(match &- 1) {
                        ip &-= 1
                        match &-= 1
                        matchLength &+= 1
                    }
                    found = 2
                    break positions
                }

                longIndex1 = unsafe long[longHash1]
                // A short match here: then look for a long one at the next position.
                let shortInvalid = shortIndex0 < prefixStartIndex
                let shortCandidate = shortInvalid ? prefixStart : input.position(shortIndex0)
                if unlikely(input.load32(shortCandidate) == input.load32(ip)), !shortInvalid {
                    shortMatch = shortCandidate
                    found = 3
                    break positions
                }

                if ip1 >= nextStep {
                    input.prefetch(ip1 &+ 64)
                    input.prefetch(ip1 &+ 128)
                    step &+= 1
                    nextStep &+= stepIncrement
                }
                ip = ip1
                ip1 &+= step
                longHash0 = longHash1
                longIndex0 = longIndex1
                // libzstd's aarch64 build reads ahead every position.
                input.prefetch(ip &+ 256)
            } while ip1 <= ilimit
            if found == 0 { break search }

            if found != 1 {
                if found == 3 {
                    // The short match, unless the next position has a longer long one.
                    var match = shortMatch
                    matchLength = input.commonLength(ip &+ 4, match &+ 4, limit: end) &+ 4
                    offset = ip &- match
                    if longIndex1 > prefixStartIndex {
                        let longMatch = input.position(longIndex1)
                        if input.load64(longMatch) == input.load64(ip1) {
                            let longLength = input.commonLength(ip1 &+ 8, longMatch &+ 8, limit: end) &+ 8
                            if longLength > matchLength {
                                ip = ip1
                                matchLength = longLength
                                offset = ip &- longMatch
                                match = longMatch
                            }
                        }
                    }
                    while ip > anchor && match > prefixStart && input.byte(ip &- 1) == input.byte(match &- 1) {
                        ip &-= 1
                        match &-= 1
                        matchLength &+= 1
                    }
                }
                rep2 = rep1
                rep1 = UInt32(truncatingIfNeeded: offset)
                if step < 4 { unsafe long[longHash1] = input.index(ip1) }
                store.store(input, anchor: anchor, literalLength: ip &- anchor, wildLimit: wildLimit, offBase: rep1 &+ 3, matchLength: matchLength)
            } else {
                store.store(input, anchor: anchor, literalLength: ip &- anchor, wildLimit: wildLimit, offBase: 1, matchLength: matchLength)
            }

            ip &+= matchLength
            anchor = ip
            if ip <= ilimit {
                // Fill the tables, and take any immediate repeats of the second offset.
                let insert = currentIndex &+ 2
                let insertPosition = input.position(insert)
                unsafe long[longHash(insertPosition)] = insert
                unsafe long[longHash(ip &- 2)] = input.index(ip &- 2)
                unsafe short[shortHash(insertPosition)] = insert
                unsafe short[shortHash(ip &- 1)] = input.index(ip &- 1)
                while ip <= ilimit && rep2 > 0 && input.load32(ip) == input.load32(ip &- Int(rep2)) {
                    let repeatLength = input.commonLength(ip &+ 4, ip &+ 4 &- Int(rep2), limit: end) &+ 4
                    swap(&rep1, &rep2)
                    unsafe short[shortHash(ip)] = input.index(ip)
                    unsafe long[longHash(ip)] = input.index(ip)
                    store.store(input, anchor: anchor, literalLength: 0, wildLimit: wildLimit, offBase: 1, matchLength: repeatLength)
                    ip &+= repeatLength
                    anchor = ip
                }
            }
        }

        repeats = restoredRepeats((rep1, rep2), saved: saved)
        return end &- anchor
    }

    // MARK: - Specialized copies

    // Each strategy's loop for each hash length, as its own function: the length a constant in it (libzstd's
    // templates). The fast loop's select form (a candidate's validity chosen without a branch) for small windows, where
    // candidates are often out of range; the branch form for large ones (libzstd's choice: window logs below 19).

    @inline(never)
    static func fast4(_ i: ZstdMatchInput, _ t: UnsafeMutablePointer<UInt32>, _ h: Int, _ tl: Int, _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats) -> Int {
        unsafe fastBody(i, table: t, hashLog: h, targetLength: tl, store: &s, repeats: &r, length: 4, select: false)
    }
    @inline(never)
    static func fast5(_ i: ZstdMatchInput, _ t: UnsafeMutablePointer<UInt32>, _ h: Int, _ tl: Int, _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats) -> Int {
        unsafe fastBody(i, table: t, hashLog: h, targetLength: tl, store: &s, repeats: &r, length: 5, select: false)
    }
    @inline(never)
    static func fast6(_ i: ZstdMatchInput, _ t: UnsafeMutablePointer<UInt32>, _ h: Int, _ tl: Int, _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats) -> Int {
        unsafe fastBody(i, table: t, hashLog: h, targetLength: tl, store: &s, repeats: &r, length: 6, select: false)
    }
    @inline(never)
    static func fast7(_ i: ZstdMatchInput, _ t: UnsafeMutablePointer<UInt32>, _ h: Int, _ tl: Int, _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats) -> Int {
        unsafe fastBody(i, table: t, hashLog: h, targetLength: tl, store: &s, repeats: &r, length: 7, select: false)
    }
    @inline(never)
    static func fastSelect4(_ i: ZstdMatchInput, _ t: UnsafeMutablePointer<UInt32>, _ h: Int, _ tl: Int, _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats) -> Int {
        unsafe fastBody(i, table: t, hashLog: h, targetLength: tl, store: &s, repeats: &r, length: 4, select: true)
    }
    @inline(never)
    static func fastSelect5(_ i: ZstdMatchInput, _ t: UnsafeMutablePointer<UInt32>, _ h: Int, _ tl: Int, _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats) -> Int {
        unsafe fastBody(i, table: t, hashLog: h, targetLength: tl, store: &s, repeats: &r, length: 5, select: true)
    }
    @inline(never)
    static func fastSelect6(_ i: ZstdMatchInput, _ t: UnsafeMutablePointer<UInt32>, _ h: Int, _ tl: Int, _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats) -> Int {
        unsafe fastBody(i, table: t, hashLog: h, targetLength: tl, store: &s, repeats: &r, length: 6, select: true)
    }
    @inline(never)
    static func fastSelect7(_ i: ZstdMatchInput, _ t: UnsafeMutablePointer<UInt32>, _ h: Int, _ tl: Int, _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats) -> Int {
        unsafe fastBody(i, table: t, hashLog: h, targetLength: tl, store: &s, repeats: &r, length: 7, select: true)
    }

    @inline(never)
    static func doubleFast4(
        _ i: ZstdMatchInput, _ l: UnsafeMutablePointer<UInt32>, _ h: Int, _ t: UnsafeMutablePointer<UInt32>, _ c: Int,
        _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats
    ) -> Int {
        unsafe doubleFastBody(i, long: l, hashLog: h, short: t, chainLog: c, store: &s, repeats: &r, length: 4)
    }
    @inline(never)
    static func doubleFast5(
        _ i: ZstdMatchInput, _ l: UnsafeMutablePointer<UInt32>, _ h: Int, _ t: UnsafeMutablePointer<UInt32>, _ c: Int,
        _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats
    ) -> Int {
        unsafe doubleFastBody(i, long: l, hashLog: h, short: t, chainLog: c, store: &s, repeats: &r, length: 5)
    }
    @inline(never)
    static func doubleFast6(
        _ i: ZstdMatchInput, _ l: UnsafeMutablePointer<UInt32>, _ h: Int, _ t: UnsafeMutablePointer<UInt32>, _ c: Int,
        _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats
    ) -> Int {
        unsafe doubleFastBody(i, long: l, hashLog: h, short: t, chainLog: c, store: &s, repeats: &r, length: 6)
    }
    @inline(never)
    static func doubleFast7(
        _ i: ZstdMatchInput, _ l: UnsafeMutablePointer<UInt32>, _ h: Int, _ t: UnsafeMutablePointer<UInt32>, _ c: Int,
        _ s: inout ZstdSequenceStore, _ r: inout ZstdRepeats
    ) -> Int {
        unsafe doubleFastBody(i, long: l, hashLog: h, short: t, chainLog: c, store: &s, repeats: &r, length: 7)
    }
}
