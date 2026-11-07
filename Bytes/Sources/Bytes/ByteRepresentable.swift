/// A type stored as a fixed run of raw bytes, such as an address or a digest, which ``Bytes`` reads with a
/// single load.
///
/// Conform by exposing the bytes, typically as an `InlineArray<N, UInt8>` that's the type's only stored
/// property:
///
/// ```swift
/// struct IPv4Address: ByteRepresentable {
///     var rawBytes: InlineArray<4, UInt8>
///     init(rawBytes: InlineArray<4, UInt8>) { self.rawBytes = rawBytes }
/// }
///
/// let address = try reader.read(IPv4Address.self)
/// ```
///
/// Reading one is a bounds check, an unaligned load of `RawBytes` from the input, and `init(rawBytes:)`.
/// When that initializer only stores its argument, it compiles away and the type parses exactly as fast as
/// its raw bytes (one 4-byte load for the example above), including in vectorized loops.
///
/// `RawBytes` must be `ConvertibleFromBytes` (any bit pattern is a valid value, as for `InlineArray` of
/// bytes or integers), so loading it from arbitrary input is safe. `Self` itself can't be: in Swift 6.4
/// only standard library types may conform to `ConvertibleFromBytes`, which is why this protocol exists.
/// Byte order is the type's business: the bytes arrive in memory order.
public protocol ByteRepresentable {
    /// The type's bytes in memory order: usually `InlineArray<N, UInt8>`.
    associatedtype RawBytes: ConvertibleFromBytes

    /// Creates a value from its bytes. To parse at raw speed, only store them; validate elsewhere.
    init(rawBytes: RawBytes)

    /// The value's bytes, in memory order.
    var rawBytes: RawBytes { get }
}

extension Load {
    /// The `R` at `offset`. Sizes that match an integer are loaded as that integer and reinterpreted with
    /// the standard library's `bitCast`: loading an `InlineArray<4, UInt8>` directly compiles to four
    /// byte loads and repacking, but as a `UInt32` it's one `ldr`.
    ///
    /// Sizes 9–15 are built from two overlapping 64-bit loads into a `UInt128`, like
    /// ``group(_:from:at:)``, and `R` is taken from its low bytes (memory order on a little-endian host):
    /// measured 2.6x faster in loops than loading them as a byte aggregate (62 against 24 GB/s for 12 bytes).
    /// Sizes 3 and 5–7 load directly: the same trick through a 32- or 64-bit integer measured slower there
    /// (14 against 31 GB/s for 6 bytes), because the reinterpretation goes through a stack slot the
    /// optimizer doesn't remove; the direct load already matches the raw-bytes speed.
    @inlinable @inline(__always)
    static func rawBytes<R: ConvertibleFromBytes>(_: R.Type, from span: RawSpan, at offset: Int) -> R {
        let size = MemoryLayout<R>.size
        switch size {
        case 1: return unsafe bitCast(native(UInt8.self, from: span, at: offset), to: R.self)
        case 2: return unsafe bitCast(native(UInt16.self, from: span, at: offset), to: R.self)
        case 4: return unsafe bitCast(native(UInt32.self, from: span, at: offset), to: R.self)
        case 8: return unsafe bitCast(native(UInt64.self, from: span, at: offset), to: R.self)
        case 16:
            return unsafe bitCast(native(UInt128.self, from: span, at: offset), to: R.self)
        #if _endian(little) // `lowBytes` takes the first bytes in memory: the low half only on little-endian.
        case 9...15:
            let low = unsafe little(UInt64.self, from: span, at: offset)
            let high = unsafe little(UInt64.self, from: span, at: offset &+ size &- 8) &>> (8 &* (16 &- size))
            return unsafe lowBytes(UInt128(high) &<< 64 | UInt128(low), as: R.self)
        #endif
        default:
            return unsafe span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: R.self)
        }
    }

    /// `R` from the first `MemoryLayout<R>.size` (at most 16) bytes of `wide`'s memory.
    ///
    /// Unsafe: an unchecked load from `wide`'s bytes. Safe: `R` is at most 16 bytes (callers' sizes are
    /// 9–15) and every bit pattern is a valid `R` (`ConvertibleFromBytes`). The safe form, a checked load
    /// from an `InlineArray<1, UInt128>`'s span, measured 46% more instructions reading 12-byte values:
    /// the array goes through a stack slot the optimizer doesn't remove.
    @inlinable @inline(__always)
    static func lowBytes<R: ConvertibleFromBytes>(_ wide: UInt128, as _: R.Type) -> R {
        withUnsafeBytes(of: wide) { unsafe $0.loadUnaligned(as: R.self) }
    }
}

