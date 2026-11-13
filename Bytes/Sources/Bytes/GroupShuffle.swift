/// Packing and unpacking runs of 3-, 5-, 6-, and 7-byte groups one 16-byte vector at a time, with byte
/// shuffles whose indices are constants, in portable Swift.
///
/// A vector holds whole values in lanes: four 32-bit lanes for 3-byte groups, two 64-bit lanes for 5 to 7
/// bytes. Unpacking loads the 12, 10, 12, or 14 bytes those values take (as a 16-byte load) and moves each
/// byte to its lane; packing does the reverse and stores 16 bytes, the next store overwriting the extra.
/// Each output byte is `input[k]` for a constant `k` (or zero), which LLVM turns into one shuffle: a
/// single-register `tbl` on ARM64, `pshufb` on x86 with SSSE3. The byte order is part of the constants, so
/// big-endian costs nothing extra.
///
/// Without it, these widths take two overlapping loads or stores and shifts per value.
@usableFromInline
enum GroupShuffle {
    /// Whether these shuffles are used rather than `Shuffle`'s 64-byte table lookups: where lookups aren't
    /// single instructions. A constant.
    @inlinable @inline(__always)
    static var isPreferred: Bool { !ByteLanes.isLookupVectorized }

    /// Whether iteration uses these shuffles rather than `Shuffle`'s. Iterators (`staged` false: their body
    /// only stores each value) use them everywhere: 22–32% faster than the table lookups with NEON too, a
    /// vector of two values at a time against a step of eight. `forEach` (`staged`) only where
    /// ``isPreferred``: with NEON, the lookups were up to 12% faster and took 40% fewer instructions. A
    /// constant wherever `staged` is.
    ///
    /// - Parameter staged: Whether values go through a buffer before the caller's body sees them.
    /// - Returns: `true` if iteration uses these shuffles.
    @inlinable @inline(__always)
    static func isPreferredForIteration(staged: Bool) -> Bool { staged ? isPreferred : true }

    /// Whether runs of `T` are shuffled: 3, 5, 6, and 7 bytes, on little-endian hosts (lanes are stored
    /// straight into `T.Integer`s, so the lane's memory order must be the integer's), and only when
    /// `T.Integer` is exactly the lane. Folds to a constant.
    ///
    /// - Parameter type: The group type.
    /// - Returns: `true` if runs of `type` are packed and unpacked with shuffles.
    @inlinable @inline(__always)
    static func handles<T: ByteGroup>(_: T.Type) -> Bool {
        #if _endian(little)
        switch T.byteCount {
        case 3, 5, 6, 7: MemoryLayout<T.Integer>.size == laneSize(T.byteCount)
        default: false
        }
        #else
        false
        #endif
    }

    /// Whether `forEach` over `T` unpacks with shuffles: 5, 6, and 7 bytes. Not 3: there the plain loop of
    /// byte loads vectorizes together with the caller's body (NEON `ld3`), while unpacking first and then
    /// calling the body once per lane keeps the body scalar.
    ///
    /// - Parameter type: The group type.
    /// - Returns: `true` if `forEach` over `type` unpacks with shuffles.
    @inlinable @inline(__always)
    static func handlesIteration<T: ByteGroup>(_: T.Type) -> Bool {
        T.byteCount != 3 && handles(T.self)
    }

    /// The size of the lane holding one value: 4 bytes for 3-byte groups, 8 otherwise.
    ///
    /// - Parameter byteCount: The group's width in bytes.
    /// - Returns: The lane size in bytes.
    @inlinable @inline(__always)
    static func laneSize(_ byteCount: Int) -> Int { byteCount == 3 ? 4 : 8 }

    /// The values in one vector of lanes.
    ///
    /// - Parameter byteCount: The group's width in bytes.
    /// - Returns: 4 for 3-byte groups, 2 otherwise.
    @inlinable @inline(__always)
    static func valuesPerVector(_ byteCount: Int) -> Int { 16 / laneSize(byteCount) }

