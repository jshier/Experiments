internal import Bytes

// Double-symbol Huffman tables (libzstd's X2): each entry, indexed by the next 11 or 12 bits, decodes one
// symbol, or two when both codes fit in the index, so well-compressed literals decode up to two per lookup.

extension ZstdHuffman {
    /// A double-symbol entry, as libzstd's `HUF_DEltX2` in 32 bits: the symbols (first in bits 0–7, second in
    /// 8–15), the bits both take (16–23), and how many symbols it holds (24–31).
    @inline(__always)
    static func doubleEntry(_ symbol: Int, bits: Int, first: Int, level: Int) -> UInt32 {
        let sequence = level == 1 ? symbol : first &+ (symbol &<< 8)
        return UInt32(truncatingIfNeeded: sequence &+ (bits &<< 16) &+ (level &<< 24))
    }

    /// Fills `count` entries from `start` with `entry`, never past `size`.
    @inline(__always)
    private static func fill(_ table: UnsafeMutablePointer<UInt32>, from start: Int, count: Int, size: Int, with entry: UInt32) {
        // Unsafe: table stores. Safe: below `size`, the table's length.
        var index = max(start, 0)
        let end = min(start &+ count, size)
        let two = UInt64(entry) &* 0x0000_0001_0000_0001
        while index &+ 2 <= end {
            unsafe UnsafeMutableRawPointer(table + index).storeBytes(of: two, as: UInt64.self)
            index &+= 2
        }
        if index < end { unsafe table[index] = entry }
    }

    /// Builds a double-symbol decoding table (libzstd's `HUF_readDTableX2_wksp`) at `table` from the weights in
    /// `weights`. Codes up to 11 bits get an 11-bit table, as for single-symbol tables.
    ///
    /// - Parameter sorted: Scratch for the symbols sorted by weight (256 bytes).
    /// - Returns: The table's index width.
    static func buildDoubleTable(
        _ table: UnsafeMutablePointer<UInt32>, weights: UnsafePointer<UInt8>, symbolCount: Int, tableLog: Int,
        sorted: UnsafeMutablePointer<UInt8>
    ) -> Int {
        let targetLog = tableLog <= fastTableLog ? fastTableLog : tableLogMaximum
        let size = 1 &<< targetLog
        var rankCounts = InlineArray<16, Int>(repeating: 0)
        // Unsafe: weight loads below `symbolCount`; sorted-symbol loads and stores masked to its 256 bytes.
        for symbol in 0..<symbolCount {
            rankCounts[Int(unsafe weights[symbol]) & 15] &+= 1
        }
        var maximumWeight = tableLog
        while maximumWeight > 1, rankCounts[maximumWeight] == 0 { maximumWeight &-= 1 }
        // Symbols sorted by weight, then value; each weight's run in `sorted` is `rankStart[w]..<rankStart[w + 1]`.
        var rankStart = InlineArray<16, Int>(repeating: 0)
        var next = 0
        for weight in 1...maximumWeight {
            rankStart[weight] = next
            next &+= rankCounts[weight]
        }
        rankStart[maximumWeight &+ 1] = next
        var position = rankStart
        for symbol in 0..<symbolCount {
            let weight = Int(unsafe weights[symbol]) & 15
            guard weight > 0, weight <= maximumWeight else { continue }
            unsafe sorted[position[weight] & 255] = UInt8(truncatingIfNeeded: symbol)
            position[weight] &+= 1
        }
        // Where each weight's first-level entries start: weight `w`'s codes take `1 << (w + rescale)` entries.
        let rescale = targetLog &- tableLog &- 1
        var rankValue = InlineArray<16, Int>(repeating: 0)
        var nextValue = 0
        for weight in 1...maximumWeight {
            rankValue[weight] = nextValue
            nextValue &+= rankCounts[weight] &<< (weight &+ rescale)
        }
        let baseline = tableLog &+ 1 // A weight-`w` code is `baseline - w` bits long.
        let scaleLog = baseline &- targetLog
        let minimumBits = baseline &- maximumWeight

        for weight in 1...maximumWeight {
            let bits = baseline &- weight
            let length = 1 &<< (targetLog &- bits)
            var start = rankValue[weight]
            if targetLog &- bits >= minimumBits {
                // Room for a second symbol after each of these: a block of entries per first symbol.
                let minimumWeight = max(1, bits &+ scaleLog)
                for rank in rankStart[weight]..<rankStart[weight &+ 1] {
                    let first = Int(unsafe sorted[rank & 255])
                    if minimumWeight > 1 {
                        // Second codes too long to fit: these entries decode the first symbol alone.
                        let skipped = rankValue[minimumWeight] &>> bits
                        unsafe fill(table, from: start, count: skipped, size: size, with: doubleEntry(first, bits: bits, first: 0, level: 1))
                    }
                    for second in minimumWeight...maximumWeight {
                        let total = baseline &- second &+ bits
                        let span = 1 &<< (targetLog &- total)
                        var index = start &+ (rankValue[second] &>> bits)
                        for secondRank in rankStart[second]..<rankStart[second &+ 1] {
                            let symbol = Int(unsafe sorted[secondRank & 255])
                            unsafe fill(table, from: index, count: span, size: size, with: doubleEntry(symbol, bits: total, first: first, level: 2))
                            index &+= span
                        }
                    }
                    start &+= length
                }
            } else {
                for rank in rankStart[weight]..<rankStart[weight &+ 1] {
                    let symbol = Int(unsafe sorted[rank & 255])
                    unsafe fill(table, from: start, count: length, size: size, with: doubleEntry(symbol, bits: bits, first: 0, level: 1))
                    start &+= length
                }
            }
        }
        return targetLog
    }

