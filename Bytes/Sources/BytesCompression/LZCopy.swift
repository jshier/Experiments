internal import Bytes

// Shared by the LZ decoders and encoders: raw pointers over their buffers (`LZBuffers`, all six whole-buffer
// decoders), and copies of literals and matches 16 bytes at a time into slack the callers leave past them, and exact
// copies for the ends of buffers. Positions are raw pointers whose bounds the callers check first, as in the
// Zstandard decoder (`ZstdCopy`, whose short-offset copy this reuses).

/// Raw pointers over a span's bytes and an output span's free capacity, for the coders' loops.
enum LZBuffers {
    /// Calls `body` with the input's base address and size and the output's free capacity's (at most `byteCount`
    /// bytes of it, when given), then appends the bytes `body` reports writing.
    ///
    /// Empty buffers get a placeholder address, which `body` must not access (their sizes are 0).
    ///
    /// - Precondition: `byteCount`, if given, is at most the output's free capacity.
    /// - Returns: What `body` returns besides the bytes it wrote.
    @inline(__always)
    static func with<R>(
        _ input: RawSpan, _ output: inout OutputRawSpan, byteCount: Int? = nil,
        _ body: (UnsafeRawPointer, Int, UnsafeMutableRawPointer, Int) throws(BytesError) -> (R, Int)
    ) throws(BytesError) -> R {
        try output.withFreeCapacity(byteCount: byteCount) { span, written throws(BytesError) -> R in
            try span.withUnsafeMutableBytes { outputBuffer throws(BytesError) -> R in
                try input.withUnsafeBytes { inputBuffer throws(BytesError) -> R in
                    // Unsafe: the buffers' base addresses, or a placeholder for an empty one, never accessed.
                    let (result, count) = try unsafe body(
                        inputBuffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, inputBuffer.count,
                        outputBuffer.baseAddress ?? UnsafeMutableRawPointer(bitPattern: 1)!, outputBuffer.count
                    )
                    written = count
                    return result
                }
            }
        }
    }
}

/// The match finders' hash, shared by the DEFLATE and Brotli encoders: libdeflate's, the top bits of a multiply.
enum LZHash {
    /// The top `bits` bits of `value` times 0x1E35A7BD.
    @inline(__always)
    static func hash(_ value: UInt32, bits: Int) -> Int {
        Int(truncatingIfNeeded: (value &* 0x1E35_A7BD) &>> UInt32(32 &- bits))
    }

    /// The 4 bytes at `offset`, little-endian, unchecked.
    @inline(__always)
    static func load32(_ buffer: RawSpan, _ offset: Int) -> UInt32 {
        // Unsafe: an unchecked load. Safe: every caller keeps 4 bytes at `offset` inside the buffer (each encoder's
        // file says how).
        UInt32(littleEndian: unsafe buffer.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt32.self))
    }
}

enum LZCopy {
    /// The most bytes ``wild(_:_:_:)`` and ``match(_:offset:count:)`` write (and read) past the bytes copied.
    static var overrun: Int { 16 }

    @inline(__always)
    static func copy16(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer) {
        // Unsafe: a 16-byte move. Safe: the callers keep both within their buffers.
        unsafe destination.storeBytes(of: source.loadUnaligned(as: SIMD16<UInt8>.self), as: SIMD16<UInt8>.self)
    }

    /// Copies `count` bytes 16 at a time: at least 16, and up to 15 past `count` (both reading and writing).
    /// The source must be in another buffer, or end at least 16 bytes before the destination starts.
    ///
    /// (32-byte steps changed instruction counts by 1.6% or less either way: LZ4 on x-ray −0.8%, LZFSE on
    /// samba +1.6%.)
    @inline(__always)
    static func wild(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer, _ count: Int) {
        // Unsafe: 16-byte moves. Safe: the callers leave `overrun` bytes of room past both.
        var index = 0
        repeat {
            unsafe copy16(destination + index, source + index)
            index &+= 16
        } while index < count
    }

    /// Copies a match of `count` bytes from `offset` (1 or more) back, forward, as LZ77 matches repeat: when
    /// the two overlap, bytes written earlier are read again. Writes up to ``overrun`` bytes past the match.
    @inline(__always)
    static func match(_ destination: UnsafeMutableRawPointer, offset: Int, count: Int) {
        // Unsafe: moves within the output. Safe: the callers checked that the match starts in the output
        // and left room past it; each 16-byte move at `offset >= 16` reads only bytes already written.
        if likely(offset >= 16) {
            unsafe wild(destination, UnsafeRawPointer(destination - offset), count)
        } else {
            unsafe ZstdCopy.overlapping(destination, offset: offset, count: count)
        }
    }

    /// Copies a match exactly, a byte at a time: near the end of the output, where there's no room for an
    /// overrun.
    @inline(never)
    static func exactMatch(_ destination: UnsafeMutableRawPointer, offset: Int, count: Int) {
        // Unsafe: byte moves within the output. Safe: the callers checked that the match starts in the output
        // and ends before its end.
        var index = 0
        while index < count {
            unsafe (destination + index).storeBytes(
                of: (destination + (index &- offset)).load(as: UInt8.self), as: UInt8.self
            )
            index &+= 1
        }
    }

    /// Copies `count` bytes from another buffer exactly.
    ///
    /// (Copies of up to 16 bytes inline, as two overlapping moves, changed no instruction count beyond noise on a
    /// 1.6 KB LZVN stream, where every literal near the end comes here.)
    @inline(__always)
    static func exact(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer, _ count: Int) {
        // Unsafe: a `memmove`. Safe: the callers checked that both ranges are within their buffers.
        unsafe destination.copyMemory(from: source, byteCount: count)
    }
}
