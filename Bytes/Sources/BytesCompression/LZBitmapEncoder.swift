public import Bytes
internal import Builtin

/// An LZBITMAP encoder whose output is byte for byte what Apple's Compression framework writes for
/// `COMPRESSION_LZBITMAP` (0x702): `compression_encode_buffer` with the same input and capacity gives the same
/// bytes, or fails where this throws.
///
/// ```swift
/// var encoder = LZBitmapEncoder()
/// try encoder.compress(fileChunk, into: &output)     // throws insufficientCapacity where Compression returns 0
/// ```
///
/// APFS-compressed files and Apple Archives decide how to store data by the size Compression's encoder gives
/// (a 64 KiB chunk compressed if it fits in 64 KiB; a file inline if it fits 3,584 bytes): matching its bytes
/// makes those decisions the same. The algorithm is libcompression's (macOS 27.2.1), read from its machine code
/// (`Benchmarks/RESULTS-lzbitmap.md` describes it): chunks of 32 KiB; each group of 8 bytes either repeats the
/// group a period back, or takes the best of 16 candidate periods from a hash table of 4-byte prefixes (two
/// positions per bucket) and the current one, scored on this group's literals and the next's; the 12 most used
/// bitmaps go in the chunk's table; runs of 4 or more equal nibbles are run-length coded. Chunks under 145 bytes,
/// and ones that don't shrink, are stored.
///
/// It needs 31 bytes past the stream, as Compression does: it throws ``BytesError/insufficientCapacity`` when
/// the stream would end within 31 bytes of the output's capacity (``maximumCompressedSize(forByteCount:)``
/// includes them), and checks room at the same points as Compression, so the two fail on the same capacities.
///
/// The encoder allocates its tables (about 560 KB) once, at creation; encoding allocates nothing. Each call
/// starts a new stream (the hash table is reset, as Compression resets it).
@safe
public struct LZBitmapEncoder: ~Copyable {
    private var workspace = LZBitmapEncoderWorkspace()

    /// Creates an encoder, allocating its tables.
    public init() {}

    /// Free capacity that's always enough for ``compress(_:into:)`` of `byteCount` bytes: every chunk stored,
    /// the magic and end chunk, and the 31 bytes Compression keeps free.
    ///
    /// Enough not to fail, not enough to compress as well as possible: the compressed path needs working room
    /// beyond its result, so with this capacity some inputs come out stored (a 220-byte file: 236 bytes here, 212
    /// with 284 of room). The output depends on the capacity, as Compression's does; give more room (APFS's
    /// compressors give each 64 KiB chunk 64 KiB, whatever its size) for the smallest stream.
    ///
    /// - Parameter byteCount: The input's size.
    /// - Returns: A capacity no stream of that input fails in.
    public static func maximumCompressedSize(forByteCount byteCount: Int) -> Int {
        let chunks = (byteCount &+ LZBitmapFormat.maximumChunkSize &- 1) / LZBitmapFormat.maximumChunkSize
        return byteCount &+ chunks &* 6 &+ 10 &+ LZBitmapEncoding.slack
    }

