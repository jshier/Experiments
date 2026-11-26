internal import Builtin
internal import Bytes

// Zstandard's fast match finders: libzstd 1.5.7's `fast` (one hash table, two positions searched in a pipeline,
// a repeat offset checked ahead) and `dfast` (a table of 8-byte hashes and one of short ones), without dictionaries.
// Their loops are libzstd's, position for position, so the sequences found are the same; the tests compare frames.
//
// The tables hold 32-bit indices, which keep growing from frame to frame so the tables never need clearing: an index
// below the block's `prefixStart` is from an earlier frame, or out of the window, and is never followed. Positions are
// those indices (as `Int`s), read at `base + position`, `base` being the buffer's address less its first byte's index
// (libzstd's `base`): so a table entry is a position, with nothing to add either way.

/// What a block's match finder reads: the bytes, the block, and how far back matches may reach. Positions are indices
/// (see above).
@safe
struct ZstdMatchInput {
    /// The address of index 0: the buffer's less its first byte's index. Read only at positions inside the buffer.
    let base: UnsafeRawPointer
    /// The block: `start..<end`.
    let start: Int
    let end: Int
    /// The earliest position a match may start at: the frame's start, or the window's from the block's end.
    let prefixStart: Int
    /// The frame's first position (before the buffer once it has left the streaming window).
    let frameStart: Int
    /// The window's size: how far back a repeat offset may reach from where it's used.
    let windowSize: Int
    /// The hash multipliers (``multiplier(forLength:)``) of the strategy's match length and of 8 bytes (dfast's long
    /// table). Runtime values from the encoder, not constants: LLVM rematerializes a 64-bit constant (four
    /// instructions) at every use in a loop rather than keep it in a register, and libzstd's build keeps it in one.
    let shortMultiplier: UInt64
    let longMultiplier: UInt64

    /// The input for the block `start..<end` of `source`, whose first byte has index `indexBase`; `prefixStart` and
    /// `frameStart` offsets in `source` too.
    @unsafe @inline(__always)
    init(
        source: UnsafeRawPointer, indexBase: Int, start: Int, end: Int, prefixStart: Int, frameStart: Int, windowSize: Int,
        shortMultiplier: UInt64, longMultiplier: UInt64
    ) {
        // Unsafe: an address before the buffer, by `indexBase` (under 4 GB; buffers are far above that). Read only at
        // positions of the buffer's bytes.
        unsafe base = source - indexBase
        self.start = start &+ indexBase
        self.end = end &+ indexBase
        self.prefixStart = prefixStart &+ indexBase
        self.frameStart = frameStart &+ indexBase
        self.windowSize = windowSize
        self.shortMultiplier = shortMultiplier
        self.longMultiplier = longMultiplier
    }

    /// The multiplier of the hash of `length` bytes (`ZSTD_hashPtr`'s primes, shifted left by the bits a shorter
    /// hash drops first: `(x << s) * p` is `x * (p << s)`), or for 4 bytes, the 32-bit prime.
    static func multiplier(forLength length: Int) -> UInt64 {
        switch length {
        case 5: 889_523_592_379 &<< 24
        case 6: 227_718_039_650_203 &<< 16
        case 7: 58_295_818_150_454_627 &<< 8
        case 8: 0xCF1B_BCDC_B7A5_6463
        default: 2_654_435_761
        }
    }

