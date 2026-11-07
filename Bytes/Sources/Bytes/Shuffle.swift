#if NEONShuffle
import CBytesNEON

/// Packing and unpacking runs of 3-, 5-, 6-, and 7-byte groups with NEON table lookups (`tbl`, through the
/// CBytesNEON C module, enabled by the `NEONShuffle` package trait).
///
/// Values travel in lanes: 32-bit lanes for 3-byte groups (16 values per step) and 64-bit lanes for 5 to 7
/// bytes (8 per step), so one step is always 64 bytes of lanes, exactly one 4-register `tbl` table. Packing
/// turns those 64 bytes into the step's 48, 40, 48, or 56 packed bytes with up to four lookups; unpacking
/// does the reverse. The index vectors also apply the byte order, so big-endian costs nothing extra.
/// Without this, these widths can't use contiguous vector loads or stores, and are compute-bound.
@usableFromInline
enum Shuffle {
    /// Whether runs of `T` are shuffled: 3, 5, 6, and 7 bytes. (Power-of-two widths vectorize without
    /// help, and 9 to 15 bytes would need lookups across more than 64 bytes.) Lanes are stored straight
    /// into `T.Integer`s, so a conformance whose `Integer` isn't the lane size is excluded. Both checks fold
    /// to a constant.
    @inlinable @inline(__always)
    static func handles<T: ByteGroup>(_: T.Type) -> Bool {
        switch T.byteCount {
        case 3, 5, 6, 7: MemoryLayout<T.Integer>.size == laneSize(T.byteCount)
        default: false
        }
    }

    /// Whether `forEach` over `T` unpacks with lookups: 5, 6, and 7 bytes. Not 3: there the plain loop
    /// already vectorizes (NEON `ld3`) together with the caller's body, while unpacking first and then
    /// calling the body once per lane keeps the body scalar (measured 5x slower). For 5 to 7 bytes, whose
    /// plain loop barely vectorizes, unpacking halves the instructions.
    @inlinable @inline(__always)
    static func handlesIteration<T: ByteGroup>(_: T.Type) -> Bool {
        switch T.byteCount {
        case 5, 6, 7: MemoryLayout<T.Integer>.size == laneSize(T.byteCount)
        default: false
        }
    }

    /// The size of the lane holding one value: 4 bytes for 3-byte groups, 8 otherwise.
    @inlinable @inline(__always)
    static func laneSize(_ byteCount: Int) -> Int { byteCount == 3 ? 4 : 8 }

    /// Values per step: 64 bytes of lanes.
    @inlinable @inline(__always)
    static func valuesPerStep(_ byteCount: Int) -> Int { 64 / laneSize(byteCount) }

    /// Packed bytes per step.
    @inlinable @inline(__always)
    static func bytesPerStep(_ byteCount: Int) -> Int { valuesPerStep(byteCount) &* byteCount }

    /// Index vector `part` (0 through 3) for packing: output byte `16 * part + i` takes byte
    /// `index[i]` of the 64 bytes of lanes. Constant-folded when its arguments are constants.
    @inlinable @inline(__always)
    static func packIndex(byteCount: Int, bigEndian: Bool, part: Int) -> SIMD16<UInt8> {
        let lane = laneSize(byteCount)
        let total = bytesPerStep(byteCount)
        var index = SIMD16<UInt8>(repeating: 0xFF)
        for slot in 0..<16 {
            let position = 16 &* part &+ slot
            guard position < total else { continue }
            let value = position / byteCount
            let byte = position % byteCount
            index[slot] = UInt8(truncatingIfNeeded: lane &* value &+ (bigEndian ? byteCount &- 1 &- byte : byte))
        }
        return index
    }

    /// Index vector `part` (0 through 3) for unpacking: lane byte `16 * part + i` takes byte `index[i]` of
    /// the step's packed bytes, or zero above the value's width.
    @inlinable @inline(__always)
    static func unpackIndex(byteCount: Int, bigEndian: Bool, part: Int) -> SIMD16<UInt8> {
        let lane = laneSize(byteCount)
        var index = SIMD16<UInt8>(repeating: 0xFF)
        for slot in 0..<16 {
            let position = 16 &* part &+ slot
            let value = position / lane
            let byte = position % lane
            guard byte < byteCount else { continue }
            index[slot] = UInt8(truncatingIfNeeded: byteCount &* value &+ (bigEndian ? byteCount &- 1 &- byte : byte))
        }
        return index
    }