    /// Whether to decode literals with a double-symbol table: when they compress to 10/16 of their size or
    /// less (codes averaging 5 bits or fewer, so two often fit in one 11-bit lookup) and there are 8 KB or more
    /// of them (the table takes longer to build).
    ///
    /// Measured rather than libzstd's `HUF_selectDecoder`, whose cost model picks double tables down to
    /// ratios of 15/16: with these decoders, double tables cost x-ray at level 1 6% more instructions and
    /// 7% more time, mozilla and xml 0.3–4%; with this rule dickens at level 1 takes 8% fewer instructions and
    /// nothing else changes by more than 0.1% (Benchmarks/RESULTS.md).
    static func prefersDoubleTable(size: Int, compressedSize: Int) -> Bool {
        size >= 8 << 10 && compressedSize &* 16 < 10 &* size
    }

    // MARK: Decoding

    /// Decodes symbols from `bits` into `output` up to `end` with a double-symbol table, as libzstd's
    /// `HUF_decodeStreamX2`: up to ten bytes per reload while the stream lasts, then two at a time, then a
    /// last single byte from an entry that may hold two.
    @inline(__always)
    static func decodeStreamX2(
        _ bits: inout ZstdReverseBits, table: UnsafePointer<UInt32>, tableLog: Int,
        from output: UnsafeMutablePointer<UInt8>, to end: UnsafeMutablePointer<UInt8>
    ) {
        // Unsafe: table lookups and stores. Safe: indices are `tableLog`-bit values, within the table; each
        // two-byte store is at least two bytes before `end` (checked by each loop's condition).
        var pointer = unsafe output
        @inline(__always)
        func symbols() {
            let entry = unsafe table[bits.peek(tableLog)]
            unsafe UnsafeMutableRawPointer(pointer).storeBytes(of: UInt16(truncatingIfNeeded: entry), as: UInt16.self)
            bits.consumed &+= Int(truncatingIfNeeded: entry &>> 16) & 0xFF
            unsafe pointer += Int(truncatingIfNeeded: entry &>> 24)
        }
        if unsafe end - pointer >= 8 {
            if tableLog <= fastTableLog {
                while bits.reloadStatus() == .unfinished, unsafe pointer < end - 9 {
                    symbols()
                    symbols()
                    symbols()
                    symbols()
                    symbols()
                }
            } else {
                while bits.reloadStatus() == .unfinished, unsafe pointer < end - 7 {
                    symbols()
                    symbols()
                    symbols()
                    symbols()
                }
            }
        } else {
            _ = bits.reloadStatus()
        }
        if unsafe end - pointer >= 2 {
            while bits.reloadStatus() == .unfinished, unsafe pointer <= end - 2 {
                symbols()
            }
            while unsafe pointer <= end - 2 {
                symbols()
            }
        }
        if unsafe pointer < end {
            // The last byte: its entry may hold two symbols, whose bits run past the stream's start; consume
            // them all, but no further than the start (libzstd's `HUF_decodeLastSymbolX2`).
            let entry = unsafe table[bits.peek(tableLog)]
            unsafe pointer.pointee = UInt8(truncatingIfNeeded: entry)
            let count = Int(truncatingIfNeeded: entry &>> 16) & 0xFF
            if entry &>> 24 == 1 {
                bits.consumed &+= count
            } else if bits.consumed < 64 {
                bits.consumed = min(bits.consumed &+ count, 64)
            }
        }
    }

