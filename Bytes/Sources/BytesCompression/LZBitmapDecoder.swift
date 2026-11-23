public import Bytes

/// An LZBITMAP decoder: Apple's Compression framework's `COMPRESSION_LZBITMAP` (0x702), streams starting
/// `ZBM\t`. Apple Encrypted Archive segments, Apple Archive `pbzb` blocks, and APFS-compressed files (decmpfs
/// type 14) use it.
///
/// ```swift
/// var decoder = LZBitmapDecoder()
/// let size = try LZBitmapDecoder.decompressedSize(of: compressed)    // from the chunk headers
/// let consumed = try decoder.decompressAll(compressed, decodedSize: size, into: &output)
/// ```
///
/// A stream is the magic, then chunks of up to 32 KiB of output each, then an empty chunk that ends it. Each
/// group of 8 output bytes has a bitmap: set bits take the next literal, clear bits copy the byte a *period*
/// back (up to 65,535 bytes, so across chunks). Chunks keep their literals, periods, bitmaps, and a nibble per
/// group (choosing one of 12 bitmaps stored at the chunk's end, or the next stored one, with run lengths) in
/// separate areas. `Benchmarks/RESULTS-lzbitmap.md` describes the format and the rules Compression's decoder
/// enforces, which this one follows: every stream Compression writes decodes, and every stream Compression
/// rejects is rejected. (Compression's own fast loop checks less than its careful loop, and decodes some
/// corrupt streams that its careful loop, and this decoder, reject.)
///
/// The decoder writes the caller's buffer only (matches read it as history) and allocates nothing per call:
/// its tables (each bitmap's lane shuffle, a chunk's nibbles, each group's nibble) are allocated once, at
/// creation. A chunk's nibbles are spelled out one per group first (up to 16 at a time); a vector pass then
/// resolves every group's bitmap and period, 16 groups at a time (prefix sums by table lookups give each
/// group's place in the bitmap and period areas); then each group is one table lookup (`tbl`) of 8 literals
/// and 8 history bytes, unchecked in blocks of 16 whose periods and room the pass and the loop verified, and a
/// block of 16 copies at one period is 128 bytes copied at once. Groups near the chunk's end, partial groups,
/// periods under 8, and errors go through careful paths. Malformed input throws; it never reads or writes
/// outside the buffers. Single-threaded on Apple silicon, it decodes Silesia files at 0.93–1.03× the speed of
/// Apple's Compression as 16 MB streams and 0.69–1.09× as 64 KB ones, about 3.2 instructions per byte, and
/// 10–17× as fast as libzbitmap (Benchmarks/RESULTS-lzbitmap.md, 2026-11-18).
/// Without NEON's `tbl` (the `Portable` build, other CPUs), groups are decoded one at a time.
@safe
public struct LZBitmapDecoder: ~Copyable {
    private var workspace = LZBitmapWorkspace()

    /// Creates a decoder, allocating its tables.
    public init() {}

    /// The number of bytes a stream decodes to, from its chunk headers, without decoding it.
    ///
    /// - Parameter input: The stream, at its start. Bytes after its end chunk are ignored.
    /// - Returns: The decompressed size.
    /// - Throws: ``BytesError/insufficientData`` if the input ends early; ``BytesError/invalidValue`` for a
    ///   wrong magic or a malformed chunk header.
    public static func decompressedSize(of input: RawSpan) throws(BytesError) -> Int {
        var reader = AlignedBytesReader(input)
        _ = try LZBitmapFormat.variant(reader.read(Byte4.self, .bigEndian))
        var total = 0
        while true {
            let length = Int(try reader.read(Byte3.self, .littleEndian))
            let size = Int(try reader.read(Byte3.self, .littleEndian))
            let kind = try LZBitmapFormat.chunkKind(length: length, size: size)
            if kind == .end { return total }
            try reader.skip(byteCount: length &- 6)
            total &+= size
        }
    }