    /// The packed bytes of one vector's values.
    ///
    /// - Parameter byteCount: The group's width in bytes.
    /// - Returns: 12, 10, 12, or 14.
    @inlinable @inline(__always)
    static func packedBytes(_ byteCount: Int) -> Int { valuesPerVector(byteCount) &* byteCount }

    /// The vectors staged through a stack buffer at a time, by ``pack(_:bigEndian:count:to:at:_:)`` and
    /// `forEach`: 512 bytes of lanes.
    @inlinable @inline(__always)
    static var chunkVectors: Int { 32 }

    /// Whether a run of `count` values is worth staging: at least a full chunk (128 values of 3 bytes, 64
    /// of 5 to 7). Shorter runs keep the plain loops: runs of 1 to 62 3-byte values took 37% more
    /// instructions staged.
    ///
    /// - Parameters:
    ///   - type: The group type.
    ///   - count: The number of values in the run.
    /// - Returns: `true` if the run fills at least one chunk.
    @inlinable @inline(__always)
    static func stages<T: ByteGroup>(_: T.Type, count: Int) -> Bool {
        count >= chunkVectors &* valuesPerVector(T.byteCount)
    }

    // MARK: Shuffles

    /// Lane byte `slot` of an unpacked vector: the packed byte it comes from, or 0 above the value's width.
    ///
    /// - Parameters:
    ///   - packed: The packed bytes.
    ///   - byteCount: The group's width in bytes.
    ///   - bigEndian: Whether each value's bytes are stored most significant first.
    ///   - slot: The lane byte, 0 through 15.
    /// - Returns: The byte.
    @inlinable @inline(__always)
    static func unpacked(_ packed: SIMD16<UInt8>, byteCount: Int, bigEndian: Bool, _ slot: Int) -> UInt8 {
        let lane = laneSize(byteCount)
        let byte = slot % lane
        guard byte < byteCount else { return 0 }
        return packed[byteCount &* (slot / lane) &+ (bigEndian ? byteCount &- 1 &- byte : byte)]
    }