extension Bytes {
    /// Returns the next `T`, from its `MemoryLayout<T.RawBytes>.size` bytes, without consuming them.
    @inlinable @inline(__always)
    public func peek<T: ByteRepresentable>(_: T.Type = T.self) throws(BytesError) -> T {
        _assumeInvariant()
        let size = MemoryLayout<T.RawBytes>.size
        precondition(size > 0, "\(T.self).RawBytes has no bytes") // Constant-folded.
        if likely(_bitOffset == 0) {
            guard likely(span.byteCount &- _byteOffset >= size) else { throw .insufficientData }
            return T(rawBytes: unsafe Load.rawBytes(T.RawBytes.self, from: span, at: _byteOffset))
        }
        guard remainingByteCount >= size else { throw .insufficientData }
        return T(rawBytes: Self._unalignedRawBytes(T.RawBytes.self, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder))
    }

    /// Reads the next `T`, from its `MemoryLayout<T.RawBytes>.size` bytes.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func read<T: ByteRepresentable>(_: T.Type = T.self) throws(BytesError) -> T {
        let value = try peek(T.self)
        _byteOffset &+= MemoryLayout<T.RawBytes>.size // Whole bytes leave the bit offset unchanged.
        return value
    }

    /// Reads every remaining whole `T`, in order, calling `body` with each. Like
    /// ``forEach(_:_:)-(T.Type,_)`` for byte groups: one bounds check, then a counted loop of unaligned
    /// loads the compiler vectorizes together with `body`. Consumes what it reads.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func forEach<T: ByteRepresentable, E: Error>(_: T.Type, _ body: (T) throws(E) -> Void) throws(E) {
        _assumeInvariant()
        let size = MemoryLayout<T.RawBytes>.size
        precondition(size > 0, "\(T.self).RawBytes has no bytes") // Constant-folded.
        let count = remainingByteCount / size
        guard likely(_bitOffset == 0) else {
            for _ in 0..<count {
                let bytes = Self._unalignedRawBytes(T.RawBytes.self, in: span, atByte: _byteOffset, bit: _bitOffset, bitOrder: bitOrder)
                _byteOffset &+= size
                try body(T(rawBytes: bytes))
            }
            return
        }
        let span = span
        let start = _byteOffset
        var index = 0
        do throws(E) {
            while index < count {
                try body(T(rawBytes: unsafe Load.rawBytes(T.RawBytes.self, from: span, at: start &+ index &* size)))
                index &+= 1
            }
        } catch {
            _byteOffset = start &+ (index &+ 1) &* size
            throw error
        }
        _byteOffset = start &+ count &* size
    }

    /// Reads consecutive `T`s until `output` is full: one bounds check, then a counted loop of loads and
    /// stores that vectorizes.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    public mutating func read<T: ByteRepresentable>(_: T.Type, into output: inout OutputSpan<T>) throws(BytesError) {
        _assumeInvariant()
        let size = MemoryLayout<T.RawBytes>.size
        precondition(size > 0, "\(T.self).RawBytes has no bytes") // Constant-folded.
        let count = output.freeCapacity
        guard likely(remainingByteCount / size >= count) else { throw .insufficientData }
        // An empty output may have no memory behind it: nothing to read, nothing to unwrap.
        guard count > 0 else { return }
        guard likely(_bitOffset == 0) else {
            for _ in 0..<count {
                output.append(try read(T.self))
            }
            return
        }
        let span = span
        let start = _byteOffset
        // Unsafe and safe as in `read(_:_:into:)` for byte groups: exactly `count` values initialized and
        // counted, through a pointer so the loop vectorizes.
        unsafe output.withUnsafeMutableBufferPointer { buffer, initializedCount in
            let destination = unsafe buffer.baseAddress! + initializedCount
            for index in 0..<count {
                let value = T(rawBytes: unsafe Load.rawBytes(T.RawBytes.self, from: span, at: start &+ index &* size))
                unsafe (destination + index).initialize(to: value)
            }
            initializedCount &+= count
        }
        _byteOffset &+= count &* size
    }

    /// `R`'s bytes when not byte-aligned, each made of the next 8 bits. Bounds already checked.
    /// Never inlined, so its stack buffer (and the stack-protector check that comes with it) stays out of
    /// the callers' fast paths.
    @inlinable @inline(never)
    static func _unalignedRawBytes<R: ConvertibleFromBytes>(
        _: R.Type, in span: RawSpan, atByte byteOffset: Int, bit: Int, bitOrder: BitOrder
    ) -> R {
        // Unsafe: assembles `R` in uninitialized stack memory. Safe: every one of its bytes is written before
        // the load, and every bit pattern is a valid `R`. `R` is generic and only `ConvertibleFromBytes`,
        // so there's no safe storage to assemble it in (that needs `ConvertibleToBytes` too).
        withUnsafeTemporaryAllocation(of: R.self, capacity: 1) { buffer in
            let bytes = UnsafeMutableRawBufferPointer(buffer)
            for index in 0..<MemoryLayout<R>.size {
                unsafe bytes[index] = _bits(8, in: span, atByte: byteOffset &+ index, bit: bit, bitOrder: bitOrder)
            }
            return unsafe bytes.load(as: R.self)
        }
    }
}