    /// Encodes `input` as one LZBITMAP stream, appending it to `output`: Compression's bytes for the input.
    ///
    /// - Parameters:
    ///   - input: The data, under 4 GiB.
    ///   - output: Where to append the stream. Its free capacity is Compression's destination size: the stream
    ///     must end at least 31 bytes before its end.
    /// - Throws: ``BytesError/insufficientCapacity`` if the stream doesn't fit, by Compression's rules (nothing
    ///   is appended); ``BytesError/invalidValue`` for 4 GiB of input or more.
    public mutating func compress(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) {
        guard input.byteCount <= Int(UInt32.max) else { throw .invalidValue }
        // Compression takes at most 2^32 − 1 bytes of destination and needs at least 35.
        let capacity = min(output.freeCapacity, Int(UInt32.max))
        guard capacity >= LZBitmapEncoding.minimumCapacity else { throw .insufficientCapacity }
        let workspace = unsafe workspace.base
        try output.withFreeCapacity(byteCount: capacity) { span, written throws(BytesError) in
            let produced = span.withUnsafeMutableBytes { outputBuffer in
                input.withUnsafeBytes { inputBuffer in
                    // Unsafe: the buffers' base addresses (the output's is non-nil: its capacity is at least 35;
                    // an empty input's is a placeholder, never read).
                    unsafe LZBitmapEncoding.encode(
                        (inputBuffer.baseAddress ?? UnsafeRawPointer(bitPattern: 16)!).assumingMemoryBound(to: UInt8.self),
                        count: inputBuffer.count,
                        into: outputBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity: capacity,
                        workspace: workspace
                    )
                }
            }
            guard produced > 0 else { throw .insufficientCapacity }
            written = produced
        }
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension LZBitmapEncoder: @unchecked Sendable {}

/// The encoder's tables, allocated once.
@safe @usableFromInline // Exported for clients' destroys, as `LZBitmapWorkspace`.
struct LZBitmapEncoderWorkspace: ~Copyable {
    static var hashBits: Int { 18 }
    /// The hash table: 2^18 `UInt16` positions (low 16 bits), read and written 32 bits at a time at a bucket's
    /// index, so a bucket's second entry is the next bucket's first (Compression's layout); then 32 more (it is
    /// reset 64 bytes at a time).
    static var tableOffset: Int { 0 }
    static var tableEntries: Int { (1 &<< hashBits) &+ 32 }
    /// 256 × 16 bytes: each bitmap's literal lanes in order, then 0xFF (a `tbl` that packs the group's
    /// literals); byte 15 is the bitmap's literal count.
    static var packOffset: Int { tableOffset &+ tableEntries &* 2 }
    /// Each group's new period (2 bytes, at the period area's running length).
    static var periodsOffset: Int { packOffset &+ 4096 }
    /// Each group's code: bitmap | period bytes << 8, as `UInt16`.
    static var codesOffset: Int { periodsOffset &+ LZBitmapWorkspace.maximumGroups &* 2 &+ 64 }
    /// Each code's count << 16 | the code, as `UInt32` (Compression's histogram, sorted in place).
    static var histogramOffset: Int { codesOffset &+ (LZBitmapWorkspace.maximumGroups &+ 64) &* 2 }
    /// Each code's nibble | 0x100 if its bitmap goes in the bitmap area, as `UInt16`.
    static var nibbleMapOffset: Int { histogramOffset &+ 768 &* 4 }
    /// Each group's nibble, one per byte, then 16 bytes that match no nibble.
    static var nibblesOffset: Int { nibbleMapOffset &+ 768 &* 2 }
    /// The nibbles run-length coded, one per byte.
    static var runsOffset: Int { nibblesOffset &+ LZBitmapWorkspace.maximumGroups &+ 64 }
    /// For the scalar choice, a group's 16 candidate periods (`UInt16`), their period byte counts, costs, and
    /// bonuses; then constants (offsets from the scratch area).
    static var scratchOffset: Int { runsOffset &+ LZBitmapWorkspace.maximumGroups &+ 64 }
    static var choiceByteCounts: Int { 48 }
    static var choiceCosts: Int { 80 }
    static var choiceBonuses: Int { 96 }
    /// The candidates' positions in the group, twice each (`SIMD8<UInt16>`): lanes 0, 4, 2, 3, then 1, 5, 6, 7.
    static var laneOffsetsA: Int { 112 }
    static var laneOffsetsB: Int { 128 }
    /// Four `tbl` indices into (newer periods, older periods, costs) building candidate keys, cost << 24 |
    /// period (0xFF in byte 2), and the choices, k + 1, to OR into byte 2.
    static var keyIndices: Int { 144 }
    static var keyChoices: Int { 208 }
    /// 4 for this group's 8 lanes, 1 for the next group's.
    static var currentWeights: Int { 272 }
    /// 1, 2, 4, … 128: each lane's bit in a bitmap.
    static var laneBits: Int { 288 }
    static var byteCount: Int { scratchOffset &+ 304 }

    let memory = CodecWorkspace(byteCount: byteCount)

    // Unsafe: the allocation's address. Safe: valid while the workspace (which owns it) lives.
    var base: UnsafeMutableRawPointer { unsafe memory.base }

    init() {
        // Unsafe: stores into the zeroed allocation. Safe: the offsets are within `byteCount`.
        for bitmap in 0..<256 {
            var literal = 0
            for lane in 0..<8 where bitmap >> lane & 1 != 0 {
                unsafe base.storeBytes(of: UInt8(lane), toByteOffset: Self.packOffset &+ bitmap &* 16 &+ literal, as: UInt8.self)
                literal &+= 1
            }
            for lane in literal..<15 {
                unsafe base.storeBytes(of: 0xFF, toByteOffset: Self.packOffset &+ bitmap &* 16 &+ lane, as: UInt8.self)
            }
            unsafe base.storeBytes(of: UInt8(literal), toByteOffset: Self.packOffset &+ bitmap &* 16 &+ 15, as: UInt8.self)
        }
        let scratch = unsafe base + Self.scratchOffset
        for (lane, position) in [0, 4, 2, 3, 1, 5, 6, 7].enumerated() {
            let offsets = lane < 4 ? Self.laneOffsetsA : Self.laneOffsetsB
            unsafe scratch.storeBytes(of: UInt16(position), toByteOffset: offsets &+ (lane & 3) &* 4, as: UInt16.self)
            unsafe scratch.storeBytes(of: UInt16(position), toByteOffset: offsets &+ (lane & 3) &* 4 &+ 2, as: UInt16.self)
        }
        for k in 0..<16 {
            // Candidate k: its period's two bytes (in the newer or the older periods), then the choice, then its cost.
            let period = k < 8 ? 2 &* k : 16 &+ 2 &* (k &- 8)
            for (byte, index) in [period, period &+ 1, 0xFF, 32 &+ k].enumerated() {
                unsafe scratch.storeBytes(of: UInt8(index), toByteOffset: Self.keyIndices &+ 4 &* k &+ byte, as: UInt8.self)
            }
            unsafe scratch.storeBytes(of: UInt8(k &+ 1), toByteOffset: Self.keyChoices &+ 4 &* k &+ 2, as: UInt8.self)
            unsafe scratch.storeBytes(of: UInt8(k < 8 ? 4 : 1), toByteOffset: Self.currentWeights &+ k, as: UInt8.self)
        }
        for lane in 0..<8 { unsafe scratch.storeBytes(of: UInt8(1 &<< lane), toByteOffset: Self.laneBits &+ lane, as: UInt8.self) }
    }
}

/// The encode loops, on pointers checked by their callers.
enum LZBitmapEncoding {
    /// Compression checks every write against its destination's end less 31 bytes.
    static var slack: Int { 31 }
    static var minimumCapacity: Int { 35 }

    /// Encodes `count` bytes at `input` into `output`, Compression's destination of `capacity` bytes (at
    /// least 35, at most 2^32 − 1).
    ///
    /// - Returns: The stream's size, or 0 if it doesn't fit.
    static func encode(
        _ input: UnsafePointer<UInt8>, count: Int, into output: UnsafeMutablePointer<UInt8>, capacity: Int,
        workspace: UnsafeMutableRawPointer
    ) -> Int {
        // Unsafe: initializing the workspace's table, then writes to the output. Safe: the table is
        // `tableEntries` `UInt16`s; the output has at least 35 bytes, and every chunk checks its writes against
        // `limit`, 31 bytes before its end.
        // Every entry 8 (Compression's initial position), 64 bytes at a time (`initializeMemory` stores one
        // entry at a time). `tableEntries` is a multiple of 32.
        let table = unsafe workspace + LZBitmapEncoderWorkspace.tableOffset
        let eights = SIMD32<UInt16>(repeating: 8)
        for offset in stride(from: 0, to: LZBitmapEncoderWorkspace.tableEntries &* 2, by: 64) {
            unsafe table.storeBytes(of: eights, toByteOffset: offset, as: SIMD32<UInt16>.self)
        }
        let limit = capacity &- slack
        unsafe UnsafeMutableRawPointer(output).storeBytes(of: UInt32(0x094D_425A).littleEndian, as: UInt32.self)    // "ZBM\t"
        var written = 4
        var start = 0
        while start < count {
            let size = min(count &- start, LZBitmapFormat.maximumChunkSize)
            written = unsafe chunk(
                input, count: count, start: start, size: size, output: output, at: written, limit: limit,
                workspace: workspace
            )
            guard written > 0 else { return 0 }
            start &+= LZBitmapFormat.maximumChunkSize
        }
        return unsafe chunk(input, count: count, start: 0, size: 0, output: output, at: written, limit: limit, workspace: workspace)
    }

    /// Writes the chunk of `size` bytes from `start` at `output + at`: compressed, or stored if that's no
    /// smaller (or under 145 bytes, or doesn't fit).
    ///
    /// - Returns: The output's length after the chunk, or 0 if it doesn't fit before `limit`.
    static func chunk(
        _ input: UnsafePointer<UInt8>, count: Int, start: Int, size: Int, output: UnsafeMutablePointer<UInt8>,
        at chunkStart: Int, limit: Int, workspace: UnsafeMutableRawPointer
    ) -> Int {
        guard chunkStart &+ 6 <= limit else { return 0 }
        var end = 0
        if size >= 0x91, chunkStart &+ 15 <= limit {
            // Unsafe: the caller's pointers passed on. Safe: `compressedChunk` checks its writes against `limit`
            // (returning 0 when the chunk doesn't fit) and reads `input` below `count`.
            end = unsafe compressedChunk(
                input, count: count, start: start, size: size, output: output, at: chunkStart, limit: limit,
                workspace: workspace
            )
        }
        if end == 0 {
            end = chunkStart &+ 6 &+ size
            guard end <= limit else { return 0 }
            // Unsafe: copying the chunk's input after its header. Safe: `start + size <= count`, and the
            // output holds `end <= limit` bytes.
            unsafe (output + (chunkStart &+ 6)).update(from: input + start, count: size)
        }
        let length = end &- chunkStart
        // Unsafe: the 6-byte header, before `end`.
        unsafe UnsafeMutableRawPointer(output + chunkStart).storeBytes(of: UInt32(truncatingIfNeeded: length | size &<< 24).littleEndian, as: UInt32.self)
        unsafe UnsafeMutableRawPointer(output + chunkStart).storeBytes(of: UInt16(truncatingIfNeeded: size &>> 8).littleEndian, toByteOffset: 4, as: UInt16.self)
        return end
    }

    /// Compresses the chunk of `size` (145 through 32,768) bytes from `start` at `output + at`, leaving its
    /// first 6 bytes (length and size) to the caller.
    ///
    /// - Returns: The chunk's end, or 0 if it doesn't fit before `limit` or isn't smaller than storing it.
    static func compressedChunk(
        _ input: UnsafePointer<UInt8>, count: Int, start: Int, size: Int, output: UnsafeMutablePointer<UInt8>,
        at chunkStart: Int, limit: Int, workspace: UnsafeMutableRawPointer
    ) -> Int {
        // Unsafe: the workspace's areas. Safe: each is sized for a chunk's 4,096 groups.
        let histogram = unsafe (workspace + LZBitmapEncoderWorkspace.histogramOffset).assumingMemoryBound(to: UInt32.self)
        for code in 0..<768 { unsafe histogram[code] = UInt32(truncatingIfNeeded: code) }
        let codes = unsafe (workspace + LZBitmapEncoderWorkspace.codesOffset).assumingMemoryBound(to: UInt16.self)
        let literalStart = unsafe output + (chunkStart &+ LZBitmapFormat.headerSize)

        // The groups: each group's code, its literals at `literalStart`, its new periods in the workspace.
        guard let (literals, periodBytes) = unsafe groupPass(
            input, count: count, start: start, size: size, output: output, chunkStart: chunkStart,
            literalStart: literalStart, limit: limit, workspace: workspace
        ) else { return 0 }

        // The period area.
        let periodArea = chunkStart &+ LZBitmapFormat.headerSize &+ literals
        let bitmapArea = periodArea &+ periodBytes
        guard bitmapArea <= limit else { return 0 }
        // Unsafe: copying the periods, `bitmapArea <= limit` checked.
        unsafe (output + periodArea).update(
            from: (workspace + LZBitmapEncoderWorkspace.periodsOffset).assumingMemoryBound(to: UInt8.self), count: periodBytes
        )

        // The 12 most used codes go in the table; each other group's bitmap goes in the bitmap area.
        let groups = ((size &+ 63) &>> 3) & ~7
        let tableCount = unsafe selectTable(histogram)
        let nibbleMap = unsafe (workspace + LZBitmapEncoderWorkspace.nibbleMapOffset).assumingMemoryBound(to: UInt16.self)
        for code in 0..<768 { unsafe nibbleMap[code] = UInt16(truncatingIfNeeded: code &>> 8 | 0x100) }
        var tableBits: UInt128 = 0
        var bitmapCount = groups
        for index in 0..<tableCount {
            let entry = unsafe histogram[index]
            let code = Int(entry & 0xFFFF)
            tableBits |= UInt128(code) &<< (index &* 10)
            unsafe nibbleMap[code] = UInt16(truncatingIfNeeded: index &+ 3)
            bitmapCount &-= Int(entry &>> 16)
        }
        guard bitmapArea &+ bitmapCount <= limit else { return 0 }
        let nibbles = unsafe (workspace + LZBitmapEncoderWorkspace.nibblesOffset).assumingMemoryBound(to: UInt8.self)
        var bitmapPosition = bitmapArea
        for group in 0..<groups {
            // Unsafe: the group's code and its nibble, in the workspace; the bitmap byte at
            // `bitmapPosition <= bitmapArea + bitmapCount <= limit`.
            let code = unsafe Int(codes[group])
            let mapped = unsafe nibbleMap[code]
            unsafe nibbles[group] = UInt8(truncatingIfNeeded: mapped)
            unsafe output[bitmapPosition] = UInt8(truncatingIfNeeded: code)
            bitmapPosition &+= Int(mapped &>> 8)
        }

        // The nibble area: run-length coded, two per byte, low first.
        let nibbleArea = bitmapArea &+ bitmapCount
        guard nibbleArea &+ (groups &>> 1) <= limit else { return 0 }
        let runs = unsafe (workspace + LZBitmapEncoderWorkspace.runsOffset).assumingMemoryBound(to: UInt8.self)
        let runCount = unsafe encodeRuns(nibbles, count: groups, into: runs)
        let nibbleBytes = (runCount &+ 1) &>> 1
        let tableArea = nibbleArea &+ nibbleBytes
        let chunkEnd = tableArea &+ LZBitmapFormat.trailerSize
        guard chunkEnd <= limit else { return 0 }
        unsafe packNibbles(runs, count: runCount, into: output + nibbleArea)
        // Unsafe: the 17-byte table, before `chunkEnd <= limit`.
        unsafe UnsafeMutableRawPointer(output + tableArea).storeBytes(of: UInt64(truncatingIfNeeded: tableBits).littleEndian, as: UInt64.self)
        unsafe UnsafeMutableRawPointer(output + tableArea).storeBytes(of: UInt64(truncatingIfNeeded: tableBits &>> 64).littleEndian, toByteOffset: 8, as: UInt64.self)
        unsafe output[tableArea &+ 16] = 0

        // The offsets of the period, bitmap, and nibble areas.
        let header = unsafe UnsafeMutableRawPointer(output + chunkStart)
        let offsets = UInt64(periodArea &- chunkStart) | UInt64(bitmapArea &- chunkStart) &<< 24
            | UInt64(nibbleArea &- chunkStart) &<< 48
        // Unsafe: header bytes 6 through 14, in the checked chunk.
        unsafe header.storeBytes(of: offsets.littleEndian, toByteOffset: 6, as: UInt64.self)
        unsafe header.storeBytes(of: UInt8(truncatingIfNeeded: (nibbleArea &- chunkStart) &>> 16), toByteOffset: 14, as: UInt8.self)
        return chunkEnd &- chunkStart < size &+ 6 ? chunkEnd : 0
    }

    /// Picks the 12 most used codes, as Compression does: the used codes (count << 16 | code) moved to the
    /// histogram's front in code order, then partitioned (a quickselect with median-of-three pivots, largest
    /// first) until its first 12 are the 12 largest, in the order the partitioning leaves them.
    ///
    /// - Returns: The number of table entries: up to 12, the used codes at the histogram's front.
    static func selectTable(_ histogram: UnsafeMutablePointer<UInt32>) -> Int {
        // Unsafe: the histogram's 768 entries; every index below is within the used ones.
        var used = 0
        for code in 0..<768 {
            let entry = unsafe histogram[code]
            unsafe histogram[used] = entry
            used &+= entry >= 0x10000 ? 1 : 0
        }
        let wanted = 12
        if used <= wanted { return used }
        var low = 0
        var high = used
        while true {
            let first = low
            let x = unsafe histogram[low]
            var y = unsafe histogram[high &- 1]
            if x > y { unsafe histogram[first] = y; y = x; unsafe histogram[high &- 1] = x }
            let middle = (low &+ high) &>> 1
            var m = unsafe histogram[middle]
            if m > y { unsafe histogram[middle] = y; unsafe histogram[high &- 1] = m; m = unsafe histogram[middle] }
            var pivot = unsafe histogram[first]
            if m > pivot { unsafe histogram[first] = m; unsafe histogram[middle] = pivot; pivot = unsafe histogram[first] }
            var i = first &- 1
            var j = high
            var boundary = 0
            while true {
                var t: UInt32
                repeat { i &+= 1; t = unsafe histogram[i] } while t > pivot
                var u: UInt32
                var k = j &+ 1
                var below = 0
                repeat { below = k &- 2; k &-= 1; u = unsafe histogram[below] } while u < pivot
                j = k &- 1
                boundary = k
                if i >= j { break }
                unsafe histogram[below] = t
                unsafe histogram[i] = u
            }
            if boundary < wanted { low = boundary } else { high = boundary; low = first }
            if boundary == wanted { return wanted }
        }
    }

    /// Run-length codes `count` nibbles (one per byte, with 16 bytes of room after them): a nibble repeated 4
    /// or more times is written once, then 15, then the remaining count in nibbles of up to 15, the last
    /// under 15. Compression's scan: 16 nibbles at a time, a run counted only if it starts in the first 14.
    ///
    /// - Returns: The number of nibbles written.
    static func encodeRuns(_ nibbles: UnsafeMutablePointer<UInt8>, count: Int, into runs: UnsafeMutablePointer<UInt8>) -> Int {
        // Unsafe: the nibbles and the 16 bytes after them (a pattern no nibble equals, so runs and counts stop
        // at the end); writes of up to 16 bytes past the output's count, within the workspace's room.
        for index in 0..<16 { unsafe nibbles[count &+ index] = index & 1 == 0 ? 0xAC : 0xCE }
        guard count > 0 else { return 0 }
        var read = 0
        var written = 0
        repeat {
            let block = unsafe UnsafeRawPointer(nibbles + read).loadUnaligned(as: SIMD16<UInt8>.self)
            let next = unsafe UnsafeRawPointer(nibbles + (read &+ 1)).loadUnaligned(as: SIMD16<UInt8>.self)
            unsafe UnsafeMutableRawPointer(runs + written).storeBytes(of: block, as: SIMD16<UInt8>.self)
            let equal = ByteMatches(highBits: unsafe unsafeBitCast(block .== next, to: SIMD16<UInt8>.self)).nibbleMask
            let starts = equal & equal &>> 4 & equal &>> 8
            let step = (starts | 1 &<< 55).trailingZeroBitCount &>> 2 &+ 1
            read &+= step
            written &+= step
            if starts != 0 {
                unsafe runs[written] = 15
                written &+= 1
                read &+= 3
                var length: Int
                repeat {
                    let previous = unsafe UnsafeRawPointer(nibbles + (read &- 1)).loadUnaligned(as: SIMD16<UInt8>.self)
                    let current = unsafe UnsafeRawPointer(nibbles + read).loadUnaligned(as: SIMD16<UInt8>.self)
                    let same = ByteMatches(highBits: unsafe unsafeBitCast(previous .== current, to: SIMD16<UInt8>.self)).nibbleMask
                    length = (~same & 0x8888_8888_8888_8888 | 1 &<< 63).trailingZeroBitCount &>> 2
                    unsafe runs[written] = UInt8(truncatingIfNeeded: length)
                    written &+= 1
                    read &+= length
                } while length == 15
            }
        } while read < count
        return written &+ count &- read
    }

    /// Packs `count` nibbles (one per byte) two to a byte, low first, into `(count + 1) / 2` bytes.
    static func packNibbles(_ nibbles: UnsafeMutablePointer<UInt8>, count: Int, into output: UnsafeMutablePointer<UInt8>) {
        // Unsafe: reading the nibbles (and one past an odd count, set to 0 first, in the workspace's room),
        // writing `(count + 1) / 2` bytes, which the caller checked.
        unsafe nibbles[count] = 0
        var index = 0
        while index &+ 32 <= count {
            let pairs = unsafe UnsafeRawPointer(nibbles + index).loadUnaligned(as: SIMD32<UInt8>.self)
            unsafe UnsafeMutableRawPointer(output + index &>> 1).storeBytes(of: pairs.evenHalf | pairs.oddHalf &<< 4, as: SIMD16<UInt8>.self)
            index &+= 32
        }
        while index < count {
            unsafe output[index &>> 1] = nibbles[index] | nibbles[index &+ 1] &<< 4
            index &+= 2
        }
    }

    /// The group pass: each group's period and bitmap, its literals at `literalStart`, its new period in the
    /// workspace's period list, its code and the code's count.
    ///
    /// - Returns: The literal count and the period bytes; `nil` if the literals
    ///   don't fit (Compression's checks, before each block of 16 groups and before the tail).
    @inline(__always)
    static func groupPass(
        _ input: UnsafePointer<UInt8>, count: Int, start: Int, size: Int, output: UnsafeMutablePointer<UInt8>,
        chunkStart: Int, literalStart: UnsafeMutablePointer<UInt8>, limit: Int, workspace: UnsafeMutableRawPointer
    ) -> (literals: Int, periodBytes: Int)? {
        // Unsafe: the workspace's regions, as typed pointers. Safe: each offset and size is the workspace's
        // layout (`LZBitmapEncoderWorkspace`), allocated for the encoder's life and used by one call at a time.
        let table = unsafe (workspace + LZBitmapEncoderWorkspace.tableOffset).assumingMemoryBound(to: UInt16.self)
        let packs = unsafe UnsafeRawPointer(workspace + LZBitmapEncoderWorkspace.packOffset)
        let periods = unsafe workspace + LZBitmapEncoderWorkspace.periodsOffset
        let codes = unsafe (workspace + LZBitmapEncoderWorkspace.codesOffset).assumingMemoryBound(to: UInt16.self)
        let histogram = unsafe (workspace + LZBitmapEncoderWorkspace.histogramOffset).assumingMemoryBound(to: UInt32.self)
        let scratch = unsafe workspace + LZBitmapEncoderWorkspace.scratchOffset

        // Blocks of 16 groups while 128 bytes fit before the chunk's end and 16 before the input's.
        let blockLimit = min(start &+ size, count &- 16)
        var period = 8
        var literals = 0
        var periodBytes = 0
        var position = start
        if start &+ 128 <= blockLimit {
            repeat {
                guard chunkStart &+ 0x8F &+ literals <= limit else { return nil }
                var group = 0
                if position == 0 {
                    // The stream's first group: literals, at period 8.
                    unsafe codes[0] = 0xFF
                    unsafe histogram[0xFF] &+= 0x10000
                    unsafe UnsafeMutableRawPointer(literalStart).storeBytes(
                        of: UnsafeRawPointer(input).loadUnaligned(as: UInt64.self), as: UInt64.self
                    )
                    literals = 8
                    position = 8
                    group = 1
                }
                while group < 16 {
                    unsafe codeGroup(
                        input, at: position, groupIndex: (position &- start) &>> 3, period: &period,
                        literals: &literals, periodBytes: &periodBytes, literalStart: literalStart, table: table,
                        packs: packs, periods: periods, codes: codes, histogram: histogram, scratch: scratch
                    )
                    position &+= 8
                    group &+= 1
                }
            } while position &+ 128 <= blockLimit
        }

        // The tail, to a multiple of 64 bytes: each group copies at the last period or takes literals.
        let tailEnd = start &+ ((size &+ 63) & ~63)
        guard chunkStart &+ LZBitmapFormat.headerSize &+ literals &+ (tailEnd &- position) <= limit else { return nil }
        while position < tailEnd {
            var bitmap = 0
            for lane in 0..<8 {
                let at = position &+ lane
                // Unsafe: input bytes before `count`, and `period` (at most 65,535, never more than the position)
                // back; literals before `limit` (checked above for every byte of the tail).
                if at < count, unsafe input[at] != input[at &- period] {
                    unsafe literalStart[literals] = input[at]
                    literals &+= 1
                    bitmap |= 1 &<< lane
                }
            }
            unsafe codes[(position &- start) &>> 3] = UInt16(truncatingIfNeeded: bitmap)
            unsafe histogram[bitmap] &+= 0x10000
            position &+= 8
        }
        return (literals, periodBytes)
    }

    /// Codes the group of 8 bytes at `position` (with at least 16 bytes of input from it).
    @inline(__always)
    static func codeGroup(
        _ input: UnsafePointer<UInt8>, at position: Int, groupIndex: Int, period: inout Int, literals: inout Int,
        periodBytes: inout Int, literalStart: UnsafeMutablePointer<UInt8>, table: UnsafeMutablePointer<UInt16>,
        packs: UnsafeRawPointer, periods: UnsafeMutableRawPointer, codes: UnsafeMutablePointer<UInt16>,
        histogram: UnsafeMutablePointer<UInt32>, scratch: UnsafeMutableRawPointer
    ) {
        // Unsafe: 16-byte loads at the position (the caller guarantees 16 bytes) and at positions a period back
        // (periods never reach before the input's start: see below); the table's buckets (hashes under 2^18,
        // plus one); the workspace's lists at the group's index.
        let here = unsafe input + position
        let bytes = unsafe UnsafeRawPointer(here).loadUnaligned(as: SIMD16<UInt8>.self)
        let back = unsafe UnsafeRawPointer(here - period).loadUnaligned(as: SIMD16<UInt8>.self)

        // The 8 positions' hashes: 4-byte little-endian words times 0x9E3779B1, top 18 bits; as byte offsets
        // of their buckets (twice the hash), in vectors (scalar, LLVM spent 4 instructions a hash).
        let bucketMask = SIMD4<UInt32>(repeating: 0x7FFFE)
        let low = (bitCast(
            SIMD16<UInt8>(bytes[0], bytes[1], bytes[2], bytes[3], bytes[1], bytes[2], bytes[3], bytes[4],
                          bytes[2], bytes[3], bytes[4], bytes[5], bytes[3], bytes[4], bytes[5], bytes[6]),
            to: SIMD4<UInt32>.self
        ) &* 0x9E37_79B1) &>> 13 & bucketMask
        let high = (bitCast(
            SIMD16<UInt8>(bytes[4], bytes[5], bytes[6], bytes[7], bytes[5], bytes[6], bytes[7], bytes[8],
                          bytes[6], bytes[7], bytes[8], bytes[9], bytes[7], bytes[8], bytes[9], bytes[10]),
            to: SIMD4<UInt32>.self
        ) &* 0x9E37_79B1) &>> 13 & bucketMask
        let h0 = Int(low[0]), h1 = Int(low[1]), h2 = Int(low[2]), h3 = Int(low[3])
        let h4 = Int(high[0]), h5 = Int(high[1]), h6 = Int(high[2]), h7 = Int(high[3])

        if bitCast(bytes, to: SIMD2<UInt64>.self)[0] == bitCast(back, to: SIMD2<UInt64>.self)[0] {
            // A copy at the current period: insert the positions (Compression's order), nothing else.
            unsafe codes[groupIndex] = 0
            unsafe histogram[0] &+= 0x10000
            unsafe insert(table, h1, position &+ 1)
            unsafe insert(table, h2, position &+ 2)
            unsafe insert(table, h3, position &+ 3)
            unsafe insert(table, h5, position &+ 5)
            unsafe insert(table, h6, position &+ 6)
            unsafe insert(table, h7, position &+ 7)
            unsafe insert(table, h4, position &+ 4)
            unsafe insert(table, h0, position)
            return
        }

        // The buckets, before this group's insertions, in Compression's lane order (positions 0, 4, 2, 3 and
        // 1, 5, 6, 7): each 32 bits, the newer position low.
        let raw = UnsafeRawPointer(table)
        let bucketsA = unsafe SIMD4<UInt32>(
            raw.loadUnaligned(fromByteOffset: h0, as: UInt32.self), raw.loadUnaligned(fromByteOffset: h4, as: UInt32.self),
            raw.loadUnaligned(fromByteOffset: h2, as: UInt32.self), raw.loadUnaligned(fromByteOffset: h3, as: UInt32.self)
        )
        let bucketsB = unsafe SIMD4<UInt32>(
            raw.loadUnaligned(fromByteOffset: h1, as: UInt32.self), raw.loadUnaligned(fromByteOffset: h5, as: UInt32.self),
            raw.loadUnaligned(fromByteOffset: h6, as: UInt32.self), raw.loadUnaligned(fromByteOffset: h7, as: UInt32.self)
        )
        unsafe insert(table, h1, position &+ 1)
        unsafe insert(table, h2, position &+ 2)
        unsafe insert(table, h3, position &+ 3)
        unsafe insert(table, h5, position &+ 5)
        unsafe insert(table, h6, position &+ 6)
        unsafe insert(table, h7, position &+ 7)
        unsafe insert(table, h4, position &+ 4)
        unsafe insert(table, h0, position)

        // The 16 candidate periods, modulo 2^16: each lane's position less its bucket's entries. (The lanes'
        // offsets come from the workspace: as constants, LLVM built the positions a lane at a time.)
        let base16 = SIMD8<UInt16>(repeating: UInt16(truncatingIfNeeded: position))
        let offsetsA = unsafe scratch.load(fromByteOffset: LZBitmapEncoderWorkspace.laneOffsetsA, as: SIMD8<UInt16>.self)
        let offsetsB = unsafe scratch.load(fromByteOffset: LZBitmapEncoderWorkspace.laneOffsetsB, as: SIMD8<UInt16>.self)
        let pairsA = base16 &+ offsetsA &- bitCast(bucketsA, to: SIMD8<UInt16>.self)
        let pairsB = base16 &+ offsetsB &- bitCast(bucketsB, to: SIMD8<UInt16>.self)
        let joined = SIMD16<UInt16>(lowHalf: pairsA, highHalf: pairsB)
        let newer = joined.evenHalf
        let older = joined.oddHalf
        // Each candidate's differing bytes in this group and the next, counted by pairwise sums of the
        // comparisons (-1 per equal byte): lanes 2k and 2k + 1 of a sum are candidate k's two halves.
        // Unsafe: a period, at most the position (every entry is an earlier position modulo 2^16, at least 8,
        // and positions inserted are at least 8 more than the lane's offset), is never before the input.
        @inline(__always) func equal(_ k: Int) -> SIMD16<UInt8> {
            // (From the vectors' lanes: through memory, loads waited for unaligned stores to commit.) Unsafe: a
            // 16-byte load at a candidate period back. Safe: candidates are positions already seen in this chunk's
            // input, and `here + 16` is within it (the block loop's limit).
            let candidate = unsafe UnsafeRawPointer(here - Int(k < 8 ? newer[k] : older[k &- 8])).loadUnaligned(as: SIMD16<UInt8>.self)
            return unsafe unsafeBitCast(bytes .== candidate, to: SIMD16<UInt8>.self)
        }
        @inline(__always) func pairwise(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>) -> SIMD16<UInt8> {
            let both = SIMD32(lowHalf: a, highHalf: b)
            return both.evenHalf &+ both.oddHalf
        }
        let sums0 = pairwise(
            pairwise(pairwise(equal(0), equal(1)), pairwise(equal(2), equal(3))),
            pairwise(pairwise(equal(4), equal(5)), pairwise(equal(6), equal(7)))
        )
        let sums1 = pairwise(
            pairwise(pairwise(equal(8), equal(9)), pairwise(equal(10), equal(11))),
            pairwise(pairwise(equal(12), equal(13)), pairwise(equal(14), equal(15)))
        )
        let halves = SIMD32(lowHalf: sums0, highHalf: sums1)
        let eight = SIMD16<UInt8>(repeating: 8)
        var thisGroup = halves.evenHalf &+ eight
        var nextGroup = halves.oddHalf &+ eight
        // Candidates under 8 count as all literals; candidates under 256 take a period byte, others two. (By
        // bytes: narrowing 16-bit comparisons compiled to lane moves.)
        let distanceBytes = SIMD32<UInt8>(
            lowHalf: bitCast(newer, to: SIMD16<UInt8>.self), highHalf: bitCast(older, to: SIMD16<UInt8>.self)
        )
        let lowBytes = distanceBytes.evenHalf
        let highBytes = distanceBytes.oddHalf
        let zero = SIMD16<UInt8>()
        let oneByte = unsafe unsafeBitCast(highBytes .== zero, to: SIMD16<UInt8>.self)
        let short = unsafe unsafeBitCast(highBytes | lowBytes & SIMD16(repeating: 0xF8) .== zero, to: SIMD16<UInt8>.self)
        thisGroup = thisGroup & ~short | eight & short
        nextGroup = nextGroup & ~short | eight & short
        let byteCounts = SIMD16<UInt8>(repeating: 2) &+ oneByte
        let costs = (thisGroup &+ byteCounts) &<< 2 &+ nextGroup
        let zeroPairs = unsafe unsafeBitCast((thisGroup | nextGroup) .== zero, to: SIMD16<UInt8>.self)

        // The current period's cost (no period bytes), 40 less 4 per equal byte in this group and 1 per equal
        // byte in the next: one weighted sum. It's on the chain from one group's period to the next's, so it
        // and the choice stay short: the candidates' minimum is found apart from it, and compared in scalars.
        let current = unsafe unsafeBitCast(bytes .== back, to: SIMD16<UInt8>.self)
        let currentWeights = unsafe scratch.load(fromByteOffset: LZBitmapEncoderWorkspace.currentWeights, as: SIMD16<UInt8>.self)
        let currentCost = 40 &- Int(UInt8(Builtin.int_vector_reduce_add_Vec16xInt8((current & currentWeights)._storage._value)))

        let newPeriod: Int
        let byteCount: Int
        if !ByteMatches(highBits: zeroPairs).any {
            // The cheapest candidate, the first of equals: the minimum of keys cost << 24 | (k + 1) << 16 |
            // period, built by lookups of the costs and periods' bytes. The current period wins ties. (No
            // branch: whether a candidate wins is a coin toss on mixed data.)
            let table = (bitCast(newer, to: SIMD16<UInt8>.self), bitCast(older, to: SIMD16<UInt8>.self), costs)
            @inline(__always) func keys(_ j: Int) -> SIMD4<UInt32> {
                // Unsafe: loads of constant index vectors from the workspace's scratch region. Safe: `j` is 0
                // through 3, within the 64 bytes each table has there.
                let indices = unsafe scratch.load(fromByteOffset: LZBitmapEncoderWorkspace.keyIndices &+ j &* 16, as: SIMD16<UInt8>.self)
                let choices = unsafe scratch.load(fromByteOffset: LZBitmapEncoderWorkspace.keyChoices &+ j &* 16, as: SIMD16<UInt8>.self)
                return unsafe unsafeBitCast(ByteLanes(indices).lookup(in: table) | choices, to: SIMD4<UInt32>.self)
            }
            let key = UInt32(Builtin.int_vector_reduce_umin_Vec4xInt32(Builtin.int_umin_Vec4xInt32(
                Builtin.int_umin_Vec4xInt32(keys(0)._storage._value, keys(1)._storage._value),
                Builtin.int_umin_Vec4xInt32(keys(2)._storage._value, keys(3)._storage._value)
            )))
            let wins = Int(key &>> 24) < currentCost
            let candidate = Int(key & 0xFFFF)
            newPeriod = wins ? candidate : period
            byteCount = wins ? (candidate < 256 ? 1 : 2) : 0
        } else {
            // Compression's scalar loop when a candidate repeats both groups: after choosing such a candidate,
            // later ones are compared at 4 less. Without branches (selects).
            unsafe scratch.storeBytes(of: costs, toByteOffset: LZBitmapEncoderWorkspace.choiceCosts, as: SIMD16<UInt8>.self)
            unsafe scratch.storeBytes(of: zeroPairs & SIMD16(repeating: 4), toByteOffset: LZBitmapEncoderWorkspace.choiceBonuses, as: SIMD16<UInt8>.self)
            unsafe scratch.storeBytes(of: byteCounts, toByteOffset: LZBitmapEncoderWorkspace.choiceByteCounts, as: SIMD16<UInt8>.self)
            unsafe scratch.storeBytes(of: newer, as: SIMD8<UInt16>.self)
            unsafe scratch.storeBytes(of: older, toByteOffset: 16, as: SIMD8<UInt16>.self)
            var bestCost = currentCost
            var bonus = 0
            var choice = 0
            for k in 0..<16 {
                let cost = unsafe Int(scratch.load(fromByteOffset: LZBitmapEncoderWorkspace.choiceCosts &+ k, as: UInt8.self)) &- bonus
                let wins = bestCost > cost
                bonus = wins ? unsafe Int(scratch.load(fromByteOffset: LZBitmapEncoderWorkspace.choiceBonuses &+ k, as: UInt8.self)) : bonus
                bestCost = wins ? cost : bestCost
                choice = wins ? k &+ 1 : choice
            }
            // Choice 0 is the current period; k + 1, candidate k.
            let candidate = choice &- 1 & 15
            newPeriod = choice == 0 ? period : unsafe Int(scratch.load(fromByteOffset: candidate &* 2, as: UInt16.self))
            byteCount = choice == 0 ? 0 : unsafe Int(scratch.load(fromByteOffset: LZBitmapEncoderWorkspace.choiceByteCounts &+ candidate, as: UInt8.self))
        }

        // The chosen period's bitmap and literals.
        let chosen = unsafe UnsafeRawPointer(here - newPeriod).loadUnaligned(as: SIMD8<UInt8>.self)
        // Each differing byte's lane bit, summed.
        let weights = unsafe scratch.load(fromByteOffset: LZBitmapEncoderWorkspace.laneBits, as: SIMD8<UInt8>.self)
        let differing = unsafe ~unsafeBitCast(bytes.lowHalf .== chosen, to: SIMD8<UInt8>.self) & weights
        let bitmap = Int(UInt8(Builtin.int_vector_reduce_add_Vec8xInt8(differing._storage._value)))
        let pack = unsafe packs.load(fromByteOffset: bitmap &* 16, as: SIMD16<UInt8>.self)
        let packed = ByteLanes(pack).lookup(in: bytes)
        unsafe UnsafeMutableRawPointer(literalStart + literals).storeBytes(
            of: bitCast(packed, to: SIMD2<UInt64>.self)[0], as: UInt64.self
        )
        literals &+= Int(pack[15])
        unsafe periods.storeBytes(of: UInt16(truncatingIfNeeded: newPeriod), toByteOffset: periodBytes, as: UInt16.self)
        periodBytes &+= byteCount
        period = newPeriod
        let code = bitmap | byteCount &<< 8
        unsafe codes[groupIndex] = UInt16(truncatingIfNeeded: code)
        unsafe histogram[code] &+= 0x10000
    }

    /// Inserts `position` (its low 16 bits) as the newer entry of the bucket at byte `offset` (twice its hash),
    /// moving its previous one to the older (the next bucket's newer).
    @inline(__always)
    static func insert(_ table: UnsafeMutablePointer<UInt16>, _ offset: Int, _ position: Int) {
        // Unsafe: the bucket's two entries, within the table (hashes are under 2^18), as one 32-bit word.
        let bucket = unsafe UnsafeMutableRawPointer(table) + offset
        let previous = unsafe bucket.loadUnaligned(as: UInt32.self)
        unsafe bucket.storeBytes(of: previous &<< 16 | UInt32(truncatingIfNeeded: position) & 0xFFFF, as: UInt32.self)
    }
}