    /// Moves a vector's worth of packed values into lanes.
    ///
    /// - Parameters:
    ///   - packed: The packed values, from the first byte; bytes past ``packedBytes(_:)`` are ignored.
    ///   - byteCount: The group's width in bytes.
    ///   - bigEndian: Whether each value's bytes are stored most significant first.
    /// - Returns: The values in little-endian lanes, zero-extended.
    @inlinable @inline(__always)
    static func unpack(_ packed: SIMD16<UInt8>, byteCount: Int, bigEndian: Bool) -> SIMD16<UInt8> {
        SIMD16(
            unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 0), unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 1),
            unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 2), unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 3),
            unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 4), unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 5),
            unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 6), unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 7),
            unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 8), unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 9),
            unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 10), unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 11),
            unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 12), unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 13),
            unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 14), unpacked(packed, byteCount: byteCount, bigEndian: bigEndian, 15)
        )
    }

    /// Packed byte `slot` of a vector of lanes: the lane byte it comes from, or 0 past the packed bytes.
    ///
    /// - Parameters:
    ///   - lanes: The values in little-endian lanes.
    ///   - byteCount: The group's width in bytes.
    ///   - bigEndian: Whether to store each value's bytes most significant first.
    ///   - slot: The packed byte, 0 through 15.
    /// - Returns: The byte.
    @inlinable @inline(__always)
    static func packed(_ lanes: SIMD16<UInt8>, byteCount: Int, bigEndian: Bool, _ slot: Int) -> UInt8 {
        guard slot < packedBytes(byteCount) else { return 0 }
        let byte = slot % byteCount
        return lanes[laneSize(byteCount) &* (slot / byteCount) &+ (bigEndian ? byteCount &- 1 &- byte : byte)]
    }

    /// Packs a vector of lanes into consecutive values.
    ///
    /// - Parameters:
    ///   - lanes: The values in little-endian lanes; bytes above each value's width are ignored.
    ///   - byteCount: The group's width in bytes.
    ///   - bigEndian: Whether to store each value's bytes most significant first.
    /// - Returns: The packed values in the first ``packedBytes(_:)`` bytes, then zeros.
    @inlinable @inline(__always)
    static func pack(_ lanes: SIMD16<UInt8>, byteCount: Int, bigEndian: Bool) -> SIMD16<UInt8> {
        SIMD16(
            packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 0), packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 1),
            packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 2), packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 3),
            packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 4), packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 5),
            packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 6), packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 7),
            packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 8), packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 9),
            packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 10), packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 11),
            packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 12), packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 13),
            packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 14), packed(lanes, byteCount: byteCount, bigEndian: bigEndian, 15)
        )
    }

    // MARK: Runs

    /// How many vectors of `T` can be unpacked: each loads 16 bytes from its start, more than its values
    /// take, so those must be readable.
    ///
    /// - Parameters:
    ///   - type: The group type.
    ///   - count: The number of values wanted.
    ///   - availableBytes: The bytes readable from the first value.
    /// - Returns: The vectors, at most `count` values' worth.
    @inlinable @inline(__always)
    static func unpackableVectors<T: ByteGroup>(_: T.Type, count: Int, availableBytes: Int) -> Int {
        guard availableBytes >= 16 else { return 0 }
        return Swift.min(count / valuesPerVector(T.byteCount), (availableBytes &- 16) / packedBytes(T.byteCount) &+ 1)
    }

    /// Loads and unpacks vector `index` of a run. The caller ensures its 16-byte load is in bounds (see
    /// ``unpackableVectors(_:count:availableBytes:)``). Unsafe: an unchecked load, like ``Load`` and for the
    /// same reason.
    ///
    /// - Parameters:
    ///   - type: The group type.
    ///   - bigEndian: Whether each value's bytes are stored most significant first.
    ///   - index: The vector's number in the run.
    ///   - span: The bytes holding the run.
    ///   - start: The byte offset of the run's first value.
    /// - Returns: The vector's values in little-endian lanes.
    @unsafe @inlinable @inline(__always)
    static func unpack<T: ByteGroup>(
        _: T.Type, bigEndian: Bool, vector index: Int, from span: RawSpan, at start: Int
    ) -> SIMD16<UInt8> {
        let offset = start &+ index &* packedBytes(T.byteCount)
        let packed = unsafe span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD16<UInt8>.self)
        return unpack(packed, byteCount: T.byteCount, bigEndian: bigEndian)
    }

    /// Unpacks the run's leading whole vectors straight into `destination`'s lanes. Unsafe: unchecked
    /// loads, and stores through a pointer.
    ///
    /// - Parameters:
    ///   - type: The group type.
    ///   - bigEndian: Whether each value's bytes are stored most significant first.
    ///   - count: The number of values wanted.
    ///   - span: The bytes holding the run.
    ///   - start: The byte offset of the run's first value.
    ///   - destination: Room for `count` `T.Integer`s.
    /// - Returns: How many values it unpacked: a multiple of ``valuesPerVector(_:)``, at most `count`.
    @unsafe @inlinable @inline(__always)
    static func unpack<T: ByteGroup>(
        _: T.Type, bigEndian: Bool, count: Int, from span: RawSpan, at start: Int, to destination: UnsafeMutableRawPointer
    ) -> Int {
        let vectors = unpackableVectors(T.self, count: count, availableBytes: span.byteCount &- start)
        // Four vectors per iteration, then the rest one at a time.
        var index = 0
        while index &+ 4 <= vectors {
            for offset in 0..<4 {
                let lanes = unsafe unpack(T.self, bigEndian: bigEndian, vector: index &+ offset, from: span, at: start)
                unsafe destination.storeBytes(of: lanes, toByteOffset: (index &+ offset) &* 16, as: SIMD16<UInt8>.self)
            }
            index &+= 4
        }
        while index < vectors {
            let lanes = unsafe unpack(T.self, bigEndian: bigEndian, vector: index, from: span, at: start)
            unsafe destination.storeBytes(of: lanes, toByteOffset: index &* 16, as: SIMD16<UInt8>.self)
            index &+= 1
        }
        return vectors &* valuesPerVector(T.byteCount)
    }

    /// Value `slot` of a vector of lanes.
    ///
    /// - Parameters:
    ///   - type: The group type.
    ///   - lanes: The vector, from ``unpack(_:bigEndian:vector:from:at:)``.
    ///   - slot: The value's index in the vector: 0 through 3 for 3-byte groups, 0 or 1 otherwise.
    /// - Returns: The value as `T.Integer`.
    @inlinable @inline(__always)
    static func lane<T: ByteGroup>(_: T.Type, _ lanes: SIMD16<UInt8>, _ slot: Int) -> T.Integer {
        if laneSize(T.byteCount) == 4 {
            return T.Integer(truncatingIfNeeded: bitCast(lanes, to: SIMD4<UInt32>.self)[slot])
        }
        return T.Integer(truncatingIfNeeded: bitCast(lanes, to: SIMD2<UInt64>.self)[slot])
    }

    /// Writes a run's leading values, packed as `T`, a vector at a time, for as long as each 16-byte store
    /// stays within the run's `count * T.byteCount` bytes, which the caller has checked are writable; none
    /// when the run is too short to stage (see ``stages(_:count:)``). Unsafe: unchecked stores, like
    /// ``Store`` and for the same reason.
    ///
    /// - Parameters:
    ///   - type: The group type.
    ///   - bigEndian: Whether to store each value's bytes most significant first.
    ///   - count: The number of values in the run.
    ///   - bytes: The span to write to.
    ///   - start: The byte offset of the run's first value.
    ///   - value: The value at an index below `count`.
    /// - Returns: How many values it wrote: a multiple of ``valuesPerVector(_:)``, at most `count`.
    @unsafe @inlinable @inline(__always)
    static func pack<T: ByteGroup>(
        _: T.Type, bigEndian: Bool, count: Int, to bytes: inout MutableRawSpan, at start: Int, _ value: (Int) -> T.Integer
    ) -> Int {
        let total = count &* T.byteCount
        guard stages(T.self, count: count) else { return 0 }
        let stride = packedBytes(T.byteCount)
        // The last store starts at most 16 bytes before the run's end; its values are all in the run.
        let vectors = (total &- 16) / stride &+ 1
        let perVector = valuesPerVector(T.byteCount)
        // A chunk of values at a time: computed into a stack buffer by a plain loop, which vectorizes the
        // caller's `value`, then loaded back a vector of lanes at a time and packed. Building lanes from
        // the values directly let LLVM merge the vector's construction into the shuffle: one byte insert
        // per byte (40 per vector for 3-byte groups), slower than not shuffling. Unsafe: the buffer is
        // uninitialized stack memory. Safe: each chunk's values are written before they're loaded.
        let chunk = chunkVectors
        return withUnsafeTemporaryAllocation(of: T.Integer.self, capacity: chunk &* perVector) { buffer in
            let base = buffer.baseAddress!
            var done = 0
            while done < vectors {
                let packing = Swift.min(chunk, vectors &- done)
                let first = done &* perVector
                for index in 0..<(packing &* perVector) {
                    unsafe (base + index).initialize(to: value(first &+ index))
                }
                for index in 0..<packing {
                    let lanes = unsafe UnsafeRawPointer(base).loadUnaligned(fromByteOffset: index &* 16, as: SIMD16<UInt8>.self)
                    let packed = pack(lanes, byteCount: T.byteCount, bigEndian: bigEndian)
                    unsafe bytes.storeBytes(of: packed, toUncheckedByteOffset: start &+ (done &+ index) &* stride, as: SIMD16<UInt8>.self)
                }
                done &+= packing
            }
            return vectors &* perVector
        }
    }
}