    @inlinable @inline(__always)
    static func table(_ lanes: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>), _ index: SIMD16<UInt8>) -> SIMD16<UInt8> {
        bytes_table4(lanes.0, lanes.1, lanes.2, lanes.3, index)
    }

    // MARK: Packing (writing)

    /// Writes whole steps of `count` values from `value`, packed as `T` in `bigEndian` or little-endian
    /// order, starting at `start`, and returns how many values it wrote (a multiple of the step). Capacity
    /// already checked for all `count` values.
    @unsafe @inlinable @inline(__always)
    static func pack<T: ByteGroup>(
        _: T.Type, bigEndian: Bool, count: Int, to bytes: inout MutableRawSpan, at start: Int, _ value: (Int) -> T.Integer
    ) -> Int {
        let byteCount = T.byteCount
        let perStep = valuesPerStep(byteCount)
        let stepBytes = bytesPerStep(byteCount)
        let steps = count / perStep
        let indices = (
            packIndex(byteCount: byteCount, bigEndian: bigEndian, part: 0),
            packIndex(byteCount: byteCount, bigEndian: bigEndian, part: 1),
            packIndex(byteCount: byteCount, bigEndian: bigEndian, part: 2),
            packIndex(byteCount: byteCount, bigEndian: bigEndian, part: 3)
        )
        for step in 0..<steps {
            let first = step &* perStep
            let lanes = self.lanes(T.self, first, value)
            let offset = start &+ step &* stepBytes
            // 48 bytes: three vectors. 40 and 56 bytes: two or three vectors, then 8 bytes.
            unsafe bytes.storeBytes(of: table(lanes, indices.0), toUncheckedByteOffset: offset, as: SIMD16<UInt8>.self)
            unsafe bytes.storeBytes(of: table(lanes, indices.1), toUncheckedByteOffset: offset &+ 16, as: SIMD16<UInt8>.self)
            if stepBytes >= 48 {
                unsafe bytes.storeBytes(of: table(lanes, indices.2), toUncheckedByteOffset: offset &+ 32, as: SIMD16<UInt8>.self)
            }
            if stepBytes % 16 == 8 {
                let last = table(lanes, stepBytes >= 48 ? indices.3 : indices.2)
                let low = unsafe unsafeBitCast(last, to: SIMD2<UInt64>.self)[0]
                unsafe bytes.storeBytes(of: low, toUncheckedByteOffset: offset &+ stepBytes &- 8, as: UInt64.self)
            }
        }
        return steps &* perStep
    }

    /// One step's values from `value`, starting at index `first`, as 64 bytes of lanes.
    @inlinable @inline(__always)
    static func lanes<T: ByteGroup>(
        _: T.Type, _ first: Int, _ value: (Int) -> T.Integer
    ) -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>) {
        if laneSize(T.byteCount) == 4 {
            func vector(_ base: Int) -> SIMD16<UInt8> {
                let lanes = SIMD4<UInt32>(
                    UInt32(truncatingIfNeeded: value(base)), UInt32(truncatingIfNeeded: value(base &+ 1)),
                    UInt32(truncatingIfNeeded: value(base &+ 2)), UInt32(truncatingIfNeeded: value(base &+ 3))
                )
                return unsafe unsafeBitCast(lanes, to: SIMD16<UInt8>.self)
            }
            return (vector(first), vector(first &+ 4), vector(first &+ 8), vector(first &+ 12))
        }
        func vector(_ base: Int) -> SIMD16<UInt8> {
            let lanes = SIMD2<UInt64>(UInt64(truncatingIfNeeded: value(base)), UInt64(truncatingIfNeeded: value(base &+ 1)))
            return unsafe unsafeBitCast(lanes, to: SIMD16<UInt8>.self)
        }
        return (vector(first), vector(first &+ 2), vector(first &+ 4), vector(first &+ 6))
    }

    // MARK: Unpacking (reading)

    /// How many whole steps of `T` can be unpacked from `availableBytes` bytes for up to `count` values:
    /// each step loads 64 bytes from its start (more than it uses), so it needs that many to be readable.
    @inlinable @inline(__always)
    static func unpackableSteps<T: ByteGroup>(_: T.Type, count: Int, availableBytes: Int) -> Int {
        let stepBytes = bytesPerStep(T.byteCount)
        guard availableBytes >= 64 else { return 0 }
        return Swift.min(count / valuesPerStep(T.byteCount), (availableBytes &- 64) / stepBytes &+ 1)
    }

    /// The unpacking index vectors for `T` in an order.
    @inlinable @inline(__always)
    static func unpackIndices<T: ByteGroup>(
        _: T.Type, bigEndian: Bool
    ) -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>) {
        (
            unpackIndex(byteCount: T.byteCount, bigEndian: bigEndian, part: 0),
            unpackIndex(byteCount: T.byteCount, bigEndian: bigEndian, part: 1),
            unpackIndex(byteCount: T.byteCount, bigEndian: bigEndian, part: 2),
            unpackIndex(byteCount: T.byteCount, bigEndian: bigEndian, part: 3)
        )
    }

    /// Step `step`'s values from packed bytes at `start`, as 64 bytes of lanes. The caller ensures the
    /// step's 64-byte load is in bounds (see ``unpackableSteps(_:count:availableBytes:)``).
    @unsafe @inlinable @inline(__always)
    static func unpack<T: ByteGroup>(
        _: T.Type, step: Int, from span: RawSpan, at start: Int,
        _ indices: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)
    ) -> (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>) {
        let offset = start &+ step &* bytesPerStep(T.byteCount)
        let packed = unsafe (
            span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD16<UInt8>.self),
            span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 16, as: SIMD16<UInt8>.self),
            span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 32, as: SIMD16<UInt8>.self),
            span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset &+ 48, as: SIMD16<UInt8>.self)
        )
        return (table(packed, indices.0), table(packed, indices.1), table(packed, indices.2), table(packed, indices.3))
    }

    /// Value `index` (0 through 15, or 7) of unpacked lanes, as `T.Integer`.
    @inlinable @inline(__always)
    static func lane<T: ByteGroup>(
        _: T.Type, _ lanes: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>), _ index: Int
    ) -> T.Integer {
        let perVector = 16 / laneSize(T.byteCount)
        let vector = switch index / perVector {
        case 0: lanes.0
        case 1: lanes.1
        case 2: lanes.2
        default: lanes.3
        }
        if laneSize(T.byteCount) == 4 {
            return T.Integer(truncatingIfNeeded: unsafe unsafeBitCast(vector, to: SIMD4<UInt32>.self)[index % perVector])
        }
        return T.Integer(truncatingIfNeeded: unsafe unsafeBitCast(vector, to: SIMD2<UInt64>.self)[index % perVector])
    }
}
#endif