    /// The largest repeat offset usable at `position` (`curr - ZSTD_getLowestPrefixIndex(curr)`): the window from
    /// there, or back to the frame's start.
    @inline(__always)
    func maximumRepeat(at position: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: min(position &- frameStart, windowSize))
    }

    /// A position's table entry: the position itself (indices stay below 2^32).
    @inline(__always)
    func index(_ position: Int) -> UInt32 { UInt32(truncatingIfNeeded: position) }

    @inline(__always)
    func position(_ index: UInt32) -> Int { Int(index) }

    @inline(__always)
    func load32(_ position: Int) -> UInt32 {
        // Unsafe: an unchecked load. Safe: callers read only positions with 4 bytes before `end`.
        UInt32(littleEndian: unsafe base.loadUnaligned(fromByteOffset: position, as: UInt32.self))
    }

    @inline(__always)
    func load64(_ position: Int) -> UInt64 {
        // Unsafe: an unchecked load. Safe: callers read only positions with 8 bytes before `end`.
        UInt64(littleEndian: unsafe base.loadUnaligned(fromByteOffset: position, as: UInt64.self))
    }

    /// Asks for the cache line at `position` (`PREFETCH_L1`): libzstd's hint where the search skips ahead faster than
    /// the hardware prefetcher follows.
    @inline(__always)
    func prefetch(_ position: Int) {
        // Unsafe: an address computed, not accessed (a prefetch never faults, even past the buffer).
        let address = unsafe base + position
        Builtin.int_prefetch_RawPointer(address._rawValue, Int32(0)._value, Int32(3)._value, Int32(1)._value)
    }

    @inline(__always)
    func byte(_ position: Int) -> UInt8 {
        // Unsafe: an unchecked load. Safe: callers read positions within the buffer, below `end`.
        unsafe base.load(fromByteOffset: position, as: UInt8.self)
    }

    /// The hash of the `length` bytes at `position` in `bits` bits (`ZSTD_hashPtr`, lengths 4 through 8): `length`
    /// is 8 (``longMultiplier``) or the strategy's match length (``shortMultiplier``).
    @inline(__always)
    func hash(_ position: Int, bits: Int, length: Int) -> Int {
        length == 4 ? hash4(load32(position), bits: bits) : hash(load64(position), bits: bits, length: length)
    }

    /// The hash of 5 to 8 bytes whose 8-byte load (little-endian, as ``load64(_:)``) is `value`: for a loop that
    /// loaded them already.
    @inline(__always)
    func hash(_ value: UInt64, bits: Int, length: Int) -> Int {
        Int(truncatingIfNeeded: (value &* (length == 8 ? longMultiplier : shortMultiplier)) &>> UInt64(64 &- bits))
    }

    /// The hash of 4 bytes whose load is `value`.
    @inline(__always)
    func hash4(_ value: UInt32, bits: Int) -> Int {
        Int(truncatingIfNeeded: (value &* UInt32(truncatingIfNeeded: shortMultiplier)) &>> UInt32(32 &- bits))
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
            let a = unsafe base.loadUnaligned(fromByteOffset: other, as: UInt16.self)
            let b = unsafe base.loadUnaligned(fromByteOffset: current, as: UInt16.self)
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
    /// Whether the block has no sequences (SwiftFormat's `isEmpty` rule writes `count == 0` as this).
    var isEmpty: Bool { count == 0 }
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
        let source = unsafe input.base + anchor
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
            unsafe Self.copyExactly(destination, source, count)
        }
        literalCount &+= count
    }

    /// Copies the block's last `count` literals, from `anchor` (after the match finder: a `memcpy` call is fine here,
    /// and fastest for the long runs incompressible blocks end with).
    @inline(__always)
    mutating func copyLastLiterals(_ input: ZstdMatchInput, anchor: Int, count: Int) {
        // Unsafe: into the literal buffer, which holds a block, from the block's bytes `anchor..<anchor + count`.
        unsafe (literals + literalCount).copyMemory(from: input.base + anchor, byteCount: count)
        literalCount &+= count
    }

    /// Copies `count` bytes reading none past them (literals near the block's end), without calling `memmove`: a
    /// call anywhere in a match finder's loop pushes everything live across it into callee-saved registers or the
    /// stack (libzstd's `ZSTD_safecopyLiterals` copies inline too).
    @unsafe @inline(__always)
    static func copyExactly(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer, _ count: Int) {
        // Unsafe: reads below `count` from `source`, writes below `count` to `destination` (the caller's bounds).
        var offset = 0
        while offset &+ 16 <= count {
            unsafe (destination + offset).storeBytes(of: (source + offset).loadUnaligned(as: SIMD16<UInt8>.self), as: SIMD16<UInt8>.self)
            offset &+= 16
        }
        if offset &+ 8 <= count {
            unsafe (destination + offset).storeBytes(of: (source + offset).loadUnaligned(as: UInt64.self), as: UInt64.self)
            offset &+= 8
        }
        if offset &+ 4 <= count {
            unsafe (destination + offset).storeBytes(of: (source + offset).loadUnaligned(as: UInt32.self), as: UInt32.self)
            offset &+= 4
        }
        if offset &+ 2 <= count {
            unsafe (destination + offset).storeBytes(of: (source + offset).loadUnaligned(as: UInt16.self), as: UInt16.self)
            offset &+= 2
        }
        if offset < count {
            unsafe (destination + offset).storeBytes(of: (source + offset).load(as: UInt8.self), as: UInt8.self)
        }
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
        // The store stays in its `inout` parameter, in memory: it's touched once a match, and its six fields in
        // registers pushed the search loop's invariants out (the hash constant rebuilt twice an iteration, the limit
        // and the prefix's index reloaded from the stack), as in `doubleFastBody`.
        var anchor = input.start
        var ip0 = input.start
        if ip0 == prefixStart { ip0 &+= 1 }
        let (current, saved) = usableRepeats(repeats, maximum: input.maximumRepeat(at: ip0))
        // As `Int`s, one register each (a `UInt32` took a second, its `Int` form, through the loop).
        var rep1 = Int(current.0)
        var rep2 = Int(current.1)

        /// Whether the candidate at `matchIndex` starts with `value`, the position's first 4 bytes (carried, not
        /// loaded again: each position's 8 bytes are loaded once, for its hash).
        @inline(__always)
        func found(_ value: UInt64, _ matchIndex: UInt32) -> Bool {
            let here = UInt32(truncatingIfNeeded: value)
            if select {
                // libzstd's `ZSTD_match4Found_cmov`: an invalid candidate reads a valid position instead, and the
                // comparison comes first, so the one branch is on a match (rare), not on whether the candidate is in
                // range (unpredictable in small windows). Marked unlikely, LLVM keeps that order (a conditional
                // compare); as one condition, or two of equal weight, it branched on validity first to skip the load.
                // (libzstd keeps them apart with an empty `asm`.)
                let invalid = matchIndex < prefixStartIndex
                let address = invalid ? prefixStart : input.position(matchIndex)
                return unlikely(here == input.load32(address)) && !invalid
            }
            guard matchIndex >= prefixStartIndex else { return false }
            return here == input.load32(input.position(matchIndex))
        }

        /// A position's hash from its 8-byte load (4-byte hashes use the low half).
        @inline(__always)
        func hash(of value: UInt64) -> Int {
            length == 4 ? input.hash4(UInt32(truncatingIfNeeded: value), bits: hashLog) : input.hash(value, bits: hashLog, length: length)
        }

        search: while true {
            var step = stepSize
            var nextStep = ip0 &+ stepIncrement
            var ip1 = ip0 &+ 1
            var ip2 = ip0 &+ step
            var ip3 = ip2 &+ 1
            if ip3 >= ilimit { break search }
            // The 8 bytes at ip0 and ip1, carried through the pipeline (positions up to ip3 are below `ilimit`).
            var value0 = input.load64(ip0)
            var value1 = input.load64(ip1)
            var hash0 = hash(of: value0)
            var hash1 = hash(of: value1)
            var matchIndex = unsafe table[hash0]
            var current0: UInt32 = 0
            var match0 = 0
            var matchLength = 0
            var offBase: UInt32 = 0
            var isRepeat = false

            pipeline: repeat {
                // The repeat offset at ip2.
                let value2 = input.load64(ip2)
                let repeatValue = input.load32(ip2 &- rep1)
                current0 = input.index(ip0)
                unsafe table[hash0] = current0
                if UInt32(truncatingIfNeeded: value2) == repeatValue && rep1 > 0 {
                    ip0 = ip2
                    match0 = ip0 &- rep1
                    matchLength = input.byte(ip0 &- 1) == input.byte(match0 &- 1) ? 1 : 0
                    ip0 &-= matchLength
                    match0 &-= matchLength
                    offBase = 1
                    matchLength &+= 4
                    unsafe table[hash1] = input.index(ip1)
                    isRepeat = true
                    break pipeline
                }
                if found(value0, matchIndex) {
                    unsafe table[hash1] = input.index(ip1)
                    break pipeline
                }
                matchIndex = unsafe table[hash1]
                hash0 = hash1
                hash1 = hash(of: value2)
                ip0 = ip1
                value0 = value1
                ip1 = ip2
                value1 = value2
                ip2 = ip3

                current0 = input.index(ip0)
                unsafe table[hash0] = current0
                if found(value0, matchIndex) {
                    if step <= 4 { unsafe table[hash1] = input.index(ip1) }
                    break pipeline
                }
                let value3 = input.load64(ip2)
                matchIndex = unsafe table[hash1]
                hash0 = hash1
                hash1 = hash(of: value3)
                ip0 = ip1
                value0 = value1
                ip1 = ip2
                value1 = value3
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
                rep1 = ip0 &- match0
                offBase = UInt32(truncatingIfNeeded: rep1 &+ 3)
                matchLength = 4
                while ip0 > anchor && match0 > prefixStart && input.byte(ip0 &- 1) == input.byte(match0 &- 1) {
                    ip0 &-= 1
                    match0 &-= 1
                    matchLength &+= 1
                }
            }

            matchLength &+= input.commonLength(ip0 &+ matchLength, match0 &+ matchLength, limit: end)
            store.store(input, anchor: anchor, literalLength: ip0 &- anchor, wildLimit: wildLimit, offBase: offBase, matchLength: matchLength)
            ip0 &+= matchLength
            anchor = ip0

            if ip0 <= ilimit {
                // Fill the table, and take any immediate repeats of the second offset.
                let after = input.position(current0) &+ 2
                unsafe table[input.hash(after, bits: hashLog, length: length)] = current0 &+ 2
                unsafe table[input.hash(ip0 &- 2, bits: hashLog, length: length)] = input.index(ip0 &- 2)
                if rep2 > 0 {
                    while ip0 <= ilimit && input.load32(ip0) == input.load32(ip0 &- rep2) {
                        let repeatLength = input.commonLength(ip0 &+ 4, ip0 &+ 4 &- rep2, limit: end) &+ 4
                        swap(&rep1, &rep2)
                        unsafe table[input.hash(ip0, bits: hashLog, length: length)] = input.index(ip0)
                        ip0 &+= repeatLength
                        store.store(input, anchor: anchor, literalLength: 0, wildLimit: wildLimit, offBase: 1, matchLength: repeatLength)
                        anchor = ip0
                    }
                }
            }
        }

        repeats = restoredRepeats((UInt32(truncatingIfNeeded: rep1), UInt32(truncatingIfNeeded: rep2)), saved: saved)
        return end &- anchor
    }

    // MARK: - dfast

    /// The 8 bytes at the candidate `index` (a table entry), or, if it's below `lowest` (outside the window, as
    /// libzstd's `ZSTD_selectAddr` decides), the complement of `value`, the bytes of the position it's a candidate for:
    /// so an invalid candidate never compares equal, with no flag to test. The load goes to `fallback` then (a
    /// readable position): without a branch.
    @inline(__always)
    static func candidate(_ input: ZstdMatchInput, _ index: UInt32, _ lowest: UInt32, fallback: Int, against value: UInt64) -> UInt64 {
        let invalid = index < lowest
        let bytes = input.load64(invalid ? fallback : input.position(index))
        return invalid ? ~value : bytes
    }

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
        // As `Int`s, as in `fastBody`.
        var rep1 = Int(current.0)
        var rep2 = Int(current.1)

        @inline(__always)
        func longHash(_ position: Int) -> Int { input.hash(position, bits: hashLog, length: 8) }
        @inline(__always)
        func shortHash(_ position: Int) -> Int { input.hash(position, bits: chainLog, length: length) }
        /// The short hash of the position whose 8-byte load is `value`.
        @inline(__always)
        func shortHash(of value: UInt64) -> Int {
            length == 4
                ? input.hash4(UInt32(truncatingIfNeeded: value), bits: chainLog) : input.hash(value, bits: chainLog, length: length)
        }

        search: while true {
            var step = 1
            var nextStep = ip &+ stepIncrement
            var ip1 = ip &+ step
            if ip1 > ilimit { break search }
            // The 8 bytes at `ip`, loaded once a position (as the next position's, then carried): its long and short
            // hashes and both comparisons use them. (libzstd's build reuses the load the same way: C's type-based
            // aliasing tells clang the tables' 32-bit stores leave it alone; Swift's IR doesn't say so.)
            var value0 = input.load64(ip)
            var longHash0 = input.hash(value0, bits: hashLog, length: 8)
            var shortHash0 = shortHash(of: value0)
            // Each position's long candidate and its bytes are fetched a position ahead, so the long test compares
            // registers: the branch (mispredicted once a match, inherently) resolves without waiting on the table and
            // candidate loads, which miss in large tables. (libzstd fetches only the index ahead; its shape, with the
            // bytes loaded at the position, was 5–17% slower here on varied bodies at the same instructions.) The short
            // candidate is read at the position, as libzstd reads it: fetched ahead too, it cost 1.5–2% more instructions
            // and gained nothing. An invalid candidate (outside the window) reads a readable position instead, and its
            // bytes are replaced by the complement of the position's own, which never compare equal: each test is one
            // comparison.
            var longIndex0 = unsafe long[longHash0]
            var longCandidateValue0 = Self.candidate(input, longIndex0, prefixStartIndex, fallback: ip1, against: value0)
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
                // The short entry, read before this position's stores.
                let shortIndex0 = unsafe short[shortHash0]
                currentIndex = input.index(ip)
                unsafe long[longHash0] = currentIndex
                unsafe short[shortHash0] = currentIndex

                // The repeat offset at the next position (whose first 4 bytes are bits 8–39 of `value0`).
                if rep1 > 0 && input.load32(ip &+ 1 &- rep1) == UInt32(truncatingIfNeeded: value0 &>> 8) {
                    matchLength = input.commonLength(ip &+ 5, ip &+ 5 &- rep1, limit: end) &+ 4
                    ip &+= 1
                    found = 1
                    break positions
                }

                let value1 = input.load64(ip1)
                longHash1 = input.hash(value1, bits: hashLog, length: 8)
                // A long match here. Validity joins the comparison as a bit, so the branch is on a match, not on
                // whether the candidate is in the window (libzstd's `ZSTD_selectAddr`; see `fastBody`).
                if unlikely(longCandidateValue0 == value0) {
                    let longMatch = input.position(longIndex0)
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
                let shortValue = UInt32(
                    truncatingIfNeeded: Self.candidate(input, shortIndex0, prefixStartIndex, fallback: ip1, against: value0)
                )
                if unlikely(shortValue == UInt32(truncatingIfNeeded: value0)) {
                    shortMatch = input.position(shortIndex0)
                    found = 3
                    break positions
                }

                // The next position's long candidate (see above).
                let shortHash1 = shortHash(of: value1)
                longIndex0 = longIndex1
                longCandidateValue0 = Self.candidate(input, longIndex1, prefixStartIndex, fallback: ip, against: value1)

                if ip1 >= nextStep {
                    input.prefetch(ip1 &+ 64)
                    input.prefetch(ip1 &+ 128)
                    step &+= 1
                    nextStep &+= stepIncrement
                }
                ip = ip1
                ip1 &+= step
                value0 = value1
                longHash0 = longHash1
                shortHash0 = shortHash1
                // libzstd's aarch64 build reads ahead every position (dropping it measured neutral here).
                input.prefetch(ip &+ 256)
            } while ip1 <= ilimit
            if found == 0 {
                break search
            }

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
                rep1 = offset
                if step < 4 { unsafe long[longHash1] = input.index(ip1) }
                store.store(
                    input, anchor: anchor, literalLength: ip &- anchor, wildLimit: wildLimit,
                    offBase: UInt32(truncatingIfNeeded: rep1 &+ 3), matchLength: matchLength
                )
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
                while ip <= ilimit && rep2 > 0 && input.load32(ip) == input.load32(ip &- rep2) {
                    let repeatLength = input.commonLength(ip &+ 4, ip &+ 4 &- rep2, limit: end) &+ 4
                    swap(&rep1, &rep2)
                    unsafe short[shortHash(ip)] = input.index(ip)
                    unsafe long[longHash(ip)] = input.index(ip)
                    store.store(input, anchor: anchor, literalLength: 0, wildLimit: wildLimit, offBase: 1, matchLength: repeatLength)
                    ip &+= repeatLength
                    anchor = ip
                }
            }
        }

        repeats = restoredRepeats((UInt32(truncatingIfNeeded: rep1), UInt32(truncatingIfNeeded: rep2)), saved: saved)
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