    /// The four-stream fast loop for double-symbol tables (libzstd's
    /// `HUF_decompress4X2_usingDTable_internal_fast_c_loop`). Returns how many bytes each stream decoded and how
    /// many of its bits are left.
    ///
    /// Bounds: each round reads at most 55 bits (7 bytes) per stream and writes at most 10 bytes per stream, two
    /// at a time. A batch of `n` rounds starts only when stream 0's load position is `7n` bytes above the
    /// section's start, streams 1 to 3 are at or above stream 0, and every stream has `10n` bytes left in its
    /// segment.
    @inline(__always)
    static func decodeFourStreamsFastDouble(
        _ source: UnsafeRawPointer, starts: (Int, Int, Int, Int), count: Int, table: UnsafePointer<UInt32>,
        output: UnsafeMutablePointer<UInt8>, size: Int, segment: Int
    ) throws(BytesError) -> (done: (Int, Int, Int, Int), unread: (Int, Int, Int, Int)) {
        // Unsafe: all loads are 8 bytes at positions within the section (see above), stores within `output`.
        var ip0 = starts.1 &- 8
        var ip1 = starts.2 &- 8
        var ip2 = starts.3 &- 8
        var ip3 = count &- 8
        @inline(__always)
        func load(_ position: Int) -> UInt64 {
            UInt64(littleEndian: unsafe source.loadUnaligned(fromByteOffset: position, as: UInt64.self))
        }
        @inline(__always)
        func initial(_ position: Int) throws(BytesError) -> UInt64 {
            let last = UInt8(truncatingIfNeeded: load(position) &>> 56)
            guard last != 0 else { throw .invalidValue } // No end marker.
            return (load(position) | 1) &<< UInt64(last.leadingZeroBitCount &+ 1)
        }
        var bits0 = try initial(ip0)
        var bits1 = try initial(ip1)
        var bits2 = try initial(ip2)
        var bits3 = try initial(ip3)
        var op0 = 0
        var op1 = segment
        var op2 = 2 &* segment
        var op3 = 3 &* segment
        let end0 = segment
        let end1 = 2 &* segment
        let end2 = 3 &* segment

        while true {
            var rounds = ip0 / 7
            rounds = min(rounds, (end0 &- op0) / 10)
            rounds = min(rounds, (end1 &- op1) / 10)
            rounds = min(rounds, (end2 &- op2) / 10)
            rounds = min(rounds, (size &- op3) / 10)
            if rounds == 0 { break }
            if ip1 < ip0 || ip2 < ip1 || ip3 < ip2 { break } // Corrupt: the checks after throw.
            // Counted, not until stream 3 reaches a limit (as libzstd): progress never depends on table entries.
            var left = rounds
            repeat {
                @inline(__always)
                func decode(_ bits: inout UInt64, _ op: inout Int) {
                    let entry = unsafe table[Int(truncatingIfNeeded: bits &>> 53)]
                    unsafe UnsafeMutableRawPointer(output + op).storeBytes(of: UInt16(truncatingIfNeeded: entry), as: UInt16.self)
                    bits &<<= UInt64(truncatingIfNeeded: entry &>> 16) & 0x3F
                    op &+= Int(truncatingIfNeeded: entry &>> 24)
                }
                for _ in 0..<5 {
                    decode(&bits0, &op0)
                    decode(&bits1, &op1)
                    decode(&bits2, &op2)
                    decode(&bits3, &op3)
                }
                @inline(__always)
                func reload(_ bits: inout UInt64, _ ip: inout Int) {
                    let consumed = bits.trailingZeroBitCount
                    ip &-= consumed &>> 3
                    bits = (load(ip) | 1) &<< UInt64(consumed & 7)
                }
                reload(&bits0, &ip0)
                reload(&bits1, &ip1)
                reload(&bits2, &ip2)
                reload(&bits3, &ip3)
                left &-= 1
            } while left > 0
        }

        @inline(__always)
        func unread(_ bits: UInt64, _ ip: Int, _ start: Int) -> Int {
            (ip &- start) &* 8 &+ 64 &- bits.trailingZeroBitCount
        }
        return (
            (op0, op1 &- segment, op2 &- 2 &* segment, op3 &- 3 &* segment),
            (unread(bits0, ip0, starts.0), unread(bits1, ip1, starts.1), unread(bits2, ip2, starts.2), unread(bits3, ip3, starts.3))
        )
    }
}