    /// Decodes a stream, from its magic through its end chunk, into `output`'s free capacity.
    ///
    /// - Parameters:
    ///   - input: The stream, at its start. Bytes after its end chunk are left alone.
    ///   - decodedSize: The size the container says the stream decodes to, if it does: a stream decoding to more
    ///     or fewer bytes is corrupt.
    ///   - output: Where to append the decoded bytes; it needs room for all of them (for `decodedSize`, when
    ///     given). Bytes of its free capacity past them may be overwritten (none past `decodedSize`).
    /// - Returns: The number of input bytes decoded, through the end chunk.
    /// - Throws: ``BytesError/insufficientData`` if the input ends early; ``BytesError/insufficientCapacity``
    ///   if the output doesn't fit (or has room for fewer than `decodedSize` bytes); ``BytesError/mismatch`` if the
    ///   stream decodes to a size other than `decodedSize`; ``BytesError/invalidValue`` for corrupt data or a
    ///   negative `decodedSize`.
    public mutating func decompressAll(
        _ input: RawSpan, decodedSize: Int? = nil, into output: inout OutputRawSpan
    ) throws(BytesError) -> Int {
        if let decodedSize {
            guard decodedSize >= 0 else { throw .invalidValue }
            guard decodedSize <= output.freeCapacity else { throw .insufficientCapacity }
        }
        guard input.byteCount >= 4 else { throw .insufficientData }
        let workspace = unsafe workspace.base
        return try unsafe LZBuffers.with(input, &output, byteCount: decodedSize) { input, count, output, capacity throws(BytesError) -> (Int, Int) in
            // Unsafe: the buffers' addresses (a placeholder for an empty output, never written: every write is
            // checked against the capacity first).
            let result = try unsafe LZBitmapStream.decode(
                input.assumingMemoryBound(to: UInt8.self), count: count,
                output: output.assumingMemoryBound(to: UInt8.self), capacity: capacity,
                overrun: decodedSize == nil ? .insufficientCapacity : .mismatch, workspace: workspace
            )
            if let decodedSize, result.produced != decodedSize { throw .mismatch }
            return (result.consumed, result.produced)
        }
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension LZBitmapDecoder: @unchecked Sendable {}

/// The format's constants and chunk header rules.
enum LZBitmapFormat {
    /// The magic's last byte: Compression writes 0x09 (`ZBM\t`) and reads 0x08 the same way. It also accepts
    /// 0x0C and 0x0D, but with those, rejects every compressed chunk it writes: some other chunk format, which
    /// nothing here writes. Streams of only stored chunks decode under them.
    enum Variant { case standard, storedOnly }

    /// The variant a stream's first 4 bytes (big-endian) name.
    ///
    /// - Throws: ``BytesError/invalidValue`` if they aren't `ZBM` and one of 0x08, 0x09, 0x0C, 0x0D.
    @inline(__always)
    static func variant(_ magic: UInt32) throws(BytesError) -> Variant {
        guard magic & 0xFFFF_FFFA == 0x5A42_4D08 else { throw .invalidValue }
        return magic & 0x04 == 0 ? .standard : .storedOnly
    }
    /// The most a chunk decodes to.
    static let maximumChunkSize = 0x8000
    /// A compressed chunk's header: its length and size, then the offsets of its period, bitmap, and nibble
    /// areas (the literals start right after the header).
    static let headerSize = 15
    /// The 12 table bitmaps at a compressed chunk's end, 10 bits each (8 for the bitmap, 2 for its period's
    /// byte count), in 15 bytes plus 2 unused.
    static let trailerSize = 17
    /// The largest nibble area Compression accepts: one nibble per group of a full chunk.
    static let maximumNibbleBytes = 2048

    enum ChunkKind { case end, stored, compressed }

    /// What a chunk header with these fields is, by the rules Compression's decoder enforces: size 0 is the
    /// end (and must be 6 bytes long); a length of the size plus 6 is stored bytes; a longer one is invalid.
    @inline(__always)
    static func chunkKind(length: Int, size: Int) throws(BytesError) -> ChunkKind {
        if size == 0 {
            guard length == 6 else { throw .invalidValue }
            return .end
        }
        guard size <= maximumChunkSize else { throw .invalidValue }
        if length == size &+ 6 { return .stored }
        guard length < size &+ 6, length >= headerSize &+ trailerSize else { throw .invalidValue }
        return .compressed
    }
}

/// The tables: each bitmap's `tbl` indices and literal count, the current chunk's 16 nibble meanings, its
/// nibbles unpacked one per byte, each group's nibble, bitmap, and period, and copies of its period and bitmap
/// areas. Allocated once per decoder.
@safe @usableFromInline // Exported for clients' destroys, as `LZMAWorkspace`.
struct LZBitmapWorkspace: ~Copyable {
    static var maximumGroups: Int { LZBitmapFormat.maximumChunkSize / 8 }
    /// 256 × 16 bytes, one load per group: lane `i` of bitmap `b`'s shuffle is the literal's index (0–7) where
    /// bit `i` is set, and 8 + `i` (the history byte) where it's clear; byte 8 is the bitmap's literal count
    /// (lanes 8–15 of the shuffle's result are unused).
    static var shufflesOffset: Int { 0 }
    /// 16 × `UInt64`: what each nibble means in the current chunk (``LZBitmapStream/entry(bitmap:periodBytes:fromBitmapArea:)``).
    static var entriesOffset: Int { 4096 }
    /// Two vectors: each nibble's table bitmap (0 for 0–2 and 15), and its period's byte count (0 for 15).
    static var nibbleVectorsOffset: Int { 4224 }
    /// The current chunk's nibbles, one per byte, then a 15 to stop at, and room for 16-byte loads past it.
    static var nibblesOffset: Int { 4256 }
    /// The current chunk's groups' nibbles, repetitions spelled out, and room for a block of 16 past them.
    static var codesOffset: Int { nibblesOffset + LZBitmapFormat.maximumNibbleBytes * 2 + 64 }
    /// Each group's bitmap, 16 at a time.
    static var bitmapsOffset: Int { codesOffset + maximumGroups + 32 }
    /// Each group's period, 16 at a time.
    static var periodsOffset: Int { bitmapsOffset + maximumGroups + 32 }
    /// Each block of 16 groups: 1 if a period needs checking.
    static var flagsOffset: Int { periodsOffset + (maximumGroups + 32) * 2 }
    /// The chunk's period area (as much as can be used), after the initial period, 8, as 2 bytes; then zeros.
    static var periodAreaOffset: Int { flagsOffset + maximumGroups / 16 + 16 }
    /// The chunk's bitmap area (as much as can be used), then zeros.
    static var bitmapAreaOffset: Int { periodAreaOffset + 2 + maximumGroups * 2 + 64 }
    static var byteCount: Int { bitmapAreaOffset + maximumGroups + 32 }

    let memory = CodecWorkspace(byteCount: byteCount, alignment: 16)

    // Unsafe: the allocation's address. Safe: valid while the workspace (which owns it) lives.
    var base: UnsafeMutableRawPointer { unsafe memory.base }

    init() {
        // Unsafe: stores into the zeroed allocation. Safe: the offsets are within `byteCount`.
        for bitmap in 0..<256 {
            var literal = 0
            for lane in 0..<8 {
                let isLiteral = bitmap >> lane & 1 != 0
                unsafe base.storeBytes(of: UInt8(isLiteral ? literal : 8 &+ lane), toByteOffset: Self.shufflesOffset &+ bitmap &* 16 &+ lane, as: UInt8.self)
                if isLiteral { literal &+= 1 }
            }
            unsafe base.storeBytes(of: UInt8(literal), toByteOffset: Self.shufflesOffset &+ bitmap &* 16 &+ 8, as: UInt8.self)
        }
    }
}

/// The decode loops, on pointers checked by their callers.
enum LZBitmapStream {
    /// What a nibble means, laid out to pick its bitmap and period without branches: bits 0–7 are a mask for
    /// the bitmap area's next byte (0xFF if the bitmap is that byte), 8–15 its bitmap (0 if it's that byte),
    /// 16–23 how many bytes of new period follow in the period area, 32–47 a mask for those bytes.
    @inline(__always)
    static func entry(bitmap: Int, periodBytes: Int, fromBitmapArea: Bool) -> UInt64 {
        let mask: UInt64 = periodBytes == 0 ? 0 : periodBytes == 1 ? 0xFF : 0xFFFF
        return (fromBitmapArea ? 0xFF : UInt64(bitmap) &<< 8) | UInt64(periodBytes) &<< 16 | mask &<< 32
    }

    /// Decodes a whole stream from `input` into `output`.
    ///
    /// - Parameters:
    ///   - overrun: The error for output that doesn't fit in `capacity`.
    /// - Returns: The input consumed, through the end chunk, and the bytes written.
    static func decode(
        _ input: UnsafePointer<UInt8>, count: Int, output: UnsafeMutablePointer<UInt8>, capacity: Int, overrun: BytesError,
        workspace: UnsafeMutableRawPointer
    ) throws(BytesError) -> (consumed: Int, produced: Int) {
        // Unsafe: reads of the input, copies to the output. Safe: the caller checked that `count` is at least 4;
        // each header is read after checking that the input holds it, each chunk after checking that the input
        // holds all of it and the output has room for its size.
        let variant = try LZBitmapFormat.variant(unsafe UInt32(bigEndian: UnsafeRawPointer(input).loadUnaligned(as: UInt32.self)))
        var position = 4
        var produced = 0
        while true {
            guard count &- position >= 6 else { throw .insufficientData }
            let header = unsafe input + position
            let length = unsafe Int(header[0]) | Int(header[1]) &<< 8 | Int(header[2]) &<< 16
            let size = unsafe Int(header[3]) | Int(header[4]) &<< 8 | Int(header[5]) &<< 16
            let kind = try LZBitmapFormat.chunkKind(length: length, size: size)
            if kind == .end { return (position &+ 6, produced) }
            guard length <= count &- position else { throw .insufficientData }
            guard size <= capacity &- produced else { throw overrun }
            if kind == .stored {
                unsafe (output + produced).update(from: header + 6, count: size)
            } else {
                guard variant == .standard else { throw .invalidValue }
                try unsafe decodeChunk(
                    header, length: length, output: output, start: produced, size: size, workspace: workspace
                )
            }
            position &+= length
            produced &+= size
        }
    }

    /// Decodes a compressed chunk of `length` bytes at `chunk` into `output + start`, `size` bytes.
    ///
    /// The caller checked that the input holds the chunk, that it's at least a header and trailer long, and
    /// that the output has room for `size` bytes.
    static func decodeChunk(
        _ chunk: UnsafePointer<UInt8>, length: Int, output: UnsafeMutablePointer<UInt8>, start: Int, size: Int,
        workspace: UnsafeMutableRawPointer
    ) throws(BytesError) {
        // Unsafe: reads of the chunk's fields. Safe: the chunk holds at least its header and trailer.
        let literalsEnd = unsafe Int(chunk[6]) | Int(chunk[7]) &<< 8 | Int(chunk[8]) &<< 16
        let periodsEnd = unsafe Int(chunk[9]) | Int(chunk[10]) &<< 8 | Int(chunk[11]) &<< 16
        let bitmapsEnd = unsafe Int(chunk[12]) | Int(chunk[13]) &<< 8 | Int(chunk[14]) &<< 16
        let nibblesEnd = length &- LZBitmapFormat.trailerSize
        guard LZBitmapFormat.headerSize <= literalsEnd, literalsEnd <= periodsEnd, periodsEnd <= bitmapsEnd,
              bitmapsEnd <= nibblesEnd, nibblesEnd &- bitmapsEnd <= LZBitmapFormat.maximumNibbleBytes
        else { throw .invalidValue }

        // The 12 table bitmaps, 10 bits each from the trailer's first 15 bytes. Compression rejects a period
        // byte count of 3 in any of them, used or not.
        let entries = unsafe (workspace + LZBitmapWorkspace.entriesOffset).assumingMemoryBound(to: UInt64.self)
        // Unsafe: the trailer's 16 bytes from `nibblesEnd`, inside the chunk (the trailer is 17), and the
        // workspace's 16 entries.
        let trailer = unsafe UnsafeRawPointer(chunk + nibblesEnd)
        let bits = unsafe UInt128(UInt64(littleEndian: trailer.loadUnaligned(fromByteOffset: 8, as: UInt64.self))) &<< 64
            | UInt128(UInt64(littleEndian: trailer.loadUnaligned(as: UInt64.self)))
        // Also as two vectors by nibble, for the vector pass: the table bitmap (0 for 0–2 and 15) and the
        // period's byte count.
        let nibbleVectors = unsafe (workspace + LZBitmapWorkspace.nibbleVectorsOffset).assumingMemoryBound(to: UInt8.self)
        for index in 0..<12 {
            let field = Int(truncatingIfNeeded: bits &>> (index &* 10)) & 0x3FF
            guard field < 0x300 else { throw .invalidValue }
            unsafe entries[index &+ 3] = entry(bitmap: field & 0xFF, periodBytes: field &>> 8, fromBitmapArea: false)
            unsafe nibbleVectors[index &+ 3] = UInt8(field & 0xFF)
            unsafe nibbleVectors[16 &+ index &+ 3] = UInt8(field &>> 8)
        }
        for periodBytes in 0..<3 {
            unsafe entries[periodBytes] = entry(bitmap: 0, periodBytes: periodBytes, fromBitmapArea: true)
            unsafe nibbleVectors[periodBytes] = 0
            unsafe nibbleVectors[16 &+ periodBytes] = UInt8(periodBytes)
        }
        unsafe entries[15] = 0
        unsafe nibbleVectors[15] = 0
        unsafe nibbleVectors[31] = 0

        // The nibbles, one per byte, low nibble first, then a 15: reading it as a group's nibble throws, and as
        // a repetition mark, the count's reader stops at the end. Then each group's nibble, repetitions spelled
        // out: the group loops read one byte per group.
        let nibbles = unsafe (workspace + LZBitmapWorkspace.nibblesOffset).assumingMemoryBound(to: UInt8.self)
        let nibbleCount = (nibblesEnd &- bitmapsEnd) &* 2
        unsafe unpackNibbles(chunk + bitmapsEnd, byteCount: nibblesEnd &- bitmapsEnd, into: nibbles)
        unsafe nibbles[nibbleCount] = 15
        let codes = unsafe (workspace + LZBitmapWorkspace.codesOffset).assumingMemoryBound(to: UInt8.self)
        let groups = (size &+ 7) &>> 3
        try unsafe expandCodes(nibbles, count: nibbleCount, groups: groups, into: codes)

        let literals: Int
        let periods: Int
        let bitmapsUsed: Int
        if ByteLanes.isLookupVectorized {
            // Each group's bitmap and period, 16 groups at a time, then the groups.
            unsafe (periods, bitmapsUsed) = resolveGroups(
                chunk: chunk, literalsEnd: literalsEnd, periodsEnd: periodsEnd, bitmapsEnd: bitmapsEnd, codes: codes,
                groups: groups, written: start, workspace: workspace
            )
            literals = try unsafe emitGroups(
                chunk: chunk, length: length, literalsEnd: literalsEnd, groups: groups, workspace: workspace,
                outputStart: output, start: start, end: start &+ size
            )
        } else {
            // Without `tbl`, a group at a time.
            unsafe (literals, periods, bitmapsUsed) = try decodeGroups(
                chunk: chunk, length: length, literalsEnd: literalsEnd, periodsEnd: periodsEnd, bitmapsEnd: bitmapsEnd,
                codes: codes, entries: entries, shuffles: UnsafeRawPointer(workspace + LZBitmapWorkspace.shufflesOffset),
                outputStart: output, start: start, end: start &+ size
            )
        }
        // Compression requires the literal and period areas to be used up (the bitmap and nibble areas may
        // have bytes left).
        guard literals == literalsEnd, periods == periodsEnd, bitmapsUsed <= bitmapsEnd else { throw .invalidValue }
    }

    /// Unpacks `byteCount` bytes of nibbles at `source` into one nibble per byte at `nibbles`, low nibble
    /// first: a load, mask, shift, and interleaving store (`st2`) per 16 bytes.
    @inline(__always)
    static func unpackNibbles(_ source: UnsafePointer<UInt8>, byteCount: Int, into nibbles: UnsafeMutablePointer<UInt8>) {
        // Unsafe: reading `byteCount` bytes of the chunk, writing twice as many to the workspace, which holds
        // 2 × 2048 (the caller checked `byteCount <= 2048`).
        for index in 0..<byteCount {
            let byte = unsafe source[index]
            unsafe nibbles[index &* 2] = byte & 0x0F
            unsafe nibbles[index &* 2 &+ 1] = byte &>> 4
        }
    }

    /// Spells out the groups' nibbles: `groups` codes at `codes`, each 0–14, a nibble with a repetition count
    /// after it written as many times (up to the last group).
    ///
    /// A nibble is followed by a count when the next nibble is 15 and it isn't the chunk's last group's (with
    /// 8 bytes or fewer left, Compression doesn't look). Of 16 nibbles, those before the one the first 15
    /// follows (15 if there's none) are groups without counts, copied at once; the one with a count, a nibble at
    /// a time.
    ///
    /// - Parameters:
    ///   - nibbles: `count` nibbles, then a 15, then at least 15 more bytes (of anything 0–15).
    ///   - codes: Room for `groups` + 16 bytes.
    /// - Throws: ``BytesError/invalidValue`` if the nibbles run out, or a group's is 15.
    static func expandCodes(
        _ nibbles: UnsafePointer<UInt8>, count: Int, groups: Int, into codes: UnsafeMutablePointer<UInt8>
    ) throws(BytesError) {
        // Unsafe: 16-byte loads from `nibbles` while `next` is at most `count` (the 15 there ends the copies,
        // and the caller left room after it), single nibbles before `count` or the 15 at it; codes written below
        // `groups` + 16.
        var next = unsafe nibbles
        let end = unsafe nibbles + count
        var group = 0
        while group < groups {
            let block = unsafe UnsafeRawPointer(next).loadUnaligned(as: SIMD16<UInt8>.self)
            // 15 + 0x71 is the only nibble with its high bit set. The nibbles before the one the first 15
            // follows are groups without counts (each followed by one that isn't 15): copied at once.
            let fifteens = ByteMatches(highBits: block &+ SIMD16(repeating: 0x71)).nibbleMask
            let plain = fifteens == 0 ? 15 : fifteens.trailingZeroBitCount &>> 2 &- 1
            if plain > 0 {
                unsafe UnsafeMutableRawPointer(codes + group).storeBytes(of: block, as: SIMD16<UInt8>.self)
                group &+= plain
                unsafe next += plain
                continue
            }
            let code = unsafe next[0]
            unsafe next += 1
            guard code != 15 else { throw .invalidValue }
            var repeats = 1
            if group < groups &- 1, unsafe next[0] == 15 {
                unsafe (repeats, next) = try readCount(at: next, end: end)
            }
            repeats = min(repeats, groups &- group)
            // 16 at a time (up to 15 past the repetition, within the room after `groups`): counts are mostly
            // short, and `memset` was a call.
            let splat = SIMD16<UInt8>(repeating: code)
            var filled = 0
            repeat {
                unsafe UnsafeMutableRawPointer(codes + (group &+ filled)).storeBytes(of: splat, as: SIMD16<UInt8>.self)
                filled &+= 16
            } while filled < repeats
            group &+= repeats
        }
    }

    // MARK: The vector pass

    /// `iota - k` as indices: a lookup moves each lane `k` lanes up, with zeros shifted in (indices of 16 or
    /// more look up 0). As `Byte16` literals (bytes in memory order), which fold to constants.
    @inline(__always) static var up1: SIMD16<UInt8> { (0xFF_00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E as Byte16).vector }
    @inline(__always) static var up2: SIMD16<UInt8> { (0xFF_FF_00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D as Byte16).vector }
    @inline(__always) static var up4: SIMD16<UInt8> { (0xFF_FF_FF_FF_00_01_02_03_04_05_06_07_08_09_0A_0B as Byte16).vector }
    @inline(__always) static var up8: SIMD16<UInt8> { (0xFF_FF_FF_FF_FF_FF_FF_FF_00_01_02_03_04_05_06_07 as Byte16).vector }

    /// Each lane's sum with the lanes before it (the values small enough not to wrap): four lookups and adds.
    @inline(__always)
    static func prefixSums(_ vector: SIMD16<UInt8>) -> SIMD16<UInt8> {
        var sums = vector
        sums &+= ByteLanes(up1).lookup(in: sums)
        sums &+= ByteLanes(up2).lookup(in: sums)
        sums &+= ByteLanes(up4).lookup(in: sums)
        sums &+= ByteLanes(up8).lookup(in: sums)
        return sums
    }

    /// 0xFF in the lanes that are 0, 0 in the others, for lanes 0–127. (Arithmetic: on Swift 6.4,
    /// `replacing(with:where:)` with a comparison's mask compiled a lane at a time here.)
    @inline(__always)
    static func zeroLanes(_ vector: SIMD16<UInt8>) -> SIMD16<UInt8> {
        SIMD16() &- ((vector &- 1) &>> 7)
    }

    /// A comparison's mask as lanes of all ones or zeros: the `cmhi` result itself. (Converting with
    /// `replacing(with:where:)` compiled a lane at a time.)
    @inline(__always)
    static func lanes(_ mask: SIMDMask<SIMD8<Int16>>) -> SIMD8<UInt16> {
        // Unsafe: a reinterpretation of the same 16 bytes; a mask's storage is its lanes, each 0 or -1.
        unsafe unsafeBitCast(mask, to: SIMD8<UInt16>.self)
    }

    /// Each lane's value, or where it's 0, the last nonzero lane's before it (0 if none). Lanes 0–127.
    @inline(__always)
    static func fillForward(_ vector: SIMD16<UInt8>) -> SIMD16<UInt8> {
        var filled = vector
        filled |= ByteLanes(up1).lookup(in: filled) & zeroLanes(filled)
        filled |= ByteLanes(up2).lookup(in: filled) & zeroLanes(filled)
        filled |= ByteLanes(up4).lookup(in: filled) & zeroLanes(filled)
        filled |= ByteLanes(up8).lookup(in: filled) & zeroLanes(filled)
        return filled
    }

    /// Resolves every group's bitmap and period, 16 groups at a time, into the workspace: the bitmap area's
    /// bytes picked by a lookup at each group's count of bitmap-area nibbles before it, the table's by a lookup
    /// at its nibble; each period's bytes picked from the period area at the running sum of period bytes, and
    /// carried forward to the groups that keep it. A block of 16 whose periods aren't all 8 through the bytes
    /// written before their group (as the fast path needs) is flagged, for checks a group at a time.
    ///
    /// The areas are copied first, after a period of 8 (the chunk's first) and before zeros, so the lookups'
    /// 16- and 48-byte loads stay in the workspace whatever the cursors do. The caller checks that they ended
    /// where they should.
    ///
    /// - Parameters:
    ///   - codes: `groups` nibbles; this writes 15s after them, to the block's end (no bitmap, no period).
    ///   - written: The bytes the stream has before the chunk.
    /// - Returns: The chunk offsets where the period and bitmap areas' used bytes end.
    static func resolveGroups(
        chunk: UnsafePointer<UInt8>, literalsEnd: Int, periodsEnd: Int, bitmapsEnd: Int, codes: UnsafeMutablePointer<UInt8>,
        groups: Int, written: Int, workspace: UnsafeMutableRawPointer
    ) -> (periods: Int, bitmaps: Int) {
        let maximumGroups = LZBitmapWorkspace.maximumGroups
        // Unsafe: copies and loads within the workspace's areas: a period area of 2 + 2 × 4,096 bytes and 64 more,
        // and a bitmap area of 4,096 and 32 more, which the cursors can't pass (a group takes at most 2 period
        // bytes and 1 bitmap, and there are at most 4,096 groups: a load at a cursor reads 48 or 16 bytes);
        // codes, bitmaps, and periods for `groups` rounded up to 16, within their 4,096 + 32.
        let periodArea = unsafe (workspace + LZBitmapWorkspace.periodAreaOffset).assumingMemoryBound(to: UInt8.self)
        let periodCount = min(periodsEnd &- literalsEnd, maximumGroups &* 2)
        unsafe periodArea[0] = 8
        unsafe periodArea[1] = 0
        unsafe (periodArea + 2).update(from: chunk + literalsEnd, count: periodCount)
        unsafe (periodArea + 2 + periodCount).update(repeating: 0, count: 64)
        let bitmapArea = unsafe (workspace + LZBitmapWorkspace.bitmapAreaOffset).assumingMemoryBound(to: UInt8.self)
        let bitmapCount = min(bitmapsEnd &- periodsEnd, maximumGroups)
        unsafe bitmapArea.update(from: chunk + periodsEnd, count: bitmapCount)
        unsafe (bitmapArea + bitmapCount).update(repeating: 0, count: 32)
        unsafe (codes + groups).update(repeating: 15, count: 16)

        let tableBitmaps = unsafe (workspace + LZBitmapWorkspace.nibbleVectorsOffset).load(as: SIMD16<UInt8>.self)
        let periodBytesByNibble = unsafe (workspace + LZBitmapWorkspace.nibbleVectorsOffset).load(fromByteOffset: 16, as: SIMD16<UInt8>.self)
        let bitmaps = unsafe workspace + LZBitmapWorkspace.bitmapsOffset
        let periods = unsafe workspace + LZBitmapWorkspace.periodsOffset
        let flags = unsafe (workspace + LZBitmapWorkspace.flagsOffset).assumingMemoryBound(to: UInt8.self)
        let one = SIMD16<UInt8>(repeating: 1)
        let eight = SIMD8<UInt16>(repeating: 8)
        // Each lane's bytes written before its group, from the block's start: 8 per lane.
        let lanes0 = SIMD8<UInt16>(0, 8, 16, 24, 32, 40, 48, 56)
        let lanes1 = lanes0 &+ SIMD8(repeating: 64)

        var bitmapCursor = 0
        // Where the current period ends in `periodArea` (after the initial 8's two bytes), and its byte count.
        var periodEnd = 2
        var lastPeriodBytes: UInt8 = 2
        var block = 0
        while block &* 16 < groups {
            let codeVector = unsafe UnsafeRawPointer(codes + block &* 16).loadUnaligned(as: SIMD16<UInt8>.self)

            // Bitmaps: lane i takes the bitmap area's byte at the count of bitmap-area nibbles before it, or
            // the table's.
            // (Nibbles under 3: 3 + 0x7D sets the high bit.)
            let areaOnes = ((codeVector &+ 0x7D) &>> 7) ^ one
            let areaSums = prefixSums(areaOnes)
            let window = unsafe UnsafeRawPointer(bitmapArea + bitmapCursor).loadUnaligned(as: SIMD16<UInt8>.self)
            let areaBitmaps = ByteLanes(areaSums &- areaOnes).lookup(in: window)
            // (The table's bitmap is 0 for nibbles under 3.)
            let blockBitmaps = ByteLanes(codeVector).lookup(in: tableBitmaps) | areaBitmaps & (SIMD16() &- areaOnes)
            unsafe (bitmaps + block &* 16).storeBytes(of: blockBitmaps, as: SIMD16<UInt8>.self)
            bitmapCursor &+= Int(areaSums[15])

            // Periods: a group with new period bytes ends them at the running sum of period bytes; one without
            // keeps the last (whose bytes end at the same sum). The last's byte count picks 1 or 2 bytes.
            let byteCounts = ByteLanes(codeVector).lookup(in: periodBytesByNibble)
            let ends = prefixSums(byteCounts)
            var lastCounts = fillForward(byteCounts)
            lastCounts |= SIMD16(repeating: lastPeriodBytes) & zeroLanes(lastCounts)
            // 48 bytes from 2 before the block's first period end: lane i's last byte is at `ends[i] + 1`.
            let base = unsafe UnsafeRawPointer(periodArea + (periodEnd &- 2))
            let table = unsafe (
                base.loadUnaligned(as: SIMD16<UInt8>.self), base.loadUnaligned(fromByteOffset: 16, as: SIMD16<UInt8>.self),
                base.loadUnaligned(fromByteOffset: 32, as: SIMD16<UInt8>.self)
            )
            let last = ByteLanes(ends &+ one).lookup(in: table)
            let beforeLast = ByteLanes(ends).lookup(in: table)
            // 0xFF where the last period has 2 bytes (counts are 1 or 2).
            let isTwo = SIMD16() &- (lastCounts &>> 1)
            let low = last ^ ((last ^ beforeLast) & isTwo)
            let high = last & isTwo
            // Each period's two bytes side by side: `zip1` and `zip2` of the low and high bytes. (Not
            // `SIMD8<UInt16>(truncatingIfNeeded:)`: that generic conversion was inlined only while this was its
            // one caller in the module; once the LZFSE and LZVN encoders used it too, it stayed a call, 6 per 16
            // groups, and decoding ran 12–15% more instructions.)
            let periods0 = bitCast(SIMD16<UInt8>(
                low[0], high[0], low[1], high[1], low[2], high[2], low[3], high[3],
                low[4], high[4], low[5], high[5], low[6], high[6], low[7], high[7]
            ), to: SIMD8<UInt16>.self)
            let periods1 = bitCast(SIMD16<UInt8>(
                low[8], high[8], low[9], high[9], low[10], high[10], low[11], high[11],
                low[12], high[12], low[13], high[13], low[14], high[14], low[15], high[15]
            ), to: SIMD8<UInt16>.self)
            unsafe (periods + block &* 32).storeBytes(of: periods0, as: SIMD8<UInt16>.self)
            unsafe (periods + (block &* 32 &+ 16)).storeBytes(of: periods1, as: SIMD8<UInt16>.self)
            periodEnd &+= Int(ends[15])
            lastPeriodBytes = lastCounts[15]

            // The fast path's condition, 8 through the bytes written before the group. (Written counts are
            // capped at 65,535 - 120, keeping limits within 16 bits; the few periods reaching past the cap are
            // flagged, and checked a group at a time.)
            let before = SIMD8<UInt16>(repeating: UInt16(min(written &+ block &* 128, 65_535 &- 120)))
            let outside0 = lanes(periods0 .< eight .| periods0 .> before &+ lanes0)
            let outside1 = lanes(periods1 .< eight .| periods1 .> before &+ lanes1)
            // 2 for a block of copies only (every bitmap 0) at one period: an LZ match of 128 bytes, copied
            // 16 bytes at a time.
            // In bytes: the bitmaps, and each period byte against lane 0's (a lookup at index 0), all zero. (A
            // byte is nonzero when it or its negation has the high bit. Reductions were unreliable here on
            // Swift 6.4: `SIMD16<UInt8>.max()` was a call, `SIMD8<UInt16>.max()` one `umaxv` or 16 lane moves.)
            let lane0 = SIMD16<UInt8>()
            let differences = blockBitmaps | (low ^ ByteLanes(lane0).lookup(in: low)) | (high ^ ByteLanes(lane0).lookup(in: high))
            let sameCopies = !ByteMatches(highBits: differences | (SIMD16() &- differences)).any
            // The lanes are all ones or zero: any outside is any byte with its high bit, no narrowing needed.
            let outsideSigns = bitCast(outside0 | outside1, to: SIMD16<UInt8>.self)
            unsafe flags[block] = ByteMatches(highBits: outsideSigns).any ? 1 : sameCopies ? 2 : 0
            block &+= 1
        }
        return (literalsEnd &+ periodEnd &- 2, periodsEnd &+ bitmapCursor)
    }

    /// Writes the chunk's groups from the resolved bitmaps and periods: blocks of 16 whose periods are all
    /// fine, and whose literals and output have room for 16 whole groups, with no checks; others a group at
    /// a time, with every check, through `careful` where the fast path can't go.
    ///
    /// - Returns: The chunk offset where the literals used end.
    static func emitGroups(
        chunk: UnsafePointer<UInt8>, length: Int, literalsEnd: Int, groups: Int, workspace: UnsafeMutableRawPointer,
        outputStart: UnsafeMutablePointer<UInt8>, start: Int, end: Int
    ) throws(BytesError) -> Int {
        // Unsafe: reads of the resolved fields (`groups` of each) and the literals, writes of the output. Safe:
        // a block without checks starts with 16 × 8 + 8 literal bytes left in the chunk and 16 × 8 output bytes
        // left, its periods 8 through the bytes written (the flag); a group with checks reads 8 literals only
        // up to the area's end and writes 8 bytes only with 8 left, and goes through `careful` otherwise. (In
        // a block without checks, the literals may run past their area, into the next: the caller checks that
        // they ended where they should, rejecting the stream.)
        let shuffles = unsafe UnsafeRawPointer(workspace + LZBitmapWorkspace.shufflesOffset)
        let bitmaps = unsafe UnsafeRawPointer(workspace + LZBitmapWorkspace.bitmapsOffset).assumingMemoryBound(to: UInt8.self)
        let periods = unsafe UnsafeRawPointer(workspace + LZBitmapWorkspace.periodsOffset).assumingMemoryBound(to: UInt16.self)
        let flags = unsafe UnsafeRawPointer(workspace + LZBitmapWorkspace.flagsOffset).assumingMemoryBound(to: UInt8.self)
        var literal = unsafe chunk + LZBitmapFormat.headerSize
        let literalLimit = unsafe chunk + literalsEnd
        let chunkEnd = unsafe chunk + length
        var out = unsafe outputStart + start
        let outEnd = unsafe outputStart + end
        let wholeGroups = (end &- start) &>> 3
        var group = 0
        while group < groups {
            let flag = unsafe flags[group &>> 4]
            if flag == 2, group &+ 16 <= wholeGroups {
                // 128 bytes copied from one period back (8 through the bytes written: the flag), 16 at a time
                // when the period allows (each load then reads bytes already written), else 8.
                let distance = unsafe Int(periods[group])
                let source = unsafe UnsafeRawPointer(out - distance)
                let target = UnsafeMutableRawPointer(out)
                if distance >= 16 {
                    for offset in stride(from: 0, to: 128, by: 16) {
                        unsafe target.storeBytes(
                            of: source.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self), toByteOffset: offset, as: SIMD16<UInt8>.self
                        )
                    }
                } else {
                    for offset in stride(from: 0, to: 128, by: 8) {
                        unsafe target.storeBytes(
                            of: source.loadUnaligned(fromByteOffset: offset, as: UInt64.self), toByteOffset: offset, as: UInt64.self
                        )
                    }
                }
                unsafe out += 128
                group &+= 16
            } else if group &+ 16 <= wholeGroups, flag == 0, unsafe chunkEnd - literal >= 16 &* 8 &+ 8 {
                let blockEnd = group &+ 16
                repeat {
                    let bitmap = unsafe Int(bitmaps[group])
                    let shuffle = unsafe shuffles + bitmap &* 16
                    unsafe emit(out, literal: literal, history: out - Int(periods[group]), bitmap: bitmap, shuffle: shuffle)
                    unsafe literal += Int(shuffle.load(fromByteOffset: 8, as: UInt8.self))
                    unsafe out += 8
                    group &+= 1
                } while group < blockEnd
            } else {
                let blockEnd = min(group &+ 16, groups)
                repeat {
                    let bitmap = unsafe Int(bitmaps[group])
                    let distance = unsafe Int(periods[group])
                    let source = unsafe out - distance
                    let shuffle = unsafe shuffles + bitmap &* 16
                    let checks = unsafe (literalLimit - literal) | (outEnd - out &- 8) | (distance &- 8) | (source - outputStart)
                    if checks >= 0 {
                        unsafe emit(out, literal: literal, history: source, bitmap: bitmap, shuffle: shuffle)
                        unsafe literal += Int(shuffle.load(fromByteOffset: 8, as: UInt8.self))
                        unsafe out += 8
                    } else {
                        let lanes = unsafe min(8, outEnd - out)
                        unsafe literal = try careful(
                            bitmap: bitmap, distance: distance, written: out - outputStart, lanes: lanes, out: out,
                            literal: literal, literalLimit: literalLimit
                        )
                        unsafe out += lanes
                    }
                    group &+= 1
                } while group < blockEnd
            }
        }
        return unsafe literal - chunk
    }

    // MARK: A group at a time

    /// Decodes a chunk's groups into `outputStart[start..<end]`, a group at a time: the path without `tbl`.
    ///
    /// - Returns: The chunk offsets where the literals, periods, and bitmaps used end.
    @inline(__always)
    static func decodeGroups(
        chunk: UnsafePointer<UInt8>, length: Int, literalsEnd: Int, periodsEnd: Int, bitmapsEnd: Int,
        codes: UnsafePointer<UInt8>, entries: UnsafePointer<UInt64>, shuffles: UnsafeRawPointer,
        outputStart: UnsafeMutablePointer<UInt8>, start: Int, end: Int
    ) throws(BytesError) -> (literals: Int, periods: Int, bitmaps: Int) {
        // Unsafe: reads of the chunk's areas and the tables, writes of the output. Safe:
        // - one code is read per group, of the chunk's `(end - start + 7) / 8`;
        // - each area's cursor starts at its start. In the fast loop, a run of groups has room inside the chunk
        //   for each cursor's most per group (8 literals, 2 period bytes, 1 bitmap) and in the output for 8 bytes
        //   each. In the careful loop, a group's checks find a cursor past its area's end before anything is
        //   read there: the literal cursor's 8-byte loads, the period cursor's 2-byte ones, and the bitmap
        //   cursor's byte stay inside the chunk while each is at most its area's end, since the nibbles and the
        //   17-byte trailer follow them all. (A cursor can run past its area's end in the fast loop, reading
        //   the next area: the checks after the loops find it, rejecting the stream.)
        // - a group's history load happens with the period 8 through the bytes written before it; anything else
        //   goes through `careful`.
        var literal = unsafe chunk + LZBitmapFormat.headerSize
        let literalLimit = unsafe chunk + literalsEnd
        var period = unsafe chunk + literalsEnd
        let periodLimit = unsafe chunk + periodsEnd
        var bitmapCursor = unsafe chunk + periodsEnd
        let bitmapLimit = unsafe chunk + bitmapsEnd
        let chunkEnd = unsafe chunk + length
        var code = unsafe codes
        var out = unsafe outputStart + start
        let outEnd = unsafe outputStart + end
        var distance = 8

        // The fast loop: runs of groups whose only check is the period's.
        while true {
            // (Two-argument `min`s: the variadic one builds an array.)
            let room = unsafe min(
                min((outEnd - out) &>> 3, (chunkEnd - literal &- 8) &>> 3), min((chunkEnd - period &- 2) &>> 1, chunkEnd - bitmapCursor &- 1)
            )
            if room <= 0 { break }
            let runEnd = unsafe out + room &* 8
            repeat {
                let entry = unsafe entries[Int(code[0])]
                unsafe code += 1
                let bitmap = unsafe fields(entry, bitmap: &bitmapCursor, period: &period, distance: &distance)
                let shuffle = unsafe shuffles + bitmap &* 16
                let source = unsafe out - distance
                if _fastPath(unsafe (distance &- 8) | (source - outputStart) >= 0) {
                    unsafe emit(out, literal: literal, history: source, bitmap: bitmap, shuffle: shuffle)
                    unsafe literal += Int(shuffle.load(fromByteOffset: 8, as: UInt8.self))
                } else {
                    unsafe literal = try careful(
                        bitmap: bitmap, distance: distance, written: out - outputStart, lanes: 8, out: out,
                        literal: literal, literalLimit: literalLimit
                    )
                }
                unsafe out += 8
            } while unsafe out < runEnd
        }

        // The careful loop: the rest (near the chunk's end, or a partial last group), with every check.
        while unsafe out < outEnd {
            let entry = unsafe entries[Int(code[0])]
            unsafe code += 1
            let bitmap = unsafe fields(entry, bitmap: &bitmapCursor, period: &period, distance: &distance)
            guard unsafe period <= periodLimit, unsafe bitmapCursor <= bitmapLimit else { throw .invalidValue }
            let source = unsafe out - distance
            let checks = unsafe (literalLimit - literal) | (outEnd - out &- 8) | (distance &- 8) | (source - outputStart)
            let shuffle = unsafe shuffles + bitmap &* 16
            if checks >= 0 {
                unsafe emit(out, literal: literal, history: source, bitmap: bitmap, shuffle: shuffle)
                unsafe literal += Int(shuffle.load(fromByteOffset: 8, as: UInt8.self))
                unsafe out += 8
            } else {
                let lanes = unsafe min(8, outEnd - out)
                unsafe literal = try careful(
                    bitmap: bitmap, distance: distance, written: out - outputStart, lanes: lanes, out: out,
                    literal: literal, literalLimit: literalLimit
                )
                unsafe out += lanes
            }
        }
        return unsafe (literal - chunk, period - chunk, bitmapCursor - chunk)
    }

    /// A group's bitmap, from its nibble's meaning: the table's, or the bitmap area's next byte (without a
    /// branch: on text, which one is a coin toss). Takes the new period, if any, from the period area.
    @inline(__always)
    static func fields(
        _ entry: UInt64, bitmap cursor: inout UnsafePointer<UInt8>, period: inout UnsafePointer<UInt8>, distance: inout Int
    ) -> Int {
        // Unsafe: a byte at the bitmap cursor and 2 at the period cursor; the caller keeps them in the chunk.
        let bitmap = unsafe Int(entry &>> 8 & 0xFF) | Int(cursor[0]) & Int(truncatingIfNeeded: entry)
        unsafe cursor += Int(entry & 1)
        let periodBytes = Int(entry &>> 16 & 0xFF)
        let loaded = unsafe Int(UInt16(littleEndian: UnsafeRawPointer(period).loadUnaligned(as: UInt16.self))) & Int(entry &>> 32)
        distance = periodBytes == 0 ? distance : loaded
        unsafe period += periodBytes
        return bitmap
    }

    /// Writes a whole group: 8 literals from `literal` and 8 history bytes from `history`, picked by `bitmap`.
    @inline(__always)
    static func emit(
        _ out: UnsafeMutablePointer<UInt8>, literal: UnsafePointer<UInt8>, history: UnsafePointer<UInt8>, bitmap: Int,
        shuffle: UnsafeRawPointer
    ) {
        // Unsafe: 8-byte loads and a store; the caller checked the room.
        let historyBytes = unsafe UnsafeRawPointer(history).loadUnaligned(as: SIMD8<UInt8>.self)
        let literals = unsafe UnsafeRawPointer(literal).loadUnaligned(as: SIMD8<UInt8>.self)
        let group = unsafe select(bitmap: bitmap, literals: literals, history: historyBytes, shuffle: shuffle)
        unsafe UnsafeMutableRawPointer(out).storeBytes(of: group, as: SIMD8<UInt8>.self)
    }

    /// Lane `i` of the group: the next literal where bit `i` of `bitmap` is set, history byte `i` where it's
    /// clear. One `tbl` on the literals and history together where NEON's lookup is there.
    @inline(__always)
    static func select(bitmap: Int, literals: SIMD8<UInt8>, history: SIMD8<UInt8>, shuffle: UnsafeRawPointer) -> SIMD8<UInt8> {
        if ByteLanes.isLookupVectorized {
            // Unsafe: the bitmap's 16-byte entry in the shuffle table (aligned: the table starts the workspace).
            let index = unsafe shuffle.load(as: SIMD16<UInt8>.self)
            return ByteLanes(index).lookup(in: SIMD16(lowHalf: literals, highHalf: history)).lowHalf
        } else {
            var result = history
            var next = 0
            for lane in 0..<8 where bitmap >> lane & 1 != 0 {
                result[lane] = literals[next]
                next &+= 1
            }
            return result
        }
    }

    /// A repetition count at `nibble`, the 15 that marks it: 4 plus the nibbles after it, through the first
    /// that isn't 15. Out of line, taking and returning values, so the caller's cursor stays in a register.
    ///
    /// - Returns: The count, and the nibble after it.
    @inline(never)
    static func readCount(at nibble: UnsafePointer<UInt8>, end: UnsafePointer<UInt8>) throws(BytesError) -> (Int, UnsafePointer<UInt8>) {
        var cursor = unsafe nibble + 1
        var total = 4
        // Unsafe: nibbles before `end`.
        while true {
            guard unsafe cursor < end else { throw .invalidValue }
            let value = unsafe Int(cursor[0])
            unsafe cursor += 1
            total &+= value
            if value != 15 { break }
        }
        return unsafe (total, cursor)
    }

    /// A group the fast path can't take: the chunk's last, partial one (`lanes` under 8, the bits past it
    /// ignored), a period under 8 (copying a byte at a time, so the group can repeat itself), or one to check:
    /// literals running out, or a period of 0 or reaching before the output's start. Compression allows those
    /// in a group of only literals (0xFF), and rejects them in any other, whichever lanes are past the end.
    ///
    /// - Returns: The literal cursor after the group.
    @inline(never)
    static func careful(
        bitmap: Int, distance: Int, written: Int, lanes: Int, out: UnsafeMutablePointer<UInt8>,
        literal: UnsafePointer<UInt8>, literalLimit: UnsafePointer<UInt8>
    ) throws(BytesError) -> UnsafePointer<UInt8> {
        if bitmap != 0xFF {
            guard distance >= 1, distance <= written else { throw .invalidValue }
        }
        var literal = unsafe literal
        // Unsafe: literals before `literalLimit`, history from `distance` back (at most `written`, checked
        // above), and `lanes` output bytes (the caller's room).
        for lane in 0..<lanes {
            if bitmap >> lane & 1 != 0 {
                guard unsafe literal < literalLimit else { throw .invalidValue }
                unsafe out[lane] = literal[0]
                unsafe literal += 1
            } else {
                unsafe out[lane] = out[lane &- distance]
            }
        }
        return unsafe literal
    }
}
