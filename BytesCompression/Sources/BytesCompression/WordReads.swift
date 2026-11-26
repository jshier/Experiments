internal import Bytes

// The encoders' and checksums' word reads from their input, in one place: the unchecked little-endian loads the LZ
// encoders' match finders make (DEFLATE, Brotli, LZFSE, LZVN), each caller's invariants keeping the word inside its
// buffer, and a word's value from the element views the checksums read whole words through (XXH64, CRC-64; the views
// themselves are Bytes' `RawSpan.chunks(of:)` since 2026-11-25). Every client compiles to the same instructions as
// before (RESULTS.md, 2026-11-24, E2). The unchecked loads stay here, not in Bytes: their safety rests on each
// encoder's invariants, and nothing outside the encoders needs them.
//
// (Brotli's encoder borrowed `DeflateCompressor.load64`, and each LZ encoder had its own copy of the 4-byte load:
// review 2026-11-23, §3.) Zstandard's match finder keeps its own `ZstdMatchInput.load32`/`load64`: the same loads
// through these moved one of its 16 specialized copies' register allocation (a 483rd instruction for 482).

/// Words from an encoder's or a checksum's input.
enum WordReads {
    // MARK: Unchecked, from a span

    /// The 4 bytes at `offset`, little-endian, unchecked.
    @inline(__always)
    static func load32(_ buffer: RawSpan, _ offset: Int) -> UInt32 {
        // Unsafe: an unchecked load. Safe: every caller keeps 4 bytes at `offset` inside the buffer (each encoder's
        // file says how).
        UInt32(littleEndian: unsafe buffer.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt32.self))
    }

    /// The 8 bytes at `offset`, little-endian, unchecked.
    @inline(__always)
    static func load64(_ buffer: RawSpan, _ offset: Int) -> UInt64 {
        // Unsafe: an unchecked load. Safe: every caller keeps 8 bytes at `offset` inside the buffer.
        UInt64(littleEndian: unsafe buffer.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt64.self))
    }

    /// The byte at `offset`, unchecked.
    @inline(__always)
    static func byte(_ buffer: RawSpan, _ offset: Int) -> UInt8 {
        // Unsafe: an unchecked load. Safe: every caller reads within the buffer.
        unsafe buffer.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: UInt8.self)
    }

    // MARK: Unchecked, from a pointer (the encoders whose loops run on their input's address)

    /// The 4 bytes at `offset` from `base`, little-endian.
    @unsafe @inline(__always)
    static func load32(_ base: UnsafeRawPointer, _ offset: Int) -> UInt32 {
        // Unsafe: an unchecked load; the caller keeps 4 bytes at `offset` within its buffer.
        UInt32(littleEndian: unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    /// The 8 bytes at `offset` from `base`, little-endian.
    @unsafe @inline(__always)
    static func load64(_ base: UnsafeRawPointer, _ offset: Int) -> UInt64 {
        // Unsafe: an unchecked load; the caller keeps 8 bytes at `offset` within its buffer.
        UInt64(littleEndian: unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    // MARK: Checked, as elements

    /// A word's value, little-endian: an element of `bytes.chunks(of: InlineArray<8, UInt8>.self)`, read by `bitCast`
    /// (no checks within an element, and no stack copy: reading one through its `span` put a stack protector in the
    /// function, 4 instructions a call).
    @inline(__always)
    static func value(_ word: InlineArray<8, UInt8>) -> UInt64 {
        UInt64(littleEndian: bitCast(word, to: UInt64.self))
    }
}
