import Builtin

// Thin wrappers over compiler builtins, for hints the standard library doesn't expose publicly.
// Each one is checked against the generated assembly and the benchmarks; see Benchmarks/RESULTS.md.

/// Tells the optimizer `condition` is almost always true (branch weight), keeping the slow path out of line.
@usableFromInline @_transparent
func likely(_ condition: Bool) -> Bool {
    Bool(Builtin.int_expect_Int1(condition._value, true._value))
}

/// Tells the optimizer `condition` is almost always false.
@usableFromInline @_transparent
func unlikely(_ condition: Bool) -> Bool {
    Bool(Builtin.int_expect_Int1(condition._value, false._value))
}

/// Tells the optimizer `condition` holds, so it can drop checks and masks that would only matter otherwise.
/// Unchecked: if `condition` is false, behavior is undefined. Use only for invariants the type maintains.
@unsafe @usableFromInline @_transparent
func assume(_ condition: Bool) {
    _ = Builtin.assume_Int1(condition._value)
}

// MARK: - Bit reversal

// Reversing bits is common in decoders: DEFLATE stores Huffman codes most significant bit first in a stream
// read least significant bit first, and reflected CRCs process bits in the other order. The standard
// library has no operation for it; LLVM's `bitreverse` is one instruction (`rbit`) on ARM.

public extension UInt8 {
    /// The bits in reverse order: bit 0 becomes bit 7.
    @inlinable @_transparent
    var bitReversed: UInt8 { UInt8(Builtin.int_bitreverse_Int8(_value)) }
}

public extension UInt16 {
    /// The bits in reverse order: bit 0 becomes bit 15.
    @inlinable @_transparent
    var bitReversed: UInt16 { UInt16(Builtin.int_bitreverse_Int16(_value)) }
}

public extension UInt32 {
    /// The bits in reverse order: bit 0 becomes bit 31.
    @inlinable @_transparent
    var bitReversed: UInt32 { UInt32(Builtin.int_bitreverse_Int32(_value)) }
}

public extension UInt64 {
    /// The bits in reverse order: bit 0 becomes bit 63.
    @inlinable @_transparent
    var bitReversed: UInt64 { UInt64(Builtin.int_bitreverse_Int64(_value)) }
}

public extension Bits {
    /// The `width` bits in reverse order: bit 0 becomes bit `width - 1`.
    @inlinable
    var bitReversed: Self { Self(_unchecked: rawValue.bitReversed &>> UInt8(8 &- width)) }
}
